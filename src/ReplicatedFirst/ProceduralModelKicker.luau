--!strict
-- Throttles ProceduralModel OnGenerate fires to stay under Roblox's
-- EditableMesh concurrency cap (~7 alive at once).
--
-- Why detach Generator instead of just bumping Version: when a PM
-- replicates with Generator already set, the engine fires OnGenerate
-- automatically. With many PMs in the scene that means tens of
-- generators racing in parallel at startup, blowing the EM budget
-- before our queue gets a chance. So at start we immediately stash +
-- clear Generator on every PM (which suppresses the next auto-fire),
-- then re-attach through the throttled queue one at a time. New PMs
-- that arrive later go through the same stash → queue → restore path.
--
-- Each restore waits for a fire of ReplicatedStorage.GeneratorDone
-- (the BindableEvent generators fire at the end of OnGenerate via
-- GeneratorSignal.wrap) before freeing its slot, with a per-fire
-- timeout fallback so a generator that errors before firing doesn't
-- deadlock the queue.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local Kicker = {}

local IN_FLIGHT_CAP = 4
-- Bumped from 5s to 15s — QEM decimation makes a typical SDF mesh take
-- longer to bake than the old coplanar pass. Premature timeouts caused
-- the kicker to free slots while generators were still actually running,
-- which over-subscribed the EM budget.
local KICK_TIMEOUT = 15.0
local SIGNAL_NAME = "GeneratorDone"

local pending: { Instance } = {}
local stashed: { [Instance]: any } = {}
local enqueued: { [Instance]: boolean } = {}
-- Rekick requests that arrived for a PM while it was already in pending or
-- mid-bake. We can't safely re-add to pending in that state (re-dispatching
-- a mid-bake PM blows the EM concurrent cap and produces duplicate
-- geometry), so we set a flag here and the drain watcher processes the
-- request via a fresh enqueue once the in-flight bake completes.
local rekickAfterByPM: { [Instance]: boolean } = {}
local draining = false
local started = false

local function ensureSignal(): BindableEvent
	local sig = ReplicatedStorage:FindFirstChild(SIGNAL_NAME)
	if sig and sig:IsA("BindableEvent") then
		return sig
	end
	if sig then
		sig:Destroy()
	end
	local b = Instance.new("BindableEvent")
	b.Name = SIGNAL_NAME
	b.Parent = ReplicatedStorage
	return b
end

local function bumpVersion(inst: Instance)
	local current = inst:GetAttribute("Version")
	if typeof(current) == "number" then
		inst:SetAttribute("Version", current + 1)
	else
		inst:SetAttribute("Version", 1)
	end
end

-- Detach + remember the Generator so the engine can't auto-fire OnGenerate.
-- Returns true if anything was actually detached (so caller can decide
-- whether the PM still has work to do).
local function freezePM(pm: Instance): boolean
	if pm.ClassName ~= "ProceduralModel" then return false end
	if stashed[pm] ~= nil then return true end
	local gen = (pm :: any).Generator
	if gen then
		stashed[pm] = gen
		;(pm :: any).Generator = nil
		return true
	end
	return false
end

local function getLayer(inst: Instance): number
	local v = inst:GetAttribute("Layer")
	if typeof(v) == "number" then return math.floor(v) end
	return 0
end

-- Forward declaration: the drain watcher closes over `enqueue` (to process
-- queued rekick-after requests), but `enqueue` itself calls `drain()`.
-- Resolve the chicken-and-egg via a forward-declared local that the
-- function definition below assigns into.
local enqueue: (Instance) -> ()

