import AVFoundation
import SwiftUI
import UIKit

// MARK: - 录音条
//
// 一颗跳动的点 + 40 根波形 + 计时 + 取消 + 完成。
// 摆在输入框上面那一条（输入行之上、附件预览之下）。
//
// 不是「按住说话」：点一下开录，再点一下停并发出去。

/// 录音条的两处颜色。默认取 `VoiceKit.style`，那边建议配成
/// 「输入框底色再深一号」而不是钉一个跟环境无关的色。
enum Voce {
    static var accent: Color { VoiceKit.style.accent }
    /// 压在强调色上面的方块 / 图标
    static var onAccent: Color { VoiceKit.style.onAccent }
}

struct RecordingStrip: View {
    @ObservedObject var recorder: VoiceRecorder
    let onCancel: () -> Void
    let onStop: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            PulsingDot()
            waveform
            Text(timeText)
                .font(.system(size: 13).monospacedDigit())   // tabular-nums
                .foregroundStyle(VoiceKit.style.ink.opacity(0.62))
                .frame(minWidth: 36, alignment: .trailing)

            // 取消：灰底一个叉
            Button(action: onCancel) {
                Image(systemName: "xmark").font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(VoiceKit.style.ink.opacity(0.62))
                    .frame(width: 32, height: 32)
                    .background(Circle().fill(VoiceKit.style.sunken))
                    .contentShape(Circle())
            }
            .buttonStyle(FadeStyle())

            // 完成：强调色底 + 一个方块。震动反馈在 `onStop` 里边（见
            // 宿主的「停止录音」入口）—— 话筒键停录走的是同一条路，两处一起有。
            Button(action: onStop) {
                RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                    .fill(Voce.onAccent)
                    .frame(width: 12, height: 12)
                    .frame(width: 32, height: 32)
                    .background(Circle().fill(Voce.accent))
                    .contentShape(Circle())
            }
            .buttonStyle(FadeStyle())
        }
        .padding(.top, 6)
        .padding(.horizontal, 2)
        .padding(.bottom, 8)
    }

    /// 波形：等宽的一排竖条，高度跟电平走
    private var waveform: some View {
        GeometryReader { geo in
            let n = recorder.levels.count
            // gap:2px，每根 max-width:3px
            let gap: CGFloat = 2
            let w = min(3, max(1, (geo.size.width - gap * CGFloat(n - 1)) / CGFloat(n)))
            HStack(alignment: .center, spacing: gap) {
                ForEach(Array(recorder.levels.enumerated()), id: \.offset) { _, level in
                    Capsule()
                        .fill(Voce.accent)
                        .frame(width: w, height: max(3, level * geo.size.height))
                }
            }
            .frame(width: geo.size.width, height: geo.size.height, alignment: .center)
            .animation(.easeOut(duration: 0.08), value: recorder.levels)   // transition:.08s
        }
        .frame(height: 28)
        .frame(maxWidth: .infinity)                    // flex:1
    }

    private var timeText: String {
        String(format: "%d:%02d", recorder.elapsed / 60, recorder.elapsed % 60)
    }
}

/// 录音中那颗一呼一吸的点
struct PulsingDot: View {
    @State private var on = false

    var body: some View {
        Circle()
            .fill(Voce.accent)
            .frame(width: 9, height: 9)
            .scaleEffect(on ? 0.85 : 1)
            .opacity(on ? 0.35 : 1)
            .animation(.easeInOut(duration: 0.5).repeatForever(autoreverses: true), value: on)
            .onAppear { on = true }
    }
}

// MARK: - 语音气泡
//
// 微信那种一条 [ 时长 · 喇叭 ]，点一下播放，长按看转写。
// 自己那条喇叭在右、口朝左；对方那条喇叭在左、口朝右。

