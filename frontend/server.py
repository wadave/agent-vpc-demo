# Copyright 2026 Google LLC
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

"""Frontend proxy server for the chatbot UI.

Serves static files and proxies API requests to the backend Cloud Run service
with OIDC identity token authentication.
"""

import logging
import os
import re
from pathlib import Path

import google.auth.transport.requests
import google.oauth2.id_token
import httpx
from fastapi import FastAPI, HTTPException, Request
from fastapi.responses import HTMLResponse, StreamingResponse
from fastapi.staticfiles import StaticFiles

logging.basicConfig(level=logging.INFO)
logger = logging.getLogger(__name__)

BACKEND_URL = os.environ.get("BACKEND_URL", "http://localhost:8000")
STATIC_DIR = Path(__file__).parent / "static"

# Reusable auth request object (enables token caching)
_auth_request = google.auth.transport.requests.Request()

# Validate IDs to prevent path traversal / injection
_SAFE_ID_RE = re.compile(r"^[a-zA-Z0-9_\-]{1,128}$")

app = FastAPI(title="agent-starter-adk-cr-frontend")


def _validate_id(value: str, name: str) -> str:
    """Validate that an ID is safe for use in URL paths."""
    if not _SAFE_ID_RE.match(value):
        raise HTTPException(status_code=400, detail=f"Invalid {name}")
    return value


def _is_local_backend() -> bool:
    return (
        "localhost" in BACKEND_URL
        or "127.0.0.1" in BACKEND_URL
        or "backend" in BACKEND_URL
    )


def _get_auth_headers() -> dict[str, str]:
    """Get OIDC identity token for backend Cloud Run service-to-service auth.

    In local development (BACKEND_URL=localhost), returns empty headers.
    In production, raises HTTPException(503) on auth failure.
    """
    if _is_local_backend():
        return {}
    try:
        token = google.oauth2.id_token.fetch_id_token(_auth_request, BACKEND_URL)
        return {"Authorization": f"Bearer {token}"}
    except Exception:
        logger.exception("Failed to fetch identity token")
        raise HTTPException(
            status_code=503, detail="Authentication service unavailable"
        ) from None


@app.post("/api/sessions")
async def create_session(request: Request) -> dict:
    """Proxy session creation to the backend."""
    body = await request.json()
    user_id = _validate_id(body.get("user_id", "default_user"), "user_id")
    state = body.get("state", {})
    url = f"{BACKEND_URL}/apps/backend/users/{user_id}/sessions"
    async with httpx.AsyncClient(timeout=30) as client:
        resp = await client.post(
            url, json={"state": state}, headers=_get_auth_headers()
        )
        if not resp.is_success:
            raise HTTPException(status_code=resp.status_code, detail=resp.text)
        return resp.json()


@app.post("/api/chat")
async def chat(request: Request) -> StreamingResponse:
    """Proxy chat requests to the backend and stream SSE responses."""
    body = await request.json()

    # Validate IDs to prevent injection
    user_id = _validate_id(body.get("user_id", ""), "user_id")
    session_id = _validate_id(body.get("session_id", ""), "session_id")

    # Build a sanitized payload — don't blindly forward arbitrary fields
    payload = {
        "app_name": "backend",
        "user_id": user_id,
        "session_id": session_id,
        "new_message": body.get("new_message", {}),
        "streaming": True,
    }

    url = f"{BACKEND_URL}/run_sse"
    headers = {**_get_auth_headers(), "Content-Type": "application/json"}

    # Open the streaming connection and check status BEFORE returning
    # StreamingResponse, so errors propagate as proper HTTP status codes.
    client = httpx.AsyncClient(timeout=httpx.Timeout(300, connect=10))
    try:
        resp = await client.send(
            client.build_request("POST", url, json=payload, headers=headers),
            stream=True,
        )
    except Exception:
        await client.aclose()
        raise HTTPException(status_code=502, detail="Backend unavailable") from None

    if not resp.is_success:
        error_body = await resp.aread()
        await resp.aclose()
        await client.aclose()
        raise HTTPException(status_code=resp.status_code, detail=error_body.decode())

    async def stream():
        try:
            async for line in resp.aiter_lines():
                yield line + "\n"
        finally:
            await resp.aclose()
            await client.aclose()

    return StreamingResponse(stream(), media_type="text/event-stream")


@app.post("/api/feedback")
async def feedback(request: Request) -> dict:
    """Proxy feedback to the backend."""
    body = await request.json()
    url = f"{BACKEND_URL}/feedback"
    async with httpx.AsyncClient(timeout=10) as client:
        resp = await client.post(url, json=body, headers=_get_auth_headers())
        if not resp.is_success:
            raise HTTPException(status_code=resp.status_code, detail=resp.text)
        return resp.json()


# Serve static files
app.mount("/static", StaticFiles(directory=str(STATIC_DIR)), name="static")


@app.get("/{path:path}")
async def serve_spa(path: str) -> HTMLResponse:
    """Serve the single-page chat UI for all non-API routes."""
    if path.startswith("api/"):
        raise HTTPException(status_code=404, detail="Not found")
    index = STATIC_DIR / "index.html"
    return HTMLResponse(index.read_text())


if __name__ == "__main__":
    import uvicorn

    uvicorn.run(app, host="0.0.0.0", port=int(os.getenv("PORT", "8081")))
