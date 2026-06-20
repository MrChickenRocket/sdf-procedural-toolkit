# SDF Procedural Modeling Toolkit

A guide set for building **procedural, signed-distance-field (SDF) meshes** in Roblox at
runtime — fluffy clouds, gnarled trees, faceted crystals, snow-capped rocks — and wiring
them into self-rebaking `ProceduralModel` instances.

This is written so that an **agent with no prior context** can read it and execute requests
like *"Make me a procedural model of an SDF fluffy cloud."* Everything here is distilled
from a working production project (`ayearofbugs`) that ships all of these techniques.

---

## The one-paragraph mental model

You describe a shape as a **soup of overlapping primitives** (spheres/ellipsoids, oriented
boxes, capsules, cones) plus optional **subtractions** (carve facets, gouges, holes). A
mesher samples the combined signed-distance field onto a voxel grid, extracts the zero-level
surface as a triangle mesh (Surface Nets), simplifies it (QEM decimation), paints it with a
per-vertex color function, and bakes it into an `EditableMesh` → `Content` → `MeshPart`.
Wrap that bake in a `ProceduralModel` generator and the result becomes a live, attribute-
driven object an artist can resize and re-tune in Studio. **Primitives in, MeshPart out.**

---

## The pipeline (read this once)

```
  [1] Author primitives            ellipsoids / slabs / capsules / taperedCapsules
      (+ subtract primitives)      subtractSlabs / subtractEllipsoids
              │
              ▼
  [2] SDF splat onto voxel grid    each cell = min(distance to all add prims),
      (SdfMesher)                  then max(-subtract prims). smooth-min blends
                                   grazing prims into bulges (no saddle holes).
              │
              ▼
  [3] Surface Nets extraction      one dual vertex per sign-changing cell;
      (SdfMesher)                  quads stitched between them → triangles.
              │
              ▼
  [4] QEM decimation               edge-collapse simplify, curvature-preserving.
      (SdfMesher)                  triCap overrun → coarsen grid + retry.
              │
              ▼
  [5] EditableMesh build           AddVertex / AddTriangle, then per-face-corner
      (SdfMesher)                  AddColor+SetVertexFaceColor (vertexColorFn),
                                   optional AddBone + SetVertexBones (skinning).
              │
              ▼
  [6] Bake to MeshPart             static:  CreateDataModelContentAsync → CreateMeshPartAsync
      (SdfMesher)                  skinned: CreateMeshPartAsync(Content.fromObject(em)) directly
                                   (fidelity opts on BOTH calls). em:Destroy() always.
              │
              ▼
  [7] ProceduralModel wrapper      module returns { Attributes, OnGenerate }.
      (your Generator)             GeneratorSignal.wrap(OnGenerate) adds the
                                   re-entrancy guard + done-signal handshake.
                                   The Kicker throttles bakes under the EM cap.
```

Steps 2–6 are **already implemented** for you in `SdfMesher.luau`. In 95% of cases you only
write step 1 (author primitives) and step 5's color function, then return step 7's table.

---

## The four pillars (and where each is documented)

| Pillar | What it is | Doc |
|---|---|---|
| **SDF meshing** | Turn primitive soup into a triangle mesh via Surface Nets over a signed-distance field | [`01-sdf-mesher.md`](01-sdf-mesher.md) |
| **EditableMesh + DataModelContent** | Build runtime geometry and bake it into a real `MeshPart` at the right fidelity | [`02-editablemesh-and-baking.md`](02-editablemesh-and-baking.md) |
| **ProceduralModel** | Attribute-driven, self-rebaking generator instances + the throttling that keeps them under the EM cap | [`03-procedural-models.md`](03-procedural-models.md) |
| **Vertex shading** | Bake lighting, fake AO/SSS, and material looks into per-vertex colors at zero runtime cost | [`04-vertex-shading.md`](04-vertex-shading.md) |

Plus:
- [`05-cookbook.md`](05-cookbook.md) — complete worked generators, **including the SDF fluffy cloud**.
- [`06-gotchas.md`](06-gotchas.md) — the consolidated "this bit me" reference table. Skim it before debugging.
- [`07-sdfmesher2.md`](07-sdfmesher2.md) — **SdfMesher2**, the second-gen *sharp-feature* mesher
  (crisp boxes/chamfers, nested CSG, QEM minimal geometry) + the `SdfDocument` multi-part layer.
- [`08-sdfmesher3.md`](08-sdfmesher3.md) — **SdfMesher3**, the third-gen *adaptive octree* mesher
  (same op-graph as v2, ~7× faster, clean minimal geometry directly — great for plastic-toy content).
