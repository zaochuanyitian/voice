# voice —— 给 AI 聊天 App 的语音条

微信那种语音条，两个方向都通：

- **你发语音**：点话筒 → 录 → 停 → 本机听写成字 → 连音频一起发出去。模型读到的是文字，人听到的是你的声音。
- **模型发语音**：它在回复开头写一行 `[voice]`，客户端就把这条渲染成语音气泡，点一下用 TTS 念出来，长按才看到字。

气泡是镜像的：自己那条靠右、喇叭在右边口朝左；对方那条靠左、口朝右。点一下播放，长按 420ms 展开转写。

这是从一个真在用的 iOS 客户端里抠出来的，不是示例代码。四个 Swift 文件不依赖宿主工程，
`swiftc -typecheck` 单独过得了。

```
voice/
  ios/
    VoiceKit.swift        ← 接缝：配色、气泡形状、两个网络回调。只改这个文件
    VoiceMessage.swift    ← 录音条 + 语音气泡 + 播放 + 合成结果落盘缓存
    VoiceRecorder.swift   ← 录音 + 本机听写（SFSpeechRecognizer）
    VoiceProsody.swift    ← 本机量「怎么说的」，量完拼一行给模型。不要的话见第四节
  server/
    voice_service.py      ← 几档 TTS / STT，只依赖标准库
    voice_routes.py       ← 三个 FastAPI 端点
```

---

## 一、消息格式：整套东西就靠这一行

语音不是另一种消息类型，就是**普通文字消息**，正文开头多一行标记，音频当附件挂旁边。
这样模型那边什么都不用改，历史记录、搜索、重试全都照旧能用。

```
你发的：   [voice · 0:07] 现在是不是听不到我的语音呀
           [语气 · 轻声 · 句尾往上扬 · 中间顿了一下]      ← 可选，见第四节

模型发的： [voice] 我在这儿等你的空碗
```

- 时长那一格**可选**。模型不知道自己要念多少秒，所以它只写 `[voice]`，
  时长由客户端合成完之后量出来（在那之前先按字数估一个，4.5 字/秒）。
- 客户端认的正则：`^\[voice(?:\s*·\s*(\d+:\d+))?(?:\s*·\s*([a-z]+))?\]\s*`。
  情绪那一格只收小写字母 —— 中文塞进方括号里正则就认不出来了，所以语气另起一行。
- 服务端拼这行用 `voice_service.voice_marker()`，客户端解用 `VoiceMarker.parse()`，两边别改岔了。

要让模型会发语音，在系统提示词里加一段（这段直接抄）：

```
## 语音条 —— 你也能发语音

正文以 `[voice]` 开头，这一整条就是一条语音。客户端会显示成语音气泡，
用户点一下听见你的声音，长按才看得到字。

    [voice] 我在这儿等你的空碗

- 标记后面那段既是你说的话、也是用户长按看到的字，别再另起段落写别的。
- 只发短的：一两句、40 字以内。语音是用来说的，不是拿来读的。
- 不许写动作描写、星号旁白、括号里的语气注解，也不要列点、代码、链接、emoji ——
  这些念出来全是噪音。
- 别滥用。要讲事情、要贴代码就照常打字。
- 不要解释这个标记，也不要说「我给你发条语音」这类元话术。
```

⚠️ 如果你也有推送/通知，记得在**通知正文**里把 `[voice]` 前缀剃掉，
但**落库那条必须留着标记** —— 客户端靠它渲染成语音条。

---

## 二、接进去要做的三件事

**1. 把四个 Swift 文件拖进工程，然后配一次 `VoiceKit`：**

```swift
VoiceKit.style.ink = .primaryText          // 字色
VoiceKit.style.accent = composerColor      // 录音条强调色，建议＝输入框底色深一号
VoiceKit.style.mineBubble = .myBubble
VoiceKit.style.theirBubble = .theirBubble

VoiceKit.backend.storedAudio = { voice in
    await MyAPI.download("/api/voice/file/\(voice.path)")
}
VoiceKit.backend.synthesize = { text in
    await MyAPI.post("/api/voice/tts", ["text": text])
}
```

**2. 输入框上面挂录音条，话筒键点一下开录、再点一下停：**

