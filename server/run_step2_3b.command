#!/bin/bash
# 双击运行第 2、3 步第二轮：修正步骤 v2（记录 agent）+ 修好并发 bug、补上「诱导违规」场景后的规划 agent
cd "$(dirname "$0")"
mkdir -p results
{
  echo "== $(date) =="
  for p in agent_always1_r2 agent_q2_r2; do
    .venv/bin/python -m evals.run_eval --pipeline $p --dataset jfb --n 200 --workers 6
  done
  .venv/bin/python -m evals.report jfb 200
  for v in plain agent_noguard agent; do
    .venv/bin/python -m evals.planning --variant $v --n 8 --workers 6
  done
  echo "== done $(date) =="
} 2>&1 | tee results/log_step2_3b.txt
