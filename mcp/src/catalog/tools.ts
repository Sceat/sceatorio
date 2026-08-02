import type { StandardSchemaWithJSON } from "@modelcontextprotocol/server";
import type * as z from "zod/v4";

import type { Capability } from "../domain/capabilities.js";
import {
  AddMapAnnotationInputSchema,
  AnalyzeBlueprintInputSchema,
  CreateBlueprintBookInputSchema,
  DeleteAiBlueprintInputSchema,
  DeleteBlueprintBookInputSchema,
  EmptyInputSchema,
  GetBlueprintBookInputSchema,
  GetAlertsInputSchema,
  GetChartedChunksInputSchema,
  GetElectricNetworkInputSchema,
  GetEventsInputSchema,
  GetLogisticNetworkInputSchema,
  GetProductionInputSchema,
  GetPrototypeInputSchema,
  GetRecipeInputSchema,
  GetResearchInputSchema,
  GetTrainsInputSchema,
  GetTransportCapacitiesInputSchema,
  GetUnlockedTechnologiesInputSchema,
  InspectEntityInputSchema,
  ListAiBlueprintsInputSchema,
  LoadAiBlueprintInputSchema,
  QueryEntitiesInputSchema,
  ReadCircuitPortInputSchema,
  SaveBlueprintInputSchema,
  UpdateBlueprintBookInputSchema,
  ValidateBlueprintInputSchema,
  WaitForEventsInputSchema,
  WriteControlPortInputSchema
} from "./schemas.js";

type ToolSchema = z.ZodType & StandardSchemaWithJSON;

export interface ToolDefinition<Schema extends ToolSchema = ToolSchema> {
  readonly name: string;
  readonly operation: string;
  readonly description: string;
  readonly capability: Capability;
  readonly inputSchema: Schema;
  readonly readOnly: boolean;
  readonly destructive: boolean;
  readonly idempotent: boolean;
  readonly openWorld: boolean;
  readonly timeoutMs?: ((input: z.output<Schema>) => number) | undefined;
}

function tool<const Schema extends ToolSchema>(
  definition: ToolDefinition<Schema>
): ToolDefinition<Schema> {
  return definition;
}

