from __future__ import annotations

import os
from typing import Any

from dotenv import load_dotenv
from fastapi import FastAPI, HTTPException, Query, Response
from pydantic import BaseModel, Field
from azure.core.exceptions import ResourceExistsError, ResourceNotFoundError
from azure.identity import DefaultAzureCredential
from azure.storage.blob import BlobServiceClient, ContentSettings

load_dotenv()

ACCOUNT_URL = os.getenv(
    "AZURE_STORAGE_ACCOUNT_URL",
    "https://myaiprojectdevdatalake.blob.core.windows.net/",
)

credential = DefaultAzureCredential()
blob_service = BlobServiceClient(account_url=ACCOUNT_URL, credential=credential)

app = FastAPI(
    title="Azure Storage OpenAPI",
    version="1.0.0",
    description=(
        "OpenAPI facade over Azure Blob Storage using DefaultAzureCredential. "
        "Designed to be wrapped by Cloudflare Codemode openApiMcpServer."
    ),
)


def get_container_client(container: str):
    return blob_service.get_container_client(container)


def get_blob_client(container: str, blob_name: str):
    return blob_service.get_blob_client(container=container, blob=blob_name)


def iso_or_none(value: Any) -> str | None:
    return value.isoformat() if value is not None else None


class CreateContainerRequest(BaseModel):
    name: str = Field(..., min_length=3, max_length=63)


class UploadTextRequest(BaseModel):
    text: str
    overwrite: bool = True
    content_type: str = "text/plain; charset=utf-8"


class CopyBlobRequest(BaseModel):
    source_container: str
    source_blob: str
    destination_container: str
    destination_blob: str
    overwrite: bool = False


@app.get("/health")
def health() -> dict[str, str]:
    return {"status": "ok"}


@app.get("/containers")
def list_containers(
    prefix: str | None = Query(default=None),
    limit: int = Query(default=100, ge=1, le=500),
) -> dict[str, Any]:
    containers = []
    for item in blob_service.list_containers(name_starts_with=prefix):
        containers.append(
            {
                "name": item["name"],
                "etag": item.get("etag"),
                "last_modified": iso_or_none(item.get("last_modified")),
                "public_access": item.get("public_access"),
                "has_immutability_policy": item.get("has_immutability_policy"),
                "has_legal_hold": item.get("has_legal_hold"),
            }
        )
        if len(containers) >= limit:
            break

    return {
        "account_url": ACCOUNT_URL,
        "count": len(containers),
        "containers": containers,
    }


@app.post("/containers")
def create_container(payload: CreateContainerRequest) -> dict[str, Any]:
    try:
        response = blob_service.create_container(payload.name)
        return {
            "ok": True,
            "name": payload.name,
            "etag": response.get("etag"),
            "last_modified": iso_or_none(response.get("last_modified")),
        }
    except ResourceExistsError:
        raise HTTPException(status_code=409, detail=f"Container '{payload.name}' already exists")


@app.delete("/containers/{container_name}")
def delete_container(container_name: str) -> Response:
    try:
        blob_service.delete_container(container_name)
        return Response(status_code=204)
    except ResourceNotFoundError:
        raise HTTPException(status_code=404, detail=f"Container '{container_name}' not found")


@app.get("/containers/{container_name}/blobs")
def list_blobs(
    container_name: str,
    prefix: str | None = Query(default=None),
    suffix: str | None = Query(default=None),
    include_metadata: bool = Query(default=False),
    limit: int = Query(default=200, ge=1, le=1000),
) -> dict[str, Any]:
    client = get_container_client(container_name)
    include = ["metadata"] if include_metadata else None

    blobs = []
    try:
        for item in client.list_blobs(name_starts_with=prefix, include=include):
            name = item["name"]
            if suffix and not name.endswith(suffix):
                continue

            blobs.append(
                {
                    "name": name,
                    "size": item.get("size"),
                    "etag": item.get("etag"),
                    "last_modified": iso_or_none(item.get("last_modified")),
                    "metadata": item.get("metadata") if include_metadata else None,
                    "content_type": (
                        getattr(item.get("content_settings"), "content_type", None)
                        if item.get("content_settings") is not None
                        else None
                    ),
                }
            )
            if len(blobs) >= limit:
                break
    except ResourceNotFoundError:
        raise HTTPException(status_code=404, detail=f"Container '{container_name}' not found")

    return {
        "container": container_name,
        "count": len(blobs),
        "blobs": blobs,
    }


