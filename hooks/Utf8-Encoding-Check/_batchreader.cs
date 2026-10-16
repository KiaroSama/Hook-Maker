// Raw Git transport only: fixed buffers and strict framing, never decoded payload retention.
using System;
using System.IO;
using System.Text;
using System.Threading.Tasks;

namespace HookMakerUtf8
{
    public sealed class BatchResult
    {
        public string Class = "";
        public byte[] Bytes = null;
        public bool Truncated;
        public bool Failed;
        public string Failure = "";
    }

    public sealed class BatchReader
    {
        private readonly Stream stream;
        private readonly DateTime deadline;
        private readonly byte[] buffer = new byte[65536];
        private readonly byte[] prefix = new byte[8192];
        private readonly char[] chars = new char[65538];
        private readonly byte[] header = new byte[129];
        private int position;
        private int available;
        private readonly bool prefetch;
        public long BytesRead { get; private set; }

        public BatchReader(Stream input, DateTime deadlineUtc) : this(input, deadlineUtc, true) { }
        public BatchReader(Stream input, DateTime deadlineUtc, bool allowPrefetch)
        {
            stream = input;
            deadline = deadlineUtc;
            prefetch = allowPrefetch;
        }

        private void CheckDeadline()
        {
            if (DateTime.UtcNow >= deadline) throw new IOException("deadline");
        }

        private int Read(byte[] target, int offset, int count)
        {
            CheckDeadline();
            int remaining = (int)Math.Min(int.MaxValue, Math.Ceiling((deadline - DateTime.UtcNow).TotalMilliseconds));
            if (remaining <= 0) throw new IOException("deadline");
            Task<int> read = stream.ReadAsync(target, offset, count);
            if (!read.Wait(remaining)) throw new IOException("deadline");
            int n = read.GetAwaiter().GetResult();
            BytesRead += n;
            return n;
        }

        private bool Fill(int wanted)
        {
            if (position < available) return true;
            position = 0;
            available = Read(buffer, 0, prefetch ? buffer.Length : Math.Min(buffer.Length, wanted));
            return available > 0;
        }

        private int Byte()
        {
            if (!Fill(1)) return -1;
            return buffer[position++];
        }

        private void Exact(byte[] target, int count, string failure)
        {
            int total = 0;
            while (total < count)
            {
                if (!Fill(count - total)) throw new IOException(failure);
                int n = Math.Min(count - total, available - position);
                Buffer.BlockCopy(buffer, position, target, total, n);
                position += n;
                total += n;
            }
        }

        private string PrefixClass(int count)
        {
            if (count >= 2 && prefix[0] == 255 && prefix[1] == 254) return "utf16le";
            if (count >= 2 && prefix[0] == 254 && prefix[1] == 255) return "utf16be";
            int even = 0, odd = 0;
            for (int i = 0; i < count; i++)
                if (prefix[i] == 0) { if ((i & 1) == 0) even++; else odd++; }
            if (even + odd > 0)
            {
                if (odd >= 2 && odd >= 3 * even) return "utf16le";
                if (even >= 2 && even >= 3 * odd) return "utf16be";
                return "binary";
            }
            return count >= 3 && prefix[0] == 239 && prefix[1] == 187 && prefix[2] == 191 ? "utf8bom" : "utf8";
        }

        public void Complete()
        {
            CheckDeadline();
            if (Byte() != -1) throw new IOException("trailing-output");
        }

        public BatchResult Frame(string oid, long maxBytes)
        {
            CheckDeadline();
            int length = 0;
            while (true)
            {
                int b = Byte();
                if (b < 0) throw new IOException("short-header");
                if (b == 10) break;
                if (length >= 128 || b > 127) throw new IOException("malformed-header");
                header[length++] = (byte)b;
            }
            string text = Encoding.ASCII.GetString(header, 0, length);
            if (text == oid + " missing") throw new IOException("missing-object");
            string start = oid + " blob ";
            long size;
            if (!text.StartsWith(start, StringComparison.Ordinal) || text.Length == start.Length)
                throw new IOException("malformed-header");
            string digits = text.Substring(start.Length);
            foreach (char c in digits) if (c < '0' || c > '9') throw new IOException("malformed-header");
            if (!long.TryParse(digits, out size)) throw new IOException("malformed-header");
            int prefixLength = (int)Math.Min(prefix.Length, size);
            Exact(prefix, prefixLength, "short-body");
            string classification = PrefixClass(prefixLength);
            Decoder decoder = null;
            if (classification == "utf8" || classification == "utf8bom")
            {
                if (size > maxBytes) classification = "oversized";
                else
                {
                    decoder = new UTF8Encoding(false, true).GetDecoder();
                    try { decoder.GetChars(prefix, 0, prefixLength, chars, 0, false); }
                    catch (DecoderFallbackException) { classification = "invalid"; decoder = null; }
                }
            }
            long left = size - prefixLength;
            while (left > 0)
            {
                CheckDeadline();
                if (!Fill((int)Math.Min(buffer.Length, left))) throw new IOException("short-body");
                int n = (int)Math.Min(left, available - position);
                if (decoder != null)
                {
                    try { decoder.GetChars(buffer, position, n, chars, 0, false); }
                    catch (DecoderFallbackException) { classification = "invalid"; decoder = null; }
                }
                position += n;
                left -= n;
            }
            if (decoder != null)
            {
                try { decoder.GetChars(prefix, 0, 0, chars, 0, true); }
                catch (DecoderFallbackException) { classification = "invalid"; }
            }
            if (Byte() != 10) throw new IOException("missing-delimiter");
            return new BatchResult { Class = classification, Truncated = classification == "oversized" };
        }
    }
}
