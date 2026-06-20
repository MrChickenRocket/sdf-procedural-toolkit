# SDF Procedural Modeling Toolkit

A self-contained, shareable bundle for building **procedural signed-distance-field (SDF)
meshes** in Roblox at runtime — fluffy clouds, gnarled trees, faceted crystals, snow-capped
rocks — and wiring them into self-rebaking `ProceduralModel` instances.

You describe a shape as a soup of overlapping primitives (spheres/ellipsoids, oriented boxes,
capsules, cones) plus optional carve-outs; a mesher samples the combined distance field,
extracts the surface (Surface Nets), simplifies it (QEM), paints per-vertex color, and bakes it
into an `EditableMesh` → `Content` → `MeshPart`. **Primitives in, MeshPart out.**

This bundle contains the production-tested engine modules, full documentation, and a runnable
example. It's everything an engineer (or an agent) needs to do this from scratch.

---

## What's in the box

```
sdf-procedural-toolkit/
├── README.md                  ← you are here (install + quickstart)
├── default.project.json       ← Rojo project: syncs src/ into ReplicatedFirst
├── docs/                       ← the full guide set (start at docs/README.md)
│   ├── README.md              ← overview, pipeline diagram, reading order
│   ├── 01-sdf-mesher.md       ← the mesher API + primitive cookbook
│   ├── 02-editablemesh-and-baking.md
│   ├── 03-procedural-models.md
│   ├── 04-vertex-shading.md
│   ├── 05-cookbook.md         ← complete worked generators (incl. the cloud)
│   ├── 06-gotchas.md          ← the consolidated "this bit me" reference
│   ├── 07-sdfmesher2.md       ← the v2 sharp-feature mesher + the document layer
│   ├── 08-sdfmesher3.md       ← the v3 adaptive octree mesher (fastest + cleanest)
│   └── 09-magicacsg.md        ← importing MagicaCSG (.mcsg) text models
└── src/
    └── ReplicatedFirst/
        ├── SdfMesher.luau                    ← v1 engine: Surface Nets, smooth (heart of it all)
        ├── SdfMesher2.luau                   ← v2 engine: uniform grid, sharp features + QEM (docs/07)
        ├── SdfMesher3.luau                   ← v3 engine: adaptive octree Dual Contouring (docs/08)
        ├── SdfField.luau                     ← shared field: distance, gradient, AABB cull (v2/v3)
        ├── SdfDecimate.luau                  ← shared QEM edge-collapse decimator (v2/v3)
        ├── SdfMcsg.luau                      ← MagicaCSG (.mcsg) text-model importer → op-graphs (docs/09)
        ├── SdfDocument.luau                  ← multi-part authoring: document → Model of MeshParts
        ├── Documents/
        │   └── Soldier.luau                  ← worked multi-part example (Lego soldier)
        ├── ProceduralModelKicker.luau        ← throttles bakes under the EM cap
        ├── ReplicatedAttributeRebake.luau    ← re-bake on server-driven attrs
        └── WorldAnimation/
            ├── GeneratorSignal.luau          ← wrap() for generators
            └── Generators/
                ├── GeneratorUtil.luau        ← snow/palette/mount helpers
                └── FluffyCloud.luau          ← runnable example generator
```

> **Three meshers, shared field.** `SdfMesher` (v1, docs `01`) is the original Surface-Nets engine
> — smooth, ships the generators. `SdfMesher2` (v2, docs `07`) adds **sharp features + QEM** on a
> uniform grid: crisp boxes & chamfers, nested CSG, minimal triangle counts. `SdfMesher3` (v3, docs
> `08`) is the **adaptive octree** engine — same op-graph as v2 but it refines only where the
> surface bends, so it's ~7× faster and produces clean minimal geometry directly (great for smooth
> "plastic-toy" content). v2 and v3 share the field evaluator (`SdfField`) and decimator
> (`SdfDecimate`). Organic/foliage → v1; **new work → v3** (fall back to v2's fixed grid if you need
> a guaranteed uniform resolution).

The modules are copied **verbatim** from a shipping project — known-working, heavily commented.

---

## Install

The `src/ReplicatedFirst` layout is load-bearing: the modules find each other through relative
`require` paths (e.g. `SdfMesher` lives at `ReplicatedFirst.SdfMesher`, `GeneratorSignal` at
`ReplicatedFirst.WorldAnimation.GeneratorSignal`). Keep that structure and the requires resolve
with zero edits.

### Option A — Rojo (recommended)

```bash
rojo serve        # then connect from the Roblox Studio Rojo plugin
```

`default.project.json` maps `src/ReplicatedFirst` → `ReplicatedFirst` in the DataModel, with
subfolders becoming `Folder` instances and `.luau` files becoming `ModuleScript`s.

### Option B — manual paste or ScriptSync

