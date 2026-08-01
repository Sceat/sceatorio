# Space Age planet fixture

This dependent test mod uses the development-gated reservation API without
players. It creates every built-in planet surface, registers two explicit team
forces, verifies stable separated spawns and native tile/resource/cliff/
decorative preservation, rejects a real platform surface, saves, then verifies
the same records after a process restart. Gleba is pre-generated before the
reservation and contains both a default hostile and another team's paired
hostile: finalization must assign only the default hostile to the nearest paired
enemy force.

Rider and cargo-pod event semantics still require the default-off administrator
test menu or a real client; this fixture covers the headless core state machine.
