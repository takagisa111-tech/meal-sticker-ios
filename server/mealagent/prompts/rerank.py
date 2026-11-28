"""RAG 重排序提示词 v2：让模型从检索出的候选里挑出和「这份食物」最匹配的数据库条目。
v1 的问题：会选成「意面酱」代替「意面」、「鸡肉塔可」代替「鱼肉塔可」、「生鸡蛋」代替「水煮蛋」。
v2：明确要求主要食材、烹饪状态都要一致，不一致就返回 null（之后回退到模型自己的估计）。"""

SYSTEM = "You match foods to entries of the USDA FNDDS nutrition database. Answer with a single JSON object."


def build(items, candidates) -> str:
    lines = ["For each food item below, choose the database entry that describes the SAME food as served.",
             "Rules: the main food must be identical (fish ≠ chicken, pasta ≠ pasta sauce, bacon ≠ turkey bacon unless stated); "
             "the state must match (cooked vs raw, fried vs baked when it changes calories a lot); "
             "a more generic entry of the same food is fine (\"Bagel\" for \"plain bagel\"). "
             "If no candidate satisfies these rules, answer null.", ""]
    for i, (it, cands) in enumerate(zip(items, candidates)):
        lines.append(f'Item {i}: "{it["name"]}" (query: {it.get("usda_query", "")}), model estimate {it.get("kcal", 0):.0f} kcal for {it.get("grams", 0):.0f} g')
        for c in cands:
            p = c["per100g"]
            lines.append(f'  - id {c["id"]}: {c["desc"]} | {p["kcal"]:.0f} kcal/100g')
        lines.append("")
    lines.append('Return JSON: {"choices": [{"item": 0, "id": 123456}, {"item": 1, "id": null}]}')
    return "\n".join(lines)
