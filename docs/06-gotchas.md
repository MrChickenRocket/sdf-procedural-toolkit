# 06 — Gotchas (the consolidated "this bit me" table)

Skim this before debugging. Each row is a real, hard-won failure mode from shipping these
techniques. Grouped by pillar; the deep explanation lives in the linked doc.

---

## EditableMesh & baking

| Symptom | Cause | Fix |
|---|---|---|
| Mesh invisible from the angle you expect / visible only from the wrong side | Triangle winding | Swap two of the three ids in `AddTriangle`. (`02`) |
| `SetVertexNormal` / `SetVertexColor` / `SetVertexUV` is not a valid member | Those don't exist — attributes are **per face-corner** | Use `SetVertexFaceNormal/Color/UV(vid, faceId, attrId)`. (`02`) |
| Engine crashes after many bakes ("EditableMesh allocation limit") | Leaked EMs — hard concurrent cap | `em:Destroy()` immediately after `Content.fromObject(em)`, every time. |
| Mesh renders coarser/jaggier than expected | Fidelity opts on only one bake call | Pass `RenderFidelity`/`CollisionFidelity`/`FluidFidelity` to **both** `CreateDataModelContentAsync` and `CreateMeshPartAsync`. |
| Skinned mesh won't deform; `HasSkinnedMesh = false` | **Roblox regression**: two-step bake strips bones during cook | Single-step: `CreateMeshPartAsync(Content.fromObject(em), opts)` directly. (`02`) |
| Vertex colors look wrong / washed / tinted | `meshPart.Color` set non-white multiplies the baked colors | `meshPart.Color = Color3.new(1,1,1)` (Neon: knock to ~200,200,200 for headroom). |
| `Content` is nil inside a generator | `Content` is fenv-only in generator sandboxes | `local Content = (getfenv(1) :: any).Content`. |
| Argument-type error passing `Content.fromUri(meshPart.MeshContent)` | `MeshContent` is already a `Content`, not a URI | Pass `meshPart.MeshContent` directly to `CreateEditableMeshAsync`. |
| Multi-part figure's pieces scatter / float / pile up at the origin | Assumed `build` re-centers each mesh on its bbox; it **keeps the authoring coordinates** and the MeshPart's origin is the authoring `(0,0,0)` | Author all parts in **one shared frame**, build each separately, then give **every** part the **same** `Position` (the global placement). Do **not** add a per-part bounds-centre. (See "Assembling multi-part figures" below.) |
| `Position - Size/2` doesn't match where the mesh actually is | The part origin is the authoring origin, **not** the bbox centre, so that formula is meaningless for these meshes | **Raycast** the part (down from above / up from below) to find true world extents. |

## Skinning / bones

| Symptom | Cause | Fix |
|---|---|---|
| Bone Instance moves but mesh doesn't deform | Animating via `bone.CFrame` | Animate via **`bone.Transform`** (offset from bind). `bone.CFrame` is the bind pose — never touch it to animate. (`02`/`04`) |
| Mesh renders but no Bone Instances under the MeshPart | `em:AddBone` stores skin data only | Post-bake `Instance.new("Bone")` per bone, matching `.Name` + `.CFrame` exactly, parented appropriately. |
| Bones exist but mesh pinned to bind pose | Bind CFrame or Name on the Instance doesn't exactly match `AddBone` | Match both exactly; bind CFrame must be in the same space as the vertex positions. |
| "Weights doesn't match ids" warning | Zero entry in the weights array, or > 4 bones | Filter zero weights **and** their matching ids; cap to top-4 and normalize. |
| Some vertices deform, others snap weirdly | > 4 bones influencing them, or a stale bone id | ≤ 4 bones/vertex; only use ids returned by `em:AddBone`. |

## SDF meshing

