"""评测数据集。

JFB：January Food Benchmark（1000 张真实餐食照片，人工核验的菜名、食材和宏量营养，CC-BY-4.0）
     https://github.com/January-ai/food-scan-benchmarks
"""
from __future__ import annotations
import ast
import tarfile
import urllib.request
from pathlib import Path

import pandas as pd

from mealagent.config import DATA_DIR

JFB_URL = "https://january-food-image-dataset-public.s3.amazonaws.com/food-scan-benchmark-dataset.tar.gz"


def _download(url: str, dest: Path):
    dest.parent.mkdir(parents=True, exist_ok=True)
    print(f"下载 {url} …")
    tmp = dest.with_suffix(dest.suffix + ".part")
    urllib.request.urlretrieve(url, tmp)
    tmp.rename(dest)


def _parse(v):
    """标注里的食材列表被字符串化了两次，需要解析到拿到 list 为止。"""
    for _ in range(3):
        if not isinstance(v, str):
            break
        try:
            v = ast.literal_eval(v)
        except (ValueError, SyntaxError):
            return []
    return v if isinstance(v, list) else []


def load_jfb() -> list[dict]:
    root = DATA_DIR / "jfb"
    base = root / "food-scan-benchmark-dataset"
    csv = base / "food_scan_bench_v1.csv"
    if not csv.exists():
        arc = root / "jfb.tar.gz"
        if not arc.exists():
            _download(JFB_URL, arc)
        print("解压 …")
        with tarfile.open(arc) as t:
            t.extractall(root)
    df = pd.read_csv(csv)
    items = []
    for row in df.itertuples():
        ings = _parse(row.ingredients_list)
        items.append({
            "id": str(row.image_id),
            "image": base / "fsb_images" / row.image_filename,
            "meal_name": row.meal_name,
            "ingredients": [str(i.get("name", "")) for i in ings if isinstance(i, dict)],
            "ingredient_details": [i for i in ings if isinstance(i, dict)],
            "macros": {"calories": float(row.total_calories), "carbs": float(row.total_carbs),
                       "protein": float(row.total_protein), "fat": float(row.total_fat)},
        })
    return items


TEST_SIZE = 200
SEED = 42


def split_jfb() -> tuple[list[dict], list[dict]]:
    """固定划分：按 seed=42 打乱后，前 200 张是测试集，其余 800 张是参考库（多模态 RAG 只能检索参考库）。"""
    import random
    items = load_jfb()
    random.Random(SEED).shuffle(items)
    return items[:TEST_SIZE], items[TEST_SIZE:]


DATASETS = {"jfb": load_jfb}
