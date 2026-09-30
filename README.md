# Moonwell Systems

Opt-in Warcraft III systems for [Moonwell](https://github.com/mdlsvensson/moonwell) maps, ported from `wc3-lib`: a
deterministic scheduler, signals, ownership scopes and time helpers today; dummies, buffs, damage, physics and save
codes in later releases. Annotated Lua 5.3, built on [moonwell-wrappers](https://github.com/mdlsvensson/moonwell-wrappers),
with editor completion for YueScript and Lua maps.

**Status:** `v0.1.0` (unreleased): `systems.scheduler`, `systems.signal`, `systems.scope` and `systems.time`. It needs
moonwell-wrappers `v0.7.0` or later and Moonwell 0.5.2 or later. Multiplayer desync checks are deferred until before
Moonwell 1.0.

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

## Changes from wc3-lib

- Failures are printed or passed to `onError`, never rethrown (wc3-lib rethrew task and release errors).
- `Scheduler:start()` replaces `startWarcraftClock`.
- Signal listeners are isolated from each other.
- `Scope:add` also accepts `destroy` and `remove`, so wrappers can be added directly.
- The time range is 32-bit (wc3-lib accepted years 1 to 9999, which do not fit Warcraft's integers), and
  `Time.localUtc()` reads `os.time()`, which Warcraft 3.0.0.24268 has.
- `SimulationTime` and `LocalWallTime` are gone: use `scheduler:getElapsed()` and `Time.localUtc()`.
