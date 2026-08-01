import assert from "node:assert/strict";
import test from "node:test";

import {
  BlueprintLayoutSchema,
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
  assert.equal(V1_TOOL_NAMES.length, 24);
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
});
