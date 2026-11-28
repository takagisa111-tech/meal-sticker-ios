"""管家 agent 的工具。每个工具返回给模型看的结果；需要在 App 里展示或执行的东西放进 turn.cards / turn.actions。

读：query_records（Text-to-SQL）、nutrition_gaps、search_recipes / get_recipe（菜谱 RAG）、search_guidelines（指南 RAG，带出处）
看：estimate_meal（文字记一餐，参考个人记录和记忆）、analyze_photo（餐食 / 菜单 / 冰箱 / 包装食品）、refine_meal
规划：plan_week（内层 agent：检索 + 程序校验循环）
安全：check_food_safety（确定性规则，不依赖模型）
写（App 端执行）：remember / forget、update_fridge、add_to_shopping_list
"""
from __future__ import annotations

import datetime as dt
import json
import re
import uuid
from collections import defaultdict
from typing import Callable

from ..agent import safety
from ..agent.tools import guide_db, recipe_db
from ..llm import chat_json
from ..schema import RunStats
from . import prompts
from .context import FLAGS, GROUPS, SCHEMA, SLOT_CN, Ctx, _num

CUISINES = ["川菜", "湘菜", "粤菜", "江浙菜", "鲁菜", "东北菜", "西北菜", "云贵菜", "闽菜", "徽菜", "家常菜", "日料", "韩餐",
            "东南亚菜", "西餐", "快餐", "轻食沙拉", "面食小吃", "火锅", "烧烤", "烘焙甜品", "其他"]
PET_GROUPS = ["kibble", "wetfood", "treat", "human"]
PANTRY = ["盐", "油", "食用油", "生抽", "老抽", "酱油", "醋", "糖", "白糖", "料酒", "水", "清水", "淀粉", "胡椒", "味精", "鸡精",
          "葱", "姜", "蒜", "香油", "芝麻油", "蚝油", "八角", "花椒", "干辣椒", "冰糖", "生粉", "白胡椒粉", "十三香"]
PANTRY = set(PANTRY) | {"大蒜", "蒜头", "蒜瓣", "小葱", "大葱", "葱花", "姜片", "生姜", "老姜", "香醋", "陈醋", "米醋", "白醋", "麻油",
                        "凉白开", "冰块", "开水", "热水", "温水", "白砂糖", "红糖", "食盐", "细盐", "黑胡椒", "胡椒粉", "孜然", "桂皮", "香叶", "葱段", "姜丝", "蒜末"}
TOOLS = ["刷子", "锅", "刀", "碗", "盘", "筷", "保鲜膜", "微波炉", "烤箱", "剪刀", "牙签", "厨房纸", "砧板", "铲", "勺", "蒸笼", "烤盘", "锡纸", "量杯", "电饭煲", "高压锅", "空气炸锅"]
SYNONYM = {"西红柿": "番茄", "马铃薯": "土豆", "洋芋": "土豆", "鸡蛋液": "鸡蛋", "蛋": "鸡蛋", "青瓜": "黄瓜", "包菜": "卷心菜", "圆白菜": "卷心菜"}
HIDE_CATS = ("调料", "饮品", "半成品")


def _norm(t: str) -> str:
    t = re.sub(r"[（(].*?[)）]", "", t)
    t = re.sub(r"[\d.~\-–]+\s*(个|瓣|颗|根|片|克|g|kg|千克|斤|两|ml|毫升|升|勺|汤匙|茶匙|碗|杯|只|条|块|把|小把|段|朵|张)?", "", t)
    t = re.sub(r"(适量|少许|若干|少量|可选|新鲜的?|一点)", "", t).strip(" ：:*-")
    return SYNONYM.get(t, t)
KEYS = ("kcal", "protein", "carbs", "fat", "fiber")

# 指南里的推荐量（每天，克）：成人来自 G3–G7，老人来自 E1–E3
TARGETS = {
    "adult": {"蔬菜": ("veg_g+dark_veg_g", 300, 500, "G4"), "深色蔬菜": ("dark_veg_g", 150, 500, "G4"), "水果": ("fruit_g", 200, 350, "G5"),
              "奶类": ("dairy_g", 300, 500, "G6"), "全谷杂豆": ("whole_grain_g", 50, 150, "G3"),
              "鱼禽蛋瘦肉": ("meat_g+seafood_g+egg_g", 120, 200, "G7"), "大豆坚果": ("soy_nut_g", 25, 35, "G1")},
    "elder": {"蔬菜": ("veg_g+dark_veg_g", 300, 450, "E1"), "水果": ("fruit_g", 200, 300, "E1"), "奶类": ("dairy_g", 300, 400, "E2"),
              "鱼禽蛋瘦肉": ("meat_g+seafood_g+egg_g", 120, 150, "E2"), "全谷杂豆": ("whole_grain_g", 50, 100, "E1"),
              "大豆坚果": ("soy_nut_g", 25, 35, "E1")},
}


