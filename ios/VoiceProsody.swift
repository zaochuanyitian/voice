import AVFoundation
import Foundation

/// 把一段录音「**怎么说的**」量出来。
///
/// 缘起：模型读不了音频。语音发过去，它手里只有一行 `[voice · 0:07] 转写文字` ——
/// 说了什么它知道，怎么说的一个字都没有。轻声还是提着嗓子、句尾往上翘还是往下沉、
/// 中间顿了几次，这些全丢在那个它打不开的 m4a 里。
///
/// 所以录完之后就地量一遍，把音量、语速、停顿、音高走向拼成一行附在转写后面。
/// **全部在本机算完**，不上传、不调任何服务 —— 人的声音本来就不该出这台手机。
///
/// ⚠️ 这里每一条都必须是真量出来的。宁可少说一条，也不能编 ——
/// 模型读到「句尾上扬」就会当真，会照着这个回话。
enum VoiceProsody {

    // 8kHz 单声道足够：人声基频 70–350Hz，奈奎斯特还有大把余量，
    // 而两分钟的音频降到 8k 才 96 万个采样点，自相关跑得动。
    private static let sr = 8000.0
    private static let energyFrame = 160          // 20ms 一格算音量
    private static let pitchWindow = 360          // 45ms 一窗算音高（最低 70Hz 也能装下 3 个周期）
    private static let pitchHop = 200             // 25ms 一步
    private static let lagMin = 23                // 8000/350 → 最高 350Hz
    private static let lagMax = 114               // 8000/70  → 最低 70Hz

    /// 量出来的原始数据。措辞留到 `describe` 里做 —— 语速要用到转写的字数，
    /// 那会儿听写还没回来，所以这一层只管数字。
    struct Metrics: Sendable {
        /// 去掉头尾静音之后真正在说话的时长
        var voicedSeconds: Double
        /// 有声段的平均电平（dBFS，负数，越接近 0 越响）
        var meanLevelDB: Double
        /// 话中间的那些停顿，每个的长度（秒）。头尾的静音不算
        var pauses: [Double]
        /// 基频中位数（Hz）。测不出来是 0
        var medianF0: Double
        /// 音高起伏，半音为单位的标准差
        var spreadSemitones: Double
        /// 句尾走向，半音。正数是往上扬
        var tailDeltaSemitones: Double
        /// 有多少帧测出了音高 —— 太少的话音高那几条结论不敢下
        var pitchPoints: Int
        /// 跟这个人平时比高了还是低了（半音）。攒够几条才有
        var baselineDeltaSemitones: Double?
        /// 跟这个人平时比轻了还是响了（dB）。攒够几条才有
        var baselineLevelDeltaDB: Double?
    }

    // MARK: - 入口

    /// 后台线程上量一遍。文件读不了 / 太短就回 nil，调用方当作没有这回事。
    static func measure(_ url: URL) async -> Metrics? {
        await Task.detached(priority: .userInitiated) { compute(url) }.value
    }

    // MARK: - 解码

    /// 解成 8kHz 单声道 Float。用 `AVAudioConverter` 而不是自己抽样 ——
    /// 44100→8000 不是整数倍，硬抽会混叠，混叠出来的假峰会被自相关当成基频。
    private static func decode(_ url: URL) -> [Float]? {
        guard let file = try? AVAudioFile(forReading: url) else { return nil }
        let inFormat = file.processingFormat
        guard file.length > 0,
              let outFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                            sampleRate: sr, channels: 1, interleaved: false),
              let converter = AVAudioConverter(from: inFormat, to: outFormat),
              let inBuf = AVAudioPCMBuffer(pcmFormat: inFormat,
                                           frameCapacity: AVAudioFrameCount(file.length))
        else { return nil }

        do { try file.read(into: inBuf) } catch { return nil }
        guard inBuf.frameLength > 0 else { return nil }

