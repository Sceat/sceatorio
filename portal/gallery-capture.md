# Mod Portal gallery capture plan

Only real Factorio screenshots belong in the gallery. The generated thumbnail is branding, not gameplay evidence.

## Legacy gallery audit

The three images currently on the Mod Portal should be treated as legacy until replacements are captured:

| Existing image | Audit | Replacement target |
| --- | --- | --- |
| 1915×1080 sandy map view | Large empty area, old interface, and no clear multiplayer story. | Two real clients, four colored team spawn markers, readable map scale, no private server data. |
| 660×534 join dialog | Small and dated; grammar and team flow no longer match the validated-token interface. | Current create-team and request-to-join flow at 1920×1080. |
| 356×298 evolution list | Too small for a portal gallery and does not prove surface isolation. | Current player/evolution view with two teams and a named planet/surface visible. |

Do not remove the legacy images until all replacements pass the checklist below; a temporarily incomplete gallery is worse than clearly old but truthful evidence.

## Reproducible capture setup

1. Use the exact Factorio and mod versions in `info.json`, with default runtime settings unless a caption explicitly says otherwise.
2. Start a dedicated test server and join with at least two real clients on different teams. Use neutral test names; hide the server address, account names, RCON output, and tokens.
3. Capture PNG at 1920×1080, 100% UI scale, default sprite resolution, English locale, and no editor/debug overlays.
4. Keep each shot focused on one behavior. Do not composite, paint over, or use generated scenery.
5. Record the save seed, scenario settings, Factorio build, mod versions, and caption in a gallery release note before upload.

## Eight-shot target set

1. Create-team screen plus a second client's owner-approved join request.
2. Map view showing several genuinely separated Nauvis spawns and the same bounded connected-player/radar discovery on two registered human teams.
3. Two team evolution displays proving different values on the same surface.
4. A rejected/refunded cross-team electric placement with both networks visible.
5. First physical Space Age planet arrival followed by the team's stable spawn notification.
6. Robot policy status showing team-wide logistic and construction counts, caps, and policy-paused crafting machines.
7. AI Assistance Uplink showing explicit per-player opt-in and a freshly generated pairing code, with no private endpoint or reusable credential visible.
8. A representative mid-game view of friendly parallel factories with separate economies.

Upload and order these manually through the Mod Portal image UI after review. Gallery mutation is intentionally not part of a tag release: images need human visual inspection, captions, and confirmation that no private server information appears.
