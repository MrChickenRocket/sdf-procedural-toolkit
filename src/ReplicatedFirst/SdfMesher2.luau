--!strict
-- SdfMesher2 — next-gen SDF mesher (work in progress).
--
-- Thesis (what we learned building the v1 soldier): the things we lean on most
-- — hard bevels, crisp boxes, and nested CSG "operand chains" — are exactly
-- what plain Surface Nets + flat union/subtract handle worst. So v2 changes
-- three things:
--
--   1. INPUT IS AN OP-GRAPH. Leaves are primitives; op nodes (union /
--      smoothUnion / subtract / intersect, each with an optional blend) nest
--      arbitrarily. The operand chain is the data structure, not a flat
--      add/subtract bucket split.
--
--   2. SHARP-FEATURE SNAPPING (the hybrid). Still Surface Nets at heart, but
--      each cell's dual vertex is placed by a REGULARIZED QEF over the edge
--      crossings' Hermite data (position + gradient). Biased toward the cell
--      mass point, it reproduces smooth SN in flat regions and snaps to the
--      corner/edge where gradients diverge — crisp bevels and box corners,
--      one formula, no mode switch.
--
--   3. ANALYTIC NORMALS. Normals come from the SDF gradient (central
--      differences of the field), not averaged face geometry — exact shading,
--      and the same Hermite data feeds the QEF. `crease` falls out of gradient
--      divergence for free.
--
-- NOT here yet (deliberately deferred): QEM decimation (cap via resolution for
-- now), multi-patch cells, a material/owner channel, the heavy per-primitive
-- inlining of v1. Correctness and sharpness first; speed and polish after.
--
-- Depends only on AssetService. The op-graph format is documented at the
-- bottom; SdfDocument will grow an adapter once this stabilises.

local AssetService = game:GetService("AssetService")

local SdfMesher2 = {}
SdfMesher2.VERSION = "2026-06-19-v2-stage3c-minimal"

-- ─────────────────────────────────────────────────────────────
-- Types
-- ─────────────────────────────────────────────────────────────

-- A node is EITHER a primitive leaf (has `shape`) OR an op (has `op` +
-- `children`). Kept as one loose type so authors write plain tables.
export type Node = {
	-- leaf
	shape: string?, -- "sphere" | "ellipsoid" | "box" | "capsule" | "cylinder"
	center: Vector3?,
	radius: number?,
	semi: Vector3?,
	cframe: CFrame?, -- box orientation (defaults to identity at `center`)
	rounding: number?, -- box: >0 rounds edges
	bevel: number?, -- box/cylinder: >0 hard flat chamfer
	height: number?, -- cylinder: full height along the frame's up axis
	a: Vector3?, -- capsule endpoints
	b: Vector3?,
	-- op
	op: string?, -- "union" | "smoothUnion" | "subtract" | "intersect"
	blend: number?, -- smoothUnion blend radius (studs)
	children: { Node }?,
}

export type Config = {
	cellSize: number?, -- explicit cell size (studs); overrides cellsPerDim
	cellsPerDim: number?, -- cells along the longest axis (default 48)
	boundsPadding: number?, -- studs around the AABB (default 1.5)
	qefBias: number?, -- regularisation toward the mass point (default 0.06)
	normalEps: number?, -- gradient step as a fraction of cellSize (default 0.35)
	sharpAngle: number?, -- degrees; a face-corner whose geometric normal diverges
	-- from the smooth analytic normal by more than this shades crisply with the
	-- face normal instead of the blended vertex normal (default 38)
	vertexColorFn: ((Vector3, Vector3, { [string]: number }, number) -> Color3)?,
	-- Decimation (QEM) — on by default; turns the dense voxel mesh into minimal
	-- geometry while preserving sharp edges.
	decimate: boolean?,
	qemTargetReduction: number?, -- fraction of tris to try to remove (default 0.92)
	qemMaxError: number?, -- stop collapsing once cost exceeds this (default cellSize²·3)
	qemLengthPenalty: number?,
	qemMaxValence: number?,
	renderFidelity: Enum.RenderFidelity?,
	collisionFidelity: Enum.CollisionFidelity?,
	fluidFidelity: Enum.FluidFidelity?,
}

export type Output = {
	meshPart: MeshPart,
	triCount: number,
	vertCount: number,
	cellSize: number,
	gridDims: Vector3,
}

local SENTINEL = 1e6

