// Native embedding provider for MemoryCorridor's vector subsystem (续二十五).
// The engine's MoonBit core never calls a model; it stores and searches vectors
// that a host produces. This is that host producer: bge-small-zh-v1.5 (Apache-2.0,
// 512-dim) over the ONNX Runtime OCR already introduced -- no Python.
//
// Contract with the engine:
//   stdin  : a JSON array of embedding-plan items
//            text face :  {page, sha256, text, truncated}
//            image face :  {page, sha256, modality:"image", image, image_sha256}
//                          (only when the provider declares embed-multimodal)
//   stdout : a JSON array of {page, sha256, values}  (embedding-submit items)
// The engine re-validates dimensions, finiteness, normalization and the page
// content version; this adapter just produces the vectors.
//
// bge retrieval recipe: WordPiece tokenize with [CLS]/[SEP] (the tokenizer's
// post-processor adds them), CLS pooling (position 0 of last_hidden_state),
// then L2 normalize. Skipping [CLS]/[SEP] silently degrades similarity -- the
// documented pitfall this pins against.
//
// Optional multimodal face (续二十六): CLIP ViT-B/32 int8 ONNX (MIT weights,
// Xenova export; vision 89 MB + text 65 MB, both projections baked into the
// graph, so the IO is literally pixel_values->image_embeds and
// input_ids->text_embeds). Images are preprocessed with the official recipe
// (short-side resize 224 bicubic, center crop, CLIP mean/std) and byte-checked
// against the plan's image_sha256 lock. The CLIP text tower pads with token 0
// to 77 -- the mask is derived from padding inside the exported graph.
// Text stays the default: this face only appears for providers that declare
// embed-multimodal; without CLIP files present the text pipeline is untouched.

use image::imageops::FilterType;
use image::{DynamicImage, GenericImageView, Rgb, RgbImage};
use ndarray::{Array2, Array3, Array4};
use ort::session::Session;
use ort::value::Tensor;
use serde_json::{json, Value};
use sha2::{Digest, Sha256};
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

const VISION_MODEL: &str = "vision_model_quantized.onnx";
const MM_TEXT_MODEL: &str = "text_model_quantized.onnx";
const MM_SEQ: usize = 77;
const CLIP_EOS: u32 = 49407;
const CLIP_PAD: u32 = 0;
const CLIP_SIDE: u32 = 224;
const CLIP_MEAN: [f32; 3] = [0.48145466, 0.4578275, 0.40821073];
const CLIP_STD: [f32; 3] = [0.26862954, 0.26130258, 0.27577711];
// decode-bomb guards, same budgets as adapters/ocr-rs
const MAX_PIXELS: u64 = 25_000_000;
const MAX_DIM: u32 = 20_000;

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

fn clip_dir() -> String {
    std::env::var("EMBED_CLIP_DIR").unwrap_or_else(|_| {
        let exe = std::env::current_exe().ok();
        let base = exe.as_ref().and_then(|p| p.parent().map(|d| d.to_path_buf()));
        match base {
            Some(d) => d.join("clip").to_string_lossy().into_owned(),
            None => "clip".to_string(),
        }
    })
}

fn l2_normalize(v: Vec<f32>) -> Result<Vec<f32>, String> {
    let norm = v.iter().map(|x| x * x).sum::<f32>().sqrt();
    if norm == 0.0 || !norm.is_finite() {
        return Err("zero/non-finite norm".into());
    }
    Ok(v.iter().map(|x| x / norm).collect())
}

fn extract_512(out: &ort::session::SessionOutputs) -> Result<Vec<f32>, String> {
    let (shape, data) = out[0].try_extract_tensor::<f32>().map_err(|e| e.to_string())?;
    let total: usize = shape.iter().map(|d| *d as usize).product();
    if total != DIM {
        return Err(format!("expected {DIM}-dim embedding, graph returned {total}"));
    }
    Ok(data[..DIM].to_vec())
}

struct Bge {
    session: Session,
    tok: tokenizers::Tokenizer,
}

impl Bge {
    fn open(env: &ort::environment::Environment) -> Result<Bge, String> {
        let dir = model_dir();
        let model_path = format!("{dir}/{MODEL}");
        let tok_path = format!("{dir}/{TOKENIZER}");
        if !Path::new(&model_path).exists() || !Path::new(&tok_path).exists() {
            return Err(format!("embedding model not found under {dir}; run scripts/fetch_bge.sh"));
        }
        let tok = tokenizers::Tokenizer::from_file(&tok_path).map_err(|e| e.to_string())?;
        let session = Session::builder(env)
            .map_err(|e| e.to_string())?
            .with_intra_threads(2)
            .map_err(|e| e.to_string())?
            .commit_from_file(&model_path)
            .map_err(|e| e.to_string())?;
        Ok(Bge { session, tok })
    }

