# 08 — SdfMesher3 (the adaptive octree mesher)

`ReplicatedFirst/SdfMesher3.luau` is the **third-generation mesher**. Where v2 samples a
**uniform grid** (cost ∝ volume) and decimates ~99% of the triangles away, v3 builds an
**adaptive octree** that only refines near the surface and only where the surface actually
**bends** — so flat / smooth / low-curvature regions get **large** leaf cells and tight rounds
& features get small ones. The result is clean, minimal geometry produced *directly*, and it's
**fast** because work scales with surface detail, not volume.

> **Status (2026-06-20): working, validated.** Box / chamfer box / round box / cylinder /
> chamfer cylinder / round cylinder / sphere and the multi-part soldier all bake crisp, smooth,
> watertight, and minimal. Built on the canonical Ju et al. 2002 Dual Contouring octree.

v1, v2 and v3 coexist and share the field evaluator (`SdfField`) and the QEM decimator
(`SdfDecimate`). Pick by content: v1 smooth organic (ships the generators), v2 uniform-grid
hard-surface, **v3 the default for new work** — fastest, cleanest, same op-graph input as v2.

---

## Why it's faster *and* cleaner

| | v2 (uniform grid + QEM) | **v3 (adaptive octree DC + QEM)** |
|---|---|---|
| box | 5050 ms → 28 t | **731 ms → 12 t** |
| cylinder | 5905 ms → 266 t | **775 ms → 138 t** |
| soldier (6 parts) | ~2.8–3.9 s, 8k–28k t | **~5 s, 2090 t** (3.4 s with `balance=false`) |

v2's floor is decimation, which scales with the **raw** triangle count set by cell size. v3 never
generates those raw triangles in the first place: the octree puts ~10× fewer cells on the surface,
so both Dual Contouring *and* the QEM cleanup run on a far smaller mesh. ~7× faster on single
shapes; on dense multi-primitive models it's comparable to v2 in wall-time but produces ~10× fewer
(equally clean) triangles.

---

## The one-paragraph model

You hand v3 the **same op-graph as v2** (primitive leaves under CSG operators). It:

1. **Builds an octree** — refine a cell while it's near the surface *and* the field still bends
   away from flat across it (a cheap one-sample "detail" test). Flat faces stay coarse; curves and
   creases refine.
2. **Places one QEF vertex per surface leaf** — snapping to sharp corners/edges where the field's
   normals genuinely diverge (same regularized QEF as v2), smooth mass-point elsewhere.
3. **Dual Contouring** the octree into quads — the canonical crack-free recursion, so leaves of
   wildly different sizes stitch with no holes or T-junction gaps.
4. **QEM-decimates** the result to truly minimal geometry (coplanar faces collapse, sharp edges
   survive). Cheap, because the input is already small.
5. **Analytic gradient normals**, split to face normals at hard edges. Bake to `MeshPart`.

```lua
local SdfMesher3 = require(game.ReplicatedFirst.SdfMesher3)
local res, msg = SdfMesher3.build(rootNode, config)   -- res.meshPart, or nil + msg
```

---

## Input — the op-graph

**Identical to v2** (see `07-sdfmesher2.md` → "Input"). Leaves: `sphere`, `ellipsoid`, `box`
(sharp / `rounding` / `bevel`), `capsule`, `cylinder` (sharp / `rounding` / `bevel`). Ops: `union`,
`smoothUnion` (`blend`), `subtract`, `intersect`. Same through-cut gotcha for subtracts.

The shared evaluator is `ReplicatedFirst/SdfField.luau` — distance, analytic gradient, AABB, and
per-node AABB **cull** boxes (so a multi-primitive group doesn't evaluate every leaf at every
sample). v3 calls `SdfField.prepare(root, margin)` once before meshing.

---

## Config — `SdfMesher3.Config`

