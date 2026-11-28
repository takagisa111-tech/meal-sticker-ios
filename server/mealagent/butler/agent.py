"""管家 agent 主循环：流式 function calling（ReAct），把每一步推给 App。

事件（每个都是一个 JSON，服务器用 SSE 发出）：
  {"type": "text", "delta": "…"}                         回答文字（流式）
  {"type": "step", "id", "tool", "icon", "label", "status": "running"|"done"|"error", "detail"}
  {"type": "note", "step", "text"}                       工具内部的进度（检索到几张参考图、第几次校验）
  {"type": "action", "action": {...}}                    App 直接执行的小动作（记住一件事、更新冰箱），带撤销
  {"type": "card", "card": {...}}                        结构化卡片：记录草稿 / 菜谱 / 菜单推荐 / 一周菜单 / 表格 / 安全 / 购物 / 出处
  {"type": "memo", "text"}                               给下一轮用的隐藏备注（卡片内容摘要），App 原样带回来 → 服务器无状态
  {"type": "done", "stats": {...}}
  {"type": "error", "message"}
"""
from __future__ import annotations

import contextvars
import datetime as dt
import json
import queue
import re
import threading
import time
from typing import Iterator

from .. import config
from ..llm import client
from ..schema import RunStats
from . import prompts
from .context import Ctx
from .tools import LABELS, SCHEMAS, Turn, summarize

MAX_STEPS = 8
REF = re.compile(r"\[\[([A-Z]{1,2}\d{1,3}[a-z]?)\]\]")
MEMO = re.compile(r"〔draft (D[0-9a-f]{5})〕(\{.*?\})〔/draft〕", re.S)
WEEKDAY = "一二三四五六日"


def _system(ctx: Ctx, user_text: str) -> str:
    m = ctx.member()
    mem = ctx.relevant_memories(user_text)
    d = dt.date.fromisoformat(ctx.today)
    return prompts.SYSTEM.format(
        today=ctx.today, weekday="周" + WEEKDAY[d.isoweekday() - 1], now=ctx.now,
        who=f'{m.get("name") or "我"}（id={m["id"]}）', today_status=ctx.today_status(),
        fridge="、".join(ctx.fridge) if ctx.fridge else "（没有登记）", members=ctx.describe_members(),
        memories="\n".join(f'- [{x.get("id", "")}] {x["text"]}' for x in mem) if mem else "（还没有）",
        taste=ctx.taste_line())


def _history(body: dict) -> tuple[list[dict], dict]:
    """App 发来的对话历史 → 模型消息。助手消息后面带着上一轮的 memo（卡片摘要），从里面恢复记录草稿。"""
    msgs, drafts = [], {}
    for x in body.get("messages", [])[-24:]:
        role, text = x.get("role"), str(x.get("content") or "")
        if role not in ("user", "assistant") or not text.strip():
            continue
        if role == "assistant":
            for did, js in MEMO.findall(text):
                try:
                    drafts[did] = json.loads(js)
                except json.JSONDecodeError:
                    pass
            text = MEMO.sub(lambda mm: f"〔记录卡片 {mm.group(1)}〕", text)
        for iid in x.get("image_ids") or []:
            text += f"\n[附图 image_id={iid}]"
        msgs.append({"role": role, "content": text[:6000]})
    return msgs, drafts


def _memo(turn: Turn, final: str) -> str:
    parts = []
    for did in turn.new_drafts:
        d = turn.drafts[did]
        keep = {k: d[k] for k in ("id", "member_id", "slot", "date", "title", "emoji", "cuisine", "methods", "flags", "foods",
                                  "kcal", "protein", "carbs", "fat", "fiber", "comment", "question", "image_id", "source")}
        parts.append(f"〔draft {did}〕{json.dumps(keep, ensure_ascii=False)}〔/draft〕")
    for rid in dict.fromkeys(REF.findall(final)):
        if rid in turn.recipes:
            parts.append(f"〔菜谱 {rid} {turn.recipes[rid]['title']}〕")
    for c in turn.cards:
        if c["kind"] == "plan":
            parts.append("〔一周菜单 " + "；".join(f'{r["weekday"]} {r["title"]}[{r["recipe_id"]}]' for r in c["rows"]) + "〕")
        if c["kind"] == "journal":
            parts.append(f'〔手账设计 {c["date"]} {c["style"]}：{c["title"]}｜{c["caption"]}〕')
        if c["kind"] == "occasion":
            parts.append("〔聚餐方案 " + "、".join(f'{d["title"]}[{d["recipe_id"]}]' for d in c["dishes"]) + "〕")
        if c["kind"] == "menu":
            parts.append("〔菜单推荐 " + "、".join(p["name"] for p in c["picks"]) + "〕")
    if turn.table:
        parts.append(f'〔查询 {turn.table["sql"]}〕')
    return "\n".join(parts)


def _cards(turn: Turn, final: str) -> list[dict]:
    cards = []
    for did in turn.new_drafts:
        cards.append({"kind": "meal", **turn.drafts[did]})
    order = {"journal": 0, "occasion": 1, "menu": 2, "plan": 3}
    cards += sorted([c for c in turn.cards if c["kind"] in order], key=lambda c: order[c["kind"]])
    refs = list(dict.fromkeys(REF.findall(final)))
    plan_ids = {r["recipe_id"] for c in turn.cards if c["kind"] == "plan" for r in c["rows"]}
    for rid in refs:
        if rid.startswith("R") and rid not in plan_ids:
            c = turn.recipe_card(rid)
            if c:
                cards.append(c)
    if turn.table:
        cards.append(turn.table)
    cards += [c for c in turn.cards if c["kind"] in ("nearby", "takeout", "safety", "shopping", "confirm", "share")]
    cites = [turn.guides[g] for g in refs if g in turn.guides]
    if not cites and turn.guides:   # 查了指南但正文忘了标编号：仍然给出处
        cites = list(turn.guides.values())[:3]
    if cites:
        cards.append({"kind": "sources", "items": [{"id": c["id"], "title": c["title"], "text": c["text"], "source": c["source"],
                                                    "url": c.get("url", "")} for c in cites]})
    return cards