def _id(prefix: str) -> str:
    return prefix + uuid.uuid4().hex[:5]


def _clean_food(f: dict, pet: bool) -> dict | None:
    if not isinstance(f, dict) or not f.get("name"):
        return None
    g = f.get("group")
    allowed = PET_GROUPS if pet else GROUPS
    out = {"name": str(f["name"])[:20], "grams": round(_num(f.get("grams") or f.get("served_g")), 1),
           "group": g if g in allowed else ("human" if pet else "other"),
           "confidence": min(1.0, max(0.0, _num(f.get("confidence", 0.7)) or 0.7))}
    for k in KEYS:
        out[k] = round(max(0.0, _num(f.get(k))), 1)
    return out


class Turn:
    """一轮对话里的工具状态。emit 用来把内层进度（plan_week 的子步骤、记忆写入）实时推给 App。"""

    def __init__(self, ctx: Ctx, stats: RunStats, emit: Callable[[dict], None], prior_drafts: dict | None = None):
        self.ctx, self.stats, self.emit = ctx, stats, emit
        self.drafts: dict[str, dict] = dict(prior_drafts or {})   # 包括之前几轮的草稿（从 memo 里恢复）
        self.new_drafts: list[str] = []
        self.cards: list[dict] = []
        self.table: dict | None = None
        self.recipes: dict[str, dict] = {}
        self.guides: dict[str, dict] = {}

    # ================= 记一餐 =================
    def _who(self, m: dict) -> str:
        t = {"me": "成年人", "elder": "老人", "dog": "狗", "cat": "猫"}.get(m["kind"], "成年人")
        bits = [t]
        if m.get("age"):
            bits.append(f'{m["age"]}岁')
        if m.get("avoid"):
            bits.append("忌口/过敏：" + m["avoid"])
        return "，".join(bits)

    def _finish_draft(self, r: dict, m: dict, slot: str | None, date: str | None, image_id: str | None = None,
                      source: str = "agent", copy_of: str | None = None, policy: str = "uncertain", replaces: str | None = None) -> dict:
        pet = m["kind"] in ("dog", "cat")
        foods = [x for x in (_clean_food(f, pet) for f in r.get("foods", [])) if x]
        tot = {k: round(sum(f[k] for f in foods), 1) for k in KEYS} if foods else {k: round(_num(r.get(k)), 1) for k in KEYS}
        names = [f["name"] for f in foods] + [str(r.get("title", ""))]
        issues = safety.check(self.ctx.kind(m["id"]), m.get("allergies", []), names) + _avoid_hits(m, names)
        # 挑一个最值得问的问题：热量 ×（1 − 置信度）最大的疑点（评测里「问一个」对识图提升最大）
        doubts = [d for d in r.get("doubts", []) if isinstance(d, dict) and d.get("question")]
        kcal = {f["name"]: f["kcal"] for f in foods}
        conf = {f["name"]: f["confidence"] for f in foods}
        scored = sorted(((max(kcal.get(d.get("food", ""), 0), 30) * (1 - conf.get(d.get("food", ""), 0.5)), d) for d in doubts),
                        key=lambda x: -x[0])
        q = None
        if scored and (policy == "always" or scored[0][0] >= 60):
            d = scored[0][1]
            q = {"question": d["question"], "options": [str(o) for o in d.get("options", [])][:4]}
        did = _id("D")
        draft = {"id": did, "member_id": m["id"], "slot": slot or _guess_slot(self.ctx.now), "date": date or self.ctx.today,
                 "title": str(r.get("title") or "这一餐")[:12], "emoji": str(r.get("emoji") or "🍽️")[:4],
                 "cuisine": r.get("cuisine") if r.get("cuisine") in CUISINES else None,
                 "methods": [str(x) for x in r.get("methods", []) if isinstance(x, str)][:3],
                 "flags": [x for x in r.get("flags", []) if x in FLAGS], "foods": foods, **tot,
                 "comment": str(r.get("comment", ""))[:60], "question": q, "image_id": image_id, "source": source,
                 "copy_of": copy_of, "warnings": issues, "replaces": replaces}
        self.drafts[did] = draft
        if replaces and replaces in self.new_drafts:
            self.new_drafts.remove(replaces)
        self.new_drafts.append(did)
        return draft

    @staticmethod
    def _for_model(d: dict) -> dict:
        return {"draft_id": d["id"], "title": d["title"], "slot": SLOT_CN.get(d["slot"], d["slot"]), "date": d["date"],
                "kcal": d["kcal"], "protein": d["protein"], "carbs": d["carbs"], "fat": d["fat"],
                "foods": [f'{f["name"]} {f["grams"]:g}g {f["kcal"]:g}kcal' for f in d["foods"]],
                "question": d["question"], "warnings": d["warnings"], "comment": d["comment"]}

    def estimate_meal(self, description: str, slot: str | None = None, date: str | None = None,
                      member_id: str | None = None, copy_of: str | None = None):
        m = self.ctx.member(member_id)
        if copy_of:
            src = next((r for r in self.ctx.records if r.get("id") == copy_of), None)
            if src:
                r = {"title": src.get("title"), "emoji": src.get("emoji"), "cuisine": src.get("cuisine"), "methods": src.get("methods") or [],
                     "flags": src.get("flags") or [], "comment": src.get("comment", ""),
                     "foods": [{**f, "kcal": 0} for f in src.get("foods") or []]}
                d = self._finish_draft(r, m, slot or src.get("slot"), date, source="reuse", copy_of=copy_of)
                for k in KEYS:
                    d[k] = round(_num(src.get(k)), 1)
                return self._for_model(d)
        mem = self.ctx.relevant_memories(description, k=12)
        sim = self.ctx.similar_records(description, m["id"])
        mem_t = ("\n用户告诉过你的事：\n" + "\n".join("- " + x["text"] for x in mem) + "\n") if mem else ""
        sim_t = ("\n这位用户以前记过的相似餐（他自己的份量）：\n" + "\n".join(
            f'- {s["date"]} {s.get("title")}：{round(_num(s.get("kcal")))}kcal；' + "、".join(f'{f["name"]}{_num(f.get("grams")):g}g' for f in s["foods"][:8])
            for s in sim) + "\n") if sim else ""
        pet = m["kind"] in ("dog", "cat")
        p = prompts.ESTIMATE.format(who=self._who(m), text=description, memories=mem_t, similar=sim_t, cuisines="/".join(CUISINES),
                                    groups=" ".join(PET_GROUPS if pet else GROUPS))
        if pet:
            p += prompts.PET_RULES.format(animal="狗" if m["kind"] == "dog" else "猫")
        r = chat_json(p, stats=self.stats, system="你是一位细心的注册营养师。你总是只输出一个 JSON 对象。", json_mode=True, temperature=0.2)
        d = self._finish_draft(r, m, slot, date, source="text")
        out = self._for_model(d)
        out["used_personal_records"] = [s.get("title") for s in sim]
        return out

    def analyze_photo(self, image_id: str, kind: str = "auto", note: str = "", member_id: str | None = None,
                      slot: str | None = None, date: str | None = None):
        img = self.ctx.images.get(image_id) or (next(iter(self.ctx.images.values())) if self.ctx.images else None)
        if not img:
            return {"error": "这一轮没有收到图片（图片只在发送的那一轮可用），请让用户重新发一次"}
        if kind not in ("meal", "menu", "fridge", "product"):
            c = chat_json(prompts.CLASSIFY, [img], stats=self.stats, json_mode=True, temperature=0, max_tokens=120)
            kind = c.get("kind") if c.get("kind") in ("meal", "menu", "fridge", "product") else "meal"
            self.emit({"type": "note", "text": f"看起来是{ {'meal': '一餐饭', 'menu': '菜单', 'fridge': '冰箱 / 食材', 'product': '包装食品'}[kind] }"})
        if kind == "menu":
            return self._menu(img, member_id)
        if kind == "fridge":
            r = chat_json(prompts.FRIDGE, [img], stats=self.stats, json_mode=True, temperature=0.2)
            items = [str(x) for x in r.get("items", []) if x][:30]
            self.emit({"type": "action", "action": {"kind": "fridge", "add": items, "remove": []}})
            self.ctx.fridge = sorted(set(self.ctx.fridge) | set(items))
            return {"kind": "fridge", "items": items, "note": r.get("note", ""), "saved_to_fridge": True}
        if kind == "product":
            r = chat_json(prompts.PRODUCT, [img], stats=self.stats, json_mode=True, temperature=0.2)
            m = self.ctx.member(member_id)
            r["safety_issues"] = safety.check(self.ctx.kind(m["id"]), m.get("allergies", []), [str(x) for x in r.get("ingredients", [])] + [str(r.get("name", ""))]) \
                + _avoid_hits(m, [str(x) for x in r.get("ingredients", [])])
            return {"kind": "product", **r}
        return self._meal_photo(img, image_id, note, member_id, slot, date)

    def _meal_photo(self, img: str, image_id: str, note: str, member_id, slot, date):
        from ..llm import encode_image
        from ..prompts import agent_zh
        m = self.ctx.member(member_id)
        refs, images = [], [img]
        try:   # 多模态 RAG：参考库里外观相似、份量已核实的餐（CLIP 检索）
            from PIL import Image
            from ..agent.recognizer import _pil
            from ..rag.visual import describe, index as visual_index
            refs = visual_index().search(_pil(img), k=5)
            images += [encode_image(Image.open(x["image"]), max_side=512) for x in refs]
            ref_txt = [describe(x) for x in refs]
            self.emit({"type": "note", "text": f"找到 {len(refs)} 张份量已核实的相似餐作参考"})
        except Exception:  # noqa: BLE001  参考库不可用时退回单图识别
            ref_txt = None
        mem = self.ctx.relevant_memories(note or "份量 一碗 饭", k=8)
        extra = (f"\n用户补充：{note}" if note else "") + (("\n用户的份量习惯：" + "；".join(x["text"] for x in mem)) if mem else "")
        p = agent_zh.perceive(ref_txt) + prompts.PHOTO_EXTRA.format(cuisines="/".join(CUISINES), note=extra)
        if m["kind"] in ("dog", "cat"):
            p += prompts.PET_RULES.format(animal="狗" if m["kind"] == "dog" else "猫")
        r = chat_json(p, images, stats=self.stats, system=agent_zh.SYSTEM, json_mode=True, temperature=0.3)
        d = self._finish_draft(r, m, slot, date, image_id=image_id, source="photo", policy="always")
        return {"kind": "meal", **self._for_model(d)}

    def refine_meal(self, draft_id: str, answer: str):
        from ..prompts import agent_zh
        d = self.drafts.get(draft_id) or (self.drafts[self.new_drafts[-1]] if self.new_drafts else None) \
            or (list(self.drafts.values())[-1] if self.drafts else None)
        if not d:
            return {"error": "找不到这张记录卡片，请用 estimate_meal 重新估算"}
        prev = {"title": d["title"], "foods": d["foods"], **{k: d[k] for k in KEYS}, "doubts": []}
        qa = f'问：{(d.get("question") or {}).get("question", "补充信息")}\n答：{answer}'
        r = chat_json(agent_zh.REFINE_V2.format(prev=json.dumps(prev, ensure_ascii=False), qa=qa), stats=self.stats,
                      system=agent_zh.SYSTEM, json_mode=True, temperature=0.2)
        for k in ("emoji", "cuisine", "methods", "flags", "comment"):
            r.setdefault(k, d.get(k))
        r["title"] = r.get("title") or d["title"]
        r["doubts"] = []
        m = self.ctx.member(d["member_id"])
        nd = self._finish_draft(r, m, d["slot"], d["date"], image_id=d.get("image_id"), source=d.get("source", "agent"),
                                policy="never", replaces=d["id"])
        return {"before_kcal": d["kcal"], **self._for_model(nd)}

    # ================= 菜单 / 外卖 =================
    def _menu(self, img: str, member_id: str | None):
        m = self.ctx.member(member_id)
        r = chat_json(prompts.MENU, [img], stats=self.stats, json_mode=True, temperature=0.2)
        dishes = [x for x in r.get("dishes", []) if isinstance(x, dict) and x.get("name")]
        eaten = sum(_num(x.get("kcal")) for x in self.ctx.recs(m["id"]) if x.get("date") == self.ctx.today)
        target = _num(m.get("kcal_target")) or 1900
        budget = max(350.0, min(target - eaten, target * 0.4))
        gaps = self.nutrition_gaps(m["id"], 7).get("gaps", [])
        want_veg = any("蔬菜" in g for g in gaps)
        scored = []
        for x in dishes:
            k = _num(x.get("kcal"))
            issues = safety.check(self.ctx.kind(m["id"]), m.get("allergies", []), [x["name"]] + [str(i) for i in x.get("ingredients", [])]) \
                + _avoid_hits(m, [x["name"]] + [str(i) for i in x.get("ingredients", [])])
            s = -abs(k - budget * 0.85) / budget + min(_num(x.get("protein")), 40) / 80 + (0.3 if x.get("veg") and want_veg else 0.1 if x.get("veg") else 0)
            s -= 0.25 * len([f for f in x.get("flags", []) if f in ("fried", "sugary", "fatty")])
            scored.append((s, x, issues))
        def bad_reason(x, issues):
            if issues:
                return "；".join(issues)
            k = _num(x.get("kcal"))
            why = [w for f, w in (("fried", "油炸"), ("sugary", "高糖"), ("fatty", "高脂")) if f in x.get("flags", [])]
            if k > budget * 1.25:
                why.append(f"约 {round(k)} kcal，超过这顿预算")
            if x.get("hidden") and why:
                why.append(x["hidden"])
            return "，".join(why)
        rated = [(sc, x, bad_reason(x, issues)) for sc, x, issues in scored]
        picks = [{"name": x["name"], "kcal": round(_num(x.get("kcal"))), "protein": round(_num(x.get("protein"))), "price": x.get("price"),
                  "hidden": x.get("hidden", ""), "veg": bool(x.get("veg"))} for _, x, why in sorted(rated, key=lambda t: -t[0]) if not why][:3]
        avoid = [{"name": x["name"], "why": why} for _, x, why in sorted(rated, key=lambda t: t[0]) if why][:4]
        card = {"kind": "menu", "shop": r.get("shop", ""), "budget": round(budget), "eaten": round(eaten), "picks": picks, "avoid": avoid,
                "count": len(dishes)}
        self.cards.append(card)
        return {"kind": "menu", "shop": r.get("shop", ""), "dish_count": len(dishes), "this_meal_budget_kcal": round(budget),
                "weekly_gaps": gaps, "top_picks": picks, "avoid": avoid,
                "all": [f'{x["name"]} ≈{round(_num(x.get("kcal")))}kcal' for x in dishes][:25]}

    # ================= 查记录 =================
    def query_records(self, sql: str):
        s = sql.strip().rstrip(";")
        if not re.match(r"^\s*(select|with)\b", s, re.I) or ";" in s:
            return {"error": "只允许单条 SELECT 查询"}
        try:
            cur = self.ctx.db().execute(s)
        except Exception as e:  # noqa: BLE001  SQL 写错了把报错给模型，让它自己改
            return {"error": f"SQL 错误：{e}"}
        cols = [c[0] for c in cur.description]
        rows = [[round(v, 1) if isinstance(v, float) else v for v in r] for r in cur.fetchmany(100)]
        if 1 <= len(rows) <= 31 and len(cols) <= 6:
            self.table = {"kind": "table", "sql": s, "columns": cols, "rows": rows[:31]}
        return {"columns": cols, "rows": rows, "row_count": len(rows), "truncated": len(rows) == 100,
                "total_records_in_db": len(self.ctx.records)}

    def nutrition_gaps(self, member_id: str | None = None, days: int = 7):
        m = self.ctx.member(member_id)
        kind = self.ctx.kind(m["id"])
        end = dt.date.fromisoformat(self.ctx.today)
        start = (end - dt.timedelta(days=days)).isoformat()
        rs = [r for r in self.ctx.recs(m["id"]) if start <= r.get("date", "") < self.ctx.today]
        dates = sorted({r["date"] for r in rs})
        n = max(1, len(dates))
        g = defaultdict(float)
        flags = defaultdict(int)
        for r in rs:
            for f in r.get("foods") or []:
                g[(f.get("group") or "other") + "_g"] += _num(f.get("grams"))
            for fl in r.get("flags") or []:
                flags[fl] += 1
        kcal_avg = sum(_num(r.get("kcal")) for r in rs) / n
        out = {"member": m.get("name"), "period": f"{start} 到 {(end - dt.timedelta(days=1)).isoformat()}", "days_with_records": len(dates),
               "meals_recorded": len(rs), "kcal_daily_avg": round(kcal_avg), "kcal_target": _num(m.get("kcal_target")) or None}
        if kind in ("dog", "cat"):
            snack = sum(_num(r.get("kcal")) for r in rs if r.get("slot") == "snack")
            out["treat_kcal_share"] = f"{round(100 * snack / (sum(_num(r.get('kcal')) for r in rs) or 1))}%（建议不超过 10%）"
            out["note"] = "宠物看总热量、零食占比和危险食物"
            return out
        rows, gaps = [], []
        for name, (expr, lo, hi, src) in TARGETS["elder" if kind == "elder" else "adult"].items():
            avg = sum(g[x] for x in expr.split("+")) / n
            status = "不足" if avg < lo * 0.8 else ("偏多" if avg > hi * 1.3 else "达标")
            rows.append({"group": name, "daily_avg_g": round(avg), "target_g": f"{lo}–{hi}", "status": status, "guideline": src})
            if status == "不足":
                gaps.append((avg / lo, name))
        fish_meals = sum(1 for r in rs if any((f.get("group") == "seafood") for f in r.get("foods") or []))
        out.update({"groups": rows, "gaps": [x for _, x in sorted(gaps)][:3], "fish_meals": fish_meals,
                    "fried_meals": flags.get("fried", 0), "high_salt_meals": flags.get("high_salt", 0),
                    "takeout_meals": sum(1 for r in rs if r.get("source") == "takeout" or r.get("shop"))})
        if len(dates) < 3:
            out["warning"] = "记录天数太少，结论只供参考"
        return out

    # ================= 菜谱 RAG =================
    def _recipe_ok(self, r: dict, m: dict, avoid: list[str]) -> list[str]:
        text = r["ingredients"] + [r["title"]]
        bad = safety.check(self.ctx.kind(m["id"]), m.get("allergies", []), text) + _avoid_hits(m, text, extra=avoid)
        if self.ctx.kind(m["id"]) == "elder" and any(w in "、".join(safety.expand([r["title"]])) for w in safety.HARD_FOR_ELDER):
            bad.append("老人不好咀嚼")
        return bad

    def _fridge_split(self, r: dict) -> tuple[list[str], list[str]]:
        """把菜谱用料分成「冰箱里有」和「要买」：拆开「葱、姜、蒜」这种合并项，去掉数量、调料、厨具和水。"""
        have, need = [], []
        fridge = [_norm(x) for x in self.ctx.fridge]
        for raw in r["ingredients"]:
            for part in re.split(r"[、，,/；;]|和|及|或", raw):
                ing = _norm(part)
                if not ing or ing in PANTRY or any(w in ing for w in TOOLS) or (ing.endswith(("油", "酱", "粉", "汁", "水")) and len(ing) <= 4):
                    continue
                hit = any(x and (x in ing or ing in x) for x in fridge)
                lst = have if hit else need
                if ing not in lst:
                    lst.append(ing)
        return have, need

    def search_recipes(self, query: str, must_use: list | None = None, avoid: list | None = None, max_kcal: float | None = None,
                       max_difficulty: int | None = None, member_id: str | None = None, k: int = 5):
        rs, idx = recipe_db()
        m = self.ctx.member(member_id)
        must = [str(x) for x in must_use or []]
        out = []
        for i, _ in idx.search(query + " " + " ".join(must), k=60):
            r = rs[i]
            if r["category"] in HIDE_CATS or self._recipe_ok(r, m, [str(a) for a in avoid or []]):
                continue
            if max_kcal and r.get("kcal") and r["kcal"] > max_kcal:
                continue
            if max_difficulty and (r.get("difficulty") or 3) > max_difficulty:
                continue
            if must and not any(w in ing or ing in w for w in must for ing in r["ingredients"]):
                continue
            have, need = self._fridge_split(r)
            self.recipes[r["id"]] = r
            out.append({"recipe_id": r["id"], "title": r["title"], "category": r["category"], "kcal_per_serving": r.get("kcal"),
                        "difficulty": r.get("difficulty"), "ingredients": r["ingredients"][:10], "in_fridge": have, "need_to_buy": need})
            if len(out) >= k:
                break
        if not out:
            return {"results": [], "hint": "没找到；换个更宽泛的关键词，或减少 must_use"}
        return {"results": out}

    def get_recipe(self, recipe_id: str):
        rs, _ = recipe_db()
        r = next((x for x in rs if x["id"] == recipe_id), None)
        if not r:
            return {"error": f"没有菜谱 {recipe_id}"}
        self.recipes[r["id"]] = r
        return {"recipe_id": r["id"], "title": r["title"], "kcal_per_serving": r.get("kcal"), "difficulty": r.get("difficulty"),
                "amounts": r.get("amounts") or r["ingredients"], "steps": r.get("steps", [])}

    def recipe_card(self, rid: str) -> dict | None:
        r = self.recipes.get(rid)
        if not r:
            rs, _ = recipe_db()
            r = next((x for x in rs if x["id"] == rid), None)
        if not r:
            return None
        have, need = self._fridge_split(r)
        return {"kind": "recipe", "id": r["id"], "title": r["title"], "category": r["category"], "kcal": r.get("kcal"),
                "difficulty": r.get("difficulty"), "intro": r.get("intro", ""), "amounts": r.get("amounts") or r["ingredients"],
                "steps": r.get("steps", []), "have": have, "need": need, "source": "HowToCook（程序员做饭指南）"}

    # ================= 一周菜单（内层 agent）=================
    def plan_week(self, days: int = 7, member_id: str | None = None, requirements: str = "", kcal_min: float | None = None,
                  kcal_max: float | None = None):
        from .plan import run_plan
        m = self.ctx.member(member_id)
        if self.ctx.kind(m["id"]) in ("dog", "cat"):
            return {"error": "宠物不需要排菜单，建议按目标热量喂主粮"}
        res = run_plan(self, m, max(2, min(int(days or 7), 7)), requirements, kcal_min, kcal_max)
        return res

    # ================= 安全 / 指南 =================
    def check_food_safety(self, foods: list, member_id: str | None = None):
        m = self.ctx.member(member_id)
        fs = [str(f) for f in foods]
        issues = safety.check(self.ctx.kind(m["id"]), m.get("allergies", []), fs) + _avoid_hits(m, fs)
        if self.ctx.kind(m["id"]) == "elder":
            hard = [w for w in safety.HARD_FOR_ELDER if w in "、".join(safety.expand(fs))]
            if hard:
                issues.append("老人可能不好咀嚼：" + "、".join(hard))
        if issues:
            self.cards.append({"kind": "safety", "member": m.get("name") or "", "foods": fs[:6], "issues": issues})
        return {"member": m.get("name"), "issues": issues, "safe": not issues,
                "note": "规则检查只覆盖常见过敏原、宠物有毒食物和老人咀嚼问题"}

    def search_guidelines(self, query: str, member_id: str | None = None, k: int = 3):
        cards, idx = guide_db()
        kind = self.ctx.kind(member_id)
        hits = [cards[i] for i, _ in idx.search(query, k=k + 3)]
        pref = "pet" if kind in ("dog", "cat") else "elder" if kind == "elder" else None
        if pref:
            hits = sorted(hits, key=lambda c: pref not in c["tags"])
        for c in hits[:k]:
            self.guides[c["id"]] = c
        return [{"id": c["id"], "title": c["title"], "text": c["text"], "source": c["source"]} for c in hits[:k]]

    # ================= 写（App 执行）=================
    def remember(self, text: str):
        mid = _id("M")
        self.emit({"type": "action", "action": {"kind": "remember", "id": mid, "text": text.strip()[:120]}})
        self.ctx.memories.append({"id": mid, "text": text})
        return {"ok": True, "memory_id": mid}

    def forget(self, memory_id: str | None = None, text: str | None = None):
        hit = next((x for x in self.ctx.memories if x.get("id") == memory_id or (text and text in x.get("text", ""))), None)
        if not hit:
            return {"error": "没找到这条记忆", "memories": self.ctx.memories[:30]}
        self.emit({"type": "action", "action": {"kind": "forget", "id": hit["id"], "text": hit["text"]}})
        return {"ok": True, "forgot": hit["text"]}

    def update_fridge(self, add: list | None = None, remove: list | None = None):
        a, r = [str(x) for x in add or []], [str(x) for x in remove or []]
        self.emit({"type": "action", "action": {"kind": "fridge", "add": a, "remove": r}})
        self.ctx.fridge = sorted((set(self.ctx.fridge) | set(a)) - set(r))
        return {"ok": True, "fridge_now": self.ctx.fridge}

    def add_to_shopping_list(self, items: list, note: str = ""):
        its = [str(x) for x in items if str(x).strip()][:40]
        self.cards.append({"kind": "shopping", "items": its, "note": note})
        return {"ok": True, "items": its, "note": "App 会显示按钮，用户点了才会加进「提醒事项」"}

    # ================= 分发 =================
    def call(self, name: str, args: dict):
        fn = getattr(self, name, None)
        if name not in NAMES or fn is None:
            return {"error": f"没有这个工具：{name}"}
        try:
            return fn(**args)
        except TypeError as e:
            return {"error": f"参数不对：{e}"}


