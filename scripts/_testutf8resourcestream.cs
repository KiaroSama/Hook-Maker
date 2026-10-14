// Lazy transport fixture: validates resource bounds without allocating a large
// body. Short reads and a pending async read model transport behavior, not UTF-8.
using System;
using System.IO;
using System.Threading;
using System.Threading.Tasks;

public sealed class Utf8ResourceStream : Stream
{
    private readonly long length;
    private long position;
    private readonly byte[] block = new byte[65536];
    public int MaximumReadSize { get; private set; }
    public int ShortReadSize { get; set; }
    public bool Stall { get; set; }
    public byte[] Patch { get; set; }
    public long PatchOffset { get; set; }
    public Utf8ResourceStream(long size)
    {
        length = size;
        for (int i = 0; i < block.Length; i++) block[i] = 97;
    }
    public override int Read(byte[] buffer, int offset, int count)
    {
        MaximumReadSize = Math.Max(MaximumReadSize, count);
        int n = (int)Math.Min(count, length - position);
        if (ShortReadSize > 0) n = Math.Min(n, ShortReadSize);
        Buffer.BlockCopy(block, 0, buffer, offset, n);
        if (Patch != null)
        {
            for (int i = 0; i < Patch.Length; i++)
            {
                long at = PatchOffset + i;
                if (at >= position && at < position + n) buffer[offset + (int)(at - position)] = Patch[i];
            }
        }
        position += n;
        return n;
    }
    public override Task<int> ReadAsync(byte[] buffer, int offset, int count, CancellationToken cancellationToken)
    {
        if (Stall) return new TaskCompletionSource<int>().Task;
        return Task.FromResult(Read(buffer, offset, count));
    }
    public override bool CanRead { get { return true; } }
    public override bool CanSeek { get { return false; } }
    public override bool CanWrite { get { return false; } }
    public override long Length { get { return length; } }
    public override long Position { get { return position; } set { throw new NotSupportedException(); } }
    public override void Flush() { }
    public override long Seek(long offset, SeekOrigin origin) { throw new NotSupportedException(); }
    public override void SetLength(long value) { throw new NotSupportedException(); }
    public override void Write(byte[] buffer, int offset, int count) { throw new NotSupportedException(); }
}
