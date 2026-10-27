# Dumps the MSAA properties of an application's menu bar and drop-down menus, the way NVDA's IAccessible objects see them.
# Used for nvaccess/nvda#20912 to show the real name, role, state and keyboard shortcut of menu items.
#
# Usage: powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -File msaaMenuDump.ps1 -ExePath "C:\...\app.exe" -OutFile dump.txt
#
# The script starts the application if it is not running, brings its window to the front, and opens each menu with
# Alt, Down, Esc, Right. It only sends keys while the application window is in the foreground and the keyboard and
# mouse have been idle for 5 seconds. If it started the application, it closes it again at the end.

param(
    [Parameter(Mandatory = $true)][string]$ExePath,
    [string]$OutFile,
    [int]$MaxMenus = 12
)

Add-Type -ReferencedAssemblies Accessibility -TypeDefinition @"
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;
using Accessibility;

public static class MsaaDump
{
    [DllImport("oleacc.dll")] static extern int AccessibleObjectFromWindow(IntPtr hwnd, uint id, ref Guid iid, [MarshalAs(UnmanagedType.Interface)] out IAccessible acc);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern int GetClassName(IntPtr h, StringBuilder s, int n);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern int GetWindowText(IntPtr h, StringBuilder s, int n);
    [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
    delegate bool EnumProc(IntPtr h, IntPtr l);
    [DllImport("user32.dll")] static extern bool EnumWindows(EnumProc p, IntPtr l);
    [DllImport("user32.dll")] static extern bool IsWindowVisible(IntPtr h);
    [DllImport("user32.dll")] static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] static extern bool SetForegroundWindow(IntPtr h);
    [DllImport("user32.dll")] static extern bool BringWindowToTop(IntPtr h);
    [DllImport("user32.dll")] static extern bool ShowWindow(IntPtr h, int cmd);
    [DllImport("user32.dll")] static extern bool AttachThreadInput(uint a, uint b, bool attach);
    [DllImport("kernel32.dll")] static extern uint GetCurrentThreadId();
    [DllImport("kernel32.dll")] static extern uint GetTickCount();

    [StructLayout(LayoutKind.Sequential)] struct LASTINPUTINFO { public uint cbSize; public uint dwTime; }
    [DllImport("user32.dll")] static extern bool GetLastInputInfo(ref LASTINPUTINFO p);
    [StructLayout(LayoutKind.Sequential)] struct MOUSEINPUT { public int dx, dy; public uint mouseData, dwFlags, time; public IntPtr extra; }
    [StructLayout(LayoutKind.Sequential)] struct KEYBDINPUT { public ushort vk, scan; public uint flags, time; public IntPtr extra; }
    [StructLayout(LayoutKind.Explicit)] struct INPUTUNION { [FieldOffset(0)] public MOUSEINPUT mi; [FieldOffset(0)] public KEYBDINPUT ki; }
    [StructLayout(LayoutKind.Sequential)] struct INPUT { public uint type; public INPUTUNION u; }
    [DllImport("user32.dll")] static extern uint SendInput(uint n, INPUT[] inputs, int size);
    [DllImport("user32.dll")] static extern bool PostMessage(IntPtr h, uint msg, IntPtr w, IntPtr l);

    static Guid IID_IAccessible = new Guid("618736E0-3C3D-11CF-810C-00AA00389B71");
    static StringBuilder log = new StringBuilder();

    static void Out(string line) { log.AppendLine(line); }

    static void Tap(ushort vk)
    {
        INPUT[] a = new INPUT[2];
        a[0].type = 1; a[0].u.ki.vk = vk;
        a[1].type = 1; a[1].u.ki.vk = vk; a[1].u.ki.flags = 2;
        SendInput(2, a, Marshal.SizeOf(typeof(INPUT)));
    }

    static bool WaitForIdle(uint idleMs, int timeoutMs)
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

    static bool Foreground(IntPtr hwnd)
    {
        for (int i = 0; i < 10; i++)
        {
            if (GetForegroundWindow() == hwnd) return true;
            IntPtr fg = GetForegroundWindow();
            uint pid;
            uint fgThread = GetWindowThreadProcessId(fg, out pid);
            uint ours = GetCurrentThreadId();
            bool attached = fgThread != 0 && fgThread != ours && AttachThreadInput(ours, fgThread, true);
            ShowWindow(hwnd, 9);
            BringWindowToTop(hwnd); SetForegroundWindow(hwnd);
            if (attached) AttachThreadInput(ours, fgThread, false);
            Thread.Sleep(300);
        }
        return GetForegroundWindow() == hwnd;
    }

    static string Cls(IntPtr h) { StringBuilder s = new StringBuilder(256); GetClassName(h, s, 256); return s.ToString(); }
    static string Title(IntPtr h) { StringBuilder s = new StringBuilder(256); GetWindowText(h, s, 256); return s.ToString(); }

    static string RoleName(int r)
    {
        switch (r)
        {
            case 2: return "MENUBAR"; case 11: return "MENUPOPUP"; case 12: return "MENUITEM"; case 21: return "SEPARATOR";
            case 43: return "PUSHBUTTON"; case 9: return "WINDOW"; default: return "role" + r;
        }
    }

