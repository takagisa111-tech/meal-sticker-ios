"""通用混合检索（中文友好）：字符二元组 BM25 + 多语言句向量，RRF 融合。用于膳食指南卡片和菜谱。"""
from __future__ import annotations

import os
import re
import threading

import numpy as np

from .fndds import _embedder

_LOCK = threading.Lock()
# 云端免费实例内存小（512MB），设 BUTLER_DENSE=0 只用 BM25；本地和评测默认开启向量检索（混合 RRF）
DENSE = os.getenv("BUTLER_DENSE", "1") != "0"


def bigrams(s: str) -> list[str]:
    s = re.sub(r"\s+", "", s.lower())
    toks = re.findall(r"[a-z]+", s)
    han = re.sub(r"[a-z0-9]+", "", s)
    return toks + [han[i:i + 2] for i in range(len(han) - 1)] + list(han)


class HybridIndex:
    def __init__(self, texts: list[str]):
        from rank_bm25 import BM25Okapi
        self.texts = texts
        self.bm25 = BM25Okapi([bigrams(t) for t in texts])
        self.emb = None
        if DENSE:
            with _LOCK:
                self.emb = _embedder().encode(texts, normalize_embeddings=True, batch_size=64)

    def search(self, query: str, k: int = 5, pool: int = 30) -> list[tuple[int, float]]:
        sparse = np.argsort(-self.bm25.get_scores(bigrams(query)))[:pool]
        lists = [sparse]
        if self.emb is not None:
            with _LOCK:
                q = _embedder().encode([query], normalize_embeddings=True)[0]
            lists.append(np.argsort(-(self.emb @ q))[:pool])
        score: dict[int, float] = {}
        for lst in lists:
            for r, i in enumerate(lst):
                score[int(i)] = score.get(int(i), 0.0) + 1.0 / (60 + r + 1)
        best = sorted(score, key=score.get, reverse=True)[:k]
        return [(i, score[i]) for i in best]
