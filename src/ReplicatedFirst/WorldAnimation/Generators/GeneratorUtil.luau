--!strict
-- Shared helpers for the garden/park ProceduralModel generators.
-- Kept deliberately small — just snow-sprinkle helpers and mesh mount.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local SdfMesher = require(script.Parent.Parent.Parent.SdfMesher)

local GeneratorUtil = {}

-- Global snow coverage scalar. Lives at
-- ReplicatedStorage.WorldSettings.SnowAmount as a 0..1 number (0 = no
-- snow, 1 = full coverage). Replaces the per-PM GenerateWithSnow boolean
-- so seasonal/climate changes can flip the world from one place. Returns
-- 1 if WorldSettings is missing, so old scenes keep working.
function GeneratorUtil.getSnowAmount(): number
	local ws = ReplicatedStorage:FindFirstChild("WorldSettings")
	if not ws then return 1 end
	local v = ws:GetAttribute("SnowAmount")
	if typeof(v) == "number" then
		return math.clamp(v, 0, 1)
	end
	return 1
end

-- Global leaf coverage scalar at WorldSettings.LeafAmount (0..1, default 1).
-- Linear shrink: 0 = bare trees, 1 = full canopy. Generators that consume
-- this typically multiply their foliage radii by it. Returns 1 if missing
-- so old scenes keep their default leafy look.
function GeneratorUtil.getLeafAmount(): number
	local ws = ReplicatedStorage:FindFirstChild("WorldSettings")
	if not ws then return 1 end
	local v = ws:GetAttribute("LeafAmount")
	if typeof(v) == "number" then
		return math.clamp(v, 0, 1)
	end
	return 1
end

-- Probabilistic thinning: each blob is kept with probability `amount`.
-- Used to scale snow coverage with WorldSettings.SnowAmount. Seeded by
-- the generator's own seed so the same PM thins to the same blobs each
-- bake (no flicker on regen). 0 returns empty, 1 returns input unchanged.
function GeneratorUtil.thinSnow(snowEllipsoids: { any }, amount: number, seed: number?): { any }
	if amount >= 1 then return snowEllipsoids end
	if amount <= 0 then return {} end
	local rng = Random.new(seed or 1)
	local out = {}
	for _, e in ipairs(snowEllipsoids) do
		if rng:NextNumber() < amount then
			table.insert(out, e)
		end
	end
	return out
end

-- Resolve a generator color attribute. The PM's color "attributes" are
-- now strings naming an entry on ReplicatedStorage.Palettes.<generatorName>
-- (a Configuration whose attributes are Color3s). Lets us recolor every
-- placed instance from a single Configuration. Falls back to the in-code
-- default if the palette / attribute is missing, or if the value passed
-- in is already a Color3 (legacy data on placed PMs that pre-dates the
-- string switch — they keep working until someone wipes the override).
function GeneratorUtil.resolveColor(generatorName: string, value: any, fallback: Color3): Color3
	if typeof(value) == "Color3" then
		return value
	end
	if typeof(value) ~= "string" or #value == 0 then
		return fallback
	end
	local palettes = ReplicatedStorage:FindFirstChild("Palettes")
	if not palettes then return fallback end
	local config = palettes:FindFirstChild(generatorName)
	if not config then return fallback end
	local resolved = config:GetAttribute(value)
	if typeof(resolved) == "Color3" then
		return resolved
	end
	return fallback
end

-- Flattened snow domes on top of each source ellipsoid. Returns a new
-- ellipsoid list ready to append to the bake input.
function GeneratorUtil.snowOnEllipsoids(
	ellipsoids: { any },
	opts: { radiusMul: number?, flatness: number?, offsetMul: number? }?
): { any }
	opts = opts or {}
	local rMul = opts.radiusMul or 0.72
	local flat = opts.flatness or 0.40
	local offMul = opts.offsetMul or 0.55
	local out = {}
	for _, e in ipairs(ellipsoids) do
		local r = (e.semi.X + e.semi.Z) * 0.5 * rMul
		table.insert(out, {
			center = e.center + Vector3.new(0, e.semi.Y * offMul, 0),
			semi = Vector3.new(r, r * flat, r),
		})
	end
	return out
