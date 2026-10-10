using System;
using System.Collections.Generic;
using System.Linq;
using System.Text.RegularExpressions;

namespace ScreenVoicer.Services
{
    /// <summary>Cheap signal analysis used to avoid feeding silence to Whisper (which then hallucinates).</summary>
    public static class AudioAnalysis
    {
        public const int SampleRate = 16000;
        private const int FrameSize = SampleRate / 50; // 20 ms

        /// <summary>
        /// True when the clip contains at least ~120 ms of frames that stand out from the noise floor.
        /// Whisper reliably turns pure silence into "[BLANK_AUDIO]", "[музика]" or invented sentences.
        /// </summary>
        public static bool HasSpeech(ReadOnlySpan<float> samples)
        {
            int frames = samples.Length / FrameSize;
            if (frames < 5)
            {
                return false;
            }

            var rms = new float[frames];
            for (int f = 0; f < frames; f++)
            {
                double sum = 0;
                var frame = samples.Slice(f * FrameSize, FrameSize);
                foreach (float s in frame)
                {
                    sum += s * s;
                }
                rms[f] = (float)Math.Sqrt(sum / FrameSize);
            }

            int voiced = rms.Count(r => r > VoiceThreshold(rms));
            return voiced >= 6;
        }

        /// <summary>
        /// Frame level that counts as voice: 7 dB over the noise floor, but at least −54 dBFS. The floor is the
        /// 10th percentile, so a take with hardly any pause (speech from the first to the last frame) isn't
        /// mistaken for "all noise" — the old p15 × 3 gate rejected quiet, continuous speech.
        /// </summary>
        private static float VoiceThreshold(float[] frameRms)
        {
            var sorted = (float[])frameRms.Clone();
            Array.Sort(sorted);
            float noiseFloor = sorted[(int)(sorted.Length * 0.10)];
            return Math.Max(0.002f, noiseFloor * 2.2f);
        }

        /// <summary>
        /// Raises a quiet take to a normal level (robust peak at −6 dBFS, at most +24 dB, never quieter).
        /// Whisper's log-mel input isn't level-independent: a far or weak microphone at −20 dBFS peak decoded
        /// noticeably worse than the same take normalized.
        /// </summary>
        public static float[] NormalizeLevel(float[] samples)
        {
            if (samples.Length == 0)
            {
                return samples;
            }

            var magnitudes = new float[samples.Length];
            for (int i = 0; i < samples.Length; i++)
            {
                magnitudes[i] = Math.Abs(samples[i]);
            }
            Array.Sort(magnitudes);
            float peak = magnitudes[(int)((magnitudes.Length - 1) * 0.999)]; // ignore single clicks
            if (peak < 1e-4f)
            {
                return samples;
            }

            float gain = Math.Clamp(0.5f / peak, 1f, 16f);
            if (gain < 1.05f)
            {
                return samples;
            }

            var result = new float[samples.Length];
            for (int i = 0; i < samples.Length; i++)
            {
                result[i] = Math.Clamp(samples[i] * gain, -1f, 1f);
            }
            return result;
        }

