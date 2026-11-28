"""把 results/ 下的结果做成对比表，并用配对 bootstrap 给出相对基线的 95% 置信区间：
python -m evals.report jfb 200
"""
from __future__ import annotations

import json
import sys

import numpy as np

from mealagent.config import RESULTS_DIR

ORDER = ["baseline", "prompt_v2", "rag", "rag_rerank", "prompt_v3", "rag_v3", "rag_ens_v3", "zh_v2", "zh_rag", "baseline_sc3", "zh_mm3_text", "zh_mm3", "zh_mm5", "agent_q0", "agent_always1", "agent_q1", "agent_q2", "agent_always1_r2", "agent_q2_r2"]
LABEL = {
    "baseline": "基线（App 现有方法）",
    "prompt_v2": "提示词 v2（检查清单 + 结构化输出）",
    "rag": "提示词 v2 + RAG Top-1",
    "rag_rerank": "提示词 v2 + RAG + LLM 重排序",
    "prompt_v3": "提示词 v3（校准）",
    "rag_v3": "提示词 v3 + RAG + 严格重排序",
    "rag_ens_v3": "提示词 v3 + RAG + 一致性校验与集成",
    "zh_v2": "中文提示词 v2（检查清单 + 结构化输出）",
    "zh_rag": "中文提示词 v2 + RAG + 一致性校验",
    "baseline_sc3": "App 原提示词 × 3 次采样取平均",
    "zh_mm3_text": "中文 v2 + 多模态 RAG：3 条相似参考（仅文字）",
    "zh_mm3": "中文 v2 + 多模态 RAG：3 张相似参考（图 + 文）",
    "zh_mm5": "中文 v2 + 多模态 RAG：5 张相似参考（图 + 文）",
    "agent_q0": "记录 agent：不提问（对照）",
    "agent_always1": "记录 agent：每餐都问 1 个问题（对照）",
    "agent_q1": "记录 agent：拿不准才问，最多 1 个",
    "agent_q2": "记录 agent：拿不准才问，最多 2 个",
    "agent_always1_r2": "记录 agent：每餐都问 1 个 + 修正 v2（对照）",
    "agent_q2_r2": "记录 agent：拿不准才问，最多 2 个 + 修正 v2",
}
ENSEMBLES = [("baseline", "zh_v2"), ("baseline", "zh_rag"), ("baseline", "rag_v3"), ("baseline_sc3", "zh_rag")]
KEYS = ["calories", "carbs", "protein", "fat"]


def wmape(gt, pr):
    return sum(abs(gt[k] - pr[k]) for k in KEYS) / max(sum(abs(gt[k]) for k in KEYS), 1e-9) * 100


def load(p, dataset, n):
    f = RESULTS_DIR / "raw" / f"{p}_{dataset}_{n}.jsonl"
    if not f.exists():
        return None
    return {r["id"]: r for r in map(json.loads, f.read_text().splitlines()) if r.get("pred")}


def ci(diff, iters=2000, seed=0):
    rng = np.random.default_rng(seed)
    d = np.asarray(diff)
    boots = d[rng.integers(0, len(d), (iters, len(d)))].mean(1)
    return d.mean(), np.percentile(boots, 2.5), np.percentile(boots, 97.5)


def main():
    dataset, n = sys.argv[1], sys.argv[2]
    base = load("baseline", dataset, n)
    head = ("| 方案 | 综合分 ↑ | 营养 wMAPE ↓ | wMAPE 相对基线（95% CI） | 热量平均偏差 | 食材 F1 ↑ | F1 相对基线（95% CI） | 耗时 | 单次成本 |\n"
            "|---|---|---|---|---|---|---|---|---|")
    lines = [f"# 评测结果：{dataset.upper()}（随机 {n} 张，seed=42）", "", head]
    for p in ORDER:
        rows = load(p, dataset, n)
        if not rows:
            continue
        rs = list(rows.values())
        mean = lambda k: float(np.mean([r[k] for r in rs]))
        bias = float(np.mean([r["pred"]["total"]["calories"] - r["gt"]["macros"]["calories"] for r in rs]))
        if base and p != "baseline":
            ids = [i for i in rows if i in base]
            w = ci([rows[i]["wmape"] - base[i]["wmape"] for i in ids])
            f = ci([rows[i]["ing_f1"] - base[i]["ing_f1"] for i in ids])
            wtxt = f"{w[0]:+.1f}（{w[1]:+.1f} ~ {w[2]:+.1f}）"
            ftxt = f"{f[0]:+.3f}（{f[1]:+.3f} ~ {f[2]:+.3f}）"
        else:
            wtxt = ftxt = "—"
        qtxt = f"（平均问 {np.mean([r.get('questions', 0) for r in rs]):.2f} 个）" if p.startswith("agent") else ""
        lines.append(f"| {LABEL.get(p, p)}{qtxt} | {mean('overall'):.1f} | {mean('wmape'):.1f}% | {wtxt} | {bias:+.0f} kcal | "
                     f"{mean('ing_f1'):.3f} | {ftxt} | {mean('wall_seconds'):.1f}s | ${mean('cost_usd'):.4f} |")
    if base:
        lines += ["", "## 集成：两个方案的营养估计取平均（两路请求并行，耗时取较慢的一路）", "",
                  "| 组合 | 营养 wMAPE ↓ | 相对基线（95% CI） | 热量平均偏差 | 单次成本 |", "|---|---|---|---|---|"]
        for a, b in ENSEMBLES:
            A, B = load(a, dataset, n), load(b, dataset, n)
            if not A or not B:
                continue
            ids = [i for i in A if i in B and i in base]
            pr = {i: {k: (A[i]["pred"]["total"][k] + B[i]["pred"]["total"][k]) / 2 for k in KEYS} for i in ids}
            w = {i: wmape(base[i]["gt"]["macros"], pr[i]) for i in ids}
            d = ci([w[i] - base[i]["wmape"] for i in ids])
            bias = float(np.mean([pr[i]["calories"] - base[i]["gt"]["macros"]["calories"] for i in ids]))
            cost = float(np.mean([A[i]["cost_usd"] + B[i]["cost_usd"] for i in ids]))
            lines.append(f"| {LABEL[a]} + {LABEL[b]} | {np.mean(list(w.values())):.1f}% | {d[0]:+.1f}（{d[1]:+.1f} ~ {d[2]:+.1f}） | {bias:+.0f} kcal | ${cost:.4f} |")
    lines += ["", "置信区间不跨过 0，说明这个差异在统计上是可靠的（不是随机波动）。"]
    out = RESULTS_DIR / f"report_{dataset}_{n}.md"
    out.write_text("\n".join(lines) + "\n")
    print("\n".join(lines))


if __name__ == "__main__":
    main()
