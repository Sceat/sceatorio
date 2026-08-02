import assert from "node:assert/strict";
import test from "node:test";

import {
  BlueprintEntitySchema,
  BlueprintLayoutSchema,
  MAX_BLUEPRINT_LAYOUT_BYTES
} from "../src/catalog/schemas.js";

function entity(extra: Record<string, unknown> = {}): Record<string, unknown> {
  return {
    entityNumber: 1,
    prototype: "assembling-machine-3",
    position: { x: 0, y: 0 },
    ...extra
  };
}

function layoutOf(entities: Record<string, unknown>[]): Record<string, unknown> {
  return {
    name: "Expressiveness fixture",
    description: "",
    entities,
    tiles: [],
    expectedOutputs: []
  };
}

test("module requests accept the author-friendly item map", () => {
  const parsed = BlueprintEntitySchema.safeParse(
    entity({ recipe: "electronic-circuit", items: { "productivity-module-3": 4 } })
  );
  assert.equal(parsed.success, true);

  // Prototype existence and module legality are Factorio's call; the wire schema
  // only has to agree on the shape.
  assert.equal(
    BlueprintEntitySchema.safeParse(entity({ items: { "productivity-module-3": 0 } })).success,
    false,
    "a zero module count is not a request"
  );
  assert.equal(
    BlueprintEntitySchema.safeParse(entity({ items: { "iron-plate": 2.5 } })).success,
    false,
    "module counts are integers"
  );
  assert.equal(
    BlueprintEntitySchema.safeParse(
      entity({
        items: Object.fromEntries(
          Array.from({ length: 9 }, (_, index) => [`module-${index}`, 1])
        )
      })
    ).success,
    false,
    "at most 8 distinct module prototypes per entity"
  );
});

test("filters, splitter priorities and logistic requests are expressible and bounded", () => {
  assert.equal(
    BlueprintEntitySchema.safeParse(
      entity({
        prototype: "fast-inserter",
        filterMode: "whitelist",
        filters: [{ name: "iron-plate" }, { name: "copper-plate", quality: "uncommon" }]
      })
    ).success,
    true
  );
  assert.equal(
    BlueprintEntitySchema.safeParse(
      entity({ prototype: "splitter", inputPriority: "left", outputPriority: "right" })
    ).success,
    true
  );
  assert.equal(
    BlueprintEntitySchema.safeParse(
      entity({ prototype: "splitter", inputPriority: "middle" })
    ).success,
    false,
    "splitter priority is left, right or none"
  );

  const oversized = entity({
    prototype: "fast-inserter",
    filters: Array.from({ length: 33 }, () => ({ name: "iron-plate" }))
  });
  assert.equal(
    BlueprintEntitySchema.safeParse(oversized).success,
    false,
    "filter lists are bounded at 32 slots"
  );

  assert.equal(
    BlueprintEntitySchema.safeParse(
      entity({
        prototype: "requester-chest",
        requestFromBuffers: true,
        requestFilters: [{ name: "iron-plate", min: 200, max: 400 }]
      })
    ).success,
    true
  );
  assert.equal(
    BlueprintEntitySchema.safeParse(
      entity({
        prototype: "requester-chest",
        requestFilters: [{ name: "iron-plate", min: 400, max: 200 }]
      })
    ).success,
    false,
    "a request maximum below its minimum is rejected"
  );
  assert.equal(
    BlueprintEntitySchema.safeParse(
      entity({ prototype: "requester-chest", requestFromBuffers: true })
    ).success,
    false,
    "requestFromBuffers without requestFilters is meaningless"
  );
  assert.equal(
    BlueprintEntitySchema.safeParse(
      entity({
        prototype: "requester-chest",
        requestFilters: Array.from({ length: 41 }, () => ({ name: "iron-plate" }))
      })
    ).success,
    false,
    "request filter lists are bounded at 40 entries"
  );
});

