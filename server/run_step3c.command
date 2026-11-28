#!/bin/bash
# 双击运行：规划部分的最终方案「单次调用 + 菜谱检索」在 48 个场景上的评测
cd "$(dirname "$0")"
{
  .venv/bin/python -m evals.planning --variant plain_rag --n 8 --workers 6
} 2>&1 | tee results/log_step3c.txt
