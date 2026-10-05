# Changelog

## Unreleased

A refactor for consistency (spec `2026-10-05-moonwell-systems-refactor-design` in the workspace). It breaks every
constructor call; nothing else a map sees changes, and every save code of 0.5 still decodes.

- Every constructor takes one options table; a system that needs a scheduler names it `clock`.
- Options and requests refuse a key they do not define: `unknown key 'maxHit'`. When several are wrong, the first in
  sorted order is named, the same on every machine. Buff definitions stay open for a map's own fields. The codec
  refuses unknown keys in its options, schemas and fields.
- Field errors name the key: `[systems] Missiles.launch: 'maxHits' expected a whole number of at least 1`.
- `Buff:remove(reason)` is now `Buff:dispose(reason)`, so everything a map owns ends with `dispose()`.
- `Aura.new` takes `interval`; `aura:start()` takes no argument.
- A buff definition is checked when first applied, not on every apply.
- `Signal:emit`, the buff store's poll and `Sync:dispose` no longer allocate per listener, per unit or per past
  request.

### Migrating from 0.5

| 0.5 | 0.6 |
|---|---|
| `Scheduler.new(step, onError)` | `Scheduler.new{step = step, onError = onError}` |
| `Signal.new(onError)`, `Scope.new(onError)` | `Signal.new{onError = onError}`, `Scope.new{onError = onError}` |
| `BuffStore.new(clock, options)` | `BuffStore.new{clock = clock, ...}` |
| `Aura.new(store, definition, source, query, onError)`, `aura:start(interval)` | `Aura.new{store = store, definition = definition, source = source, query = query, interval = interval, onError = onError}`, `aura:start()` |
| `Dummies.new(clock, options)`, `Missiles.new(clock, options)`, `Knockbacks.new(clock, options)` | `X.new{clock = clock, ...}` |
| `Sync.new(clock, options)`, `Savefile.new(clock, options)` | `X.new{clock = clock, ...}` |
| `buff:remove(reason)` | `buff:dispose(reason)` |

## 0.5.1 (2026-10-02)

- New `moonwell-library.json` at the library's root, naming `src` as its module folder. A map on Moonwell 0.6.0 or
  later leaves `dir = "src"` out of its `libraries` entry; an entry that still has it keeps working. With Moonwell 0.5,
  keep `dir = "src"`. moonwell-wrappers has the same file from `v0.8.1` on.
- `tools/integration.lua` runs the `moonwell` program of Moonwell 0.8.0 (on the PATH, or `MOONWELL`) in place of the
  Deno CLI; `MOONWELL_CLI` is gone and `MOONWELL_REPO` names the Moonwell checkout.
- The documents name YueScript 0.34.3, the compiler Moonwell 0.8.1 pins.

No library code changed: `src/` is that of 0.5.0.

### Release gate

Automated checks passed 2026-10-02 on Windows, with Moonwell 0.8.1, YueScript 0.34.3 and moonwell-wrappers `v0.8.1`:
21 suites (185 tests); Lua 5.3.6 syntax (51 files); integration, whose consumer map names both libraries by `path`
alone, so the files are what place their modules: normal and minified builds, LuaLS 3.19.1 fixtures (26 expected
negative diagnostics), `src/systems` against Moonwell's native declarations, all 15 entry points, and the five gate
examples with clean editor diagnostics.

The in-game gate was not re-run: no file under `src/` changed.

## 0.5.0 (2026-10-01)

Release 5 of the wc3-lib port, the last (spec `2026-10-01-moonwell-systems-release-5-design` in the Moonwell
repository).

- `systems.codec`: save codes packed by a versioned schema into 64 symbols (integers by their range, booleans,
  strings and lists), with a check value keyed by a map secret, a binding such as the player's name, and migrations.
- `systems.sync`: `ask` one player's machine for a local value; the answer, or the reason there is none, reaches
  every machine at the same moment.
- `systems.savefile`: `save` and `load` a player's data in a local file. The steps that run on one machine only are
  inside the library.
