"""一周晚饭菜单 agent（plan → verify → revise）。

约束（全部由程序检查，validate_plan 返回违规清单）：
  7 天晚饭都来自真实菜谱库（recipe_id 存在）、不重复；每顿热量在范围内；至少 2 顿鱼/水产；至少 4 顿有蔬菜；
  不含过敏原；老人不吃油炸/偏硬的；第 1、2 天各用上至少一样冰箱里的食材；工作日（第 1–5 天）难度 ≤ 3 星。

三个版本（消融）：
  single         一次生成：把菜谱库（约 300 道）全部给模型，直接排菜单
  single_verify  一次生成 + 程序检查 + 带着违规清单最多改 2 次（只有「校验-修改」循环，没有工具）
  agent          ReAct agent：自己检索菜谱（混合检索 RAG）、查冰箱、调用 validate_plan 自检，直到通过
"""
from __future__ import annotations

import json

from ..llm import extract_json
from ..schema import RunStats
from . import react, safety
from .planner import _llm
from .tools import recipe_db
from evals.planning import WORDS  # 蔬菜 / 水产关键词

MAX_FIX = 2


def _flags(r: dict) -> dict:
    ings = "".join(r["ingredients"]) + r["title"]
    return {"fish": r["category"] == "水产" or any(w in ings for w in WORDS["fish"]),
            "veg": r["category"] == "素菜" or any(w in ings for w in WORDS["veg"] + WORDS["dark_veg"])}


def eligible() -> list[dict]:
    rs, _ = recipe_db()
    return [r for r in rs if r["category"] in ("荤菜", "素菜", "水产", "汤", "主食") and r.get("kcal")]


def validate(plan: list, sc: dict) -> list[str]:
    rs, _ = recipe_db()
    by_id = {r["id"]: r for r in rs}
    m = sc["member"]
    lo, hi = sc["kcal_range"]
    v = []
    days = {}
    for p in plan if isinstance(plan, list) else []:
        if isinstance(p, dict):
            try:
                days[int(p.get("day"))] = p.get("recipe_id")
            except (TypeError, ValueError):
                pass
    if sorted(days) != list(range(1, 8)):
        v.append(f"需要第 1–7 天各一顿，现在是：{sorted(days)}")
    ids = [days[d] for d in sorted(days)]
    if len(set(ids)) != len(ids):
        v.append("有重复的菜")
    fish = veg = 0
    for d in sorted(days):
        r = by_id.get(days[d])
        if not r:
            v.append(f"第{d}天：菜谱 {days[d]} 不存在")
            continue
        f = _flags(r)
        fish += f["fish"]
        veg += f["veg"]
        if not r.get("kcal") or not (lo <= r["kcal"] <= hi):
            v.append(f"第{d}天「{r['title']}」热量 {r.get('kcal')} 不在 {lo}–{hi} 千卡范围内")
        bad = safety.check(m["kind"], m.get("allergies", []), r["ingredients"] + [r["title"]])
        if m["kind"] == "elder" and any(w in "、".join(safety.expand([r["title"]])) for w in safety.HARD_FOR_ELDER):
            bad.append("老人难咀嚼（油炸/偏硬）")
        if bad:
            v.append(f"第{d}天「{r['title']}」：" + "；".join(bad))
        if d <= 5 and (r.get("difficulty") or 5) > 3:
            v.append(f"第{d}天「{r['title']}」难度 {r.get('difficulty')} 星，工作日要 ≤3 星")
        if d <= 2 and not any(x in ing or ing in x for x in sc["fridge"] for ing in r["ingredients"]):
            v.append(f"第{d}天「{r['title']}」没有用上冰箱里的食材（{('、'.join(sc['fridge']))}）")
    if fish < 2:
        v.append(f"鱼/水产只有 {fish} 顿，至少要 2 顿")
    if veg < 4:
        v.append(f"有蔬菜的只有 {veg} 顿，至少要 4 顿")
    return v


def _task(sc: dict) -> str:
    m = sc["member"]
    lo, hi = sc["kcal_range"]
    who = f"{m['name']}（{m['age']}岁{'，对' + '、'.join(m['allergies']) + '过敏' if m['allergies'] else ''}{'，牙口不好要软烂' if m['kind'] == 'elder' else ''}）"
    return (f"请给{who}排下周 7 天的晚饭，每天一道菜，全部来自菜谱库并写上 recipe_id。要求：\n"
            f"1. 7 道菜不重复；2. 每顿热量在 {lo}–{hi} 千卡；3. 至少 2 顿鱼或水产；4. 至少 4 顿有蔬菜；\n"
            f"5. 不能有过敏原{'，不要油炸或偏硬的' if m['kind'] == 'elder' else ''}；6. 第 1、2 天各用上至少一样冰箱里的食材：{'、'.join(sc['fridge'])}；\n"
            f"7. 第 1–5 天是工作日，难度不超过 3 星。\n"
            '最后只输出 JSON：{"plan": [{"day": 1, "recipe_id": "R012", "dish": "菜名"}, …], "notes": "一句话说明"}')


