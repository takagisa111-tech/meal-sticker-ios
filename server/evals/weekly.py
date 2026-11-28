"""一周菜单评测：12 个场景（我 / 对虾过敏的朋友 / 82 岁妈妈 × 不同冰箱），程序检查全部约束。
python -m evals.weekly --variant single|single_verify|agent"""
from __future__ import annotations

import argparse
import json
import random
import time
from concurrent.futures import ThreadPoolExecutor

import numpy as np

from mealagent import config
from mealagent.agent import weekly
from mealagent.schema import RunStats
from evals.planning import FRIDGE

PEOPLE = [
    ({"name": "我", "kind": "adult", "age": 28, "allergies": ["花生"]}, (300, 900)),
    ({"name": "小林", "kind": "adult", "age": 31, "allergies": ["虾"]}, (300, 900)),
    ({"name": "妈妈", "kind": "elder", "age": 82, "allergies": []}, (200, 800)),
]


def scenarios(n_fridge: int = 4, seed: int = 11) -> list[dict]:
    rng = random.Random(seed)
    out = []
    for j in range(n_fridge):
        fridge = rng.sample(FRIDGE, 4)
        for i, (m, kr) in enumerate(PEOPLE):
            out.append({"id": f"W{i}{j}", "member": m, "kcal_range": kr, "fridge": fridge})
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--variant", default="agent", choices=["single", "single_verify", "agent"])
    ap.add_argument("--workers", type=int, default=6)
    args = ap.parse_args()
    weekly.recipe_db()

    def one(sc):
        st = RunStats()
        t = time.time()
        try:
            if args.variant == "agent":
                out = weekly.run_agent(sc, st)
            else:
                out = weekly.run_single(sc, st, verify=args.variant == "single_verify")
            err = None
        except Exception as e:  # noqa: BLE001
            out, err = {"plan": [], "rounds": 0, "tool_calls": []}, f"{type(e).__name__}: {e}"
        v = weekly.validate(out["plan"], sc)
        return {"id": sc["id"], "kind": sc["member"]["kind"], "error": err, "plan": out["plan"], "violations": v, "valid": not v,
                "rounds": out["rounds"], "tool_calls": out["tool_calls"], "seconds": time.time() - t, "llm_calls": st.llm_calls,
                "cost_usd": st.cost_usd(config.PRICE_INPUT_PER_M, config.PRICE_OUTPUT_PER_M)}

    with ThreadPoolExecutor(args.workers) as ex:
        rows = list(ex.map(one, scenarios()))
    raw = config.RESULTS_DIR / "raw" / f"weekly_{args.variant}.jsonl"
    raw.parent.mkdir(parents=True, exist_ok=True)
    raw.write_text("\n".join(json.dumps(r, ensure_ascii=False) for r in rows) + "\n")
    summary = {"variant": args.variant, "n": len(rows), "errors": sum(1 for r in rows if r["error"]),
               "valid_rate": float(np.mean([r["valid"] for r in rows])), "violations_mean": float(np.mean([len(r["violations"]) for r in rows])),
               "seconds_mean": float(np.mean([r["seconds"] for r in rows])), "llm_calls_mean": float(np.mean([r["llm_calls"] for r in rows])),
               "cost_usd_mean": float(np.mean([r["cost_usd"] for r in rows]))}
    (config.RESULTS_DIR / f"weekly_{args.variant}.json").write_text(json.dumps(summary, ensure_ascii=False, indent=2))
    print(json.dumps(summary, ensure_ascii=False, indent=2))


if __name__ == "__main__":
    main()
