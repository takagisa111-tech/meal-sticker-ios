"""手账排版工具 design_journal：大模型出「设计」（风格、配色、标题、装饰物和贴纸摆放），程序做「排版约束」。

为什么分两层：大模型擅长审美和文案，但给坐标经常重叠、出界、把胶带贴在空白处。
所以模型只给意图（胶带贴在哪张贴纸的哪个角、装饰放在哪一侧），程序负责：
  1. 贴纸互相推开（按大小做斥力迭代），不出界、不压标题区；
  2. 胶带按 attach 吸附到对应贴纸的角上；
  3. 装饰物避开贴纸主体，压到了就沿径向推开；
  4. 颜色只能用调色板里的、尺寸和数量有上限。
"""
from __future__ import annotations

import math
import random

from ..llm import chat_json
from .context import SLOT_CN, _num

PAPERS = ["dots", "grid", "lines", "blank", "kraft", "paws"]
PALETTE = {"sage": "#A8C3A0", "butter": "#F2D38B", "blush": "#F2B8B5", "sky": "#A9C6E8", "lavender": "#C9B8E8",
           "kraft": "#C9A27E", "ink": "#3A3A36", "tomato": "#D97A6C", "mint": "#BFE3D0", "peach": "#F7C59F"}
ICONS = ["sparkles", "star.fill", "heart.fill", "leaf.fill", "sun.max.fill", "cloud.fill", "moon.stars.fill", "drop.fill",
         "camera.macro", "fork.knife", "cup.and.saucer.fill", "birthday.cake.fill", "carrot.fill", "fish.fill", "pawprint.fill",
         "flame.fill", "music.note", "bolt.heart.fill", "face.smiling", "hand.thumbsup.fill"]
KINDS = {"emoji", "text", "tape", "stamp", "note", "icon"}
RATIO = 1.25        # 手账页 4:5，高 = 1.25 × 宽

PROMPT = """你是一位擅长手账排版的设计师。请为这一页饮食手账做一版好看的设计。

## 这一页
日期：{date}（{weekday}），主人：{who}
心情：{mood}　喝水：{water} 杯
这天的餐（贴纸）：
{meals}
{stats}
用户的要求：{request}
{prefs}
## 画布
宽 1、高 1.25（坐标 x、y 都用 0–1 的比例，y=0 在顶部）。顶部 y<0.18 是日期标题区，底部 y>0.94 是页脚，贴纸不要放进去。
贴纸 scale 是宽度占页宽的比例（0.26–0.42）。餐少就放大一点、居中错落；餐多就小一点、错落成 Z 字或环形，不要排成整齐一列。

## 可以用的装饰（6–12 个，少而精，留白比堆满好看）
- tape 和纸胶带：用 attach 指定贴在哪张贴纸上、corner 取 tl / tr，不用给坐标。最多 3 条。
- emoji：小 emoji 点缀，size 0.05–0.09
- icon：线条小图标，text 只能取：{icons}；size 0.04–0.08
- text：手写感短句或标签（≤10 字），size 0.035–0.05，可设 highlight: true（荧光笔底色）
- note：便利贴小卡片，写一句小结（≤16 字），size 0.2–0.3（宽度）
- stamp：圆形印章，2–4 个字（如「今日达标」「好好吃饭」），size 0.12–0.16
颜色只能用：{palette}。整页最多 3 种主色，和纸张风格协调。
纸张 paper 只能取：dots(点点) grid(方格) lines(横线) blank(纯色) kraft(牛皮纸) {pet_paper}

## 文案
title：这一页的小标题（≤8 字），caption：一句今天的手账日记（≤22 字，具体、温暖，可以提到吃了什么或今天的状态，不要说教）。

只输出 JSON：
{{"style": "风格名（≤6字）", "paper": "...", "title": "...", "caption": "...",
 "stickers": [{{"id": "餐的id", "x": 0.3, "y": 0.4, "rot": -6, "scale": 0.34}}],
 "decos": [{{"kind": "tape", "attach": "餐的id", "corner": "tl", "color": "sage"}},
           {{"kind": "emoji", "text": "🌿", "x": 0.85, "y": 0.3, "size": 0.07, "rot": 10}},
           {{"kind": "text", "text": "今日份能量", "x": 0.2, "y": 0.9, "size": 0.04, "color": "ink", "highlight": true, "rot": -4}}]}}"""


def _clamp(v, lo, hi):
    return max(lo, min(hi, v))


