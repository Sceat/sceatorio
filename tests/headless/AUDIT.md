# Factorio 2.1.12, Space Age, robot-cap, and server-mod audit

Audit date: 2026-08-01. Gameplay code was inspected read-only for this audit;
the only implementation changes made here are under `tests/headless/`.

## Verified engine baseline

- The executable used was Wube's macOS arm64 build 87038, reporting Factorio
  `2.1.12` and map output `2.1.12-2`.
- Its bundled `runtime-api.json` and Wube's current downloaded JSON both report
  application version `2.1.12`, runtime API version `6`, and have identical
  SHA-256 `a60e482db523d3910f5ef6081032efc51862dc92e2523b35b263f501e956f310`.
- `tests/headless/run.sh smoke all` passed against isolated base and Space Age
  profiles. Both completed `on_init` and 120 benchmark ticks. Base averaged
  `0.267 ms/update`; Space Age averaged `0.281 ms/update`.
- `tests/headless/run.sh server space-age` created a save, reloaded it through
  the dedicated-server path, and reached `Hosting game` and
  `CreatingGame -> InGame`. The harness uses `SIGTERM` for bounded teardown;
  a background POSIX shell can inherit ignored `SIGINT`.
- The fixed-seed Space Age engine baseline completed three 3,600-tick runs at
  `0.270`, `0.269`, and `0.272 ms/update`, all with checksum `3216346747`.

These are real engine load and empty-save overhead results. They are **not** a
measurement of active logistic or construction robot performance.

