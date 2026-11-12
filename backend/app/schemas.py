"""手表 ↔ 后端之间的数据格式。字段名和 Swift 端 AIJudge.swift 里的 Codable 结构一一对应。"""

from typing import Literal

from pydantic import BaseModel, Field

FocusState = Literal["focused", "distracted", "away", "unclear"]


class WindowSummary(BaseModel):
    """手表把最近约 2 分钟的逐秒数据压缩成的一段摘要。"""

    minute_of_session: int = Field(description="这是本次专注的第几分钟")
    local_time: str = Field(description="手表本地时间 HH:mm")
    baseline_hr: float | None = Field(None, description="校准得到的平静心率")
    hr_mean: float | None = None
    hr_min: float | None = None
    hr_max: float | None = None
    hr_trend: float | None = Field(None, description="窗口末尾减开头的心率差，正数=在上升")
    motion_mean: float = Field(description="手腕用户加速度均值 (g)")
    motion_max: float
    still_ratio: float = Field(description="手腕基本静止（<0.03g）的秒数占比 0–1")
    away_seconds: int = Field(description="窗口内离座（走路/跑步）的秒数")
    rule_score_mean: float | None = Field(None, description="手表本地规则算出的平均分 0–100")


class Judgment(BaseModel):
    """模型对一个窗口的判断。也是 Claude 结构化输出的 schema。"""

    state: FocusState
    score: int = Field(description="0–100 的专注程度")
    reason: str = Field(description="给用户看的一句中文理由，不超过 20 个字")


class LabeledExample(BaseModel):
    """用户自己打过标签的窗口——few-shot 例子，让模型参照「你本人」来判断。"""

    window: WindowSummary
    label: Literal["focused", "distracted"]


class JudgeRequest(BaseModel):
    window: WindowSummary
    examples: list[LabeledExample] = Field(default_factory=list, max_length=20)
    recent: list[Judgment] = Field(default_factory=list, max_length=5, description="本次前几个窗口的判断")


class ReviewRequest(BaseModel):
    duration_minutes: int
    average_score: float | None = None
    focused_ratio: float | None = None
    away_count: int = 0
    away_minutes: float = 0
    windows: list[WindowSummary] = Field(default_factory=list, max_length=240)
    judgments: list[Judgment] = Field(default_factory=list, max_length=240)


class Review(BaseModel):
    summary: str = Field(description="一两句话总结这次专注，中文，不超过 60 字")
    tip: str = Field(description="一条具体可执行的建议，中文，不超过 40 字")
