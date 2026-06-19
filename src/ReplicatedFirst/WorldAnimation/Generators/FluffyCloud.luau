--!strict
-- FluffyCloud — a self-contained ProceduralModel generator that builds a
-- cumulonimbus cloud out of soft SDF puffs melted together with a generous
-- smooth-blend, shaded with a neutral-intensity + fake-AO + backlit-rim recipe.
--
-- This is the worked example from docs/05-cookbook.md. It depends only on
-- SdfMesher and GeneratorSignal (no WorldSun / palettes / WorldSettings), so it
-- runs as-is in this bundle.
--
-- USAGE: set a ProceduralModel's Generator property to this ModuleScript. The
-- cloud's dimensions follow the PM's Size; its style follows the attributes.

local SdfMesher = require(script.Parent.Parent.Parent.SdfMesher)
local GeneratorSignal = require(script.Parent.Parent.GeneratorSignal)

-- Every field here becomes an editable property in the PM's Studio panel.
-- Changing any of them re-fires OnGenerate.
local Attributes = {
	Seed = 1,
	BaseWidthRatio = 0.48, -- flat-base width / anvil spread
	PuffCount = 95,
	MinPuffRadius = 12,
	MaxPuffRadius = 30,
	SmoothBlend = 6, -- the "fluffiness" knob — high so puffs melt together
	SdfCellsPerDim = 20,
	SdfTriCap = 25000,
	LightColor = Color3.fromRGB(255, 250, 240),
	ShadowColor = Color3.fromRGB(70, 80, 100),
	SunDir = Vector3.new(0.4, 0.8, 0.3).Unit,
	Version = 0, -- bump to force a manual re-bake
}

-- XZ width (stud radius) at normalized height yT for a cumulonimbus silhouette:
-- flat base, narrow stem, column, cauliflower bulges, flared anvil cap.
local function widthAt(yT: number, baseWidth: number, anvilSpread: number): number
	if yT < 0.10 then
		return baseWidth * 0.90
	elseif yT < 0.30 then
		return baseWidth * (0.90 - 0.35 * (yT - 0.10) / 0.20)
	elseif yT < 0.70 then
		return baseWidth * 0.55
	elseif yT < 0.90 then
		return baseWidth * 0.55 + (baseWidth * 0.45) * (yT - 0.70) / 0.20
	else
		return baseWidth + (anvilSpread - baseWidth) * (yT - 0.90) / 0.10
	end
end

-- Vertical squash (horizontal mul, vertical mul) per band — squashed base + anvil.
local function squash(yT: number): (number, number)
	if yT < 0.10 then
		return 1.15, 0.55
	elseif yT > 0.90 then
		return 1.30, 0.60
	elseif yT > 0.70 then
		return 1.08, 1.05
	end
	return 1.0, 1.0
end

-- Height sampler biased toward the fluffy upper region.
local function sampleHeightT(rng: Random): number
	local u = rng:NextNumber()
	if u < 0.10 then
		return u / 0.10 * 0.10
	elseif u < 0.50 then
		return 0.10 + (u - 0.10) / 0.40 * 0.60
	elseif u < 0.85 then
		return 0.70 + (u - 0.50) / 0.35 * 0.20
	else
		return 0.90 + (u - 0.85) / 0.15 * 0.10
	end
end

