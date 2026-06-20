--!strict
-- SdfDecimate — Garland-Heckbert QEM edge-collapse decimation.
--
-- Lifted from SdfMesher2 so v3 (adaptive octree DC) can reuse it. v3's raw mesh
-- is already an order of magnitude smaller than v2's uniform grid, so running
-- QEM on it is cheap — and it's what turns DC's "one quad per surface cell"
-- output into genuinely minimal geometry (coplanar faces collapse, sharp edges
-- survive and straighten).
--
-- decimateQEM(verts, tris, targetReduction, maxError, lengthPenalty, maxValence,
--             hardCap) -> (newVerts, newTris)

local SdfDecimate = {}

type Quadric = { number } -- 10 coeffs: a11 a12 a13 a14 a22 a23 a24 a33 a34 a44

local function quadricFromPlane(nx: number, ny: number, nz: number, d: number): Quadric
	return {
		nx * nx, nx * ny, nx * nz, nx * d,
		ny * ny, ny * nz, ny * d,
		nz * nz, nz * d,
		d * d,
	}
end

local function quadricErrorAt(q: Quadric, x: number, y: number, z: number): number
	return q[1] * x * x + 2 * q[2] * x * y + 2 * q[3] * x * z + 2 * q[4] * x
		+ q[5] * y * y + 2 * q[6] * y * z + 2 * q[7] * y
		+ q[8] * z * z + 2 * q[9] * z
		+ q[10]
end

local function quadricOptimalSum(qa: Quadric, qb: Quadric, fallback: Vector3): (Vector3, number)
	local a11 = qa[1] + qb[1]
	local a12 = qa[2] + qb[2]
	local a13 = qa[3] + qb[3]
	local a22 = qa[5] + qb[5]
	local a23 = qa[6] + qb[6]
	local a33 = qa[8] + qb[8]
	local q4 = qa[4] + qb[4]
	local q7 = qa[7] + qb[7]
	local q9 = qa[9] + qb[9]
	local q10 = qa[10] + qb[10]
	local m11 = a22 * a33 - a23 * a23
	local m12 = a13 * a23 - a12 * a33
	local m13 = a12 * a23 - a13 * a22
	local det = a11 * m11 + a12 * m12 + a13 * m13
	local x, y, z
	if math.abs(det) < 1e-12 then
		x, y, z = fallback.X, fallback.Y, fallback.Z
	else
		local m22 = a11 * a33 - a13 * a13
		local m23 = a12 * a13 - a11 * a23
		local m33 = a11 * a22 - a12 * a12
		local invDet = 1 / det
		x = invDet * (m11 * -q4 + m12 * -q7 + m13 * -q9)
		y = invDet * (m12 * -q4 + m22 * -q7 + m23 * -q9)
		z = invDet * (m13 * -q4 + m23 * -q7 + m33 * -q9)
	end
	local cost = a11 * x * x + 2 * a12 * x * y + 2 * a13 * x * z + 2 * q4 * x
		+ a22 * y * y + 2 * a23 * y * z + 2 * q7 * y
		+ a33 * z * z + 2 * q9 * z
		+ q10
	return Vector3.new(x, y, z), cost
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

function SdfDecimate.decimateQEM(
	verts: { Vector3 },
	tris: { number },
	targetReduction: number,
	maxErrorThreshold: number,
	lengthPenaltyWeight: number,
	maxValence: number,
	hardCap: number
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
			local qa, qb, qc = Q[a], Q[b], Q[c]
			for qi = 1, 10 do
				local qv = q[qi]
				qa[qi] += qv
				qb[qi] += qv
				qc[qi] += qv
			end
		else
			faceNormal[ti] = Vector3.zero
			triActive[ti] = false
		end
		table.insert(vToTris[a], ti)
		table.insert(vToTris[b], ti)
		table.insert(vToTris[c], ti)
	end

	local vertRemoved = table.create(nVerts, false)
	local edges: { [number]: any } = {}
	local heap: { any } = {}

	local function evalEdge(a: number, b: number)
		if a == b then return end
		if a > b then a, b = b, a end
		if vertRemoved[a] or vertRemoved[b] then return end
		local fallback = (verts[a] + verts[b]) * 0.5
		local target, cost = quadricOptimalSum(Q[a], Q[b], fallback)
		local edge = verts[b] - verts[a]
		cost += lengthPenaltyWeight * edge:Dot(edge)
		local entry = { cost = cost, target = target, lo = a, hi = b }
		edges[a * 16777216 + b] = entry
		heapPush(heap, entry)
	end

	local pcvSeen: { [number]: boolean } = {}
	local function postCollapseValence(va: number, vb: number): number
		local seen = pcvSeen
		table.clear(seen)
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
		if edge.cost > maxErrorThreshold and liveTri <= hardCap then break end
		local key = edge.lo * 16777216 + edge.hi
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
		local qva, qvb = Q[va], Q[vb]
		for qi = 1, 10 do
			qva[qi] += qvb[qi]
		end
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

return SdfDecimate