        let ratio = outFormat.sampleRate / inFormat.sampleRate
        let capacity = AVAudioFrameCount(Double(inBuf.frameLength) * ratio) + 4096
        guard let outBuf = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: capacity) else {
            return nil
        }

        var fed = false
        var err: NSError?
        converter.convert(to: outBuf, error: &err) { _, status in
            if fed { status.pointee = .endOfStream; return nil }
            fed = true
            status.pointee = .haveData
            return inBuf
        }
        guard err == nil, outBuf.frameLength > 0,
              let ch = outBuf.floatChannelData?[0] else { return nil }
        return Array(UnsafeBufferPointer(start: ch, count: Int(outBuf.frameLength)))
    }

    // MARK: - 主流程

    private static func compute(_ url: URL) -> Metrics? {
        guard let x = decode(url), x.count >= Int(sr * 0.4) else { return nil }

        // ── 音量包络 ──
        var db: [Double] = []
        db.reserveCapacity(x.count / energyFrame)
        var i = 0
        while i + energyFrame <= x.count {
            var sum = 0.0
            for k in i..<(i + energyFrame) {
                let v = Double(x[k])
                sum += v * v
            }
            db.append(20 * log10(max((sum / Double(energyFrame)).squareRoot(), 1e-7)))
            i += energyFrame
        }
        guard db.count >= 8 else { return nil }

        // 有声 / 静音的界。取 15 分位当底噪、97 分位当峰值 ——
        // 直接用 min/max 的话一声咳嗽或一下爆音就能把整条线拉歪。
        let sorted = db.sorted()
        let floorDB = sorted[Int(Double(sorted.count) * 0.15)]
        let peakDB = sorted[min(sorted.count - 1, Int(Double(sorted.count) * 0.97))]

        // ⚠️ 绝对静音闸，非有不可。上面那条界是**相对这条文件自己**取的，
        // 一段只录到房间底噪的音频照样能被切出「有声段」，然后一本正经地
        // 报「很轻，几乎是气声」—— 实测 1:29 那条空录音就是这么被算出 36 秒
        // 「说话」的。整条最响处都不到 -38dBFS，就是没人在说话，什么都别说。
        // （手上 16 条真实语音的平均电平在 -18.6 ~ -31.2 之间，这条线离得很远，误伤不了。）
        guard peakDB > -38 else { return nil }

        var threshold = max(floorDB + 8, peakDB - 28)
        threshold = min(threshold, peakDB - 6)

        let voiced = db.map { $0 > threshold }
        guard let first = voiced.firstIndex(of: true),
              let last = voiced.lastIndex(of: true), last > first else { return nil }

        let frameSec = Double(energyFrame) / sr
        let voicedCount = voiced[first...last].filter { $0 }.count
        let voicedSeconds = Double(voicedCount) * frameSec

        // 有声帧的平均电平。静音帧算进来的话，说得越少显得越轻
        var levelSum = 0.0
        for k in first...last where voiced[k] { levelSum += db[k] }
        let meanLevel = levelSum / Double(max(1, voicedCount))

        // 第二道闸：光看峰值不够。那条 1:29 的空录音里有几下碰撞声，峰值过得去，
        // 但「说话」的平均电平是 -56dB —— 纯底噪。真人说话没有这么轻的。
        guard meanLevel > -40, voicedSeconds >= 0.5 else { return nil }

        // ── 中间的停顿 ──（头尾的不算：那是按键前后的空档，不是在想话）
        var pauses: [Double] = []
        var run = 0
        for k in first...last {
            if voiced[k] {
                if run > 0 {
                    let seconds = Double(run) * frameSec
                    // 0.5s 起才算「顿」—— 中文的自然短语边界本来就有 0.3~0.4s 的空档
                    if seconds >= 0.50 { pauses.append(seconds) }
                    run = 0
                }
            } else {
                run += 1
            }
        }

        // ── 音高 ──
        let track = pitchTrack(x, voiced: voiced, frameSec: frameSec)
        var medianF0 = 0.0
        var spread = 0.0
        var tailDelta = 0.0
        if track.count >= 5 {
            medianF0 = median(track)
            let semis = track.map { 12 * log2($0 / medianF0) }
            let mean = semis.reduce(0, +) / Double(semis.count)
            spread = (semis.map { ($0 - mean) * ($0 - mean) }.reduce(0, +)
                      / Double(semis.count)).squareRoot()

            // 句尾：最后半秒（25ms 一步 → 20 个点）里，后一半比前一半高了多少
            if semis.count >= 8 {
                let tail = Array(semis.suffix(20))
                let half = tail.count / 2
                tailDelta = median(Array(tail[half...])) - median(Array(tail[..<half]))
            }
        }

        let baseline = Baseline.compare(f0: medianF0, level: meanLevel, points: track.count)
        return Metrics(
            voicedSeconds: voicedSeconds,
            meanLevelDB: meanLevel,
            pauses: pauses,
            medianF0: medianF0,
            spreadSemitones: spread,
            tailDeltaSemitones: tailDelta,
            pitchPoints: track.count,
            baselineDeltaSemitones: baseline.pitch,
            baselineLevelDeltaDB: baseline.level
        )
    }

    /// 逐窗自相关取基频。只在有声的地方算 —— 静音里算出来的全是噪声的假峰。
    private static func pitchTrack(_ x: [Float], voiced: [Bool], frameSec: Double) -> [Double] {
        let compare = pitchWindow - lagMax       // 各个 lag 用同样长的一段比，不然长 lag 天然吃亏
        var out: [Double] = []
        var start = 0
        while start + pitchWindow <= x.count {
            let frameIndex = Int((Double(start) / sr) / frameSec)
            guard frameIndex < voiced.count, voiced[frameIndex] else {
                start += pitchHop
                continue
            }

            // 归一化自相关：r(τ) = Σx[n]x[n+τ] / √(Σx[n]²·Σx[n+τ]²)
            var energy0 = 0.0
            for n in 0..<compare {
                let v = Double(x[start + n])
                energy0 += v * v
            }
            guard energy0 > 1e-9 else { start += pitchHop; continue }

            var best = 0.0
            var bestLag = 0
            var scores = [Double](repeating: 0, count: lagMax + 2)
            for lag in lagMin...lagMax {
                var dot = 0.0
                var energy = 0.0
                for n in 0..<compare {
                    let a = Double(x[start + n])
                    let b = Double(x[start + n + lag])
                    dot += a * b
                    energy += b * b
                }
                guard energy > 1e-9 else { continue }
                let r = dot / (energy0 * energy).squareRoot()
                scores[lag] = r
                if r > best { best = r; bestLag = lag }
            }

            // 0.45 以下当没测出来（清音、气声、噪声）
            if best >= 0.45, bestLag > 0 {
                // 取**最短**的那个够格的峰。自相关的经典错误是挑到 2τ，
                // 结果整条音高线低一个八度、句尾走向跟着反过来。
                // 必须同时是**局部极大**，否则会挑在爬坡的半路上，
                // 挑出一个根本不存在的高音，起伏就虚高了（实测能虚到 9 个半音）。
                var pick = bestLag
                for lag in (lagMin + 1)..<lagMax
                where scores[lag] >= best * 0.90
                    && scores[lag] >= scores[lag - 1]
                    && scores[lag] >= scores[lag + 1] {
                    pick = lag
                    break
                }
                out.append(sr / Double(pick))
            }
            start += pitchHop
        }
        return smooth(fixOctaves(out))
    }

    /// 把跳了八度的帧拉回来。挑错峰是逐帧独立发生的，单看一帧分不出对错，
    /// 但整段的中位数是可信的 —— 离中位数一个八度上下的，基本都是挑错了。
    private static func fixOctaves(_ v: [Double]) -> [Double] {
        guard v.count >= 3 else { return v }
        let center = median(v)
        guard center > 0 else { return v }
        return v.map { f in
            var x = f
            while x > center * 1.6 { x /= 2 }      // 高出 8 个半音以上
            while x < center * 0.62 { x *= 2 }
            return x
        }
    }

    /// 三点中值滤波。单帧的倍频错误就靠它抹掉。
    private static func smooth(_ v: [Double]) -> [Double] {
        guard v.count >= 3 else { return v }
        var out = v
        for i in 1..<(v.count - 1) {
            out[i] = [v[i - 1], v[i], v[i + 1]].sorted()[1]
        }
        return out
    }

    private static func median(_ v: [Double]) -> Double {
        guard !v.isEmpty else { return 0 }
        let s = v.sorted()
        return s.count % 2 == 1 ? s[s.count / 2] : (s[s.count / 2 - 1] + s[s.count / 2]) / 2
    }

    // MARK: - 「比平时」

    /// 一条语音里的绝对数值说明不了什么 —— 每个人嗓子不一样，
    /// 音量更是麦克风离嘴远近就能盖过一切（手上 16 条真实语音的平均电平
    /// 挤在 -18.6 ~ -31.2 这 12dB 里，拿死阈值切必然乱喊「轻声」）。
    /// 攒一条这个人自己的基线，才说得出「今天比平时低」。存在本机，就两个数。
    private enum Baseline {
        private static let f0Key = "voce.prosody.f0"
        private static let levelKey = "voce.prosody.level"
        private static let countKey = "voce.prosody.count"

        /// 跟基线比差多少；样本不够就先不说话，只默默攒。
        static func compare(f0: Double, level: Double, points: Int) -> (pitch: Double?, level: Double?) {
            guard f0 > 0, points >= 20 else { return (nil, nil) }
            let d = UserDefaults.standard
            let prevF0 = d.double(forKey: f0Key)
            let prevLevel = d.double(forKey: levelKey)      // dB，负数；0 表示还没有
            let count = d.integer(forKey: countKey)

            // 指数滑动平均，新的占四分之一 —— 感冒了压着嗓子说两天，
            // 基线跟着挪一点，但不会被一条彻底带跑
            d.set(prevF0 > 0 ? prevF0 * 0.75 + f0 * 0.25 : f0, forKey: f0Key)
            d.set(prevLevel < 0 ? prevLevel * 0.75 + level * 0.25 : level, forKey: levelKey)
            d.set(count + 1, forKey: countKey)

            // 头几条只攒不说：基线还没稳，这时候比出来的差是噪声
            guard count >= 5, prevF0 > 0, prevLevel < 0 else { return (nil, nil) }
            return (12 * log2(f0 / prevF0), level - prevLevel)
        }
    }
}

