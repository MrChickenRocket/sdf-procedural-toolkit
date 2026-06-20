--!strict
-- SdfMesher3 — adaptive octree Dual Contouring (work in progress).
--
-- Where v2 samples a uniform grid (cost ∝ volume) and decimates 99% away, v3
-- builds an OCTREE that only refines near the surface and only where the
-- surface curves. Flat / smooth / low-curvature regions get LARGE leaf cells;
-- tight rounds and features get small ones. The result is clean, minimal
-- geometry produced DIRECTLY (no decimation pass) — ideal for smooth
-- "plastic-toy" shapes, and fast because work scales with surface detail, not
-- volume.
--
-- Pipeline: octree (adaptive subdivide) → one QEF vertex per surface leaf →
-- Dual Contouring polygon recursion (crack-free across leaf sizes) → analytic
-- normals → bake.

local AssetService = game:GetService("AssetService")
local SdfField = require(script.Parent.SdfField)
local SdfDecimate = require(script.Parent.SdfDecimate)

local SdfMesher3 = {}
SdfMesher3.VERSION = "2026-06-20-v3-subdiv-project"

export type Config = {
	minLeaf: number?, -- finest cell (studs); detail floor (default ~ size/64)
	maxLeaf: number?, -- coarsest surface cell (default minLeaf * 8)
	uniform: boolean?, -- force uniform minLeaf surface cells: crisp wave-free curves, slower
	subdivide: number?, -- hero quality: N levels of 1→4 subdivision + surface projection (default 0)
	detailTol: number?, -- subdivide while the field bends from flat by > detailTol*cellSize (default 0.08; lower = finer)
	balance: boolean?, -- 2:1-balance the octree so sharp creases stay clean (default true)
	reproject: boolean?, -- snap final vertices back onto the iso-surface after QEM (default true)
	relaxIters: number?, -- tangential relaxation passes for even tessellation (default 2; 0 = off)
	sharpRelaxAngle: number?, -- pin a vertex from relaxation if its faces diverge past this (deg, default 30)
	featureAngle: number?, -- QEF sharp-snap threshold (deg, default 25)
	qefBias: number?, -- QEF mass-point regularisation (default 0.05)
	boundsPadding: number?,
	cullMargin: number?, -- AABB-cull margin; raise if a large smoothUnion blend gets clipped
	-- decimation (QEM) — turns DC's per-cell quads into minimal geometry
	decimate: boolean?, -- default true
	qemMaxError: number?, -- quality knob; default ~ minLeaf^2 * 3 (higher = fewer tris)
	triCap: number?, -- hard ceiling on output triangles (default 40000)
	vertexColorFn: ((Vector3, Vector3, { [string]: number }, number) -> Color3)?,
	sharpAngle: number?, -- shading: face-corner crisp vs smooth (deg, default 38)
	renderFidelity: Enum.RenderFidelity?,
	collisionFidelity: Enum.CollisionFidelity?,
	fluidFidelity: Enum.FluidFidelity?,
}

local SENTINEL = SdfField.SENTINEL

-- Corner offsets: corner c = (c>>2, (c>>1)&1, c&1) in {0,1}³.
local CORNER = {
	{ 0, 0, 0 }, { 0, 0, 1 }, { 0, 1, 0 }, { 0, 1, 1 },
	{ 1, 0, 0 }, { 1, 0, 1 }, { 1, 1, 0 }, { 1, 1, 1 },
}
-- 12 edges as corner-index pairs (0-based corners), grouped by axis (x,y,z).
local EDGEV = {
	{ 0, 4 }, { 1, 5 }, { 2, 6 }, { 3, 7 }, -- x
	{ 0, 2 }, { 1, 3 }, { 4, 6 }, { 5, 7 }, -- y
	{ 0, 1 }, { 2, 3 }, { 4, 5 }, { 6, 7 }, -- z
}

-- ── 3x3 symmetric solve (for QEF) ──
local function solveSym3(a11, a12, a13, a22, a23, a33, b1, b2, b3): (number?, number?, number?)
	local c11 = a22 * a33 - a23 * a23
	local c12 = a13 * a23 - a12 * a33
	local c13 = a12 * a23 - a13 * a22
	local det = a11 * c11 + a12 * c12 + a13 * c13
	if math.abs(det) < 1e-10 then
		return nil, nil, nil
	end
	local c22 = a11 * a33 - a13 * a13
	local c23 = a13 * a12 - a11 * a23
	local c33 = a11 * a22 - a12 * a12
	local inv = 1 / det
	return (c11 * b1 + c12 * b2 + c13 * b3) * inv,
		(c12 * b1 + c22 * b2 + c23 * b3) * inv,
		(c13 * b1 + c23 * b2 + c33 * b3) * inv
