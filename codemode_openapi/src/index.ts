import { createMcpHandler } from "agents/mcp";
import { openApiMcpServer } from "@cloudflare/codemode/mcp";
import { DynamicWorkerExecutor } from "@cloudflare/codemode";

type Env = {
  LOADER: unknown;
  OPENAPI_BASE_URL: string;
  INTERNAL_API_KEY?: string;
};

let cachedSpec: Record<string, unknown> | null = null;

function appendQuery(url: URL, query: Record<string, unknown> | undefined) {
  if (!query) return;

  for (const [key, value] of Object.entries(query)) {
    if (value === undefined || value === null) continue;

    if (Array.isArray(value)) {
      for (const item of value) {
        url.searchParams.append(key, String(item));
      }
    } else {
      url.searchParams.set(key, String(value));
    }
  }
}

async function fetchSpec(env: Env): Promise<Record<string, unknown>> {
  if (cachedSpec) return cachedSpec;

  const url = new URL("/openapi.json", env.OPENAPI_BASE_URL);
  const headers = new Headers();

  if (env.INTERNAL_API_KEY) {
    headers.set("x-internal-api-key", env.INTERNAL_API_KEY);
  }

  const res = await fetch(url.toString(), { headers });
  if (!res.ok) {
    throw new Error(`Failed to load OpenAPI spec: ${res.status} ${await res.text()}`);
  }

  cachedSpec = (await res.json()) as Record<string, unknown>;
  return cachedSpec;
}

function buildServer(spec: Record<string, unknown>, env: Env) {
  const executor = new DynamicWorkerExecutor({
    loader: env.LOADER as any,
  });

  return openApiMcpServer({
    spec,
    executor,
    request: async ({ method, path, query, body }) => {
      const url = new URL(path, env.OPENAPI_BASE_URL);
      appendQuery(url, query as Record<string, unknown> | undefined);

      const headers = new Headers({
        "content-type": "application/json",
      });

      if (env.INTERNAL_API_KEY) {
        headers.set("x-internal-api-key", env.INTERNAL_API_KEY);
      }

      const res = await fetch(url.toString(), {
        method,
        headers,
        body: body === undefined ? undefined : JSON.stringify(body),
      });

      const contentType = res.headers.get("content-type") || "";

      if (!res.ok) {
        const text = await res.text();
        throw new Error(`OpenAPI backend error ${res.status}: ${text}`);
      }

      if (contentType.includes("application/json")) {
        return await res.json();
      }

      return await res.text();
    },
  });
}

export default {
  async fetch(request: Request, env: Env, ctx: ExecutionContext) {
    const url = new URL(request.url);

    if (url.pathname === "/health") {
      return new Response("ok");
    }

    if (url.pathname !== "/mcp") {
      return new Response("Not found", { status: 404 });
    }

    const spec = await fetchSpec(env);
    const server = buildServer(spec, env);
    const handler = createMcpHandler(server);
    return handler(request, env, ctx);
  },
} satisfies ExportedHandler<Env>;
