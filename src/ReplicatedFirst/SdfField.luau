--!strict
-- SdfField — the shared signed-distance field for the v2/v3 meshers.
--
-- An "op-graph" of primitive leaves under CSG operators (union / smoothUnion /
-- subtract / intersect). This module only EVALUATES the field: distance,
-- analytic gradient (exact outward normal), and the world AABB. The meshers
-- (SdfMesher2 = uniform surface-nets+QEM; SdfMesher3 = adaptive octree DC)
-- consume it. Lifted verbatim from SdfMesher2's internals so behaviour matches.
--
-- Node format (plain tables):
--   leaves: { shape = "sphere"|"ellipsoid"|"box"|"capsule"|"cylinder", ... }
--     sphere    : center, radius
--     ellipsoid : center, semi
--     box       : center|cframe, semi, rounding?, bevel?   (sharp by default)
--     capsule   : a, b, radius
--     cylinder  : center|cframe, radius, height, rounding?, bevel?
--   ops:    { op = "union"|"smoothUnion"|"subtract"|"intersect", blend?, children = {...} }

local SdfField = {}

export type Node = {
	shape: string?,
	center: Vector3?,
	radius: number?,
	semi: Vector3?,
	cframe: CFrame?,
	rounding: number?,
	bevel: number?,
	height: number?,
	a: Vector3?,
	b: Vector3?,
	op: string?,
	blend: number?,
	children: { Node }?,
	_lo: Vector3?, -- AABB cull box (stamped by prepare); optional
	_hi: Vector3?,
}

local SENTINEL = 1e6

-- ── Primitive SDFs ──────────────────────────────────────────────

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

local function boxSDF(lx, ly, lz, sx, sy, sz, rounding, bevel): number
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

local function cylinderSDF(lx, ly, lz, R, h, rounding, bevel): number
	local r = math.sqrt(lx * lx + lz * lz)
	local ay = if ly >= 0 then ly else -ly
	if bevel and bevel > 0 then
		local dr, dy = r - R, ay - h
		local drp = if dr > 0 then dr else 0
		local dyp = if dy > 0 then dy else 0
		local d = math.min(if dr > dy then dr else dy, 0) + math.sqrt(drp * drp + dyp * dyp)
		local edge = (dr + dy + bevel) * 0.70710678
		return if edge > d then edge else d
	elseif rounding and rounding > 0 then
		local dr, dy = r - (R - rounding), ay - (h - rounding)
		local drp = if dr > 0 then dr else 0
		local dyp = if dy > 0 then dy else 0
		return math.min(if dr > dy then dr else dy, 0) + math.sqrt(drp * drp + dyp * dyp) - rounding
	end
	local dr, dy = r - R, ay - h
	local drp = if dr > 0 then dr else 0
	local dyp = if dy > 0 then dy else 0
	return math.min(if dr > dy then dr else dy, 0) + math.sqrt(drp * drp + dyp * dyp)
end

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

-- ── Field value ────────────────────────────────────────────────

local function evalNode(node: Node, px: number, py: number, pz: number): number
	-- AABB cull: outside a node's margin-expanded box, SENTINEL is correct in
	-- every op context (min won't pick it, subtract won't carve, intersect is
	-- outside) and skips the whole subtree.
	local lo = node._lo
	if lo then
		local hi = node._hi :: Vector3
		if px < lo.X or px > hi.X or py < lo.Y or py > hi.Y or pz < lo.Z or pz > hi.Z then
			return SENTINEL
		end
	end
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
			local R = node.radius or 1
			local h = (node.height or 2) * 0.5
			local cf = node.cframe or CFrame.new(node.center or Vector3.zero)
			local lp = cf:PointToObjectSpace(Vector3.new(px, py, pz))
			return cylinderSDF(lp.X, lp.Y, lp.Z, R, h, node.rounding, node.bevel)
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

-- ── Analytic gradient (exact outward normal) ───────────────────

