import assert from "node:assert/strict";
import test from "node:test";

import {
  BlueprintLayoutSchema,
  CreateBlueprintBookInputSchema,
  DeleteAiBlueprintInputSchema,
  DeleteBlueprintBookInputSchema,
  GetBlueprintBookInputSchema,
  ListAiBlueprintsInputSchema,
  UpdateBlueprintBookInputSchema,
  GetChartedChunksInputSchema,
  GetElectricNetworkInputSchema,
  GetTransportCapacitiesInputSchema,
  QueryEntitiesInputSchema,
  SaveBlueprintInputSchema
} from "../src/catalog/schemas.js";
import { V1_TOOL_DEFINITIONS, V1_TOOL_NAMES } from "../src/catalog/tools.js";

function validLayout() {
  return {
    name: "Compact stone smelter",
    description: "A small test layout",
    entities: [
      {
        entityNumber: 1,
        prototype: "stone-furnace",
        position: { x: 0, y: 0 },
        connections: [
          {
            toEntityNumber: 2,
            wire: "copper" as const
          }
        ]
      },
      {
        entityNumber: 2,
        prototype: "small-electric-pole",
        position: { x: 2, y: 0 }
      }
    ],
    tiles: [],
    expectedOutputs: [{ type: "item" as const, name: "iron-plate", perSecond: 1 }]
  };
}

test("representative structured blueprints pass validation", () => {
  assert.equal(BlueprintLayoutSchema.safeParse(validLayout()).success, true);
  assert.equal(
    SaveBlueprintInputSchema.safeParse({ layout: validLayout(), delivery: "inbox" }).success,
    true
  );
});

test("duplicate IDs and dangling circuit connections fail blueprint validation", () => {
  const duplicate = validLayout();
  duplicate.entities[1]!.entityNumber = 1;
  assert.equal(BlueprintLayoutSchema.safeParse(duplicate).success, false);

  const dangling = validLayout();
  dangling.entities[0]!.connections![0]!.toEntityNumber = 99;
  assert.equal(BlueprintLayoutSchema.safeParse(dangling).success, false);
});

test("Factorio 2.1 wire connector IDs include zero for the red circuit connector", () => {
  const red = validLayout();
  const redConnection = red.entities[0]!.connections![0]! as {
    fromConnectorId?: number;
    toConnectorId?: number;
  };
  redConnection.fromConnectorId = 0;
  redConnection.toConnectorId = 0;
  assert.equal(BlueprintLayoutSchema.safeParse(red).success, true);

  const outsideDefines = validLayout();
  (outsideDefines.entities[0]!.connections![0]! as { fromConnectorId?: number })
    .fromConnectorId = 9;
  assert.equal(BlueprintLayoutSchema.safeParse(outsideDefines).success, false);
});

test("entity scans reject unbounded or oversized map areas", () => {
  const parsed = QueryEntitiesInputSchema.safeParse({
    surfaceId: "nauvis",
    area: {
      leftTop: { x: 0, y: 0 },
      rightBottom: { x: 2_000, y: 2_000 }
    }
  });
  assert.equal(parsed.success, false);
});

test("charted chunk reads always require an explicit bounded area", () => {
  assert.equal(
    GetChartedChunksInputSchema.safeParse({ surfaceId: "nauvis" }).success,
    false
  );
  assert.equal(
    GetChartedChunksInputSchema.safeParse({
      surfaceId: "nauvis",
      area: {
        leftTop: { x: -64, y: -64 },
        rightBottom: { x: 64, y: 64 }
      }
    }).success,
    true
  );
});

test("electric reads require a scoped anchor and transport reads are pageable", () => {
  assert.equal(
    GetElectricNetworkInputSchema.safeParse({
      surfaceId: "surface:1",
      networkId: "electric:1"
    }).success,
    false
  );
  assert.equal(
    GetElectricNetworkInputSchema.safeParse({
      surfaceId: "surface:1",
      anchorEntityId: "entity:42"
    }).success,
    true
  );
  assert.equal(
    GetTransportCapacitiesInputSchema.safeParse({
      pagination: { cursor: "offset:100", limit: 50 }
    }).success,
    true
  );
});

