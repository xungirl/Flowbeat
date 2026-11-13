import os

os.environ["LLM_PROVIDER"] = "fake"
os.environ.pop("FLOWBEAT_TOKEN", None)

from fastapi.testclient import TestClient  # noqa: E402

from app import prompts  # noqa: E402
from app.main import app  # noqa: E402
from app.schemas import JudgeRequest  # noqa: E402

client = TestClient(app)

WINDOW = {
    "minute_of_session": 6, "local_time": "14:32", "baseline_hr": 68,
    "hr_mean": 70, "hr_min": 66, "hr_max": 74, "hr_trend": 1,
    "motion_mean": 0.01, "motion_max": 0.04, "still_ratio": 0.95,
    "away_seconds": 0, "rule_score_mean": 92,
}


def test_health():
    assert client.get("/health").json() == {"ok": True, "provider": "fake"}


def test_judge_focused():
    r = client.post("/v1/judge", json={"window": WINDOW})
    assert r.status_code == 200
    assert r.json()["state"] == "focused"


def test_judge_away():
    r = client.post("/v1/judge", json={"window": {**WINDOW, "away_seconds": 90}})
    assert r.json()["state"] == "away"


def test_judge_rejects_bad_payload():
    assert client.post("/v1/judge", json={"window": {"minute_of_session": 1}}).status_code == 422


def test_review():
    r = client.post("/v1/review", json={"duration_minutes": 30, "away_count": 2})
    assert r.status_code == 200
    assert set(r.json()) == {"summary", "tip"}


def test_prompt_includes_user_examples():
    req = JudgeRequest.model_validate({
        "window": WINDOW,
        "examples": [{"label": "distracted", "window": {**WINDOW, "still_ratio": 0.3}}],
    })
    msg = prompts.judge_user_message(req)
    assert "标注过的例子" in msg and '"label":"distracted"' in msg


def test_prompt_omits_rule_score_by_default():
    req = JudgeRequest.model_validate({
        "window": WINDOW,
        "examples": [{"label": "focused", "window": WINDOW}],
    })
    msg = prompts.judge_user_message(req)
    # 当前窗口和例子里都不能出现规则分，否则模型会照抄（锚定偏差）
    assert "rule_score_mean" not in msg
    assert '"still_ratio":0.95' in msg


def test_prompt_can_include_rule_score_behind_flag(monkeypatch):
    req = JudgeRequest.model_validate({"window": WINDOW})
    assert '"rule_score_mean":92' in prompts.judge_user_message(req, include_rule_score=True)
    monkeypatch.setenv("JUDGE_INCLUDE_RULE_SCORE", "1")
    assert '"rule_score_mean":92' in prompts.judge_user_message(req)
