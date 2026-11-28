"""评测公平性：基线输出中文菜名，标注是英文。跨语言比对会吃亏，
所以打分前把中文名统一翻译成英文（文本调用，结果缓存，不计入各方案的耗时和成本）。"""
from __future__ import annotations

import json
import re

from mealagent.config import DATA_DIR
from mealagent.llm import chat_json

CJK = re.compile(r"[一-鿿]")
CACHE = DATA_DIR / "translate_cache.json"


def has_cjk(s: str) -> bool:
    return bool(CJK.search(s or ""))


def to_english(names: list[str]) -> dict[str, str]:
    cache = json.loads(CACHE.read_text()) if CACHE.exists() else {}
    todo = sorted({n for n in names if has_cjk(n) and n not in cache})
    for i in range(0, len(todo), 80):
        chunk = todo[i:i + 80]
        prompt = ("Translate each Chinese food name into the common English food name a nutrition app would use. "
                  "Keep it short and literal. Return JSON: {\"t\": {\"<chinese>\": \"<english>\"}}\n\n" + "\n".join(chunk))
        r = chat_json(prompt, json_mode=True, temperature=0)
        cache.update({k: str(v) for k, v in (r.get("t") or {}).items()})
        CACHE.parent.mkdir(parents=True, exist_ok=True)
        CACHE.write_text(json.dumps(cache, ensure_ascii=False, indent=1))
    return {n: cache.get(n, n) for n in names}
