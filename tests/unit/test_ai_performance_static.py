import pathlib
import unittest


ROOT = pathlib.Path(__file__).resolve().parents[2]


class AiPerformanceStaticTests(unittest.TestCase):
    def test_disabled_entity_events_do_no_ai_bookkeeping(self):
        gateway = (ROOT / "src/game/aiGateway.lua").read_text(encoding="utf-8")
        built = gateway[
            gateway.index("function Gateway.on_entity_built") :
            gateway.index("function Gateway.on_entity_removed")
        ]
        removed = gateway[
            gateway.index("function Gateway.on_entity_removed") :
            gateway.index("function Gateway.on_player_changed_force")
        ]
        gate = 'if not global_value("sceatorio-ai-enabled", false) then return end'
        self.assertIn(gate, built)
        self.assertLess(built.index(gate), built.index("AiEvents.record"))
        self.assertNotIn("Telemetry.index_entity", built)
        self.assertIn(gate, removed)
        self.assertLess(removed.index(gate), removed.index("pending_pairings"))
        self.assertLess(removed.index(gate), removed.index("root().bindings"))

    def test_entity_reference_cache_is_a_migrating_constant_time_ring(self):
        telemetry = (ROOT / "src/game/aiTelemetry.lua").read_text(encoding="utf-8")
        self.assertIn("local MAX_ENTITY_REFS = 2000", telemetry)
        self.assertIn("ENTITY_REF_SCHEMA_VERSION", telemetry)
        self.assertIn("migrate_entity_refs", telemetry)
        self.assertIn("refs.slots", telemetry)
        self.assertIn("refs.head", telemetry)
        self.assertIn("refs.tail", telemetry)
        self.assertIn("refs.count", telemetry)
        self.assertNotIn("table.remove(refs.order, 1)", telemetry)
        self.assertIn("game.get_entity_by_unit_number(unit_number)", telemetry)
        removed = telemetry[
            telemetry.index("function Telemetry.on_entity_removed") :
            telemetry.index("local function resolve_entity")
        ]
        self.assertNotIn("entity_ref_root()", removed)

    def test_event_waits_are_expensive_and_round_robin_bounded(self):
        gateway = (ROOT / "src/game/aiGateway.lua").read_text(encoding="utf-8")
        operations = (ROOT / "src/game/aiOperations.lua").read_text(encoding="utf-8")
        self.assertIn('["event.wait"] = true', operations)
        self.assertIn("local MAX_WAITS_PER_SLICE", gateway)
        self.assertIn("pending_event_wait_queue", gateway)
        self.assertIn("enqueue_event_wait", gateway)
        self.assertIn("dequeue_event_wait", gateway)
        process = gateway[
            gateway.index("local function process_event_waits") :
            gateway.index("local function cancel_event_waits")
        ]
        self.assertIn("for _ = 1, MAX_WAITS_PER_SLICE do", process)
        self.assertIn("AiEvents.has_new_events", process)
        self.assertNotIn("for id, pending in pairs(pending_event_waits)", process)

    def test_save_global_quota_is_atomic_with_player_quotas(self):
        settings = (ROOT / "settings.lua").read_text(encoding="utf-8")
        gateway = (ROOT / "src/game/aiGateway.lua").read_text(encoding="utf-8")
        operations = (ROOT / "src/game/aiOperations.lua").read_text(encoding="utf-8")
        self.assertIn('name = "sceatorio-ai-global-requests-per-minute"', settings)
        self.assertIn('name = "sceatorio-ai-global-expensive-requests-per-minute"', settings)
        consume = gateway[
            gateway.index("local function consume_quota") :
            gateway.index("local function authorize")
        ]
        self.assertIn("ai.global_quota", consume)
        self.assertIn('"GLOBAL_RATE_LIMITED"', consume)
        self.assertIn('"GLOBAL_EXPENSIVE_RATE_LIMITED"', consume)
        self.assertLess(consume.index("if quota.requests >= request_limit"), consume.index("quota.requests = quota.requests + 1"))
        self.assertLess(consume.index("if global_quota.requests >= global_limit"), consume.index("quota.requests = quota.requests + 1"))
        self.assertLess(consume.index("if expensive and global_quota.expensive >= global_expensive_limit"), consume.index("quota.requests = quota.requests + 1"))
        self.assertIn("globalExpensiveRequestsPerMinute", operations)
        self.assertIn("globalExpensiveRequestsRemaining", operations)

    def test_blueprint_inbox_is_canonicalized_and_byte_bounded(self):
        blueprints = (ROOT / "src/game/aiBlueprints.lua").read_text(encoding="utf-8")
        self.assertIn("local MAX_BLUEPRINT_BYTES_PER_PLAYER = 512 * 1024", blueprints)
        # Version 4 added the books collection; the bump is what makes an
        # existing 2.4.0 inbox run migrate_inbox exactly once on first access.
        self.assertIn("local BLUEPRINT_INBOX_SCHEMA_VERSION = 4", blueprints)
        # Migration must never delete a record that was legal when it was saved,
        # so the persistence ceiling stays above the tightened authoring bound.
        self.assertIn("local MAX_STORED_ENTITIES = 512", blueprints)
        self.assertIn("#canonical.entities > MAX_STORED_ENTITIES", blueprints)
        self.assertIn("local function canonical_layout", blueprints)
        self.assertIn("local function migrate_inbox", blueprints)
        self.assertIn("local function evict_oldest_until_fit", blueprints)
        self.assertIn("bytes = 0", blueprints)
        self.assertIn("helpers.table_to_json(canonical)", blueprints)
        save = blueprints[
            blueprints.index("function Blueprints.save") :
            blueprints.index("function Blueprints.list")
        ]
        self.assertIn("local canonical = canonical_layout(layout)", save)
        self.assertIn("layout_bytes > MAX_BLUEPRINT_BYTES_PER_PLAYER", save)
        self.assertIn('"BLUEPRINT_TOO_LARGE"', save)
        self.assertIn("evict_oldest_until_fit(inbox, layout_bytes)", save)
        self.assertIn("evictedBlueprintIds", save)
        self.assertIn("layout = canonical", save)
        self.assertNotIn("layout = clone_plain(layout, 0)", save)
        self.assertNotIn("#inbox.order >= MAX_BLUEPRINTS_PER_PLAYER then\n    return", save)

    def test_blueprint_books_are_reference_only_and_separately_bounded(self):
        blueprints = (ROOT / "src/game/aiBlueprints.lua").read_text(encoding="utf-8")
        # A book carries no layout, so it pays into neither the record count nor
        # the byte budget -- charging it there would let a grouping evict the
        # blueprints it points at. Its own two caps are the whole bound.
        self.assertIn("local MAX_BOOKS_PER_PLAYER = 20", blueprints)
        self.assertIn("local MAX_BOOK_MEMBERS = 50", blueprints)
        create = blueprints[
            blueprints.index("function Blueprints.create_book") :
            blueprints.index("function Blueprints.load_book")
        ]
        self.assertNotIn("MAX_BLUEPRINT_BYTES_PER_PLAYER", create)
        self.assertNotIn("MAX_BLUEPRINTS_PER_PLAYER", create)
        self.assertNotIn("inbox.bytes", create)
        self.assertNotIn("evict_oldest_until_fit", create)
        self.assertNotIn("layout", create)
        # A full shelf is an error the assistant can act on, never a silent
        # eviction of a grouping the player curated.
        self.assertIn("#inbox.book_order >= MAX_BOOKS_PER_PLAYER", create)
        self.assertIn('"BLUEPRINT_BOOK_LIMIT_REACHED"', create)
        # Migration bounds whatever it finds, and rebuilds books only against
        # the records that survived, so no reference can dangle.
        migrate = blueprints[
            blueprints.index("local function migrate_inbox") :
            blueprints.index("local function player_inbox")
        ]
        self.assertLess(migrate.index("while (#order - first + 1)"), migrate.index("canonical_book("))
        self.assertIn("canonical_book(id, type(inbox.books) == \"table\"", migrate)
        self.assertIn("(#book_order - first_book + 1) > MAX_BOOKS_PER_PLAYER", migrate)
        self.assertIn("inbox.books = books", migrate)
        self.assertIn("inbox.book_order = book_order", migrate)
        # An inbox written before books existed keeps every blueprint it had.
        self.assertIn('type(inbox.book_order) == "table" and inbox.book_order or {}', migrate)
        # Both paths that unmake a record drop the references to it.
        for owner in ("function Blueprints.delete", "local function evict_oldest_until_fit"):
            body = blueprints[blueprints.index(owner):]
            self.assertIn("forget_member(inbox, ", body[: body.index("\nend\n")])

    def test_global_enumerations_are_expensive_and_candidate_bounded(self):
        operations = (ROOT / "src/game/aiOperations.lua").read_text(encoding="utf-8")
        telemetry = (ROOT / "src/game/aiTelemetry.lua").read_text(encoding="utf-8")
        for operation in (
            "alert.list",
            "research.get",
            "research.unlocked-technologies",
            "statistics.production",
        ):
            self.assertIn(f'["{operation}"] = true', operations)
        trains = telemetry[
            telemetry.index("function Telemetry.trains") :
            telemetry.index("function Telemetry.alerts")
        ]
        alerts = telemetry[
            telemetry.index("function Telemetry.alerts") :
            telemetry.index("local function chunk_area")
        ]
        self.assertIn("examined >= MAX_SCAN_RESULTS", trains)
        self.assertIn("truncated", trains)
        self.assertIn("native_filter.surface = context.surface", alerts)
        self.assertIn("get_alerts(native_filter)", alerts)
        self.assertIn("#rows >= MAX_SCAN_RESULTS", alerts)
        self.assertIn("truncated", alerts)

    def test_udp_operations_are_processed_through_a_bounded_persisted_fifo(self):
        gateway = (ROOT / "src/game/aiGateway.lua").read_text(encoding="utf-8")
        self.assertIn("local MAX_INGRESS_PACKETS = 64", gateway)
        self.assertIn("local MAX_INGRESS_PACKETS_PER_TICK = 4", gateway)
        self.assertIn("ai.ingress = ai.ingress or", gateway)
        self.assertIn("local function enqueue_ingress", gateway)
        self.assertIn("local function process_ingress", gateway)
        process = gateway[
            gateway.index("local function process_ingress") :
            gateway.index("function Gateway.poll")
        ]
        self.assertIn("for _ = 1, MAX_INGRESS_PACKETS_PER_TICK do", process)
        handler = gateway[
            gateway.index("function Gateway.on_udp_packet_received") :
            gateway.index("function Gateway.on_entity_built")
        ]
        self.assertIn("enqueue_ingress", handler)
        self.assertNotIn("execute_request", handler)
        self.assertNotIn("handle_pairing_exchange", handler)

    def test_event_retention_is_isolated_per_force(self):
        events = (ROOT / "src/game/aiEvents.lua").read_text(encoding="utf-8")
        gateway = (ROOT / "src/game/aiGateway.lua").read_text(encoding="utf-8")
        self.assertIn("by_force", events)
        self.assertIn("local function force_event_root", events)
        listing = events[
            events.index("function AiEvents.list") :
            events.index("function AiEvents.latest_cursor")
        ]
        self.assertIn("force_event_root(context.force.index", listing)
        self.assertNotIn("entry.force_index ~= context.force.index", listing)
        self.assertIn(
            "AiEvents.has_new_events(pending.context, pending.payload.cursor)",
            gateway,
        )

    def test_event_rings_exist_only_for_forces_that_can_read_them(self):
        events = (ROOT / "src/game/aiEvents.lua").read_text(encoding="utf-8")
        # The guard sits on the single funnel every record call site goes
        # through, so no future event type can reintroduce an unreadable ring.
        self.assertIn('local Teams = require("src.game.teams")', events)
        readable = events[
            events.index("function AiEvents.readable_force") :
            events.index("function AiEvents.record")
        ]
        self.assertIn("Teams.get_by_force(force)", readable)
        # The headless development pairing binds game.forces.player, which is
        # never a team; dropping it would silence a client that does read.
        self.assertIn('force.name == "player" and dev_tools_enabled()', readable)
        # Team lookup first: an enemy force fails the name compare and never
        # reaches a settings read on the death path.
        self.assertLess(
            readable.index("Teams.get_by_force(force)"),
            readable.index("dev_tools_enabled()"),
        )
        record = events[
            events.index("function AiEvents.record") :
            events.index("local function parse_cursor")
        ]
        self.assertIn("if not AiEvents.readable_force(force) then return end", record)
        self.assertLess(
            record.index("readable_force(force)"),
            record.index("force_event_root("),
        )
        # A readable force still allocates and appends exactly as before.
        self.assertIn("force_event_root(force.index, true)", record)
        self.assertIn("events.slots[((id - 1) % events.capacity) + 1] = {", record)
        # Ring creation happens on exactly one line, and it is the guarded one.
        creating = [
            line for line in events.splitlines()
            if "force_event_root(" in line and "true" in line
        ]
        self.assertEqual(len(creating), 1)
        self.assertIn("force_event_root(force.index, true)", creating[0])

    def test_entity_death_hot_path_exits_before_any_bookkeeping(self):
        gateway = (ROOT / "src/game/aiGateway.lua").read_text(encoding="utf-8")
        removed = gateway[
            gateway.index("function Gateway.on_entity_removed") :
            gateway.index("function Gateway.on_player_changed_force")
        ]
        guard = (
            "if not (entity and entity.valid "
            "and AiEvents.readable_force(entity.force)) then return end"
        )
        self.assertIn(guard, removed)
        self.assertLess(
            removed.index('global_value("sceatorio-ai-enabled", false)'),
            removed.index(guard),
        )
        # A biter death allocates nothing, writes no storage and reads no
        # prototype name: every remaining statement sits behind the guard.
        for work in (
            "AiEvents.record",
            "AiConstants.OUTPUT_PORT",
            "AiControl.on_entity_removed",
            "Telemetry.on_entity_removed",
            "AiConstants.UPLINK",
            "pending_pairings",
            "root().bindings",
        ):
            self.assertLess(removed.index(guard), removed.index(work))

    def test_untracked_entity_removal_skips_the_reference_migration(self):
        telemetry = (ROOT / "src/game/aiTelemetry.lua").read_text(encoding="utf-8")
        removed = telemetry[
            telemetry.index("function Telemetry.on_entity_removed") :
            telemetry.index("local function resolve_entity")
        ]
        self.assertNotIn("entity_ref_root()", removed)
        self.assertIn(
            'local by_unit = type(refs.by_unit) == "table" and refs.by_unit or nil',
            removed,
        )
        self.assertIn(
            "if not by_unit or by_unit[entity.unit_number] == nil then return end",
            removed,
        )
        # Both schemas key by_unit by unit number, so the presence test is what
        # lets the migration stay behind it instead of running per death.
        self.assertLess(
            removed.index("by_unit[entity.unit_number] == nil then return end"),
            removed.index("migrate_entity_refs(refs)"),
        )
        self.assertEqual(removed.count("migrate_entity_refs"), 1)


if __name__ == "__main__":
    unittest.main()
