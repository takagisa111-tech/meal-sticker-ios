"""不重新调用识图模型，只用最新的标注解析 / 指标重新打分：
python -m evals.rescore results/raw/baseline_jfb_100.jsonl
"""
from __future__ import annotations

import json
import sys
from pathlib import Path

from evals.datasets import DATASETS
from evals.run_eval import score_rows, summarize


def main():
    path = Path(sys.argv[1])
    parts = path.stem.rsplit("_", 2)
    pipeline, dataset = parts[0], parts[1]
    gt = {it["id"]: it for it in DATASETS[dataset]()}
    rows = [json.loads(l) for l in path.read_text().splitlines() if l.strip()]
    for r in rows:
        it = gt[r["id"]]
        r["gt"] = {"meal_name": it["meal_name"], "ingredients": it["ingredients"], "macros": it["macros"]}
    score_rows(rows)
    path.write_text("\n".join(json.dumps(r, ensure_ascii=False) for r in rows) + "\n")
    summarize(rows, pipeline, dataset)


if __name__ == "__main__":
    main()
