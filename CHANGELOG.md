# Changelog

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
