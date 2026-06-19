# 04 — Vertex Shading

SDF meshes have no UVs worth texturing and no normal maps. They get their entire look from
**baked per-vertex color**. You supply a `vertexColorFn` in the mesher config; it's called
once per vertex and returns the `Color3` baked into every face that uses that vertex. This is
free at runtime — the lighting is painted into the geometry at bake time.

```lua
type VertexColorFn = (
    vertex: Vector3,                 -- the vertex world/model position
    normal: Vector3,                 -- averaged unit normal at this vertex
    weights: { [string]: number },   -- bone-weight tally (empty if no skinning)
    creaseness: number               -- 0 = flat region, → 1 on sharp creases / cut edges
) -> Color3
```

Keep `meshPart.Color = Color3.new(1,1,1)` so the baked colors pass through unmultiplied. With
`Material = Neon`, knock the part color down (e.g. `Color3.fromRGB(200,200,200)`) so highlights
have headroom and don't clip to solid white.

---

## The neutral-intensity shader (the core recipe)

Don't tint from many colored light sources — it muddies. Instead accumulate **all light into a
single scalar intensity**, then `shadowColor:Lerp(lightColor, intensity)`. This is the cloud
shader, and it generalizes to almost everything:

```lua
local sunDir = Vector3.new(0.4, 0.8, 0.3).Unit   -- or WorldSun.getDirection()
local function colorFn(vertex, normal, _weights, _crease)
    -- Three soft directional terms.
    local key = math.max(0, normal:Dot(sunDir))        -- direct sun (Lambert)
    local sky = math.max(0, normal.Y * 0.5 + 0.5)      -- wrap light: softer toward the top
    local grn = math.max(0, -normal.Y)                 -- ground bounce on undersides
    local intensity = key * 0.55 + sky * 0.35 + grn * 0.18 + 0.12   -- + ambient floor

    intensity = math.clamp(intensity, 0, 1)
    return shadowColor:Lerp(lightColor, intensity)
end
```

That alone gives a clean, readable soft-lit look. The next two tricks add realism on top.

### Fake ambient occlusion

Darken downward-facing normals high on the form — the concave creases between bulges. Quadratic
in normalized height so the under-base stays unaffected:

```lua
local heightT = math.clamp((vertex.Y - minY) / yRange, 0, 1)
local creaseAO = math.max(0, -normal.Y) * heightT * heightT * 0.40
intensity *= (1 - creaseAO)
```

### Fake subsurface scattering / backlit rim

Thin silhouette edges facing away from the sun glow with "transmitted" light. The combination
of *anti-sun facing* × *near-horizontal normal* × *outer radial edge*, with sharp angular
falloff, concentrates the glow into a bright rim band rather than a soft backglow:

```lua
local radial = math.sqrt(vertex.X * vertex.X + vertex.Z * vertex.Z)
local radialT = math.clamp(radial / horizRef, 0, 1)
local antiKey = math.max(0, -normal:Dot(sunDir))
local edgeness = 1 - math.abs(normal.Y)
local rim = (antiKey ^ 1.2) * (edgeness ^ 1.5) * (0.5 + radialT * 0.5) * 0.85
intensity = intensity + rim                  -- add BEFORE the final clamp
```

Raise the powers to tighten the rim into a thinner band; raise the `0.85` gain to make it read
as real transmitted light instead of subtle fill. This is what makes the cloud look fluffy
rather than like a gray potato.

---

## `creaseness` — highlight cut edges and sharp corners

The mesher hands you a per-vertex `creaseness` in `[0,1]`: `0` where adjacent face normals are
parallel (flat region), trending to `1` where they diverge (sharp crease, subtract-slab cut
edge). Use it to darken/lighten edges, add wear, or accent faceted cuts:

```lua
local function colorFn(vertex, normal, _w, creaseness)
    local base = litColor(vertex, normal)
    return base:Lerp(edgeAccent, creaseness * 0.6)   -- e.g. crisp facet rims on a crystal
end
```

---

## Two-tone snow (height/normal split)

Bright white on up-facing surfaces, cool blue on undersides. A linear lerp washes out into
uniform pale blue, so **sharpen** the remap so most of the mesh stays white and only the bottom
third pushes into the under-tint:

```lua
local function snowColorFn(_vertex, normal, _w, _c)
    local t = math.clamp(normal.Y * 0.5 + 0.5, 0, 1)   -- -1..1 → 0..1
    t = math.clamp((t - 0.35) / 0.4, 0, 1)             -- sharpen: bottom third → under
    return underColor:Lerp(topColor, t)
end
```

`GeneratorUtil.bakeSnow(snowEllipsoids, container, opts)` bakes snow as its own MeshPart so it
can carry `Enum.Material.Snow` + white color independently of the host prop, using exactly this
shader. Source the snow ellipsoids from:

- `GeneratorUtil.snowOnEllipsoids(ellipsoids, opts)` — flattened domes on top of each blob.
- `GeneratorUtil.snowOnCapsules(capsules, opts)` — beads along the upward side of each branch.
- `GeneratorUtil.snowOnSurface(input, opts)` — sphere-traces the *actual baked SDF surface*
  downward on an XZ grid and drops a flattened oval wherever a ray hits an up-facing,
  footprint-supported spot. This follows the real carved silhouette (rocks, fences, terrain)
  instead of just sitting on the source primitives.

Global coverage scalars live at `ReplicatedStorage.WorldSettings`:
`GeneratorUtil.getSnowAmount()` / `getLeafAmount()` (0..1). `GeneratorUtil.thinSnow(list,
amount, seed)` probabilistically thins blobs by the snow amount, seeded so the same PM thins
to the same blobs each bake (no flicker on regen).

---

## Debug coloring

Set `config.debugVertexColors = true` and the mesher colors each vertex by its **dominant
bone** (golden-angle-spread hues), making skin-weight regions visible on the baked part.
Mutually exclusive with `vertexColorFn`. Invaluable when skinning looks wrong.

---

## Per-corner normals (smooth vs faceted control)

By default the bake auto-computes flat per-face normals. To force smooth shading or a specific
direction, use the per-face-corner normal API (see `02`): `AddNormal(vec)` →
`SetVertexFaceNormal(vid, faceId, nid)`. Example use: force a dome's top bevel ring to `+Y`
normals so it fades smoothly into the flat top instead of showing a hard rim.

---

## ⚠️ CFrame handedness (when you build slab/oriented frames)

To orient a `Slab` (or any `CFrame.fromMatrix`) you supply a `right`/`up`/`forward` basis. It
**must be right-handed**: `right × up == forward` (equivalently `vR × vU == vB`, **not** `-vB`,
verified from `CFrame.identity`). A left-handed triple does **not** error — Roblox silently
mirrors one axis, and the geometry renders **inside-out** (correct position and size, flipped
normals/winding), which makes the bug maddening to diagnose.

When deriving a basis from two perpendicular world directions `d1`, `d2` with vertical `up`:

```lua
-- If you intend vB = d2: need up × d1 == d2; swap the two legs when (up × d1)·d2 < 0.
local back = d2
local rightV = up:Cross(d1)
if rightV:Dot(d2) < 0 then d1, d2 = d2, d1; back = d2; rightV = up:Cross(d1) end
-- Verify before trusting: assert(rightV:Cross(up):Dot(back) > 0)
```

When a slab or wedge looks placed-and-sized-correctly but shaded inside-out, suspect handedness
first.

---

## Next

- See these shaders inside complete generators → [`05-cookbook.md`](05-cookbook.md)
- The pitfalls quick reference → [`06-gotchas.md`](06-gotchas.md)