local function boxGradDir(qx, qy, qz, sgx, sgy, sgz): (number, number, number)
	if qx > 0 or qy > 0 or qz > 0 then
		local gx = (if qx > 0 then qx else 0) * sgx
		local gy = (if qy > 0 then qy else 0) * sgy
		local gz = (if qz > 0 then qz else 0) * sgz
		local m = math.sqrt(gx * gx + gy * gy + gz * gz)
		if m < 1e-9 then return sgx, 0, 0 end
		return gx / m, gy / m, gz / m
	elseif qx >= qy and qx >= qz then
		return sgx, 0, 0
	elseif qy >= qz then
		return 0, sgy, 0
	else
		return 0, 0, sgz
	end
end

local function cappedGrad2(dr: number, dy: number): (number, number)
	if dr > 0 or dy > 0 then
		local a = if dr > 0 then dr else 0
		local b = if dy > 0 then dy else 0
		local m = math.sqrt(a * a + b * b)
		if m < 1e-9 then return 1, 0 end
		return a / m, b / m
	elseif dr >= dy then
		return 1, 0
	else
		return 0, 1
	end
end

local function boxLocalGrad(lx, ly, lz, sx, sy, sz, rounding, bevel): (number, number, number, number)
	local sgx = if lx >= 0 then 1 else -1
	local sgy = if ly >= 0 then 1 else -1
	local sgz = if lz >= 0 then 1 else -1
	local ax, ay, az = lx * sgx, ly * sgy, lz * sgz
	if bevel and bevel > 0 then
		local qx, qy, qz = ax - sx, ay - sy, az - sz
		local qxp = if qx > 0 then qx else 0
		local qyp = if qy > 0 then qy else 0
		local qzp = if qz > 0 then qz else 0
		local outside = math.sqrt(qxp * qxp + qyp * qyp + qzp * qzp)
		local mYZ = if qy > qz then qy else qz
		local mQ = if qx > mYZ then qx else mYZ
		local inside = if mQ < 0 then mQ else 0
		local d, which = outside + inside, 0
		local exy = (qx + qy + bevel) * 0.70710678
		local eyz = (qy + qz + bevel) * 0.70710678
		local exz = (qx + qz + bevel) * 0.70710678
		if exy > d then d, which = exy, 1 end
		if eyz > d then d, which = eyz, 2 end
		if exz > d then d, which = exz, 3 end
		local s = 0.70710678
		if which == 1 then
			return d, sgx * s, sgy * s, 0
		elseif which == 2 then
			return d, 0, sgy * s, sgz * s
		elseif which == 3 then
			return d, sgx * s, 0, sgz * s
		end
		local gx, gy, gz = boxGradDir(qx, qy, qz, sgx, sgy, sgz)
		return d, gx, gy, gz
	elseif rounding and rounding > 0 then
		local qx, qy, qz = ax - sx + rounding, ay - sy + rounding, az - sz + rounding
		local qxp = if qx > 0 then qx else 0
		local qyp = if qy > 0 then qy else 0
		local qzp = if qz > 0 then qz else 0
		local outside = math.sqrt(qxp * qxp + qyp * qyp + qzp * qzp)
		local mYZ = if qy > qz then qy else qz
		local mQ = if qx > mYZ then qx else mYZ
		local inside = if mQ < 0 then mQ else 0
		local gx, gy, gz = boxGradDir(qx, qy, qz, sgx, sgy, sgz)
		return outside + inside - rounding, gx, gy, gz
	end
	local qx, qy, qz = ax - sx, ay - sy, az - sz
	local qxp = if qx > 0 then qx else 0
	local qyp = if qy > 0 then qy else 0
	local qzp = if qz > 0 then qz else 0
	local outside = math.sqrt(qxp * qxp + qyp * qyp + qzp * qzp)
	local mYZ = if qy > qz then qy else qz
	local mQ = if qx > mYZ then qx else mYZ
	local inside = if mQ < 0 then mQ else 0
	local gx, gy, gz = boxGradDir(qx, qy, qz, sgx, sgy, sgz)
	return outside + inside, gx, gy, gz
end

