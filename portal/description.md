# Build together without sharing one starting patch

Sceatorio is a friendly multiplayer scenario mode for groups that want the same persistent world and conversation without forcing everyone into one base or economy.

- Create a separate team and distant starting area, or request an owner-approved join to a friend.
- Enemy evolution is tracked per team and per surface from connected time, own worm/spawner kills, and new pollution consumed by nests on that surface.
- Every team's nests treat every player as an enemy, so no base is safe inside a rival team's nest field, while the nests themselves never fight each other.
- With Space Age enabled, each team receives one stable separated spawn after physically reaching a new planet; platforms and remote view are excluded.
- Electric networks are isolated by default; deliberate sharing requires both team owners to opt in.
- Connected players and team radars share their nearby, already-generated map discovery with every registered human team, without merging forces, economies, evolution, or electric networks.
- The compact top-left player panel shows exact online/offline totals and every friend's cumulative playtime without growing indefinitely; each section has simple pages when needed.
- Configurable per-team robot limits aggregate all fixed networks and surfaces; enforcement pauses only crafting machines currently producing the capped robot class, and never moves, deletes, or hides robot items.
- Optional AI Assistance is off by default and uses one automation-science technology, a powered Uplink, one-time pairing codes a player creates as their own explicit opt-in, and 29 scoped MCP tools.

Evolution, offline protection, electricity, planet spawns, and robot policy are configurable through runtime map settings. Construction robots have a deliberately roomier policy than logistic robots, but server operators choose the actual limits.

Factorio exposes cumulative pollution flow statistics per surface rather than per force. Pollution evolution follows surface-global nest consumption rather than gross factory emissions: Sceatorio counts only output attributed to unit-spawner prototypes. Every team recorded there receives the same newly consumed delta; no proximity or triangulation is used. Trees and scrubbers can intercept pollution before nests and reduce future evolution, but evolution already credited never decreases.

## Offline protection and compatibility

Offline protection activates immediately when the last human leaves a team: tracked team-owned entities become unbreakable, then the first teammate back restores each exact prior destructible state.

Normal save/load is supported, but offline entity registration targets fresh 2.0 worlds; installing it onto an existing untracked world has no retrofit guarantee.

Direct links and conflicting visible builds are rejected. A bounded next-tick audit catches silent companion poles around visible electric builds; unrelated entities created without any Factorio lifecycle event remain a trusted-mod boundary.

No MCP tool controls the character or places entities, and bearer credentials never enter Factorio UDP or the save; the local bridge requires Factorio's loopback Lua UDP flag. Its TypeScript stdio companion is built separately from the GitHub source and is not embedded in the Mod Portal ZIP. The tested AI path is local stdio over loopback UDP; this mod does not expose a public AI or Factorio endpoint.

The AI Assistance icon's stylized starburst intentionally references Claude's visual mark. Claude and Anthropic are trademarks of Anthropic, PBC. Sceatorio is an unofficial, independently maintained project and is not affiliated with or endorsed by Anthropic; Claude is one compatible MCP host, while the protocol and in-game identifiers remain vendor-neutral.

## Compatibility

This development line requires Factorio 2.1.12. Space Age is optional. The base game works without the expansion; planet spawn behavior activates only on real planet surfaces.

Sceatorio is inspired by [Oarc's Multiplayer Spawn](https://github.com/Oarcinae/FactorioScenarioMultiplayerSpawn) and is independently maintained as an open-source MIT project.
