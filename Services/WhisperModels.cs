using System;
using System.Collections.Generic;
using System.Linq;

namespace ScreenVoicer.Services
{
    /// <param name="Id">Stored in settings.</param>
    /// <param name="SizeMb">Download size, shown in the menu.</param>
    /// <param name="NeedsGpu">Too slow on a CPU for comfortable use.</param>
    public sealed record WhisperModelInfo(string Id, string Title, string Hint, string FileName, string Url, int SizeMb, bool NeedsGpu)
    {
        public string MenuTitle => $"{Title} — {Id} · {SizeMb} МБ";
    }

    /// <summary>
    /// Quantized builds are used for the bigger models: practically the same accuracy at a third of the download.
    /// Measured on GTX 1650 / i5-10400F (3.9 s phrase): base 0.24 s GPU / 1.3 s CPU, small 0.7 s GPU / 4.2 s CPU.
    /// </summary>
    public static class WhisperModels
    {
        private const string Repo = "https://huggingface.co/sandrohanea/whisper.net/resolve/v3/";

        public static readonly WhisperModelInfo Base = new(
            "base", "Швидка", "найменша, працює швидко навіть без відеокарти",
            "ggml-base.bin", Repo + "classic/ggml-base.bin", 141, NeedsGpu: false);

        public static readonly WhisperModelInfo Small = new(
            "small", "Точна", "помітно краще розпізнає українську",
            "ggml-small-q5_1.bin", Repo + "q5_1/ggml-small.bin", 181, NeedsGpu: false);

        public static readonly WhisperModelInfo Turbo = new(
            "turbo", "Дуже точна", "потрібна відеокарта",
            "ggml-large-v3-turbo-q5_0.bin", Repo + "q5_0/ggml-large-v3-turbo.bin", 547, NeedsGpu: true);

        /// <summary>
        /// Full large-v3: the only model that got a hard-to-understand take fully right where turbo still missed a
        /// word. 7.5–8.5 s per phrase via Vulkan on a GTX 1650, 3.5 s with the CUDA pack (see <see cref="CudaPack"/>).
        /// </summary>
        public static readonly WhisperModelInfo Large = new(
            "large", "Максимальна", "найкраще розуміє нечітку вимову; потрібна відеокарта (з прискоренням NVIDIA — швидко)",
            "ggml-large-v3-q5_0.bin", Repo + "q5_0/ggml-large-v3.bin", 1031, NeedsGpu: true);

        public static IReadOnlyList<WhisperModelInfo> All { get; } = new[] { Base, Small, Turbo, Large };

        public static WhisperModelInfo Find(string? id) =>
            All.FirstOrDefault(m => string.Equals(m.Id, id, StringComparison.OrdinalIgnoreCase)) ?? Base;
    }
}
