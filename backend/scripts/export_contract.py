"""把后端 Pydantic 模型的字段名导出成契约文件，Swift 和 Python 的测试都读它。
改了 schemas.py 之后运行，再跑两边的测试：

    cd backend && uv run python scripts/export_contract.py
"""

import json
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))

from app.schemas import JudgeRequest, Judgment, ReviewRequest, WindowSummary  # noqa: E402

OUT = ROOT.parent / "FlowbeatCore/Tests/FlowbeatCoreTests/Fixtures/contract_fields.json"

if __name__ == "__main__":
    d = {m.__name__: sorted(m.model_fields) for m in (WindowSummary, JudgeRequest, ReviewRequest, Judgment)}
    OUT.write_text(json.dumps(d, indent=2) + "\n")
    print(f"wrote {OUT}")
