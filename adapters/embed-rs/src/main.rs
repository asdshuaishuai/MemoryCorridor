// Native embedding provider for MemoryCorridor's vector subsystem (续二十五).
// The engine's MoonBit core never calls a model; it stores and searches vectors
// that a host produces. This is that host producer: bge-small-zh-v1.5 (Apache-2.0,
// 512-dim) over the ONNX Runtime OCR already introduced -- no Python.
//
// Contract with the engine:
//   stdin  : a JSON array of {page, sha256, text}  (the `embedding-plan` items)
//   stdout : a JSON array of {page, sha256, values} (the `embedding-submit` items)
// The engine re-validates dimensions, finiteness, normalization and the page
// content version; this adapter just produces the vectors.
//
// bge retrieval recipe: WordPiece tokenize with [CLS]/[SEP] (the tokenizer's
// post-processor adds them), CLS pooling (position 0 of last_hidden_state),
// then L2 normalize. Skipping [CLS]/[SEP] silently degrades similarity -- the
// documented pitfall this pins against.

use ndarray::{Array2, Array3};
use ort::session::Session;
use ort::value::Tensor;
use serde_json::{json, Value};
use std::io::Read;
use std::path::Path;

// Apple clang availability shim (see adapters/ocr-rs for the rationale).
#[cfg(target_os = "macos")]
#[unsafe(no_mangle)]
pub extern "C" fn __isPlatformVersionAtLeast(_p: u32, _major: u32, _minor: u32, _patch: u32) -> i32 {
    1
}

const MODEL: &str = "model_int8.onnx";
const TOKENIZER: &str = "tokenizer.json";
const DIM: usize = 512;

fn ort_environment() -> Result<ort::environment::Environment, String> {
    if let Ok(p) = std::env::var("ORT_DYLIB_PATH") {
        if !p.is_empty() {
            if !Path::new(&p).exists() {
                return Err(format!("ORT_DYLIB_PATH={p} does not exist"));
            }
            return ort::init_from(&p)
                .map_err(|e| format!("loading ORT dylib {p}: {e}"))?
                .build()
                .map_err(|e| e.to_string());
        }
    }
    if let Some(dir) = std::env::current_exe().ok().and_then(|x| x.parent().map(|d| d.to_path_buf())) {
        let cand = dir.join("libonnxruntime.dylib");
        if cand.exists() {
            return ort::init_from(&cand)
                .map_err(|e| format!("loading ORT dylib {}: {e}", cand.display()))?
                .build()
                .map_err(|e| e.to_string());
        }
    }
    Err("ONNX Runtime dylib not found: set ORT_DYLIB_PATH or place libonnxruntime.dylib next to embed-adapter".to_string())
}

fn model_dir() -> String {
    std::env::var("EMBED_MODEL_DIR")
        .unwrap_or_else(|_| {
            let exe = std::env::current_exe().ok();
            let base = exe.as_ref().and_then(|p| p.parent().map(|d| d.to_path_buf()));
            match base {
                Some(d) => d.join("model").to_string_lossy().into_owned(),
                None => "model".to_string(),
            }
        })
}

