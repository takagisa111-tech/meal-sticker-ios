"""中文提示词系列（只比较技术，不再混入语言差异）：

zh_v2          中文提示词 + 检查清单 + 份量参照 + JSON 结构化输出，营养由模型估
zh_rag         zh_v2 + FNDDS 知识库：按英文名 + 检索词混合检索前 8 个候选，严格重排序，
               数据库值与模型估计做一致性校验（相差超过 2 倍视为匹配错误），通过则两者取平均
baseline_sc3   App 原提示词采样 3 次取平均（self-consistency，自洽性集成），三次请求并行
"""
from __future__ import annotations

from concurrent.futures import ThreadPoolExecutor

from PIL import Image

from ..llm import chat_json, encode_image
from ..prompts import recognize_zh, rerank
from ..rag.fndds import index
from ..schema import FoodAnalysis, Ingredient, Macros, RunStats
from . import baseline
from .rag import KEYS, num

FIELDS = {"kcal": "calories", "carbs": "carbs", "protein": "protein", "fat": "fat"}


def recognize(img, stats):
    r = chat_json(recognize_zh.USER, [img], stats=stats, system=recognize_zh.SYSTEM, json_mode=True, temperature=0.3)
    items = []
    for f in r.get("foods", []):
        if not isinstance(f, dict) or not f.get("name"):
            continue
        it = {"name": str(f["name"]), "name_en": str(f.get("name_en") or f["name"]), "usda_query": str(f.get("usda_query", "")),
              "grams": num(f.get("served_g") or f.get("grams"))}
        for k in KEYS:
            it[k] = num(f.get(k))
        it["llm"] = {k: it[k] for k in KEYS}
        items.append(it)
    total = {k: num(r.get(k)) for k in KEYS}
    if items and sum(it["kcal"] for it in items) > 0:
        total = {k: sum(it[k] for it in items) for k in KEYS}
    return {"title_en": str(r.get("title_en") or r.get("title", "")), "items": items, "total": total}


def to_analysis(r):
    ings = [Ingredient(name=it["name_en"], grams=it["grams"], calories=it["kcal"], carbs=it["carbs"], protein=it["protein"],
                       fat=it["fat"], source=it.get("source", "")) for it in r["items"]]
    return FoodAnalysis(meal_name=r["title_en"], ingredients=ings, total=Macros(**{FIELDS[k]: v for k, v in r["total"].items()}))


def zh_v2(img: Image.Image, stats: RunStats) -> FoodAnalysis:
    return to_analysis(recognize(img, stats))


def zh_rag(img: Image.Image, stats: RunStats) -> FoodAnalysis:
    r = recognize(img, stats)
    items = r["items"]
    if items:
        for it in items:
            it["usda_query"] = it["usda_query"] or it["name_en"]
        cands = index().search([f'{it["usda_query"]} {it["name_en"]}' for it in items], k=8)
        try:
            pick = chat_json(rerank.build([dict(it, name=it["name_en"]) for it in items], cands), stats=stats, system=rerank.SYSTEM, json_mode=True, temperature=0)
            chosen = {int(c["item"]): c.get("id") for c in pick.get("choices", []) if isinstance(c, dict) and "item" in c}
        except Exception:
            chosen = {}
        for i, (it, cs) in enumerate(zip(items, cands)):
            food = next((c for c in cs if str(c["id"]) == str(chosen.get(i))), None)
            if not food:
                continue
            db = {k: food["per100g"][k] * it["grams"] / 100 for k in KEYS}
            llm_k = it["llm"]["kcal"]
            if llm_k > 20 and db["kcal"] > 0 and not (0.5 <= db["kcal"] / llm_k <= 2.0):
                it["source"] = f'rejected FNDDS {food["id"]}: {food["desc"]}'
                continue
            it.update({k: (db[k] + it["llm"][k]) / 2 for k in KEYS})
            it["source"] = f'FNDDS {food["id"]}: {food["desc"]}'
        r["total"] = {k: sum(it[k] for it in items) for k in KEYS}
    return to_analysis(r)


def baseline_sc3(img: Image.Image, stats: RunStats) -> FoodAnalysis:
    data_url = encode_image(img)
    subs = [RunStats() for _ in range(3)]
    with ThreadPoolExecutor(3) as ex:
        outs = list(ex.map(lambda s: baseline.analyze_url(data_url, s, temperature=0.8), subs))
    stats.seconds += max(s.seconds for s in subs)
    stats.llm_calls += sum(s.llm_calls for s in subs)
    stats.input_tokens += sum(s.input_tokens for s in subs)
    stats.output_tokens += sum(s.output_tokens for s in subs)
    outs.sort(key=lambda a: a.total.calories)
    mid = outs[1]
    avg = Macros(**{k: sum(getattr(o.total, k) for o in outs) / 3 for k in ("calories", "carbs", "protein", "fat")})
    return FoodAnalysis(meal_name=mid.meal_name, ingredients=mid.ingredients, total=avg)


# ---------------- 多模态 RAG（检索相似的已核实餐食作为份量参照） ----------------
from ..prompts import recognize_zh_mm  # noqa: E402
from ..rag import visual  # noqa: E402


def _recognize_mm(img, stats, k: int, with_images: bool):
    refs = visual.index().search(img, k=k)
    prompt = recognize_zh_mm.build([visual.describe(r) for r in refs], with_images)
    images = [img] + ([encode_image(Image.open(r["image"]), max_side=512) for r in refs] if with_images else [])
    r = chat_json(prompt, images, stats=stats, system=recognize_zh_mm.SYSTEM, json_mode=True, temperature=0.3)
    items = []
    for f in r.get("foods", []):
        if not isinstance(f, dict) or not f.get("name"):
            continue
        it = {"name": str(f["name"]), "name_en": str(f.get("name_en") or f["name"]),
              "grams": num(f.get("served_g") or f.get("grams"))}
        for kk in KEYS:
            it[kk] = num(f.get(kk))
        items.append(it)
    total = {kk: num(r.get(kk)) for kk in KEYS}
    if items and sum(it["kcal"] for it in items) > 0:
        total = {kk: sum(it[kk] for it in items) for kk in KEYS}
    out = {"title_en": str(r.get("title_en") or r.get("title", "")), "items": items, "total": total}
    out["refs"] = [x["id"] for x in refs]
    return out


def zh_mm3(img, stats):
    """检索 3 张相似参考餐，图片 + 文字一起给模型。"""
    return to_analysis(_recognize_mm(img, stats, 3, True))


def zh_mm5(img, stats):
    """检索 5 张相似参考餐，图片 + 文字。"""
    return to_analysis(_recognize_mm(img, stats, 5, True))


def zh_mm3_text(img, stats):
    """消融：只给参考餐的文字（菜名、份量、营养），不给参考图片。"""
    return to_analysis(_recognize_mm(img, stats, 3, False))
