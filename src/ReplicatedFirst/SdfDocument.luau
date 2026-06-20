--!strict
-- SdfDocument — a thin authoring layer over SdfMesher.
--
-- A "document" describes a whole MULTI-PART figure as plain data: a list of
-- bake GROUPS, each holding a flat list of shape-tagged PRIMITIVES. `bake`
-- turns a document into a `Model` of baked MeshParts (one per group).
--
-- This is the canonical intermediate representation for SDF authoring. The
-- same document can be:
--   • hand-written / AI-written as a Luau table (see Documents/Soldier), or
--   • extracted from a tree of Parts in Studio (Block→box, Ball→ellipsoid,
--     Cylinder→capsule; CFrame→frame, Size/2→semi, attributes→op/bevel/…).
-- Either front-end produces the same table; this module adapts + drives it.
--
-- The engine (SdfMesher) is UNTOUCHED — this only (a) flattens the friendly
-- shape-tagged prim list into SdfMesher's parallel add/subtract arrays, and
-- (b) loops the groups, applying the multi-part assembly rule (every part of
-- one document shares the authoring frame, so they all bake at the same world
-- `origin`; see docs/06 → "Assembling multi-part figures").

local SdfMesher = require(script.Parent.SdfMesher)
local SdfMesher2 = require(script.Parent.SdfMesher2)
local SdfMesher3 = require(script.Parent.SdfMesher3)

local SdfDocument = {}

SdfDocument.VERSION = "2026-06-19-doc-v1"

-- ─────────────────────────────────────────────────────────────
-- Types
-- ─────────────────────────────────────────────────────────────

-- One primitive. `shape` selects the family; the rest are shape-specific.
--   box            → center|cframe + semi (+ rounding | bevel)
--   ellipsoid      → center + semi   (uniform semi = sphere, hits fast path)
--   capsule        → a + b + radius
--   taperedCapsule → a + b + radiusA + radiusB   (add-only)
-- `op` is "add" (default) or "subtract"; subtracts carve after the union.
export type Prim = {
	shape: string,
	op: string?,
	center: Vector3?,
	cframe: CFrame?,
	semi: Vector3?,
	rounding: number?,
	bevel: number?,
	a: Vector3?,
	b: Vector3?,
	radius: number?,
	radiusA: number?,
	radiusB: number?,
}

-- One bake group → one MeshPart. `prims` blend together (within `blend`) and
-- carve; parts of different groups never blend (hard seams).
export type Group = {
	name: string,
	prims: { Prim },
	material: Enum.Material?,
	color: Color3?, -- base colour; lit by the default shader unless colorFn is set
	colorFn: ((Vector3, Vector3, { [string]: number }, number) -> Color3)?,
	blend: number?,
	cell: number?, -- target cell size (studs); resolution is derived from it
	triCap: number?,
	boundsPadding: number?,
	renderFidelity: Enum.RenderFidelity?,
	collisionFidelity: Enum.CollisionFidelity?,
}

export type Document = {
	name: string,
	groups: { Group },
	defaults: { blend: number?, cell: number?, triCap: number?, boundsPadding: number? }?,
	sun: Vector3?,
}

export type BakeOpts = {
	origin: Vector3?, -- world point the document's authoring (0,0,0) lands on
	parent: Instance?,
	primaryGroup: string?, -- set Model.PrimaryPart to this group's part
	sun: Vector3?,
}

-- ─────────────────────────────────────────────────────────────
-- Adapter: friendly prim list → SdfMesher.Input
-- ─────────────────────────────────────────────────────────────

-- Resolve a box's orthonormal frame. A `cframe` carries it for free (always
-- orthonormal + right-handed — the whole reason Parts are a good front-end);
-- otherwise the box is axis-aligned about `center`.
local function frameOf(p: Prim): (Vector3, Vector3, Vector3)
	if p.cframe then
		local cf = p.cframe
		-- forward = +Z local axis = -LookVector (LookVector is -Z in Roblox).
		return cf.RightVector, cf.UpVector, -cf.LookVector
	end
	return Vector3.xAxis, Vector3.yAxis, Vector3.zAxis
