"""Flowbeat 后端：手表每 2 分钟调一次 /v1/judge，结束时调一次 /v1/review。

本地运行：
    cd backend && uv run uvicorn app.main:app --env-file .env --host 0.0.0.0 --port 8765

可靠性设计（见 resilience.py）：
- 每次 LLM 调用有超时；超时 / 限流 / 5xx 会退避重试；最后还失败就按手表的规则分兜底，
  返回 200 + source="fallback"，手表照常显示，不会卡 30 秒后报错。
- 每个请求一行 JSON 日志：request_id、路径、状态码、耗时、结果来源。不记身体数据。
"""

import logging
import secrets
import time
import uuid
from contextlib import asynccontextmanager

from fastapi import Depends, FastAPI, Header, HTTPException, Request

from . import resilience
from .config import Settings
from .logs import setup_logging
from .providers import Provider, get_provider
from .schemas import JudgeRequest, Judgment, Review, ReviewRequest

VERSION = "0.2.0"
log = logging.getLogger("flowbeat")


@asynccontextmanager
async def lifespan(app: FastAPI):
    settings = Settings()
    settings.validate()          # 配置错了就启动失败，而不是带病运行
    setup_logging(settings.log_format)
    app.state.settings = settings
    app.state.provider = get_provider()
    if not settings.token:
        log.warning("FLOWBEAT_TOKEN is not set: auth disabled (local development only)")
    log.info("startup", extra={"provider": app.state.provider.name, "version": VERSION,
                               "llm_timeout_s": settings.llm_timeout_s, "llm_retries": settings.llm_retries})
    yield


app = FastAPI(title="Flowbeat backend", version=VERSION, lifespan=lifespan)


def get_settings(request: Request) -> Settings:
    return request.app.state.settings


def provider_dep(request: Request) -> Provider:
    return request.app.state.provider


def check_token(settings: Settings = Depends(get_settings),
                x_flowbeat_token: str | None = Header(default=None)) -> None:
    """共享口令：防止别人知道地址后白嫖 API 额度。compare_digest 防计时攻击。"""
    if settings.token and not secrets.compare_digest(x_flowbeat_token or "", settings.token):
        raise HTTPException(status_code=401, detail="bad token")


@app.middleware("http")
async def access_log(request: Request, call_next):
    rid = request.headers.get("x-request-id") or uuid.uuid4().hex[:12]
    request.state.request_id = rid
    request.state.log = {}
    t0 = time.perf_counter()
    status = 500
    try:
        response = await call_next(request)
        status = response.status_code
        response.headers["X-Request-ID"] = rid
        return response
    finally:
        log.info("request", extra={"request_id": rid, "method": request.method, "path": request.url.path,
                                   "status": status, "latency_ms": int((time.perf_counter() - t0) * 1000),
                                   **request.state.log})


@app.get("/healthz")
def healthz(request: Request):
    """存活探针（Docker HEALTHCHECK / Cloud Run）。不调用 LLM，不需要口令。"""
    return {"status": "ok", "provider": request.app.state.provider.name, "version": VERSION}


@app.get("/health")
def health(request: Request):
    """旧接口，保留兼容。"""
    return {"ok": True, "provider": request.app.state.provider.name}


@app.post("/v1/judge", response_model=Judgment, dependencies=[Depends(check_token)])
async def judge(req: JudgeRequest, request: Request, provider: Provider = Depends(provider_dep),
                settings: Settings = Depends(get_settings)):
    out = await resilience.call_with_retry(lambda: provider.judge(req), settings, "judge")
    result = out.value or resilience.fallback_judgment(req.window)
    request.state.log.update(op="judge", provider=provider.name, source=result.source, attempts=out.attempts,
                             llm_ms=out.latency_ms, examples=len(req.examples), error=out.error)
    return result


@app.post("/v1/review", response_model=Review, dependencies=[Depends(check_token)])
async def review(req: ReviewRequest, request: Request, provider: Provider = Depends(provider_dep),
                 settings: Settings = Depends(get_settings)):
    out = await resilience.call_with_retry(lambda: provider.review(req), settings, "review")
    result = out.value or resilience.fallback_review(req)
    request.state.log.update(op="review", provider=provider.name, source=result.source, attempts=out.attempts,
                             llm_ms=out.latency_ms, error=out.error)
    return result
