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
│   └── 07-sdfmesher2.md       ← the v2 sharp-feature mesher + the document layer
└── src/
    └── ReplicatedFirst/
        ├── SdfMesher.luau                    ← v1 engine: Surface Nets, smooth (heart of it all)
        ├── SdfMesher2.luau                   ← v2 engine: sharp features + QEM minimal geometry (docs/07)
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

> **Two meshers.** `SdfMesher` (v1, docs `01`) is the original Surface-Nets engine — smooth,
> ships the generators. `SdfMesher2` (v2, docs `07`) is newer and aimed at **hard-surface /
> mechanical / CSG** content: crisp boxes & chamfers, nested boolean ops, and aggressive QEM
> decimation to minimal triangle counts. Organic/foliage → v1; boxes/machined → v2.

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

### Option B — manual paste

Recreate the tree under `ReplicatedFirst` in Studio:
- `ReplicatedFirst/SdfMesher` (ModuleScript)
- `ReplicatedFirst/ProceduralModelKicker` (ModuleScript)
- `ReplicatedFirst/ReplicatedAttributeRebake` (ModuleScript)
- `ReplicatedFirst/WorldAnimation/GeneratorSignal` (ModuleScript)
- `ReplicatedFirst/WorldAnimation/Generators/GeneratorUtil` (ModuleScript)
- `ReplicatedFirst/WorldAnimation/Generators/FluffyCloud` (ModuleScript)

`WorldAnimation` and `Generators` are plain `Folder`s.

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
