"""手表 ↔ 后端之间的数据格式。字段名和 Swift 端 FlowbeatCore/Models.swift 里的 Codable 结构一一对应，
由 FlowbeatCore/Tests/FlowbeatCoreTests/Fixtures/contract_fields.json 在两边各测一次。

取值范围是「物理上可能」的宽松上下限：挡住明显坏掉/恶意的数据（返回 422），不替模型做判断。
"""

from typing import Literal

from pydantic import BaseModel, Field

FocusState = Literal["focused", "distracted", "away", "unclear"]
Source = Literal["llm", "fallback"]

HeartRate = Field(None, ge=25, le=250)


class WindowSummary(BaseModel):
    """手表把最近约 2 分钟的逐秒数据压缩成的一段摘要。"""

    minute_of_session: int = Field(ge=0, le=24 * 60, description="这是本次专注的第几分钟")
    local_time: str = Field(pattern=r"^([01]\d|2[0-3]):[0-5]\d$", description="手表本地时间 HH:mm")
    baseline_hr: float | None = Field(None, ge=25, le=250, description="校准得到的平静心率")
    hr_mean: float | None = HeartRate
    hr_min: float | None = HeartRate
    hr_max: float | None = HeartRate
    hr_trend: float | None = Field(None, ge=-200, le=200, description="窗口末尾减开头的心率差，正数=在上升")
    motion_mean: float = Field(ge=0, le=50, description="手腕用户加速度均值 (g)")
    motion_max: float = Field(ge=0, le=50)
    still_ratio: float = Field(ge=0, le=1, description="手腕基本静止（<0.03g）的秒数占比 0–1")
    away_seconds: int = Field(ge=0, le=3600, description="窗口内离座（走路/跑步）的秒数")
    rule_score_mean: float | None = Field(None, ge=0, le=100, description="手表本地规则算出的平均分 0–100")
    # HRV 是可选信号：手表只是偶尔测一次 SDNN，所以发的是「最近一次读数 + 距今多久」，没有就不发
    hrv_sdnn_ms: float | None = Field(None, ge=5, le=250, description="最近一次心率变异性 SDNN（毫秒）")
    hrv_age_min: int | None = Field(None, ge=0, le=24 * 60, description="这次 HRV 读数距窗口结束的分钟数")


class LLMJudgment(BaseModel):
    """让模型输出的字段（也是 Claude 结构化输出的 schema）。"""

    state: FocusState
    score: int = Field(description="0–100 的专注程度")
    reason: str = Field(max_length=200, description="给用户看的一句中文理由，不超过 20 个字")


class Judgment(LLMJudgment):
    """返回给手表的判断：多一个 source，区分是模型判断还是兜底。"""

    source: Source | None = None


class LabeledExample(BaseModel):
    """用户自己打过标签的窗口——few-shot 例子，让模型参照「你本人」来判断。"""

    window: WindowSummary
    label: Literal["focused", "distracted"]


class JudgeRequest(BaseModel):
    window: WindowSummary
    examples: list[LabeledExample] = Field(default_factory=list, max_length=20)
    recent: list[Judgment] = Field(default_factory=list, max_length=5, description="本次前几个窗口的判断")


class ReviewRequest(BaseModel):
    duration_minutes: int = Field(ge=0, le=24 * 60)
    average_score: float | None = Field(None, ge=0, le=100)
    focused_ratio: float | None = Field(None, ge=0, le=1)
    away_count: int = Field(0, ge=0, le=10_000)
    away_minutes: float = Field(0, ge=0, le=24 * 60)
    windows: list[WindowSummary] = Field(default_factory=list, max_length=240)
    judgments: list[Judgment] = Field(default_factory=list, max_length=240)


class LLMReview(BaseModel):
    summary: str = Field(description="一两句话总结这次专注，中文，不超过 60 字")
    tip: str = Field(description="一条具体可执行的建议，中文，不超过 40 字")


class Review(LLMReview):
    source: Source | None = None
