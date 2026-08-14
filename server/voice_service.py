"""语音条的服务端那半边：把一句话念出来（TTS），把一段录音听成字（STT）。

依赖只有标准库；edge-tts 那一档要 `pip install edge-tts`（可选）。
两个函数就是全部对外接口：

    audio = await synthesize_speech("我在这儿等你")      # → (bytes, media_type) | None
    result = transcribe_audio("voice.m4a", data)          # → {"text": ..., "emotion": ...}

配置全走环境变量，见文件头这一段。一个都不配也能跑：
TTS 会掉到本机 `say`（只有 macOS 有），STT 会返回空字符串（客户端本机听写兜底）。
"""

from __future__ import annotations

import asyncio
import json
import logging
import os
import tempfile
import time
import urllib.error
import urllib.request
import uuid
from pathlib import Path
from typing import Any

logger = logging.getLogger(__name__)

# ── 出声：三档，从贵到免费，一档不成掉下一档 ──────────────────────────
#
# 1. ElevenLabs —— 音色最好，要 key、要钱。不配就跳过。
# 2. edge-tts   —— 微软神经声库，免费、不要 key，质量够用。
#                  ⚠️ 走这条＝把**正文**发到微软的服务器上（wss://speech.platform.bing.com）。
#                  介意就把 EDGE_TTS_VOICE 设成空，这一档直接跳过。
# 3. 本机 say    —— macOS 自带，离线，一个字都不出这台机器。音色最差但永远在。
#
# 还有第 0 档在客户端：三档全哑的时候用 iOS 的 AVSpeechSynthesizer / 浏览器的
# speechSynthesis 直接在设备上念。那一档完全不联网，见 README。

ELEVENLABS_API_KEY = os.environ.get("ELEVENLABS_API_KEY", "").strip()
ELEVENLABS_VOICE_ID = os.environ.get("ELEVENLABS_VOICE_ID", "").strip()
ELEVENLABS_MODEL = os.environ.get("ELEVENLABS_MODEL", "eleven_multilingual_v2").strip()

# `edge-tts --list-voices` 看全部。云健(Yunjian) 是中文男声里最低沉的一个。
EDGE_TTS_VOICE = os.environ.get("EDGE_TTS_VOICE", "zh-CN-YunjianNeural").strip()
EDGE_TTS_PITCH = os.environ.get("EDGE_TTS_PITCH", "+0Hz").strip() or "+0Hz"
EDGE_TTS_RATE = os.environ.get("EDGE_TTS_RATE", "+0%").strip() or "+0%"
# ⚠️ 实测：进程冷着的时候头几次要 14~31 秒，热起来之后稳定 2.5~4 秒。
# 所以给它一个上限，超了就掉到本机声音 —— 宁可音色差一点，也不能让它哑着。
# 预热见 `warm_tts()`：服务起来时打一发，把这段冷启动提前吃掉。
EDGE_TTS_TIMEOUT = float(os.environ.get("EDGE_TTS_TIMEOUT", "6"))

# 本机兜底的声音。`say -v '?'` 看全部；Reed / Rocko / Eddy 是中文的。
SAY_VOICE = os.environ.get("SAY_VOICE", "Reed").strip()

# ── 听懂：自建 STT 服务（可选）────────────────────────────────────────
# 空着就不走服务端转写，让客户端自己听写（iOS 的 SFSpeechRecognizer 能离线，
# 浏览器的 webkitSpeechRecognition 会发去 Apple/Google）。
# 要自建就填个地址，例：http://127.0.0.1:3462/transcribe
# 接口约定：multipart 上传字段名 `file`，返回 {"text": "...", "emotion": "..."}。
# 实现可以用 SenseVoice / faster-whisper / whisper.cpp，随便哪个。
STT_URL = os.environ.get("STT_URL", "").strip()

AUDIO_EXTENSIONS = {".webm", ".ogg", ".opus", ".mp3", ".wav", ".m4a", ".flac"}


def tts_available() -> bool:
    return bool(_elevenlabs_available() or EDGE_TTS_VOICE or SAY_VOICE)


