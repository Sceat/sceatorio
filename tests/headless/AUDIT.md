# Factorio 2.1.12, Space Age, robot-cap, and server-mod audit

Audit date: 2026-08-01. The audit informed the Factorio 2.1/Space Age runtime
implementation and its static and isolated-engine validation under `tests/`.

## Verified engine baseline

- The executable used was Wube's macOS arm64 build 87038, reporting Factorio
  `2.1.12` and map output `2.1.12-2`.
- GitHub Actions uses Wube's free Linux headless archive from the exact 2.1.12
  URL and verifies SHA-256 `885ff029a40b0edd815cfe1fc13845f232723da1ea8fe9a83eae114d1eccd3fe`
  from the matrix SSOT before running the same isolated first-party suite.
- Its bundled `runtime-api.json` and Wube's current downloaded JSON both report
  application version `2.1.12`, runtime API version `6`, and have identical
  SHA-256 `a60e482db523d3910f5ef6081032efc51862dc92e2523b35b263f501e956f310`.
- `tests/headless/run.sh smoke all` passed against isolated base and Space Age
  profiles after the Space Age and robot-policy implementation. Both completed
  `on_init` and 120 benchmark ticks. The final audit run averaged
  `0.260 ms/update` for base and `0.306 ms/update` for Space Age.
- `tests/headless/run.sh server space-age` created a save, reloaded it through
  the dedicated-server path, and reached `Hosting game` and
  `CreatingGame -> InGame`. Checkpoint fixtures now wait for Factorio's
  `Saving finished` marker before bounded `SIGTERM` teardown. This closes a
  reproduced Factorio 2.1.12 `ParallelScenarioSaver` SIGSEGV caused by
  terminating while `game.server_save` was still completing asynchronously.
- The fixed-seed Space Age engine baseline completed three 3,600-tick runs at
  `0.275`, `0.271`, and `0.268 ms/update`, all with checksum `3835234403`.
- The isolated `security.runtime-wire-isolation` fixture passed on the same
  build. Dedicated-server checkpoint/reload fixtures also emitted
  `SCEATORIO_OFFLINE_PASS`, `SCEATORIO_EVOLUTION_PASS`, and
  `SCEATORIO_ROBOT_POLICY_PASS`, covering exact offline restoration,
  persisted team/surface evolution, and non-destructive production
  pause/clone restoration. The 64-network/1,024-candidate stress fixture also
  emitted `SCEATORIO_ROBOT_PERFORMANCE_PASS`. The Space Age fixture emitted
  `SCEATORIO_PLANET_PASS` for all three matrix requirements after creating all
  five built-in planet surfaces and a real platform, keeping two teams
  separated, preserving native terrain/content, rejecting the platform, and
  reassigning a pre-generated Gleba hostile without touching the other team's
  hostile. The full static suite passed 105 of 105 checks.

These are real engine load and empty-save overhead results. They are **not** a
measurement of active logistic or construction robot performance.

### Radar and player-HUD performance invariants

- Every 600 ticks, one bounded pass shares the original 70-tile connected-player
  and 112-tile team-radar footprints. Overlapping source chunks are deduplicated
  within that pass, currently visible or already-requested destinations are
  skipped, and every chart refresh is preceded by `surface.is_chunk_generated`.
  A generated chunk that is permanently charted but currently fogged is
  re-charted so cross-team player and radar positions remain live.
- There is no `on_chunk_charted` feedback handler, canonical union force,
  persistent propagation queue, or full-surface catch-up scan. Chart sharing can
  therefore neither request new terrain nor turn its own writes into a map sweep.
- The compact top-left player HUD caches sorted online/offline player indexes.
  Join/leave/force/surface events rerender only bounded visible pages rather
  than rescanning and drawing all historical players for every viewer. Online
  and offline counts remain exact, with six entries per independent page, so
  every engine-maintained cumulative playtime remains reachable without an
  unbounded panel or a scroll-pane style write.

### Immediate offline-transition fixture

