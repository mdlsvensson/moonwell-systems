# Moonwell Systems

Opt-in Warcraft III systems for [Moonwell](https://github.com/mdlsvensson/moonwell) maps, ported from `wc3-lib`: a
deterministic scheduler, signals, ownership scopes, time helpers, script buffs, auras, dummy casters, a damage
pipeline, missiles and knockbacks today; save codes in a later release. Annotated Lua 5.3, built on
[moonwell-wrappers](https://github.com/mdlsvensson/moonwell-wrappers), with editor completion for YueScript and Lua
maps.

**Status:** `v0.3.0` (2026-10-01): `systems.damage` joins `systems.scheduler`, `systems.signal`, `systems.scope`,
`systems.time`, `systems.buffs`, `systems.aura` and `systems.dummy`. It needs moonwell-wrappers `v0.7.0` or later and
Moonwell 0.5.2 or later. Multiplayer desync checks are deferred until before Moonwell 1.0. Its in-game gate passed on
3.0.0.24268.

## Use it

Moonwell libraries cannot declare dependencies, so list both libraries in the map's committed `moonwell.pkl`:

```pkl
libraries {
  ["wrappers"] { github = "mdlsvensson/moonwell-wrappers"; tag = "v0.7.0"; dir = "src" }
  ["systems"] { github = "mdlsvensson/moonwell-systems"; tag = "v0.3.0"; dir = "src" }
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

### `systems.damage`

- `DamageSystem.new({sourceOf?, onError?, maxQueue = 128, maxChain = 64, maxPending = 64})`
- `start()`; `beforeArmor(callback, priority = 0)`, `afterArmor(callback, priority = 0)` and
  `observe(callback, priority = 0)`: each returns a remove function; lower priority runs first
- `deal(request)`, `getCurrent()`, `dispose()`
- a hit, to read: `source`, `dealer`, `target`, `amount`, `isAttack`, `attackType`, `damageType`, `weaponType`,
  `metadata`, `phase`, `initialAmount`, `beforeArmorAmount`, `armorAmount`, `cancelled`, `paired`
- a hit, to change: `setAmount(n)`, `cancel()`, `setAttackType(t)`, `setDamageType(t)`, `setWeaponType(t)`; and
  `isLethal()`

Every hit in the map runs three phases: the `beforeArmor` listeners (the amount and the types can change), the
`afterArmor` listeners (the amount can change) and the observers (nothing can change). A listener gets the hit. Its
fields are for reading; change it with its methods. A setter raises at your line when its phase has passed, when an
observer calls it, or when the hit is not the one being handled. A cancelled hit stays at 0.

`deal` takes a table: `source`, `target`, `amount`, and optionally `attack`, `ranged`, `attackType`, `damageType`,
`weaponType` and `metadata`. Outside damage events it runs at once. Inside a listener it is queued and runs after the
current hit, first in first out, so script damage never nests. Only the hit that `deal` causes carries its `metadata`.
A listener that answers every hit with another `deal` is stopped after `maxChain` deals, and a full queue raises at the
`deal` line.

`sourceOf(dealer)` credits a hit to another Unit: `hit.source` is its answer (or the dealer), and `hit.dealer` is the
unit the game reported. With `sourceOf: dummies\sourceOf`, a dummy's damage counts for its real caster while the
dummy's lease lasts.

- `hit.source` and `hit.dealer` are nil when the game gives no source.
- `isAttack` is the game's value: false for script damage, even with `attack: true`.
- A hit whose DAMAGED event never comes gets no `afterArmor` or observer call. Measured on 3.0.0.24268: magic damage
  on a spell-immune unit runs the `beforeArmor` listeners and nothing more, while a cancelled hit still gets its
  DAMAGED event, so its `afterArmor` listeners and observers run with amount 0.
- One spell can cause several hits. Storm Bolt gave two (measured): one of 0, then its 100 damage, which armor did
  not reduce. Observers that count hits should skip those with amount 0.
- To react to one unit's hits, look `hit.target` up in your own table inside one listener.

```yue
import "systems.damage" as DamageSystem

damage = DamageSystem.new sourceOf: dummies\sourceOf
damage\beforeArmor (hit) -> hit\setAmount hit.amount * 2 if hit.metadata == "crit"
damage\afterArmor (hit) -> hit\cancel! if shields[hit.target]
damage\observe (hit) -> print hit.amount
damage\start!
damage\deal source: hero, target: enemy, amount: 50, metadata: "crit"
```

### `systems.geometry`

- `Geometry.length(x, y, z = 0)`
- `Geometry.turnToward(vx, vy, vz, tx, ty, tz, maxAngle)` returns `x, y, z`: the velocity turned toward a direction
  by at most `maxAngle`, at the same speed
- `Geometry.segmentSphere(fx, fy, fz, tx, ty, tz, cx, cy, cz, radius)` returns the fraction (0 to 1) of the segment
  at which it first touches the sphere, or nil
- `Geometry.orientation(vx, vy, vz)` returns `yaw, pitch` for `effect:setOrientation(yaw, pitch, 0)`

Pure functions on plain numbers, so nothing is allocated per call. Angles are radians. In Warcraft a positive pitch
points an effect's nose down (measured on 3.0.0.24268), so `orientation` gives a negative pitch for a climbing
velocity.

### `systems.terrain`

- `Terrain.new({itemType?})`
- `height(x, y)`, `isWalkable(x, y)`, `isClear(x, y)`, `inBounds(x, y)`, `dispose()`

A Terrain owns one location, one hidden item and one rect, each created on first use. Measured on 3.0.0.24268:

- `isWalkable` reads the terrain only (`IsTerrainPathable`): it does not see trees or buildings.
- `isClear` sees them: it places a hidden item (`itemType`, default `'wolg'`) on the point and reads where it landed.
  Visible items within 32 units are hidden for the check and shown again. The hidden item stays where it last landed.
- `height` is `GetLocationZ`. It follows temporary terrain deformations, such as a Thunder Clap ripple, while they
  last; w3ts marks it as possibly different between machines then.
- A unit's absolute height is `terrain:height(x, y)` plus `GetUnitFlyHeight`; `BlzGetUnitZ` gives only the ground
  height.
- `inBounds` is true up to 64 units from the world's edge. Moving a unit outside the world bounds can crash the game.

### `systems.missile`

- `Missiles.new(clock, {onError?, terrain = true, targetOffset = 50, maxTargetRadius = 128})`
- `launch(request)` returns a missile; `getCount()`, `dispose()`
- a missile: `getPosition()` (x, y, absolute z), `getVelocity()`, `setVelocity(vx, vy, vz)`, `getAge()`,
  `getTravelled()`, `getHitCount()`, `getEffect()`, `isActive()`, `dispose()`, and its `data`

The request is a table: `x`, `y`, `height` (above the ground, default 60), `vx`, `vy`, `vz?`, `ax?`, `ay?`, `az?`,
`radius`, `lifetime`, `maxRange?`, `maxHits?` (default 1; more pierces), `followGround?`, `model?` or `effect?`,
`scale?`, `face?` (default true), `filter?(unit, missile)`, `steer?(missile, dt)`, `onHit?(missile, unit)`,
`onEnd?(missile, reason)` and `data?`. It ends with `hit-limit`, `expired`, `range`, `ground`, `cancelled`,
`disposed` or `error`.

- **Swept collision.** Each step tests the whole segment the missile travels against a sphere around every unit near
  it, so a fast missile never jumps over a unit. Hits come in order of distance; a tie keeps the engine's enumeration
  order. A unit is hit at most once.
- **Pass a `filter`.** Without one, a missile hits every living unit, the one it was launched from included. Each
  missile has its own filter, so one system serves every team.
- **Heights are above the ground.** A target's centre is the ground at its feet, plus its fly height, plus
  `targetOffset`. A missile whose step ends below the ground ends with `ground`, on the ground. `followGround` keeps
  the missile at its `height` over hills instead. `terrain = false` makes the ground flat at 0 and samples nothing.
- **The effect** (`model`, or an `effect` you hand over) is moved, turned along the travel unless `face = false`, and
  destroyed when the missile ends.
- **Targets larger than `maxTargetRadius`** are hit as if they had that radius: the search around the path uses it.
- **Callbacks** may dispose any missile or the system. A failing `steer`, `filter` or `onHit` ends that missile with
  `error` and is reported; the others still move.
- The system ticks from its scheduler only while missiles are in flight.

```yue
import "systems.missile" as Missiles
import "systems.geometry" as Geometry

missiles = Missiles.new clock
missiles\launch
  x: hero\getX!, y: hero\getY!, vx: 900, vy: 0, radius: 16, lifetime: 1.2, maxHits: 3
  model: "Abilities\\Weapons\\BallistaMissile\\BallistaMissile.mdl"
  filter: (unit) -> unit\getOwner! ~= owner
  onHit: (missile, unit) -> damage\deal source: hero, target: unit, amount: 40

-- An arc: gravity pulls it down, and it ends with "ground" where it lands.
missiles\launch x: 0, y: 0, vx: 500, vy: 0, vz: 500, az: -1000, radius: 16, lifetime: 5, onEnd: explode

-- Homing: steer runs first in every step.
missiles\launch
  x: 0, y: 0, vx: 600, vy: 0, radius: 16, lifetime: 5
  steer: (missile, dt) ->
    x, y, z = missile\getPosition!
    vx, vy, vz = missile\getVelocity!
    missile\setVelocity Geometry.turnToward vx, vy, vz, target\getX! - x, target\getY! - y, 0, 2.5 * dt
```

### `systems.knockback`

- `Knockbacks.new(clock, {onError?, pathing = "obstacles", sampleStep = 32})`
- `apply(Unit, request)` returns a knockback; `get(Unit)`, `getCount()`, `dispose()`
- a knockback: `getUnit()`, `isActive()`, `getRemaining()`, `dispose()`

The request is a table: `angle` (radians, as `math.atan(dy, dx)` gives; the wrappers' unit facings are degrees),
`distance`, `duration`, `falloff?` (`"none"`, or `"linear"` to slow to a stop) and `onEnd?(knockback, reason)`. It
ends with `completed`, `replaced`, `interrupted`, `invalid`, `blocked`, `disposed` or `error`.

- **One knockback per unit:** a new one replaces the old, which ends with `replaced`.
- **The unit is moved with `SetUnitX/Y`,** from where it is in each step. It keeps its orders and is never paused
  (measured: `SetUnitPosition` would clear the order), so it keeps walking while pushed. Stun it yourself if it
  should not.
- **Pathing** is checked before each move, and a refused move ends the knockback with `blocked`:
  `"obstacles"` (the default) stops at unwalkable terrain, trees and buildings; `"terrain"` only at unwalkable
  terrain, so units slide through trees; `"none"` never; a function `(unit, fromX, fromY, toX, toY)` decides itself.
  Flying units skip the `"obstacles"` and `"terrain"` checks.
- **No policy moves a unit outside the world bounds:** that can crash the game.
- A unit pushed into an obstacle under `"terrain"` or `"none"` is not stuck: it can walk out (measured).

```yue
import "systems.knockback" as Knockbacks

knockbacks = Knockbacks.new clock
angle = math.atan target\getY! - caster\getY!, target\getX! - caster\getX!
knockbacks\apply target, angle: angle, distance: 300, duration: 0.4, falloff: "linear"
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
- The damage system has no port: `DamageSystem.new` is the Warcraft system, and a `deal` request is one flat table.
- A hit changes through setter methods, which raise at the listener's line; observers get the hit itself, and its
  setters raise there. `invalid-amount` is gone.
- `sourceOf`, `hit.dealer` and hits with no source are new (wc3-lib dropped hits without a source).
- Only failures are reported: a missing or unpaired DAMAGED event and a rejected native call are silent. A full queue
  raises instead of returning false, and `deal` returns nothing.
- Missiles and knockbacks have no ports: `Missiles` and `Knockbacks` are the Warcraft systems, and they tick from the
  scheduler they are given (`update(dt)` is not public).
- Vectors are plain numbers, not `{x, y, z}` tables.
- Missile heights are above the ground by default (`terrain = false` gives the old flat behavior), and `targetOffset`
  replaces the `centerHeight` callback. Each missile has its own `filter`; `followGround` and the effect's facing are
  new; contact ties follow the enumeration order, not handle ids.
- A knockback takes an angle and a distance (`knockbackVelocity` is gone). Pathing has a default that sees trees and
  buildings, and no policy leaves the world bounds.
