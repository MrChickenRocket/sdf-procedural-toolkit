# 07 — SdfMesher2 (the sharp-feature mesher) + the document layer

`ReplicatedFirst/SdfMesher2.luau` is a **second-generation mesher**, written after the
v1 `SdfMesher` to handle the things v1 is worst at: **crisp hard edges** (boxes, chamfers),
**nested CSG**, and **minimal triangle counts**. v1 (plain Surface Nets, flat union/subtract)
rounds every sharp edge and emits dense meshes; v2 keeps edges crisp, curves smooth, and
decimates to a handful of triangles.

> **Status (2026-06-20): working, validated, still WIP.** It cleanly meshes box / chamfered box
> / rounded box / cylinder / chamfered cylinder / rounded cylinder and the example soldier.
> Known rough edges are listed under **Limitations & roadmap** at the bottom — read those before
> you push on performance or thin features.

v1 and v2 coexist. v1 still backs the shipping generators (FluffyCloud etc.); v2 is the path for
hard-surface / mechanical content. They share nothing but the EditableMesh bake pattern.

---

## The one-paragraph model

You hand v2 an **op-graph**: a tree whose leaves are primitives and whose interior nodes are CSG
operators. It samples the combined signed-distance field on a grid, extracts the surface with
**Surface Nets**, but places each cell's vertex with a **regularized QEF** that *snaps to sharp
corners/edges where the field's normals genuinely diverge* and stays smooth everywhere else.
It then **QEM-decimates** down to minimal geometry (collapsing flat/curved regions, preserving
sharp edges), and shades with **analytic gradient normals** (split to face normals at hard
edges). Primitives in, one crisp low-poly `MeshPart` out.

```lua
local SdfMesher2 = require(game.ReplicatedFirst.SdfMesher2)
local result, msg = SdfMesher2.build(rootNode, config)   -- result.meshPart, or nil + msg
```

---

## Input — the op-graph

A **node** is either a primitive **leaf** (has `shape`) or an **op** (has `op` + `children`).
They're plain tables; nest them freely.

### Leaves (primitives)

```lua
{ shape = "sphere",    center = Vector3, radius = n }
{ shape = "ellipsoid", center = Vector3, semi = Vector3 }            -- uniform semi = sphere fast path
{ shape = "box",       center|cframe, semi = Vector3, rounding = n?, bevel = n? }
{ shape = "capsule",   a = Vector3, b = Vector3, radius = n }
{ shape = "cylinder",  center|cframe, radius = n, height = n, rounding = n?, bevel = n? }
```

