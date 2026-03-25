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

- `app.py` — interactive CLI for local testing
- `chatbot_api.py` — FastAPI web API with chat session management (used for deployment)

### `deploy/` — Azure deployment scripts

Imperative `az` CLI scripts to provision and deploy everything to Azure:

- `deploy.ps1` — provisions Storage Account, Azure OpenAI (with model deployment), App Service Plan, 2 Web Apps, RBAC; generates `.env` files for all components
- `deploy-apps.ps1` — zip-deploys code to both App Services
- `upload-dummy-data.ps1` — generates and uploads sample PDFs to storage

## Prerequisites

- **Azure CLI** — signed in (`az login`)
- **Node.js** >= 18
- **Python** >= 3.11
- **Wrangler** (installed as a dev dependency)

## Setup

### Option A: Automated (recommended)

Run `deploy/deploy.ps1` — it provisions all Azure resources and generates `.env` files for every component automatically. See [Azure Deployment](#azure-deployment) below.

### Option B: Manual local setup

#### 1. Storage API

```bash
cd storage_api
python -m venv .venv
source .venv/bin/activate   # Windows: .venv\Scripts\activate
pip install -r requirements.txt
cp .env.example .env        # edit with your values
uvicorn app:app --host 0.0.0.0 --port 8001
```

#### 2. Cloudflare Codemode bridge

```bash
cd codemode_openapi
npm install
```

Update `wrangler.jsonc` vars (`OPENAPI_BASE_URL`, `INTERNAL_API_KEY`) to match your storage API, then:

```bash
npm run dev    # local dev on port 8787
```

#### 3. Agent app

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

## Azure Deployment

Deploy everything to Azure with three scripts:

```powershell
cd deploy
cp deploy.config.example.toml deploy.config.toml   # edit with your values

# 1. Provision all infrastructure + generate .env files
.\deploy.ps1

# 2. Deploy code to App Services
.\deploy-apps.ps1

# 3. Upload sample test data
.\upload-dummy-data.ps1

# 4. Deploy Cloudflare Worker (separate)
cd ..\codemode_openapi && npx wrangler deploy
```

**What gets created:**

| Resource | Purpose |
|---|---|
| Storage Account (Data Lake Gen2) | Blob storage for the API |
| Azure OpenAI + model deployment | LLM for the chatbot agent |
| App Service Plan (Linux B1) | Shared plan for both web apps |
| Web App: storage API | FastAPI OpenAPI facade over storage |
| Web App: chatbot API | Agent Framework chatbot with chat sessions |
| RBAC assignments | Managed identity access to storage + OpenAI |

**What is NOT created** (runs externally on Cloudflare):
- Cloudflare Worker — deployed separately via `npx wrangler deploy`

**Generated `.env` files** (after `deploy.ps1`):

| File | Contents |
|---|---|
| `storage_api/.env` | `AZURE_STORAGE_ACCOUNT_URL` |
| `agent_app/.env` | `AZURE_OPENAI_ENDPOINT`, deployment name, `CODEMODE_MCP_URL` |
| `codemode_openapi/.dev.vars` | `OPENAPI_BASE_URL` |

### Chatbot API endpoints

Once deployed, the chatbot API exposes:

- `POST /chat` — send a message (optionally with `chat_id` to continue a conversation)
- `GET /chats` — list active chat sessions
- `GET /chats/{chat_id}` — get full chat history
- `DELETE /chats/{chat_id}` — delete a chat session
- `GET /docs` — Swagger UI

If a `chat_id` is provided but not found (expired or invalid), the API creates a new session and returns `"new_session": true` — it never fails on a missing chat.

Chat sessions are automatically flushed after 24 hours of inactivity (configurable via `CHAT_TTL_HOURS` env var) to prevent memory growth on the App Service.

## Key implementation notes

- `AzureOpenAIChatClient` is used (Chat Completions API) rather than `AzureOpenAIResponsesClient` (Responses API requires additional RBAC for `responses/write`)
- `MCPStreamableHTTPTool` is initialized with `load_prompts=False` because the Codemode MCP server only exposes tools, not prompts
- A new `McpServer` instance is created per request in the Worker to avoid "already connected to transport" errors
- The OpenAPI spec is cached after first fetch for performance
- In-memory chat sessions are evicted after 24h via a background asyncio task
