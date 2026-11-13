from app import prompts
from app.schemas import JudgeRequest

from .conftest import WINDOW


def test_health(client):
    assert client.get("/health").json() == {"ok": True, "provider": "fake"}


def test_judge_focused(client):
    r = client.post("/v1/judge", json={"window": WINDOW})
    assert r.status_code == 200
    assert r.json()["state"] == "focused"
    assert r.json()["source"] == "llm"


def test_judge_away(client):
    r = client.post("/v1/judge", json={"window": {**WINDOW, "away_seconds": 90}})
    assert r.json()["state"] == "away"


def test_judge_rejects_bad_payload(client):
    assert client.post("/v1/judge", json={"window": {"minute_of_session": 1}}).status_code == 422


def test_review(client):
    r = client.post("/v1/review", json={"duration_minutes": 30, "away_count": 2})
    assert r.status_code == 200
    assert set(r.json()) == {"summary", "tip", "source"}


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
