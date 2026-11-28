"""饮食数据分析评测：问题由模板生成，标准答案由程序直接查数据库算出（不靠人工、不靠模型）。
python -m evals.analytics --variant agent|plain
打分：计数和日期必须完全一致；平均值误差在 5% 以内；标签（变多/变少、周末/工作日）必须一致；列表每一项都要对。"""
from __future__ import annotations

import argparse
import datetime as dt
import json
import time
from concurrent.futures import ThreadPoolExecutor

import numpy as np

from mealagent import config
from mealagent.agent import analyst
from mealagent.data import history
from mealagent.schema import RunStats

T = history.TODAY


def since(n):
    return (T - dt.timedelta(days=n)).isoformat()


def q(con, sql, *a):
    return con.execute(sql, a).fetchone()[0]


def questions() -> list[dict]:
    con = history.connect()
    out = []

    def add(qid, text, kind, value):
        out.append({"id": qid, "question": text, "kind": kind, "answer": value})

    for n in (7, 30, 60):
        add(f"fish{n}", f"过去{n}天里，我有几餐吃了鱼或海鲜？", "int",
            q(con, "select count(*) from meals where member='me' and fish_g>0 and date>=?", since(n)))
        add(f"takeout{n}", f"过去{n}天我点了几次外卖？", "int",
            q(con, "select count(*) from meals where member='me' and source='takeout' and date>=?", since(n)))
    for n in (7, 14, 30):
        add(f"veg{n}", f"最近{n}天，我平均每天吃多少克蔬菜？", "float",
            q(con, "select sum(veg_g)*1.0/? from meals where member='me' and date>=?", n, since(n)))
        add(f"momprot{n}", f"妈妈最近{n}天平均每天摄入多少克蛋白质？", "float",
            q(con, "select sum(protein_g)*1.0/? from meals where member='mom' and date>=?", n, since(n)))
    add("lasthotpot", "我上一次吃火锅是哪天？", "date",
        q(con, "select max(date) from meals where member='me' and cuisine='火锅'"))
    add("hotpot120", "这四个月（过去120天）我一共吃了几次火锅？", "int",
        q(con, "select count(*) from meals where member='me' and cuisine='火锅'"))
    for n in (30, 60):
        days = con.execute("select date, sum(dairy_g) from meals where member='mom' and date>=? group by date", (since(n),)).fetchall()
        add(f"momnomilk{n}", f"过去{n}天里，妈妈有几天一点奶类都没吃？", "int", sum(1 for _, d in days if d == 0) + (n - len(days)))
    for thr, n in ((2200, 60), (2500, 30)):
        add(f"high{thr}_{n}", f"过去{n}天，我有几天全天总热量超过{thr}千卡？", "int",
            q(con, "select count(*) from (select date, sum(kcal) k from meals where member='me' and date>=? group by date) where k>?", since(n), thr))
    add("fried_nov", "11 月份我吃了几次油炸的东西？", "int",
        q(con, "select count(*) from meals where member='me' and fried=1 and date like '2026-11-%'"))
    add("fried_oct_mom", "10 月份妈妈吃了几次油炸的东西？", "int",
        q(con, "select count(*) from meals where member='mom' and fried=1 and date like '2026-10-%'"))
    wk = con.execute("select weekday>=6, sum(kcal)*1.0/count(distinct date) from meals where member='me' group by weekday>=6").fetchall()
    d = dict(wk)
    add("wkend", "按天算，我周末和工作日哪个平均每天的热量更高？回答「周末」或「工作日」。", "label", "周末" if d[1] > d[0] else "工作日")
    a = q(con, "select count(*) from meals where member='me' and source='takeout' and date>=?", since(28))
    b = q(con, "select count(*) from meals where member='me' and source='takeout' and date>=? and date<?", since(56), since(28))
    add("takeouttrend", "比较最近4周和再往前的4周，我点外卖的次数是变多了还是变少了？回答「变多」或「变少」。", "label", "变多" if a > b else "变少")
    a = q(con, "select count(*) from meals where member='me' and fish_g>0 and date>=?", since(30))
    b = q(con, "select count(*) from meals where member='me' and fish_g>0 and date<?", (T - dt.timedelta(days=90)).isoformat())
    add("fishtrend", "我最近30天吃鱼的次数，和最早那30天（记录开始的第一个月）相比，是变多了还是变少了？回答「变多」或「变少」。", "label",
        "变多" if a > b else "变少")
    top = con.execute("select dish, count(*) c from meals where member='me' and source!='home' group by dish order by c desc limit 2").fetchall()
    if top[0][1] > top[1][1]:
        add("topout", "这几个月里，我在外面吃（外卖和堂食）次数最多的是哪道菜？", "text", top[0][0])
    top = con.execute("select dish, count(*) c from meals where member='mom' and slot='breakfast' group by dish order by c desc limit 2").fetchall()
    if top[0][1] > top[1][1]:
        add("momtopbf", "妈妈早餐吃得最多的是什么？", "text", top[0][0])
    add("momkcal_oct", "10 月份妈妈平均每天摄入多少千卡？", "float",
        q(con, "select sum(kcal)*1.0/31 from meals where member='mom' and date like '2026-10-%'"))
    add("me_restaurant_wkend30", "过去30天里，我周末去餐厅堂食了几次？", "int",
        q(con, "select count(*) from meals where member='me' and source='restaurant' and weekday>=6 and date>=?", since(30)))
    add("me_salt14", "最近两周我有几餐是重盐的？", "int",
        q(con, "select count(*) from meals where member='me' and high_salt=1 and date>=?", since(14)))
    add("mom_fish30", "过去30天妈妈吃了几餐鱼或海鲜？", "int",
        q(con, "select count(*) from meals where member='mom' and fish_g>0 and date>=?", since(30)))
    add("me_darkveg_days30", "过去30天里，我有几天吃到了深色蔬菜？", "int",
        q(con, "select count(distinct date) from meals where member='me' and dark_veg_g>0 and date>=?", since(30)))
    add("me_fruit_days30", "过去30天我有几天吃了水果？", "int",
        q(con, "select count(distinct date) from meals where member='me' and fruit_g>0 and date>=?", since(30)))
    con.close()
    return out


