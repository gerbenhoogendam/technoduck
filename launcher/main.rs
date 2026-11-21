// Starts the Swift app with the same arguments (e.g. --screenshot out.png).
use std::os::unix::process::CommandExt;
use std::path::Path;

fn main() {
    let bin = Path::new(env!("CARGO_MANIFEST_DIR")).join(".build/release/Technoduck");
    let err = std::process::Command::new(&bin).args(std::env::args_os().skip(1)).exec();
    eprintln!("could not start {}: {err}", bin.display());
    std::process::exit(1);
}
