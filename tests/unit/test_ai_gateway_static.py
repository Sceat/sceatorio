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
        self.assertIn('name = "sceatorio-ai-requests-per-minute"', settings)
        # The redundant per-player enable switch was removed in 2.0.5; creating
        # a pairing code at a powered Uplink is the explicit personal opt-in.
        self.assertNotIn("sceatorio-ai-assistance-enabled", settings)
        self.assertNotIn("sceatorio-ai-assistance-enabled", gateway)
        self.assertNotIn("sceatorio-ai-assistance-enabled", locale)
        # 2.0.9 finished the same cleanup: pairing at a powered Uplink is the
        # only personal consent, so no per-player setting survives at all.
        self.assertNotIn("runtime-per-user", settings)
        for removed in (
            "sceatorio-ai-requested-capabilities",
            "sceatorio-ai-blueprint-cursor-delivery",
            "sceatorio-ai-max-page-size",
            "sceatorio-ai-binding-lifetime-hours",
        ):
            self.assertNotIn(removed, settings)
            self.assertNotIn(removed, gateway)
            self.assertNotIn(removed, locale)
        self.assertNotIn("settings.get_player_settings", gateway)

    def test_pairing_grants_the_full_server_capability_set(self):
        gateway = (ROOT / "src/game/aiGateway.lua").read_text(encoding="utf-8")
        effective = gateway[
            gateway.index("local function effective_capabilities") :
            gateway.index("local function physical_player_surface")
        ]
        # A player's capabilities are exactly the server allowlist intersected
        # with the supported set and the researched technology.
        self.assertIn("allowed_capabilities()", effective)
        self.assertIn("if allowed[capability] then", effective)
        self.assertNotIn("requested", effective)

    def test_blueprint_clipboard_delivery_is_always_allowed_for_real_players(self):
        gateway = (ROOT / "src/game/aiGateway.lua").read_text(encoding="utf-8")
        descriptor = gateway[
            gateway.index("local function descriptor(binding)") :
            gateway.index("local function uplink_powered")
        ]
        self.assertIn('blueprintDelivery = "allow-cursor"', descriptor)
        # Dev pairings keep cursor delivery off: headless has no connected
        # player, and deliver_to_clipboard requires one.
        self.assertIn("allow_cursor = not binding.dev_virtual,", gateway)
        self.assertNotIn("binding.allow_cursor", gateway)

    def test_page_size_is_a_fixed_constant(self):
        gateway = (ROOT / "src/game/aiGateway.lua").read_text(encoding="utf-8")
        self.assertIn("local MAX_PAGE_SIZE = 100", gateway)
        self.assertIn("max_page_size = MAX_PAGE_SIZE", gateway)

    def test_bindings_never_expire_and_revocation_is_the_only_end(self):
        gateway = (ROOT / "src/game/aiGateway.lua").read_text(encoding="utf-8")
        operations = (ROOT / "src/game/aiOperations.lua").read_text(encoding="utf-8")
        # A pairing is permanent: no lifetime constant, no stamped expiry, and
        # nothing in the gateway can answer TOKEN_EXPIRED any more.
        self.assertNotIn("BINDING_LIFETIME_HOURS", gateway)
        self.assertNotIn("TOKEN_EXPIRED", gateway)
        self.assertNotIn("binding.expires_tick", gateway)
        self.assertNotIn("binding.expires_tick", operations)
        # The descriptor is the wire contract: no expiry field means no expiry.
        descriptor = gateway[
            gateway.index("local function descriptor(binding)") :
            gateway.index("local function uplink_powered")
        ]
        self.assertIn("issuedTick = binding.issued_tick", descriptor)
        self.assertNotIn("expiresTick", descriptor)

        # Every place that used to gate on expiry now gates on revocation alone.
        authorize = gateway[
            gateway.index("local function authorize(request)") :
            gateway.index("local function attach_quota")
        ]
        self.assertIn(
            'if binding.revoked_tick then return nil, "TOKEN_REVOKED"', authorize
        )
        wait_check = gateway[
            gateway.index("local function wait_context_valid") :
            gateway.index("local function process_event_waits")
        ]
        self.assertIn("if binding.revoked_tick then return false end", wait_check)
        compact = gateway[
            gateway.index("local function compact_bindings") :
            gateway.index("local function process_ingress")
        ]
        self.assertIn("local active = not binding.revoked_tick", compact)
        self.assertIn("game.tick - binding.revoked_tick <= BINDING_RETENTION_TICKS", compact)
        active = gateway[
            gateway.index("local function active_bindings") :
            gateway.index("local function destroy_gui")
        ]
        self.assertIn("if not binding.revoked_tick", active)

        # Pairing codes are the one thing that still expires: they are one-shot.
        self.assertIn("local PAIRING_CODE_LIFETIME_TICKS = 5 * 60 * 60", gateway)
        self.assertIn("if pending.expires_tick <= game.tick then", gateway)

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

    def test_blueprint_extensions_are_validated_against_real_prototypes(self):
        blueprints = (ROOT / "src/game/aiBlueprints.lua").read_text(encoding="utf-8")
        validate = blueprints[
            blueprints.index("function Blueprints.validate") :
            blueprints.index("local function signal_id")
        ]
        # The v1 blanket rejections are gone; every widened field is validated.
        self.assertNotIn("ITEM_REQUESTS_UNSUPPORTED", blueprints)
        for call in (
            "validate_items(entity, prototype, build_cost, errors, path)",
            "validate_filters(entity, prototype, errors, path)",
            "validate_request_filters(entity, prototype, errors, path)",
            "validate_control(entity, prototype, errors, path)",
        ):
            self.assertIn(call, validate)
        # Arbitrary settings blobs stay rejected; `control` replaced them.
        self.assertIn("ENTITY_SETTINGS_UNSUPPORTED", validate)

        # Modules are checked against the target prototype, not just the item list.
        for guard in (
            'item.type ~= "module"',
            "prototype.allowed_module_categories",
            "prototype.allowed_effects",
            "prototype.module_inventory_size",
            '"MODULE_CATEGORY_NOT_ALLOWED"',
            '"MODULE_EFFECT_NOT_ALLOWED"',
            '"TOO_MANY_MODULES"',
            '"ENTITY_ACCEPTS_NO_MODULES"',
        ):
            self.assertIn(guard, blueprints)

        # Signals resolve against real prototypes, and operators are enumerated.
        for guard in (
            "prototypes.virtual_signal",
            '"UNKNOWN_SIGNAL"',
            '"INVALID_OPERATION"',
            '"INVALID_COMPARATOR"',
            '"INVALID_READ_MODE"',
            '"CONTROL_FIELD_NOT_SUPPORTED"',
        ):
            self.assertIn(guard, blueprints)

        # Lua 5.2 has no \u{} escape; Unicode comparators must be byte escapes.
        self.assertNotIn("\\u{", blueprints.replace("no \\u{} escape", ""))

    def test_canonical_layout_persists_only_the_declared_whitelist(self):
        blueprints = (ROOT / "src/game/aiBlueprints.lua").read_text(encoding="utf-8")
        canonical = blueprints[
            blueprints.index("local function copy_shape") :
            blueprints.index("local function position_of")
        ]
        # copy_shape walks only declared keys, so unknown JSON keys cannot reach
        # the save file even though validation tolerates them.
        for declared in ("shape.scalars", "shape.objects", "shape.arrays", "shape.counts"):
            self.assertIn(declared, canonical)
        self.assertNotIn("pairs(source)", canonical)
        self.assertIn("copy_shape(source, ENTITY_EXTRA_SHAPE)", canonical)

        # Every widened field is declared in the whitelist exactly once.
        shapes = blueprints[
            blueprints.index("local SIGNAL_SHAPE") :
            blueprints.index("local function copy_shape")
        ]
        for field in (
            '"filterMode"',
            '"inputPriority"',
            '"outputPriority"',
            '"requestFromBuffers"',
            "items = {max = MAX_MODULE_KINDS}",
            "filters = {max = MAX_FILTERS",
            "requestFilters = {",
            "control = CONTROL_SHAPE",
        ):
            self.assertIn(field, shapes)
        # Bounds live in the shape, so the copier cannot be made to walk forever.
        for bound in ("max = MAX_SECTIONS", "max = MAX_DECIDER_CONDITIONS", "max = MAX_DECIDER_OUTPUTS"):
            self.assertIn(bound, shapes)

    def test_blueprint_caps_are_bounded_by_the_gateway_datagram(self):
        blueprints = (ROOT / "src/game/aiBlueprints.lua").read_text(encoding="utf-8")
        constants = (ROOT / "src/core/aiConstants.lua").read_text(encoding="utf-8")
        self.assertIn("Constants.MAX_DATAGRAM_BYTES = 48 * 1024", constants)
        # 512 entities / 2048 tiles needed ~172 KiB and could never be delivered.
        self.assertIn("local MAX_ENTITIES = 400", blueprints)
        self.assertIn("local MAX_TILES = 512", blueprints)
        self.assertIn("local MAX_LAYOUT_BYTES = 44 * 1024", blueprints)
        self.assertIn('"LAYOUT_TOO_LARGE"', blueprints)
        self.assertIn("helpers.table_to_json(canonical_layout(layout))", blueprints)

    def test_blueprint_emitter_stays_in_lockstep_with_the_persisted_layout(self):
        blueprints = (ROOT / "src/game/aiBlueprints.lua").read_text(encoding="utf-8")
        emitter = blueprints[
            blueprints.index("local function apply_extras") :
            blueprints.index("local function blueprint_tiles")
        ]
        # Every persisted extension has to reach the delivered blueprint item.
        for emitted in (
            "entity.items = insert_plans(source, prototype_type)",
            "entity.filters = item_filters(source)",
            "entity.filter = single_filter(source.filters[1])",
            "entity.filter_mode = source.filterMode",
            "entity.input_priority = source.inputPriority",
            "entity.output_priority = source.outputPriority",
            "entity.request_filters = request_sections(source)",
            "entity.control_behavior = control_behavior(kind, source.control)",
            "entity.use_filters = true",
        ):
            self.assertIn(emitted, emitter)
        # Factorio 2.1 collapsed crafting machines onto crafter_modules.
        self.assertIn('["assembling-machine"] = "crafter_modules"', blueprints)
        self.assertIn("defines.inventory[MODULE_INVENTORY[prototype_type]", blueprints)
        self.assertIn("in_inventory = positions", blueprints)
        # Module placement must be deterministic for multiplayer save sync.
        self.assertIn("table.sort(names)", blueprints)

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