The exact-2.1.12 `security.offline-transition-overhead` fixture builds a dense
synthetic base of 10,000 real stone walls on generated, paved Nauvis terrain.
Nine thousand start with the normal destructible state and 1,000 start false.
It profiles the immediate unprotect/protect call separately from verification,
then synchronously checks every entity after the call, checkpoints while
protected, reloads in a second Factorio process, and repeats exact restoration
and protection. The development call's ordinary diagnostic status snapshot is
explicitly suppressed only for this measurement; its default behavior remains
unchanged.

The production transition walks the force-index bucket in place with `next`,
capturing each successor before stale-entry validation. A static regression
test rejects the former `local registrations = {}` O(N) snapshot in this
critical path. Touching each registered durable entity is still inherently
O(N), because immediate protection requires writing every entity's
`destructible` property. This dense wall grid isolates traversal and property
writes; it does not model a mixed active factory, combat, client/network join
latency, third-party entities, or comparative megabase UPS.

The fixture passed on Wube's macOS arm64 Factorio 2.1.12 build 87038 and emitted
`SCEATORIO_OFFLINE_PERFORMANCE_PASS` after four immediate profiled transitions
and the protected checkpoint reload. All 10,000 registrations were in the
expected state when checked immediately after each call returned. Both
pre-save and post-reload unprotect calls restored 9,000 true plus 1,000
preexisting false states.

A retained rerun on the audited macOS 15.7.3 arm64 host (14 cores, 36,864 MB
RAM as reported by Factorio) produced these `LuaProfiler` wall-time samples:

| Transition | Tick | Duration |
| --- | ---: | ---: |
| Unprotect before save | 0 | 47.146000 ms |
| Protect before save | 0 | 65.582459 ms |
| Unprotect after reload | 2 | 54.373041 ms |
| Protect after reload | 2 | 45.199542 ms |

The four-sample range was 45.200-65.582 ms and the median was 50.760 ms. At
10,000 registered entities, an immediate presence transition can therefore
consume roughly 2.7-3.9 nominal 60-UPS update budgets on this host and may be a
visible one-off hitch. The samples include the development-interface call
boundary but exclude its O(N) status report and exclude the fixture's entity
verification loop. They are one synthetic run, not a percentile, cross-host
benchmark, active-factory measurement, or release latency threshold. The
static test proves specifically that Sceatorio creates no second O(N) Lua
registration snapshot in the transition; it does not claim that Factorio's
property writes allocate nothing internally.

