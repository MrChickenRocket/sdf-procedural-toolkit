--!strict
-- EvalSet — one-click repro of the SdfMesher2 quality/perf eval set.
--
-- Bakes the six canonical shapes in a row through the v2 mesher:
--   box · chamfered box · rounded box · cylinder · chamfered cylinder · rounded cylinder
-- Each demonstrates crisp-where-sharp, smooth-where-round, minimal geometry.
-- build() also prints a per-phase timing line per shape (see docs/07).
--
-- Run from the Studio command bar (Edit mode):
--   require(game.ReplicatedFirst.Examples.EvalSet).run()     -- v2 (uniform grid)
--   require(game.ReplicatedFirst.Examples.EvalSet).runV3()   -- v3 (adaptive octree; faster)
--
-- Options (all optional):
--   require(game.ReplicatedFirst.Examples.EvalSet).run({
--     origin   = Vector3.new(0, 3.2, 0),  -- where the first shape's centre goes
--     cellSize = 0.12,                     -- resolution (0.10–0.15 is the sweet spot)
--     spacing  = 10,                       -- gap between shapes along +X
--     parent   = workspace,
--   })
-- Re-running clears the previous set (it's tagged with the "SdfEvalSet" attribute).

local SdfMesher2 = require(script.Parent.Parent.SdfMesher2)
local SdfMesher3 = require(script.Parent.Parent.SdfMesher3)

local EvalSet = {}

local SHAPES = {
	{ name = "Box", color = Color3.fromRGB(150, 170, 200), node = { shape = "box", semi = Vector3.new(3, 3, 3) } },
	{ name = "ChamferBox", color = Color3.fromRGB(210, 180, 140), node = { shape = "box", semi = Vector3.new(3, 3, 3), bevel = 0.9 } },
	{ name = "RoundBox", color = Color3.fromRGB(170, 150, 210), node = { shape = "box", semi = Vector3.new(3, 3, 3), rounding = 0.9 } },
	{ name = "Cylinder", color = Color3.fromRGB(160, 200, 170), node = { shape = "cylinder", radius = 3, height = 6 } },
	{ name = "ChamferCyl", color = Color3.fromRGB(200, 160, 190), node = { shape = "cylinder", radius = 3, height = 6, bevel = 0.9 } },
	{ name = "RoundCyl", color = Color3.fromRGB(210, 200, 150), node = { shape = "cylinder", radius = 3, height = 6, rounding = 0.9 } },
}

-- Simple baked-lighting shader (key + sky fill); normals from v2 are exact.
local function makeShader(base: Color3, sun: Vector3)
	return function(_v: Vector3, n: Vector3, _w, _crease: number): Color3
		local k = math.max(0, n:Dot(sun))
		local sky = math.max(0, n.Y * 0.5 + 0.5)
		local i = math.clamp(0.42 + 0.55 * k + 0.12 * sky, 0, 1.25)
		return Color3.new(math.clamp(base.R * i, 0, 1), math.clamp(base.G * i, 0, 1), math.clamp(base.B * i, 0, 1))
	end
end

export type RunOpts = {
	origin: Vector3?,
	cellSize: number?,
	spacing: number?,
	parent: Instance?,
	sun: Vector3?,
}

function EvalSet.run(opts: RunOpts?): Model
	local o = opts or {}
	local origin = o.origin or Vector3.new(0, 3.2, 0)
	local cellSize = o.cellSize or 0.12
	local spacing = o.spacing or 10
	local parent = o.parent or workspace
	local sun = (o.sun or Vector3.new(0.4, 0.8, 0.45)).Unit

	-- Clear a previous run.
	for _, c in ipairs(parent:GetChildren()) do
		if c:GetAttribute("SdfEvalSet") then
			c:Destroy()
		end
	end

	local model = Instance.new("Model")
	model.Name = "SdfEvalSet"
	model:SetAttribute("SdfEvalSet", true)

	local summary = {}
	for i, s in ipairs(SHAPES) do
		local res, msg = SdfMesher2.build(s.node, {
			cellSize = cellSize,
			vertexColorFn = makeShader(s.color, sun),
			renderFidelity = Enum.RenderFidelity.Precise,
			collisionFidelity = Enum.CollisionFidelity.Box,
		})
		if not res then
			warn(`[EvalSet] {s.name} failed: {tostring(msg)}`)
		else
			local mp = res.meshPart
			mp.Name = s.name
			mp.Anchored = true
			mp.Material = Enum.Material.SmoothPlastic
			mp.Color = Color3.new(1, 1, 1) -- let the baked vertex colours show
			mp.Position = origin + Vector3.new((i - 1) * spacing, 0, 0)
			mp.Parent = model
			table.insert(summary, `{s.name}={res.triCount}t`)
		end
	end

	model.Parent = parent
	print("[EvalSet] " .. table.concat(summary, "  "))
	return model
end

-- Same six shapes through the v3 adaptive octree mesher. `detailTol` is the
-- quality/speed dial (lower = finer). Parts get SmoothPlastic + a little
-- reflectance so the surface reads like a plastic toy.
function EvalSet.runV3(opts: RunOpts?): Model
	local o = opts or {}
	local origin = o.origin or Vector3.new(0, 3.2, 0)
	local spacing = o.spacing or 10
	local parent = o.parent or workspace
	local sun = (o.sun or Vector3.new(0.4, 0.8, 0.45)).Unit
	local detailTol = (o :: any).detailTol or 0.08

	for _, c in ipairs(parent:GetChildren()) do
		if c:GetAttribute("SdfEvalSetV3") then
			c:Destroy()
		end
	end

	local model = Instance.new("Model")
	model.Name = "SdfEvalSetV3"
	model:SetAttribute("SdfEvalSetV3", true)

	-- Hero-quality defaults: `uniform` even surface cells (wave-free curves) +
	-- 2 `subdivide` levels (adaptive curved-edge split with each new vertex
	-- projected onto the surface — smooths curves & silhouettes, leaves flat
	-- faces and sharp edges untouched). Slow-ish, but these are single hero
	-- primitives. Pass uniform=false / subdivide=0 for the fast adaptive look.
	local uniform = (o :: any).uniform ~= false
	local subdivide = (o :: any).subdivide or 2
	local summary = {}
	for i, s in ipairs(SHAPES) do
		local res, msg = SdfMesher3.build(s.node, {
			detailTol = detailTol,
			uniform = uniform,
			subdivide = subdivide,
			vertexColorFn = makeShader(s.color, sun),
			renderFidelity = Enum.RenderFidelity.Precise,
			collisionFidelity = Enum.CollisionFidelity.Box,
		})
		if not res then
			warn(`[EvalSet.runV3] {s.name} failed: {tostring(msg)}`)
		else
			local mp = res.meshPart
			mp.Name = s.name
			mp.Anchored = true
			mp.Material = Enum.Material.SmoothPlastic
			mp.Reflectance = 0.1
			mp.Color = Color3.new(1, 1, 1)
			mp.Position = origin + Vector3.new((i - 1) * spacing, 0, 0)
			mp.Parent = model
			table.insert(summary, `{s.name}={res.triCount}t`)
		end
	end

	model.Parent = parent
	print("[EvalSet.runV3] " .. table.concat(summary, "  "))
	return model
end

return EvalSet