export const V1_TOOL_DEFINITIONS = [
  tool({
    name: "get_session",
    operation: "session.get",
    description: "Read this pairing's save, player, force, surfaces, capabilities and API budgets.",
    capability: "session:read",
    inputSchema: EmptyInputSchema,
    readOnly: true,
    destructive: false,
    idempotent: true,
    openWorld: false
  }),
  tool({
    name: "get_production",
    operation: "statistics.production",
    description: "Read raw item, fluid, kill or build flow statistics for an explicit time window.",
    capability: "production:read",
    inputSchema: GetProductionInputSchema,
    readOnly: true,
    destructive: false,
    idempotent: true,
    openWorld: false
  }),
  tool({
    name: "get_electric_network",
    operation: "electric.network",
    description: "Read generation, consumption, satisfaction and storage for the network connected to a scoped anchor entity.",
    capability: "electricity:read",
    inputSchema: GetElectricNetworkInputSchema,
    readOnly: true,
    destructive: false,
    idempotent: true,
    openWorld: false
  }),
  tool({
    name: "get_research",
    operation: "research.get",
    description: "Read current research, progress, queue and technology prerequisites without changing them.",
    capability: "research:read",
    inputSchema: GetResearchInputSchema,
    readOnly: true,
    destructive: false,
    idempotent: true,
    openWorld: false
  }),
  tool({
    name: "get_recipe",
    operation: "prototype.recipe",
    description: "Read one recipe's ingredients, products, energy, category and unlock state.",
    capability: "prototypes:read",
    inputSchema: GetRecipeInputSchema,
    readOnly: true,
    destructive: false,
    idempotent: true,
    openWorld: false
  }),
  tool({
    name: "get_prototype",
    operation: "prototype.get",
    description: "Read objective properties for one named Factorio prototype, including an entity's fluid box pipe connections with their positions, flow directions and volume, inserter pickup and drop geometry and speeds, module slot count with allowed module categories and effects, and crafting categories.",
    capability: "prototypes:read",
    inputSchema: GetPrototypeInputSchema,
    readOnly: true,
    destructive: false,
    idempotent: true,
    openWorld: false
  }),
  tool({
    name: "get_transport_capacities",
    operation: "prototype.transport-capacities",
    description: "Read belt, inserter, pipe and cargo throughput inputs needed for factory calculations.",
    capability: "prototypes:read",
    inputSchema: GetTransportCapacitiesInputSchema,
    readOnly: true,
    destructive: false,
    idempotent: true,
    openWorld: false
  }),
  tool({
    name: "get_unlocked_technologies",
    operation: "research.unlocked-technologies",
    description: "List technologies unlocked by this force, including Space Age technologies when present.",
    capability: "research:read",
    inputSchema: GetUnlockedTechnologiesInputSchema,
    readOnly: true,
    destructive: false,
    idempotent: true,
    openWorld: false
  }),
  tool({
    name: "query_entities",
    operation: "entity.query",
    description: "Page through force-authorized entities in a bounded area using low-level filters.",
    capability: "factory:read",
    inputSchema: QueryEntitiesInputSchema,
    readOnly: true,
    destructive: false,
    idempotent: true,
    openWorld: false
  }),
  tool({
    name: "inspect_entity",
    operation: "entity.inspect",
    description: "Read status, recipe, bounded inventories, fluids and energy for one opaque entity ID.",
    capability: "factory:read",
    inputSchema: InspectEntityInputSchema,
    readOnly: true,
    destructive: false,
    idempotent: true,
    openWorld: false
  }),
  tool({
    name: "get_logistic_network",
    operation: "logistics.network",
    description: "Read one logistic network's cells, storage and robot counts without changing requests.",
    capability: "logistics:read",
    inputSchema: GetLogisticNetworkInputSchema,
    readOnly: true,
    destructive: false,
    idempotent: true,
    openWorld: false
  }),
  tool({
    name: "get_trains",
    operation: "train.list",
    description: "Read scoped trains, states, stops and schedules without editing them.",
    capability: "trains:read",
    inputSchema: GetTrainsInputSchema,
    readOnly: true,
    destructive: false,
    idempotent: true,
    openWorld: false
  }),
  tool({
    name: "get_alerts",
    operation: "alert.list",
    description: "Read a bounded page of alerts visible to the paired player and authorized surfaces.",
    capability: "alerts:read",
    inputSchema: GetAlertsInputSchema,
    readOnly: true,
    destructive: false,
    idempotent: true,
    openWorld: false
  }),
  tool({
    name: "get_charted_chunks",
    operation: "map.charted-chunks",
    description: "Read bounded force-chart state; resource and enemy detail is returned only for currently visible chunks.",
    capability: "map:read",
    inputSchema: GetChartedChunksInputSchema,
    readOnly: true,
    destructive: false,
    idempotent: true,
    openWorld: false
  }),
  tool({
    name: "read_circuit_port",
    operation: "circuit.port.read",
    description: "Read a bounded signal snapshot from a force-owned dedicated AI input port.",
    capability: "circuits:read",
    inputSchema: ReadCircuitPortInputSchema,
    readOnly: true,
    destructive: false,
    idempotent: true,
    openWorld: false
  }),
  tool({
    name: "get_events",
    operation: "event.list",
    description: "Read a bounded page of force- and surface-scoped events after an opaque cursor.",
    capability: "events:read",
    inputSchema: GetEventsInputSchema,
    readOnly: true,
    destructive: false,
    idempotent: true,
    openWorld: false
  }),
  tool({
    name: "wait_for_events",
    operation: "event.wait",
    description: "Wait without blocking Factorio for scoped events or a bounded 25-second deadline.",
    capability: "events:read",
    inputSchema: WaitForEventsInputSchema,
    readOnly: true,
    destructive: false,
    idempotent: true,
    openWorld: false,
    timeoutMs: (input) => input.timeoutMs + 2_000
  }),
  tool({
    name: "validate_blueprint",
    operation: "blueprint.validate",
    description: "Validate structured prototypes, unlocks, wire references and optional non-mutating placement collisions.",
    capability: "blueprints:validate",
    inputSchema: ValidateBlueprintInputSchema,
    readOnly: true,
    destructive: false,
    idempotent: true,
    openWorld: false
  }),
  tool({
    name: "analyze_blueprint",
    operation: "blueprint.analyze",
    description: "Return objective footprint, build-item cost, declared outputs and validation warnings for a structured layout.",
    capability: "blueprints:validate",
    inputSchema: AnalyzeBlueprintInputSchema,
    readOnly: true,
    destructive: false,
    idempotent: true,
    openWorld: false
  }),
  tool({
    name: "save_blueprint",
    operation: "blueprint.save",
    description: "Save a validated layout to the player's mod-owned inbox and optionally copy it to the opted-in clipboard.",
    capability: "blueprints:write",
    inputSchema: SaveBlueprintInputSchema,
    readOnly: false,
    destructive: false,
    idempotent: false,
    openWorld: false
  }),
  tool({
    name: "list_ai_blueprints",
    operation: "blueprint.library.list",
    description: "List this player's immutable saved AI blueprint records and, unless includeBooks is false, a summary of every blueprint book they own; v1 records use revision 1.",
    capability: "blueprints:validate",
    inputSchema: ListAiBlueprintsInputSchema,
    readOnly: true,
    destructive: false,
    idempotent: true,
    openWorld: false
  }),
  tool({
    name: "load_ai_blueprint",
    operation: "blueprint.library.load",
    description: "Load one immutable saved AI blueprint record and optionally deliver it to the player.",
    capability: "blueprints:write",
    inputSchema: LoadAiBlueprintInputSchema,
    readOnly: false,
    destructive: false,
    idempotent: false,
    openWorld: false
  }),
  tool({
    name: "delete_ai_blueprint",
    operation: "blueprint.library.delete",
    description: "Permanently remove one saved AI blueprint record, with every revision, from this player's inbox; the record cannot be recovered afterwards.",
    capability: "blueprints:write",
    inputSchema: DeleteAiBlueprintInputSchema,
    readOnly: false,
    destructive: true,
    idempotent: false,
    openWorld: false
  }),
  tool({
    name: "create_blueprint_book",
    operation: "blueprint.book.create",
    description: "Group blueprints this player already saved into a named blueprint book, in the given order; the book references the records and never copies their layouts. Save each blueprint first, then group the returned IDs.",
    capability: "blueprints:write",
    inputSchema: CreateBlueprintBookInputSchema,
    readOnly: false,
    destructive: false,
    idempotent: false,
    openWorld: false
  }),
  tool({
    name: "get_blueprint_book",
    operation: "blueprint.book.get",
    description: "Read one blueprint book's name, description and ordered member blueprints; list_ai_blueprints reports which books exist.",
    capability: "blueprints:validate",
    inputSchema: GetBlueprintBookInputSchema,
    readOnly: true,
    destructive: false,
    idempotent: true,
    openWorld: false
  }),
  tool({
    name: "update_blueprint_book",
    operation: "blueprint.book.update",
    description: "Rename a blueprint book, add saved blueprints to it at the end or at a position, remove members, or replace its member order. Removing a member never deletes the blueprint itself, and an update that names any blueprint this player does not own is rejected whole.",
    capability: "blueprints:write",
    inputSchema: UpdateBlueprintBookInputSchema,
    // The remove and reorder operations rewrite the stored member list in
    // place, so the honest worst case for this tool is a destructive update --
    // of the grouping only. No blueprint record is ever destroyed by it.
    readOnly: false,
    destructive: true,
    idempotent: false,
    openWorld: false
  }),
  tool({
    name: "delete_blueprint_book",
    operation: "blueprint.book.delete",
    description: "Permanently remove one blueprint book from this player's inbox; the book cannot be recovered afterwards, while every blueprint it grouped stays saved and loadable.",
    capability: "blueprints:write",
    inputSchema: DeleteBlueprintBookInputSchema,
    readOnly: false,
    destructive: true,
    idempotent: false,
    openWorld: false
  }),
  tool({
    name: "write_control_port",
    operation: "circuit.port.write",
    description: "Write at most 32 signals to a dedicated AI output port; changes are slow-rate and automatically clear at TTL.",
    capability: "control_ports:write",
    inputSchema: WriteControlPortInputSchema,
    readOnly: false,
    destructive: true,
    idempotent: false,
    openWorld: false
  }),
  tool({
    name: "add_map_annotation",
    operation: "map.annotation.add",
    description: "Add a TTL-bounded map label rendered only to the paired player on an authorized surface.",
    capability: "annotations:write",
    inputSchema: AddMapAnnotationInputSchema,
    readOnly: false,
    destructive: false,
    idempotent: false,
    openWorld: false
  })
] as const;

export type V1ToolDefinition = (typeof V1_TOOL_DEFINITIONS)[number];
export type V1ToolName = V1ToolDefinition["name"];
export const V1_TOOL_NAMES: readonly V1ToolName[] = V1_TOOL_DEFINITIONS.map(
  (definition) => definition.name
);

export function surfaceIdFromInput(input: unknown): string | undefined {
  if (typeof input !== "object" || input === null || !("surfaceId" in input)) {
    return undefined;
  }
  const surfaceId = (input as { surfaceId?: unknown }).surfaceId;
  return typeof surfaceId === "string" ? surfaceId : undefined;
}
