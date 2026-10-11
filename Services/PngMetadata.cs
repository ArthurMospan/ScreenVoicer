using System;
using System.Collections.Generic;
using System.IO;
using System.Text;

namespace ScreenVoicer.Services
{
    /// <summary>
    /// Writes the comment into the PNG itself, so it travels with the file: an iTXt «Description» chunk (read by
    /// ScreenVoicer, ExifTool, macOS) and XMP dc:description (Spotlight, photo apps). The same bytes as the Mac
    /// app's PngMetadata.swift and the share page. No re-encoding: chunks are inserted right after IHDR.
    /// </summary>
    public static class PngMetadata
    {
        private const string DescriptionKey = "Description";
        private const string XmpKey = "XML:com.adobe.xmp";
        private static readonly byte[] Signature = { 137, 80, 78, 71, 13, 10, 26, 10 };
        private static readonly uint[] CrcTable = BuildCrcTable();

        /// <summary>Rewrites the file with the comment inside; returns the new size, or null if it isn't a PNG.</summary>
        public static long? WriteComment(string path, string comment)
        {
            byte[] original = File.ReadAllBytes(path);
            byte[]? updated = WithComment(original, comment);
            if (updated == null)
            {
                return null;
            }
            string temp = path + ".tmp";
            File.WriteAllBytes(temp, updated);
            File.Move(temp, path, overwrite: true);
            return updated.Length;
        }

        /// <summary>The PNG with the comment chunks replaced (an empty comment removes them); null if not a PNG.</summary>
        public static byte[]? WithComment(byte[] png, string comment)
        {
            var chunks = ReadChunks(png);
            if (chunks == null)
            {
                return null;
            }

            using var output = new MemoryStream(png.Length + 1024);
            output.Write(Signature);
            foreach (var (type, start, length) in chunks)
            {
                if (IsCommentChunk(png, type, start, length))
                {
                    continue;
                }
                output.Write(png, start - 8, length + 12);
                if (type == "IHDR" && comment.Length > 0)
                {
                    WriteChunk(output, "iTXt", InternationalText(DescriptionKey, comment));
                    WriteChunk(output, "iTXt", InternationalText(XmpKey, Xmp(comment)));
                }
            }
            return output.ToArray();
        }

        /// <summary>The comment stored in the PNG, or null.</summary>
        public static string? ReadComment(string path)
        {
            try
            {
                using var stream = File.OpenRead(path);
                // the comment sits right after IHDR, so the first 64 KB are plenty
                var head = new byte[Math.Min(stream.Length, 64 * 1024)];
                stream.ReadExactly(head);
                return ReadComment(head);
            }
            catch (Exception ex)
            {
                Log.Warn($"[PngMetadata] Could not read '{path}'", ex);
                return null;
            }
        }

        public static string? ReadComment(byte[] png)
        {
            var chunks = ReadChunks(png, allowTruncated: true);
            if (chunks == null)
            {
                return null;
            }
            foreach (var (type, start, length) in chunks)
            {
                if (type != "iTXt")
                {
                    continue;
                }
                int zero = Array.IndexOf(png, (byte)0, start, length);
                if (zero < 0 || zero + 3 > start + length
                    || Encoding.Latin1.GetString(png, start, zero - start) != DescriptionKey || png[zero + 1] != 0)
                {
                    continue; // another keyword, or compressed text (we never write that)
                }
                int language = Array.IndexOf(png, (byte)0, zero + 3, start + length - zero - 3);
                int translated = language < 0 ? -1 : Array.IndexOf(png, (byte)0, language + 1, start + length - language - 1);
                if (translated < 0)
                {
                    continue;
                }
                return Encoding.UTF8.GetString(png, translated + 1, start + length - translated - 1);
            }
            return null;
        }

        public static uint Crc32(ReadOnlySpan<byte> data, uint crc = 0)
        {
            crc ^= 0xFFFFFFFF;
            foreach (byte b in data)
            {
                crc = CrcTable[(crc ^ b) & 0xFF] ^ (crc >> 8);
            }
            return crc ^ 0xFFFFFFFF;
        }