- **box** is **sharp by default** (no `rounding=nil`→ellipsoid overload like v1's slab).
  `rounding > 0` = soft rounded edges; `bevel > 0` = **hard flat 45° chamfer** (bevel wins if both).
- **cylinder** is capped (flat ends), axis = the frame's up vector; `rounding`/`bevel` treat the
  rim exactly like the box edges.
- Oriented box/cylinder: pass `cframe` (orthonormal, comes free from any `Part.CFrame`); else
  `center` for axis-aligned.

### Ops

```lua
{ op = "union",       children = {...} }              -- min
{ op = "smoothUnion", blend = n, children = {...} }   -- polynomial smooth-min (metaball blend)
{ op = "subtract",    children = { base, cut1, ... } }-- base minus the rest
{ op = "intersect",   children = {...} }              -- max
```

Nesting is the "operand chain": `subtract( smoothUnion(a,b,c), cutter )` etc.

> ⚠️ **Subtract cutters must pass CLEAN THROUGH the solid.** A cutter that ends *inside*
> (a blind hole) leaves a thin domed cavity end that seams the nearby outer surface at practical
> cell sizes. Start the cutter outside one face and end it outside another. (See `06-gotchas`.)

---

## Config — `SdfMesher2.Config`

```lua
{
    -- resolution (pick one)
    cellSize = n?,            -- explicit cell size in studs
    cellsPerDim = n?,         -- cells along the longest axis (default 48)
    boundsPadding = 1.5,

    -- sharp-feature controls
    featureAngle = 25,        -- a cell is "sharp" (→ QEF snap) only if its crossing normals
                              -- span > this many degrees; below it use the smooth mass point
    qefBias = 0.06,           -- QEF regularization toward the cell mass point
    sharpAngle = 38,          -- shading: face-corner uses the crisp face normal (not the smooth
                              -- analytic one) when they differ by more than this

    -- decimation (QEM) — on by default
    decimate = true,
    triCap = 20000,           -- hard ceiling; forces collapses past the feature gate while over it
    qemTargetReduction = 1.0, -- 1.0 = "remove everything the error gate allows" (minimal)
    qemMaxError = cellSize^2*3,-- the real quality knob: higher = more aggressive on curves

    -- output
    vertexColorFn = nil,      -- (vertex, normal, {}, crease) -> Color3   (normal is exact here)
    renderFidelity, collisionFidelity, fluidFidelity = nil,
}
```

### The knobs that matter

1. **`cellSize`** — the dominant cost driver (see Performance). Finer = more detail but the grid
   grows cubically. With the sharp/smooth handling, you need *far* coarser cells than you'd
   expect: **0.10–0.15 stud is plenty** for most shapes. Reserve sub-0.06 for genuinely tiny
   features (thin bores) and expect it to be slow.
2. **`featureAngle`** — the smooth↔sharp threshold. Lower = more things treated as sharp (crisper
   but more prone to jagged fake-creases on tight blends); higher = smoother. 25° is a good
   default; raise toward 40° if tight blends jag.
3. **`qemMaxError`** — how hard decimation pushes. Higher = fewer triangles, coarser curves.

---

## Output — `SdfMesher2.Output`

```lua
{
    meshPart, triCount, vertCount, cellSize, gridDims,
    timings = { sdf, extract, decimate, bake, total },   -- seconds
}
```

`build` also **prints a timing line** to the console every bake:

```
[SdfMesher2] cell 0.150 | grid 70x82x54 | 20060→1048 tris | sdf 680ms  extract 941ms  decimate 1225ms  bake 59ms  total 2905ms
```

`A→B tris` is raw-surface-nets → post-decimation. Watch the `extract`/`decimate` split when tuning.

---

## How `build` works (so you can reason about failures)

1. **Bounds** = op-graph AABB + padding. Per-node AABBs are stamped for **culling** (a sample
   outside a node's box short-circuits its whole subtree — big win for many-primitive graphs).
2. **Sample** the field at every grid corner (`evalNode`).
3. **Extract** — per sign-changing cell, gather edge crossings + their **analytic gradients**.
   Measure the normal-cone spread: if it's within `featureAngle` (smooth) place the **mass point**;
   otherwise solve a **regularized QEF** that snaps to the corner/edge. Stitch quads.
4. **Decimate** (QEM edge-collapse) on the buffered triangles *before* the EditableMesh — flat &
   curved regions collapse fully, sharp edges survive and get straightened. Also lifts the
   EditableMesh ~21k-triangle hard cap (output is what's capped, via `triCap`).
5. **Normals** — per vertex from the analytic field gradient (smooth even on uneven triangulation),
   per face-corner falling back to the geometric face normal at hard edges. Bake to `MeshPart`.

---

## The document layer (`SdfDocument`)

`ReplicatedFirst/SdfDocument.luau` is the multi-part authoring layer (a "document" = a list of
bake **groups**, each → one MeshPart; see `03`/the soldier). It targets **both** meshers:

- `SdfDocument.bake(doc, opts)` — v1 (`SdfMesher`), smooth.
- `SdfDocument.bakeV2(doc, opts)` — v2 (`SdfMesher2`), crisp + minimal. Internally
  `SdfDocument.toGraph(group)` compiles a group's flat prim list into a v2 op-graph
  (adds → `smoothUnion`/`union`, `op="subtract"` prims → `subtract`).

`Documents/Soldier.luau` is the worked example; bake it with either path. v2 gives ~2.7k tris with
crisp boots/helmet/gun vs ~28k smooth from v1.

---

## Performance

Cost scales with **grid cell count** (≈ `(size/cellSize)³`); `extract` and `decimate` dominate.
Measured (single shapes, this machine):

| cell | grid | example | total |
|---|---|---|---|
| 0.15 | ~50³ | soldier group | 0.5–3 s |
| 0.08 | ~113³ | box | ~7 s |
| 0.05 | ~150³ | gun | ~6 s |
| 0.025 | ~300³ | gun | **~120 s** ⚠️ |

**Takeaway: stay at 0.10–0.15 unless you truly need finer.** The quality work (analytic normals,
the smooth/sharp discriminator) is what makes coarse cells look good, so use them.

---

## Limitations & roadmap (read before extending)

- **Fine cells are slow** — there is no narrow-band/sparse sampling yet; the full grid is sampled
  and every surface cell runs the QEF. **The highest-value next task is a narrow-band extraction**
  (only process cells near the surface), which would make fine cells affordable and speed up
  everything. (A coplanar pre-merge before QEM, and a scalar-compiled CFrame transform to drop the
  per-sample `PointToObjectSpace` allocation, are smaller follow-on wins.)
- **Thin, grid-diagonal tubes** can show a faint Surface-Nets ridge seam at coarse cells; finer
  cells fix it (but are slow — see above).
- **Tight blends / blind subtracts** need either proportional resolution or authoring around
  (through-cuts, wider blends matched to the cell). See `06-gotchas`.
- No material/owner channel (colour is via `vertexColorFn`); no skinning/bones (v1 has those);
  `taperedCapsule` exists in v1 but not v2.

---

## Quickstart

One-click: bake the whole eval set (all six shapes in a row) from the command bar —
```lua
require(game.ReplicatedFirst.Examples.EvalSet).run()
```

Or a single shape directly:
```lua
local M2 = require(game.ReplicatedFirst.SdfMesher2)
-- a chamfered box with a hole drilled clean through it
local res = M2.build({
    op = "subtract",
    children = {
        { shape = "box", semi = Vector3.new(3,3,3), bevel = 0.6 },
        { shape = "capsule", a = Vector3.new(0,0,-6), b = Vector3.new(0,0,6), radius = 1.2 },
    },
}, { cellSize = 0.12, renderFidelity = Enum.RenderFidelity.Precise })
local mp = res.meshPart
mp.Anchored = true; mp.Position = Vector3.new(0, 20, 0); mp.Parent = workspace
```
