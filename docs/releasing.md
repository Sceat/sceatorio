# Release and Mod Portal operations

No script in this repository changes a version, commits, tags, pushes, or publishes on its own. A release begins with a reviewed source commit and an explicit `vX.Y.Z` tag.

## Release invariants

- The tag `vX.Y.Z`, `info.json` version, and first `changelog.txt` version must match.
- The tagged commit must be reachable from the repository's current default branch.
- The archive has exactly one root, `Sceatorio_X.Y.Z`, and contains only `scripts/release-manifest.json`'s allowlist.
- ZIP timestamps and modes are fixed; entries are stored rather than zlib-compressed so builds do not vary with zlib versions.
- CI publishes the exact downloaded workflow artifact to both GitHub Releases and the Factorio Mod Portal, alongside its SHA-256 file.
- The portal client verifies the release's public API SHA-1 after upload and is idempotent only when an existing version has identical bytes.

Verify a candidate locally:

```sh
sh tests/run.sh
python3 scripts/sync_docs.py --check
python3 scripts/validate.py

first=$(mktemp -d)
second=$(mktemp -d)
version=$(python3 -c 'import json; print(json.load(open("info.json"))["version"])')
python3 scripts/package.py --output "$first"
python3 scripts/package.py --output "$second"
cmp "$first/Sceatorio_${version}.zip" "$second/Sceatorio_${version}.zip"
```

Use version-derived paths in real release work rather than copying the example version literally.

## GitHub environment and secrets

Create a protected GitHub environment named `factorio-mod-portal`. Require reviewer approval for production if the repository plan supports it. Add one environment secret:

- `FACTORIO_MOD_PORTAL_API_KEY` — a Factorio API key scoped to both **ModPortal: Upload Mods** and **ModPortal: Edit Mods**.

Before publishing any bytes, the protected job fails without printing values if
the secret is empty. This prevents a missing Portal credential from being
discovered only after the new immutable Portal version is already live. Secret
presence does not prove that a key is current or correctly scoped; GitHub
environment review must verify both scopes before approving the job because the
Portal exposes no documented non-mutating credential-validation endpoint.

The tag workflow has read-only repository permission while testing/building. Only the gated publish job receives `contents: write` for the GitHub Release and the scoped Portal key. The workflow never uses a Factorio username/password or general account token. The workflow resolves the default branch from GitHub at run time (currently `master`) and rejects a tag whose commit is not reachable from `origin/<default-branch>`.

Repository-side protection remains external configuration: protect the default branch and release tag pattern, restrict tag creation, and require the protected environment's production approval. The workflow checks ancestry but deliberately does not require annotated or signed tags.

After the source commit is approved, an operator may create and push one tag:

```sh
version=$(python3 -c 'import json; print(json.load(open("info.json"))["version"])')
git tag -a "v${version}" -m "Sceatorio ${version}"
git push origin "v${version}"
```

This repository deliberately does not provide a command that performs those steps. Never retag a published version; increment the version.

The historical Mod Portal release `1.1.6` has no matching source tag in this repository. Do not fabricate or retroactively reconstruct one. The reproducible chain begins with the reviewed 2.x release process.

## GitHub Actions supply-chain pins

Workflow actions execute only immutable 40-character commit SHAs; the adjacent version comments are review aids, not executable references. On 2026-08-01, every comment tag in both workflows was checked against GitHub's public tag-ref API and resolved to its pinned commit. `scripts/validate.py` rejects a workflow action that is not pinned to a full SHA.

When updating an action, verify the upstream tag reference and review the complete old-to-new commit diff before changing the workflow SHA and its comment together. A Dependabot pull request is a prompt for that review, not proof that the update is trustworthy.

## Portal presentation

The Mod Portal payload is assembled from explicit single sources: mod name, title, and homepage come from `info.json`; the one-line summary comes from `portal/summary.txt` and must equal `info.json`'s in-game description; description and FAQ come from their files under `portal/`; and `portal/metadata.json` holds only Portal-specific category, tags, license, source URL, and canonical file pointers. Preview the API payload without credentials:

```sh
python3 scripts/update_portal_details.py
```

The protected tag workflow applies this presentation automatically after the exact ZIP has been published. It then polls the unauthenticated full-details API and fails unless the public title, summary, description, category, tags, license, homepage, source URL, and deprecation state match source control. The public details API does not expose FAQ text, so FAQ has the edit API's successful acknowledgement but no independent public readback.

For recovery, an operator can repeat only the same idempotent presentation operation with the same key, which must include **ModPortal: Edit Mods**:

```sh
FACTORIO_MOD_PORTAL_API_KEY=... \
  python3 scripts/update_portal_details.py --apply
```

The Mod Portal has no `multiplayer` tag; discoverability comes from the title/summary plus the valid Scenarios category and supported tags recorded in `portal/metadata.json`.

Gallery images remain a manual visual gate. Follow `portal/gallery-capture.md`, inspect every real screenshot for stale UI and private server data, then upload/order them with the same scoped credential or the portal UI. Never upload the generated thumbnail as gameplay evidence.

## Pinned real Factorio tests in CI

Fast unit/static tests and the MCP suite run on GitHub-hosted runners. Wube provides the Linux dedicated headless package free; CI downloads the exact Factorio version URL and verifies the filename and SHA-256 stored once in `tests/headless/matrix.json`. It never follows a `latest` alias and does not redistribute the archive. The same pinned real-engine matrix gates tagged publication. Outside CI, maintainers can point the isolated harness at any exact 2.1.12 executable.

The repository now includes the real Factorio Lua Uplink/gateway, one-time pairing, the local stdio companion, and an injectable HTTP handler factory. It does not include a production authenticated HTTP service, authorization server, container image, or public distribution channel. There is therefore no MCP Containerfile, GHCR publication, or enabled Helm sidecar yet; those artifacts wait on the HTTP/OAuth and container-deployment gate, not on missing Lua gameplay integration.

The automated [MCP end-to-end release gate](mcp-e2e-release-gate.md) passes against the real Factorio 2.1.12 `--enable-lua-udp` process and an independent stdio MCP client, including all operation paths plus critical pairing/scope/revocation failures. Its documented manual player/Space Age cases remain required before a broader player-host claim. A public image or endpoint additionally requires the separate HTTP/OAuth, TLS, redaction, revocation, and container-distribution evidence listed there. No API key is needed for the local protocol test; optional Claude Code registration is host evidence, not a substitute for the independent client.
