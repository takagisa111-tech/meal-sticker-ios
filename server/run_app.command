#!/bin/bash
# 双击启动「管家」后端（给 iOS App 用）。关掉这个终端窗口即停止。
#   模拟器里的 App：服务器地址填 http://localhost:8765
#   真机（和 Mac 连同一个 Wi-Fi）：填下面打印出来的 http://192.168.x.x:8765
cd "$(dirname "$0")"
mkdir -p results
.venv/bin/pip install -q -r requirements.txt
echo "准备菜谱库（第一次会下载 HowToCook）…"
.venv/bin/python -c "from mealagent.knowledge import recipes; print(len(recipes.load()), '道菜谱')"
IP=$(ipconfig getifaddr en0 2>/dev/null || ipconfig getifaddr en1 2>/dev/null)
echo ""
echo "======================================================"
echo "  模拟器：http://localhost:8765"
[ -n "$IP" ] && echo "  真机：  http://$IP:8765"
echo "======================================================"
echo ""
.venv/bin/python -m uvicorn app.server:app --host 0.0.0.0 --port 8765 2>&1 | tee results/log_app.txt
