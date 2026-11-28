"""演示用的家庭数据（内存里，重启即重置）：我、妈妈（82 岁）、猫团子，各自一周饮食记录 + 冰箱 + 附近餐厅。
识别 agent 记下的餐会写进对应成员的记录，规划 agent 马上就能用上——两个 agent 在这里打通。"""
from __future__ import annotations

import copy
import datetime as dt
import threading

from evals.planning import FRIDGE, RESTAURANTS, make_log

_LOCK = threading.Lock()
MEMBERS = {
    "me": {"name": "我", "kind": "adult", "age": 28, "allergies": ["花生"], "dislikes": ["香菜"], "goal": "保持健康体重"},
    "mom": {"name": "妈妈", "kind": "elder", "age": 82, "allergies": [], "dislikes": [], "goal": "预防营养不良，饭菜要软"},
    "cat": {"name": "团子", "kind": "cat", "age": 3, "allergies": [], "dislikes": [], "goal": "健康"},
}
STATE = {
    "logs": {"me": make_log(["veg", "fish"], True), "mom": make_log(["dairy"], True), "cat": make_log([], False)},
    "fridge": FRIDGE[:9],
}
GROUP_MAP = {"grain": "grain", "whole_grain": "whole_grain", "tuber": "grain", "veg": "veg", "dark_veg": "dark_veg", "fruit": "fruit",
             "meat": "meat", "seafood": "seafood", "egg": "egg", "dairy": "dairy", "soy_nut": "soy_nut"}


def scenario(member_id: str, request: str) -> dict:
    with _LOCK:
        return {"member": MEMBERS[member_id], "log": copy.deepcopy(STATE["logs"][member_id]), "fridge": list(STATE["fridge"]),
                "restaurants": RESTAURANTS, "request": request}


def log_meal(member_id: str, foods: list[dict]) -> int:
    """把识别结果记进今天：foods 里每项有 name、group、served_g/grams。"""
    with _LOCK:
        logs = STATE["logs"][member_id]
        today = {"day": len(logs) + 1, "date": dt.date.today().isoformat(), "foods": [], "flags": []}
        for f in foods:
            g = GROUP_MAP.get(str(f.get("group", "")))
            if g:
                today["foods"].append({"name": f.get("name", ""), "group": g, "grams": float(f.get("served_g") or f.get("grams") or 0)})
        logs.append(today)
        del logs[:-7]
        return len(today["foods"])