def _layout_stickers(st: list[dict]) -> list[dict]:
    """贴纸互相推开：两张贴纸中心距离（按真实宽高比换算）小于两者半宽之和的 0.9 倍就沿连线推开。"""
    for _ in range(80):
        moved = False
        for i in range(len(st)):
            for j in range(i + 1, len(st)):
                a, b = st[i], st[j]
                dx, dy = b["x"] - a["x"], (b["y"] - a["y"]) * RATIO
                d = math.hypot(dx, dy) or 1e-3
                need = (a["scale"] + b["scale"]) / 2 * 0.92
                if d < need:
                    push = (need - d) / 2
                    ux, uy = (dx / d, dy / d) if d > 1e-3 else (1.0, 0.0)
                    a["x"] -= ux * push; a["y"] -= uy * push / RATIO
                    b["x"] += ux * push; b["y"] += uy * push / RATIO
                    moved = True
        for s in st:
            h = s["scale"] / 2
            s["x"] = _clamp(s["x"], 0.06 + h, 0.94 - h)
            s["y"] = _clamp(s["y"], 0.2 + h / RATIO, 0.9 - h / RATIO)
        if not moved:
            break
    return st


def _inside(px, py, s, pad=0.0) -> bool:
    h = s["scale"] / 2 + pad
    return abs(px - s["x"]) < h * 0.85 and abs(py - s["y"]) * RATIO < h * 0.85


def _avoid(d: dict, st: list[dict]):
    """装饰物压在贴纸上就沿着离开贴纸中心的方向推出去。"""
    for _ in range(12):
        hit = next((s for s in st if _inside(d["x"], d["y"], s)), None)
        if not hit:
            break
        dx, dy = d["x"] - hit["x"], (d["y"] - hit["y"]) * RATIO
        n = math.hypot(dx, dy) or 1e-3
        if n < 1e-2:
            dx, dy, n = 1.0, -0.3, math.hypot(1.0, 0.3)
        d["x"] += dx / n * 0.06
        d["y"] += dy / n * 0.06 / RATIO
        d["x"], d["y"] = _clamp(d["x"], 0.05, 0.95), _clamp(d["y"], 0.05, 0.96)