    fn embed(&mut self, text: &str) -> Result<Vec<f32>, String> {
        let enc = self.tok.encode(text, true).map_err(|e| e.to_string())?; // [CLS]..[SEP]
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
        let out = self
            .session
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
}

struct Mm {
    vision: Session,
    text: Session,
    tok: tokenizers::Tokenizer,
}

impl Mm {
    fn open(env: &ort::environment::Environment) -> Result<Mm, String> {
        let dir = clip_dir();
        let vis = format!("{dir}/{VISION_MODEL}");
        let txt = format!("{dir}/{MM_TEXT_MODEL}");
        let tok = format!("{dir}/{TOKENIZER}");
        if !Path::new(&vis).exists() || !Path::new(&txt).exists() || !Path::new(&tok).exists() {
            return Err(format!("CLIP multimodal pair not found under {dir}; run scripts/fetch_clip.sh"));
        }
        let tokenizer = tokenizers::Tokenizer::from_file(&tok).map_err(|e| e.to_string())?;
        let vision = Session::builder(env)
            .map_err(|e| e.to_string())?
            .with_intra_threads(2)
            .map_err(|e| e.to_string())?
            .commit_from_file(&vis)
            .map_err(|e| e.to_string())?;
        let text = Session::builder(env)
            .map_err(|e| e.to_string())?
            .with_intra_threads(2)
            .map_err(|e| e.to_string())?
            .commit_from_file(&txt)
            .map_err(|e| e.to_string())?;
        Ok(Mm { vision, text, tok: tokenizer })
    }

    // Official CLIP preprocessing: resize the short side to 224 (bicubic),
    // center crop, scale to [0,1], per-channel mean/std, CHW float tensor.
    fn preprocess(img: &DynamicImage) -> Result<Array4<f32>, String> {
        let (w, h) = img.dimensions();
        if w == 0 || h == 0 || w > MAX_DIM || h > MAX_DIM || (w as u64) * (h as u64) > MAX_PIXELS {
            return Err(format!("image dimensions rejected: {w}x{h}"));
        }
        let rgb = img.to_rgb8();
        let short = w.min(h).max(1) as f32;
        let scale = CLIP_SIDE as f32 / short;
        let nw = ((w as f32 * scale).ceil() as u32).max(CLIP_SIDE);
        let nh = ((h as f32 * scale).ceil() as u32).max(CLIP_SIDE);
        let resized = image::imageops::resize(&rgb, nw, nh, FilterType::CatmullRom);
        let x0 = (nw - CLIP_SIDE) / 2;
        let y0 = (nh - CLIP_SIDE) / 2;
        let crop = image::imageops::crop_imm(&resized, x0, y0, CLIP_SIDE, CLIP_SIDE).to_image();
        let side = CLIP_SIDE as usize;
        let mut data = vec![0f32; 3 * side * side];
        for (x, y, px) in crop.enumerate_pixels() {
            for c in 0..3usize {
                let v = px.0[c] as f32 / 255.0;
                data[c * side * side + (y as usize) * side + (x as usize)] = (v - CLIP_MEAN[c]) / CLIP_STD[c];
            }
        }
        Array4::from_shape_vec((1, 3, side, side), data).map_err(|e| e.to_string())
    }

    fn embed_image(&mut self, img: &DynamicImage) -> Result<Vec<f32>, String> {
        let pixel_values = Mm::preprocess(img)?;
        let out = self
            .vision
            .run(ort::inputs![
                "pixel_values" => Tensor::from_array(pixel_values).map_err(|e| e.to_string())?,
            ])
            .map_err(|e| e.to_string())?;
        l2_normalize(extract_512(&out)?)
    }

    fn embed_bytes(&mut self, bytes: &[u8]) -> Result<Vec<f32>, String> {
        let img = image::load_from_memory(bytes).map_err(|e| format!("decode: {e}"))?;
        self.embed_image(&img)
    }

