# syntax=docker/dockerfile:1
# 两阶段构建：builder 里用 uv 按 uv.lock 装依赖，运行镜像只拷 .venv 和代码（没有 uv、没有编译工具）。
#   docker build -t flowbeat-backend backend
#   docker run -p 8765:8765 -e FLOWBEAT_TOKEN=... -e DASHSCOPE_API_KEY=... flowbeat-backend

FROM python:3.13-slim AS builder
COPY --from=ghcr.io/astral-sh/uv:0.9 /uv /bin/uv
ENV UV_COMPILE_BYTECODE=1 UV_LINK_MODE=copy UV_PYTHON_DOWNLOADS=0
WORKDIR /app
# 先只拷依赖清单：代码改了不会让依赖层的缓存失效
COPY pyproject.toml uv.lock .python-version ./
RUN uv sync --frozen --no-dev --no-install-project
COPY app ./app

FROM python:3.13-slim
RUN useradd --create-home --uid 10001 flowbeat
WORKDIR /app
COPY --from=builder /app/.venv /app/.venv
COPY --from=builder /app/app ./app
# 镜像默认「必须有口令」：部署到公网时忘了设 FLOWBEAT_TOKEN 会直接启动失败
ENV PATH="/app/.venv/bin:$PATH" \
    PYTHONUNBUFFERED=1 \
    FLOWBEAT_REQUIRE_TOKEN=1 \
    PORT=8765
USER flowbeat
EXPOSE 8765
HEALTHCHECK --interval=30s --timeout=3s --start-period=5s \
  CMD python -c "import os, urllib.request; urllib.request.urlopen(f'http://127.0.0.1:{os.environ[\"PORT\"]}/healthz', timeout=2)"
CMD ["sh", "-c", "exec uvicorn app.main:app --host 0.0.0.0 --port ${PORT}"]
