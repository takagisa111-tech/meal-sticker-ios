"""确定性的安全规则（护栏）：过敏原、宠物有毒食物、老人难咀嚼。不依赖大模型，规则写死、可审计。"""
from __future__ import annotations

ALLERGENS = {
    "花生": ["花生"],
    "虾": ["虾"],
    "蟹": ["蟹"],
    "鱼": ["鱼"],
    "牛奶": ["牛奶", "奶油", "黄油", "芝士", "奶酪", "酸奶", "乳"],
    "鸡蛋": ["鸡蛋", "蛋清", "蛋黄", "蛋液", "荷包蛋", "炒蛋", "蛋"],
    "坚果": ["核桃", "杏仁", "腰果", "榛子", "开心果", "夏威夷果"],
    "大豆": ["黄豆", "豆腐", "豆浆", "腐竹", "豆皮"],
    "小麦": ["面粉", "面条", "馒头", "面包", "饺子皮"],
    "芝麻": ["芝麻"],
}

PET_TOXIC = {
    "洋葱/葱/蒜/韭菜（损伤红细胞）": ["洋葱", "大葱", "小葱", "葱", "大蒜", "蒜", "韭菜"],
    "葡萄/葡萄干（可能导致肾衰竭）": ["葡萄"],
    "巧克力/可可/咖啡（含可可碱、咖啡因）": ["巧克力", "可可", "咖啡"],
    "酒精/生面团": ["酒", "酵母"],
    "木糖醇": ["木糖醇"],
    "夏威夷果": ["夏威夷果"],
    "牛油果": ["牛油果"],
}

# 常见菜名隐含的食材（菜名里看不出来，但一定含有）
DISH_HINTS = {
    "宫保": ["花生", "葱", "蒜"], "腰果": ["腰果"], "虾饺": ["虾"], "鱼香": ["葱", "蒜"], "蒜蓉": ["蒜"], "麻婆豆腐": ["豆腐", "蒜"],
    "葱油": ["葱"], "葱爆": ["葱"], "韭菜": ["韭菜"], "提拉米苏": ["咖啡", "奶油", "鸡蛋"], "奶茶": ["牛奶"], "拿铁": ["牛奶", "咖啡"],
    "炸鸡": ["炸"], "锅包肉": ["炸"], "番茄炒蛋": ["鸡蛋"], "西红柿炒鸡蛋": ["鸡蛋"], "蛋炒饭": ["鸡蛋"], "芝士": ["芝士"],
}

HARD_FOR_ELDER = ["油炸", "炸", "脆", "干煸", "坚果", "花生", "牛肉干", "锅巴", "排骨"]


def find(words: dict[str, list[str]], text: str, only: list[str] | None = None) -> list[str]:
    return [k for k, kws in words.items() if (only is None or k in only) and any(w in text for w in kws)]


NEG = ["不放", "去掉", "去除", "不加", "不要", "无", "免", "换掉", "改用"]


def expand(foods: list[str]) -> list[str]:
    """补上菜名隐含的食材；但用户/agent 明确写了「不放花生」「去掉葱」的，就不再补。"""
    text = "、".join(foods)
    removed = {w for ws in DISH_HINTS.values() for w in ws if any(n + w in text for n in NEG)}
    return foods + [w for k, ws in DISH_HINTS.items() if k in text for w in ws if w not in removed]


def check(kind: str, allergies: list[str], foods: list[str]) -> list[str]:
    """返回违规说明列表；空列表表示安全。"""
    text = "、".join(expand(foods))
    for n in NEG:  # 「不放花生」里的「花生」不算含有
        for w in [x for ws in ALLERGENS.values() for x in ws] + [x for ws in PET_TOXIC.values() for x in ws]:
            text = text.replace(n + w, n)
    issues = []
    for a in find(ALLERGENS, text, allergies):
        issues.append(f"含过敏原「{a}」")
    if kind in ("dog", "cat"):
        for t in find(PET_TOXIC, text):
            issues.append(f"宠物不能吃：{t}")
    return issues
