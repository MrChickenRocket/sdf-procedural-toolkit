# 03 — ProceduralModels

A `ProceduralModel` is a Roblox instance with a **`Generator`** property pointing at a
ModuleScript. When the PM replicates or any attribute changes, the engine runs the module's
`OnGenerate`, which builds geometry into a target container. This turns an SDF bake into a
**live, artist-tweakable object**: drag the bounding box to resize, change an attribute in the
Properties panel, and it re-bakes.

This doc is the generator contract plus the infrastructure that keeps many PMs from blowing
the EditableMesh concurrency cap.

---

## The generator contract

A generator ModuleScript **returns exactly** `{ Attributes, OnGenerate }`:

```lua
local SdfMesher = require(script.Parent.Parent.Parent.SdfMesher)
local GeneratorSignal = require(script.Parent.Parent.GeneratorSignal)

-- Every field here becomes an editable property in the PM's Studio panel.
-- Changing any of them re-fires OnGenerate.
local Attributes = {
    Seed = 1,
    PuffCount = 95,
    SmoothBlend = 6,
    LightColor = Color3.fromRGB(255, 250, 240),
    Version = 0,                 -- conventional manual re-bake trigger (bump to force a rebake)
}

local function OnGenerate(parameters: any, targetContainer: Instance)
    local a = parameters.Attributes              -- the live attribute values
    local size = parameters.Size or Vector3.new(100, 100, 100)
    -- ... build primitives from a + size ...
    local result = SdfMesher.build(input, cfg)
    if not result then return end
    local mp = result.meshPart
    mp.Parent = targetContainer                  -- parent into the container, NOT workspace
end

return {
    Attributes = Attributes,
    OnGenerate = GeneratorSignal.wrap(OnGenerate),   -- ⭐ always wrap (see below)
}
```

### `parameters` — what OnGenerate receives

| Field | Meaning |
|---|---|
| `parameters.Attributes` | Table of the PM's current attribute values (your `Attributes` defaults, overridden by whatever is set on the instance). |
| `parameters.Size` | The PM's bounding-box size (`Vector3`). **This is how you scale** — drag the invisible bounds part in Studio and the shape resizes to fit. Drive dimensions off this, not off attributes. |
| `parameters.Pause` | A yield slot: call `parameters:Pause()` between cheap planning and the heavy bake so the engine's watchdog doesn't trip on large inputs. |

### Authoring conventions used in this project

- **File naming** (scriptSync): `*.luau` = ModuleScript, `*.client.luau` = client `Script`,
  `*.legacy.luau` = server `Script` with Legacy RunContext. Generators are plain `.luau`
  ModuleScripts.
- **Size drives dimensions, attributes drive style.** A cloud's width/height come from
  `parameters.Size`; `PuffCount`/`SmoothBlend`/colors come from attributes.
- **`Version` attribute**: a conventional integer you bump to force a manual re-bake (changing
  *any* attribute re-fires, so `Version` is just a no-semantic-meaning trigger).
- **Color attributes as palette keys**: store colors as **strings** naming an entry in
  `ReplicatedStorage.Palettes.<GeneratorName>` (a Configuration of Color3s), resolved via
  `GeneratorUtil.resolveColor(name, value, fallback)`. Lets you recolor every placed instance
  from one place. (Falls back to a literal Color3 for legacy data.)

---

## ⚠️ The generator sandbox is detached

A generator runs in an isolated sandbox, **not** as a child of the source instance. Critical
consequences:

- **Only `Pause`, `Attributes`, and `Size` pass through.** `targetContainer.Parent` is `nil`
  during generation — you cannot read sibling instances or walk up to Workspace. If a
  generator needs data about its neighbors, **serialize it into Attributes** beforehand.
- **A generator's `require()` chain is cached** inside the sandbox. After editing a required
  module (e.g. `SdfMesher`), the generator may keep running the *stale* version until a Studio
  restart forces a fresh load. When behavior is "spooky", drop a `print` / version-stamp
  diagnostic to confirm which version is actually running **before** theorizing.
  (`SdfMesher.VERSION` exists for exactly this.)
- **No module-level scratch state.** A yielding generator can be re-entered mid-bake (see
  below), and two concurrent runs sharing a module-level buffer corrupt each other. Keep all
  scratch **function-local**.

---

## ⚠️ ProceduralModel merges old + new geometry on re-bake

The engine does **not** auto-delete the previous bake's children before firing `OnGenerate`
again. Anything left in `targetContainer` **stays and merges** with the new output → doubled/
stale geometry. Two cases:

1. **You re-emit everything each bake** (the common case: one MeshPart named "Cloud"). A new
   bake naturally replaces it only if you clear first — but in practice re-emitting the same
   single child is fine because the engine reconciles same-shape output. Still, if you emit
   multiple children, **clear the container at the top of OnGenerate**.
2. **Children you *don't* re-emit** (e.g. emitted once, conditionally) stay forever. These
   can't be cleaned from inside `OnGenerate` (the container's parent is nil), so they need an
   external cleanup pass before the next kick.