        private static List<(string Type, int Start, int Length)>? ReadChunks(byte[] png, bool allowTruncated = false)
        {
            if (png.Length < 33 || !png.AsSpan(0, 8).SequenceEqual(Signature))
            {
                return null;
            }
            var chunks = new List<(string, int, int)>();
            int pos = 8;
            while (pos + 12 <= png.Length)
            {
                int length = (int)ReadUInt32(png, pos);
                if (length < 0 || pos + 12L + length > png.Length)
                {
                    return allowTruncated ? chunks : null;
                }
                chunks.Add((Encoding.ASCII.GetString(png, pos + 4, 4), pos + 8, length));
                pos += 12 + length;
            }
            return chunks;
        }

        private static bool IsCommentChunk(byte[] png, string type, int start, int length)
        {
            if (type is not ("iTXt" or "tEXt" or "zTXt"))
            {
                return false;
            }
            int zero = Array.IndexOf(png, (byte)0, start, Math.Min(length, 80));
            string keyword = Encoding.Latin1.GetString(png, start, (zero < 0 ? Math.Min(length, 80) : zero - start));
            return keyword is DescriptionKey or XmpKey;
        }

        /// <summary>keyword, 0, compression flag 0, method 0, language "" 0, translated keyword "" 0, UTF-8 text.</summary>
        private static byte[] InternationalText(string keyword, string text)
        {
            byte[] key = Encoding.Latin1.GetBytes(keyword);
            byte[] body = Encoding.UTF8.GetBytes(text);
            var data = new byte[key.Length + 5 + body.Length];
            key.CopyTo(data, 0);
            body.CopyTo(data, key.Length + 5);
            return data;
        }

        private static string Xmp(string comment) =>
            "<?xpacket begin=\"" + (char)0xFEFF + "\" id=\"W5M0MpCehiHzreSzNTczkc9d\"?>" +
            "<x:xmpmeta xmlns:x=\"adobe:ns:meta/\"><rdf:RDF xmlns:rdf=\"http://www.w3.org/1999/02/22-rdf-syntax-ns#\">" +
            "<rdf:Description rdf:about=\"\" xmlns:dc=\"http://purl.org/dc/elements/1.1/\"><dc:description><rdf:Alt>" +
            "<rdf:li xml:lang=\"x-default\">" + EscapeXml(comment) + "</rdf:li>" +
            "</rdf:Alt></dc:description></rdf:Description></rdf:RDF></x:xmpmeta><?xpacket end=\"r\"?>";

        /// <summary>The same four entities as the Mac app and the share page, so all three write identical bytes.</summary>
        private static string EscapeXml(string text) =>
            text.Replace("&", "&amp;").Replace("<", "&lt;").Replace(">", "&gt;").Replace("\"", "&quot;");

        private static void WriteChunk(Stream output, string type, byte[] data)
        {
            byte[] typeBytes = Encoding.ASCII.GetBytes(type);
            WriteUInt32(output, (uint)data.Length);
            output.Write(typeBytes);
            output.Write(data);
            WriteUInt32(output, Crc32(data, Crc32(typeBytes)));
        }

        private static uint ReadUInt32(byte[] b, int at) =>
            (uint)(b[at] << 24 | b[at + 1] << 16 | b[at + 2] << 8 | b[at + 3]);

        private static void WriteUInt32(Stream s, uint v)
        {
            s.WriteByte((byte)(v >> 24));
            s.WriteByte((byte)(v >> 16));
            s.WriteByte((byte)(v >> 8));
            s.WriteByte((byte)v);
        }

        private static uint[] BuildCrcTable()
        {
            var table = new uint[256];
            for (uint n = 0; n < 256; n++)
            {
                uint c = n;
                for (int k = 0; k < 8; k++)
                {
                    c = (c & 1) != 0 ? 0xEDB88320 ^ (c >> 1) : c >> 1;
                }
                table[n] = c;
            }
            return table;
        }
    }
}