end

local function centerOf(p: Prim): Vector3
	return p.center or (p.cframe and p.cframe.Position) or Vector3.zero
end

-- Flatten a prim list into SdfMesher's parallel arrays, bucketing by shape
-- and op. Returns the Input table SdfMesher.build expects.
function SdfDocument.adapt(prims: { Prim }): SdfMesher.Input
	local input: SdfMesher.Input = {
		ellipsoids = {},
		slabs = {},
		capsules = {},
		taperedCapsules = {},
		subtractEllipsoids = {},
		subtractSlabs = {},
		subtractCapsules = {},
	}
	for i, p in ipairs(prims) do
		local sub = p.op == "subtract"
		local shape = p.shape
		if shape == "ellipsoid" or shape == "sphere" then
			local semi = p.semi or (p.radius and Vector3.one * p.radius)
			assert(semi, `prim #{i}: ellipsoid needs semi or radius`)
			local e = { center = centerOf(p), semi = semi }
			table.insert(if sub then input.subtractEllipsoids :: any else input.ellipsoids :: any, e)
		elseif shape == "box" then
			assert(p.semi, `prim #{i}: box needs semi`)
			local right, up, forward = frameOf(p)
			local slab = {
				center = centerOf(p),
				right = right,
				up = up,
				forward = forward,
				semi = p.semi,
				rounding = p.rounding,
				bevel = p.bevel,
			}
			table.insert(if sub then input.subtractSlabs :: any else input.slabs :: any, slab)
		elseif shape == "capsule" then
			assert(p.a and p.b and p.radius, `prim #{i}: capsule needs a, b, radius`)
			local c = { a = p.a, b = p.b, radius = p.radius }
			table.insert(if sub then input.subtractCapsules :: any else input.capsules :: any, c)
		elseif shape == "taperedCapsule" then
			assert(not sub, `prim #{i}: taperedCapsule has no subtract variant`)
			assert(p.a and p.b and p.radiusA and p.radiusB, `prim #{i}: taperedCapsule needs a, b, radiusA, radiusB`)
			table.insert(input.taperedCapsules :: any, { a = p.a, b = p.b, radiusA = p.radiusA, radiusB = p.radiusB })
		else
			error(`prim #{i}: unknown shape '{tostring(shape)}'`)
		end
	end
	return input
end

-- ─────────────────────────────────────────────────────────────
-- Default shader: base colour modulated by a baked light recipe
-- (key + sky fill + fake AO + faint crease pop). Groups override via colorFn.
-- ─────────────────────────────────────────────────────────────
function SdfDocument.makeShader(color: Color3, sun: Vector3): (Vector3, Vector3, any, number) -> Color3
	local s = sun
	return function(_v: Vector3, n: Vector3, _w, crease: number): Color3
		local key = math.max(0, n:Dot(s))
		local sky = math.max(0, n.Y * 0.5 + 0.5)
		local I = 0.5 + 0.5 * key + 0.16 * sky + (crease or 0) * 0.06
		I *= (1 - math.max(0, -n.Y) * 0.22) -- fake AO underneath
		I = math.clamp(I, 0, 1.3)
		return Color3.new(
			math.clamp(color.R * I, 0, 1),
			math.clamp(color.G * I, 0, 1),
			math.clamp(color.B * I, 0, 1)
		)
	end
end

