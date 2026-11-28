"""DeepSeek 调用封装：图片编码、JSON 输出解析、重试、token 统计。"""
from __future__ import annotations
import base64
import io
import json
import re
import time

from openai import OpenAI
from PIL import Image, ImageOps

from . import config
from .schema import RunStats

_client = None


def client() -> OpenAI:
    global _client
    if _client is None:
        if not config.DEEPSEEK_API_KEY:
            raise RuntimeError("缺少 DEEPSEEK_API_KEY，请在 .env 里填写")
        _client = OpenAI(api_key=config.DEEPSEEK_API_KEY, base_url=config.DEEPSEEK_BASE_URL, timeout=150)
    return _client


def encode_image(img: Image.Image, max_side: int = 1024, quality: int = 82) -> str:
    """和 iOS App 一致：长边缩到 1024，JPEG 质量 0.82。"""
    img = ImageOps.exif_transpose(img).convert("RGB")
    s = min(1.0, max_side / max(img.size))
    if s < 1:
        img = img.resize((round(img.width * s), round(img.height * s)), Image.LANCZOS)
    buf = io.BytesIO()
    img.save(buf, "JPEG", quality=quality)
    return "data:image/jpeg;base64," + base64.b64encode(buf.getvalue()).decode()


def extract_json(text: str):
    text = text.strip()
    text = re.sub(r"^```(?:json)?|```$", "", text, flags=re.M).strip()
    a, b = text.find("{"), text.rfind("}")
    if a < 0 or b <= a:
        return None
    try:
        return json.loads(text[a:b + 1])
    except json.JSONDecodeError:
        return None


def chat_json(prompt: str, images=(), stats: RunStats | None = None, system: str | None = None,
              temperature: float = 0.3, max_tokens: int = 6000, retry_hint: str = "", json_mode: bool = False) -> dict:
    """发一次请求，要求只返回 JSON；解析失败时带提示重试一次。"""
    content = [{"type": "text", "text": prompt}]
    for im in images:
        content.append({"type": "image_url", "image_url": {"url": im if isinstance(im, str) else encode_image(im)}})
    messages = ([{"role": "system", "content": system}] if system else []) + [{"role": "user", "content": content}]
    last = None
    for attempt in range(2):
        if attempt == 1 and retry_hint:
            messages[-1]["content"][0]["text"] = prompt + "\n\n" + retry_hint
        t = time.time()
        r = client().chat.completions.create(
            model=config.DEEPSEEK_MODEL, messages=messages, temperature=temperature,
            max_tokens=max_tokens, stream=False,
            extra_body={"thinking": {"type": "disabled"}},
            **({"response_format": {"type": "json_object"}} if json_mode else {}),
        )
        if stats is not None:
            stats.seconds += time.time() - t
            stats.llm_calls += 1
            if r.usage:
                stats.input_tokens += r.usage.prompt_tokens or 0
                stats.output_tokens += r.usage.completion_tokens or 0
        last = r.choices[0].message.content or ""
        obj = extract_json(last)
        if obj is not None:
            return obj
    raise ValueError("模型没有返回合法 JSON：" + last[:200])


def chat_text(prompt: str, system: str | None = None, temperature: float = 0.3, max_tokens: int = 300) -> str:
    """纯文本对话（评测里的模拟用户用），不计入 agent 的统计。"""
    messages = ([{"role": "system", "content": system}] if system else []) + [{"role": "user", "content": prompt}]
    r = client().chat.completions.create(model=config.DEEPSEEK_MODEL, messages=messages, temperature=temperature,
                                         max_tokens=max_tokens, stream=False, extra_body={"thinking": {"type": "disabled"}})
    return (r.choices[0].message.content or "").strip()
