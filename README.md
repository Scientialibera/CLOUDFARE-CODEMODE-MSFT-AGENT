# Azure Storage + Cloudflare Codemode + Microsoft Agent Framework

An integration that connects Azure Blob Storage to a Microsoft Agent Framework agent through Cloudflare's Codemode, demonstrating how an LLM agent can orchestrate storage operations by writing and executing code rather than calling tools one at a time.

## Architecture

```
FastAPI Storage API  ──>  Cloudflare Worker + Codemode  ──>  Microsoft Agent Framework
   (OpenAPI REST)           (openApiMcpServer → MCP)           (AzureOpenAIChatClient)
```

**Without Codemode:** the agent would see 8+ individual REST endpoints as separate tools.

**With Codemode:** the agent sees 2 compact tools (`search` + `execute`). It writes JavaScript to discover endpoints and chain API calls with logic, loops, and error handling — all executed in an isolated Worker sandbox.

## Components

### `storage_api/` — FastAPI OpenAPI facade

A REST API over Azure Blob Storage using `DefaultAzureCredential`. Endpoints:

- `GET /containers` — list containers
- `POST /containers` — create container
- `DELETE /containers/{name}` — delete container
- `GET /containers/{name}/blobs` — list blobs (with prefix/suffix filtering)
- `GET /containers/{name}/blobs/{path}/metadata` — blob properties
- `GET /containers/{name}/blobs/{path}/text` — download blob as text
- `PUT /containers/{name}/blobs/{path}/text` — upload text to blob
- `DELETE /containers/{name}/blobs/{path}` — delete blob
- `POST /blobs/copy` — copy blob

### `codemode_openapi/` — Cloudflare Worker bridge

Fetches the OpenAPI spec from the storage API and wraps it with `openApiMcpServer()`. This produces an MCP server with two tools:

- **`search`** — LLM writes JS to query the OpenAPI spec and find endpoints
- **`execute`** — LLM writes JS to call `codemode.request()` and chain API operations

Authentication stays on the host side (never enters the sandbox).

### `agent_app/` — Microsoft Agent Framework agent

Connects to Azure OpenAI (`gpt-5-mini`) and the Codemode MCP endpoint. The agent uses the wrapped tools to perform storage operations autonomously.

## Prerequisites

- **Azure CLI** — signed in (`az login`)
- **Node.js** >= 18
- **Python** >= 3.11
- **Wrangler** (installed as a dev dependency)
- **Azure RBAC** on your principal:
  - `Storage Blob Data Contributor` on the storage account
  - `Cognitive Services OpenAI User` on the Azure OpenAI resource

## Setup

### 1. Storage API

```bash
cd storage_api
python -m venv .venv
source .venv/bin/activate   # Windows: .venv\Scripts\activate
pip install -r requirements.txt
cp .env.example .env        # edit with your values
uvicorn app:app --host 0.0.0.0 --port 8001
```

### 2. Cloudflare Codemode bridge

```bash
cd codemode_openapi
npm install
```

Update `wrangler.jsonc` vars (`OPENAPI_BASE_URL`, `INTERNAL_API_KEY`) to match your storage API, then:

```bash
npm run dev    # local dev on port 8787
```

### 3. Agent app

```bash
cd agent_app
python -m venv .venv
source .venv/bin/activate   # Windows: .venv\Scripts\activate
pip install -r requirements.txt
cp .env.example .env        # edit with your values
python app.py
```

## Example prompts

```
> List all containers in the storage account.
> Find all blobs in "data" with prefix "contracts/nda-" ending in ".pdf"
> Upload this text to blob "notes/memo.txt" in container "data": Meeting at 3pm tomorrow.
> List all invoices from 2026 and tell me the total count.
> Copy blob "contracts/sow-project-alpha.pdf" to "archive/sow-project-alpha.pdf" in container "data"
```

## How Codemode works here

When the agent receives a storage task, it:

1. Calls the `search` tool — writes JS that queries the OpenAPI spec to find relevant endpoints
2. Calls the `execute` tool — writes JS that chains `codemode.request()` calls with conditionals, loops, and aggregation
3. The JS runs in an isolated Cloudflare Worker sandbox; tool calls are dispatched back to the host via Workers RPC
4. The host forwards requests to the FastAPI storage API with auth headers
5. Results flow back through Codemode to the agent

## Key implementation notes

- `AzureOpenAIChatClient` is used (Chat Completions API) rather than `AzureOpenAIResponsesClient` (Responses API requires additional RBAC for `responses/write`)
- `MCPStreamableHTTPTool` is initialized with `load_prompts=False` because the Codemode MCP server only exposes tools, not prompts
- A new `McpServer` instance is created per request in the Worker to avoid "already connected to transport" errors
- The OpenAPI spec is cached after first fetch for performance