    static string StateText(int s)
    {
        List<string> f = new List<string>();
        if ((s & 0x1) != 0) f.Add("UNAVAILABLE"); if ((s & 0x2) != 0) f.Add("SELECTED"); if ((s & 0x4) != 0) f.Add("FOCUSED");
        if ((s & 0x10) != 0) f.Add("CHECKED"); if ((s & 0x80) != 0) f.Add("HOTTRACKED"); if ((s & 0x8000) != 0) f.Add("INVISIBLE");
        if ((s & 0x40000000) != 0) f.Add("HASPOPUP");
        return "0x" + s.ToString("X") + (f.Count > 0 ? " " + string.Join("|", f.ToArray()) : "");
    }

    static string Show(string s)
    {
        if (s == null) return "(null)";
        StringBuilder b = new StringBuilder();
        foreach (char c in s)
        {
            if (c == '\t') b.Append("<TAB>"); else if (c < 32) b.Append("<U+" + ((int)c).ToString("X4") + ">"); else b.Append(c);
        }
        return "[" + b.ToString() + "]";
    }

    // Writes the children of an accessible object and returns how many of them are menu items.
    static int DumpChildren(IAccessible acc, string title)
    {
        int n;
        int items = 0;
        try { n = acc.accChildCount; } catch (Exception e) { Out("== " + title + " : cannot read child count: " + e.Message); return 0; }
        Out("== " + title + " (accChildCount=" + n + ")");
        for (int i = 1; i <= n; i++)
        {
            object id = i;
            string name = null, shortcut = null, action = null, desc = null; int role = -1, state = -1;
            try { name = acc.get_accName(id); } catch { }
            try { shortcut = acc.get_accKeyboardShortcut(id); } catch { }
            try { action = acc.get_accDefaultAction(id); } catch { }
            try { desc = acc.get_accDescription(id); } catch { }
            try { role = Convert.ToInt32(acc.get_accRole(id)); } catch { }
            try { state = Convert.ToInt32(acc.get_accState(id)); } catch { }
            if (role == 21) { Out("  " + i + ": SEPARATOR"); continue; }
            if (role == 12) items++;
            Out("  " + i + ": name=" + Show(name) + "  accKeyboardShortcut=" + Show(shortcut) + "  role=" + RoleName(role) + "  state=" + StateText(state)
                + (string.IsNullOrEmpty(action) ? "" : "  defaultAction=" + Show(action)) + (string.IsNullOrEmpty(desc) ? "" : "  description=" + Show(desc)));
        }
        return items;
    }

    static void ListWindows(uint pid)
    {
        EnumWindows(delegate(IntPtr h, IntPtr l)
        {
            uint p; GetWindowThreadProcessId(h, out p);
            if (p == pid) Out("    window " + h.ToInt64().ToString("X") + " class=" + Show(Cls(h)) + " visible=" + IsWindowVisible(h) + " title=" + Show(Title(h)));
            return true;
        }, IntPtr.Zero);
    }

    static IntPtr FindPopup(uint pid)
    {
        IntPtr found = IntPtr.Zero;
        EnumWindows(delegate(IntPtr h, IntPtr l)
        {
            uint p; GetWindowThreadProcessId(h, out p);
            if (p == pid && IsWindowVisible(h) && Cls(h) == "#32768") { found = h; }
            return true;
        }, IntPtr.Zero);
        return found;
    }

    static Process FindMain(string name, int seconds)
    {
        for (int i = 0; i < seconds * 2; i++)
        {
            foreach (Process p in Process.GetProcessesByName(name))
            {
                p.Refresh();
                if (p.MainWindowHandle != IntPtr.Zero) return p;
            }
            Thread.Sleep(500);
        }
        return null;
    }

