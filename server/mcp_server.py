"""食贴 MCP 服务：让 Claude Desktop 等支持 MCP 的 AI 助手直接调用食贴的能力。

运行（stdio）：.venv/bin/python mcp_server.py
在 Claude Desktop 的配置里加入：
  "shitie": {"command": "<项目路径>/.venv/bin/python", "args": ["<项目路径>/mcp_server.py"]}

提供的工具：
  recognize_meal      识别一张本地餐食照片（多模态 RAG，不提问的一次性版本）
  ask_meal_butler     家庭饮食管家：下一餐吃什么、这周吃得怎么样、宠物能不能吃
  check_food_safety   检查食物对某位成员是否安全（过敏原、宠物有毒、老人难咀嚼）
  search_recipes      检索 362 道家常菜谱（自动排除过敏原）
  search_guidelines   检索膳食指南知识卡片（带出处）
"""
from __future__ import annotations

from mcp.server.fastmcp import FastMCP
from PIL import Image

from app import store
from mealagent.agent import planner, recognizer, safety
from mealagent.agent.tools import Toolbox
from mealagent.schema import RunStats

mcp = FastMCP("shitie")


@mcp.tool()
def recognize_meal(image_path: str) -> dict:
    """识别本地餐食照片，返回每样食物的份量和营养估计（参照 5 张外观相似、份量已核实的餐）。"""
    a = recognizer.run(Image.open(image_path), RunStats(), max_questions=0, use_refs=True, k_refs=5)
    return a.model_dump(exclude={"trace"})


@mcp.tool()
def ask_meal_butler(request: str, member: str = "me") -> dict:
    """家庭饮食管家。member 取 me（我）/ mom（妈妈，82 岁）/ cat（猫团子）。"""
    out = planner.run_plain(store.scenario(member, request), RunStats(), with_recipes=True)
    return {"final": out["final"], "actions": out["actions"]}


@mcp.tool()
def check_food_safety(foods: list[str], kind: str = "adult", allergies: list[str] | None = None) -> dict:
    """kind 取 adult / elder / dog / cat；返回不安全的原因列表，空列表表示安全。"""
    issues = safety.check(kind, allergies or [], foods)
    if kind == "elder":
        issues += [f"{f}：老人可能难咀嚼" for f in foods if any(w in "、".join(safety.expand([f])) for w in safety.HARD_FOR_ELDER)]
    return {"issues": issues}


@mcp.tool()
def search_recipes(query: str, avoid: list[str] | None = None, member: str = "me") -> list[dict]:
    """检索家常菜谱（HowToCook，公有领域），会自动排除该成员的过敏原和 avoid 里的食材。"""
    return Toolbox(store.scenario(member, query)).search_recipes(query, avoid=avoid or [], k=6)


@mcp.tool()
def search_guidelines(query: str, member: str = "me") -> list[dict]:
    """检索膳食指南知识卡片（中国居民膳食指南 2022、老年人膳食指南、ASPCA 宠物禁忌等），带出处。"""
    return Toolbox(store.scenario(member, query)).search_guidelines(query, k=4)


if __name__ == "__main__":
    mcp.run()
