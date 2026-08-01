# Robot production policy fixture

This dependent test mod creates two disconnected fixed logistic networks whose
individual robot counts are below the force-wide cap, plus crafting machines
with both possible prior `disabled_by_script` states. It verifies on Factorio
2.1.12 that enforcement pauses only matching robot production, never removes a
robot item, preserves recipe contents/progress/quality, and restores an explicit
false state through a paused clone.

Run it in an isolated data directory with:

```sh
tests/headless/run.sh mod-fixture base robot-policy
```