```lua
{
    -- resolution / adaptivity
    minLeaf = n?,        -- finest cell (studs); detail floor (default ≈ longestAxis/64)
    maxLeaf = n?,        -- coarsest surface cell (default minLeaf*8)
    detailTol = 0.08,    -- THE quality/speed knob: subdivide while the field bends from flat by
                         -- more than detailTol*cellSize. Lower = finer & slower; higher = coarser
                         -- & faster. 0.08 is a good default; 0.04 high-detail, 0.14 fast/low-poly.
    subdivide = 0,       -- HERO QUALITY: N levels of ADAPTIVE subdivision. An edge splits only
                         -- where it's curved (its midpoint, projected onto the surface, leaves the
                         -- chord by > subdivideCurveTol·len); flat faces and crease edges don't
                         -- split, so a box stays 12 tris while curves get smooth. Faces re-cut
                         -- red-green by how many edges split → no T-junction cracks. Cheap (~linear
                         -- in tris). `uniform = true, subdivide = 2` is the recommended hero combo.
    subdivideCurveTol = 0.03, -- lower = subdivide gentler curves too (smoother, more tris)
    uniform = false,     -- force uniform minLeaf surface cells. The adaptive octree's mixed cell
                         -- sizes give curved surfaces a faint shading "wave" (uneven vertex
                         -- spacing); uniform cells fix it for genuinely crisp, wave-free curves —
                         -- at a big speed cost (a cylinder: ~0.3s adaptive → ~4s uniform). Use it
                         -- for hero/turned primitives; leave it off for organic content and the
                         -- adaptive speed. `EvalSet.runV3` uses it by default.
    balance = true,      -- 2:1-balance the octree. Keeps hard 45° chamfer creases clean (without
                         -- it they go wavy / spike). Smooth shapes barely trigger it; bevelled
                         -- ones do, at a moderate speed cost. Turn off for max speed on smooth-only
                         -- content.
    cullMargin = n?,     -- AABB-cull margin; raise if a big smoothUnion blend gets clipped

    -- features / shading (same meaning as v2)
    featureAngle = 25,   -- QEF sharp-snap threshold (deg)
    qefBias = 0.05,      -- QEF mass-point regularisation
    sharpAngle = 38,     -- shading: crisp face normal vs smooth analytic when they differ > this

    -- decimation (QEM) — on by default
    decimate = true,
    qemMaxError = n?,    -- default ≈ minLeaf²*3; higher = fewer tris on curves
    triCap = 40000,      -- hard ceiling on output triangles

    -- output
    vertexColorFn = nil, -- (vertex, normal, {}, crease) -> Color3
    renderFidelity, collisionFidelity, fluidFidelity = nil,
}
```

**`detailTol` is the dial you actually turn.** It replaces v2's `cellSize` as the primary control
and behaves better: it's curvature-relative, so it spends triangles where the shape needs them. On
the soldier, 0.04→0.08→0.14 walks 2424 t / 6.2 s → 1980 t / 3.4 s → 1552 t / 1.9 s. For smooth
"plastic-toy" content, 0.08–0.12 looks clean and bakes fast.

---

## Output — `SdfMesher3.Output`

```lua
{
    meshPart, triCount, vertCount, rawTris, leafCount,
    timings = { octree, qef, dc, decimate, total },   -- seconds
}
```

`build` also **prints a timing line** every bake:

```
[SdfMesher3] leaves 41315 | 12618→843 tris | octree 1790ms qef 153ms dc 400ms decimate 541ms bake 49ms total 2933ms
```

`A→B tris` is raw Dual Contouring → post-QEM. The `octree` phase is field sampling + the detail
test (the dominant cost on multi-primitive graphs); raise `detailTol` to cut it.

---

## The document layer

`SdfDocument.bakeV3(doc, opts)` bakes a multi-part document through v3 (mirrors `bakeV2`). Per
group you can set `g.detailTol` / `g.minLeaf`; the legacy `g.cell` is ignored (v3 is adaptive, not
fixed-grid). See `Documents/Soldier.luau` for the worked example — it bakes to ~1980 crisp tris
through v3.

---

## How `build` works (so you can reason about failures)

1. **Prepare** — `SdfField.aabb` for bounds, `SdfField.prepare` stamps per-node cull boxes.
2. **Octree** — recursive subdivide. A cell is a leaf unless: it's empty-but-huge (tree balance),
   or near-surface and bigger than `maxLeaf`, or near-surface and the **detail test** fails
   (`|field(centre) − mean(corner values)| > detailTol·size`). Sharp creases and curves spike the
   detail metric → refine; flat faces don't → stay coarse.
2b. **2:1 balance** — subdivide any leaf with a face-neighbour more than one level finer (located
   by point-descent from the root, ≤6 samples per leaf per pass, iterated to a fixed point). This
   grades cell-size transitions so a hard chamfer's crease vertices stay collinear instead of
   waving. Without it, a coarse flat-face cell next to fine crease cells places its dual vertex far
   from theirs → visibly lumpy bevels and corner spikes.
