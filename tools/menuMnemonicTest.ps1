# Menu mnemonic test window for nvaccess/nvda#20912.
#
# Question it answers: while a menu bar is active, can a mnemonic written in Han, Hiragana, Katakana, Hangul
# or Bopomofo be entered at all, and what does the window receive when it is typed through an IME?
#
# Manual use (needs an IME): powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -File menuMnemonicTest.ps1
# Automatic use (injects Unicode characters, no IME involved): add -Auto
#
# The menu is a native Win32 menu. Every message of interest and every activated item is written to the log box
# and to menuMnemonicTest.log next to this script.

param([switch]$Auto, [switch]$AutoIme, [string]$Layout = '00000804')

Add-Type -ReferencedAssemblies System.Windows.Forms, System.Drawing -TypeDefinition @"
using System;
using System.Drawing;
using System.IO;
using System.Runtime.InteropServices;
using System.Threading;
using System.Windows.Forms;

public class MnemonicTestForm : Form
{
    public TextBox LogBox = new TextBox();
    public TextBox InputBox = new TextBox();
    public Label Instructions = new Label();
    public string LogPath;
    public string LayoutId = "00000804";   // 00000804 = Chinese (Simplified) with Microsoft Pinyin, 00000409 = US English
    public string LastActivated;
    IntPtr hwnd;

