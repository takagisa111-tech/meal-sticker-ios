"""跑评测：python -m evals.run_eval --pipeline baseline --dataset jfb --n 100

结果写到 results/：
  raw/<pipeline>_<dataset>_<n>.jsonl   每张图的预测和指标（不提交）
  <pipeline>_<dataset>_<n>.json        汇总（提交，用于对比和写报告）
"""
from __future__ import annotations
import argparse
import json
import random
import time
import traceback
from concurrent.futures import ThreadPoolExecutor, as_completed

import numpy as np
from PIL import Image
from tqdm import tqdm

from mealagent import config
from mealagent.pipelines import PIPELINES
from mealagent.schema import RunStats
from evals import metrics, translate
from evals.datasets import DATASETS


def run_one(pipeline, item):
    stats = RunStats()
    t = time.time()
    try:
        with Image.open(item["image"]) as im:
            im.load()
            pred = pipeline(im, stats, item=item) if getattr(pipeline, "needs_item", False) else pipeline(im, stats)
        err = None
    except Exception as e:
        pred, err = None, f"{type(e).__name__}: {e}"
        traceback.print_exc()
    wall = time.time() - t
    return item, pred, stats, wall, err


def score_rows(rows):
    """统一打分：先把中文名翻成英文（公平对比），再算各项指标。"""
    names = []
    for r in rows:
        if r.get("pred"):
            names.append(r["pred"]["meal_name"])
            names += [i["name"] for i in r["pred"]["ingredients"]]
    en = translate.to_english(names)
    for r in rows:
        p = r.get("pred")
        if not p:
            continue
        pred_ings = [en.get(i["name"], i["name"]) for i in p["ingredients"]]
        ing = metrics.ingredient_scores(r["gt"]["ingredients"], pred_ings)
        r.update({
            "name_sim": metrics.name_similarity(r["gt"]["meal_name"], en.get(p["meal_name"], p["meal_name"])),
            "ing_precision": ing["precision"], "ing_recall": ing["recall"], "ing_f1": ing["f1"],
            "wmape": metrics.macro_wmape(r["gt"]["macros"], p["total"]),
            "cal_ape": abs(p["total"]["calories"] - r["gt"]["macros"]["calories"]) / max(r["gt"]["macros"]["calories"], 1) * 100,
        })
        r["overall"] = metrics.overall_score(r["name_sim"], r["ing_f1"], r["wmape"], r["cost_usd"], r["wall_seconds"])


def summarize(rows, pipeline, dataset):
    ok = [r for r in rows if r["error"] is None]
    def m(k, rs=ok):
        return float(np.mean([r[k] for r in rs])) if rs else None
    def med(k, rs=ok):
        return float(np.median([r[k] for r in rs])) if rs else None
    gt_cal = sum(r["gt"]["macros"]["calories"] for r in ok)
    summary = {
        "pipeline": pipeline, "dataset": dataset, "n": len(rows), "ok": len(ok),
        "model": config.DEEPSEEK_MODEL, "embed_model": metrics.EMBED_MODEL,
        "overall_score": m("overall"),
        "meal_name_similarity": m("name_sim"),
        "ingredient_precision": m("ing_precision"), "ingredient_recall": m("ing_recall"), "ingredient_f1": m("ing_f1"),
        "macro_wmape_mean": m("wmape"), "macro_wmape_median": med("wmape"),
        "calorie_wmape_pooled": (sum(abs(r["pred"]["total"]["calories"] - r["gt"]["macros"]["calories"]) for r in ok) / gt_cal * 100) if gt_cal else None,
        "latency_mean_s": m("wall_seconds"), "latency_p50_s": med("wall_seconds"),
        "latency_p90_s": float(np.percentile([r["wall_seconds"] for r in ok], 90)) if ok else None,
        "llm_calls_mean": m("llm_calls"), "questions_mean": m("questions"), "cost_usd_mean": m("cost_usd"),
        "input_tokens_mean": m("input_tokens"), "output_tokens_mean": m("output_tokens"),
    }
    out = config.RESULTS_DIR / f"{pipeline}_{dataset}_{len(rows)}.json"
    out.write_text(json.dumps(summary, ensure_ascii=False, indent=2))
    print(json.dumps(summary, ensure_ascii=False, indent=2))
    return summary


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--pipeline", default="baseline", choices=list(PIPELINES))
    ap.add_argument("--tag", default="")
    ap.add_argument("--dataset", default="jfb", choices=list(DATASETS))
    ap.add_argument("--n", type=int, default=100)
    ap.add_argument("--seed", type=int, default=42)
    ap.add_argument("--workers", type=int, default=4)
    args = ap.parse_args()

    items = DATASETS[args.dataset]()
    random.Random(args.seed).shuffle(items)
    items = items[:args.n]
    pipeline = PIPELINES[args.pipeline]
    if args.pipeline.startswith("rag"):
        from mealagent.rag.fndds import index
        index()  # 先建好知识库索引，避免多线程同时构建
    if args.pipeline.startswith(("zh_mm", "agent")):
        from mealagent.rag import visual
        visual.index()
        assert args.n <= 200, "多模态 RAG 只能在前 200 张测试集上评测（其余是参考库）"

    tag = f"{args.pipeline}_{args.dataset}_{args.n}"
    raw_dir = config.RESULTS_DIR / "raw"
    raw_dir.mkdir(parents=True, exist_ok=True)
    rows = []
    with ThreadPoolExecutor(args.workers) as ex:
        futs = [ex.submit(run_one, pipeline, it) for it in items]
        for fu in tqdm(as_completed(futs), total=len(futs), desc=tag):
            item, pred, stats, wall, err = fu.result()
            row = {"id": item["id"], "error": err, "wall_seconds": wall, "llm_seconds": stats.seconds,
                   "llm_calls": stats.llm_calls, "questions": stats.questions, "input_tokens": stats.input_tokens, "output_tokens": stats.output_tokens,
                   "cost_usd": stats.cost_usd(config.PRICE_INPUT_PER_M, config.PRICE_OUTPUT_PER_M),
                   "gt": {"meal_name": item["meal_name"], "ingredients": item["ingredients"], "macros": item["macros"]}}
            if pred is not None:
                row["pred"] = pred.model_dump()

            rows.append(row)
    score_rows(rows)
    with open(raw_dir / f"{tag}.jsonl", "w") as f:
        for row in rows:
            f.write(json.dumps(row, ensure_ascii=False) + "\n")
    summarize(rows, args.pipeline, args.dataset)


if __name__ == "__main__":
    main()
