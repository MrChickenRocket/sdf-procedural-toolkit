--!strict
-- Generator → kicker handshake. Each ProceduralModel generator should
-- call GeneratorSignal.notify() at the end of OnGenerate; the
-- EditableMeshKicker plugin (and the runtime kicker) use it to throttle
-- the next Version bump so we don't pile up EditableMesh allocations
-- beyond the engine's hard concurrent cap.
--
-- The BindableEvent lives in ReplicatedStorage so the plugin (running
-- outside the generator sandbox) can find the same instance.

local CollectionService = game:GetService("CollectionService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local SIGNAL_NAME = "GeneratorDone"

local GeneratorSignal = {}
GeneratorSignal.SIGNAL_NAME = SIGNAL_NAME

local function ensure(): BindableEvent
	local existing = ReplicatedStorage:FindFirstChild(SIGNAL_NAME)
	if existing and existing:IsA("BindableEvent") then
		return existing
	end
	if existing then
		existing:Destroy()
	end
	local sig = Instance.new("BindableEvent")
	sig.Name = SIGNAL_NAME
	sig.Parent = ReplicatedStorage
	return sig
end

-- Diagnostic: counters of every place wrap() can exit, so we can correlate
-- with the kicker's issued/fireCount imbalance reports.
local debugStats = {
	notifyCalls = 0,         -- actual GeneratorSignal.notify() invocations
	bailServer = 0,          -- exited via play-mode-server bail (no notify)
	bailReentrancy = 0,      -- exited via re-entrancy short-circuit (no notify)
	bodyOk = 0,              -- body ran to completion, notify fired
	bodyError = 0,           -- body errored (pcall caught), notify still fired
}
GeneratorSignal._debugStats = debugStats

function GeneratorSignal.notify()
	debugStats.notifyCalls += 1
	pcall(function()
		ensure():Fire()
	end)
end

-- Periodic dump so the kicker can correlate accounting drift with where
-- the missed notifies came from. Once-per-3-seconds rate so it doesn't
-- spam logs.
local lastStatsPrint = 0
local function maybePrintStats()
	local now = os.clock()
	if now - lastStatsPrint < 3 then return end
	lastStatsPrint = now
	print(string.format(
		"[GeneratorSignal] notifies=%d bodyOk=%d bodyErr=%d bailServer=%d bailReentry=%d",
		debugStats.notifyCalls, debugStats.bodyOk, debugStats.bodyError,
		debugStats.bailServer, debugStats.bailReentrancy))
end
GeneratorSignal._maybePrintStats = maybePrintStats

function GeneratorSignal.event(): RBXScriptSignal
	return ensure().Event
end

-- Per-PM re-entrancy guard. ProceduralModel auto-fires OnGenerate any time
-- an attribute changes. Generators that yield (AssetService bake calls are
-- async) can therefore have a SECOND OnGenerate invoked on the same PM
-- mid-bake — both calls then run concurrently in the same generator
-- sandbox, which produces duplicate geometry (the first bake's MeshPart
-- ends up parented alongside the second's) and corrupts any module-level
-- state the generator might use across nested fieldAt-style calls.
--
-- The guard, keyed by the PM's stable Guid attribute (stamped by
-- PolyEdit / similar), short-circuits re-entrant calls and queues a
-- single deferred refire (Version bump) at the end of the in-flight one.
-- That way the latest attribute snapshot still gets baked, but only after
-- the current bake fully completes — no concurrent fires.
--
-- PMs without a Guid attribute (e.g. Tree, Cloud — single-shot bakes that
-- don't yield long enough for re-entry to matter in practice) skip the
-- guard and behave as before.
local inProgressByGuid: { [string]: boolean } = {}
local refireQueuedByGuid: { [string]: boolean } = {}

local function findPMByGuid(guid: string): Instance?
	for _, inst in CollectionService:GetTagged("HAS_GUID") do
		if inst:GetAttribute("Guid") == guid then return inst end
	end
	return nil
end

-- Wrap a generator's OnGenerate so it always fires the done signal at
-- the end (success, early-return, or error). Errors are pcall'd into a
-- warn so the kicker queue doesn't stall on an exception. Guards against
-- re-entrant calls per PM (see above).
-- One-time warn flag so we don't spam the log if many PMs all try to
-- bake on the play-mode server at the same instant.
local serverBailWarned = false

function GeneratorSignal.wrap(fn: (any, Instance) -> ()): (any, Instance) -> ()
	return function(parameters: any, targetContainer: Instance)
		-- During play, only clients should bake. The server's OnGenerate
		-- would produce duplicate / racing geometry against clients'
		-- bakes (which the engine fires when the PM replicates), and
		-- server-side EditableMesh allocations don't benefit gameplay
		-- since the resulting MeshParts can't replicate cleanly.
		-- Edit-time plugin bakes (IsRunning() == false) still proceed.
		if RunService:IsRunning() and RunService:IsServer() then
			if not serverBailWarned then
				serverBailWarned = true
				warn("[GeneratorSignal] OnGenerate fired on the play-mode SERVER — bailing. (further bails silent for this session)")
			end
			-- Don't fire the done-signal: the kicker uses notify count to
			-- track real bake completions, and the server doesn't bake.
			-- (And the kicker only runs on clients anyway.)
			debugStats.bailServer += 1
			return
		end

		local guid: string? = nil
		local rawGuid = parameters and parameters.Attributes and parameters.Attributes.Guid
		if typeof(rawGuid) == "string" and #rawGuid > 0 then
			guid = rawGuid
		end

		if guid and inProgressByGuid[guid] then
			-- Another OnGenerate for this PM is mid-bake. Queue a refire to
			-- run after it finishes; drop this one to avoid concurrent state.
			-- Don't notify — this OnGenerate didn't actually bake, and
			-- inflating the kicker's fireCount on short-circuits causes it
			-- to think more PMs have completed than actually have, which
			-- pulls inFlight below zero and dispatches more PMs concurrently
			-- than IN_FLIGHT_CAP allows (blowing the EM cap).
			refireQueuedByGuid[guid] = true
			debugStats.bailReentrancy += 1
			-- Diagnostic: re-entry from the engine = something fired
			-- OnGenerate while we were already mid-bake on this PM. The
			-- kicker doesn't know this fire happened, so its issued count
			-- stays correct, but if the IN-FLIGHT call was a kicker
			-- dispatch and this re-entry gets the body to short-circuit,
			-- the *kicker's* OnGenerate gets to notify normally. The
			-- problematic case is the OPPOSITE: kicker dispatches, but
			-- inProgressByGuid is already true (from a prior engine
			-- auto-fire that's still in flight), so the kicker's OnGenerate
			-- gets short-circuited and never notifies. That misses a
			-- fireCount increment.
			print(string.format(
				"[GeneratorSignal] re-entry short-circuit on guid=%s — body skipped, refire queued",
				guid))
			return
		end

		if guid then
			inProgressByGuid[guid] = true
		end

		-- Diagnostic: ProceduralModel does NOT auto-delete previous-bake
		-- children before a new OnGenerate fires. Anything left in the
		-- target container will MERGE with what this fire emits, producing
		-- doubled / stale geometry. If we see leftovers here, either the
		-- previous bake's cleanup didn't run, the kicker / runtime bumped
		-- Version without a stash+detach, or a generator emitted children
		-- it doesn't re-emit on every fire (so there's nothing forcing a
		-- delete). Warn loudly with the names so it's easy to track down.
		local existing = targetContainer:GetChildren()
		if #existing > 0 then
			local names = table.create(#existing)
			for i, c in ipairs(existing) do names[i] = c.Name end
			local guidTag = guid and (" guid=" .. guid) or ""
			warn(string.format("[GeneratorSignal] target container had %d leftover child(ren) at OnGenerate start%s: %s",
				#existing, guidTag, table.concat(names, ", ")))
		end

		local ok, err = pcall(fn, parameters, targetContainer)
		if not ok then
			warn("[GeneratorSignal] generator errored: " .. tostring(err))
			debugStats.bodyError += 1
		else
			debugStats.bodyOk += 1
		end

		if guid then
			inProgressByGuid[guid] = nil
			if refireQueuedByGuid[guid] then
				refireQueuedByGuid[guid] = nil
				-- Defer the refire through the kicker's throttled queue
				-- instead of bumping Version directly. Direct bumps bypass
				-- the IN_FLIGHT_CAP throttle and can blow the EM cap when a
				-- batch of PMs all need refiring at once. The kicker's
				-- rekickAfterByPM flow handles the case where this PM is
				-- still in-flight for the kicker (clearing enqueued and
				-- requeuing happens once the watcher exits).
				--
				-- Lazy-require the kicker so generator sandboxes that don't
				-- have access to it (e.g. running in a context where the
				-- module path doesn't resolve) gracefully fall back to a
				-- direct Version bump.
				local capturedGuid = guid
				task.defer(function()
					local pm = findPMByGuid(capturedGuid)
					if not pm or not pm.Parent then return end
					-- script.Parent.Parent.ProceduralModelKicker resolves to
					-- ReplicatedFirst.ProceduralModelKicker. Lazy-require so
					-- a sandbox without access to it (or a load-order edge
					-- case) falls back to a direct Version bump rather than
					-- erroring out.
					local kickerModule = (script.Parent.Parent :: any):FindFirstChild("ProceduralModelKicker")
					local rOk, kicker = pcall(require, kickerModule)
					if rOk and kicker and (kicker :: any).rekick then
						(kicker :: any).rekick(pm)
					else
						local v = tonumber(pm:GetAttribute("Version")) or 0
						pm:SetAttribute("Version", v + 1)
					end
				end)
			end
		end

		GeneratorSignal.notify()
	end
end

return GeneratorSignal
