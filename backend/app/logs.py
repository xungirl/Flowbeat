"""结构化日志：每行一个 JSON 对象，字段固定，方便用 jq / Cloud Logging 检索。
只记元数据（路径、状态码、耗时、token 数、结果来源），不记手表发来的身体数据。"""

import json
import logging
import sys
import time

# 这些是 LogRecord 自带的属性，其余通过 extra= 传进来的都当作结构化字段输出
_RESERVED = set(vars(logging.LogRecord("", 0, "", 0, "", None, None))) | {"message", "asctime"}


class JsonFormatter(logging.Formatter):
    def format(self, record: logging.LogRecord) -> str:
        out = {
            "ts": time.strftime("%Y-%m-%dT%H:%M:%S", time.gmtime(record.created)) + f".{int(record.msecs):03d}Z",
            "level": record.levelname.lower(),
            "logger": record.name,
            "msg": record.getMessage(),
        }
        for k, v in vars(record).items():
            if k not in _RESERVED and not k.startswith("_"):
                out[k] = v
        if record.exc_info:
            out["exc"] = self.formatException(record.exc_info)
        return json.dumps(out, ensure_ascii=False, default=str)


def setup_logging(fmt: str = "json", level: int = logging.INFO) -> None:
    handler = logging.StreamHandler(sys.stdout)
    handler.setFormatter(JsonFormatter() if fmt == "json" else logging.Formatter("%(levelname)s %(name)s %(message)s"))
    root = logging.getLogger()
    root.handlers[:] = [handler]
    root.setLevel(level)
    # uvicorn 自己的 access log 和我们的请求日志重复，关掉
    logging.getLogger("uvicorn.access").disabled = True
