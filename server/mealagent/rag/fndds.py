"""营养知识库：USDA FNDDS（美国膳食调查食物营养数据库，约 5000 种日常食物和成品菜，公有领域 CC0）。

构建：python -m mealagent.rag.fndds
  1. 下载 FNDDS JSON，抽出每种食物每 100g 的热量、碳水、蛋白质、脂肪，以及常见份量（1 杯、1 片 …）的克重
  2. 建两种索引：BM25 关键词索引 + 向量索引（多语言句向量），检索时用倒数排名融合（RRF）合并
"""
from __future__ import annotations

import io
import json
import re
import threading
import urllib.request
import zipfile
from functools import lru_cache

import numpy as np

from ..config import DATA_DIR

URL = "https://fdc.nal.usda.gov/fdc-datasets/FoodData_Central_survey_food_json_2024-10-31.zip"
DIR = DATA_DIR / "fndds"
FOODS = DIR / "foods.jsonl"
EMB = DIR / "emb.npy"
EMBED_MODEL = "sentence-transformers/paraphrase-multilingual-mpnet-base-v2"
NUTR = {"208": "kcal", "205": "carbs", "203": "protein", "204": "fat"}
_LOCK = threading.Lock()
TOKEN = re.compile(r"[a-z]+")
STOP = {"ns", "as", "to", "nfs", "with", "and", "or", "in", "of", "from", "made", "type", "the", "a"}


def build():
    DIR.mkdir(parents=True, exist_ok=True)
    print("下载 FNDDS …")
    raw = urllib.request.urlopen(URL, timeout=300).read()
    with zipfile.ZipFile(io.BytesIO(raw)) as z:
        name = next(n for n in z.namelist() if n.endswith(".json"))
        data = json.loads(z.read(name))
    foods = []
    for f in data["SurveyFoods"]:
        n = {}
        for fn in f.get("foodNutrients", []):
            num = str(fn.get("nutrient", {}).get("number", ""))
            if num in NUTR:
                n[NUTR[num]] = float(fn.get("amount") or 0)
        if "kcal" not in n:
            continue
        portions = [{"desc": p.get("portionDescription", ""), "g": p.get("gramWeight")}
                    for p in f.get("foodPortions", []) if p.get("gramWeight")]
        foods.append({
            "id": f["fdcId"], "desc": f["description"],
            "cat": (f.get("wweiaFoodCategory") or {}).get("wweiaFoodCategoryDescription", ""),
            "per100g": {k: n.get(k, 0.0) for k in NUTR.values()},
            "portions": portions[:6],
        })
    with open(FOODS, "w") as out:
        for x in foods:
            out.write(json.dumps(x, ensure_ascii=False) + "\n")
    print(f"共 {len(foods)} 种食物，计算向量 …")
    vec = _embedder().encode([x["desc"] for x in foods], normalize_embeddings=True, batch_size=128, show_progress_bar=True)
    np.save(EMB, vec.astype(np.float32))
    print("完成")


@lru_cache(maxsize=1)
def _embedder():
    from sentence_transformers import SentenceTransformer
    return SentenceTransformer(EMBED_MODEL)


def tokens(s: str) -> list[str]:
    return [t for t in TOKEN.findall(s.lower()) if t not in STOP]


class Index:
    """混合检索：BM25 + 向量，倒数排名融合（RRF, k=60）。"""

    def __init__(self):
        if not FOODS.exists() or not EMB.exists():
            build()
        from rank_bm25 import BM25Okapi
        self.foods = [json.loads(l) for l in FOODS.read_text().splitlines()]
        self.emb = np.load(EMB)
        self.bm25 = BM25Okapi([tokens(f["desc"]) for f in self.foods])

    def search(self, queries: list[str], k: int = 5, pool: int = 30) -> list[list[dict]]:
        with _LOCK:
            qv = _embedder().encode(queries, normalize_embeddings=True, batch_size=64)
        sims = qv @ self.emb.T
        out = []
        for qi, q in enumerate(queries):
            dense = np.argsort(-sims[qi])[:pool]
            sparse = np.argsort(-self.bm25.get_scores(tokens(q)))[:pool]
            score: dict[int, float] = {}
            for rank_list in (dense, sparse):
                for r, i in enumerate(rank_list):
                    score[int(i)] = score.get(int(i), 0.0) + 1.0 / (60 + r + 1)
            best = sorted(score, key=score.get, reverse=True)[:k]
            out.append([dict(self.foods[i], sim=float(sims[qi, i])) for i in best])
        return out


_INDEX = None


def index() -> Index:
    global _INDEX
    with _BUILD_LOCK:
        if _INDEX is None:
            _INDEX = Index()
    return _INDEX


_BUILD_LOCK = threading.Lock()


if __name__ == "__main__":
    build()