test("the v1 tool catalog contains no unrestricted character-control tools", () => {
  const forbidden = ["move", "mine", "craft", "shoot", "teleport", "place_entity", "delete_entity"];
  for (const fragment of forbidden) {
    assert.equal(V1_TOOL_NAMES.some((name) => name.includes(fragment)), false);
  }
  assert.ok(V1_TOOL_NAMES.includes("save_blueprint"));
  assert.ok(V1_TOOL_NAMES.includes("get_transport_capacities"));
  assert.ok(V1_TOOL_NAMES.includes("get_logistic_network"));
  assert.ok(V1_TOOL_NAMES.includes("get_trains"));
  assert.ok(V1_TOOL_NAMES.includes("list_ai_blueprints"));
  assert.ok(V1_TOOL_NAMES.includes("load_ai_blueprint"));
  assert.ok(V1_TOOL_NAMES.includes("delete_ai_blueprint"));
  assert.ok(V1_TOOL_NAMES.includes("create_blueprint_book"));
  assert.ok(V1_TOOL_NAMES.includes("get_blueprint_book"));
  assert.ok(V1_TOOL_NAMES.includes("update_blueprint_book"));
  assert.ok(V1_TOOL_NAMES.includes("delete_blueprint_book"));
  assert.equal(V1_TOOL_NAMES.length, 29);
  for (const safeBoundaryTool of [
    "get_alerts",
    "get_events",
    "wait_for_events",
    "add_map_annotation",
    "read_circuit_port",
    "write_control_port"
  ] as const) {
    assert.ok(V1_TOOL_NAMES.includes(safeBoundaryTool));
  }
});

test("every tool declares exact MCP safety annotations", () => {
  for (const definition of V1_TOOL_DEFINITIONS) {
    assert.equal(typeof definition.readOnly, "boolean", definition.name);
    assert.equal(typeof definition.destructive, "boolean", definition.name);
    assert.equal(typeof definition.idempotent, "boolean", definition.name);
    assert.equal(typeof definition.openWorld, "boolean", definition.name);
    assert.equal(definition.openWorld, false, definition.name);
  }

  const byName = new Map(V1_TOOL_DEFINITIONS.map((definition) => [definition.name, definition]));
  assert.equal(byName.get("save_blueprint")?.destructive, false);
  assert.equal(byName.get("load_ai_blueprint")?.destructive, false);
  assert.equal(byName.get("add_map_annotation")?.destructive, false);
  assert.equal(byName.get("write_control_port")?.destructive, true);
  assert.equal(byName.get("write_control_port")?.idempotent, false);
  // Deleting a saved record is unrecoverable, so it must be announced as
  // destructive and non-idempotent, on the same write capability as saving.
  assert.equal(byName.get("delete_ai_blueprint")?.destructive, true);
  assert.equal(byName.get("delete_ai_blueprint")?.idempotent, false);
  assert.equal(byName.get("delete_ai_blueprint")?.readOnly, false);
  assert.equal(byName.get("delete_ai_blueprint")?.capability, "blueprints:write");
});

test("blueprint book tools carry honest annotations on the documented capabilities", () => {
  const byName = new Map(V1_TOOL_DEFINITIONS.map((definition) => [definition.name, definition]));
  // Creating and reading a book add nothing and destroy nothing.
  assert.equal(byName.get("create_blueprint_book")?.capability, "blueprints:write");
  assert.equal(byName.get("create_blueprint_book")?.readOnly, false);
  assert.equal(byName.get("create_blueprint_book")?.destructive, false);
  assert.equal(byName.get("get_blueprint_book")?.capability, "blueprints:validate");
  assert.equal(byName.get("get_blueprint_book")?.readOnly, true);
  assert.equal(byName.get("get_blueprint_book")?.idempotent, true);
  // Removing or reordering members rewrites the stored list in place, so the
  // update tool announces a destructive worst case even though no blueprint
  // record is ever destroyed by it.
  assert.equal(byName.get("update_blueprint_book")?.destructive, true);
  assert.equal(byName.get("update_blueprint_book")?.readOnly, false);
  assert.equal(byName.get("delete_blueprint_book")?.destructive, true);
  assert.equal(byName.get("delete_blueprint_book")?.idempotent, false);
  assert.equal(byName.get("delete_blueprint_book")?.capability, "blueprints:write");
  // The books surface must never grow a capability of its own.
  for (const name of [
    "create_blueprint_book",
    "get_blueprint_book",
    "update_blueprint_book",
    "delete_blueprint_book"
  ] as const) {
    assert.ok(["blueprints:write", "blueprints:validate"].includes(
      byName.get(name)?.capability as string
    ));
  }
});

