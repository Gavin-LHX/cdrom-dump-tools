using System.ComponentModel;
using System.Runtime.InteropServices;
using System.Security.Cryptography;
using System.Text;

namespace CdromDumpToolsGui.Core;

public static class SecretProtector
{
    private const string Prefix = "dpapi-v1:";
    private const int CryptProtectUiForbidden = 0x1;
    private static readonly byte[] OptionalEntropy = Encoding.UTF8.GetBytes("CdromDumpToolsGui.AiSecrets.v1");

    public static string Protect(string? plaintext)
    {
        if (string.IsNullOrEmpty(plaintext))
        {
            return string.Empty;
        }
        EnsureWindows();
        var clearBytes = Encoding.UTF8.GetBytes(plaintext);
        try
        {
            return Prefix + Convert.ToBase64String(Transform(clearBytes, protect: true));
        }
        finally
        {
            CryptographicOperations.ZeroMemory(clearBytes);
        }
    }

    public static bool TryUnprotect(string? protectedValue, out string plaintext)
    {
        plaintext = string.Empty;
        if (string.IsNullOrEmpty(protectedValue))
        {
            return true;
        }
        if (!OperatingSystem.IsWindows() || !protectedValue.StartsWith(Prefix, StringComparison.Ordinal))
        {
            return false;
        }

        byte[] protectedBytes;
        try
        {
            protectedBytes = Convert.FromBase64String(protectedValue[Prefix.Length..]);
        }
        catch (FormatException)
        {
            return false;
        }

        try
        {
            var clearBytes = Transform(protectedBytes, protect: false);
            try
            {
                plaintext = Encoding.UTF8.GetString(clearBytes);
                return true;
            }
            finally
            {
                CryptographicOperations.ZeroMemory(clearBytes);
            }
        }
        catch (Exception exception) when (exception is CryptographicException or Win32Exception)
        {
            plaintext = string.Empty;
            return false;
        }
        finally
        {
            CryptographicOperations.ZeroMemory(protectedBytes);
        }
    }

    private static byte[] Transform(byte[] input, bool protect)
    {
        var inputBlob = CreateBlob(input);
        var entropyBlob = CreateBlob(OptionalEntropy);
        DataBlob outputBlob = default;
        IntPtr description = IntPtr.Zero;
        try
        {
            var success = protect
                ? CryptProtectData(
                    ref inputBlob,
                    IntPtr.Zero,
                    ref entropyBlob,
                    IntPtr.Zero,
                    IntPtr.Zero,
                    CryptProtectUiForbidden,
                    out outputBlob)
                : CryptUnprotectData(
                    ref inputBlob,
                    out description,
                    ref entropyBlob,
                    IntPtr.Zero,
                    IntPtr.Zero,
                    CryptProtectUiForbidden,
                    out outputBlob);
            if (!success)
            {
                throw new CryptographicException(new Win32Exception(Marshal.GetLastWin32Error()).Message);
            }

            var output = new byte[outputBlob.Length];
            Marshal.Copy(outputBlob.Data, output, 0, output.Length);
            return output;
        }
        finally
        {
            FreeBlob(ref inputBlob, clear: true);
            FreeBlob(ref entropyBlob, clear: false);
            if (outputBlob.Data != IntPtr.Zero)
            {
                LocalFree(outputBlob.Data);
            }
            if (description != IntPtr.Zero)
            {
                LocalFree(description);
            }
        }
    }

    private static DataBlob CreateBlob(byte[] bytes)
    {
        var pointer = Marshal.AllocHGlobal(bytes.Length);
        Marshal.Copy(bytes, 0, pointer, bytes.Length);
        return new DataBlob { Length = bytes.Length, Data = pointer };
    }

    private static void FreeBlob(ref DataBlob blob, bool clear)
    {
        if (blob.Data == IntPtr.Zero)
        {
            return;
        }
        if (clear && blob.Length > 0)
        {
            Marshal.Copy(new byte[blob.Length], 0, blob.Data, blob.Length);
        }
        Marshal.FreeHGlobal(blob.Data);
        blob = default;
    }

    private static void EnsureWindows()
    {
        if (!OperatingSystem.IsWindows())
        {
            throw new PlatformNotSupportedException("Windows DPAPI is required to protect saved API keys.");
        }
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct DataBlob
    {
        public int Length;
        public IntPtr Data;
    }

    [DllImport("Crypt32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool CryptProtectData(
        ref DataBlob dataIn,
        IntPtr description,
        ref DataBlob optionalEntropy,
        IntPtr reserved,
        IntPtr prompt,
        int flags,
        out DataBlob dataOut);

    [DllImport("Crypt32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool CryptUnprotectData(
        ref DataBlob dataIn,
        out IntPtr description,
        ref DataBlob optionalEntropy,
        IntPtr reserved,
        IntPtr prompt,
        int flags,
        out DataBlob dataOut);

    [DllImport("Kernel32.dll")]
    private static extern IntPtr LocalFree(IntPtr memory);
}
