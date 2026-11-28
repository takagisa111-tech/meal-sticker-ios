"""规划 agent（LangGraph）：「下一餐 / 这周吃什么」「爸妈和猫这周吃得怎么样」。

    START → agent ⇄ tools（ReAct：模型决定调哪个工具、看结果、再决定下一步）
              │ 不再调用工具
              ▼
           guardrail ──(违规且还能改)──→ agent（带着问题清单重写）
              │ 通过 / 改够了
              ▼
             END

guardrail 是确定性规则（不依赖模型）：推荐的菜不能含过敏原、宠物有毒食物；引用的指南 id 必须真实存在。
"""
from __future__ import annotations

import json
import time
from typing import TypedDict

from langgraph.graph import END, START, StateGraph

from .. import config
from ..knowledge.guidelines import CARDS
from ..llm import client, extract_json
from ..prompts import planner_zh
from ..schema import RunStats
from . import safety
from .tools import SCHEMAS, Toolbox, recipe_db

VALID_IDS = {c["id"] for c in CARDS}


class PState(TypedDict, total=False):
    messages: list
    final: dict
    fixes: int
    steps: int


def _llm(messages, stats: RunStats, tools=None):
    t = time.time()
    kw = {"tools": tools, "tool_choice": "auto"} if tools else {}
    r = client().chat.completions.create(model=config.DEEPSEEK_MODEL, messages=messages, temperature=0.3, max_tokens=2000,
                                         stream=False, extra_body={"thinking": {"type": "disabled"}}, **kw)
    stats.seconds += time.time() - t
    stats.llm_calls += 1
    if r.usage:
        stats.input_tokens += r.usage.prompt_tokens or 0
        stats.output_tokens += r.usage.completion_tokens or 0
    return r.choices[0].message


def recipe_ids() -> set:
    rs, _ = recipe_db()
    return {r["id"] for r in rs}


def rec_ingredients(rec: dict, tb: Toolbox | None) -> list[str]:
    ings = [str(x) for x in rec.get("ingredients") or []]
    rid = rec.get("recipe_id")
    if rid:
        rs, _ = recipe_db()
        r = next((x for x in rs if x["id"] == rid), None)
        if r:
            ings += r["ingredients"]
    return ings + [str(rec.get("dish", ""))]


def validate(final: dict, member: dict, tb: Toolbox | None) -> list[str]:
    issues = []
    for rec in final.get("recommendations") or []:
        if not isinstance(rec, dict):
            continue
        bad = safety.check(member["kind"], member.get("allergies", []), rec_ingredients(rec, tb))
        if member["kind"] == "elder" and any(w in "、".join(safety.expand([str(rec.get("dish", ""))])) for w in safety.HARD_FOR_ELDER):
            bad.append("老人难咀嚼（油炸/偏硬）")
        if bad:
            issues.append(f"「{rec.get('dish')}」：" + "；".join(bad))
    bad_ids = [c for c in final.get("citations") or [] if c not in VALID_IDS]
    if bad_ids:
        issues.append(f"引用了不存在的指南 id：{bad_ids}")
    return issues


