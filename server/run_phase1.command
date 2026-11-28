#!/bin/bash
# 双击运行第一阶段评测：建 RAG 知识库 → 用新指标重新给基线打分 → 跑 3 个改进版本 → 生成对比表
cd "$(dirname "$0")"
mkdir -p results
{
  echo "== $(date) =="
  .venv/bin/pip install -q -r requirements.txt
  .venv/bin/python -m mealagent.rag.fndds
  .venv/bin/python -m evals.rescore results/raw/baseline_jfb_100.jsonl
  for p in prompt_v2 rag rag_rerank; do
    .venv/bin/python -m evals.run_eval --pipeline $p --dataset jfb --n 100 --workers 6
  done
  .venv/bin/python -m evals.report jfb 100
  echo "== done $(date) =="
} 2>&1 | tee results/log_phase1.txt
