"""一次对话请求的上下文：App 每次把需要的数据随请求带上来，服务器不存任何用户数据（无状态、隐私友好）。

- members   家庭成员档案（人 / 老人 / 猫狗，忌口、目标热量）
- records   手机里最近的饮食记录 → 每次请求建一个内存 SQLite，给 Text-to-SQL 工具查
- memories  长期记忆：用户教过管家的事（份量习惯、口味、忌口），按相关性取出放进提示词
- fridge    冰箱里有什么
- images    这一轮用户附带的图片（data URL）
"""
from __future__ import annotations

import datetime as dt
import re
import sqlite3
from collections import defaultdict
from dataclasses import dataclass, field

from ..rag.kb import bigrams

KIND = {"me": "adult", "adult": "adult", "elder": "elder", "dog": "dog", "cat": "cat"}
GROUPS = ["grain", "whole_grain", "tuber", "veg", "dark_veg", "fruit", "meat", "seafood", "egg", "dairy", "soy_nut", "sweet", "other"]
FLAGS = ["fried", "high_salt", "sugary", "processed", "spicy", "fatty"]
SLOT_CN = {"breakfast": "早餐", "lunch": "午餐", "dinner": "晚餐", "snack": "加餐"}

SCHEMA = """CREATE TABLE meals (            -- 每行一餐
  id TEXT, member TEXT, member_name TEXT,  -- member 是成员 id，'me' 是用户本人
  date TEXT,                               -- 'YYYY-MM-DD'
  weekday INTEGER,                         -- 1=周一 … 7=周日
  slot TEXT,                               -- 'breakfast' / 'lunch' / 'dinner' / 'snack'
  time TEXT,                               -- 'HH:MM'
  dish TEXT,                               -- 菜名
  source TEXT,                             -- 'photo' 拍照 / 'text' 文字 / 'takeout' 外卖 / 'reuse' 复用 / 'agent' 管家记录
  cuisine TEXT, shop TEXT,                 -- 菜系、外卖或餐厅店名（可能为空）
  kcal REAL, protein_g REAL, carbs_g REAL, fat_g REAL, fiber_g REAL,
  grain_g REAL, whole_grain_g REAL, tuber_g REAL, veg_g REAL, dark_veg_g REAL, fruit_g REAL,
  meat_g REAL, seafood_g REAL, egg_g REAL, dairy_g REAL, soy_nut_g REAL, sweet_g REAL,   -- 各类食物克数
  fried INTEGER, high_salt INTEGER, sugary INTEGER, processed INTEGER, spicy INTEGER, fatty INTEGER  -- 1 = 是
);
CREATE TABLE foods (meal_id TEXT, name TEXT, grams REAL, grp TEXT);   -- 每餐里的每样食物，grp 同上面的类别名
-- 蔬菜总量 = veg_g + dark_veg_g；鱼禽蛋瘦肉 = meat_g + seafood_g + egg_g；外卖可看 source='takeout' 或 shop 不为空"""


def _num(v) -> float:
    try:
        return float(v)
    except (TypeError, ValueError):
        return 0.0


