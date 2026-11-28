#!/bin/bash
# 双击运行第 1 步：多模态 RAG（检索相似的已核实餐食作为份量参照），200 张测试集
cd "$(dirname "$0")"
mkdir -p results
{
  echo "== $(date) =="
  .venv/bin/python -m mealagent.rag.visual
  for p in zh_mm3_text zh_mm3 zh_mm5; do
    .venv/bin/python -m evals.run_eval --pipeline $p --dataset jfb --n 200 --workers 6
  done
  .venv/bin/python -m evals.report jfb 200
  echo "== done $(date) =="
} 2>&1 | tee results/log_step1.txt
