"""plan_occasion：帮用户办一件和吃有关的事（家里请客、给爸妈做顿饭、带饭、过节）。

一次调用里完成多步：
  1. 把每位客人的情况（「妈妈牙不好」「爸爸控糖」「小李花生过敏」「不吃辣」）解析成可执行的规则；
  2. 内层 agent 从真实菜谱库里挑菜，validate_menu 用程序检查每道菜对每位客人都安全、荤素搭配、难度和总时长；
  3. 用菜谱步骤里的时长倒推做饭时间线（炖的先下锅、炒的最后），整理合并后的采购清单。
提醒由主 agent 按用户意愿再调用 create_reminder，App 卡片上也有「全部设提醒」按钮。
"""
from __future__ import annotations

import datetime as dt
import re

from ..agent import react, safety
from ..agent.planner import _llm
from ..agent.tools import recipe_db
from ..llm import extract_json

RULES = [  # (触发词, 规则名, 菜名/用料里不能出现的词)
    (["牙", "软烂", "咬不动", "假牙"], "软烂好嚼", safety.HARD_FOR_ELDER),
    (["控糖", "糖尿病", "血糖", "少糖"], "控糖", ["糖醋", "拔丝", "蜜汁", "冰糖", "蜂蜜", "可乐", "红糖", "甜"]),
    (["不吃辣", "不能吃辣", "怕辣", "清淡"], "不辣", ["辣", "剁椒", "水煮", "麻婆", "干煸", "小米辣", "花椒"]),
    (["高血压", "少盐", "低盐", "控盐"], "少盐", ["腊", "腌", "咸", "酱", "卤"]),
    (["痛风", "尿酸"], "低嘌呤", ["海鲜", "虾", "蟹", "贝", "动物内脏", "肝", "啤酒", "浓汤"]),
]
MEAT = ["肉", "鸡", "鸭", "牛", "羊", "猪", "排骨", "鱼", "虾", "蟹", "培根", "火腿", "肠"]
VEGAN = (["素食", "吃素", "不吃肉"], "素食", MEAT)


def parse_guest(g: dict, members: dict) -> dict:
    """客人 → {name, rules: [(规则名, 禁用词)], allergies}"""
    name = str(g.get("name") or "客人")
    notes = str(g.get("notes") or "")
    m = members.get(g.get("member_id") or "") or next((x for x in members.values() if x.get("name") and x["name"] == name), None)
    if m:
        notes += " " + (m.get("avoid") or "") + " " + (m.get("health") or "")
        if m.get("kind") == "elder":
            notes += " 牙"
    rules = [(r, words) for keys, r, words in RULES + [VEGAN] if any(k in notes for k in keys)]
    allergies = [a for a in safety.ALLERGENS if a in notes and ("过敏" in notes or "不吃" in notes or m)]
    allergies += [w for w in re.findall(r"不吃([一-龥]{1,3})", notes) if w not in ("辣", "肉")]
    return {"name": name, "notes": notes.strip(), "rules": rules, "allergies": sorted(set(allergies))}


def minutes(r: dict) -> int:
    """从步骤里把「炖 60 分钟」「蒸 8 分钟」加起来估一道菜的耗时，再加备菜时间。"""
    total = 0.0
    for s in r.get("steps", []):
        for n, unit in re.findall(r"(\d+(?:\.\d+)?)\s*(?:-|~|–|到)?\s*(?:\d+(?:\.\d+)?)?\s*(分钟|小时|秒)", s):
            total += float(n) * (60 if unit == "小时" else 1 / 60 if unit == "秒" else 1)
    return int(min(180, max(12, total + 8 + 2 * (r.get("difficulty") or 2))))


def check_dish(r: dict, guests: list[dict]) -> list[str]:
    text = "、".join(safety.expand(r["ingredients"] + [r["title"]]))
    out = []
    for g in guests:
        bad = safety.check("adult", g["allergies"], r["ingredients"] + [r["title"]])
        bad += [f"含忌口「{a}」" for a in g["allergies"] if a not in safety.ALLERGENS and a in text]
        for rule, words in g["rules"]:
            hit = [w for w in words if w in text]
            if hit:
                bad.append(f"{rule}（含{hit[0]}）")
        if bad:
            out.append(f"「{r['title']}」不适合{g['name']}：" + "；".join(sorted(set(bad))))
    return out