Official references: [2.1.12 runtime API](https://lua-api.factorio.com/latest/),
[command-line parameters](https://wiki.factorio.com/Command_line_parameters).

## Remaining surface and Space Age gaps

The 2.1 port now has useful surface-keyed foundations:

- `src/game/teams.lua:170-194` stores one surface record per team and
  `src/game/teams.lua:196-221` finds only spawns on the queried surface.
- `src/game/spawns.lua:260-271` joins the target force and uses the target
  surface rather than deriving a force from a player name.
- `src/game/spawns.lua:421-437` correctly uses `event.surface` for generated
  chunks.

The secondary-planet feature is not implemented yet, and the existing primary
spawn mutator is not planet-safe:

- `src/game/spawns.lua:8-30` is a Nauvis-only terrain/resource profile.
- `src/game/spawns.lua:50-101` deletes native resources, cliffs, trees, and
  decoratives, paints `sand-1`, adds Nauvis ores/crude oil, and creates water.
  Applying it on Vulcanus, Fulgora, Gleba, or Aquilo would damage native
  progression and can create invalid terrain/resource combinations.
- `src/game/spawns.lua:296-325` creates only the initial spawn on the player's
  current lobby surface.
- `control.lua:64-69` observes surface changes only for evolution; it does not
  allocate a team spawn on first planetary arrival.
- `src/game/spawns.lua:403-406` calls `force_generate_chunk_requests()` from a
  periodic handler. Secondary generation should remain asynchronous to avoid a
  large multiplayer tick stall.
- `src/game/offlineSecurity.lua:1-16` still scans only `nauvis`; protection must
  cover all surfaces and must not protect a whole team merely because one
  teammate disconnected while another is online.
- No freeplay remote calls currently suppress vanilla intro/crash-site/starter
  items. The 2.1 base freeplay interface supports `set_skip_intro`,
  `set_disable_crashsite`, `set_created_items`, and `set_respawn_items`.

### Exact secondary-spawn invariant

Store exactly one authoritative record at:

```text
storage.sceatorio.team_spawns[force_index][surface_index] = {
  force_index, surface_index, planet_name,
  state = "reserved" | "generating" | "ready" | "retired",
  position, requested_radius, queued_player_indices,
  arrival_pod_unit_numbers, created_tick
}
```

This is force-and-surface keyed, never player keyed. Creation must first insert
the `reserved` record and only then request chunks, so two teammates arriving
on the same tick cannot allocate two locations. Later arrivals reuse the same
record. On force merge, move or reconcile records deterministically; on surface
deletion, retire the record and resolve pending arrivals without retaining
invalid LuaObjects.

A supported terrestrial destination must satisfy all of the following:

1. `surface.valid` is true.
2. `surface.planet` is non-nil.
3. `surface.platform` is nil. Never infer this from a surface-name prefix.
4. `surface.planet.name` has a registered profile (initially `nauvis`,
   `vulcanus`, `fulgora`, `gleba`, or `aquilo`). Unknown modded planets use a
   preserve-native fallback or are disabled by setting; they never receive the
   Nauvis mutator.

### Arrival event/state flow

Use the exact 2.1.12 events rather than polling every player every tick:

1. `on_cargo_pod_started_ascending` supplies `cargo_pod` and optional
   `player_index`. If its destination is a supported planet and the player's
   force lacks a record, atomically reserve a location and call
   `request_to_generate_chunks`.
2. If a force cargo landing pad already exists on the target surface, native
   landing-pad behavior wins. Register one safe respawn near that pad rather
   than redirecting the pod or creating duplicate resources.
3. Otherwise, set `cargo_pod_destination` to the reserved exact position only
   after an integration test proves the property remains writable at that pod
   phase. Do not block the tick waiting for chunks.
4. `on_cargo_pod_finished_descending` is authoritative for a rider landing and
   supplies the pod and optional `player_index`. Finalize/reuse the record,
   resolve a non-colliding character position, set the force spawn for that
   surface, and move any queued teammates.
5. `on_cargo_pod_delivered_cargo` supplies `spawned_container`; use it to keep a
   first-arrival cargo container with the player if fallback relocation was
   necessary.
6. `on_player_changed_surface` is the fallback for scripted teleports and
   non-pod travel. Confirm `player.character` exists and use
   `player.character.surface`; remote-view changes must not create a planetary
   spawn just because `player.surface` changed.
7. Track pod `unit_number` and validate every LuaObject before reuse. If async
   terrain is not ready at descent, use a visible temporary holding flow and
   relocate the player/container when ready; never delete the pod or cargo.

The exact event fields above were verified from the bundled 2.1.12 API JSON.
Relevant surface APIs are documented on
[LuaSurface](https://lua-api.factorio.com/latest/classes/LuaSurface.html).

### Planet-safe profiles

The portal-safe default should be `preserve-native`, with richer starter rings
opt-in. Minimal safety work should be small, reversible where practical, and
must not grant progression resources.

| Planet | Default behavior | Explicitly avoid |
| --- | --- | --- |
| Nauvis | Find buildable land, clear a compact hostile radius, preserve native patches for secondary spawns. The legacy rich bundle may remain an initial-Nauvis-only option. | Applying starter resources repeatedly per teammate. |
| Vulcanus | Select compact safe ground outside a demolisher territory; preserve lava and native ash terrain. | Creating tungsten/calcite, deleting or changing segmented-unit territories, or re-forcing individual demolisher segments. |
| Fulgora | Pick valid island ground and preserve lightning/ruin mechanics. | Deleting vault ruins/fulgurite or painting across oil ocean. |
| Gleba | Pick buildable native biome tiles and clear only a compact immediate pentapod danger area. | Creating agricultural soil, yumako/jellynut plants, or stromatolites, which bypasses progression. |
| Aquilo | Find a non-colliding heated/buildable arrival point, normally near a force landing pad. | Giving lithium brine/fluorine/crude oil or replacing broad ammoniacal-ocean/snow terrain. |

Nauvis enemies are conventional units/spawners/worm turrets; Gleba uses
pentapod units/spawners; Vulcanus uses segmented demolishers and territories.
Fulgora and Aquilo do not need a fabricated native enemy ecosystem. Use entity
types and `localised_name`, not a short hard-coded biter-name list. Keep
surface-specific evolution through `LuaForce.get_evolution_factor(surface)` and
its setter/component methods.

Suggested authoritative runtime-global settings:

- enable secondary spawns;
- per-planet enabled/profile choice;
- preserve-native versus starter-ring mode;
- reservation distance, generated radius, and compact safe radius;
- landing-pad precedence and unknown-planet policy.

Runtime-per-user settings should control only arrival messages or UI. Per-force
overrides belong in validated admin commands/remote interfaces because Factorio
does not provide runtime-per-force mod settings.

## Robot counts and enforceable caps

### API facts (verified, not inferred)

- `LuaForce.logistic_networks` is a read-only dictionary from surface name to
  arrays of `LuaLogisticNetwork`.
- `LuaLogisticNetwork.all_logistic_robots` and
  `all_construction_robots` are maintained total counts, including active,
  available, and robots in roboports. The corresponding `available_*` values
  are separate read-only counts.
- `logistic_robots`, `construction_robots`, and `robots` return deployed robot
  arrays. Do not materialize these in a frequent monitor merely to count them.
- `LuaLogisticCell.stationed_logistic_robot_count` and
  `stationed_construction_robot_count` expose docked counts. `mobile` identifies
  a personal/mobile cell, and `owner` identifies its character, vehicle, or
  roboport.
- `LuaLogisticNetwork.robot_limit` is read-only and documented as currently
  used only for personal roboports. It is not a static-network cap setter.
- `LuaEntity.allow_dispatching_robots` is writable only for Character and
  Vehicle subclasses. It cannot disable a static roboport network.
- `defines.inventory.roboport_robot` identifies a roboport's robot inventory.

There is no 2.1.12 runtime setter for separate static logistic/construction
network caps. References:
[LuaForce](https://lua-api.factorio.com/latest/classes/LuaForce.html),
[LuaLogisticNetwork](https://lua-api.factorio.com/latest/classes/LuaLogisticNetwork.html),
[LuaLogisticCell](https://lua-api.factorio.com/latest/classes/LuaLogisticCell.html).

### Accounting hierarchy

On a 300-tick cadence, stagger work across forces and networks:

```text
network total        = network.all_logistic_robots
surface-force total  = sum(force.logistic_networks[surface.name])
force-global total   = sum(all surface arrays for that force)
```

Compute construction totals independently. Ordinary chest/player inventory is
not a deployed network and should not count. Mobile/personal networks can be
reported separately; static-server policy should not accidentally penalize
personal construction equipment.

The monitor fast path is O(forces + networks) per interval and performs no
entity search. Only an exceeded network enters the slower cell/inventory path.
Networks split and merge, so cache cursors rather than durable network identity
and rebuild them safely each cycle.

### Proposed policy (requires the controlled benchmark)

These are conservative gameplay starting points, not claims about universal
UPS limits:

| Scope | Logistic soft / hard | Construction soft / hard |
| --- | ---: | ---: |
| Static network | 250 / 500 | 1,000 / 2,500 |
| Force + surface | 750 / 1,000 | 3,500 / 5,000 |
| Force global | 2,000 / 2,500 | 10,000 / 12,500 |

Do not scale a live hard cap down when players disconnect; that creates surprise
quarantines. Per-user authoritative caps are impossible because a logistic
network does not attribute shared robots to individual players. Use fixed
server-global defaults plus admin-set per-force overrides. Per-user options are
only notification/dashboard preferences.

For a portal release, default to warning-only until the fixture establishes a
safe policy on representative hardware. A curated dedicated-server preset can
enable strict enforcement. Wube's own performance work shows that busy robots,
jobs, charging, roboport count, and network geometry matter; robots are not
categorically slower than belts in every factory:
[FFF-415](https://factorio.com/blog/post/fff-415),
[FFF-421](https://factorio.com/blog/post/fff-421),
[FFF-374](https://factorio.com/blog/post/fff-374).

### No-silent-loss enforcement

Strict mode should quarantine **only stationary excess logistic robots**:

1. When a static network exceeds a hard layer, inspect its non-mobile cells.
2. Read each cell owner's `roboport_robot` inventory. Identify modded robot items
   by `prototypes.item[item_name].place_result.type == "logistic-robot"` (or
   `construction-robot` for the separately configured construction policy).
3. Transfer quality-preserving stacks into a recoverable, force-owned overflow
   vault until the target is reached. Never destroy or force-mine active robots;
   later cycles catch them as they dock.
4. If the vault cannot accept a full stack, leave the remainder in the roboport,
   keep the violation active, and alert the force/admin. Never discard or
   silently spill carried items.
5. Expose status and recovery through localized UI/admin commands. Raising or
   disabling a cap should return quarantined robots when capacity exists.
6. Document/export the vault before mod removal and migrate it on force merge or
   surface deletion.

Do not disable vanilla robot recipes/technologies: that conflicts with research
and other mods, does not catch imported robots, and cannot distinguish the two
robot classes reliably.

### Required performance fixture

`matrix.json` keeps robot integration/benchmark cases planned until a fixture
exists. Use fixed seeds and saves, warm the map, then run at least 36,000 ticks
and five measured repetitions. Vary:

- 1/8/24 forces and 1/5 terrestrial surfaces;
- one large versus many small roboport networks;
- 0/250/500/1,000/2,500 active logistic robots;
- 0/1,000/2,500/5,000 construction robots;
- cap off, warning-only, and strict modes;
- idle, sustained delivery, sustained construction, and charging congestion.

Compare median/p95 total update time and script time, not only averages. At 60
UPS the whole update budget is 16.667 ms; a reasonable monitor target is below
0.05 ms average or 1% of update time on the reference server. A dedicated
server startup test checks serialization and hosting, while the benchmark is a
single deterministic simulation; neither replaces a two-client desync test.

## Oarc Multiplayer Spawn comparison

The requested upstream was inspected at commit
`ba6cc666ea01658ec2fb096b3e48b887a5419213` (version 2.1.25).

Useful patterns to adopt:

- `control.lua:61-66` disables duplicate freeplay intro/crash-site/items.
- `control.lua:114-160` and `separate_spawns.lua:1834-1940` account for remote
  view and cargo-pod travel rather than relying only on surface-change events.
- `lib/config.lua:18-22` and `config.lua:376-398` provide five explicit planet
  profiles.
- `separate_spawns.lua:114-164` initializes surfaces and iterates `game.planets`.
- `separate_spawns.lua:1481-1665` reserves/generates secondary locations
  asynchronously.

Things to improve rather than copy:

- Its secondary ownership is host/player keyed; Sceatorio needs exactly one
  force/surface record.
- `config.lua:400-424` excludes platforms partly by name/prefix. Use the
  engine's `surface.planet`/`surface.platform` properties.
- Rich profiles can bypass progression: Vulcanus creates tungsten, Fulgora
  creates ruins/scrap, Gleba creates soils/crops, and Aquilo creates planetary
  fluids. Preserve-native should be the default.
- `scaled_enemies.lua:4-18` still marks Space Age work TODO; its demolisher loop
  (`337-390`) performs one removal per tick. Prefer choosing outside territories.
- `spawn_area_generation.lua:387-411` hardcodes force `player` for Fulgora
  lightning attractors instead of the actual team force.

## Required third-party server set

The Mod Portal API and the Cargo Ships 2.1 branch resolve the requested four
mods to this six-archive closure. Exact SHA-1s and dependencies live in
`matrix.json`.

| Package | Pin | Role |
| --- | ---: | --- |
| `aai-containers` | 0.4.0 | Direct; base >=2.1.7, optional ordered Space Age >=2.1.0 |
| `cargo-ships` | 2.1.6 | Direct |
| `cargo-ships-oil-rig` | 2.1.2 | Direct |
| `cargo-ships-floating-electric-pole` | 2.1.0 | Direct |
| `cargo-ships-graphics` | 2.1.0 | Required transitive |
| `Robot256Lib` | 2.1.4 | Required transitive; base >=2.1.12 |

AAI Containers is under a limited-distribution license: use the complete,
unmodified portal archive and do not publish a fork. Cargo Ships companions are
GPLv3, graphics are LGPLv3, and Robot256Lib is MIT.

Credential-free portal downloads redirect to login. The harness therefore does
not read a normal Factorio user-data directory or account token and marks the
combined cases `blocked-artifacts`. Once an operator downloads all six exact
archives into a dedicated staging directory, these commands verify every SHA-1,
copy only those files into isolated data, and exercise the pinned set:

```sh
FACTORIO_EXTERNAL_MOD_DIR=/path/to/staged-mods \
  tests/headless/run.sh smoke space-age required-server
FACTORIO_EXTERNAL_MOD_DIR=/path/to/staged-mods \
  tests/headless/run.sh server space-age required-server
```

Portal references:
[AAI Containers 0.4.0](https://mods.factorio.com/mod/aai-containers),
[Cargo Ships 2.1.6](https://mods.factorio.com/mod/cargo-ships),
[Oil Rig 2.1.2](https://mods.factorio.com/mod/cargo-ships-oil-rig),
[Floating Electric Pole 2.1.0](https://mods.factorio.com/mod/cargo-ships-floating-electric-pole).

### Cargo Ships source audit

Read-only source audit target:
`robot256/cargo_ships`, branch `V2.1support`, commit
`fe495302ea4ad289237defe0b0918bb13ee90e9c` (`Release 2.1.6`). This branch head
postdates the portal artifact, so static findings must still be reproduced
against the pinned portal zips before deployment.

Good performance characteristics:

- `control.lua:594-713` uses event filters; it does not scan all entities each
  tick. Rail placement checks at most six connected rails.
- `logic/ship_placement.lua:347-352` and
  `cargo-ships-oil-rig/logic/entity_placement.lua:73-78` register `on_tick` only
  while a placement queue is non-empty.
- `logic/bridge_logic.lua:267-272` registers a 72-tick bridge retry only while a
  destroyed-bridge queue exists.
- Oil rigs scan their stored rig table only on configuration migration, not as a
  permanent tick loop.

Public multiplayer hardening findings, in priority order:

1. **Unauthorised world mutation / possible stall:**
   `cargo-ships-oil-rig/logic/mapgen.lua:70-151` registers
   `/cargo-ships-set-oil-settings` without checking `command.player_index` or
   `player.admin`. Any permitted console user can change map generation and run
   `surface.regenerate_entity`. Values are checked only for non-nil fields, not
   numeric type, finiteness, or range (`123-140`), so malformed values may also
   raise a runtime error. Patch: allow RCON or admins only, validate three finite
   bounded numbers, address replies to the caller, and require explicit
   confirmation before regeneration.
2. **Unbounded information/log work:** `control.lua:836-837` and
   `cargo-ships-oil-rig/control.lua:230-231` let any player serialize all mod
   storage to the server log. Patch: admin/RCON gate and preferably compile the
   dump command out of production builds.
3. **Possible silent item/quality loss:** `logic/ship_placement.lua:52-78`,
   `logic/rail_placement.lua:39-49`, and
   `cargo-ships-oil-rig/logic/entity_placement.lua:4-30` call inventory `insert`,
   ignore the inserted count/remainder, then destroy the placed entity. A full
   player or construction-robot inventory can lose the refund; the rail path
   also does not explicitly preserve the placed entity's quality. Similar
   unchecked refund inserts exist in `logic/bridge_logic.lua:88-105`. Patch one
   shared quality-preserving refund helper that spills/logs a visible remainder
   only when insertion cannot complete, and never destroys before accounting
   for the full stack.
4. **Overwritten death handler:** `cargo-ships-oil-rig/control.lua:172-178`
   registers `on_entity_died` first for oil-rig ghosts and immediately registers
   the same event again for oil rigs. Factorio keeps one handler per mod/event,
   so the second registration replaces the ghost cleanup path. Patch a single
   dispatcher with combined filters or handle both entity kinds in one callback.
5. **Unbounded blocked bridge retry:** `logic/bridge_logic.lua:253-264` walks the
   entire pending bridge table every 72 ticks until one succeeds. A griefed set
   of permanently blocked bridges makes this O(blocked bridges) indefinitely.
   Patch a durable cursor and a small per-invocation budget.
6. **One-time migration spike and content interaction:**
   `cargo-ships-oil-rig/logic/mapgen.lua:4-26` regenerates offshore oil across
   generated Nauvis/Aquilo chunks when adding the mod. This is intentional but
   can stall a large established save. Back up and benchmark migration; the
   Sceatorio spawn mutator must preserve `offshore-oil`, waterways, and rig
   components.

Fork verdict: no fork is required merely for Factorio 2.1/Space Age loading;
the active upstream has current 2.1 releases and generally sound event-driven
runtime design. For an untrusted public server, a small pinned GPL fork (or an
accepted upstream patch) is justified because Sceatorio cannot safely replace
another mod's local command callbacks/refund logic. Reproduce findings 1-4 with
the pinned portal archives first, send minimal upstream fixes, and carry a fork
only until those fixes ship. Do not fork AAI Containers.

## Prioritized implementation order

1. Add the force/surface reservation state machine, exact supported-surface
   predicate, cargo-pod events, surface/force merge cleanup, and freeplay remote
   integration.
2. Split initial Nauvis terrain from preserve-native planetary safety profiles;
   eliminate blocking generation from periodic handlers.
3. Add robot telemetry and localized warning-only policy using native network
   counts; build the controlled benchmark before enabling strict defaults.
4. Add stationary-only, quality-preserving quarantine and recovery with explicit
   failure alerts; implement the planned no-silent-loss integration case.
5. Supply the six pinned third-party archives to the isolated staging command,
   run combined smoke/server/benchmark tests, and reproduce Cargo findings.
6. Upstream the Cargo hardening patch or pin a minimal GPL fork for public
   multiplayer, then run a real two-client join/planet-arrival/desync matrix.
