# Team evolution runtime fixture

This disposable test mod runs against Factorio 2.1.12 with two explicitly
registered Sceatorio teams and two real surfaces. It verifies the engine's
surface-specific evolution setter/getter, own-enemy worm and spawner kill
attribution, rejection of cross-team and default-enemy kills, independent
team/surface factors, and the disabled-vanilla policy. A controlled biter
spawner proves the engine's surface-global consumption statistics model: gross
stone-furnace input alone changes no ledger, while actual unit-spawner output
advances two existing teams by the same exact delta and leaves another surface
unchanged. A late team is not back-charged, disabled evolution advances its
cursor without a re-enable spike, a cleared counter rebaselines, and nest
consumption continues after a real save/reload. A post-reload kill also proves
the original ledger path.

The fixture deliberately does not claim connected-time deduplication. A
headless server can create disconnected `LuaPlayer` records, but only a real
connected client appears in `game.connected_players`; the two-teammate timing
case therefore remains a connected-client test.
