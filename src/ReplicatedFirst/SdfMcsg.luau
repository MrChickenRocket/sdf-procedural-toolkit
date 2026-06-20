--!strict
-- SdfMcsg — import MagicaCSG (.mcsg) text models into v3 op-graphs.
--
-- MagicaCSG saves a JSON-ish text format (quoted values, no commas, // line
-- comments, no top-level braces). A model is a list of `object`s, each pointing
-- at a `csg` group — a flat list of parametric SDF primitives that smooth-union
-- (per-prim `blend`) or `sub`tract to form the shape, under `r` (3×3 rotation)
-- `t` (translate) `s` (per-axis half-extent) transforms.
--
-- This is a BEST-EFFORT importer: cube / cylinder / sphere map cleanly to our
-- box / cylinder / ellipsoid (with round%/bevel%). The exotic parametric types
-- (polygon, triangle, jt, bezier, bpoly, nested csg) are skipped for now and
-- counted in `.skipped` so you know what's missing.
--
--   local SdfMcsg = require(game.ReplicatedFirst.SdfMcsg)
--   local parsed = SdfMcsg.parse(text)
--   local graphs = SdfMcsg.toGraphs(parsed, { scale = 1/30 })  -- {name,graph,color}[]
--   for _, g in ipairs(graphs) do SdfMesher3.build(g.graph, {...}) end

local SdfMcsg = {}

-- ── Tolerant tokenizer + parser ────────────────────────────────

local function tokenize(s: string): { any }
	local toks: { any } = {}
	local i, n = 1, #s
	while i <= n do
		local c = string.sub(s, i, i)
		if c == " " or c == "\t" or c == "\r" or c == "\n" then
			i += 1
		elseif c == "/" and string.sub(s, i + 1, i + 1) == "/" then
			-- line comment
			local nl = string.find(s, "\n", i, true)
			i = if nl then nl + 1 else n + 1
		elseif c == "{" or c == "}" or c == "[" or c == "]" or c == ":" then
			table.insert(toks, c)
			i += 1
		elseif c == '"' then
			local j = string.find(s, '"', i + 1, true) or (n + 1)
			table.insert(toks, { str = string.sub(s, i + 1, j - 1) })
			i = j + 1
		else
			i += 1 -- skip stray chars (commas etc.)
		end
	end
	return toks
end

function SdfMcsg.parse(text: string): any
	local toks = tokenize(text)
	local pos = 1
	local function peek()
		return toks[pos]
	end
	local parseValue

	local function parseObject(): any
		local obj: { [string]: any } = {}
		pos += 1 -- consume {
		while peek() ~= nil and peek() ~= "}" do
			local key = peek()
			if type(key) == "table" then
				pos += 1
				if peek() == ":" then pos += 1 end
				obj[key.str] = parseValue()
			else
				pos += 1 -- skip unexpected
			end
		end
		pos += 1 -- consume }
		return obj
	end

	local function parseArray(): any
		local arr: { any } = {}
		pos += 1 -- consume [
		while peek() ~= nil and peek() ~= "]" do
			table.insert(arr, parseValue())
		end
		pos += 1 -- consume ]
		return arr
	end

	parseValue = function(): any
		local t = peek()
		if t == "{" then
			return parseObject()
		elseif t == "[" then
			return parseArray()
		elseif type(t) == "table" then
			pos += 1
			return t.str
		else
			pos += 1 -- stray punct
			return nil
		end
	end

	-- top level: sequence of "key" : value
	local top: { [string]: any } = {}
	while peek() ~= nil do
		local key = peek()
		if type(key) == "table" then
			pos += 1
			if peek() == ":" then pos += 1 end
			top[key.str] = parseValue()
		else
			pos += 1
		end
	end
	return top
end

-- ── Helpers ────────────────────────────────────────────────────

local function nums(s: string?): { number }
	local out = {}
	if s then
		for w in string.gmatch(s, "[^%s]+") do
			table.insert(out, tonumber(w) or 0)
		end
	end
	return out
end

local function vec(s: string?, default: Vector3?): Vector3
	local a = nums(s)
	if #a >= 3 then
		return Vector3.new(a[1], a[2], a[3])
	end
	return default or Vector3.zero
end

-- r is a 3×3 matrix, 9 numbers. MagicaCSG uses the row-vector convention
-- (world = local · M), so the world axes that local X/Y/Z map to are the ROWS.
local function axes(s: string?): (Vector3, Vector3, Vector3)
	local m = nums(s)
	if #m < 9 then
		return Vector3.xAxis, Vector3.yAxis, Vector3.zAxis
	end
	return Vector3.new(m[1], m[2], m[3]), Vector3.new(m[4], m[5], m[6]), Vector3.new(m[7], m[8], m[9])
end

