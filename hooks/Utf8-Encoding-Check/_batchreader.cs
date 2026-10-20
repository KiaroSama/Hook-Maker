// Raw Git transport only: fixed buffers and strict framing, never decoded payload retention.
using System;
using System.IO;
using System.Text;
using System.Collections.Generic;
using System.Threading;
using System.Threading.Tasks;
using System.Runtime.InteropServices;

namespace HookMakerUtf8
{
    // Narrow complete-object evidence, never an extension or cryptographic test.
    public static class BinaryEvidence
    {
        public static bool IsOpaque(byte[] bytes, int count, bool complete)
        {
            if (!complete || bytes == null || count < 64 || count > 8192 || count > bytes.Length) return false;
            if ((bytes[0] == 255 && bytes[1] == 254) || (bytes[0] == 254 && bytes[1] == 255) ||
                (bytes[0] == 239 && bytes[1] == 187 && bytes[2] == 191)) return false;
            int controls = 0, high = 0;
            for (int i = 0; i < count; i++)
            {
                byte b = bytes[i];
                if (b < 32 && b != 9 && b != 10 && b != 13) controls++;
                if (b >= 128) high++;
            }
            if (controls < 8 || controls * 16 < count || high * 4 < count) return false;
            // Either valid UTF-16 byte order vetoes opacity, even for actual binary.
            foreach (Encoding encoding in new Encoding[] {
                new UTF8Encoding(false, true), new UnicodeEncoding(false, false, true), new UnicodeEncoding(true, false, true) })
            {
                try { encoding.GetCharCount(bytes, 0, count); return false; }
                catch (DecoderFallbackException) { }
            }
            return true;
        }
    }

    public sealed class BatchResult
    {
        public string Class = "";
        public byte[] Bytes = null;
        public bool Truncated;
        public bool Failed;
        public string Failure = "";
    }

    // Redirected Windows pipes are synchronous handles. Keep their blocking I/O
    // on one owned thread instead of queuing every buffer to the thread pool.
    public sealed class BatchWorker
    {
        public readonly Dictionary<string, BatchResult> Results = new Dictionary<string, BatchResult>(StringComparer.Ordinal);
        public readonly Task Work;
        public string Failure = "";
        private readonly object gate = new object();
        private IntPtr threadHandle;
        private volatile bool cancelled;
        [DllImport("kernel32.dll")] private static extern uint GetCurrentThreadId();
        [DllImport("kernel32.dll")] private static extern IntPtr OpenThread(uint access, bool inherit, uint id);
        [DllImport("kernel32.dll")] private static extern bool CancelSynchronousIo(IntPtr handle);
        [DllImport("kernel32.dll")] private static extern bool CloseHandle(IntPtr handle);

        public BatchWorker(Stream input, Stream output, string[] ids, long maxBytes, DateTime deadline)
        {
            Work = Task.Factory.StartNew(delegate {
                bool windows = Environment.OSVersion.Platform == PlatformID.Win32NT;
                try
                {
                    if (windows)
                    {
                        lock (gate) threadHandle = OpenThread(1, false, GetCurrentThreadId());
                        if (threadHandle == IntPtr.Zero) throw new IOException("transport");
                    }
                    BatchReader reader = new BatchReader(output, deadline, delegate { Check(deadline); });
                    byte[] requests = new byte[2080];
                    for (int index = 0; index < ids.Length; index += 32)
                    {
                        Check(deadline);
                        int end = Math.Min(ids.Length, index + 32), count = 0;
                        for (int i = index; i < end; i++)
                        {
                            string oid = ids[i];
                            if (oid == null || (oid.Length != 40 && oid.Length != 64)) throw new IOException("invalid-object-id");
                            foreach (char c in oid)
                            {
                                if (!((c >= '0' && c <= '9') || (c >= 'a' && c <= 'f'))) throw new IOException("invalid-object-id");
                                requests[count++] = (byte)c;
                            }
                            requests[count++] = 10;
                        }
                        Check(deadline);
                        input.Write(requests, 0, count);
                        Check(deadline);
                        input.Flush();
                        for (int i = index; i < end; i++)
                        {
                            Check(deadline);
                            Results[ids[i]] = reader.Frame(ids[i], maxBytes);
                        }
                    }
                    input.Close();
                    reader.Complete();
                    Check(deadline);
                }
                catch (Exception error)
                {
                    Failure = "transport";
                    foreach (string code in new[] { "deadline", "missing-object", "malformed-header", "short-header", "short-body", "missing-delimiter", "trailing-output", "invalid-object-id" })
                        if (error.Message == code) { Failure = code; break; }
                }
                finally
                {
                    lock (gate)
                    {
                        if (threadHandle != IntPtr.Zero) CloseHandle(threadHandle);
                        threadHandle = IntPtr.Zero;
                    }
                }
            }, CancellationToken.None, TaskCreationOptions.LongRunning, TaskScheduler.Default);
        }

