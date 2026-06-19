# 01 — The SDF Mesher

`ReplicatedFirst/SdfMesher.luau` is the engine. You hand it a table of **primitives** and a
**config**; it returns a baked `MeshPart`. This doc is the reference for that contract plus a
cookbook of how to express shapes as primitives.

```lua
local SdfMesher = require(game.ReplicatedFirst.SdfMesher)
local result, msg = SdfMesher.build(input, config)
-- result is nil on failure; msg is always a human string.
```

---

## What an SDF is (30 seconds)

A signed distance field is a function `f(point) -> number`: negative **inside** the shape,
positive **outside**, zero **exactly on the surface**. Each primitive has a cheap closed-form
SDF. To combine them:

- **Union** (add material): `min(a, b)` — the standard min of all add-primitives.
- **Subtraction** (carve): `max(field, -primitive)` — applied after the union.
- **Smooth union** (blend): a polynomial smooth-min that bulges grazing primitives together
  instead of leaving a crease. The single most important knob for organic shapes.

The mesher samples this field on a grid and extracts the `f = 0` isosurface. You never write
SDF math yourself — you just place primitives and pick a blend radius.

---

## Input — the primitive types

All positions are in the **same coordinate space you choose to author in** (commonly model-
local, centered on the origin). `semi` always means **semi-axes (radii), not diameters**.

```lua
type Input = {
    ellipsoids:        { Ellipsoid }?,
    slabs:             { Slab }?,
    capsules:          { Capsule }?,
    taperedCapsules:   { TaperedCapsule }?,
    subtractSlabs:     { Slab }?,         -- carve flat facets / holes (beveled cuts too)
    subtractEllipsoids:{ Ellipsoid }?,    -- carve rounded gouges
    subtractCapsules:  { Capsule }?,      -- drill round bores / grooves
    bones:             { BoneDecl }?,     -- skinning (see 02)
}
```

### Ellipsoid — the workhorse (foliage, clouds, blobs)

```lua
{ center = Vector3, semi = Vector3, boneWeights = { BoneWeight }? }
```

When all three `semi` axes are equal it's a **sphere** and hits a ~3× faster code path — for
big clusters (cloud puffs, leaf balls) prefer spheres where you can. Squash one axis for
flattened domes (snow caps), stretch one for eggs.

### Slab — oriented box or ellipsoid (architecture, planks, crystals)

```lua
{
    center = Vector3,
    right = Vector3, up = Vector3, forward = Vector3,  -- MUST be orthonormal
    semi = Vector3,                                    -- half-extents in (right, up, forward)
    rounding = number?,        -- nil = ellipsoid; 0 = sharp box; >0 = ROUNDED-edge box
    bevel = number?,           -- >0 = HARD flat chamfer on all edges (overrides rounding)
    centerOffset = Vector3?,   -- bake an off-axis bulge without rebuilding the frame
    boneWeights = { BoneWeight }?,
}
```

`rounding` and `bevel` pick the edge treatment (mutually exclusive — `bevel` wins if both set):
- `rounding = nil`, no `bevel` → oriented **ellipsoid** (soft, organic).
- `rounding = 0` → **sharp box** (`iq` `sdBox`) — crisp 90° edges for stone tiers, wood beams.
- `rounding > 0` → **rounded box** (`sdRoundBox`) — soft, radiused edges (rolled stone, worn
  wood). ⚠️ This **rounds** the edges; despite older "chamfer radius" naming it does **not**
  flat-cut them.
- `bevel > 0` → **hard-beveled box** — every edge sliced by a flat **45° facet** at chamfer
  depth `bevel`, with triangular facets where three cuts meet at a corner. The crisp, faceted,
  machined look: gemstones, armor plates, helmet shells, mechanical props. This is the *true*
  flat chamfer people reach for `rounding` expecting. (Implemented as the box intersected with
  its 12 edge planes; works on `subtractSlabs` too, for faceted **cuts**.)

> ⚠️ The `right`/`up`/`forward` basis must be **orthonormal and right-handed**
> (`right × up == forward`). A left-handed basis renders the slab inside-out with no error.
> See `04-vertex-shading.md` → CFrame handedness.

### Capsule — uniform-radius tube (branches, limbs, pipes)

```lua
{ a = Vector3, b = Vector3, radius = number, boneWeights = { BoneWeight }? }
```

A cylinder between points `a` and `b` with hemispherical caps. Capsules that share an
endpoint **merge smoothly under min-union** without an explicit joint sphere — chain them for
branches. A zero-length capsule degenerates cleanly to a sphere.

### TaperedCapsule — round cone (trunks, tapering needles, horns)

```lua
{ a = Vector3, b = Vector3, radiusA = number, radiusB = number, boneWeights = { BoneWeight }? }
```