def stt_available() -> bool:
    return bool(STT_URL)


def _elevenlabs_available() -> bool:
    return bool(ELEVENLABS_API_KEY and ELEVENLABS_VOICE_ID)


def _ssl_context():
    """macOS 的系统 Python 常缺 CA 包，有 certifi 就优先用它。"""
    import ssl

    try:
        import certifi

        return ssl.create_default_context(cafile=certifi.where())
    except ImportError:
        return ssl.create_default_context()


# ── TTS ───────────────────────────────────────────────────────────────


async def synthesize_speech(text: str) -> tuple[bytes, str] | None:
    """一句话 → (音频字节, media_type)。三档往下掉，掉到底也要有声音。

    ⚠️ 别把 edge-tts 那条塞进 `asyncio.to_thread`：它是 aiohttp 的，
    扔进新线程要另起一个事件循环，白白多掉半秒。ElevenLabs 那条是 urllib，
    它自己包 to_thread。
    """
    text = (text or "").strip()
    if not text:
        return None

    if _elevenlabs_available():
        audio = await asyncio.to_thread(_elevenlabs_bytes, text)
        if audio:
            return audio, "audio/mpeg"

    if EDGE_TTS_VOICE:
        audio = await _edge_tts_bytes(text)
        if audio:
            return audio, "audio/mpeg"

    audio = await _say_bytes(text)
    return (audio, "audio/mp4") if audio else None


def _elevenlabs_bytes(text: str) -> bytes | None:
    url = f"https://api.elevenlabs.io/v1/text-to-speech/{ELEVENLABS_VOICE_ID}"
    payload = json.dumps(
        {
            "text": text[:2500],
            "model_id": ELEVENLABS_MODEL,
            "voice_settings": {
                "stability": 0.42,
                "similarity_boost": 0.75,
                "style": 0.84,
                "use_speaker_boost": True,
            },
        },
        ensure_ascii=False,
    ).encode("utf-8")
    req = urllib.request.Request(
        url,
        data=payload,
        headers={
            "xi-api-key": ELEVENLABS_API_KEY,
            "Content-Type": "application/json",
            "Accept": "audio/mpeg",
        },
        method="POST",
    )
    try:
        with urllib.request.urlopen(req, timeout=45, context=_ssl_context()) as resp:
            return resp.read()
    except (urllib.error.URLError, TimeoutError, OSError) as exc:
        logger.warning("[voice] elevenlabs failed: %s", exc)
        return None


async def _edge_tts_bytes(text: str, *, timeout: float | None = None) -> bytes | None:
    """微软神经声库。免费、不要 key，代价是正文要发到它的服务器上。

    `timeout` 不给就用 `EDGE_TTS_TIMEOUT`。预热那一发要给得足够长 ——
    它等的正是那段冷启动，拿 6 秒去掐它就永远热不起来。
    """
    timeout = EDGE_TTS_TIMEOUT if timeout is None else timeout
    try:
        import edge_tts
    except ImportError:
        logger.warning("[voice] edge-tts not installed — pip install edge-tts")
        return None

    async def pull() -> bytes:
        comm = edge_tts.Communicate(
            text[:2500], EDGE_TTS_VOICE, pitch=EDGE_TTS_PITCH, rate=EDGE_TTS_RATE
        )
        buf = bytearray()
        async for chunk in comm.stream():
            if chunk["type"] == "audio":
                buf += chunk["data"]
        return bytes(buf)

    try:
        audio = await asyncio.wait_for(pull(), timeout=timeout)
        # 太小就是没合成出东西（客户端也按 100 字节判空）
        return audio if len(audio) > 100 else None
    except TimeoutError:
        logger.warning("[voice] edge-tts slow (>%.0fs) — falling back to say", timeout)
        return None
    except Exception as exc:  # 网络抖、声音名写错、对面改协议，都不该让它哑掉
        logger.warning("[voice] edge-tts failed: %s", exc)
        return None


