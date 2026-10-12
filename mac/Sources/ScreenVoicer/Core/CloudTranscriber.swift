import Foundation

/// Voice comments recognized online through the ScreenVoicer server (share-worker/, POST /api/transcribe): accurate and
/// fast on any Mac, the language detected by itself. Returns nil when it can't (no internet, the server's daily
/// allowance used up, a timeout) and the caller recognizes on the Mac instead. Same request as the Windows app.
enum CloudTranscriber {
    static func transcribe(_ samples: [Float]) async -> String? {
        let seconds = Double(samples.count) / Double(AudioAnalysis.sampleRate)
        let audio = wav(AudioAnalysis.normalizeLevel(samples)).base64EncodedString()
        guard let body = try? JSONSerialization.data(withJSONObject: ["audio": audio]) else { return nil }

        var request = URLRequest(url: URL(string: "\(ShareService.endpoint)/api/transcribe")!)
        request.httpMethod = "POST"
        request.timeoutInterval = min(max(8 + seconds / 2, 8), 40)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("ScreenVoicer/\(AppInfo.version)", forHTTPHeaderField: "User-Agent")
        request.httpBody = body

        let started = Date()
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard (200..<300).contains(status),
                  let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                Log.warn("[Cloud] Recognition refused (\(status)): \(String(decoding: data.prefix(160), as: UTF8.self))")
                return nil
            }
            let text = json["text"] as? String ?? ""
            let language = json["language"] as? String ?? ""
            Log.info("[Cloud] \(String(format: "%.1f", seconds)) s → \(Int(Date().timeIntervalSince(started) * 1000)) ms, lang=\(language): \"\(text)\"")
            return TranscriptCleaner.clean(text)
        } catch {
            Log.warn("[Cloud] Recognition unavailable, using the Mac: \(error.localizedDescription)")
            return nil
        }
    }

    /// 16 kHz mono 16-bit PCM WAV, the format the recognizer expects.
    private static func wav(_ samples: [Float]) -> Data {
        var data = Data(capacity: 44 + samples.count * 2)
        let rate = UInt32(AudioAnalysis.sampleRate)
        func put32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
        func put16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
        let payload = UInt32(samples.count * 2)
        data.append(contentsOf: Array("RIFF".utf8)); put32(36 + payload)
        data.append(contentsOf: Array("WAVE".utf8))
        data.append(contentsOf: Array("fmt ".utf8)); put32(16); put16(1); put16(1); put32(rate); put32(rate * 2); put16(2); put16(16)
        data.append(contentsOf: Array("data".utf8)); put32(payload)
        for s in samples {
            put16(UInt16(bitPattern: Int16((max(-1, min(1, s)) * 32767).rounded())))
        }
        return data
    }
}
