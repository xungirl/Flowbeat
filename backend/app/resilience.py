"""LLM 调用的超时 + 重试 + 兜底。

手表每 2 分钟要一个判断。模型慢、限流、挂了的时候，宁可按手表的规则分给一个「保守」的结果，
也不要让手表等 30 秒后什么都拿不到。兜底结果带 source="fallback"，手表和日志都能区分。

注意：SDK 自带的重试已关掉（max_retries=0），重试策略只在这一层，避免 SDK 3 次 × 这里 2 次 叠加成 6 次。
"""

import asyncio
import logging
import time
from collections.abc import Awaitable, Callable
from dataclasses import dataclass
from typing import Generic, TypeVar

from .config import Settings
from .providers import ProviderError
from .schemas import Judgment, Review, ReviewRequest, WindowSummary

log = logging.getLogger("flowbeat.llm")
T = TypeVar("T")

# 值得重试的状态：限流、上游 5xx、连不上。key 无效（500）、格式错误（502 但每次都会错）不在这里时也只多试一次
RETRIABLE_STATUS = {429, 502, 503, 504}


@dataclass
class Outcome(Generic[T]):
    value: T | None
    attempts: int
    error: str | None = None
    latency_ms: int = 0


async def call_with_retry(fn: Callable[[], Awaitable[T]], settings: Settings, op: str,
                          sleep: Callable[[float], Awaitable[None]] = asyncio.sleep) -> Outcome[T]:
    """最多调用 1 + llm_retries 次，每次 llm_timeout_s 超时。全部失败时 value=None，由调用方兜底。"""
    t0 = time.perf_counter()
    attempts, error = 0, None
    for attempt in range(settings.llm_retries + 1):
        attempts = attempt + 1
        if attempt:
            await sleep(settings.llm_backoff_s * 2 ** (attempt - 1))
        try:
            value = await asyncio.wait_for(fn(), timeout=settings.llm_timeout_s)
            return Outcome(value, attempts, None, int((time.perf_counter() - t0) * 1000))
        except TimeoutError:
            error = f"timeout after {settings.llm_timeout_s}s"
            retriable = True
        except ProviderError as e:
            error = f"{e} (status {e.status})"
            retriable = e.status in RETRIABLE_STATUS
        except Exception as e:  # SDK 里没预料到的异常也不能让接口 500
            error = f"{type(e).__name__}: {e}"
            retriable = False
        log.warning("llm call failed", extra={"op": op, "attempt": attempts, "error": error, "retriable": retriable})
        if not retriable:
            break
    return Outcome(None, attempts, error, int((time.perf_counter() - t0) * 1000))


def fallback_judgment(w: WindowSummary) -> Judgment:
    """模型不可用时的规则兜底：阈值和手表圆环的配色一致（≥70 心流，<40 走神）。"""
    if w.away_seconds > 60:
        return Judgment(state="away", score=0, reason="大部分时间在走动", source="fallback")
    if w.rule_score_mean is None:
        return Judgment(state="unclear", score=50, reason="AI 暂不可用，数据不足", source="fallback")
    score = int(round(w.rule_score_mean))
    state = "focused" if score >= 70 else ("distracted" if score < 40 else "unclear")
    return Judgment(state=state, score=score, reason="AI 暂不可用，按手表规则分", source="fallback")


def fallback_review(req: ReviewRequest) -> Review:
    avg = f"，平均专注 {req.average_score:.0f}" if req.average_score is not None else ""
    return Review(summary=f"本次 {req.duration_minutes} 分钟{avg}，离座 {req.away_count} 次。",
                  tip="AI 复盘暂不可用，数据已保存在手表上。", source="fallback")
