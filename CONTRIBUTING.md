# Contributing

Handwritten annotated Lua 5.3, test-first changes, and no Node.js or Deno in this repository. Runtime modules stay under
`src/systems/`; tests, tools and examples stay outside `src/`.

## Tools

- YueScript 0.34.2 (`yue`, installed by Moonwell setup; or `MOONWELL_YUE`). Its `yue -e` runs the Lua tools.
- LuaLS 3.19.1 (`MOONWELL_LUALS`, for example the Lua extension's `server/bin/lua-language-server.exe`).
- Lua 5.3.6 `luac` (`MOONWELL_LUAC`); the wrappers' CONTRIBUTING shows how to build `luac53.exe` on Windows.
- Pkl 0.32 on `PATH`, for `moonwell init`.
- Sibling checkouts of Moonwell (`../moonwell`, 0.5.2 or later; or `MOONWELL_CLI` as a full command line) and
  moonwell-wrappers (`../moonwell-wrappers`, v0.7.0 or later; or `MOONWELL_WRAPPERS`).

## Checks

Run from the repository root; all must pass before a commit:

```bash
yue -e tests/run.lua
yue -e tools/check.lua
yue -e tools/integration.lua
```

Integration makes a fresh ignored `.test-work/integration-*/consumer` with both libraries as local paths, checks and
builds it normal and minified, runs LuaLS over the positive and negative fixtures and over `src/systems` against
Moonwell's native declarations, checks that each entry point bundles only what it imports, and builds the gate example.

## In-game release gate (maintainer)

v0.1.0: in `../wrappers-gate` (whose `moonwell.local.pkl` lists both libraries as local paths), run
`deno task gate systems`. The gate starts just after the map loads. Expected messages (F12 log):

1. `Systems signal order: low:7 five:7` after one `[systems] Signal listener failed: …intentional signal probe`;
   `Systems local UTC <seconds> <date> weekday <d>` (record it; the date is today's UTC); `Systems duration 3725 s
   1:02:05`; `Systems gate started`.
2. `Systems same-tick order: first second third`.
3. `[systems] Scheduler task failed: …intentional systems probe 1` exactly once.
4. `Systems every 0.5 s: run 1` to `run 4`, with the reference timer near 0.5, 1.0, 1.5 and 2.0; `Systems after 1 s:
   reference <~1.0> elapsed 1.0`.
5. At 3 s: `Systems scope release function ran first`, then `Systems scope disposed: timer disposed true unit disposed
   true`, and the footman at the centre disappears.
6. At 5 s: `Systems gate done: tick at dispose <t> tick now <t> failures 1`, with the two ticks equal, and no systems
   line after it.

## Publication and tag gate (maintainer)

After the checks and the in-game gate pass: change the Unreleased changelog heading to the version and date, record the
gate, update the README Status and the tags in its configuration, tag the verified commit `vX.Y.Z`, push the tag and
create a GitHub pre-release. Then, in a fresh Moonwell map with both libraries from GitHub (the README configuration)
and `examples/gate.yue` as `src/main.yue`: check, build and build `--minify`; `moonwell.lock` must record both tags'
commits; remove the map's `.moonwell/`, check again, and the lock must stay unchanged. Record it here.
