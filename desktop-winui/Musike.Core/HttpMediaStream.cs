namespace Musike.Core;

/// <summary>A bounded, seekable HTTP range cache. Windows receives bytes, never a URL to open itself.</summary>
public sealed class HttpMediaStream : Stream
{
    private const int ChunkSize = 256 * 1024;
    private const int CacheChunks = 8;
    private readonly long length;
    private readonly Func<long, int, CancellationToken, Task<byte[]>> fetch;
    private readonly SemaphoreSlim gate = new(1, 1);
    private readonly CancellationTokenSource lifetime = new();
    private readonly CancellationToken lifetimeToken;
    private readonly Dictionary<long, byte[]> cache = [];
    private readonly LinkedList<long> order = [];
    private long position;
    private bool disposed;
    public Exception? LastError { get; private set; }

    public HttpMediaStream(long length, Func<long, int, CancellationToken, Task<byte[]>> fetch)
    {
        if (length <= 0) throw new ArgumentOutOfRangeException(nameof(length));
        this.length = length;
        this.fetch = fetch;
        lifetimeToken = lifetime.Token;
    }
    public override bool CanRead => !disposed;
    public override bool CanSeek => !disposed;
    public override bool CanWrite => false;
    public override long Length { get { ObjectDisposedException.ThrowIf(disposed, this); return length; } }
    public override long Position { get => Interlocked.Read(ref position); set => Seek(value, SeekOrigin.Begin); }

    public async Task PrimeAsync(CancellationToken ct = default)
    {
        using var linked = CancellationTokenSource.CreateLinkedTokenSource(ct, lifetimeToken);
        await gate.WaitAsync(linked.Token).ConfigureAwait(false);
        try { await ChunkAsync(0, linked.Token).ConfigureAwait(false); }
        finally { gate.Release(); }
    }
    public override int Read(byte[] buffer, int offset, int count) => ReadAsync(buffer.AsMemory(offset, count)).AsTask().GetAwaiter().GetResult();
    public override Task<int> ReadAsync(byte[] buffer, int offset, int count, CancellationToken ct) => ReadAsync(buffer.AsMemory(offset, count), ct).AsTask();
    public override async ValueTask<int> ReadAsync(Memory<byte> buffer, CancellationToken ct = default)
    {
        ObjectDisposedException.ThrowIf(disposed, this);
        using var linked = CancellationTokenSource.CreateLinkedTokenSource(ct, lifetimeToken);
        await gate.WaitAsync(linked.Token).ConfigureAwait(false);
        try
        {
            ObjectDisposedException.ThrowIf(disposed, this);
            var read = 0;
            while (read < buffer.Length && position < length)
            {
                var start = position / ChunkSize * ChunkSize;
                var chunk = await ChunkAsync(start, linked.Token).ConfigureAwait(false);
                var offset = (int)(position - start);
                var count = Math.Min(buffer.Length - read, chunk.Length - offset);
                chunk.AsMemory(offset, count).CopyTo(buffer[read..]);
                position += count;
                read += count;
            }
            return read;
        }
        catch (Exception error) when (!lifetimeToken.IsCancellationRequested && !ct.IsCancellationRequested)
        {
            LastError = error;
            throw;
        }
        finally { gate.Release(); }
    }
    private async Task<byte[]> ChunkAsync(long start, CancellationToken ct)
    {
        ct.ThrowIfCancellationRequested();
        if (cache.TryGetValue(start, out var cached))
        {
            order.Remove(start); order.AddLast(start);
            return cached;
        }
        var count = (int)Math.Min(ChunkSize, length - start);
        var bytes = await fetch(start, count, ct).ConfigureAwait(false);
        if (bytes.Length != count) throw new EndOfStreamException("El servidor ha cortado el audio antes de completar los bytes solicitados.");
        cache.Add(start, bytes);
        order.AddLast(start);
        if (cache.Count > CacheChunks) { cache.Remove(order.First!.Value); order.RemoveFirst(); }
        return bytes;
    }
    public override long Seek(long offset, SeekOrigin origin)
    {
        ObjectDisposedException.ThrowIf(disposed, this);
        gate.Wait(lifetimeToken);
        try
        {
            var next = checked(origin switch
            {
                SeekOrigin.Begin => offset,
                SeekOrigin.Current => position + offset,
                SeekOrigin.End => length + offset,
                _ => throw new ArgumentOutOfRangeException(nameof(origin))
            });
            if (next < 0) throw new IOException("No se puede buscar antes del principio del audio.");
            position = next;
            return next;
        }
        finally { gate.Release(); }
    }
    protected override void Dispose(bool disposing)
    {
        if (disposing && !disposed)
        {
            disposed = true;
            lifetime.Cancel();
            // Do not wait for decoder I/O on the UI thread. Cancellation releases pending reads.
            if (gate.Wait(0)) { try { cache.Clear(); order.Clear(); } finally { gate.Release(); } }
        }
        base.Dispose(disposing);
    }
    public override void Flush() { }
    public override void SetLength(long value) => throw new NotSupportedException();
    public override void Write(byte[] buffer, int offset, int count) => throw new NotSupportedException();
}
