import SwiftUI

/// 语音条要从宿主 App 借的东西，全在这一个文件里：配色、气泡形状、两个网络回调。
///
/// 搬进你自己的工程之后**只改这个文件**就够了，另外三个（VoiceMessage / VoiceRecorder /
/// VoiceProsody）可以原样放着不动。
///
/// ```swift
/// // App 启动时配一次
/// VoiceKit.style.accent = Color("我的强调色")
/// VoiceKit.backend.storedAudio = { voice in await MyAPI.download(voice.path) }
/// VoiceKit.backend.synthesize  = { text in await MyAPI.tts(text) }
/// ```
enum VoiceKit {

    // MARK: - 外观

    /// 一整套颜色和尺寸。默认值是一套中性的浅色，照着你自己的气泡改。
    struct Style {
        /// 正文字色。喇叭、秒数、转写都跟着它走
        var ink = Color(red: 0.125, green: 0.122, blue: 0.114)
        /// 录音条上的强调色：跳动的点、波形、完成键。
        /// 建议取**输入框底色再深一号**，而不是钉一个跟环境无关的颜色 ——
        /// 用户把界面调成别的色系之后，钉死的那个就是一处杂色。
        var accent = Color(red: 0.55, green: 0.66, blue: 0.75)
        /// 压在强调色上面的方块 / 图标。跟字色走，浅底深色、深底浅色都看得见
        var onAccent = Color(red: 0.125, green: 0.122, blue: 0.114)
        /// 取消键那个灰底
        var sunken = Color.black.opacity(0.06)
        /// 自己发的气泡底色
        var mineBubble = Color(red: 0.83, green: 0.88, blue: 0.93)
        /// 对方气泡底色
        var theirBubble = Color.white
        var bubbleShadow = Color.black.opacity(0.05)
        var shadowRadius: CGFloat = 6
        /// 转写展开之后的正文字号
        var textSize: CGFloat = 16
        /// 气泡圆角，以及贴着头像那一角收窄成多少（微信那种小尖角）
        var bubbleRound: CGFloat = 18
        var bubbleTip: CGFloat = 6

        func bubble(mine: Bool) -> Color { mine ? mineBubble : theirBubble }
    }

    /// ⚠️ 启动时配一次就别再动了：这几个值在渲染路径上被随手读，
    /// 运行中改不会触发 SwiftUI 刷新（真要能跟着变，把 Style 挂到你自己的
    /// ObservableObject 上，然后在这儿转发）。
    nonisolated(unsafe) static var style = Style()

    // MARK: - 后端

    /// 语音条只需要外界给两样东西。两个都返回音频**原始字节**
    /// （m4a / mp3 都行，AVAudioPlayer 自己认格式），拿不到就回 nil。
    struct Backend {
        /// 取一段已经存在服务器上的录音 —— 用户自己发出去的那条。
        var storedAudio: (StoredVoice) async -> Data? = { _ in nil }
        /// 把一句话念出来 —— 对方那条语音。对应 `server/voice_service.py`
        /// 里的 `POST /api/voice/tts`。
        var synthesize: (String) async -> Data? = { _ in nil }
    }

    nonisolated(unsafe) static var backend = Backend()

    /// djb2。只用来给合成结果起一个稳定的文件名，不是安全用途。
    static func hash(_ s: String) -> String {
        var h: Int32 = 5381
        for u in s.unicodeScalars {
            for unit in String(u).utf16 { h = (h << 5) &+ h &+ Int32(unit) }
        }
        return "v" + String(UInt32(bitPattern: h), radix: 36) + "_" + String(s.utf16.count)
    }
}

/// 服务器上那段录音的地址。你的工程里多半已经有个附件模型，
/// 把它映射成这个就行 —— 语音条只认 `path`，其余字段随你。
struct StoredVoice: Equatable, Hashable {
    /// 服务端认得的地址（例：`uploads/{会话}/{存盘名}`）
    var path: String
    /// 给人看的名字，可以为空
    var name: String = ""

    init(path: String, name: String = "") {
        self.path = path
        self.name = name
    }
}

/// 气泡形状：三个圆角 + 贴着头像那一角收成小尖。
/// 你要是已经有自己的气泡形状，把这个换掉就行。
struct BubbleShape: Shape {
    let mine: Bool

    func path(in rect: CGRect) -> Path {
        let tip = VoiceKit.style.bubbleTip, r = VoiceKit.style.bubbleRound
        return UnevenRoundedRectangle(
            topLeadingRadius: mine ? r : tip,
            bottomLeadingRadius: r,
            bottomTrailingRadius: r,
            topTrailingRadius: mine ? tip : r,
            style: .continuous
        ).path(in: rect)
    }
}

/// 按下去淡一档，不走系统那套变灰。
struct FadeStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.opacity(configuration.isPressed ? 0.62 : 1)
    }
}
