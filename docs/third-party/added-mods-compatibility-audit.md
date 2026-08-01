# Added server mods: Factorio 2.1.12 compatibility audit

Audit date: 2026-08-01. The canonical audited versions, hashes, dependency
strings, source commits, approved set, and blocked candidates are in
[`added-mods-2.1.12.lock.json`](added-mods-2.1.12.lock.json). This report does
not replace a production server lock. The JSON is an audit proposal with
`production_lock=false`; consumers must not treat its `blocked_candidates` as
deployable mods.

The target is Factorio 2.1.12 build 87038 with Space Age. Wube currently labels
2.1.12 as the latest experimental API and 2.0.77 as stable, so a 2.0 server
needs a separate lock rather than older archives mixed into this one. See the
[official API version index](https://lua-api.factorio.com/) and
[2.1.12 API documentation](https://lua-api.factorio.com/latest/).

## Deployment decision

| Mod | Decision | Reason |
| --- | --- | --- |
| `Aircraft-space-age` 2.3.5 | Add the exact Portal ZIP | The Portal artifact is reproducible from the tagged GitHub release and passed Base, Space Age, Sceatorio, save-add/remove, and dedicated-server loads. Keep the surface restriction on and disable its vanilla technology-tree rewrite. |
| `nuclear-thruster` 1.2.4 | Blocked; stage and verify before any canary | The exact upstream commit passed real 2.1.12 tests, but the Portal ZIP could not be fetched without credentials, the mod globally replaces the vanilla centrifuge fluid boxes, and its GitHub repository has no license file despite the Portal's GPLv3 declaration. |
| `MushroomCloud2` 2.1.34 | Keep disabled until the exact ZIP passes the gate below | It was released one day before this audit, publishes no source, and requires authenticated Portal download. Its recent changelog describes significant runtime/rendering changes and earlier compatibility crashes. Source, multiplayer, stress, force, and license audits remain blocked. |
| `aai-signal-transmission` 0.6.0 | Keep in the blocked server inventory until the exact ZIP passes a two-force gate | It is the current 2.1 release and its Portal SHA-1 is pinned, but there is no source. Its unlimited cross-surface circuit reach is useful for AI ports while also making force isolation, hidden electric helpers, authorization reach, and active-channel cost release-critical. |

All four exact releases exist on the Mod Portal and remain client-synchronizable
once their gates pass. Factorio's synchronization only works for Portal-hosted
versions; it does not transfer an arbitrary server-local ZIP. See the official
[mod synchronization documentation](https://wiki.factorio.com/Mods#Downloading_&_installing_mods)
and [Mod Portal API download rules](https://wiki.factorio.com/Mod_portal_API#Downloading_Mods).

## Dependency closure

There are no additional required third-party dependencies for these four
mods:

- Aircraft requires only Base. Its Space Age, Aircraft Realism, Helicopter
  Revival, Muluna, and Bob dependencies are optional. Version 2.3.5 removed the
  required `flib` dependency.
- Nuclear Thruster requires Base and Space Age. Space Age in turn requires the
  bundled Elevated Rails and Recycler mods; Quality is recommended by Space
  Age and is enabled in the proposed server profile.
- Mushroom Cloud 2 requires only Base. Its 17 nuclear-overhaul integrations are
  optional. It explicitly conflicts with `StopgapNukes` and the older
  `mushroom-cloud`; neither is in the requested server set.
- AAI Signal Transmission requires only Base >=2.1.7. Space Age >=2.1.0 is an
  ordered optional dependency, so the server's bundled Space Age 2.1.12
  satisfies it without another Portal archive.

The complete literal dependency strings are retained in the lock. Optional
dependencies must not be installed merely to satisfy closure.

## Aircraft 2.3.5

Primary sources: [Portal record](https://mods.factorio.com/mod/Aircraft-space-age),
[tag `v2.3.5`](https://github.com/nicholasgower/Aircraft-Space-Age/tree/v2.3.5),
[upstream issues](https://github.com/nicholasgower/Aircraft-Space-Age/issues), and
[Portal discussions](https://mods.factorio.com/mod/Aircraft-space-age/discussion).

### What is safe

- The GitHub release asset SHA-1 is exactly the Portal SHA-1. This is the only
  audited release for which the tested bytes are proven to be the Portal bytes.
- `control.lua` is an effective no-op. There is no `on_tick`, persisted state,
  remote interface, command, rendering queue, console privilege, force
  mutation, or LuaObject retention. It cannot create a system force.
- The exact ZIP loaded on Factorio 2.1.12 with Base alone and with all bundled
  Space Age mods. It also loaded and ran with Nuclear Thruster and the current
  Sceatorio.
- Its open sound-path report concerns Aircraft 2.3.4 on Factorio 2.0.69. The
  2.3.5 ZIP contains the referenced sound and loaded cleanly in the target
  engine. Version 2.3.5 also adopted the 2.1
  [`driving_sound_volume_modifier`](https://forums.factorio.com/viewtopic.php?t=133782).
- The package and its predecessor are declared MIT and the repository contains
  the current and predecessor MIT notices. Upstream credits the graphics and
  sounds, although a per-asset manifest would still be cleaner.

### Confirmed crash blind spot

Aircraft still has a 1.1-era compatibility branch in `data-updates.lua`. If
any enabled mod defines a recipe named `rifle`, it reads the removed
`recipe.normal` and `recipe.expensive` fields. A minimal 2.1 recipe probe
reproduced this exact startup failure:

```text
Failed to load mod "Aircraft-space-age":
__Aircraft-space-age__/data-updates.lua:23:
attempt to index field 'normal' (a nil value)
```

None of Sceatorio, AAI Containers, Cargo Ships and its required submods,
Nuclear Thruster, or Mushroom Cloud 2 declares `rifle`, so this is not a crash
in the requested closure. It is a deterministic future-mod trap. Upstream
should replace that branch with direct 2.1 `ingredients` editing or remove it.
A fork is unnecessary for the current set, but a future rifle-bearing mod must
be blocked until Aircraft is fixed.

### Balance, grief, and performance concerns

- With Space Age and default settings, Aircraft changes vanilla progression:
  Rocket Silo requires Cargo Planes, and Space Platform Thruster requires
  Afterburner. Set `aircraft-change-vanilla-tech-tree=false` to keep the server
  pack composable and avoid surprising progression coupling with Nuclear
  Thruster.
- Keep `lock-surfaces-space-age=true`. Aircraft then require at least 700 hPa
  pressure and at most 20 m/s² gravity: the intended usable planets are Nauvis,
  Gleba, and Fulgora, not Vulcanus, Aquilo, or space platforms. Sceatorio's
  per-team secondary spawn does not need to override this.
- Without the optional Aircraft Realism mod, all four vehicle prototypes have
  an empty collision mask, are placeable off-grid, support remote driving, and
  include weapons on three variants. This is intended flight behavior, but it
  bypasses terrain and wall boundaries. Claim/offline protection must treat a
  remotely driven aircraft exactly like an on-site hostile player.
- The cargo plane source currently exposes 120 inventory slots even though an
  older changelog said it had been reduced to 40. It also supports vehicle
  logistic requests and has a trash inventory. Robot-count caps do not cap
  request throughput, so a large cargo-plane fleet can still create intense
  logistic work or bypass the intended belt-first economy.
- There is no Lua update cost while idle. The main scale risks are engine-side
  vehicle simulation, remote fleets, smoke/light rendering, and the 22 MB
  client asset archive. These require active-fleet/client-FPS tests, not an
  empty headless benchmark.
- Historical AAI crash reports involve Aircraft Realism and AAI Programmable
  Vehicles. The requested `aai-containers` is a different mod and the current
  server does not request Aircraft Realism.

## Nuclear Thruster 1.2.4

Primary sources: [Portal record](https://mods.factorio.com/mod/nuclear-thruster),
[source repository](https://github.com/versuffer/factorio-mod-nuclear-thruster),
and exact audited commit
[`a6cdd9f`](https://github.com/versuffer/factorio-mod-nuclear-thruster/commit/a6cdd9f7fde73b6efb2738e8cfb2ca63646c4b10).

### What is safe

- The mod is data-stage-only. It has no `control.lua`, event handlers, mutable
  storage, LuaObjects, commands, remote interfaces, player iteration, surface
  scans, random behavior, or force creation.
- Commit `a6cdd9f` contains real 2.1 prototype changes, not only a metadata
  bump: plural recipe categories, independent result probabilities, and
  updated centrifuge pipe graphics. Its source snapshot loaded cleanly on
  Factorio 2.1.12 with Space Age, both with and without the optional Quality
  built-in mod.
- It has no names or technology prerequisites in common with Aircraft, Cargo
  Ships, its oil-rig/floating-pole components, AAI Containers, or Sceatorio.
  Mushroom Cloud does not list it because this thruster is not a nuclear
  weapon or detonation source.
- Script update cost is zero. Runtime work is the engine's ordinary thruster,
  fluid, platform, plume, and recipe simulation.

### Compatibility and lifecycle risks

- It deep-copies the vanilla `centrifuge`, replaces its entire `fluid_boxes`
  array with one north input and one south output, then re-registers the same
  prototype name. That is a global prototype override, not a private machine.
  The requested closure does not otherwise touch centrifuges, so it loads
  today, but any overhaul that also changes centrifuge fluid boxes is a
  last-writer/order conflict and can silently break recipes even without a
  startup crash. Prefer an upstream custom centrifuge or a merge that preserves
  existing boxes.
- The Portal ZIP is pinned by SHA-1, but no public GitHub release/tag asset
  exists to compare with it. Only the matching source commit was tested. The
  authenticated Portal bytes must be tested before production.
- The GitHub repository has no `LICENSE` file and GitHub reports no detected
  license, while the Portal declares GNU GPLv3. Do not publish or redistribute
  a derived ZIP until the author adds the license text and confirms graphics
  provenance. Using the author's Portal release avoids inventing a fork
  provenance chain.
- The project was created less than two weeks before this audit, 1.2.4 was
  three days old, and it had no issue reports, tagged releases, or discussions.
  Absence of reports is not maturity evidence.
- Startup settings can raise fuel value to 85 MJ, fluid use to 200%, and other
  performance parameters. The asteroid recipe also creates uranium ore in
  space. Keep the audited defaults in the lock; treat changes as balance-pack
  changes requiring a new save benchmark.
- Adding both source-available mods to an existing Sceatorio save and loading
  them for 600 ticks passed. Removing them after placing an aircraft and a
  centrifuge also loaded: Factorio removed the now-unknown aircraft and retained
  the vanilla centrifuge. That is non-crashing, not lossless. A populated
  nuclear thruster, quality variants, centrifuge fluids, platform blueprints,
  and logistic requests still need backup/restore tests before removal or an
  upgrade.

## Mushroom Cloud 2.1.34

Primary sources: [Portal record](https://mods.factorio.com/mod/MushroomCloud2),
[downloads](https://mods.factorio.com/mod/MushroomCloud2/downloads), and the
[fixed Ion Cannon startup-crash report](https://mods.factorio.com/mod/MushroomCloud2/discussion/694c1cca592b8470092a4b18).

This release cannot yet be approved from evidence:

- It has no source URL or homepage. Unauthenticated downloads redirect to
  Factorio login, and this audit intentionally did not read a personal Factorio
  profile or token. Therefore no claims can be made about `storage`, system
  forces, duplicate event registration, admin gates, deterministic iteration,
  retained LuaObjects, queue bounds, or actual settings names.
- Version 2.1.34 was published on 2026-07-31, the day before this audit. Its
  changelog says 1.1.34 moved compatibility patching to final fixes, preserved
  Space Age surface-specific tile/damage effects, prevented duplicate Ion
  Cannon effects, and guarded expired render objects. Earlier 1.1.17 fixed a
  nil `action_delivery` startup crash; 1.1.31 reworked recursive trigger
  patching and persisted render state. Those are encouraging fixes but also
  identify high-risk code paths that need direct review.
- The feature necessarily creates explosion entities, crater/tile effects,
  per-player distance-based sounds, and active multi-layer lights. Recent
  changelog text says idle tick dispatch was eliminated, but simultaneous
  detonations can still scale with active render records, effect entities,
  affected tiles, and players. Headless tests with audio disabled cannot
  measure client rendering or sound impact.
- Optional crater radiation creates a new public-server grief surface. Test
  damage attribution and force filtering for two hostile Sceatorio teams,
  offline claims, characters, vehicles, construction bots, Gleba biological
  enemies, and non-Nauvis surfaces. Confirm each team's spawner/worm kills still
  reach Sceatorio's per-team evolution accounting exactly once.
- The Portal labels the mod MIT, but its own credits identify CC-BY 3.0,
  CC-BY-NC 3.0, and AudioBlocks-origin sound assets. The archive must not be
  treated as uniformly MIT, and a fork/rehost is blocked until every embedded
  asset's redistribution terms and attribution are documented.
- No current discussion reports a multiplayer desync or performance failure,
  but the total download count is only 642 and the 2.1 archive is new. This is
  weak negative evidence, not proof of safety.

The exact Portal artifact can ultimately be enabled without losing client
auto-sync, but only after the following gate passes.

## AAI Signal Transmission 0.6.0

Primary sources: the [Portal record](https://mods.factorio.com/mod/aai-signal-transmission),
[downloads](https://mods.factorio.com/mod/aai-signal-transmission/downloads),
[changelog](https://mods.factorio.com/mod/aai-signal-transmission/changelog),
and official Mod Portal API metadata. Version 0.6.0 was published on
2026-06-24 specifically for Factorio 2.1. Its official archive SHA-1 is
`c6606a442a66d77eab8c8341a0e84a6c63b50197`.

The feature is a good circuit-level companion to Sceatorio's AI ports, but it
does not add a privileged software bridge. A factory can wire an AAI transmitter
to a Sceatorio AI Output Port, and a remote receiver can expose those signals on
another planet. In the other direction, a remote transmitter can feed a
receiver wired to a Sceatorio AI Input Port for `read_circuit_port`. Sceatorio's
write limit still applies at the originating port: at most 32 distinct signals,
one change per five seconds, and a 5--3600 second TTL. AAI can then combine
multiple transmitters and preserves red/green wire colors according to its
public contract.

That composition broadens the *downstream circuit effect* of an authorized AI
output beyond the surface containing the port. MCP surface grants still govern
which Sceatorio entity the gateway may address, but no Factorio circuit port can
prove where player-built wire networks or another mod will relay its output.
Likewise, `read_circuit_port` authenticates the local AI Input Port but cannot
prove which surface produced a signal relayed into it. This must be documented
as intentional transitive circuit behavior, not claimed as surface-confined
control or telemetry provenance.

The release is not approved yet:

- The Portal publishes no source. The exact authenticated ZIP has therefore not
  been reviewed for `storage`, event registration, commands, remote interfaces,
  deterministic iteration, retained LuaObjects, channel keying, or queue bounds.
- Public documentation says channels work without distance or surface limits,
  but it does not promise that equal channel names are isolated by force.
  Historical changelog entries fixed force-merge crashes, which suggests
  force-aware state, but that is not sufficient evidence against cross-team
  signal disclosure. Two Sceatorio forces must transmit the same red/green
  signal names on the same channel and prove complete isolation before approval.
- Since 0.4.8 the mod has connected its internal electric poles together to
  avoid the UPS cost of many electric networks. The implementation, helper
  surface, helper forces, and build events are unavailable for inspection.
  Sceatorio audits script-created team poles on non-platform surfaces and may
  disconnect cross-team copper. The combined test must prove that this neither
  breaks AAI nor creates an electrical path between Sceatorio teams.
- The public processing-frequency option can trade latency for UPS, but the
  current setting name, default, bounds, and algorithm cannot be authenticated
  without the ZIP. Benchmark 1/10/100 channels with 1/10/100 transmitters and
  receivers, 32 signals on both wire colors, powered/unpowered transitions,
  and receivers on every planet plus a platform.
- Exercise build, blueprint, clone, mine, destroy, force change/merge, surface
  deletion, add-to-save, reload, and removal. Recent fixes cover channel
  persistence after rebuild, low-power behavior across multiple electric
  networks, and space-platform initialization, but 0.6.0's published changelog
  only states the 2.1 update and does not add new lifecycle evidence.
- A Factorio 2.0.69 engine crash involved a legendary AAI transceiver combined
  with More Quality Scaling; Wube fixed the underlying engine issue for a later
  release. That optional mod is not requested and the server pins 2.1.12, so it
  is not a known current-set crash, but quality variants still belong in the
  exact artifact test.
- The license permits distribution only of the complete, unmodified package
  under stated attribution/link conditions and limits modifications to private
  personal use. Do not vendor source, publish a patched fork, or repackage
  extracted assets. Let clients obtain the exact Portal release.

## Combined interaction findings

- Source scans found no direct prototype-name collision among Aircraft,
  Nuclear Thruster, Sceatorio, AAI Containers, Cargo Ships, Oil Rig, and the
  Floating Electric Pole. The exact Portal ZIP closure still needs one combined
  test; source compatibility does not prove artifact compatibility.
- Aircraft's remote, collisionless combat vehicles and Mushroom Cloud's
  presentation/radiation effects widen Sceatorio's security requirements.
  Electricity isolation alone does not stop weapon, vehicle, scripted-damage,
  or logistic-request grief.
- Aircraft vehicle logistics are not covered by a static-network robot count.
  Keep vehicle request throughput visible in performance telemetry before
  treating a robot cap as a complete belt-first policy.
- Nuclear Thruster is space-platform-only through its inherited prototype and
  does not interact with terrestrial per-planet spawn allocation.
- AAI signals can intentionally cross planets and platforms, so they are useful
  for carrying AI-port telemetry and bounded output. They carry circuit values,
  not MCP credentials or operations, and do not relax Sceatorio's direct
  entity/force authorization. Their transitive downstream reach and force
  isolation remain unverified until the exact archive passes the two-force gate.
- The hardened Cargo Ships fork exists at
  [`Sceat/cargo_ships@27b52f3`](https://github.com/Sceat/cargo_ships/commit/27b52f3),
  but it remains outside the server lock until an upstream/Portal release can
  auto-sync to clients. These server-only candidates do not change that
  constraint.

### System-force regression

Aircraft and Nuclear Thruster provably create no forces.
Mushroom Cloud and AAI Signal Transmission remain unknown without source. An
earlier Sceatorio
regression auto-adopted every
non-reserved force from `on_force_created`, so a disposable `probe-system`
force also created `sceatorio-enemy-1`. That behavior is fixed: force creation
alone is ignored, while only Sceatorio's explicit create/register and narrowly
identified legacy-player migration paths can create team records and paired
enemies. Third-party system forces remain unknown even when their names resemble
Sceatorio's internal prefixes.

The static gate asserts that `Teams.on_force_created` cannot call the team
registration path. The real security fixture creates an internal-looking foreign
force, verifies that no enemy force appears, then explicitly registers two test
teams and verifies that only those teams receive paired enemies. This regression
is therefore green for the current release candidate; any future change to force
registration must preserve both tests rather than relying on a prefix allowlist.

## Real verification performed

All runs used isolated user data and never read the normal Factorio profile.
The executable was macOS arm64 Factorio 2.1.12 build 87038.

| Case | Result |
| --- | --- |
| Exact Aircraft Portal/GitHub ZIP, Base only, new save | Pass |
| Exact Aircraft ZIP, Space Age, new save + 600 ticks | Pass, 0.276 ms/update empty-save average |
| Nuclear Thruster commit `a6cdd9f`, Space Age + 600 ticks | Pass, 0.258 ms/update empty-save average |
| Same Nuclear source with Quality disabled | Pass |
| Aircraft + Nuclear source + current Sceatorio, Space Age + 600 ticks | Pass, 0.265 ms/update empty-save average |
| Same combined save through dedicated-server path | Pass, reached `Hosting game` and `CreatingGame -> InGame` |
| Add Aircraft + Nuclear source to an existing Sceatorio/Space Age save | Pass, 600 ticks at 0.278 ms/update |
| Place cargo plane and modified centrifuge | Pass |
| Remove both mods and reload that save | Pass; custom car removed, vanilla centrifuge retained |
| Add a standards-compliant 2.1 recipe named `rifle` beside Aircraft | Expected red; reproduced Aircraft `.normal` nil crash |
| Mushroom Cloud exact artifact | Blocked: authenticated Portal ZIP required |
| AAI Signal Transmission 0.6.0 metadata and SHA-1 | Pass: exact official Portal release metadata pinned |
| AAI Signal Transmission exact artifact/runtime | Blocked: authenticated Portal ZIP required |
| Complete AAI/Cargo/four-added-mod Portal ZIP set | Blocked: all exact compatible artifacts have not yet been staged together |

These averages only establish negligible idle Lua overhead. They are not active
vehicle, thruster, explosion, robot, graphics, or network benchmarks.

## Production gate and known blind spots

Before any blocked candidate is enabled, and before any mod update:

1. Download through a dedicated server secret, verify the exact lock SHA-1,
   and keep the token out of values files, logs, Pod arguments, and generated
   manifests. Never fall back to "latest" at container startup.
2. Run the complete pinned set on the actual Linux headless 2.1.12 image. The
   tests above used the same API/content version on macOS, not the production
   binary and container filesystem.
3. Create a save, reload it as a dedicated server, add/update/remove each mod,
   and verify populated inventories, fluids, quality variants, blueprints,
   ghosts, platform entities, research, and startup-setting changes. Wube's
   [migration documentation](https://lua-api.factorio.com/latest/auxiliary/migrations.html)
   explains why removed prototype references and ghosts need explicit checks.
4. Join with at least two real clients, disconnect/rejoin during activity, and
   compare desync reports. Reaching `Hosting game` does not exercise client mod
   sync, catch-up, per-player settings, rendering, or audio.
5. Benchmark idle and active cases for at least 36,000 ticks with repeated
   runs: 1/10/100 aircraft (moving, remote, firing, logistic requests),
   1/10/100 nuclear thrusters under load, and 1/10/50 simultaneous nuclear
   detonations on multiple surfaces, plus the AAI channel/transceiver/signal
   matrix above. Measure server update time, save size, entity/render counts,
   memory, network catch-up, and client FPS/audio.
6. Exercise two Sceatorio teams on every supported planet and a space platform.
   Validate kill attribution/evolution, offline protection, scripted radiation,
   foreign vehicle/build restrictions, robot accounting, surface deletion, and
   force merge. Repeat the synthetic third-party system-force test.
7. Diff all data-stage mutations after each mod update. Specifically assert
   centrifuge fluid boxes, Rocket Silo and Space Platform Thruster prerequisites,
   aircraft surface conditions/collision masks/cargo size, atomic projectile
   gameplay effects, and the absence of a `rifle`-recipe crash.
8. Keep tested ZIPs and save backups long enough to roll back. A clean load
   after removal can still delete custom entities and their contents.

Factorio 2.1.12 itself includes fixes for mod-sensitive crashes and desyncs,
including invalidated construction-robot orders and pollution override. Pinning
the exact engine is part of the compatibility result; silently downgrading the
server invalidates it.
