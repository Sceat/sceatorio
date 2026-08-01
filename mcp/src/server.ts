import {
  createMcpHandler,
  McpServer,
  type CallToolResult,
  type McpRequestContext,
  type RegisteredTool,
  type StandardSchemaWithJSON
} from "@modelcontextprotocol/server";
import type * as z from "zod/v4";

import {
  AuthorizationError,
  authorizeAccess,
  type AccessGrant
} from "./auth/authorize.js";
import {
  V1_TOOL_DEFINITIONS,
  surfaceIdFromInput,
  type ToolDefinition
} from "./catalog/tools.js";
import type { ServerPolicy } from "./domain/capabilities.js";
import {
  FactorioProtocolError,
  FactorioRemoteError,
  FactorioTimeoutError,
  FactorioTransportClosedError,
  type FactorioTransport
} from "./transport/factorio-transport.js";

export interface McpLogger {
  error(message: string, metadata?: Readonly<Record<string, unknown>>): void;
}

const NOOP_LOGGER: McpLogger = {
  error: () => undefined
};

export interface SceatorioMcpDependencies {
  factorio: FactorioTransport;
  policy: ServerPolicy;
  grant: AccessGrant;
  logger?: McpLogger | undefined;
  now?: (() => number) | undefined;
}

export interface SceatorioHttpDependencies
  extends Omit<SceatorioMcpDependencies, "grant"> {
  resolveGrant(context: McpRequestContext): AccessGrant | Promise<AccessGrant>;
}

export function createSceatorioMcpServer(dependencies: SceatorioMcpDependencies): McpServer {
  const server = new McpServer(
    { name: "sceatorio-factorio", version: "0.1.0" },
    { capabilities: { tools: {} } }
  );

  for (const definition of V1_TOOL_DEFINITIONS) {
    registerTool(server, definition, dependencies);
  }
  return server;
}

export function createSceatorioMcpHandler(dependencies: SceatorioHttpDependencies) {
  return createMcpHandler(async (context) =>
    createSceatorioMcpServer({
      factorio: dependencies.factorio,
      policy: dependencies.policy,
      grant: await dependencies.resolveGrant(context),
      ...(dependencies.logger === undefined ? {} : { logger: dependencies.logger }),
      ...(dependencies.now === undefined ? {} : { now: dependencies.now })
    })
  );
}

function registerTool<Schema extends z.ZodType & StandardSchemaWithJSON>(
  server: McpServer,
  definition: ToolDefinition<Schema>,
  dependencies: SceatorioMcpDependencies
): void {
  const registerValidatedTool = server.registerTool.bind(server) as unknown as (
    name: string,
    config: {
      description: string;
      inputSchema: StandardSchemaWithJSON;
      annotations: {
        readOnlyHint: boolean;
        destructiveHint: boolean;
        idempotentHint: boolean;
        openWorldHint: boolean;
      };
    },
    callback: (input: unknown) => Promise<CallToolResult>
  ) => RegisteredTool;

  registerValidatedTool(
    definition.name,
    {
      description: definition.description,
      inputSchema: definition.inputSchema,
      annotations: {
        readOnlyHint: definition.readOnly,
        destructiveHint: definition.destructive,
        idempotentHint: definition.idempotent,
        openWorldHint: definition.openWorld
      }
    },
    async (input) => executeTool(definition, definition.inputSchema.parse(input), dependencies)
  );
}