fn embed(session: &mut Session, tok: &tokenizers::Tokenizer, text: &str) -> Result<Vec<f32>, String> {
    let enc = tok.encode(text, true).map_err(|e| e.to_string())?; // add_special_tokens = true ([CLS]..[SEP])
    let ids = enc.get_ids();
    let mask = enc.get_attention_mask();
    let seq = ids.len();
    if seq == 0 {
        return Err("empty tokenization".into());
    }
    let mut id_arr = Array2::<i64>::zeros((1, seq));
    let mut mask_arr = Array2::<i64>::zeros((1, seq));
    let mut type_arr = Array2::<i64>::zeros((1, seq));
    for (i, (&id, &m)) in ids.iter().zip(mask.iter()).enumerate() {
        id_arr[[0, i]] = id as i64;
        mask_arr[[0, i]] = m as i64;
        type_arr[[0, i]] = 0;
    }
    let out = session
        .run(ort::inputs![
            "input_ids" => Tensor::from_array(id_arr).map_err(|e| e.to_string())?,
            "attention_mask" => Tensor::from_array(mask_arr).map_err(|e| e.to_string())?,
            "token_type_ids" => Tensor::from_array(type_arr).map_err(|e| e.to_string())?,
        ])
        .map_err(|e| e.to_string())?;
    let (shape, data) = out[0]
        .try_extract_tensor::<f32>()
        .map_err(|e| e.to_string())?;
    // last_hidden_state [1, seq, DIM]; CLS pooling = position 0.
    let dims3: [usize; 3] = [shape[0] as usize, shape[1] as usize, shape[2] as usize];
    let _ = Array3::<f32>::from_shape_vec(dims3, data.to_vec()).map_err(|e| e.to_string())?;
    let cls = &data[..DIM];
    let norm = cls.iter().map(|x| x * x).sum::<f32>().sqrt();
    if norm == 0.0 || !norm.is_finite() {
        return Err("zero/non-finite CLS norm".into());
    }
    Ok(cls.iter().map(|x| x / norm).collect())
}

fn cosine(a: &[f32], b: &[f32]) -> f32 {
    a.iter().zip(b).map(|(x, y)| x * y).sum()
}

fn main() {
    let args: Vec<String> = std::env::args().collect();
    let selftest = args.iter().any(|a| a == "--selftest");
    let env = match ort_environment() {
        Ok(e) => e,
        Err(e) => {
            eprintln!("{e}");
            std::process::exit(2);
        }
    };
    let dir = model_dir();
    let model_path = format!("{dir}/{MODEL}");
    let tok_path = format!("{dir}/{TOKENIZER}");
    if !Path::new(&model_path).exists() || !Path::new(&tok_path).exists() {
        eprintln!("embedding model not found under {dir}; run scripts/fetch_bge.sh");
        std::process::exit(2);
    }
    let tok = tokenizers::Tokenizer::from_file(&tok_path).map_err(|e| e.to_string()).unwrap();
    let mut session = Session::builder(&env)
        .map_err(|e| e.to_string())
        .unwrap()
        .with_intra_threads(2)
        .map_err(|e| e.to_string())
        .unwrap()
        .commit_from_file(&model_path)
        .map_err(|e| e.to_string())
        .unwrap();

    if selftest {
        // Deterministic sanity: two related Chinese sentences should be much
        // closer than a celadon sentence vs an unrelated one. Guards the
        // [CLS]/[SEP] + pooling + normalize recipe end to end.
        let a = embed(&mut session, &tok, "龙泉窑青瓷以粉青与梅子青著称").unwrap();
        let b = embed(&mut session, &tok, "梅子青是龙泉窑的代表釉色").unwrap();
        let c = embed(&mut session, &tok, "如何把 JSON 对象序列化成字符串").unwrap();
        println!("{}", json!({"dim": a.len(), "cos_related": cosine(&a, &b), "cos_unrelated": cosine(&a, &c)}));
        return;
    }

    let mut buf = String::new();
    std::io::stdin().read_to_string(&mut buf).unwrap();
    let items: Vec<Value> = serde_json::from_str(&buf).map_err(|e| e.to_string()).unwrap();
    let mut out: Vec<Value> = Vec::new();
    for item in items {
        let text = item.get("text").and_then(|v| v.as_str()).unwrap_or("");
        let vec = match embed(&mut session, &tok, text) {
            Ok(v) => v,
            Err(e) => {
                eprintln!("embed failed for {}: {e}", item.get("page").and_then(|v| v.as_str()).unwrap_or("?"));
                std::process::exit(1);
            }
        };
        out.push(json!({
            "page": item.get("page"),
            "sha256": item.get("sha256"),
            "values": vec,
        }));
    }
    println!("{}", serde_json::to_string(&out).unwrap());
}
