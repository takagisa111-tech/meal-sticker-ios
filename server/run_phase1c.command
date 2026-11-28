#!/bin/bash
# 双击运行第一阶段第三轮：全部用中文提示词，排除语言差异，只比较技术本身（200 张）
cd "$(dirname "$0")"
mkdir -p results
{
  echo "== $(date) =="
  for p in zh_v2 zh_rag baseline_sc3; do
    .venv/bin/python -m evals.run_eval --pipeline $p --dataset jfb --n 200 --workers 6
  done
  .venv/bin/python -m evals.report jfb 200
  echo "== done $(date) =="
} 2>&1 | tee results/log_phase1c.txt