@dataclass
class Ctx:
    today: str
    now: str
    member_id: str
    members: list[dict]
    memories: list[dict] = field(default_factory=list)
    records: list[dict] = field(default_factory=list)
    fridge: list[str] = field(default_factory=list)
    images: dict[str, str] = field(default_factory=dict)
    day: dict = field(default_factory=dict)          # 今天的心情、喝水、小记
    _db: sqlite3.Connection | None = None

    @classmethod
    def from_request(cls, c: dict, images: dict | None = None) -> "Ctx":
        members = c.get("members") or [{"id": "me", "name": "我", "kind": "me"}]
        for m in members:
            m["kind"] = m.get("kind") or "me"
            m["allergies"] = [w for w in re.split(r"[，,、；;\s/]+", m.get("avoid") or "") if w]
        today = c.get("today") or dt.date.today().isoformat()
        return cls(today=today, now=c.get("now") or "12:00", member_id=c.get("member_id") or "me", members=members,
                   memories=c.get("memories") or [], records=c.get("records") or [], fridge=c.get("fridge") or [],
                   images=images or {}, day=c.get("day") or {})

    # ---------- 成员 ----------
    def member(self, mid: str | None = None) -> dict:
        mid = mid or self.member_id
        for m in self.members:
            if m["id"] == mid or m.get("name") == mid:
                return m
        return next((m for m in self.members if m["id"] == self.member_id), self.members[0])

    def kind(self, mid: str | None = None) -> str:
        return KIND.get(self.member(mid)["kind"], "adult")

    def describe_members(self) -> str:
        out = []
        for m in self.members:
            t = {"me": "用户本人", "elder": "老人", "dog": "狗", "cat": "猫"}.get(m["kind"], m["kind"])
            bits = [f'{m.get("name") or t}（id={m["id"]}，{t}']
            for k, label in (("age", "岁"),):
                if m.get(k):
                    bits.append(f'{m[k]}{label}')
            if m.get("goal") in ("lose", "gain"):
                bits.append({"lose": "想减脂/减重", "gain": "想增重"}[m["goal"]])
            if m.get("avoid"):
                bits.append("忌口/过敏：" + m["avoid"])
            if m.get("health"):
                bits.append("健康：" + m["health"])
            if m.get("reminders"):
                bits.append("提醒 " + " / ".join(f'{SLOT_CN[k]} {v}' for k, v in m["reminders"].items() if k in SLOT_CN))
            if m.get("kcal_target"):
                bits.append(f'每日目标约 {int(_num(m["kcal_target"]))} kcal')
            out.append("，".join(bits) + "）")
        return "\n".join("- " + x for x in out)

    # ---------- 记录 ----------
    def recs(self, mid: str | None = None) -> list[dict]:
        mid = mid or self.member_id
        return [r for r in self.records if (r.get("member") or "me") == mid]

    def today_status(self, mid: str | None = None) -> str:
        m = self.member(mid)
        rs = [r for r in self.recs(m["id"]) if r.get("date") == self.today]
        if not rs:
            return "今天还没有记录。"
        kcal = sum(_num(r.get("kcal")) for r in rs)
        items = "；".join(f'{SLOT_CN.get(r.get("slot"), r.get("slot"))} {r.get("title") or "未命名"} {round(_num(r.get("kcal")))}kcal（id={r.get("id")}，{r.get("time", "")}）' for r in rs)
        tgt = _num(m.get("kcal_target"))
        left = f"，目标 {int(tgt)}，还剩约 {int(tgt - kcal)} kcal" if tgt else ""
        return f"今天已记录：{items}。合计 {round(kcal)} kcal{left}。"

    def db(self) -> sqlite3.Connection:
        """把手机传来的记录建成只读的内存 SQLite。"""
        if self._db is not None:
            return self._db
        con = sqlite3.connect(":memory:", check_same_thread=False)
        con.executescript(SCHEMA)
        names = {m["id"]: m.get("name") or m["id"] for m in self.members}
        for r in self.records:
            g = defaultdict(float)
            for f in r.get("foods") or []:
                g[f.get("group") or "other"] += _num(f.get("grams"))
            fl = set(r.get("flags") or [])
            try:
                wd = dt.date.fromisoformat(r.get("date", "")).isoweekday()
            except ValueError:
                wd = None
            mid = r.get("member") or "me"
            cols = [x for x in GROUPS if x != "other"]
            con.execute(f"INSERT INTO meals VALUES ({','.join('?' * (16 + len(cols) + len(FLAGS)))})", [
                r.get("id"), mid, names.get(mid, mid), r.get("date"), wd, r.get("slot"), r.get("time"), r.get("title"),
                r.get("source") or "photo", r.get("cuisine"), r.get("shop"),
                _num(r.get("kcal")), _num(r.get("protein")), _num(r.get("carbs")), _num(r.get("fat")), _num(r.get("fiber")),
                *[g[x] for x in cols], *[int(x in fl) for x in FLAGS]])
            for f in r.get("foods") or []:
                con.execute("INSERT INTO foods VALUES (?,?,?,?)", [r.get("id"), f.get("name"), _num(f.get("grams")), f.get("group")])
        con.commit()
        con.execute("PRAGMA query_only = 1")
        self._db = con
        return con

    def similar_records(self, text: str, mid: str | None = None, k: int = 3) -> list[dict]:
        """个人记录检索：用户以前记过的、名字相近的餐（他自己的份量和热量），用来让估算前后一致。"""
        q = set(bigrams(text))
        scored = []
        for r in self.recs(mid):
            t = r.get("title") or ""
            if not t or not r.get("foods"):
                continue
            s = len(q & set(bigrams(t))) / (len(set(bigrams(t))) or 1)
            if s >= 0.5:
                scored.append((s, r.get("date", ""), r))
        scored.sort(key=lambda x: (x[0], x[1]), reverse=True)   # 最像的、最近的优先
        out, seen = [], set()
        for _, _, r in scored:
            if r["title"] in seen:
                continue
            seen.add(r["title"])
            out.append(r)
            if len(out) >= k:
                break
        return out

    # ---------- 长期记忆 ----------
    def relevant_memories(self, text: str, k: int = 25) -> list[dict]:
        """记忆不多时全部给模型；多了就按和当前问题的字面相关性（中文二元组重叠）取前 k 条。"""
        mem = [m for m in self.memories if m.get("text")]
        if len(mem) <= k:
            return mem
        q = set(bigrams(text))
        return sorted(mem, key=lambda m: -len(q & set(bigrams(m["text"]))))[:k]
