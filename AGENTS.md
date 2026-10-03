# Moonwell Systems: agent handoff

This is an optional Moonwell library in annotated Lua 5.3: `wc3-lib`'s systems, ported for Warcraft's Lua and built on
moonwell-wrappers. Runtime modules live only in `src/systems/`; maps consume it next to the wrappers, and
`moonwell-library.json` at the root names `src` as the module folder (since `v0.5.1`; a map on an older tag, or on
Moonwell 0.5, writes `dir = "src"`). The remote is `mdlsvensson/moonwell-systems` (HTTPS). Tags are immutable GitHub
pre-releases: `v0.1.0` is on `0b51fd1` (in-game gate and tag consumption passed 2026-09-30), `v0.2.0` on `c20f013`,
`v0.3.0` on `63027c9`, `v0.4.0` on `b75d024` and `v0.5.0` on `5866744` (all four passed 2026-10-01). The port of
`wc3-lib` is complete. `v0.5.1` (2026-10-02) adds only `moonwell-library.json`: `src/` is that of `v0.5.0`, the in-game
gate was not re-run, and integration's consumer names both libraries by `path` alone, so every run exercises the files.
Its tag is on `8792bb3`; tag consumption passed the same day, with wrappers `v0.8.1` and no `dir` in either entry.

The design lives in the sibling Moonwell repository: `../moonwell/docs/superpowers/specs/2026-09-30-moonwell-systems-design.md`
(Part 1 binds every release; each release has its own spec and plan in `../moonwell/docs/superpowers/`). Release 1
(v0.1.0): scheduler, signal, scope, time. Release 2 (v0.2.0): buffs, aura, dummy, on `internal/ordered.lua`. Release 3
(v0.3.0): damage. Release 4 (v0.4.0): geometry, terrain, missile, knockback, on `internal/vector.lua` and
`internal/ground.lua`. Release 5 (v0.5.0): codec, sync, savefile, on `internal/preload.lua`.

## Rules (spec §4)

- Importing creates nothing and calls no native. Everything that owns a handle starts explicitly and has an idempotent
  `dispose()`.
- Errors read `[systems] <Class>.<method>: <problem>` and point at the caller: level 2 in a public function, 3 (+ depth)
  in a helper, and never a tail call into a raising helper (`return (helper(...))`). `tests/blame.lua` sweeps it.
- Callbacks run behind `systems.internal.callback` (a copy of the wrappers' one): failures go to `onError` or are
  printed; nothing is rethrown.
- Pure logic takes plain values. Game-facing code calls the wrappers directly; raw natives only for Preload files,
  terrain sampling and the innermost physics loops.
- Determinism: insertion-ordered collections for handle keys, no `pairs` over handle-keyed tables when the loop calls
  natives, ties by owned sequence numbers, never `GetHandleId`.
- 32-bit integers and single-precision floats in game.

## Tooling (no Deno)

```bash
yue -e tests/run.lua [suite ...]   # behavior suites, each in a fresh environment
yue -e tools/check.lua             # Lua 5.3.6 syntax (MOONWELL_LUAC) and every suite listed
yue -e tools/integration.lua       # Moonwell builds, LuaLS fixtures, one-module bundles, the gate example
```

Environment: `MOONWELL` (the `moonwell` executable, when it is not on the PATH), `MOONWELL_REPO`, `MOONWELL_WRAPPERS`,
`MOONWELL_YUE`, `MOONWELL_LUALS`, `MOONWELL_LUAC` (CONTRIBUTING). Since Moonwell 0.8.0 the CLI is a Go program:
integration runs `moonwell init --link` with the Moonwell checkout as its working directory (the program finds the
checkout by walking up from there), and `MOONWELL_CLI`, which named a Deno command line, is gone. `tools/lib.lua` is
shared with moonwell-wrappers, which adds a `MOONWELL_PKL` override to its copy.

## Process

Spec, then a plan of test-first tasks, then implementation task by task; the maintainer approves each spec. Commit on
`main`, staging explicit paths. The maintainer runs the in-game gate in `../wrappers-gate` (`yue -e gate.lua systems`
for releases 1 and 2, `yue -e gate.lua systems-damage` for release 3, `yue -e gate.lua systems-physics` and
`yue -e gate.lua systems-knockback` for release 4, `yue -e gate.lua systems-save` for release 5); then tag,
pre-release and tag consumption with both libraries.

## Pitfalls

- `yue -e` is Lua 5.4 with 64-bit integers, so overflow cannot be observed in tests: test ranges at their exact edges.
- In Warcraft's Lua NaN compares equal to itself, so NaN checks work only outside the game.
- The runner restores globals between suites but not tables changed in place: a test that replaces `os.time` must
  restore it.
- `tools/lib.lua` wraps Windows command lines in an extra pair of quotes, because cmd.exe strips the outer ones.
- LuaLS: `math.tointeger` returns `integer?`; `systems.time` uses `whole()` after its own integer check. It narrows a
  union through `type(x) == 'string'`, not through `math.type`. Type user callbacks `fun(...): ...`: YueScript returns
  a callback's last expression, and a `fun()` parameter makes LuaLS flag that.
- An object's field must never share a name with one of its methods (the ordered map's key array is `order`, not
  `keys`): the field would hide the method.
