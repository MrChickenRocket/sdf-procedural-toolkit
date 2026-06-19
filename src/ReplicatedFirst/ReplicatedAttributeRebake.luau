--!strict
-- Client-side workaround for a Roblox limitation: ProceduralModel does
-- NOT auto-fire OnGenerate on a client when an attribute is changed by
-- the server and replicated. The replicated value lands on the client's
-- PM (and AttributeChanged fires), but the engine's procedural-model
-- bake hook only triggers for changes made on THIS process. So without
-- intervention, server-driven SeasonDirector writes never re-bake.
--
-- This module hooks AttributeChanged on every ProceduralModel in
-- Workspace. Any non-Version attribute change schedules a deferred
-- *kicker rekick* on that PM. The rekick goes through the kicker's
-- IN_FLIGHT_CAP throttle so a SeasonDirector tick that touches every
-- landmass at once doesn't slam 50 EditableMesh allocations into the
-- engine simultaneously and blow the concurrent EM cap.
--
-- The defer coalesces a batch of writes (one SeasonDirector tick on a
-- single PM writes 7+ attrs in one frame) into a single rekick.
-- The Version-skip in the listener avoids a self-triggered loop when
-- the kicker / rekick path itself bumps Version.

local Workspace = game:GetService("Workspace")
local ReplicatedFirst = game:GetService("ReplicatedFirst")

local ProceduralModelKicker = require(ReplicatedFirst.ProceduralModelKicker)

local ReplicatedAttributeRebake = {}

-- AttributeChanged listeners, one per PM. Stored so we can disconnect
-- on PM removal (otherwise the connection holds the PM alive after
-- it leaves Workspace).
local connByPM: { [Instance]: { RBXScriptConnection } } = {}

-- Per-PM "rekick pending" guard so a batch of attribute writes in the
-- same frame produces exactly one rekick (and therefore one OnGenerate
-- fire), not one per attribute.
local rekickPending: { [Instance]: boolean } = {}

-- Diagnostic: throttled batch summary so we don't spam the log on a day
-- change that touches 50+ PMs, but we do see "this many rekicks fired
-- this frame" for stall debugging.
local frameBatch = { count = 0, lastReport = 0 }

local function watchPM(pm: Instance)
	if connByPM[pm] then return end
	if pm.ClassName ~= "ProceduralModel" then return end
	local conns: { RBXScriptConnection } = {}
	connByPM[pm] = conns

	table.insert(conns, pm.AttributeChanged:Connect(function(attrName: string)
		if attrName == "Version" then return end
		if rekickPending[pm] then return end
		rekickPending[pm] = true
		task.defer(function()
			rekickPending[pm] = nil
			if not pm.Parent then return end
			-- Route through the kicker's throttled queue (IN_FLIGHT_CAP=4)
			-- instead of bumping Version directly. Without the throttle,
			-- N PMs all rebaking in one frame allocates N concurrent
			-- EditableMeshes and blows the engine's hard cap.
			ProceduralModelKicker.rekick(pm)
			frameBatch.count += 1
			-- Coalesce per-rekick prints into one summary per ~500ms so
			-- a SeasonDirector tick produces a single "kicked N PMs"
			-- line instead of 50.
			local now = os.clock()
			if now - frameBatch.lastReport > 0.5 then
				print(string.format("[ReplicatedAttributeRebake] rekicked %d PM(s)", frameBatch.count))
				frameBatch.count = 0
				frameBatch.lastReport = now
			end
		end)
	end))

	table.insert(conns, pm.AncestryChanged:Connect(function(_, parent)
		if parent == nil then
			-- PM removed — drop our listeners and any pending rekick.
			for _, c in ipairs(conns) do c:Disconnect() end
			connByPM[pm] = nil
			rekickPending[pm] = nil
		end
	end))
end

local started = false

function ReplicatedAttributeRebake.start()
	if started then return end
	started = true

	for _, d in ipairs(Workspace:GetDescendants()) do
		watchPM(d)
	end
	Workspace.DescendantAdded:Connect(watchPM)
end

return ReplicatedAttributeRebake
