use std::ffi::OsStr;
use std::io::{ErrorKind, Read, Write};
use std::path::Path;
use std::process::{Child, ChildStdin, Command, ExitStatus, Stdio};
use std::sync::mpsc::{self, RecvTimeoutError};
use std::thread::JoinHandle;
use std::time::{Duration, Instant};

use crate::error::{fail, B3Error};

/// Maximum time to wait for a timed-out child process to exit and be reaped after termination.
const CLEANUP_GRACE: Duration = Duration::from_millis(500);
/// Maximum time to wait for `taskkill.exe` fallback when Job Object termination is unavailable.
#[cfg(windows)]
const TASKKILL_TIMEOUT: Duration = Duration::from_millis(1000);

/// Captured output from a child process.
#[derive(Debug, Clone)]
pub struct CmdOutput {
    pub exit_code: i32,
    pub stdout: Vec<u8>,
    pub stderr: Vec<u8>,
}

#[cfg(windows)]
mod win_job {
    use std::os::windows::io::AsRawHandle;
    use std::process::Child;

    use crate::error::{fail, B3Error};

    type Handle = *mut core::ffi::c_void;
    type Bool = i32;

    const JOB_OBJECT_EXTENDED_LIMIT_INFORMATION_CLASS: u32 = 9;
    const JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE: u32 = 0x2000;
    const TH32CS_SNAPTHREAD: u32 = 0x0000_0004;
    const THREAD_SUSPEND_RESUME: u32 = 0x0002;
    const INVALID_HANDLE_VALUE: Handle = (-1isize) as Handle;

    #[repr(C)]
    #[derive(Default)]
    struct JobObjectBasicLimitInformation {
        per_process_user_time_limit: i64,
        per_job_user_time_limit: i64,
        limit_flags: u32,
        minimum_working_set_size: usize,
        maximum_working_set_size: usize,
        active_process_limit: u32,
        affinity: usize,
        priority_class: u32,
        scheduling_class: u32,
    }

    #[repr(C)]
    #[derive(Default)]
    struct IoCounters {
        read_operation_count: u64,
        write_operation_count: u64,
        other_operation_count: u64,
        read_transfer_count: u64,
        write_transfer_count: u64,
        other_transfer_count: u64,
    }

    #[repr(C)]
    #[derive(Default)]
    struct JobObjectExtendedLimitInformation {
        basic_limit_information: JobObjectBasicLimitInformation,
        io_info: IoCounters,
        process_memory_limit: usize,
        job_memory_limit: usize,
        peak_process_memory_used: usize,
        peak_job_memory_used: usize,
    }

    #[repr(C)]
    struct ThreadEntry32 {
        dw_size: u32,
        cnt_usage: u32,
        th32_thread_id: u32,
        th32_owner_process_id: u32,
        tp_base_pri: i32,
        tp_delta_pri: i32,
        dw_flags: u32,
    }

    #[link(name = "kernel32")]
    extern "system" {
        fn CreateJobObjectW(
            lp_job_attributes: *const core::ffi::c_void,
            lp_name: *const u16,
        ) -> Handle;
        fn SetInformationJobObject(
            h_job: Handle,
            job_object_information_class: u32,
            lp_job_object_information: *const core::ffi::c_void,
            cb_job_object_information_length: u32,
        ) -> Bool;
        fn AssignProcessToJobObject(h_job: Handle, h_process: Handle) -> Bool;
        fn TerminateJobObject(h_job: Handle, u_exit_code: u32) -> Bool;
        fn CreateToolhelp32Snapshot(dw_flags: u32, th32_process_id: u32) -> Handle;
        fn Thread32First(h_snapshot: Handle, lpte: *mut ThreadEntry32) -> Bool;
        fn Thread32Next(h_snapshot: Handle, lpte: *mut ThreadEntry32) -> Bool;
        fn OpenThread(dw_desired_access: u32, b_inherit_handle: Bool, dw_thread_id: u32) -> Handle;
        fn ResumeThread(h_thread: Handle) -> u32;
        fn CloseHandle(h_object: Handle) -> Bool;
        fn OpenProcess(
            dw_desired_access: u32,
            b_inherit_handle: Bool,
            dw_process_id: u32,
        ) -> Handle;
        fn GetExitCodeProcess(h_process: Handle, lp_exit_code: *mut u32) -> Bool;
        fn WaitForSingleObject(h_handle: Handle, dw_milliseconds: u32) -> u32;
        fn GetLastError() -> u32;
    }

    pub struct WinJobGuard {
        handle: Handle,
    }

    impl WinJobGuard {
        pub fn attach(child: &Child) -> Result<Self, B3Error> {
            // SAFETY: Win32 Job Object APIs receive valid pointers/handles and zeroed attributes.
            unsafe {
                let job = CreateJobObjectW(core::ptr::null(), core::ptr::null());
                if job.is_null() {
                    return Err(fail("GIT_ERROR: CreateJobObjectW failed", 1));
                }
                let mut info = JobObjectExtendedLimitInformation::default();
                info.basic_limit_information.limit_flags = JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE;
                let ok_info = SetInformationJobObject(
                    job,
                    JOB_OBJECT_EXTENDED_LIMIT_INFORMATION_CLASS,
                    (&info as *const JobObjectExtendedLimitInformation).cast::<core::ffi::c_void>(),
                    core::mem::size_of::<JobObjectExtendedLimitInformation>() as u32,
                );
                if ok_info == 0 {
                    CloseHandle(job);
                    return Err(fail("GIT_ERROR: SetInformationJobObject failed", 1));
                }
                if AssignProcessToJobObject(job, child.as_raw_handle()) == 0 {
                    CloseHandle(job);
                    return Err(fail("GIT_ERROR: AssignProcessToJobObject failed", 1));
                }
                Ok(Self { handle: job })
            }
        }

