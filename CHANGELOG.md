# Changelog

## Unreleased

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