test("a book is created by reference, never by payload", () => {
  assert.equal(
    CreateBlueprintBookInputSchema.safeParse({
      name: "Mall",
      blueprintIds: ["blueprint:1:1", "blueprint:1:2"]
    }).success,
    true
  );
  for (const rejected of [
    {},
    { name: "Mall" },
    { name: "", blueprintIds: ["blueprint:1:1"] },
    { name: "Mall", blueprintIds: [] },
    // The same blueprint twice makes every later edit ambiguous.
    { name: "Mall", blueprintIds: ["blueprint:1:1", "blueprint:1:1"] },
    { name: "Mall", blueprintIds: Array.from({ length: 51 }, (_, index) => `blueprint:1:${index}`) },
    // No layout may ever enter a book call: that is what keeps it small.
    { name: "Mall", blueprintIds: ["blueprint:1:1"], layout: validLayout() }
  ]) {
    assert.equal(CreateBlueprintBookInputSchema.safeParse(rejected).success, false);
  }
  assert.equal(GetBlueprintBookInputSchema.safeParse({ bookId: "book:1:9" }).success, true);
  assert.equal(GetBlueprintBookInputSchema.safeParse({ bookId: "book:1:9", delivery: "cursor" }).success, false);
  assert.equal(DeleteBlueprintBookInputSchema.safeParse({ bookId: "book:1:9" }).success, true);
  assert.equal(DeleteBlueprintBookInputSchema.safeParse({ blueprintId: "blueprint:1:9" }).success, false);
});

test("every book edit states exactly the fields its operation uses", () => {
  const bookId = "book:1:9";
  for (const accepted of [
    { bookId, operation: "rename", name: "Main bus" },
    { bookId, operation: "rename", description: "Left to right" },
    { bookId, operation: "add", blueprintIds: ["blueprint:1:3"] },
    { bookId, operation: "add", blueprintIds: ["blueprint:1:3"], position: 1 },
    { bookId, operation: "remove", blueprintIds: ["blueprint:1:3"] },
    { bookId, operation: "reorder", blueprintIds: ["blueprint:1:3", "blueprint:1:1"] }
  ]) {
    assert.equal(UpdateBlueprintBookInputSchema.safeParse(accepted).success, true, accepted.operation);
  }
  for (const rejected of [
    { bookId, operation: "rename" },
    { bookId, operation: "rename", blueprintIds: ["blueprint:1:3"] },
    { bookId, operation: "add" },
    { bookId, operation: "add", blueprintIds: ["blueprint:1:3"], name: "Main bus" },
    // position is an insertion point for add and means nothing elsewhere.
    { bookId, operation: "remove", blueprintIds: ["blueprint:1:3"], position: 1 },
    { bookId, operation: "reorder", blueprintIds: ["blueprint:1:3", "blueprint:1:3"] },
    { bookId, operation: "clear", blueprintIds: ["blueprint:1:3"] },
    { operation: "add", blueprintIds: ["blueprint:1:3"] }
  ]) {
    assert.equal(UpdateBlueprintBookInputSchema.safeParse(rejected).success, false, JSON.stringify(rejected));
  }
});

test("listing the inbox reports books unless they are explicitly excluded", () => {
  const listed = ListAiBlueprintsInputSchema.safeParse({});
  assert.equal(listed.success, true);
  assert.equal(listed.success && listed.data.includeBooks, true);
  assert.equal(ListAiBlueprintsInputSchema.safeParse({ includeBooks: false }).success, true);
  assert.equal(ListAiBlueprintsInputSchema.safeParse({ includeBooks: "no" }).success, false);
});

test("deleting a saved blueprint takes exactly one identifier", () => {
  assert.equal(
    DeleteAiBlueprintInputSchema.safeParse({ blueprintId: "blueprint:1:7" }).success,
    true
  );
  for (const rejected of [
    {},
    { blueprintId: "" },
    { blueprintId: 7 },
    { blueprintId: "blueprint:1:7", revision: 1 },
    { blueprintId: "blueprint:1:7", delivery: "cursor" }
  ]) {
    assert.equal(DeleteAiBlueprintInputSchema.safeParse(rejected).success, false);
  }
});