        pub fn terminate(&self) -> bool {
            if self.handle.is_null() {
                return false;
            }
            // SAFETY: `self.handle` is a valid open Job Object handle until `Drop`.
            unsafe { TerminateJobObject(self.handle, 1) != 0 }
        }
    }

    impl Drop for WinJobGuard {
        fn drop(&mut self) {
            if !self.handle.is_null() {
                // SAFETY: `self.handle` is owned exclusively by this guard.
                unsafe {
                    CloseHandle(self.handle);
                }
                self.handle = core::ptr::null_mut();
            }
        }
    }

    struct HandleCloser(Handle);

    impl Drop for HandleCloser {
        fn drop(&mut self) {
            if !self.0.is_null() && self.0 != INVALID_HANDLE_VALUE {
                // SAFETY: `self.0` is an owned Win32 handle.
                unsafe {
                    CloseHandle(self.0);
                }
            }
        }
    }

    pub fn resume_process_threads(pid: u32) -> Result<(), B3Error> {
        // SAFETY: Toolhelp32 and thread APIs receive properly sized `ThreadEntry32` and valid handles.
        unsafe {
            let snap = CreateToolhelp32Snapshot(TH32CS_SNAPTHREAD, 0);
            if snap.is_null() || snap == INVALID_HANDLE_VALUE {
                return Err(fail("GIT_ERROR: CreateToolhelp32Snapshot failed", 1));
            }
            let _snap_guard = HandleCloser(snap);

            let mut entry = ThreadEntry32 {
                dw_size: core::mem::size_of::<ThreadEntry32>() as u32,
                cnt_usage: 0,
                th32_thread_id: 0,
                th32_owner_process_id: 0,
                tp_base_pri: 0,
                tp_delta_pri: 0,
                dw_flags: 0,
            };
            if Thread32First(snap, &mut entry) == 0 {
                return Err(fail("GIT_ERROR: Thread32First failed", 1));
            }

            let mut resumed = 0u32;
            loop {
                if entry.th32_owner_process_id == pid {
                    let th = OpenThread(THREAD_SUSPEND_RESUME, 0, entry.th32_thread_id);
                    if th.is_null() {
                        return Err(fail("GIT_ERROR: OpenThread failed", 1));
                    }
                    let _th_guard = HandleCloser(th);
                    let prev = ResumeThread(th);
                    if prev == u32::MAX {
                        return Err(fail("GIT_ERROR: ResumeThread failed", 1));
                    }
                    resumed += 1;
                }
                entry.dw_size = core::mem::size_of::<ThreadEntry32>() as u32;
                if Thread32Next(snap, &mut entry) == 0 {
                    break;
                }
            }

            if resumed == 0 {
                return Err(fail("GIT_ERROR: no suspended thread found to resume", 1));
            }
            Ok(())
        }
    }

