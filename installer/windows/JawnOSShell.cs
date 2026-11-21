// JawnOS for Windows: a WebView2 window and a tray.
//
// The Linux desktop uses Qt WebEngine. The Windows VM this house runs on has
// only a 2D Matrox framebuffer, and Qt WebEngine cannot create a GL context
// there. WebView2 is the same Chromium engine family and renders in that VM,
// so the Windows shell embeds it instead. The C# is compiled by
// prepare-webview.ps1 into webview\JawnOSShell.exe, next to the three
// Microsoft.Web.WebView2 DLLs and WebView2Loader.dll.
//
// It signs in with the same ticket the Linux shell uses: install.ps1 mints
// app\.shots\ticket.txt, the shell loads that URL (which mints the president
// cookie), then loads the Manager on the ticket's host. The WebView2 profile
// under %LOCALAPPDATA%\JawnOS\webview2 keeps the cookie across launches.
//
// The tray carries the Linux shell's controls: show, reload, start/stop/
// restart jawn, log, browser, quit, and quit-and-stop. Closing the window
// hides it; the tray is the way out, as on Linux.

using System;
using System.Diagnostics;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.IO;
using System.Net.Sockets;
using System.Text.RegularExpressions;
using System.Threading;
using System.Threading.Tasks;
using System.Windows.Forms;
using Microsoft.Web.WebView2.Core;
using Microsoft.Web.WebView2.WinForms;

namespace JawnOS
{
    static class Program
    {
        [STAThread]
        static void Main(string[] args)
        {
            bool created;
            using (Mutex mutex = new Mutex(true, "JawnOS.WebViewShell", out created))
            {
                if (!created)
                {
                    try
                    {
                        using (EventWaitHandle show = EventWaitHandle.OpenExisting("JawnOS.WebViewShell.Show"))
                        {
                            show.Set();
                        }
                    }
                    catch (Exception)
                    {
                    }
                    return;
                }
                Application.EnableVisualStyles();
                Application.SetCompatibleTextRenderingDefault(false);

                string install = Arg(args, "--install");
                if (string.IsNullOrEmpty(install))
                {
                    install = AppDomain.CurrentDomain.BaseDirectory.TrimEnd('\\');
                    if (string.Equals(Path.GetFileName(install), "webview", StringComparison.OrdinalIgnoreCase))
                    {
                        install = Path.GetDirectoryName(install);
                    }
                }
                Application.Run(new ShellForm(Path.GetFullPath(install)));
            }
        }

        static string Arg(string[] args, string name)
        {
            for (int i = 0; i < args.Length - 1; i++)
            {
                if (args[i] == name)
                {
                    return args[i + 1];
                }
            }
            return null;
        }
    }

    class ShellForm : Form
    {
        readonly string install;
        readonly string appDir;
        readonly string ticketPath;
        readonly string configPath;
        readonly string perl;
        readonly string killer;
        readonly string startVbs;
        readonly string userData;
        readonly string domain;
        readonly string ticket;
        readonly string managerUrl;
        readonly string host;
        readonly int port;

        WebView2 web;
        CoreWebView2Environment environment;
        NotifyIcon tray;
        Icon iconBase;
        Icon iconGreen;
        Icon iconAmber;
        Icon iconRed;
        System.Windows.Forms.Timer statusTimer;
        ToolStripMenuItem startItem;
        ToolStripMenuItem stopItem;
        bool exiting;
        bool webReady;
        int gateTries;
        EventWaitHandle showEvent;

        public ShellForm(string install)
        {
            this.install = install;
            appDir = Path.Combine(install, "app");
            ticketPath = Path.Combine(appDir, ".shots", "ticket.txt");
            configPath = Path.Combine(appDir, "config.json");
            perl = Path.Combine(install, "runtime", "perl", "bin", "perl.exe");
            killer = Path.Combine(appDir, "scripts", "manager_killer.pl");
            startVbs = Path.Combine(install, "start.vbs");
            userData = Path.Combine(
                Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
                "JawnOS", "webview2");

            domain = ReadDomain();
            port = ReadPort();
            ticket = ReadTicket();
            host = TicketHost(ticket, domain);
            managerUrl = "https://" + host + ":" + port + "/manager";

            Text = "JawnOS";
            Rectangle area = Screen.PrimaryScreen.WorkingArea;
            Width = Math.Min(1100, Math.Max(800, area.Width - 80));
            Height = Math.Min(820, Math.Max(600, area.Height - 80));
            StartPosition = FormStartPosition.CenterScreen;
            iconBase = LoadIcon();
            Icon = iconBase;
        }

