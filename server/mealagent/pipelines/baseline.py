"""基线：和 iOS App 现在的做法完全一致——一张图、一个提示词，模型直接估出菜品和营养。
提示词照搬 ShiTie/AI.swift 的 analyzeMeal（成人、拍照识别），只是不需要的字段没有删。"""
from PIL import Image

from ..llm import chat_json
from ..schema import FoodAnalysis, Ingredient, Macros, RunStats

CUISINES = "川菜、湘菜、粤菜、江浙菜、鲁菜、东北菜、西北菜、云贵菜、闽菜、徽菜、家常菜、日料、韩餐、东南亚菜、西餐、快餐、轻食沙拉、面食小吃、火锅、烧烤、烘焙甜品、其他"
METHODS = "蒸、煮、炖、炒、煎、炸、烤、凉拌、生食"

PROMPT = f"""你是一位细心的注册营养师，帮用户记录饮食。请识别图片里这一餐吃了什么，估算分量和营养。
对象情况：成年人。
只输出一个 JSON 对象，不要任何其他文字：
{{"title":"这餐的简短名字(≤8字)","emoji":"一个最能代表它的食物emoji","cuisine":"川菜","methods":["炒"],"foods":[{{"name":"米饭","grams":75,"group":"grain"}}],"kcal":620,"protein":24,"carbs":80,"fat":18,"fiber":5,"flags":[],"comment":"一句具体、温和的营养点评(≤30字)"}}
cuisine 从这些里选一个最贴切的：{CUISINES}。methods 是这餐用到的主要做法，从这些里选：{METHODS}。
group 只能取：grain(精米白面等精制谷物) whole_grain(糙米燕麦玉米小米红豆绿豆等全谷物和杂豆) tuber(土豆红薯芋头山药) veg(浅色蔬菜) dark_veg(深绿/红/橙/紫色蔬菜) fruit meat(猪牛羊鸡鸭及其制品) seafood(鱼虾贝等水产) egg dairy(牛奶酸奶奶酪) soy_nut(大豆、豆腐豆浆等豆制品、坚果) sweet(甜点、含糖饮料、糖果零食) other(其他)。
grams 估算实际吃下的量：谷物和杂豆折算成生重/干重（一碗米饭约折合生米75g，一个馒头约折合面粉60g）；豆制品折算成大豆重量；其余按可食部分重量。
kcal、protein、carbs、fat、fiber 是整餐估算（单位：千卡/克）。
flags 从 ["fried","high_salt","sugary","processed"] 里选（油炸/重盐/高糖/加工肉），没有就空数组。"""

RETRY = "再次强调：只输出 JSON 本身，保持简短，foods 最多列 12 项。"


def num(v) -> float:
    try:
        return float(v)
    except (TypeError, ValueError):
        s = "".join(c for c in str(v) if c in "0123456789.")
        return float(s) if s else 0.0


def analyze(img: Image.Image, stats: RunStats, temperature: float = 0.3) -> FoodAnalysis:
    return analyze_url(img, stats, temperature)


def analyze_url(img, stats: RunStats, temperature: float = 0.3) -> FoodAnalysis:
    """img 可以是 PIL 图片，也可以是已经编码好的 data URL（多次采样时只编码一次）。"""
    r = chat_json(PROMPT, [img], stats=stats, retry_hint=RETRY, temperature=temperature)
    return FoodAnalysis(
        meal_name=str(r.get("title", "")),
        ingredients=[Ingredient(name=str(f.get("name", "")), grams=num(f.get("grams"))) for f in r.get("foods", []) if f.get("name")],
        total=Macros(calories=num(r.get("kcal")), carbs=num(r.get("carbs")), protein=num(r.get("protein")), fat=num(r.get("fat"))),
    )
