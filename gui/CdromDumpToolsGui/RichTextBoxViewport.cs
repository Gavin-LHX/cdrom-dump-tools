using System.Runtime.InteropServices;

namespace CdromDumpToolsGui;

internal static class RichTextBoxViewport
{
    private const int WmSetRedraw = 0x000B;
    private const int EmGetScrollPos = 0x04DD;
    private const int EmSetScrollPos = 0x04DE;
    private const uint RdwInvalidate = 0x0001;
    private const uint RdwErase = 0x0004;
    private const uint RdwAllChildren = 0x0080;
    private const uint RdwFrame = 0x0400;

    internal readonly record struct State(
        int SelectionStart,
        int SelectionLength,
        Point ScrollPosition,
        bool WasAtBottom);

    public static State Capture(RichTextBox textBox)
    {
        ArgumentNullException.ThrowIfNull(textBox);
        var scrollPosition = new Point();
        _ = SendMessage(textBox.Handle, EmGetScrollPos, IntPtr.Zero, ref scrollPosition);
        return new State(
            textBox.SelectionStart,
            textBox.SelectionLength,
            scrollPosition,
            IsAtBottom(textBox));
    }

    public static void BeginBatch(RichTextBox textBox)
    {
        ArgumentNullException.ThrowIfNull(textBox);
        _ = SendMessage(textBox.Handle, WmSetRedraw, IntPtr.Zero, IntPtr.Zero);
    }

    public static void EndBatch(RichTextBox textBox)
    {
        ArgumentNullException.ThrowIfNull(textBox);
        _ = SendMessage(textBox.Handle, WmSetRedraw, new IntPtr(1), IntPtr.Zero);
        _ = RedrawWindow(
            textBox.Handle,
            IntPtr.Zero,
            IntPtr.Zero,
            RdwErase | RdwFrame | RdwInvalidate | RdwAllChildren);
        textBox.Update();
    }

    public static void Restore(RichTextBox textBox, State state)
    {
        ArgumentNullException.ThrowIfNull(textBox);
        var selectionStart = Math.Clamp(state.SelectionStart, 0, textBox.TextLength);
        var selectionLength = Math.Clamp(state.SelectionLength, 0, textBox.TextLength - selectionStart);
        textBox.Select(selectionStart, selectionLength);
        var scrollPosition = state.ScrollPosition;
        _ = SendMessage(textBox.Handle, EmSetScrollPos, IntPtr.Zero, ref scrollPosition);
    }

    public static void ScrollToEnd(RichTextBox textBox)
    {
        ArgumentNullException.ThrowIfNull(textBox);
        textBox.Select(textBox.TextLength, 0);
        textBox.SelectionColor = textBox.ForeColor;
        textBox.ScrollToCaret();
    }

    private static bool IsAtBottom(RichTextBox textBox)
    {
        var endPosition = textBox.GetPositionFromCharIndex(textBox.TextLength);
        return endPosition.Y >= 0 && endPosition.Y < textBox.ClientSize.Height;
    }

    [DllImport("user32.dll")]
    private static extern IntPtr SendMessage(IntPtr window, int message, IntPtr word, IntPtr data);

    [DllImport("user32.dll")]
    private static extern IntPtr SendMessage(IntPtr window, int message, IntPtr word, ref Point data);

    [DllImport("user32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool RedrawWindow(
        IntPtr window,
        IntPtr updateRectangle,
        IntPtr updateRegion,
        uint flags);
}
