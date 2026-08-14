"""三个端点，够语音条跑起来了。挂进你自己的 FastAPI：

    from voice_routes import router as voice_router
    app.include_router(voice_router)

鉴权按你自己那套加（`dependencies=[Depends(你的鉴权)]`）——
这几个端点会写文件、会往外发正文，别裸奔。
"""

from __future__ import annotations

import re
import uuid
from datetime import datetime, timezone
from pathlib import Path

from fastapi import APIRouter, File, Form, HTTPException, UploadFile
from fastapi.responses import Response
from pydantic import BaseModel

import voice_service as vs

router = APIRouter(prefix="/api/voice", tags=["voice"])

# 录音存哪儿。真上生产的话按会话分目录，别全堆一起。
UPLOAD_DIR = Path("uploads/voice").resolve()
MAX_BYTES = 12 * 1024 * 1024          # 一条 12MB，两分钟的 m4a 远用不到
_SAFE = re.compile(r"[^A-Za-z0-9._-]+")


class TTSBody(BaseModel):
    text: str = ""


@router.post("/message")
async def voice_message(
    file: UploadFile = File(...),
    duration: int = Form(default=0),
) -> dict:
    """收一段录音：存盘 → （可选）服务端转写 → 回一行标记 + 文件名。

    客户端拿到 `message` 之后，把它当成**一条普通文字消息**发给模型，
    音频只是挂在旁边给人回放的附件 —— 模型读不了音频，它读的是那行标记和转写。
    """
    suffix = Path(file.filename or "voice.m4a").suffix.lower() or ".m4a"
    if suffix not in vs.AUDIO_EXTENSIONS:
        raise HTTPException(status_code=415, detail=f"不支持的音频类型：{suffix}")

    data = await file.read()
    if not data:
        raise HTTPException(status_code=400, detail="empty audio")
    if len(data) > MAX_BYTES:
        raise HTTPException(status_code=413, detail="audio too large")

    UPLOAD_DIR.mkdir(parents=True, exist_ok=True)
    stamp = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%S%f")
    name = f"{stamp}_{uuid.uuid4().hex[:8]}{suffix}"
    dest = (UPLOAD_DIR / name).resolve()
    # 存盘名是自己拼的，但还是核一遍：别人改客户端就能把 `../` 塞进来
    if UPLOAD_DIR not in dest.parents:
        raise HTTPException(status_code=400, detail="bad filename")
    dest.write_bytes(data)

    stt = vs.transcribe_audio(file.filename or f"voice{suffix}", data)
    text = str(stt.get("text") or "")
    emotion = str(stt.get("emotion") or "neutral")
    if not re.fullmatch(r"[a-z]+", emotion):
        emotion = "neutral"

    dur = max(0, int(duration or 0))
    return {
        "name": name,
        "duration": dur,
        "text": text,
        "emotion": emotion,
        # 客户端把这一行当普通消息发出去
        "message": vs.voice_marker(dur, text, emotion),
        "stt_error": stt.get("error"),
    }


@router.get("/file/{name}")
async def voice_file(name: str) -> Response:
    """把存下来的那段录音原样吐回去。对应 iOS 那边的 `VoiceKit.backend.storedAudio`。"""
    safe = _SAFE.sub("", name)
    path = (UPLOAD_DIR / safe).resolve()
    if UPLOAD_DIR not in path.parents or not path.is_file():
        raise HTTPException(status_code=404, detail="not found")
    return Response(content=path.read_bytes(), media_type="audio/mp4")


@router.post("/tts")
async def voice_tts(body: TTSBody) -> Response:
    """把一句话念出来。对应 iOS 那边的 `VoiceKit.backend.synthesize`。

    ⚠️ 这里**不做缓存**：同一句话只会被请求一次，因为客户端合成完就落盘了
    （见 `VoiceSpeech`）。真要在服务端也存一份，按 sha1(text) 存文件就行。
    """
    text = (body.text or "").strip()
    if not text:
        raise HTTPException(status_code=400, detail="text required")
    out = await vs.synthesize_speech(text)
    if not out:
        # 三档全哑。客户端该掉到设备自带的合成器上（AVSpeechSynthesizer /
        # speechSynthesis），别在这儿假装成功回一段空音频。
        raise HTTPException(status_code=503, detail="tts unavailable")
    audio, mime = out
    return Response(content=audio, media_type=mime)
