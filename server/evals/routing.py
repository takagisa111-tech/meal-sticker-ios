"""路由评测：混合了三类请求（48 个日常问答 + 30 个统计问题 + 12 个一周菜单），
先测路由准确率，再用三条路径各自的评测结果，算出整个系统在三种策略下的成功率和成本：
  always_simple  全部走单次调用
  always_agent   全部走 agent
  router         先路由再分发（路由错了按失败算，比较保守）
python -m evals.routing"""
from __future__ import annotations

import json
from concurrent.futures import ThreadPoolExecutor

import numpy as np

from mealagent import config
from mealagent.agent import router, weekly
from mealagent.schema import RunStats
from evals import analytics, planning
from evals import weekly as weekly_eval

R = config.RESULTS_DIR


def load(name):
    f = R / "raw" / f"{name}.jsonl"
    return {r["id"]: r for r in map(json.loads, f.read_text().splitlines())} if f.exists() else {}


def items():
    out = [{"id": s["id"], "q": s["request"], "label": "simple", "src": "plan"} for s in planning.scenarios(8)]
    out += [{"id": a["id"], "q": a["question"], "label": "analytics", "src": "analytics"} for a in analytics.questions()]
    for s in weekly_eval.scenarios():
        m = s["member"]
        out.append({"id": s["id"], "q": f"帮{m['name']}排下周7天的晚饭，冰箱里有{'、'.join(s['fridge'])}" + ("，要软烂一点" if m["kind"] == "elder" else ""),
                    "label": "weekly", "src": "weekly"})
    return out


def main():
    its = items()

    def one(it):
        st = RunStats()
        r = router.route(it["q"], st)
        return {**it, "route": r, "router_cost": st.cost_usd(config.PRICE_INPUT_PER_M, config.PRICE_OUTPUT_PER_M), "router_s": st.seconds}

    with ThreadPoolExecutor(8) as ex:
        rows = list(ex.map(one, its))
    acc = float(np.mean([r["route"] == r["label"] for r in rows]))
    paths = {"plan": {"simple": load("plan_plain_rag"), "agent": load("plan_agent_noguard")},
             "analytics": {"simple": load("analytics_plain"), "agent": load("analytics_agent")},
             "weekly": {"simple": load("weekly_single"), "agent": load("weekly_agent")}}
    ok_key = {"plan": lambda r: r["checks"]["success"], "analytics": lambda r: r["correct"], "weekly": lambda r: r["valid"]}

    def outcome(it, which):
        r = paths[it["src"]][which].get(it["id"])
        if r is None:
            return None
        return ok_key[it["src"]](r), r.get("cost_usd", 0), r.get("seconds", 0)

    res = {}
    for strat in ("always_simple", "always_agent", "router"):
        succ, cost, sec = [], [], []
        for it in rows:
            if strat == "router":
                if it["route"] != it["label"]:
                    o = (False, 0.0, 0.0)
                else:
                    o = outcome(it, "simple" if it["route"] == "simple" else "agent")
                if o:
                    o = (o[0], o[1] + it["router_cost"], o[2] + it["router_s"])
            else:
                o = outcome(it, "simple" if strat == "always_simple" else "agent")
            if o is None:
                continue
            succ.append(o[0]); cost.append(o[1]); sec.append(o[2])
        res[strat] = {"n": len(succ), "success": float(np.mean(succ)) if succ else None,
                      "cost_usd_mean": float(np.mean(cost)) if cost else None, "seconds_mean": float(np.mean(sec)) if sec else None}
    conf = {}
    for r in rows:
        conf.setdefault(r["label"], {}).setdefault(r["route"], 0)
        conf[r["label"]][r["route"]] += 1
    summary = {"routing_accuracy": acc, "confusion": conf, "strategies": res}
    (R / "raw").mkdir(parents=True, exist_ok=True)
    (R / "raw" / "routing.jsonl").write_text("\n".join(json.dumps(r, ensure_ascii=False) for r in rows) + "\n")
    (R / "routing.json").write_text(json.dumps(summary, ensure_ascii=False, indent=2))
    print(json.dumps(summary, ensure_ascii=False, indent=2))


if __name__ == "__main__":
    main()