def correct(item: dict, value) -> bool:
    a, k = item["answer"], item["kind"]
    if value is None:
        return False
    if isinstance(value, list) and len(value) == 1:
        value = value[0]
    s = str(value).strip()
    if k == "int":
        try:
            return int(round(float(str(s).rstrip("次餐天")))) == int(a)
        except ValueError:
            return False
    if k == "float":
        try:
            v = float("".join(ch for ch in s if ch in "0123456789.-"))
            return abs(v - a) <= 0.05 * abs(a) + 0.5
        except ValueError:
            return False
    if k == "date":
        return a in s
    if k == "label":
        return a in s and not (a == "周末" and "工作日" in s and s.index("工作日") < s.index("周末"))
    return a in s or s in a


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--variant", default="agent", choices=["agent", "plain"])
    ap.add_argument("--workers", type=int, default=6)
    args = ap.parse_args()
    qs = questions()

    def one(item):
        st = RunStats()
        t = time.time()
        try:
            out = analyst.ask(item["question"], st) if args.variant == "agent" else analyst.ask_plain(item["question"], st)
            err = None
        except Exception as e:  # noqa: BLE001
            out, err = {"value": None, "sql": []}, f"{type(e).__name__}: {e}"
        return {**item, "pred": out.get("value"), "explanation": out.get("explanation"), "sql": out.get("sql"), "error": err,
                "correct": correct(item, out.get("value")), "seconds": time.time() - t, "llm_calls": st.llm_calls,
                "cost_usd": st.cost_usd(config.PRICE_INPUT_PER_M, config.PRICE_OUTPUT_PER_M), "input_tokens": st.input_tokens}

    with ThreadPoolExecutor(args.workers) as ex:
        rows = list(ex.map(one, qs))
    raw = config.RESULTS_DIR / "raw" / f"analytics_{args.variant}.jsonl"
    raw.parent.mkdir(parents=True, exist_ok=True)
    raw.write_text("\n".join(json.dumps(r, ensure_ascii=False, default=str) for r in rows) + "\n")
    by = {}
    for r in rows:
        by.setdefault(r["kind"], []).append(r["correct"])
    summary = {"variant": args.variant, "n": len(rows), "errors": sum(1 for r in rows if r["error"]),
               "accuracy": float(np.mean([r["correct"] for r in rows])), "by_kind": {k: float(np.mean(v)) for k, v in by.items()},
               "seconds_mean": float(np.mean([r["seconds"] for r in rows])), "llm_calls_mean": float(np.mean([r["llm_calls"] for r in rows])),
               "input_tokens_mean": float(np.mean([r["input_tokens"] for r in rows])), "cost_usd_mean": float(np.mean([r["cost_usd"] for r in rows]))}
    (config.RESULTS_DIR / f"analytics_{args.variant}.json").write_text(json.dumps(summary, ensure_ascii=False, indent=2))
    print(json.dumps(summary, ensure_ascii=False, indent=2))


if __name__ == "__main__":
    main()
