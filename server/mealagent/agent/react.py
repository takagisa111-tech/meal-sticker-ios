"""通用 ReAct agent（LangGraph）：模型决定调用哪个工具 → 执行 → 把结果给模型 → 直到模型给出最终答案。
analyst（Text-to-SQL）和 weekly（一周菜单）都用它。"""
from __future__ import annotations

import json
from typing import Callable, TypedDict

from langgraph.graph import END, START, StateGraph

from ..schema import RunStats


class RState(TypedDict, total=False):
    messages: list
    steps: int


def build(llm: Callable, tools: list, call_tool: Callable[[str, dict], object], stats: RunStats, max_steps: int = 8):
    def agent(s: RState):
        msg = llm(s["messages"], stats, tools)
        m = {"role": "assistant", "content": msg.content or ""}
        if msg.tool_calls:
            m["tool_calls"] = [{"id": c.id, "type": "function", "function": {"name": c.function.name, "arguments": c.function.arguments}}
                               for c in msg.tool_calls]
        return {"messages": s["messages"] + [m], "steps": s.get("steps", 0) + 1}

    def run_tools(s: RState):
        out = []
        for c in s["messages"][-1].get("tool_calls", []):
            try:
                args = json.loads(c["function"]["arguments"] or "{}")
            except json.JSONDecodeError:
                args = {}
            try:
                res = call_tool(c["function"]["name"], args)
            except Exception as e:  # noqa: BLE001  工具报错也交给模型看，让它自己改
                res = {"error": f"{type(e).__name__}: {e}"}
            out.append({"role": "tool", "tool_call_id": c["id"], "content": json.dumps(res, ensure_ascii=False, default=str)[:6000]})
        return {"messages": s["messages"] + out}

    def route(s: RState):
        last = s["messages"][-1]
        return "tools" if last.get("tool_calls") and s.get("steps", 0) < max_steps else "end"

    g = StateGraph(RState)
    g.add_node("agent", agent)
    g.add_node("tools", run_tools)
    g.add_edge(START, "agent")
    g.add_conditional_edges("agent", route, {"tools": "tools", "end": END})
    g.add_edge("tools", "agent")
    return g.compile()


def final_text(messages: list) -> str:
    for m in reversed(messages):
        if m.get("role") == "assistant" and m.get("content") and not m.get("tool_calls"):
            return m["content"]
    return ""
