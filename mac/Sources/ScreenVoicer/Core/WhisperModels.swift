import Foundation

/// The same models and download URLs as Services/WhisperModels.cs (ggml files work with whisper.cpp directly).
struct WhisperModelInfo: Equatable, Identifiable {
    let id: String
    let title: String
    let hint: String
    let fileName: String
    let url: String
    let sizeMb: Int
    /// Too slow on a processor for comfortable use.
    let needsGpu: Bool
}

enum WhisperModels {
    private static let repo = "https://huggingface.co/sandrohanea/whisper.net/resolve/v3/"

    static let base = WhisperModelInfo(
        id: "base", title: "Швидка", hint: "найменша, працює швидко навіть без відеокарти",
        fileName: "ggml-base.bin", url: repo + "classic/ggml-base.bin", sizeMb: 141, needsGpu: false)

    static let small = WhisperModelInfo(
        id: "small", title: "Точна", hint: "помітно краще розпізнає українську",
        fileName: "ggml-small-q5_1.bin", url: repo + "q5_1/ggml-small.bin", sizeMb: 181, needsGpu: false)

    static let turbo = WhisperModelInfo(
        id: "turbo", title: "Дуже точна", hint: "потрібна відеокарта",
        fileName: "ggml-large-v3-turbo-q5_0.bin", url: repo + "q5_0/ggml-large-v3-turbo.bin", sizeMb: 547, needsGpu: true)

    static let large = WhisperModelInfo(
        id: "large", title: "Максимальна",
        hint: "найкраще розуміє нечітку вимову; потрібна відеокарта",
        fileName: "ggml-large-v3-q5_0.bin", url: repo + "q5_0/ggml-large-v3.bin", sizeMb: 1031, needsGpu: true)

    static let all = [base, small, turbo, large]

    static func find(_ id: String?) -> WhisperModelInfo {
        all.first { $0.id.caseInsensitiveCompare(id ?? "") == .orderedSame } ?? base
    }
}