        /// <summary>
        /// Share of the voice energy (100 Hz–4 kHz) that lies in 1–4 kHz, measured on voiced frames only.
        /// Consonants and the second formant live there; normal speech through a normal microphone gives
        /// 4–20 %, while a microphone that sounds "through a pillow" (wrong jack, headphone speaker picked up
        /// as a mic, covered capsule) gives well under 1 % — and then no recognizer can understand the words.
        /// Returns null when there is too little voice to judge.
        /// </summary>
        public static double? HighBandShare(float[] samples)
        {
            const int n = 512; // 32 ms
            int frames = samples.Length / n;
            if (frames < 8)
            {
                return null;
            }

            var frameRms = new float[frames];
            for (int f = 0; f < frames; f++)
            {
                double sum = 0;
                for (int i = 0; i < n; i++)
                {
                    float s = samples[f * n + i];
                    sum += s * s;
                }
                frameRms[f] = (float)Math.Sqrt(sum / n);
            }
            float threshold = VoiceThreshold(frameRms);

            var re = new double[n];
            var im = new double[n];
            double low = 0, high = 0;
            int used = 0;
            double binHz = (double)SampleRate / n;
            for (int f = 0; f < frames; f++)
            {
                if (frameRms[f] <= threshold)
                {
                    continue;
                }
                for (int i = 0; i < n; i++)
                {
                    re[i] = samples[f * n + i] * (0.5 - 0.5 * Math.Cos(2 * Math.PI * i / (n - 1)));
                    im[i] = 0;
                }
                Fft(re, im);
                for (int k = 1; k < n / 2; k++)
                {
                    double hz = k * binHz, power = re[k] * re[k] + im[k] * im[k];
                    if (hz >= 100 && hz < 1000) low += power;
                    else if (hz >= 1000 && hz < 4000) high += power;
                }
                used++;
            }

            if (used < 8 || low + high <= 0)
            {
                return null;
            }
            return high / (low + high);
        }

        private static void Fft(double[] re, double[] im)
        {
            int n = re.Length;
            for (int i = 1, j = 0; i < n; i++)
            {
                int bit = n >> 1;
                for (; (j & bit) != 0; bit >>= 1)
                {
                    j ^= bit;
                }
                j ^= bit;
                if (i < j)
                {
                    (re[i], re[j]) = (re[j], re[i]);
                    (im[i], im[j]) = (im[j], im[i]);
                }
            }
            for (int len = 2; len <= n; len <<= 1)
            {
                double angle = -2 * Math.PI / len;
                double wRe = Math.Cos(angle), wIm = Math.Sin(angle);
                for (int i = 0; i < n; i += len)
                {
                    double curRe = 1, curIm = 0;
                    for (int j = 0; j < len / 2; j++)
                    {
                        int a = i + j, b = a + len / 2;
                        double tRe = re[b] * curRe - im[b] * curIm, tIm = re[b] * curIm + im[b] * curRe;
                        re[b] = re[a] - tRe;
                        im[b] = im[a] - tIm;
                        re[a] += tRe;
                        im[a] += tIm;
                        double nextRe = curRe * wRe - curIm * wIm;
                        curIm = curRe * wIm + curIm * wRe;
                        curRe = nextRe;
                    }
                }
            }
        }

        /// <summary>
        /// Every sample exactly zero: not a quiet room but a dead/virtual input device
        /// (e.g. "Steam Streaming" devices set as the Windows default microphone).
        /// </summary>
        public static bool IsDigitalSilence(ReadOnlySpan<float> samples)
        {
            foreach (float s in samples)
            {
                if (s != 0f)
                {
                    return false;
                }
            }
            return true;
        }

        /// <summary>Normalized 0..1 meter value for a block of 16-bit PCM (−50 dBFS → 0, 0 dBFS → 1).</summary>
        public static float LevelFromPcm16(byte[] buffer, int bytes)
        {
            int count = bytes / 2;
            if (count == 0)
            {
                return 0f;
            }

            double sum = 0;
            for (int i = 0; i + 1 < bytes; i += 2)
            {
                float s = (short)(buffer[i] | (buffer[i + 1] << 8)) / 32768f;
                sum += s * s;
            }

            double rms = Math.Sqrt(sum / count);
            double db = 20 * Math.Log10(Math.Max(rms, 1e-6));
            return (float)Math.Clamp((db + 50) / 50, 0, 1);
        }