local function OnGenerate(parameters: any, targetContainer: Instance)
	local a = parameters.Attributes
	local size = parameters.Size or Vector3.new(100, 100, 100)
	local height = size.Y
	local maxHoriz = math.min(size.X, size.Z)
	local anvilSpread = maxHoriz
	local baseWidth = anvilSpread * (a.BaseWidthRatio or 0.48)

	local rng = Random.new(a.Seed or 1)
	local minR, maxR = a.MinPuffRadius or 12, a.MaxPuffRadius or 30
	local ellipsoids = {}
	for _ = 1, math.floor(a.PuffCount or 95) do
		local yT = sampleHeightT(rng)
		local w = widthAt(yT, baseWidth, anvilSpread)
		local radialT = math.sqrt(rng:NextNumber()) -- push puffs toward the rim
		local angle = rng:NextNumber() * math.pi * 2
		local r = w * 0.5 * radialT
		local base = minR + rng:NextNumber() * (maxR - minR)
		local hMul, vMul = squash(yT)
		local jitter = 0.85 + rng:NextNumber() * 0.30
		local centeredY = yT * height - height * 0.5 -- base at -h/2, anvil at +h/2
		table.insert(ellipsoids, {
			center = Vector3.new(math.cos(angle) * r, centeredY, math.sin(angle) * r),
			semi = Vector3.new(base * hMul * jitter, base * vMul, base * hMul * (2 - jitter)),
		})
	end

	-- Yield slot between cheap planning and the heavy bake so the engine's
	-- watchdog doesn't trip on big puffCount values.
	if parameters.Pause then
		parameters:Pause()
	end

	-- Height/radial reference for the shader.
	local minY, maxY = math.huge, -math.huge
	for _, e in ipairs(ellipsoids) do
		minY = math.min(minY, e.center.Y - e.semi.Y)
		maxY = math.max(maxY, e.center.Y + e.semi.Y)
	end
	local yRange = math.max(maxY - minY, 0.01)
	local horizRef = math.max(maxHoriz * 0.5, 0.01)

	local sunDir = (a.SunDir and a.SunDir.Magnitude > 0.01) and a.SunDir.Unit or Vector3.new(0.4, 0.8, 0.3).Unit
	local lightColor = a.LightColor or Color3.fromRGB(255, 250, 240)
	local shadowColor = a.ShadowColor or Color3.fromRGB(70, 80, 100)

	-- Neutral-intensity shader: accumulate all light into a single scalar, then
	-- lerp shadow→light by it. Fake AO darkens creases; fake SSS rim glows on
	-- the anti-sun silhouette edges.
	local function colorFn(vertex: Vector3, normal: Vector3): Color3
		local heightT = math.clamp((vertex.Y - minY) / yRange, 0, 1)
		local radialT = math.clamp(math.sqrt(vertex.X * vertex.X + vertex.Z * vertex.Z) / horizRef, 0, 1)
		local key = math.max(0, normal:Dot(sunDir))
		local sky = math.max(0, normal.Y * 0.5 + 0.5)
		local grn = math.max(0, -normal.Y)
		local intensity = key * 0.55 + sky * 0.35 + grn * 0.18 + 0.12
		intensity *= (1 - math.max(0, -normal.Y) * heightT * heightT * 0.40) -- fake AO
		local antiKey = math.max(0, -normal:Dot(sunDir))
		local edgeness = 1 - math.abs(normal.Y)
		intensity += (antiKey ^ 1.2) * (edgeness ^ 1.5) * (0.5 + radialT * 0.5) * 0.85 -- SSS rim
		return shadowColor:Lerp(lightColor, math.clamp(intensity, 0, 1))
	end

	local result, msg = SdfMesher.build({ ellipsoids = ellipsoids }, {
		triCap = math.floor(a.SdfTriCap or 25000),
		initialMaxCellsPerDim = math.floor(a.SdfCellsPerDim or 20),
		boundsPadding = 4,
		smoothBlend = a.SmoothBlend or 6,
		vertexColorFn = colorFn,
		renderFidelity = Enum.RenderFidelity.Precise,
		collisionFidelity = Enum.CollisionFidelity.Box,
	})
	if not result then
		warn("[FluffyCloud] bake failed: " .. tostring(msg))
		return
	end

	local mp = result.meshPart
	mp.Name = "Cloud"
	mp.Anchored = true
	mp.CanCollide = false
	mp.CastShadow = false
	mp.CanQuery = false
	mp.CanTouch = false
	mp.AudioCanCollide = false
	-- Neon blows out at pure white — knock the part color down so highlights
	-- have headroom and don't clip to solid white.
	mp.Color = Color3.fromRGB(200, 200, 200)
	mp.Material = Enum.Material.Neon
	mp.Size = size
	mp.Parent = targetContainer
end

return {
	Attributes = Attributes,
	OnGenerate = GeneratorSignal.wrap(OnGenerate),
}
