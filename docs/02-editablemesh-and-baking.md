# 02 — EditableMesh & Baking to a MeshPart

`SdfMesher.build` does all of this for you. Read this doc when you want to **build custom
geometry by hand** (non-SDF: grass blades, banners, terrain quads), **add colors/UVs/normals/
bones**, or **understand/debug** what the mesher does at the bake step.

The minimum-viable pipeline for "I want a custom-shaped colored MeshPart at runtime":

```
em = AssetService:CreateEditableMesh()
   → AddVertex / AddColor / AddUV / AddNormal  (each returns an id)
   → AddTriangle(vid, vid, vid)                (returns a faceId; WINDING matters)
   → per-face-corner attrs: SetVertexFaceColor/UV/Normal(vid, faceId, attrId)
   → optional: AddBone + SetVertexBones/SetVertexBoneWeights  (skinning)
content/meshPart = bake (two-step for static, single-step for skinned)
em:Destroy()                                   ← MANDATORY (hard concurrent EM cap)
   → set MeshPart props (Anchored, Color, Material, …); Parent it.
```

---

## ⚠️ Rule #1: winding order

`AddTriangle(a, b, c)` makes a face whose **front** is the side from which `a → b → c` reads
**counter-clockwise**. In Roblox's left-handed +Y-up world a **top face** (seen from above)
usually wants its XZ-CCW vertices passed as `AddTriangle(v1, v3, v2)` — i.e. **swap the last
two**.

> If your mesh is invisible from the angle you expect, or visible only from the "wrong" side:
> **swap two of the three vertex ids.** That is the bug ~90% of the time. Don't overthink it.

Vertex sharing is fine — reusing a `vid` in two triangles still lets each face carry its own
per-corner color/UV/normal, because those are keyed `(vertexId, faceId)`.

---

## Per-face-corner attributes — the API that confuses everyone

EditableMesh stores attributes **per face-corner**, not per vertex. There is **no**
`SetVertexColor`, `SetVertexNormal`, or `SetVertexUV`. The real pattern is always
*Add an attribute → get an id → assign that id to a (vertex, face) pair*:

```lua
local cid = em:AddColor(Color3.fromRGB(255, 128, 0), 1)   -- alpha optional
em:SetVertexFaceColor(vid, faceId, cid)

local uvid = em:AddUV(Vector2.new(0.25, 0.75))
em:SetVertexFaceUV(vid, faceId, uvid)

local nid = em:AddNormal(Vector3.new(0, 1, 0))
em:SetVertexFaceNormal(vid, faceId, nid)        -- NOT SetVertexNormal — that doesn't exist
```

Set the attribute for every `(vertex, face)` tuple you want to control — three calls per
triangle for full per-corner control, or all three to the same id for a flat look.

- **Normals**: skip them entirely and the bake auto-computes flat per-face normals (usually
  fine). Add them for smooth shading or to force a direction (e.g. forcing a bevel ring's
  normals to `+Y` so a dome fades smoothly into a flat top). Bulk setters exist:
  `SetFaceNormals(faceId, {n,n,n})`, `SetNormal(nid, vec)`, `ResetNormal(nid)`. Enumerate the
  faces on a vertex with `em:GetVertexFaces(vid)`.
- **UVs**: convention is **V=0 at the top of the texture, V=1 at the bottom**. A leaf with its
  root at the bottom of the texture wants tip vertices at V=0, base vertices at V=1. For
  per-instance sprite-atlas variants, pre-allocate the UV id set once and reuse a quadrant.
- **Colors**: see `04-vertex-shading.md` for the recipes. Keep `meshPart.Color =
  Color3.new(1,1,1)` or vertex colors get multiplied by the part color.

---

## The bake: two paths

> **Decision rule:**
> - **Static geometry (no bones)** → **two-step** bake, fidelity opts on **both** calls.
> - **Skinned geometry (`AddBone` / `SetVertexBones`)** → **single-step** bake. The two-step
>   path currently **strips bones during cook** (a Roblox regression).

`Content` is a regular global in normal scripts, but inside a ProceduralModel generator
sandbox you must grab it from the function environment: `local Content = (getfenv(1) :: any).Content`.

### Two-step (static EMs) — preserves fidelity

```lua
local FIDELITY = {
    RenderFidelity = Enum.RenderFidelity.Precise,        -- or Performance
    CollisionFidelity = Enum.CollisionFidelity.Box,      -- Box for visual-only props
    FluidFidelity = Enum.FluidFidelity.UseCollisionGeometry,
}
local Content = (getfenv(1) :: any).Content

-- Step 1: cook the EM into immutable, fidelity-locked Content.
local res, content = AssetService:CreateDataModelContentAsync(Content.fromObject(em), FIDELITY)
em:Destroy()                                              -- MANDATORY, right after fromObject
if res ~= Enum.CreateContentResult.Success then warn(res); return end

-- Step 2: wrap the baked Content in a MeshPart.
local meshPart = AssetService:CreateMeshPartAsync(content, FIDELITY)
```

**Why two steps:** `CreateDataModelContentAsync` is the "careful" pass — it bakes the final
GPU/physics representation at the requested fidelity. Passing the same opts to
`CreateMeshPartAsync` makes the resulting part instantiate with those properties already set
so the engine doesn't re-cook or re-apply defaults. **Pass fidelity to both calls** —
supplying it to only one silently downgrades render quality.

### Single-step (skinned EMs) — preserves bones

```lua
local opts = {
    RenderFidelity = Enum.RenderFidelity.Performance,
    CollisionFidelity = Enum.CollisionFidelity.Box,
    FluidFidelity = Enum.FluidFidelity.UseCollisionGeometry,
}
local Content = (getfenv(1) :: any).Content
local meshPart = AssetService:CreateMeshPartAsync(Content.fromObject(em), opts)   -- direct
em:Destroy()
```

