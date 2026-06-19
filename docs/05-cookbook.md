# 05 — Cookbook

Complete, copy-pasteable worked examples. Start with the cloud — it's the headline request and
it exercises every pillar (primitive authoring, smooth-min, the neutral-intensity shader, the
ProceduralModel contract). The later examples show subtraction (crystals), capsules + skinning
(branches), and snow layering.

---

## ⭐ The SDF fluffy cloud

> *"Make me a procedural model of an SDF fluffy cloud."*

A cloud is a **biased cluster of soft ellipsoid puffs** melted together with a generous
`smoothBlend`, shaded with the neutral-intensity + fake-AO + backlit-rim recipe from `04`.

### How it works

1. Pick a **vertical profile** — the XZ width at each normalized height `yT ∈ 0..1`. A
   cumulonimbus has a flat base, a narrow stem, a column, cauliflower bulges, then a flared
   anvil cap.
2. Scatter `PuffCount` spheres: sample a height (biased toward the fluffy upper region), pick a
   radius within `[width(yT)*0.5]`, jitter the axes. `sqrt` radial bias pushes puffs toward the
   silhouette for a full outline.
3. Bake with a big `smoothBlend` so the puffs melt into one continuous cloud body, not a bag of
   balls.
4. Shade: single-intensity Lambert + wrap light, fake AO in the creases, fake SSS rim on the
   anti-sun silhouette. `Material = Neon`, no collision/shadow/query.

### The generator (ModuleScript — set a ProceduralModel's `Generator` to this)

```lua
--!strict
-- FluffyCloud — a ProceduralModel generator. Returns { Attributes, OnGenerate }.
local SdfMesher = require(script.Parent.Parent.Parent.SdfMesher)
local GeneratorSignal = require(script.Parent.Parent.GeneratorSignal)

local Attributes = {
    Seed = 1,
    BaseWidthRatio = 0.48,   -- flat-base width / anvil spread
    PuffCount = 95,
    MinPuffRadius = 12,
    MaxPuffRadius = 30,
    SmoothBlend = 6,         -- ⭐ the "fluffiness" knob — high so puffs melt together
    SdfCellsPerDim = 20,
    SdfTriCap = 25000,
    LightColor = Color3.fromRGB(255, 250, 240),
    ShadowColor = Color3.fromRGB(70, 80, 100),
    SunDir = Vector3.new(0.4, 0.8, 0.3).Unit,
    Version = 0,
}

-- XZ width (stud radius) at normalized height yT for a cumulonimbus silhouette.
local function widthAt(yT: number, baseWidth: number, anvilSpread: number): number
    if yT < 0.10 then return baseWidth * 0.90                       -- flat base
    elseif yT < 0.30 then return baseWidth * (0.90 - 0.35 * (yT - 0.10) / 0.20)  -- stem
    elseif yT < 0.70 then return baseWidth * 0.55                   -- column
    elseif yT < 0.90 then return baseWidth * 0.55 + (baseWidth * 0.45) * (yT - 0.70) / 0.20  -- bulges
    else return baseWidth + (anvilSpread - baseWidth) * (yT - 0.90) / 0.10 end   -- anvil
end

-- Vertical squash (horizontal mul, vertical mul) per band — squashed base + anvil.
local function squash(yT: number): (number, number)
    if yT < 0.10 then return 1.15, 0.55
    elseif yT > 0.90 then return 1.30, 0.60
    elseif yT > 0.70 then return 1.08, 1.05 end
    return 1.0, 1.0
end

-- Height sampler biased toward the fluffy upper region.
local function sampleHeightT(rng: Random): number
    local u = rng:NextNumber()
    if u < 0.10 then return u / 0.10 * 0.10
    elseif u < 0.50 then return 0.10 + (u - 0.10) / 0.40 * 0.60
    elseif u < 0.85 then return 0.70 + (u - 0.50) / 0.35 * 0.20
    else return 0.90 + (u - 0.85) / 0.15 * 0.10 end
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
        local radialT = math.sqrt(rng:NextNumber())             -- push toward the rim
        local angle = rng:NextNumber() * math.pi * 2
        local r = w * 0.5 * radialT
        local base = minR + rng:NextNumber() * (maxR - minR)
        local hMul, vMul = squash(yT)
        local jitter = 0.85 + rng:NextNumber() * 0.30
        local centeredY = yT * height - height * 0.5            -- base at -h/2, anvil at +h/2
        table.insert(ellipsoids, {
            center = Vector3.new(math.cos(angle) * r, centeredY, math.sin(angle) * r),
            semi = Vector3.new(base * hMul * jitter, base * vMul, base * hMul * (2 - jitter)),
        })
    end

    if parameters.Pause then parameters:Pause() end             -- yield before the heavy bake

    -- Height/radial reference for the shader.
    local minY, maxY = math.huge, -math.huge
    for _, e in ipairs(ellipsoids) do
        minY = math.min(minY, e.center.Y - e.semi.Y)
        maxY = math.max(maxY, e.center.Y + e.semi.Y)
    end
    local yRange = math.max(maxY - minY, 0.01)
    local horizRef = math.max(maxHoriz * 0.5, 0.01)

    local sunDir = (a.SunDir and a.SunDir.Magnitude > 0.01) and a.SunDir.Unit
        or Vector3.new(0.4, 0.8, 0.3).Unit
    local lightColor = a.LightColor or Color3.fromRGB(255, 250, 240)
    local shadowColor = a.ShadowColor or Color3.fromRGB(70, 80, 100)

    local function colorFn(vertex: Vector3, normal: Vector3): Color3
        local heightT = math.clamp((vertex.Y - minY) / yRange, 0, 1)
        local radialT = math.clamp(math.sqrt(vertex.X^2 + vertex.Z^2) / horizRef, 0, 1)
        local key = math.max(0, normal:Dot(sunDir))
        local sky = math.max(0, normal.Y * 0.5 + 0.5)
        local grn = math.max(0, -normal.Y)
        local intensity = key * 0.55 + sky * 0.35 + grn * 0.18 + 0.12
        intensity *= (1 - math.max(0, -normal.Y) * heightT * heightT * 0.40)      -- fake AO
        local antiKey = math.max(0, -normal:Dot(sunDir))
        local edgeness = 1 - math.abs(normal.Y)
        intensity += (antiKey ^ 1.2) * (edgeness ^ 1.5) * (0.5 + radialT * 0.5) * 0.85  -- SSS rim
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
    if not result then warn("[FluffyCloud] " .. tostring(msg)); return end

    local mp = result.meshPart
    mp.Name = "Cloud"
    mp.Anchored, mp.CanCollide, mp.CastShadow = true, false, false
    mp.CanQuery, mp.CanTouch, mp.AudioCanCollide = false, false, false
    mp.Color = Color3.fromRGB(200, 200, 200)   -- Neon headroom so highlights don't clip white
    mp.Material = Enum.Material.Neon
    mp.Size = size                              -- conform to the PM bounds
    mp.Parent = targetContainer
end

return {
    Attributes = Attributes,
    OnGenerate = GeneratorSignal.wrap(OnGenerate),
}
```