        protected override async void OnLoad(EventArgs e)
        {
            base.OnLoad(e);
            BuildTray();
            ListenForShow();

            BackColor = Color.Black;
            web = new WebView2();
            web.Dock = DockStyle.Fill;
            web.DefaultBackgroundColor = Color.Black;
            Controls.Add(web);
            web.CoreWebView2InitializationCompleted += (sender, args) => { };

            try
            {
                Directory.CreateDirectory(userData);
                environment = await CoreWebView2Environment.CreateAsync(null, userData, null);
                await web.EnsureCoreWebView2Async(environment);
                webReady = true;
                try { web.DefaultBackgroundColor = Color.Black; }
                catch (Exception) { }

                web.CoreWebView2.Settings.AreDevToolsEnabled = false;
                web.CoreWebView2.Settings.AreDefaultContextMenusEnabled = true;
                // WebView2's default background is transparent; the Manager's
                // desktop expects the shell's black ground. Paint the root black
                // before the page's own wallpaper has a chance to be absent.
                await web.CoreWebView2.AddScriptToExecuteOnDocumentCreatedAsync(
                    "(function(){var s=document.createElement('style');" +
                    "s.textContent='html{background:#000 !important;}';" +
                    "document.documentElement.appendChild(s);})()");
                web.CoreWebView2.ServerCertificateErrorDetected += OnCertificate;
                web.CoreWebView2.NavigationCompleted += OnNavigation;
                web.CoreWebView2.NewWindowRequested += OnNewWindow;
                web.CoreWebView2.PermissionRequested += OnPermission;

                web.CoreWebView2.NavigateToString(Dark("Starting JawnOS ..."));
                await EnsureJawnAsync();
                NavigateTicket();
            }
            catch (Exception ex)
            {
                MessageBox.Show(
                    "JawnOS needs the Microsoft Edge WebView2 runtime.\n\n" + ex.Message +
                    "\n\nInstall it from https://go.microsoft.com/fwlink/p/?LinkId=2124703",
                    "JawnOS", MessageBoxButtons.OK, MessageBoxIcon.Error);
                exiting = true;
                Close();
                return;
            }

            statusTimer = new System.Windows.Forms.Timer();
            statusTimer.Interval = 2000;
            statusTimer.Tick += (sender, args) => UpdateStatus();
            statusTimer.Start();
            UpdateStatus();
        }

        // ---- startup and navigation --------------------------------------

        async Task EnsureJawnAsync()
        {
            if (PortOpen(port))
            {
                return;
            }
            StartJawn();
            for (int i = 0; i < 240 && !PortOpen(port); i++)
            {
                await Task.Delay(500);
            }
        }

        void NavigateTicket()
        {
            if (!webReady)
            {
                return;
            }
            if (!string.IsNullOrEmpty(ticket))
            {
                web.CoreWebView2.Navigate(ticket);
                After(1800, delegate
                {
                    if (webReady)
                    {
                        web.CoreWebView2.Navigate(managerUrl);
                    }
                });
                return;
            }
            web.CoreWebView2.Navigate(managerUrl);
        }

        async void OnNavigation(object sender, CoreWebView2NavigationCompletedEventArgs e)
        {
            try
            {
                if (!e.IsSuccess)
                {
                    await Task.Delay(2000);
                    if (!PortOpen(port))
                    {
                        StartJawn();
                        await Task.Delay(3000);
                    }
                    if (webReady)
                    {
                        web.CoreWebView2.Navigate(managerUrl);
                    }
                    return;
                }

                string source = web.CoreWebView2.Source ?? "";
                string title = web.CoreWebView2.DocumentTitle ?? "";

                if (source.IndexOf("/box_office/", StringComparison.OrdinalIgnoreCase) >= 0)
                {
                    await Task.Delay(1500);
                    if (webReady)
                    {
                        web.CoreWebView2.Navigate(managerUrl);
                    }
                    return;
                }

                if (source.IndexOf("/manager", StringComparison.OrdinalIgnoreCase) >= 0)
                {
                    bool gate = string.Equals(title, "Gate", StringComparison.OrdinalIgnoreCase);
                    if (gate && gateTries < 2 && !string.IsNullOrEmpty(ticket))
                    {
                        gateTries++;
                        web.CoreWebView2.Navigate(ticket);
                        await Task.Delay(1500);
                        if (webReady)
                        {
                            web.CoreWebView2.Navigate(managerUrl);
                        }
                    }
                    else if (!gate)
                    {
                        gateTries = 0;
                    }
                }
            }
            catch (Exception)
            {
            }
        }

