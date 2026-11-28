"""规划 agent 可以调用的工具（OpenAI / DeepSeek function calling 格式）。

每个工具都是普通 Python 函数，读写一个「场景」（一位家庭成员的档案、近 7 天饮食记录、冰箱、附近餐厅）。
写操作（加购物清单、设提醒）只记录在 actions 里，评测时检查调用得对不对。
"""
from __future__ import annotations

import json
import threading
from collections import defaultdict

from ..knowledge import guidelines, recipes
from ..rag.kb import HybridIndex
from . import safety

# 每天推荐量（克），来自膳食指南卡片 G3–G7（成人）与 E1–E3（老人）
TARGETS = {
    "veg": (300, 500, "G4"), "dark_veg": (150, 250, "G4"), "fruit": (200, 350, "G5"), "dairy": (300, 500, "G6"),
    "whole_grain": (50, 150, "G3"), "protein": (120, 200, "G7"), "fish": (40, 75, "G7"), "soy_nut": (25, 35, "G1"),
}
GROUP_NAMES = {"veg": "蔬菜", "dark_veg": "深色蔬菜", "fruit": "水果", "dairy": "奶类", "whole_grain": "全谷物杂豆",
               "protein": "鱼禽蛋瘦肉", "fish": "鱼虾水产", "soy_nut": "大豆坚果"}
GROUP_OF = {"veg": ["veg"], "dark_veg": ["veg", "dark_veg"], "fruit": ["fruit"], "dairy": ["dairy"],
            "whole_grain": ["whole_grain"], "meat": ["protein"], "egg": ["protein"], "seafood": ["protein", "fish"],
            "soy_nut": ["soy_nut"]}

_recipes = None
_recipe_idx = None
_guide_idx = None
_INIT = threading.Lock()  # 多个请求并发时，索引只建一次（修复：之前会读到建了一半的索引）


def recipe_db():
    global _recipes, _recipe_idx
    with _INIT:
        if _recipe_idx is None:
            rs = recipes.load()
            _recipe_idx = HybridIndex([f'{r["title"]} {r["category"]} {" ".join(r["ingredients"])} {r["intro"]}' for r in rs])
            _recipes = rs
    return _recipes, _recipe_idx


def guide_db():
    global _guide_idx
    with _INIT:
        if _guide_idx is None:
            _guide_idx = HybridIndex([f'{c["title"]} {c["text"]} {" ".join(c["tags"])}' for c in guidelines.CARDS])
    return guidelines.CARDS, _guide_idx