def _guess_slot(now: str) -> str:
    try:
        h, mi = (int(x) for x in now.split(":")[:2])
    except ValueError:
        return "lunch"
    t = h + mi / 60
    return "breakfast" if t < 10.5 else "lunch" if t < 15 else "snack" if t < 17 else "dinner" if t < 21.5 else "snack"


NEG = safety.NEG


def _avoid_hits(m: dict, foods: list[str], extra: list[str] | None = None) -> list[str]:
    """忌口是自由文本（如「香菜、花生」），除了过敏原表之外，再做一次字面匹配（「不放香菜」不算）。"""
    text = "、".join(safety.expand([str(f) for f in foods]))
    out = []
    for w in list(m.get("allergies", [])) + list(extra or []):
        w = w.strip()
        if len(w) < 1 or w in safety.ALLERGENS:      # 过敏原表里的已由 safety.check 处理
            continue
        t = text
        for n in NEG:
            t = t.replace(n + w, n)
        if w in t:
            out.append(f"含忌口「{w}」")
    return out


def _f(name, desc, props, req=()):
    return {"type": "function", "function": {"name": name, "description": desc,
                                             "parameters": {"type": "object", "properties": props, "required": list(req)}}}


S, A, I, N = {"type": "string"}, {"type": "array", "items": {"type": "string"}}, {"type": "integer"}, {"type": "number"}
MID = {"type": "string", "description": "家庭成员 id；不填就是当前正在帮的人"}
SLOT = {"type": "string", "enum": ["breakfast", "lunch", "dinner", "snack"]}
DATE = {"type": "string", "description": "YYYY-MM-DD，不填是今天"}
SCHEMAS = [
    _f("estimate_meal", "根据文字描述估算一餐的食物、克数和营养，生成一张待用户确认的记录卡片。会参考用户自己以前的相似记录和份量习惯。",
       {"description": {**S, "description": "用户原话，尽量完整，包括份量和店名"}, "slot": SLOT, "date": DATE, "member_id": MID,
        "copy_of": {**S, "description": "要原样复用的历史记录 id（来自 query_records 的 id 列）"}}, ["description"]),
    _f("analyze_photo", "看用户发来的图片：餐食照片 → 识别并生成记录卡片；菜单/外卖截图 → 按今天剩余热量和本周缺口推荐怎么点；冰箱/食材 → 识别并存进冰箱；包装食品 → 读配料并做安全检查。",
       {"image_id": S, "kind": {"type": "string", "enum": ["auto", "meal", "menu", "fridge", "product"]},
        "note": {**S, "description": "用户对图片的补充说明，如「只吃了一半」"}, "member_id": MID, "slot": SLOT, "date": DATE}, ["image_id"]),
    _f("refine_meal", "用户回答了记录卡片上的问题（或补充了信息）后，修正那张卡片。", {"draft_id": S, "answer": S}, ["draft_id", "answer"]),
    _f("query_records", "在用户手机里的真实饮食记录上执行一条只读 SQL（SQLite）。表结构：\n" + SCHEMA,
       {"sql": S}, ["sql"]),
    _f("nutrition_gaps", "按《中国居民膳食指南》对照最近 N 天（不含今天）的记录，算各类食物的日均量、缺口、油炸/重盐/外卖次数。",
       {"member_id": MID, "days": I}),
    _f("search_recipes", "混合检索（关键词 + 语义）真实菜谱库（HowToCook，约 360 道家常菜）。自动排除过敏原和忌口，标出冰箱里已有和需要买的食材。",
       {"query": {**S, "description": "想吃什么，如「下饭 快手 鸡肉」"}, "must_use": {**A, "description": "必须用上的食材"}, "avoid": A,
        "max_kcal": N, "max_difficulty": {**I, "description": "1–5 星"}, "member_id": MID, "k": I}, ["query"]),
    _f("get_recipe", "取一道菜谱的完整用量和做法步骤。", {"recipe_id": S}, ["recipe_id"]),
    _f("plan_week", "给一位家庭成员排 N 天（默认 7 天）晚饭菜单：内部会检索菜谱，并用程序检查热量、不重复、鱼和蔬菜次数、过敏忌口、工作日难度、优先用冰箱食材，全部通过才返回。",
       {"days": I, "member_id": MID, "requirements": {**S, "description": "用户额外的要求"}, "kcal_min": N, "kcal_max": N}),
    _f("check_food_safety", "用确定性规则检查食物对某位成员是否安全：过敏原、忌口、猫狗有毒食物、老人咀嚼。", {"foods": A, "member_id": MID}, ["foods"]),
    _f("search_guidelines", "检索膳食指南知识库（《中国居民膳食指南 2022》、老年人膳食指南、ASPCA/AVMA 宠物食物安全），返回带编号的原文要点。",
       {"query": S, "member_id": MID}, ["query"]),
    _f("remember", "把用户亲口说的、长期有用的个人信息存进长期记忆（一句第三人称陈述）。", {"text": S}, ["text"]),
    _f("forget", "删除一条长期记忆。", {"memory_id": S, "text": {**S, "description": "记忆内容里的关键词"}}),
    _f("update_fridge", "更新冰箱里的食材。", {"add": A, "remove": A}),
    _f("add_to_shopping_list", "整理一份购物清单，App 会显示「加入提醒事项」按钮。", {"items": A, "note": S}, ["items"]),
]
NAMES = {s["function"]["name"] for s in SCHEMAS}

