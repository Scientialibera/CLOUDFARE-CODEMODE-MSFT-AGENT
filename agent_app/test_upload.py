from __future__ import annotations

import asyncio
import os

from dotenv import load_dotenv
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


async def main() -> None:
    endpoint = os.getenv(
        "AZURE_OPENAI_ENDPOINT",
        "https://myaiproject-dev-openai.openai.azure.com/",
    )
    deployment_name = os.getenv(
        "AZURE_OPENAI_RESPONSES_DEPLOYMENT_NAME",
        "gpt-5-mini",
    )
    codemode_mcp_url = os.environ["CODEMODE_MCP_URL"]

    async with (
        DefaultAzureCredential() as credential,
        MCPStreamableHTTPTool(
            name="azure-storage-codemode-openapi",
            url=codemode_mcp_url,
            load_prompts=False,
        ) as storage_tool,
    ):
        client = AzureOpenAIChatClient(
            endpoint=endpoint,
            deployment_name=deployment_name,
            credential=credential,
        )

        agent = client.as_agent(
            name="AzureStorageAgent",
            instructions=SYSTEM_PROMPT,
            tools=[storage_tool],
        )

        prompt = (
            'Upload this text to blob "notes/hello.txt" in container "data": '
            '"Hello from Agent Framework through Cloudflare Codemode!" '
            'Then read it back to confirm.'
        )
        print(f"Prompt: {prompt}\n")

        result = await agent.run(prompt)

        text = getattr(result, "text", None)
        print("=== Agent Response ===")
        print(text if text is not None else str(result))
        print("=== End Response ===")


if __name__ == "__main__":
    asyncio.run(main())
