# Sceatorio — Separate Multiplayer Spawns

[![CI](https://github.com/Sceat/sceatorio/actions/workflows/ci.yml/badge.svg)](https://github.com/Sceat/sceatorio/actions/workflows/ci.yml)

Sceatorio is a friendly Factorio multiplayer scenario mod for people who want one persistent world without sharing one starting patch or economy. Players create separate forces and distant spawns, or join a friend's team through an owner-approved request.

> The 2.x release line targets Factorio 2.1.12. It is not the older 1.1 Mod Portal release. Space Age 2.1.12 is supported as an optional dependency.

## What is implemented

- Stable team records, validated team joining, separate forces, and distant Nauvis starting areas.
- Per-team, per-surface enemy evolution driven by connected time, that team's own worm/spawner kills, and new pollution actually consumed by unit spawners on the surface.
- One stable separated spawn after a team's first physical arrival on each real Space Age planet; platforms and remote view are excluded.
- Electricity isolation with bounded background auditing, exact player refunds, and mutual owner opt-in for deliberate sharing.
- Global radar/chart discovery shared among all Sceatorio human teams without merging their forces, economies, evolution, or electric networks. Chunk updates are deduplicated behind a fixed queue; an exceptional overflow is announced and reconciled from the saved force charts in bounded background passes.
- Configurable per-team robot policy that aggregates all fixed networks/surfaces and favors belts with default caps of 500 logistic and 5,000 construction robots. Enforcement pauses only crafting machines currently producing the capped robot class; it never moves, deletes, or hides robot items.
- Optional, default-off AI Assistance through one automation-science technology, a powered Uplink, per-player opt-in, one-time pairing/revocation, and 24 scope-checked MCP tools.
- Shared chat/research notices, death messages, and a compact top-left player list with accurate online/offline counts and independently paged access to every player's total playtime.

The generated [feature contract](docs/features.md) is the concise source of truth for shipped behavior and limitations. Runtime setting names, defaults, ranges, and descriptions are generated from the Lua prototypes and locale in [settings.md](docs/settings.md).

Factorio exposes cumulative pollution flow statistics per surface rather than per force. Sceatorio samples only output keys whose runtime entity prototype is a unit spawner, matching vanilla's nest-consumption boundary instead of charging gross factory emissions. Every team recorded on the surface receives the same newly consumed delta; no proximity or triangulation is used. Trees and scrubbers can reduce future evolution by intercepting pollution before it reaches a nest, while evolution already credited never decreases.

## Offline protection and world lifecycle

When the last human leaves a team, tracked team-owned entities immediately become unbreakable. The first teammate back immediately restores every exact prior `destructible` state. There is no grace timer.

Normal save/load and server restarts are supported for worlds created with the 2.0 line. Offline entity registration is event-driven and deliberately performs no retrofit world scan, so installing 2.0 onto an existing untracked world has no offline-protection guarantee. Start a fresh 2.0 world.

Human teams are friendly parallel forces; Sceatorio does not mutate their diplomacy or add a custom item/entity ownership layer. Factorio's normal force access remains authoritative. Direct links and conflicting visible builds are rejected; a bounded next-tick audit also catches unannounced companion poles created around a visible electric build. Factorio exposes no general event for unrelated entities created silently by another mod, so those mods remain an operator-audited trust boundary.

## Install

Install `Sceatorio` from Factorio's Mod Portal UI and use Factorio 2.1.12. Space Age may be enabled or omitted.

For a local development install, build and copy the exact ZIP without modifying `info.json` or deleting other mod versions:

```sh
scripts/install-local.sh "/absolute/path/to/Factorio/mods"
```

The script refuses to overwrite the same version unless `--replace` is supplied. It never removes a wildcard of old releases.

## Operator commands

- `/sceatorio-power-share <team-id> on|off|status` — team owner/admin intent; power sharing becomes active only when both teams opt in and the global policy permits it. Revocation removes/audits direct links and blocks new implicit overlaps, but a previously accepted implicit overlap must be relocated manually.
- `/sceatorio-robot-status [force-index]` — show network totals, caps, registered robot-producing machines, and how many are policy-paused. Only admins can query another force.
- `/equalize_all` — admin/RCON cleanup of enemy structures assigned outside their team territory.
- `/eradicate <player>` — admin/RCON removal of a player and, when they are the team's final member, that team's entities and spawn chunks. Back up first; this is intentionally destructive.

Other mods that intentionally reveal one chunk for a registered Sceatorio team
should call `remote.call("sceatorio_radars", "share_chunk", force_name,
surface_name_or_index, {x = chunk_x, y = chunk_y})`. The wrapper accepts only
one bounded integer chunk and routes it through shared discovery; direct
`LuaForce.chart` calls do not raise `on_chunk_charted` in Factorio 2.1.12.

## AI/MCP status

The tagged open-source release includes both the fail-closed Lua gateway and TypeScript [MCP companion](mcp/README.md), with exact Codex setup commands and a versioned [security architecture](docs/claude-mcp-architecture-v1.md). The Mod Portal ZIP remains Factorio-only; it does not make every joining player download Node.js source or dependencies. The real Factorio 2.1.12 end-to-end test covers one-time pairing, all 24 operation paths, stdio MCP initialization/list/call, scope rejection, replay, expiry, shared per-player quota, and revocation.

The human remains the character. No tool moves, mines, crafts, fights, teleports, places entities, runs arbitrary Lua/RCON, or changes generic factory state. The tested release path is local stdio over loopback UDP; an internet-facing Streamable HTTP/OAuth endpoint is not shipped by this repository. See the [end-to-end gate](docs/mcp-e2e-release-gate.md) for the exact evidence and remaining production boundary.

The AI Assistance icon's stylized starburst intentionally references Claude's visual mark. Claude and Anthropic are trademarks of Anthropic, PBC. Sceatorio is an unofficial, independently maintained project and is not affiliated with or endorsed by Anthropic; Claude is one compatible MCP host, while the protocol and in-game identifiers remain vendor-neutral.

## Dedicated server

The convention-aligned Helmfile release lives in the separate [`Sceat/kubernetes` repository](https://github.com/Sceat/kubernetes/tree/master/domains/sceatorio). It is release-gated and disabled until this mod exists on the Mod Portal, the audited third-party lock is complete, and operator secrets are provisioned through that repository's encrypted secret workflow. No credentials belong here.

Factorio can synchronize joining clients only to releases published on the Mod Portal. A server-local patched ZIP is not transferred to clients; a necessary fork must use its own compatible portal identity and release.

## Development and tests

The fast source checks run on every pull request and push:

```sh
sh tests/run.sh
python3 scripts/sync_docs.py --check
python3 scripts/validate.py
python3 scripts/package.py --output dist
cd mcp && npm ci && npm run check
```

CI also downloads Wube's free Linux headless package from the exact version URL and verifies the SHA-256 pinned in `tests/headless/matrix.json`; it never follows a `latest` alias. It runs the base/Space Age loads, multiplayer startup, security/evolution/offline/robot/planet fixtures, and the AI gateway E2E before release publication.

To reproduce that engine matrix outside CI, provide any exact Factorio 2.1.12 executable—either a normal installation or Wube's free Linux headless package—and run:

```sh
sh tests/headless/ci.sh
```

The harness never reads the normal Factorio user-data directory. See [headless testing](tests/headless/README.md) for benchmarks and audited external-mod staging.

## Project docs

Start with the [documentation index](docs/README.md). Release provenance and portal operations are documented in [releasing.md](docs/releasing.md). Contributions and security reports are covered by [CONTRIBUTING.md](CONTRIBUTING.md) and [SECURITY.md](SECURITY.md).

Sceatorio was inspired by [Oarcinae's Factorio Scenario Multiplayer Spawn](https://github.com/Oarcinae/FactorioScenarioMultiplayerSpawn). See [THIRD_PARTY.md](THIRD_PARTY.md) for lineage and dependency notices. Sceatorio itself is available under the [MIT License](LICENSE).
