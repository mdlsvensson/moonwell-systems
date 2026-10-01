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

In `../wrappers-gate` (whose `moonwell.local.pkl` lists both libraries as local paths, and whose `objects/units.pkl`
has the README's dummy unit type), run `deno task gate systems`. The gate starts just after the map loads and takes
about 18 seconds. Expected messages (F12 log), release 1 first:

1. `Systems signal order: low:7 five:7` after one `[systems] Signal listener failed: …intentional signal probe`;
   `Systems local UTC <seconds> <date> weekday <d>` (record it; the date is today's UTC); `Systems duration 3725 s
   1:02:05`; `Systems gate started`.
2. `Systems same-tick order: first second third`.
3. `[systems] Scheduler task failed: …intentional systems probe 1` exactly once.
4. `Systems every 0.5 s: run 1` to `run 4`, with the reference timer near 0.5, 1.0, 1.5 and 2.0; `Systems after 1 s:
   reference <~1.0> elapsed 1.0`.
5. At 3 s: `Systems scope release function ran first`, then `Systems scope disposed: timer disposed true unit disposed
   true`, and the footman at the centre disappears.
6. At 5 s: `Systems gate done: tick at dispose <t> tick now <t> failures 1`, with the two ticks equal.

Release 2 (v0.2.0) starts right after step 6; its times count from `Systems release 2 started`. A paladin stands on
the left, with footmen above, below and to the upper right, and one far to the right:

7. `Systems dummy cast accepted true isDummy true source is hero true count 1`, then `Systems release 2 started`. The
   footman above the paladin is hit by a Storm Bolt (stunned and damaged). No dummy model is visible where the bolt
   starts.
8. At 2.5 s: `Systems dummy gone: count 0 active false life lost <n>`, with n above 0 (record it).
9. From 3 s the footman below turns blue and is slowed; at 3.5 s `Systems buff stacks 1 -> 2`; then
   `Systems buff tick: stacks 2 remaining <s>` once a second; at 6.5 s
   `Systems buff removed: expired speed restored true`, and the footman's colour returns.
10. At 7 s, within a quarter second: `Systems buff pruned: killed death` (that footman dies) and
    `Systems buff pruned: removed removed` (that footman vanishes). No `Systems passive buff removed` line yet.
11. At 9 s the far footman jumps next to the paladin and `Systems aura applied to walker true` prints within half a
    second; at 11 s it jumps back and `Systems aura removed: source-lost` prints.
12. At 12.5 s: `Systems passive buff removed: disposed`, then `Systems release 2 done`. No `[systems] … failed` line
    prints in release 2.

Release 3 (v0.3.0) has its own run, `deno task gate systems-damage`, about 10 seconds. A paladin stands on the left;
above the centre your footman faces a hostile footman; a hostile Spell Breaker stands below. All four are paused.
`Damage gate started` prints first. A hit prints as
`Damage <metadata>: <source> via <dealer> -> <target> <initial> > <before armor> > <after armor> > <final> attack <b>`.

13. At 1 s: `Damage baseline: Footman via Footman -> Footman 100.0 > 100.0 > <X> > <X> attack false`, then
    `Damage step 1 life lost <X>` (100 reduced by armor; record X).
14. At 2 s: `Damage crit: … 100.0 > 200.0 > <2X> > 50.0 attack false`, then `Damage step 2 life lost 50.0`.
15. At 3 s: `Damage cancel: … 100.0 > 0 > 0.0 > 0 attack false` (Warcraft sends DAMAGED for a zero amount), then
    `Damage step 3 life lost 0.0`.
16. At 4 s: `Damage step 4 dummy cast accepted true`; a Storm Bolt hits the hostile footman and two
    `Damage native: Paladin via Dummy -> Footman …` lines print: first `0.0 > 0.0 > 0.0 > 0.0`, then
    `100.0 > 100.0 > 100.0 > 100.0` (armor does not reduce it).
17. At 5 s: `Damage chain: follow-up queued`, then the `Damage chain: …` line, then
    `Damage follow-up: … 5.0 > 5.0 > …`, then `Damage step 5 life lost <n>` (both hits).
18. At 6 s: `Damage immune: before armor ran, amount 100.0`, then `Damage step 6 life lost 0.0`, with no
    `Damage immune: …` hit line: a spell-immune unit gets no DAMAGED event for magic damage.
19. At 7 s: `Damage step 7 attack ordered true`; your footman attacks, and one
    `Damage native: Footman via Footman -> Footman … attack true` line prints.
20. At 9 s: `Damage gate done`, and no line after it. No `[systems] … failed` line prints in the run.

v0.1.0: passed 2026-09-30, run by the maintainer on Warcraft III Reforged 3.0.0.24268 (normal build). Every message
printed as listed: the reference timer read 0.5000038, 1.000004, 1.500004 and 2.000004 s for the four half-second
runs; the failing task printed once (`war3map.lua:1822`); the footman disappeared at 3 s; the tick stayed at 128 after
dispose; the local UTC time was correct.

v0.2.0: passed 2026-10-01, run by the maintainer on Warcraft III Reforged 3.0.0.24268 (normal build). Steps 1 to 6
printed as for v0.1.0. Steps 7 to 12 printed as listed: the Storm Bolt hit with no dummy model visible and 125.3767
life lost; the buff went `1 -> 2`, ticked at 2.5, 1.5 and 0.5 s remaining and expired with speed and colour restored;
`killed death` and `removed removed`; the aura applied and ended `source-lost`; the passive buff ended `disposed`.

v0.3.0: passed 2026-10-01, run by the maintainer on Warcraft III Reforged 3.0.0.24268 (normal build,
`deno task gate systems-damage`). Steps 13 to 20 printed as listed: the baseline read 100.0 > 100.0 > 89.28571 with
89.28577 life lost; the crit read 100.0 > 200.0 > 178.5714 > 50 with 50.0 life lost; the cancelled hit printed its
observer line with 0.0 life lost; the Storm Bolt printed two hits credited to the paladin (0.0, then 100.0), with no
dummy model visible; the chain read 89.28571 and its follow-up 5.0 > 4.464285, with 93.75012 life lost; the Spell
Breaker ran `beforeArmor`, lost 0.0 life and got no observer line; the attack read 13.0 > 11.60714 with `attack true`,
once; nothing printed after `Damage gate done`, and no failure line printed.

## Publication and tag gate (maintainer)

After the checks and the in-game gate pass: change the Unreleased changelog heading to the version and date, record the
gate, update the README Status and the tags in its configuration, tag the verified commit `vX.Y.Z`, push the tag and
create a GitHub pre-release. Then, in a fresh Moonwell map with both libraries from GitHub (the README configuration)
and each gate example (`examples/gate.yue`, `examples/gate-damage.yue`) in turn as `src/main.yue`: check, build and
build `--minify`; `moonwell.lock` must record both tags' commits; remove the map's `.moonwell/`, check again, and the
lock must stay unchanged. Record it here.

v0.1.0: passed 2026-09-30 with Moonwell 0.5.2 (`main`) and moonwell-wrappers `v0.7.0`, in a map made fresh with
`init --link`: check, normal and minified builds of the gate example; `moonwell.lock` recorded systems commit
`172543665e299943076feb647f86e1308d728aa0` and wrappers commit `e9c2880993fd8b0755da8d2d442654cea467c913`, the 6
fetched systems files matched the tag's `src/` byte for byte, and the lock stayed unchanged after removing the map's
`.moonwell/` and checking again.

v0.2.0: passed 2026-10-01 with Moonwell 0.5.2 (`main`) and moonwell-wrappers `v0.7.0`, in a map made fresh with
`init --link`: check, normal and minified builds of the gate example (18 modules); `moonwell.lock` recorded systems
commit `afabc3d977077ddf01cb4556bfdaee2e62b51476` and wrappers commit `e9c2880993fd8b0755da8d2d442654cea467c913`, the
10 fetched systems files matched the tag's `src/` byte for byte, and the lock stayed unchanged after removing the map's
`.moonwell/` and checking again.