def validate(ids: list, guests: list[dict], n: int) -> list[str]:
    rs, _ = recipe_db()
    by_id = {r["id"]: r for r in rs}
    v = []
    dishes = [by_id.get(i) for i in ids]
    if any(d is None for d in dishes):
        v.append("有菜谱 id 不存在：" + "、".join(str(i) for i, d in zip(ids, dishes) if d is None))
    dishes = [d for d in dishes if d]
    if len(dishes) != n:
        v.append(f"需要 {n} 道菜，现在是 {len(dishes)} 道")
    if len({d["id"] for d in dishes}) != len(dishes):
        v.append("有重复的菜")
    for d in dishes:
        v += check_dish(d, guests)
    staples = {"盐", "油", "葱", "姜", "蒜", "生抽", "老抽", "糖", "料酒", "水", "淀粉", "食用油", "食用盐", "香葱", "小葱", "大蒜"}
    for i in range(len(dishes)):
        for j in range(i + 1, len(dishes)):
            a = {x for x in dishes[i]["ingredients"] if x not in staples}
            b = {x for x in dishes[j]["ingredients"] if x not in staples}
            same = a & b
            if len(same) >= 2:
                v.append(f"「{dishes[i]['title']}」和「{dishes[j]['title']}」主料重复（{'、'.join(sorted(same))}），换一道")
    cats = [d["category"] for d in dishes]
    if n >= 2 and "素菜" not in cats:
        v.append("至少要有一道素菜")
    if n >= 3 and not any(c in ("荤菜", "水产") for c in cats) and not any(r[0] == "素食" for g in guests for r in g["rules"]):
        v.append("至少要有一道荤菜或水产")
    if cats.count("汤") > 1:
        v.append("汤最多一道")
    if sum(1 for d in dishes if (d.get("difficulty") or 3) >= 4) > 1:
        v.append("难度 4 星以上的菜最多一道，不然做不过来")
    return v


