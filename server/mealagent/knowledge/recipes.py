"""菜谱知识库：HowToCook（程序员做饭指南，公有领域 Unlicense，约 375 道家常菜，每道有每份用料克数和预估热量）。
构建：python -m mealagent.knowledge.recipes"""
from __future__ import annotations

import io
import json
import re
import urllib.request
import zipfile

from ..config import DATA_DIR

URL = "https://codeload.github.com/Anduin2017/HowToCook/zip/refs/heads/master"
OUT = DATA_DIR / "recipes.jsonl"
CATS = {"aquatic": "水产", "breakfast": "早餐", "condiment": "调料", "dessert": "甜品", "drink": "饮品",
        "meat_dish": "荤菜", "semi-finished": "半成品", "soup": "汤", "staple": "主食", "vegetable_dish": "素菜"}


def parse(name: str, md: str) -> dict | None:
    m = re.search(r"#\s*(.+?)的做法", md)
    title = (m.group(1) if m else name).strip()
    kcal = re.search(r"预估卡路里[：:]\s*([\d.]+)", md)
    diff = re.search(r"预估烹饪难度[：:]\s*(★+)", md)
    sec = re.search(r"##\s*必备原料和工具(.*?)(\n##|\Z)", md, re.S)
    ings = []
    if sec:
        for line in sec.group(1).splitlines():
            line = line.strip()
            if line[:1] in "*-":
                t = re.sub(r"[（(].*?[)）]", "", line[1:]).strip()
                if t:
                    ings.append(t)
    if not ings:
        return None
    desc = md.split("\n\n")
    intro = next((p.strip() for p in desc[1:4] if p.strip() and not p.strip().startswith(("预估", "#", "!["))), "")
    return {"title": title, "ingredients": ings[:25], "kcal": float(kcal.group(1)) if kcal else None,
            "difficulty": len(diff.group(1)) if diff else None, "intro": intro[:160],
            "amounts": _bullets(md, r"计算")[:25], "steps": _bullets(md, r"操作")[:30]}


def _clean_md(t: str) -> str:
    t = re.sub(r"!\[.*?\]\(.*?\)", "", t)              # 图片
    t = re.sub(r"\[(.*?)\]\(.*?\)", r"\1", t)           # 链接只留文字
    t = re.sub(r"[*_`]{1,3}", "", t)
    return re.sub(r"\s+", " ", t).strip()


def _bullets(md: str, head: str) -> list[str]:
    """取「## 计算」「## 操作」这类小节里的列表项（用量、步骤），给 App 的烹饪模式用。"""
    sec = re.search(r"##\s*" + head + r"[^\n]*\n(.*?)(\n##\s|\Z)", md, re.S)
    if not sec:
        return []
    out = []
    for line in sec.group(1).splitlines():
        s = line.strip()
        m = re.match(r"^(?:[*\-+]|\d+[.、)])\s+(.*)", s)
        if m and line[:1] not in " \t":
            t = _clean_md(m.group(1))
            if t:
                out.append(t)
        elif m and out:                                     # 缩进的子项并到上一条
            t = _clean_md(m.group(1))
            if t:
                out[-1] += "；" + t
    return out


def build():
    print("下载 HowToCook 菜谱 …")
    raw = urllib.request.urlopen(URL, timeout=300).read()
    out = []
    with zipfile.ZipFile(io.BytesIO(raw)) as z:
        for n in z.namelist():
            parts = n.split("/")
            if len(parts) < 4 or parts[1] != "dishes" or not n.endswith(".md") or parts[2] == "template":
                continue
            r = parse(parts[-1][:-3], z.read(n).decode("utf-8", "ignore"))
            if r:
                r["category"] = CATS.get(parts[2], parts[2])
                r["id"] = f"R{len(out) + 1:03d}"
                out.append(r)
    OUT.parent.mkdir(parents=True, exist_ok=True)
    OUT.write_text("\n".join(json.dumps(r, ensure_ascii=False) for r in out) + "\n")
    print(f"共 {len(out)} 道菜")


def load() -> list[dict]:
    if not OUT.exists():
        build()
    rs = [json.loads(l) for l in OUT.read_text().splitlines() if l.strip()]
    if rs and "steps" not in rs[0]:   # 旧版文件没有做法步骤，重新构建一次
        build()
        rs = [json.loads(l) for l in OUT.read_text().splitlines() if l.strip()]
    return rs


if __name__ == "__main__":
    build()
