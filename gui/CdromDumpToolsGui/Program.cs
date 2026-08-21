using CdromDumpToolsGui.Core;

namespace CdromDumpToolsGui;

internal static class Program
{
    [STAThread]
    private static int Main(string[] args)
    {
        var isSelfTest = args.Length == 1
            && (string.Equals(args[0], "--self-test", StringComparison.OrdinalIgnoreCase)
                || string.Equals(args[0], "--self-test-embedded-script", StringComparison.OrdinalIgnoreCase));
        if (isSelfTest)
        {
            return RunEmbeddedScriptSelfTest();
        }

        Application.SetHighDpiMode(HighDpiMode.PerMonitorV2);
        Application.EnableVisualStyles();
        Application.SetCompatibleTextRenderingDefault(false);

        bool isElevated;
        try
        {
            isElevated = ElevationGuard.IsCurrentProcessElevated();
        }
        catch (Exception exception)
        {
            MessageBox.Show(
                "无法确认当前进程是否已提升权限，因此为避免以管理员权限运行转换器，程序将退出。\n\n" + exception.Message,
                "安全检查失败",
                MessageBoxButtons.OK,
                MessageBoxIcon.Error);
            return 3;
        }

        if (ElevationGuard.ShouldRefuseInteractiveLaunch(isSelfTest, isElevated))
        {
            MessageBox.Show(
                "检测到当前程序已使用提升后的管理员令牌启动。\n\n请关闭程序，并以普通用户身份重新运行；不要选择“以管理员身份运行”。",
                "拒绝以管理员权限运行",
                MessageBoxButtons.OK,
                MessageBoxIcon.Error);
            return 2;
        }

        Application.Run(new MainForm());
        return 0;
    }

    private static int RunEmbeddedScriptSelfTest()
    {
        try
        {
            using var lease = EmbeddedConverterScript.AcquireVerifiedExecutionLease();
            if (!File.Exists(lease.ScriptPath)
                || !string.Equals(
                    Directory.GetParent(lease.ScriptPath)?.Name,
                    EmbeddedConverterScript.EmbeddedSha256ForChecks,
                    StringComparison.OrdinalIgnoreCase))
            {
                return 1;
            }

            return 0;
        }
        catch
        {
            return 1;
        }
    }
}
