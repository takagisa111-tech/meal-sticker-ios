"""记录 agent 的评测入口（需要模拟用户，所以要拿到这张图的标注）。

agent_q0       只识别 + 给出置信度，不提问（对照：排除「提示词多了置信度字段」本身的影响）
agent_q1       拿不准时最多问 1 个问题
agent_q2       拿不准时最多问 2 个问题
agent_always1  不管有没有把握，都问 1 个问题（对照：证明「挑着问」更划算）
*_r2           修正步骤用 v2 提示词：用户给了具体份量就按份量重算（第一轮发现模型常沿用旧估计）
环境变量 AGENT_REFS=0 可以关掉多模态 RAG 参考（默认开）。
"""
from __future__ import annotations

import os

USE_REFS = os.getenv("AGENT_REFS", "1") != "0"


def _make(**kw):
    def run(img, stats, item=None):
        from ..agent import recognizer  # 延迟导入：只有跑 agent 时才需要 langgraph
        user = None
        if kw.get("max_questions", 0) > 0:
            from evals.sim_user import make
            user = make(item)
        return recognizer.run(img, stats, user=user or (lambda q, o: "不确定"), use_refs=USE_REFS, k_refs=5, **kw)
    run.needs_item = True
    return run


agent_q0 = _make(max_questions=0)
agent_q1 = _make(max_questions=1, ask_policy="uncertain")
agent_q2 = _make(max_questions=2, ask_policy="uncertain")
agent_always1 = _make(max_questions=1, ask_policy="always")
agent_q2_r2 = _make(max_questions=2, ask_policy="uncertain", refine_prompt="v2")
agent_always1_r2 = _make(max_questions=1, ask_policy="always", refine_prompt="v2")