        void OnCertificate(object sender, CoreWebView2ServerCertificateErrorDetectedEventArgs e)
        {
            try
            {
                Uri uri = new Uri(e.RequestUri);
                if (IsHouseHost(uri.Host))
                {
                    e.Action = CoreWebView2ServerCertificateErrorAction.AlwaysAllow;
                    return;
                }
            }
            catch (Exception)
            {
            }
            e.Action = CoreWebView2ServerCertificateErrorAction.Default;
        }

        void OnPermission(object sender, CoreWebView2PermissionRequestedEventArgs e)
        {
            try
            {
                Uri uri = new Uri(e.Uri);
                if (IsHouseHost(uri.Host))
                {
                    CoreWebView2PermissionKind kind = e.PermissionKind;
                    if (kind == CoreWebView2PermissionKind.Microphone ||
                        kind == CoreWebView2PermissionKind.Camera ||
                        kind == CoreWebView2PermissionKind.ClipboardRead)
                    {
                        e.State = CoreWebView2PermissionState.Allow;
                        return;
                    }
                }
            }
            catch (Exception)
            {
            }
            e.State = CoreWebView2PermissionState.Default;
        }

        void OnNewWindow(object sender, CoreWebView2NewWindowRequestedEventArgs e)
        {
            e.Handled = true;
            try
            {
                Uri uri = new Uri(e.Uri);
                if (IsHouseHost(uri.Host))
                {
                    OpenWindow(e.Uri);
                }
                else
                {
                    Process.Start(e.Uri);
                }
            }
            catch (Exception)
            {
            }
        }

        void OpenWindow(string url)
        {
            Form form = new Form();
            form.Text = "JawnOS";
            form.Width = 900;
            form.Height = 700;
            form.StartPosition = FormStartPosition.CenterParent;
            form.Icon = iconBase;
            WebView2 view = new WebView2();
            view.Dock = DockStyle.Fill;
            form.Controls.Add(view);
            form.Shown += async delegate
            {
                try
                {
                    await view.EnsureCoreWebView2Async(environment);
                    view.CoreWebView2.ServerCertificateErrorDetected += OnCertificate;
                    view.CoreWebView2.Navigate(url);
                }
                catch (Exception)
                {
                }
            };
            form.Show(this);
        }

        bool IsHouseHost(string name)
        {
            if (string.IsNullOrEmpty(name))
            {
                return false;
            }
            return name.Equals("127.0.0.1", StringComparison.OrdinalIgnoreCase)
                || name.Equals("localhost", StringComparison.OrdinalIgnoreCase)
                || (!string.IsNullOrEmpty(domain) && name.Equals(domain, StringComparison.OrdinalIgnoreCase));
        }

        // ---- jawn ---------------------------------------------------------

        void StartJawn()
        {
            try
            {
                if (File.Exists(startVbs))
                {
                    Process.Start(new ProcessStartInfo("wscript.exe", "\"" + startVbs + "\"")
                    {
                        UseShellExecute = true,
                        WorkingDirectory = install
                    });
                    return;
                }
                string bat = Path.Combine(install, "launch.bat");
                if (File.Exists(bat))
                {
                    Process.Start(new ProcessStartInfo(bat)
                    {
                        UseShellExecute = true,
                        WorkingDirectory = install
                    });
                }
            }
            catch (Exception)
            {
            }
        }

        bool StopJawn()
        {
            try
            {
                if (File.Exists(perl) && File.Exists(killer))
                {
                    ProcessStartInfo info = new ProcessStartInfo(perl);
                    info.Arguments = "\"scripts\\manager_killer.pl\" master";
                    info.WorkingDirectory = appDir;
                    info.UseShellExecute = false;
                    info.CreateNoWindow = true;
                    info.RedirectStandardOutput = true;
                    info.RedirectStandardError = true;
                    info.EnvironmentVariables["JAWNOS_PORTABLE"] = "1";
                    info.EnvironmentVariables["JAWNOS_TRANSPORT"] = "tcp";
                    info.EnvironmentVariables["JAWNOS_DIR"] = appDir;
                    info.EnvironmentVariables["PATH"] =
                        Path.Combine(install, "runtime", "c", "bin") + ";" +
                        Path.Combine(install, "runtime", "perl", "bin") + ";" +
                        Environment.GetEnvironmentVariable("PATH");
                    Process process = Process.Start(info);
                    if (process != null)
                    {
                        process.WaitForExit(20000);
                    }
                }
            }
            catch (Exception)
            {
            }
            for (int i = 0; i < 40 && PortOpen(port); i++)
            {
                Thread.Sleep(300);
            }
            return !PortOpen(port);
        }