@app.get("/containers/{container_name}/blobs/{blob_path:path}/metadata")
def get_blob_metadata(container_name: str, blob_path: str) -> dict[str, Any]:
    client = get_blob_client(container_name, blob_path)
    try:
        props = client.get_blob_properties()
    except ResourceNotFoundError:
        raise HTTPException(status_code=404, detail=f"Blob '{blob_path}' not found in '{container_name}'")

    return {
        "container": container_name,
        "blob_name": blob_path,
        "size": props.size,
        "etag": props.etag,
        "last_modified": iso_or_none(props.last_modified),
        "blob_type": str(props.blob_type),
        "content_type": props.content_settings.content_type if props.content_settings else None,
        "content_language": props.content_settings.content_language if props.content_settings else None,
        "content_encoding": props.content_settings.content_encoding if props.content_settings else None,
        "content_disposition": props.content_settings.content_disposition if props.content_settings else None,
        "metadata": props.metadata or {},
    }


@app.get("/containers/{container_name}/blobs/{blob_path:path}/text")
def download_blob_text(
    container_name: str,
    blob_path: str,
    max_bytes: int = Query(default=1_000_000, ge=1, le=10_000_000),
    encoding: str = Query(default="utf-8"),
) -> dict[str, Any]:
    client = get_blob_client(container_name, blob_path)
    try:
        downloader = client.download_blob(offset=0, length=max_bytes)
        data = downloader.readall()
    except ResourceNotFoundError:
        raise HTTPException(status_code=404, detail=f"Blob '{blob_path}' not found in '{container_name}'")

    return {
        "container": container_name,
        "blob_name": blob_path,
        "bytes_returned": len(data),
        "text": data.decode(encoding, errors="replace"),
    }


@app.put("/containers/{container_name}/blobs/{blob_path:path}/text")
def upload_blob_text(container_name: str, blob_path: str, payload: UploadTextRequest) -> dict[str, Any]:
    client = get_blob_client(container_name, blob_path)
    data = payload.text.encode("utf-8")

    result = client.upload_blob(
        data,
        overwrite=payload.overwrite,
        content_settings=ContentSettings(content_type=payload.content_type),
    )

    return {
        "ok": True,
        "container": container_name,
        "blob_name": blob_path,
        "etag": result.get("etag"),
        "last_modified": iso_or_none(result.get("last_modified")),
        "bytes_uploaded": len(data),
    }


@app.delete("/containers/{container_name}/blobs/{blob_path:path}")
def delete_blob(container_name: str, blob_path: str) -> Response:
    client = get_blob_client(container_name, blob_path)
    try:
        client.delete_blob(delete_snapshots="include")
        return Response(status_code=204)
    except ResourceNotFoundError:
        raise HTTPException(status_code=404, detail=f"Blob '{blob_path}' not found in '{container_name}'")


@app.post("/blobs/copy")
def copy_blob(payload: CopyBlobRequest) -> dict[str, Any]:
    source_client = get_blob_client(payload.source_container, payload.source_blob)
    destination_client = get_blob_client(payload.destination_container, payload.destination_blob)

    if not payload.overwrite:
        try:
            destination_client.get_blob_properties()
            raise HTTPException(
                status_code=409,
                detail=(
                    f"Destination blob '{payload.destination_blob}' already exists in "
                    f"'{payload.destination_container}'"
                ),
            )
        except ResourceNotFoundError:
            pass

    try:
        copy_result = destination_client.start_copy_from_url(source_client.url)
    except ResourceNotFoundError:
        raise HTTPException(
            status_code=404,
            detail=(
                f"Source blob '{payload.source_blob}' not found in "
                f"'{payload.source_container}'"
            ),
        )

    return {
        "ok": True,
        "source_container": payload.source_container,
        "source_blob": payload.source_blob,
        "destination_container": payload.destination_container,
        "destination_blob": payload.destination_blob,
        "copy_id": copy_result["copy_id"],
        "copy_status": copy_result["copy_status"],
    }
