use std::ffi::OsStr;
use std::io::{ErrorKind, Read, Write};
use std::path::Path;
use std::process::{Child, Command, ExitStatus, Stdio};
use std::sync::mpsc::{self, RecvTimeoutError};
use std::time::{Duration, Instant};

use crate::error::{fail, B3Error};

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

    type Handle = *mut core::ffi::c_void;
    type Bool = i32;

    const JOB_OBJECT_EXTENDED_LIMIT_INFORMATION_CLASS: u32 = 9;
    const JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE: u32 = 0x2000;

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
        fn CloseHandle(h_object: Handle) -> Bool;
    }

    pub struct WinJobGuard {
        handle: Handle,
        assigned: bool,
    }

    impl WinJobGuard {
        pub fn attach(child: &Child) -> Self {
            // SAFETY: Win32 Job Object APIs receive valid pointers/handles and zeroed attributes.
            unsafe {
                let job = CreateJobObjectW(core::ptr::null(), core::ptr::null());
                if job.is_null() {
                    return Self {
                        handle: core::ptr::null_mut(),
                        assigned: false,
                    };
                }
                let mut info = JobObjectExtendedLimitInformation::default();
                info.basic_limit_information.limit_flags = JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE;
                let ok_info = SetInformationJobObject(
                    job,
                    JOB_OBJECT_EXTENDED_LIMIT_INFORMATION_CLASS,
                    (&info as *const JobObjectExtendedLimitInformation).cast::<core::ffi::c_void>(),
                    core::mem::size_of::<JobObjectExtendedLimitInformation>() as u32,
                );
                let ok_assign = if ok_info != 0 {
                    AssignProcessToJobObject(job, child.as_raw_handle()) != 0
                } else {
                    false
                };
                if !ok_assign {
                    CloseHandle(job);
                    return Self {
                        handle: core::ptr::null_mut(),
                        assigned: false,
                    };
                }
                Self {
                    handle: job,
                    assigned: true,
                }
            }
        }

        pub fn terminate(&self) -> bool {
            if !self.assigned || self.handle.is_null() {
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
}

fn kill_process_tree(child: &mut Child, #[cfg(windows)] job: Option<&win_job::WinJobGuard>) {
    #[cfg(windows)]
    {
        let job_killed = job.is_some_and(win_job::WinJobGuard::terminate);
        let _ = child.kill();
        if !job_killed {
            use std::os::windows::process::CommandExt;
            const CREATE_NO_WINDOW: u32 = 0x0800_0000;
            let pid_str = child.id().to_string();
            let _ = Command::new("taskkill")
                .args(["/F", "/T", "/PID", &pid_str])
                .creation_flags(CREATE_NO_WINDOW)
                .stdin(Stdio::null())
                .stdout(Stdio::null())
                .stderr(Stdio::null())
                .status();
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

    #[cfg(windows)]
    {
        use std::os::windows::process::CommandExt;
        const CREATE_NO_WINDOW: u32 = 0x0800_0000;
        cmd.creation_flags(CREATE_NO_WINDOW);
    }
    #[cfg(unix)]
    {
        use std::os::unix::process::CommandExt;
        cmd.process_group(0);
    }

    let mut child = cmd
        .spawn()
        .map_err(|e| fail(format!("GIT_ERROR: failed to start process: {e}"), 1))?;

    let deadline = timeout_ms.map(|ms| Instant::now() + Duration::from_millis(ms));

    #[cfg(windows)]
    let job = if timeout_ms.is_some() {
        Some(win_job::WinJobGuard::attach(&child))
    } else {
        None
    };

    let child_stdin = child.stdin.take();
    let mut child_stdout = child
        .stdout
        .take()
        .ok_or_else(|| fail("GIT_ERROR: missing child stdout handle", 1))?;
    let mut child_stderr = child
        .stderr
        .take()
        .ok_or_else(|| fail("GIT_ERROR: missing child stderr handle", 1))?;

    let stdin_rx = if let (Some(mut sin), Some(bytes)) = (child_stdin, stdin_bytes) {
        let owned = bytes.to_vec();
        let (tx, rx) = mpsc::sync_channel(1);
        std::thread::spawn(move || {
            let res = (|| -> std::io::Result<()> {
                if !owned.is_empty() {
                    sin.write_all(&owned)?;
                }
                sin.flush()?;
                Ok(())
            })();
            drop(sin);
            let _ = tx.send(res);
        });
        Some(rx)
    } else {
        None
    };

    let (stdout_tx, stdout_rx) = mpsc::sync_channel(1);
    std::thread::spawn(move || {
        let mut buf = Vec::new();
        let res = child_stdout.read_to_end(&mut buf).map(|_| buf);
        let _ = stdout_tx.send(res);
    });

    let (stderr_tx, stderr_rx) = mpsc::sync_channel(1);
    std::thread::spawn(move || {
        let mut buf = Vec::new();
        let res = child_stderr.read_to_end(&mut buf).map(|_| buf);
        let _ = stderr_tx.send(res);
    });

    let status = match deadline {
        None => child
            .wait()
            .map_err(|e| fail(format!("GIT_ERROR: failed waiting for process: {e}"), 1))?,
        Some(dl) => loop {
            if let Some(st) = child
                .try_wait()
                .map_err(|e| fail(format!("GIT_ERROR: failed polling process: {e}"), 1))?
            {
                break st;
            }
            let now = Instant::now();
            if now >= dl {
                #[cfg(windows)]
                kill_process_tree(&mut child, job.as_ref());
                #[cfg(not(windows))]
                kill_process_tree(&mut child);

                let _ = reap_child_bounded(&mut child, Duration::from_millis(250));
                let _ = stdout_rx.recv_timeout(Duration::from_millis(150));
                let _ = stderr_rx.recv_timeout(Duration::from_millis(150));
                if let Some(ref rx) = stdin_rx {
                    let _ = rx.recv_timeout(Duration::from_millis(100));
                }
                return Ok(CmdOutput {
                    exit_code: 124,
                    stdout: Vec::new(),
                    stderr: Vec::new(),
                });
            }
            let sleep_dur = dl
                .saturating_duration_since(now)
                .min(Duration::from_millis(10));
            std::thread::sleep(sleep_dur);
        },
    };

    let recv_with_deadline = |rx: &mpsc::Receiver<std::io::Result<Vec<u8>>>,
                              label: &str|
     -> Result<Option<Vec<u8>>, B3Error> {
        match deadline {
            None => rx
                .recv()
                .map_err(|_| fail(format!("GIT_ERROR: {label} reader thread panicked"), 1))?
                .map(Some)
                .map_err(|e| fail(format!("GIT_ERROR: failed to read {label}: {e}"), 1)),
            Some(dl) => {
                let rem = dl.saturating_duration_since(Instant::now());
                match rx.recv_timeout(rem) {
                    Ok(Ok(data)) => Ok(Some(data)),
                    Ok(Err(e)) => Err(fail(format!("GIT_ERROR: failed to read {label}: {e}"), 1)),
                    Err(RecvTimeoutError::Timeout) => Ok(None),
                    Err(RecvTimeoutError::Disconnected) => Err(fail(
                        format!("GIT_ERROR: {label} reader thread panicked"),
                        1,
                    )),
                }
            }
        }
    };

    let Some(stdout) = recv_with_deadline(&stdout_rx, "stdout")? else {
        #[cfg(windows)]
        kill_process_tree(&mut child, job.as_ref());
        #[cfg(not(windows))]
        kill_process_tree(&mut child);
        return Ok(CmdOutput {
            exit_code: 124,
            stdout: Vec::new(),
            stderr: Vec::new(),
        });
    };
    let Some(stderr) = recv_with_deadline(&stderr_rx, "stderr")? else {
        #[cfg(windows)]
        kill_process_tree(&mut child, job.as_ref());
        #[cfg(not(windows))]
        kill_process_tree(&mut child);
        return Ok(CmdOutput {
            exit_code: 124,
            stdout: Vec::new(),
            stderr: Vec::new(),
        });
    };

    if let Some(rx) = stdin_rx {
        let sin_res = match deadline {
            None => rx
                .recv()
                .map_err(|_| fail("GIT_ERROR: stdin writer thread panicked", 1))?,
            Some(dl) => {
                let rem = dl.saturating_duration_since(Instant::now());
                match rx.recv_timeout(rem) {
                    Ok(r) => r,
                    Err(RecvTimeoutError::Timeout) => {
                        #[cfg(windows)]
                        kill_process_tree(&mut child, job.as_ref());
                        #[cfg(not(windows))]
                        kill_process_tree(&mut child);
                        return Ok(CmdOutput {
                            exit_code: 124,
                            stdout: Vec::new(),
                            stderr: Vec::new(),
                        });
                    }
                    Err(RecvTimeoutError::Disconnected) => {
                        return Err(fail("GIT_ERROR: stdin writer thread panicked", 1));
                    }
                }
            }
        };
        if let Err(e) = sin_res {
            if e.kind() != ErrorKind::BrokenPipe || status.success() {
                return Err(fail(format!("GIT_ERROR: failed to write stdin: {e}"), 1));
            }
        }
    }

    Ok(CmdOutput {
        exit_code: status.code().unwrap_or(1),
        stdout,
        stderr,
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    fn shell_sleep_cmd(
        script_win: &'static str,
        script_unix: &'static str,
    ) -> (&'static str, Vec<&'static str>) {
        #[cfg(windows)]
        {
            let _ = script_unix;
            ("cmd", vec!["/d", "/c", script_win])
        }
        #[cfg(not(windows))]
        {
            let _ = script_win;
            ("sh", vec!["-c", script_unix])
        }
    }

    #[test]
    fn timeout_triggers_when_child_ignores_large_stdin() {
        let (prog, args) = shell_sleep_cmd("ping -n 15 127.0.0.1 >nul", "sleep 15");
        let payload = vec![b'x'; 256 * 1024];
        let no_env: [(&str, &str); 0] = [];
        let start = Instant::now();
        let out = run_command_timeout(
            OsStr::new(prog),
            &args,
            None,
            &no_env,
            &[],
            Some(&payload),
            Some(400),
        )
        .expect("timeout should return CmdOutput");
        let elapsed = start.elapsed();
        assert_eq!(out.exit_code, 124);
        assert!(
            elapsed < Duration::from_secs(4),
            "expected prompt timeout when child ignores large stdin, elapsed={elapsed:?}"
        );
    }

    #[test]
    fn timeout_kills_grandchild_holding_stdout_pipe() {
        let (prog, args) =
            shell_sleep_cmd("cmd /d /c ping -n 15 127.0.0.1 >nul", "sleep 15 & wait");
        let no_env: [(&str, &str); 0] = [];
        let start = Instant::now();
        let out = run_command_timeout(OsStr::new(prog), &args, None, &no_env, &[], None, Some(400))
            .expect("timeout should kill process tree and return");
        let elapsed = start.elapsed();
        assert_eq!(out.exit_code, 124);
        assert!(
            elapsed < Duration::from_secs(4),
            "expected prompt process-tree termination on timeout, elapsed={elapsed:?}"
        );
    }

    #[test]
    fn stdin_roundtrip_and_exit_code() {
        let (prog, args) = shell_sleep_cmd("findstr hello", "cat");
        let payload = b"hello-b3-stdin\n";
        let no_env: [(&str, &str); 0] = [];
        let out = run_command_timeout(
            OsStr::new(prog),
            &args,
            None,
            &no_env,
            &[],
            Some(payload),
            Some(5000),
        )
        .expect("stdin roundtrip succeeds");
        assert_eq!(out.exit_code, 0);
        let text = String::from_utf8_lossy(&out.stdout);
        assert!(text.contains("hello-b3-stdin"), "stdout={text:?}");
    }
}
