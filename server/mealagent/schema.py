"""统一的识别结果格式（和 January Food Benchmark 对齐，方便评测）。"""
from typing import List
from pydantic import BaseModel, Field


class Ingredient(BaseModel):
    name: str
    grams: float = 0
    calories: float = 0
    carbs: float = 0
    protein: float = 0
    fat: float = 0
    source: str = ""  # 营养来自哪条数据库记录（RAG），空表示模型自己估的


class Macros(BaseModel):
    calories: float = 0
    carbs: float = 0
    protein: float = 0
    fat: float = 0


class FoodAnalysis(BaseModel):
    meal_name: str = ""
    ingredients: List[Ingredient] = Field(default_factory=list)
    total: Macros = Field(default_factory=Macros)
    trace: list = Field(default_factory=list)  # agent 的执行轨迹（问了什么、用户怎么答）


class RunStats(BaseModel):
    """一次识别的耗时、token 和成本。"""
    seconds: float = 0
    input_tokens: int = 0
    output_tokens: int = 0
    llm_calls: int = 0
    questions: int = 0  # agent 向用户提问的次数

    def cost_usd(self, price_in: float, price_out: float) -> float:
        return self.input_tokens / 1e6 * price_in + self.output_tokens / 1e6 * price_out
