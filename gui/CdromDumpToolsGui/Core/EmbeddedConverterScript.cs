using System.Reflection;
using System.Security.Cryptography;

namespace CdromDumpToolsGui.Core;

public static class EmbeddedConverterScript
{
    public const string ScriptFileName = "bin_to_audio_windows.ps1";
    internal const string ResourceName = "CdromDumpToolsGui.Resources.bin_to_audio_windows.ps1";

    private static readonly Lazy<EmbeddedPayload> Payload = new(
        LoadPayload,
        LazyThreadSafetyMode.ExecutionAndPublication);

    public static string EnsureExtracted()
    {
        var localAppData = Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData);
        if (string.IsNullOrWhiteSpace(localAppData))
        {
            throw new InvalidOperationException("Windows did not provide a local application-data directory.");
        }

        var applicationRoot = Path.Combine(localAppData, "CdromDumpToolsGui");
        EnsureOrdinaryDirectory(applicationRoot);
        return EnsureExtractedUnder(Path.Combine(applicationRoot, "ConverterScripts"));
    }

    public static VerifiedExecutionLease AcquireVerifiedExecutionLease()
    {
        var localAppData = Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData);
        if (string.IsNullOrWhiteSpace(localAppData))
        {
            throw new InvalidOperationException("Windows did not provide a local application-data directory.");
        }

        var applicationRoot = Path.Combine(localAppData, "CdromDumpToolsGui");
        EnsureOrdinaryDirectory(applicationRoot);
        return AcquireVerifiedExecutionLeaseUnder(Path.Combine(applicationRoot, "ConverterScripts"));
    }

    internal static string EnsureExtractedUnder(string scriptsRoot)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(scriptsRoot);

        var payload = Payload.Value;
        var root = Path.GetFullPath(scriptsRoot);
        EnsureOrdinaryDirectory(root);

        var versionDirectory = Path.Combine(root, payload.Sha256Hex);
        EnsureOrdinaryDirectory(versionDirectory);
        var targetPath = Path.Combine(versionDirectory, ScriptFileName);

        using var extractionLock = AcquireExtractionLock(versionDirectory);

        if (File.Exists(targetPath))
        {
            EnsureOrdinaryFile(targetPath);
            if (MatchesPayload(targetPath, payload))
            {
                return targetPath;
            }
        }
        else if (Directory.Exists(targetPath))
        {
            throw new IOException($"The converter-script path is a directory: {targetPath}");
        }

        var temporaryPath = Path.Combine(
            versionDirectory,
            $".{ScriptFileName}.{Guid.NewGuid():N}.tmp");
        try
        {
            var options = new FileStreamOptions
            {
                Mode = FileMode.CreateNew,
                Access = FileAccess.Write,
                Share = FileShare.None,
                Options = FileOptions.WriteThrough,
            };
            using (var stream = new FileStream(temporaryPath, options))
            {
                stream.Write(payload.Bytes);
                stream.Flush(flushToDisk: true);
            }

            if (!MatchesPayload(temporaryPath, payload))
            {
                throw new CryptographicException("The extracted converter script failed its SHA-256 check.");
            }

            if (File.Exists(targetPath))
            {
                EnsureOrdinaryFile(targetPath);
            }
            File.Move(temporaryPath, targetPath, overwrite: true);

            EnsureOrdinaryFile(targetPath);
            if (!MatchesPayload(targetPath, payload))
            {
                throw new CryptographicException("The installed converter script failed its SHA-256 check.");
            }

            return targetPath;
        }
        finally
        {
            try
            {
                File.Delete(temporaryPath);
            }
            catch (Exception exception) when (exception is IOException or UnauthorizedAccessException)
            {
                // A uniquely named incomplete temp file is never executed.
            }
        }
    }

    internal static byte[] ReadEmbeddedBytesForChecks() => Payload.Value.Bytes.ToArray();

    internal static string EmbeddedSha256ForChecks => Payload.Value.Sha256Hex;

    internal static VerifiedExecutionLease AcquireVerifiedExecutionLeaseUnder(string scriptsRoot)
    {
        const int maximumAttempts = 3;
        var payload = Payload.Value;

        for (var attempt = 1; attempt <= maximumAttempts; attempt++)
        {
            var path = EnsureExtractedUnder(scriptsRoot);
            FileStream? stream = null;
            try
            {
                // Read sharing lets PowerShell open the script, while denying writers and deleters
                // until the child process has completely exited and the lease is disposed.
                stream = new FileStream(
                    path,
                    FileMode.Open,
                    FileAccess.Read,
                    FileShare.Read);
                EnsureOrdinaryFile(path);
                if (!MatchesPayload(stream, payload))
                {
                    throw new CryptographicException(
                        "The converter script changed before its verified execution lease was acquired.");
                }

                return new VerifiedExecutionLease(path, stream);
            }
            catch (Exception exception) when (
                attempt < maximumAttempts
                && exception is IOException or UnauthorizedAccessException or CryptographicException)
            {
                stream?.Dispose();
            }
            catch
            {
                stream?.Dispose();
                throw;
            }
        }

        throw new CryptographicException("Unable to acquire a verified converter-script execution lease.");
    }

    private static FileStream AcquireExtractionLock(string versionDirectory)
    {
        var lockPath = Path.Combine(versionDirectory, ".extract.lock");
        if (File.Exists(lockPath))
        {
            EnsureOrdinaryFile(lockPath);
        }
        else if (Directory.Exists(lockPath))
        {
            throw new IOException($"The converter-script lock path is a directory: {lockPath}");
        }

        var deadline = DateTime.UtcNow.AddSeconds(15);
        while (true)
        {
            try
            {
                var stream = new FileStream(lockPath, new FileStreamOptions
                {
                    Mode = FileMode.OpenOrCreate,
                    Access = FileAccess.ReadWrite,
                    Share = FileShare.None,
                    Options = FileOptions.WriteThrough,
                });

                try
                {
                    EnsureOrdinaryFile(lockPath);
                    return stream;
                }
                catch
                {
                    stream.Dispose();
                    throw;
                }
            }
            catch (IOException) when (DateTime.UtcNow < deadline)
            {
                Thread.Sleep(25);
            }
        }
    }

    private static EmbeddedPayload LoadPayload()
    {
        var assembly = typeof(EmbeddedConverterScript).Assembly;
        using var stream = assembly.GetManifestResourceStream(ResourceName)
            ?? throw new InvalidOperationException($"Embedded converter resource is missing: {ResourceName}");
        using var memory = new MemoryStream();
        stream.CopyTo(memory);
        var bytes = memory.ToArray();

        if (bytes.Length < 3 || bytes[0] != 0xEF || bytes[1] != 0xBB || bytes[2] != 0xBF)
        {
            throw new InvalidDataException("The embedded converter script must retain its UTF-8 BOM.");
        }

        var hash = SHA256.HashData(bytes);
        return new EmbeddedPayload(bytes, hash, Convert.ToHexString(hash).ToLowerInvariant());
    }

    private static bool MatchesPayload(string path, EmbeddedPayload payload)
    {
        using var stream = new FileStream(
            path,
            FileMode.Open,
            FileAccess.Read,
            FileShare.Read | FileShare.Delete);
        return MatchesPayload(stream, payload);
    }

    private static bool MatchesPayload(FileStream stream, EmbeddedPayload payload)
    {
        if (stream.Length != payload.Bytes.LongLength)
        {
            return false;
        }

        stream.Position = 0;
        var actualHash = SHA256.HashData(stream);
        return CryptographicOperations.FixedTimeEquals(actualHash, payload.Sha256);
    }

    private static void EnsureOrdinaryDirectory(string path)
    {
        Directory.CreateDirectory(path);
        var attributes = File.GetAttributes(path);
        if ((attributes & FileAttributes.Directory) == 0
            || (attributes & FileAttributes.ReparsePoint) != 0)
        {
            throw new IOException($"Converter-script directory is not an ordinary directory: {path}");
        }
    }

    private static void EnsureOrdinaryFile(string path)
    {
        var attributes = File.GetAttributes(path);
        if ((attributes & FileAttributes.Directory) != 0
            || (attributes & FileAttributes.ReparsePoint) != 0)
        {
            throw new IOException($"Converter-script file is not an ordinary file: {path}");
        }
    }

    private sealed record EmbeddedPayload(byte[] Bytes, byte[] Sha256, string Sha256Hex);

    public sealed class VerifiedExecutionLease : IDisposable
    {
        private FileStream? _stream;

        internal VerifiedExecutionLease(string scriptPath, FileStream stream)
        {
            ScriptPath = scriptPath;
            _stream = stream;
        }

        public string ScriptPath { get; }

        public void Dispose()
        {
            Interlocked.Exchange(ref _stream, null)?.Dispose();
        }
    }
}