-- ─────────────────────────────────────────────────────────────
-- Primitive SDFs (local point already in the primitive's frame where needed)
-- ─────────────────────────────────────────────────────────────

local function ellipsoidSDF(px: number, py: number, pz: number, sx: number, sy: number, sz: number): number
	if sx == sy and sy == sz then
		return math.sqrt(px * px + py * py + pz * pz) - sx
	end
	local k0x, k0y, k0z = px / sx, py / sy, pz / sz
	local k0 = math.sqrt(k0x * k0x + k0y * k0y + k0z * k0z)
	if k0 < 1e-6 then
		return -math.min(sx, sy, sz)
	end
	local k1x, k1y, k1z = k0x / sx, k0y / sy, k0z / sz
	local k1 = math.sqrt(k1x * k1x + k1y * k1y + k1z * k1z)
	return k0 * (k0 - 1) / k1
end

-- Box SDF on a point already in the box's local frame. Sharp by default;
-- `rounding` rounds edges, `bevel` hard-chamfers them (overrides rounding).
local function boxSDF(lx: number, ly: number, lz: number, sx: number, sy: number, sz: number, rounding: number?, bevel: number?): number
	local ax = if lx >= 0 then lx else -lx
	local ay = if ly >= 0 then ly else -ly
	local az = if lz >= 0 then lz else -lz
	if bevel and bevel > 0 then
		local qx, qy, qz = ax - sx, ay - sy, az - sz
		local qxp = if qx > 0 then qx else 0
		local qyp = if qy > 0 then qy else 0
		local qzp = if qz > 0 then qz else 0
		local outside = math.sqrt(qxp * qxp + qyp * qyp + qzp * qzp)
		local mYZ = if qy > qz then qy else qz
		local mQ = if qx > mYZ then qx else mYZ
		local inside = if mQ < 0 then mQ else 0
		local boxD = outside + inside
		local exy = (qx + qy + bevel) * 0.70710678
		local eyz = (qy + qz + bevel) * 0.70710678
		local exz = (qx + qz + bevel) * 0.70710678
		local edgeD = if exy > eyz then exy else eyz
		if exz > edgeD then edgeD = exz end
		return if boxD > edgeD then boxD else edgeD
	elseif rounding and rounding > 0 then
		local qx, qy, qz = ax - sx + rounding, ay - sy + rounding, az - sz + rounding
		local qxp = if qx > 0 then qx else 0
		local qyp = if qy > 0 then qy else 0
		local qzp = if qz > 0 then qz else 0
		local outside = math.sqrt(qxp * qxp + qyp * qyp + qzp * qzp)
		local mYZ = if qy > qz then qy else qz
		local mQ = if qx > mYZ then qx else mYZ
		local inside = if mQ < 0 then mQ else 0
		return outside + inside - rounding
	end
	local qx, qy, qz = ax - sx, ay - sy, az - sz
	local qxp = if qx > 0 then qx else 0
	local qyp = if qy > 0 then qy else 0
	local qzp = if qz > 0 then qz else 0
	local outside = math.sqrt(qxp * qxp + qyp * qyp + qzp * qzp)
	local mYZ = if qy > qz then qy else qz
	local mQ = if qx > mYZ then qx else mYZ
	local inside = if mQ < 0 then mQ else 0
	return outside + inside
end

local function capsuleSDF(px: number, py: number, pz: number, a: Vector3, b: Vector3, r: number): number
	local pax, pay, paz = px - a.X, py - a.Y, pz - a.Z
	local bax, bay, baz = b.X - a.X, b.Y - a.Y, b.Z - a.Z
	local baLen2 = bax * bax + bay * bay + baz * baz
	if baLen2 < 1e-10 then
		return math.sqrt(pax * pax + pay * pay + paz * paz) - r
	end
	local h = (pax * bax + pay * bay + paz * baz) / baLen2
	h = if h < 0 then 0 elseif h > 1 then 1 else h
	local dx, dy, dz = pax - bax * h, pay - bay * h, paz - baz * h
	return math.sqrt(dx * dx + dy * dy + dz * dz) - r
end

-- ─────────────────────────────────────────────────────────────
-- Op-graph evaluation
-- ─────────────────────────────────────────────────────────────

local function smin(a: number, b: number, k: number): number
	if k <= 0 then
		return if a < b then a else b
	end
	local diff = a - b
	local ad = if diff >= 0 then diff else -diff
	if ad >= k then
		return if a < b then a else b
	end
	local hh = 1 - ad / k
	local m = if a < b then a else b
	return m - hh * hh * k * 0.25
end

local function evalNode(node: Node, px: number, py: number, pz: number): number
	local shape = node.shape
	if shape then
		if shape == "sphere" then
			local c = node.center or Vector3.zero
			local dx, dy, dz = px - c.X, py - c.Y, pz - c.Z
			return math.sqrt(dx * dx + dy * dy + dz * dz) - (node.radius or 1)
		elseif shape == "ellipsoid" then
			local c = node.center or Vector3.zero
			local s = node.semi or Vector3.one
			return ellipsoidSDF(px - c.X, py - c.Y, pz - c.Z, s.X, s.Y, s.Z)
		elseif shape == "box" then
			local s = node.semi or Vector3.one
			if node.cframe then
				local lp = node.cframe:PointToObjectSpace(Vector3.new(px, py, pz))
				return boxSDF(lp.X, lp.Y, lp.Z, s.X, s.Y, s.Z, node.rounding, node.bevel)
			end
			local c = node.center or Vector3.zero
			return boxSDF(px - c.X, py - c.Y, pz - c.Z, s.X, s.Y, s.Z, node.rounding, node.bevel)
		elseif shape == "capsule" then
			return capsuleSDF(px, py, pz, node.a or Vector3.zero, node.b or Vector3.zero, node.radius or 1)
		elseif shape == "cylinder" then
			-- Capped (flat-ended) cylinder along the frame's up axis. iq
			-- sdCappedCylinder in (radial, axial) space; `bevel` chamfers the
			-- rim (the single outer corner in (r,|y|) space, both ends).
			local R = node.radius or 1
			local h = (node.height or 2) * 0.5
			local cf = node.cframe or CFrame.new(node.center or Vector3.zero)
			local lp = cf:PointToObjectSpace(Vector3.new(px, py, pz))
			local r = math.sqrt(lp.X * lp.X + lp.Z * lp.Z)
			local dr = r - R
			local dy = (if lp.Y >= 0 then lp.Y else -lp.Y) - h
			local drp = if dr > 0 then dr else 0
			local dyp = if dy > 0 then dy else 0
			local outside = math.sqrt(drp * drp + dyp * dyp)
			local inside = math.min(if dr > dy then dr else dy, 0)
			local d = inside + outside
			local bevel = node.bevel
			if bevel and bevel > 0 then
				local edge = (dr + dy + bevel) * 0.70710678
				if edge > d then d = edge end
			end
			return d
		end
		error("unknown shape: " .. tostring(shape))
	end

	local op = node.op
	local children = node.children or {}
	if op == "union" then
		local d = SENTINEL
		for _, c in ipairs(children) do
			local di = evalNode(c, px, py, pz)
			if di < d then d = di end
		end
		return d
	elseif op == "smoothUnion" then
		local k = node.blend or 0
		local d = SENTINEL
		local first = true
		for _, c in ipairs(children) do
			local di = evalNode(c, px, py, pz)
			if first then d, first = di, false else d = smin(d, di, k) end
		end
		return d
	elseif op == "subtract" then
		-- children[1] minus the rest
		local d = if children[1] then evalNode(children[1], px, py, pz) else SENTINEL
		for i = 2, #children do
			local neg = -evalNode(children[i], px, py, pz)
			if neg > d then d = neg end
		end
		return d
	elseif op == "intersect" then
		local d = -SENTINEL
		for _, c in ipairs(children) do
			local di = evalNode(c, px, py, pz)
			if di > d then d = di end
		end
		return d
	end
	error("unknown op: " .. tostring(op))
end

function SdfMesher2.makeFieldFn(root: Node): (number, number, number) -> number
	return function(x: number, y: number, z: number): number
		return evalNode(root, x, y, z)
	end
end

-- ─────────────────────────────────────────────────────────────
-- AABB (conservative: union of all leaf boxes; safe for grid bounds)
-- ─────────────────────────────────────────────────────────────

local function expand(minV: Vector3, maxV: Vector3, lo: Vector3, hi: Vector3): (Vector3, Vector3)
	return Vector3.new(math.min(minV.X, lo.X), math.min(minV.Y, lo.Y), math.min(minV.Z, lo.Z)),
		Vector3.new(math.max(maxV.X, hi.X), math.max(maxV.Y, hi.Y), math.max(maxV.Z, hi.Z))
end

local function nodeAABB(node: Node, minV: Vector3, maxV: Vector3): (Vector3, Vector3)
	local shape = node.shape
	if shape then
		if shape == "sphere" then
			local c = node.center or Vector3.zero
			local r = Vector3.one * (node.radius or 1)
			return expand(minV, maxV, c - r, c + r)
		elseif shape == "ellipsoid" then
			local c = node.center or Vector3.zero
			local s = node.semi or Vector3.one
			return expand(minV, maxV, c - s, c + s)
		elseif shape == "box" then
			local s = node.semi or Vector3.one
			local cf = node.cframe or CFrame.new(node.center or Vector3.zero)
			-- world extent of an oriented box: |axis|·semi summed per world axis
			local r, u, f = cf.RightVector, cf.UpVector, -cf.LookVector
			local ext = Vector3.new(
				math.abs(r.X) * s.X + math.abs(u.X) * s.Y + math.abs(f.X) * s.Z,
				math.abs(r.Y) * s.X + math.abs(u.Y) * s.Y + math.abs(f.Y) * s.Z,
				math.abs(r.Z) * s.X + math.abs(u.Z) * s.Y + math.abs(f.Z) * s.Z
			)
			return expand(minV, maxV, cf.Position - ext, cf.Position + ext)
		elseif shape == "capsule" then
			local a, b = node.a or Vector3.zero, node.b or Vector3.zero
			local r = Vector3.one * (node.radius or 1)
			local lo = Vector3.new(math.min(a.X, b.X), math.min(a.Y, b.Y), math.min(a.Z, b.Z))
			local hi = Vector3.new(math.max(a.X, b.X), math.max(a.Y, b.Y), math.max(a.Z, b.Z))
			return expand(minV, maxV, lo - r, hi + r)
		elseif shape == "cylinder" then
			local R = node.radius or 1
			local h = (node.height or 2) * 0.5
			local cf = node.cframe or CFrame.new(node.center or Vector3.zero)
			local r, u, f = cf.RightVector, cf.UpVector, -cf.LookVector
			local ext = Vector3.new(
				math.abs(r.X) * R + math.abs(u.X) * h + math.abs(f.X) * R,
				math.abs(r.Y) * R + math.abs(u.Y) * h + math.abs(f.Y) * R,
				math.abs(r.Z) * R + math.abs(u.Z) * h + math.abs(f.Z) * R
			)
			return expand(minV, maxV, cf.Position - ext, cf.Position + ext)
		end
	end
	-- op: subtract/intersect can't grow beyond the first child, but union of
	-- all children is always a safe (conservative) superset.
	for _, c in ipairs(node.children or {}) do
		minV, maxV = nodeAABB(c, minV, maxV)
	end
	return minV, maxV
end

-- ─────────────────────────────────────────────────────────────
-- Surface-nets cube tables
-- ─────────────────────────────────────────────────────────────

local CORNERS = {
	Vector3.new(0, 0, 0), Vector3.new(1, 0, 0), Vector3.new(0, 1, 0), Vector3.new(1, 1, 0),
	Vector3.new(0, 0, 1), Vector3.new(1, 0, 1), Vector3.new(0, 1, 1), Vector3.new(1, 1, 1),
}
-- 12 edges as 1-based corner-index pairs
local EDGES = {
	{ 1, 2 }, { 3, 4 }, { 5, 6 }, { 7, 8 },
	{ 1, 3 }, { 2, 4 }, { 5, 7 }, { 6, 8 },
	{ 1, 5 }, { 2, 6 }, { 3, 7 }, { 4, 8 },
}

-- Solve a symmetric 3x3 system [a11 a12 a13; a12 a22 a23; a13 a23 a33] x = b.
-- Returns nil if (near-)singular.
local function solveSym3(a11, a12, a13, a22, a23, a33, b1, b2, b3): (number?, number?, number?)
	local c11 = a22 * a33 - a23 * a23
	local c12 = a13 * a23 - a12 * a33
	local c13 = a12 * a23 - a13 * a22
	local det = a11 * c11 + a12 * c12 + a13 * c13
	if math.abs(det) < 1e-9 then
		return nil, nil, nil
	end
	local c22 = a11 * a33 - a13 * a13
	local c23 = a13 * a12 - a11 * a23
	local c33 = a11 * a22 - a12 * a12
	local inv = 1 / det
	local x = (c11 * b1 + c12 * b2 + c13 * b3) * inv
	local y = (c12 * b1 + c22 * b2 + c23 * b3) * inv
	local z = (c13 * b1 + c23 * b2 + c33 * b3) * inv
	return x, y, z
end

-- ─────────────────────────────────────────────────────────────
-- QEM decimation (Garland-Heckbert edge collapse) — ported from the v1
-- engine, weights stripped. Curvature-preserving: flat regions collapse to a
-- few large triangles while sharp edges/corners survive (high quadric cost +
-- the wouldFlip guard). This is what turns the dense voxel mesh into MINIMAL
-- geometry AND straightens the convergence-corner jaggedness (surviving
-- vertices are repositioned onto the planes/edges that minimise quadric error).
-- ─────────────────────────────────────────────────────────────

type Quadric = { number }

local function quadricFromPlane(nx: number, ny: number, nz: number, d: number): Quadric
	return {
		nx * nx, nx * ny, nx * nz, nx * d,
		ny * ny, ny * nz, ny * d,
		nz * nz, nz * d,
		d * d,
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

local function quadricErrorAt(q: Quadric, x: number, y: number, z: number): number
	return q[1] * x * x + 2 * q[2] * x * y + 2 * q[3] * x * z + 2 * q[4] * x
		+ q[5] * y * y + 2 * q[6] * y * z + 2 * q[7] * y
		+ q[8] * z * z + 2 * q[9] * z
		+ q[10]
end

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

local function decimateQEM(
	verts: { Vector3 },
	tris: { number },
	targetReduction: number,
	maxErrorThreshold: number,
	lengthPenaltyWeight: number,
	maxValence: number
): ({ Vector3 }, { number })
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
		local edge = verts[b] - verts[a]
		cost += lengthPenaltyWeight * edge:Dot(edge)
		local entry = { cost = cost, target = target, lo = a, hi = b }
		edges[a .. "_" .. b] = entry
		heapPush(heap, entry)
	end

	local function postCollapseValence(va: number, vb: number): number
		local seen: { [number]: boolean } = {}
		for _, ti in ipairs(vToTris[va]) do
			if not triActive[ti] then continue end
			local base = (ti - 1) * 3
			for k = 1, 3 do
				local nv = tris[base + k]
				if nv ~= va and nv ~= vb and not vertRemoved[nv] then seen[nv] = true end
			end
		end
		for _, ti in ipairs(vToTris[vb]) do
			if not triActive[ti] then continue end
			local base = (ti - 1) * 3
			for k = 1, 3 do
				local nv = tris[base + k]
				if nv ~= va and nv ~= vb and not vertRemoved[nv] then seen[nv] = true end
			end
		end
		local count = 0
		for _ in pairs(seen) do count += 1 end
		return count
	end

	for ti = 1, nTris do
		if not triActive[ti] then continue end
		local base = (ti - 1) * 3
		evalEdge(tris[base + 1], tris[base + 2])
		evalEdge(tris[base + 2], tris[base + 3])
		evalEdge(tris[base + 3], tris[base + 1])
	end

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
		if edges[key] ~= edge then continue end
		if vertRemoved[edge.lo] or vertRemoved[edge.hi] then continue end
		local va, vb = edge.lo, edge.hi
		local target = edge.target
		if wouldFlip(va, vb, target) then
			edges[key] = nil
			continue
		end
		if postCollapseValence(va, vb) > maxValence then
			edges[key] = nil
			continue
		end
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
		for _, ti in ipairs(vToTris[va]) do
			if not triActive[ti] then continue end
			local base = (ti - 1) * 3
			local p1 = verts[tris[base + 1]]
			local p2 = verts[tris[base + 2]]
			local p3 = verts[tris[base + 3]]
			local n = (p2 - p1):Cross(p3 - p1)
			local m = n.Magnitude
			if m > 1e-9 then faceNormal[ti] = n / m end
		end
		vToTris[va] = merged
		vertRemoved[vb] = true
		local neighbours: { [number]: boolean } = {}
		for _, ti in ipairs(vToTris[va]) do
			local base = (ti - 1) * 3
			for k = 1, 3 do
				local nv = tris[base + k]
				if nv ~= va and not vertRemoved[nv] then neighbours[nv] = true end
			end
		end
		for nv in pairs(neighbours) do
			evalEdge(va, nv)
		end
	end

	local oldToNew = table.create(nVerts)
	local newVerts: { Vector3 } = {}
	for v = 1, nVerts do
		if not vertRemoved[v] then
			table.insert(newVerts, verts[v])
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
	return newVerts, newTris
end

-- ─────────────────────────────────────────────────────────────
-- build
-- ─────────────────────────────────────────────────────────────

function SdfMesher2.build(root: Node, config: Config?): (Output?, string)
	local cfg = config or {}
	local padding = cfg.boundsPadding or 1.5
	local qefBias = cfg.qefBias or 0.06
	-- Small gradient stencil: a large one straddles sharp creases and averages
	-- two facet normals into a bogus one (fake-bevel shading). Keep it tight so
	-- the central difference samples one facet at a time. (Doubles are precise
	-- enough that cancellation isn't a concern at this scale.)
	local normalEpsFrac = cfg.normalEps or 0.12

	local minV, maxV = nodeAABB(root, Vector3.new(SENTINEL, SENTINEL, SENTINEL), Vector3.new(-SENTINEL, -SENTINEL, -SENTINEL))
	if minV.X > maxV.X then
		return nil, "Empty / no primitives"
	end
	minV = minV - Vector3.one * padding
	maxV = maxV + Vector3.one * padding
	local size = maxV - minV
	local maxDim = math.max(size.X, size.Y, size.Z)
	if maxDim < 0.01 then
		return nil, "Bounds too small"
	end

	local cellSize = cfg.cellSize or (maxDim / (cfg.cellsPerDim or 48))
	local eps = normalEpsFrac * cellSize

	local minX, minY, minZ = minV.X, minV.Y, minV.Z
	local nsx = math.ceil(size.X / cellSize) + 1 -- samples per axis
	local nsy = math.ceil(size.Y / cellSize) + 1
	local nsz = math.ceil(size.Z / cellSize) + 1
	local cx, cy, cz = nsx - 1, nsy - 1, nsz - 1 -- cells per axis

	-- Sample the field at every grid corner.
	local sdf = table.create(nsx * nsy * nsz, SENTINEL)
	local function sidx(x: number, y: number, z: number): number
		return 1 + x + nsx * y + nsx * nsy * z
	end
	for z = 0, nsz - 1 do
		local wz = minZ + z * cellSize
		for y = 0, nsy - 1 do
			local wy = minY + y * cellSize
			local base = 1 + nsx * y + nsx * nsy * z
			for x = 0, nsx - 1 do
				sdf[base + x] = evalNode(root, minX + x * cellSize, wy, wz)
			end
		end
	end

	-- Gradient (central differences) → outward normal.
	local function gradAt(wx: number, wy: number, wz: number): (number, number, number)
		local gx = evalNode(root, wx + eps, wy, wz) - evalNode(root, wx - eps, wy, wz)
		local gy = evalNode(root, wx, wy + eps, wz) - evalNode(root, wx, wy - eps, wz)
		local gz = evalNode(root, wx, wy, wz + eps) - evalNode(root, wx, wy, wz - eps)
		local m = math.sqrt(gx * gx + gy * gy + gz * gz)
		if m < 1e-9 then
			return 0, 1, 0
		end
		return gx / m, gy / m, gz / m
	end

	-- Per-cell dual vertex via regularised QEF.
	local cellVert = table.create(cx * cy * cz, 0)
	local function cidx(ix: number, iy: number, iz: number): number
		return 1 + ix + cx * iy + cx * cy * iz
	end
	local verts: { Vector3 } = {}
	local cs = table.create(8, 0)

	for iz = 0, cz - 1 do
		for iy = 0, cy - 1 do
			for ix = 0, cx - 1 do
				-- 8 corner samples
				cs[1] = sdf[sidx(ix, iy, iz)]
				cs[2] = sdf[sidx(ix + 1, iy, iz)]
				cs[3] = sdf[sidx(ix, iy + 1, iz)]
				cs[4] = sdf[sidx(ix + 1, iy + 1, iz)]
				cs[5] = sdf[sidx(ix, iy, iz + 1)]
				cs[6] = sdf[sidx(ix + 1, iy, iz + 1)]
				cs[7] = sdf[sidx(ix, iy + 1, iz + 1)]
				cs[8] = sdf[sidx(ix + 1, iy + 1, iz + 1)]

				local s0 = cs[1] < 0
				local changed = false
				for i = 2, 8 do
					if (cs[i] < 0) ~= s0 then
						changed = true
						break
					end
				end
				if not changed then
					continue
				end

				local cellOX = minX + ix * cellSize
				local cellOY = minY + iy * cellSize
				local cellOZ = minZ + iz * cellSize

				local a11, a12, a13, a22, a23, a33 = 0, 0, 0, 0, 0, 0
				local b1, b2, b3 = 0, 0, 0
				local mx, my, mz, cnt = 0, 0, 0, 0

				for _, e in ipairs(EDGES) do
					local i1, i2 = e[1], e[2]
					local va, vb = cs[i1], cs[i2]
					if (va < 0) ~= (vb < 0) then
						local t = va / (va - vb)
						local p0, p1 = CORNERS[i1], CORNERS[i2]
						local wx = cellOX + (p0.X + (p1.X - p0.X) * t) * cellSize
						local wy = cellOY + (p0.Y + (p1.Y - p0.Y) * t) * cellSize
						local wz = cellOZ + (p0.Z + (p1.Z - p0.Z) * t) * cellSize
						local nx, ny, nz = gradAt(wx, wy, wz)
						local d = nx * wx + ny * wy + nz * wz
						a11 += nx * nx; a12 += nx * ny; a13 += nx * nz
						a22 += ny * ny; a23 += ny * nz; a33 += nz * nz
						b1 += nx * d; b2 += ny * d; b3 += nz * d
						mx += wx; my += wy; mz += wz; cnt += 1
					end
				end

				if cnt == 0 then
					continue
				end
				local imx, imy, imz = mx / cnt, my / cnt, mz / cnt

				-- regularise toward the mass point
				a11 += qefBias; a22 += qefBias; a33 += qefBias
				b1 += qefBias * imx; b2 += qefBias * imy; b3 += qefBias * imz

				local vx, vy, vz = solveSym3(a11, a12, a13, a22, a23, a33, b1, b2, b3)
				if not vx then
					vx, vy, vz = imx, imy, imz
				end
				-- clamp to the cell to avoid QEF spikes
				vx = math.clamp(vx :: number, cellOX, cellOX + cellSize)
				vy = math.clamp(vy :: number, cellOY, cellOY + cellSize)
				vz = math.clamp(vz :: number, cellOZ, cellOZ + cellSize)

				table.insert(verts, Vector3.new(vx, vy, vz))
				cellVert[cidx(ix, iy, iz)] = #verts
			end
		end
	end

	if #verts == 0 then
		return nil, "No surface produced"
	end

	-- Quad stitching: for each interior grid edge with a sign change, connect
	-- the 4 cells sharing it. Winding flips with the edge's sign direction.
	local tris: { number } = {}
	local function quad(va, vb, vc, vd, flip)
		if va == 0 or vb == 0 or vc == 0 or vd == 0 then
			return
		end
		-- Winding: outward-facing (CCW seen from outside). The two branches are
		-- mirror windings; `flip` picks by the edge's sign direction.
		if flip then
			table.insert(tris, va); table.insert(tris, vb); table.insert(tris, vc)
			table.insert(tris, va); table.insert(tris, vc); table.insert(tris, vd)
		else
			table.insert(tris, va); table.insert(tris, vc); table.insert(tris, vb)
			table.insert(tris, va); table.insert(tris, vd); table.insert(tris, vc)
		end
	end

	-- X-edges (sample x→x+1); 4 cells in the YZ plane.
	for z = 1, cz - 1 do
		for y = 1, cy - 1 do
			for x = 0, cx - 1 do
				local va = sdf[sidx(x, y, z)]
				local vb = sdf[sidx(x + 1, y, z)]
				if (va < 0) ~= (vb < 0) then
					quad(
						cellVert[cidx(x, y - 1, z - 1)],
						cellVert[cidx(x, y, z - 1)],
						cellVert[cidx(x, y, z)],
						cellVert[cidx(x, y - 1, z)],
						va < 0
					)
				end
			end
		end
	end
	-- Y-edges (sample y→y+1); 4 cells in the XZ plane.
	for z = 1, cz - 1 do
		for x = 1, cx - 1 do
			for y = 0, cy - 1 do
				local va = sdf[sidx(x, y, z)]
				local vb = sdf[sidx(x, y + 1, z)]
				if (va < 0) ~= (vb < 0) then
					quad(
						cellVert[cidx(x - 1, y, z - 1)],
						cellVert[cidx(x, y, z - 1)],
						cellVert[cidx(x, y, z)],
						cellVert[cidx(x - 1, y, z)],
						not (va < 0)
					)
				end
			end
		end
	end
	-- Z-edges (sample z→z+1); 4 cells in the XY plane.
	for y = 1, cy - 1 do
		for x = 1, cx - 1 do
			for z = 0, cz - 1 do
				local va = sdf[sidx(x, y, z)]
				local vb = sdf[sidx(x, y, z + 1)]
				if (va < 0) ~= (vb < 0) then
					quad(
						cellVert[cidx(x - 1, y - 1, z)],
						cellVert[cidx(x, y - 1, z)],
						cellVert[cidx(x, y, z)],
						cellVert[cidx(x - 1, y, z)],
						va < 0
					)
				end
			end
		end
	end

	-- ── Decimate to minimal geometry (QEM), then build ──
	-- Runs on the buffered tables BEFORE the EditableMesh, so the dense voxel
	-- output never hits the EM triangle cap and the cap effectively applies to
	-- the simplified result. Flat regions collapse to a few large triangles;
	-- sharp edges/corners survive and get straightened.
	if cfg.decimate ~= false then
		-- Default to ERROR-driven minimal geometry: targetReduction 1.0 means
		-- "collapse everything the error gate allows". qemMaxError is then the
		-- real quality knob — flat regions (cost ≈ 0) collapse fully; sharp
		-- edges (high cost) survive. The flip/valence guards keep it manifold.
		local target = cfg.qemTargetReduction or 1.0
		local maxErr = cfg.qemMaxError or (cellSize * cellSize * 3)
		verts, tris = decimateQEM(verts, tris, target, maxErr, cfg.qemLengthPenalty or 0.001, cfg.qemMaxValence or 16)
	end
	if #tris == 0 then
		return nil, "No surface after decimation"
	end

	-- Shading normals on the (decimated) mesh: geometric face normals, a smooth
	-- per-vertex normal = Σ incident face normals, then a per-face-corner split
	-- — smooth where the face agrees with the vertex normal (curves stay
	-- smooth), crisp face normal at hard edges (clean shading discontinuity).
	local triCount = #tris / 3
	local faceN = table.create(triCount)
	local vAdj: { { number } } = table.create(#verts)
	for i = 1, #verts do
		vAdj[i] = {}
	end
	for fi = 1, triCount do
		local base = (fi - 1) * 3
		local i1, i2, i3 = tris[base + 1], tris[base + 2], tris[base + 3]
		local fn = (verts[i2] - verts[i1]):Cross(verts[i3] - verts[i1])
		local m = fn.Magnitude
		faceN[fi] = if m > 1e-9 then fn / m else Vector3.yAxis
		table.insert(vAdj[i1], fi)
		table.insert(vAdj[i2], fi)
		table.insert(vAdj[i3], fi)
	end

	local em = AssetService:CreateEditableMesh()
	local vids = table.create(#verts)
	for i, p in ipairs(verts) do
		vids[i] = em:AddVertex(p)
	end
	local fids = table.create(triCount)
	for i = 1, #tris, 3 do
		fids[(i - 1) / 3 + 1] = em:AddTriangle(vids[tris[i]], vids[tris[i + 1]], vids[tris[i + 2]])
	end

	local colorFn = cfg.vertexColorFn
	local cosSharp = math.cos(math.rad(cfg.sharpAngle or 38))
	for fi = 1, triCount do
		local base = (fi - 1) * 3
		local fn = faceN[fi]
		local fid = fids[fi]
		for k = 1, 3 do
			local vi = tris[base + k]
			-- Smoothing-group normal: average ONLY the incident faces within
			-- `sharpAngle` of THIS face. On a flat/curved region that's all of
			-- them (smooth); across a hard edge the other side is excluded, so
			-- the corner keeps its own face normal (crisp). Comparing to a
			-- global average would miss edges whose halves straddle it.
			local sx, sy, sz = 0, 0, 0
			local maxDiv = 0
			for _, g in ipairs(vAdj[vi]) do
				local ng = faceN[g]
				local dp = fn:Dot(ng)
				if dp >= cosSharp then
					sx += ng.X
					sy += ng.Y
					sz += ng.Z
				end
				local div = 1 - dp
				if div > maxDiv then
					maxDiv = div
				end
			end
			local mm = math.sqrt(sx * sx + sy * sy + sz * sz)
			local nrm = if mm > 1e-6 then Vector3.new(sx / mm, sy / mm, sz / mm) else fn
			em:SetVertexFaceNormal(vids[vi], fid, em:AddNormal(nrm))
			if colorFn then
				em:SetVertexFaceColor(vids[vi], fid, em:AddColor(colorFn(verts[vi], nrm, {}, math.clamp(maxDiv, 0, 1)), 1))
			end
		end
	end

	local Content = (getfenv(1) :: any).Content
	local opts: { [string]: any } = {}
	if cfg.renderFidelity then opts.RenderFidelity = cfg.renderFidelity end
	if cfg.collisionFidelity then opts.CollisionFidelity = cfg.collisionFidelity end
	if cfg.fluidFidelity then opts.FluidFidelity = cfg.fluidFidelity end

	local baked
	local okC, errC = pcall(function()
		local res, content
		if next(opts) then
			res, content = AssetService:CreateDataModelContentAsync(Content.fromObject(em), opts)
		else
			res, content = AssetService:CreateDataModelContentAsync(Content.fromObject(em))
		end
		if res ~= Enum.CreateContentResult.Success then
			error("CreateDataModelContentAsync: " .. tostring(res))
		end
		baked = content
	end)
	em:Destroy()
	if not okC or not baked then
		return nil, "bake content failed: " .. tostring(errC)
	end

	local meshPart
	local okM, errM = pcall(function()
		if next(opts) then
			meshPart = AssetService:CreateMeshPartAsync(baked, opts)
		else
			meshPart = AssetService:CreateMeshPartAsync(baked)
		end
	end)
	if not okM or not meshPart then
		return nil, "CreateMeshPartAsync failed: " .. tostring(errM)
	end
	if cfg.renderFidelity then pcall(function() (meshPart :: any).RenderFidelity = cfg.renderFidelity end) end
	if cfg.collisionFidelity then pcall(function() (meshPart :: any).CollisionFidelity = cfg.collisionFidelity end) end

	return {
		meshPart = meshPart,
		triCount = #tris / 3,
		vertCount = #verts,
		cellSize = cellSize,
		gridDims = Vector3.new(cx, cy, cz),
	}, string.format("%d tris @ %.3f cells", #tris / 3, cellSize)
end

return SdfMesher2

-- ─────────────────────────────────────────────────────────────
-- Op-graph format (examples)
-- ─────────────────────────────────────────────────────────────
-- A sharp box:            { shape="box", semi=Vector3.new(3,3,3) }
-- A hard-beveled box:     { shape="box", semi=Vector3.new(3,3,3), bevel=0.6 }
-- Two blended spheres:    { op="smoothUnion", blend=2, children={
--                             { shape="sphere", center=v1, radius=4 },
--                             { shape="sphere", center=v2, radius=4 } } }
-- Box minus a bore:       { op="subtract", children={
--                             { shape="box", semi=..., bevel=0.4 },
--                             { shape="capsule", a=..., b=..., radius=1 } } }