        void OpenLog()
        {
            string path = Path.Combine(
                Environment.GetFolderPath(Environment.SpecialFolder.UserProfile),
                "manager.log");
            try
            {
                string text = File.ReadAllText(configPath);
                Match match = Regex.Match(text, "\"logfile\"\\s*:\\s*\"([^\"]+)\"");
                if (match.Success && match.Groups[1].Value.Length > 0)
                {
                    path = match.Groups[1].Value.Replace("~", Environment.GetFolderPath(
                        Environment.SpecialFolder.UserProfile));
                }
            }
            catch (Exception)
            {
            }
            if (File.Exists(path))
            {
                Process.Start("notepad.exe", "\"" + path + "\"");
            }
            else
            {
                MessageBox.Show("No manager.log at " + path, "JawnOS");
            }
        }

        // ---- tray ---------------------------------------------------------

        void BuildTray()
        {
            iconGreen = MakeIcon(Color.FromArgb(0x34, 0xC7, 0x59));
            iconAmber = MakeIcon(Color.FromArgb(0xFF, 0xB0, 0x20));
            iconRed = MakeIcon(Color.FromArgb(0xFF, 0x45, 0x3A));

            tray = new NotifyIcon();
            tray.Icon = iconRed;
            tray.Text = "JawnOS";
            tray.Visible = true;

            ContextMenuStrip menu = new ContextMenuStrip();
            menu.Items.Add(new ToolStripMenuItem("Show JawnOS", null, delegate { ShowWindow(); }));
            menu.Items.Add(new ToolStripMenuItem("Reload view", null, delegate
            {
                if (webReady)
                {
                    web.CoreWebView2.Reload();
                }
            }));
            menu.Items.Add(new ToolStripSeparator());

            startItem = new ToolStripMenuItem("Start jawn", null, delegate
            {
                RunAsync(delegate
                {
                    StartJawn();
                    WaitForPort(120);
                });
            });
            stopItem = new ToolStripMenuItem("Stop jawn", null, delegate
            {
                RunAsync(delegate { StopJawn(); });
            });
            ToolStripMenuItem restart = new ToolStripMenuItem("Restart jawn", null, delegate
            {
                RunAsync(delegate
                {
                    StopJawn();
                    StartJawn();
                    WaitForPort(120);
                });
            });
            menu.Items.Add(startItem);
            menu.Items.Add(stopItem);
            menu.Items.Add(restart);
            menu.Items.Add(new ToolStripSeparator());

            menu.Items.Add(new ToolStripMenuItem("Log", null, delegate { OpenLog(); }));
            menu.Items.Add(new ToolStripMenuItem("Open in browser", null, delegate
            {
                try { Process.Start(managerUrl); }
                catch (Exception) { }
            }));
            menu.Items.Add(new ToolStripSeparator());
            menu.Items.Add(new ToolStripMenuItem("Quit and stop jawn", null, delegate
            {
                exiting = true;
                Hide();
                ThreadPool.QueueUserWorkItem(delegate
                {
                    StopJawn();
                    After(0, delegate { Close(); });
                });
            }));
            menu.Items.Add(new ToolStripMenuItem("Quit", null, delegate
            {
                exiting = true;
                Close();
            }));

            tray.ContextMenuStrip = menu;
            tray.DoubleClick += delegate { ShowWindow(); };
            tray.MouseClick += delegate(object sender, MouseEventArgs args)
            {
                if (args.Button == MouseButtons.Left)
                {
                    ShowWindow();
                }
            };
        }

        void ListenForShow()
        {
            try
            {
                showEvent = new EventWaitHandle(false, EventResetMode.AutoReset, "JawnOS.WebViewShell.Show");
                ThreadPool.RegisterWaitForSingleObject(showEvent, delegate
                {
                    try
                    {
                        if (!IsDisposed && IsHandleCreated)
                        {
                            BeginInvoke(new MethodInvoker(ShowWindow));
                        }
                    }
                    catch (Exception)
                    {
                    }
                }, null, Timeout.Infinite, false);
            }
            catch (Exception)
            {
            }
        }

        void ShowWindow()
        {
            Show();
            WindowState = FormWindowState.Normal;
            Activate();
            BringToFront();
        }

        void UpdateStatus()
        {
            bool up = PortOpen(port);
            if (tray != null && !exiting)
            {
                tray.Icon = up ? iconGreen : iconRed;
                tray.Text = "JawnOS - jawn " + (up ? "running" : "stopped");
            }
            if (startItem != null)
            {
                startItem.Enabled = !up;
            }
            if (stopItem != null)
            {
                stopItem.Enabled = up;
            }
        }

