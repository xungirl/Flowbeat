"""所有运行时配置都从环境变量读，集中在这里，测试里可以直接构造一个 Settings 替换。"""

import os
from dataclasses import dataclass, field


def _bool(name: str, default: bool) -> bool:
    v = os.getenv(name)
    return default if v is None else v.strip().lower() in ("1", "true", "yes", "on")


@dataclass
class Settings:
    # 共享口令：手表在 X-Flowbeat-Token 头里带上。空 = 不校验（只适合本机开发）
    token: str | None = field(default_factory=lambda: os.getenv("FLOWBEAT_TOKEN") or None)
    # 部署时设成 1：没配口令就拒绝启动，避免把一个白嫖 LLM 额度的接口暴露在公网
    require_token: bool = field(default_factory=lambda: _bool("FLOWBEAT_REQUIRE_TOKEN", False))
    # 单次 LLM 调用的超时（秒）。手表端请求超时是 30 s，这里要明显更短，留出重试和兜底的时间
    llm_timeout_s: float = field(default_factory=lambda: float(os.getenv("LLM_TIMEOUT_S", "8")))
    # 失败后再试几次（只对超时 / 限流 / 5xx 重试；key 无效这种重试也没用）
    llm_retries: int = field(default_factory=lambda: int(os.getenv("LLM_RETRIES", "1")))
    # 第 n 次重试前等待 backoff * 2^(n-1) 秒
    llm_backoff_s: float = field(default_factory=lambda: float(os.getenv("LLM_BACKOFF_S", "0.5")))
    # 日志格式：json（默认，方便机器检索）或 text
    log_format: str = field(default_factory=lambda: os.getenv("LOG_FORMAT", "json"))

    def validate(self) -> None:
        if self.require_token and not self.token:
            raise RuntimeError("FLOWBEAT_REQUIRE_TOKEN=1 but FLOWBEAT_TOKEN is empty")
        if self.llm_timeout_s <= 0 or self.llm_retries < 0 or self.llm_backoff_s < 0:
            raise RuntimeError("LLM_TIMEOUT_S must be > 0, LLM_RETRIES and LLM_BACKOFF_S >= 0")
