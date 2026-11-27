// Embed the ONNX Runtime dylib into the adapter when the build host has it.
// The adapter still uses the official dylib (not the static pyke build): at
// startup it extracts the embedded bytes to a private temp file and dlopens
// that file. Builds without a local runtime keep the external fallback used
// by source checkouts that only ran `scripts/fetch_ort.sh` for a different
// architecture.

use std::env;
use std::fs;
use std::path::{Path, PathBuf};

fn main() {
    println!("cargo:rerun-if-changed=build.rs");
    let manifest = PathBuf::from(env::var("CARGO_MANIFEST_DIR").expect("CARGO_MANIFEST_DIR"));
    let candidates = [
        "libonnxruntime.dylib",
        "libonnxruntime.so",
        "onnxruntime.dll",
    ];
    for name in candidates {
        println!(
            "cargo:rerun-if-changed={}",
            manifest.join("runtime").join(name).display()
        );
    }
    let runtime = candidates
        .iter()
        .map(|name| manifest.join("runtime").join(name))
        .find(|path| path.is_file());
    let generated = Path::new(&env::var("OUT_DIR").expect("OUT_DIR")).join("embedded_ort.rs");
    match runtime {
        Some(path) => {
            println!("cargo:rerun-if-changed={}", path.display());
            let absolute = path.canonicalize().unwrap_or(path);
            let literal = format!("{:?}", absolute.to_string_lossy().as_ref());
            fs::write(
                generated,
                format!(
                    "pub static EMBEDDED_ORT: Option<&'static [u8]> = Some(include_bytes!({literal}));\n"
                ),
            )
            .expect("write embedded_ort.rs");
        }
        None => {
            fs::write(
                generated,
                "pub static EMBEDDED_ORT: Option<&'static [u8]> = None;\n",
            )
            .expect("write embedded_ort.rs");
        }
    }
}