-- ─────────────────────────────────────────────────────────────
-- bake — document → Model of MeshParts
-- ─────────────────────────────────────────────────────────────
function SdfDocument.bake(doc: Document, opts: BakeOpts?): (Model, { { name: string, tris: number, cell: number } })
	local o = opts or {}
	local origin = o.origin or Vector3.zero
	local defaults = doc.defaults or {}
	local sun = o.sun or doc.sun or Vector3.new(0.5, 0.9, 0.35).Unit

	local model = Instance.new("Model")
	model.Name = doc.name or "SdfDocument"

	local stats: { { name: string, tris: number, cell: number } } = {}
	for _, g in ipairs(doc.groups) do
		local input = SdfDocument.adapt(g.prims)
		local cell = g.cell or defaults.cell or 0.15
		local pad = g.boundsPadding or defaults.boundsPadding or 0.75

		-- Derive resolution from the desired cell size (and the padding the
		-- grid will add), so density is uniform across differently-sized groups.
		local minB, maxB = SdfMesher.computeInputBounds(input, 0)
		if not minB or not maxB then
			warn(`[SdfDocument] group '{g.name}' has no add-primitives — skipped`)
			continue
		end
		local dim = maxB - minB
		local maxDim = math.max(dim.X, dim.Y, dim.Z)
		local cells = math.max(10, math.ceil((maxDim + 2 * pad) / cell))

		local colorFn = g.colorFn or SdfDocument.makeShader(g.color or Color3.new(0.6, 0.6, 0.6), sun)
		local res, msg = SdfMesher.build(input, {
			triCap = g.triCap or defaults.triCap or 20000,
			initialMaxCellsPerDim = cells,
			boundsPadding = pad,
			smoothBlend = g.blend or defaults.blend or 0,
			vertexColorFn = colorFn,
			renderFidelity = g.renderFidelity or Enum.RenderFidelity.Precise,
			collisionFidelity = g.collisionFidelity or Enum.CollisionFidelity.Box,
		})
		if not res then
			warn(`[SdfDocument] group '{g.name}' failed: {tostring(msg)}`)
		else
			local mp = res.meshPart
			mp.Name = g.name
			mp.Anchored = true
			if g.material then
				mp.Material = g.material
			end
			-- ⭐ Every group shares the document's authoring frame, so they all
			-- bake at the SAME world origin. (Do NOT add a per-group centre.)
			mp.Position = origin
			mp.Parent = model
			table.insert(stats, { name = g.name, tris = res.triCount, cell = res.cellSize })
		end
	end

	if o.primaryGroup then
		model.PrimaryPart = model:FindFirstChild(o.primaryGroup) :: BasePart?
	end
	if o.parent then
		model.Parent = o.parent
	end
	return model, stats
end

-- ─────────────────────────────────────────────────────────────
-- v2 path: compile a group's flat prim list into an SdfMesher2 op-graph and
-- bake through the sharp-feature mesher (analytic gradients, QEF sharp snap,
-- QEM minimal geometry). Same document; different engine.
-- ─────────────────────────────────────────────────────────────

local function primToNode(p: Prim): SdfMesher2.Node
	local shape = p.shape
	if shape == "ellipsoid" or shape == "sphere" then
		return { shape = "ellipsoid", center = centerOf(p), semi = p.semi or (p.radius and Vector3.one * p.radius) }
	elseif shape == "box" then
		local n: SdfMesher2.Node = { shape = "box", semi = p.semi, rounding = p.rounding, bevel = p.bevel }
		if p.cframe then n.cframe = p.cframe else n.center = centerOf(p) end
		return n
	elseif shape == "capsule" then
		return { shape = "capsule", a = p.a, b = p.b, radius = p.radius }
	elseif shape == "cylinder" then
		local n: SdfMesher2.Node = { shape = "cylinder", radius = p.radius, height = p.height, rounding = p.rounding, bevel = p.bevel }
		if p.cframe then n.cframe = p.cframe else n.center = centerOf(p) end
		return n
	end
	error(`toGraph: shape '{tostring(shape)}' not supported by SdfMesher2`)
end

