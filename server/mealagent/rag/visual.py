"""多模态 RAG：检索「外观相似、份量和营养已核实」的餐食照片，作为份量估计的参考示例。

为什么：前几轮评测发现误差主要来自克数估计，而不是营养密度。模型凭空估克数很难，
但给它看几张相似的、已知份量的参考照片，它可以「对照着估」（检索增强的 in-context 示例）。

参考库：JFB 中不在测试集里的 800 张（和测试集严格不重叠）。产品里参考库会换成公开称重数据集 + 用户自己纠正过的记录。
图像向量：CLIP ViT-B/32（sentence-transformers），余弦相似度检索。
构建：python -m mealagent.rag.visual
"""
from __future__ import annotations

import json
import threading

import numpy as np
from PIL import Image, ImageOps

from ..config import DATA_DIR

DIR = DATA_DIR / "visual"
META = DIR / "pool.jsonl"
EMB = DIR / "pool.npy"
MODEL = "clip-ViT-B-32"
_LOCK = threading.Lock()
_model = None
_index = None


def model():
    global _model
    if _model is None:
        from sentence_transformers import SentenceTransformer
        _model = SentenceTransformer(MODEL)
    return _model


def _img(path_or_img) -> Image.Image:
    im = path_or_img if isinstance(path_or_img, Image.Image) else Image.open(path_or_img)
    im = ImageOps.exif_transpose(im).convert("RGB")
    im.thumbnail((448, 448))
    return im


def build():
    from evals.datasets import split_jfb
    _, pool = split_jfb()
    DIR.mkdir(parents=True, exist_ok=True)
    print(f"参考库 {len(pool)} 张，计算图像向量 …")
    vecs = model().encode([_img(it["image"]) for it in pool], batch_size=32, normalize_embeddings=True, show_progress_bar=True)
    np.save(EMB, vecs.astype(np.float32))
    with open(META, "w") as f:
        for it in pool:
            f.write(json.dumps({"id": it["id"], "image": str(it["image"]), "meal_name": it["meal_name"],
                                "ingredients": it.get("ingredient_details", []), "macros": it["macros"]}, ensure_ascii=False) + "\n")
    print("完成")


class VisualIndex:
    def __init__(self):
        if not META.exists() or not EMB.exists():
            build()
        self.meta = [json.loads(l) for l in META.read_text().splitlines()]
        self.emb = np.load(EMB)

    def search(self, img: Image.Image, k: int = 3) -> list[dict]:
        with _LOCK:
            q = model().encode([_img(img)], normalize_embeddings=True)[0]
        sims = self.emb @ q
        top = np.argsort(-sims)[:k]
        return [dict(self.meta[i], sim=float(sims[i])) for i in top]


def index() -> VisualIndex:
    global _index
    with _LOCK:
        if _index is None:
            _index = VisualIndex()
    return _index


def describe(ex: dict) -> str:
    """把一条参考餐写成给模型看的中文说明（份量用数据集里的原始单位，并附每样的热量）。"""
    parts = []
    for i in ex["ingredients"][:12]:
        q, u = i.get("quantity"), i.get("unit", "")
        amount = f"{q:g} {u}".strip() if isinstance(q, (int, float)) else ""
        kcal = i.get("calories")
        parts.append(f'{i.get("name", "")} {amount}' + (f"（{kcal:.0f} kcal）" if isinstance(kcal, (int, float)) else ""))
    m = ex["macros"]
    return (f'{ex["meal_name"]}；食材：' + "，".join(parts) +
            f'；整餐 {m["calories"]:.0f} kcal，碳水 {m["carbs"]:.0f}g，蛋白质 {m["protein"]:.0f}g，脂肪 {m["fat"]:.0f}g')


if __name__ == "__main__":
    build()