Official references: [2.1.12 runtime API](https://lua-api.factorio.com/2.1.12/),
[free Linux headless server](https://factorio.com/support/faq),
[command-line parameters](https://wiki.factorio.com/Command_line_parameters).

## Implemented surface and Space Age policy

The 2.1 port now has surface-keyed foundations and a secondary-planet state
machine:

- `src/game/teams.lua:170-194` stores one surface record per team and
  `src/game/teams.lua:196-221` finds only spawns on the queried surface.
- `src/game/planetSpawns.lua` stores one reservation per team and real planet
  surface. The first physical arrival reserves it before chunk generation;
  later teammates reuse it.
- Real planets are detected from `surface.planet`; `surface.platform` is
  excluded. Unknown modded planets use the same preserve-native fallback.
- Candidate work is bounded and uses only `request_to_generate_chunks` plus
  generated-chunk checks. It does not paint tiles, add resources, remove cliffs
  or decoratives, or synchronously force secondary chunks.
- Vulcanus candidates avoid demolisher territories. Immediate hostile clearing
  is limited to conventional Nauvis/Gleba units, spawners, and turrets;
  segmented units and unknown-planet mechanics are untouched.
- Player arrival uses `player.character.surface`, so Space Age remote view does
  not allocate a false spawn. Join, respawn, cargo-pod, force-merge, runtime
  setting, and surface-deletion paths are wired.
- Each human team retains its own spawn, economy, and evolution ledger on every
  planet. Human-team friendship, ceasefire, and native force chart sharing do
  not merge those records or alter per-team enemy-force assignment.
- Pollution evolution follows Factorio's actual 2.1.12 consumption boundary:
  `LuaSurface.pollution_statistics.output_counts` is surface-global rather
  than force-scoped. Once per recorded surface per second, Sceatorio iterates
  only those statistic keys and sums values whose runtime entity prototype has
  type `unit-spawner`; every existing team ledger on that surface receives the
  same positive delta. Gross input emissions and non-spawner outputs do not
  count, so trees and scrubbers can reduce future evolution by intercepting
  pollution before a nest consumes it. No chunk/entity scan, pollution-cloud
  proximity, or triangulation is involved, and evolution already credited is
  never subtracted. A first/reduced counter rebaselines and disabled evolution
  advances its cursor without back-charge. The real evolution checkpoint
  fixture covers gross-emission rejection, exact biter-spawner consumption,
  two teams, a late team, another surface, freeze/re-enable, reset, and reload.
- A first surface-targeted cargo pod is held while its asynchronous reservation
  finishes, then released to the stable exact position. Landing-pad and other
  non-surface destinations remain native. The pod and cargo are never deleted.
- Guarded Freeplay remote calls disable the intro, crash site, and duplicate
  starter/respawn item grants without assuming the interface exists.

### Exact secondary-spawn invariant

The authoritative record lives under the existing team surface record:

```text
storage.sceatorio.teams[team_id].surfaces[surface_index] = {
  spawn,
  planet_spawn = {
    state = "generating" | "ready",
    planet_name, candidate, waiting_players, cargo_pods, created_tick
  }
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
4. Unknown modded planets use a preserve-native fallback; they never receive
   the initial-Nauvis terrain/resource mutator.

### Arrival event/state flow

Use the exact 2.1.12 events rather than polling every player every tick:

1. `on_cargo_pod_started_ascending` supplies `cargo_pod` and optional
   `player_index`. If its destination is a supported planet and the player's
   force lacks a record, atomically reserve a location and call
   `request_to_generate_chunks`.
2. A later trip to a team surface whose spawn is already ready keeps its native
   explicit destination; stable-spawn reuse does not hijack normal travel.
3. For the first asynchronous reservation, write `disabled_by_script` and read
   it back before recording that Sceatorio held the pod. A successful `pcall`
   alone is insufficient because some updatable subclasses ignore writes. If
   readback confirms the hold, set `cargo_pod_destination` to the reserved exact
   position when terrain is ready and release only Sceatorio's own hold. If the
   write is ignored, fail open: keep native descent and use the physical-arrival
   path after landing. Do not claim that the pod paused.
4. `on_cargo_pod_finished_descending` is authoritative for a rider landing and
   supplies the pod and optional `player_index`. Finalize/reuse the record,
   resolve a non-colliding character position, set the force spawn for that
   surface, and move any queued teammates.
5. The pod and its cargo are never deleted or recreated by the spawn path.
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
- `LuaEntity.active` is read-only. Crafting entities instead expose the
  writable `disabled_by_script` flag, whose previous boolean state can be
  preserved and restored without touching recipe progress or inventories.
- Recipe products expose their item prototype; an item's `place_result.type`
  distinguishes logistic-robot from construction-robot products, including
  ordinary modded robot recipes.
- Factorio 2.1.12 has `on_entity_settings_pasted`, but no general recipe-changed
  event. Manual recipe changes therefore require a bounded registered-machine
  poll.

There is no 2.1.12 runtime setter for separate static logistic/construction
network caps. References:
[LuaForce](https://lua-api.factorio.com/latest/classes/LuaForce.html),
[LuaLogisticNetwork](https://lua-api.factorio.com/latest/classes/LuaLogisticNetwork.html),
[LuaLogisticCell](https://lua-api.factorio.com/latest/classes/LuaLogisticCell.html).

### Accounting hierarchy

Fixed roboports are registered from build, clone, mine, death, script-raised,
and Space Age platform events. A two-port-per-tick round-robin obtains each
fixed network's engine-maintained aggregate and deduplicates it by force,
surface, network id, and game tick:

```text
network total        = network.all_logistic_robots
surface-force total  = sum(force.logistic_networks[surface.name])
force-global total   = sum(all surface arrays for that force)
```

Compute construction totals independently. Ordinary chest/player inventory is
not a deployed network and should not count. Mobile/personal networks can be
reported separately; static-server policy should not accidentally penalize
personal construction equipment.

The monitor performs no surface entity search and never materializes robot
entity arrays. Registered-port membership retires a snapshot when its last
fixed port disappears. During network split/merge discovery the conservative
old snapshot remains until its registered ports are revisited, avoiding a
temporary undercount. All network snapshots are then summed force-wide, so
splitting a network or spreading it across planets cannot evade the cap.

### Implemented conservative policy

Caps are force-wide across all fixed networks and surfaces so a team cannot
evade them by splitting a network. Static platform roboports are included;
personal/mobile cells are excluded. Logistic and construction classes are
counted independently using engine-maintained network aggregates.

| Default mode | Logistic cap | Construction cap |
| --- | ---: | ---: |
| `enforce` | 500 | 5,000 |

Do not scale a live hard cap down when players disconnect; that creates surprise
production stops. Per-user authoritative caps are impossible because a logistic
network does not attribute shared robots to individual players. Use fixed
server-global settings. Per-user options are only notification/dashboard
preferences.

The runtime mode is `disabled`, `warn`, or `enforce`; `enforce` is the default,
with warning-only and fully disabled modes retained for server operators. Zero
means unlimited. Wube's own performance work shows that busy robots,
jobs, charging, roboport count, and network geometry matter; robots are not
categorically slower than belts in every factory:
[FFF-415](https://factorio.com/blog/post/fff-415),
[FFF-421](https://factorio.com/blog/post/fff-421),
[FFF-374](https://factorio.com/blog/post/fff-374).

### Non-destructive enforcement

Strict mode never moves, removes, destroys, or hides any robot or item:

1. At or above either non-zero force-wide cap, mark that robot class as blocked.
2. Inspect only registered assembling machines, furnaces, and rocket silos.
   Classify every current recipe product through
   `prototypes.item[product.name].place_result.type`, with the standard robot
   item names as a fallback. Any matching product in a multi-product recipe is
   sufficient.
3. Snapshot the machine's exact prior `disabled_by_script` boolean, then set it
   true. Do not write inventories, recipe progress, productivity, quality, or
   the read-only `active` property.
4. Restore the exact prior boolean when totals fall below the relevant cap, the
   recipe changes, or enforcement is disabled. A clone of a paused machine
   inherits the source's logical prior state rather than the clone's temporary
   disabled state.
5. Existing, flying, manually supplied, imported, and stored robots remain
   untouched. Manual overflow stays visible, produces a warning, and keeps
   matching production paused.
6. Build and settings-paste events evaluate immediately. Because 2.1.12 has no
   general recipe-change event, a persistent round-robin checks eight registered
   candidates per tick; diagnostics disclose this bounded delay. Candidate
   prototypes are prefiltered to crafting categories used by at least one
   vanilla or modded robot-producing recipe. With `C` candidates, worst-case
   manual recipe-change detection is `ceil(C / 8)` ticks.
7. Crossing a cap performs an O(1) force enqueue. A separate priority queue
   revisits only machines currently known to produce a robot recipe, with one
   global budget of 32 queue steps per tick and round-robin progress across
   queued forces. Empty/stale force entries consume that same budget; they
   cannot turn a settings change involving many teams into an unbounded tick.
   A stable queued set of `R` robot-recipe machines requires
   `ceil(R / 32)` processing ticks rather than creating an
   unbudgeted threshold spike; the ordinary eight-machine recipe poll continues
   independently.

Do not disable recipe prototypes or technologies: that conflicts with research
and other mods. The runtime machine flag is reversible and applies only while a
currently selected recipe makes a robot class whose team cap is reached.

### Measured synthetic performance fixture

The exact real-2.1.12 `robot.production-pause-roundtrip` fixture already proves
same-surface split-network aggregation, non-destructive threshold pause,
input/progress preservation, exact prior script-disabled restoration, paused
clone behavior, save/reload continuity, and that robot items are not moved. It
remains the small correctness test.

The additional exact-2.1.12 `robot.cap-overhead` fixture is a deterministic
worst-shape policy workload, not a simulated megabase. It creates 64 separate
fixed networks, docks 499 logistic and 4,999 construction robots, and registers
1,024 assembling-machine candidates. The candidates comprise 256 logistic
robot recipes, 256 construction robot recipes, and 512 unrelated recipes. It
then repeatedly crosses both real defaults (500/5,000), verifies every matching
producer stops and resumes, verifies every unrelated recipe remains enabled,
and reloads the enforced checkpoint. No robot array is materialized.

The original 16-port/second monitor took 240 ticks (4.000 s) for each repeated
worst-position stop/resume transition. Sampling two registered ports per tick
reduced the repeated transitions to 32 ticks (0.533 s); the first aligned
transition took 23 ticks. The exact fixture's 64-tick regression bound covers
the analytical maximum of `ceil(P / 2) + ceil(R / 32)` plus event ordering for
its `P=64` ports and `R=512` known robot producers. Recurring production work
is now capped at two port inspections, eight candidate recipe checks, and 32
threshold-reevaluation queue steps per tick.

Five sanitized 3,600-tick benchmark repetitions on the same synthetic
checkpoint measured these total-update averages on the audited macOS arm64
machine:

| Monitor | Runs (ms/update) | Median | 60-UPS budget |
| --- | --- | ---: | ---: |
| 16 ports/second (before) | 0.340, 0.341, 0.339, 0.341, 0.343 | 0.341 ms | 2.05% |
| 2 ports/tick (implemented) | 0.383, 0.368, 0.365, 0.366, 0.370 | 0.368 ms | 2.21% |

The measured median cost of the faster sampling schedule is therefore 0.027
ms/update, or 0.16% of the 16.667 ms update budget. One implemented run had a
5.437 ms single-update maximum; the other implemented-run maxima were
1.504-1.598 ms, so no p95 is inferred from these aggregate CLI results. The
transition `LuaProfiler` samples include real-time server pacing and fixture
verification work and are retained as diagnostics, not misreported as isolated
mod CPU time. All five checksums matched within each build.

Candidate breadth remains intentionally conservative: vanilla robot recipes use
the general crafting category, so all vanilla assemblers are candidates even
when their current recipe is unrelated. This costs at most eight recipe checks
per tick, but a manual recipe switch has worst-case detection latency
`ceil(C / 8)`; the 1,024-candidate fixture implies 128 ticks (2.133 s). Builds
and settings-paste events are evaluated immediately, and an already-known robot
recipe uses the 32-step priority queue when a cap changes.

The cap counts robots in fixed logistic networks, not robot items sitting in
assemblers, chests, player inventories, or other storage. A craft that completes
during the bounded network-sample/priority-queue delay can therefore overshoot
the threshold, and stored output does not itself trigger the cap. Once deployed
network totals reach the threshold, matching production stops; no existing
robot or item is deleted to manufacture an instantaneous hard limit.

This synthetic workload keeps all robots docked in unpowered ports. It does not
measure pathfinding, active jobs, charging congestion, quality variants,
multiple planets/platforms, or competing mods. `matrix.json` therefore keeps
the real Space Age active-megabase benchmark explicitly planned. That benchmark
should use fixed seeds and saves, warm the map, then run at least 36,000 ticks
and five measured repetitions while varying:

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

1. Add real-client coverage for simultaneous rider arrival, cargo-pod
   hold/readback/fallback, force merge, and surface deletion. Headless core
   planet reservation and exact robot production restoration now have
   dedicated checkpoint/reload fixtures.
2. Build the controlled robot workload benchmark to validate or tune the
   `enforce` defaults (500 logistic / 5,000 construction) before claiming a
   server-safe universal cap.
3. Supply the six pinned third-party archives to the isolated staging command,
   run combined smoke/server/benchmark tests, and reproduce Cargo findings.
4. Upstream the Cargo hardening patch or pin a minimal GPL fork for public
   multiplayer, then run a real two-client join/planet-arrival/desync matrix.