local function cylLocalGrad(lx, ly, lz, R, h, rounding, bevel): (number, number, number, number)
	local r = math.sqrt(lx * lx + lz * lz)
	local sgy = if ly >= 0 then 1 else -1
	local ruX, ruZ = 1, 0
	if r > 1e-9 then
		ruX, ruZ = lx / r, lz / r
	end
	local ay = ly * sgy
	local d, gr, gay
	if bevel and bevel > 0 then
		local dr, dy = r - R, ay - h
		local op = if dr > 0 then dr else 0
		local oq = if dy > 0 then dy else 0
		local cd = math.min(if dr > dy then dr else dy, 0) + math.sqrt(op * op + oq * oq)
		local edge = (dr + dy + bevel) * 0.70710678
		if edge > cd then
			d, gr, gay = edge, 0.70710678, 0.70710678
		else
			d, gr, gay = cd, cappedGrad2(dr, dy)
		end
	elseif rounding and rounding > 0 then
		local dr, dy = r - (R - rounding), ay - (h - rounding)
		local op = if dr > 0 then dr else 0
		local oq = if dy > 0 then dy else 0
		d = math.min(if dr > dy then dr else dy, 0) + math.sqrt(op * op + oq * oq) - rounding
		gr, gay = cappedGrad2(dr, dy)
	else
		local dr, dy = r - R, ay - h
		local op = if dr > 0 then dr else 0
		local oq = if dy > 0 then dy else 0
		d = math.min(if dr > dy then dr else dy, 0) + math.sqrt(op * op + oq * oq)
		gr, gay = cappedGrad2(dr, dy)
	end
	local gx, gz = gr * ruX, gr * ruZ
	local gyy = gay * sgy
	local m = math.sqrt(gx * gx + gyy * gyy + gz * gz)
	if m < 1e-9 then
		return d, 0, 1, 0
	end
	return d, gx / m, gyy / m, gz / m
end