async def _say_bytes(text: str) -> bytes | None:
    """本机 `say` → m4a。离线、1~2 秒、一个字都不出这台机器。macOS 限定。"""
    if not SAY_VOICE:
        return None
    with tempfile.TemporaryDirectory() as tmp:
        out = Path(tmp) / "say.m4a"
        try:
            proc = await asyncio.create_subprocess_exec(
                "/usr/bin/say", "-v", SAY_VOICE, "-o", str(out),
                "--data-format=aac", text[:2500],
                stdout=asyncio.subprocess.DEVNULL, stderr=asyncio.subprocess.PIPE,
            )
            _, err = await asyncio.wait_for(proc.communicate(), timeout=20)
        except (TimeoutError, OSError) as exc:
            logger.warning("[voice] say failed: %s", exc)
            return None
        if proc.returncode != 0:
            logger.warning("[voice] say exit=%s %s", proc.returncode, err[:200])
            return None
        data = out.read_bytes() if out.exists() else b""
        return data if len(data) > 100 else None


async def warm_tts() -> None:
    """把到微软那条链先焐热。冷着头一次要半分钟，热了就 2 秒出声。

    服务起来时打一发就够（FastAPI 的 lifespan 里 `asyncio.create_task(warm_tts())`）。
    ⚠️ 预热这一发必须给长超时，否则它等的那段冷启动永远等不完。
    """
    if not EDGE_TTS_VOICE:
        return
    t0 = time.perf_counter()
    got = await _edge_tts_bytes("嗯", timeout=45)
    logger.info("[voice] tts warm %.1fs ok=%s", time.perf_counter() - t0, bool(got))


# ── STT ───────────────────────────────────────────────────────────────


def transcribe_audio(filename: str, data: bytes) -> dict[str, Any]:
    """把一段录音丢给自建 STT 服务。失败一律软着陆，返回空字符串。

    没配 STT_URL 就直接返回空 —— 客户端本机听写会兜住（见 iOS 的
    `VoiceRecorder.transcribe`），这不是错误路径，是默认路径。
    """
    if not STT_URL:
        return {"text": "", "emotion": "neutral", "error": "stt not configured"}
    if not data:
        return {"text": "", "emotion": "neutral", "error": "no audio"}

    boundary = f"----voicekit{uuid.uuid4().hex}"
    ext = Path(filename or "a.webm").suffix.lower() or ".webm"
    if ext not in AUDIO_EXTENSIONS:
        ext = ".webm"
    body = (
        f"--{boundary}\r\n"
        f'Content-Disposition: form-data; name="file"; filename="audio{ext}"\r\n'
        f"Content-Type: application/octet-stream\r\n\r\n"
    ).encode() + data + f"\r\n--{boundary}--\r\n".encode()
    req = urllib.request.Request(
        STT_URL,
        data=body,
        headers={"Content-Type": f"multipart/form-data; boundary={boundary}"},
        method="POST",
    )
    try:
        with urllib.request.urlopen(req, timeout=60) as resp:
            payload = json.loads(resp.read().decode("utf-8", "replace"))
        if not isinstance(payload, dict):
            return {"text": "", "emotion": "neutral", "error": "bad stt response"}
        return {
            "text": str(payload.get("text") or "").strip(),
            "emotion": str(payload.get("emotion") or "neutral"),
            "elapsed_s": payload.get("elapsed_s"),
        }
    except (urllib.error.URLError, TimeoutError, OSError, json.JSONDecodeError) as exc:
        logger.warning("[voice] stt failed: %s", exc)
        return {"text": "", "emotion": "neutral", "error": str(exc)}


# ── 消息里的那行标记 ──────────────────────────────────────────────────


def voice_marker(duration: int, transcript: str = "", emotion: str = "") -> str:
    """拼出发给模型的那一行：`[voice · 0:05 · happy] 转写文字`。

    emotion 是 neutral / 空就不写那一格。客户端认的正则见 iOS 的 `VoiceMarker.parse`。
    """
    mins, secs = divmod(max(0, int(duration)), 60)
    emo = f" · {emotion}" if emotion and emotion != "neutral" else ""
    head = f"[voice · {mins}:{secs:02d}{emo}]"
    return f"{head} {transcript}".rstrip() if transcript else head
