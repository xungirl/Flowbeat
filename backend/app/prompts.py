"""提示词。系统提示词保持不变（利于 prompt caching），每次变化的数据都放在 user 消息里。"""

import json
import os

from .schemas import JudgeRequest, ReviewRequest

# 手表本地规则分。默认不发给模型：2026-11-11 的对比里，模型给的分数和它一模一样（锚定偏差），
# 等于没有独立判断。需要复现旧行为时设 JUDGE_INCLUDE_RULE_SCORE=1。
RULE_SCORE_FIELD = "rule_score_mean"


def include_rule_score_default() -> bool:
    return os.getenv("JUDGE_INCLUDE_RULE_SCORE", "0").lower() in ("1", "true", "yes")

JUDGE_SYSTEM = """\
你是 Flowbeat（心流）的专注判断器。Flowbeat 是一款 Apple Watch app，用户在学习或工作时开启。
你会收到手表对最近约 2 分钟的身体信号摘要，判断用户这段时间的状态。

可参考的生理常识（都是倾向，不是定律）：
- 专注的伏案工作：手腕大多静止，或者只有打字那种小而规律的动作；心率接近平静基线，平稳或略升。
- 走神或分心：手腕动作零碎、不规律（玩手机、抖腿、东摸西摸）；常常伴随心率小幅波动。
- 紧张或压力：心率明显高于基线，而手腕并没有大动作。这不等于不专注，比如赶 deadline 时可能既紧张又专注。
- 离座：窗口里有走路或跑步的秒数。离座占了大部分时间就判 away。
- 刚坐回来的 1–2 分钟心率偏高是正常的，不要因此判走神。

最重要的是用户本人的标注例子（如果有）：每个人的身体不一样，相似的数据要优先按这个用户自己的标注来判断，而不是套常识。
数据太少或互相矛盾时判 unclear，不要硬猜。

输出：
- state：focused / distracted / away / unclear
- score：0–100 的专注程度
- reason：一句给用户看的中文理由，不超过 20 个字，要具体（例如「手腕静止 2 分钟，心率平稳」），不要说教。
"""

REVIEW_SYSTEM = """\
你是 Flowbeat（心流）的专注教练。用户刚结束一段专注，你会收到整段的统计数据和每 2 分钟的状态判断。
请找出这段里真实存在的规律（比如第几分钟开始下滑、离座后多久恢复），不要编造数据里没有的东西。
summary：一两句中文总结，不超过 60 字。
tip：一条下次就能照做的具体建议，不超过 40 字。语气友好、简洁，不要说教。
"""


def _dump(obj) -> str:
    return json.dumps(obj, ensure_ascii=False, separators=(",", ":"))


def _window_dict(window, include_rule_score: bool) -> dict:
    exclude = None if include_rule_score else {RULE_SCORE_FIELD}
    return window.model_dump(exclude_none=True, exclude=exclude)


def judge_user_message(req: JudgeRequest, include_rule_score: bool | None = None) -> str:
    """拼 user 消息。include_rule_score=None 时读环境变量（默认 False）。
    规则分在「当前窗口」和「标注例子」里都要去掉，否则模型可以从例子里抄分数。"""
    if include_rule_score is None:
        include_rule_score = include_rule_score_default()
    parts = []
    if req.examples:
        lines = [_dump({"label": e.label, **_window_dict(e.window, include_rule_score)}) for e in req.examples]
        parts.append("这个用户自己标注过的例子：\n" + "\n".join(lines))
    else:
        parts.append("这个用户还没有标注过例子，请按常识判断。")
    if req.recent:
        parts.append("本次前几个窗口的判断（从早到晚）：\n" + "\n".join(_dump(j.model_dump()) for j in req.recent))
    parts.append("请判断这个窗口：\n" + _dump(_window_dict(req.window, include_rule_score)))
    return "\n\n".join(parts)


def review_user_message(req: ReviewRequest) -> str:
    return _dump(req.model_dump(exclude_none=True))