local function drain()
	if draining then return end
	draining = true
	task.spawn(function()
		local signal = ensureSignal()
		local fireCount = 0
		local conn = signal.Event:Connect(function()
			fireCount += 1
		end)

		local issued = 0
		local inFlight = 0
		-- Per-layer in-flight counts. Layer N can't dispatch while any
		-- layer < N is still in flight, so PMs that consume the world
		-- (fences raycasting against terrain, decals reading splines, …)
		-- only fire after the layer they depend on has fully baked.
		local inFlightByLayer: { [number]: number } = {}
		local function minInFlightLayer(): number
			local m = math.huge
			for layer, count in pairs(inFlightByLayer) do
				if count > 0 and layer < m then m = layer end
			end
			return m
		end

		-- Pick the lowest-layer pending PM. Defaults to layer 0 when the
		-- attribute is absent. Linear scan — pending is small in practice.
		local function pickNextPending(): (number?, number?)
			local bestIdx: number?, bestLayer = nil, math.huge
			for idx, p in ipairs(pending) do
				local L = getLayer(p)
				if L < bestLayer then
					bestLayer = L
					bestIdx = idx
				end
			end
			if bestIdx then return bestIdx, bestLayer end
			return nil, nil
		end

		-- Single loop covers both phases: dispatching from `pending` and
		-- waiting for in-flight slots to free. A new PM arriving during
		-- the latter phase (e.g., CloudManager spawning a cloud after the
		-- initial sweep finished) goes into `pending`, which this loop's
		-- condition picks up on the next iteration. The old two-loop
		-- structure had a dead window — once `pending` emptied it stopped
		-- watching `pending`, and `enqueue → drain()` was a no-op while
		-- `draining` was still true, so late arrivals sat orphaned.
		--
		-- Diagnostic: track in-flight PMs by name + start time so a stall
		-- dump can show what's actually holding up the queue.
		local inFlightInfo: { [number]: { name: string, layer: number, target: number, start: number } } = {}
		local stallTicks = 0
		local lastStallReport = 0
		while #pending > 0 or inFlight > 0 do
			local dispatched = false
			if #pending > 0 and inFlight < IN_FLIGHT_CAP then
				local idx, layer = pickNextPending()
				if idx and layer and layer <= minInFlightLayer() then
					local inst = table.remove(pending, idx)
					if inst and inst.Parent and inst.ClassName == "ProceduralModel" then
						local stashedGen = stashed[inst]
						local liveGen = (inst :: any).Generator
						-- Skip PMs that have no Generator at all — neither
						-- stashed (we'd restore on dispatch) nor live (we'd
						-- bumpVersion on dispatch, but bumpVersion on a PM
						-- with no Generator does NOTHING, so the engine
						-- never fires OnGenerate and our watcher just sits
						-- the whole 15s KICK_TIMEOUT for nothing. Worse:
						-- because the missed notify never increments
						-- fireCount, every subsequent kick's myTarget is
						-- offset by 1 from fireCount forever — every
						-- subsequent batch's last kicks then time out too.
						-- Symptom in the wild: persistent `issued-fireCount=N`
						-- gap and N kicks per batch hitting KICK_TIMEOUT.
						if not stashedGen and not liveGen then
							enqueued[inst] = nil
							rekickAfterByPM[inst] = nil
							warn(string.format(
								"[Kicker] skipping %s — no Generator (would never fire OnGenerate)",
								inst.Name))
							dispatched = true
							stallTicks = 0
						else
							issued += 1
							inFlight += 1
							inFlightByLayer[layer] = (inFlightByLayer[layer] or 0) + 1
							local myTarget = issued
							local myLayer = layer
							local instName = inst.Name
							inFlightInfo[myTarget] = {
								name = instName, layer = myLayer,
								target = myTarget, start = os.clock(),
							}
							-- Pick exactly one regen trigger per kick. Restoring
							-- Generator (nil → ModuleScript) and SetAttribute("Version", …)
							-- are both independent regen triggers on a ProceduralModel —
							-- doing both fires OnGenerate twice and the second fire's
							-- output stacks on top of the first, producing duplicate
							-- meshes (visible as double-baked cliffs/caps for landmass).
							if stashedGen then
								stashed[inst] = nil
								;(inst :: any).Generator = stashedGen
							else
								bumpVersion(inst)
							end

						task.spawn(function()
							local start = os.clock()
							while fireCount < myTarget and (os.clock() - start) < KICK_TIMEOUT do
								task.wait()
							end
							local elapsed = os.clock() - start
							if elapsed >= KICK_TIMEOUT then
								warn(string.format(
									"[Kicker] kick #%d (%s, layer %d) hit KICK_TIMEOUT=%.1fs without a done-signal — fireCount=%d target=%d. Continuing anyway.",
									myTarget, instName, myLayer, KICK_TIMEOUT, fireCount, myTarget))
							end
							inFlight -= 1
							inFlightByLayer[myLayer] = (inFlightByLayer[myLayer] or 1) - 1
							inFlightInfo[myTarget] = nil
							-- Clear the enqueued flag now that this PM's bake is
							-- done, so future rekicks can re-add it to pending.
							-- Then process any "rekick again" request that landed
							-- while this bake was running — that's how attr-driven
							-- re-bakes (e.g. another day change mid-bake) get
							-- routed through the throttled queue instead of
							-- racing against the in-flight bake.
							enqueued[inst] = nil
							if rekickAfterByPM[inst] then
								rekickAfterByPM[inst] = nil
								if inst.Parent then
									enqueue(inst)
								end
							end
						end)
						dispatched = true
						stallTicks = 0 -- progress made, reset stall counter
						end -- closes: if not stashedGen and not liveGen / else
					end
				end
			end
			if not dispatched then
				-- Either at cap, pending empty but slots in flight, or
				-- the next pending PM is in a higher layer than something
				-- still baking. Yield and re-check.
				stallTicks += 1
				-- Every ~2 seconds (~120 ticks at 60Hz) of no progress,
				-- dump state so it's clear what's blocking the queue.
				if stallTicks > 0 and stallTicks % 120 == 0 and (os.clock() - lastStallReport) > 1.5 then
					lastStallReport = os.clock()
					local now = os.clock()
					local inFlightSummary = {}
					for tgt, info in pairs(inFlightInfo) do
						table.insert(inFlightSummary, string.format(
							"#%d %s (layer %d, %.1fs)",
							tgt, info.name, info.layer, now - info.start))
					end
					warn(string.format(
						"[Kicker] stalled %.1fs: pending=%d inFlight=%d (cap=%d) issued=%d fireCount=%d minInFlightLayer=%g | in-flight: [%s]",
						stallTicks / 60, #pending, inFlight, IN_FLIGHT_CAP,
						issued, fireCount, minInFlightLayer(),
						table.concat(inFlightSummary, ", ")))
					-- Cross-reference with GeneratorSignal exit-path stats.
					-- bailReentrancy > 0 + issued > fireCount = the missed
					-- notifies came from kicker dispatches that landed on a
					-- PM whose previous bake was still in-flight (KICK_TIMEOUT
					-- already fired its watcher → re-dispatched too soon).
					local gsOk, gsModule = pcall(require, script.Parent.WorldAnimation.GeneratorSignal)
					if gsOk and gsModule and gsModule._debugStats then
						local s = gsModule._debugStats
						warn(string.format(
							"[Kicker]    GeneratorSignal stats: notifies=%d bodyOk=%d bodyErr=%d bailServer=%d bailReentry=%d",
							s.notifyCalls, s.bodyOk, s.bodyError,
							s.bailServer, s.bailReentrancy))
					end
				end
				task.wait()
			end
		end

		conn:Disconnect()
		draining = false
	end)
end

enqueue = function(inst: Instance)
	if inst.ClassName ~= "ProceduralModel" then return end
	if enqueued[inst] then return end
	enqueued[inst] = true
	-- Freeze immediately so the engine doesn't auto-fire OnGenerate while
	-- the PM sits in the queue.
	freezePM(inst)
	table.insert(pending, inst)
	if started then
		drain()
	end
end

-- Hook DescendantAdded at module-require time, not start time. Bootstrap
-- requires several other modules between this require and our .start() —
-- some of those may yield, during which workspace replication can deliver
-- new PMs. Hooking here captures them the moment they arrive and freezes
-- their Generator before the engine schedules OnGenerate. drain() is
-- gated on `started` so nothing actually fires until start() is called.
Workspace.DescendantAdded:Connect(enqueue)

-- Sweep any PMs that already replicated before this module loaded, then
-- start draining the queue at IN_FLIGHT_CAP fires at a time.
function Kicker.start()
	if started then return end
	for _, d in ipairs(Workspace:GetDescendants()) do
		enqueue(d)
	end
	started = true
	if #pending > 0 then
		print(string.format("[Kicker] queued %d ProceduralModel(s) at startup", #pending))
	end
	drain()
end

-- Detach Generator without enqueueing for restore. Use this when caller
-- wants to write attributes (e.g. SeasonDirector pushing seasonal palette
-- values) without the engine auto-firing OnGenerate per write — then
-- caller pairs it with `rekick(pm)` after the writes are done.
function Kicker.freeze(pm: Instance)
	freezePM(pm)
end

-- Returns whatever generator the PM "really" has — its live Generator if
-- set, else the stashed copy (for PMs the kicker has frozen mid-drain).
-- SeasonDirector uses this so its initial walk can find the generator
-- name on PMs that the kicker hasn't restored yet at startup.
function Kicker.getActiveGenerator(pm: Instance): Instance?
	local live = (pm :: any).Generator
	if live then return live end
	return stashed[pm]
end

-- Re-enqueue an already-baked PM through the throttled queue. SeasonDirector
-- and ReplicatedAttributeRebake call this on day-change / replicated-attr
-- events so palette/scalar updates re-bake at the same IN_FLIGHT_CAP-
-- throttled, layer-ordered cadence as the initial sweep instead of
-- slamming every PM in parallel and blowing the EM budget.
--
-- If the PM is already in pending or mid-bake (i.e. enqueued[pm] is true)
-- we DON'T add a second pending entry — that would dispatch the same PM
-- twice, blow the EM concurrent cap, and stall the queue. Instead we set
-- a "needs another rekick after this one finishes" flag, and the drain
-- watcher re-enqueues for us when the in-flight bake completes.
function Kicker.rekick(pm: Instance)
	if pm.ClassName ~= "ProceduralModel" then return end
	if enqueued[pm] then
		rekickAfterByPM[pm] = true
		return
	end
	enqueue(pm)
end

function Kicker.rekickAll()
	Kicker.rekickWhere(nil)
end

-- Re-enqueue every PM whose `predicate(pm)` returns true. SeasonDirector
-- uses this to skip clouds/grass and any other generator that doesn't
-- actually read WorldSettings or seasonal palettes — slamming those
-- through the throttled queue on every day step costs bake time for zero
-- visual change. `nil` predicate = kick everything (back-compat).
function Kicker.rekickWhere(predicate: ((pm: Instance) -> boolean)?)
	local count = 0
	for _, d in ipairs(Workspace:GetDescendants()) do
		if d.ClassName == "ProceduralModel" then
			if predicate == nil or predicate(d) then
				Kicker.rekick(d)
				count += 1
			end
		end
	end
	if count > 0 then
		print(string.format("[Kicker] rekick queued %d ProceduralModel(s)", count))
	end
end

return Kicker