3. **QEF vertex per surface leaf** — edge crossings + analytic gradients → regularized QEF;
   normal-cone spread decides sharp-snap vs smooth mass-point. **Smooth vertices are then
   projected onto the iso-surface** with one Newton step (`p − field(p)·∇field(p)`). This is
   essential on an adaptive grid: the raw mass point sits *inside* a convex surface by a chord
   error that grows with cell size, so mixed-resolution curved regions otherwise barrel and wave;
   projecting onto `field = 0` lands every vertex on the true surface regardless of cell size.
4. **Dual Contouring** — `cellProc`/`faceProc`/`edgeProc`/`processEdge` (Ju et al. 2002, verbatim
   tables). Emits one quad per minimal sign-changing edge; leaves are reused as the recursion
   descends past them, so different leaf sizes stitch crack-free.
5. **QEM** (`SdfDecimate`) → minimal geometry.
6. **Reproject + relax** — snap every vertex back onto `field = 0` (QEM placed them at
   quadric-optimal points, off a curved surface), then a couple of **tangential relaxation**
   passes (move smooth vertices toward their neighbour centroid + reproject) to even out Dual
   Contouring's uneven spacing. Sharp vertices (incident faces diverge past `sharpRelaxAngle`) are
   pinned, so creases survive. (`reproject` / `relaxIters` config; both default on.)
7. **Analytic normals** (face-split at hard edges) → bake.

---

## Limitations & roadmap (read before extending)

- **Redundant corner sampling.** Adjacent octree cells and parent/child levels re-evaluate shared
  corners. A position-keyed sample cache would cut the `octree` phase further on dense graphs —
  the biggest remaining single win.
- **Curved surfaces show a faint shading "wave"** on the bare adaptive grid (uneven vertex spacing
  from mixed cell sizes). The **hero recipe `uniform = true, subdivide = 2`** removes it cleanly:
  uniform cells give even spacing, and adaptive subdivision+projection pulls curves smooth — sharp
  edges survive, and it's cheap (a cylinder: base ~2.5 s, +subdiv ~+0.7 s/level, vs ~145 s for an
  equivalently fine grid). For organic content the adaptive default is already smooth and fast.
  `subdivide` only splits curved edges (red-green, crack-free), so flat faces and sharp edges stay
  minimal — a box stays 12 tris while a sphere densifies.
  Tangential vertex relaxation was also tried (3 variants incl. flip-safe) but reliably dimpled
  curves near rims (reprojection jumps surface sheets), so it's off by default (`relaxIters = 0`,
  config-gated as experimental).
- **2:1 balance is the speed cost.** Hard 45° chamfer creases run diagonally across the
  axis-aligned octree, so without balancing they go wavy. The balance pass fixes that but roughly
  doubles the octree phase on feature-rich models (the soldier: 3.4 s → ~5 s). Smooth shapes barely
  trigger it. It also over-fires on smooth *curvature* gradients (which don't actually need it) —
  gating it to true sharp features (normal-cone) would recover most of the cost.
- **Sharp creases over-refine.** The field-nonlinearity detail test spikes at SDF kinks even
  though one QEF vertex represents them — so sharp features generate extra leaves that QEM then
  collapses. Harmless to output, but wasted work; a normal-cone gate could suppress it.
- **Double-crossing on a coarse leaf edge** (surface enters+exits one leaf edge) can in principle
  leave a tiny gap — prevented in practice by the near-surface refinement, guarded against crashes.
- Shares v2's gaps: no material/owner channel (colour via `vertexColorFn`), no skinning/bones,
  no `taperedCapsule`.

---

## Quickstart

```lua
local M3 = require(game.ReplicatedFirst.SdfMesher3)
-- a chamfered box with a hole drilled clean through it
local res = M3.build({
    op = "subtract",
    children = {
        { shape = "box", semi = Vector3.new(3,3,3), bevel = 0.6 },
        { shape = "capsule", a = Vector3.new(0,0,-6), b = Vector3.new(0,0,6), radius = 1.2 },
    },
}, { detailTol = 0.08, renderFidelity = Enum.RenderFidelity.Precise })
local mp = res.meshPart
mp.Anchored = true; mp.Material = Enum.Material.SmoothPlastic; mp.Reflectance = 0.1
mp.Position = Vector3.new(0, 20, 0); mp.Parent = workspace
```
