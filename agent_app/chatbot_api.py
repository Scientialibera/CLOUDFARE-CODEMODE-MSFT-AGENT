from __future__ import annotations

import os
import uuid
from contextlib import asynccontextmanager
from datetime import datetime, timezone
from typing import Any

from dotenv import load_dotenv
from fastapi import FastAPI, HTTPException
from pydantic import BaseModel, Field

from azure.identity.aio import DefaultAzureCredential
from agent_framework import MCPStreamableHTTPTool
from agent_framework.azure import AzureOpenAIChatClient

load_dotenv()

SYSTEM_PROMPT = """
You are an Azure Storage operations agent.

The storage system is available through a Codemode-wrapped OpenAPI MCP endpoint.
Use it whenever the user asks for storage operations.

Guidelines:
- Prefer using the available MCP tool rather than guessing.
- For listing tasks, include container and blob names.
- For text reads, clearly state if content was truncated.
- Do not invent containers, blobs, metadata, or operation results.
- When writing or deleting data, summarize exactly what changed.
- Blob names may contain slashes; preserve them exactly.
""".strip()

chats: dict[str, list[dict[str, Any]]] = {}

credential: DefaultAzureCredential | None = None
storage_tool: MCPStreamableHTTPTool | None = None
client: AzureOpenAIChatClient | None = None


@asynccontextmanager
async def lifespan(app: FastAPI):
    global credential, storage_tool, client

    endpoint = os.getenv(
        "AZURE_OPENAI_ENDPOINT",
        "https://myaiproject-dev-openai.openai.azure.com/",
    )
    deployment_name = os.getenv(
        "AZURE_OPENAI_RESPONSES_DEPLOYMENT_NAME",
        "gpt-5-mini",
    )
    codemode_mcp_url = os.environ["CODEMODE_MCP_URL"]

    credential = DefaultAzureCredential()
    storage_tool = MCPStreamableHTTPTool(
        name="azure-storage-codemode-openapi",
        url=codemode_mcp_url,
        load_prompts=False,
    )
    await storage_tool.__aenter__()

    client = AzureOpenAIChatClient(
        endpoint=endpoint,
        deployment_name=deployment_name,
        credential=credential,
    )

    yield

    if storage_tool:
        await storage_tool.__aexit__(None, None, None)
    if credential:
        await credential.__aexit__(None, None, None)


app = FastAPI(
    title="Azure Storage Chatbot API",
    version="1.0.0",
    description="Chat-based interface to Azure Storage via Cloudflare Codemode + Microsoft Agent Framework.",
    lifespan=lifespan,
)


class ChatRequest(BaseModel):
    message: str
    chat_id: str | None = Field(
        default=None,
        description="Existing chat ID to continue a conversation. Omit to start a new chat.",
    )


class ChatResponse(BaseModel):
    chat_id: str
    reply: str
    created_at: str


class ChatSummary(BaseModel):
    chat_id: str
    message_count: int
    last_message_at: str
    preview: str


@app.get("/health")
def health() -> dict[str, str]:
    return {"status": "ok"}


@app.post("/chat", response_model=ChatResponse)
async def chat(req: ChatRequest) -> ChatResponse:
    if client is None or storage_tool is None:
        raise HTTPException(status_code=503, detail="Agent not initialized")

    chat_id = req.chat_id or str(uuid.uuid4())

    if chat_id not in chats:
        chats[chat_id] = []

    now = datetime.now(timezone.utc).isoformat()
    chats[chat_id].append({"role": "user", "content": req.message, "timestamp": now})

    agent = client.as_agent(
        name="AzureStorageAgent",
        instructions=SYSTEM_PROMPT,
        tools=[storage_tool],
    )

    history_text = "\n".join(
        f"{m['role']}: {m['content']}" for m in chats[chat_id][:-1]
    )
    prompt = req.message
    if history_text:
        prompt = f"Conversation so far:\n{history_text}\n\nUser: {req.message}"

    result = await agent.run(prompt)
    reply = getattr(result, "text", None) or str(result)

    chats[chat_id].append({"role": "assistant", "content": reply, "timestamp": now})

    return ChatResponse(chat_id=chat_id, reply=reply, created_at=now)


@app.get("/chats", response_model=list[ChatSummary])
def list_chats() -> list[ChatSummary]:
    summaries = []
    for cid, messages in chats.items():
        if not messages:
            continue
        last = messages[-1]
        preview = last["content"][:120] + ("..." if len(last["content"]) > 120 else "")
        summaries.append(
            ChatSummary(
                chat_id=cid,
                message_count=len(messages),
                last_message_at=last["timestamp"],
                preview=preview,
            )
        )
    return summaries


@app.get("/chats/{chat_id}")
def get_chat(chat_id: str) -> dict[str, Any]:
    if chat_id not in chats:
        raise HTTPException(status_code=404, detail="Chat not found")
    return {"chat_id": chat_id, "messages": chats[chat_id]}


@app.delete("/chats/{chat_id}")
def delete_chat(chat_id: str) -> dict[str, str]:
    if chat_id not in chats:
        raise HTTPException(status_code=404, detail="Chat not found")
    del chats[chat_id]
    return {"status": "deleted", "chat_id": chat_id}