- A save file is carried by the tooltips of borrowed standard abilities, which are restored at once; nothing creates
  a handle on one machine only.

This completes the port of wc3-lib.

### Release gate

Automated checks passed 2026-10-01 on Windows: 21 suites (185 tests) with YueScript 0.34.2; Lua 5.3.6 syntax (51
files); Moonwell normal and minified builds; LuaLS 3.19.1 fixtures (26 expected negative diagnostics) and `src/systems`
against Moonwell's native declarations; all 15 entry points bundle only what they import (`systems.codec` bundles no
wrappers module); the five gate examples with clean editor diagnostics. The codec's fixed codes match a second
implementation written from the spec's layout, and 92 mutations of the new modules are each caught by a test.

In-game gate, 2026-10-01, Warcraft III 3.0.0.24268, `deno task gate systems-save`, normal build, one machine:

- **Parity:** three fixed sets of data encoded to the codes the test suite expects, from the game's 32-bit integers,
  and a decoded value at the edge of the range (2147483647) was an integer.
- **Round trip:** `save`, then `load`, gave the same data, through the file and through sync.
- A slot that was never saved gave `missing`; a file that holds no code `damaged`; a code with one symbol changed,
  and a code decoded with another name, `checksum`.
- **The largest save,** 8189 symbols in 44 tooltips and 38 sync packets, came back whole: saving took 10 ms,
  reading and sending 64 ms, and the answer arrived 0.07 s after the call.
- **A migration:** a version 1 file loaded as version 2 data.
- **`ask`:** the local clock arrived, and a slot without a human gave `absent`.
- Every borrowed tooltip read afterwards as it did before, and no failure line printed.

Three probes came before the design (`../wrappers-gate/PROBE-PRELOAD-RESULTS.md`): Lua cannot be run from a Preload
file on this version; a game cache carries text but makes a handle on every line; a file whose JASS names a global of
blizzard.j crashes the game; tooltips make no handles, one chunk per ability field. Two machines are not part of
this gate: the online checks before Moonwell 1.0 cover them.

## 0.4.0 (2026-10-01)

Release 4 of the wc3-lib port (spec `2026-10-01-moonwell-systems-release-4-design` in the Moonwell repository).

- `systems.geometry`: `length`, `turnToward`, `segmentSphere` and `orientation`, on plain numbers.
- `systems.terrain`: ground height, terrain walkability, `isClear` (which also sees trees and buildings, by placing
  a hidden item) and the world bounds.
- `systems.missile`: missiles with swept collision, heights above the ground, a filter per missile, piercing, range,
  gravity, steering, `followGround`, and an effect that faces its travel.
- `systems.knockback`: one knockback per unit, by angle, distance and duration, with linear falloff and pathing
  policies; no policy leaves the world bounds.
- The per-tick loops call raw natives on handles the systems own, and allocate nothing per call. A missile step
  rules out a unit that is too far with one native (`IsUnitInRangeXY`, which counts the unit's collision size).

### Release gate

Automated checks passed 2026-10-01 on Windows: 17 suites (144 tests) with YueScript 0.34.2; Lua 5.3.6 syntax (43
files); Moonwell normal and minified builds; LuaLS 3.19.1 fixtures (20 expected negative diagnostics) and `src/systems`
against Moonwell's native declarations; all 12 entry points bundle only what they import (`systems.geometry` and
`systems.terrain` bundle no wrappers module); the four gate examples with clean editor diagnostics.

In-game gate, 2026-10-01, Warcraft III 3.0.0.24268, normal builds, in two runs.

`deno task gate systems-physics`:

- A straight bolt pointed along its travel, hit the hostile footman at x -145.9 and ended `hit-limit` after 450.0.
- A bolt with `maxHits = 3` passed an allied footman, pierced two hostile ones and ended at the third.
- A bolt with nothing in its way ended `range` at exactly 600.
- A bolt under gravity nosed up, turned over and landed (`ground`) at x -84.4, on the ground.
- At a raised hill, a straight bolt ended `ground` on the slope at x 131.2, and a `followGround` bolt rode over it
  (highest z 195.7).
