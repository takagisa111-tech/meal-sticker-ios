"""RAG 重排序提示词 v1（第一轮评测用，保留以便复现）。"""

SYSTEM = "You match foods to entries of the USDA FNDDS nutrition database. Answer with a single JSON object."


def build(items, candidates) -> str:
    lines = ["For each food item below, choose the database entry that best matches the food AS SERVED "
             "(same food, same preparation, similar calorie density). If no candidate is a reasonable match, use null.", ""]
    for i, (it, cands) in enumerate(zip(items, candidates)):
        lines.append(f'Item {i}: "{it["name"]}" ({it.get("usda_query", "")}), about {it.get("kcal", "?")} kcal for {it.get("grams", "?")} g')
        for c in cands:
            p = c["per100g"]
            lines.append(f'  - id {c["id"]}: {c["desc"]} | {p["kcal"]:.0f} kcal/100g')
        lines.append("")
    lines.append('Return JSON: {"choices": [{"item": 0, "id": 123456}, {"item": 1, "id": null}]}')
    return "\n".join(lines)