local function evalNodeGrad(node: Node, px: number, py: number, pz: number): (number, number, number, number)
	local lo = node._lo
	if lo then
		local hi = node._hi :: Vector3
		if px < lo.X or px > hi.X or py < lo.Y or py > hi.Y or pz < lo.Z or pz > hi.Z then
			return SENTINEL, 0, 1, 0
		end
	end
	local shape = node.shape
	if shape then
		if shape == "sphere" then
			local c = node.center or Vector3.zero
			local dx, dy, dz = px - c.X, py - c.Y, pz - c.Z
			local len = math.sqrt(dx * dx + dy * dy + dz * dz)
			if len > 1e-9 then
				return len - (node.radius or 1), dx / len, dy / len, dz / len
			end
			return len - (node.radius or 1), 0, 1, 0
		elseif shape == "ellipsoid" then
			local c = node.center or Vector3.zero
			local s = node.semi or Vector3.one
			local ex, ey, ez = px - c.X, py - c.Y, pz - c.Z
			local d = ellipsoidSDF(ex, ey, ez, s.X, s.Y, s.Z)
			local gx, gy, gz = ex / (s.X * s.X), ey / (s.Y * s.Y), ez / (s.Z * s.Z)
			local m = math.sqrt(gx * gx + gy * gy + gz * gz)
			if m > 1e-9 then
				return d, gx / m, gy / m, gz / m
			end
			return d, 0, 1, 0
		elseif shape == "box" then
			local s = node.semi or Vector3.one
			if node.cframe then
				local lp = node.cframe:PointToObjectSpace(Vector3.new(px, py, pz))
				local d, gx, gy, gz = boxLocalGrad(lp.X, lp.Y, lp.Z, s.X, s.Y, s.Z, node.rounding, node.bevel)
				local gw = node.cframe:VectorToWorldSpace(Vector3.new(gx, gy, gz))
				return d, gw.X, gw.Y, gw.Z
			end
			local c = node.center or Vector3.zero
			return boxLocalGrad(px - c.X, py - c.Y, pz - c.Z, s.X, s.Y, s.Z, node.rounding, node.bevel)
		elseif shape == "capsule" then
			local a = node.a or Vector3.zero
			local b = node.b or Vector3.zero
			local pax, pay, paz = px - a.X, py - a.Y, pz - a.Z
			local bax, bay, baz = b.X - a.X, b.Y - a.Y, b.Z - a.Z
			local l2 = bax * bax + bay * bay + baz * baz
			local hh = if l2 > 1e-10 then math.clamp((pax * bax + pay * bay + paz * baz) / l2, 0, 1) else 0
			local dx, dy, dz = pax - bax * hh, pay - bay * hh, paz - baz * hh
			local len = math.sqrt(dx * dx + dy * dy + dz * dz)
			if len > 1e-9 then
				return len - (node.radius or 1), dx / len, dy / len, dz / len
			end
			return len - (node.radius or 1), 0, 1, 0
		elseif shape == "cylinder" then
			local R = node.radius or 1
			local h = (node.height or 2) * 0.5
			local cf = node.cframe or CFrame.new(node.center or Vector3.zero)
			local lp = cf:PointToObjectSpace(Vector3.new(px, py, pz))
			local d, gx, gy, gz = cylLocalGrad(lp.X, lp.Y, lp.Z, R, h, node.rounding, node.bevel)
			local gw = cf:VectorToWorldSpace(Vector3.new(gx, gy, gz))
			return d, gw.X, gw.Y, gw.Z
		end
		error("unknown shape: " .. tostring(shape))
	end
	local op = node.op
	local ch = node.children or {}
	if op == "union" then
		local bd, bx, by, bz = SENTINEL, 0, 1, 0
		for _, c in ipairs(ch) do
			local d, gx, gy, gz = evalNodeGrad(c, px, py, pz)
			if d < bd then bd, bx, by, bz = d, gx, gy, gz end
		end
		return bd, bx, by, bz
	elseif op == "smoothUnion" then
		local k = node.blend or 0
		local first = true
		local bd, bx, by, bz = SENTINEL, 0, 1, 0
		for _, c in ipairs(ch) do
			local d, gx, gy, gz = evalNodeGrad(c, px, py, pz)
			if first then
				bd, bx, by, bz, first = d, gx, gy, gz, false
			elseif k <= 0 or math.abs(bd - d) >= k then
				if d < bd then bd, bx, by, bz = d, gx, gy, gz end
			else
				local diff = bd - d
				local hh = 1 - math.abs(diff) / k
				local mn = if bd < d then bd else d
				local mix = math.clamp(0.5 + 0.5 * diff / k, 0, 1)
				local nx = bx * (1 - mix) + gx * mix
				local ny = by * (1 - mix) + gy * mix
				local nz = bz * (1 - mix) + gz * mix
				local m = math.sqrt(nx * nx + ny * ny + nz * nz)
				if m < 1e-9 then m = 1 end
				bd, bx, by, bz = mn - hh * hh * k * 0.25, nx / m, ny / m, nz / m
			end
		end
		return bd, bx, by, bz
	elseif op == "subtract" then
		local d, gx, gy, gz = if ch[1] then evalNodeGrad(ch[1], px, py, pz) else SENTINEL, 0, 1, 0
		for i = 2, #ch do
			local dc, cx, cy, cz = evalNodeGrad(ch[i], px, py, pz)
			if -dc > d then d, gx, gy, gz = -dc, -cx, -cy, -cz end
		end
		return d, gx, gy, gz
	elseif op == "intersect" then
		local bd, bx, by, bz = -SENTINEL, 0, 1, 0
		for _, c in ipairs(ch) do
			local d, gx, gy, gz = evalNodeGrad(c, px, py, pz)
			if d > bd then bd, bx, by, bz = d, gx, gy, gz end
		end
		return bd, bx, by, bz
	end
	error("unknown op: " .. tostring(op))
end

-- ── AABB (per-leaf box; per-node cull boxes) ───────────────────