- [`09-magicacsg.md`](09-magicacsg.md) — **SdfMcsg**, importing [MagicaCSG](https://ephtracy.github.io/)
  `.mcsg` text models into v3 op-graphs (the format reverse-engineered + what's supported).

> **Three meshers, shared field.** `SdfMesher` (docs `01`) is the original Surface-Nets engine —
> smooth, ships the generators. `SdfMesher2` (doc `07`) adds sharp features + QEM on a uniform grid.
> `SdfMesher3` (doc `08`) is the adaptive-octree successor: same input as v2, faster, cleaner.
> v2/v3 share `SdfField` (eval) and `SdfDecimate` (QEM). Pick: organic/foliage → v1; new
> hard-surface/CSG/toys → **v3** (v2 if you need a guaranteed uniform resolution).

**Recommended reading order for a first build:** this README → `05-cookbook.md` (copy the
cloud, run it) → `01` and `02` when you need to understand or extend it → `03`/`04`/`06` as
reference. For hard-surface work, read `07` then `08`.

---

## The portable core

These modules are the reusable engine. To do "all the cool things" in a *fresh* place, copy
them across; everything else (the generators) is application content built on top.

| Module | Role | Required? |
|---|---|---|
| `ReplicatedFirst/SdfMesher.luau` | The v1 mesher (Surface Nets, smooth) — steps 2–6. | **Yes** (v1 path) |
| `ReplicatedFirst/SdfMesher2.luau` | The v2 mesher (uniform grid, sharp features + QEM). Self-contained; only `AssetService`. See `07`. | For uniform-grid hard-surface |
| `ReplicatedFirst/SdfMesher3.luau` | The v3 mesher (adaptive octree DC, fastest + cleanest). Needs `SdfField` + `SdfDecimate`. See `08`. | **For new work** |
| `ReplicatedFirst/SdfField.luau` | Shared field evaluator: distance, analytic gradient, AABB cull boxes. | Yes for v3 |
| `ReplicatedFirst/SdfDecimate.luau` | Shared Garland-Heckbert QEM edge-collapse decimator. | Yes for v3 |
| `ReplicatedFirst/SdfDocument.luau` | Multi-part authoring layer: a document → a `Model` of MeshParts. `bake` (v1) / `bakeV2` (v2) / `bakeV3` (v3). | Optional |
| `ReplicatedFirst/Documents/Soldier.luau` | Worked multi-part example (the Lego soldier), bakes through any mesher. | Example |
| `ReplicatedFirst/WorldAnimation/GeneratorSignal.luau` | `wrap()` for generators: re-entrancy guard, server bail, done-signal. | Yes for ProceduralModels |
| `ReplicatedFirst/ProceduralModelKicker.luau` | Throttles concurrent bakes under the EditableMesh cap; layer ordering. | Yes if you have >~4 PMs |
| `ReplicatedFirst/ReplicatedAttributeRebake.luau` | Client-side re-bake when the server changes a replicated attribute. | Only for server-driven attrs |
| `ReplicatedFirst/WorldAnimation/Generators/GeneratorUtil.luau` | Snow/leaf helpers, palette resolution, mesh mounting. | Optional convenience |

`SdfMesher` and `SdfMesher2` depend only on `AssetService` (v1 also uses the native `vector`
library) — each is fully self-contained. `SdfMesher3` is the same except it requires the two shared
modules `SdfField` (field eval) and `SdfDecimate` (QEM) as siblings — copy all three together.

---

## How an agent actually runs this in Studio

The shapes are produced by Luau that calls `AssetService`. An agent drives Studio through
the `Roblox_Studio` MCP server. Two paths:

1. **Author a Generator ModuleScript** (the production pattern) and create a
   `ProceduralModel` whose `Generator` property points at it. The engine bakes it
   automatically and re-bakes on attribute changes. Use `multi_edit` to write the module,
   then `generate_procedural_model` / `execute_luau` to place the PM. This is what you want
   for anything an artist will keep tweaking.

2. **One-shot bake via `execute_luau`** — `require(SdfMesher)`, build primitives, call
   `SdfMesher.build(...)`, parent the resulting `meshPart` into Workspace. Good for quick
   experiments and screenshots; no live re-tuning.

> ⚠️ Per project convention: **print a notice to the Studio console before and after any MCP
> action that touches Studio.** See `06-gotchas.md`.

Either way the geometry math is identical — it all routes through `SdfMesher.build`.

---

## Quickstart: the smallest possible SDF mesh

A single sphere, baked to a MeshPart, dropped into Workspace. Run via `execute_luau`:

```lua
local SdfMesher = require(game.ReplicatedFirst.SdfMesher)

local result, msg = SdfMesher.build(
    {
        ellipsoids = {
            { center = Vector3.new(0, 0, 0), semi = Vector3.new(8, 8, 8) },  -- a sphere
            { center = Vector3.new(6, 4, 0), semi = Vector3.new(5, 5, 5) },  -- merges into it
        },
    },
    {
        smoothBlend = 2,                                   -- blob the two together
        renderFidelity = Enum.RenderFidelity.Precise,
        collisionFidelity = Enum.CollisionFidelity.Box,
    }
)

if not result then warn(msg); return end
local mp = result.meshPart
mp.Anchored = true
mp.Position = Vector3.new(0, 20, 0)
mp.Parent = workspace
print(string.format("baked %d tris, %d verts", result.triCount, result.vertCount))
```

Change `smoothBlend` to `0` and the two spheres meet with a hard crease; raise it and they
melt into a peanut. That single knob — and the choice of primitives — is most of the art.
From here, `05-cookbook.md` scales this up to a real fluffy cloud.