    fn embed_text(&mut self, text: &str) -> Result<Vec<f32>, String> {
        let enc = self.tok.encode(text, true).map_err(|e| e.to_string())?; // BOS + EOS post-processor
        let mut ids: Vec<u32> = enc.get_ids().iter().copied().collect();
        if ids.is_empty() {
            return Err("empty tokenization".into());
        }
        if ids.len() > MM_SEQ {
            // official CLIP crop: keep room for the trailing EOS
            ids.truncate(MM_SEQ - 1);
            ids.push(CLIP_EOS);
        }
        ids.resize(MM_SEQ, CLIP_PAD); // mask = (ids != pad) is derived inside the graph
        let mut id_arr = Array2::<i64>::zeros((1, MM_SEQ));
        for (i, &id) in ids.iter().enumerate() {
            id_arr[[0, i]] = id as i64;
        }
        let out = self
            .text
            .run(ort::inputs![
                "input_ids" => Tensor::from_array(id_arr).map_err(|e| e.to_string())?,
            ])
            .map_err(|e| e.to_string())?;
        l2_normalize(extract_512(&out)?)
    }
}

fn cosine(a: &[f32], b: &[f32]) -> f32 {
    a.iter().zip(b).map(|(x, y)| x * y).sum()
}

fn hex_sha256(bytes: &[u8]) -> String {
    let mut hasher = Sha256::new();
    hasher.update(bytes);
    format!("{:x}", hasher.finalize())
}

// Plan image paths are vault-relative (`raw/…`); never let a crafted request
// make the host reader escape the vault root.
fn read_vault_image(vault_dir: &str, rel: &str) -> Result<Vec<u8>, String> {
    if !rel.starts_with("raw/") || rel.contains("..") || rel.contains('\\') {
        return Err(format!("image path rejected: {rel}"));
    }
    let full = Path::new(vault_dir).join(rel);
    std::fs::read(&full).map_err(|e| format!("read {}: {e}", full.display()))
}

fn selftest_bge(env: &ort::environment::Environment) {
    let mut bge = match Bge::open(env) {
        Ok(b) => b,
        Err(e) => { eprintln!("{e}"); std::process::exit(2); }
    };
    // Deterministic sanity: two related Chinese sentences should be much
    // closer than a celadon sentence vs an unrelated one. Guards the
    // [CLS]/[SEP] + pooling + normalize recipe end to end.
    let a = bge.embed("龙泉窑青瓷以粉青与梅子青著称").unwrap();
    let b = bge.embed("梅子青是龙泉窑的代表釉色").unwrap();
    let c = bge.embed("如何把 JSON 对象序列化成字符串").unwrap();
    println!("{}", json!({"dim": a.len(), "cos_related": cosine(&a, &b), "cos_unrelated": cosine(&a, &c)}));
}

fn solid(w: u32, h: u32, rgb: [u8; 3]) -> DynamicImage {
    DynamicImage::ImageRgb8(RgbImage::from_pixel(w, h, Rgb(rgb)))
}

fn selftest_mm(env: &ort::environment::Environment) {
    let mut mm = match Mm::open(env) {
        Ok(m) => m,
        Err(e) => { eprintln!("{e}"); std::process::exit(2); }
    };
    // Recipe guards. Flat synthetic images legitimately cluster in CLIP's
    // appearance space (pure red vs pure blue cosine ~0.93), so the checks pin
    // ORDERING, not a fixed margin: same-colour pair closer than cross-colour
    // pair; a matching caption beats the mismatched one; byte-decode path
    // round-trips. Non-square sizes exercise the short-side resize + center
    // crop path.
    let red = mm.embed_image(&solid(224, 224, [230, 40, 40])).unwrap();
    let dark_red = mm.embed_image(&solid(300, 160, [215, 35, 45])).unwrap();
    let blue = mm.embed_image(&solid(160, 300, [30, 60, 230])).unwrap();
    let t_red = mm.embed_text("a solid bright red picture").unwrap();
    let t_blue = mm.embed_text("a solid bright blue picture").unwrap();
    // byte round-trip: PNG in memory -> embed_bytes must match embed_image
    let mut png_bytes = std::io::Cursor::new(Vec::new());
    image::DynamicImage::ImageRgb8(RgbImage::from_pixel(32, 32, Rgb([230, 40, 40])))
        .write_to(&mut png_bytes, image::ImageFormat::Png)
        .unwrap();
    let red_via_bytes = mm.embed_bytes(png_bytes.get_ref()).unwrap();
    let report = json!({
        "vision_dim": red.len(),
        "text_dim": t_red.len(),
        "cos_red_images": cosine(&red, &dark_red),
        "cos_red_blue_images": cosine(&red, &blue),
        "cos_red_match": cosine(&red, &t_red),
        "cos_red_mismatch": cosine(&red, &t_blue),
        "cos_byte_roundtrip": cosine(&red, &red_via_bytes),
    });
    println!("{report}");
    let checks = [
        ("vision 512", red.len() == DIM),
        ("text 512", t_red.len() == DIM),
        ("byte round-trip stable", cosine(&red, &red_via_bytes) > 0.999),
        ("same-color beats cross-color", cosine(&red, &dark_red) > cosine(&red, &blue) + 0.03),
        ("caption matches own color", cosine(&red, &t_red) > cosine(&red, &t_blue) + 0.05),
    ];
    for (name, ok) in checks {
        if !ok {
            eprintln!("multimodal selftest failed: {name}");
            std::process::exit(1);
        }
    }
}

fn main() {
    let args: Vec<String> = std::env::args().collect();
    let selftest = args.iter().any(|a| a == "--selftest");
    let mm_check = args.iter().any(|a| a == "--selftest-mm");
    let mm_query = args.iter().any(|a| a == "--mm-query");
    let env = match ort_environment() {
        Ok(e) => e,
        Err(e) => {
            eprintln!("{e}");
            std::process::exit(2);
        }
    };

    if selftest {
        selftest_bge(&env);
        return;
    }
    if mm_check {
        selftest_mm(&env);
        return;
    }

    let mut buf = String::new();
    std::io::stdin().read_to_string(&mut buf).unwrap();

    if mm_query {
        // Cross-modal query vector: CLIP text tower -> mm-space embedding.
        let mut mm = match Mm::open(&env) {
            Ok(m) => m,
            Err(e) => { eprintln!("{e}"); std::process::exit(2); }
        };
        let text = buf.trim_end_matches(['\n', '\r']);
        let values = match mm.embed_text(text) {
            Ok(v) => v,
            Err(e) => { eprintln!("mm query embed failed: {e}"); std::process::exit(1); }
        };
        println!("{}", serde_json::to_string(&values).unwrap());
        return;
    }

    let items: Vec<Value> = serde_json::from_str(&buf).map_err(|e| e.to_string()).unwrap();
    let any_image = items.iter().any(|i| i.get("modality").and_then(|v| v.as_str()) == Some("image"));
    let any_text = items.iter().any(|i| i.get("modality").and_then(|v| v.as_str()) != Some("image"));
    let mut bge = if any_text {
        match Bge::open(&env) {
            Ok(b) => Some(b),
            Err(e) => { eprintln!("{e}"); std::process::exit(2); }
        }
    } else { None };
    let mut mm = if any_image {
        match Mm::open(&env) {
            Ok(m) => Some(m),
            Err(e) => { eprintln!("{e}"); std::process::exit(2); }
        }
    } else { None };
    let vault_dir = std::env::var("EMBED_VAULT_DIR").unwrap_or_default();

    let mut out: Vec<Value> = Vec::new();
    for item in items {
        let page = item.get("page").and_then(|v| v.as_str()).unwrap_or("?").to_string();
        let vec = if item.get("modality").and_then(|v| v.as_str()) == Some("image") {
            let mm = match mm.as_mut() {
                Some(m) => m,
                None => { eprintln!("image item without multimodal face"); std::process::exit(2); }
            };
            let rel = item.get("image").and_then(|v| v.as_str()).unwrap_or("");
            let bytes = match read_vault_image(&vault_dir, rel) {
                Ok(b) => b,
                Err(e) => { eprintln!("embed failed for {page}: {e}"); std::process::exit(1); }
            };
            if let Some(expected) = item.get("image_sha256").and_then(|v| v.as_str()) {
                let got = hex_sha256(&bytes);
                if got != expected {
                    eprintln!("embed failed for {page}: image bytes drifted ({got} != {expected})");
                    std::process::exit(1);
                }
            }
            match mm.embed_bytes(&bytes) {
                Ok(v) => v,
                Err(e) => { eprintln!("embed failed for {page}: {e}"); std::process::exit(1); }
            }
        } else {
            let bge = match bge.as_mut() {
                Some(b) => b,
                None => { eprintln!("text item without bge face"); std::process::exit(2); }
            };
            let text = item.get("text").and_then(|v| v.as_str()).unwrap_or("");
            match bge.embed(text) {
                Ok(v) => v,
                Err(e) => { eprintln!("embed failed for {page}: {e}"); std::process::exit(1); }
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