### Placing it as a ProceduralModel

After writing the module (say at `ReplicatedFirst/WorldAnimation/Generators/FluffyCloud.luau`):

```lua
local pm = Instance.new("ProceduralModel")
pm.Size = Vector3.new(120, 80, 120)            -- drives the cloud's dimensions
pm.Generator = game.ReplicatedFirst.WorldAnimation.Generators.FluffyCloud
pm.Parent = workspace
-- The engine bakes on parent. To re-tune: change any attribute, e.g.
pm:SetAttribute("SmoothBlend", 9)              -- puffier
pm:SetAttribute("Seed", 7)                     -- a different cloud
```

With many clouds, route them through the Kicker (`03`) so you stay under the EM cap.

### Quick one-shot version (no ProceduralModel, just see it)

Drop the `ellipsoids`/`colorFn`/`SdfMesher.build` body straight into `execute_luau`, parent
`result.meshPart` to workspace at some altitude. Good for a screenshot; no live re-tuning.

### Tuning the look

| Want | Change |
|---|---|
| Puffier / more melted | raise `SmoothBlend` (6 → 10) |
| More detail / crisper puffs | raise `SdfCellsPerDim` (20 → 30) **and** `SdfTriCap` |
| Denser body | raise `PuffCount`; raise `MinPuffRadius` |
| Flatter "Pixar" pyramid cloud | swap the profile: widest at base, taper up, clamp puff bottoms to a flat floor (see the production `CloudGenerator.luau` `Pyramid` branch) |
| Different lighting | set `SunDir`, `LightColor`, `ShadowColor` |

---

## Faceted crystal rock (subtraction)

Build a rounded rock body from a few overlapping ellipsoids, then **carve flat facets** with
thin `subtractSlabs` (`rounding = 0` for sharp cuts). Use `creaseness` to accent the cut rims.

