"""plan_week 的内层 agent（LangGraph ReAct）：检索菜谱 → 排菜单 → validate_plan 程序校验 → 不通过就换菜，直到通过。
评测（evals/weekly.py，12 个场景）：一次生成 0% 合格，加校验-修改 50%，agent 自己检索 + 校验 100%。
这里把评测里写死的场景换成用户的真实情况：成员档案、忌口、冰箱、最近吃过的菜。"""
from __future__ import annotations

import datetime as dt
from ..agent import react
from ..agent.planner import _llm
from ..agent.tools import recipe_db
from ..llm import extract_json
from . import prompts

FISH = ["鱼", "虾", "蟹", "贝", "鱿鱼", "蛤", "海带", "紫菜"]
VEG = ["菜", "瓜", "茄", "豆角", "西兰花", "菠菜", "番茄", "西红柿", "胡萝卜", "萝卜", "青椒", "蘑菇", "菇", "笋", "藕", "芹", "生菜", "白菜", "土豆", "洋葱"]
WEEKDAY = "一二三四五六日"


def flags(r: dict) -> dict:
    ings = "".join(r["ingredients"]) + r["title"]
    return {"fish": r["category"] == "水产" or any(w in ings for w in FISH),
            "veg": r["category"] == "素菜" or any(w in ings for w in VEG)}


def kcal_range(tb, m: dict, lo, hi) -> tuple[float, float]:
    if lo and hi:
        return float(lo), float(hi)
    t = float(m.get("kcal_target") or (1650 if m["kind"] == "elder" else 1900))
    if m.get("goal") == "lose":
        return 200.0, round(t * 0.33)
    return (200.0, 700.0) if m["kind"] == "elder" else (250.0, round(t * 0.42))