/// 从正文里认出 `[voice · 0:05 · happy] 转写文字`。
///
/// 时长那一格是可选的 —— 对方发来的语音只写 `[voice] 说的话`，
/// 声音是 App 现合成的（见 `VoiceSpeech`），时长要合成完才知道。
struct VoiceMarker {
    var duration: Int
    var emotion: String
    var transcript: String
    /// 正文最后那行 `[语气 · 轻声 · 句尾往上扬]` 里的内容（已去掉方括号和前缀）。
    /// 由 `VoiceProsody` 在本机量出来，跟转写一起发给模型（怎么拼见 README）。
    ///
    /// ⚠️ 这行**故意不在界面上显示**，但照旧要拆出来：不拆的话它会混进转写里，
    /// 长按展开就多一行方括号。给模型的正文里仍然留着 —— 「尾音还翘上去」那种
    /// 回应就是靠它。拆掉的是显示，不是这条信道。
    var prosody: String = ""

    static func parse(_ raw: String) -> VoiceMarker? {
        // 标记前面可能有空行/空格（模型偶尔会先空一行才写）。不剃掉的话 `^` 认不出来，
        // 用户看到的就是一条写着「[voice] …」的普通气泡。
        let text = String(raw.drop { $0.isWhitespace })
        // ^\[voice(?:\s*·\s*(\d+:\d+))?(?:\s*·\s*([a-z]+))?\]\s*
        let pattern = #"^\[voice(?:\s*·\s*(\d+:\d+))?(?:\s*·\s*([a-z]+))?\]\s*"#
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
              let m = re.firstMatch(in: text, range: NSRange(text.startIndex..., in: text))
        else { return nil }

        func group(_ i: Int) -> String {
            guard let r = Range(m.range(at: i), in: text) else { return "" }
            return String(text[r])
        }
        let clock = group(1).split(separator: ":").compactMap { Int($0) }
        let seconds = clock.count == 2 ? clock[0] * 60 + clock[1] : 0
        var rest = Range(m.range, in: text).map { String(text[$0.upperBound...]) } ?? ""

        // 语气那行拆出来单独放，不然它会混进转写里一起显示
        var prosody = ""
        if let r = rest.range(of: #"\n?\[语气[^\]]*\]\s*$"#, options: [.regularExpression]) {
            prosody = String(rest[r])
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .replacingOccurrences(of: #"^\[语气\s*·?\s*"#, with: "", options: [.regularExpression])
                .replacingOccurrences(of: "]", with: "")
            rest.removeSubrange(r)
        }

        return VoiceMarker(duration: seconds,
                           emotion: group(2).lowercased(),
                           transcript: rest.trimmingCharacters(in: .whitespacesAndNewlines),
                           prosody: prosody)
    }
}

struct VoiceBubble: View {
    let marker: VoiceMarker
    /// 声音从哪儿来：自己那条是服务器上存着的 m4a，对方那条是正文现合成的。
    /// nil = 只有一条标记没有音频（历史里附件丢了），点了不响，但转写照看。
    let audio: VoiceAudio?
    let mine: Bool
    /// 语音行不挂整行的 `.contextMenu` —— 那个会把语音条的长按整个吃掉，
    /// 长按就只剩 Copy、转不出文字。复制/删除/重来改挂在展开的转写上。
    var onCopy: (() -> Void)?
    var onDelete: (() -> Void)?
    var onRetry: (() -> Void)?
    /// 气泡顶上那行小灰字（思考链摘要）。跟文字气泡一样长在**气泡里面**，
    /// 不是气泡外面单摆一个。
    var summary: String?
    var onSummaryTap: (() -> Void)?

    @StateObject private var player = VoicePlayer()
    /// 长按展开转写
    @State private var showText = false

    var body: some View {
        VStack(alignment: mine ? .trailing : .leading, spacing: 6) {
            bar
            if showText, !marker.transcript.isEmpty {
                transcriptBlock
            }
        }
        .frame(maxWidth: 240, alignment: mine ? .trailing : .leading)
        // 对方那条的声音是现合成的，时长要等合成完才知道。本地已经存过就当场量出来，
        // 气泡一出现宽度就是对的，不用先按字数估一个再跳一下。
        .task(id: audio) { await player.prepare(audio) }
    }

