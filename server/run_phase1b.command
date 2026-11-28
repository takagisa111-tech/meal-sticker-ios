#!/bin/bash
# 双击运行第一阶段第二轮：扩大到 200 张，对比基线、提示词 v2/v3、RAG v3、RAG 集成，生成带置信区间的对比表
cd "$(dirname "$0")"
mkdir -p results
{
  echo "== $(date) =="
  .venv/bin/pip install -q -r requirements.txt
  for p in baseline prompt_v2 prompt_v3 rag_v3 rag_ens_v3; do
    .venv/bin/python -m evals.run_eval --pipeline $p --dataset jfb --n 200 --workers 6
  done
  .venv/bin/python -m evals.report jfb 200
  echo "== done $(date) =="
} 2>&1 | tee results/log_phase1b.txt
