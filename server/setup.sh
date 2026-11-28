#!/bin/bash
# 在 Mac 上第一次运行：建虚拟环境、装依赖
set -e
cd "$(dirname "$0")"
PY=$(command -v python3.12 || command -v python3.11 || command -v python3)
"$PY" -m venv .venv
.venv/bin/pip install -q --upgrade pip
.venv/bin/pip install -q -r requirements.txt
[ -f .env ] || cp .env.example .env
echo "OK: $(.venv/bin/python --version)"
