"""改进后的识别流程。每个版本只改一处，便于做消融实验、看清每项技术各贡献多少：

第一轮
  prompt_v2   新提示词（检查清单、份量参照、JSON 结构化输出），营养仍由模型自己估
  rag         prompt_v2 + FNDDS 知识库混合检索（BM25 + 向量，RRF 融合）取第 1 名，按每 100g 营养 × 克数计算
  rag_rerank  rag + LLM 从前 5 个候选里重排序挑选，挑不出来回退到模型估计
第二轮（针对第一轮发现的问题）
  prompt_v3   提示词校准：只记看得见的、份量取中位数、相同物品用 count
  rag_v3      prompt_v3 + 检索词合并（usda_query + 名称）+ 前 8 个候选 + 严格的重排序规则
  rag_ens_v3  rag_v3 + 一致性校验：数据库值和模型估计相差超过 2 倍视为匹配错误、用模型估计；否则两者取平均（集成）
"""
from __future__ import annotations

from types import ModuleType

from PIL import Image

from ..llm import chat_json
from ..prompts import recognize_v2, recognize_v3, rerank, rerank_v1
from ..rag.fndds import index
from ..schema import FoodAnalysis, Ingredient, Macros, RunStats

KEYS = ("kcal", "carbs", "protein", "fat")


def num(v) -> float:
    try:
        return max(0.0, float(v))
    except (TypeError, ValueError):
        return 0.0


def recognize(img: Image.Image, stats: RunStats, prompt: ModuleType) -> dict:
    r = chat_json(prompt.USER, [img], stats=stats, system=prompt.SYSTEM, json_mode=True, temperature=0.2)
    items = [it for it in r.get("items", []) if isinstance(it, dict) and it.get("name")]
    for it in items:
        n = max(1, int(num(it.get("count", 1)) or 1))
        it["count"] = n
        it["grams"] = num(it.get("grams")) * n
        for k in KEYS:
            it[k] = num(it.get(k)) * n
        it["llm"] = {k: it[k] for k in KEYS}
    return {"meal_name": str(r.get("meal_name", "")), "items": items}


def to_analysis(meal_name: str, items: list[dict]) -> FoodAnalysis:
    ings = [Ingredient(name=it["name"], grams=it["grams"], calories=it["kcal"], carbs=it["carbs"],
                       protein=it["protein"], fat=it["fat"],
                       source=(f'FNDDS {it["source"]["fdc_id"]}: {it["source"]["desc"]}' if it.get("source") else ""))
            for it in items]
    total = Macros(**{("calories" if k == "kcal" else k): sum(it[k] for it in items) for k in KEYS})
    return FoodAnalysis(meal_name=meal_name, ingredients=ings, total=total)


def apply_db(it: dict, food: dict, mode: str = "db") -> None:
    """mode=db 直接用数据库值；mode=ensemble 先做一致性校验，再和模型估计取平均。"""
    f = it["grams"] / 100.0
    db = {k: food["per100g"][k] * f for k in KEYS}
    if mode == "ensemble":
        llm_k, db_k = it["llm"]["kcal"], db["kcal"]
        if llm_k > 20 and db_k > 0 and not (0.5 <= db_k / llm_k <= 2.0):
            it["source"] = {"fdc_id": food["id"], "desc": "rejected: " + food["desc"]}
            return
        db = {k: (db[k] + it["llm"][k]) / 2 for k in KEYS}
    it["source"] = {"fdc_id": food["id"], "desc": food["desc"]}
    it.update(db)


def _rerank(items, cands, stats, prompt_mod):
    try:
        pick = chat_json(prompt_mod.build(items, cands), stats=stats, system=prompt_mod.SYSTEM, json_mode=True, temperature=0)
        return {int(c["item"]): c.get("id") for c in pick.get("choices", []) if isinstance(c, dict) and "item" in c}
    except Exception:
        return {}


def _with_db(img, stats, prompt, k, rerank_mod, query, mode):
    r = recognize(img, stats, prompt)
    items = r["items"]
    if items:
        cands = index().search([query(it) for it in items], k=k)
        if rerank_mod is None:
            chosen = {i: c[0]["id"] for i, c in enumerate(cands) if c}
        else:
            chosen = _rerank(items, cands, stats, rerank_mod)
        for i, (it, cs) in enumerate(zip(items, cands)):
            food = next((c for c in cs if str(c["id"]) == str(chosen.get(i))), None)
            if food:
                apply_db(it, food, mode)
    return to_analysis(r["meal_name"], items)


def q_v2(it):
    return it.get("usda_query") or it["name"]


def q_v3(it):
    return f'{it.get("usda_query", "")} {it["name"]}'.strip()


def prompt_v2(img, stats):
    r = recognize(img, stats, recognize_v2)
    return to_analysis(r["meal_name"], r["items"])


def rag(img, stats):
    return _with_db(img, stats, recognize_v2, 1, None, q_v2, "db")


def rag_rerank(img, stats):
    return _with_db(img, stats, recognize_v2, 5, rerank_v1, q_v2, "db")


def prompt_v3(img, stats):
    r = recognize(img, stats, recognize_v3)
    return to_analysis(r["meal_name"], r["items"])


def rag_v3(img, stats):
    return _with_db(img, stats, recognize_v3, 8, rerank, q_v3, "db")


def rag_ens_v3(img, stats):
    return _with_db(img, stats, recognize_v3, 8, rerank, q_v3, "ensemble")
