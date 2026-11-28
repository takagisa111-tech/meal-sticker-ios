"""记录 agent（LangGraph 状态图）：「拍一下就记好，拿不准才问」。

    START → retrieve ──→ perceive ──→ decide ──┬─(值得问)──→ ask ──→ refine ──→ decide …
                                               └─(够确定 / 问够了)──→ END

- retrieve：多模态 RAG，从参考库（以后加上用户自己的历史记录）里找外观相似、份量已核实的餐
- perceive：视觉模型识别，并对每样食物给出置信度，列出「拿不准且影响热量」的疑点
- decide：把疑点按「热量 × 不确定度」排序；最大的那个影响超过阈值、且还没问满，就去问
- ask：向用户问一个问题（App 里是 interrupt 暂停等用户点选；评测里由「模拟用户」回答）
- refine：把用户的回答并入识别结果（文本调用，不重新看图，省时省钱）

模式：
  ask_policy="uncertain"  只在拿不准时问（默认）
  ask_policy="always"     每次都问影响最大的那个疑点（对照组，用来证明「挑着问」更划算）
"""
from __future__ import annotations

import json
from typing import Any, Callable, Optional, TypedDict

from langgraph.graph import END, START, StateGraph

from ..llm import chat_json
from ..prompts import agent_zh
from ..rag.visual import describe, index as visual_index
from ..schema import FoodAnalysis, Ingredient, Macros, RunStats
from ..pipelines.rag import KEYS, num

FIELDS = {"kcal": "calories", "carbs": "carbs", "protein": "protein", "fat": "fat"}


class State(TypedDict, total=False):
    image: Any
    refs: list
    result: dict            # 当前识别结果（模型 JSON）
    qa: list                # [(问题, 回答), …]
    pending: Optional[dict]  # 准备问的疑点
    asked: int
    trace: list


def _clean(r: dict) -> dict:
    foods = []
    for f in r.get("foods", []):
        if isinstance(f, dict) and f.get("name"):
            f = dict(f)
            for k in KEYS:
                f[k] = num(f.get(k))
            f["confidence"] = min(1.0, max(0.0, num(f.get("confidence", 0.7)) or 0.7))
            foods.append(f)
    r["foods"] = foods
    r["doubts"] = [d for d in r.get("doubts", []) if isinstance(d, dict) and d.get("question")]
    return r


def _pil(img):
    """状态里的图片可以是 PIL 图片，也可以是 data URL 字符串（网页版用，便于 LangGraph 存检查点）。"""
    if isinstance(img, str):
        import base64
        import io
        from PIL import Image
        return Image.open(io.BytesIO(base64.b64decode(img.split(",", 1)[1])))
    return img


