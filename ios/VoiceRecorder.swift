import AVFoundation
import Speech
import SwiftUI

/// 录一段语音：点话筒开录 → 输入框上面出来一条「跳动的点 + 波形 + 计时 + 取消 + 完成」
/// → 点完成停录并发出去。**不是按住说话**，是点一下开、再点一下停。
///
/// 转写走 `SFSpeechRecognizer`，而且是**录完再对文件转一遍**，不是边说边听写：
/// 实时听写要 AVAudioEngine 挂 tap，跟 AVAudioRecorder 抢同一个 audio session，
/// 录完再转只多等一两秒，稳得多。
///
/// ⚠️ 转写这一步是**必须的**，不是锦上添花 —— 模型读不了音频，
/// 没有文字的话对面收到的就只是一个 `[voice · 0:05]` 空壳。
@MainActor
final class VoiceRecorder: NSObject, ObservableObject {

    /// 波形几根
    static let bars = 40
    /// 一条语音最长两分钟，到点自动收 —— 后端那边 12MB 的闸远比这个宽松，
    /// 但录了十分钟才发现忘了停是最糟的体验。
    static let maxSeconds = 120

    @Published private(set) var isRecording = false
    @Published private(set) var elapsed = 0
    @Published private(set) var levels: [CGFloat] = Array(repeating: 0, count: bars)
    /// 停下之后在转写 / 上传，这段时间话筒键按不动
    @Published private(set) var busy = false
    /// 没给麦克风权限。界面上要说人话，不能默默什么都不发生
    @Published var deniedMessage: String?

    private var recorder: AVAudioRecorder?
    private var ticker: Task<Void, Never>?
    private var fileURL: URL?

    // MARK: - 开录

    func start() async {
        guard !isRecording, !busy else { return }

        guard await Self.askMic() else {
            deniedMessage = "没有麦克风权限。到「设置 → 本 App → 麦克风」打开就能录了。"
            return
        }

        // 顺手把听写权限也一起要了。⚠️ 别等到 finish() 再问 ——
        // 那会儿录都录完了才弹窗，第一条语音必然转写不出来（模型看不懂音频，
        // 结果就是对面收到一个空的 `[voice · 0:05]`）。这里问，用户拒绝也不挡录音。
        _ = await Self.askSpeech()

        // ⚠️ **第一次**开录经常起不来，再点一次才行 —— 2026-08-06 实测两种触发：
        //   · 刚点完「允许」那一下（音频硬件还没交接完）
        //   · App 刚启动后的第一次（session 还没热，权限早就有也一样）
        // 两次的日志都是 `HALC_ProxyObject::SetPropertyData ('guse','inpt')
        // got an error from the server`。表现完全一样：点了毫无反应。
        // 所以重试不设条件 —— 失败就等一下重来一次，代价只有 300ms。
        var started = beginCapture()
        if !started {
            try? await Task.sleep(for: .milliseconds(300))
            started = beginCapture()
        }
        guard started else {
            deniedMessage = "录音起不来了，再点一次试试。"
            return
        }

        elapsed = 0
        levels = Array(repeating: 0, count: Self.bars)
        isRecording = true
        startTicking()
    }

