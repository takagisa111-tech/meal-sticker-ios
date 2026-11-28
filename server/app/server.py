"""食贴 AI 后端（FastAPI）：给 iOS App 的「管家」用。

    python -m uvicorn app.server:app --host 0.0.0.0 --port 8765

POST /api/agent   一轮对话。请求体：
    {"messages": [{"role": "user"|"assistant", "content": "…", "image_ids": ["img1"]}, …],
     "images": {"img1": "data:image/jpeg;base64,…"},          # 只放这一轮新发的图
     "context": {"today", "now", "member_id", "members", "memories", "records", "fridge"}}
  返回 text/event-stream，每行 `data: {事件 JSON}`，事件类型见 mealagent/butler/agent.py。
GET  /api/health  健康检查

服务器不保存任何用户数据：饮食记录、记忆、冰箱都由 App 每次随请求带上来。
设置环境变量 APP_TOKEN 后，请求头必须带 X-App-Token（防止别人用你的 DeepSeek 额度）。
"""
from __future__ import annotations

import json
import os
import threading

from fastapi import FastAPI, Header, HTTPException, Request
from fastapi.responses import JSONResponse, StreamingResponse

from mealagent import config
from mealagent.butler import agent

app = FastAPI(title="食贴 Meal Sticker AI")
TOKEN = os.getenv("APP_TOKEN", "")


@app.exception_handler(Exception)
async def _err(request, exc):
    import traceback
    traceback.print_exc()
    return JSONResponse({"error": f"{type(exc).__name__}: {exc}"}, status_code=500)


@app.on_event("startup")
def _warm():
    """后台预热菜谱和指南索引（第一次要加载向量模型），这样第一条消息不会卡很久。"""
    def go():
        try:
            from mealagent.agent.tools import guide_db, recipe_db
            recipe_db()
            guide_db()
            print("索引已就绪")
        except Exception as e:  # noqa: BLE001
            print("预热失败：", e)
    threading.Thread(target=go, daemon=True).start()


@app.get("/")
@app.get("/api/health")
def health():
    return {"ok": True, "model": config.DEEPSEEK_MODEL, "key": bool(config.DEEPSEEK_API_KEY), "auth": bool(TOKEN)}


@app.post("/api/agent")
async def chat(request: Request, x_app_token: str = Header(default="")):
    if TOKEN and x_app_token != TOKEN:
        raise HTTPException(401, "token 不对")
    body = await request.json()

    def events():
        for ev in agent.run(body):
            yield "data: " + json.dumps(ev, ensure_ascii=False, default=str) + "\n\n"

    return StreamingResponse(events(), media_type="text/event-stream",
                             headers={"Cache-Control": "no-cache", "X-Accel-Buffering": "no"})
