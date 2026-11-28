#!/bin/bash
# 双击运行「agent + RAG 加强版」全部评测：
#   ① 饮食数据分析 agent（Text-to-SQL）vs 全部记录塞进提示词       30 题
#   ② 一周菜单：一次生成 / 一次生成+校验修改 / ReAct agent+RAG+自检  12 个场景
#   ③ 日常问答最终方案（单次调用 + 菜谱检索 + 护栏）                48 个场景
#   ④ 智能路由：路由准确率 + 三种策略的整体成功率和成本
cd "$(dirname "$0")"
mkdir -p results
{
  echo "== $(date) =="
  .venv/bin/pip install -q -r requirements.txt
  .venv/bin/python -m mealagent.knowledge.recipes
  .venv/bin/python -m mealagent.data.history
  for v in plain agent; do .venv/bin/python -m evals.analytics --variant $v; done
  for v in single single_verify agent; do .venv/bin/python -m evals.weekly --variant $v; done
  .venv/bin/python -m evals.planning --variant plain_rag --n 8 --workers 6
  .venv/bin/python -m evals.routing
  echo "== done $(date) =="
} 2>&1 | tee results/log_stack.txt
