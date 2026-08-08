# Frequently asked questions

## How do separate human teams relate?

Sceatorio is designed for friendly parallel factories with separate forces, bases, economies, evolution, and power. It does not rewrite human-force diplomacy or add a custom ownership layer; ordinary Factorio force access rules remain authoritative.

## What exactly happens when a team goes offline?

Offline protection activates immediately when the last human leaves a team: tracked team-owned entities become unbreakable, then the first teammate back restores each exact prior destructible state. There is no grace timer.

Normal save/load is supported, but offline entity registration targets fresh 2.0 worlds; installing it onto an existing untracked world has no retrofit guarantee.

## Do separate teams share the explored map?

Yes. Every 10 seconds, Sceatorio shares the already-generated chunks near connected team characters and team-owned radars with all registered human teams, without merging forces, economies, evolution, or electric networks. It uses the original scenario's compact 70-tile player and 112-tile radar footprints. Lobby, enemy, and system forces are excluded. It never scans an entire surface, reacts to its own chart writes, or asks Factorio to generate a chunk merely to reveal it.

## Can teams share power intentionally?

Yes, when the sharing policy permits it. Both team owners (or an administrator acting for a team) must opt in with `/sceatorio-power-share <team-id> on`. Either side can revoke its intent. Revoking mutual power sharing immediately makes direct cross-team copper unauthorized and prevents new player/robot implicit overlaps, but an implicit overlap accepted while sharing was active must be relocated manually. Script-raised builds are checked after their creator resumes, and a bounded next-tick audit catches silent companion poles around visible electric builds. An unrelated entity created by another mod without raising any Factorio lifecycle event remains an operator-audited trust boundary.

## How do the robot limits work?

The policy aggregates a team's robots across every fixed logistic network and surface, so splitting networks cannot evade the cap. It can be disabled, warning-only, or enforced. Enforcement pauses only registered crafting machines while their current recipe produces a robot class that is at its cap, then restores each machine's prior script-disabled state when the class falls below the cap. Existing, flying, stored, and imported robot items are never moved, deleted, or hidden. Use `/sceatorio-robot-status` to inspect counts and paused machines.

## Does Space Age work?

Space Age is an optional dependency. A team's first physical arrival on each real planet starts bounded asynchronous generation of one stable, separated spawn. Space platforms and remote-view surfaces are excluded. Native resources, tiles, cliffs, and planet progression are preserved.

Vulcanus has no territory-free distant starting region: beyond the shared center, its map is divided among demolishers. Sceatorio therefore uses Oarc's exact temporary workaround instead of rejecting every territory forever. Segmented demolisher entities are tracked as Factorio creates them, one is checked per tick, and it is destroyed only after moving within six chunks (192 tiles) of the nearest team spawn. That grants the territory for free and can leave a larger-than-normal starting territory; distant teams may also encounter medium or big demolishers because the mod does not downgrade them.

## Is AI Assistance available in-game?

Yes, but it is optional and off by default. The server administrator must enable it, the force must research the single red-science **AI Assistance** technology and power an AI Uplink, and a player must create a short-lived, one-time pairing code at that Uplink, which is that player's own explicit opt-in. The local stdio companion is built separately from this GitHub source—it is not embedded in the Mod Portal ZIP—and exposes 29 low-level, scope-checked MCP tools for telemetry, structured blueprints, dedicated circuit ports, events, and private annotations.

The human remains the character: there is no movement, mining, crafting, combat, teleportation, entity placement, arbitrary Lua, or RCON tool. Start Factorio with a loopback-only `--enable-lua-udp=<port>` and keep the sidecar on the same trusted host. A pairing code crosses that loopback channel once; bearer credentials do not. Revoke bindings from the Uplink whenever access is no longer wanted. A public HTTPS/OAuth endpoint is deliberately not included.

## Why is there no “Multiplayer” tag?

The Factorio Mod Portal does not define a Multiplayer tag. Sceatorio uses the Scenarios category, supported gameplay tags, and “multiplayer” in its title and summary so it remains discoverable without inventing metadata.

## Can joining clients download the server mod set automatically?

Factorio can synchronize releases published on the Mod Portal. A ZIP installed only on the server is not transferred to clients. Any patched third-party fork therefore needs its own compatible Mod Portal identity and release before a public server can depend on it.

## Can I install 2.0 onto an older world?

Start a fresh 2.0 world. Normal saves created with this line can be saved, loaded, and restarted, but offline protection deliberately avoids a disruptive retrofit scan of arbitrary existing worlds. A complete 1.1-to-2.1 multiplayer save migration is not a supported release path.
