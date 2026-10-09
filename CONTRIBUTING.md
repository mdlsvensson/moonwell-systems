# Contributing

Handwritten annotated Lua 5.3, test-first changes, and no Node.js or Deno in this repository. Runtime modules stay under
`src/systems/`; tests, tools and examples stay outside `src/`.

## Tools

- YueScript 0.34.3 (`yue`, installed by Moonwell setup; or `MOONWELL_YUE`). Its `yue -e` runs the Lua tools.
- LuaLS 3.19.1 (`MOONWELL_LUALS`, for example the Lua extension's `server/bin/lua-language-server.exe`).
- Lua 5.3.6 `luac` (`MOONWELL_LUAC`); the wrappers' CONTRIBUTING shows how to build `luac53.exe` on Windows.
- The `moonwell` program, 0.12.0 or later, on the PATH (or `MOONWELL` naming the executable: a path, not a command
  line), and Pkl 0.32 on the PATH.
- Sibling checkouts of Moonwell (`../moonwell`; or `MOONWELL_REPO`) and moonwell-wrappers (`../moonwell-wrappers`,
  v0.8.1 or later, for its `moonwell-library.json`; or `MOONWELL_WRAPPERS`). Integration links its consumer map to the
  Moonwell checkout's Pkl schema, so the program and that checkout must have the same major and minor version.

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

In `../wrappers-gate` (with both libraries named as local folders in your `config.toml`, and whose `objects/units.pkl`
has the README's dummy unit type), run `yue -e gate.lua systems`. The gate starts just after the map loads and takes
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

Release 3 (v0.3.0) has its own run, `yue -e gate.lua systems-damage`, about 10 seconds. A paladin stands on the left;
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

Release 4 (v0.4.0) has two runs of its own. Both also write their lines to
`Documents\Warcraft III\CustomMapData\` (`moonwell-systems-physics.pld` and `moonwell-systems-knockback.pld`).

`yue -e gate.lua systems-physics` (missiles and terrain, about 16 seconds, with the camera zoomed out): hostile
footmen stand in the upper rows, and a small hill rises right of the centre. `Physics gate started` prints first.

21. At 1 s a bolt flies east along the top row, pointing east, and hits the hostile footman:
    `Physics 1 hit Footman at x <about -146>`, then `Physics 1 end hit-limit travelled <about 450>`.
22. At 2.5 s a bolt passes your footman, pierces two hostile ones and ends at the third:
    `Physics 2 end hit-limit hit the footmen at x -100.0 100.0 300.0`.
23. At 4 s: `Physics 3 end range travelled exactly 600 true`.
24. At 5.5 s a bolt climbs nose up, turns over and comes down nose first:
    `Physics 4 end ground at x <about -84> height above the ground 0.0`.
25. At 7.5 s two bolts fly east at the hill. One ends on its slope:
    `Physics 5 straight end ground at x <about 131>`. The other rides over it:
    `Physics 5 followGround end range highest z <about 196>`.
26. At 10 s a bolt starts north, bends round to the east and comes down into the footman east of its start:
    `Physics 6 homing hit the footman`, then `Physics 6 end hit-limit after curving north to y <about 290>`.
27. At 12 s: `Physics 7 isClear on a lying item true the item is still visible true` and
    `Physics 7 at the tree: isWalkable true isClear false`.
28. At 13 s the game freezes briefly, then `Physics 8 missiles: <ms> ms per step; in flight 100`. It must be under
    3; record it.
29. At 15 s: `Physics gate done`. No `[systems] … failed` line prints in the run.

`yue -e gate.lua systems-knockback` (about 18 seconds): one footman at a time stands left of the centre, and each
step prints `Knockback <n> next: …` a second before its push. `Knockback gate started` prints first.

30. At 2 s the footman slides east and slows to a stop: `Knockback 1 slide completed moved 300.0 0.0`.
31. At 5 s, with a tree east of it, the footman is pushed at the tree and stops in front of it:
    `Knockback 2 into the tree blocked moved <about 234> 0.0`.
32. At 8 s the same push under terrain pathing slides the footman through the tree:
    `Knockback 3 through the tree completed moved 400.0 0.0`.
33. At 11 s the footman moves north only: `Knockback 4 first push replaced moved 0.0 0.0`, then
    `Knockback 4 second push completed moved 0.0 100.0`.
34. At 14 s the walking footman is pushed north and keeps walking east:
    `Knockback 5 walker completed moved <x> <y>` with both above 0, then
    `Knockback 5 the walker keeps its move order true`.
35. At 16 s the game freezes briefly, then `Knockback 6 knockbacks: <ms> ms per step; active 100`. It must be
    under 3; record it.
36. At 17.5 s: `Knockback gate done`. No `[systems] … failed` line prints in the run.

Release 5 (v0.5.0) has its own run, `yue -e gate.lua systems-save`, about 9 seconds. Nothing needs watching. Its lines
also go to `Documents\Warcraft III\CustomMapData\moonwell-systems-save.pld`, and its save files to
`CustomMapData\moonwell-gate\`. `Save gate started as <your name>` prints first.

37. At once: `Save 1 parity: hero true edges true empty true` (the game's 32-bit integers give the codes the test
    suite expects) and `Save 1 the edges decode: integer`.
38. `Save 4 another binding: checksum`.
39. At 1 s: `Save 2 round trip: gold 500 hero Hpal hardMode true items 1227894832,1227894833,2147483647`.
40. At 2 s: `Save 3 a missing slot: nil missing`.
41. At 3 s: `Save 5 a damaged file: nil damaged` and `Save 5 a changed symbol: nil checksum`.
42. At 4 s: `Save 6 saving took <ms> ms, and reading and sending <ms> ms`, then
    `Save 6 the largest save: true of 8189 symbols arrived after <s> s`. Record the three numbers.
43. At 5.5 s: `Save 7 a migration: coins 400 nil`.
44. At 6.5 s: `Save 8 ask a slot without a human: nil absent`, then
    `Save 8 ask: the local clock arrived: true nil`.
45. At 8 s: `Save 9 tooltips unchanged: true`, then `Save gate done`.
46. No `[systems] … failed` line prints in the run, and `CustomMapData\moonwell-gate\` holds `slot1.pld`,
    `damaged.pld`, `changed.pld`, `big.pld` and `old.pld`.

Two machines are not part of this gate: the online checks before Moonwell 1.0 cover them.

v0.1.0: passed 2026-09-30, run by the maintainer on Warcraft III Reforged 3.0.0.24268 (normal build). Every message
printed as listed: the reference timer read 0.5000038, 1.000004, 1.500004 and 2.000004 s for the four half-second
runs; the failing task printed once (`war3map.lua:1822`); the footman disappeared at 3 s; the tick stayed at 128 after
dispose; the local UTC time was correct.

v0.2.0: passed 2026-10-01, run by the maintainer on Warcraft III Reforged 3.0.0.24268 (normal build). Steps 1 to 6
printed as for v0.1.0. Steps 7 to 12 printed as listed: the Storm Bolt hit with no dummy model visible and 125.3767
life lost; the buff went `1 -> 2`, ticked at 2.5, 1.5 and 0.5 s remaining and expired with speed and colour restored;
`killed death` and `removed removed`; the aura applied and ended `source-lost`; the passive buff ended `disposed`.

v0.3.0: passed 2026-10-01, run by the maintainer on Warcraft III Reforged 3.0.0.24268 (normal build,
`yue -e gate.lua systems-damage`). Steps 13 to 20 printed as listed: the baseline read 100.0 > 100.0 > 89.28571 with
89.28577 life lost; the crit read 100.0 > 200.0 > 178.5714 > 50 with 50.0 life lost; the cancelled hit printed its
observer line with 0.0 life lost; the Storm Bolt printed two hits credited to the paladin (0.0, then 100.0), with no
dummy model visible; the chain read 89.28571 and its follow-up 5.0 > 4.464285, with 93.75012 life lost; the Spell
Breaker ran `beforeArmor`, lost 0.0 life and got no observer line; the attack read 13.0 > 11.60714 with `attack true`,
once; nothing printed after `Damage gate done`, and no failure line printed.

v0.4.0: passed 2026-10-01, run by the maintainer on Warcraft III Reforged 3.0.0.24268 (normal builds,
`yue -e gate.lua systems-physics` and `yue -e gate.lua systems-knockback`). Steps 21 to 29 printed as listed: the hit at
x -145.9 after 450.0; the three footmen at x -100.0, 100.0 and 300.0; exactly 600; the arc landed at x -84.4; the
straight bolt ended at x 131.2 and the `followGround` one reached z 195.7; the homing bolt curved north to y 290.6;
`isClear` read true on the item and false at the tree; the missiles cost 1.597 ms per step. Steps 30 to 36 printed as
listed: 300.0; blocked after 234.4; 400.0 through the tree; replaced, then 100.0 north; the walker moved 133.8 and
135.0 and kept its order; the knockbacks cost 2.528 ms per step. A first run of the physics gate read 3.603 ms per
step for the missiles; the loop was changed after a probe (`../wrappers-gate/PROBE-MISSILE-PERF-RESULTS.md`), and the
gate was run again.

v0.5.0: passed 2026-10-01, run by the maintainer on Warcraft III Reforged 3.0.0.24268 (normal build,
`yue -e gate.lua systems-save`, one machine). Steps 37 to 46 printed as listed: parity true for all three codes; the
round trip gave `gold 500 hero Hpal hardMode true items 1227894832,1227894833,2147483647`; `missing`, `damaged` and
`checksum` twice; the largest save came back whole (saving 10 ms, reading and sending 64 ms, arrived after 0.07 s);
`coins 400`; `absent`, then the local clock; the tooltips unchanged; and the five files in `moonwell-gate\`, of which
`big.pld` has 44 lines.

v0.5.1: not re-run (maintainer's decision, 2026-10-02). The release adds `moonwell-library.json` and changes a tool and
documentation; no file under `src/` changed since v0.5.0.

v0.5.2: not re-run (2026-10-09). The release changes a tool and documentation for Moonwell 0.12; no file under `src/`
changed since v0.5.1.

## Publication and tag gate (maintainer)

After the checks and the in-game gate pass: change the Unreleased changelog heading to the version and date, record the
gate, update the README Status and the tags in its configuration, tag the verified commit `vX.Y.Z`, push the tag and
create a GitHub pre-release. Then, in a fresh Moonwell map with both libraries from GitHub (the README configuration)
and each gate example (`examples/gate.yue`, `examples/gate-damage.yue`, `examples/gate-physics.yue`,
`examples/gate-knockback.yue`, `examples/gate-save.yue`) in turn as `src/main.yue`: check, build and build
`--minify`; `moonwell.lock` must record both tags' commits; remove the map's `.moonwell/`, check again, and the
lock must stay unchanged. Record it here.

v0.1.0: passed 2026-09-30 with Moonwell 0.5.2 (`main`) and moonwell-wrappers `v0.7.0`, in a map made fresh with
`init --link`: check, normal and minified builds of the gate example; `moonwell.lock` recorded systems commit
`0b51fd1f667c7474abc6d6932de22ee109143505` and wrappers commit `9a8456e4d2c16dbb46cecaf92b303f7fac8017c3`, the 6
fetched systems files matched the tag's `src/` byte for byte, and the lock stayed unchanged after removing the map's
`.moonwell/` and checking again.

v0.2.0: passed 2026-10-01 with Moonwell 0.5.2 (`main`) and moonwell-wrappers `v0.7.0`, in a map made fresh with
`init --link`: check, normal and minified builds of the gate example (18 modules); `moonwell.lock` recorded systems
commit `c20f013035d756c2ed3dd8a8e1bf06303907d54f` and wrappers commit `9a8456e4d2c16dbb46cecaf92b303f7fac8017c3`, the
10 fetched systems files matched the tag's `src/` byte for byte, and the lock stayed unchanged after removing the map's
`.moonwell/` and checking again.

v0.3.0: passed 2026-10-01 with Moonwell 0.5.2 (`main`) and moonwell-wrappers `v0.7.0`, in a map made fresh with
`init --link`: check, normal and minified builds of both gate examples; `moonwell.lock` recorded systems commit
`63027c9e310b95f7d4025af13debfc26bad5bbc2` and wrappers commit `9a8456e4d2c16dbb46cecaf92b303f7fac8017c3`, the 11
fetched systems files matched the tag's `src/` byte for byte, and the lock stayed unchanged after removing the map's
`.moonwell/` and checking again.

v0.4.0: passed 2026-10-01 with Moonwell 0.5.2 (`main`) and moonwell-wrappers `v0.7.0`, in a map made fresh with
`init --link`: check, normal and minified builds of the four gate examples; `moonwell.lock` recorded systems commit
`b75d024d367c6e670f29d960baef932b7ffd6733` and wrappers commit `9a8456e4d2c16dbb46cecaf92b303f7fac8017c3`, the 17
fetched systems files matched the tag's `src/` byte for byte, and the lock stayed unchanged after removing the map's
`.moonwell/` and checking again.

v0.5.0: passed 2026-10-01 with Moonwell 0.5.2 (`main`) and moonwell-wrappers `v0.7.0`, in a map made fresh with
`init --link`: check, normal and minified builds of the five gate examples; `moonwell.lock` recorded systems commit
`5866744e4bda4b643073237b8773254b6d985453` and wrappers commit `9a8456e4d2c16dbb46cecaf92b303f7fac8017c3`, the 21
fetched systems files matched the tag's `src/` byte for byte, and the lock stayed unchanged after removing the map's
`.moonwell/` and checking again.

v0.5.1: passed 2026-10-02 with Moonwell 0.8.1 and moonwell-wrappers `v0.8.1`, in a map made fresh with `init --link`
whose two entries have no `dir` (the README configuration): check, normal and minified builds of the five gate
examples; `moonwell.lock` recorded systems commit `8792bb3811dd5dcac03c147b3dffdd1bca0d9e78` and wrappers commit
`4d1d6e977ea3755cf6f85c95a65d985ca5b5c2db`, each with `"dir": ""`, the 21 fetched systems files matched the tag's
`src/` byte for byte, and the lock stayed unchanged after removing the map's `.moonwell/` and checking again.

v0.5.2: passed 2026-10-09 with Moonwell 0.12.0 and moonwell-wrappers `v0.8.1`, in a map made fresh with `init --link`
whose two entries are the README's, in `moonwell.toml`: check, normal and minified builds of the five gate examples;
`moonwell.lock` recorded systems commit `63792f6d2e78ab2761f69f384497ab994ac945e8` and wrappers commit
`4d1d6e977ea3755cf6f85c95a65d985ca5b5c2db`, the 21 fetched systems files matched the tag's `src/` byte for byte,
and the lock stayed unchanged after removing the map's `.moonwell/` and checking again. The README's example keeps
wrappers `v0.8.1`, the tag the in-game gate ran with; the automated checks of this release ran with `v0.9.2`.
