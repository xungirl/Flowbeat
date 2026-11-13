"""后端加固：校验、口令、超时 / 重试 / 兜底、结构化日志、/healthz、和 Swift 的字段契约。
全部用假的 provider，不调用真模型。"""

import asyncio
import json
import logging
from pathlib import Path

import pytest

from app import resilience
from app.config import Settings
from app.logs import JsonFormatter
from app.main import app
from app.providers import FakeProvider, ProviderError
from app.schemas import Judgment, JudgeRequest, Review, ReviewRequest, WindowSummary

from .conftest import WINDOW

CONTRACT = Path(__file__).resolve().parents[2] / "FlowbeatCore/Tests/FlowbeatCoreTests/Fixtures/contract_fields.json"


class ScriptedProvider:
    """按脚本依次「失败 / 超时 / 成功」，并记录被调用了几次。"""

    name = "scripted"

    def __init__(self, *steps):
        self.steps = list(steps)
        self.calls = 0

    async def _next(self, ok):
        self.calls += 1
        step = self.steps.pop(0) if self.steps else "ok"
        if step == "slow":
            await asyncio.sleep(5)
        elif isinstance(step, ProviderError):
            raise step
        elif isinstance(step, Exception):
            raise step
        return ok

    async def judge(self, req, include_rule_score=None):
        return await self._next(Judgment(state="focused", score=77, reason="模型判断", source="llm"))

    async def review(self, req):
        return await self._next(Review(summary="s", tip="t", source="llm"))


# ---------- /healthz ----------

def test_healthz(client):
    r = client.get("/healthz")
    assert r.status_code == 200
    assert r.json() == {"status": "ok", "provider": "fake", "version": "0.2.0"}


def test_healthz_does_not_need_token(client):
    app.state.settings.token = "s3cret"
    assert client.get("/healthz").status_code == 200


# ---------- 口令 ----------

def test_token_required_when_configured(client):
    app.state.settings.token = "s3cret"
    assert client.post("/v1/judge", json={"window": WINDOW}).status_code == 401
    assert client.post("/v1/judge", json={"window": WINDOW}, headers={"X-Flowbeat-Token": "nope"}).status_code == 401
    ok = client.post("/v1/judge", json={"window": WINDOW}, headers={"X-Flowbeat-Token": "s3cret"})
    assert ok.status_code == 200


def test_review_also_needs_token(client):
    app.state.settings.token = "s3cret"
    assert client.post("/v1/review", json={"duration_minutes": 3}).status_code == 401


def test_require_token_refuses_to_start_without_one():
    with pytest.raises(RuntimeError):
        Settings(token=None, require_token=True).validate()
    Settings(token="x", require_token=True).validate()


# ---------- 校验 ----------

@pytest.mark.parametrize("patch", [
    {"still_ratio": 1.5},
    {"still_ratio": -0.1},
    {"hr_mean": 400},
    {"hr_min": 5},
    {"away_seconds": -1},
    {"motion_mean": -0.01},
    {"local_time": "25:61"},
    {"local_time": "2pm"},
    {"minute_of_session": -3},
    {"rule_score_mean": 120},
])
def test_rejects_out_of_range_window(client, patch):
    assert client.post("/v1/judge", json={"window": {**WINDOW, **patch}}).status_code == 422


def test_rejects_too_many_examples(client):
    ex = [{"label": "focused", "window": WINDOW}] * 21
    assert client.post("/v1/judge", json={"window": WINDOW, "examples": ex}).status_code == 422


def test_rejects_unknown_label(client):
    ex = [{"label": "sleepy", "window": WINDOW}]
    assert client.post("/v1/judge", json={"window": WINDOW, "examples": ex}).status_code == 422


def test_missing_optional_hr_is_fine(client):
    w = {k: v for k, v in WINDOW.items() if not k.startswith("hr_") and k != "baseline_hr"}
    assert client.post("/v1/judge", json={"window": w}).status_code == 200


# ---------- 超时 / 重试 / 兜底 ----------

def test_timeout_then_fallback_to_rule_score(client):
    p = ScriptedProvider("slow", "slow")
    app.state.provider = p
    r = client.post("/v1/judge", json={"window": WINDOW})
    assert r.status_code == 200
    body = r.json()
    assert body["source"] == "fallback"
    assert body["state"] == "focused" and body["score"] == 92   # rule_score_mean 92 → focused
    assert p.calls == 2                                          # 1 次 + 1 次重试


def test_retry_recovers_from_transient_error(client):
    p = ScriptedProvider(ProviderError("upstream 502", 502))
    app.state.provider = p
    body = client.post("/v1/judge", json={"window": WINDOW}).json()
    assert body["source"] == "llm" and body["score"] == 77
    assert p.calls == 2


def test_rate_limit_is_retried(client):
    p = ScriptedProvider(ProviderError("rate limited", 429))
    app.state.provider = p
    assert client.post("/v1/judge", json={"window": WINDOW}).json()["source"] == "llm"
    assert p.calls == 2


def test_auth_error_is_not_retried(client):
    p = ScriptedProvider(ProviderError("bad key", 500))
    app.state.provider = p
    body = client.post("/v1/judge", json={"window": WINDOW}).json()
    assert body["source"] == "fallback"
    assert p.calls == 1


