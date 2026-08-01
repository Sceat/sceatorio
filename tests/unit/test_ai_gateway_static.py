import pathlib
import unittest


ROOT = pathlib.Path(__file__).resolve().parents[2]


class AiGatewayStaticTests(unittest.TestCase):
    def test_data_stage_defines_researched_powered_uplink(self):
        data = (ROOT / "data.lua").read_text(encoding="utf-8")
        self.assertIn('name = "sceatorio-ai-uplink"', data)
        self.assertEqual(data.count('name = "sceatorio-ai-assistance"'), 1)
        self.assertNotIn("sceatorio-claude-blueprint-synthesis", data)
        self.assertIn('{"automation-science-pack", 1}', data)
        self.assertNotIn('"logistic-science-pack"', data)
        self.assertNotIn('"chemical-science-pack"', data)
        self.assertIn('energy_usage = "500kW"', data)

    def test_settings_are_server_gated_and_bounded(self):
        settings = (ROOT / "settings.lua").read_text(encoding="utf-8")
        gateway = (ROOT / "src/game/aiGateway.lua").read_text(encoding="utf-8")
        locale = (ROOT / "locale/en/sceatorio.cfg").read_text(encoding="utf-8")
        self.assertIn('name = "sceatorio-ai-enabled"', settings)
        self.assertIn('setting_type = "runtime-per-user"', settings)
        self.assertIn('name = "sceatorio-ai-requests-per-minute"', settings)
        # The redundant per-player enable switch was removed in 2.0.5; creating
        # a pairing code at a powered Uplink is the explicit personal opt-in.
        self.assertNotIn("sceatorio-ai-assistance-enabled", settings)
        self.assertNotIn("sceatorio-ai-assistance-enabled", gateway)
        self.assertNotIn("sceatorio-ai-assistance-enabled", locale)

    def test_entity_resolution_and_annotations_require_a_scoped_surface(self):
        telemetry = (ROOT / "src/game/aiTelemetry.lua").read_text(encoding="utf-8")
        control = (ROOT / "src/game/aiControl.lua").read_text(encoding="utf-8")
        resolver = telemetry[
            telemetry.index("local function resolve_entity") :
            telemetry.index("function Telemetry.resolve_entity")
        ]
        self.assertLess(
            resolver.index('"SURFACE_REQUIRED"'),
            resolver.index('"FORCE_SCOPE_MISMATCH"'),
        )
        annotation = control[control.index("function AiControl.add_annotation") :]
        self.assertIn('"SURFACE_REQUIRED"', annotation)

    def test_failed_pairing_exchanges_are_rate_limited_before_code_consumption(self):
        gateway = (ROOT / "src/game/aiGateway.lua").read_text(encoding="utf-8")
        self.assertIn("MAX_PAIRING_FAILURES_PER_MINUTE", gateway)
        exchange = gateway[
            gateway.index("local function handle_pairing_exchange") :
            gateway.index("local function send_success")
        ]
        self.assertLess(
            exchange.index("pairing_rate_limited()"),
            exchange.index("remove_pairing_code(request.code)"),
        )

    def test_udp_gateway_uses_server_only_2_1_api_and_hard_size_limit(self):
        gateway = (ROOT / "src/game/aiGateway.lua").read_text(encoding="utf-8")
        constants = (ROOT / "src/core/aiConstants.lua").read_text(encoding="utf-8")
        self.assertIn("helpers.recv_udp(0)", gateway)
        self.assertIn("helpers.send_udp(port, encoded, 0)", gateway)
        self.assertIn("48 * 1024", constants)
        self.assertIn('"sceatorio.factorio-gateway/1"', constants)
        self.assertIn("on_udp_packet_received", (ROOT / "control.lua").read_text(encoding="utf-8"))

    def test_pairing_is_one_time_server_derived_and_sends_one_exchange_response(self):
        gateway = (ROOT / "src/game/aiGateway.lua").read_text(encoding="utf-8")
        self.assertIn('request.kind ~= "pairing.exchange"', gateway)
        self.assertIn("local pending = remove_pairing_code(request.code)", gateway)
        self.assertLess(
            gateway.index("local pending = remove_pairing_code(request.code)"),
            gateway.index("local binding = create_binding_record(options)"),
        )
        self.assertEqual(
            gateway.count("handle_pairing_exchange(event.source_port, decoded, event.payload)"), 1
        )
        exchange = gateway[
            gateway.index("local function handle_pairing_exchange") :
            gateway.index("local function send_success")
        ]
        self.assertNotIn("request.force", exchange)
        self.assertNotIn("request.scope", exchange)

    def test_repairing_cannot_reset_player_quota_and_history_is_bounded(self):
        gateway = (ROOT / "src/game/aiGateway.lua").read_text(encoding="utf-8")
        revoke = gateway[
            gateway.index("local function revoke_binding") :
            gateway.index("local function revoke_player_bindings")
        ]
        self.assertNotIn("quota", revoke)
        self.assertIn("local quota = ai.quota[binding.player_id]", gateway)
        self.assertIn("MAX_RETAINED_BINDINGS_PER_PLAYER", gateway)
        self.assertIn("compact_bindings()", gateway)

    def test_completed_requests_are_exact_bounded_and_replay_safe(self):
        gateway = (ROOT / "src/game/aiGateway.lua").read_text(encoding="utf-8")
        self.assertIn("COMPLETED_REQUEST_TTL_TICKS", gateway)
        self.assertIn("MAX_COMPLETED_REQUESTS_PER_PLAYER", gateway)
        self.assertIn("MAX_COMPLETED_REQUEST_BYTES_PER_PLAYER", gateway)
        self.assertIn("request_bytes == entry.request_bytes", gateway)
        self.assertIn('"DUPLICATE_REQUEST_ID"', gateway)
        execute = gateway[
            gateway.index("local function execute_request") :
            gateway.index("local function wait_context_valid")
        ]
        self.assertLess(execute.index("authorize(request)"), execute.index("completed_request_replay"))
        self.assertLess(execute.index("completed_request_replay"), execute.index("attach_quota"))
        self.assertIn("complete_request_success", execute)
        self.assertIn("complete_request_error", execute)

    def test_pairing_retries_resend_only_the_identical_exchange(self):
        gateway = (ROOT / "src/game/aiGateway.lua").read_text(encoding="utf-8")
        exchange = gateway[
            gateway.index("local function handle_pairing_exchange") :
            gateway.index("local function send_success")
        ]
        self.assertIn("pairing_replay", exchange)
        self.assertIn("request_bytes == replay.request_bytes", gateway)
        self.assertLess(exchange.index("pairing_replay"), exchange.index("remove_pairing_code"))
        self.assertIn('"DUPLICATE_REQUEST_ID"', exchange)

    def test_disabled_policy_does_not_drain_or_accept_udp(self):
        gateway = (ROOT / "src/game/aiGateway.lua").read_text(encoding="utf-8")
        poll = gateway[
            gateway.index("function Gateway.poll") :
            gateway.index("function Gateway.on_udp_packet_received")
        ]
        self.assertLess(
            poll.index('not global_value("sceatorio-ai-enabled", false)'),
            poll.index("helpers.recv_udp(0)"),
        )
        udp_handler = gateway[
            gateway.index("function Gateway.on_udp_packet_received") :
            gateway.index("function Gateway.on_entity_built")
        ]
        self.assertIn('not global_value("sceatorio-ai-enabled", false)', udp_handler)
        setting_change = gateway[
            gateway.index("function Gateway.on_setting_changed") :
            gateway.index("local function active_bindings")
        ]
        self.assertIn('revoke_binding(binding, "server-policy-disabled")', setting_change)
        self.assertIn("cancel_event_waits", setting_change)
        self.assertIn("clear_pairing_replays", setting_change)

    def test_event_wait_rechecks_events_capability(self):
        gateway = (ROOT / "src/game/aiGateway.lua").read_text(encoding="utf-8")
        wait_check = gateway[
            gateway.index("local function wait_context_valid") :
            gateway.index("local function process_event_waits")
        ]
        self.assertIn('binding.capabilities["events:read"]', wait_check)
        self.assertIn('current_capabilities["events:read"]', wait_check)

    def test_event_details_cannot_expose_an_ungranted_remote_view_surface(self):
        gateway = (ROOT / "src/game/aiGateway.lua").read_text(encoding="utf-8")
        events = (ROOT / "src/game/aiEvents.lua").read_text(encoding="utf-8")
        surface_change = gateway[
            gateway.index("function Gateway.on_player_changed_surface") :
            gateway.index("function Gateway.on_research_started")
        ]
        self.assertNotIn("previousSurfaceId", surface_change)
        self.assertIn("previous_surface_index", surface_change)
        self.assertIn("context.surface_ids_by_index[details.previous_surface_index]", events)
        public_entry = events[
            events.index("local function public_entry") :
            events.index("function AiEvents.list")
        ]
        self.assertIn("details = public_details(context, entry)", public_entry)
        self.assertNotIn("details = entry.details", public_entry)

    def test_pairing_and_operation_defaults_ignore_space_age_remote_view(self):
        gateway = (ROOT / "src/game/aiGateway.lua").read_text(encoding="utf-8")
        surface_builder = gateway[
            gateway.index("local function binding_surfaces") :
            gateway.index("local function sorted_capabilities")
        ]
        self.assertIn("for surface_index in pairs(team.surfaces)", surface_builder)
        self.assertNotRegex(gateway, r"\bplayer\.surface(?:\.|\s|[,;)])")
        self.assertIn("local function physical_player_surface", gateway)
        pairing_options = gateway[
            gateway.index("local function player_pairing_options") :
            gateway.index("local function remove_pairing_code")
        ]
        self.assertIn(
            "surfaces = binding_surfaces(team, uplink.surface, physical_player_surface(player))",
            pairing_options,
        )
        selected_surface = gateway[
            gateway.index("local function selected_surface") :
            gateway.index("local function consume_quota")
        ]
        self.assertIn("local candidate = physical_player_surface(player)", selected_surface)
        self.assertIn("candidate = uplink.surface", selected_surface)
        self.assertNotIn("for id, grant in pairs(binding.surfaces)", selected_surface)
        surface_change = gateway[
            gateway.index("function Gateway.on_player_changed_surface") :
            gateway.index("function Gateway.on_research_started")
        ]
        self.assertNotIn("binding.surfaces", surface_change)

    def test_mcp_operations_expose_no_character_or_world_mutation(self):
        operations = (ROOT / "src/game/aiOperations.lua").read_text(encoding="utf-8")
        for forbidden in (
            ".teleport(",
            ".mine(",
            ".craft(",
            "create_entity",
            "order_deconstruction",
            "order_upgrade",
            "revive(",
            "set_recipe(",
        ):
            self.assertNotIn(forbidden, operations)

    def test_blueprints_are_inbox_first_and_never_place_ghosts(self):
        blueprints = (ROOT / "src/game/aiBlueprints.lua").read_text(encoding="utf-8")
        self.assertIn("blueprint_inbox", blueprints)
        self.assertIn("set_blueprint_entities", blueprints)
        self.assertIn("add_to_clipboard", blueprints)
        self.assertNotIn("build_blueprint", blueprints)
        self.assertNotIn("create_entity", blueprints)

    def test_map_annotations_are_chart_only_and_player_force_scoped(self):
        control = (ROOT / "src/game/aiControl.lua").read_text(encoding="utf-8")
        annotation = control[
            control.index("function AiControl.add_annotation") :
            control.index("return AiControl")
        ]
        self.assertIn('render_mode = "chart"', annotation)
        self.assertIn("players = {context.player.index}", annotation)
        self.assertIn("forces = {context.force}", annotation)
        self.assertIn('visibility = "paired-player-only"', annotation)


if __name__ == "__main__":
    unittest.main()
