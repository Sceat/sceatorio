import { once } from "node:events";
import { createServer, type IncomingMessage, type Server, type ServerResponse } from "node:http";

/**
 * `node:http` ↔ WHATWG `Request`/`Response`. The MCP SDK's HTTP handler is
 * fetch-shaped and its Node adapter is a separate package we deliberately do
 * not depend on, so this is the whole bridge: body ceiling, client address,
 * streaming responses (SSE), and nothing else.
 */

export interface HttpClient {
  /** Cloudflare-supplied client address when present, otherwise the socket peer. */
  ip: string;
}

export type WebHandler = (request: Request, client: HttpClient) => Promise<Response>;

export interface NodeBridgeOptions {
  maxBodyBytes?: number | undefined;
  headersTimeoutMs?: number | undefined;
  requestTimeoutMs?: number | undefined;
}

const DEFAULT_MAX_BODY_BYTES = 1024 * 1024;
const IP_PATTERN = /^[0-9a-fA-F:.]{1,45}$/u;
const BODYLESS_METHODS = new Set(["GET", "HEAD", "OPTIONS", "DELETE"]);

class BodyTooLargeError extends Error {}

export function createNodeServer(handler: WebHandler, options: NodeBridgeOptions = {}): Server {
  const maxBodyBytes = options.maxBodyBytes ?? DEFAULT_MAX_BODY_BYTES;
  const server = createServer((request, response) => {
    void serve(handler, request, response, maxBodyBytes);
  });
  server.headersTimeout = options.headersTimeoutMs ?? 15_000;
  server.requestTimeout = options.requestTimeoutMs ?? 30_000;
  return server;
}

async function serve(
  handler: WebHandler,
  incoming: IncomingMessage,
  outgoing: ServerResponse,
  maxBodyBytes: number
): Promise<void> {
  const controller = new AbortController();
  outgoing.on("close", () => {
    if (!outgoing.writableEnded) {
      controller.abort();
    }
  });

  let request: Request;
  try {
    request = await toWebRequest(incoming, maxBodyBytes, controller.signal);
  } catch (error) {
    respondPlain(outgoing, error instanceof BodyTooLargeError ? 413 : 400);
    return;
  }

  let response: Response;
  try {
    response = await handler(request, { ip: clientIp(incoming) });
  } catch {
    respondPlain(outgoing, 500);
    return;
  }
  await writeWebResponse(outgoing, response);
}

export async function toWebRequest(
  incoming: IncomingMessage,
  maxBodyBytes: number,
  signal?: AbortSignal
): Promise<Request> {
  const host = incoming.headers.host;
  if (host === undefined) {
    throw new Error("missing host header");
  }
  const url = new URL(incoming.url ?? "/", `http://${host}`);
  const method = incoming.method ?? "GET";
  const headers = new Headers();
  for (const [name, value] of Object.entries(incoming.headers)) {
    if (value === undefined || name.startsWith(":")) {
      continue;
    }
    for (const entry of Array.isArray(value) ? value : [value]) {
      headers.append(name, entry);
    }
  }

  const body = BODYLESS_METHODS.has(method) ? undefined : await readBody(incoming, maxBodyBytes);
  return new Request(url, {
    method,
    headers,
    ...(body === undefined || body.byteLength === 0 ? {} : { body }),
    ...(signal === undefined ? {} : { signal })
  });
}

export async function writeWebResponse(
  outgoing: ServerResponse,
  response: Response
): Promise<void> {
  const headers: Record<string, string | string[]> = {};
  response.headers.forEach((value, name) => {
    headers[name] = name === "set-cookie" ? [value] : value;
  });
  outgoing.writeHead(response.status, headers);
  if (response.body === null) {
    outgoing.end();
    return;
  }
  try {
    for await (const chunk of response.body as unknown as AsyncIterable<Uint8Array>) {
      if (!outgoing.write(chunk)) {
        await once(outgoing, "drain");
      }
    }
    outgoing.end();
  } catch {
    outgoing.destroy();
  }
}

function clientIp(incoming: IncomingMessage): string {
  const forwarded = incoming.headers["cf-connecting-ip"];
  const candidate = Array.isArray(forwarded) ? forwarded[0] : forwarded;
  if (typeof candidate === "string" && IP_PATTERN.test(candidate)) {
    return candidate;
  }
  return incoming.socket.remoteAddress ?? "unknown";
}

async function readBody(
  incoming: IncomingMessage,
  maxBodyBytes: number
): Promise<Uint8Array<ArrayBuffer>> {
  const chunks: Buffer[] = [];
  let size = 0;
  for await (const chunk of incoming) {
    const buffer = chunk as Buffer;
    size += buffer.byteLength;
    if (size > maxBodyBytes) {
      incoming.destroy();
      throw new BodyTooLargeError();
    }
    chunks.push(buffer);
  }
  return new Uint8Array(Buffer.concat(chunks));
}

function respondPlain(outgoing: ServerResponse, status: number): void {
  if (outgoing.headersSent || outgoing.writableEnded) {
    outgoing.destroy();
    return;
  }
  outgoing.writeHead(status, { "content-type": "application/json; charset=utf-8" });
  outgoing.end(`{"error":"${status === 413 ? "PAYLOAD_TOO_LARGE" : status === 400 ? "BAD_REQUEST" : "INTERNAL_ERROR"}"}`);
}
