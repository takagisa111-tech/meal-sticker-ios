#!/bin/bash
# 双击运行第 2、3 步：
#   第 2 步 记录 agent（拿不准才问）在 200 张测试集上的 4 个版本
#   第 3 步 规划 agent 在 40 个家庭场景上的 3 个版本（agent / 去掉护栏 / 不用工具的普通大模型）
cd "$(dirname "$0")"
mkdir -p results
{
  echo "== $(date) =="
  .venv/bin/pip install -q -r requirements.txt
  .venv/bin/python -m mealagent.knowledge.recipes
  for p in agent_q0 agent_always1 agent_q1 agent_q2; do
    .venv/bin/python -m evals.run_eval --pipeline $p --dataset jfb --n 200 --workers 6
  done
  .venv/bin/python -m evals.report jfb 200
  for v in plain agent_noguard agent; do
    .venv/bin/python -m evals.planning --variant $v --n 8 --workers 6
  done
  echo "== done $(date) =="
} 2>&1 | tee results/log_step2_3.txt