def test_unexpected_exception_falls_back_instead_of_500(client):
    p = ScriptedProvider(ValueError("sdk bug"))
    app.state.provider = p
    r = client.post("/v1/judge", json={"window": WINDOW})
    assert r.status_code == 200 and r.json()["source"] == "fallback"


def test_retries_are_configurable(client):
    app.state.settings.llm_retries = 3
    p = ScriptedProvider(*[ProviderError("x", 503)] * 5)
    app.state.provider = p
    assert client.post("/v1/judge", json={"window": WINDOW}).json()["source"] == "fallback"
    assert p.calls == 4


def test_review_falls_back(client):
    app.state.provider = ScriptedProvider("slow", "slow")
    r = client.post("/v1/review", json={"duration_minutes": 25, "average_score": 71.6, "away_count": 2})
    assert r.status_code == 200
    body = r.json()
    assert body["source"] == "fallback"
    assert "25 分钟" in body["summary"] and "72" in body["summary"] and "2 次" in body["summary"]


def test_backoff_doubles():
    waits = []

    async def fake_sleep(s):
        waits.append(s)

    async def always_fail():
        raise ProviderError("x", 503)

    s = Settings(token=None, llm_timeout_s=1, llm_retries=3, llm_backoff_s=0.5)
    out = asyncio.run(resilience.call_with_retry(always_fail, s, "t", sleep=fake_sleep))
    assert out.value is None and out.attempts == 4
    assert waits == [0.5, 1.0, 2.0]


@pytest.mark.parametrize("patch,state,score", [
    ({"rule_score_mean": 92}, "focused", 92),
    ({"rule_score_mean": 70}, "focused", 70),
    ({"rule_score_mean": 55.4}, "unclear", 55),
    ({"rule_score_mean": 39.6}, "unclear", 40),
    ({"rule_score_mean": 20}, "distracted", 20),
    ({"rule_score_mean": None}, "unclear", 50),
    ({"away_seconds": 90}, "away", 0),
])
def test_fallback_mapping(patch, state, score):
    j = resilience.fallback_judgment(WindowSummary.model_validate({**WINDOW, **patch}))
    assert (j.state, j.score, j.source) == (state, score, "fallback")


# ---------- 结构化日志 ----------

def test_request_id_is_echoed_and_generated(client):
    r = client.get("/healthz", headers={"X-Request-ID": "abc123"})
    assert r.headers["X-Request-ID"] == "abc123"
    assert len(client.get("/healthz").headers["X-Request-ID"]) == 12


def test_access_log_is_structured_and_has_no_body_data(client, caplog):
    app.state.provider = ScriptedProvider("slow", "slow")
    with caplog.at_level(logging.INFO, logger="flowbeat"):
        client.post("/v1/judge", json={"window": WINDOW}, headers={"X-Request-ID": "rid-1"})
    rec = next(r for r in caplog.records if r.getMessage() == "request" and getattr(r, "request_id", "") == "rid-1")
    line = json.loads(JsonFormatter().format(rec))
    assert line["status"] == 200 and line["path"] == "/v1/judge"
    assert line["source"] == "fallback" and line["attempts"] == 2
    assert isinstance(line["latency_ms"], int)
    # 不记身体数据
    assert "hr_mean" not in json.dumps(line) and "still_ratio" not in json.dumps(line)


# ---------- 和 Swift 的字段契约 ----------

def test_schema_matches_swift_contract_fixture():
    contract = json.loads(CONTRACT.read_text())
    assert sorted(WindowSummary.model_fields) == contract["WindowSummary"]
    assert sorted(JudgeRequest.model_fields) == contract["JudgeRequest"]
    assert sorted(ReviewRequest.model_fields) == contract["ReviewRequest"]
    assert sorted(Judgment.model_fields) == contract["Judgment"]


def test_llm_output_schema_has_no_source_field():
    """source 是后端加的，不能让模型去填。"""
    from app.schemas import LLMJudgment
    assert "source" not in LLMJudgment.model_json_schema()["properties"]


def test_fake_provider_marks_source():
    req = JudgeRequest.model_validate({"window": WINDOW})
    assert asyncio.run(FakeProvider().judge(req)).source == "llm"


# ---------- HRV（可选信号） ----------

def test_hrv_fields_are_optional_and_validated(client):
    assert client.post("/v1/judge", json={"window": WINDOW}).status_code == 200
    ok = {**WINDOW, "hrv_sdnn_ms": 42.5, "hrv_age_min": 30}
    assert client.post("/v1/judge", json={"window": ok}).status_code == 200
    assert client.post("/v1/judge", json={"window": {**ok, "hrv_sdnn_ms": 900}}).status_code == 422
    assert client.post("/v1/judge", json={"window": {**ok, "hrv_age_min": -1}}).status_code == 422


def test_hrv_reaches_the_prompt_only_when_present():
    from app import prompts
    with_hrv = JudgeRequest.model_validate({"window": {**WINDOW, "hrv_sdnn_ms": 42.5, "hrv_age_min": 30}})
    without = JudgeRequest.model_validate({"window": WINDOW})
    assert '"hrv_sdnn_ms":42.5' in prompts.judge_user_message(with_hrv)
    assert "hrv_sdnn_ms" not in prompts.judge_user_message(without)