LABELS = {
    "estimate_meal": ("🧮", "估算这餐的营养"), "analyze_photo": ("📷", "看照片"), "refine_meal": ("✏️", "按你的回答修正"),
    "query_records": ("🗂️", "查询你的饮食记录"), "nutrition_gaps": ("📊", "对照膳食指南算缺口"), "search_recipes": ("🔍", "检索菜谱库"),
    "get_recipe": ("📖", "打开菜谱"), "plan_week": ("🗓️", "排菜单并逐条校验"), "check_food_safety": ("🛡️", "安全规则检查"),
    "search_guidelines": ("📚", "查膳食指南"), "remember": ("🧠", "记住"), "forget": ("🧠", "忘掉"), "update_fridge": ("🧊", "更新冰箱"),
    "add_to_shopping_list": ("🛒", "整理购物清单"),
}


def summarize(name: str, args: dict, res) -> str:
    """步骤详情：让用户看到 agent 具体做了什么（SQL、检索词、找到什么）。"""
    if isinstance(res, dict) and res.get("error"):
        return "出错：" + str(res["error"])[:80]
    try:
        if name == "query_records":
            return f'{args.get("sql", "")}\n→ {res.get("row_count")} 行'
        if name == "search_recipes":
            rs = res.get("results", [])
            return f'「{args.get("query", "")}」→ ' + ("、".join(r["title"] for r in rs) if rs else "没找到")
        if name in ("estimate_meal", "refine_meal") or (name == "analyze_photo" and res.get("kind") == "meal"):
            return f'{res.get("title")} · 约 {round(res.get("kcal", 0))} kcal' + (f'（修正前 {round(res["before_kcal"])}）' if "before_kcal" in res else "")
        if name == "analyze_photo":
            k = res.get("kind")
            if k == "menu":
                return f'认出 {res.get("dish_count")} 道菜，这顿预算约 {res.get("this_meal_budget_kcal")} kcal'
            if k == "fridge":
                return "认出：" + "、".join(res.get("items", [])[:12])
            return str(res.get("name", ""))
        if name == "nutrition_gaps":
            return f'{res.get("days_with_records")} 天有记录 · 缺口：' + ("、".join(res.get("gaps", [])) or "无")
        if name == "search_guidelines":
            return "、".join(f'{c["id"]} {c["title"]}' for c in res)
        if name == "check_food_safety":
            return "安全" if res.get("safe") else "；".join(res.get("issues", []))
        if name == "plan_week":
            return res.get("summary", "")
        if name == "remember":
            return args.get("text", "")
        if name == "update_fridge":
            return " ".join(["+" + x for x in args.get("add", []) or []] + ["−" + x for x in args.get("remove", []) or []])
        if name == "add_to_shopping_list":
            return "、".join(res.get("items", [])[:10])
        if name == "get_recipe":
            return res.get("title", "")
    except Exception:  # noqa: BLE001
        pass
    return ""