end

-- Snow beads riding the upward-facing side of each non-vertical capsule.
function GeneratorUtil.snowOnCapsules(
	capsules: { any },
	opts: { radiusMul: number?, flatness: number?, verticalityFloor: number? }?
): { any }
	opts = opts or {}
	local rMul = opts.radiusMul or 0.5
	local flat = opts.flatness or 0.40
	local floor = opts.verticalityFloor or 0.20
	local out = {}
	for _, cap in ipairs(capsules) do
		local diff = cap.b - cap.a
		local len = diff.Magnitude
		if len < 0.1 then continue end
		local dir = diff / len
		local tan = Vector3.new(-dir.X * dir.Y, 1 - dir.Y * dir.Y, -dir.Z * dir.Y)
		local tanMag = tan.Magnitude
		if tanMag < floor then continue end
		tan = tan / tanMag
		local r = cap.radius * rMul
		local ry = r * flat
		local offset = cap.radius * 0.75
		local spacing = math.max(r * 0.7, 0.3)
		local n = math.max(1, math.floor(len / spacing))
		for i = 0, n do
			local t = i / n
			local c = cap.a + diff * t + tan * offset
			table.insert(out, {
				center = c,
				semi = Vector3.new(r, ry, r),
			})
		end
	end
	return out
end