        private void Check(DateTime deadline)
        {
            if (cancelled || DateTime.UtcNow >= deadline) throw new IOException("deadline");
        }

        public bool Stop(int milliseconds)
        {
            cancelled = true;
            System.Diagnostics.Stopwatch clock = System.Diagnostics.Stopwatch.StartNew();
            while (!Work.IsCompleted)
            {
                // Cancellation can land between synchronous calls; repeat until
                // the dedicated thread acknowledges it, never reuse that thread.
                lock (gate)
                    if (threadHandle != IntPtr.Zero) CancelSynchronousIo(threadHandle);
                int left = milliseconds - (int)clock.ElapsedMilliseconds;
                if (left <= 0) return Work.IsCompleted;
                Work.Wait(Math.Min(10, left));
            }
            return true;
        }
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
        private readonly Action checkOwner;
        public long BytesRead { get; private set; }

        public BatchReader(Stream input, DateTime deadlineUtc) : this(input, deadlineUtc, true) { }
        public BatchReader(Stream input, DateTime deadlineUtc, bool allowPrefetch)
        {
            stream = input;
            deadline = deadlineUtc;
            prefetch = allowPrefetch;
        }

        internal BatchReader(Stream input, DateTime deadlineUtc, Action ownerCheck) : this(input, deadlineUtc, true)
        {
            checkOwner = ownerCheck;
        }

        private void CheckDeadline()
        {
            if (checkOwner != null) checkOwner();
            if (DateTime.UtcNow >= deadline) throw new IOException("deadline");
        }

        private int Read(byte[] target, int offset, int count)
        {
            CheckDeadline();
            int remaining = (int)Math.Min(int.MaxValue, Math.Ceiling((deadline - DateTime.UtcNow).TotalMilliseconds));
            if (remaining <= 0) throw new IOException("deadline");
            int n;
            if (checkOwner != null) n = stream.Read(target, offset, count);
            else
            {
                Task<int> read = stream.ReadAsync(target, offset, count);
                if (!read.Wait(remaining)) throw new IOException("deadline");
                n = read.GetAwaiter().GetResult();
            }
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

        private string PrefixClass(int count, bool complete)
        {
            if (BinaryEvidence.IsOpaque(prefix, count, complete)) return "binary";
            if (count >= 2 && prefix[0] == 255 && prefix[1] == 254) return "utf16le";
            if (count >= 2 && prefix[0] == 254 && prefix[1] == 255) return "utf16be";
            int even = 0, odd = 0;
            for (int i = 0; i < count; i++)
                if (prefix[i] == 0) { if ((i & 1) == 0) even++; else odd++; }
            // Sparse NULs are not UTF-16 evidence; the complete UTF-8 decoder
            // below must still validate every byte, including the final flush.
            if (even + odd > 0 && (even + odd) * 16 >= count)
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
            string classification = PrefixClass(prefixLength, size == prefixLength && size <= maxBytes);
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