    /// 展开的那块。只有转写 —— 本机量出来的那行语气不在这儿显示（它是给模型看的）。
    private var transcriptBlock: some View {
        Text(marker.transcript)
            .font(.system(size: VoiceKit.style.textSize, design: .serif))
            .lineSpacing(VoiceKit.style.textSize * 0.45)                        // line-height:1.45
            .foregroundStyle(VoiceKit.style.ink)
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .frame(maxWidth: 240, alignment: .leading)
            .background(BubbleShape(mine: mine).fill(VoiceKit.style.bubble(mine: mine)))
            .contextMenu {
                if let onCopy {
                    Button(action: onCopy) { Label("Copy", systemImage: "doc.on.doc") }
                }
                if let onDelete {
                    Button(role: .destructive, action: onDelete) {
                        Label("Delete", systemImage: "trash")
                    }
                }
                if let onRetry {
                    Button(action: onRetry) {
                        Label("Renovate", systemImage: "arrow.counterclockwise")
                    }
                }
            }
    }

    /// 语音条本体：高 40，宽度跟时长走，圆角同文字气泡。
    /// 有思考链摘要时那行小灰字也装在这个气泡里，喇叭那行落到它下面。
    private var bar: some View {
        VStack(alignment: mine ? .trailing : .leading, spacing: 6) {
            if let summary {
                if let onSummaryTap {
                    Button(action: onSummaryTap) { statusLine(summary) }
                        .buttonStyle(FadeStyle())
                } else {
                    statusLine(summary)
                }
            }
            speakerRow
        }
        .padding(.horizontal, 14)
        // 只有喇叭那行时靠 40 的定高撑着（跟文字气泡的单行高对齐）；
        // 多了摘要那行就改成上下各 10 的内边距，跟文字气泡一个数
        .padding(.vertical, summary == nil ? 0 : 10)
        .frame(minHeight: summary == nil ? 40 : 0)
        // ⚠️ 两处都不能省：
        // · minWidth 不是 width —— 算出来的宽度只当**下限**，内容撑不下时自己长开。
        //   写死 width 的话 `3"` 那种短条装不下数字，会折成上下两截。
        // · alignment 不能用默认的 .center —— 默认居中时内容会浮在气泡正中间，
        //   两边各空一大块。对方的贴左、自己的贴右，离边一个 padding（14pt，
        //   正好一个字的宽度）。
        .frame(minWidth: Self.width(seconds), alignment: mine ? .trailing : .leading)
        .background(
            BubbleShape(mine: mine)
                .fill(VoiceKit.style.bubble(mine: mine))
                .shadow(color: VoiceKit.style.bubbleShadow, radius: VoiceKit.style.shadowRadius, y: 1)
        )
        .contentShape(BubbleShape(mine: mine))
        .onTapGesture { toggle() }
        // 长按 420ms 展开转写，并轻震一下
        .onLongPressGesture(minimumDuration: 0.42) {
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            withAnimation(.easeOut(duration: 0.15)) { showText.toggle() }
        }
    }

    /// 喇叭 + 秒数那一行。我方喇叭在右口朝左，对方在左口朝右。
    private var speakerRow: some View {
        HStack(spacing: 8) {
            if mine {
                Text(durationText)
                // 喇叭跟着气泡字色走，不是钉死的主文字色 —— 用户把字色调浅之后，
                // 钉死的喇叭会突兀地黑一块
                speaker(flip: true)
            } else {
                speaker(flip: false)
                Text(durationText)
            }
        }
        // 秒数：15px，中等字重，等宽数字
        .font(.system(size: 15, weight: .medium).monospacedDigit())
        .lineLimit(1)
        .fixedSize()
        .foregroundStyle(VoiceKit.style.ink)
    }