-- Coat the upward-facing parts of a built SDF surface with snow blobs
-- by sphere-tracing downward at a regular grid spacing in XZ. Each ray
-- that hits the surface drops a flattened ellipsoid (oval sphere) at
-- the hit point, oriented so its bottom kisses the surface. Steep /
-- vertical / underside surfaces fail the normal-Y threshold and stay
-- bare, so the result follows the actual sloped silhouette of carved
-- shapes (rocks, fences, terrain) instead of just sitting on top of
-- the source primitives like the legacy snowOnEllipsoids does.
--
-- `input` is the same table you'd hand to SdfMesher.build — same
-- ellipsoids/slabs/capsules/subtracts. The snow blobs returned can be
-- fed straight to bakeSnow.
function GeneratorUtil.snowOnSurface(
	input: any,
	opts: {
		ballRadius: number?, -- horizontal half-extent of each snow oval
		flatness: number?, -- vertical / horizontal radius ratio (< 1 = squashed)
		gridSpacing: number?, -- XZ grid step. Smaller = denser coverage
		jitter: number?, -- per-sample random XZ jitter as a fraction of gridSpacing
		minNormalY: number?, -- reject surfaces whose normal.Y is below this
		maxRayDist: number?, -- cap on sphere-trace length
		startMargin: number?, -- studs above the bounds top to start each ray
		-- Fraction (0..1) of footprint samples that must hit the surface
		-- within ±ballRadius of the center hit's Y for the blob to count
		-- as resting on rock. Higher = stricter, kills blobs that hang
		-- over edges. 1.0 = fully supported only; 0.6–0.8 = some
		-- tolerance for natural corners.
		supportThreshold: number?,
		-- Number of XZ directions sampled at radius ballR around each
		-- center hit when checking footprint support.
		supportSamples: number?,
		seed: number?,
	}?
): { any }
	opts = opts or {}
	local ballRadius = opts.ballRadius or 0.6
	local flatness = opts.flatness or 0.35
	local gridSpacing = opts.gridSpacing or (ballRadius * 0.9)
	local jitter = math.clamp(opts.jitter or 0.4, 0, 0.5)
	local minNormalY = opts.minNormalY or 0.45
	local maxRayDist = opts.maxRayDist or 200
	local startMargin = opts.startMargin or 1
	local supportThreshold = math.clamp(opts.supportThreshold or 0.75, 0, 1)
	local supportSamples = math.max(4, math.floor(opts.supportSamples or 8))
	local seed = opts.seed or 1

	local minV, maxV = SdfMesher.computeInputBounds(input)
	if not minV or not maxV then return {} end

	local sdfFn = SdfMesher.makeSdfFn(input)

	-- Sphere-trace downward from above the bounds. The SDF gives a
	-- conservative step distance at every iteration, so we never
	-- overshoot a feature smaller than the current SDF value. ~80
	-- iterations is plenty for any reasonable rock-sized shape.
	local function traceDown(x: number, z: number): Vector3?
		local startY = maxV.Y + startMargin
		local t = 0
		for _ = 1, 80 do
			if t >= maxRayDist then return nil end
			local y = startY - t
			if y < minV.Y - ballRadius then return nil end
			local p = Vector3.new(x, y, z)
			local d = sdfFn(p)
			if d < 0.01 then return p end
			t += d
		end
		return nil
	end

	-- SDF gradient via central differences. The gradient points OUTWARD
	-- of the surface (away from the interior), so it's already the
	-- outward normal direction once normalized. Step size of half a ball
	-- radius is plenty fine without amplifying numeric noise.
	local h = math.max(0.05, ballRadius * 0.5)
	local function normalAt(p: Vector3): Vector3
		local dx = sdfFn(p + Vector3.new(h, 0, 0)) - sdfFn(p - Vector3.new(h, 0, 0))
		local dy = sdfFn(p + Vector3.new(0, h, 0)) - sdfFn(p - Vector3.new(0, h, 0))
		local dz = sdfFn(p + Vector3.new(0, 0, h)) - sdfFn(p - Vector3.new(0, 0, h))
		local g = Vector3.new(dx, dy, dz)
		local mag = g.Magnitude
		if mag < 1e-6 then return Vector3.new(0, 1, 0) end
		return g / mag
	end

	-- Footprint support: trace a ring of `supportSamples` rays straight
	-- down from above, at radius ballRadius around the center hit. Count
	-- how many find rock close enough (within ±ballRadius vertically) to
	-- be supporting the blob. Catches placements where the center is on
	-- rock but the ball hangs out into air past an edge — the cardinal-
	-- direction samples there will either miss the rock entirely or hit
	-- way down on a cliff face, both failing the proximity test.
	local supportNeeded = math.ceil(supportSamples * supportThreshold)
	local supportYTolerance = ballRadius
	local function isFootprintSupported(hit: Vector3): boolean
		if supportNeeded <= 0 then return true end
		local supported = 0
		local missLimit = supportSamples - supportNeeded -- early-out when survival is impossible
		local missed = 0
		for k = 1, supportSamples do
			local theta = (k / supportSamples) * math.pi * 2
			local sx = hit.X + math.cos(theta) * ballRadius
			local sz = hit.Z + math.sin(theta) * ballRadius
			local edgeHit = traceDown(sx, sz)
			if edgeHit and math.abs(edgeHit.Y - hit.Y) <= supportYTolerance then
				supported += 1
				if supported >= supportNeeded then return true end
			else
				missed += 1
				if missed > missLimit then return false end
			end
		end
		return supported >= supportNeeded
	end

	local rng = Random.new(seed)
	local out = {}
	local ballHalfY = ballRadius * flatness
	-- Lift each ball so most of it sits ABOVE the surface — bottom
	-- ~20% intersects the host so the SDF blends visually but the
	-- silhouette reads as a snow cap, not a half-buried disk.
	local centerLift = ballHalfY * 0.6

	local x = minV.X
	while x <= maxV.X do
		local z = minV.Z
		while z <= maxV.Z do
			local jx = (rng:NextNumber() - 0.5) * 2 * jitter * gridSpacing
			local jz = (rng:NextNumber() - 0.5) * 2 * jitter * gridSpacing
			local hit = traceDown(x + jx, z + jz)
			if hit then
				local n = normalAt(hit)
				if n.Y >= minNormalY and isFootprintSupported(hit) then
					table.insert(out, {
						center = hit + Vector3.new(0, centerLift, 0),
						semi = Vector3.new(ballRadius, ballHalfY, ballRadius),
					})
				end
			end
			z += gridSpacing
		end
		x += gridSpacing
	end

	return out
