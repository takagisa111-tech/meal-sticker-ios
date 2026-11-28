"""饮食数据分析 agent（Text-to-SQL）：「过去 30 天我吃了几次鱼？」「上次吃火锅是哪天？」

agent       ReAct：模型看表结构 → 写 SQL → 执行（只读）→ 看结果 → 必要时改 SQL → 给出答案
plain_full  对照组：把全部记录（约 800 条）一次性放进提示词，让模型直接读表回答
"""
from __future__ import annotations

import json
import re

from ..data import history
from ..llm import extract_json
from ..schema import RunStats
from . import react
from .planner import _llm

SYSTEM = f"""你是「食贴」App 的饮食数据分析助手。今天是 {history.TODAY.isoformat()}（记录截止到昨天）。
用户的饮食记录在 SQLite 表 meals 里：
{history.SCHEMA}

做法：先想清楚要算什么（时间范围、哪位成员、按餐还是按天），用 run_sql 查询；结果不对劲就检查 SQL 再查。
「过去 N 天」指 date >= date('{history.TODAY.isoformat()}', '-N day')。「按天平均」= 总量 ÷ 天数。
最后只输出一个 JSON：{{"value": 数字 / 日期字符串 / 文字标签 / 列表, "explanation": "一句话说明怎么算的"}}"""

PLAIN_SYSTEM = f"""你是「食贴」App 的饮食数据分析助手。今天是 {history.TODAY.isoformat()}（记录截止到昨天）。
下面是用户全部的饮食记录（CSV，每行一餐）。请直接根据数据回答。
「过去 N 天」指日期 >= 今天往前 N 天。「按天平均」= 总量 ÷ 天数。
只输出一个 JSON：{{"value": 数字 / 日期字符串 / 文字标签 / 列表, "explanation": "一句话说明怎么算的"}}"""

TOOLS = [{"type": "function", "function": {"name": "run_sql", "description": "在只读的 SQLite 数据库上执行一条 SELECT 语句，返回最多 200 行结果。",
          "parameters": {"type": "object", "properties": {"sql": {"type": "string"}}, "required": ["sql"]}}}]
COLS = ["member", "date", "weekday", "slot", "dish", "source", "cuisine", "kcal", "protein_g", "veg_g", "dairy_g", "fish_g", "fried"]


def run_sql(sql: str):
    if not re.match(r"^\s*(select|with)\b", sql, re.I) or ";" in sql.strip().rstrip(";"):
        return {"error": "只允许单条 SELECT 查询"}
    con = history.connect(readonly=True)
    try:
        cur = con.execute(sql)
        cols = [d[0] for d in cur.description]
        rows = cur.fetchmany(200)
        return {"columns": cols, "rows": rows, "truncated": len(rows) == 200}
    finally:
        con.close()


def ask(question: str, stats: RunStats) -> dict:
    app = react.build(_llm, TOOLS, lambda name, args: run_sql(**args) if name == "run_sql" else {"error": "未知工具"}, stats)
    s = app.invoke({"messages": [{"role": "system", "content": SYSTEM}, {"role": "user", "content": question}]}, {"recursion_limit": 30})
    sqls = [json.loads(c["function"]["arguments"]).get("sql", "") for m in s["messages"] if m.get("tool_calls") for c in m["tool_calls"]]
    out = extract_json(react.final_text(s["messages"])) or {}
    return {"value": out.get("value"), "explanation": out.get("explanation", ""), "sql": sqls}


def ask_plain(question: str, stats: RunStats) -> dict:
    con = history.connect()
    rows = con.execute(f"SELECT {','.join(COLS)} FROM meals ORDER BY date, member").fetchall()
    con.close()
    csv = ",".join(COLS) + "\n" + "\n".join(",".join(str(round(v) if isinstance(v, float) else v) for v in r) for r in rows)
    m = _llm([{"role": "system", "content": PLAIN_SYSTEM}, {"role": "user", "content": csv + "\n\n问题：" + question}], stats)
    out = extract_json(m.content or "") or {}
    return {"value": out.get("value"), "explanation": out.get("explanation", ""), "sql": []}
