use std::io::Write;

fn write_stream(mut stream: impl Write, text: &str) {
    if !text.is_empty() {
        if text.ends_with('\n') {
            let _ = stream.write_all(text.as_bytes());
        } else {
            let _ = writeln!(stream, "{text}");
        }
        let _ = stream.flush();
    }
}

fn main() {
    let args: Vec<String> = std::env::args().skip(1).collect();
    match b3::dispatch_args_io(&args) {
        Ok(res) => {
            write_stream(std::io::stdout().lock(), &res.stdout);
            write_stream(std::io::stderr().lock(), &res.stderr);
            std::process::exit(res.exit_code);
        }
        Err(err) => {
            if args.first().map(String::as_str) == Some("hook") {
                write_stream(std::io::stderr().lock(), &err.message);
            } else {
                write_stream(std::io::stdout().lock(), &err.message);
            }
            std::process::exit(err.code);
        }
    }
}