        /// <summary>
        /// whisper.cpp silently returns nothing for input shorter than one second, so short phrases
        /// ("тут баг") were lost. Adds a short lead-in and pads the tail with silence.
        /// </summary>
        public static float[] PadForWhisper(float[] samples)
        {
            const int leadIn = SampleRate / 10;              // 100 ms
            const int minLength = SampleRate + SampleRate / 4; // 1.25 s
            int length = Math.Max(samples.Length + leadIn * 2, minLength);
            var padded = new float[length];
            Array.Copy(samples, 0, padded, leadIn, samples.Length);
            return padded;
        }
    }

    /// <summary>Removes Whisper's non-speech tags and well-known hallucinated phrases.</summary>
    public static class TranscriptCleaner
    {
        private static readonly Regex NonSpeechTags = new(
            @"\[[^\]]*\]|\((?:[^)]*?)(?:музик|music|тиша|silence|оплеск|applause|сміх|laugh|шум|noise|звук|sound)[^)]*\)|\*[^*]{1,40}\*|♪+",
            RegexOptions.IgnoreCase | RegexOptions.CultureInvariant | RegexOptions.Compiled);

        // Only the exact credit formulas Whisper learned from subtitled videos, so a real comment like
        // "субтитри у плеєрі не показуються" survives.
        private static readonly Regex SubtitleCredits = new(
            // "(?:[^.!?\n]|\.(?=\S))*" = rest of the sentence, where a dot inside "Amara.org" doesn't end it.
            @"(?:субтитри\s+(?:створ|зроб|підготу)\w*|субтитрувальни\w*|редактор\s+субтитрів)(?:[^.!?\n]|\.(?=\S))*[.!?]?|\S*amara\.org\S*",
            RegexOptions.IgnoreCase | RegexOptions.CultureInvariant | RegexOptions.Compiled);

        private static readonly Regex Whitespace = new(@"\s+", RegexOptions.Compiled);

        // Phrases Whisper invents for near-silent clips. Only dropped when they are the whole transcript.
        private static readonly HashSet<string> StandaloneHallucinations = new(StringComparer.OrdinalIgnoreCase)
        {
            "дякую за перегляд", "дякую за увагу", "дякую", "дякуємо за перегляд", "до зустрічі",
            "продовження в наступній серії", "thank you", "thanks for watching", "thank you for watching",
            "you", "bye"
        };

        public static string Clean(string? text)
        {
            if (string.IsNullOrWhiteSpace(text))
            {
                return string.Empty;
            }

            string result = NonSpeechTags.Replace(text, " ");
            result = SubtitleCredits.Replace(result, " ");
            result = Whitespace.Replace(result, " ").Trim().TrimStart('-', '–', '—', ' ');

            string core = result.Trim().TrimEnd('.', '!', '?', '…', ' ');
            if (StandaloneHallucinations.Contains(core))
            {
                return string.Empty;
            }

            return CollapseRepeats(result);
        }

        /// <summary>Whisper sometimes loops ("тест тест тест тест ..."); keep at most two repeats in a row.</summary>
        private static string CollapseRepeats(string text)
        {
            var words = text.Split(' ', StringSplitOptions.RemoveEmptyEntries);
            if (words.Length < 4)
            {
                return text;
            }

            var output = new List<string>(words.Length);
            int run = 0;
            for (int i = 0; i < words.Length; i++)
            {
                bool same = i > 0 && string.Equals(Normalize(words[i]), Normalize(words[i - 1]), StringComparison.OrdinalIgnoreCase);
                run = same ? run + 1 : 0;
                if (run < 2)
                {
                    output.Add(words[i]);
                }
            }

            return string.Join(' ', output);

            static string Normalize(string w) => w.Trim(',', '.', '!', '?', '…', ';', ':');
        }

        /// <summary>Joins an existing (possibly user-edited) comment with a new dictated fragment.</summary>
        public static string Append(string existing, string addition)
        {
            existing = existing.TrimEnd();
            addition = addition.Trim();
            if (existing.Length == 0)
            {
                return addition;
            }
            if (addition.Length == 0)
            {
                return existing;
            }
            return existing + " " + addition;
        }
    }
}
