// A synchronous pipe-shaped boundary that refuses per-operation async scheduling.
using System;
using System.IO;
using System.Threading;
using System.Threading.Tasks;

public sealed class Utf8SyncStream : MemoryStream
{
    public int WorkerThread;
    public bool UsedThreadPool;
    public int MaximumWrite;
    public int FlushCount;
    public int AsyncCalls;
    public Utf8SyncStream() { }
    public Utf8SyncStream(byte[] bytes) : base(bytes, false) { }
    private void Observe()
    {
        int id = Thread.CurrentThread.ManagedThreadId;
        if (WorkerThread != 0 && WorkerThread != id) throw new IOException("multiple-workers");
        WorkerThread = id;
        UsedThreadPool |= Thread.CurrentThread.IsThreadPoolThread;
    }
    public override int Read(byte[] buffer, int offset, int count)
    {
        Observe();
        return base.Read(buffer, offset, Math.Min(count, 113));
    }
    public override void Write(byte[] buffer, int offset, int count)
    {
        Observe();
        MaximumWrite = Math.Max(MaximumWrite, count);
        base.Write(buffer, offset, count);
    }
    public override void Flush() { Observe(); FlushCount++; base.Flush(); }
    public override Task<int> ReadAsync(byte[] buffer, int offset, int count, CancellationToken cancellationToken)
    {
        AsyncCalls++;
        throw new IOException("per-read-async-scheduling");
    }
    public override Task WriteAsync(byte[] buffer, int offset, int count, CancellationToken cancellationToken)
    {
        AsyncCalls++;
        throw new IOException("per-write-async-scheduling");
    }
    public static bool CheckPendingPipeCancellation(Type workerType)
    {
        var server = new System.IO.Pipes.AnonymousPipeServerStream(System.IO.Pipes.PipeDirection.Out);
        var source = new PendingPipeStream(server.GetClientHandleAsString());
        var sink = new MemoryStream();
        object worker = null;
        bool stopped = false;
        try
        {
            worker = Activator.CreateInstance(workerType, sink, source, new[] { new string('a', 40) }, (long)1024, DateTime.UtcNow.AddSeconds(5));
            bool entered = source.Entered.Wait(2000);
            stopped = (bool)workerType.GetMethod("Stop").Invoke(worker, new object[] { 2000 });
            return entered && stopped && ((Task)workerType.GetField("Work").GetValue(worker)).IsCompleted && (string)workerType.GetField("Failure").GetValue(worker) != "";
        }
        finally
        {
            server.Dispose();
            if (worker == null) stopped = true;
            else if (!stopped) stopped = (bool)workerType.GetMethod("Stop").Invoke(worker, new object[] { 2000 });
            if (stopped) { source.Dispose(); sink.Dispose(); }
            else throw new IOException("worker-cleanup");
        }
    }
    private sealed class PendingPipeStream : Stream
    {
        private readonly System.IO.Pipes.AnonymousPipeClientStream pipe;
        public readonly ManualResetEventSlim Entered = new ManualResetEventSlim();
        public PendingPipeStream(string handle) { pipe = new System.IO.Pipes.AnonymousPipeClientStream(System.IO.Pipes.PipeDirection.In, handle); }
        public override int Read(byte[] bytes, int offset, int count) { Entered.Set(); return pipe.Read(bytes, offset, count); }
        protected override void Dispose(bool disposing) { if (disposing) { pipe.Dispose(); Entered.Dispose(); } base.Dispose(disposing); }
        public override bool CanRead { get { return true; } }
        public override bool CanWrite { get { return false; } }
        public override bool CanSeek { get { return false; } }
        public override long Length { get { throw new NotSupportedException(); } }
        public override long Position { get { throw new NotSupportedException(); } set { throw new NotSupportedException(); } }
        public override void Flush() { }
        public override long Seek(long offset, SeekOrigin origin) { throw new NotSupportedException(); }
        public override void SetLength(long value) { throw new NotSupportedException(); }
        public override void Write(byte[] bytes, int offset, int count) { throw new NotSupportedException(); }
    }
    public override Task FlushAsync(CancellationToken cancellationToken)
    {
        AsyncCalls++;
        throw new IOException("per-flush-async-scheduling");
    }
}