    pub fn probe_pid_liveness(pid: i64) -> super::PidLiveness {
        const PROCESS_QUERY_LIMITED_INFORMATION: u32 = 0x1000;
        const SYNCHRONIZE: u32 = 0x0010_0000;
        const WAIT_OBJECT_0: u32 = 0;
        const WAIT_TIMEOUT: u32 = 0x0000_0102;
        const STILL_ACTIVE: u32 = 259;
        const ERROR_ACCESS_DENIED: u32 = 5;
        const ERROR_INVALID_PARAMETER: u32 = 87;

        let Ok(pid_u32) = u32::try_from(pid) else {
            return super::PidLiveness::Unknown;
        };
        if pid <= 0 || pid > i32::MAX as i64 {
            return super::PidLiveness::Unknown;
        }
        // SAFETY: Win32 handle obtained via `OpenProcess` is always closed via `CloseHandle`.
        unsafe {
            let handle = OpenProcess(SYNCHRONIZE | PROCESS_QUERY_LIMITED_INFORMATION, 0, pid_u32);
            if !handle.is_null() {
                let _guard = HandleCloser(handle);
                let wait = WaitForSingleObject(handle, 0);
                if wait == WAIT_OBJECT_0 {
                    return super::PidLiveness::Dead;
                }
                if wait == WAIT_TIMEOUT {
                    return super::PidLiveness::Alive;
                }
                let mut exit_code: u32 = 0;
                if GetExitCodeProcess(handle, &mut exit_code) != 0 {
                    return if exit_code == STILL_ACTIVE {
                        super::PidLiveness::Alive
                    } else {
                        super::PidLiveness::Dead
                    };
                }
                return super::PidLiveness::Unknown;
            }
            let err = GetLastError();
            if err == ERROR_INVALID_PARAMETER {
                return super::PidLiveness::Dead;
            }
            if err == ERROR_ACCESS_DENIED {
                let h2 = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, 0, pid_u32);
                if h2.is_null() {
                    return match GetLastError() {
                        ERROR_ACCESS_DENIED => super::PidLiveness::Alive,
                        ERROR_INVALID_PARAMETER => super::PidLiveness::Dead,
                        _ => super::PidLiveness::Unknown,
                    };
                }
                let _guard2 = HandleCloser(h2);
                let mut exit_code: u32 = 0;
                if GetExitCodeProcess(h2, &mut exit_code) != 0 {
                    return if exit_code == STILL_ACTIVE {
                        super::PidLiveness::Alive
                    } else {
                        super::PidLiveness::Dead
                    };
                }
                return super::PidLiveness::Unknown;
            }
            super::PidLiveness::Unknown
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum PidLiveness {
    Alive,
    Dead,
    Unknown,
}

pub(crate) fn probe_pid_liveness(pid: i64) -> PidLiveness {
    if pid <= 0 || pid > i32::MAX as i64 {
        return PidLiveness::Unknown;
    }
    #[cfg(windows)]
    {
        win_job::probe_pid_liveness(pid)
    }
    #[cfg(unix)]
    {
        const EPERM: i32 = 1;
        const ESRCH: i32 = 3;
        extern "C" {
            fn kill(pid: i32, sig: i32) -> i32;
        }
        // SAFETY: Signal 0 probes process existence without delivering a signal.
        let rc = unsafe { kill(pid as i32, 0) };
        if rc == 0 {
            return PidLiveness::Alive;
        }
        match std::io::Error::last_os_error().raw_os_error() {
            Some(ESRCH) => PidLiveness::Dead,
            Some(EPERM) => PidLiveness::Alive,
            _ => PidLiveness::Unknown,
        }
    }
    #[cfg(not(any(windows, unix)))]
    {
        let _ = pid;
        PidLiveness::Unknown
    }
}

#[cfg(test)]
pub(crate) fn is_pid_alive(pid: u32) -> bool {
    pid != 0 && matches!(probe_pid_liveness(i64::from(pid)), PidLiveness::Alive)
}

fn kill_process_tree(child: &mut Child, #[cfg(windows)] job: Option<&win_job::WinJobGuard>) {
    #[cfg(windows)]
    {
        let job_killed = job.is_some_and(win_job::WinJobGuard::terminate);
        if !job_killed {
            use std::os::windows::process::CommandExt;
            const CREATE_NO_WINDOW: u32 = 0x0800_0000;
            let pid_str = child.id().to_string();
            if let Ok(mut tk) = Command::new("taskkill")
                .args(["/F", "/T", "/PID", &pid_str])
                .creation_flags(CREATE_NO_WINDOW)
                .stdin(Stdio::null())
                .stdout(Stdio::null())
                .stderr(Stdio::null())
                .spawn()
            {
                if reap_child_bounded(&mut tk, TASKKILL_TIMEOUT).is_none() {
                    let _ = tk.kill();
                    let _ = reap_child_bounded(&mut tk, Duration::from_millis(100));
                }
            }
        }
        let _ = child.kill();
    }

    #[cfg(unix)]
    {
        extern "C" {
            fn kill(pid: i32, sig: i32) -> i32;
        }
        let pid = child.id() as i32;
        if pid > 0 {
            // SAFETY: Negative PID signals the child's isolated process group created via `process_group(0)`.
            unsafe {
                let _ = kill(-pid, 9);
            }
        }
        let _ = child.kill();
    }

    #[cfg(not(any(windows, unix)))]
    {
        let _ = child.kill();
    }
}

fn reap_child_bounded(child: &mut Child, max_wait: Duration) -> Option<ExitStatus> {
    let stop_at = Instant::now() + max_wait;
    loop {
        match child.try_wait() {
            Ok(Some(st)) => return Some(st),
            Ok(None) => {
                if Instant::now() >= stop_at {
                    return None;
                }
                std::thread::sleep(Duration::from_millis(10));
            }
            Err(_) => return None,
        }
    }
}

fn write_stdin_all(mut sin: ChildStdin, bytes: &[u8]) -> std::io::Result<()> {
    if !bytes.is_empty() {
        sin.write_all(bytes)?;
    }
    sin.flush()
}

fn check_stdin_result(res: std::io::Result<()>, status: ExitStatus) -> Result<(), B3Error> {
    if let Err(e) = res {
        if e.kind() != ErrorKind::BrokenPipe || status.success() {
            return Err(fail(format!("GIT_ERROR: failed to write stdin: {e}"), 1));
        }
    }
    Ok(())
}

struct PipeTask<T> {
    rx: mpsc::Receiver<T>,
    handle: JoinHandle<()>,
}

fn spawn_pipe_task<T, F>(f: F) -> PipeTask<T>
where
    T: Send + 'static,
    F: FnOnce() -> T + Send + 'static,
{
    let (tx, rx) = mpsc::sync_channel(1);
    let handle = std::thread::spawn(move || {
        let _ = tx.send(f());
    });
    PipeTask { rx, handle }
}

fn drain_pipe_task<T>(task: Option<PipeTask<T>>, cleanup_dl: Instant) {
    if let Some(PipeTask { rx, handle }) = task {
        let rem = cleanup_dl.saturating_duration_since(Instant::now());
        if !matches!(rx.recv_timeout(rem), Err(RecvTimeoutError::Timeout)) {
            let _ = handle.join();
        }
    }
}

fn take_pipe_with_deadline<T>(
    slot: &mut Option<PipeTask<std::io::Result<T>>>,
    deadline: Instant,
    label: &str,
) -> Result<Option<T>, B3Error> {
    let task = slot
        .take()
        .ok_or_else(|| fail(format!("GIT_ERROR: missing {label} task"), 1))?;
    let rem = deadline.saturating_duration_since(Instant::now());
    match task.rx.recv_timeout(rem) {
        Ok(res) => {
            let _ = task.handle.join();
            res.map(Some)
                .map_err(|e| fail(format!("GIT_ERROR: failed to read {label}: {e}"), 1))
        }
        Err(RecvTimeoutError::Timeout) => {
            *slot = Some(task);
            Ok(None)
        }
        Err(RecvTimeoutError::Disconnected) => {
            let _ = task.handle.join();
            Err(fail(
                format!("GIT_ERROR: {label} reader thread panicked"),
                1,
            ))
        }
    }
}

fn cleanup_descendants(child: &Child, #[cfg(windows)] job: Option<win_job::WinJobGuard>) {
    #[cfg(windows)]
    {
        let _ = child;
        if let Some(guard) = job {
            let _ = guard.terminate();
            drop(guard);
        }
    }
    #[cfg(unix)]
    {
        extern "C" {
            fn kill(pid: i32, sig: i32) -> i32;
        }
        let pid = child.id() as i32;
        if pid > 0 {
            // SAFETY: Negative PID signals the child's isolated process group created via `process_group(0)`.
            unsafe {
                let _ = kill(-pid, 9);
            }
        }
    }
    #[cfg(not(any(windows, unix)))]
    let _ = child;
}

fn abort_and_cleanup(
    child: &mut Child,
    #[cfg(windows)] job: Option<win_job::WinJobGuard>,
    stdout_task: Option<PipeTask<std::io::Result<Vec<u8>>>>,
    stderr_task: Option<PipeTask<std::io::Result<Vec<u8>>>>,
    stdin_task: Option<PipeTask<std::io::Result<()>>>,
) -> CmdOutput {
    let cleanup_dl = Instant::now() + CLEANUP_GRACE;

    #[cfg(windows)]
    kill_process_tree(child, job.as_ref());
    #[cfg(not(windows))]
    kill_process_tree(child);

    let _ = reap_child_bounded(child, cleanup_dl.saturating_duration_since(Instant::now()));

    #[cfg(windows)]
    drop(job);

    drain_pipe_task(stdout_task, cleanup_dl);
    drain_pipe_task(stderr_task, cleanup_dl);
    drain_pipe_task(stdin_task, cleanup_dl);

    CmdOutput {
        exit_code: 124,
        stdout: Vec::new(),
        stderr: Vec::new(),
    }
}

/// Runs a program directly via OS process creation (no shell interpolation) and
/// drains stdout/stderr concurrently to avoid pipe deadlocks.
pub fn run_command<S, K, V>(
    program: &OsStr,
    args: &[S],
    cwd: Option<&Path>,
    extra_env: &[(K, V)],
    remove_env: &[&str],
    stdin_bytes: Option<&[u8]>,
) -> Result<CmdOutput, B3Error>
where
    S: AsRef<OsStr>,
    K: AsRef<OsStr>,
    V: AsRef<OsStr>,
{
    run_command_timeout(program, args, cwd, extra_env, remove_env, stdin_bytes, None)
}

/// Runs a program with an optional wall-clock timeout in milliseconds.
pub fn run_command_timeout<S, K, V>(
    program: &OsStr,
    args: &[S],
    cwd: Option<&Path>,
    extra_env: &[(K, V)],
    remove_env: &[&str],
    stdin_bytes: Option<&[u8]>,
    timeout_ms: Option<u64>,
) -> Result<CmdOutput, B3Error>
where
    S: AsRef<OsStr>,
    K: AsRef<OsStr>,
    V: AsRef<OsStr>,
{
    let mut cmd = Command::new(program);
    cmd.args(args);
    if let Some(dir) = cwd {
        cmd.current_dir(dir);
    }
    for key in remove_env {
        cmd.env_remove(key);
    }
    for (k, v) in extra_env {
        cmd.env(k, v);
    }
    run_command_prepared(cmd, stdin_bytes, timeout_ms)
}

/// Runs a pre-configured `Command` with bounded wall-clock timeout, OS process-tree
/// isolation/termination on timeout, and non-blocking stdin/stdout/stderr handling.
pub fn run_command_prepared(
    mut cmd: Command,
    stdin_bytes: Option<&[u8]>,
    timeout_ms: Option<u64>,
) -> Result<CmdOutput, B3Error> {
    if stdin_bytes.is_some() {
        cmd.stdin(Stdio::piped());
    } else {
        cmd.stdin(Stdio::null());
    }
    cmd.stdout(Stdio::piped());
    cmd.stderr(Stdio::piped());

    match timeout_ms {
        None => run_command_untimed(cmd, stdin_bytes),
        Some(ms) => run_command_timed(cmd, stdin_bytes, ms),
    }
}

fn run_command_untimed(mut cmd: Command, stdin_bytes: Option<&[u8]>) -> Result<CmdOutput, B3Error> {
    #[cfg(windows)]
    {
        use std::os::windows::process::CommandExt;
        const CREATE_NO_WINDOW: u32 = 0x0800_0000;
        cmd.creation_flags(CREATE_NO_WINDOW);
    }

    let mut child = cmd
        .spawn()
        .map_err(|e| fail(format!("GIT_ERROR: failed to start process: {e}"), 1))?;

    let child_stdin = child.stdin.take();
    let mut child_stdout = child
        .stdout
        .take()
        .ok_or_else(|| fail("GIT_ERROR: missing child stdout handle", 1))?;
    let mut child_stderr = child
        .stderr
        .take()
        .ok_or_else(|| fail("GIT_ERROR: missing child stderr handle", 1))?;

    let stdin_handle = match (child_stdin, stdin_bytes) {
        (Some(sin), Some(bytes)) => {
            let owned = bytes.to_vec();
            Some(std::thread::spawn(move || write_stdin_all(sin, &owned)))
        }
        _ => None,
    };

    let stderr_handle = std::thread::spawn(move || {
        let mut buf = Vec::new();
        child_stderr.read_to_end(&mut buf).map(|_| buf)
    });

    let mut stdout = Vec::new();
    let stdout_res = child_stdout.read_to_end(&mut stdout);
    let stderr_res = stderr_handle
        .join()
        .map_err(|_| fail("GIT_ERROR: stderr reader thread panicked", 1))?;
    let status = child
        .wait()
        .map_err(|e| fail(format!("GIT_ERROR: failed waiting for process: {e}"), 1))?;

    if let Some(handle) = stdin_handle {
        let sin_res = handle
            .join()
            .map_err(|_| fail("GIT_ERROR: stdin writer thread panicked", 1))?;
        check_stdin_result(sin_res, status)?;
    }

    stdout_res.map_err(|e| fail(format!("GIT_ERROR: failed to read stdout: {e}"), 1))?;
    let stderr =
        stderr_res.map_err(|e| fail(format!("GIT_ERROR: failed to read stderr: {e}"), 1))?;

    Ok(CmdOutput {
        exit_code: status.code().unwrap_or(1),
        stdout,
        stderr,
    })
}

fn run_command_timed(
    mut cmd: Command,
    stdin_bytes: Option<&[u8]>,
    timeout_ms: u64,
) -> Result<CmdOutput, B3Error> {
    #[cfg(windows)]
    {
        use std::os::windows::process::CommandExt;
        const CREATE_NO_WINDOW: u32 = 0x0800_0000;
        const CREATE_SUSPENDED: u32 = 0x0000_0004;
        cmd.creation_flags(CREATE_NO_WINDOW | CREATE_SUSPENDED);
    }
    #[cfg(unix)]
    {
        use std::os::unix::process::CommandExt;
        cmd.process_group(0);
    }

    let deadline = Instant::now() + Duration::from_millis(timeout_ms);
    let mut child = cmd
        .spawn()
        .map_err(|e| fail(format!("GIT_ERROR: failed to start process: {e}"), 1))?;

    #[cfg(windows)]
    let job = {
        let guard = match win_job::WinJobGuard::attach(&child) {
            Ok(g) => g,
            Err(e) => {
                let _ = child.kill();
                let _ = reap_child_bounded(&mut child, CLEANUP_GRACE);
                return Err(e);
            }
        };
        if let Err(e) = win_job::resume_process_threads(child.id()) {
            let _ = guard.terminate();
            let _ = child.kill();
            let _ = reap_child_bounded(&mut child, CLEANUP_GRACE);
            drop(guard);
            return Err(e);
        }
        Some(guard)
    };

    let child_stdin = child.stdin.take();
    let Some(mut child_stdout) = child.stdout.take() else {
        cleanup_descendants(
            &child,
            #[cfg(windows)]
            job,
        );
        let _ = child.kill();
        let _ = reap_child_bounded(&mut child, CLEANUP_GRACE);
        return Err(fail("GIT_ERROR: missing child stdout handle", 1));
    };
    let Some(mut child_stderr) = child.stderr.take() else {
        cleanup_descendants(
            &child,
            #[cfg(windows)]
            job,
        );
        let _ = child.kill();
        let _ = reap_child_bounded(&mut child, CLEANUP_GRACE);
        return Err(fail("GIT_ERROR: missing child stderr handle", 1));
    };

    let mut stdin_task = match (child_stdin, stdin_bytes) {
        (Some(sin), Some(bytes)) => {
            let owned = bytes.to_vec();
            Some(spawn_pipe_task(move || write_stdin_all(sin, &owned)))
        }
        _ => None,
    };

    let mut stdout_task = Some(spawn_pipe_task(move || {
        let mut buf = Vec::new();
        child_stdout.read_to_end(&mut buf).map(|_| buf)
    }));

    let mut stderr_task = Some(spawn_pipe_task(move || {
        let mut buf = Vec::new();
        child_stderr.read_to_end(&mut buf).map(|_| buf)
    }));

    let status = loop {
        match child.try_wait() {
            Ok(Some(st)) => break st,
            Ok(None) => {}
            Err(e) => {
                cleanup_descendants(
                    &child,
                    #[cfg(windows)]
                    job,
                );
                return Err(fail(format!("GIT_ERROR: failed polling process: {e}"), 1));
            }
        }
        let now = Instant::now();
        if now >= deadline {
            return Ok(abort_and_cleanup(
                &mut child,
                #[cfg(windows)]
                job,
                stdout_task,
                stderr_task,
                stdin_task,
            ));
        }
        let sleep_dur = deadline
            .saturating_duration_since(now)
            .min(Duration::from_millis(10));
        std::thread::sleep(sleep_dur);
    };

    let stdout = match take_pipe_with_deadline(&mut stdout_task, deadline, "stdout") {
        Ok(Some(data)) => data,
        Ok(None) => {
            return Ok(abort_and_cleanup(
                &mut child,
                #[cfg(windows)]
                job,
                stdout_task,
                stderr_task,
                stdin_task,
            ));
        }
        Err(e) => {
            cleanup_descendants(
                &child,
                #[cfg(windows)]
                job,
            );
            return Err(e);
        }
    };

    let stderr = match take_pipe_with_deadline(&mut stderr_task, deadline, "stderr") {
        Ok(Some(data)) => data,
        Ok(None) => {
            return Ok(abort_and_cleanup(
                &mut child,
                #[cfg(windows)]
                job,
                stdout_task,
                stderr_task,
                stdin_task,
            ));
        }
        Err(e) => {
            cleanup_descendants(
                &child,
                #[cfg(windows)]
                job,
            );
            return Err(e);
        }
    };

    let stdin_result = if let Some(task) = stdin_task.take() {
        let rem = deadline.saturating_duration_since(Instant::now());
        match task.rx.recv_timeout(rem) {
            Ok(res) => {
                let _ = task.handle.join();
                res
            }
            Err(RecvTimeoutError::Timeout) => {
                stdin_task = Some(task);
                return Ok(abort_and_cleanup(
                    &mut child,
                    #[cfg(windows)]
                    job,
                    stdout_task,
                    stderr_task,
                    stdin_task,
                ));
            }
            Err(RecvTimeoutError::Disconnected) => {
                let _ = task.handle.join();
                cleanup_descendants(
                    &child,
                    #[cfg(windows)]
                    job,
                );
                return Err(fail("GIT_ERROR: stdin writer thread panicked", 1));
            }
        }
    } else {
        Ok(())
    };

    cleanup_descendants(
        &child,
        #[cfg(windows)]
        job,
    );
    check_stdin_result(stdin_result, status)?;

    Ok(CmdOutput {
        exit_code: status.code().unwrap_or(1),
        stdout,
        stderr,
    })
}

#[cfg(test)]
mod tests {
    use std::path::PathBuf;
    use std::sync::atomic::{AtomicUsize, Ordering};

    use super::*;

    static NEXT_TEMP_ID: AtomicUsize = AtomicUsize::new(0);

    struct TempDirGuard(PathBuf);

    impl TempDirGuard {
        fn new(prefix: &str) -> Self {
            let seq = NEXT_TEMP_ID.fetch_add(1, Ordering::Relaxed);
            let dir = std::env::temp_dir().join(format!(
                "b3-process-unit-{prefix}-{}-{seq}",
                std::process::id()
            ));
            let _ = std::fs::remove_dir_all(&dir);
            std::fs::create_dir_all(&dir).expect("create temp test dir");
            Self(dir)
        }

        fn path(&self) -> &Path {
            &self.0
        }
    }

    impl Drop for TempDirGuard {
        fn drop(&mut self) {
            let _ = std::fs::remove_dir_all(&self.0);
        }
    }

    fn read_pid_file(path: &Path) -> u32 {
        let raw = std::fs::read_to_string(path).expect("expected child/grandchild PID file");
        raw.trim().parse::<u32>().expect("valid numeric PID")
    }

    fn assert_pid_dead(pid: u32) {
        let stop = Instant::now() + Duration::from_millis(500);
        while is_pid_alive(pid) && Instant::now() < stop {
            std::thread::sleep(Duration::from_millis(10));
        }
        assert!(!is_pid_alive(pid), "process {pid} should be dead");
    }

    fn shell_cmd(script_win: &str, script_unix: &str) -> (&'static str, Vec<String>) {
        #[cfg(windows)]
        {
            let _ = script_unix;
            (
                "cmd",
                vec!["/d".to_string(), "/c".to_string(), script_win.to_string()],
            )
        }
        #[cfg(not(windows))]
        {
            let _ = script_win;
            ("sh", vec!["-c".to_string(), script_unix.to_string()])
        }
    }

    #[cfg(windows)]
    fn warm_windows_node() {
        static WARMED: std::sync::Once = std::sync::Once::new();
        WARMED.call_once(|| {
            let no_env: [(&str, &str); 0] = [];
            let _ = run_command(
                OsStr::new("node"),
                &["-e", "process.exit(0)"],
                None,
                &no_env,
                &[],
                None,
            );
        });
    }

    #[test]
    fn timeout_triggers_when_child_ignores_large_stdin() {
        #[cfg(windows)]
        warm_windows_node();
        let tmp = TempDirGuard::new("large-stdin-timeout");
        let pid_file = tmp.path().join("child.pid");
        let env = [("B3_TEST_PID_FILE", pid_file.as_os_str())];
        #[cfg(windows)]
        let (prog, args) = (
            "node",
            vec![
                "-e".to_string(),
                "require('fs').writeFileSync(process.env.B3_TEST_PID_FILE,String(process.pid));setTimeout(()=>{},30000);".to_string(),
            ],
        );
        #[cfg(not(windows))]
        let (prog, args) = (
            "sh",
            vec![
                "-c".to_string(),
                "printf '%s' \"$$\" > \"$B3_TEST_PID_FILE\"; exec sleep 30".to_string(),
            ],
        );
        let payload = vec![b'x'; 2 * 1024 * 1024];
        let start = Instant::now();
        let out = run_command_timeout(
            OsStr::new(prog),
            &args,
            None,
            &env,
            &[],
            Some(&payload),
            Some(3_500),
        )
        .expect("timeout should return CmdOutput");
        let elapsed = start.elapsed();
        assert_eq!(out.exit_code, 124);
        assert!(
            elapsed < Duration::from_secs(7),
            "expected prompt timeout when child ignores large stdin, elapsed={elapsed:?}"
        );
        let pid = read_pid_file(&pid_file);
        assert_pid_dead(pid);
    }

    #[test]
    fn child_exiting_zero_before_consuming_large_stdin_returns_error() {
        let (prog, args) = shell_cmd("exit 0", "exit 0");
        let payload = vec![b'x'; 2 * 1024 * 1024];
        let no_env: [(&str, &str); 0] = [];
        let err = run_command_timeout(
            OsStr::new(prog),
            &args,
            None,
            &no_env,
            &[],
            Some(&payload),
            Some(5_000),
        )
        .expect_err("exiting 0 without reading large stdin must return Err");
        assert!(
            err.to_string().contains("failed to write stdin"),
            "unexpected error: {err}"
        );
    }

    #[test]
    fn child_exiting_nonzero_before_consuming_large_stdin_preserves_exit_code() {
        let (prog, args) = shell_cmd(
            "echo boom-err 1>&2 & exit /b 7",
            "echo boom-err >&2; exit 7",
        );
        let payload = vec![b'x'; 2 * 1024 * 1024];
        let no_env: [(&str, &str); 0] = [];
        let out = run_command_timeout(
            OsStr::new(prog),
            &args,
            None,
            &no_env,
            &[],
            Some(&payload),
            Some(5_000),
        )
        .expect("non-zero exit with BrokenPipe stdin should preserve exit code");
        assert_eq!(out.exit_code, 7);
        let stderr = String::from_utf8_lossy(&out.stderr);
        assert!(stderr.contains("boom-err"), "stderr={stderr:?}");
    }

    #[test]
    fn timeout_kills_grandchild_holding_stdout_pipe() {
        #[cfg(windows)]
        warm_windows_node();
        let tmp = TempDirGuard::new("grandchild-stdout");
        let pid_file = tmp.path().join("grandchild.pid");
        let env = [("B3_TEST_PID_FILE", pid_file.as_os_str())];
        #[cfg(windows)]
        let (prog, args) = (
            "node",
            vec![
                "-e".to_string(),
                "const fs=require('fs'),{spawn}=require('child_process');const p=spawn(process.execPath,['-e','setTimeout(()=>{},30000)'],{stdio:['ignore',1,'ignore']});fs.writeFileSync(process.env.B3_TEST_PID_FILE,String(p.pid));".to_string(),
            ],
        );
        #[cfg(not(windows))]
        let (prog, args) = (
            "sh",
            vec![
                "-c".to_string(),
                "sleep 30 2>/dev/null & printf '%s' \"$!\" > \"$B3_TEST_PID_FILE\"".to_string(),
            ],
        );
        let start = Instant::now();
        let out = run_command_timeout(OsStr::new(prog), &args, None, &env, &[], None, Some(3_500))
            .expect("timeout should kill grandchild holding stdout and return");
        let elapsed = start.elapsed();
        assert_eq!(out.exit_code, 124);
        assert!(
            elapsed < Duration::from_secs(7),
            "expected prompt process-tree termination on stdout timeout, elapsed={elapsed:?}"
        );
        let pid = read_pid_file(&pid_file);
        assert_pid_dead(pid);
    }

    #[test]
    fn timeout_kills_grandchild_holding_stderr_pipe() {
        #[cfg(windows)]
        warm_windows_node();
        let tmp = TempDirGuard::new("grandchild-stderr");
        let pid_file = tmp.path().join("grandchild.pid");
        let env = [("B3_TEST_PID_FILE", pid_file.as_os_str())];
        #[cfg(windows)]
        let (prog, args) = (
            "node",
            vec![
                "-e".to_string(),
                "const fs=require('fs'),{spawn}=require('child_process');const p=spawn(process.execPath,['-e','setTimeout(()=>{},30000)'],{stdio:['ignore','ignore',2]});fs.writeFileSync(process.env.B3_TEST_PID_FILE,String(p.pid));".to_string(),
            ],
        );
        #[cfg(not(windows))]
        let (prog, args) = (
            "sh",
            vec![
                "-c".to_string(),
                "sleep 30 >/dev/null & printf '%s' \"$!\" > \"$B3_TEST_PID_FILE\"".to_string(),
            ],
        );
        let start = Instant::now();
        let out = run_command_timeout(OsStr::new(prog), &args, None, &env, &[], None, Some(3_500))
            .expect("timeout should kill grandchild holding stderr and return");
        let elapsed = start.elapsed();
        assert_eq!(out.exit_code, 124);
        assert!(
            elapsed < Duration::from_secs(7),
            "expected prompt process-tree termination on stderr timeout, elapsed={elapsed:?}"
        );
        let pid = read_pid_file(&pid_file);
        assert_pid_dead(pid);
    }

    #[test]
    fn parent_exits_while_descendant_remains_alive_is_cleaned_up() {
        #[cfg(windows)]
        warm_windows_node();
        let tmp = TempDirGuard::new("detached-descendant");
        let pid_file = tmp.path().join("descendant.pid");
        let env = [("B3_TEST_PID_FILE", pid_file.as_os_str())];
        #[cfg(windows)]
        let (prog, args) = (
            "node",
            vec![
                "-e".to_string(),
                "const fs=require('fs'),{spawn}=require('child_process');const p=spawn(process.execPath,['-e','setTimeout(()=>{},30000)'],{stdio:'ignore',detached:true});fs.writeFileSync(process.env.B3_TEST_PID_FILE,String(p.pid));process.exit(0);".to_string(),
            ],
        );
        #[cfg(not(windows))]
        let (prog, args) = (
            "sh",
            vec![
                "-c".to_string(),
                "sleep 30 </dev/null >/dev/null 2>&1 & printf '%s' \"$!\" > \"$B3_TEST_PID_FILE\""
                    .to_string(),
            ],
        );
        let start = Instant::now();
        let out = run_command_timeout(OsStr::new(prog), &args, None, &env, &[], None, Some(10_000))
            .expect("parent exit with closed-stdio descendant should return cleanly");
        let elapsed = start.elapsed();
        assert_eq!(out.exit_code, 0);
        assert!(
            elapsed < Duration::from_secs(6),
            "expected prompt return when descendant closes stdio, elapsed={elapsed:?}"
        );
        let pid = read_pid_file(&pid_file);
        assert_pid_dead(pid);
    }

    #[test]
    fn repeated_timeout_invocations_clean_up_reliably() {
        let tmp = TempDirGuard::new("repeated-timeouts");
        let mut pids = Vec::with_capacity(5);
        #[cfg(windows)]
        warm_windows_node();
        let start = Instant::now();
        for idx in 0..5 {
            let pid_file = tmp.path().join(format!("grandchild-{idx}.pid"));
            let env = [("B3_TEST_PID_FILE", pid_file.as_os_str())];
            #[cfg(windows)]
            let (prog, args) = (
                "node",
                vec![
                    "-e".to_string(),
                    "const fs=require('fs'),{spawn}=require('child_process');const p=spawn(process.execPath,['-e','setTimeout(()=>{},30000)'],{stdio:['ignore',1,2]});fs.writeFileSync(process.env.B3_TEST_PID_FILE,String(p.pid));setTimeout(()=>{},30000);".to_string(),
                ],
            );
            #[cfg(not(windows))]
            let (prog, args) = (
                "sh",
                vec![
                    "-c".to_string(),
                    "sleep 30 & printf '%s' \"$!\" > \"$B3_TEST_PID_FILE\"; wait".to_string(),
                ],
            );
            let out =
                run_command_timeout(OsStr::new(prog), &args, None, &env, &[], None, Some(2_500))
                    .expect("repeated timeout should succeed with exit 124");
            assert_eq!(out.exit_code, 124);
            pids.push(read_pid_file(&pid_file));
        }
        let elapsed = start.elapsed();
        assert!(
            elapsed < Duration::from_secs(18),
            "5 back-to-back timeouts should complete < 18s, elapsed={elapsed:?}"
        );
        for pid in pids {
            assert_pid_dead(pid);
        }
    }

    #[test]
    fn stdin_roundtrip_and_exit_code() {
        let (prog, args) = shell_cmd("findstr hello", "cat");
        let payload = b"hello-b3-stdin\n";
        let no_env: [(&str, &str); 0] = [];
        let out_timed = run_command_timeout(
            OsStr::new(prog),
            &args,
            None,
            &no_env,
            &[],
            Some(payload),
            Some(5_000),
        )
        .expect("timed stdin roundtrip succeeds");
        assert_eq!(out_timed.exit_code, 0);
        let text_timed = String::from_utf8_lossy(&out_timed.stdout);
        assert!(
            text_timed.contains("hello-b3-stdin"),
            "stdout={text_timed:?}"
        );

        let out_untimed = run_command(OsStr::new(prog), &args, None, &no_env, &[], Some(payload))
            .expect("untimed stdin roundtrip succeeds");
        assert_eq!(out_untimed.exit_code, 0);
        let text_untimed = String::from_utf8_lossy(&out_untimed.stdout);
        assert!(
            text_untimed.contains("hello-b3-stdin"),
            "stdout={text_untimed:?}"
        );
    }

    #[test]
    fn nonzero_exit_code_preserved() {
        let (prog, args) = shell_cmd(
            "echo out-msg & echo err-msg 1>&2 & exit /b 7",
            "echo out-msg; echo err-msg >&2; exit 7",
        );
        let no_env: [(&str, &str); 0] = [];

        for timeout in [None, Some(5_000)] {
            let out =
                run_command_timeout(OsStr::new(prog), &args, None, &no_env, &[], None, timeout)
                    .expect("non-zero exit should return CmdOutput");
            assert_eq!(out.exit_code, 7);
            let stdout = String::from_utf8_lossy(&out.stdout);
            let stderr = String::from_utf8_lossy(&out.stderr);
            assert!(stdout.contains("out-msg"), "stdout={stdout:?}");
            assert!(stderr.contains("err-msg"), "stderr={stderr:?}");
        }
    }
}