    [StructLayout(LayoutKind.Sequential)] struct MOUSEINPUT { public int dx, dy; public uint mouseData, dwFlags, time; public IntPtr extra; }
    [StructLayout(LayoutKind.Sequential)] struct KEYBDINPUT { public ushort vk, scan; public uint flags, time; public IntPtr extra; }
    [StructLayout(LayoutKind.Explicit)] struct INPUTUNION { [FieldOffset(0)] public MOUSEINPUT mi; [FieldOffset(0)] public KEYBDINPUT ki; }
    [StructLayout(LayoutKind.Sequential)] struct INPUT { public uint type; public INPUTUNION u; }
    [DllImport("user32.dll")] static extern uint SendInput(uint n, INPUT[] inputs, int size);
    [DllImport("user32.dll")] static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] static extern bool SetForegroundWindow(IntPtr h);

    public MnemonicTestForm()
    {
        Text = "Menu mnemonic test";
        Width = 700; Height = 520;
        Instructions.Dock = DockStyle.Top; Instructions.Height = 150;
        Instructions.AccessibleName = "Instructions";
        InputBox.Dock = DockStyle.Top; InputBox.AccessibleName = "IME typing check";
        LogBox.Multiline = true; LogBox.ReadOnly = true; LogBox.ScrollBars = ScrollBars.Vertical;
        LogBox.Dock = DockStyle.Fill; LogBox.AccessibleName = "Log";
        Button copy = new Button(); copy.Text = "Copy log"; copy.Dock = DockStyle.Bottom;
        copy.Click += delegate { Clipboard.SetText(LogBox.Text); };
        Button clear = new Button(); clear.Text = "Clear log"; clear.Dock = DockStyle.Bottom;
        clear.Click += delegate { LogBox.Clear(); };
        Controls.Add(LogBox); Controls.Add(clear); Controls.Add(copy); Controls.Add(InputBox); Controls.Add(Instructions);
        InputBox.TabIndex = 0; LogBox.TabIndex = 1; copy.TabIndex = 2; clear.TabIndex = 3;
        Menu = new MainMenu();
        Shown += delegate { hwnd = Handle; };
    }

    public void AddMenu(string text)
    {
        MenuItem item = new MenuItem(text);
        item.Click += delegate { LastActivated = text; Write("ACTIVATED: " + text); };
        Menu.MenuItems.Add(item);
    }

    public void Write(string text)
    {
        string line = DateTime.Now.ToString("HH:mm:ss.fff") + "  " + text;
        if (InvokeRequired) { BeginInvoke(new Action<string>(WriteUi), line); } else { WriteUi(line); }
    }

    void WriteUi(string line)
    {
        LogBox.AppendText(line + "\r\n");
        try { File.AppendAllText(LogPath, line + "\r\n"); } catch { }
    }

    protected override void WndProc(ref Message m)
    {
        switch (m.Msg)
        {
            case 0x0116: Write("WM_INITMENU (menu mode entered)"); break;
            case 0x0120: Write("WM_MENUCHAR, no mnemonic matched, char=U+" + (m.WParam.ToInt64() & 0xFFFF).ToString("X4")); break;
            case 0x010D: Write("WM_IME_STARTCOMPOSITION"); break;
            case 0x010F: Write("WM_IME_COMPOSITION"); break;
            case 0x0286: Write("WM_IME_CHAR char=U+" + (m.WParam.ToInt64() & 0xFFFF).ToString("X4")); break;
        }
        base.WndProc(ref m);
    }

    static void Key(ushort vk, ushort scan, uint flags)
    {
        INPUT[] a = new INPUT[1];
        a[0].type = 1; a[0].u.ki.vk = vk; a[0].u.ki.scan = scan; a[0].u.ki.flags = flags;
        SendInput(1, a, Marshal.SizeOf(typeof(INPUT)));
    }
    static void Tap(ushort vk) { Key(vk, 0, 0); Key(vk, 0, 2); }
    static void SendUnicode(char c) { Key(0, c, 4); Key(0, c, 4 | 2); }

    [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
    [DllImport("user32.dll")] static extern bool AttachThreadInput(uint a, uint b, bool attach);
    [DllImport("user32.dll")] static extern bool BringWindowToTop(IntPtr h);
    [DllImport("kernel32.dll")] static extern uint GetCurrentThreadId();
    [DllImport("kernel32.dll")] static extern uint GetTickCount();
    [StructLayout(LayoutKind.Sequential)] struct LASTINPUTINFO { public uint cbSize; public uint dwTime; }
    [DllImport("user32.dll")] static extern bool GetLastInputInfo(ref LASTINPUTINFO p);

    // Brings this window to the foreground even when another program has it, by briefly sharing input state
    // with the current foreground thread. Keys are only injected once the window really is in front.
    bool EnsureForeground()
    {
        for (int i = 0; i < 10; i++)
        {
            if (GetForegroundWindow() == hwnd) return true;
            Invoke(new Action(delegate {
                IntPtr fg = GetForegroundWindow();
                uint pid;
                uint fgThread = GetWindowThreadProcessId(fg, out pid);
                uint ours = GetCurrentThreadId();
                bool attached = fgThread != 0 && fgThread != ours && AttachThreadInput(ours, fgThread, true);
                Activate(); BringWindowToTop(hwnd); SetForegroundWindow(hwnd);
                if (attached) AttachThreadInput(ours, fgThread, false);
            }));
            Thread.Sleep(250);
        }
        return GetForegroundWindow() == hwnd;
    }

    // True once the keyboard and mouse have been untouched for idleMs, so injected keys cannot mix with real ones.
    bool WaitForIdle(uint idleMs, int timeoutMs)
    {
        for (int waited = 0; waited <= timeoutMs; waited += 500)
        {
            LASTINPUTINFO li = new LASTINPUTINFO();
            li.cbSize = (uint)Marshal.SizeOf(typeof(LASTINPUTINFO));
            GetLastInputInfo(ref li);
            if (GetTickCount() - li.dwTime >= idleMs) return true;
            Thread.Sleep(500);
        }
        return false;
    }

    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern IntPtr LoadKeyboardLayout(string klid, uint flags);

    static void TypeKeys(params ushort[] vks) { foreach (ushort vk in vks) { Tap(vk); Thread.Sleep(80); } }

    string Codes(string s)
    {
        System.Text.StringBuilder sb = new System.Text.StringBuilder();
        foreach (char c in s) { sb.Append("U+" + ((int)c).ToString("X4") + " "); }
        return sb.ToString().Trim();
    }

    string TextBoxText()
    {
        return (string)Invoke(new Func<string>(delegate { return InputBox.Text; }));
    }

    // Types the pinyin "ren" and a space through the real IME, first into a text box, then while the menu bar is active.
    public void StartAutoIme()
    {
        Thread t = new Thread(delegate() { AutoImeRun(); });
        t.IsBackground = true; t.Start();
    }

    void AutoImeRun()
    {
        if (!WaitForIdle(5000, 30000)) { Write("AUTO-IME aborted, keyboard or mouse was used in the last 5 seconds"); BeginInvoke(new Action(Close)); return; }
        Thread.Sleep(800);
        Invoke(new Action(delegate {
            IntPtr h = LoadKeyboardLayout(LayoutId, 1);
            Write("AUTO-IME keyboard layout now " + h.ToInt64().ToString("X"));
            InputBox.Clear(); InputBox.Focus();
        }));
        Thread.Sleep(800);
        if (!EnsureForeground())
        {
            Write("AUTO-IME aborted, window is not in the foreground. foreground=" + GetForegroundWindow().ToInt64().ToString("X") + " ours=" + hwnd.ToInt64().ToString("X"));
            BeginInvoke(new Action(Close)); return;
        }

        // Control: does the IME turn ren + space into Han characters in a text box?
        for (int attempt = 1; attempt <= 2; attempt++)
        {
            Invoke(new Action(delegate { InputBox.Clear(); InputBox.Focus(); }));
            TypeKeys(0x52, 0x45, 0x4E); Thread.Sleep(500); TypeKeys(0x20); Thread.Sleep(600);
            string typed = TextBoxText();
            Write("AUTO-IME text box check " + attempt + ": [" + typed + "] " + Codes(typed));
            bool hasHan = false;
            foreach (char c in typed) { if (c > 0x2E80) hasHan = true; }
            if (hasHan || attempt == 2) break;
            Write("AUTO-IME no Han text, toggling Chinese/English mode with Shift");
            Tap(0x10); Thread.Sleep(500);
        }

        // Test: the same keys while the menu bar is active.
        Invoke(new Action(delegate { InputBox.Clear(); ActiveControl = null; }));
        LastActivated = null;
        Write("AUTO-IME tap Alt, then type ren and space through the IME");
        Tap(0x12); Thread.Sleep(400);
        TypeKeys(0x52, 0x45, 0x4E); Thread.Sleep(600); TypeKeys(0x20); Thread.Sleep(600);
        Write("AUTO-IME RESULT B1 (Chinese mode, ren + space) -> " + (LastActivated == null ? "no item activated" : "activated " + LastActivated));
        Tap(0x1B); Thread.Sleep(150); Tap(0x1B); Thread.Sleep(250);

        // B2: control, a Latin mnemonic while the IME is in Chinese mode.
        LastActivated = null;
        Write("AUTO-IME B2: tap Alt, then t, IME still in Chinese mode");
        Tap(0x12); Thread.Sleep(400); TypeKeys(0x54); Thread.Sleep(600);
        Write("AUTO-IME RESULT B2 (Chinese mode, t) -> " + (LastActivated == null ? "no item activated" : "activated " + LastActivated));
        Tap(0x1B); Thread.Sleep(150); Tap(0x1B); Thread.Sleep(250);

        // B3: switch the IME to English mode and repeat both.
        Tap(0x10); Thread.Sleep(500);
        LastActivated = null;
        Write("AUTO-IME B3: Shift pressed to toggle the IME mode, tap Alt, then ren + space");
        Tap(0x12); Thread.Sleep(400);
        TypeKeys(0x52, 0x45, 0x4E); Thread.Sleep(600); TypeKeys(0x20); Thread.Sleep(600);
        Write("AUTO-IME RESULT B3 (English mode, ren + space) -> " + (LastActivated == null ? "no item activated" : "activated " + LastActivated));
        Tap(0x1B); Thread.Sleep(150); Tap(0x1B); Thread.Sleep(250);
        LastActivated = null;
        Write("AUTO-IME B3b: tap Alt, then t, IME in the other mode");
        Tap(0x12); Thread.Sleep(400); TypeKeys(0x54); Thread.Sleep(600);
        Write("AUTO-IME RESULT B3b (other mode, t) -> " + (LastActivated == null ? "no item activated" : "activated " + LastActivated));
        Tap(0x1B); Thread.Sleep(150); Tap(0x1B); Thread.Sleep(250);
        Tap(0x10); Thread.Sleep(300);   // toggle back so the IME mode is left as it was found
        Write("AUTO-IME done");
        BeginInvoke(new Action(Close));
    }

    public void StartAuto(char[] chars)
    {
        Thread t = new Thread(delegate() { AutoRun(chars); });
        t.IsBackground = true; t.Start();
    }

    void AutoRun(char[] chars)
    {
        if (!WaitForIdle(5000, 30000)) { Write("AUTO aborted, keyboard or mouse was used in the last 5 seconds"); BeginInvoke(new Action(Close)); return; }
        Thread.Sleep(800);
        foreach (char c in chars)
        {
            string code = "U+" + ((int)c).ToString("X4");
            LastActivated = null;
            if (!EnsureForeground()) { Write("AUTO " + code + " skipped, window is not in the foreground"); continue; }
            Write("AUTO tap Alt, then inject " + code);
            Tap(0x12); Thread.Sleep(300);
            SendUnicode(c); Thread.Sleep(500);
            Write("AUTO RESULT " + code + " -> " + (LastActivated == null ? "no item activated" : "activated " + LastActivated));
            Tap(0x1B); Thread.Sleep(150); Tap(0x1B); Thread.Sleep(250);
        }
        Write("AUTO done");
        BeginInvoke(new Action(Close));
    }
}
"@