def _stream_llm(messages: list, stats: RunStats, tools: list | None):
    """流式调用：边生成边把文字吐出来；工具调用的参数分片拼起来。"""
    t = time.time()
    kw = {"tools": tools, "tool_choice": "auto"} if tools else {}
    resp = client().chat.completions.create(
        model=config.DEEPSEEK_MODEL, messages=messages, temperature=0.4, max_tokens=1800, stream=True,
        stream_options={"include_usage": True}, extra_body={"thinking": {"type": "disabled"}}, **kw)
    calls: dict[int, dict] = {}
    for ch in resp:
        if ch.usage:
            stats.input_tokens += ch.usage.prompt_tokens or 0
            stats.output_tokens += ch.usage.completion_tokens or 0
        if not ch.choices:
            continue
        d = ch.choices[0].delta
        if d.content:
            yield "text", d.content
        for tc in d.tool_calls or []:
            c = calls.setdefault(tc.index, {"id": "", "name": "", "args": ""})
            if tc.id:
                c["id"] = tc.id
            if tc.function and tc.function.name:
                c["name"] += tc.function.name
            if tc.function and tc.function.arguments:
                c["args"] += tc.function.arguments
    stats.llm_calls += 1
    stats.seconds += time.time() - t
    yield "calls", [calls[i] for i in sorted(calls)]


def run(body: dict) -> Iterator[dict]:
    t0 = time.time()
    stats = RunStats()
    ctx = Ctx.from_request(body.get("context") or {}, body.get("images") or {})
    hist, prior = _history(body)
    if not hist or hist[-1]["role"] != "user":
        yield {"type": "error", "message": "没有收到你的消息"}
        return
    q: queue.Queue = queue.Queue()
    current = {"step": None}

    def emit(ev: dict):
        if ev.get("type") == "note":
            ev["step"] = current["step"]
        q.put(ev)

    turn = Turn(ctx, stats, emit, prior)
    msgs = [{"role": "system", "content": _system(ctx, hist[-1]["content"])}] + hist
    final = ""
    try:
        for step in range(MAX_STEPS + 1):
            tools = SCHEMAS if step < MAX_STEPS else None
            text, calls = "", []
            for kind, val in _stream_llm(msgs, stats, tools):
                if kind == "text":
                    text += val
                    yield {"type": "text", "delta": val}
                else:
                    calls = val
            assistant = {"role": "assistant", "content": text}
            if calls:
                assistant["tool_calls"] = [{"id": c["id"] or f"call{step}{i}", "type": "function",
                                            "function": {"name": c["name"], "arguments": c["args"] or "{}"}} for i, c in enumerate(calls)]
            msgs.append(assistant)
            final += text
            if not calls:
                break
            if text and not text.endswith("\n"):
                yield {"type": "text", "delta": "\n"}
                final += "\n"
            for c in assistant["tool_calls"]:
                name = c["function"]["name"]
                try:
                    args = json.loads(c["function"]["arguments"] or "{}")
                except json.JSONDecodeError:
                    args = {}
                icon, label = LABELS.get(name, ("🔧", name))
                sid = c["id"]
                current["step"] = sid
                yield {"type": "step", "id": sid, "tool": name, "icon": icon, "label": label, "status": "running", "detail": ""}
                # 工具在后台线程跑，期间把它发出的进度（note / action）实时转发
                box: dict = {}

                def work():
                    try:
                        box["res"] = turn.call(name, args)
                    except Exception as e:  # noqa: BLE001  工具出错交给模型处理
                        box["res"] = {"error": f"{type(e).__name__}: {e}"}
                    finally:
                        q.put(None)

                th = threading.Thread(target=contextvars.copy_context().run, args=(work,), daemon=True)   # 带上这一轮的 Key
                th.start()
                while True:
                    ev = q.get()
                    if ev is None:
                        break
                    yield ev
                res = box.get("res")
                err = isinstance(res, dict) and bool(res.get("error"))
                yield {"type": "step", "id": sid, "tool": name, "icon": icon, "label": label, "status": "error" if err else "done",
                       "detail": summarize(name, args, res)}
                msgs.append({"role": "tool", "tool_call_id": sid, "content": json.dumps(res, ensure_ascii=False, default=str)[:8000]})
        for c in _cards(turn, final):
            yield {"type": "card", "card": c}
        memo = _memo(turn, final)
        if memo:
            yield {"type": "memo", "text": memo}
        yield {"type": "done", "stats": {"seconds": round(time.time() - t0, 1), "llm_calls": stats.llm_calls,
                                         "tokens": stats.input_tokens + stats.output_tokens,
                                         "cost_usd": round(stats.cost_usd(config.PRICE_INPUT_PER_M, config.PRICE_OUTPUT_PER_M), 5)}}
    except Exception as e:  # noqa: BLE001
        import traceback
        traceback.print_exc()
        yield {"type": "error", "message": f"{type(e).__name__}: {e}"}