def layout(raw: dict, meal_ids: list[str], pet: bool) -> tuple[dict, list[str]]:
    """把模型的设计变成一版合法的排版；返回（排版, 修正记录）。"""
    fixes: list[str] = []
    rng = random.Random(len(meal_ids))
    given = {s.get("id"): s for s in raw.get("stickers", []) if isinstance(s, dict)}
    st = []
    for i, mid in enumerate(meal_ids):
        s = given.get(mid) or {}
        if not s:
            fixes.append(f"补上了漏排的贴纸 {mid}")
        st.append({"id": mid, "x": _num(s.get("x")) or 0.3 + 0.4 * (i % 2), "y": _num(s.get("y")) or 0.32 + 0.2 * (i // 2),
                   "rot": _clamp(_num(s.get("rot")) or rng.uniform(-8, 8), -14, 14),
                   "scale": _clamp(_num(s.get("scale")) or 0.34, 0.24, 0.44)})
    before = [(s["x"], s["y"]) for s in st]
    st = _layout_stickers(st)
    if any(abs(a[0] - s["x"]) + abs(a[1] - s["y"]) > 0.02 for a, s in zip(before, st)):
        fixes.append("推开了互相重叠或出界的贴纸")

    by_id = {s["id"]: s for s in st}
    decos, tapes = [], 0
    for d in raw.get("decos", []):
        if not isinstance(d, dict) or d.get("kind") not in KINDS or len(decos) >= 14:
            continue
        k = d["kind"]
        color = PALETTE.get(str(d.get("color", "")).lower(), None)
        if d.get("color") and not color:
            fixes.append(f"颜色 {d.get('color')} 不在调色板里，换成了默认色")
        out = {"kind": k, "text": str(d.get("text", ""))[:16], "color": color or PALETTE["kraft" if k == "tape" else "ink"],
               "rot": _clamp(_num(d.get("rot")), -30, 30), "highlight": bool(d.get("highlight"))}
        if k == "tape":
            s = by_id.get(d.get("attach")) or (st[tapes % len(st)] if st else None)
            if not s or tapes >= 3:
                continue
            tapes += 1
            side = -1 if d.get("corner", "tl") == "tl" else 1
            h = s["scale"] / 2
            out.update(x=s["x"] + side * h * 0.72, y=s["y"] - h * 0.8 / RATIO, size=_clamp(s["scale"] * 0.55, 0.13, 0.22),
                       rot=side * rng.uniform(28, 40) + s["rot"], attach=s["id"])
            decos.append(out)
            continue
        if k == "icon" and out["text"] not in ICONS:
            fixes.append(f"图标 {out['text']} 不可用，换成 sparkles")
            out["text"] = "sparkles"
        lim = {"emoji": (0.04, 0.1), "icon": (0.035, 0.08), "text": (0.03, 0.055), "note": (0.18, 0.32), "stamp": (0.1, 0.17)}[k]
        out["size"] = _clamp(_num(d.get("size")) or sum(lim) / 2, *lim)
        out["x"] = _clamp(_num(d.get("x")) or rng.uniform(0.1, 0.9), 0.05, 0.95)
        out["y"] = _clamp(_num(d.get("y")) or rng.uniform(0.2, 0.9), 0.05, 0.96)
        if k in ("text", "note") and not out["text"]:
            continue
        old = (out["x"], out["y"])
        if 0.25 < out["x"] < 0.75 and out["y"] < 0.17:       # 不压日期标题
            out["y"] = 0.19
        _avoid(out, st)
        for _ in range(8):                                     # 装饰之间也别挤在一起
            near = next((o for o in decos if math.hypot(o["x"] - out["x"], (o["y"] - out["y"]) * RATIO) < 0.07), None)
            if not near:
                break
            dx, dy = out["x"] - near["x"], out["y"] - near["y"]
            n = math.hypot(dx, dy) or 1e-3
            out["x"] = _clamp(out["x"] + (dx / n if n > 1e-3 else 1) * 0.05, 0.05, 0.95)
            out["y"] = _clamp(out["y"] + (dy / n if n > 1e-3 else 0) * 0.05 / RATIO, 0.05, 0.96)
            _avoid(out, st)
        if (out["x"], out["y"]) != old:
            fixes.append(f"把装饰「{out['text'] or k}」挪开，不压住贴纸")
        decos.append(out)
    paper = raw.get("paper") if raw.get("paper") in PAPERS else ("paws" if pet else "dots")
    if paper == "paws" and not pet:
        paper = "dots"
    return {"style": str(raw.get("style", ""))[:8], "paper": paper, "title": str(raw.get("title", ""))[:10],
            "caption": str(raw.get("caption", ""))[:26], "stickers": st, "decos": decos}, fixes


def design(tb, date: str | None, request: str, member_id: str | None) -> dict:
    ctx = tb.ctx
    m = ctx.member(member_id)
    date = date or ctx.today
    meals = [r for r in ctx.recs(m["id"]) if r.get("date") == date]
    pet = m["kind"] in ("dog", "cat")
    import datetime as dt
    wd = "周" + "一二三四五六日"[dt.date.fromisoformat(date).isoweekday() - 1]
    lines = "\n".join(f'- id={r["id"]}：{SLOT_CN.get(r.get("slot"), "")} {r.get("emoji", "")}{r.get("title") or "未命名"} '
                      f'{round(_num(r.get("kcal")))}kcal' for r in meals) or "（这天还没有记录，只做装饰和文案）"
    kcal = sum(_num(r.get("kcal")) for r in meals)
    tgt = _num(m.get("kcal_target"))
    stats = f"合计约 {round(kcal)} kcal" + (f"，目标 {int(tgt)}" if tgt else "")
    day = ctx.day or {}
    prefs = ctx.relevant_memories(request + " 手账 风格 喜欢 颜色", k=6)
    p = PROMPT.format(date=date, weekday=wd, who=f'{m.get("name") or "我"}（{ {"me": "成年人", "elder": "老人", "dog": "狗", "cat": "猫"}.get(m["kind"], "") }）',
                      mood=day.get("mood") or "没写", water=day.get("water", 0), meals=lines, stats=stats,
                      request=request or "做一版好看的", icons=" ".join(ICONS), palette=" ".join(PALETTE),
                      pet_paper="paws(小爪印)" if pet else "",
                      prefs=("用户的偏好：" + "；".join(x["text"] for x in prefs) + "\n") if prefs else "")
    raw = chat_json(p, stats=tb.stats, system="你是手账设计师，只输出一个 JSON 对象。", json_mode=True, temperature=0.8)
    lay, fixes = layout(raw, [r["id"] for r in meals], pet)
    for f in fixes[:3]:
        tb.emit({"type": "note", "text": "排版修正：" + f})
    card = {"kind": "journal", "id": "J" + __import__("uuid").uuid4().hex[:6], "date": date, "member_id": m["id"], **lay, "fixes": len(fixes)}
    tb.cards.append(card)
    return {"date": date, "style": lay["style"], "paper": lay["paper"], "title": lay["title"], "caption": lay["caption"],
            "stickers": len(lay["stickers"]), "decorations": [f'{d["kind"]}:{d["text"]}' for d in lay["decos"]],
            "layout_fixes": fixes, "note": "App 会显示预览和「用这版」按钮，用户点了才会改手账"}
