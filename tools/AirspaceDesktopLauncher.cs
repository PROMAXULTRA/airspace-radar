using System;
using System.Diagnostics;
using System.IO;
using System.Windows.Forms;

internal static class AirspaceDesktopLauncher {
    [STAThread]
    private static void Main() {
        string root = AppDomain.CurrentDomain.BaseDirectory;
        string script = Path.Combine(root, "tools", "Start-AirspaceDesktop.ps1");
        try {
            if (!File.Exists(script)) throw new FileNotFoundException("Cannot find the desktop script.", script);
            var launch = new ProcessStartInfo {
                FileName = Path.Combine(Environment.SystemDirectory, @"WindowsPowerShell\v1.0\powershell.exe"),
                Arguments = "-NoProfile -STA -ExecutionPolicy Bypass -File \"" + script + "\"",
                WorkingDirectory = root,
                UseShellExecute = false,
                CreateNoWindow = true
            };
            using (Process.Start(launch)) { }
        } catch (Exception error) {
            MessageBox.Show(error.Message, "Airspace Radar", MessageBoxButtons.OK, MessageBoxIcon.Error);
        }
    }
}