Like a capsule but with a different radius at each end (`iq`'s `sdRoundCone`); the lateral
surface is tangent to both end-spheres so the silhouette stays clean. More expensive than a
plain capsule — use a `Capsule` when both radii would be equal. Pass whole arrays of these
for things like a ring of tapered needle clusters around a tree tier.

### Subtractions — carve the final union

`subtractSlabs` and `subtractEllipsoids` are the **same Slab/Ellipsoid types**, but evaluated
as `field := max(field, -primitiveSDF)` *after* the whole union is built — so they carve the
combined surface, not just one primitive.

- **subtractSlabs** → crisp **flat facets** (crystal/obsidian look; `rounding = 0` for sharp
  cuts, or `bevel > 0` to carve a chamfered notch). RockCrystal carves ~14 facets per rock.
- **subtractEllipsoids** → rounded **gouges** (arched doorways, carved bowls, eye sockets,
  mouse holes).
- **subtractCapsules** → round-section **bores and grooves** (bolt holes, gun-barrel bores,
  pipe lumens, a fuller groove down a blade, the slot a buckle threads through). A tube from
  `a` to `b` of `radius`; a (near) zero-length capsule punches a single round dimple. Start the
  cutter slightly *outside* the surface (extend `a`/`b` past it) so the opening is a clean full
  circle rather than a rounded-cap dimple.

> ⚠️ **Carved features must be resolvable.** A bore leaves a wall of `prim_radius −
> cutter_radius`; if that wall (or the hole) is thinner than ~2 cells the surface collapses
> into a mangled dimple. Size both ≥ ~2–3 × `cellSize`, or drop the cell size for that part
> (e.g. a 0.55-stud barrel bored to 0.32 needs `cell ≈ 0.06`). See `06` → carved-feature row.

Subtracts don't claim cell ownership and don't contribute skin weights. **All three subtract
types must still lie inside the grid bounds** — `computeInputBounds` ignores subtracts, so a
cutter poking past the padded AABB corrupts the bake (see `06` → bounds).

---

## Config — `SdfMesher.Config`

Every field is optional; defaults shown. Tune from the top group most often.

```lua
type Config = {
    -- ── Resolution & budget ───────────────────────────────────────────
    triCap = 20000,                  -- hard ceiling on triangle count
    initialMaxCellsPerDim = 60,      -- grid resolution: cells along the LONGEST axis
    boundsPadding = 1.5,             -- studs added around the primitive AABB
    smoothBlend = 0.0,               -- ⭐ polynomial smooth-min radius (studs). 0 = hard union

    -- ── Coarsen-on-overflow retry ─────────────────────────────────────
    maxCoarsenAttempts = 8,          -- if tris > triCap, grow cellSize and re-run
    coarsenFactor = 1.3,             -- multiplier per retry

    -- ── Shading hooks (see 04) ────────────────────────────────────────
    vertexColorFn = nil,             -- (vertex, normal, weights, creaseness) -> Color3
    debugVertexColors = false,       -- color each vertex by dominant bone instead

    -- ── Skinning ──────────────────────────────────────────────────────
    maxBonesPerVertex = 4,           -- engine hard cap is 4; do not exceed

    -- ── Fidelity (passed to BOTH bake calls) ──────────────────────────
    renderFidelity = nil,            -- Enum.RenderFidelity.Precise / Performance
    collisionFidelity = nil,         -- Enum.CollisionFidelity.Box for visual-only props
    fluidFidelity = nil,

    -- ── Advanced ──────────────────────────────────────────────────────
    primitiveSpill = 0.0,            -- extra AABB margin per prim (raise with heavy smoothBlend)
    qemTargetReduction = 0.6,        -- fraction of triangles QEM tries to remove
    qemMaxErrorThreshold = cellSize^2 * 0.25,
    qemLengthPenaltyWeight = 0.005,  -- tiebreaker so flat regions decimate uniformly
    qemMaxValence = 12,              -- reject collapses that would create hub vertices
}
```

### The three knobs you actually turn

1. **`smoothBlend`** — `0` for hard-edged unions (stone, architecture), `0.3–1.0` for foliage
   and props, higher for cloud-like melting. It eliminates the classic Surface-Nets "diamond
   hole" saddle artifact where two primitives graze: the surface bulges out at the junction
   instead. Distant primitives still collapse to plain `min`, so it's free where unused.

2. **`initialMaxCellsPerDim`** — resolution. More cells = finer detail but more triangles and
   slower bakes. This counts cells along the **longest** bounding axis; the others scale to
   match cell size. Clouds run ~20; detailed props 40–60.

3. **`triCap`** — your budget, measured on the **decimated** mesh (not the raw surface-nets
   output). Each attempt runs the full **splat → extract → QEM decimate** chain; only if the
   *decimated* count still exceeds `triCap` does the mesher **coarsen the grid and re-run the
   whole chain** (doubling/tripling wall time) and warn loudly. Because surface nets emits
   2–3× the final budget and decimation reclaims it, you usually keep a finer grid (more
   silhouette detail) than a raw-count cap would allow. If you still see triangle-cap retry
   warnings, raise `triCap`, lower `initialMaxCellsPerDim`, or simplify the input.

---

## Output — `SdfMesher.Output`

```lua
type Output = {
    meshPart: MeshPart,        -- the baked part. Parent it; set Material/Color/Anchored.
    triCount: number,
    vertCount: number,
    cellSize: number,          -- final cell size after any coarsen retries
    gridDims: Vector3,         -- nx, ny, nz
    primitiveCount: number,
    boneCount: number,
    coarsenAttempts: number,   -- > 1 means you overflowed triCap
    timings: Timings,          -- per-stage clocks (splat/extract/quads/decimate/bake/…)
}
```

The returned `meshPart` has **no Material/Color/parent set** beyond what the bake produced —
that's the caller's job. Per-vertex colors from `vertexColorFn` are baked in; keep
`meshPart.Color = Color3.new(1,1,1)` so they pass through unmultiplied (see 02 & 04).

---

## Helper functions on the module

Besides `build`, two public helpers reuse the exact same field math — useful for post-bake
geometry queries (snow placement, decal projection, sticking objects to a surface):

```lua
-- Returns f(point) for the combined field of an input (same union/subtract math).
local sdfFn = SdfMesher.makeSdfFn(input)
local d = sdfFn(Vector3.new(0, 10, 0))      -- < 0 inside, > 0 outside

-- World AABB of all union primitives (subtracts don't extend volume). nil,nil if empty.
local minV, maxV = SdfMesher.computeInputBounds(input, paddingStuds)
```

`GeneratorUtil.snowOnSurface` (see `04`) is built on these two: sphere-trace downward against
`makeSdfFn`, drop a flattened snow ellipsoid wherever a ray hits an up-facing surface.

---

## How `build` works internally (so you can reason about it)

You don't need this to use the mesher, but it explains the failure modes:

1. **Bounds** — AABB of all union primitives + `boundsPadding`. `cellSize = maxDim /
   initialMaxCellsPerDim`.
2. **Splat** — every primitive's SDF is evaluated over the cells in its AABB; `smoothMin`
   folds it into the running field. Each cell also remembers its **surface-closest** owning
   primitive (smallest `|d|`) for skin-weight attribution. Then subtracts carve via `max`.
3. **Surface Nets** — one dual vertex per sign-changing cell, placed at the averaged edge
   crossings; quads stitched across shared cell edges, triangulated. A multi-patch refinement
   emits a second vertex for cube-diagonal-split cells to kill spike artifacts.
4. **QEM decimation** — Garland-Heckbert edge collapse, curvature-preserving. Runs **inside**
   the attempt loop (steps 2–4 together), so the cap sees the simplified count.
5. **Coarsen check** — is the **decimated** tri count over `triCap`? Grow `cellSize` by
   `coarsenFactor` and redo 2–4. (Pre-2026-06 this checked the raw count *before* decimation
   and needlessly coarsened away detail.)
6. **EditableMesh** — `AddVertex`/`AddTriangle`; bones + `vertexColorFn` applied per face-
   corner; bake to `MeshPart`. (See `02`.) The baked part keeps the **authoring coordinates**
   — its origin is the authoring `(0,0,0)`, *not* the mesh's bbox centre (see `06` → assembly).

---

## Gotchas specific to the mesher

> The full cross-cutting list is in `06-gotchas.md`. These are the SDF-specific ones.

- **Bounds must enclose every primitive, including subtract cutters.** If a primitive sticks
  past the grid, you get open-polyline rings and corrupted bakes (sharp axis-aligned corner
  garbage is the telltale). `boundsPadding` covers smooth-blend spill; raise `primitiveSpill`
  too if you blend hard.
- **Hard-min (`smoothBlend = 0`) can leave diamond holes** along merge seams where two
  primitives graze at a saddle. The mesher patches most with a 3-corner fill, but the real
  fix is a small `smoothBlend`. Conversely, the 3-corner fill is *disabled* under smooth-min
  because it produces sliver "teeth" there — so don't expect hole-filling when blending.
- **Never feed `math.huge` as a position/size/sentinel that flows into interpolation.**
  `inf - inf` and `inf / inf` are `NaN`, which poisons the edge-crossing math and produces
  NaN vertices. Use a large finite value like `1e6`. (The mesher uses `1e6` as its own
  "far outside" SDF sentinel for exactly this reason.)
- **A `triangle-cap retry` warning means a slow bake.** It's not an error, but each retry
  re-runs the whole splat. Tune resolution/cap to avoid it in hot paths.
- **`semi` is radius, not diameter.** A `semi = Vector3.new(10,10,10)` sphere is 20 studs
  across. Off-by-2× sizing bugs almost always trace here.
- **An empty/degenerate input returns `nil, "No primitives"` / `"No surface produced"`.**
  Always check the first return value before touching `result.meshPart`.

---

## Next

- Author colors and bake details → [`02-editablemesh-and-baking.md`](02-editablemesh-and-baking.md)
- Make it a live, tweakable object → [`03-procedural-models.md`](03-procedural-models.md)
- Make it *look* good → [`04-vertex-shading.md`](04-vertex-shading.md)
- See it all assembled → [`05-cookbook.md`](05-cookbook.md)
