using System;
using System.ComponentModel;
using System.Diagnostics;
using System.IO;
using System.Runtime.InteropServices;
using System.Threading.Tasks;
using Microsoft.Win32.SafeHandles;

public sealed class AirspaceWorker : IDisposable {
    private readonly SafeFileHandle job;
    private readonly Process process;
    private FileStream outputLog;
    private FileStream errorLog;
    private Task copyOutput;
    private Task copyError;

    public AirspaceWorker(string engine, string arguments, string directory, string stdout, string stderr) {
        job = CreateWorkerJob();
        process = new Process {
            StartInfo = new ProcessStartInfo {
                FileName = engine,
                Arguments = arguments,
                WorkingDirectory = directory,
                UseShellExecute = false,
                CreateNoWindow = true,
                RedirectStandardOutput = true,
                RedirectStandardError = true
            }
        };
        try {
            outputLog = OpenLog(stdout);
            errorLog = OpenLog(stderr);
            process.Start();
            if (!AssignProcessToJobObject(job, process.Handle)) {
                var error = new Win32Exception(Marshal.GetLastWin32Error());
                if (!process.HasExited) process.Kill();
                throw error;
            }
            copyOutput = process.StandardOutput.BaseStream.CopyToAsync(outputLog);
            copyError = process.StandardError.BaseStream.CopyToAsync(errorLog);
        } catch {
            Dispose();
            throw;
        }
    }

    public bool HasExited { get { return process.HasExited; } }
    public int ExitCode { get { return process.ExitCode; } }
    public void Kill() { job.Dispose(); }
    public bool WaitForExit(int milliseconds) { return process.WaitForExit(milliseconds); }

    public void Dispose() {
        job.Dispose();
        try {
            Task.WaitAll(new[] { copyOutput ?? Task.FromResult(0), copyError ?? Task.FromResult(0) }, 1500);
        } catch (AggregateException) { }
        finally {
            if (copyOutput != null) process.StandardOutput.Dispose();
            if (copyError != null) process.StandardError.Dispose();
            process.Dispose();
            if (outputLog != null) outputLog.Dispose();
            if (errorLog != null) errorLog.Dispose();
        }
    }

    private static FileStream OpenLog(string path) {
        // No write buffering, so the desktop can tail output as it arrives.
        return new FileStream(path, FileMode.Create, FileAccess.Write, FileShare.ReadWrite, 1, true);
    }

    private static SafeFileHandle CreateWorkerJob() {
        const int extendedLimitInformation = 9;
        const uint killOnJobClose = 0x2000;
        SafeFileHandle handle = CreateJobObject(IntPtr.Zero, null);
        if (handle.IsInvalid) throw new Win32Exception(Marshal.GetLastWin32Error());

        var limits = new ExtendedLimits();
        limits.Basic.LimitFlags = killOnJobClose;
        if (SetInformationJobObject(handle, extendedLimitInformation, ref limits, Marshal.SizeOf(limits)))
            return handle;

        var error = new Win32Exception(Marshal.GetLastWin32Error());
        handle.Dispose();
        throw error;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct BasicLimits {
        public long ProcessTime, JobTime;
        public uint LimitFlags;
        public UIntPtr MinWorkingSet, MaxWorkingSet;
        public uint ActiveProcessLimit;
        public UIntPtr Affinity;
        public uint PriorityClass, SchedulingClass;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct ExtendedLimits {
        public BasicLimits Basic;
        public ulong ReadOps, WriteOps, OtherOps, ReadBytes, WriteBytes, OtherBytes;
        public UIntPtr ProcessMemory, JobMemory, PeakProcessMemory, PeakJobMemory;
    }

    [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    private static extern SafeFileHandle CreateJobObject(IntPtr attributes, string name);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool SetInformationJobObject(SafeFileHandle handle, int kind, ref ExtendedLimits limits, int size);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool AssignProcessToJobObject(SafeFileHandle handle, IntPtr process);
}
