# Third-party lineage and notices

Sceatorio's separate-spawn concept was inspired by [Oarcinae's Factorio Scenario Multiplayer Spawn](https://github.com/Oarcinae/FactorioScenarioMultiplayerSpawn), audited during the 2.1 port at upstream commit `ba6cc666ea01658ec2fb096b3e48b887a5419213` (2.1.25). That project is MIT-licensed, copyright Oarcinae. Sceatorio maintains its own runtime/state model and credits the design lineage rather than hiding it.

The `mcp/` development package resolves the official Model Context Protocol TypeScript SDK and Zod through `package-lock.json`; they are not vendored into the Factorio mod archive. Their upstream notices and licenses remain authoritative in the installed npm packages.

The dedicated server's optional third-party Factorio mods are downloaded as exact, separately licensed Mod Portal archives by the infrastructure release. They are not redistributed in this repository or inside the Sceatorio ZIP. Consult the audited lock/matrix and each upstream project before modifying or republishing one; some requested mods prohibit modified redistribution even when source is visible.

The selected thumbnail is trained-algorithmic media generated for this project. Exact prompts, C2PA/source information, transformation, and hashes are recorded in `portal/assets/manifest.json`. It does not depict actual gameplay.

The selected AI Assistance icon's stylized starburst intentionally references Claude's visual mark. Claude and Anthropic are trademarks of Anthropic, PBC; Sceatorio is unofficial, independently maintained, and not affiliated with or endorsed by Anthropic. The integration's protocol identity and gameplay technology remain vendor-neutral. Sceatorio's original surrounding artwork is distributed under this repository's MIT License, which does not grant rights in third-party trademarks.