| Symptom | Cause | Fix |
|---|---|---|
| Open-polyline rings / sharp axis-aligned bake corruption | A primitive (often a subtract cutter) sticks past the grid bounds | Grid must enclose **all** primitives; raise `boundsPadding` (and `primitiveSpill` under heavy blend). (`01`) |
| Diamond-shaped holes along merge seams | Hard-min saddle artifact where two prims graze | Use a small `smoothBlend` (> 0). It bulges the junction instead of leaving a saddle. |
| Sliver "tooth" triangles at junctions when blending | 3-corner hole-fill fires under smooth-min | Expected — hole-fill is disabled under smooth-min by design; tune blend/resolution instead. |
| NaN vertices / broken bake | `math.huge` flowed into interpolation (`inf-inf`/`inf/inf` = NaN) | Use a large finite sentinel like `1e6`/`1e9`. |
| Shape is 2× the size you intended | `semi` is **radius**, not diameter | Halve your numbers. |
| Slow bake + `triangle-cap retry` warnings | The **decimated** output still exceeded `triCap`; whole splat+decimate re-runs coarser | Raise `triCap`, lower `initialMaxCellsPerDim`, or simplify input. (`triCap` is checked *after* QEM decimation, so retries are now rarer.) |
| `result` is nil | Empty/degenerate input or no surface crossed zero | Check first return value + `msg` before using `result.meshPart`. |
| Slab/wedge placed & sized right but shaded inside-out | Left-handed `right`/`up`/`forward` basis — Roblox silently mirrors | Ensure `right × up == forward` (right-handed). (`04`) |
| Box edges came out **rounded** when you wanted crisp flat facets | `rounding` (any name notwithstanding) **rounds** edges; it does not chamfer them | Use `bevel = n` on the Slab for a **hard flat 45° chamfer** (overrides `rounding`). Works on `subtractSlabs` too. (`01`) |
| Subtract cutter (incl. `subtractCapsules`) corrupts the bake | Cutter pokes past the grid; `computeInputBounds` ignores subtracts so they don't grow the AABB | Make sure every subtract lies inside the **union** prims' padded bounds; raise `boundsPadding`. (`01`) |
| Drilled bore / thin carved feature comes out a mangled dimple (or vanishes) | The remaining **wall** (or the hole itself) spans `< ~2 cells`; surface nets can't resolve an inner *and* outer surface inside one cell | Size it so **both** the wall thickness **and** the hole radius are `≥ ~2–3 × cellSize`. For a small part, drop the cell size (raise `initialMaxCellsPerDim`) — e.g. boring a 0.55-radius barrel needs `cell ≈ 0.06` for a clean hole, not `0.13`. Same rule for thin subtract slabs and thin walls generally. |
| `vertexColorFn` can't tell which body part a vertex belongs to | Nothing tags the geometry by region | Tag each primitive's `boneWeights = {{key="skin", w=1}}` (a region name, not a real bone); in `vertexColorFn` pick the **max-weight key** from the `weights` table. Works with **no `bones` declared** — the weight tally is built for coloring regardless of skinning. (`04`) |

## ProceduralModels

| Symptom | Cause | Fix |
|---|---|---|
| Doubled / stale geometry after re-bake | PM does **not** auto-delete previous children; they merge with new output | Clear `targetContainer` at the top of `OnGenerate` if you emit multiple children; heed the leftover-children warning from `GeneratorSignal.wrap`. (`03`) |
| Duplicate geometry mid-tuning | Re-entrant `OnGenerate` (attr change during the yielding bake) | Wrap with `GeneratorSignal.wrap` (guards by `Guid`, queues one deferred re-fire). |
| Server produces racing/duplicate bakes in play | Server ran `OnGenerate` | `GeneratorSignal.wrap` bails on the play-mode server; only clients bake. |
| EM cap blown at startup with many PMs | Engine auto-fires every PM's `OnGenerate` on replication | Use the Kicker: stash+clear `Generator`, re-attach through the `IN_FLIGHT_CAP` queue. (`03`) |
| Double-baked geometry from the Kicker | Restoring `Generator` **and** bumping `Version` both trigger regen | Trigger exactly one per kick (the Kicker does this). |
| Server attribute change doesn't re-bake on clients | Engine bake hook only fires for same-process changes | `ReplicatedAttributeRebake.start()` → deferred `Kicker.rekick` on `AttributeChanged`. |
| Generator can't see sibling instances / Workspace | Generator sandbox is detached; `targetContainer.Parent == nil` | Serialize needed data into `Attributes` beforehand. Only `Pause`/`Attributes`/`Size` pass through. (`03`) |
| Edits to a required module (e.g. SdfMesher) seem ignored | Generator caches its `require()` chain in the sandbox | Restart Studio to force a fresh load. Drop a `print`/`SdfMesher.VERSION` stamp to confirm which version runs **before** theorizing. |
| Concurrent OnGenerate calls corrupt each other | Module-level scratch state shared across runs | Keep all scratch function-local. |
| Shape doesn't resize when you drag it | Dimensions hard-coded instead of read from `parameters.Size` | Drive dimensions off `parameters.Size`; reserve attributes for style. |

