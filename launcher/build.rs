// Compiles the Swift app; a Swift compile error fails `cargo build`.
use std::process::Command;

fn main() {
    println!("cargo:rerun-if-changed=Package.swift");
    println!("cargo:rerun-if-changed=Sources");
    let ok = Command::new("swift").args(["build", "-c", "release"]).status().map(|s| s.success()).unwrap_or(false);
    assert!(ok, "swift build failed");
}