- A steered bolt that started north bent round in an arc (to y 290.6) into the footman east of its start.
- `isClear` read true on a lying item, which stayed visible; at a tree `isWalkable` read true and `isClear` false.
- 100 missiles among 20 footmen cost 1.597 ms per step (budget: 3 ms).

`deno task gate systems-knockback`, one footman at a time:

- A push of 300 with linear falloff moved it 300.0 (`completed`).
- A push at a tree ended `blocked` after 234.4, in front of the tree; under `"terrain"` pathing the same push went
  through it (400.0, `completed`).
- A second push ended the first with `replaced` before it moved; the footman moved 100.0 north only.
- A walking footman was pushed sideways (133.8 east, 135.0 north) and kept its move order.
- 100 knockbacks under `"obstacles"` cost 2.528 ms per step (budget: 3 ms).

Found at the gate: the first run read 3.603 ms per step for the missiles, over the budget. A probe then measured that
`GroupEnumUnitsInRange` tests unit origins and clears its group first, and that `IsUnitInRangeXY` counts a unit's
collision size; the missile step was changed to ask that native first. The first run's homing bolt finished its turn
in two steps and looked straight, and its five simultaneous knockbacks could not be followed, so the homing step
changed and the knockbacks got a run of their own.

## 0.3.0 (2026-10-01)

Release 3 of the wc3-lib port (spec `2026-10-01-moonwell-systems-release-3-design` in the Moonwell repository).

- `systems.damage`: listeners before armor, after armor and once the final amount is known, on `wrappers.damage`. A
  hit changes through setter methods that raise at the listener's line. `deal` queues script damage so it never nests,
  and carries `metadata`. `sourceOf` credits a hit to another Unit, for example a dummy's damage to its caster.
- `Callback.report` in `systems.internal.callback`.
- The blame sweep also covers the classes a module exposes (`DamageSystem.Hit`).

### Release gate

Automated checks passed 2026-10-01 on Windows: 12 suites (90 tests) with YueScript 0.34.2; Lua 5.3.6 syntax (32
files); Moonwell normal and minified builds; LuaLS 3.19.1 fixtures (14 expected negative diagnostics) and `src/systems`
against Moonwell's native declarations; all 8 entry points bundle only what they import (damage alone bundles no
scheduler, buffs or dummy module); both gate examples with clean editor diagnostics.

In-game gate, 2026-10-01, Warcraft III 3.0.0.24268, `deno task gate systems-damage`, normal build:

- A 100-damage `deal` between footmen read 100.0 before armor and 89.28571 after it, and the target lost that life.
- A hit doubled before armor (200.0, 178.5714 after armor) and capped at 50 after armor took 50.0 life.
- A cancelled hit took no life. Warcraft still sent its DAMAGED event, so its observers ran with amount 0.
- A dummy's Storm Bolt was credited to the paladin (`source` Paladin, `dealer` Dummy). It caused two hits: one of 0,
  then 100.0, which armor did not reduce.
- A `deal` made inside a listener ran after the first hit's observers (89.28571, then the follow-up's 4.464285).
- Magic damage on a spell-immune Spell Breaker ran the `beforeArmor` listeners and took no life; no DAMAGED event
  came, so no observer ran, and nothing was reported as a failure.
- A real attack read `isAttack` true (13.0 before armor, 11.60714 after).
- After `dispose()`, a further hit printed nothing.

## 0.2.0 (2026-10-01)

Release 2 of the wc3-lib port (spec `2026-09-30-moonwell-systems-release-2-design` in the Moonwell repository).

- `systems.buffs`: script buffs on Units with refresh, replace, stack and independent stacking, expiry, periodic ticks
  and owned effects released exactly once. The store polls its units and clears removed and dead ones.
- `systems.aura`: keeps an aura buff on the Units a query returns; each emitter owns its instances.
- `systems.dummy`: fresh dummy casters with timed removal and caster attribution (`sourceOf`). The README has the
  object-data definition of the dummy unit type.