def timeline(dishes: list[dict], date: str, serve: str) -> list[dict]:
    """倒推时间线：每道菜按耗时从长到短排，炒菜放最后，单灶台近似为「前一道开始后 1/3 时间就能开始下一道」。"""
    t_serve = dt.datetime.fromisoformat(f"{date} {serve if len(serve) == 5 else '0' + serve}")
    order = sorted(dishes, key=lambda d: (-("炒" not in d["title"]), -minutes(d)))
    starts, cursor = [], t_serve
    for d in reversed(order):  # 从最后一道往前排
        m = minutes(d)
        start = min(cursor - dt.timedelta(minutes=m), t_serve - dt.timedelta(minutes=m))
        starts.append((start, d, m))
        cursor = start + dt.timedelta(minutes=m * 2 // 3)
    starts.sort(key=lambda x: x[0])
    first = starts[0][0] if starts else t_serve
    prep = first - dt.timedelta(minutes=20)
    out = [{"time": (prep - dt.timedelta(hours=2)).strftime("%Y-%m-%d %H:%M"), "text": "去买菜（清单在下面）"},
           {"time": prep.strftime("%Y-%m-%d %H:%M"), "text": "洗菜、切配、腌肉"}]
    for s, d, m in starts:
        out.append({"time": s.strftime("%Y-%m-%d %H:%M"), "text": f"开始做「{d['title']}」（约 {m} 分钟）", "recipe_id": d["id"]})
    out.append({"time": t_serve.strftime("%Y-%m-%d %H:%M"), "text": "开饭 🎉"})
    return out


TOOLS = [
    {"type": "function", "function": {"name": "search_recipes", "description": "检索菜谱库，已经排除了对任何一位客人不安全的菜。返回 id、菜名、类别、热量、难度、估计耗时。",
     "parameters": {"type": "object", "properties": {"query": {"type": "string"}}, "required": ["query"]}}},
    {"type": "function", "function": {"name": "validate_menu", "description": "检查一份菜单是否对每位客人都安全、荤素搭配、难度可行。输出最终答案前必须通过。",
     "parameters": {"type": "object", "properties": {"recipe_ids": {"type": "array", "items": {"type": "string"}}}, "required": ["recipe_ids"]}}},
]
SYSTEM = """你是家宴规划师。用 search_recipes 找菜，用 validate_menu 检查，不通过就换菜再查（最多 4 次）。
菜要互补：荤素搭配、口感有变化、别全是炒菜。最后只输出 JSON：{"recipe_ids": ["R012", …], "why": "一句话说明这桌菜的思路"}"""


def run(tb, date: str, time: str, guests_in: list, dishes: int | None, requirements: str) -> dict:
    members = {m["id"]: m for m in tb.ctx.members}
    guests = [parse_guest(g if isinstance(g, dict) else {"name": str(g)}, members) for g in guests_in or []]
    if not guests:
        guests = [parse_guest({"member_id": tb.ctx.member_id}, members)]
    n = int(dishes or min(6, max(2, len(guests) + 1)))
    rs, _ = recipe_db()
    by_id = {r["id"]: r for r in rs}
    rounds = {"v": 0}

    def call(name, args):
        if name == "search_recipes":
            res = tb.search_recipes(args.get("query", ""), k=25)
            ok = []
            for x in res.get("results", []):
                r = by_id[x["recipe_id"]]
                if not check_dish(r, guests):
                    ok.append({"recipe_id": r["id"], "title": r["title"], "category": r["category"], "kcal": r.get("kcal"),
                               "difficulty": r.get("difficulty"), "minutes": minutes(r)})
            tb.emit({"type": "note", "text": f'检索「{args.get("query", "")}」→ {len(ok)} 道对所有人都安全'})
            return {"results": ok[:12]}
        if name == "validate_menu":
            rounds["v"] += 1
            v = validate(args.get("recipe_ids", []), guests, n)
            tb.emit({"type": "note", "text": f'第 {rounds["v"]} 次检查：' + ("全部通过 ✓" if not v else f"{len(v)} 处不满足")})
            return {"violations": v, "passed": not v}
        return {"error": "未知工具"}

    who = "；".join(f'{g["name"]}（{g["notes"] or "无特别要求"}）' for g in guests)
    task = f"{date} {time} 开饭，一共 {len(guests)} 人：{who}。请排 {n} 道菜。" + (f"\n额外要求：{requirements}" if requirements else "")
    app = react.build(_llm, TOOLS, call, tb.stats, max_steps=10)
    s = app.invoke({"messages": [{"role": "system", "content": SYSTEM}, {"role": "user", "content": task}]}, {"recursion_limit": 40})
    out = extract_json(react.final_text(s["messages"])) or {}
    ids = [i for i in out.get("recipe_ids", []) if i in by_id]
    v = validate(ids, guests, n)
    dishes_r = [by_id[i] for i in ids]
    for d in dishes_r:
        tb.recipes[d["id"]] = d
    buy = []
    for d in dishes_r:
        _, need = tb._fridge_split(d)
        buy += [x for x in need if x not in buy]
    tl = timeline(dishes_r, date, time) if dishes_r else []
    card = {"kind": "occasion", "date": date, "time": time, "people": len(guests),
            "guests": [{"name": g["name"], "rules": [r for r, _ in g["rules"]] + [f"不吃{a}" for a in g["allergies"]]} for g in guests],
            "dishes": [{"recipe_id": d["id"], "title": d["title"], "category": d["category"], "kcal": d.get("kcal"),
                        "minutes": minutes(d)} for d in dishes_r],
            "passed": not v, "violations": v, "rounds": rounds["v"], "why": out.get("why", ""),
            "timeline": tl, "shopping": buy[:40], "details": {d["id"]: tb.recipe_card(d["id"]) for d in dishes_r}}
    tb.cards.append(card)
    return {"summary": f'{len(dishes_r)} 道菜 · 检查 {rounds["v"]} 次 · ' + ("全部通过" if not v else f"{len(v)} 处不满足"),
            "menu": [f'{d["title"]}（{d["category"]}，约{minutes(d)}分钟）' for d in dishes_r], "why": out.get("why", ""),
            "guest_rules": card["guests"], "violations": v, "timeline": [f'{x["time"][11:]} {x["text"]}' for x in tl],
            "shopping": buy[:40], "note": "卡片上有「全部设提醒」和「加购物清单」按钮"}