If you use **ScriptSync**, just point your Studio `ReplicatedFirst` at this repo's
`src/ReplicatedFirst` folder and let it sync — done.

Otherwise recreate the tree under `ReplicatedFirst` in Studio (`.luau` files = `ModuleScript`s,
the rest are plain `Folder`s):
- `ReplicatedFirst/SdfMesher` — v1 mesher
- `ReplicatedFirst/SdfMesher2` — v2 sharp-feature mesher
- `ReplicatedFirst/SdfMesher3` — v3 adaptive octree mesher
- `ReplicatedFirst/SdfField` — shared field evaluator (v2/v3)
- `ReplicatedFirst/SdfDecimate` — shared QEM decimator (v2/v3)
- `ReplicatedFirst/SdfDocument` — multi-part document layer
- `ReplicatedFirst/Documents/Soldier` — worked example
- `ReplicatedFirst/Examples/EvalSet` — one-click eval-set bake
- `ReplicatedFirst/ProceduralModelKicker`
- `ReplicatedFirst/ReplicatedAttributeRebake`
- `ReplicatedFirst/WorldAnimation/GeneratorSignal`
- `ReplicatedFirst/WorldAnimation/Generators/GeneratorUtil`
- `ReplicatedFirst/WorldAnimation/Generators/FluffyCloud`

### What you actually need

`SdfMesher.luau` is fully self-contained (depends only on `AssetService` and the native
`vector` library) — for one-shot bakes that's the only file you need. Add `GeneratorSignal` for
ProceduralModel generators, and the `Kicker` once you have more than ~4 PMs baking at once.

---

## Quickstart 1 — one-shot bake (no ProceduralModel)

Paste into the command bar or a `Script` once the bundle is installed:

```lua
local SdfMesher = require(game.ReplicatedFirst.SdfMesher)

local result = SdfMesher.build(
    { ellipsoids = {
        { center = Vector3.new(0, 0, 0), semi = Vector3.new(8, 8, 8) },
        { center = Vector3.new(6, 4, 0), semi = Vector3.new(5, 5, 5) },
    } },
    { smoothBlend = 2, renderFidelity = Enum.RenderFidelity.Precise,
      collisionFidelity = Enum.CollisionFidelity.Box }
)
local mp = result.meshPart
mp.Anchored = true
mp.Position = Vector3.new(0, 20, 0)
mp.Parent = workspace
```

## Quickstart 2 — the fluffy cloud as a live ProceduralModel

```lua
local pm = Instance.new("ProceduralModel")
pm.Size = Vector3.new(120, 80, 120)     -- drives the cloud's dimensions
pm.Generator = game.ReplicatedFirst.WorldAnimation.Generators.FluffyCloud
pm.Parent = workspace
-- Re-tune live: change any attribute and it re-bakes.
pm:SetAttribute("SmoothBlend", 9)       -- puffier
pm:SetAttribute("Seed", 7)              -- a different cloud
```

With many PMs in a scene, start the throttle once on the client so you stay under Roblox's
~7-concurrent-EditableMesh cap:

```lua
require(game.ReplicatedFirst.ProceduralModelKicker).start()
```

See [`docs/05-cookbook.md`](docs/05-cookbook.md) for the cloud's tuning table plus faceted
crystals, skinned branches, and snow.

---

## Notes for sharing / cleanup

- **Code is verbatim** from the source project. The modules carry generous diagnostic `print`/
  `warn` lines and comments that occasionally reference the original project's *other*
  generators (e.g. `Landmass`, `TallGrass`, `RockCrystal`) purely as examples — those are
  comments, not dependencies, and nothing breaks without them. Strip the diagnostics if you
  want a quieter console.
- **`GeneratorUtil`** reads optional globals (`ReplicatedStorage.WorldSettings.SnowAmount` /
  `LeafAmount`, and a `ReplicatedStorage.Palettes.<Name>` Configuration for palette colors).
  All of these **degrade gracefully** — missing values fall back to sensible defaults, so the
  helpers work in a bare place.
- **Skinning caveat:** there is a current Roblox regression where the two-step bake
  (`CreateDataModelContentAsync` → `CreateMeshPartAsync`) strips bone data during cook.
  `SdfMesher.build` uses the two-step path. For static geometry that's ideal (best fidelity);
  for skinned meshes that must deform, route the bake single-step. See `docs/02` and `docs/06`.
- Licensed **MIT** (see [`LICENSE`](LICENSE)) — use it however you like, just keep the notice.

---

## Where to go next

**Read [`docs/README.md`](docs/README.md)** — it has the full mental model, the end-to-end
pipeline diagram, and the recommended reading order. The headline worked example
("Make me a procedural model of an SDF fluffy cloud") is in
[`docs/05-cookbook.md`](docs/05-cookbook.md).