end

-- Standard mount: applied to every MeshPart the generators produce.
function GeneratorUtil.mountMesh(
	mp: MeshPart,
	container: Instance,
	props: { [string]: any }?
)
	mp.Anchored = true
	mp.CanCollide = false
	mp.CastShadow = true
	mp.Material = Enum.Material.SmoothPlastic
	if props then
		for k, v in pairs(props) do
			(mp :: any)[k] = v
		end
	end
	mp.Parent = container
end

-- Bake a separate Snow MeshPart from the given ellipsoids and parent it.
-- Keeping snow on its own mesh lets it carry Enum.Material.Snow + a
-- neutral white color independently of the host prop's material. Skips
-- cleanly when the ellipsoid list is empty.
local FALLBACK_SNOW_TOP = Color3.fromRGB(245, 248, 253)
local FALLBACK_SNOW_UNDER = Color3.fromRGB(170, 195, 225)

function GeneratorUtil.bakeSnow(
	snowEllipsoids: { any },
	targetContainer: Instance,
	opts: { triCap: number?, cellsPerDim: number?, smoothBlend: number?, color: Color3? }?
)
	if #snowEllipsoids == 0 then return end
	opts = opts or {}
	-- Two-tone snow shading: bright white on up-facing surfaces (sunlit
	-- caps), cool blue on down-facing / underside surfaces (sky bounce
	-- + shadow). normal.Y maps from -1 (full under) to +1 (full top); we
	-- remap to 0..1 with a gentle bias so the upper hemisphere reads as
	-- mostly white and the under-tint kicks in on the truly downward bits.
	local topColor = GeneratorUtil.resolveColor("Snow", "Top", FALLBACK_SNOW_TOP)
	local underColor = GeneratorUtil.resolveColor("Snow", "Under", FALLBACK_SNOW_UNDER)
	local function snowColorFn(_vertex: Vector3, normal: Vector3, _w: { [string]: number }): Color3
		local t = math.clamp(normal.Y * 0.5 + 0.5, 0, 1)
		-- Sharpen: most of the mesh stays top-color, only the bottom
		-- ~third pushes hard into under-color. A linear lerp washed out
		-- the silhouette into uniform pale blue.
		t = math.clamp((t - 0.35) / 0.4, 0, 1)
		return underColor:Lerp(topColor, t)
	end
	local result, msg = SdfMesher.build(
		{ ellipsoids = snowEllipsoids },
		{
			-- Bumped from 4000 → 6000: at smoothBlend=0.9 (RockCrystal's
			-- "continuous tube" snow look) tri counts routinely landed at
			-- ~4500, forcing a triangle-cap retry that doubled the bake
			-- time. 6000 leaves headroom without producing visibly heavier
			-- meshes.
			triCap = opts.triCap or 6000,
			initialMaxCellsPerDim = opts.cellsPerDim or 40,
			boundsPadding = 2,
			smoothBlend = opts.smoothBlend or 0.45,
			vertexColorFn = snowColorFn,
			renderFidelity = Enum.RenderFidelity.Precise,
			collisionFidelity = Enum.CollisionFidelity.Box,
		}
	)
	if not result then
		warn("[GeneratorUtil.bakeSnow] bake failed: " .. tostring(msg))
		return
	end
	-- MeshPart.Color stays white so the per-vertex colors carry the look;
	-- if `opts.color` is passed, multiply on top via Color (rare path).
	GeneratorUtil.mountMesh(result.meshPart, targetContainer, {
		Name = "Snow",
		Color = opts.color or Color3.new(1, 1, 1),
		Material = Enum.Material.Snow,
	})
end

return GeneratorUtil