// MARK: - 措辞

extension VoiceProsody.Metrics {

    /// 拼成跟在正文后面那行 `[语气 · 轻声 · 句尾往上扬]`。
    /// 一条都没量出来（平平常常地说了句话）就回空串，那一行干脆不出现。
    ///
    /// 阈值都往保守了取：宁可不说，不能说错。每一条的界都是拿真实
    /// 那 16 条真实语音的分布卡出来的，让每个说法都**罕见**——
    /// 一开口就跳出四个标签，等于什么都没说。
    func describe(transcript: String) -> String {
        var parts: [String] = []

        // 音量：只留一条绝对规则（真·气声），其余交给下面的「比平时」。
        // 那批语料最轻也就 -31.2dB，-34 这条线平时不会响。
        if meanLevelDB < -34 { parts.append("很轻，几乎是气声") }

        // 语速。那批语料 3.2~5.1 字/秒，中位 3.7，所以只标两头
        let chars = transcript.filter { $0.isLetter || $0.isNumber }.count
        if voicedSeconds >= 1.2, chars >= 4 {
            let rate = Double(chars) / voicedSeconds
            if rate < 3.0 { parts.append("语速偏慢") }
            else if rate > 5.0 { parts.append("语速偏快") }
        }

        // 句尾走向 —— 疑问、撒娇、话没说完，都在这儿。
        // ⚠️ 上下不对称是故意的：陈述句收尾天然往下掉（自然降调），
        // 门槛跟上扬取一样的话，「句尾往下沉」会变成一句废话天天出现。
        if pitchPoints >= 8 {
            if tailDeltaSemitones >= 1.5 { parts.append("句尾往上扬") }
            else if tailDeltaSemitones <= -2.2 { parts.append("句尾往下沉") }
        }

        // 整段的起伏。那批语料挤在 0.76~2.59 半音，两头都窄
        if pitchPoints >= 12 {
            if spreadSemitones < 1.05 { parts.append("语调很平") }
            else if spreadSemitones > 2.6 { parts.append("起伏挺大") }
        }

        // 停顿。单独一个半秒的空档不值一提 —— 一句话里换口气而已，
        // 报出来只会让这行变长。要么停得久，要么停了不止一次，才算「顿」。
        if let longest = pauses.max(), longest >= 1.2 {
            parts.append("说到一半停了挺久")
        } else if pauses.count >= 2 {
            parts.append("中间顿了\(Self.cn(pauses.count))次")
        }

        // 跟这个人自己平时比
        if let d = baselineLevelDeltaDB {
            if d <= -5 { parts.append("比平时轻") }
            else if d >= 5 { parts.append("比平时大声") }
        }
        if let d = baselineDeltaSemitones {
            if d >= 2.0 { parts.append("比平时高一点") }
            else if d <= -2.0 { parts.append("比平时低一点") }
        }

        guard !parts.isEmpty else { return "" }
        return "[语气 · " + parts.prefix(4).joined(separator: " · ") + "]"
    }

    private static func cn(_ n: Int) -> String {
        ["", "一", "两", "三", "四", "五", "六", "七", "八", "九"].indices.contains(n)
            ? ["", "一", "两", "三", "四", "五", "六", "七", "八", "九"][n]
            : "\(n)"
    }
}