def _catalog() -> str:
    lines = []
    for r in eligible():
        f = _flags(r)
        lines.append(f'{r["id"]}|{r["title"]}|{r["category"]}|{r["kcal"]:.0f}kcal|难度{r.get("difficulty") or "?"}|'
                     f'{"鱼" if f["fish"] else ""}{"菜" if f["veg"] else ""}|{"、".join(r["ingredients"][:8])}')
    return "菜谱库（id|菜名|类别|每份热量|难度|含鱼/含菜|主要用料）：\n" + "\n".join(lines)


def run_single(sc: dict, stats: RunStats, verify: bool = False) -> dict:
    msgs = [{"role": "system", "content": "你是「食贴」的家庭菜单规划师。只输出 JSON。"},
            {"role": "user", "content": _catalog() + "\n\n" + _task(sc)}]
    m = _llm(msgs, stats)
    out = extract_json(m.content or "") or {}
    rounds = 0
    while verify and rounds < MAX_FIX:
        v = validate(out.get("plan", []), sc)
        if not v:
            break
        msgs += [{"role": "assistant", "content": m.content or ""},
                 {"role": "user", "content": "程序检查发现这些问题：\n" + "\n".join(v) + "\n请修改后重新输出完整 JSON。"}]
        m = _llm(msgs, stats)
        out = extract_json(m.content or "") or out
        rounds += 1
    return {"plan": out.get("plan", []), "rounds": rounds, "tool_calls": []}


TOOLS = [
    {"type": "function", "function": {"name": "search_recipes", "description": "混合检索（关键词 + 语义）菜谱库，返回 id、菜名、类别、每份热量、难度、是否含鱼/蔬菜、主要用料。已自动排除过敏原。",
     "parameters": {"type": "object", "properties": {"query": {"type": "string"}, "must_use": {"type": "array", "items": {"type": "string"}},
                                                     "max_difficulty": {"type": "integer"}, "kcal_min": {"type": "number"}, "kcal_max": {"type": "number"}},
                    "required": ["query"]}}},
    {"type": "function", "function": {"name": "validate_plan", "description": "用程序检查一版菜单是否满足全部要求，返回违规清单（空表示全部通过）。提交最终答案前必须调用并通过。",
     "parameters": {"type": "object", "properties": {"plan": {"type": "array", "items": {"type": "object", "properties": {
         "day": {"type": "integer"}, "recipe_id": {"type": "string"}}}}}, "required": ["plan"]}}},
]


def run_agent(sc: dict, stats: RunStats) -> dict:
    from .tools import Toolbox
    tb = Toolbox({**sc, "restaurants": [], "log": []})
    calls = []

    def call(name, args):
        calls.append(name)
        if name == "search_recipes":
            res = tb.search_recipes(args.get("query", ""), must_use=args.get("must_use"), k=12)
            rs, _ = recipe_db()
            by_id = {r["id"]: r for r in rs}
            out = []
            for x in res:
                r = by_id[x["recipe_id"]]
                if r["category"] not in ("荤菜", "素菜", "水产", "汤", "主食") or not r.get("kcal"):
                    continue
                if args.get("max_difficulty") and (r.get("difficulty") or 5) > args["max_difficulty"]:
                    continue
                if args.get("kcal_min") and r["kcal"] < args["kcal_min"] or args.get("kcal_max") and r["kcal"] > args["kcal_max"]:
                    continue
                out.append({**x, "difficulty": r.get("difficulty"), **_flags(r)})
            return out
        if name == "validate_plan":
            v = validate(args.get("plan", []), sc)
            return {"ok": not v, "violations": v}
        return {"error": "未知工具"}

    system = ("你是「食贴」的家庭菜单规划 agent。用 search_recipes 多次检索候选菜（可以按鱼、蔬菜、冰箱食材、软烂等分别搜），"
              "排出一版后调用 validate_plan 检查，有违规就换菜再检查，直到全部通过，再输出最终 JSON。")
    app = react.build(_llm, TOOLS, call, stats, max_steps=14)
    s = app.invoke({"messages": [{"role": "system", "content": system}, {"role": "user", "content": _task(sc)}]}, {"recursion_limit": 40})
    out = extract_json(react.final_text(s["messages"])) or {}
    return {"plan": out.get("plan", []), "rounds": calls.count("validate_plan"), "tool_calls": calls}
