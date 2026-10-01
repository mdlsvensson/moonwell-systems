# Moonwell Systems: agent handoff

This is an optional Moonwell library in annotated Lua 5.3: `wc3-lib`'s systems, ported for Warcraft's Lua and built on
moonwell-wrappers. Runtime modules live only in `src/systems/`; maps consume it with `dir = "src"` next to the wrappers.
The remote is `mdlsvensson/moonwell-systems` (HTTPS). Tags are immutable GitHub pre-releases: `v0.1.0` is on
`1725436` (in-game gate and tag consumption passed 2026-09-30), `v0.2.0` on `afabc3d` and `v0.3.0` on `d67d3fc` (both
passed 2026-10-01).

The design lives in the sibling Moonwell repository: `../moonwell/docs/superpowers/specs/2026-09-30-moonwell-systems-design.md`
(Part 1 binds every release; each release has its own spec and plan in `../moonwell/docs/superpowers/`). Release 1
(v0.1.0): scheduler, signal, scope, time. Release 2 (v0.2.0): buffs, aura, dummy, on `internal/ordered.lua`. Release 3
(v0.3.0): damage. Releases 4 and 5: physics; persistence.

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

Environment: `MOONWELL_WRAPPERS`, `MOONWELL_CLI`, `MOONWELL_YUE`, `MOONWELL_LUALS`, `MOONWELL_LUAC` (CONTRIBUTING).

## Process

Spec, then a plan of test-first tasks, then implementation task by task; the maintainer approves each spec. Commit on
`main`, staging explicit paths. The maintainer runs the in-game gate in `../wrappers-gate` (`deno task gate systems`
for releases 1 and 2, `deno task gate systems-damage` for release 3); then tag, pre-release and tag consumption with
both libraries.

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
