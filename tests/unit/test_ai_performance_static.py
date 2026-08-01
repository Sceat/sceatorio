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
        self.assertIn("local BLUEPRINT_INBOX_SCHEMA_VERSION = 2", blueprints)
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


if __name__ == "__main__":
    unittest.main()
