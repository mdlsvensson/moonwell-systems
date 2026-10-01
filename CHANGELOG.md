# Changelog

## Unreleased

Release 4 of the wc3-lib port (spec `2026-10-01-moonwell-systems-release-4-design` in the Moonwell repository).

- `systems.geometry`: `length`, `turnToward`, `segmentSphere` and `orientation`, on plain numbers.
- `systems.terrain`: ground height, terrain walkability, `isClear` (which also sees trees and buildings, by placing
  a hidden item) and the world bounds.
- `systems.missile`: missiles with swept collision, heights above the ground, a filter per missile, piercing, range,
  gravity, steering, `followGround`, and an effect that faces its travel.
- `systems.knockback`: one knockback per unit, by angle, distance and duration, with linear falloff and pathing
  policies; no policy leaves the world bounds.
- The per-tick loops call raw natives on handles the systems own, and allocate nothing per call.

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