- LuaLS's `--check` mangles a project path that contains `--` (it reads it as an option): keep work folders out of
  such paths.
- LuaLS reports `need-check-nil` for a nil-able local, not for a chained call (`a:b().c`): assign the result first.
- Hot loops (missile and knockback steps) call raw natives and the unchecked `internal/vector.lua` and
  `internal/ground.lua`; the public `geometry` and `terrain` modules are for maps. Do not add argument checks or
  table allocations to the internal ones.
- Measured on 3.0.0.24268 (`../wrappers-gate/PROBE-MISSILE-PERF-RESULTS.md`): `GroupEnumUnitsInRange` tests unit
  origins and clears the group first; `IsUnitInRangeXY` is true up to the range plus the unit's collision size; a
  native costs 0.3 to 0.5 µs, an enumerated unit about 0.8 µs more, and `SetItemPosition` 16 µs or more. A missile
  step therefore asks `IsUnitInRangeXY` first and reads nothing else from most units.
- A gate step must show one thing at a time, and a turn must be large enough to see: the first physics gate's
  homing bolt finished turning in two steps, and its five simultaneous knockbacks could not be followed.
- A mutation that removes a loop bound can make a test loop forever and eat memory: run mutation checks with a
  timeout per run.
- A YueScript function that ends in a bare `return` compiles to Lua that LuaLS flags (`redundant-return`): end gate
  functions with a statement instead.
- The game's integers are 32-bit and the test runner's 64-bit. Arithmetic that is meant to wrap (the codec's check
  value) masks every product with `& 0xFFFFFFFF`, so both agree; the codec writes at most 16 bits at a time; and
  fixed codes in `tests/codec.lua` are compared in game by the gate. Those codes came from a second implementation
  written from the spec's layout alone; a change to the layout needs a new layout number, not new fixed codes.
- `math.tointeger` converts strings on Lua 5.4 and not on 5.3: check `type(x) == 'number'` first.
- A Preload file must hold only lines the game can run, none over 259 characters: anything else can crash the game
  when `Preloader` runs it. The tests run every generated line through a simulated `Preloader` that refuses any
  other shape.
- Reading a save happens on one machine, so nothing on that path may create a handle. A game cache makes one per
  call (measured); tooltips make none (`../wrappers-gate/PROBE-PRELOAD-RESULTS.md`).
- The wrappers keep one trigger per sync prefix for every listener: a test that counts `CreateTrigger` needs a
  prefix no other test used.
- YueScript cannot build bitwise operators: 0.34.2 wrote an empty file for such a source, as for `//`, and 0.34.3
  (pinned by Moonwell 0.8.1, where `//` works) fails with an error. Gate examples keep such code
  out (the library is Lua).