def validate(tb, plan: list, m: dict, days: int, lo: float, hi: float) -> list[str]:
    rs, _ = recipe_db()
    by_id = {r["id"]: r for r in rs}
    v, chosen, sides = [], {}, {}
    for p in plan if isinstance(plan, list) else []:
        try:
            chosen[int(p.get("day"))] = p.get("recipe_id")
            if p.get("side_id"):
                sides[int(p.get("day"))] = p.get("side_id")
        except (TypeError, ValueError, AttributeError):
            pass
    if sorted(chosen) != list(range(1, days + 1)):
        v.append(f"需要第 1–{days} 天各一顿，现在是：{sorted(chosen)}")
    ids = [chosen[d] for d in sorted(chosen)] + list(sides.values())
    if len(set(ids)) != len(ids):
        v.append("有重复的菜")
    recent = {r.get("title") for r in tb.ctx.recs(m["id"]) if r.get("date", "") >= (dt.date.fromisoformat(tb.ctx.today) - dt.timedelta(days=3)).isoformat()}
    start = _start(tb)
    fish = veg = 0
    for d in sorted(chosen):
        r = by_id.get(chosen[d])
        side = by_id.get(sides.get(d)) if sides.get(d) else None
        if not r:
            v.append(f"第{d}天：菜谱 {chosen[d]} 不存在")
            continue
        if sides.get(d) and not side:
            v.append(f"第{d}天：配菜 {sides[d]} 不存在")
        dishes = [r] + ([side] if side else [])
        f = flags(r)
        fish += f["fish"]
        veg += any(flags(x)["veg"] for x in dishes)
        total = sum(x.get("kcal") or 0 for x in dishes)
        name = "+".join(x["title"] for x in dishes)
        if not r.get("kcal") or not (lo <= total <= hi):
            v.append(f"第{d}天「{name}」热量 {total:.0f} 不在 {lo:.0f}–{hi:.0f} 千卡范围内")
        date = start + dt.timedelta(days=d - 1)
        for x in dishes:
            bad = tb._recipe_ok(x, m, [])
            if bad:
                v.append(f"第{d}天「{x['title']}」：" + "；".join(bad))
            if date.isoweekday() <= 5 and (x.get("difficulty") or 5) > 3:
                v.append(f"第{d}天（周{WEEKDAY[date.isoweekday() - 1]}）「{x['title']}」难度 {x.get('difficulty')} 星，工作日要 ≤3 星")
            if x["title"] in recent:
                v.append(f"第{d}天「{x['title']}」最近 3 天刚吃过")
    if tb.ctx.fridge and days >= 2:
        early = [by_id.get(x) for d in (1, 2) for x in (chosen.get(d), sides.get(d)) if x]
        if not any(r and any(x in ing or ing in x for x in tb.ctx.fridge for ing in r["ingredients"]) for r in early):
            v.append(f"前两天至少有一顿要用上冰箱里的食材（{'、'.join(tb.ctx.fridge[:10])}）")
    need_fish, need_veg = (2, 4) if days >= 7 else (1 if days >= 4 else 0, max(1, days // 2))
    if fish < need_fish:
        v.append(f"鱼/水产只有 {fish} 顿，至少要 {need_fish} 顿")
    if veg < need_veg:
        v.append(f"有蔬菜的只有 {veg} 顿，至少要 {need_veg} 顿")
    return v


TOOLS = [
    {"type": "function", "function": {"name": "search_recipes", "description": "检索菜谱库，返回 id、菜名、类别、每份热量、难度、是否含鱼/蔬菜、主要用料、冰箱里有的食材。已排除过敏原和忌口。",
     "parameters": {"type": "object", "properties": {"query": {"type": "string"}, "must_use": {"type": "array", "items": {"type": "string"}},
                                                     "max_difficulty": {"type": "integer"}}, "required": ["query"]}}},
    {"type": "function", "function": {"name": "validate_plan", "description": "用程序检查一版菜单，返回违规清单（空 = 全部通过）。输出最终答案前必须调用并通过。",
     "parameters": {"type": "object", "properties": {"plan": {"type": "array", "items": {"type": "object", "properties": {
         "day": {"type": "integer"}, "recipe_id": {"type": "string", "description": "主菜"}, "side_id": {"type": "string", "description": "可选的配菜（一般是素菜）"}}}}},
        "required": ["plan"]}}},
]


def _start(tb) -> dt.date:
    """第一天：用户说了从哪天开始（如「下周一」）就用那天，否则从明天开始。"""
    try:
        d = dt.date.fromisoformat(str(getattr(tb, "plan_start", "") or ""))
        if d >= dt.date.fromisoformat(tb.ctx.today):
            return d
    except ValueError:
        pass
    return dt.date.fromisoformat(tb.ctx.today) + dt.timedelta(days=1)


def run_plan(tb, m: dict, days: int, requirements: str, lo, hi) -> dict:
    lo, hi = kcal_range(tb, m, lo, hi)
    start = _start(tb)
    dates = [start + dt.timedelta(days=i) for i in range(days)]
    rounds = {"validate": 0}
    last_v: list[str] = []

    def call(name, args):
        if name == "search_recipes":
            res = tb.search_recipes(args.get("query", ""), must_use=args.get("must_use"), max_difficulty=args.get("max_difficulty"),
                                    member_id=m["id"], k=12)
            rs, _ = recipe_db()
            by_id = {r["id"]: r for r in rs}
            for x in res.get("results", []):
                f = flags(by_id[x["recipe_id"]])
                x["fish"], x["veg"] = f["fish"], f["veg"]
                x.pop("need_to_buy", None)
            tb.emit({"type": "note", "text": f'检索「{args.get("query", "")}」→ {len(res.get("results", []))} 道'})
            return res
        if name == "validate_plan":
            rounds["validate"] += 1
            v = validate(tb, args.get("plan", []), m, days, lo, hi)
            last_v[:] = v
            tb.emit({"type": "note", "text": f'第 {rounds["validate"]} 次校验：' + ("全部通过 ✓" if not v else f"{len(v)} 处不满足")})
            return {"violations": v, "passed": not v}
        return {"error": "未知工具"}

    who = f'{m.get("name") or "用户"}（{ {"me": "成年人", "elder": "老人"}.get(m["kind"], "成年人") }' + \
          (f'，忌口/过敏：{m["avoid"]}' if m.get("avoid") else "") + "）"
    task = (f"请给{who}排 {days} 天晚饭（从 {dates[0].isoformat()} 周{WEEKDAY[dates[0].isoweekday() - 1]} 开始），每天一道主菜，可以再配一道素菜（side_id），全部来自菜谱库。要求：\n"
            f"1. 不重复；2. 每顿（主菜+配菜合计）{lo:.0f}–{hi:.0f} 千卡；3. 鱼/水产和蔬菜要够（validate_plan 会告诉你具体数量）；"
            f"4. 工作日难度 ≤3 星；5. 不要最近 3 天吃过的菜" + (f"；6. 前两天优先用上冰箱里的：{'、'.join(tb.ctx.fridge[:12])}" if tb.ctx.fridge else "") +
            (f"\n用户的额外要求：{requirements}" if requirements else "") +
            ("\n用户长期偏好：" + "；".join(x["text"] for x in tb.ctx.relevant_memories(requirements or "口味 忌口 喜欢", k=8)) if tb.ctx.memories else ""))
    app = react.build(_llm, TOOLS, call, tb.stats, max_steps=10)
    s = app.invoke({"messages": [{"role": "system", "content": prompts.PLAN_SYSTEM}, {"role": "user", "content": task}]}, {"recursion_limit": 40})
    out = extract_json(react.final_text(s["messages"])) or {}
    plan = out.get("plan", [])
    v = validate(tb, plan, m, days, lo, hi)
    rs, _ = recipe_db()
    by_id = {r["id"]: r for r in rs}
    rows, buy = [], []
    for p in sorted([p for p in plan if isinstance(p, dict) and p.get("recipe_id") in by_id], key=lambda p: int(p.get("day", 0))):
        r = by_id[p["recipe_id"]]
        side = by_id.get(p.get("side_id") or "")
        d = dates[min(days, max(1, int(p["day"]))) - 1]
        f = flags(r)
        rows.append({"day": int(p["day"]), "date": d.isoformat(), "weekday": "周" + WEEKDAY[d.isoweekday() - 1], "recipe_id": r["id"],
                     "title": r["title"], "side_id": side["id"] if side else None, "side": side["title"] if side else None,
                     "kcal": (r.get("kcal") or 0) + ((side or {}).get("kcal") or 0), "difficulty": r.get("difficulty"),
                     "fish": f["fish"], "veg": f["veg"] or bool(side and flags(side)["veg"])})
        for x in [r] + ([side] if side else []):
            tb.recipes[x["id"]] = x
            _, need = tb._fridge_split(x)
            buy += [y for y in need if y not in buy]
    checks = [f"每顿 {lo:.0f}–{hi:.0f} kcal", "不重复", "鱼和蔬菜次数", "过敏 / 忌口", "工作日 ≤3 星"] + (["用上冰箱食材"] if tb.ctx.fridge else [])
    tb.cards.append({"kind": "plan", "member": m.get("name") or "", "rows": rows, "passed": not v, "violations": v, "checks": checks,
                     "rounds": rounds["validate"], "shopping": buy[:30], "notes": out.get("notes", ""),
                     "details": {rid: tb.recipe_card(rid) for x in rows for rid in (x["recipe_id"], x["side_id"]) if rid}})
    summary = f'{len(rows)} 天 · 校验 {rounds["validate"]} 次 · ' + ("全部通过" if not v else f"仍有 {len(v)} 处不满足")
    return {"summary": summary, "plan": [f'{x["weekday"]} {x["title"]}{"+" + x["side"] if x["side"] else ""} {x["kcal"]:.0f}kcal' for x in rows], "passed": not v,
            "violations": v, "shopping_needed": buy[:30], "notes": out.get("notes", "")}
