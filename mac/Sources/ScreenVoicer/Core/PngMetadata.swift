import Foundation

/// PngMetadata.cs: writes the comment into the PNG itself, so it travels with the file: an iTXt «Description»
/// chunk (read by ScreenVoicer, ExifTool, ImageIO) and XMP dc:description (Spotlight, photo apps). The same bytes
/// as the Windows app and the share page. No re-encoding: the chunks go right after IHDR.
enum PngMetadata {
    private static let descriptionKey = "Description"
    private static let xmpKey = "XML:com.adobe.xmp"
    private static let signature: [UInt8] = [137, 80, 78, 71, 13, 10, 26, 10]

    private static let crcTable: [UInt32] = (0..<256).map { n -> UInt32 in
        var c = UInt32(n)
        for _ in 0..<8 { c = c & 1 != 0 ? 0xEDB8_8320 ^ (c >> 1) : c >> 1 }
        return c
    }

    /// Rewrites the file with the comment inside; returns the new size, or nil if it isn't a PNG.
    @discardableResult
    static func writeComment(path: String, comment: String) throws -> Int64? {
        let url = URL(fileURLWithPath: path)
        guard let updated = withComment(try Data(contentsOf: url), comment: comment) else { return nil }
        try updated.write(to: url, options: .atomic)
        return Int64(updated.count)
    }

    /// The PNG with the comment chunks replaced (an empty comment removes them); nil if not a PNG.
    static func withComment(_ png: Data, comment: String) -> Data? {
        let bytes = [UInt8](png)
        guard let chunks = readChunks(bytes) else { return nil }
        var out = Data(capacity: bytes.count + 1024)
        out.append(contentsOf: signature)
        for chunk in chunks {
            if isCommentChunk(bytes, chunk) { continue }
            out.append(contentsOf: bytes[(chunk.start - 8)..<(chunk.start + chunk.length + 4)])
            if chunk.type == "IHDR" && !comment.isEmpty {
                appendChunk(&out, "iTXt", internationalText(descriptionKey, comment))
                appendChunk(&out, "iTXt", internationalText(xmpKey, xmp(comment)))
            }
        }
        return out
    }

    /// The comment stored in the PNG, or nil. Only the head of the file is read: the comment sits after IHDR.
    static func readComment(path: String) -> String? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        guard let head = try? handle.read(upToCount: 64 * 1024) else { return nil }
        return readComment(head)
    }

    static func readComment(_ png: Data) -> String? {
        let bytes = [UInt8](png)
        guard let chunks = readChunks(bytes, allowTruncated: true) else { return nil }
        for chunk in chunks where chunk.type == "iTXt" {
            let end = chunk.start + chunk.length
            guard let zero = bytes[chunk.start..<end].firstIndex(of: 0), zero + 3 <= end,
                  String(decoding: bytes[chunk.start..<zero], as: UTF8.self) == descriptionKey,
                  bytes[zero + 1] == 0, // compressed text: we never write it
                  let language = bytes[(zero + 3)..<end].firstIndex(of: 0),
                  let translated = bytes[(language + 1)..<end].firstIndex(of: 0) else { continue }
            return String(decoding: bytes[(translated + 1)..<end], as: UTF8.self)
        }
        return nil
    }

    static func crc32<S: Sequence>(_ data: S, _ start: UInt32 = 0) -> UInt32 where S.Element == UInt8 {
        var c = start ^ 0xFFFF_FFFF
        for b in data { c = crcTable[Int((c ^ UInt32(b)) & 0xFF)] ^ (c >> 8) }
        return c ^ 0xFFFF_FFFF
    }

    private struct Chunk {
        let type: String
        let start: Int  // first data byte
        let length: Int
    }

    private static func readChunks(_ png: [UInt8], allowTruncated: Bool = false) -> [Chunk]? {
        guard png.count >= 33, Array(png[0..<8]) == signature else { return nil }
        var chunks: [Chunk] = []
        var pos = 8
        while pos + 12 <= png.count {
            let length = Int(png[pos]) << 24 | Int(png[pos + 1]) << 16 | Int(png[pos + 2]) << 8 | Int(png[pos + 3])
            guard pos + 12 + length <= png.count else { return allowTruncated ? chunks : nil }
            chunks.append(Chunk(type: String(decoding: png[(pos + 4)..<(pos + 8)], as: UTF8.self), start: pos + 8, length: length))
            pos += 12 + length
        }
        return chunks
    }

    private static func isCommentChunk(_ png: [UInt8], _ chunk: Chunk) -> Bool {
        guard ["iTXt", "tEXt", "zTXt"].contains(chunk.type) else { return false }
        let limit = chunk.start + min(chunk.length, 80)
        let end = png[chunk.start..<limit].firstIndex(of: 0) ?? limit
        let keyword = String(decoding: png[chunk.start..<end], as: UTF8.self)
        return keyword == descriptionKey || keyword == xmpKey
    }

    /// keyword, 0, compression flag 0, method 0, language "" 0, translated keyword "" 0, UTF-8 text.
    private static func internationalText(_ keyword: String, _ text: String) -> [UInt8] {
        Array(keyword.utf8) + [0, 0, 0, 0, 0] + Array(text.utf8)
    }

    private static func xmp(_ comment: String) -> String {
        let escaped = comment
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
        let bom = String(Character(Unicode.Scalar(0xFEFF)!))
        return "<?xpacket begin=\"\(bom)\" id=\"W5M0MpCehiHzreSzNTczkc9d\"?>"
            + "<x:xmpmeta xmlns:x=\"adobe:ns:meta/\"><rdf:RDF xmlns:rdf=\"http://www.w3.org/1999/02/22-rdf-syntax-ns#\">"
            + "<rdf:Description rdf:about=\"\" xmlns:dc=\"http://purl.org/dc/elements/1.1/\"><dc:description><rdf:Alt>"
            + "<rdf:li xml:lang=\"x-default\">\(escaped)</rdf:li>"
            + "</rdf:Alt></dc:description></rdf:Description></rdf:RDF></x:xmpmeta><?xpacket end=\"r\"?>"
    }

    private static func appendChunk(_ out: inout Data, _ type: String, _ data: [UInt8]) {
        let typeBytes = Array(type.utf8)
        appendUInt32(&out, UInt32(data.count))
        out.append(contentsOf: typeBytes)
        out.append(contentsOf: data)
        appendUInt32(&out, crc32(data, crc32(typeBytes)))
    }

    private static func appendUInt32(_ out: inout Data, _ v: UInt32) {
        out.append(contentsOf: [UInt8(v >> 24 & 0xFF), UInt8(v >> 16 & 0xFF), UInt8(v >> 8 & 0xFF), UInt8(v & 0xFF)])
    }
}
