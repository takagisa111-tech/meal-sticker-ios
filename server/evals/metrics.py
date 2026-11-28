"""评测指标，计算方式和 January Food Benchmark 一致：
- 菜名相似度：菜名向量的余弦相似度
- 食材识别：匈牙利算法一对一匹配，相似度 ≥ 0.75 算命中，得到 precision / recall / F1
- 营养误差：热量、碳水、蛋白质、脂肪四项的 wMAPE（%）
- 综合分：加权几何平均（菜名 0.15、食材 0.40、营养 0.25、成本 0.10、速度 0.10）
区别：JFB 用 OpenAI text-embedding-3-small，这里用开源多语言向量模型（中文菜名也能和英文标注对比），
所以菜名和食材两项与 JFB 排行榜不能严格对比；营养 wMAPE 不依赖向量模型，可以直接对比。
"""
from __future__ import annotations
from functools import lru_cache

import numpy as np
from scipy.optimize import linear_sum_assignment

EMBED_MODEL = "sentence-transformers/paraphrase-multilingual-mpnet-base-v2"
THRESHOLD = 0.75
MACROS = ["calories", "carbs", "protein", "fat"]


@lru_cache(maxsize=1)
def _model():
    from sentence_transformers import SentenceTransformer
    return SentenceTransformer(EMBED_MODEL)


_cache: dict[str, np.ndarray] = {}


def embed(texts: list[str]) -> np.ndarray:
    todo = [t for t in dict.fromkeys(texts) if t not in _cache]
    if todo:
        vecs = _model().encode(todo, normalize_embeddings=True, batch_size=64)
        _cache.update(zip(todo, vecs))
    return np.array([_cache[t] for t in texts]) if texts else np.zeros((0, 768))


def _norm(names):
    return [str(n).lower().strip() for n in names if str(n).strip()]


def ingredient_scores(gt: list[str], pred: list[str]) -> dict:
    gt, pred = _norm(gt), _norm(pred)
    if not gt and not pred:
        return {"precision": 1.0, "recall": 1.0, "f1": 1.0, "matches": []}
    if not gt or not pred:
        return {"precision": 0.0 if pred else 1.0, "recall": 0.0, "f1": 0.0, "matches": []}
    sim = embed(gt) @ embed(pred).T
    rows, cols = linear_sum_assignment(1 - sim)
    matches = [(gt[r], pred[c], float(sim[r, c])) for r, c in zip(rows, cols) if sim[r, c] >= THRESHOLD]
    p, r = len(matches) / len(pred), len(matches) / len(gt)
    f1 = 0.0 if p + r == 0 else 2 * p * r / (p + r)
    return {"precision": p, "recall": r, "f1": f1, "matches": matches}


def name_similarity(gt: str, pred: str) -> float:
    if not str(pred).strip():
        return 0.0
    v = embed([str(gt).strip(), str(pred).strip()])
    return float(v[0] @ v[1])


def macro_wmape(gt: dict, pred: dict) -> float:
    err = sum(abs(gt.get(k, 0) - pred.get(k, 0)) for k in MACROS)
    tot = sum(abs(gt.get(k, 0)) for k in MACROS)
    if tot == 0:
        return 0.0 if err == 0 else 100.0
    return err / tot * 100


def overall_score(name_sim, f1, wmape, cost_usd, seconds, cost_ceiling=1.0, time_ceiling=60.0) -> float:
    w = {"name": 0.15, "ing": 0.40, "macro": 0.25, "cost": 0.10, "speed": 0.10}
    parts = {
        "name": min(max(name_sim, 0), 1),
        "ing": min(max(f1, 0), 1),
        "macro": min(max(1 - wmape / 100, 0), 1),
        "cost": 1 - min(cost_usd, cost_ceiling) / cost_ceiling,
        "speed": 1 - min(seconds, time_ceiling) / time_ceiling,
    }
    s = 1.0
    for k, v in parts.items():
        s *= v ** w[k]
    return 100 * s