The two-step path returns `HasSkinnedMesh = false` even when the EM had correct bones +
weights, with no warning and a `Success` result. Skip the Content-cook for anything that must
deform. (`SdfMesher.build` currently uses the two-step path for everything; if you need its
skinned output to deform reliably at runtime, route that path single-step.)

Both bake calls **yield** — if you call them from another yielding context (a ProceduralModel
`OnGenerate`), mind re-entrancy (see `03`).

---

## Configure the MeshPart after bake

```lua
meshPart.Name = "Whatever"
meshPart.Anchored = true
meshPart.Color = Color3.new(1, 1, 1)   -- WHITE = baked vertex colors pass through unmodified
meshPart.Material = Enum.Material.SmoothPlastic
-- Belt-and-suspenders: re-assert fidelity (some contexts drop it through migration). pcall'd
-- because these can be locked post-creation in some Studio versions.
pcall(function() (meshPart :: any).RenderFidelity = Enum.RenderFidelity.Precise end)
pcall(function() (meshPart :: any).CollisionFidelity = Enum.CollisionFidelity.Box end)
meshPart.Parent = wherever
```

For a **pure visual element** with no physics cost:
`CanCollide=false, CanQuery=false, CanTouch=false, CastShadow=false, AudioCanCollide=false`.
The cloud generator does exactly this.

---

## Bones / skinning (only if it deforms)

Full reference and a copy-paste minimal example are below the table. The five weight rules
that **break silently**:

| Rule | What breaks if violated |
|---|---|
| **≤ 4 bones per vertex** | Engine caps to 4; extras dropped, weights go weird |
| **No zero weights in the array** | Engine trims them, then warns "weights doesn't match ids" — filter zeros **and** their matching ids |
| **ids and weights arrays equal length** | Warning + skinning ignored for that vertex |
| **Weights sum to ~1.0** | Engine renormalizes; empty/negative → vertex pins to bind pose |
| **Bone id came from `em:AddBone`** | A stale id silently breaks that vertex |

Two-part lifecycle:

1. **Pre-bake**: `em:AddBone({ Name, CFrame = bindCFrame, ParentId?, Virtual = false })`
   stores only **skin data**. Declare parents before children (topologically sort). Then
   `em:SetVertexBones(vid, {ids})` + `em:SetVertexBoneWeights(vid, {ws})` per skinned vertex.
2. **Post-bake**: `AddBone` does **not** create `Bone` Instances. For each declared bone,
   `Instance.new("Bone")`, set `.Name` to the **exact** string and `.CFrame` to the **exact**
   bind CFrame you passed, and parent it to the MeshPart (flat) or to a parent `Bone`
   (nested). Miss any of these and the mesh renders but won't deform.

```lua
-- ⚠️ ANIMATE via bone.Transform, NOT bone.CFrame. This is the #1 skinning bug.
bone.Transform = CFrame.Angles(0.1, 0, 0)   -- deforms the mesh (offset from bind)
bone.Transform = CFrame.new()               -- reset to bind pose
-- bone.CFrame is the BIND POSE — set once at creation, never touch it to animate.
```

`Transform` is tween-able, settable every frame, and composes hierarchically
(`parent.Transform * child.Transform`). The bind CFrame must be in the **same coordinate
space as the vertex positions** you fed to `AddVertex`.

`SdfMesher` automates the entire bone pipeline: declare `bones = { {key, name, bindCFrame,
parentKey?, attributes?} }` and put `boneWeights = { {key="branch_3", w=1} }` on the
primitives. It tops-sorts, weights each vertex by the surface-closest owning primitive, keeps
the top-4, normalizes, and creates the post-bake `Bone` Instances mirroring `parentKey`.

---

## Other EditableMesh tricks

- **Vertex dedup**: `AddVertex` always returns a fresh id. To share corners, keep a
  `cache: {[Vector3]: vertexId}` and only `AddVertex` on a miss. `Vector3` works directly as a
  table key with exact float comparison.
- **Greedy meshing**: for grid-aligned filled regions, merge runs of full cells into max
  rectangles before triangulating — a 10×10 block goes 200 tris → 2.
- **Skip degenerate tris** (area < ε): they waste vertices and don't render.
- **Read geometry back**: `AssetService:CreateEditableMeshAsync(meshPart.MeshContent,
  {FixedSize = false})` then `em:GetVertices()` / `em:GetPosition(vid)`; world pos =
  `meshPart.CFrame * localPos`. Pass `meshPart.MeshContent` **directly** — it's already a
  `Content`, not a URI. `em:Destroy()` when done.

---

## Coordinate frames (where the MeshPart ends up)

Whatever frame you emit vertices in becomes the MeshPart's local mesh space. Roblox places
`MeshPart.CFrame` at the **centroid of the AABB** of your input vertices, and `Size` at the
AABB extents.

- **Emit world-space vertices** → the part lands at the geometry's world centroid. Simplest
  for static world geometry.
- **Emit pivot-local vertices** → the part is placed at the local-AABB centroid; under a
  `ProceduralModel` the engine applies the PM's pivot so it renders correctly anyway. Don't
  compute world AABBs from `Position ± Size/2` for non-origin-centered data — transform actual
  vertices by `meshPart.CFrame` instead.

---

## Next

- Wrap your bake in a live, attribute-driven object → [`03-procedural-models.md`](03-procedural-models.md)
- The classic EM gotchas table → [`06-gotchas.md`](06-gotchas.md)