    /// 开音频链路 + 起录音机。成功返回 true。
    private func beginCapture() -> Bool {
        let session = AVAudioSession.sharedInstance()
        do {
            // .default 模式下 iPhone 会用降噪后的语音链路，正好是我们要的
            try session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker])
            try session.setActive(true)
        } catch {
            // 打出来。不打的话「点了没反应」在日志里一点痕迹都没有
            print("[voice] 开不了 session: \(error)")
            return false
        }

        // m4a/AAC：后端 AUDIO_EXTENSIONS 收，体积也比 WAV 小一个量级
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("voice-\(UUID().uuidString).m4a")
        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
            AVSampleRateKey: 44100,
            AVNumberOfChannelsKey: 1,
            AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue,
        ]
        guard let rec = try? AVAudioRecorder(url: url, settings: settings) else { return false }
        rec.isMeteringEnabled = true                    // 波形要靠它取电平
        guard rec.record() else { return false }

        recorder = rec
        fileURL = url
        return true
    }

    /// 每 80ms 取一次电平往波形里推，正好对上波形条 .08s 的过渡。
    private func startTicking() {
        ticker?.cancel()
        ticker = Task { [weak self] in
            var frames = 0
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(80))
                guard let self, self.isRecording, let rec = self.recorder else { return }
                rec.updateMeters()
                // dBFS（-160…0）压到 0…1。-50dB 以下当静音 —— 直接线性映射的话
                // 环境底噪就能把波形顶到一半高，看着像一直在说话。
                let db = max(-50, rec.averagePower(forChannel: 0))
                let level = CGFloat(pow(10, db / 20))
                self.levels.removeFirst()
                self.levels.append(min(1, level * 1.6))
                frames += 1
                if frames % 12 == 0 {                   // 约每秒
                    self.elapsed = Int(rec.currentTime)
                    if self.elapsed >= Self.maxSeconds { _ = await self.finish(); return }
                }
            }
        }
    }

    // MARK: - 停

    /// 录完的一段。`transcript` 可能是空的 —— 没听清也照样发得出去，
    /// 兜住就行（对面只是少看到一行字，仍然听得见）。
    struct Take {
        var url: URL
        var duration: Int
        var transcript: String
        /// 本机量出来的那行 `[语气 · 轻声 · 句尾往上扬]`，量不出东西就是空串。
        /// 转写给的是「说了什么」，这行给的是「怎么说的」—— 见 `VoiceProsody`。
        var prosody: String = ""
    }

    /// 停下、转写、量语气，把这一段交出去。取消录音走 `cancel()`。
    func finish() async -> Take? {
        guard isRecording, let rec = recorder, let url = fileURL else { return nil }
        let seconds = max(1, Int(rec.currentTime.rounded()))
        stopEngine()

        busy = true
        defer { busy = false }
        // 两件事互不相干，一起跑：听写走 Speech 框架，语气分析在后台线程啃 PCM，
        // 串行的话用户要多等一截才看到消息发出去
        async let words = Self.transcribe(url)
        async let tone = VoiceProsody.measure(url)
        let text = await words
        let prosody = await tone?.describe(transcript: text) ?? ""
        return Take(url: url, duration: seconds, transcript: text, prosody: prosody)
    }

    func cancel() {
        let url = fileURL
        stopEngine()
        if let url { try? FileManager.default.removeItem(at: url) }
    }

    private func stopEngine() {
        ticker?.cancel(); ticker = nil
        recorder?.stop(); recorder = nil
        isRecording = false
        levels = Array(repeating: 0, count: Self.bars)
        // 录完把 session 还回去，不然放音乐 / 播语音条会被压成听筒音量
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    /// 录完的那条清完了就删，临时目录别越攒越大
    func discard(_ take: Take) { try? FileManager.default.removeItem(at: take.url) }

    // MARK: - 权限 & 转写

    private static func askMic() async -> Bool {
        await withCheckedContinuation { c in
            AVAudioApplication.requestRecordPermission { c.resume(returning: $0) }
        }
    }

    private static func askSpeech() async -> Bool {
        await withCheckedContinuation { c in
            SFSpeechRecognizer.requestAuthorization { c.resume(returning: $0 == .authorized) }
        }
    }

    /// 对着录好的文件转一遍。听不出来就返回空串 —— 转写失败不该拦住发送。
    ///
    /// ⚠️ 优先设备本机识别：私下说的话能不出这台手机就不出去。
    /// 只有本机模型没装（`supportsOnDeviceRecognition == false`）才退回
    /// Apple 的在线识别 —— 浏览器里的 `webkitSpeechRecognition` 在 iOS 上
    /// 走的也是这条，不比它差。
    private static func transcribe(_ url: URL) async -> String {
        guard await askSpeech() else { return "" }
        // 简体中文优先；没有就跟随系统
        let rec = SFSpeechRecognizer(locale: Locale(identifier: "zh-CN")) ?? SFSpeechRecognizer()
        guard let rec, rec.isAvailable else { return "" }

        let req = SFSpeechURLRecognitionRequest(url: url)
        req.shouldReportPartialResults = false
        req.requiresOnDeviceRecognition = rec.supportsOnDeviceRecognition

        return await withCheckedContinuation { c in
            // 只允许回一次 —— 识别回调在出错时可能既给结果又给错误
            let once = OnceBox(c)
            rec.recognitionTask(with: req) { result, error in
                if let result, result.isFinal {
                    once.resume(result.bestTranscription.formattedString
                        .trimmingCharacters(in: .whitespacesAndNewlines))
                } else if error != nil {
                    once.resume("")
                }
            }
        }
    }
}

/// `withCheckedContinuation` 恢复两次会直接崩，识别回调又不保证只来一次。
private final class OnceBox: @unchecked Sendable {
    private var c: CheckedContinuation<String, Never>?
    private let lock = NSLock()

    init(_ c: CheckedContinuation<String, Never>) { self.c = c }

    func resume(_ value: String) {
        lock.lock()
        let pending = c
        c = nil
        lock.unlock()
        pending?.resume(returning: value)
    }
}