async function executeTool<Schema extends z.ZodType & StandardSchemaWithJSON>(
  definition: ToolDefinition<Schema>,
  input: z.output<Schema>,
  dependencies: SceatorioMcpDependencies
): Promise<CallToolResult> {
  const logger = dependencies.logger ?? NOOP_LOGGER;
  const nowMs = dependencies.now?.() ?? Date.now();
  const surfaceId = surfaceIdFromInput(input);

  try {
    authorizeAccess(
      dependencies.grant,
      dependencies.policy,
      definition.capability,
      {
        saveId: dependencies.grant.saveId,
        forceId: dependencies.grant.forceId,
        ...(surfaceId === undefined ? {} : { surfaceId })
      },
      nowMs
    );
    enforcePlayerPreferences(input, dependencies.grant);
    enforcePageBudget(input, dependencies.policy.maxPageSize);

    const requestedTimeout = definition.timeoutMs?.(input) ?? dependencies.policy.maxRequestTimeoutMs;
    if (requestedTimeout > dependencies.policy.maxRequestTimeoutMs) {
      throw new AuthorizationError(
        "REQUEST_BUDGET_EXCEEDED",
        `This operation needs a ${requestedTimeout} ms deadline; server policy allows ${dependencies.policy.maxRequestTimeoutMs} ms`
      );
    }
    const response = await dependencies.factorio.request(
      {
        operation: definition.operation,
        scope: {
          bindingId: dependencies.grant.bindingId,
          saveId: dependencies.grant.saveId,
          playerId: dependencies.grant.playerId,
          forceId: dependencies.grant.forceId,
          ...(surfaceId === undefined ? {} : { surfaceId })
        },
        payload: input
      },
      { timeoutMs: requestedTimeout }
    );

    if (!response.ok) {
      const remote = response.error;
      throw new FactorioRemoteError(
        remote?.code ?? "FACTORIO_ERROR",
        remote?.message ?? "Factorio rejected the request",
        remote?.retryable ?? false,
        remote?.details
      );
    }

    const result = {
      tick: response.tick,
      worldRevision: response.worldRevision,
      data: response.result ?? null
    };
    return {
      content: [{ type: "text" as const, text: JSON.stringify(result) }],
      structuredContent: result
    };
  } catch (error) {
    const publicError = toPublicError(error);
    if (publicError.code === "INTERNAL_ERROR") {
      logger.error("Unhandled MCP tool failure", {
        tool: definition.name,
        error: error instanceof Error ? error.message : String(error)
      });
    }
    return {
      isError: true,
      content: [{ type: "text" as const, text: JSON.stringify({ error: publicError }) }],
      structuredContent: { error: publicError }
    };
  }
}

function enforcePlayerPreferences(input: unknown, grant: AccessGrant): void {
  if (typeof input !== "object" || input === null || !("delivery" in input)) {
    return;
  }
  const delivery = (input as { delivery?: unknown }).delivery;
  if (delivery === "cursor" && grant.preferences.blueprintDelivery !== "allow-cursor") {
    throw new AuthorizationError(
      "PLAYER_PREFERENCE_DENIED",
      "This player allows blueprint delivery to the inbox only"
    );
  }
}

function enforcePageBudget(input: unknown, maxPageSize: number): void {
  if (typeof input !== "object" || input === null) {
    return;
  }
  const directLimit = "limit" in input ? (input as { limit?: unknown }).limit : undefined;
  const pagination = "pagination" in input
    ? (input as { pagination?: unknown }).pagination
    : undefined;
  const nestedLimit =
    typeof pagination === "object" && pagination !== null && "limit" in pagination
      ? (pagination as { limit?: unknown }).limit
      : undefined;
  for (const limit of [directLimit, nestedLimit]) {
    if (typeof limit === "number" && limit > maxPageSize) {
      throw new AuthorizationError(
        "REQUEST_BUDGET_EXCEEDED",
        `Server policy limits result pages to ${maxPageSize} records`
      );
    }
  }
}

function toPublicError(error: unknown): {
  code: string;
  message: string;
  retryable: boolean;
} {
  if (error instanceof AuthorizationError) {
    return { code: error.code, message: error.message, retryable: false };
  }
  if (error instanceof FactorioTimeoutError) {
    return { code: "FACTORIO_TIMEOUT", message: error.message, retryable: true };
  }
  if (error instanceof FactorioRemoteError) {
    return { code: error.code, message: error.message, retryable: error.retryable };
  }
  if (error instanceof FactorioProtocolError) {
    return { code: "FACTORIO_PROTOCOL_ERROR", message: error.message, retryable: false };
  }
  if (error instanceof FactorioTransportClosedError) {
    return { code: "FACTORIO_UNAVAILABLE", message: error.message, retryable: true };
  }
  return {
    code: "INTERNAL_ERROR",
    message: "The MCP server could not complete this request",
    retryable: false
  };
}