test("control behavior covers conditions, combinators and read modes", () => {
  assert.equal(
    BlueprintEntitySchema.safeParse(
      entity({
        prototype: "fast-inserter",
        control: {
          enabledCondition: {
            firstSignal: { type: "item", name: "iron-plate" },
            comparator: "<",
            constant: 100
          },
          readContents: true,
          readMode: "hold",
          setStackSize: true,
          stackSizeSignal: { type: "virtual", name: "signal-S" }
        }
      })
    ).success,
    true
  );
  assert.equal(
    BlueprintEntitySchema.safeParse(
      entity({
        prototype: "arithmetic-combinator",
        control: {
          arithmetic: {
            firstSignal: { type: "item", name: "iron-plate" },
            operation: "*",
            secondConstant: 3,
            outputSignal: { type: "virtual", name: "signal-A" }
          }
        }
      })
    ).success,
    true
  );
  assert.equal(
    BlueprintEntitySchema.safeParse(
      entity({
        prototype: "arithmetic-combinator",
        control: {
          arithmetic: {
            firstSignal: { type: "item", name: "iron-plate" },
            operation: "**",
            outputSignal: { type: "virtual", name: "signal-A" }
          }
        }
      })
    ).success,
    false,
    "unknown arithmetic operators are rejected"
  );
  assert.equal(
    BlueprintEntitySchema.safeParse(
      entity({
        prototype: "arithmetic-combinator",
        control: { arithmetic: { operation: "+", firstConstant: 1, secondConstant: 2 } }
      })
    ).success,
    false,
    "an arithmetic combinator needs an output signal"
  );
  assert.equal(
    BlueprintEntitySchema.safeParse(
      entity({
        prototype: "decider-combinator",
        control: {
          decider: {
            conditions: [
              {
                firstSignal: { type: "virtual", name: "signal-A" },
                comparator: ">=",
                constant: 10
              }
            ],
            outputs: [
              { signal: { type: "virtual", name: "signal-green" }, copyCountFromInput: false, constant: 1 }
            ]
          }
        }
      })
    ).success,
    true
  );
  assert.equal(
    BlueprintEntitySchema.safeParse(
      entity({
        prototype: "decider-combinator",
        control: { decider: { conditions: [], outputs: [] } }
      })
    ).success,
    false,
    "a decider needs at least one condition and one output"
  );
  assert.equal(
    BlueprintEntitySchema.safeParse(
      entity({
        prototype: "constant-combinator",
        control: {
          sections: [
            {
              active: true,
              filters: [
                { type: "item", name: "iron-plate", count: 100 },
                { type: "virtual", name: "signal-B", count: -3 }
              ]
            }
          ]
        }
      })
    ).success,
    true
  );
  assert.equal(
    BlueprintEntitySchema.safeParse(
      entity({
        prototype: "constant-combinator",
        control: { sections: [{ filters: [{ type: "recipe", name: "iron-gear-wheel", count: 1 }] }] }
      })
    ).success,
    false,
    "signal types are limited to item, fluid and virtual"
  );
});

test("the strict schema still rejects unknown keys and arbitrary settings blobs", () => {
  assert.equal(
    BlueprintEntitySchema.safeParse(entity({ settings: { anything: true } })).success,
    false,
    "the arbitrary settings escape hatch is gone"
  );
  assert.equal(
    BlueprintEntitySchema.safeParse(entity({ tags: { smuggled: "payload" } })).success,
    false
  );
  assert.equal(
    BlueprintEntitySchema.safeParse(
      entity({ control: { enabledCondition: { firstSignal: { type: "item", name: "iron-plate", extra: 1 } } } })
    ).success,
    false,
    "nested control objects are strict too"
  );
});

test("layouts that could not fit the gateway datagram are rejected before sending", () => {
  const fits = layoutOf(
    Array.from({ length: 200 }, (_, index) => ({
      entityNumber: index + 1,
      prototype: "transport-belt",
      position: { x: index % 32, y: Math.floor(index / 32) }
    }))
  );
  assert.equal(BlueprintLayoutSchema.safeParse(fits).success, true);

  const tooManyEntities = layoutOf(
    Array.from({ length: 401 }, (_, index) => ({
      entityNumber: index + 1,
      prototype: "transport-belt",
      position: { x: index % 32, y: Math.floor(index / 32) }
    }))
  );
  assert.equal(BlueprintLayoutSchema.safeParse(tooManyEntities).success, false);

  // Within the entity count but over the byte budget: 400 richly configured
  // machines are a legal shape that no 48 KiB datagram could ever carry.
  const tooManyBytes = layoutOf(
    Array.from({ length: 400 }, (_, index) => ({
      entityNumber: index + 1,
      prototype: "assembling-machine-3",
      position: { x: index % 32, y: Math.floor(index / 32) },
      recipe: "electronic-circuit",
      items: { "productivity-module-3": 4 },
      control: {
        enabledCondition: {
          firstSignal: { type: "item", name: "electronic-circuit" },
          comparator: "<",
          constant: 1000
        }
      }
    }))
  );
  const parsed = BlueprintLayoutSchema.safeParse(tooManyBytes);
  assert.equal(parsed.success, false);
  assert.ok(
    new TextEncoder().encode(JSON.stringify(tooManyBytes)).byteLength >
      MAX_BLUEPRINT_LAYOUT_BYTES
  );
});
