import Foundation

/// Cheap signal analysis used to avoid feeding silence to Whisper (port of the Windows AudioAnalysis).
enum AudioAnalysis {
    static let sampleRate = 16000
    private static let frameSize = sampleRate / 50 // 20 ms

    /// True when the clip contains at least ~120 ms of frames that stand out from the noise floor.
    static func hasSpeech(_ samples: [Float]) -> Bool {
        let frames = samples.count / frameSize
        if frames < 5 { return false }
        var rms = [Float](repeating: 0, count: frames)
        samples.withUnsafeBufferPointer { p in
            for f in 0..<frames {
                var sum: Double = 0
                for i in (f * frameSize)..<((f + 1) * frameSize) {
                    let s = Double(p[i])
                    sum += s * s
                }
                rms[f] = Float((sum / Double(frameSize)).squareRoot())
            }
        }
        let threshold = voiceThreshold(rms)
        return rms.filter { $0 > threshold }.count >= 6
    }

    /// Frame level that counts as voice: 2.2× the 10th-percentile noise floor, at least −54 dBFS.
    private static func voiceThreshold(_ frameRms: [Float]) -> Float {
        let sorted = frameRms.sorted()
        let noiseFloor = sorted[Int(Double(sorted.count) * 0.10)]
        return max(0.002, noiseFloor * 2.2)
    }

    /// Raises a quiet take to a normal level (robust peak at −6 dBFS, at most +24 dB, never quieter).
    static func normalizeLevel(_ samples: [Float]) -> [Float] {
        if samples.isEmpty { return samples }
        let magnitudes = samples.map { abs($0) }.sorted()
        let peak = magnitudes[Int(Double(magnitudes.count - 1) * 0.999)] // ignore single clicks
        if peak < 1e-4 { return samples }
        let gain = min(max(0.5 / peak, 1), 16)
        if gain < 1.05 { return samples }
        return samples.map { min(max($0 * gain, -1), 1) }
    }

    /// Share of the voice energy (100 Hz–4 kHz) that lies in 1–4 kHz on voiced frames; nil = too little voice.
    static func highBandShare(_ samples: [Float]) -> Double? {
        let n = 512 // 32 ms
        let frames = samples.count / n
        if frames < 8 { return nil }

        var frameRms = [Float](repeating: 0, count: frames)
        for f in 0..<frames {
            var sum: Double = 0
            for i in 0..<n {
                let s = Double(samples[f * n + i])
                sum += s * s
            }
            frameRms[f] = Float((sum / Double(n)).squareRoot())
        }
        let threshold = voiceThreshold(frameRms)

        var re = [Double](repeating: 0, count: n)
        var im = [Double](repeating: 0, count: n)
        var low = 0.0, high = 0.0
        var used = 0
        let binHz = Double(sampleRate) / Double(n)
        for f in 0..<frames where frameRms[f] > threshold {
            for i in 0..<n {
                re[i] = Double(samples[f * n + i]) * (0.5 - 0.5 * cos(2 * Double.pi * Double(i) / Double(n - 1)))
                im[i] = 0
            }
            fft(&re, &im)
            for k in 1..<(n / 2) {
                let hz = Double(k) * binHz
                let power = re[k] * re[k] + im[k] * im[k]
                if hz >= 100 && hz < 1000 { low += power } else if hz >= 1000 && hz < 4000 { high += power }
            }
            used += 1
        }
        if used < 8 || low + high <= 0 { return nil }
        return high / (low + high)
    }

    private static func fft(_ re: inout [Double], _ im: inout [Double]) {
        let n = re.count
        var j = 0
        for i in 1..<n {
            var bit = n >> 1
            while j & bit != 0 {
                j ^= bit
                bit >>= 1
            }
            j ^= bit
            if i < j {
                re.swapAt(i, j)
                im.swapAt(i, j)
            }
        }
        var len = 2
        while len <= n {
            let angle = -2 * Double.pi / Double(len)
            let wRe = cos(angle), wIm = sin(angle)
            var i = 0
            while i < n {
                var curRe = 1.0, curIm = 0.0
                for k in 0..<(len / 2) {
                    let a = i + k, b = a + len / 2
                    let tRe = re[b] * curRe - im[b] * curIm
                    let tIm = re[b] * curIm + im[b] * curRe
                    re[b] = re[a] - tRe
                    im[b] = im[a] - tIm
                    re[a] += tRe
                    im[a] += tIm
                    let nextRe = curRe * wRe - curIm * wIm
                    curIm = curRe * wIm + curIm * wRe
                    curRe = nextRe
                }
                i += len
            }
            len <<= 1
        }
    }