end

type Cell = {
	x: number,
	y: number,
	z: number,
	size: number,
	leaf: boolean,
	children: { Cell }?,
	corner: { number }, -- 8 sdf values at corners
	corners: number, -- 8-bit mask: bit c set if corner c is solid (sdf < 0)
	vid: number?, -- index into verts (nil if no surface)
}

function SdfMesher3.build(root: SdfField.Node, config: Config?): (any, string)
	local cfg = config or {}
	local field = function(x, y, z)
		return SdfField.field(root, x, y, z)
	end
	local grad = function(x, y, z)
		local _, gx, gy, gz = SdfField.fieldGrad(root, x, y, z)
		return gx, gy, gz
	end

	local minV, maxV = SdfField.aabb(root)
	if minV.X > maxV.X then
		return nil, "empty"
	end
	-- Stamp AABB cull boxes so multi-primitive graphs don't evaluate every leaf
	-- at every sample. Margin must cover any smoothUnion bulge past the raw boxes.
	local cullMargin = math.max(cfg.boundsPadding or 1.0, (cfg.cullMargin or 0))
	SdfField.prepare(root, cullMargin)
	local pad = cfg.boundsPadding or 1.0
	minV = minV - Vector3.one * pad
	maxV = maxV + Vector3.one * pad
	local span = maxV - minV
	local maxDim = math.max(span.X, span.Y, span.Z)
	-- Cubic octree root covering the (padded) AABB, centred on it.
	local cx = (minV.X + maxV.X) * 0.5
	local cy = (minV.Y + maxV.Y) * 0.5
	local cz = (minV.Z + maxV.Z) * 0.5
	local rootSize = maxDim
	local ox, oy, oz = cx - rootSize * 0.5, cy - rootSize * 0.5, cz - rootSize * 0.5

	local minLeaf = cfg.minLeaf or (maxDim / 64)
	-- `uniform` forces every surface cell to minLeaf (even vertex spacing → crisp,
	-- wave-free curves, at the cost of v3's adaptive speed). Otherwise surface
	-- cells coarsen up to maxLeaf away from detail.
	local maxLeaf = cfg.maxLeaf or (minLeaf * (if cfg.uniform then 1 else 8))
	local detailTol = cfg.detailTol or 0.08
	local cosFeature = math.cos(math.rad(cfg.featureAngle or 25))
	local qefBias = cfg.qefBias or 0.05

	local verts: { Vector3 } = {}
	local tSample0 = os.clock()
	local leafCount, internalCount = 0, 0

	-- Sample field at the 8 corners of a cell.
	local function sampleCorners(x, y, z, size): { number }
		local c = table.create(8)
		for i = 1, 8 do
			local o = CORNER[i]
			c[i] = field(x + o[1] * size, y + o[2] * size, z + o[3] * size)
		end
		return c
	end

	-- Adaptive subdivision.
	local function buildCell(x, y, z, size, corner): Cell
		-- "near surface": a corner sign-changes, or the surface is within reach.
		local s0 = corner[1] < 0
		local mixed = false
		local minAbs = math.huge
		local cmask = 0
		for i = 1, 8 do
			if corner[i] < 0 then
				cmask += bit32.lshift(1, i - 1)
				if i > 1 and not s0 then mixed = true end
			elseif i > 1 and s0 then
				mixed = true
			end
			local a = if corner[i] < 0 then -corner[i] else corner[i]
			if a < minAbs then minAbs = a end
		end
		local diag = size * 1.7320508
		local near = mixed or (minAbs < diag)

		local subdivide = false
		if size > minLeaf + 1e-9 then
			if not near then
				-- empty cell: keep coarse but cap so the octree root doesn't stay huge
				subdivide = size > maxLeaf * 4
			elseif size > maxLeaf then
				subdivide = true -- cap surface-cell size
			else
				-- Detail test: how far the field bends from a flat (trilinear) fit
				-- across the cell. The cell centre's trilinear prediction is just
				-- the mean of the 8 corners; compare to the actual centre value.
				-- ~0 on flat faces (stay coarse), spikes on curves & sharp creases
				-- (subdivide). One field eval — vs 8 gradient evals before.
				local sum = corner[1] + corner[2] + corner[3] + corner[4]
					+ corner[5] + corner[6] + corner[7] + corner[8]
				local predicted = sum * 0.125
				local actual = field(x + size * 0.5, y + size * 0.5, z + size * 0.5)
				local dev = actual - predicted
				if dev < 0 then dev = -dev end
				subdivide = dev > detailTol * size
			end
		end

		if not subdivide then
			leafCount += 1
			return { x = x, y = y, z = z, size = size, leaf = true, corner = corner, corners = cmask }
		end

		internalCount += 1
		local h = size * 0.5
		local children = table.create(8)
		for i = 1, 8 do
			local o = CORNER[i]
			local cxn, cyn, czn = x + o[1] * h, y + o[2] * h, z + o[3] * h
			children[i] = buildCell(cxn, cyn, czn, h, sampleCorners(cxn, cyn, czn, h))
		end
		return { x = x, y = y, z = z, size = size, leaf = false, children = children, corner = corner, corners = cmask }
	end

	local rootCell = buildCell(ox, oy, oz, rootSize, sampleCorners(ox, oy, oz, rootSize))

	-- ── 2:1 balance ──
	-- Restrict the octree so no leaf has a face-neighbour more than one level
	-- finer. Without this, a coarse flat-face cell sitting next to fine crease
	-- cells places its dual vertex far from theirs → wavy creases / corner
	-- spikes on hard chamfers. Balancing grades the transition (clean creases)
	-- while leaving flat interiors coarse (still fast). Smooth shapes rarely
	-- trigger it; sharp/bevelled ones do.
	if cfg.balance ~= false then
		local function cmaskOf(corner: { number }): number
			local m = 0
			for i = 1, 8 do
				if corner[i] < 0 then m += bit32.lshift(1, i - 1) end
			end
			return m
		end
		local function splitLeaf(cell: Cell)
			local h = cell.size * 0.5
			local children = table.create(8)
			for i = 1, 8 do
				local o = CORNER[i]
				local cxn, cyn, czn = cell.x + o[1] * h, cell.y + o[2] * h, cell.z + o[3] * h
				local cc = sampleCorners(cxn, cyn, czn, h)
				children[i] = { x = cxn, y = cyn, z = czn, size = h, leaf = true, corner = cc, corners = cmaskOf(cc) }
				leafCount += 1
			end
			cell.leaf = false
			cell.children = children
			leafCount -= 1
			internalCount += 1
		end
		local function findLeaf(px: number, py: number, pz: number): Cell
			local node = rootCell
			while not node.leaf do
				local h = node.size * 0.5
				local cx = if px >= node.x + h then 1 else 0
				local cy = if py >= node.y + h then 1 else 0
				local cz = if pz >= node.z + h then 1 else 0
				node = (node.children :: { Cell })[1 + 4 * cx + 2 * cy + cz]
			end
			return node
		end
		local function collect(node: Cell, out: { Cell })
			if node.leaf then
				table.insert(out, node)
			else
				for _, c in ipairs(node.children :: { Cell }) do
					collect(c, out)
				end
			end
		end
		local rx1, ry1, rz1 = ox + rootSize, oy + rootSize, oz + rootSize
		local eps = minLeaf * 0.25
		for _ = 1, 12 do
			local leaves: { Cell } = {}
			collect(rootCell, leaves)
			local toSplit: { Cell } = {}
			for _, lf in ipairs(leaves) do
				if lf.size > minLeaf * 1.5 then
					local s = lf.size
					local s2 = s * 0.5
					-- one sample per face (centre). A 4:1 neighbour is ¼ the
					-- face, so the centre lands in it; iteration cleans up the
					-- rest. Cheap: ≤6 point-locations per leaf per pass.
					local pts = {
						{ lf.x - eps, lf.y + s2, lf.z + s2 },
						{ lf.x + s + eps, lf.y + s2, lf.z + s2 },
						{ lf.x + s2, lf.y - eps, lf.z + s2 },
						{ lf.x + s2, lf.y + s + eps, lf.z + s2 },
						{ lf.x + s2, lf.y + s2, lf.z - eps },
						{ lf.x + s2, lf.y + s2, lf.z + s + eps },
					}
					local finer = false
					for _, p in ipairs(pts) do
						if p[1] > ox and p[1] < rx1 and p[2] > oy and p[2] < ry1 and p[3] > oz and p[3] < rz1 then
							if findLeaf(p[1], p[2], p[3]).size < s * 0.5 - 1e-6 then
								finer = true
								break
							end
						end
					end
					if finer then
						table.insert(toSplit, lf)
					end
				end
			end
			if #toSplit == 0 then
				break
			end
			for _, lf in ipairs(toSplit) do
				splitLeaf(lf)
			end
		end
	end
	local tSample1 = os.clock()

	-- ── Per-leaf QEF vertex ──
	local function makeVertex(cell: Cell)
		local corner = cell.corner
		local s0 = corner[1] < 0
		local changed = false
		for i = 2, 8 do
			if (corner[i] < 0) ~= s0 then changed = true break end
		end
		if not changed then
			return
		end
		local x, y, z, size = cell.x, cell.y, cell.z, cell.size
		local a11, a12, a13, a22, a23, a33 = 0, 0, 0, 0, 0, 0
		local b1, b2, b3 = 0, 0, 0
		local mx, my, mz, cnt = 0, 0, 0, 0
		local n0x, n0y, n0z, minDot = 0, 0, 0, 1
		for _, e in ipairs(EDGEV) do
			local i1, i2 = e[1] + 1, e[2] + 1
			local va, vb = corner[i1], corner[i2]
			if (va < 0) ~= (vb < 0) then
				local t = va / (va - vb)
				local o1, o2 = CORNER[i1], CORNER[i2]
				local wx = x + (o1[1] + (o2[1] - o1[1]) * t) * size
				local wy = y + (o1[2] + (o2[2] - o1[2]) * t) * size
				local wz = z + (o1[3] + (o2[3] - o1[3]) * t) * size
				local gx, gy, gz = grad(wx, wy, wz)
				if cnt == 0 then
					n0x, n0y, n0z = gx, gy, gz
				else
					local dp = gx * n0x + gy * n0y + gz * n0z
					if dp < minDot then minDot = dp end
				end
				local d = gx * wx + gy * wy + gz * wz
				a11 += gx * gx; a12 += gx * gy; a13 += gx * gz
				a22 += gy * gy; a23 += gy * gz; a33 += gz * gz
				b1 += gx * d; b2 += gy * d; b3 += gz * d
				mx += wx; my += wy; mz += wz; cnt += 1
			end
		end
		if cnt == 0 then
			return
		end
		local imx, imy, imz = mx / cnt, my / cnt, mz / cnt
		local vx, vy, vz
		if minDot >= cosFeature then
			-- Smooth cell: project the mass point onto the iso-surface (one Newton
			-- step). The raw mass point sits inside a convex surface by a chord
			-- error that grows with cell size, so mixed-resolution curved regions
			-- (from adaptivity + the balance pass) get differential inset and
			-- barrel/wave. Projecting onto field=0 removes that — the vertex lands
			-- on the true surface no matter the cell size.
			local d, gx, gy, gz = SdfField.fieldGrad(root, imx, imy, imz)
			if math.abs(d) > size then
				vx, vy, vz = imx, imy, imz
			else
				vx, vy, vz = imx - d * gx, imy - d * gy, imz - d * gz
			end
		else
			a11 += qefBias; a22 += qefBias; a33 += qefBias
			b1 += qefBias * imx; b2 += qefBias * imy; b3 += qefBias * imz
			vx, vy, vz = solveSym3(a11, a12, a13, a22, a23, a33, b1, b2, b3)
			if not vx then
				vx, vy, vz = imx, imy, imz
			end
			vx = math.clamp(vx :: number, x, x + size)
			vy = math.clamp(vy :: number, y, y + size)
			vz = math.clamp(vz :: number, z, z + size)
		end
		table.insert(verts, Vector3.new(vx, vy, vz))
		cell.vid = #verts
	end

	local function assignVerts(cell: Cell)
		if cell.leaf then
			makeVertex(cell)
		else
			for _, ch in ipairs(cell.children :: { Cell }) do
				assignVerts(ch)
			end
		end
	end
	assignVerts(rootCell)
	local tQef1 = os.clock()

	-- ── Dual Contouring polygon recursion (Ju et al. 2002) ──
	-- Verbatim canonical traversal tables + recursion. A quad is emitted on each
	-- "minimal edge" with a sign change, connecting the 4 surrounding leaves'
	-- vertices. Leaves are reused as they're descended past, so different leaf
	-- sizes stitch crack-free. Tables are 0-based; +1 to index Lua child arrays.
	local tris: { number } = {}

	local cellProcFaceMask = {
		{ 0, 4, 0 }, { 1, 5, 0 }, { 2, 6, 0 }, { 3, 7, 0 }, { 0, 2, 1 }, { 4, 6, 1 },
		{ 1, 3, 1 }, { 5, 7, 1 }, { 0, 1, 2 }, { 2, 3, 2 }, { 4, 5, 2 }, { 6, 7, 2 },
	}
	local cellProcEdgeMask = {
		{ 0, 1, 2, 3, 0 }, { 4, 5, 6, 7, 0 }, { 0, 4, 1, 5, 1 },
		{ 2, 6, 3, 7, 1 }, { 0, 2, 4, 6, 2 }, { 1, 3, 5, 7, 2 },
	}
	local faceProcFaceMask = {
		{ { 4, 0, 0 }, { 5, 1, 0 }, { 6, 2, 0 }, { 7, 3, 0 } },
		{ { 2, 0, 1 }, { 6, 4, 1 }, { 3, 1, 1 }, { 7, 5, 1 } },
		{ { 1, 0, 2 }, { 3, 2, 2 }, { 5, 4, 2 }, { 7, 6, 2 } },
	}
	local faceProcEdgeMask = {
		{ { 1, 4, 0, 5, 1, 1 }, { 1, 6, 2, 7, 3, 1 }, { 0, 4, 6, 0, 2, 2 }, { 0, 5, 7, 1, 3, 2 } },
		{ { 0, 2, 3, 0, 1, 0 }, { 0, 6, 7, 4, 5, 0 }, { 1, 2, 0, 6, 4, 2 }, { 1, 3, 1, 7, 5, 2 } },
		{ { 1, 1, 0, 3, 2, 0 }, { 1, 5, 4, 7, 6, 0 }, { 0, 1, 5, 0, 4, 1 }, { 0, 3, 7, 2, 6, 1 } },
	}
	local edgeProcEdgeMask = {
		{ { 3, 2, 1, 0, 0 }, { 7, 6, 5, 4, 0 } },
		{ { 5, 1, 4, 0, 1 }, { 7, 3, 6, 2, 1 } },
		{ { 6, 4, 2, 0, 2 }, { 7, 5, 3, 1, 2 } },
	}
	local processEdgeMask = { { 3, 2, 1, 0 }, { 7, 5, 6, 4 }, { 11, 10, 9, 8 } }
	local ORDERS = { { 0, 0, 1, 1 }, { 0, 1, 0, 1 } }

	local function processEdge(nodes: { Cell }, dir: number)
		local minSize = math.huge
		local minIndex = 1
		local flip = false
		local scMin = false
		local pem = processEdgeMask[dir + 1]
		for i = 1, 4 do
			local ev = EDGEV[pem[i] + 1]
			local cm = nodes[i].corners
			local m1 = bit32.band(bit32.rshift(cm, ev[1]), 1)
			local m2 = bit32.band(bit32.rshift(cm, ev[2]), 1)
			if nodes[i].size < minSize then
				minSize = nodes[i].size
				minIndex = i
				flip = m1 ~= 0
				scMin = m1 ~= m2
			end
		end
		if not scMin then
			return
		end
		local a, b, c, d = nodes[1].vid, nodes[2].vid, nodes[3].vid, nodes[4].vid
		if not (a and b and c and d) then
			return
		end
		if not flip then
			table.insert(tris, a); table.insert(tris, b); table.insert(tris, d)
			table.insert(tris, a); table.insert(tris, d); table.insert(tris, c)
		else
			table.insert(tris, a); table.insert(tris, d); table.insert(tris, b)
			table.insert(tris, a); table.insert(tris, c); table.insert(tris, d)
		end
	end

	local edgeProc
	edgeProc = function(nodes: { Cell }, dir: number)
		if not (nodes[1] and nodes[2] and nodes[3] and nodes[4]) then
			return
		end
		if nodes[1].leaf and nodes[2].leaf and nodes[3].leaf and nodes[4].leaf then
			processEdge(nodes, dir)
			return
		end
		local mask = edgeProcEdgeMask[dir + 1]
		for i = 1, 2 do
			local m = mask[i]
			local en = table.create(4)
			for j = 1, 4 do
				local nj = nodes[j]
				en[j] = if nj.leaf then nj else (nj.children :: { Cell })[m[j] + 1]
			end
			edgeProc(en, m[5])
		end
	end

	local faceProc
	faceProc = function(a: Cell, b: Cell, dir: number)
		if not (a and b) then
			return
		end
		if a.leaf and b.leaf then
			return
		end
		local sel = { a, b }
		local fm = faceProcFaceMask[dir + 1]
		for i = 1, 4 do
			local m = fm[i]
			local f0 = if a.leaf then a else (a.children :: { Cell })[m[1] + 1]
			local f1 = if b.leaf then b else (b.children :: { Cell })[m[2] + 1]
			faceProc(f0, f1, m[3])
		end
		local fem = faceProcEdgeMask[dir + 1]
		for i = 1, 4 do
			local m = fem[i]
			local order = ORDERS[m[1] + 1]
			local en = table.create(4)
			for j = 1, 4 do
				local nj = sel[order[j] + 1]
				en[j] = if nj.leaf then nj else (nj.children :: { Cell })[m[j + 1] + 1]
			end
			edgeProc(en, m[6])
		end
	end

	local function cellProc(cell: Cell)
		if cell.leaf then
			return
		end
		local ch = cell.children :: { Cell }
		for i = 1, 8 do
			cellProc(ch[i])
		end
		for i = 1, 12 do
			local m = cellProcFaceMask[i]
			faceProc(ch[m[1] + 1], ch[m[2] + 1], m[3])
		end
		for i = 1, 6 do
			local m = cellProcEdgeMask[i]
			edgeProc({ ch[m[1] + 1], ch[m[2] + 1], ch[m[3] + 1], ch[m[4] + 1] }, m[5])
		end
	end

	cellProc(rootCell)
	local tDC1 = os.clock()

	if #verts == 0 or #tris == 0 then
		return nil, "no surface"
	end
	local rawTris = #tris / 3

	-- ── Decimate (QEM) — collapse DC's coplanar/curved cell quads to minimal
	-- geometry while preserving sharp edges. Cheap here: v3's adaptive raw mesh
	-- is already far smaller than a uniform grid's, so QEM has little to chew. ──
	if cfg.decimate ~= false then
		local maxErr = cfg.qemMaxError or (minLeaf * minLeaf * 3)
		local cap = cfg.triCap or 40000
		verts, tris = SdfDecimate.decimateQEM(verts, tris, 1.0, maxErr, 0.0, 14, cap)

		-- Reproject onto the iso-surface. QEM places each collapsed vertex at the
		-- quadric-optimal point — the intersection of its incident planes — which
		-- on a curved surface lies *off* it, re-introducing the chord inset that
		-- barrels/waves curves. One Newton step snaps every vertex back onto
		-- field = 0. Sharp-feature vertices already sit at field ≈ 0 (they're on
		-- the surface), so this barely moves them; the clamp skips any outlier.
		if cfg.reproject ~= false then
			local clamp = maxLeaf
			for i = 1, #verts do
				local v = verts[i]
				local d, gx, gy, gz = SdfField.fieldGrad(root, v.X, v.Y, v.Z)
				if d > -clamp and d < clamp then
					verts[i] = Vector3.new(v.X - d * gx, v.Y - d * gy, v.Z - d * gz)
				end
			end
		end

		-- Tangential relaxation with flip-prevention. Dual Contouring's vertex
		-- spacing is uneven → smooth surfaces show a "wave" under shading and the
		-- triangulation looks questionable. Slide each smooth vertex along the
		-- surface toward its neighbour centroid (tangent-plane move + reproject)
		-- to even the spacing. Crucially, each proposed move is REJECTED if it
		-- would flip an incident triangle — that's what dented/holed the earlier
		-- attempts (folded geometry). Sharp vertices (incident faces diverge past
		-- sharpRelaxAngle) are pinned so edges/creases survive.
		local relaxIters = cfg.relaxIters or 0
		if relaxIters > 0 and #verts > 0 then
			local nV = #verts
			local nT = #tris // 3
			local adj: { { [number]: boolean } } = table.create(nV)
			local vTris: { { number } } = table.create(nV)
			for i = 1, nV do
				adj[i] = {}
				vTris[i] = {}
			end
			local refN: { Vector3 } = table.create(nV)
			local sharp = table.create(nV, false)
			local cosRelax = math.cos(math.rad(cfg.sharpRelaxAngle or 30))
			local fnx = table.create(nT)
			local fny = table.create(nT)
			local fnz = table.create(nT)
			for t = 1, nT do
				local b = (t - 1) * 3
				local i1, i2, i3 = tris[b + 1], tris[b + 2], tris[b + 3]
				local p1, p2, p3 = verts[i1], verts[i2], verts[i3]
				local fn = (p2 - p1):Cross(p3 - p1)
				local m = fn.Magnitude
				fn = if m > 1e-9 then fn / m else Vector3.yAxis
				fnx[t], fny[t], fnz[t] = fn.X, fn.Y, fn.Z
				local tri = { i1, i2, i3 }
				for _, vi in ipairs(tri) do
					local rn = refN[vi]
					if rn == nil then
						refN[vi] = fn
					elseif fn:Dot(rn) < cosRelax then
						sharp[vi] = true
					end
					table.insert(vTris[vi], t)
				end
				adj[i1][i2] = true; adj[i1][i3] = true
				adj[i2][i1] = true; adj[i2][i3] = true
				adj[i3][i1] = true; adj[i3][i2] = true
			end
			local clamp = maxLeaf
			for _ = 1, relaxIters do
				for i = 1, nV do
					if not sharp[i] then
						local v = verts[i]
						local cx, cy, cz, c = 0, 0, 0, 0
						for nb in pairs(adj[i]) do
							local p = verts[nb]
							cx += p.X; cy += p.Y; cz += p.Z; c += 1
						end
						if c > 0 then
							-- tangent-plane move toward centroid, then reproject
							local _, gx, gy, gz = SdfField.fieldGrad(root, v.X, v.Y, v.Z)
							local dx, dy, dz = cx / c - v.X, cy / c - v.Y, cz / c - v.Z
							local dn = dx * gx + dy * gy + dz * gz
							dx -= dn * gx; dy -= dn * gy; dz -= dn * gz
							local tx, ty, tz = v.X + dx * 0.5, v.Y + dy * 0.5, v.Z + dz * 0.5
							local d, rgx, rgy, rgz = SdfField.fieldGrad(root, tx, ty, tz)
							local nvx, nvy, nvz
							if d > -clamp and d < clamp then
								nvx, nvy, nvz = tx - d * rgx, ty - d * rgy, tz - d * rgz
							else
								nvx, nvy, nvz = tx, ty, tz
							end
							-- reject if any incident triangle would flip
							local flip = false
							for _, t in ipairs(vTris[i]) do
								local b = (t - 1) * 3
								local a1, a2, a3 = tris[b + 1], tris[b + 2], tris[b + 3]
								local q1 = if a1 == i then Vector3.new(nvx, nvy, nvz) else verts[a1]
								local q2 = if a2 == i then Vector3.new(nvx, nvy, nvz) else verts[a2]
								local q3 = if a3 == i then Vector3.new(nvx, nvy, nvz) else verts[a3]
								local nn = (q2 - q1):Cross(q3 - q1)
								if nn.X * fnx[t] + nn.Y * fny[t] + nn.Z * fnz[t] <= 0 then
									flip = true
									break
								end
							end
							if not flip then
								verts[i] = Vector3.new(nvx, nvy, nvz)
								for _, t in ipairs(vTris[i]) do
									local b = (t - 1) * 3
									local p1, p2, p3 = verts[tris[b + 1]], verts[tris[b + 2]], verts[tris[b + 3]]
									local fn = (p2 - p1):Cross(p3 - p1)
									local m = fn.Magnitude
									if m > 1e-9 then
										fn /= m
										fnx[t], fny[t], fnz[t] = fn.X, fn.Y, fn.Z
									end
								end
							end
						end
					end
				end
			end
		end
	end
	local tDecim1 = os.clock()

	-- ── Subdivide + project (hero quality) ──
	-- Loop-style 1→4 split, with each new edge-midpoint projected onto the
	-- iso-surface. On a CURVED edge the midpoint bulges out to the true surface
	-- (the chord becomes an arc → smooth curves & silhouettes); on a flat or
	-- crease edge field≈0 at the midpoint so it doesn't move (flats stay flat,
	-- creases stay sharp). Reliable — unlike relaxation it can't fold. Best on a
	-- uniform base (even spacing in, even + smooth out). Cost is ~linear in tris.
	local subdiv = cfg.subdivide or 0
	for _ = 1, subdiv do
		local nT = #tris // 3
		local midOf: { [number]: number } = {}
		local newTris: { number } = table.create(#tris * 4)
		local function midVert(a: number, b: number): number
			local lo, hi = a, b
			if lo > hi then lo, hi = hi, lo end
			local key = lo * 33554432 + hi
			local mi = midOf[key]
			if mi then return mi end
			local pa, pb = verts[lo], verts[hi]
			local mx, my, mz = (pa.X + pb.X) * 0.5, (pa.Y + pb.Y) * 0.5, (pa.Z + pb.Z) * 0.5
			local d, gx, gy, gz = SdfField.fieldGrad(root, mx, my, mz)
			local lim = (pb - pa).Magnitude * 0.5 -- never project further than half the edge (no sheet jumps)
			if d > -lim and d < lim then
				mx, my, mz = mx - d * gx, my - d * gy, mz - d * gz
			end
			table.insert(verts, Vector3.new(mx, my, mz))
			mi = #verts
			midOf[key] = mi
			return mi
		end
		for t = 1, nT do
			local b = (t - 1) * 3
			local a1, a2, a3 = tris[b + 1], tris[b + 2], tris[b + 3]
			local m12 = midVert(a1, a2)
			local m23 = midVert(a2, a3)
			local m31 = midVert(a3, a1)
			newTris[#newTris + 1] = a1; newTris[#newTris + 1] = m12; newTris[#newTris + 1] = m31
			newTris[#newTris + 1] = m12; newTris[#newTris + 1] = a2; newTris[#newTris + 1] = m23
			newTris[#newTris + 1] = m31; newTris[#newTris + 1] = m23; newTris[#newTris + 1] = a3
			newTris[#newTris + 1] = m12; newTris[#newTris + 1] = m23; newTris[#newTris + 1] = m31
		end
		tris = newTris
	end

	-- ── Normals (analytic, split at hard edges) + bake ──
	local triCount = #tris / 3
	local faceN = table.create(triCount)
	for fi = 1, triCount do
		local base = (fi - 1) * 3
		local fn = (verts[tris[base + 2]] - verts[tris[base + 1]]):Cross(verts[tris[base + 3]] - verts[tris[base + 1]])
		local m = fn.Magnitude
		faceN[fi] = if m > 1e-9 then fn / m else Vector3.yAxis
	end
	local vN = table.create(#verts)
	for i = 1, #verts do
		local v = verts[i]
		local gx, gy, gz = grad(v.X, v.Y, v.Z)
		vN[i] = Vector3.new(gx, gy, gz)
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
			local an = vN[vi]
			local dp = fn:Dot(an)
			local nrm = if dp >= cosSharp then an else fn
			em:SetVertexFaceNormal(vids[vi], fid, em:AddNormal(nrm))
			if colorFn then
				em:SetVertexFaceColor(vids[vi], fid, em:AddColor(colorFn(verts[vi], nrm, {}, math.clamp(1 - dp, 0, 1)), 1))
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
			error("content: " .. tostring(res))
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
		return nil, "meshpart failed: " .. tostring(errM)
	end
	if cfg.renderFidelity then pcall(function() (meshPart :: any).RenderFidelity = cfg.renderFidelity end) end
	if cfg.collisionFidelity then pcall(function() (meshPart :: any).CollisionFidelity = cfg.collisionFidelity end) end

	print(string.format(
		"[SdfMesher3] leaves %d | %d→%d tris | octree %.0fms qef %.0fms dc %.0fms decimate %.0fms bake %.0fms total %.0fms",
		leafCount, rawTris, triCount,
		(tSample1 - tSample0) * 1000, (tQef1 - tSample1) * 1000, (tDC1 - tQef1) * 1000,
		(tDecim1 - tDC1) * 1000, (os.clock() - tDecim1) * 1000, (os.clock() - tSample0) * 1000
	))

	return {
		meshPart = meshPart,
		triCount = triCount,
		vertCount = #verts,
		rawTris = rawTris,
		leafCount = leafCount,
		timings = {
			octree = tSample1 - tSample0,
			qef = tQef1 - tSample1,
			dc = tDC1 - tQef1,
			decimate = tDecim1 - tDC1,
			total = os.clock() - tSample0,
		},
	}, string.format("%d tris", triCount)
end

return SdfMesher3