    public static string Run(string exe, int maxMenus)
    {
        string name = Path.GetFileNameWithoutExtension(exe);
        bool started = false;
        Process existing = FindMain(name, 1);
        if (existing == null) { Process.Start(exe); started = true; }
        Process proc = existing != null ? existing : FindMain(name, 45);
        if (proc == null) { Out("Could not find a main window for " + name); return log.ToString(); }
        IntPtr hwnd = proc.MainWindowHandle;
        uint pid = (uint)proc.Id;
        Thread.Sleep(2500);
        proc.Refresh(); hwnd = proc.MainWindowHandle;

        Out("Application: " + name + "  version=" + FileVersionInfo.GetVersionInfo(exe).FileVersion + "  pid=" + pid + "  startedByScript=" + started);
        Out("Main window: class=" + Show(Cls(hwnd)) + "  title=" + Show(Title(hwnd)));

        IAccessible bar;
        int hr = AccessibleObjectFromWindow(hwnd, 0xFFFFFFFD, ref IID_IAccessible, out bar);
        if (hr != 0 || bar == null) { Out("OBJID_MENU not available, hr=" + hr); }
        else
        {
            DumpChildren(bar, "menu bar (OBJID_MENU)");
            int count = 0; try { count = bar.accChildCount; } catch { }
            if (count > maxMenus) count = maxMenus;

            // Step 1: ask MSAA for the drop-down of each menu bar item. No key presses are needed.
            bool[] done = new bool[count + 1];
            for (int m = 1; m <= count; m++)
            {
                try
                {
                    object c = bar.get_accChild(m);
                    IAccessible sub = c as IAccessible;
                    if (sub != null) { if (DumpChildren(sub, "menu " + m + " via accChild") > 0) done[m] = true; }
                    else Out("== menu " + m + ": accChild returned " + (c == null ? "null" : c.GetType().Name));
                }
                catch (Exception e) { Out("== menu " + m + ": accChild failed: " + e.Message); }
            }

            // Step 2: run each menu item's default action ("open") through MSAA, on a worker thread because
            // the call can wait until the menu closes. No key presses are needed either.
            for (int m = 1; m <= count; m++)
            {
                if (done[m]) continue;
                int which = m;
                Thread worker = new Thread(delegate()
                {
                    try
                    {
                        IAccessible b2;
                        if (AccessibleObjectFromWindow(hwnd, 0xFFFFFFFD, ref IID_IAccessible, out b2) == 0 && b2 != null) b2.accDoDefaultAction(which);
                    }
                    catch { }
                });
                worker.IsBackground = true; worker.Start();
                IntPtr popup = IntPtr.Zero;
                for (int w = 0; w < 10 && popup == IntPtr.Zero; w++) { Thread.Sleep(200); popup = FindPopup(pid); }
                if (popup == IntPtr.Zero) { Out("== menu " + m + ": accDoDefaultAction opened no popup window"); }
                else
                {
                    IAccessible pa;
                    int h2 = AccessibleObjectFromWindow(popup, 0xFFFFFFFC, ref IID_IAccessible, out pa);
                    if (h2 != 0 || pa == null) Out("== menu " + m + ": popup not accessible, hr=" + h2);
                    else if (DumpChildren(pa, "menu " + m + " popup via accDoDefaultAction (window class " + Show(Cls(popup)) + ")") > 0) done[m] = true;
                }
                PostMessage(hwnd, 0x001F, IntPtr.Zero, IntPtr.Zero);                 // WM_CANCELMODE
                PostMessage(hwnd, 0x0100, (IntPtr)0x1B, IntPtr.Zero);                // WM_KEYDOWN Esc
                PostMessage(hwnd, 0x0101, (IntPtr)0x1B, IntPtr.Zero);                // WM_KEYUP Esc
                worker.Join(2000);
                Thread.Sleep(300);
            }

            bool allDone = true;
            for (int m = 1; m <= count; m++) if (!done[m]) allDone = false;

            // Step 3: only if some menus are still missing, open them with the keyboard.
            if (allDone) { Out("All menus were read without sending any key."); }
            else if (!WaitForIdle(5000, 30000)) { Out("Not opening the remaining menus: keyboard or mouse was used in the last 5 seconds."); }
            else if (!Foreground(hwnd)) { Out("Not opening the remaining menus: could not bring the window to the foreground."); }
            else
            {
                Tap(0x12); Thread.Sleep(500);          // Alt, enter the menu bar
                Tap(0x28); Thread.Sleep(600);          // Down, open the first menu
                for (int m = 1; m <= count; m++)
                {
                    if (GetForegroundWindow() != hwnd && FindPopup(pid) == IntPtr.Zero) { Out("Stopped: the window lost the foreground."); break; }
                    IntPtr popup = FindPopup(pid);
                    if (!done[m])
                    {
                        if (popup == IntPtr.Zero) { Out("== menu " + m + ": no popup window found with the keyboard either"); }
                        else
                        {
                            IAccessible pa;
                            int h2 = AccessibleObjectFromWindow(popup, 0xFFFFFFFC, ref IID_IAccessible, out pa);
                            if (h2 != 0 || pa == null) Out("== menu " + m + ": popup not accessible, hr=" + h2);
                            else DumpChildren(pa, "menu " + m + " popup via keyboard (window class " + Show(Cls(popup)) + ")");
                        }
                    }
                    Tap(0x1B); Thread.Sleep(400);      // Esc, close the popup but stay in the menu bar
                    Tap(0x27); Thread.Sleep(400);      // Right, next menu bar item
                    Tap(0x28); Thread.Sleep(600);      // Down, open it
                }
                Tap(0x1B); Thread.Sleep(200); Tap(0x1B); Thread.Sleep(200); Tap(0x1B);
            }
        }

        if (started)
        {
            Thread.Sleep(500);
            try { proc.CloseMainWindow(); if (!proc.WaitForExit(4000)) proc.Kill(); } catch { }
            Out("Closed the application the script had started.");
        }
        return log.ToString();
    }
}
"@

$result = [MsaaDump]::Run($ExePath, $MaxMenus)
if ($OutFile) { [IO.File]::WriteAllText($OutFile, $result, (New-Object Text.UTF8Encoding($true))) }
$result
