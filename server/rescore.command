#!/bin/bash
# 双击运行：用修正后的食材标注，给基线结果重新打分（不再调用 DeepSeek）
cd "$(dirname "$0")"
.venv/bin/python -m evals.rescore results/raw/baseline_jfb_100.jsonl 2>&1 | tee results/log_rescore.txt
