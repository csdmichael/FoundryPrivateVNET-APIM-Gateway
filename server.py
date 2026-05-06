import json
import logging
import os
import time
from datetime import datetime, timezone
from pathlib import Path
from typing import Any
from uuid import uuid4

import httpx
from fastapi import FastAPI, HTTPException
from fastapi.middleware.cors import CORSMiddleware
from pydantic import BaseModel

import config


app = FastAPI(title="Foundry Private VNET Gateway API", version="1.0.0")

logging.basicConfig(level=os.environ.get("LOG_LEVEL", "INFO").upper())
logger = logging.getLogger("foundry_privatevnet_gateway")

_allowed_origins = [
    origin.strip()
    for origin in os.environ.get(
        "ALLOWED_ORIGINS",
        config.default_allowed_origins(),
    ).split(",")
    if origin.strip()
]

app.add_middleware(
    CORSMiddleware,
    allow_origins=_allowed_origins,
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)

SAMPLE_PROMPTS = config.prompts_config()["use_cases"]
DOCUMENTS = config.document_config()["use_cases"]
VALID_USE_CASES = set(config.VALID_USE_CASES)
FEEDBACK_DIR = Path(config.PROJECT_ROOT) / "docs" / "feedback"
FEEDBACK_DIR.mkdir(parents=True, exist_ok=True)


class ChatRequest(BaseModel):
    prompt: str
    use_case: str = "tax_pdf_forms"


class ChatResponse(BaseModel):
    prompt: str
    response: str
    use_case: str
    duration_ms: int
    sources: list[str]
    attempts: int
    ok: bool = True
    error: str | None = None
    trace_id: str | None = None


class BatchRequest(BaseModel):
    prompts: list[str]
    use_case: str = "tax_pdf_forms"


class BatchResultItem(BaseModel):
    prompt: str
    response: str
    duration_ms: int
    sources: list[str]
    passed: bool
    reason: str


class BatchResponse(BaseModel):
    use_case: str
    total: int
    passed: int
    failed: int
    accuracy_pct: float
    results: list[BatchResultItem]


class FeedbackRequest(BaseModel):
    query: str
    document_id: str
    relevant: bool
    score: float = 0.0
    notes: str = ""
    use_case: str = "tax_pdf_forms"


def _require_use_case(use_case: str) -> dict[str, Any]:
    if use_case not in VALID_USE_CASES:
        raise HTTPException(status_code=400, detail=f"Invalid use_case: {use_case}")
    return config.use_case_settings(use_case)


def _feedback_file(use_case: str) -> Path:
    return FEEDBACK_DIR / f"{use_case}.json"


def _load_feedback(use_case: str) -> list[dict[str, Any]]:
    path = _feedback_file(use_case)
    if not path.exists():
        return []
    return json.loads(path.read_text(encoding="utf-8"))


def _save_feedback(use_case: str, entries: list[dict[str, Any]]) -> None:
    _feedback_file(use_case).write_text(json.dumps(entries, indent=2), encoding="utf-8")


def _extract_sources(payload: Any) -> list[str]:
    if isinstance(payload, dict):
        for key in ("sources", "citations", "references"):
            value = payload.get(key)
            if isinstance(value, list):
                return [str(item) for item in value]
        if "data" in payload:
            return _extract_sources(payload["data"])
    if isinstance(payload, list):
        return [str(item) for item in payload]
    return []


def _extract_response_text(payload: Any) -> str:
    if isinstance(payload, str):
        return payload
    if isinstance(payload, list):
        for item in payload:
            text = _extract_response_text(item)
            if text:
                return text
        return ""
    if not isinstance(payload, dict):
        return ""

    for key in ("response", "answer", "output", "output_text", "content", "text"):
        value = payload.get(key)
        if isinstance(value, str) and value.strip():
            return value.strip()

    choices = payload.get("choices")
    if isinstance(choices, list) and choices:
        message = choices[0].get("message", {}) if isinstance(choices[0], dict) else {}
        content = message.get("content")
        if isinstance(content, str):
            return content.strip()
        if isinstance(content, list):
            for item in content:
                if isinstance(item, dict) and isinstance(item.get("text"), str):
                    return item["text"].strip()

    data = payload.get("data")
    if data is not None:
        return _extract_response_text(data)

    return ""


