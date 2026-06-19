-- Generic surface-nets SDF mesher. Caller supplies ellipsoid + oriented
-- slab primitives (plus optional skinning bones); this module splats them
-- onto a voxel grid, extracts the zero-level dual mesh, declares bones on
-- the EditableMesh, and binds each vertex to the bones whose primitives
-- claimed the cells around it.
--
-- This is the creature-agnostic core. MeshBuilder.luau keeps all the
-- spine/blending-group/sub-bone rigging and calls this module's algorithm
-- directly (it pre-dates the split); use SdfMesher for anything that isn't
-- a spine — trees, props, foliage, terrain chunks.
--
-- Vertices + triangles are buffered into plain Luau tables first so we know
-- the total triangle count BEFORE committing to an EditableMesh (which
-- enforces its own hard cap and throws mid-build if exceeded). Over triCap
-- (measured AFTER the QEM decimation pass, not on the raw surface-nets
-- output) triggers a coarsen + retry.

local AssetService = game:GetService("AssetService")

-- Native Luau `vector` library — ~33% faster than Vector3 method equivalents
-- for dot / magnitude / cross. Cast to any because the LSP's globals table
-- doesn't always include it; it exists at runtime in Roblox Luau.
local vector = (getfenv(0) :: any).vector :: any

local SdfMesher = {}

-- Bump this whenever you want to detect whether a consumer has cached an
-- older copy of this module. Read via `SdfMesher.VERSION` from the caller.
SdfMesher.VERSION = "2026-06-19-bevel-subtractcapsules"

-- ─────────────────────────────────────────────────────────────
-- Types
-- ─────────────────────────────────────────────────────────────

-- Weight a primitive contributes to skinning when it claims a cell. A
-- rigidly-attached part (e.g. a leaf) uses `{ { key = "branch_5", w = 1 } }`.
-- A primitive that straddles two bones (e.g. a creature slab across a
-- joint) splits its vote between anchors. The per-cell tally sums across
-- all 8 corners, then the top-K by weight are normalised onto each vertex.
export type BoneWeight = { key: string, w: number }

export type Ellipsoid = {
	center: Vector3,
	semi: Vector3, -- semi-axes (radii), not diameters
	boneWeights: { BoneWeight }?,
}