    /// Every sample exactly zero: a dead or virtual input device, not a quiet room.
    static func isDigitalSilence(_ samples: [Float]) -> Bool {
        !samples.contains { $0 != 0 }
    }

    /// Normalized 0..1 meter value (−50 dBFS → 0, 0 dBFS → 1).
    static func level(_ samples: UnsafeBufferPointer<Float>) -> Float {
        if samples.isEmpty { return 0 }
        var sum: Double = 0
        for s in samples { sum += Double(s) * Double(s) }
        let rms = (sum / Double(samples.count)).squareRoot()
        let db = 20 * log10(max(rms, 1e-6))
        return Float(min(max((db + 50) / 50, 0), 1))
    }

    /// whisper.cpp returns nothing for input shorter than a second: add a lead-in and pad the tail.
    static func padForWhisper(_ samples: [Float]) -> [Float] {
        let leadIn = sampleRate / 10               // 100 ms
        let minLength = sampleRate + sampleRate / 4 // 1.25 s
        let length = max(samples.count + leadIn * 2, minLength)
        var padded = [Float](repeating: 0, count: length)
        padded.replaceSubrange(leadIn..<(leadIn + samples.count), with: samples)
        return padded
    }
}

/// Removes Whisper's non-speech tags and well-known hallucinated phrases (port of the Windows TranscriptCleaner).
enum TranscriptCleaner {
    private static let nonSpeechTags = try! NSRegularExpression(
        pattern: #"\[[^\]]*\]|\((?:[^)]*?)(?:музик|music|тиша|silence|оплеск|applause|сміх|laugh|шум|noise|звук|sound)[^)]*\)|\*[^*]{1,40}\*|♪+"#,
        options: [.caseInsensitive])

    // Only the exact credit formulas Whisper learned from subtitled videos.
    private static let subtitleCredits = try! NSRegularExpression(
        pattern: #"(?:субтитри\s+(?:створ|зроб|підготу)\w*|субтитрувальни\w*|редактор\s+субтитрів)(?:[^.!?\n]|\.(?=\S))*[.!?]?|\S*amara\.org\S*"#,
        options: [.caseInsensitive])

    private static let whitespace = try! NSRegularExpression(pattern: #"\s+"#)

    // Phrases Whisper invents for near-silent clips. Only dropped when they are the whole transcript.
    private static let standaloneHallucinations: Set<String> = [
        "дякую за перегляд", "дякую за увагу", "дякую", "дякуємо за перегляд", "до зустрічі",
        "продовження в наступній серії", "thank you", "thanks for watching", "thank you for watching",
        "you", "bye"
    ]

    static func clean(_ text: String?) -> String {
        guard let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return "" }
        var result = replace(nonSpeechTags, in: text, with: " ")
        result = replace(subtitleCredits, in: result, with: " ")
        result = replace(whitespace, in: result, with: " ").trimmingCharacters(in: .whitespaces)
        while let first = result.first, "-–— ".contains(first) {
            result.removeFirst()
        }

        var core = result.trimmingCharacters(in: .whitespaces)
        while let last = core.last, ".!?… ".contains(last) {
            core.removeLast()
        }
        if standaloneHallucinations.contains(core.lowercased()) {
            return ""
        }
        return collapseRepeats(result)
    }

    /// Whisper sometimes loops ("тест тест тест тест …"); keep at most two repeats in a row.
    private static func collapseRepeats(_ text: String) -> String {
        let words = text.split(separator: " ").map(String.init)
        if words.count < 4 { return text }
        var output: [String] = []
        var run = 0
        for (i, word) in words.enumerated() {
            let same = i > 0 && normalize(word).lowercased() == normalize(words[i - 1]).lowercased()
            run = same ? run + 1 : 0
            if run < 2 { output.append(word) }
        }
        return output.joined(separator: " ")
    }

    private static func normalize(_ word: String) -> String {
        word.trimmingCharacters(in: CharacterSet(charactersIn: ",.!?…;:"))
    }

    /// Joins an existing (possibly user-edited) comment with a new dictated fragment.
    static func append(_ existing: String, _ addition: String) -> String {
        let e = existing.replacingOccurrences(of: #"\s+$"#, with: "", options: .regularExpression)
        let a = addition.trimmingCharacters(in: .whitespacesAndNewlines)
        if e.isEmpty { return a }
        if a.isEmpty { return e }
        return e + " " + a
    }

    private static func replace(_ regex: NSRegularExpression, in text: String, with template: String) -> String {
        regex.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: template)
    }
}