local function pct(p: any): number
	return tonumber(p) or 0
end

-- ── Primitive → op-graph node ──────────────────────────────────

-- `scale` shrinks MagicaCSG's ~hundreds-of-units world to studs. `flipY`
-- swaps the up axis (MagicaCSG is Z-up; Roblox is Y-up).
local function primToNode(p: any, base: CFrame, scale: number): any?
	local ty = p.type
	if ty ~= "cube" and ty ~= "cylinder" and ty ~= "sphere" then
		return nil -- exotic type, skip
	end
	local s = vec(p.s, Vector3.one)
	local xa, ya, za = axes(p.r)
	local t = vec(p.t) * scale
	local cf = base * CFrame.fromMatrix(t, xa, ya, za)
	local semi = s * scale
	if ty == "sphere" then
		return { shape = "ellipsoid", center = cf.Position, semi = semi }
	elseif ty == "cube" then
		local mn = math.min(semi.X, semi.Y, semi.Z)
		local node: any = { shape = "box", cframe = cf, semi = semi }
		local bevel = pct(p["bevel%"]) * mn
		local round = pct(p["round%"]) * mn
		if bevel > 0 then
			node.bevel = bevel
		elseif round > 0 then
			node.rounding = round
		end
		return node
	else -- cylinder: MagicaCSG axis = local Z, radius = s.x, half-height = s.z
		local cyl = CFrame.fromMatrix(cf.Position, cf.RightVector, cf.LookVector * -1) -- up := local Z
		local node: any = { shape = "cylinder", cframe = cyl, radius = semi.X, height = semi.Z * 2 }
		local mn = math.min(semi.X, semi.Z)
		local bevel = pct(p["bevel%"]) * mn
		local round = pct(p["round%"]) * mn
		if bevel > 0 then
			node.bevel = bevel
		elseif round > 0 then
			node.rounding = round
		end
		return node
	end
end

export type GraphEntry = { name: string, graph: any, color: Color3, prims: number }

-- Build one op-graph per object. Adds smooth-union left-to-right by each prim's
-- `blend`; `mode == "sub"` prims subtract (hard) at the end.
function SdfMcsg.toGraphs(parsed: any, opts: { scale: number?, flipY: boolean? }?): ({ GraphEntry }, { [string]: number })
	local o = opts or {}
	local scale = o.scale or (1 / 30)
	local objects = parsed.object or {}
	local csg = parsed.csg or {}
	local out: { GraphEntry } = {}
	local skipped: { [string]: number } = {}

	-- MagicaCSG is Z-up; Roblox is Y-up. Map (x,y,z) → (x, z, -y): local X→X,
	-- local Y→-Z, local Z→Y. (CFrame.fromMatrix columns = images of X,Y,Z.)
	local worldCF = if o.flipY ~= false
		then CFrame.fromMatrix(Vector3.zero, Vector3.new(1, 0, 0), Vector3.new(0, 0, -1), Vector3.new(0, 1, 0))
		else CFrame.identity

	for oi, obj in ipairs(objects) do
		local cid = (tonumber(obj.cid) or (oi - 1)) + 1
		local group = csg[cid]
		if type(group) ~= "table" then
			continue
		end
		local oxa, oya, oza = axes(obj.r)
		local objCF = worldCF * CFrame.fromMatrix(vec(obj.t) * scale, oxa, oya, oza)

		local adds: { any } = {}
		local addBlend: { number } = {}
		local subs: { any } = {}
		for _, p in ipairs(group) do
			if type(p) ~= "table" then continue end
			local node = primToNode(p, objCF, scale)
			if not node then
				skipped[p.type or "?"] = (skipped[p.type or "?"] or 0) + 1
				continue
			end
			if p.mode == "sub" then
				table.insert(subs, node)
			else
				table.insert(adds, node)
				table.insert(addBlend, (tonumber(p.blend) or 0) * scale)
			end
		end
		if #adds == 0 then
			continue
		end
		-- left-fold smooth-union with per-prim blend
		local acc = adds[1]
		for i = 2, #adds do
			acc = { op = "smoothUnion", blend = addBlend[i], children = { acc, adds[i] } }
		end
		local graph = acc
		if #subs > 0 then
			local children = { acc }
			for _, sNode in ipairs(subs) do
				table.insert(children, sNode)
			end
			graph = { op = "subtract", children = children }
		end

		local rgb = nums(obj.color or (group[1] and group[1].rgb))
		local color = if #rgb >= 3 then Color3.fromRGB(rgb[1], rgb[2], rgb[3]) else Color3.fromRGB(180, 180, 185)
		table.insert(out, {
			name = obj.name or ("object" .. oi),
			graph = graph,
			color = color,
			prims = #adds + #subs,
		})
	end
	return out, skipped
end

return SdfMcsg