-- Oriented slab. right/up/forward must be orthonormal.
-- centerOffset bakes an off-axis bulge into the slab without rebuilding
-- its frame (useful when the cross-section isn't symmetric).
--
-- `rounding` and `bevel` switch the SDF shape (mutually exclusive; `bevel`
-- wins if both are set):
--   rounding nil, bevel nil  → oriented ellipsoid (legacy; soft organic blobs)
--   rounding 0               → sharp oriented box (Church of Inigo's sdBox)
--   rounding > 0             → ROUNDED box (sdRoundBox; soft, radiused edges —
--                              despite the historical "chamfer radius" naming
--                              this rounds the edges, it does NOT flat-cut them)
--   bevel > 0                → HARD-BEVELED box: all 12 edges sliced by flat 45°
--                              facets at chamfer depth `bevel` (and the 8
--                              corners get triangular facets where three edge
--                              cuts meet). Crisp, faceted, mechanical — gems,
--                              armor plates, machined props. This is the true
--                              flat chamfer that `rounding` is often mistaken
--                              for. Works on subtractSlabs too, for faceted cuts.
--
-- Boxes are the right choice for architectural props (stone tiers, wood
-- beams); ellipsoids stay the default for foliage etc.
export type Slab = {
	center: Vector3,
	forward: Vector3,
	up: Vector3,
	right: Vector3,
	centerOffset: Vector3?,
	semi: Vector3, -- semi-axes in the slab's local (right, up, forward) frame
	rounding: number?, -- nil = ellipsoid; 0 = sharp box; > 0 = ROUNDED-edge box
	bevel: number?, -- > 0 = HARD flat chamfer on all edges (overrides rounding)
	boneWeights: { BoneWeight }?,
}

-- Capsule: a cylinder with hemispherical end-caps. Defined by two endpoints
-- (centers of the caps) and a radius. Great for tree branches, limbs, and
-- any tube-like feature — adjacent capsules sharing an endpoint merge
-- smoothly via min-union of SDFs without requiring explicit joint spheres.
export type Capsule = {
	a: Vector3,
	b: Vector3,
	radius: number,
	boneWeights: { BoneWeight }?,
}

-- TaperedCapsule (round cone): same two-endpoint shape as Capsule, but
-- with a different radius at each end (rA at endpoint a, rB at endpoint
-- b). The SDF is iq's sdRoundCone — a cone capped by hemispheres of
-- the two radii. Separate type from Capsule because (a) its SDF is
-- meaningfully more expensive than the uniform-radius capsule, so we
-- want plain capsules to keep their fast path, and (b) the typical
-- caller passes WHOLE ARRAYS of these (e.g., a ring of needle-clusters
-- around one cone tier of a pine tree), so having its own splat
-- queue is cleaner than per-element branching inside the capsule loop.
export type TaperedCapsule = {
	a: Vector3,
	b: Vector3,
	radiusA: number,
	radiusB: number,
	boneWeights: { BoneWeight }?,
}

-- Bone-instance declaration. parentKey links bones into a hierarchy —
-- useful for trees (trunk → branch → twig) where the runtime only drives
-- local rotations. Set parentKey = nil for a root, or on every bone to
-- keep the tree flat (matches how MeshBuilder does it, since its puppet
-- runtime drives each bone's absolute world CFrame directly).
-- Attributes are stashed on the final Bone instance — handy for runtime
-- metadata like "this branch was at angle X, sway with phase Y".
export type BoneDecl = {
	key: string,
	name: string,
	bindCFrame: CFrame,
	parentKey: string?,
	attributes: { [string]: any }?,
}

export type Input = {
	ellipsoids: { Ellipsoid }?,
	slabs: { Slab }?,
	capsules: { Capsule }?,
	taperedCapsules: { TaperedCapsule }?,
	-- Slabs that CARVE material out of the combined union instead of adding
	-- to it. Each is evaluated as `sdf := max(sdf, -slabSDF)` after the
	-- union pass — a classic iq subtraction. Crisp flat facets come from
	-- thin subtract slabs; set rounding=0 for sharp-edge cuts.
	subtractSlabs: { Slab }?,
	-- Ellipsoids that carve curved gouges out of the union. Great for the
	-- rounded arches between the feet of a yukimi-dōrō, skull-sockets,
	-- carved-out bowls, mouse holes, etc. Same `max(sdf, -ellipsoidSDF)`
	-- math as subtractSlabs.
	subtractEllipsoids: { Ellipsoid }?,
	-- Capsules that DRILL round-section channels out of the union: bolt holes,
	-- barrel bores, pipe lumens, fuller grooves down a blade, the slot a buckle
	-- threads through. Same `max(sdf, -capsuleSDF)` carve as the other
	-- subtracts — a tube from `a` to `b` of the given `radius` with rounded
	-- ends. Use a (near) zero-length capsule to punch a single round dimple.
	subtractCapsules: { Capsule }?,
	bones: { BoneDecl }?,
}

export type Config = {
	triCap: number?,
	boundsPadding: number?,
	initialMaxCellsPerDim: number?,
	maxCoarsenAttempts: number?,
	coarsenFactor: number?,
	maxBonesPerVertex: number?,
	-- "Spillage" added to every primitive AABB before splatting. Zero is
	-- correct for plain min-union (a primitive can't push the running min
	-- lower outside its own AABB). Bump up when layering smooth-blend ops
	-- that can leak a primitive's influence beyond its hard AABB.
	primitiveSpill: number?,
	-- Polynomial smooth-min blend radius (studs). When > 0, primitive SDFs
	-- within this distance of each other blend smoothly (metaball-style)
	-- instead of hard-unioning. Eliminates the classic surface-nets "diamond
	-- hole" saddle artifact where two primitives graze close — the saddle
	-- disappears because the surface bulges outward at the junction. Distant
	-- primitives collapse to plain min (no behavior change). Typical values
	-- 0.3–1.0 stud. Zero disables the blend.
	smoothBlend: number?,
	-- When true, colours each vertex by its dominant bone so weight regions
	-- are visible on the built MeshPart. Off by default.
	debugVertexColors: boolean?,
	-- Optional callback to assign a per-vertex tint after the mesh is built.
	-- Called once per vertex with: world position, averaged unit normal,
	-- bone-weight tally, and a creaseness score in [0, 1] (0 = vertex
	-- sits inside a flat region of the surface; → 1 as adjacent face
	-- normals diverge, peaking on sharp creases / cut edges). Returns
	-- the Color3 to apply to every face that uses this vertex. Ignored
	-- when debugVertexColors is true.
	vertexColorFn: ((vertex: Vector3, normal: Vector3, weights: { [string]: number }, creaseness: number) -> Color3)?,
	-- Mesh fidelity options — these must be passed to CreateMeshPartAsync at
	-- creation time; script context lacks the capability to set them on the
	-- resulting MeshPart afterward.
	renderFidelity: Enum.RenderFidelity?,
	collisionFidelity: Enum.CollisionFidelity?,
	fluidFidelity: Enum.FluidFidelity?,
}

export type Timings = {
	splat: number, -- primitive SDF splatting onto the grid
	extract: number, -- surface-net dual vertex extraction
	quads: number, -- quad / triangle emission
	decimate: number, -- coplanar vertex decimation pass
	normals: number, -- per-vertex normal averaging (only if vertexColorFn used)
	colors: number, -- vertex color application (debug or vertexColorFn)
	bones: number, -- AddBone + per-vertex weight assignment
	bakeContent: number, -- AssetService:CreateDataModelContentAsync (EditableMesh → static Content)
	createMeshPart: number, -- AssetService:CreateMeshPartAsync (Content → MeshPart)
	total: number,
}

export type Output = {
	meshPart: MeshPart,
	triCount: number,
	vertCount: number,
	cellSize: number,
	gridDims: Vector3, -- nx, ny, nz
	primitiveCount: number,
	boneCount: number,
	coarsenAttempts: number,
	timings: Timings,
}

local DEFAULT_TRI_CAP = 20000
local DEFAULT_BOUNDS_PADDING = 1.5
local DEFAULT_INITIAL_MAX_CELLS_PER_DIM = 60
local DEFAULT_MAX_COARSEN_ATTEMPTS = 8
local DEFAULT_COARSEN_FACTOR = 1.3
local DEFAULT_MAX_BONES_PER_VERTEX = 4
local DEFAULT_PRIMITIVE_SPILL = 0.0
local DEFAULT_SMOOTH_BLEND = 0.0

-- Cells outside every primitive's AABB stay at this sentinel — large enough
-- that the sign test treats them as "far outside" without any chance of
-- creating phantom crossings with near-surface cells.
local SDF_SENTINEL = 1e6

-- ─────────────────────────────────────────────────────────────
-- SDF primitives
-- ─────────────────────────────────────────────────────────────

-- Inigo Quilez approximate ellipsoid SDF. semi is semi-axes, not diameters.
-- Degenerates gracefully at center. Uses an exact-sphere fast-path when all
-- three semi axes match — the splat loop hits this constantly for foliage
-- clusters of spherical ellipsoids, where the ~3× cheaper math adds up.
local function ellipsoidSDF(p: Vector3, semi: Vector3): number
	local sx, sy, sz = semi.X, semi.Y, semi.Z
	if sx == sy and sy == sz then
		-- Sphere: SDF is just length(p) - radius.
		return math.sqrt(p.X * p.X + p.Y * p.Y + p.Z * p.Z) - sx
	end
	local k0x, k0y, k0z = p.X / sx, p.Y / sy, p.Z / sz
	local k0 = math.sqrt(k0x * k0x + k0y * k0y + k0z * k0z)
	if k0 < 1e-6 then
		return -math.min(sx, sy, sz)
	end
	local k1x, k1y, k1z = k0x / sx, k0y / sy, k0z / sz
	local k1 = math.sqrt(k1x * k1x + k1y * k1y + k1z * k1z)
	return k0 * (k0 - 1) / k1
end

local function slabSDF(p: Vector3, s: Slab): number
	local rel = p - s.center
	if s.centerOffset then
		rel -= s.centerOffset
	end
	-- vector.dot is measurably faster than the Vector3:Dot method in Luau.
	local local_p = Vector3.new(vector.dot(rel, s.right), vector.dot(rel, s.up), vector.dot(rel, s.forward))

	local bevel = s.bevel
	if bevel and bevel > 0 then
		-- Hard-beveled box. Intersect the box with the 12 edge planes whose
		-- normals are (±1,±1,0)/√2 etc.; each plane sits at chamfer depth
		-- `bevel` along the two faces it joins, replacing the sharp edge with
		-- a flat 45° facet. d = max(boxDist, edgePlanes). See the Slab type
		-- comment for why this differs from `rounding`.
		local ax = if local_p.X >= 0 then local_p.X else -local_p.X
		local ay = if local_p.Y >= 0 then local_p.Y else -local_p.Y
		local az = if local_p.Z >= 0 then local_p.Z else -local_p.Z
		local qx = ax - s.semi.X
		local qy = ay - s.semi.Y
		local qz = az - s.semi.Z
		local qxp = if qx > 0 then qx else 0
		local qyp = if qy > 0 then qy else 0
		local qzp = if qz > 0 then qz else 0
		local outside = math.sqrt(qxp * qxp + qyp * qyp + qzp * qzp)
		local maxYZ = if qy > qz then qy else qz
		local maxQ = if qx > maxYZ then qx else maxYZ
		local inside = if maxQ < 0 then maxQ else 0
		local boxD = outside + inside
		local exy = (qx + qy + bevel) * 0.70710678
		local eyz = (qy + qz + bevel) * 0.70710678
		local exz = (qx + qz + bevel) * 0.70710678
		local edgeD = if exy > eyz then exy else eyz
		if exz > edgeD then edgeD = exz end
		return if boxD > edgeD then boxD else edgeD
	end

	local rounding = s.rounding
	if rounding then
		-- iq sdRoundBox: vec3 q = abs(p) - b + vec3(r);
		--   length(max(q,0)) + min(max(q.x,max(q.y,q.z)),0) - r
		local ax = if local_p.X >= 0 then local_p.X else -local_p.X
		local ay = if local_p.Y >= 0 then local_p.Y else -local_p.Y
		local az = if local_p.Z >= 0 then local_p.Z else -local_p.Z
		local qx = ax - s.semi.X + rounding
		local qy = ay - s.semi.Y + rounding
		local qz = az - s.semi.Z + rounding
		local qxp = if qx > 0 then qx else 0
		local qyp = if qy > 0 then qy else 0
		local qzp = if qz > 0 then qz else 0
		local outside = math.sqrt(qxp * qxp + qyp * qyp + qzp * qzp)
		local maxYZ = if qy > qz then qy else qz
		local maxQ = if qx > maxYZ then qx else maxYZ
		local inside = if maxQ < 0 then maxQ else 0
		return outside + inside - rounding
	end

	return ellipsoidSDF(local_p, s.semi)
end

-- Capsule SDF: distance to closest point on segment AB, minus radius.
local function capsuleSDF(p: Vector3, c: Capsule): number
	local pa = p - c.a
	local ba = c.b - c.a
	local baLenSq = vector.dot(ba, ba)
	if baLenSq < 1e-10 then
		-- Degenerate capsule = sphere
		return vector.magnitude(pa) - c.radius
	end
	local h = math.clamp(vector.dot(pa, ba) / baLenSq, 0, 1)
	return vector.magnitude(pa - ba * h) - c.radius
end

local function ellipsoidAABB(e: Ellipsoid): (Vector3, Vector3)
	return e.center - e.semi, e.center + e.semi
end

-- Tight AABB of an oriented ellipsoid: |forward|·semi.Z + |right|·semi.X
-- + |up|·semi.Y per world axis.
local function slabAABB(s: Slab): (Vector3, Vector3)
	local extent = Vector3.new(
		math.abs(s.forward.X) * s.semi.Z + math.abs(s.right.X) * s.semi.X + math.abs(s.up.X) * s.semi.Y,
		math.abs(s.forward.Y) * s.semi.Z + math.abs(s.right.Y) * s.semi.X + math.abs(s.up.Y) * s.semi.Y,
		math.abs(s.forward.Z) * s.semi.Z + math.abs(s.right.Z) * s.semi.X + math.abs(s.up.Z) * s.semi.Y
	)
	local shifted = s.center + (s.centerOffset or Vector3.zero)
	return shifted - extent, shifted + extent
end

local function capsuleAABB(c: Capsule): (Vector3, Vector3)
	local r = Vector3.one * c.radius
	local lo = Vector3.new(math.min(c.a.X, c.b.X), math.min(c.a.Y, c.b.Y), math.min(c.a.Z, c.b.Z))
	local hi = Vector3.new(math.max(c.a.X, c.b.X), math.max(c.a.Y, c.b.Y), math.max(c.a.Z, c.b.Z))
	return lo - r, hi + r
end

-- TaperedCapsule SDF: iq's sdRoundCone. Defines the shape of a cone
-- segment between two spheres of different radii, with the lateral
-- surface tangent to both spheres so the silhouette is a clean
-- continuous tube (no pinch where the cone meets the end-caps).
local function taperedCapsuleSDF(p: Vector3, c: TaperedCapsule): number
	local a, b = c.a, c.b
	local r1, r2 = c.radiusA, c.radiusB
	local ba = b - a
	local l2 = vector.dot(ba, ba)
	if l2 < 1e-10 then
		-- Degenerate: both endpoints coincident — sphere with the larger radius.
		return vector.magnitude(p - a) - math.max(r1, r2)
	end
	local rr = r1 - r2
	local a2 = l2 - rr * rr
	if a2 <= 1e-10 then
		-- Ill-formed: |radius difference| ≥ segment length, meaning one
		-- end-sphere contains the other. Fall back to a uniform-radius
		-- capsule of max(r1, r2) so the primitive still produces a sane
		-- surface instead of NaN-ing on the sqrt below.
		local pa_ = p - a
		local h = math.clamp(vector.dot(pa_, ba) / l2, 0, 1)
		return vector.magnitude(pa_ - ba * h) - math.max(r1, r2)
	end
	local il2 = 1 / l2
	local pa = p - a
	local y = vector.dot(pa, ba)
	local z = y - l2
	local q = pa * l2 - ba * y
	local x2 = vector.dot(q, q)
	local y2 = y * y * l2
	local z2 = z * z * l2
	local k = math.sign(rr) * rr * rr * x2
	if math.sign(z) * a2 * z2 > k then
		return math.sqrt(x2 + z2) * il2 - r2
	end
	if math.sign(y) * a2 * y2 < k then
		return math.sqrt(x2 + y2) * il2 - r1
	end
	return (math.sqrt(x2 * a2 * il2) + y * rr) * il2 - r1
end

local function taperedCapsuleAABB(c: TaperedCapsule): (Vector3, Vector3)
	local rA = c.radiusA
	local rB = c.radiusB
	return Vector3.new(
		math.min(c.a.X - rA, c.b.X - rB),
		math.min(c.a.Y - rA, c.b.Y - rB),
		math.min(c.a.Z - rA, c.b.Z - rB)
	), Vector3.new(
		math.max(c.a.X + rA, c.b.X + rB),
		math.max(c.a.Y + rA, c.b.Y + rB),
		math.max(c.a.Z + rA, c.b.Z + rB)
	)
end

-- Public SDF sampler: returns a closure that evaluates the combined
-- signed distance field of the given input at any world point. Same
-- union/subtract math the splat loop runs internally — < 0 inside,
-- > 0 outside, exactly equals the surface at zero. Useful for
-- post-bake operations like raycasting onto the final shape (snow
-- placement, decal projection, terrain sticking).
function SdfMesher.makeSdfFn(input: Input): (Vector3) -> number
	local ellipsoids = input.ellipsoids or {}
	local slabs = input.slabs or {}
	local capsules = input.capsules or {}
	local taperedCapsules = input.taperedCapsules or {}
	local subtractSlabs = input.subtractSlabs or {}
	local subtractEllipsoids = input.subtractEllipsoids or {}
	local subtractCapsules = input.subtractCapsules or {}
	return function(p: Vector3): number
		local d = math.huge
		for _, e in ipairs(ellipsoids) do
			local di = ellipsoidSDF(p - e.center, e.semi)
			if di < d then d = di end
		end
		for _, s in ipairs(slabs) do
			local di = slabSDF(p, s)
			if di < d then d = di end
		end
		for _, c in ipairs(capsules) do
			local di = capsuleSDF(p, c)
			if di < d then d = di end
		end
		for _, c in ipairs(taperedCapsules) do
			local di = taperedCapsuleSDF(p, c)
			if di < d then d = di end
		end
		for _, s in ipairs(subtractSlabs) do
			local neg = -slabSDF(p, s)
			if neg > d then d = neg end
		end
		for _, e in ipairs(subtractEllipsoids) do
			local neg = -ellipsoidSDF(p - e.center, e.semi)
			if neg > d then d = neg end
		end
		for _, c in ipairs(subtractCapsules) do
			local neg = -capsuleSDF(p, c)
			if neg > d then d = neg end
		end
		return d
	end
end

-- Public bounds helper: returns the world AABB of all union primitives
-- in the input (subtracts don't extend the volume). nil, nil if the
-- input has no geometry.
function SdfMesher.computeInputBounds(input: Input, padding: number?): (Vector3?, Vector3?)
	local pad = padding or 0
	local minV = Vector3.new(math.huge, math.huge, math.huge)
	local maxV = Vector3.new(-math.huge, -math.huge, -math.huge)
	local hasAny = false
	for _, e in ipairs(input.ellipsoids or {}) do
		local lo, hi = ellipsoidAABB(e)
		minV = Vector3.new(math.min(minV.X, lo.X), math.min(minV.Y, lo.Y), math.min(minV.Z, lo.Z))
		maxV = Vector3.new(math.max(maxV.X, hi.X), math.max(maxV.Y, hi.Y), math.max(maxV.Z, hi.Z))
		hasAny = true
	end
	for _, s in ipairs(input.slabs or {}) do
		local lo, hi = slabAABB(s)
		minV = Vector3.new(math.min(minV.X, lo.X), math.min(minV.Y, lo.Y), math.min(minV.Z, lo.Z))
		maxV = Vector3.new(math.max(maxV.X, hi.X), math.max(maxV.Y, hi.Y), math.max(maxV.Z, hi.Z))
		hasAny = true
	end
	for _, c in ipairs(input.capsules or {}) do
		local lo, hi = capsuleAABB(c)
		minV = Vector3.new(math.min(minV.X, lo.X), math.min(minV.Y, lo.Y), math.min(minV.Z, lo.Z))
		maxV = Vector3.new(math.max(maxV.X, hi.X), math.max(maxV.Y, hi.Y), math.max(maxV.Z, hi.Z))
		hasAny = true
	end
	for _, c in ipairs(input.taperedCapsules or {}) do
		local lo, hi = taperedCapsuleAABB(c)
		minV = Vector3.new(math.min(minV.X, lo.X), math.min(minV.Y, lo.Y), math.min(minV.Z, lo.Z))
		maxV = Vector3.new(math.max(maxV.X, hi.X), math.max(maxV.Y, hi.Y), math.max(maxV.Z, hi.Z))
		hasAny = true
	end
	if not hasAny then return nil, nil end
	local p = Vector3.one * pad
	return minV - p, maxV + p
end

-- ─────────────────────────────────────────────────────────────
-- Surface nets
-- ─────────────────────────────────────────────────────────────

local EDGES: { { number } } = {
	{ 0, 1 }, { 2, 3 }, { 4, 5 }, { 6, 7 },
	{ 0, 2 }, { 1, 3 }, { 4, 6 }, { 5, 7 },
	{ 0, 4 }, { 1, 5 }, { 2, 6 }, { 3, 7 },
}
local CORNERS: { Vector3 } = {
	Vector3.new(0, 0, 0), Vector3.new(1, 0, 0),
	Vector3.new(0, 1, 0), Vector3.new(1, 1, 0),
	Vector3.new(0, 0, 1), Vector3.new(1, 0, 1),
	Vector3.new(0, 1, 1), Vector3.new(1, 1, 1),
}

-- ─── Multi-patch cell detection (manifold surface nets, lite) ────
-- A cell whose 8 corner signs split into ≥2 same-sign connected components
-- (via cube-edge adjacency) hosts >1 distinct surface patch. Vanilla
-- Surface Nets averages all sign-changing edge crossings into a single
-- vertex that floats between the patches — and quad triangulation then
-- stitches that vertex to neighbour cells lying on either patch, drawing
-- a spike across the gap.
--
-- Fix: emit one vertex per patch (manifold dual contouring's core idea).
-- Per-quad triangulation dispatches each of the 4 surrounding cells'
-- voxel-edges to the slot whose patch it belongs to.
--
-- We pre-classify all 256 corner-sign masks. Each multi-patch mask gets
-- two slots: edges of the largest patch in slot 1, every other patch
-- merged into slot 2 (3+ patches happen only in checkerboard-like
-- configurations and merging the tail keeps this two-vertex scheme intact
-- with at most a sub-cell dimple on the merged side).
--
-- Edge ownership: each sign-changing edge belongs to the patch of its
-- side-component endpoint. The "side" is whichever sign has more
-- components — partitioning by that side gives one patch per component.

local CORNER_NEIGHBORS: { { number } } = {
	[0] = { 1, 2, 4 }, [1] = { 0, 3, 5 },
	[2] = { 0, 3, 6 }, [3] = { 1, 2, 7 },
	[4] = { 0, 5, 6 }, [5] = { 1, 4, 7 },
	[6] = { 2, 4, 7 }, [7] = { 3, 5, 6 },
}

-- For multi-patch masks: slot1Edges, slot2Edges, and slot2Bits — a 12-bit
-- bitmask where bit (i-1) is set iff EDGES[i] belongs to slot 2. Single-
-- patch (and all-same-sign) masks leave the entry nil → fast path.
-- slot2Bits is what gets copied into the per-cell cellSlot2Mask array;
-- triangulation then dispatches each voxel-edge with one bit-and.
type MultiPatch = {
	slot1: { { number } },
	slot2: { { number } },
	slot2Bits: number,
}
local MULTI_PATCH: { MultiPatch? } = table.create(256)
do
	local function components(mask: number, signBit: number): { { number } }
		local function inSide(c: number): boolean
			local has = bit32.band(mask, bit32.lshift(1, c)) ~= 0
			return has == (signBit == 1)
		end
		local visited = { false, false, false, false, false, false, false, false }
		local comps: { { number } } = {}
		for c = 0, 7 do
			if inSide(c) and not visited[c + 1] then
				local comp: { number } = {}
				local stack = { c }
				visited[c + 1] = true
				while #stack > 0 do
					local n = stack[#stack]
					stack[#stack] = nil
					table.insert(comp, n)
					for _, m in CORNER_NEIGHBORS[n] do
						if inSide(m) and not visited[m + 1] then
							visited[m + 1] = true
							table.insert(stack, m)
						end
					end
				end
				table.insert(comps, comp)
			end
		end
		return comps
	end

	-- Hamming distance between two corners (popcount of XOR). 1 = cube-edge,
	-- 2 = face-diagonal, 3 = cube-diagonal.
	local function hamming(a: number, b: number): number
		local d = bit32.bxor(a, b)
		local n = 0
		while d > 0 do
			n += bit32.band(d, 1)
			d = bit32.rshift(d, 1)
		end
		return n
	end

	for mask = 1, 254 do
		local negComps = components(mask, 1)
		local posComps = components(mask, 0)
		if #negComps <= 1 and #posComps <= 1 then
			continue
		end
		local sideComps, sideBit
		if #negComps >= #posComps then
			sideComps, sideBit = negComps, 1
		else
			sideComps, sideBit = posComps, 0
		end
		-- Conservative filter: only treat as multi-patch when every pair of
		-- components is cube-diagonal-separated (min hamming distance 3).
		-- Face-diagonal pairs (distance 2) are saddle cases — geometrically
		-- ambiguous, but in practice almost always a single continuous
		-- surface bridging through the cell. Splitting those into two
		-- vertices removes the saddle bridge and leaves visible gaps where
		-- the two tongues fail to meet. Fall back to vanilla averaging.
		local clearMultiPatch = true
		for i = 1, #sideComps - 1 do
			for j = i + 1, #sideComps do
				for _, ca in sideComps[i] do
					for _, cb in sideComps[j] do
						if hamming(ca, cb) < 3 then
							clearMultiPatch = false
							break
						end
					end
					if not clearMultiPatch then
						break
					end
				end
				if not clearMultiPatch then
					break
				end
			end
			if not clearMultiPatch then
				break
			end
		end
		if not clearMultiPatch then
			continue
		end
		-- Build per-patch edge lists, indexed by component order.
		local patchEdges: { { { number } } } = {}
		local edgeIdxByPatch: { { number } } = {}
		for pi, comp in sideComps do
			local cornerSet: { [number]: boolean } = {}
			for _, c in comp do
				cornerSet[c] = true
			end
			local edges: { { number } } = {}
			local edgeIdxs: { number } = {}
			for ei, e in EDGES do
				local a, b = e[1], e[2]
				local aHas = bit32.band(mask, bit32.lshift(1, a)) ~= 0
				local bHas = bit32.band(mask, bit32.lshift(1, b)) ~= 0
				if aHas ~= bHas then
					local sideCorner: number
					if sideBit == 1 then
						sideCorner = if aHas then a else b
					else
						sideCorner = if aHas then b else a
					end
					if cornerSet[sideCorner] then
						table.insert(edges, e)
						table.insert(edgeIdxs, ei)
					end
				end
			end
			patchEdges[pi] = edges
			edgeIdxByPatch[pi] = edgeIdxs
		end
		-- Pick largest patch as slot 1; merge every other patch into slot 2.
		local biggest, biggestCount = 1, #patchEdges[1]
		for pi = 2, #patchEdges do
			if #patchEdges[pi] > biggestCount then
				biggest, biggestCount = pi, #patchEdges[pi]
			end
		end
		local slot1: { { number } } = patchEdges[biggest]
		local slot2: { { number } } = {}
		local slot2Bits = 0
		for pi, edges in patchEdges do
			if pi == biggest then
				continue
			end
			for _, e in edges do
				table.insert(slot2, e)
			end
			for _, ei in edgeIdxByPatch[pi] do
				slot2Bits = bit32.bor(slot2Bits, bit32.lshift(1, ei - 1))
			end
		end
		MULTI_PATCH[mask] = { slot1 = slot1, slot2 = slot2, slot2Bits = slot2Bits }
	end
end

-- Splat every primitive onto the grid (sdf := min per cell) while tracking
-- per-cell ownership by SURFACE-closest primitive (smallest |d|, not
-- smallest d — an enveloping body prim would otherwise hijack weight from
-- the smaller prim whose silhouette the cell actually sits on).
--
-- Owner encoding: 0 = none, 1..NE = ellipsoid index, NE+1..NE+NS = slab
-- index (subtract NE).
--
-- Fills `vertices`, `triangles`, `perVertexWeights` and returns
-- (vertCount, triCount).
-- Returns (vertCount, triCount, splatTime, extractTime, quadsTime, gridX, gridY, gridZ).
local function meshPrimitives(
	minV: Vector3,
	maxV: Vector3,
	cellSize: number,
	spill: number,
	smoothBlend: number,
	ellipsoids: { Ellipsoid },
	slabs: { Slab },
	capsules: { Capsule },
	taperedCapsules: { TaperedCapsule },
	subtractSlabs: { Slab },
	subtractEllipsoids: { Ellipsoid },
	subtractCapsules: { Capsule },
	vertices: { Vector3 },
	triangles: { number },
	perVertexWeights: { { [string]: number } }
): (number, number, number, number, number, number, number, number)
	local tSplat0 = os.clock()

	-- Local helper: polynomial smooth-min. When blend is 0 this collapses to
	-- a plain min. Distant SDFs (|a-b| >= blend) also short-circuit to min.
	-- Used during splat so primitives whose surfaces graze each other blend
	-- into a bulge instead of producing a saddle (and the surface-nets holes
	-- that saddles cause).
	local smoothMin
	if smoothBlend > 0 then
		local inv = 1 / smoothBlend
		local quarterK = smoothBlend * 0.25
		smoothMin = function(a: number, b: number): number
			local diff = a - b
			local absdiff = if diff >= 0 then diff else -diff
			if absdiff >= smoothBlend then
				return if diff >= 0 then b else a
			end
			local h = 1 - absdiff * inv
			local m = if diff >= 0 then b else a
			return m - h * h * quarterK
		end
	else
		smoothMin = function(a: number, b: number): number
			return if a < b then a else b
		end
	end

	local size = maxV - minV
	local nx = math.ceil(size.X / cellSize) + 1
	local ny = math.ceil(size.Y / cellSize) + 1
	local nz = math.ceil(size.Z / cellSize) + 1
	local sampleX = nx + 1
	local sampleY = ny + 1
	local sampleTotal = sampleX * sampleY * (nz + 1)

	local sdf = table.create(sampleTotal, SDF_SENTINEL)
	local owner = table.create(sampleTotal, 0)
	local ownerAbs = table.create(sampleTotal, SDF_SENTINEL)
	-- Owner code encoding:
	--   0                       → no primitive claims this cell
	--   1..NE                   → ellipsoid index
	--   NE+1..NE+NS             → slab index (subtract NE)
	--   NE+NS+1..NE+NS+NC       → capsule index (subtract NE+NS)
	--   NE+NS+NC+1..end         → tapered capsule index (subtract NE+NS+NC)
	local NE = #ellipsoids
	local NS = #slabs
	local NC = #capsules

	local function aabbToIndexRange(lo: Vector3, hi: Vector3): (number, number, number, number, number, number)
		local ix_min = math.max(0, math.floor((lo.X - spill - minV.X) / cellSize))
		local ix_max = math.min(nx, math.ceil((hi.X + spill - minV.X) / cellSize))
		local iy_min = math.max(0, math.floor((lo.Y - spill - minV.Y) / cellSize))
		local iy_max = math.min(ny, math.ceil((hi.Y + spill - minV.Y) / cellSize))
		local iz_min = math.max(0, math.floor((lo.Z - spill - minV.Z) / cellSize))
		local iz_max = math.min(nz, math.ceil((hi.Z + spill - minV.Z) / cellSize))
		return ix_min, ix_max, iy_min, iy_max, iz_min, iz_max
	end

	-- Strides for inlined sdfIdx: sdfIdx(x, y, z) = 1 + x + sampleY_ * y + sampleZ_ * z
	local sampleY_ = sampleX
	local sampleZ_ = sampleX * sampleY
	local minVX, minVY, minVZ = minV.X, minV.Y, minV.Z

	-- Ellipsoid splat. Spheres (semi.X == semi.Y == semi.Z) get a fully inlined
	-- fast-path that skips the ellipsoidSDF function call and uses sqrt+sub
	-- directly — foliage is all spheres so this alone saves hundreds of
	-- thousands of function calls per tree bake.
	for eIdx, e in ellipsoids do
		local elo, ehi = ellipsoidAABB(e)
		local ix0, ix1, iy0, iy1, iz0, iz1 = aabbToIndexRange(elo, ehi)
		local ecX, ecY, ecZ = e.center.X, e.center.Y, e.center.Z
		local eSemi = e.semi
		local isSphere = eSemi.X == eSemi.Y and eSemi.Y == eSemi.Z
		if isSphere then
			local r = eSemi.X
			for z = iz0, iz1 do
				local baseZ = 1 + sampleZ_ * z
				local pzBase = minVZ + z * cellSize - ecZ
				for y = iy0, iy1 do
					local baseYZ = baseZ + sampleY_ * y
					local pyBase = minVY + y * cellSize - ecY
					local pySqPzSq = pyBase * pyBase + pzBase * pzBase
					for x = ix0, ix1 do
						local px = minVX + x * cellSize - ecX
						local d = math.sqrt(px * px + pySqPzSq) - r
						local i = baseYZ + x
						sdf[i] = smoothMin(sdf[i], d)
						local absD = if d < 0 then -d else d
						if absD < ownerAbs[i] then
							ownerAbs[i] = absD
							owner[i] = eIdx
						end
					end
				end
			end
		else
			for z = iz0, iz1 do
				local baseZ = 1 + sampleZ_ * z
				local pzBase = minVZ + z * cellSize - ecZ
				for y = iy0, iy1 do
					local baseYZ = baseZ + sampleY_ * y
					local pyBase = minVY + y * cellSize - ecY
					for x = ix0, ix1 do
						local px = minVX + x * cellSize - ecX
						local d = ellipsoidSDF(Vector3.new(px, pyBase, pzBase), eSemi)
						local i = baseYZ + x
						sdf[i] = smoothMin(sdf[i], d)
						local absD = if d < 0 then -d else d
						if absD < ownerAbs[i] then
							ownerAbs[i] = absD
							owner[i] = eIdx
						end
					end
				end
			end
		end
	end

	-- Slab splat. Same inlined SDF as subtract slabs (see below) but with
	-- smoothMin union + owner tracking. Two paths: iq sdRoundBox (slabs
	-- with `rounding` set) and the unrounded fallback (ellipsoid SDF on
	-- the rotated point).
	for sIdx, s in slabs do
		local slo, shi = slabAABB(s)
		local ix0, ix1, iy0, iy1, iz0, iz1 = aabbToIndexRange(slo, shi)
		local slabCode = NE + sIdx
		local rightX, rightY, rightZ = s.right.X, s.right.Y, s.right.Z
		local upX, upY, upZ = s.up.X, s.up.Y, s.up.Z
		local fwdX, fwdY, fwdZ = s.forward.X, s.forward.Y, s.forward.Z
		local semiX, semiY, semiZ = s.semi.X, s.semi.Y, s.semi.Z
		local rounding = s.rounding
		local bevel = s.bevel
		local cX, cY, cZ = s.center.X, s.center.Y, s.center.Z
		if s.centerOffset then
			cX += s.centerOffset.X
			cY += s.centerOffset.Y
			cZ += s.centerOffset.Z
		end

		if bevel and bevel > 0 then
			-- Hard-beveled box union: box intersected with 45° edge planes
			-- (see slabSDF for the derivation). Owner tracking as usual.
			for z = iz0, iz1 do
				local baseZ = 1 + sampleZ_ * z
				local relZ = minVZ + z * cellSize - cZ
				for y = iy0, iy1 do
					local baseYZ = baseZ + sampleY_ * y
					local relY = minVY + y * cellSize - cY
					for x = ix0, ix1 do
						local relX = minVX + x * cellSize - cX
						local lx = relX * rightX + relY * rightY + relZ * rightZ
						local ly = relX * upX + relY * upY + relZ * upZ
						local lz = relX * fwdX + relY * fwdY + relZ * fwdZ
						local ax = if lx >= 0 then lx else -lx
						local ay = if ly >= 0 then ly else -ly
						local az = if lz >= 0 then lz else -lz
						local qx = ax - semiX
						local qy = ay - semiY
						local qz = az - semiZ
						local qxp = if qx > 0 then qx else 0
						local qyp = if qy > 0 then qy else 0
						local qzp = if qz > 0 then qz else 0
						local outside = math.sqrt(qxp * qxp + qyp * qyp + qzp * qzp)
						local maxYZ = if qy > qz then qy else qz
						local maxQ = if qx > maxYZ then qx else maxYZ
						local inside = if maxQ < 0 then maxQ else 0
						local boxD = outside + inside
						local exy = (qx + qy + bevel) * 0.70710678
						local eyz = (qy + qz + bevel) * 0.70710678
						local exz = (qx + qz + bevel) * 0.70710678
						local edgeD = if exy > eyz then exy else eyz
						if exz > edgeD then edgeD = exz end
						local d = if boxD > edgeD then boxD else edgeD
						local i = baseYZ + x
						sdf[i] = smoothMin(sdf[i], d)
						local absD = if d < 0 then -d else d
						if absD < ownerAbs[i] then
							ownerAbs[i] = absD
							owner[i] = slabCode
						end
					end
				end
			end
		elseif rounding then
			for z = iz0, iz1 do
				local baseZ = 1 + sampleZ_ * z
				local relZ = minVZ + z * cellSize - cZ
				for y = iy0, iy1 do
					local baseYZ = baseZ + sampleY_ * y
					local relY = minVY + y * cellSize - cY
					for x = ix0, ix1 do
						local relX = minVX + x * cellSize - cX
						local lx = relX * rightX + relY * rightY + relZ * rightZ
						local ly = relX * upX + relY * upY + relZ * upZ
						local lz = relX * fwdX + relY * fwdY + relZ * fwdZ
						local ax = if lx >= 0 then lx else -lx
						local ay = if ly >= 0 then ly else -ly
						local az = if lz >= 0 then lz else -lz
						local qx = ax - semiX + rounding
						local qy = ay - semiY + rounding
						local qz = az - semiZ + rounding
						local qxp = if qx > 0 then qx else 0
						local qyp = if qy > 0 then qy else 0
						local qzp = if qz > 0 then qz else 0
						local outside = math.sqrt(qxp * qxp + qyp * qyp + qzp * qzp)
						local maxYZ = if qy > qz then qy else qz
						local maxQ = if qx > maxYZ then qx else maxYZ
						local inside = if maxQ < 0 then maxQ else 0
						local d = outside + inside - rounding
						local i = baseYZ + x
						sdf[i] = smoothMin(sdf[i], d)
						local absD = if d < 0 then -d else d
						if absD < ownerAbs[i] then
							ownerAbs[i] = absD
							owner[i] = slabCode
						end
					end
				end
			end
		else
			for z = iz0, iz1 do
				local baseZ = 1 + sampleZ_ * z
				local relZ = minVZ + z * cellSize - cZ
				for y = iy0, iy1 do
					local baseYZ = baseZ + sampleY_ * y
					local relY = minVY + y * cellSize - cY
					for x = ix0, ix1 do
						local relX = minVX + x * cellSize - cX
						local lx = relX * rightX + relY * rightY + relZ * rightZ
						local ly = relX * upX + relY * upY + relZ * upZ
						local lz = relX * fwdX + relY * fwdY + relZ * fwdZ
						local k0x, k0y, k0z = lx / semiX, ly / semiY, lz / semiZ
						local k0 = math.sqrt(k0x * k0x + k0y * k0y + k0z * k0z)
						local d
						if k0 < 1e-6 then
							d = -math.min(semiX, semiY, semiZ)
						else
							local k1x, k1y, k1z = k0x / semiX, k0y / semiY, k0z / semiZ
							local k1 = math.sqrt(k1x * k1x + k1y * k1y + k1z * k1z)
							d = k0 * (k0 - 1) / k1
						end
						local i = baseYZ + x
						sdf[i] = smoothMin(sdf[i], d)
						local absD = if d < 0 then -d else d
						if absD < ownerAbs[i] then
							ownerAbs[i] = absD
							owner[i] = slabCode
						end
					end
				end
			end
		end
	end

	-- Capsule splat. Inlined SDF (was capsuleSDF function call + Vector3.new
	-- per cell) — Trees bake many bark capsules and the fast-path here cuts
	-- the per-cell cost down to scalar arithmetic. Degenerate (zero-length
	-- segment) capsules fall through to the same sphere fast-path the
	-- ellipsoid loop uses.
	for cIdx, c in capsules do
		local clo, chi = capsuleAABB(c)
		local ix0, ix1, iy0, iy1, iz0, iz1 = aabbToIndexRange(clo, chi)
		local capsuleCode = NE + NS + cIdx
		local caX, caY, caZ = c.a.X, c.a.Y, c.a.Z
		local baX, baY, baZ = c.b.X - caX, c.b.Y - caY, c.b.Z - caZ
		local baLenSq = baX * baX + baY * baY + baZ * baZ
		local radius = c.radius
		if baLenSq < 1e-10 then
			-- Sphere fast-path (segment too short to project onto)
			for z = iz0, iz1 do
				local baseZ = 1 + sampleZ_ * z
				local pzBase = minVZ + z * cellSize - caZ
				for y = iy0, iy1 do
					local baseYZ = baseZ + sampleY_ * y
					local pyBase = minVY + y * cellSize - caY
					local pyzSq = pyBase * pyBase + pzBase * pzBase
					for x = ix0, ix1 do
						local px = minVX + x * cellSize - caX
						local d = math.sqrt(px * px + pyzSq) - radius
						local i = baseYZ + x
						sdf[i] = smoothMin(sdf[i], d)
						local absD = if d < 0 then -d else d
						if absD < ownerAbs[i] then
							ownerAbs[i] = absD
							owner[i] = capsuleCode
						end
					end
				end
			end
		else
			local invBaLenSq = 1 / baLenSq
			for z = iz0, iz1 do
				local baseZ = 1 + sampleZ_ * z
				local paZBase = minVZ + z * cellSize - caZ
				for y = iy0, iy1 do
					local baseYZ = baseZ + sampleY_ * y
					local paYBase = minVY + y * cellSize - caY
					for x = ix0, ix1 do
						local paX = minVX + x * cellSize - caX
						-- h = clamp(pa · ba / |ba|², 0, 1) — projection of
						-- point onto segment, clamped to endpoints.
						local hh = (paX * baX + paYBase * baY + paZBase * baZ) * invBaLenSq
						if hh < 0 then hh = 0 elseif hh > 1 then hh = 1 end
						local dx = paX - baX * hh
						local dy = paYBase - baY * hh
						local dz = paZBase - baZ * hh
						local d = math.sqrt(dx * dx + dy * dy + dz * dz) - radius
						local i = baseYZ + x
						sdf[i] = smoothMin(sdf[i], d)
						local absD = if d < 0 then -d else d
						if absD < ownerAbs[i] then
							ownerAbs[i] = absD
							owner[i] = capsuleCode
						end
					end
				end
			end
		end
	end

	for tcIdx, tc in ipairs(taperedCapsules) do
		local tlo, thi = taperedCapsuleAABB(tc)
		local ix0, ix1, iy0, iy1, iz0, iz1 = aabbToIndexRange(tlo, thi)
		local tcCode = NE + NS + NC + tcIdx
		for z = iz0, iz1 do
			local baseZ = 1 + sampleZ_ * z
			for y = iy0, iy1 do
				local baseYZ = baseZ + sampleY_ * y
				for x = ix0, ix1 do
					local p = minV + Vector3.new(x, y, z) * cellSize
					local d = taperedCapsuleSDF(p, tc)
					local i = baseYZ + x
					sdf[i] = smoothMin(sdf[i], d)
					local absD = if d < 0 then -d else d
					if absD < ownerAbs[i] then
						ownerAbs[i] = absD
						owner[i] = tcCode
					end
				end
			end
		end
	end

	-- Subtract pass (runs AFTER every union primitive so it carves the
	-- final combined surface, not just part of it). Each subtract primitive
	-- evaluates `sdf := max(sdf, -primSDF)` — the classic iq subtraction.
	-- Subtract slabs produce flat facets (crystal / obsidian look);
	-- subtract ellipsoids produce rounded gouges (arched door openings,
	-- concave seats, skull sockets). Subtracts don't claim cell ownership.
 
	-- Subtract slabs: inlined slabSDF — RockCrystal carves ~14 facets per
	-- rock × dozens of rocks, this is the hottest carve loop in the bake.
	-- Two paths: rounded box (iq sdRoundBox, the typical facet-cut shape)
	-- and the unrounded fallback (slabSDF defers to ellipsoidSDF on the
	-- rotated point). No owner tracking — subtracts don't claim cells.
	for _, s in subtractSlabs do
		local slo, shi = slabAABB(s)
		local ix0, ix1, iy0, iy1, iz0, iz1 = aabbToIndexRange(slo, shi)
		local rightX, rightY, rightZ = s.right.X, s.right.Y, s.right.Z
		local upX, upY, upZ = s.up.X, s.up.Y, s.up.Z
		local fwdX, fwdY, fwdZ = s.forward.X, s.forward.Y, s.forward.Z
		local semiX, semiY, semiZ = s.semi.X, s.semi.Y, s.semi.Z
		local rounding = s.rounding
		local bevel = s.bevel
		local cX, cY, cZ = s.center.X, s.center.Y, s.center.Z
		if s.centerOffset then
			cX += s.centerOffset.X
			cY += s.centerOffset.Y
			cZ += s.centerOffset.Z
		end

		if bevel and bevel > 0 then
			-- Hard-beveled box carve: flat-faceted subtraction (see slabSDF).
			for z = iz0, iz1 do
				local baseZ = 1 + sampleZ_ * z
				local relZ = minVZ + z * cellSize - cZ
				for y = iy0, iy1 do
					local baseYZ = baseZ + sampleY_ * y
					local relY = minVY + y * cellSize - cY
					for x = ix0, ix1 do
						local relX = minVX + x * cellSize - cX
						local lx = relX * rightX + relY * rightY + relZ * rightZ
						local ly = relX * upX + relY * upY + relZ * upZ
						local lz = relX * fwdX + relY * fwdY + relZ * fwdZ
						local ax = if lx >= 0 then lx else -lx
						local ay = if ly >= 0 then ly else -ly
						local az = if lz >= 0 then lz else -lz
						local qx = ax - semiX
						local qy = ay - semiY
						local qz = az - semiZ
						local qxp = if qx > 0 then qx else 0
						local qyp = if qy > 0 then qy else 0
						local qzp = if qz > 0 then qz else 0
						local outside = math.sqrt(qxp * qxp + qyp * qyp + qzp * qzp)
						local maxYZ = if qy > qz then qy else qz
						local maxQ = if qx > maxYZ then qx else maxYZ
						local inside = if maxQ < 0 then maxQ else 0
						local boxD = outside + inside
						local exy = (qx + qy + bevel) * 0.70710678
						local eyz = (qy + qz + bevel) * 0.70710678
						local exz = (qx + qz + bevel) * 0.70710678
						local edgeD = if exy > eyz then exy else eyz
						if exz > edgeD then edgeD = exz end
						local d = if boxD > edgeD then boxD else edgeD
						local neg = -d
						local i = baseYZ + x
						if neg > sdf[i] then
							sdf[i] = neg
						end
					end
				end
			end
		elseif rounding then
			-- iq sdRoundBox path (the common facet-carve case).
			for z = iz0, iz1 do
				local baseZ = 1 + sampleZ_ * z
				local relZ = minVZ + z * cellSize - cZ
				for y = iy0, iy1 do
					local baseYZ = baseZ + sampleY_ * y
					local relY = minVY + y * cellSize - cY
					for x = ix0, ix1 do
						local relX = minVX + x * cellSize - cX
						-- Rotate world-space rel into slab-local frame.
						local lx = relX * rightX + relY * rightY + relZ * rightZ
						local ly = relX * upX + relY * upY + relZ * upZ
						local lz = relX * fwdX + relY * fwdY + relZ * fwdZ
						local ax = if lx >= 0 then lx else -lx
						local ay = if ly >= 0 then ly else -ly
						local az = if lz >= 0 then lz else -lz
						local qx = ax - semiX + rounding
						local qy = ay - semiY + rounding
						local qz = az - semiZ + rounding
						local qxp = if qx > 0 then qx else 0
						local qyp = if qy > 0 then qy else 0
						local qzp = if qz > 0 then qz else 0
						local outside = math.sqrt(qxp * qxp + qyp * qyp + qzp * qzp)
						local maxYZ = if qy > qz then qy else qz
						local maxQ = if qx > maxYZ then qx else maxYZ
						local inside = if maxQ < 0 then maxQ else 0
						local d = outside + inside - rounding
						local neg = -d
						local i = baseYZ + x
						if neg > sdf[i] then
							sdf[i] = neg
						end
					end
				end
			end
		else
			-- Unrounded slab → ellipsoidSDF on the rotated point.
			for z = iz0, iz1 do
				local baseZ = 1 + sampleZ_ * z
				local relZ = minVZ + z * cellSize - cZ
				for y = iy0, iy1 do
					local baseYZ = baseZ + sampleY_ * y
					local relY = minVY + y * cellSize - cY
					for x = ix0, ix1 do
						local relX = minVX + x * cellSize - cX
						local lx = relX * rightX + relY * rightY + relZ * rightZ
						local ly = relX * upX + relY * upY + relZ * upZ
						local lz = relX * fwdX + relY * fwdY + relZ * fwdZ
						-- iq ellipsoid SDF inlined (skipping sphere branch
						-- because slabs are rarely uniform).
						local k0x, k0y, k0z = lx / semiX, ly / semiY, lz / semiZ
						local k0 = math.sqrt(k0x * k0x + k0y * k0y + k0z * k0z)
						local d
						if k0 < 1e-6 then
							d = -math.min(semiX, semiY, semiZ)
						else
							local k1x, k1y, k1z = k0x / semiX, k0y / semiY, k0z / semiZ
							local k1 = math.sqrt(k1x * k1x + k1y * k1y + k1z * k1z)
							d = k0 * (k0 - 1) / k1
						end
						local neg = -d
						local i = baseYZ + x
						if neg > sdf[i] then
							sdf[i] = neg
						end
					end
				end
			end
		end
	end
	for _, e in ipairs(subtractEllipsoids) do
		local elo, ehi = ellipsoidAABB(e)
		local ix0, ix1, iy0, iy1, iz0, iz1 = aabbToIndexRange(elo, ehi)
		local ecX, ecY, ecZ = e.center.X, e.center.Y, e.center.Z
		local eSemi = e.semi
		for z = iz0, iz1 do
			local baseZ = 1 + sampleZ_ * z
			local pzBase = minVZ + z * cellSize - ecZ
			for y = iy0, iy1 do
				local baseYZ = baseZ + sampleY_ * y
				local pyBase = minVY + y * cellSize - ecY
				for x = ix0, ix1 do
					local px = minVX + x * cellSize - ecX
					local d = ellipsoidSDF(Vector3.new(px, pyBase, pzBase), eSemi)
					local neg = -d
					local i = baseYZ + x
					if neg > sdf[i] then
						sdf[i] = neg
					end
				end
			end
		end
	end
	-- Subtract capsules: drill round-section channels (bolt holes, bores,
	-- grooves). Inlined capsule SDF mirroring the union capsule loop; carves
	-- via max(sdf, -d). No owner tracking — subtracts don't claim cells.
	for _, c in ipairs(subtractCapsules) do
		local clo, chi = capsuleAABB(c)
		local ix0, ix1, iy0, iy1, iz0, iz1 = aabbToIndexRange(clo, chi)
		local caX, caY, caZ = c.a.X, c.a.Y, c.a.Z
		local baX, baY, baZ = c.b.X - caX, c.b.Y - caY, c.b.Z - caZ
		local baLenSq = baX * baX + baY * baY + baZ * baZ
		local radius = c.radius
		if baLenSq < 1e-10 then
			for z = iz0, iz1 do
				local baseZ = 1 + sampleZ_ * z
				local pzBase = minVZ + z * cellSize - caZ
				for y = iy0, iy1 do
					local baseYZ = baseZ + sampleY_ * y
					local pyBase = minVY + y * cellSize - caY
					local pyzSq = pyBase * pyBase + pzBase * pzBase
					for x = ix0, ix1 do
						local px = minVX + x * cellSize - caX
						local d = math.sqrt(px * px + pyzSq) - radius
						local neg = -d
						local i = baseYZ + x
						if neg > sdf[i] then
							sdf[i] = neg
						end
					end
				end
			end
		else
			local invBaLenSq = 1 / baLenSq
			for z = iz0, iz1 do
				local baseZ = 1 + sampleZ_ * z
				local paZBase = minVZ + z * cellSize - caZ
				for y = iy0, iy1 do
					local baseYZ = baseZ + sampleY_ * y
					local paYBase = minVY + y * cellSize - caY
					for x = ix0, ix1 do
						local paX = minVX + x * cellSize - caX
						local hh = (paX * baX + paYBase * baY + paZBase * baZ) * invBaLenSq
						if hh < 0 then hh = 0 elseif hh > 1 then hh = 1 end
						local dx = paX - baX * hh
						local dy = paYBase - baY * hh
						local dz = paZBase - baZ * hh
						local d = math.sqrt(dx * dx + dy * dy + dz * dz) - radius
						local neg = -d
						local i = baseYZ + x
						if neg > sdf[i] then
							sdf[i] = neg
						end
					end
				end
			end
		end
	end

	local tSplat1 = os.clock()
	-- Flat-array cellVid indexed by 1 + cx + nx*cy + nx*ny*cz. 0 = no vertex.
	-- Array-part lookups dramatically outrun hash-part for dense integer keys.
	local cellVid = table.create(nx * ny * nz, 0)
	-- Multi-patch cells emit a second vertex (one per surface patch). cellVid2
	-- holds the slot-2 vid (0 = none), cellSlot2Mask holds the 12-bit slot-2
	-- bitmask (mp.slot2Bits, 0 if single-patch). Triangulation then resolves
	-- with one bit-and: `bit32.band(slot2Mask, edgeBit) ~= 0 ? cellVid2 : cellVid`.
	local cellVid2 = table.create(nx * ny * nz, 0)
	local cellSlot2Mask = table.create(nx * ny * nz, 0)
	local cellStrideY = nx
	local cellStrideZ = nx * ny

	-- Hot loop. Five optimizations stacked here:
	--   (1) Inlined index math (no sdfIdx function calls).
	--   (2) Sliding-window corner reuse: each cell's left-plane corners (s0,
	--       s2, s4, s6) are carried over from the previous cell's right plane,
	--       halving the SDF reads per cell from 8 → 4.
	--   (3) All-same-sign early exit (most cells are fully inside or outside).
	--   (4) Switch-ladder replaced by pre-computed corner-index table lookup.
	--   (5) cornerS pre-allocated once and overwritten per cell, instead of
	--       a fresh `{ s0, s1, ..., s7 }` literal per cell. With ~200k cells
	--       the per-cell allocation was a real hot-path GC contributor.
	local cornerS = table.create(8, 0)
	for cz = 0, nz - 1 do
		local baseZ0 = 1 + sampleZ_ * cz
		local baseZ1 = baseZ0 + sampleZ_
		local cellBaseZ = cellStrideZ * cz
		for cy = 0, ny - 1 do
			local baseYZ0 = baseZ0 + sampleY_ * cy
			local baseYZ1 = baseYZ0 + sampleY_
			local baseYZ2 = baseZ1 + sampleY_ * cy
			local baseYZ3 = baseYZ2 + sampleY_
			local cellBaseYZ = cellBaseZ + cellStrideY * cy

			-- Initial left-plane corners for cx = 0
			local s0 = sdf[baseYZ0]
			local s2 = sdf[baseYZ1]
			local s4 = sdf[baseYZ2]
			local s6 = sdf[baseYZ3]
			local o0 = owner[baseYZ0]
			local o2 = owner[baseYZ1]
			local o4 = owner[baseYZ2]
			local o6 = owner[baseYZ3]

			for cx = 0, nx - 1 do
				local i1 = baseYZ0 + cx + 1
				local i3 = baseYZ1 + cx + 1
				local i5 = baseYZ2 + cx + 1
				local i7 = baseYZ3 + cx + 1

				-- Right-plane corners (new reads for this cell)
				local s1 = sdf[i1]
				local s3 = sdf[i3]
				local s5 = sdf[i5]
				local s7 = sdf[i7]

				-- All-same-sign early exit
				local sign0 = s0 < 0
				if
					sign0 == (s1 < 0)
					and sign0 == (s2 < 0)
					and sign0 == (s3 < 0)
					and sign0 == (s4 < 0)
					and sign0 == (s5 < 0)
					and sign0 == (s6 < 0)
					and sign0 == (s7 < 0)
				then
					-- shift right plane to left for the next cell
					s0, s2, s4, s6 = s1, s3, s5, s7
					o0, o2, o4, o6 = owner[i1], owner[i3], owner[i5], owner[i7]
					continue
				end

				-- Gather owners for right plane (we already have left from prev iter)
				local o1 = owner[i1]
				local o3 = owner[i3]
				local o5 = owner[i5]
				local o7 = owner[i7]

				-- 12-edge loop. Pack corners into a packed-local array so the
				-- switch-ladder disappears — table access by integer is faster
				-- than an 8-branch if-else chain in Luau. cornerS is hoisted
				-- outside the cell loop and overwritten per cell to avoid a
				-- fresh 8-slot table allocation every iteration.
				cornerS[1] = s0
				cornerS[2] = s1
				cornerS[3] = s2
				cornerS[4] = s3
				cornerS[5] = s4
				cornerS[6] = s5
				cornerS[7] = s6
				cornerS[8] = s7
				local cellIdx = cellBaseYZ + cx + 1

				-- Bone-weight tally — same pattern as the original Surface Nets
				-- code: a per-cell closure over the 8 corner contributions,
				-- collapsing multi-bone cells into a single hashmap and
				-- single-bone cells into the (key, weight) pair fast path.
				local tally: { [string]: number }? = nil
				local singleKey: string? = nil
				local singleW: number = 0
				local function contribute(code: number, signInside: boolean)
					if not signInside or code <= 0 then
						return
					end
					local bws: { BoneWeight }?
					if code <= NE then
						bws = ellipsoids[code].boneWeights
					elseif code <= NE + NS then
						bws = slabs[code - NE].boneWeights
					elseif code <= NE + NS + NC then
						bws = capsules[code - NE - NS].boneWeights
					else
						bws = taperedCapsules[code - NE - NS - NC].boneWeights
					end
					if not bws then
						return
					end
					for _, bw in bws do
						if tally then
							tally[bw.key] = (tally[bw.key] or 0) + bw.w
						elseif singleKey == nil then
							singleKey = bw.key
							singleW = bw.w
						elseif singleKey == bw.key then
							singleW += bw.w
						else
							tally = { [singleKey] = singleW, [bw.key] = bw.w }
							singleKey = nil
						end
					end
				end

				-- Compute the 8-bit corner-sign mask (mask ∈ [1,254] here
				-- because the all-same-sign early exit caught 0 and 255).
				local mask = 0
				if s0 < 0 then mask += 1 end
				if s1 < 0 then mask += 2 end
				if s2 < 0 then mask += 4 end
				if s3 < 0 then mask += 8 end
				if s4 < 0 then mask += 16 end
				if s5 < 0 then mask += 32 end
				if s6 < 0 then mask += 64 end
				if s7 < 0 then mask += 128 end
				local mp = MULTI_PATCH[mask]

				if mp == nil then
					-- ── Single-patch fast path (≈97% of surface cells) ──
					-- Inline averaging + vertex emission, no extra closures
					-- beyond `contribute` (matches the original cost profile).
					local sumX, sumY, sumZ, n = 0, 0, 0, 0
					for _, e in EDGES do
						local ei1 = e[1] + 1
						local ei2 = e[2] + 1
						local a = cornerS[ei1]
						local b = cornerS[ei2]
						if (a < 0) ~= (b < 0) then
							local t = a / (a - b)
							local p0 = CORNERS[ei1]
							local p1 = CORNERS[ei2]
							sumX += p0.X + (p1.X - p0.X) * t
							sumY += p0.Y + (p1.Y - p0.Y) * t
							sumZ += p0.Z + (p1.Z - p0.Z) * t
							n += 1
						end
					end
					-- After the all-same-sign early exit n is always > 0;
					-- a non-trivial mask implies at least one cube-edge with
					-- opposite-sign endpoints.
					local invN = 1 / n
					table.insert(vertices, Vector3.new(
						minV.X + (cx + sumX * invN) * cellSize,
						minV.Y + (cy + sumY * invN) * cellSize,
						minV.Z + (cz + sumZ * invN) * cellSize
					))
					local vid = #vertices
					cellVid[cellIdx] = vid

					contribute(o0, s0 < 0)
					contribute(o1, s1 < 0)
					contribute(o2, s2 < 0)
					contribute(o3, s3 < 0)
					contribute(o4, s4 < 0)
					contribute(o5, s5 < 0)
					contribute(o6, s6 < 0)
					contribute(o7, s7 < 0)
					if tally then
						perVertexWeights[vid] = tally
					elseif singleKey then
						perVertexWeights[vid] = { [singleKey] = singleW }
					else
						perVertexWeights[vid] = {}
					end
				else
					-- ── Multi-patch slow path (≈3% of surface cells, the 8
					-- cube-diagonal masks). Slot edge lists are pre-filtered
					-- to sign-changing edges so we skip the runtime check.
					local function emitFromSlot(edges: { { number } }): number
						local sumX, sumY, sumZ, n = 0, 0, 0, 0
						for _, e in edges do
							local ei1 = e[1] + 1
							local ei2 = e[2] + 1
							local a = cornerS[ei1]
							local b = cornerS[ei2]
							local t = a / (a - b)
							local p0 = CORNERS[ei1]
							local p1 = CORNERS[ei2]
							sumX += p0.X + (p1.X - p0.X) * t
							sumY += p0.Y + (p1.Y - p0.Y) * t
							sumZ += p0.Z + (p1.Z - p0.Z) * t
							n += 1
						end
						local invN = 1 / n
						table.insert(vertices, Vector3.new(
							minV.X + (cx + sumX * invN) * cellSize,
							minV.Y + (cy + sumY * invN) * cellSize,
							minV.Z + (cz + sumZ * invN) * cellSize
						))
						return #vertices
					end
					local vid1 = emitFromSlot(mp.slot1)
					local vid2 = emitFromSlot(mp.slot2)
					cellVid[cellIdx] = vid1
					cellVid2[cellIdx] = vid2
					cellSlot2Mask[cellIdx] = mp.slot2Bits

					contribute(o0, s0 < 0)
					contribute(o1, s1 < 0)
					contribute(o2, s2 < 0)
					contribute(o3, s3 < 0)
					contribute(o4, s4 < 0)
					contribute(o5, s5 < 0)
					contribute(o6, s6 < 0)
					contribute(o7, s7 < 0)
					-- Both slot vids share the same weights — clone the tally
					-- map (the single-bone fast path already returns a fresh
					-- table per call so it's safe to reuse).
					local w1: { [string]: number }
					local w2: { [string]: number }
					if tally then
						w1 = tally
						w2 = {}
						for k, v in tally do
							w2[k] = v
						end
					elseif singleKey then
						w1 = { [singleKey] = singleW }
						w2 = { [singleKey] = singleW }
					else
						w1 = {}
						w2 = {}
					end
					perVertexWeights[vid1] = w1
					perVertexWeights[vid2] = w2
				end

				-- Slide: right plane becomes left plane of next cell.
				s0, s2, s4, s6 = s1, s3, s5, s7
				o0, o2, o4, o6 = o1, o3, o5, o7
			end
		end
	end

	-- With hard-min SDFs, cells entirely inside multiple primitives can fail to
	-- emit a surface vertex even though their neighbors produce one — leading
	-- to diamond-shaped holes along merge seams. The 3-corner fill patches
	-- those with a single triangle. With smooth-min enabled the saddle is
	-- resolved before it can create holes, and the 3-corner fill can actually
	-- produce "tooth"-like sliver triangles at the rare remaining ambiguous
	-- cells. So we only enable it under hard-min.
	local fillOpenQuads = smoothBlend <= 0

	local function emitTri(a: number, b: number, c: number, flip: boolean)
		if flip then
			table.insert(triangles, a); table.insert(triangles, c); table.insert(triangles, b)
		else
			table.insert(triangles, a); table.insert(triangles, b); table.insert(triangles, c)
		end
	end

	-- cellVid is a flat array where 0 means "no vertex in this cell".
	-- 0 is truthy in Lua, so we check > 0 explicitly (can't use `if v00 and ...`).
	local function tryQuad(v00: number, v10: number, v01: number, v11: number, flip: boolean)
		if v00 > 0 and v10 > 0 and v11 > 0 and v01 > 0 then
			emitTri(v00, v10, v11, flip)
			emitTri(v00, v11, v01, flip)
			return
		end
		if not fillOpenQuads then
			return
		end
		local present = 0
		if v00 > 0 then present += 1 end
		if v10 > 0 then present += 1 end
		if v01 > 0 then present += 1 end
		if v11 > 0 then present += 1 end
		if present < 3 then
			return
		end
		if v00 == 0 then
			emitTri(v10, v11, v01, flip)
		elseif v10 == 0 then
			emitTri(v00, v11, v01, flip)
		elseif v11 == 0 then
			emitTri(v00, v10, v01, flip)
		else
			emitTri(v00, v10, v11, flip)
		end
	end

	local tExtract1 = os.clock()
	local triStart = #triangles

	-- Quad emission with fully inlined index math. cellVid is a flat array
	-- with 0 meaning "no vertex in this cell". tryQuad reads these raw and
	-- treats 0 as absent (since 0 is truthy in Lua, the classic
	-- `if v00 and ...` pattern would misbehave — it checks > 0 instead).
	-- Edge between samples (x, y, z) and (x+s, y, z) where s is the stride
	-- along one axis. The 4 cells sharing that edge have varying (cy, cz)
	-- or (cx, cz) offsets — see each loop for the specific quad corners.
	--
	-- For multi-patch cells (cellSlot2Mask[idx] ≠ 0), each of the 12 cube-
	-- edges may belong to slot 1 or slot 2; resolveVid picks cellVid or
	-- cellVid2 accordingly so that a voxel-edge from patch B doesn't
	-- mistakenly stitch through the patch-A vertex (the spike artifact).
	-- Single-patch cells have slot2Mask = 0, so band(0, anything) = 0 and
	-- we hit the fast `cellVid[idx]` branch with no extra table reads.
	-- Caller passes edgeBit = 1 << (localEdgeIdx - 1) as a constant.
	local function resolveVid(idx: number, edgeBit: number): number
		if bit32.band(cellSlot2Mask[idx], edgeBit) ~= 0 then
			return cellVid2[idx]
		end
		return cellVid[idx]
	end

	-- X-axis edges: edge (x,y,z)→(x+1,y,z); quad cells at (x, y-1..y, z-1..z).
	-- Local cube-edge per cell (into EDGES, 1-based) and corresponding bit:
	--   v00=(x,y-1,z-1)→edge 4→bit 8 (corners 6,7); v10=(x,y,z-1)→edge 3→bit 4
	--   v01=(x,y-1,z)  →edge 2→bit 2 (corners 2,3); v11=(x,y,z)  →edge 1→bit 1
	for z = 1, nz - 1 do
		local sdfBaseZ = 1 + sampleZ_ * z
		local cellBaseZ0 = 1 + cellStrideZ * (z - 1)
		local cellBaseZ1 = cellBaseZ0 + cellStrideZ
		for y = 1, ny - 1 do
			local sdfBase = sdfBaseZ + sampleY_ * y
			local vbY0Z0 = cellBaseZ0 + cellStrideY * (y - 1)
			local vbY1Z0 = vbY0Z0 + cellStrideY
			local vbY0Z1 = cellBaseZ1 + cellStrideY * (y - 1)
			local vbY1Z1 = vbY0Z1 + cellStrideY
			for x = 0, nx - 1 do
				local a = sdf[sdfBase + x]
				local b = sdf[sdfBase + x + 1]
				if (a < 0) ~= (b < 0) then
					tryQuad(
						resolveVid(vbY0Z0 + x, 8),
						resolveVid(vbY1Z0 + x, 4),
						resolveVid(vbY0Z1 + x, 2),
						resolveVid(vbY1Z1 + x, 1),
						a >= 0
					)
				end
			end
		end
	end

	-- Y-axis edges: edge (x,y,z)→(x,y+1,z); quad cells at (x-1..x, y, z-1..z).
	-- Local cube-edge per cell and bit:
	--   v00=(x-1,y,z-1)→edge 8→bit 128 (corners 5,7); v10=(x-1,y,z)→edge 6→bit 32
	--   v01=(x,y,z-1)  →edge 7→bit 64  (corners 4,6); v11=(x,y,z)  →edge 5→bit 16
	for z = 1, nz - 1 do
		local sdfBaseZ = 1 + sampleZ_ * z
		local cellBaseZ0 = 1 + cellStrideZ * (z - 1)
		local cellBaseZ1 = cellBaseZ0 + cellStrideZ
		for y = 0, ny - 1 do
			local sdfBase = sdfBaseZ + sampleY_ * y
			local sdfBaseNext = sdfBase + sampleY_
			local vbX0Z0 = cellBaseZ0 + cellStrideY * y
			local vbX0Z1 = cellBaseZ1 + cellStrideY * y
			for x = 1, nx - 1 do
				local a = sdf[sdfBase + x]
				local b = sdf[sdfBaseNext + x]
				if (a < 0) ~= (b < 0) then
					tryQuad(
						resolveVid(vbX0Z0 + x - 1, 128),
						resolveVid(vbX0Z1 + x - 1, 32),
						resolveVid(vbX0Z0 + x, 64),
						resolveVid(vbX0Z1 + x, 16),
						a >= 0
					)
				end
			end
		end
	end

	-- Z-axis edges: edge (x,y,z)→(x,y,z+1); quad cells at (x-1..x, y-1..y, z).
	-- Quad plane is XY here so tryQuad's v10 must vary in X and v01 in Y
	-- (matches the original non-sliding loop's winding; getting this wrong
	-- flips triangle winding and renders as backfaces/tangled ribbons).
	-- Local cube-edge per cell and bit:
	--   v00=(x-1,y-1,z)→edge 12→bit 2048 (corners 3,7); v10=(x,y-1,z)→edge 11→bit 1024
	--   v01=(x-1,y,z)  →edge 10→bit 512  (corners 1,5); v11=(x,y,z)  →edge 9 →bit 256
	for z = 0, nz - 1 do
		local sdfBaseZ = 1 + sampleZ_ * z
		local sdfBaseZ1 = sdfBaseZ + sampleZ_
		local cellBaseZ = 1 + cellStrideZ * z
		for y = 1, ny - 1 do
			local sdfBase = sdfBaseZ + sampleY_ * y
			local sdfBaseN = sdfBaseZ1 + sampleY_ * y
			local vbY0 = cellBaseZ + cellStrideY * (y - 1)
			local vbY1 = vbY0 + cellStrideY
			for x = 1, nx - 1 do
				local a = sdf[sdfBase + x]
				local b = sdf[sdfBaseN + x]
				if (a < 0) ~= (b < 0) then
					tryQuad(
						resolveVid(vbY0 + x - 1, 2048), -- v00 = (x-1, y-1)
						resolveVid(vbY0 + x, 1024),     -- v10 = (x,   y-1)  ← changes X
						resolveVid(vbY1 + x - 1, 512),  -- v01 = (x-1, y  )  ← changes Y
						resolveVid(vbY1 + x, 256),      -- v11 = (x,   y  )
						a >= 0
					)
				end
			end
		end
	end
	local tQuads1 = os.clock()
	return
		#vertices,
		(#triangles - triStart) / 3,
		tSplat1 - tSplat0, -- splat
		tExtract1 - tSplat1, -- extract
		tQuads1 - tExtract1, -- quads
		nx,
		ny,
		nz
end

local function computeBounds(
	ellipsoids: { Ellipsoid },
	slabs: { Slab },
	capsules: { Capsule },
	taperedCapsules: { TaperedCapsule },
	padding: number
): (Vector3?, Vector3?)
	local minV = Vector3.new(math.huge, math.huge, math.huge)
	local maxV = Vector3.new(-math.huge, -math.huge, -math.huge)
	local hasAny = false
	for _, e in ellipsoids do
		local lo, hi = ellipsoidAABB(e)
		minV = Vector3.new(math.min(minV.X, lo.X), math.min(minV.Y, lo.Y), math.min(minV.Z, lo.Z))
		maxV = Vector3.new(math.max(maxV.X, hi.X), math.max(maxV.Y, hi.Y), math.max(maxV.Z, hi.Z))
		hasAny = true
	end
	for _, s in slabs do
		local lo, hi = slabAABB(s)
		minV = Vector3.new(math.min(minV.X, lo.X), math.min(minV.Y, lo.Y), math.min(minV.Z, lo.Z))
		maxV = Vector3.new(math.max(maxV.X, hi.X), math.max(maxV.Y, hi.Y), math.max(maxV.Z, hi.Z))
		hasAny = true
	end
	for _, c in capsules do
		local lo, hi = capsuleAABB(c)
		minV = Vector3.new(math.min(minV.X, lo.X), math.min(minV.Y, lo.Y), math.min(minV.Z, lo.Z))
		maxV = Vector3.new(math.max(maxV.X, hi.X), math.max(maxV.Y, hi.Y), math.max(maxV.Z, hi.Z))
		hasAny = true
	end
	for _, c in taperedCapsules do
		local lo, hi = taperedCapsuleAABB(c)
		minV = Vector3.new(math.min(minV.X, lo.X), math.min(minV.Y, lo.Y), math.min(minV.Z, lo.Z))
		maxV = Vector3.new(math.max(maxV.X, hi.X), math.max(maxV.Y, hi.Y), math.max(maxV.Z, hi.Z))
		hasAny = true
	end
	if not hasAny then
		return nil, nil
	end
	local pad = Vector3.one * padding
	return minV - pad, maxV + pad
end

-- Topological sort of bone decls so each AddBone call can pass a resolved
-- ParentId. Cycles or unknown parentKey throw — caller bug, loud is better.
local function sortBonesParentsFirst(bones: { BoneDecl }): { BoneDecl }
	local byKey: { [string]: BoneDecl } = {}
	for _, b in bones do
		if byKey[b.key] then
			error("SdfMesher: duplicate bone key '" .. b.key .. "'", 2)
		end
		byKey[b.key] = b
	end
	local sorted: { BoneDecl } = {}
	local visited: { [string]: boolean } = {}
	local function visit(b: BoneDecl, stack: { [string]: boolean })
		if visited[b.key] then
			return
		end
		if stack[b.key] then
			error("SdfMesher: bone parent cycle at '" .. b.key .. "'", 2)
		end
		stack[b.key] = true
		if b.parentKey then
			local parent = byKey[b.parentKey]
			if not parent then
				error("SdfMesher: unknown parentKey '" .. b.parentKey .. "' (on '" .. b.key .. "')", 2)
			end
			visit(parent, stack)
		end
		stack[b.key] = false
		visited[b.key] = true
		table.insert(sorted, b)
	end
	for _, b in bones do
		visit(b, {})
	end
	return sorted
end

-- Polynomial hash × golden-angle (~137°) after the mod scatters adjacent
-- input strings to maximally-separated hues.
local function keyToColor(key: string): Color3
	local h = 0
	for i = 1, #key do
		h = (h * 31 + string.byte(key, i)) % 100000
	end
	local hue = ((h * 137) % 360) / 360
	return Color3.fromHSV(hue, 0.75, 0.95)
end

-- ─────────────────────────────────────────────────────────────
-- QEM (Quadric Error Metric) decimation
-- ─────────────────────────────────────────────────────────────
--
-- Garland-Heckbert edge collapse. For every vertex we accumulate the sum
-- of plane outer products from its incident faces — that's a 4x4
-- symmetric quadric whose v^T Q v at any candidate point equals the
-- total squared distance from that point to all original incident
-- planes. To collapse an edge (a, b) we combine their quadrics, solve a
-- 3x3 linear system for the optimal new vertex position (the point that
-- minimises v^T (Qa+Qb) v), and use that minimum as the collapse cost.
-- Edges go into a min-heap keyed by cost; we pop the cheapest, validate
-- that no incident face would flip its normal, and if good, commit. The
-- coplanar pass below is kept around for the future "decimate even
-- harder for low-end devices" case — see decimateMeshQEM's docstring on
-- the pipeline call site for how to switch.

-- Symmetric 4x4 matrix packed as 10 doubles in upper-triangle order:
--   [ q1 q2 q3 q4 ]
--   [    q5 q6 q7 ]
--   [       q8 q9 ]
--   [          q10]
type Quadric = { number }

local function quadricFromPlane(nx: number, ny: number, nz: number, d: number): Quadric
	return {
		nx * nx, nx * ny, nx * nz, nx * d,
		         ny * ny, ny * nz, ny * d,
		                  nz * nz, nz * d,
		                           d  * d,
	}
end

local function quadricAdd(a: Quadric, b: Quadric): Quadric
	return {
		a[1] + b[1], a[2] + b[2], a[3] + b[3], a[4] + b[4],
		a[5] + b[5], a[6] + b[6], a[7] + b[7],
		a[8] + b[8], a[9] + b[9],
		a[10] + b[10],
	}
end

-- v^T Q v with v = (x, y, z, 1)
local function quadricErrorAt(q: Quadric, x: number, y: number, z: number): number
	return q[1] * x * x + 2 * q[2] * x * y + 2 * q[3] * x * z + 2 * q[4] * x
		                +     q[5] * y * y + 2 * q[6] * y * z + 2 * q[7] * y
		                                   +     q[8] * z * z + 2 * q[9] * z
		                                                      +     q[10]
end

-- Solve the 3x3 symmetric system for the gradient-zero point.
-- Returns (Vector3 position, residual error). Falls back to `fallback` and
-- evaluates the error there when the system is singular (parallel planes,
-- pure boundary verts, etc.).
local function quadricOptimal(q: Quadric, fallback: Vector3): (Vector3, number)
	local a11, a12, a13 = q[1], q[2], q[3]
	local a22, a23, a33 = q[5], q[6], q[8]
	local m11 = a22 * a33 - a23 * a23
	local m12 = a13 * a23 - a12 * a33
	local m13 = a12 * a23 - a13 * a22
	local det = a11 * m11 + a12 * m12 + a13 * m13

	if math.abs(det) < 1e-12 then
		return fallback, quadricErrorAt(q, fallback.X, fallback.Y, fallback.Z)
	end

	local m22 = a11 * a33 - a13 * a13
	local m23 = a12 * a13 - a11 * a23
	local m33 = a11 * a22 - a12 * a12
	local invDet = 1 / det
	local b1, b2, b3 = -q[4], -q[7], -q[9]

	local x = invDet * (m11 * b1 + m12 * b2 + m13 * b3)
	local y = invDet * (m12 * b1 + m22 * b2 + m23 * b3)
	local z = invDet * (m13 * b1 + m23 * b2 + m33 * b3)

	return Vector3.new(x, y, z), quadricErrorAt(q, x, y, z)
end

-- Min-heap keyed on `.cost`. Stale entries are detected by the caller
-- (we leave them in the heap and skip on pop).
local function heapPush(heap: { any }, item: any)
	table.insert(heap, item)
	local i = #heap
	while i > 1 do
		local p = i // 2
		if heap[p].cost > heap[i].cost then
			heap[i], heap[p] = heap[p], heap[i]
			i = p
		else
			break
		end
	end
end

local function heapPop(heap: { any }): any
	local n = #heap
	if n == 0 then return nil end
	local top = heap[1]
	if n == 1 then
		heap[1] = nil
		return top
	end
	heap[1] = heap[n]
	heap[n] = nil
	n -= 1
	local i = 1
	while true do
		local l = i * 2
		if l > n then break end
		local s = i
		if heap[l].cost < heap[s].cost then s = l end
		if l + 1 <= n and heap[l + 1].cost < heap[s].cost then s = l + 1 end
		if s == i then break end
		heap[i], heap[s] = heap[s], heap[i]
		i = s
	end
	return top
end

local function decimateMeshQEM(
	verts: { Vector3 },
	tris: { number },
	weights: { { [string]: number } },
	targetReduction: number, -- 0..1: fraction of triangles to remove
	maxErrorThreshold: number, -- stop once cheapest collapse cost > this
	lengthPenaltyWeight: number, -- adds lengthPenaltyWeight * edgeLen² to the cost; tiebreaker on near-flat regions
	maxValence: number -- reject collapse if surviving vertex's neighbor count would exceed this
): ({ Vector3 }, { number }, { { [string]: number } })
	local nVerts = #verts
	local nTris = #tris / 3

	local Q: { Quadric } = table.create(nVerts)
	for v = 1, nVerts do
		Q[v] = { 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 }
	end

	local faceNormal: { Vector3 } = table.create(nTris)
	local triActive = table.create(nTris, true)
	local vToTris: { { number } } = table.create(nVerts)
	for v = 1, nVerts do vToTris[v] = {} end

	-- Initial pass: face normals, vertex quadrics, vertex→face adjacency.
	for ti = 1, nTris do
		local base = (ti - 1) * 3
		local a, b, c = tris[base + 1], tris[base + 2], tris[base + 3]
		local va, vb, vc = verts[a], verts[b], verts[c]
		local n = (vb - va):Cross(vc - va)
		local m = n.Magnitude
		if m > 1e-9 then
			n = n / m
			faceNormal[ti] = n
			local d = -n:Dot(va)
			local q = quadricFromPlane(n.X, n.Y, n.Z, d)
			Q[a] = quadricAdd(Q[a], q)
			Q[b] = quadricAdd(Q[b], q)
			Q[c] = quadricAdd(Q[c], q)
		else
			faceNormal[ti] = Vector3.zero
			triActive[ti] = false
		end
		table.insert(vToTris[a], ti)
		table.insert(vToTris[b], ti)
		table.insert(vToTris[c], ti)
	end

	local vertRemoved = table.create(nVerts, false)
	local edges: { [string]: any } = {}
	local heap: { any } = {}

	local function evalEdge(a: number, b: number)
		if a == b then return end
		if a > b then a, b = b, a end
		if vertRemoved[a] or vertRemoved[b] then return end
		local q = quadricAdd(Q[a], Q[b])
		local fallback = (verts[a] + verts[b]) * 0.5
		local target, cost = quadricOptimal(q, fallback)
		-- Edge-length tiebreaker: on near-flat regions every QEM cost is
		-- ≈0, so heap order picks essentially at random and decimation
		-- cascades into one hub vertex. The length term breaks the tie in
		-- favor of short edges, decimating uniformly instead of radially.
		local edge = verts[b] - verts[a]
		cost += lengthPenaltyWeight * edge:Dot(edge)
		local entry = { cost = cost, target = target, lo = a, hi = b }
		edges[a .. "_" .. b] = entry
		heapPush(heap, entry)
	end

	-- Post-collapse valence: count of distinct surviving neighbours that
	-- would end up in vToTris[va] after vb folds in (excluding va, vb,
	-- and removed verts).
	local function postCollapseValence(va: number, vb: number): number
		local seen: { [number]: boolean } = {}
		for _, ti in ipairs(vToTris[va]) do
			if not triActive[ti] then continue end
			local base = (ti - 1) * 3
			for k = 1, 3 do
				local nv = tris[base + k]
				if nv ~= va and nv ~= vb and not vertRemoved[nv] then
					seen[nv] = true
				end
			end
		end
		for _, ti in ipairs(vToTris[vb]) do
			if not triActive[ti] then continue end
			local base = (ti - 1) * 3
			for k = 1, 3 do
				local nv = tris[base + k]
				if nv ~= va and nv ~= vb and not vertRemoved[nv] then
					seen[nv] = true
				end
			end
		end
		local count = 0
		for _ in pairs(seen) do count += 1 end
		return count
	end

	for ti = 1, nTris do
		if not triActive[ti] then continue end
		local base = (ti - 1) * 3
		local a, b, c = tris[base + 1], tris[base + 2], tris[base + 3]
		evalEdge(a, b)
		evalEdge(b, c)
		evalEdge(c, a)
	end

	-- Reject the collapse if any incident face would flip its normal or
	-- become degenerate. Faces that sit on both va and vb will collapse to
	-- a degenerate tri and are filtered out by the hasOther check.
	local function wouldFlip(va: number, vb: number, target: Vector3): boolean
		for _, ti in ipairs(vToTris[va]) do
			if not triActive[ti] then continue end
			local base = (ti - 1) * 3
			local i1, i2, i3 = tris[base + 1], tris[base + 2], tris[base + 3]
			if i1 == vb or i2 == vb or i3 == vb then continue end
			local p1 = if i1 == va then target else verts[i1]
			local p2 = if i2 == va then target else verts[i2]
			local p3 = if i3 == va then target else verts[i3]
			local newN = (p2 - p1):Cross(p3 - p1)
			if newN.Magnitude < 1e-9 then return true end
			if newN:Dot(faceNormal[ti]) <= 0 then return true end
		end
		for _, ti in ipairs(vToTris[vb]) do
			if not triActive[ti] then continue end
			local base = (ti - 1) * 3
			local i1, i2, i3 = tris[base + 1], tris[base + 2], tris[base + 3]
			if i1 == va or i2 == va or i3 == va then continue end
			local p1 = if i1 == vb then target else verts[i1]
			local p2 = if i2 == vb then target else verts[i2]
			local p3 = if i3 == vb then target else verts[i3]
			local newN = (p2 - p1):Cross(p3 - p1)
			if newN.Magnitude < 1e-9 then return true end
			if newN:Dot(faceNormal[ti]) <= 0 then return true end
		end
		return false
	end

	local liveTri = 0
	for ti = 1, nTris do
		if triActive[ti] then liveTri += 1 end
	end
	local targetTri = math.max(0, math.floor(liveTri * (1 - targetReduction)))

	while liveTri > targetTri do
		local edge = heapPop(heap)
		if not edge then break end
		if edge.cost > maxErrorThreshold then break end

		local key = edge.lo .. "_" .. edge.hi
		if edges[key] ~= edge then continue end -- stale (cost was re-evaluated)
		if vertRemoved[edge.lo] or vertRemoved[edge.hi] then continue end

		local va, vb = edge.lo, edge.hi
		local target = edge.target

		if wouldFlip(va, vb, target) then
			edges[key] = nil
			continue
		end

		-- Hard cap on hub formation: if folding vb into va would push va's
		-- neighbour count past maxValence, reject — produces the long
		-- radial fan triangulations otherwise. Drop the edge from the map
		-- so we don't reconsider this exact pair (other edges incident to
		-- va/vb may still be viable as the mesh evolves around them).
		if postCollapseValence(va, vb) > maxValence then
			edges[key] = nil
			continue
		end

		-- Commit: move va to target, fold vb into va, fix incident tris.
		verts[va] = target
		Q[va] = quadricAdd(Q[va], Q[vb])

		local merged: { number } = {}
		for _, ti in ipairs(vToTris[va]) do
			if triActive[ti] then table.insert(merged, ti) end
		end
		for _, ti in ipairs(vToTris[vb]) do
			if not triActive[ti] then continue end
			local base = (ti - 1) * 3
			local i1, i2, i3 = tris[base + 1], tris[base + 2], tris[base + 3]
			if i1 == vb then i1 = va end
			if i2 == vb then i2 = va end
			if i3 == vb then i3 = va end
			if i1 == i2 or i2 == i3 or i1 == i3 then
				triActive[ti] = false
				liveTri -= 1
			else
				tris[base + 1], tris[base + 2], tris[base + 3] = i1, i2, i3
				local p1, p2, p3 = verts[i1], verts[i2], verts[i3]
				local n = (p2 - p1):Cross(p3 - p1)
				local m = n.Magnitude
				if m > 1e-9 then
					faceNormal[ti] = n / m
					table.insert(merged, ti)
				else
					triActive[ti] = false
					liveTri -= 1
				end
			end
		end
		-- Re-normal the va-only tris too — the vertex moved.
		for _, ti in ipairs(vToTris[va]) do
			if not triActive[ti] then continue end
			local base = (ti - 1) * 3
			local p1 = verts[tris[base + 1]]
			local p2 = verts[tris[base + 2]]
			local p3 = verts[tris[base + 3]]
			local n = (p2 - p1):Cross(p3 - p1)
			local m = n.Magnitude
			if m > 1e-9 then
				faceNormal[ti] = n / m
			end
		end
		vToTris[va] = merged
		vertRemoved[vb] = true

		-- Merge skinning weights into the surviving vertex (simple sum +
		-- normalize so total weight stays at 1).
		if weights[vb] then
			local wOut: { [string]: number } = {}
			for k, w in pairs(weights[va] or {}) do wOut[k] = w end
			for k, w in pairs(weights[vb]) do wOut[k] = (wOut[k] or 0) + w end
			local sum = 0
			for _, w in pairs(wOut) do sum += w end
			if sum > 0 then
				for k, w in pairs(wOut) do wOut[k] = w / sum end
			end
			weights[va] = wOut
		end

		-- Re-cost edges from va to each surviving neighbour.
		local neighbours: { [number]: boolean } = {}
		for _, ti in ipairs(vToTris[va]) do
			local base = (ti - 1) * 3
			for k = 1, 3 do
				local nv = tris[base + k]
				if nv ~= va and not vertRemoved[nv] then
					neighbours[nv] = true
				end
			end
		end
		for nv in pairs(neighbours) do
			evalEdge(va, nv)
		end
	end

	-- Compaction.
	local oldToNew = table.create(nVerts)
	local newVerts: { Vector3 } = {}
	local newWeights: { { [string]: number } } = {}
	for v = 1, nVerts do
		if not vertRemoved[v] then
			table.insert(newVerts, verts[v])
			if weights[v] then table.insert(newWeights, weights[v]) end
			oldToNew[v] = #newVerts
		end
	end
	local newTris: { number } = {}
	local nTrisCurr = #tris / 3
	for ti = 1, nTrisCurr do
		if not triActive[ti] then continue end
		local base = (ti - 1) * 3
		local a = oldToNew[tris[base + 1]]
		local b = oldToNew[tris[base + 2]]
		local c = oldToNew[tris[base + 3]]
		if a and b and c then
			table.insert(newTris, a)
			table.insert(newTris, b)
			table.insert(newTris, c)
		end
	end
	return newVerts, newTris, newWeights
end

-- ─────────────────────────────────────────────────────────────
-- Coplanar vertex decimation (legacy fallback)
-- ─────────────────────────────────────────────────────────────
--
-- Removes interior vertices whose incident triangles are all coplanar
-- within `coplanarThreshold` (cosine of the angle between adjacent face
-- normals; 1.0 = identical, 0.995 ≈ 5.7°). The boundary loop around the
-- removed vertex is fan-triangulated and the result is rejected if any
-- new triangle's normal would invert relative to the original face. Kept
-- on hand for cases where we want to decimate harder than QEM (low-end
-- devices); QEM gives much cleaner geometry on curved surfaces but
-- preserves more triangles.
local function decimateMesh(
	verts: { Vector3 },
	tris: { number },
	weights: { { [string]: number } },
	coplanarThreshold: number,
	maxPasses: number,
	maxValence: number
): ({ Vector3 }, { number }, { { [string]: number } })
	local nVerts = #verts
	local removed = table.create(nVerts, false)

	local function rebuildTopology()
		local nTris = #tris / 3
		local vToTris = table.create(nVerts)
		for v = 1, nVerts do vToTris[v] = {} end
		local triNormals = table.create(nTris)
		for ti = 1, nTris do
			local base = (ti - 1) * 3
			local a, b, c = tris[base + 1], tris[base + 2], tris[base + 3]
			table.insert(vToTris[a], ti)
			table.insert(vToTris[b], ti)
			table.insert(vToTris[c], ti)
			local n = (verts[b] - verts[a]):Cross(verts[c] - verts[a])
			local m = n.Magnitude
			triNormals[ti] = if m > 1e-9 then n / m else Vector3.zero
		end
		return vToTris, triNormals, nTris
	end

	for _ = 1, maxPasses do
		local vToTris, triNormals, nTris = rebuildTopology()
		local triActive = table.create(nTris, true)
		local touched = table.create(nVerts, false)
		local addedTris: { number } = {}
		local removedThisPass = 0

		for v = 1, nVerts do
			if removed[v] or touched[v] then continue end

			-- Drop any stale tri references (from earlier collapses this pass).
			local incident = vToTris[v]
			local active = {}
			for _, ti in ipairs(incident) do
				if triActive[ti] then table.insert(active, ti) end
			end
			if #active < 3 or #active > maxValence then continue end

			-- Coplanarity check: every incident face must agree with the first.
			local n0 = triNormals[active[1]]
			if n0:Dot(n0) < 0.5 then continue end -- ref face is degenerate
			local coplanar = true
			for i = 2, #active do
				if n0:Dot(triNormals[active[i]]) < coplanarThreshold then
					coplanar = false
					break
				end
			end
			if not coplanar then continue end

			-- Walk the boundary cycle. For each incident triangle, the edge
			-- opposite v contributes one (start → end) link in the cycle.
			-- A non-closed cycle means v is on a mesh boundary — skip.
			local nextOf = {}
			for _, ti in ipairs(active) do
				local base = (ti - 1) * 3
				local ta, tb, tc = tris[base + 1], tris[base + 2], tris[base + 3]
				if ta == v then nextOf[tb] = tc
				elseif tb == v then nextOf[tc] = ta
				else nextOf[ta] = tb end
			end
			local boundary = {}
			local startV
			for k in pairs(nextOf) do startV = k; break end
			if not startV then continue end
			local cur = startV
			local closed = false
			for _ = 1, #active + 1 do
				table.insert(boundary, cur)
				local nxt = nextOf[cur]
				if not nxt then break end
				if nxt == startV then closed = true; break end
				cur = nxt
			end
			if not closed or #boundary ~= #active then continue end

			-- Fan-triangulate from boundary[1]. Reject if any new triangle's
			-- normal flips against the original face (non-convex boundary).
			local newTris = {}
			local fanOk = true
			for k = 2, #boundary - 1 do
				local pa, pb, pc = boundary[1], boundary[k], boundary[k + 1]
				local nn = (verts[pb] - verts[pa]):Cross(verts[pc] - verts[pa])
				if nn:Dot(n0) <= 0 then
					fanOk = false
					break
				end
				newTris[#newTris + 1] = pa
				newTris[#newTris + 1] = pb
				newTris[#newTris + 1] = pc
			end
			if not fanOk then continue end

			for _, ti in ipairs(active) do
				triActive[ti] = false
			end
			for _, idx in ipairs(newTris) do
				table.insert(addedTris, idx)
			end
			-- Don't touch boundary verts again this pass — their topology
			-- changed and we'd need to rebuild before evaluating them.
			for _, bv in ipairs(boundary) do
				touched[bv] = true
			end
			removed[v] = true
			removedThisPass += 1
		end

		if removedThisPass == 0 then break end

		-- Compact tris into the new array.
		local newTrisArr = {}
		for ti = 1, nTris do
			if triActive[ti] then
				local base = (ti - 1) * 3
				table.insert(newTrisArr, tris[base + 1])
				table.insert(newTrisArr, tris[base + 2])
				table.insert(newTrisArr, tris[base + 3])
			end
		end
		for _, idx in ipairs(addedTris) do
			table.insert(newTrisArr, idx)
		end
		tris = newTrisArr
	end

	-- Final compaction: drop removed verts + remap tri indices.
	if next(removed) == nil then
		return verts, tris, weights
	end
	local oldToNew = table.create(nVerts)
	local newVerts = {}
	local newWeights = {}
	for v = 1, nVerts do
		if not removed[v] then
			table.insert(newVerts, verts[v])
			if weights[v] then
				table.insert(newWeights, weights[v])
			end
			oldToNew[v] = #newVerts
		end
	end
	local newTrisFinal = {}
	local nTris = #tris / 3
	for ti = 1, nTris do
		local base = (ti - 1) * 3
		local a = oldToNew[tris[base + 1]]
		local b = oldToNew[tris[base + 2]]
		local c = oldToNew[tris[base + 3]]
		if a and b and c then
			table.insert(newTrisFinal, a)
			table.insert(newTrisFinal, b)
			table.insert(newTrisFinal, c)
		end
	end
	return newVerts, newTrisFinal, newWeights
end

-- ─────────────────────────────────────────────────────────────
-- Top-level build
-- ─────────────────────────────────────────────────────────────

function SdfMesher.build(input: Input, config: Config?): (Output?, string)
	local cfg = config or {}
	local triCap = cfg.triCap or DEFAULT_TRI_CAP
	local boundsPadding = cfg.boundsPadding or DEFAULT_BOUNDS_PADDING
	local initialMaxCells = cfg.initialMaxCellsPerDim or DEFAULT_INITIAL_MAX_CELLS_PER_DIM
	local maxCoarsenAttempts = cfg.maxCoarsenAttempts or DEFAULT_MAX_COARSEN_ATTEMPTS
	local coarsenFactor = cfg.coarsenFactor or DEFAULT_COARSEN_FACTOR
	local maxBonesPerVertex = cfg.maxBonesPerVertex or DEFAULT_MAX_BONES_PER_VERTEX
	local spill = cfg.primitiveSpill or DEFAULT_PRIMITIVE_SPILL
	local smoothBlend = cfg.smoothBlend or DEFAULT_SMOOTH_BLEND
	local debugVertexColors = cfg.debugVertexColors == true

	local ellipsoids = input.ellipsoids or {}
	local slabs = input.slabs or {}
	local capsules = input.capsules or {}
	local taperedCapsules = input.taperedCapsules or {}
	local subtractSlabs = input.subtractSlabs or {}
	local subtractEllipsoids = input.subtractEllipsoids or {}
	local subtractCapsules = input.subtractCapsules or {}
	local bones = input.bones or {}

	if #ellipsoids == 0 and #slabs == 0 and #capsules == 0 and #taperedCapsules == 0 then
		return nil, "No primitives"
	end

	local minV, maxV = computeBounds(ellipsoids, slabs, capsules, taperedCapsules, boundsPadding)
	if not minV or not maxV then
		return nil, "Empty bounds"
	end
	local size = maxV - minV
	local maxDim = math.max(size.X, size.Y, size.Z)
	if maxDim < 0.01 then
		return nil, "Bounds too small"
	end

	local tTotal0 = os.clock()
	local splatTotal, extractTotal, quadsTotal, decimateTotal = 0, 0, 0, 0
	local coarsenAttempts = 0
	local cellSize = maxDim / initialMaxCells
	local finalVerts: { Vector3 }? = nil
	local finalTris: { number }? = nil
	local finalWeights: { { [string]: number } }? = nil
	local finalCellSize = cellSize
	local finalGridX, finalGridY, finalGridZ = 0, 0, 0
	-- triCap gates the DECIMATED triangle count, not the raw surface-nets
	-- output. Surface nets routinely emits 2–3× the final triangle budget,
	-- and the QEM pass below reclaims most of it on rounded/flat regions.
	-- Checking the cap pre-decimation would coarsen the voxel grid — throwing
	-- away silhouette detail (helmet curvature, thin limbs) — to satisfy a
	-- budget the decimator would have met on its own. So every attempt runs
	-- the FULL splat → extract → decimate chain and only coarsens when the
	-- *decimated* mesh still overflows.
	for _ = 1, maxCoarsenAttempts do
		coarsenAttempts += 1
		local verts: { Vector3 } = {}
		local tris: { number } = {}
		local perVertWeights: { { [string]: number } } = {}
		local _, rawTc, splatT, extractT, quadsT, gx, gy, gz =
			meshPrimitives(minV, maxV, cellSize, spill, smoothBlend, ellipsoids, slabs, capsules, taperedCapsules, subtractSlabs, subtractEllipsoids, subtractCapsules, verts, tris, perVertWeights)
		splatTotal += splatT
		extractTotal += extractT
		quadsTotal += quadsT
		if rawTc == 0 then
			return nil, "No surface produced"
		end

		-- QEM decimation pass. Edge collapse ordered by quadric error metric —
		-- preserves curvature on rounded surfaces where the coplanar pass
		-- would flatten and create discontinuities. To switch back to the
		-- coplanar pass (e.g., for harder reductions on low-end devices),
		-- replace decimateMeshQEM with decimateMesh and pass the
		-- (coplanarThreshold, maxPasses, maxValence) tuple instead. The error
		-- threshold scales with cellSize², so a coarsened retry also tolerates
		-- proportionally larger collapses.
		local tDecimate0 = os.clock()
		local dVerts, dTris, dWeights = decimateMeshQEM(
			verts,
			tris,
			perVertWeights,
			cfg.qemTargetReduction or 0.6, -- aim to remove ~60% of triangles
			cfg.qemMaxErrorThreshold or (cellSize * cellSize * 0.25),
			cfg.qemLengthPenaltyWeight or 0.005, -- edge-length tiebreaker on flat regions
			cfg.qemMaxValence or 12 -- reject collapses that would create hub vertices
		)
		decimateTotal += os.clock() - tDecimate0
		local decTc = #dTris / 3

		if decTc <= triCap then
			finalVerts = dVerts
			finalTris = dTris
			finalWeights = dWeights
			finalCellSize = cellSize
			finalGridX, finalGridY, finalGridZ = gx, gy, gz
			break
		end
		-- Coarsen retry: even AFTER decimation the mesh overflows triCap, so we
		-- redo the WHOLE splat+extract+decimate pass at lower resolution. This
		-- multiplies the wall time of the bake. Surface it loud so callers can
		-- either bump triCap, simplify input, or tighten bounds.
		local oldCells = gx * gy * gz
		warn(string.format(
			"[SdfMesher] triangle-cap retry — decimated to %d tris from %d raw (cap=%d) at %.3f-stud cells (%dx%dx%d=%d cells, attempt %d). Coarsening to %.3f-stud and re-running. Primitives: %d ellipsoids, %d slabs, %d capsules, %d tapered, %d subtractSlabs.",
			decTc, rawTc, triCap, cellSize, gx, gy, gz, oldCells, coarsenAttempts,
			cellSize * coarsenFactor,
			#ellipsoids, #slabs, #capsules, #taperedCapsules, #subtractSlabs
		))
		cellSize *= coarsenFactor
	end

	if not finalVerts or not finalTris or not finalWeights then
		return nil, string.format("Could not fit under %d-tri cap after %d attempts", triCap, maxCoarsenAttempts)
	end

	local em = AssetService:CreateEditableMesh()
	local vids = table.create(#finalVerts)
	for i, p in finalVerts do
		vids[i] = em:AddVertex(p)
	end
	local fids = table.create(#finalTris / 3)
	for i = 1, #finalTris, 3 do
		fids[(i - 1) / 3 + 1] = em:AddTriangle(
			vids[finalTris[i]],
			vids[finalTris[i + 1]],
			vids[finalTris[i + 2]]
		)
	end

	local tBones0 = os.clock()
	-- Declare bones on the EM in parents-first order so ParentId resolves.
	-- Cache the sort so we re-use it for the final Instance tree.
	local sortedBones: { BoneDecl } = {}
	local keyToBoneId: { [string]: any } = {}
	if #bones > 0 then
		sortedBones = sortBonesParentsFirst(bones)
		for _, spec in sortedBones do
			keyToBoneId[spec.key] = em:AddBone({
				Name = spec.name,
				ParentId = if spec.parentKey then keyToBoneId[spec.parentKey] else nil,
				CFrame = spec.bindCFrame,
				Virtual = false,
			})
		end
		for i = 1, #vids do
			local tally = finalWeights[i]
			if not tally then
				continue
			end
			local sortedBw: { { key: string, w: number } } = {}
			for k, w in tally do
				table.insert(sortedBw, { key = k, w = w })
			end
			table.sort(sortedBw, function(a, b)
				return a.w > b.w
			end)
			local keep = math.min(#sortedBw, maxBonesPerVertex)
			local sum = 0
			for j = 1, keep do
				sum += sortedBw[j].w
			end
			if sum < 1e-9 then
				continue
			end
			local ids: { any } = {}
			local ws: { number } = {}
			for j = 1, keep do
				local boneId = keyToBoneId[sortedBw[j].key]
				if boneId ~= nil then
					table.insert(ids, boneId)
					table.insert(ws, sortedBw[j].w / sum)
				end
			end
			if #ids > 0 then
				em:SetVertexBones(vids[i], ids)
				em:SetVertexBoneWeights(vids[i], ws)
			end
		end
	end
	local tBones1 = os.clock()

	local tNormals0, tNormals1 = 0, 0
	local tColors0, tColors1 = 0, 0
	if debugVertexColors then
		tColors0 = os.clock()
		local dominantByVid: { [number]: string } = {}
		for i = 1, #vids do
			local tally = finalWeights[i]
			if tally then
				local bestKey: string? = nil
				local bestW = -math.huge
				for k, w in tally do
					if w > bestW then
						bestW = w
						bestKey = k
					end
				end
				if bestKey then
					dominantByVid[i] = bestKey
				end
			end
		end
		local colorIds: { [string]: any } = {}
		for _, k in dominantByVid do
			if not colorIds[k] then
				colorIds[k] = em:AddColor(keyToColor(k), 1)
			end
		end
		for faceIdx, fid in fids do
			local base = (faceIdx - 1) * 3
			for corner = 1, 3 do
				local vIdx = finalTris[base + corner]
				local k = dominantByVid[vIdx]
				if k then
					em:SetVertexFaceColor(vids[vIdx], fid, colorIds[k])
				end
			end
		end
		tColors1 = os.clock()
	elseif cfg.vertexColorFn then
		tNormals0 = os.clock()
		-- Caller-supplied per-vertex tint (SSS fake, dot3 lighting, vertex AO, etc.)
		-- Compute per-vertex normals via face-normal averaging over adjacent
		-- triangles. Surface nets emits quads with consistent outward winding
		-- (see tryQuad's `flip` flag), so the sum is already oriented outward.
		--
		-- We also track sum-of-magnitudes per vertex so we can derive a
		-- "creaseness" score: |sum normals| / sum |face normals|. That
		-- ratio is the cosine-weighted average of how aligned a vertex's
		-- adjacent face normals are. 1 = perfectly flat (all face normals
		-- parallel), → 0 as the faces diverge. 1 - ratio is what we hand
		-- to vertexColorFn so callers can highlight cut edges, sharp
		-- corners, etc.
		local normals: { Vector3 } = table.create(#finalVerts, Vector3.zero)
		local sumMags: { number } = table.create(#finalVerts, 0)
		for i = 1, #finalTris, 3 do
			local a, b, c = finalTris[i], finalTris[i + 1], finalTris[i + 2]
			local v0, v1, v2 = finalVerts[a], finalVerts[b], finalVerts[c]
			local faceN = vector.cross(v1 - v0, v2 - v0)
			local faceMag = vector.magnitude(faceN)
			-- Area-weighted accumulation (no normalization inside the loop)
			normals[a] = normals[a] + faceN
			normals[b] = normals[b] + faceN
			normals[c] = normals[c] + faceN
			sumMags[a] += faceMag
			sumMags[b] += faceMag
			sumMags[c] += faceMag
		end
		local creaseness: { number } = table.create(#finalVerts, 0)
		for i = 1, #normals do
			local n = normals[i]
			local mag = vector.magnitude(n)
			if mag > 1e-6 then
				normals[i] = n / mag
				local denom = sumMags[i]
				if denom > 1e-6 then
					creaseness[i] = math.clamp(1 - mag / denom, 0, 1)
				end
			else
				normals[i] = Vector3.new(0, 1, 0) -- safe fallback
			end
		end
		tNormals1 = os.clock()

		tColors0 = os.clock()
		local fn = cfg.vertexColorFn
		local perVidColor: { any } = table.create(#vids)
		for i = 1, #vids do
			perVidColor[i] = em:AddColor(fn(finalVerts[i], normals[i], finalWeights[i] or {}, creaseness[i]), 1)
		end
		for faceIdx, fid in fids do
			local base = (faceIdx - 1) * 3
			for corner = 1, 3 do
				local vIdx = finalTris[base + corner]
				em:SetVertexFaceColor(vids[vIdx], fid, perVidColor[vIdx])
			end
		end
		tColors1 = os.clock()
	end

	-- Two-step bake: CreateDataModelContentAsync is the "careful" step — it
	-- cooks the EditableMesh into immutable, fidelity-locked Content (this is
	-- where RenderFidelity / CollisionFidelity / FluidFidelity are applied).
	-- Once that snapshot exists, the EditableMesh can be released. The second
	-- step — CreateMeshPartAsync — just wraps the baked Content in a MeshPart.
	local tBake0 = os.clock()
	local staticContent
	local bakeOk, bakeErr = pcall(function()
		local contentLib = (getfenv(1) :: any).Content
		local options: { [string]: any } = {}
		if cfg.renderFidelity then
			options.RenderFidelity = cfg.renderFidelity
		end
		if cfg.collisionFidelity then
			options.CollisionFidelity = cfg.collisionFidelity
		end
		if cfg.fluidFidelity then
			options.FluidFidelity = cfg.fluidFidelity
		end
		local bakeResult, baked
		if next(options) then
			bakeResult, baked = AssetService:CreateDataModelContentAsync(contentLib.fromObject(em), options)
		else
			bakeResult, baked = AssetService:CreateDataModelContentAsync(contentLib.fromObject(em))
		end
		if bakeResult ~= Enum.CreateContentResult.Success then
			error("CreateDataModelContentAsync returned " .. tostring(bakeResult))
		end
		staticContent = baked
	end)
	if not bakeOk or not staticContent then
		em:Destroy()
		return nil, "CreateDataModelContentAsync failed: " .. tostring(bakeErr)
	end
	em:Destroy() -- Content snapshot is independent; drop the editable buffers.
	local tBake1 = os.clock()

	local tCreate0 = os.clock()
	local meshPart
	local ok, err = pcall(function()
		local options: { [string]: any } = {}
		if cfg.renderFidelity then
			options.RenderFidelity = cfg.renderFidelity
		end
		if cfg.collisionFidelity then
			options.CollisionFidelity = cfg.collisionFidelity
		end
		if cfg.fluidFidelity then
			options.FluidFidelity = cfg.fluidFidelity
		end
		if next(options) then
			meshPart = AssetService:CreateMeshPartAsync(staticContent, options)
		else
			meshPart = AssetService:CreateMeshPartAsync(staticContent)
		end
	end)
	if not ok or not meshPart then
		return nil, "CreateMeshPartAsync failed: " .. tostring(err)
	end
	-- Belt-and-suspenders: in some contexts (e.g. ProceduralModel's
	-- generation pipeline) the options don't survive migration — the final
	-- MeshPart shows Default/Automatic. Set explicitly now; pcall'd because
	-- these properties may be locked post-creation in some Roblox versions.
	if cfg.renderFidelity then
		pcall(function() (meshPart :: any).RenderFidelity = cfg.renderFidelity end)
	end
	if cfg.collisionFidelity then
		pcall(function() (meshPart :: any).CollisionFidelity = cfg.collisionFidelity end)
	end
	if cfg.fluidFidelity then
		pcall(function() (meshPart :: any).FluidFidelity = cfg.fluidFidelity end)
	end
	local tCreate1 = os.clock()

	-- Attach Bone instances. The Instance hierarchy mirrors parentKey so
	-- runtime code can drive a parent (e.g. trunk) via CFrame/Transform and
	-- have children (branches, leaves) propagate along. MeshBuilder's
	-- puppet prefers flat parenting because it drives each bone's absolute
	-- world CFrame — callers doing the same should leave parentKey nil on
	-- every decl so everything parents to the MeshPart.
	if #sortedBones > 0 then
		local keyToInstance: { [string]: Bone } = {}
		for _, spec in sortedBones do
			local bone = Instance.new("Bone")
			bone.Name = spec.name
			bone.CFrame = spec.bindCFrame
			if spec.attributes then
				for k, v in spec.attributes do
					bone:SetAttribute(k, v)
				end
			end
			if spec.parentKey and keyToInstance[spec.parentKey] then
				bone.Parent = keyToInstance[spec.parentKey]
			else
				bone.Parent = meshPart
			end
			keyToInstance[spec.key] = bone
		end
	end

	local tTotal1 = os.clock()
	local timings: Timings = {
		splat = splatTotal,
		extract = extractTotal,
		quads = quadsTotal,
		decimate = decimateTotal,
		normals = tNormals1 - tNormals0,
		colors = tColors1 - tColors0,
		bones = tBones1 - tBones0,
		bakeContent = tBake1 - tBake0,
		createMeshPart = tCreate1 - tCreate0,
		total = tTotal1 - tTotal0,
	}

	return {
		meshPart = meshPart,
		triCount = #finalTris / 3,
		vertCount = #finalVerts,
		cellSize = finalCellSize,
		gridDims = Vector3.new(finalGridX, finalGridY, finalGridZ),
		primitiveCount = #ellipsoids + #slabs + #capsules,
		boneCount = #bones,
		coarsenAttempts = coarsenAttempts,
		timings = timings,
	}, string.format("%d tris @ %.2f stud cells", #finalTris / 3, finalCellSize)
end

return SdfMesher
