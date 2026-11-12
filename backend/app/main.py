"""Flowbeat 后端：手表每 2 分钟调一次 /v1/judge，结束时调一次 /v1/review。

本地运行：
    cd backend && uv run uvicorn app.main:app --host 0.0.0.0 --port 8000
"""

import logging
import os
import secrets

from fastapi import Depends, FastAPI, Header, HTTPException

from .providers import ProviderError, get_provider
from .schemas import JudgeRequest, Judgment, Review, ReviewRequest

logging.basicConfig(level=logging.INFO)

app = FastAPI(title="Flowbeat backend", version="0.1.0")
provider = get_provider()

# 简单的共享口令：防止别人知道地址后白嫖你的 API 额度。不设置就不校验（仅限本地开发）。
APP_TOKEN = os.getenv("FLOWBEAT_TOKEN")


def check_token(x_flowbeat_token: str | None = Header(default=None)):
    if APP_TOKEN and not secrets.compare_digest(x_flowbeat_token or "", APP_TOKEN):
        raise HTTPException(status_code=401, detail="bad token")


@app.get("/health")
def health():
    return {"ok": True, "provider": provider.name}


@app.post("/v1/judge", response_model=Judgment, dependencies=[Depends(check_token)])
async def judge(req: JudgeRequest):
    try:
        return await provider.judge(req)
    except ProviderError as e:
        raise HTTPException(status_code=e.status, detail=str(e))


@app.post("/v1/review", response_model=Review, dependencies=[Depends(check_token)])
async def review(req: ReviewRequest):
    try:
        return await provider.review(req)
    except ProviderError as e:
        raise HTTPException(status_code=e.status, detail=str(e))