        void RunAsync(Action action)
        {
            if (tray != null)
            {
                tray.Icon = iconAmber;
            }
            ThreadPool.QueueUserWorkItem(delegate
            {
                try { action(); }
                catch (Exception) { }
                After(0, delegate { UpdateStatus(); });
            });
        }

        void WaitForPort(int seconds)
        {
            for (int i = 0; i < seconds * 2 && !PortOpen(port); i++)
            {
                Thread.Sleep(500);
            }
        }

        void After(int milliseconds, Action action)
        {
            Task.Delay(milliseconds).ContinueWith(delegate
            {
                try
                {
                    if (!IsDisposed && IsHandleCreated)
                    {
                        BeginInvoke(action);
                    }
                }
                catch (Exception)
                {
                }
            });
        }

        Icon MakeIcon(Color dot)
        {
            Bitmap bitmap = new Bitmap(32, 32);
            using (Graphics graphics = Graphics.FromImage(bitmap))
            {
                graphics.SmoothingMode = SmoothingMode.AntiAlias;
                if (iconBase != null)
                {
                    graphics.DrawIcon(iconBase, new Rectangle(0, 0, 32, 32));
                }
                else
                {
                    graphics.Clear(Color.Black);
                }
                using (Brush brush = new SolidBrush(dot))
                {
                    graphics.FillEllipse(brush, 20, 20, 11, 11);
                }
                graphics.DrawEllipse(Pens.White, 20, 20, 11, 11);
            }
            return Icon.FromHandle(bitmap.GetHicon());
        }

        Icon LoadIcon()
        {
            string ico = Path.Combine(install, "jawnos.ico");
            if (File.Exists(ico))
            {
                try { return new Icon(ico); }
                catch (Exception) { }
            }
            string png = Path.Combine(appDir, "desktop", "icons", "jawnos.png");
            if (File.Exists(png))
            {
                try
                {
                    using (Bitmap bitmap = new Bitmap(png))
                    {
                        return Icon.FromHandle(bitmap.GetHicon());
                    }
                }
                catch (Exception) { }
            }
            return SystemIcons.Application;
        }

        protected override void OnFormClosing(FormClosingEventArgs e)
        {
            if (!exiting)
            {
                e.Cancel = true;
                Hide();
                return;
            }
            if (tray != null)
            {
                tray.Visible = false;
                tray.Dispose();
                tray = null;
            }
            if (web != null)
            {
                web.Dispose();
                web = null;
            }
            base.OnFormClosing(e);
        }

        // ---- the app's files ---------------------------------------------

        string ReadTicket()
        {
            try
            {
                if (!File.Exists(ticketPath))
                {
                    return null;
                }
                string text = File.ReadAllText(ticketPath).Trim();
                if (text.StartsWith("https://", StringComparison.OrdinalIgnoreCase))
                {
                    return text.Split('\n')[0].Trim();
                }
            }
            catch (Exception)
            {
            }
            return null;
        }

        int ReadPort()
        {
            try
            {
                string text = File.ReadAllText(configPath);
                Match match = Regex.Match(text, "\"working_port\"\\s*:\\s*(\\d+)");
                int value;
                if (match.Success && int.TryParse(match.Groups[1].Value, out value) && value > 0 && value < 65536)
                {
                    return value;
                }
            }
            catch (Exception)
            {
            }
            return 45545;
        }

        string ReadDomain()
        {
            try
            {
                string text = File.ReadAllText(configPath);
                Match match = Regex.Match(text, "\"domain\"\\s*:\\s*\"([^\"]*)\"");
                if (match.Success)
                {
                    return match.Groups[1].Value.Trim();
                }
            }
            catch (Exception)
            {
            }
            return "";
        }

        static string TicketHost(string ticket, string domain)
        {
            try
            {
                if (!string.IsNullOrEmpty(ticket))
                {
                    Uri uri = new Uri(ticket);
                    if (!string.IsNullOrEmpty(uri.Host))
                    {
                        return uri.Host;
                    }
                }
            }
            catch (Exception)
            {
            }
            return string.IsNullOrEmpty(domain) ? "127.0.0.1" : domain;
        }

        static bool PortOpen(int port)
        {
            try
            {
                using (TcpClient client = new TcpClient())
                {
                    Task task = client.ConnectAsync("127.0.0.1", port);
                    return task.Wait(350) && client.Connected;
                }
            }
            catch (Exception)
            {
                return false;
            }
        }

        static string Dark(string text)
        {
            return "<!doctype html><html><body style=\"margin:0;background:#000;" +
                "color:#eee;font:16px sans-serif;display:flex;align-items:center;" +
                "justify-content:center;height:100vh\">" + text + "</body></html>";
        }
    }
}
