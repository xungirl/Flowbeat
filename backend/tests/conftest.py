import os

# 测试永远用 FakeProvider，不花钱、不需要 key；也不能读到开发机 .env 里的口令
os.environ["LLM_PROVIDER"] = "fake"
for k in ("FLOWBEAT_TOKEN", "FLOWBEAT_REQUIRE_TOKEN", "JUDGE_INCLUDE_RULE_SCORE"):
    os.environ.pop(k, None)

import pytest  # noqa: E402
from fastapi.testclient import TestClient  # noqa: E402

from app.config import Settings  # noqa: E402
from app.main import app  # noqa: E402

WINDOW = {
    "minute_of_session": 6, "local_time": "14:32", "baseline_hr": 68,
    "hr_mean": 70, "hr_min": 66, "hr_max": 74, "hr_trend": 1,
    "motion_mean": 0.01, "motion_max": 0.04, "still_ratio": 0.95,
    "away_seconds": 0, "rule_score_mean": 92,
}


@pytest.fixture
def client():
    """每个测试一个新的 app 生命周期；测试可以改 app.state.settings / app.state.provider。"""
    with TestClient(app) as c:
        # 测试里不真的等退避
        app.state.settings = Settings(token=None, llm_timeout_s=0.2, llm_retries=1, llm_backoff_s=0, log_format="json")
        yield c
