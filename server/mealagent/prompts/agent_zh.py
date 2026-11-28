"""记录 agent 用到的提示词。"""
from . import recognize_zh, recognize_zh_mm

SYSTEM = recognize_zh.SYSTEM

UNCERTAINTY = """

另外，对每样食物额外给出：
- "confidence"：0–1，你对「这是什么」和「大概多少」整体有多确定。
并在最外层给出 "doubts"：你最拿不准、而且会明显影响热量的地方（最多 3 条，没有就空数组），每条：
{"food": "对应 foods 里的 name", "type": "identity（是什么）/ portion（多少）/ hidden（看不见的部分，比如油、糖、酱）",
 "question": "一个用户一眼就能回答的简短问题", "options": ["2–4 个选项"]}"""


def perceive(refs: list[str] | None) -> str:
    base = recognize_zh_mm.build(refs, True) if refs else recognize_zh.USER
    return base + UNCERTAINTY


REFINE = """你之前识别了一餐，结果如下（JSON）：
{prev}

你向用户提了问题，用户的回答：
{qa}

请根据用户的回答修正识别结果：用户说的优先于你的猜测；只改受影响的食物和对应的营养，其余保持不变；
如果回答揭示了你漏掉的食物，就加上；整餐合计要和各项之和一致。
只输出修正后的完整 JSON，格式和之前完全相同（包括 confidence 和 doubts，已经问过的不要再放进 doubts）。"""

REFINE_V2 = """你之前识别了一餐，结果如下（JSON）：
{prev}

你向用户提了问题，用户的回答：
{qa}

请根据回答修正识别结果，按下面的规则：
1. 用户说的优先于你的猜测。用户给出了具体份量（几杯、几片、几勺、一碗、喝完了/剩一半），
   就按这个份量重新计算这样食物的克数和营养，不要沿用原来的估计。
   常用换算：1 杯液体约 240ml，1 汤匙约 15ml（油约 14g、糖约 12g），1 茶匙约 5ml，1 片面包约 30g，1 碗汤约 300ml。
2. 用户说「没有」的食物删掉；回答里出现、但你漏掉的食物加上，并估算它的营养。
3. 用户说「不确定」时保持原估计。
4. 先在心里写出受影响食物「份量 × 单位营养」的计算，再填数字；整餐合计 = 各项之和。
只输出修正后的完整 JSON，格式和之前完全相同（包括 confidence 和 doubts，已经问过的不要再放进 doubts）。"""

SIM_USER_SYSTEM = "你在扮演一位正在用饮食记录 App 的普通用户。你只说真话，回答简短自然。"

SIM_USER = """这顿饭的真实情况（只有你知道）：
菜名：{meal}
食材和份量：{ings}

App 问你：「{question}」{options}

请用一句简短的中文回答，就像普通人回答一样：份量用日常说法（碗、片、勺、杯、个、大概多少克），
可以说「大概」；问题问到的东西真实情况里没有，就说没有；不知道就说不确定。
绝对不要提热量、卡路里或任何营养数字。"""
