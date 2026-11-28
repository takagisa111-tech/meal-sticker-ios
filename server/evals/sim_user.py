"""评测用的「模拟用户」：知道这顿饭的真实菜名和食材份量（不知道热量），像普通人一样简短回答 agent 的问题。
它的调用不计入 agent 的耗时和成本。"""
from __future__ import annotations

from mealagent.llm import chat_text
from mealagent.prompts import agent_zh


def make(item: dict):
    ings = []
    for i in item.get("ingredient_details", []):
        q, u = i.get("quantity"), i.get("unit", "")
        amount = f"{q:g} {u}".strip() if isinstance(q, (int, float)) else ""
        ings.append(f'{i.get("name", "")} {amount}'.strip())
    ings_txt = "；".join(ings) or "、".join(item.get("ingredients", []))

    def answer(question: str, options: list) -> str:
        opts = f"（选项：{' / '.join(options)}）" if options else ""
        return chat_text(agent_zh.SIM_USER.format(meal=item["meal_name"], ings=ings_txt, question=question, options=opts),
                         system=agent_zh.SIM_USER_SYSTEM, temperature=0.2, max_tokens=80)
    return answer