## Project conventions

| Convention | Detail |
|---|---|
| Announce MCP Studio actions | Print a Studio-console notice **before and after** any MCP action that touches Studio, every time. |
| File naming (scriptSync) | `*.luau` = ModuleScript, `*.client.luau` = client Script, `*.legacy.luau` = server Script (Legacy RunContext). |
| Disk edits auto-sync | scriptSync pushes disk edits into Studio on its own — don't also mirror them with `multi_edit`. |
| Don't weak-key tables on Instances | `__mode="k"` tables GC the Instance while it's still parented; use strong keys + `AncestryChanged` cleanup. |
| Prop day-animation | Use scale-shrink + `visible=false` toggles, not transparency tweens (multi-day fades look bad). |

---

## Assembling multi-part figures ("Lego" composition)

To build a figure out of **separate MeshParts** — skin in one, helmet in another, gun in
another — so that parts **don't blend into each other** (crisp seams) while ops *within* a part
still melt together: run **one `build` per part** and parent the results under a `Model`.

Two facts make or break the assembly:

1. **`build` preserves authoring coordinates.** The output MeshPart's origin is the authoring
   `(0,0,0)` — not the mesh's bounding-box centre. So every part already carries the full shared
   frame. **Give every part the same `Position`** (the world spot you want the authoring origin)
   and they line up. Adding a per-part bbox centre double-offsets and scatters them.
2. **`smoothBlend` only acts within a single `build`.** Separate builds = hard seams between
   parts (parts just overlap/socket like Lego); the blend melts only the primitives you passed
   into that one call. Tune blend per part (e.g. legs→pelvis wants ~0.4; over-blending fuses the
   legs into a cone whose lower half tapers to a near-invisible point — looks like a "gap").

```lua
local OFFSET = Vector3.new(40, 0.15, 0)   -- where the shared authoring origin lands in the world
local model  = Instance.new("Model")
for _, part in PARTS do                    -- each part = { input=..., blend=..., color=..., mat=... }
    local res = SdfMesher.build(part.input, {
        triCap = 20000, smoothBlend = part.blend,
        vertexColorFn = shade(part.color),       -- one base colour per part (no region tags needed)
        renderFidelity = Enum.RenderFidelity.Precise,
    })
    local mp = res.meshPart
    mp.Material = part.mat
    mp.Position = OFFSET                   -- ⭐ SAME for every part — do NOT add a per-part centre
    mp.Parent   = model
end
model.Parent = workspace
```

To keep surface density uniform across differently-sized parts, derive each part's
`initialMaxCellsPerDim` from a target cell size: `ceil((maxDim + 2*boundsPadding) / cell)` using
`SdfMesher.computeInputBounds(part.input, 0)` for `maxDim`. To verify alignment, **raycast** the
parts — `Position ± Size/2` lies (see the baking table above).

---

## Fast triage flow

1. **Nothing renders / renders inside-out** → winding (`AddTriangle`) or handedness (slab basis).
2. **Colors wrong** → `meshPart.Color` non-white, or fidelity/Neon clipping.
3. **Crashes after a while** → forgot `em:Destroy()`, or too many PMs without the Kicker.
4. **Holes / NaN / corrupt surface** → bounds don't enclose prims, `math.huge` sentinel, or
   hard-min saddle (add `smoothBlend`).
5. **Doubled geometry** → PM re-bake merge or re-entrancy → clear container + `GeneratorSignal.wrap`.
6. **Skinning dead** → `bone.Transform` vs `.CFrame`, or the two-step-strips-bones regression.
7. **Multi-part figure floats / scatters / piles at origin** → you added a per-part bbox centre
   to `Position`; `build` keeps authoring coords, so give every part the **same** `Position`.
8. **Box edges rounded when you wanted flat facets** → that's `rounding`; use `bevel` instead.
