using System;
using System.IO;
using System.Text;
using System.Threading;
using System.Threading.Tasks;
namespace HookMaker {
    // Pipe reads stay compiled: PowerShell's per-chunk dispatch can consume the
    // entire hook deadline on a valid MiB response even with a large buffer.
    public sealed class CiResponseBudget {
        private readonly object sync = new object();
        private long bytes;
        public CiResponseBudget(long initial) { bytes = initial; }
        public long Bytes { get { lock(sync) return bytes; } }
        public void Charge(int count) {
            lock(sync) {
                bytes += count;
                if(bytes > 4194304) throw new IOException("CI aggregate response limit exceeded.");
            }
        }
    }
    public sealed class CiResponseReader {
        private readonly object sync = new object();
        private readonly MemoryStream[] data = { new MemoryStream(), new MemoryStream() };
        private long bytes;
        private volatile bool failed;
        public readonly Task Work;
        public CiResponseReader(Stream output, Stream error, CiResponseBudget budget) {
            Work = Task.WhenAll(Read(output,0,budget), Read(error,1,budget));
        }
        private async Task Read(Stream stream, int index, CiResponseBudget budget) {
            byte[] buffer = new byte[65536];
            try {
            while(true) {
                int count = await stream.ReadAsync(buffer,0,buffer.Length).ConfigureAwait(false);
                if(count == 0) return;
                budget.Charge(count);
                lock(sync) {
                    bytes += count;
                    if(bytes > 1048576) throw new IOException("CI response limit exceeded.");
                }
                data[index].Write(buffer,0,count);
            }
            } catch { failed = true; throw; }
        }
        public string Text(int index) {
            if(!Work.IsCompleted || Work.IsFaulted || Work.IsCanceled) throw new IOException("Incomplete CI response.");
            return new UTF8Encoding(false,true).GetString(data[index].ToArray());
        }
        public bool Release(int milliseconds) {
            try { Work.Wait(Math.Max(0,milliseconds)); } catch (AggregateException) { }
            if(!Work.IsCompleted) return false;
            foreach(var stream in data) stream.Dispose();
            return true;
        }
        public bool Failed { get { return failed || Work.IsFaulted || Work.IsCanceled; } }
    }
}