async def _invoke_agent(prompt: str, use_case: str) -> tuple[str, list[str]]:
    use_case_settings = _require_use_case(use_case)
    azure_settings = config.azure_resources()
    apim = azure_settings["apim"]

    gateway_url = os.environ.get("APIM_GATEWAY_URL", apim["gateway_url"]).rstrip("/")
    subscription_key = os.environ.get("APIM_SUBSCRIPTION_KEY", "")
    route_path = os.environ.get(
        f"{use_case.upper()}_APIM_PATH",
        use_case_settings["apim_agent_path"],
    )

    headers = {
        "Content-Type": "application/json",
        "Accept": "application/json",
    }
    if subscription_key:
        headers["Ocp-Apim-Subscription-Key"] = subscription_key

    body = {
        "prompt": prompt,
        "messages": [{"role": "user", "content": prompt}],
        "use_case": use_case,
        "agentName": use_case_settings["agent_name"],
        "foundryProjectEndpoint": azure_settings["foundry"]["project_endpoint"],
    }

    logger.info("Invoking agent for use_case=%s via %s", use_case, route_path)

    async with httpx.AsyncClient(timeout=60.0) as client:
        response = await client.post(f"{gateway_url}{route_path}", headers=headers, json=body)

    if response.status_code >= 400:
        logger.error(
            "APIM request failed for use_case=%s status=%s body=%s",
            use_case,
            response.status_code,
            response.text[:1000],
        )
        raise HTTPException(status_code=502, detail=f"APIM request failed: {response.status_code} {response.text}")

    try:
        payload = response.json() if response.content else {}
    except ValueError as exc:
        logger.exception("APIM returned non-JSON payload for use_case=%s", use_case)
        raise HTTPException(status_code=502, detail=f"APIM response was not valid JSON: {exc}") from exc

    text = _extract_response_text(payload)
    if not text:
        logger.error("APIM response did not contain agent content for use_case=%s payload=%s", use_case, json.dumps(payload)[:1000])
        raise HTTPException(status_code=502, detail="APIM response did not contain agent content")
    return text, _extract_sources(payload)


def _build_chat_error_response(req: ChatRequest, started_at: float, exc: HTTPException) -> ChatResponse:
    detail = exc.detail if isinstance(exc.detail, str) else json.dumps(exc.detail)
    trace_id = str(uuid4())
    duration = int((time.time() - started_at) * 1000)
    logger.error(
        "Teams chat request failed trace_id=%s use_case=%s prompt=%s detail=%s",
        trace_id,
        req.use_case,
        req.prompt[:200],
        detail,
    )
    return ChatResponse(
        prompt=req.prompt,
        response=f"Agent request failed. Trace ID: {trace_id}. Details: {detail}",
        use_case=req.use_case,
        duration_ms=duration,
        sources=[],
        attempts=1,
        ok=False,
        error=detail,
        trace_id=trace_id,
    )


async def _run_chat(req: ChatRequest, *, render_errors: bool) -> ChatResponse:
    _require_use_case(req.use_case)
    start = time.time()
    try:
        response_text, sources = await _invoke_agent(req.prompt, req.use_case)
    except HTTPException as exc:
        if render_errors:
            return _build_chat_error_response(req, start, exc)
        raise
    except Exception as exc:
        logger.exception("Unexpected Teams chat request failure for use_case=%s", req.use_case)
        wrapped_exc = HTTPException(status_code=502, detail=f"Unexpected upstream failure: {exc}")
        if render_errors:
            return _build_chat_error_response(req, start, wrapped_exc)
        raise wrapped_exc from exc

    duration = int((time.time() - start) * 1000)
    return ChatResponse(
        prompt=req.prompt,
        response=response_text,
        use_case=req.use_case,
        duration_ms=duration,
        sources=sources,
        attempts=1,
    )