- `systems.internal.ordered`: the insertion-ordered map behind every unit-keyed collection.
- Callback parameters are typed `fun(...): ...`, so YueScript callbacks, which return their last expression, pass the
  editor's checks.

### Release gate

Automated checks passed 2026-10-01 on Windows: 11 suites (58 tests) with YueScript 0.34.2; Lua 5.3.6 syntax (30
files); Moonwell normal and minified builds; LuaLS 3.19.1 fixtures (9 expected negative diagnostics) and `src/systems`
against Moonwell's native declarations; all 7 entry points bundle only what they import (buffs alone bundles no dummy
module); the gate example with clean editor diagnostics.

In-game gate, 2026-10-01, Warcraft III 3.0.0.24268, `deno task gate systems`, normal build. Release 1's part passed
again with the same readings. Release 2:

- A dummy of the README's unit type cast Storm Bolt at a footman: the order was accepted, `isDummy` and `sourceOf`
  held while leased, no dummy model was visible, and 2.5 s later the count was 0 and the footman had lost 125.38 life.
- A `stack` buff went `1 -> 2`, ticked three times (2.5, 1.5 and 0.5 s remaining) and ended `expired`; the footman's
  colour and move speed came back.
- Pruning: a killed footman's buff ended with `death` and its passive buff stayed; a footman removed with raw
  `RemoveUnit` lost its buff with `removed`.
- An aura applied its buff when a footman was moved into range and removed it (`source-lost`) when it was moved out.
- Disposing the store ended the passive buff with `disposed`. No `[systems] ... failed` line printed.

## 0.1.0 (2026-09-30)

Release 1 of the wc3-lib port (spec `2026-09-30-moonwell-systems-design` in the Moonwell repository).

- `systems.scheduler`: a deterministic fixed-step clock on a binary heap; `after` and `every` return cancel functions;
  `start()` drives it from one wrappers Timer.
- `systems.signal`: prioritized listeners, each isolated from the others.
- `systems.scope`: an ownership stack released in reverse; `add` accepts anything with `dispose`, `destroy` or
  `remove`.
- `systems.time`: 32-bit UTC calendar helpers, formatting, and `Time.localUtc()` through `os.time()`.
- Changes from wc3-lib: failures are printed or passed to `onError` instead of rethrown; `Scheduler:start()` replaces
  `startWarcraftClock`; signal listeners are isolated; the time range fits Warcraft's 32-bit integers;
  `SimulationTime` and `LocalWallTime` are gone.
- Tooling in Lua, run with `yue -e`: the test runner, the Lua 5.3.6 syntax check and integration.

### Release gate

Automated checks passed 2026-09-30 on Windows: 7 suites (31 tests) with YueScript 0.34.2, including the `blame` sweep
and the import checks; Lua 5.3.6 syntax (22 files); Moonwell normal and minified builds with both libraries as local
paths; LuaLS 3.19.1 fixtures (6 expected negative diagnostics) and `src/systems` against Moonwell's native declarations
(4 planted mistakes detected); Scheduler-, Signal-, Scope- and Time-only bundles; the gate example with clean editor
diagnostics.

In-game gate, 2026-09-30, Warcraft III 3.0.0.24268, `deno task gate systems`, normal build:

- The scheduler kept time with a real Warcraft timer: `every 0.5` ran with the reference at 0.5000038, 1.000004,
  1.500004 and 2.000004 s; `after 1` at 1.000004 s with `getElapsed()` 1.0.
- Three tasks due on the same tick ran as `first second third`.
- A failing repeating task printed `[systems] Scheduler task failed: war3map.lua:1822: intentional systems probe 1`
  once and never ran again.
- The signal ran `low:7 five:7`; its failing listener printed and did not stop the others.
- The scope ran its release function first, then disposed the timer and removed the footman, which disappeared.
- `Time.localUtc()` read 1790777585, `2026-09-30 14:13:05`, weekday 3 (Wednesday), the correct UTC time.
- After `dispose()` the tick stayed at 128 (4 s at 1/32 s), and no task ran.