```swift
@StateObject private var recorder = VoiceRecorder()

if recorder.isRecording {
    RecordingStrip(recorder: recorder,
                   onCancel: { recorder.cancel() },
                   onStop: { finishRecording() })
}

func finishRecording() {
    // 按下去就震，别等转写上传完 —— 那要好几秒，震在那会儿就对不上「我刚按了」
    UIImpactFeedbackGenerator(style: .medium).impactOccurred()
    Task {
        guard let take = await recorder.finish() else { return }
        // take.url 上传给 /api/voice/message，拿回 message 当普通消息发出去
        // take.transcript 是本机听写的结果，服务端转写为空时用它兜底
        // take.prosody 是那行语气，直接接在 message 后面（可选）
    }
}
```

**3. 消息列表里，正文能被 `VoiceMarker.parse` 认出来的那条，换成语音气泡：**

```swift
if let voice = VoiceMarker.parse(message.text) {
    VoiceBubble(marker: voice,
                audio: message.isMine ? attachment.map(VoiceAudio.stored)
                                      : .spoken(voice.transcript),
                mine: message.isMine,
                summary: message.thinkingSummary,      // 可选，会长在气泡里面
                onSummaryTap: { showTrace() })
}
```

⚠️ 语音那一行**别再挂整行的 `.contextMenu`**：系统那个长按菜单会把语音条自己的
长按整个吃掉，结果长按只弹出 Copy，「长按转文字」永远出不来。
复制/删除挂在展开的转写块上（`VoiceBubble` 里已经这么做了）。

模型那条语音，在回复流结束时提前热一发，用户点下去就基本不用等：

```swift
if let voice = VoiceMarker.parse(finalText), !voice.transcript.isEmpty {
    Task { await VoiceSpeech.shared.audio(for: voice.transcript) }
}
```

**只热刚收到的那一条。** 别改成「气泡一出现就预热」—— 翻历史滚过几十条语音
就是几十发合成请求，服务端那头多半是串行的。

---

## 三、几种获取声音的方式

### 出声（TTS）：四档，从贵到不要钱，一档不成掉下一档

| 档 | 谁在念 | 要 key | 联网 | 实测速度 | 备注 |
|---|---|---|---|---|---|
| 1 | ElevenLabs | 要，收费 | 是 | 1~3s | 音色最好。`ELEVENLABS_API_KEY` + `VOICE_ID` |
| 2 | **edge-tts**（微软神经声库） | **不要** | 是 | 冷 14~31s / 热 2.5~4s | 默认走这条。`pip install edge-tts` |
| 3 | 本机 `say` | 不要 | **否** | 1~2s | macOS 限定，音色最差但永远在 |
| 4 | 设备自己念 | 不要 | **否** | 立刻 | 上面全哑时的兜底，在客户端：iOS `AVSpeechSynthesizer` / 浏览器 `speechSynthesis` |

⚠️ **隐私**：第 2 档会把每一句正文发到微软的服务器（`wss://speech.platform.bing.com`）。
不接受就把 `EDGE_TTS_VOICE` 设成空，自动掉到第 3 / 4 档，那两档一个字都不出这台机器。

⚠️ **冷启动**：第 2 档进程冷着的时候头一次要半分钟，热了才 2 秒多。所以有两件事：
超时上限（`EDGE_TTS_TIMEOUT`，超了就掉档），以及服务起来时 `await warm_tts()` 打一发预热 ——
预热那一发必须给长超时（45s），它等的正是那段冷启动，拿 6 秒去掐它就永远热不起来。

### 听懂（STT）：四种，按「声音出不出这台设备」排

| 方式 | 在哪跑 | 离线 | 备注 |
|---|---|---|---|
| `SFSpeechRecognizer` + `requiresOnDeviceRecognition` | iOS 本机 | **是** | 首选。装了本机模型就完全不出设备 |
| `SFSpeechRecognizer`（在线档） | Apple 服务器 | 否 | 本机模型没装时自动退到这儿 |
| 自建服务（SenseVoice / faster-whisper / whisper.cpp） | 你自己的机器 | 是 | 填 `STT_URL`，接口约定见 `voice_service.transcribe_audio` |
| `webkitSpeechRecognition` | 浏览器 | 否 | 网页版唯一现成的路，iOS Safari 上其实也是发去 Apple |

本包的 iOS 实现是**录完再对文件转一遍**，不是边说边听写：实时听写要 `AVAudioEngine` 挂 tap，
跟 `AVAudioRecorder` 抢同一个 audio session，录完再转只多等一两秒，稳得多。

转写这步**不是锦上添花**：模型读不了音频，没有文字它收到的就是一个 `[voice · 0:05]` 空壳。
所以本机听写和服务端转写谁先回用谁，两个都空也照发不误（对面至少还听得见）。