@app.get("/api/health")
def health() -> dict[str, str]:
    return {"status": "ok"}


@app.get("/health")
def health_root() -> dict[str, str]:
    return health()


@app.get("/api/prompts")
def get_prompts(use_case: str = "tax_pdf_forms") -> dict[str, list[dict[str, str]]]:
    _require_use_case(use_case)
    return SAMPLE_PROMPTS[use_case]


@app.get("/prompts")
def get_prompts_root(use_case: str = "tax_pdf_forms") -> dict[str, list[dict[str, str]]]:
    return get_prompts(use_case)


@app.post("/api/chat", response_model=ChatResponse)
async def chat(req: ChatRequest) -> ChatResponse:
    return await _run_chat(req, render_errors=False)


@app.post("/chat", response_model=ChatResponse)
async def chat_root(req: ChatRequest) -> ChatResponse:
    return await _run_chat(req, render_errors=True)


@app.post("/api/batch", response_model=BatchResponse)
async def batch_run(req: BatchRequest) -> BatchResponse:
    _require_use_case(req.use_case)
    results: list[BatchResultItem] = []
    for prompt in req.prompts:
        start = time.time()
        try:
            response_text, sources = await _invoke_agent(prompt, req.use_case)
            passed = bool(response_text.strip())
            reason = "OK" if passed else "Empty response"
        except HTTPException as exc:
            response_text = exc.detail if isinstance(exc.detail, str) else json.dumps(exc.detail)
            sources = []
            passed = False
            reason = "APIM invocation failed"
        except Exception as exc:
            logger.exception("Unexpected batch invocation failure for use_case=%s", req.use_case)
            response_text = f"Unexpected upstream failure: {exc}"
            sources = []
            passed = False
            reason = "Unexpected invocation failure"
        duration = int((time.time() - start) * 1000)
        results.append(
            BatchResultItem(
                prompt=prompt,
                response=response_text,
                duration_ms=duration,
                sources=sources,
                passed=passed,
                reason=reason,
            )
        )

    passed_count = sum(1 for result in results if result.passed)
    total = len(results)
    accuracy_pct = round((passed_count / total * 100.0), 1) if total else 0.0
    return BatchResponse(
        use_case=req.use_case,
        total=total,
        passed=passed_count,
        failed=total - passed_count,
        accuracy_pct=accuracy_pct,
        results=results,
    )


@app.post("/batch", response_model=BatchResponse)
async def batch_run_root(req: BatchRequest) -> BatchResponse:
    return await batch_run(req)


@app.post("/api/feedback")
def submit_feedback(req: FeedbackRequest) -> dict[str, Any]:
    _require_use_case(req.use_case)
    entries = _load_feedback(req.use_case)
    entries.append(
        {
            "timestamp": datetime.now(timezone.utc).isoformat(),
            "query": req.query,
            "document_id": req.document_id,
            "relevant": req.relevant,
            "search_score": round(req.score, 4),
            "notes": req.notes,
        }
    )
    _save_feedback(req.use_case, entries)
    return {"status": "ok", "total_entries": len(entries)}


@app.get("/api/feedback")
def get_feedback(use_case: str = "tax_pdf_forms") -> list[dict[str, Any]]:
    _require_use_case(use_case)
    return _load_feedback(use_case)


@app.get("/api/documents")
def list_documents(use_case: str = "tax_pdf_forms") -> dict[str, Any]:
    use_case_settings = _require_use_case(use_case)
    documents = DOCUMENTS[use_case].get("sample_documents", [])
    return {
        "use_case": use_case,
        "label": use_case_settings["label"],
        "total": len(documents),
        "documents": documents,
    }