class Toolbox:
    def __init__(self, scenario: dict):
        self.s = scenario
        self.actions: list[dict] = []
        self.calls: list[str] = []
        self.recipe_seen: dict[str, dict] = {}

    # ---------- 读 ----------
    def get_profile(self):
        return self.s["member"]

    def get_nutrition_summary(self, days: int = 7):
        log = self.s["log"][-days:]
        tot = defaultdict(float)
        flags = defaultdict(int)
        for day in log:
            for f in day["foods"]:
                for g in GROUP_OF.get(f["group"], []):
                    tot[g] += f["grams"]
            for fl in day.get("flags", []):
                flags[fl] += 1
        n = max(1, len(log))
        out = []
        for g, (lo, hi, src) in TARGETS.items():
            avg = tot[g] / n
            status = "不足" if avg < lo * 0.8 else ("偏多" if avg > hi * 1.3 else "达标")
            out.append({"group": GROUP_NAMES[g], "key": g, "daily_avg_g": round(avg), "target_g": f"{lo}–{hi}",
                        "status": status, "guideline": src})
        gaps = sorted([o for o in out if o["status"] == "不足"], key=lambda o: o["daily_avg_g"] / TARGETS[o["key"]][0])
        return {"days": n, "groups": out, "biggest_gaps": [g["group"] for g in gaps[:3]],
                "frequent_flags": {k: v for k, v in flags.items() if v >= 2}}

    def search_guidelines(self, query: str, k: int = 3):
        cards, idx = guide_db()
        kind = self.s["member"]["kind"]
        hits = [cards[i] for i, _ in idx.search(query, k=k + 3)]
        if kind in ("dog", "cat"):
            hits = sorted(hits, key=lambda c: "pet" not in c["tags"])
        elif kind == "elder":
            hits = sorted(hits, key=lambda c: "elder" not in c["tags"])
        return [{"id": c["id"], "title": c["title"], "text": c["text"], "source": c["source"]} for c in hits[:k]]

    def search_recipes(self, query: str, must_use: list | None = None, avoid: list | None = None, k: int = 5):
        rs, idx = recipe_db()
        q = query + " " + " ".join(must_use or [])
        avoid = list(avoid or []) + list(self.s["member"].get("allergies", []))
        out = []
        for i, _ in idx.search(q, k=40):
            r = rs[i]
            if r["category"] in ("调料", "饮品", "半成品"):
                continue
            if safety.check(self.s["member"]["kind"], avoid, r["ingredients"]) or any(a in "".join(r["ingredients"]) for a in avoid):
                continue
            fridge_hit = [x for x in self.s.get("fridge", []) if any(x in ing or ing in x for ing in r["ingredients"])]
            out.append({"recipe_id": r["id"], "title": r["title"], "category": r["category"], "ingredients": r["ingredients"],
                        "kcal_per_serving": r["kcal"], "uses_from_fridge": fridge_hit})
            self.recipe_seen[r["id"]] = r
            if len(out) >= k:
                break
        return out

    def get_fridge(self):
        return {"items": self.s.get("fridge", [])}

    def find_restaurants(self, cuisine: str | None = None, max_price: float | None = None):
        rs = self.s.get("restaurants", [])
        return [r for r in rs if (not cuisine or cuisine in r["cuisine"]) and (not max_price or r["price"] <= max_price)] or rs

    def check_food_safety(self, foods: list):
        m = self.s["member"]
        return {"issues": safety.check(m["kind"], m.get("allergies", []), [str(f) for f in foods])}

    # ---------- 写 ----------
    def add_to_shopping_list(self, items: list):
        self.actions.append({"type": "shopping", "items": [str(i) for i in items]})
        return {"ok": True, "added": items}

    def create_reminder(self, when: str, text: str):
        self.actions.append({"type": "reminder", "when": when, "text": text})
        return {"ok": True}

    def call(self, name: str, args: dict):
        self.calls.append(name)
        fn = getattr(self, name, None)
        if fn is None or name.startswith("_") or name == "call":
            return {"error": f"没有这个工具：{name}"}
        try:
            return fn(**args)
        except TypeError as e:
            return {"error": f"参数不对：{e}"}


def _f(name, desc, props, req=()):
    return {"type": "function", "function": {"name": name, "description": desc,
            "parameters": {"type": "object", "properties": props, "required": list(req)}}}


S, A = {"type": "string"}, {"type": "array", "items": {"type": "string"}}
SCHEMAS = [
    _f("get_profile", "查看这位家庭成员的档案：类型（成人/老人/猫/狗）、年龄、过敏、忌口、目标。", {}),
    _f("get_nutrition_summary", "按膳食指南统计最近几天各类食物的日均摄入、是否达标、最大的缺口，以及常见问题（重盐、油炸等）。", {"days": {"type": "integer"}}),
    _f("search_guidelines", "检索膳食指南知识库（成人、老年人、宠物），返回带 id 的原文要点，回答里引用这些 id。", {"query": S}, ["query"]),
    _f("search_recipes", "检索家常菜谱库，返回菜名、用料、每份热量、能用上冰箱里的哪些东西。已自动排除过敏原和宠物禁忌。",
       {"query": S, "must_use": A, "avoid": A}, ["query"]),
    _f("get_fridge", "查看冰箱里现有的食材。", {}),
    _f("find_restaurants", "查附近餐厅（菜系、人均、招牌菜）。", {"cuisine": S, "max_price": {"type": "number"}}),
    _f("check_food_safety", "检查一组食物/食材对这位成员是否安全（过敏原、宠物有毒食物）。", {"foods": A}, ["foods"]),
    _f("add_to_shopping_list", "把食材加入购物清单（只加冰箱里没有的）。", {"items": A}, ["items"]),
    _f("create_reminder", "创建提醒，比如吃饭、备菜、买菜。", {"when": S, "text": S}, ["when", "text"]),
]