    /// 跟文字气泡里那行一模一样：钟 + 一行小灰字。
    /// ⚠️ 这儿不能像文字气泡那样塞 `Spacer(minLength: 0)` 把它撑满 ——
    /// 语音气泡的宽度就是这行字撑出来的，撑满等于让它自己跟自己较劲。
    private func statusLine(_ text: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "clock").font(.system(size: 13))
            Text(text)
                .font(.system(size: 13))
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .foregroundStyle(VoiceKit.style.ink.opacity(0.62))
        .contentShape(Rectangle())
    }

    /// 喇叭那一格。对方那条第一次点要等服务端合成（热着 2~4 秒），
    /// 那段时间摆个转圈的 —— 不然点下去一点动静都没有，像是坏了。
    @ViewBuilder
    private func speaker(flip: Bool) -> some View {
        if player.loading {
            ProgressView()
                .controlSize(.mini)
                .tint(VoiceKit.style.ink)
                .frame(width: 18, height: 18)                          // 同喇叭那格
        } else {
            Speaker(flip: flip, playing: player.isPlaying, tint: VoiceKit.style.ink)
        }
    }

    /// 宽度：56 + 4×秒，最多 180
    static func width(_ seconds: Int) -> CGFloat {
        min(56 + CGFloat(max(1, seconds)) * 4, 180)
    }

    /// 显示多少秒。自己那条录的时候就知道；对方那条要么已经合成过（真实时长），
    /// 要么先按字数估一个 —— 估歪了只影响这一下的宽度，合成完就盖掉。
    private var seconds: Int {
        if marker.duration > 0 { return marker.duration }
        return player.measured ?? Self.estimate(marker.transcript)
    }

    /// edge-tts 那把中文声音（云健 -6%）实测每秒 4~5 个字，取 4.5。
    static func estimate(_ text: String) -> Int {
        let n = text.filter { !$0.isWhitespace }.count
        return max(1, Int((Double(n) / 4.5).rounded()))
    }

    /// 微信那样只写秒数加一个引号
    private var durationText: String { "\(max(1, seconds))\"" }

    private func toggle() {
        guard let audio else { return }
        Task { await player.toggle(audio) }
    }
}

/// 喇叭：三道弧，播放时依次闪。
struct Speaker: View {
    let flip: Bool
    let playing: Bool
    var tint: Color = VoiceKit.style.ink

    /// 三道弧，坐标按 24×24 画，渲染时等比缩到实际尺寸。
    /// 起点 / 两个控制点 / 终点，从里到外一道比一道张得开。
    private static let arcs: [(CGPoint, CGPoint, CGPoint, CGPoint)] = [
        (CGPoint(x: 11, y: 9.5), CGPoint(x: 12.2, y: 10.4), CGPoint(x: 12.2, y: 13.6), CGPoint(x: 11, y: 14.5)),
        (CGPoint(x: 14, y: 7.2), CGPoint(x: 16.2, y: 8.8), CGPoint(x: 16.2, y: 15.1), CGPoint(x: 14, y: 16.8)),
        (CGPoint(x: 17, y: 5.0), CGPoint(x: 20.3, y: 7.4), CGPoint(x: 20.3, y: 16.6), CGPoint(x: 17, y: 19.0)),
    ]