```lua
local rng = Random.new(seed)
local ellipsoids = {
    { center = Vector3.new(0, 0, 0),    semi = Vector3.new(10, 12, 9) },
    { center = Vector3.new(4, 3, -2),   semi = Vector3.new(6, 7, 6) },
}
-- Carve ~10 random facets by slicing with thin sharp slabs from outside.
local subtractSlabs = {}
for _ = 1, 10 do
    local dir = Vector3.new(rng:NextNumber()-0.5, rng:NextNumber()-0.5, rng:NextNumber()-0.5).Unit
    local up = math.abs(dir.Y) > 0.9 and Vector3.xAxis or Vector3.yAxis
    local right = up:Cross(dir).Unit
    up = dir:Cross(right).Unit                      -- right × up == dir (right-handed!)
    table.insert(subtractSlabs, {
        center = dir * (9 + rng:NextNumber() * 3),  -- push the cutter just inside the surface
        right = right, up = up, forward = dir,
        semi = Vector3.new(20, 20, 8),              -- wide, thin slab → planar cut
        rounding = 0,                               -- sharp facet
    })
end

local result = SdfMesher.build(
    { ellipsoids = ellipsoids, subtractSlabs = subtractSlabs },
    {
        smoothBlend = 0,                            -- hard edges for crystal facets
        initialMaxCellsPerDim = 48,
        vertexColorFn = function(v, n, _w, crease)
            local lit = bodyColor:Lerp(Color3.new(1,1,1), math.max(0, n:Dot(sunDir)) * 0.5)
            return lit:Lerp(facetRimColor, crease * 0.7)   -- bright crisp facet edges
        end,
        renderFidelity = Enum.RenderFidelity.Precise,
        collisionFidelity = Enum.CollisionFidelity.Box,
    }
)
```

Key points: **bounds must enclose the cutters** (the mesher pads, but keep cutters near the
surface); `smoothBlend = 0` for crisp edges; the cutter basis must be **right-handed** (`04`).
For curved gouges (bowls, arches, sockets) use `subtractEllipsoids` instead.

---

## Tree branch (capsules + skinning)

Chain `capsules`/`taperedCapsules` for limbs — they merge smoothly where endpoints meet, no
joint spheres needed. Tag primitives with `boneWeights` and declare `bones` to get a skinned,
wind-swayable branch.

```lua
local input = {
    taperedCapsules = {
        { a = Vector3.new(0,0,0), b = Vector3.new(0,8,0),  radiusA = 2.0, radiusB = 1.2,
          boneWeights = { { key = "trunk", w = 1 } } },
    },
    capsules = {
        { a = Vector3.new(0,8,0), b = Vector3.new(5,13,1), radius = 0.8,
          boneWeights = { { key = "branch", w = 1 } } },
    },
    bones = {
        { key = "trunk",  name = "Trunk",  bindCFrame = CFrame.new(0, 0, 0) },
        { key = "branch", name = "Branch", bindCFrame = CFrame.new(0, 8, 0), parentKey = "trunk" },
    },
}
local result = SdfMesher.build(input, {
    smoothBlend = 0.5,
    maxBonesPerVertex = 4,
    renderFidelity = Enum.RenderFidelity.Precise,
})
-- After this, result.meshPart has child Bone instances "Trunk" / "Branch".
-- Sway at runtime via Transform (NOT CFrame — see 02/06):
local branchBone = result.meshPart:FindFirstChild("Branch", true)
branchBone.Transform = CFrame.Angles(0, 0, math.sin(os.clock()) * 0.1)
```

The mesher topologically sorts the bones, weights each vertex by the surface-closest owning
primitive, keeps the top-4 normalized, and builds the post-bake `Bone` Instances mirroring
`parentKey`.

> Reliability note: skinned meshes currently need the **single-step** bake (the two-step path
> strips bones). `SdfMesher.build` uses two-step; if branch deformation doesn't take at
> runtime, that's why — see `06-gotchas.md` and `02`.

---

## Adding snow to anything

```lua
local GeneratorUtil = require(script.Parent.GeneratorUtil)

-- Source snow from the actual baked SDF surface (follows carved silhouettes):
local snow = GeneratorUtil.snowOnSurface(input, { ballRadius = 0.7, gridSpacing = 0.6,
    minNormalY = 0.45, supportThreshold = 0.75, seed = seed })
snow = GeneratorUtil.thinSnow(snow, GeneratorUtil.getSnowAmount(), seed)  -- global coverage
GeneratorUtil.bakeSnow(snow, targetContainer, { smoothBlend = 0.45 })    -- its own Snow MeshPart
```

`snowOnEllipsoids` / `snowOnCapsules` are cheaper alternatives that ride the source primitives
directly instead of the baked surface.

---

## Back to reference

- [`01-sdf-mesher.md`](01-sdf-mesher.md) · [`02-editablemesh-and-baking.md`](02-editablemesh-and-baking.md) ·
  [`03-procedural-models.md`](03-procedural-models.md) · [`04-vertex-shading.md`](04-vertex-shading.md) ·
  [`06-gotchas.md`](06-gotchas.md)
- Real production generators to crib from: `ReplicatedFirst/WorldAnimation/Generators/`
  (`CloudGenerator`, `RockCrystal`, `PineTree`, `Landmass`, `TallGrass`, `GroundCutter`, …).