def build(scenario: dict, stats: RunStats, tb: Toolbox, guard: bool = True, max_steps: int = 10):
    def agent(s: PState):
        msg = _llm(s["messages"], stats, SCHEMAS)
        m = {"role": "assistant", "content": msg.content or ""}
        if msg.tool_calls:
            m["tool_calls"] = [{"id": c.id, "type": "function", "function": {"name": c.function.name, "arguments": c.function.arguments}}
                               for c in msg.tool_calls]
        return {"messages": s["messages"] + [m], "steps": s.get("steps", 0) + 1}

    def tools(s: PState):
        last = s["messages"][-1]
        out = []
        for c in last.get("tool_calls", []):
            try:
                args = json.loads(c["function"]["arguments"] or "{}")
            except json.JSONDecodeError:
                args = {}
            res = tb.call(c["function"]["name"], args)
            out.append({"role": "tool", "tool_call_id": c["id"], "content": json.dumps(res, ensure_ascii=False)[:4000]})
        return {"messages": s["messages"] + out}

    def route_agent(s: PState):
        last = s["messages"][-1]
        if last.get("tool_calls") and s.get("steps", 0) < max_steps:
            return "tools"
        return "guardrail"

    def guardrail(s: PState):
        last = s["messages"][-1]
        final = extract_json(last.get("content") or "") or {}
        if not final:
            base = s["messages"][:-1] if last.get("tool_calls") else s["messages"]
            msgs = base + [{"role": "user", "content": "请按要求只输出最终的 JSON 对象。"}]
            m = _llm(msgs, stats)
            final = extract_json(m.content or "") or {"answer": m.content or ""}
        issues = validate(final, scenario["member"], tb) if guard else []
        if issues and s.get("fixes", 0) < 2:
            return {"final": final, "fixes": s.get("fixes", 0) + 1,
                    "messages": s["messages"] + [{"role": "user", "content": planner_zh.FIX.format(issues="\n".join(issues))}]}
        return {"final": dict(final, _issues=issues), "fixes": s.get("fixes", 0)}

    def route_guard(s: PState):
        return "agent" if s["messages"][-1]["role"] == "user" and s["messages"][-1]["content"].startswith("你的方案没有通过") else "end"

    g = StateGraph(PState)
    g.add_node("agent", agent)
    g.add_node("tools", tools)
    g.add_node("guardrail", guardrail)
    g.add_edge(START, "agent")
    g.add_conditional_edges("agent", route_agent, {"tools": "tools", "guardrail": "guardrail"})
    g.add_edge("tools", "agent")
    g.add_conditional_edges("guardrail", route_guard, {"agent": "agent", "end": END})
    return g


def run(scenario: dict, stats: RunStats, guard: bool = True) -> dict:
    tb = Toolbox(scenario)
    msgs = [{"role": "system", "content": planner_zh.SYSTEM},
            {"role": "user", "content": f"（当前成员：{scenario['member']['name']}）{scenario['request']}"}]
    app = build(scenario, stats, tb, guard=guard).compile()
    s = app.invoke({"messages": msgs}, {"recursion_limit": 40})
    final = s.get("final", {})
    return {"final": final, "actions": tb.actions, "tool_calls": tb.calls, "fixes": s.get("fixes", 0)}


def run_plain(scenario: dict, stats: RunStats, with_recipes: bool = False) -> dict:
    """单次调用：把这位成员的全部资料一次性放进提示词，模型直接回答（评测里它赢过了 ReAct agent）。
    with_recipes=True 时先用混合检索从菜谱库取 12 道相关、且已排除过敏原/宠物禁忌的菜一起放进去（检索增强的单次调用），
    这样推荐的菜来自真实菜谱、带 recipe_id 和每份热量。"""
    tb = Toolbox(scenario)
    summary = tb.get_nutrition_summary()
    ctx = {"成员档案": tb.get_profile(), "近7天营养统计": summary, "冰箱": tb.get_fridge(),
           "附近餐厅": scenario.get("restaurants", []), "膳食指南卡片": [{"id": c["id"], "text": c["text"]} for c in CARDS]}
    if with_recipes and scenario["member"]["kind"] not in ("dog", "cat"):
        q = scenario["request"] + " " + " ".join(summary["biggest_gaps"]) + " " + " ".join(scenario.get("fridge", []))
        ctx["候选菜谱（已排除过敏原）"] = tb.search_recipes(q, k=12)
    msgs = [{"role": "system", "content": planner_zh.PLAIN_SYSTEM},
            {"role": "user", "content": "资料：" + json.dumps(ctx, ensure_ascii=False) + f"\n\n用户：{scenario['request']}"}]
    m = _llm(msgs, stats)
    final = extract_json(m.content or "") or {"answer": m.content or ""}
    issues = validate(final, scenario["member"], tb)
    if issues:  # 同样的确定性护栏：违规就带着问题清单让模型改一次
        msgs += [{"role": "assistant", "content": m.content or ""}, {"role": "user", "content": planner_zh.FIX.format(issues="\n".join(issues))}]
        m = _llm(msgs, stats)
        final = extract_json(m.content or "") or final
    actions = []
    if final.get("shopping_list"):
        actions.append({"type": "shopping", "items": final["shopping_list"]})
    for r in final.get("reminders") or []:
        actions.append({"type": "reminder", **(r if isinstance(r, dict) else {"text": str(r)})})
    return {"final": final, "actions": actions, "tool_calls": [], "fixes": int(bool(issues))}
