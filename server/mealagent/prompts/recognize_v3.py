"""识图提示词 v3：在 v2 基础上做「校准」。

v2 的问题（评测发现）：为了不漏东西，模型开始脑补看不见的食物，份量也偏大，热量从少估 43 kcal 变成多估 70 kcal。
v3 的改动：
1. 只记录照片里看得见的东西，不推测画面外的配菜、饮料
2. 份量拿不准时取「常见一人份的中间值」，不往大里估
3. 多个相同的东西用 count 字段，不重复列
4. 保留 v2 的检查清单（酱汁、油、饮料）和份量参照物
"""
from .recognize_v2 import SYSTEM  # noqa: F401

USER = """Analyze this meal photo for a food log.

Work through these steps silently (do NOT write them out):
1. Identify every distinct food and drink that is clearly VISIBLE in the photo. Check specifically for sauces, dressings, dips, cheese, spreads, toppings, sides and drinks — but never add anything you cannot see (no assumed sides, drinks or hidden ingredients).
2. Log items the way a person would log them: keep a prepared dish (soup, chili, curry, fried rice, casserole) as one item; split a plate into its separately visible components (e.g. steak, mashed potatoes, green beans, gravy).
3. If several identical items are visible (3 tacos, 2 slices of pizza), list the item once and set "count".
4. Estimate the served, cooked, edible weight in grams PER PIECE. Use visual references: dinner plate ≈ 26 cm, side plate ≈ 18 cm, bowl ≈ 350 ml, mug ≈ 300 ml, glass ≈ 250 ml, fork ≈ 19 cm, slice of bread ≈ 30 g, large egg ≈ 50 g. When unsure, choose the MEDIAN typical single serving, not a generous one. Only count cooking oil or butter separately when it is clearly visible (pooled oil, a pat of butter, glossy coating).
5. Estimate calories, carbohydrates, protein and fat PER PIECE.

Return JSON exactly in this shape:
{"meal_name": "short descriptive English name of the meal",
 "items": [
   {"name": "fish taco", "name_zh": "鱼肉塔可", "count": 3, "grams": 110,
    "usda_query": "Taco, flour tortilla, fish",
    "kcal": 230, "carbs": 20, "protein": 12, "fat": 11, "confidence": 0.8}
 ]}

Field rules:
- name: common English food name, specific but short (e.g. "white rice", "caesar dressing", "iced latte").
- name_zh: the same food in Simplified Chinese.
- usda_query: a search phrase written like a USDA FNDDS food description: food first, then preparation, comma separated (e.g. "Chicken breast, grilled", "Pasta, cooked", "Egg, whole, boiled or poached").
- count: integer ≥ 1. grams and nutrition are PER PIECE.
- confidence: 0–1, how sure you are of the identification.
- No more than 15 items; merge negligible garnishes."""
