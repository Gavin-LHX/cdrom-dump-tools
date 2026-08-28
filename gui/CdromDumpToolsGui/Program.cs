using CdromDumpToolsGui.Core;

namespace CdromDumpToolsGui;

internal static class Program
{
    [STAThread]
    private static int Main(string[] args)
    {
        var isEmbeddedScriptSelfTest = args.Length == 1
            && (string.Equals(args[0], "--self-test", StringComparison.OrdinalIgnoreCase)
                || string.Equals(args[0], "--self-test-embedded-script", StringComparison.OrdinalIgnoreCase));
        var isLogViewportSelfTest = args.Length == 1
            && string.Equals(args[0], "--self-test-log-viewport", StringComparison.OrdinalIgnoreCase);
        var isSelfTest = isEmbeddedScriptSelfTest || isLogViewportSelfTest;
        if (isEmbeddedScriptSelfTest)
        {
            return RunEmbeddedScriptSelfTest();
        }
        if (isLogViewportSelfTest)
        {
            return RunLogViewportSelfTest();
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

    private static int RunLogViewportSelfTest()
    {
        try
        {
            Application.SetHighDpiMode(HighDpiMode.PerMonitorV2);
            Application.EnableVisualStyles();
            using var host = new Form
            {
                ShowInTaskbar = false,
                StartPosition = FormStartPosition.Manual,
                Location = new Point(-32000, -32000),
                ClientSize = new Size(480, 180),
            };
            using var log = new RichTextBox
            {
                Dock = DockStyle.Fill,
                ReadOnly = true,
                ScrollBars = RichTextBoxScrollBars.Vertical,
                BorderStyle = BorderStyle.FixedSingle,
            };
            host.Controls.Add(log);
            host.Show();

            for (var index = 1; index <= 240; index++)
            {
                var appendViewport = RichTextBoxViewport.Capture(log);
                if (!appendViewport.WasAtBottom)
                {
                    return 1;
                }
                RichTextBoxViewport.BeginBatch(log);
                try
                {
                    log.AppendText($"log line {index:D3}" + Environment.NewLine);
                    RichTextBoxViewport.ScrollToEnd(log);
                }
                finally
                {
                    RichTextBoxViewport.EndBatch(log);
                }
                Application.DoEvents();
            }
            if (!RichTextBoxViewport.Capture(log).WasAtBottom)
            {
                return 1;
            }

            var middleLine = log.GetFirstCharIndexFromLine(120);
            log.Select(middleLine, "log line 121".Length);
            log.ScrollToCaret();
            Application.DoEvents();

            var before = RichTextBoxViewport.Capture(log);
            if (before.WasAtBottom)
            {
                return 1;
            }
            RichTextBoxViewport.BeginBatch(log);
            try
            {
                log.Select(log.TextLength, 0);
                log.AppendText(Environment.NewLine + "new background log line");
                RichTextBoxViewport.Restore(log, before);
            }
            finally
            {
                RichTextBoxViewport.EndBatch(log);
            }
            Application.DoEvents();
            var after = RichTextBoxViewport.Capture(log);

            return after.SelectionStart == before.SelectionStart
                && after.SelectionLength == before.SelectionLength
                && after.ScrollPosition == before.ScrollPosition
                ? 0
                : 1;
        }
        catch
        {
            return 1;
        }
    }
}
