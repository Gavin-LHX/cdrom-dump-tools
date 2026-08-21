using System.ComponentModel;
using System.Runtime.InteropServices;
using Microsoft.Win32.SafeHandles;

namespace CdromDumpToolsGui.Core;

public static class ElevationGuard
{
    private const uint TokenQuery = 0x0008;
    private const int TokenElevationInformationClass = 20;

    public static bool ShouldRefuseInteractiveLaunch(bool isSelfTest, bool isElevated) =>
        !isSelfTest && isElevated;

    public static bool IsCurrentProcessElevated()
    {
        if (!OperatingSystem.IsWindows())
        {
            return false;
        }

        if (!OpenProcessToken(GetCurrentProcess(), TokenQuery, out var token))
        {
            throw new Win32Exception(Marshal.GetLastWin32Error(), "Unable to query the current process token.");
        }

        using (token)
        {
            var elevation = new TokenElevation();
            var elevationSize = Marshal.SizeOf<TokenElevation>();
            if (!GetTokenInformation(
                    token,
                    TokenElevationInformationClass,
                    ref elevation,
                    elevationSize,
                    out _))
            {
                throw new Win32Exception(Marshal.GetLastWin32Error(), "Unable to query token elevation.");
            }

            return elevation.TokenIsElevated != 0;
        }
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct TokenElevation
    {
        public int TokenIsElevated;
    }

    [DllImport("kernel32.dll")]
    private static extern IntPtr GetCurrentProcess();

    [DllImport("advapi32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool OpenProcessToken(
        IntPtr processHandle,
        uint desiredAccess,
        out SafeAccessTokenHandle tokenHandle);

    [DllImport("advapi32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool GetTokenInformation(
        SafeAccessTokenHandle tokenHandle,
        int tokenInformationClass,
        ref TokenElevation tokenInformation,
        int tokenInformationLength,
        out int returnLength);
}
