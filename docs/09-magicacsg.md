# 09 — MagicaCSG (.mcsg) import

`ReplicatedFirst/SdfMcsg.luau` imports [MagicaCSG](https://ephtracy.github.io/) `.mcsg` text
models into v3 op-graphs, so you can mesh real parametric-SDF models through `SdfMesher3`.

```lua
local SdfMcsg = require(game.ReplicatedFirst.SdfMcsg)
local parsed  = SdfMcsg.parse(mcsgText)              -- text → table
local graphs, skipped = SdfMcsg.toGraphs(parsed, { scale = 1/25 })
for _, g in ipairs(graphs) do                        -- g = { name, graph, color, prims }
    local res = SdfMesher3.build(g.graph, { vertexColorFn = ... })
    res.meshPart.Color = g.color
    res.meshPart.Parent = workspace                  -- parts share authoring origin → they assemble
end
```

> **Status: best-effort.** `cube` / `cylinder` / `sphere` import cleanly (with `round%`/`bevel%`).
> The bespoke parametric types (`polygon`, `triangle`, `jt`, `bezier`, `bpoly`, nested `csg`) are
> **skipped** and tallied in the returned `skipped` table — so e.g. a robot whose arms are `polygon`
> prims imports as a recognisable but armless figure. Extending coverage = adding those SDFs.

---

## The file format (reverse-engineered)

It looks like JSON but **isn't**: values are all **quoted strings** (numbers included), there are
**no commas**, `//` starts a line comment, and there are **no enclosing top-level braces** — the
file is a bare sequence of `"key" : value` pairs. `SdfMcsg.parse` is a tolerant tokenizer/parser for
exactly this (skips strays, so it's forgiving).

### Top-level sections

| key | meaning |
|---|---|
| `meta` | `{ "version": "730" }` |
| `render` | viewport/render settings (ignored) |
| `object` | **list of placed instances** — what actually gets drawn |
| `mtl` | material list (`metal`, `rough`, `ior`, `emit` …), indexed by `mid` |
| `palette` / `asset` | optional |
| `csg` | **list of CSG groups**, indexed by `cid` — the geometry |

### `object` — instances

Each entry **places a `csg` group** in the world:

```lua
{ "cid": "1"  "name": "wheel"  "mid": "0"  "res": "64"
  "r": "<3×3 matrix>"  "t": "<x y z>" }
```

- `cid` → index into `csg` (0-based). **Multiple objects can share one `cid`** — that's instancing
  (the demo car has four `wheel` objects all pointing at `csg[1]`, placed by four transforms).
- `name` → we use it as the MeshPart name; `mid` → material; `res` → MagicaCSG's voxel resolution.
- `r` `t` → the instance's transform (see **Transforms**).

### `csg` — groups of primitives

`csg` is a list; each element is a **list of primitives** that combine to one shape:

```lua
{ "type": "cube"  "mode": "sub"?  "blend": "22.00"  "rgb": "186 159 126"
  "r": "<3×3>"  "t": "<x y z>"  "s": "<sx sy sz>"  "round%": "0.3"  ... }
```

- **`type`**: `cube`, `cylinder`, `sphere` (supported) · `polygon`, `triangle`, `jt`, `bezier`,
  `bpoly`, `csg` (skipped). `subtype` refines some (`tri_iso`, `elli_l2s`).
- **`mode`**: `"sub"` = subtract. **Absent = add** (the default). Prims accumulate left-to-right.
- **`blend`**: smooth-union radius **in model units** (so it scales with the model). High values
  (the car/robot use 22) deliberately melt neighbouring prims together.
- **`op`** (on some prims): a *modifier*, not a boolean — `revolve` (lathe) / `torus` (wrap). Skipped.
- **modifiers** (fractions 0–1 of the size unless noted): `round%`, `bevel%`, `hole%`, `cone%`,
  `shell%`, `star%`, `n` (polygon sides), `top_v%`/`top_w%` (triangle), `half`, `power`.

### Transforms & coordinate system

- **`t`** = translation, **`s`** = per-axis **full size** (cube edge / cylinder diameter & height —
  so our half-extent `semi = s/2`), **`r`** = 3×3 rotation as 9 numbers.
- **`r` is row-major and uses the row-vector convention** — the three **rows** are the world
  directions of the primitive's local X/Y/Z axes. (Determined empirically: column-as-axis stands
  asymmetric parts on end.)
- **Z is up** in MagicaCSG; Roblox is Y-up. `toGraphs` maps `(x,y,z) → (x, z, −y)` by default
  (`flipY = false` to disable).
- Units are **voxel-scale** (hundreds). `scale` (default `1/30`) shrinks to studs — `1/25` suits the
  demo models. `s`, `t`, and `blend` are all scaled together.

### Mapping to our op-graph

| .mcsg | → op-graph node |
|---|---|
| `cube` | `box` (cframe from `r`+`t`, `semi = s/2`; `bevel%`/`round%` × min half-extent) |
| `cylinder` | `cylinder` (axis = local **Z**; `radius = s.x/2`, `height = s.z`) |
| `sphere` | `ellipsoid` (`semi = s/2`) |
| add prims | left-fold `smoothUnion` with each prim's `blend` |
| `mode:"sub"` | `subtract` (hard) of those prims from the add result |

---

## Wrapping a `.mcsg` for Studio

`.mcsg` files live on disk; ScriptSync only carries `.luau`. Wrap one as a string module (the shell
does this without the text ever leaving disk):

```bash
{ printf 'return [===[\n'; cat model.mcsg; printf '\n]===]\n'; } > McsgModels/Model.luau
```

then `SdfMcsg.parse(require(game.ReplicatedFirst.McsgModels.Model))`.

---

## Known gaps / next steps

- **Exotic primitives skipped** — `polygon` (n-gon prism with star/hole/cone/shell), `triangle`,
  `jt` (likely a joint/capsule between points), `bezier`/`bpoly` (swept curves), nested `csg`.
  Each needs its SDF written; `polygon` and `jt` are the highest-value (most common).
- **Per-prim subtract blend** is treated as a hard subtract (MagicaCSG can smooth-subtract).
- **Materials** (`metal`/`rough`/`emit`) aren't mapped to Roblox materials yet — only `rgb` colour.
- The rotation convention and `1/25` scale are empirical; verify against a model with a known
  orientation if something imports sideways.
