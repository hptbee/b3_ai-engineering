use std::ffi::OsStr;
use std::io::{Read, Write};
use std::path::Path;
use std::process::{Command, Stdio};

use std::time::{Duration, Instant};

use crate::error::{fail, B3Error};

/// Captured output from a child process.
#[derive(Debug, Clone)]
pub struct CmdOutput {
    pub exit_code: i32,
    pub stdout: Vec<u8>,
    pub stderr: Vec<u8>,
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

    let mut child = cmd
        .spawn()
        .map_err(|e| fail(format!("GIT_ERROR: failed to start process: {e}"), 1))?;

    let mut child_stdin = child.stdin.take();
    let mut child_stdout = child
        .stdout
        .take()
        .ok_or_else(|| fail("GIT_ERROR: missing child stdout handle", 1))?;
    let mut child_stderr = child
        .stderr
        .take()
        .ok_or_else(|| fail("GIT_ERROR: missing child stderr handle", 1))?;

    std::thread::scope(|scope| {
        let stdin_handle = stdin_bytes.map(|bytes| {
            scope.spawn(move || -> std::io::Result<()> {
                if let Some(mut sin) = child_stdin.take() {
                    if !bytes.is_empty() {
                        sin.write_all(bytes)?;
                    }
                    sin.flush()?;
                }
                Ok(())
            })
        });

        let stdout_handle = scope.spawn(move || -> std::io::Result<Vec<u8>> {
            let mut buf = Vec::new();
            child_stdout.read_to_end(&mut buf)?;
            Ok(buf)
        });

        let stderr_handle = scope.spawn(move || -> std::io::Result<Vec<u8>> {
            let mut buf = Vec::new();
            child_stderr.read_to_end(&mut buf)?;
            Ok(buf)
        });

        if let Some(h) = stdin_handle {
            let _ = h.join();
        }
        let status = match timeout_ms {
            None => child
                .wait()
                .map_err(|e| fail(format!("GIT_ERROR: failed waiting for process: {e}"), 1))?,
            Some(ms) => {
                let deadline = Instant::now() + Duration::from_millis(ms);
                loop {
                    if let Some(st) = child
                        .try_wait()
                        .map_err(|e| fail(format!("GIT_ERROR: failed polling process: {e}"), 1))?
                    {
                        break st;
                    }
                    if Instant::now() >= deadline {
                        let _ = child.kill();
                        let _ = child.wait();
                        let _ = stdout_handle.join();
                        let _ = stderr_handle.join();
                        return Ok(CmdOutput {
                            exit_code: 124,
                            stdout: Vec::new(),
                            stderr: Vec::new(),
                        });
                    }
                    std::thread::sleep(Duration::from_millis(20));
                }
            }
        };
        let stdout = stdout_handle
            .join()
            .map_err(|_| fail("GIT_ERROR: stdout reader thread panicked", 1))?
            .map_err(|e| fail(format!("GIT_ERROR: failed to read stdout: {e}"), 1))?;
        let stderr = stderr_handle
            .join()
            .map_err(|_| fail("GIT_ERROR: stderr reader thread panicked", 1))?
            .map_err(|e| fail(format!("GIT_ERROR: failed to read stderr: {e}"), 1))?;

        Ok(CmdOutput {
            exit_code: status.code().unwrap_or(1),
            stdout,
            stderr,
        })
    })
}