`GeneratorSignal.wrap` warns loudly if the container has leftover children at OnGenerate start
— heed that warning.

---

## `GeneratorSignal.wrap` — always wrap OnGenerate

`GeneratorSignal.wrap(fn)` returns a wrapped OnGenerate that handles three things every
generator needs:

1. **Server bail.** During play, only **clients** bake. A play-mode server `OnGenerate` would
   produce racing/duplicate geometry and its EM allocations can't replicate cleanly, so the
   wrapper returns early on `RunService:IsRunning() and IsServer()`. Edit-time plugin bakes
   (`IsRunning() == false`) still proceed.
2. **Re-entrancy guard.** Because `OnGenerate` re-fires on every attribute change and the bake
   **yields** (AssetService calls are async), a second `OnGenerate` can start on the same PM
   mid-bake — two concurrent runs in one sandbox produce duplicate geometry and corrupt
   shared state. The guard (keyed by the PM's stable `Guid` attribute) short-circuits the
   re-entrant call and queues **one** deferred re-fire to run after the in-flight bake
   finishes, so the latest attribute snapshot still gets baked — just serially. PMs without a
   `Guid` attribute (single-shot bakes like Cloud/Tree) skip the guard.
3. **Done-signal handshake.** At the end of every (real) bake it fires
   `ReplicatedStorage.GeneratorDone`, which the Kicker uses to free a throttle slot.

You essentially never write `OnGenerate` without wrapping it.

---

## The Kicker — throttling under the EditableMesh cap

`ReplicatedFirst/ProceduralModelKicker.luau`. **Roblox allows only ~7 EditableMeshes alive at
once.** A scene with dozens of PMs that all auto-bake on replication blows that cap instantly.
The Kicker prevents it:

- **Detach, don't just queue.** When a PM replicates with `Generator` set, the engine
  auto-fires `OnGenerate`. So at startup the Kicker immediately **stashes and clears the
  `Generator` property** on every PM (which suppresses the auto-fire), then re-attaches them
  through a throttled queue one at a time. New PMs arriving later go through the same
  stash → queue → restore path (it hooks `DescendantAdded` at require-time).
- **`IN_FLIGHT_CAP = 4`** concurrent bakes. Each dispatch waits for a `GeneratorDone` fire (or
  a `KICK_TIMEOUT` fallback so an erroring generator can't deadlock the queue) before freeing
  its slot.
- **One trigger per kick.** Restoring `Generator` (nil → module) *and* bumping `Version` are
  **both** independent regen triggers — doing both fires `OnGenerate` twice and stacks
  duplicate meshes. The Kicker picks exactly one.
- **Layer ordering.** A PM with a higher `Layer` attribute won't dispatch until all lower
  layers finish baking — so consumers (a fence raycasting against terrain, decals reading a
  baked spline) only fire after their dependency exists.

Public API:

```lua
local Kicker = require(game.ReplicatedFirst.ProceduralModelKicker)
Kicker.start()                         -- sweep existing PMs + begin draining (call once, client)
Kicker.rekick(pm)                      -- re-bake one PM through the throttle
Kicker.rekickWhere(pred)               -- re-bake every PM matching predicate(pm)
Kicker.freeze(pm)                      -- detach Generator WITHOUT queueing (then write attrs, then rekick)
Kicker.getActiveGenerator(pm)          -- live Generator, or the stashed copy if frozen
```

> If you have only a handful of PMs you can skip the Kicker and let the engine auto-bake — but
> the moment you have more than ~4 baking at once, add it or you'll hit the EM cap.

---

## Server-driven attributes: `ReplicatedAttributeRebake`

Another Roblox quirk: **a ProceduralModel does NOT auto-re-bake on a client when the server
changes a replicated attribute.** The value lands on the client's PM and `AttributeChanged`
fires, but the engine's bake hook only triggers for changes made in *this* process. So a
server-side director writing seasonal palette attributes would never visually update.

`ReplicatedFirst/ReplicatedAttributeRebake.luau` fixes it: hook `AttributeChanged` on every PM
and, on any non-`Version` change, schedule a **deferred** `Kicker.rekick(pm)`. The defer
coalesces a batch of writes (a director touching 7 attributes in one frame) into a single
re-bake, and routing through the Kicker keeps the batch under the EM cap. Call
`ReplicatedAttributeRebake.start()` once on the client.

> You only need this if a **server** script (or anything in another process) drives PM
> attributes. Purely client-authored attribute changes re-bake on their own.

---

## Minimal startup wiring (client)

```lua
-- In a ReplicatedFirst client Script (Bootstrap):
local ReplicatedFirst = game:GetService("ReplicatedFirst")
require(ReplicatedFirst.ProceduralModelKicker).start()
require(ReplicatedFirst.ReplicatedAttributeRebake).start()   -- only if server drives attrs
```

---

## Next

- The actual shape-building math → [`01-sdf-mesher.md`](01-sdf-mesher.md)
- Make it look good → [`04-vertex-shading.md`](04-vertex-shading.md)
- A complete cloud generator front to back → [`05-cookbook.md`](05-cookbook.md)
