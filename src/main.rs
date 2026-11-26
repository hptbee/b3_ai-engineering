use std::io::Write;

fn main() {
    let args: Vec<String> = std::env::args().skip(1).collect();
    match b3::dispatch_args(&args) {
        Ok((output, code)) => {
            if !output.is_empty() {
                let mut stdout = std::io::stdout().lock();
                if output.ends_with('\n') {
                    let _ = stdout.write_all(output.as_bytes());
                } else {
                    let _ = writeln!(stdout, "{output}");
                }
                let _ = stdout.flush();
            }
            std::process::exit(code);
        }
        Err(err) => {
            let mut stdout = std::io::stdout().lock();
            let _ = writeln!(stdout, "{}", err.message);
            let _ = stdout.flush();
            std::process::exit(err.code);
        }
    }
}
