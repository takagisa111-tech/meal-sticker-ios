from . import agent, baseline, rag, zh

PIPELINES = {
    "baseline": baseline.analyze,
    "prompt_v2": rag.prompt_v2,
    "rag": rag.rag,
    "rag_rerank": rag.rag_rerank,
    "prompt_v3": rag.prompt_v3,
    "rag_v3": rag.rag_v3,
    "rag_ens_v3": rag.rag_ens_v3,
    "zh_v2": zh.zh_v2,
    "zh_rag": zh.zh_rag,
    "baseline_sc3": zh.baseline_sc3,
    "zh_mm3": zh.zh_mm3,
    "zh_mm5": zh.zh_mm5,
    "zh_mm3_text": zh.zh_mm3_text,
    "agent_q0": agent.agent_q0,
    "agent_q1": agent.agent_q1,
    "agent_q2": agent.agent_q2,
    "agent_always1": agent.agent_always1,
    "agent_q2_r2": agent.agent_q2_r2,
    "agent_always1_r2": agent.agent_always1_r2,
}
