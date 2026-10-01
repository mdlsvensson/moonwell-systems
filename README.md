# Moonwell Systems

Opt-in Warcraft III systems for [Moonwell](https://github.com/mdlsvensson/moonwell) maps, ported from `wc3-lib`: a
deterministic scheduler, signals, ownership scopes, time helpers, script buffs, auras and dummy casters today; damage,
physics and save codes in later releases. Annotated Lua 5.3, built on [moonwell-wrappers](https://github.com/mdlsvensson/moonwell-wrappers),
with editor completion for YueScript and Lua maps.

**Status:** `v0.1.0` (2026-09-30): `systems.scheduler`, `systems.signal`, `systems.scope` and `systems.time`. It needs
moonwell-wrappers `v0.7.0` or later and Moonwell 0.5.2 or later. Multiplayer desync checks are deferred until before
Moonwell 1.0. Its in-game gate passed on 3.0.0.24268.

## Use it

Moonwell libraries cannot declare dependencies, so list both libraries in the map's committed `moonwell.pkl`:

```pkl
libraries {
  ["wrappers"] { github = "mdlsvensson/moonwell-wrappers"; tag = "v0.7.0"; dir = "src" }
  ["systems"] { github = "mdlsvensson/moonwell-systems"; tag = "v0.1.0"; dir = "src" }
}
```

Commit the resulting `moonwell.lock`. To work on a local checkout, override the entries in `moonwell.local.pkl` with
`path = "../moonwell-systems"` (and `path = "../moonwell-wrappers"`). Modules are named `systems.<name>`, for example
`import "systems.scheduler" as Scheduler`.

## Rules

- **Opt-in.** Importing a module creates nothing and calls no native. Everything starts explicitly (`new`, `start`) and
  has an idempotent `dispose()`. A map bundles only the modules it imports.
- **Callbacks are isolated.** A failing task, listener or release never stops the others. Its message goes to the
  owner's optional `onError(message)`, or is printed as `[systems] <label> failed: <message>`. Nothing is rethrown:
  errors rethrown inside Warcraft timer callbacks are silent.
- **Errors point at your line.** A wrong argument raises `[systems] <Class>.<method>: <problem>` at the calling line.
- **Deterministic.** Ties break by creation order, never by handle ids.
- **32-bit numbers.** Warcraft's integers wrap silently past 2,147,483,647 and floats are single precision.

## API reference

### `systems.scheduler`

- `Scheduler.new(stepSeconds = 1/32, onError?)`
- `after(seconds, callback)`, `every(seconds, callback)`: return a cancel function (idempotent)
- `advance()`, `getTick()`, `getElapsed()`, `getPending()`, `getStep()`, `ticks(seconds)`
- `start()`: drives `advance()` from one wrappers Timer; returns a stop function
- `dispose()`: cancels every task and stops the timer

Delays round up to whole ticks, at least one. Tasks due on the same tick run in creation order; tasks scheduled during a
tick run on a later one. A failing task is cancelled, repeating or not. `every` first runs one interval from now.

```yue
import "systems.scheduler" as Scheduler

clock = Scheduler.new!
clock\start!
cancel = clock\every 1, -> print "tick", clock\getElapsed!
clock\after 5, -> cancel!
```

### `systems.signal`

- `Signal.new(onError?)`
- `subscribe(callback, priority = 0)`: returns an unsubscribe function; lower priority runs first
- `emit(...)`: passes every argument; listeners added during an emit wait for the next one
- `getCount()`, `dispose()`

```yue
import "systems.signal" as Signal

levelUp = Signal.new!
levelUp\subscribe ((unit, level) -> print unit\getName!, level), -1
levelUp\emit hero, 2
```

### `systems.scope`

- `Scope.new(onError?)`
- `own(release)`: a function; returns it
- `add(value)`: anything with `dispose`, `destroy` or `remove` (checked in that order), such as a Scheduler, a Timer or
  a Unit; returns the value
- `isActive()`, `dispose()`: releases in reverse order; owning after dispose releases at once

```yue
import "systems.scope" as Scope

scope = Scope.new!
clock = scope\add Scheduler.new!
scope\own clock\start!
footman = scope\add Unit.create owner, $FourCC("hfoo"), 0, 0, 270
scope\dispose!  -- removes the footman, then disposes the scheduler
```

### `systems.time`

- `Time.isLeapYear(year)`, `Time.utcToUnix(date)`, `Time.unixToUtc(seconds)`, `Time.dayOfWeek(seconds)` (0 = Sunday)
- `Time.formatUtc(date)` (`YYYY-MM-DD HH:MM:SS`), `Time.formatDuration(seconds)` (`M:SS` or `H:MM:SS`)
- `Time.localUtc()`: this machine's `os.time()`, or nil

Timestamps are 32-bit: from 1901-12-13 20:45:52 to 2038-01-19 03:14:07. `utcToUnix` and `unixToUtc` return nil outside
that range. `localUtc()` is local and untrusted: sync it before it affects shared state.

```yue
import "systems.time" as Time

now = Time.localUtc!
print Time.formatUtc Time.unixToUtc now if now
print Time.formatDuration 125  -- 2:05
```

### `systems.buffs`

- `BuffStore.new(clock, {onError?, pollInterval = 0.25})`
- `apply(Unit, definition, source?)` returns the buff; `get(Unit, id, source?)`, `has(Unit, id, source?)`,
  `stacks(Unit, id)`, `list(Unit)`
- `clearUnit(Unit, reason = "removed")` (with `"death"`, buffs that survive death stay), `clearSource(source)`,
  `getScheduler()`, `dispose()`
- a buff: `getUnit()`, `getSource()`, `getId()`, `getDefinition()`, `isActive()`, `getStacks()`, `getRemaining()`,
  `own(release)`, `remove(reason = "dispelled")`, and a `data` table for its own state

A definition is a table: `id`, `kind` (`"active"`, `"passive"` or `"aura"`), and optionally `stacking` (`"refresh"`,
`"replace"`, `"stack"` or `"independent"`), `maxStacks`, `duration`, `interval`, `removeOnDeath`, and the callbacks
`onApply(buff)`, `onStacks(buff, previous)`, `onTick(buff)` and `onRemove(buff, reason)`. Use one definition table per
buff id: applying the same id from the same source with another table raises.

There is one instance per (unit, id, source). Register the inverse of every change with `buff:own(release)`: the store
runs each release exactly once, in reverse, whatever ends the buff, and then `onRemove` with the reason (`expired`,
`dispelled`, `replaced`, `death`, `removed`, `source-lost`, `disposed` or `error`). A failing `onApply`, `onStacks` or
`onTick` ends that buff with `error`.

The store checks its units every `pollInterval` seconds: a unit the game removed (or whose wrapper was disposed) loses
every buff (`removed`); a dead unit loses the buffs with `removeOnDeath` (`death`), which is every buff except
`"passive"` ones by default.

```yue
import "systems.buffs" as BuffStore

buffs = BuffStore.new clock
slow =
  id: "slow"
  kind: "active"
  stacking: "stack"
  maxStacks: 3
  duration: 4
  onApply: (buff) ->
    unit = buff\getUnit!
    speed = unit\getMoveSpeed!
    unit\setMoveSpeed speed * 0.5
    buff\own -> unit\setMoveSpeed speed
buffs\apply footman, slow, caster
```

### `systems.aura`

- `Aura.new(store, definition, source, query, onError?)`: `definition.kind` is `"aura"`; `query()` returns the Units that
  should carry the buff
- `start(interval = 0.5)` updates at once and then on the store's scheduler; `update()`; `dispose()`

Each emitter (`source`) owns its instances, so two auras with the same definition never remove each other's buffs. The
query decides range, team and visibility. Return the Units in the engine's enumeration order (for example
`group:getUnits()`), which is the same on every machine.

```yue
import "systems.aura" as Aura

devotion = {id: "devotion", kind: "aura", onApply: (buff) -> print buff\getUnit!\getName!}
aura = Aura.new buffs, devotion, paladin, -> alliesNear paladin
aura\start!
```

### `systems.dummy`

- `Dummies.new(clock, {onError?})`
- `cast(request)` returns a lease; `isDummy(Unit)`, `sourceOf(Unit)`, `getCount()`, `dispose()`
- a lease: `getUnit()`, `getSource()`, `isActive()`, `isOrderAccepted()`, `dispose()`

The request is a table: `owner` (Player), `typeId` (the dummy unit type), `x`, `y`, `facing?`, `ability`, `level?`,
`order` (an order string or an order id), `target?` (a Unit, Item or Destructable) or `point?` (`{x, y}`), `duration`
and `source?` (the real caster, returned by `sourceOf`). Every cast creates a fresh unit: it gets Locust,
invulnerability, no pathing, the ability and full mana, and is removed after `duration` seconds. Make `duration` cover
the cast point, channel time and projectile travel: removing the dummy early cancels channels. A rejected order removes
the dummy at once (`isOrderAccepted()` is false).

```yue
import "systems.dummy" as Dummies

dummies = Dummies.new clock
dummies\cast
  owner: owner, typeId: $FourCC("e000"), x: hero\getX!, y: hero\getY!
  ability: $FourCC("AHtb"), order: "thunderbolt", target: enemy, duration: 2, source: hero
```

#### The dummy unit type

The dummy comes from your map's object data. Put this in a file under `objects/` (the gate map uses it unchanged):

```pkl
units {
  ["dummy"] {
    id = "e000"                  // pick a free rawcode
    base = "ewsp"                // Wisp: no attack, no food
    name = "Dummy"
    modelFile = ".mdl"           // no model is drawn
    shadowImageUnit = ""
    normal = List("Aloc")        // Locust: unselectable and untargetable
    animationCastPoint = 0
    animationCastBackswing = 0
    collisionSize = 0
    manaMaximum = 10000
    foodCost = 0
    type = "fly"
  }
}
```

## Changes from wc3-lib

- Failures are printed or passed to `onError`, never rethrown (wc3-lib rethrew task and release errors).
- `Scheduler:start()` replaces `startWarcraftClock`.
- Signal listeners are isolated from each other.
- `Scope:add` also accepts `destroy` and `remove`, so wrappers can be added directly.
- The time range is 32-bit (wc3-lib accepted years 1 to 9999, which do not fit Warcraft's integers), and
  `Time.localUtc()` reads `os.time()`, which Warcraft 3.0.0.24268 has.
- `SimulationTime` and `LocalWallTime` are gone: use `scheduler:getElapsed()` and `Time.localUtc()`.
- Buffs target Units only, and the store prunes removed and dead units by itself (wc3-lib needed
  `trackWarcraftBuffTargets`); a disposed wrapper counts as removed.
- A failing buff callback ends the buff with `error` and is reported, not rethrown.
- Aura members keep the query's order; nothing is sorted by handle id, which can differ between machines.
- Dummy orders may be order ids, and a dummy that cannot get its ability raises at the `cast` line.
