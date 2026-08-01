# Security policy

## Supported lines

| Line | Status |
| --- | --- |
| `master` / 2.x | Security fixes accepted; targets Factorio 2.1.12. |
| Mod Portal 1.1 releases | Legacy and unsupported. |

## Reporting a vulnerability

Use GitHub's private vulnerability reporting for this repository when the **Security → Report a vulnerability** option is available. Include the affected version, server/client context, reproduction steps, impact across forces or saves, and the smallest practical proof of concept.

If private reporting is unavailable, open a public issue containing only a request for a private maintainer contact. Do not include an exploit, live server address, credential, private save, player identity, or portal token in a public issue.

Please allow maintainers time to reproduce and coordinate a release before public disclosure. No specific response or remediation deadline is promised by this volunteer project.

## Relevant threat boundary

Reports are especially useful when they demonstrate cross-force information disclosure, permission bypass, unauthorized team joins, save corruption, deterministic multiplayer desync, unbounded work that can exhaust server resources, electricity isolation bypass, or MCP authorization/scope bypass.

The following are documented product limitations rather than vulnerabilities by themselves:

- Human Sceatorio teams are friendly parallel forces. The mod does not rewrite their diplomacy or replace Factorio's native force access rules.
- Offline protection is guaranteed for event-registered team entities in fresh 2.0 worlds. Installing it onto an existing untracked world is unsupported; no retrofit entity scan runs.
- Server operators and same-host processes are trusted. RCON, Factorio account tokens, and local MCP access-grant credentials must remain outside the mod and save. A public OAuth service is not shipped; any future deployment must keep its OAuth credentials outside Factorio as well.
- Sceatorio rejects script-raised conflicts and performs a bounded next-tick audit for silent companion poles around visible electric builds. Factorio exposes no general event for unrelated entities that another mod creates without raising a lifecycle event; installing such a mod is an operator trust decision and its exact release must be audited.

A way to turn one of these limitations into a cross-force escalation, remote crash, desync, secret exposure, or persistent save compromise is still worth reporting privately.
