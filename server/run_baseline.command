#!/bin/bash
# 双击运行：装依赖（第一次）→ 跑基线评测（JFB 随机 100 张）
cd "$(dirname "$0")"
mkdir -p results
{
  echo "== $(date) =="
  [ -x .venv/bin/python ] || ./setup.sh
  .venv/bin/python -m evals.run_eval --pipeline baseline --dataset jfb --n 100 --workers 4
  echo "== done $(date) =="
} 2>&1 | tee results/log_baseline.txt