-- One group → one op-graph: adds blend together (smoothUnion if blend>0),
-- then any `op="subtract"` prims carve.
function SdfDocument.toGraph(group: Group): SdfMesher2.Node
	local adds, subs = {}, {}
	for _, p in ipairs(group.prims) do
		if p.op == "subtract" then
			table.insert(subs, primToNode(p))
		else
			table.insert(adds, primToNode(p))
		end
	end
	assert(#adds > 0, `group '{group.name}' has no add primitives`)
	local addNode: SdfMesher2.Node
	if #adds == 1 then
		addNode = adds[1]
	elseif (group.blend or 0) > 0 then
		addNode = { op = "smoothUnion", blend = group.blend, children = adds }
	else
		addNode = { op = "union", children = adds }
	end
	if #subs == 0 then
		return addNode
	end
	local children = { addNode }
	for _, s in ipairs(subs) do
		table.insert(children, s)
	end
	return { op = "subtract", children = children }
end

function SdfDocument.bakeV2(doc: Document, opts: BakeOpts?): (Model, { { name: string, tris: number } })
	local o = opts or {}
	local origin = o.origin or Vector3.zero
	local defaults = doc.defaults or {}
	local sun = o.sun or doc.sun or Vector3.new(0.5, 0.9, 0.35).Unit
	local model = Instance.new("Model")
	model.Name = (doc.name or "SdfDocument") .. "_v2"
	local stats = {}
	for _, g in ipairs(doc.groups) do
		local graph = SdfDocument.toGraph(g)
		local colorFn = g.colorFn or SdfDocument.makeShader(g.color or Color3.new(0.6, 0.6, 0.6), sun)
		local res, msg = SdfMesher2.build(graph, {
			cellSize = g.cell or defaults.cell or 0.15,
			vertexColorFn = colorFn,
			renderFidelity = g.renderFidelity or Enum.RenderFidelity.Precise,
			collisionFidelity = g.collisionFidelity or Enum.CollisionFidelity.Box,
		})
		if not res then
			warn(`[SdfDocument.bakeV2] group '{g.name}' failed: {tostring(msg)}`)
		else
			local mp = res.meshPart
			mp.Name = g.name
			mp.Anchored = true
			if g.material then
				mp.Material = g.material
			end
			mp.Position = origin
			mp.Parent = model
			table.insert(stats, { name = g.name, tris = res.triCount })
		end
	end
	if o.primaryGroup then
		model.PrimaryPart = model:FindFirstChild(o.primaryGroup) :: BasePart?
	end
	if o.parent then
		model.Parent = o.parent
	end
	return model, stats
end

-- ─────────────────────────────────────────────────────────────
-- v3 path: same op-graph, baked through the adaptive octree mesher (SdfMesher3).
-- Fastest + cleanest minimal geometry; ideal for smooth "plastic-toy" content.
-- Group config maps `g.detailTol` / `g.minLeaf` (else v3 defaults). The legacy
-- `g.cell` is ignored (v3 is resolution-adaptive, not fixed-grid).
-- ─────────────────────────────────────────────────────────────

function SdfDocument.bakeV3(doc: Document, opts: BakeOpts?): (Model, { { name: string, tris: number } })
	local o = opts or {}
	local origin = o.origin or Vector3.zero
	local sun = o.sun or doc.sun or Vector3.new(0.5, 0.9, 0.35).Unit
	local model = Instance.new("Model")
	model.Name = (doc.name or "SdfDocument") .. "_v3"
	local stats = {}
	for _, g in ipairs(doc.groups) do
		local graph = SdfDocument.toGraph(g)
		local colorFn = g.colorFn or SdfDocument.makeShader(g.color or Color3.new(0.6, 0.6, 0.6), sun)
		local res, msg = SdfMesher3.build(graph, {
			detailTol = g.detailTol,
			minLeaf = g.minLeaf,
			vertexColorFn = colorFn,
			renderFidelity = g.renderFidelity or Enum.RenderFidelity.Precise,
			collisionFidelity = g.collisionFidelity or Enum.CollisionFidelity.Box,
		})
		if not res then
			warn(`[SdfDocument.bakeV3] group '{g.name}' failed: {tostring(msg)}`)
		else
			local mp = res.meshPart
			mp.Name = g.name
			mp.Anchored = true
			if g.material then
				mp.Material = g.material
			end
			mp.Position = origin
			mp.Parent = model
			table.insert(stats, { name = g.name, tris = res.triCount })
		end
	end
	if o.primaryGroup then
		model.PrimaryPart = model:FindFirstChild(o.primaryGroup) :: BasePart?
	end
	if o.parent then
		model.Parent = o.parent
	end
	return model, stats
end

return SdfDocument