$here = if ($PSScriptRoot) { $PSScriptRoot } else { (Get-Location).Path }
$form = New-Object MnemonicTestForm
$form.LogPath = Join-Path $here 'menuMnemonicTest.log'
if (Test-Path $form.LogPath) { Remove-Item $form.LogPath }

# Menu bar items, each with an explicit mnemonic in a different script. The last one is a Latin control.
$form.AddMenu('&人民')        # Han, U+4EBA, the first candidate for the pinyin "ren"
$form.AddMenu('&任务')        # Han, U+4EFB
$form.AddMenu('&ひらがな')    # Hiragana, U+3072
$form.AddMenu('&カタカナ')    # Katakana, U+30AB
$form.AddMenu('&한글')        # Hangul, U+D55C
$form.AddMenu('&ㄅㄆㄇ')      # Bopomofo, U+3105
$form.AddMenu('&Tools')       # Latin control, t

$form.Instructions.Text = @'
菜单助记符输入测试。菜单栏有六项，访问键依次是：任（汉字）、ひ（平假名）、カ（片假名）、한（谚文）、ㄅ（注音符号）、T（拉丁字母，作对照）。
手动测试：1. 先在下面的“输入法检查”框里确认输入法能正常输出文字。2. 按 Alt 进入菜单栏。3. 用输入法输入对应的访问键（例如拼音输入 ren 再按空格）。4. 按 Esc 退出菜单。5. Tab 到“日志”框阅读结果。
日志里出现“ACTIVATED: ...”表示该菜单项被访问键触发；出现“WM_MENUCHAR ... char=U+xxxx”表示窗口收到了字符但没有匹配的访问键，xxxx 就是实际收到的字符。
'@

if ($AutoIme) {
    $form.LayoutId = $Layout
    $form.Add_Shown({ $form.StartAutoIme() })
}
if ($Auto) {
    $form.Add_Shown({ $form.StartAuto([char[]]@(0x4EFB, 0x3072, 0x30AB, 0xD55C, 0x3105, 0x0074, 0x0078)) })
}

[System.Windows.Forms.Application]::Run($form)
Get-Content -LiteralPath $form.LogPath -Encoding UTF8
