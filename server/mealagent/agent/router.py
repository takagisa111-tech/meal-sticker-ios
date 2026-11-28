"""智能路由：先用一次很便宜的调用判断问题类型，再分给最合适的执行方式。

simple     日常问答（下一餐吃什么、这周吃得怎么样、能不能吃）→ 单次调用 + 菜谱检索（评测里最好）
analytics  需要在长期记录上精确统计（几次、哪天、平均、趋势）→ Text-to-SQL agent
weekly     排多天的菜单、约束很多 → 带校验循环的规划 agent
"""
from __future__ import annotations

from ..llm import chat_json
from ..schema import RunStats

PROMPT = """把用户对饮食管家的请求分到一类，只输出 JSON：{{"route": "simple" | "analytics" | "weekly"}}

simple：关于下一餐、今天、这周整体情况的建议，推荐菜或餐厅，某样东西能不能吃，加购物清单、设提醒。
analytics：要在历史饮食记录上精确统计或查找：几次、几天、哪天、平均多少、最多的是什么、是变多还是变少。
weekly：要排未来多天（如一周）的菜单或餐单计划。

例子：
「明天午饭吃什么？用冰箱里的东西」→ simple
「我这周吃得怎么样，下一餐补点什么」→ simple
「猫能吃葡萄吗」→ simple
「过去30天我吃了几次鱼？」→ analytics
「上次吃火锅是哪天」→ analytics
「最近外卖是不是变多了」→ analytics
「帮我排下周7天的晚饭」→ weekly
「给妈妈做个下周的菜单，要软一点」→ weekly

请求：{q}"""


def route(question: str, stats: RunStats) -> str:
    r = chat_json(PROMPT.format(q=question), stats=stats, json_mode=True, temperature=0, max_tokens=30)
    x = str(r.get("route", "simple"))
    return x if x in ("simple", "analytics", "weekly") else "simple"