-- Tight axis-aligned box of a single primitive leaf.
local function shapeBox(node: Node): (Vector3, Vector3)
	local shape = node.shape
	if shape == "sphere" then
		local c = node.center or Vector3.zero
		local r = Vector3.one * (node.radius or 1)
		return c - r, c + r
	elseif shape == "ellipsoid" then
		local c = node.center or Vector3.zero
		local s = node.semi or Vector3.one
		return c - s, c + s
	elseif shape == "box" or shape == "cylinder" then
		local s
		if shape == "box" then
			s = node.semi or Vector3.one
		else
			local R = node.radius or 1
			s = Vector3.new(R, (node.height or 2) * 0.5, R)
		end
		-- a bevel/rounding never grows the box, so semi is the conservative half-extent
		local cf = node.cframe or CFrame.new(node.center or Vector3.zero)
		local rr, u, f = cf.RightVector, cf.UpVector, -cf.LookVector
		local ext = Vector3.new(
			math.abs(rr.X) * s.X + math.abs(u.X) * s.Y + math.abs(f.X) * s.Z,
			math.abs(rr.Y) * s.X + math.abs(u.Y) * s.Y + math.abs(f.Y) * s.Z,
			math.abs(rr.Z) * s.X + math.abs(u.Z) * s.Y + math.abs(f.Z) * s.Z
		)
		return cf.Position - ext, cf.Position + ext
	elseif shape == "capsule" then
		local a, b = node.a or Vector3.zero, node.b or Vector3.zero
		local r = Vector3.one * (node.radius or 1)
		local lo = Vector3.new(math.min(a.X, b.X), math.min(a.Y, b.Y), math.min(a.Z, b.Z))
		local hi = Vector3.new(math.max(a.X, b.X), math.max(a.Y, b.Y), math.max(a.Z, b.Z))
		return lo - r, hi + r
	end
	error("shapeBox: unknown shape " .. tostring(shape))
end

-- Tight bounds of the whole graph (no stamping — pure read).
local function tightAABB(node: Node, lo: Vector3, hi: Vector3): (Vector3, Vector3)
	if node.shape then
		local l, h = shapeBox(node)
		return Vector3.new(math.min(lo.X, l.X), math.min(lo.Y, l.Y), math.min(lo.Z, l.Z)),
			Vector3.new(math.max(hi.X, h.X), math.max(hi.Y, h.Y), math.max(hi.Z, h.Z))
	end
	for _, c in ipairs(node.children or {}) do
		lo, hi = tightAABB(c, lo, hi)
	end
	return lo, hi
end

-- Stamp _lo/_hi on every node (margin-expanded) and return the node's box.
-- A node's box is the union of its children's (already-expanded) boxes — so a
-- sample outside it is outside the whole subtree.
local function stampAABB(node: Node, margin: Vector3): (Vector3, Vector3)
	if node.shape then
		local lo, hi = shapeBox(node)
		lo, hi = lo - margin, hi + margin
		node._lo, node._hi = lo, hi
		return lo, hi
	end
	local lo = Vector3.new(SENTINEL, SENTINEL, SENTINEL)
	local hi = Vector3.new(-SENTINEL, -SENTINEL, -SENTINEL)
	for _, c in ipairs(node.children or {}) do
		local cl, ch = stampAABB(c, margin)
		lo = Vector3.new(math.min(lo.X, cl.X), math.min(lo.Y, cl.Y), math.min(lo.Z, cl.Z))
		hi = Vector3.new(math.max(hi.X, ch.X), math.max(hi.Y, ch.Y), math.max(hi.Z, ch.Z))
	end
	node._lo, node._hi = lo, hi
	return lo, hi
end

-- ── Public API ─────────────────────────────────────────────────

SdfField.SENTINEL = SENTINEL

function SdfField.field(root: Node, x: number, y: number, z: number): number
	return evalNode(root, x, y, z)
end

-- distance + outward unit normal
function SdfField.fieldGrad(root: Node, x: number, y: number, z: number): (number, number, number, number)
	return evalNodeGrad(root, x, y, z)
end

-- Stamp AABB cull boxes. `margin` (studs) must cover any surface bulge past the
-- raw primitive boxes — i.e. the largest smoothUnion blend plus a cell or two.
-- Call once before meshing; cheap (one pass over the graph).
function SdfField.prepare(root: Node, margin: number?)
	local m = Vector3.one * (margin or 1)
	stampAABB(root, m)
end

function SdfField.aabb(root: Node): (Vector3, Vector3)
	return tightAABB(root, Vector3.new(SENTINEL, SENTINEL, SENTINEL), Vector3.new(-SENTINEL, -SENTINEL, -SENTINEL))
end

return SdfField