    // ⚠️ 这里必须是 TimelineView，不能用 `withAnimation` 推一个 phase。
    // 透明度是在 body 里**算**出来的（`arcOpacity`），SwiftUI 只对可动画的视图属性
    // 做插值，不会因为某个 @State 在动就反复重算 body —— 那种写法 body 只会拿
    // 最终值跑一次，三道弧从头到尾定死不动，而且 phase 播完不归零，第二次点更没反应。
    // TimelineView(.animation) 是按帧驱动重算，正好对上「1s 一轮、无限循环」。
    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: !playing)) { ctx in
            let t = ctx.date.timeIntervalSinceReferenceDate
            ZStack {
                ForEach(Array(Self.arcs.enumerated()), id: \.offset) { i, arc in
                    Arc(arc: arc)
                        .stroke(tint, style: StrokeStyle(lineWidth: 1.8, lineCap: .round))
                        .opacity(playing ? Self.arcOpacity(i, at: t) : 1)
                }
            }
        }
        .frame(width: 18, height: 18)
        .scaleEffect(x: flip ? -1 : 1)                                 // 自己发的那条喇叭口朝左
    }

    private struct Arc: Shape {
        let arc: (CGPoint, CGPoint, CGPoint, CGPoint)

        func path(in rect: CGRect) -> Path {
            let k = min(rect.width, rect.height) / 24
            func p(_ q: CGPoint) -> CGPoint { CGPoint(x: q.x * k, y: q.y * k) }
            var path = Path()
            path.move(to: p(arc.0))
            path.addCurve(to: p(arc.3), control1: p(arc.1), control2: p(arc.2))
            return path
        }
    }

    /// 一轮 1 秒：透明度 .25 →（40%）1 →（60% 起）落回 .25，ease-in-out。
    /// 三道弧依次错开 0 / .15s / .3s，所以是 `t - i*.15`。
    private static func arcOpacity(_ i: Int, at t: Double) -> Double {
        var x = (t - Double(i) * 0.15).truncatingRemainder(dividingBy: 1)
        if x < 0 { x += 1 }
        let level: Double
        if x < 0.4 { level = x / 0.4 }                 // 0% → 40%：.25 爬到 1
        else if x < 0.6 { level = 1 }                  // 40% → 60%：顶住
        else { level = 1 - (x - 0.6) / 0.4 }           // 60% → 100%：落回 .25
        let eased = level * level * (3 - 2 * level)    // ease-in-out
        return 0.25 + 0.75 * eased
    }
}

/// 一条语音条的声音打哪儿来。
enum VoiceAudio: Equatable, Hashable {
    /// 自己录的那段。服务器上存着，取回来直接放。
    case stored(StoredVoice)
    /// 对方说的那句。App 拿正文找服务端合成（`POST /api/voice/tts`），
    /// 合出来的落盘存着，同一句话一辈子只合成一次。
    case spoken(String)
}

/// 语音条的播放。一次只让一条在响 —— 点第二条时第一条自己停。
@MainActor
final class VoicePlayer: NSObject, ObservableObject, AVAudioPlayerDelegate {
    @Published private(set) var isPlaying = false
    /// 正在取音频（对方那条第一次点要等服务端合成）。界面上是喇叭位置转个圈。
    @Published private(set) var loading = false
    /// 音频真实时长（秒）。自己那条录的时候就知道，用不上这个；
    /// 对方那条只有合成出来（或本地存过）才量得到。
    @Published private(set) var measured: Int?

    private var player: AVAudioPlayer?
    /// 当前在响的那个。换一条时先把上一条按停
    private static weak var active: VoicePlayer?

    /// 气泡一出现调一次：**只**在本地已经有音频时量个时长，不主动去合成。
    /// 翻历史时不该因为滚过几十条语音就往服务器打几十发合成请求。
    func prepare(_ audio: VoiceAudio?) async {
        guard measured == nil, case .spoken(let text)? = audio,
              let url = await VoiceSpeech.shared.cached(text),
              let data = try? Data(contentsOf: url),
              let probe = try? AVAudioPlayer(data: data)
        else { return }
        measured = max(1, Int(probe.duration.rounded()))
    }

    func toggle(_ audio: VoiceAudio) async {
        if isPlaying { stop(); return }
        Self.active?.stop()

        loading = true
        let data = await Self.data(for: audio)
        loading = false
        guard let data else { return }

        // 录音时把 session 切成了 playAndRecord，放的时候切回来，
        // 不然声音会从听筒出、小得几乎听不见
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .default)
        try? AVAudioSession.sharedInstance().setActive(true)

        guard let p = try? AVAudioPlayer(data: data) else { return }
        p.delegate = self
        player = p
        measured = max(1, Int(p.duration.rounded()))
        p.play()
        isPlaying = true
        Self.active = self
    }

    private static func data(for audio: VoiceAudio) async -> Data? {
        switch audio {
        case .stored(let att):
            return await VoiceKit.backend.storedAudio(att)
        case .spoken(let text):
            guard let url = await VoiceSpeech.shared.audio(for: text) else { return nil }
            return try? Data(contentsOf: url)
        }
    }

    func stop() {
        player?.stop()
        player = nil
        isPlaying = false
        if Self.active === self { Self.active = nil }
    }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in self.stop() }
    }
}

