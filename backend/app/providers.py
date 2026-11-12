"""大模型提供方。每家一个类，对外都是 judge() / review() 两个方法。
以后加通义千问：再写一个 QwenProvider，在 get_provider() 里加一个分支。
"""

import logging
import os
from typing import Protocol

import anthropic

from . import prompts
from .schemas import JudgeRequest, Judgment, Review, ReviewRequest

log = logging.getLogger("flowbeat")


class ProviderError(Exception):
    """调用模型失败；status 是要回给手表的 HTTP 状态码。"""

    def __init__(self, message: str, status: int = 502):
        super().__init__(message)
        self.status = status


class Provider(Protocol):
    name: str

    async def judge(self, req: JudgeRequest) -> Judgment: ...
    async def review(self, req: ReviewRequest) -> Review: ...


class ClaudeProvider:
    name = "claude"

    def __init__(self, model: str | None = None):
        # 凭据从环境变量 ANTHROPIC_API_KEY 读取，不写死在代码里
        self.client = anthropic.AsyncAnthropic(timeout=30.0, max_retries=2)
        self.model = model or os.getenv("CLAUDE_MODEL", "claude-haiku-5-5")

    async def _parse(self, system: str, user: str, schema):
        try:
            resp = await self.client.messages.parse(
                model=self.model,
                max_tokens=4000,
                # 系统提示词固定不变，打上缓存断点，重复调用更便宜
                system=[{"type": "text", "text": system, "cache_control": {"type": "ephemeral"}}],
                messages=[{"role": "user", "content": user}],
                # 简单的分类任务，low effort 就够，省钱、更快
                output_config={"effort": "low"},
                output_format=schema,
            )
        except anthropic.AuthenticationError as e:
            raise ProviderError("Claude API key 无效", 500) from e
        except anthropic.RateLimitError as e:
            raise ProviderError("Claude 限流，请稍后再试", 429) from e
        except anthropic.APIStatusError as e:
            raise ProviderError(f"Claude 返回错误 {e.status_code}", 502) from e
        except anthropic.APIConnectionError as e:
            raise ProviderError("连不上 Claude", 504) from e

        if resp.stop_reason == "refusal":
            raise ProviderError("模型拒绝了这次请求", 502)
        if resp.parsed_output is None:
            raise ProviderError(f"模型没有返回有效结果（stop_reason={resp.stop_reason}）", 502)
        u = resp.usage
        log.info("claude %s in=%s cached=%s out=%s", self.model, u.input_tokens, u.cache_read_input_tokens, u.output_tokens)
        return resp.parsed_output

    async def judge(self, req: JudgeRequest) -> Judgment:
        j = await self._parse(prompts.JUDGE_SYSTEM, prompts.judge_user_message(req), Judgment)
        j.score = max(0, min(100, j.score))
        return j

    async def review(self, req: ReviewRequest) -> Review:
        return await self._parse(prompts.REVIEW_SYSTEM, prompts.review_user_message(req), Review)


class FakeProvider:
    """没有 API key 时用：按简单规则返回，方便本地联调手表 ↔ 后端，不花钱。"""

    name = "fake"

    async def judge(self, req: JudgeRequest) -> Judgment:
        w = req.window
        if w.away_seconds > 60:
            return Judgment(state="away", score=0, reason="【模拟】大部分时间在走动")
        if w.still_ratio > 0.8:
            return Judgment(state="focused", score=85, reason="【模拟】手腕基本静止")
        if w.still_ratio < 0.4:
            return Judgment(state="distracted", score=35, reason="【模拟】手腕动作零碎")
        return Judgment(state="unclear", score=60, reason="【模拟】信号不明确")

    async def review(self, req: ReviewRequest) -> Review:
        return Review(summary=f"【模拟】本次 {req.duration_minutes} 分钟，离座 {req.away_count} 次。",
                      tip="【模拟】配置 ANTHROPIC_API_KEY 后这里会是真正的 AI 建议")


def get_provider() -> Provider:
    """LLM_PROVIDER=claude|fake；不设置时有 key 就用 Claude，没有就用 fake。"""
    choice = os.getenv("LLM_PROVIDER") or ("claude" if os.getenv("ANTHROPIC_API_KEY") else "fake")
    if choice == "claude":
        return ClaudeProvider()
    if choice == "fake":
        log.warning("使用 FakeProvider（没有 ANTHROPIC_API_KEY），返回的是模拟结果")
        return FakeProvider()
    raise ValueError(f"未知的 LLM_PROVIDER: {choice}")