def build(stats: RunStats, user: Callable[[str, list], str] | None = None, *, max_questions: int = 2,
          ask_policy: str = "uncertain", use_refs: bool = True, k_refs: int = 3, threshold_kcal: float = 60.0,
          refine_prompt: str = "v1"):
    """user(question, options) -> answer。为 None 时用 LangGraph 的 interrupt 暂停，等前端把用户回答传回来。"""

    def retrieve(s: State):
        if not use_refs:
            return {"refs": []}
        refs = visual_index().search(_pil(s["image"]), k=k_refs)
        return {"refs": refs}

    def perceive(s: State):
        from ..llm import encode_image
        from PIL import Image
        refs = s.get("refs") or []
        images = [s["image"]] + [encode_image(Image.open(r["image"]), max_side=512) for r in refs]
        r = chat_json(agent_zh.perceive([describe(x) for x in refs] if refs else None), images, stats=stats,
                      system=agent_zh.SYSTEM, json_mode=True, temperature=0.3)
        r = _clean(r)
        return {"result": r, "asked": 0, "qa": [], "trace": [{"step": "perceive", "foods": len(r["foods"]), "doubts": len(r["doubts"])}]}

    def decide(s: State):
        r = s["result"]
        if s.get("asked", 0) >= max_questions:
            return {"pending": None}
        kcal = {f["name"]: f["kcal"] for f in r["foods"]}
        conf = {f["name"]: f["confidence"] for f in r["foods"]}
        asked_q = {q for q, _ in s.get("qa", [])}
        scored = []
        for d in r["doubts"]:
            if d["question"] in asked_q:
                continue
            food = d.get("food", "")
            impact = max(kcal.get(food, 0.0), 30.0) * (1 - conf.get(food, 0.5))
            if d.get("type") == "hidden":
                impact = max(impact, 0.3 * sum(kcal.values()) * (1 - conf.get(food, 0.5)))
            scored.append((impact, d))
        scored.sort(key=lambda x: -x[0])
        if ask_policy == "always" and s.get("asked", 0) == 0:
            if scored:
                return {"pending": scored[0][1]}
            if r["foods"]:
                top = max(r["foods"], key=lambda f: f["kcal"])
                return {"pending": {"food": top["name"], "type": "portion",
                                    "question": f"{top['name']}大概有多少？", "options": ["比图里看起来少", "差不多", "比看起来多"]}}
            return {"pending": None}
        if ask_policy == "uncertain" and scored and scored[0][0] >= threshold_kcal:
            return {"pending": scored[0][1]}
        return {"pending": None}

    def route(s: State) -> str:
        return "ask" if s.get("pending") else "done"

    def ask(s: State):
        d = s["pending"]
        q, opts = d["question"], [str(o) for o in d.get("options", [])][:4]
        if user is not None:
            a = user(q, opts)
        else:
            from langgraph.types import interrupt
            a = interrupt({"question": q, "options": opts})
        stats.questions += 1
        return {"qa": s.get("qa", []) + [(q, a)], "asked": s.get("asked", 0) + 1,
                "trace": s.get("trace", []) + [{"step": "ask", "question": q, "options": opts, "answer": a}]}

    def refine(s: State):
        prev = json.dumps(s["result"], ensure_ascii=False)
        qa = "\n".join(f"问：{q}\n答：{a}" for q, a in s["qa"])
        tmpl = agent_zh.REFINE_V2 if refine_prompt == "v2" else agent_zh.REFINE
        r = chat_json(tmpl.format(prev=prev, qa=qa), stats=stats, system=agent_zh.SYSTEM, json_mode=True, temperature=0.2)
        r = _clean(r)
        return {"result": r, "trace": s.get("trace", []) + [{"step": "refine", "foods": len(r["foods"])}]}

    g = StateGraph(State)
    g.add_node("retrieve", retrieve)
    g.add_node("perceive", perceive)
    g.add_node("decide", decide)
    g.add_node("ask", ask)
    g.add_node("refine", refine)
    g.add_edge(START, "retrieve")
    g.add_edge("retrieve", "perceive")
    g.add_edge("perceive", "decide")
    g.add_conditional_edges("decide", route, {"ask": "ask", "done": END})
    g.add_edge("ask", "refine")
    g.add_edge("refine", "decide")
    return g


def to_analysis(s: State) -> FoodAnalysis:
    r = s["result"]
    foods = r["foods"]
    ings = [Ingredient(name=str(f.get("name_en") or f["name"]), grams=num(f.get("served_g") or f.get("grams")),
                       calories=f["kcal"], carbs=f["carbs"], protein=f["protein"], fat=f["fat"]) for f in foods]
    if foods and sum(f["kcal"] for f in foods) > 0:
        total = {FIELDS[k]: sum(f[k] for f in foods) for k in KEYS}
    else:
        total = {FIELDS[k]: num(r.get(k)) for k in KEYS}
    return FoodAnalysis(meal_name=str(r.get("title_en") or r.get("title", "")), ingredients=ings, total=Macros(**total),
                        trace=s.get("trace", []))


def session(stats: RunStats, **kw):
    """网页 / App 用：带检查点的 agent。第一次 invoke 会在 ask 节点用 interrupt 暂停并返回问题，
    用户回答后用 Command(resume=回答) 继续（LangGraph 的 human-in-the-loop）。"""
    from langgraph.checkpoint.memory import InMemorySaver
    return build(stats, None, **kw).compile(checkpointer=InMemorySaver())


def run(image, stats: RunStats, user=None, **kw) -> FoodAnalysis:
    app = build(stats, user, **kw).compile()
    s = app.invoke({"image": image}, {"recursion_limit": 25})
    return to_analysis(s)