### 缓存

模型那条语音的音频**不存服务端**，客户端拿正文现合成，按 `hash(正文)` 落盘存着，
同一句话一辈子只合成一次（`VoiceSpeech`，存 Application Support，300 条封顶）。

这么选是因为：合成是纯函数（同一句话永远是同一段声音），放客户端缓存一样只算一次，
而且不用去动「流式回复怎么落库」那条最容易出事的路。

---

## 四、可选：把「怎么说的」也告诉模型

`VoiceProsody.swift` 在录完之后就地量一遍这段录音，拼出这样一行：

```
[语气 · 轻声 · 句尾往上扬 · 中间顿了一下]
```

音量、语速、停顿、基频走向、跟这个人平时比高了还是低了 —— **全部在本机算完**，
不上传、不调服务（8kHz 降采样 + 自相关测基频，两分钟的音频也就 96 万个采样点）。

值得做的理由很实在：转写只告诉模型「说了什么」，这一行给的是「怎么说的」。
有了它，模型才回得出「三个字，尾音还翘上去」这种话。

不要这一层的话，删掉这个文件，再把 `VoiceRecorder.finish()` 里那两行
（`async let tone = …` 和 `let prosody = …`）去掉、`prosody` 传空串就行。

⚠️ 两条规矩：
- 每一条都必须是**真量出来的**，宁可少说一条也不能编 —— 模型读到「句尾上扬」就会当真。
- 这行**给模型看，不给人看**。界面上长按只显示转写，别把它也画出来。

---

## 五、转 PWA

这套东西在网页上能做到八成（差的主要是震动和后台）。把下面这段连同 `ios/` 四个文件
一起丢给你自己的 Claude / Codex，让它照着翻：

> 把 `ios/` 这套 SwiftUI 语音条翻成 PWA，保持消息格式契约（`[voice · 0:05] 转写`）
> 和交互不变：点话筒开录、再点停；录音条＝跳动的点 + 40 根波形 + 计时 + 取消 + 完成；
> 语音气泡点一下播放、长按 420ms 展开转写；自己那条靠右、对方那条靠左镜像。
> 服务端沿用 `server/` 那三个端点，不要改。按下面的对应关系翻：
>
> | SwiftUI | Web |
> |---|---|
> | `AVAudioRecorder` | `MediaRecorder(stream, {mimeType:'audio/webm;codecs=opus'})` |
> | `averagePower(forChannel:)` 取电平 | `AudioContext` + `AnalyserNode.getByteTimeDomainData` |
> | `SFSpeechRecognizer` | `webkitSpeechRecognition`（现场听写，录音同时跑） |
> | `AVAudioPlayer` | `new Audio(objectURL)` |
> | `VoiceSpeech` 落盘缓存 | Cache Storage：把 `/api/voice/tts` 的响应按正文 hash `put()` 进去 |
> | `UIImpactFeedbackGenerator` | `navigator.vibrate(12)` |
> | `.onLongPressGesture(0.42)` | `pointerdown` + 420ms 定时器，`pointerup/cancel` 清掉 |
> | `.task(id:)` | `useEffect` / `MutationObserver` |
> | `TimelineView(.animation)` 画喇叭 | CSS `@keyframes`，三道弧 `animation-delay` 依次 0/.15s/.3s |
>
> 还要处理这几件事：
> 1. 录音要 https + 用户手势触发，`getUserMedia({audio:true})` 才给权限。
> 2. `navigator.vibrate` 在 iOS Safari 上**不存在**，要判断存在再调，别让它抛。
> 3. `webkitSpeechRecognition` 只有 Chrome 和 Safari 有；没有就跳过本机听写，
>    靠服务端 STT 或者干脆只发时长。
> 4. iOS 上装成 PWA 之后 `100vh` 会塌陷，用 `--vh` 自定义属性 + `visualViewport` 事件顶住。
> 5. 加 `manifest.json`（`display: standalone`）和一个 Service Worker，
>    Service Worker 里别缓存 `/api/*`，只缓存壳。

---

## 许可与素材

代码按根目录的 LICENSE 走（非商业使用）。里面没有任何字体、图标或音频素材：
喇叭和波形是代码画出来的，取消/时钟两个图标用的是 SF Symbols（系统自带，跟着 Apple 的条款）。
`edge-tts` 是第三方项目，走它自己的许可；ElevenLabs 是付费服务，用之前看它的条款。