// MARK: - 对方那边的声音
//
// 对方的语音条正文是 `[voice] 说的话`，没有音频文件 —— 声音是 App 拿这句话去
// 服务端现合成的（`POST /api/voice/tts`，几档合成方式见 server/voice_service.py）。
//
// 为什么不在服务端合成好存成附件：那要动流式落库那条路，是最容易出事的一段；
// 而合成本身是纯函数（同一句话永远是同一段声音），放客户端缓存一样只算一次。
//
// ⚠️ 别改成「气泡一出现就预热」。翻历史滚过几十条语音就是几十发合成请求，
// 服务端那头多半是串行的。只把**刚收到的那条**提前热上（回复流结束时调
// `VoiceSpeech.shared.audio(for:)` 就行）。

/// 对方说的话 → 一个音频文件。同一句话只合成一次，落盘存着。
///
/// 放 Application Support 而不是 Caches：
/// 系统清 Caches 的时候不会打招呼，清掉之后每条老语音都要重新等 3 秒才响。
/// 代价是要自己管上限，见 `prune()`。
actor VoiceSpeech {
    static let shared = VoiceSpeech()

    /// 存多少条。一条几十 KB，300 条也就十几兆。
    private static let keep = 300

    private let directory: URL = {
        let root = FileManager.default.urls(for: .applicationSupportDirectory,
                                            in: .userDomainMask)[0]
        let dir = root
            .appendingPathComponent("VoiceKit", isDirectory: true)
            .appendingPathComponent("Voice", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    /// 同一句话正在合成的那一发。用户连点两下不该打两趟。
    private var inflight: [String: Task<URL?, Never>] = [:]

    /// 本地存过的那份。没有就 nil —— 调用方据此决定要不要显示真实时长。
    func cached(_ text: String) -> URL? {
        let url = file(for: text)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    /// 要声音。本地有就直接给；没有就去合成（热着 2~4 秒，冷启动能到半分钟）。
    @discardableResult
    func audio(for text: String) async -> URL? {
        let key = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return nil }
        if let hit = cached(key) { return hit }
        if let running = inflight[key] { return await running.value }

        let url = file(for: key)
        let task = Task<URL?, Never> {
            guard let data = await VoiceKit.backend.synthesize(key) else { return nil }
            do { try data.write(to: url, options: .atomic) } catch { return nil }
            return url
        }
        inflight[key] = task
        let out = await task.value
        inflight[key] = nil
        if out != nil { prune() }
        return out
    }

    /// 存盘名。djb2 + 长度，够分辨了（见 `VoiceKit.hash`）。
    /// 后缀写 mp3 只是给人看的 —— 播放走 `AVAudioPlayer(data:)`，它自己认格式，
    /// 服务端掉到本机 `say` 那档给的其实是 m4a，照样放得出来。
    private func file(for text: String) -> URL {
        directory.appendingPathComponent(VoiceKit.hash(text)).appendingPathExtension("mp3")
    }

    /// 超了就把最老的几条扔掉。按修改时间排 —— 常听的那几条会被 `audio()` 重新写吗？
    /// 不会，命中缓存直接返回。所以这里等于「按合成先后」淘汰，正是想要的。
    private func prune() {
        let keys: [URLResourceKey] = [.contentModificationDateKey]
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: keys
        ), files.count > Self.keep else { return }

        let sorted = files.sorted {
            let a = (try? $0.resourceValues(forKeys: Set(keys)))?.contentModificationDate ?? .distantPast
            let b = (try? $1.resourceValues(forKeys: Set(keys)))?.contentModificationDate ?? .distantPast
            return a < b
        }
        for old in sorted.prefix(files.count - Self.keep) {
            try? FileManager.default.removeItem(at: old)
        }
    }
}
