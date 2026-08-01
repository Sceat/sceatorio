# Documentation

- [Feature contract](features.md) — generated public behavior and explicit limitations.
- [Runtime settings](settings.md) — generated names, defaults, ranges, and English descriptions.
- [Headless tests](../tests/headless/README.md) — isolated Factorio 2.1.12 smoke, server, external-mod, and benchmark runs.
- [Headless audit](../tests/headless/AUDIT.md) — API, Space Age, robot performance, Oarc, and external-mod findings.
- [Added-mod compatibility audit](third-party/added-mods-compatibility-audit.md) and [2.1.12 lock](third-party/added-mods-2.1.12.lock.json) — source/runtime risks and exact candidate versions for the expanded server set.
- [Release and Mod Portal operations](releasing.md) — deterministic artifacts, required environments/secrets, and manual gallery gate.
- [AI/MCP architecture](claude-mcp-architecture-v1.md) — v1 security and deployment boundary; Claude is one compatible client.
- [Factorio gateway protocol](claude-mcp-protocol-v1.md) — implemented versioned pairing/transport/tool contract.
- [MCP end-to-end release gate](mcp-e2e-release-gate.md) — real Factorio 2.1.12 Lua/stdio evidence and the separate public-deployment boundary.
- [MCP companion](../mcp/README.md) — build, one-time pairing, local stdio configuration, and SSOT links.
- [Mod Portal source copy](../portal/description.md) and [gallery plan](../portal/gallery-capture.md).

Generated documents identify their source at the top. Change that source and run `python3 scripts/sync_docs.py --write`; CI rejects hand-edited drift.
