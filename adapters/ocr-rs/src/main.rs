// Native host OCR / PDF text adapter for the MemoryCorridor extraction
// sidecar channel. One static binary (ONNX Runtime linked in, PP-OCRv4 mobile
// models and the 6623-char dictionary embedded), no Python runtime.
//
// Pipeline mirrors RapidOCR/PaddleOCR:
//   det: resize (min side >= 736, rounded to x32), ImageNet normalize on BGR,
//        DB prob map, threshold 0.3, 8-connected components, mean-prob box
//        filter 0.5, rectangular unclip, reading-order sort.
//   rec: crop box, resize h=48 keeping aspect, (v/255-0.5)/0.5 BGR,
//        CTC greedy over [blank, dict(6623), space].
//   pdf: embedded text layer first (exact, no model); a PDF with no text
//        layer is refused here -- page rasterization stays host-pluggable.
//
// CLI matches the reference Python adapter:
//   ocr-adapter <file>            -> plain text
//   ocr-adapter <file> --json     -> {sha256, kind, source, confidence, text}

use image::imageops::FilterType;

// Apple's clang availability helper: the prebuilt ONNX Runtime (built against
// a newer SDK) references it from its CoreML version probe, but the host SDK's
// stubs may not export it. The running OS is always newer than any check the
// probe makes, so answering "yes" is correct for this binary.
#[cfg(target_os = "macos")]
#[unsafe(no_mangle)]
pub extern "C" fn __isPlatformVersionAtLeast(_p: u32, _major: u32, _minor: u32, _patch: u32) -> i32 {
    1
}
use image::{GenericImageView, ImageReader};
use ort::session::Session;
use std::process::exit;

const DET_MODEL: &[u8] = include_bytes!("../models/ch_PP-OCRv4_det_infer.onnx");
const REC_MODEL: &[u8] = include_bytes!("../models/ch_PP-OCRv4_rec_infer.onnx");
const DICT: &str = include_str!("../models/ppocr_keys_v1.txt");

const DET_MEAN: [f32; 3] = [0.5, 0.5, 0.5]; // PP-OCRv4 uses symmetric norm on BGR
const DET_STD: [f32; 3] = [0.5, 0.5, 0.5];
const DET_LIMIT_MIN: f32 = 736.0;
const DET_THRESH: f32 = 0.3;
const DET_BOX_THRESH: f32 = 0.5;
const DET_UNCLIP: f32 = 1.6;
const REC_H: usize = 48;
const REC_MAX_W: usize = 1280;

#[derive(Clone, Copy)]
struct Box2 {
    x0: u32,
    y0: u32,
    x1: u32,
    y1: u32,
}

// ---------------- ORT runtime (load-dynamic) -----------------------------

// The ONNX Runtime is a plain C dylib loaded at start. Resolution order:
// $ORT_DYLIB_PATH, then libonnxruntime.dylib next to this executable. This
// deliberately avoids ort-sys' static "download-binaries" build, which
// mis-executes the PP-OCRv4 recognition graph on macOS/arm64 (det fine, rec
// collapses to one token) while the official dylib is correct.
fn ort_environment() -> Result<ort::environment::Environment, String> {
    if let Ok(p) = std::env::var("ORT_DYLIB_PATH") {
        if !p.is_empty() {
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
    Err("ONNX Runtime dylib not found: set ORT_DYLIB_PATH or place libonnxruntime.dylib next to ocr-adapter".to_string())
}

fn main() {
    let args: Vec<String> = std::env::args().collect();
    let json = args.iter().any(|a| a == "--json");
    let Some(path) = args.iter().skip(1).find(|a| !a.starts_with("--")).cloned() else {
        eprintln!("usage: ocr-adapter <file> [--json]");
        exit(2);
    };
    let env = match ort_environment() {
        Ok(e) => e,
        Err(e) => {
            eprintln!("{e}");
            exit(2);
        }
    };
    let raw = match std::fs::read(&path) {
        Ok(r) => r,
        Err(e) => {
            eprintln!("cannot read {path}: {e}");
            exit(2);
        }
    };
    let sha = sha256_hex(&raw);
    let is_pdf = path.to_lowercase().ends_with(".pdf") || raw.starts_with(b"%PDF");
    let result: Result<(String, serde_json::Value), String> = if is_pdf {
        match extract_pdf(&env, &raw) {
            Ok((text, mut meta)) => {
                meta["sha256"] = sha.clone().into();
                Ok((text, meta))
            }
            Err(e) => Err(e),
        }
    } else {
        let decoded = ImageReader::open(&path)
            .map_err(|e| format!("cannot open image: {e}"))
            .and_then(|r| r.decode().map_err(|e| format!("cannot decode image: {e}")));
        match decoded.and_then(|img| ocr_image(&env, &img)) {
            Ok((text, conf)) => {
                let meta = serde_json::json!({"sha256": sha, "kind": "image",
                    "source": "ocr", "confidence": conf});
                Ok((text, meta))
            }
            Err(e) => Err(e),
        }
    };
    match result {
        Ok((text, meta)) => {
            if json {
                let mut out = meta;
                out["text"] = text.into();
                println!("{out}");
            } else {
                println!("{text}");
            }
        }
        Err(e) => {
            eprintln!("{e}");
            exit(1);
        }
    }
}

// ---------------- SHA-256 (FIPS 180-4, minimal) -------------------------

fn sha256_hex(data: &[u8]) -> String {
    const K: [u32; 64] = [
        0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4,
        0xab1c5ed5, 0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe,
        0x9bdc06a7, 0xc19bf174, 0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f,
        0x4a7484aa, 0x5cb0a9dc, 0x76f988da, 0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7,
        0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967, 0x27b70a85, 0x2e1b2138, 0x4d2c6dfc,
        0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85, 0xa2bfe8a1, 0xa81a664b,
        0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070, 0x19a4c116,
        0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
        0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7,
        0xc67178f2,
    ];
    let mut h: [u32; 8] = [
        0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a, 0x510e527f, 0x9b05688c, 0x1f83d9ab,
        0x5be0cd19,
    ];
    let mut msg = data.to_vec();
    let bits = (data.len() as u64) * 8;
    msg.push(0x80);
    while msg.len() % 64 != 56 {
        msg.push(0);
    }
    msg.extend_from_slice(&bits.to_be_bytes());
    for chunk in msg.chunks(64) {
        let mut w = [0u32; 64];
        for i in 0..16 {
            w[i] = u32::from_be_bytes(chunk[i * 4..i * 4 + 4].try_into().unwrap());
        }
        for i in 16..64 {
            let s0 = w[i - 15].rotate_right(7) ^ w[i - 15].rotate_right(18) ^ (w[i - 15] >> 3);
            let s1 = w[i - 2].rotate_right(17) ^ w[i - 2].rotate_right(19) ^ (w[i - 2] >> 10);
            w[i] = w[i - 16]
                .wrapping_add(s0)
                .wrapping_add(w[i - 7])
                .wrapping_add(s1);
        }
        let mut v = h;
        for i in 0..64 {
            let s1 = v[4].rotate_right(6) ^ v[4].rotate_right(11) ^ v[4].rotate_right(25);
            let ch = (v[4] & v[5]) ^ (!v[4] & v[6]);
            let t1 = v[7]
                .wrapping_add(s1)
                .wrapping_add(ch)
                .wrapping_add(K[i])
                .wrapping_add(w[i]);
            let s0 = v[0].rotate_right(2) ^ v[0].rotate_right(13) ^ v[0].rotate_right(22);
            let mj = (v[0] & v[1]) ^ (v[0] & v[2]) ^ (v[1] & v[2]);
            let t2 = s0.wrapping_add(mj);
            v.copy_within(0..7, 1);
            v[0] = t1.wrapping_add(t2);
            v[4] = v[4].wrapping_add(t1);
        }
        for i in 0..8 {
            h[i] = h[i].wrapping_add(v[i]);
        }
    }
    h.iter().map(|x| format!("{x:08x}")).collect()
}

// ---------------- image helpers ------------------------------------------

fn bgr_planar(img: &image::DynamicImage, mean: [f32; 3], std: [f32; 3], scale: f32) -> (usize, usize, Vec<f32>) {
    let rgb = img.to_rgb8();
    let (w, h) = rgb.dimensions();
    let mut data = vec![0f32; (w * h * 3) as usize];
    for y in 0..h as usize {
        for x in 0..w as usize {
            let p = rgb.get_pixel(x as u32, y as u32);
            let px = [p[2] as f32, p[1] as f32, p[0] as f32]; // B, G, R
            for c in 0..3 {
                data[(c * h as usize + y) * w as usize + x] = (px[c] * scale / 255.0 - mean[c]) / std[c];
            }
        }
    }
    (w as usize, h as usize, data)
}

fn resize_to(img: &image::DynamicImage, nw: u32, nh: u32) -> image::DynamicImage {
    img.resize_exact(nw, nh, FilterType::Triangle)
}

// ---------------- detection + recognition --------------------------------

fn ocr_image(env: &ort::environment::Environment, img: &image::DynamicImage) -> Result<(String, f64), String> {
    let (w0, h0) = img.dimensions();
    let scale = (DET_LIMIT_MIN / (w0.min(h0) as f32)).max(1.0);
    let dw = (((w0 as f32 * scale) / 32.0).round() as u32 * 32).max(32);
    let dh = (((h0 as f32 * scale) / 32.0).round() as u32 * 32).max(32);
    let det_img = resize_to(img, dw, dh);
    let (_, _, input) = bgr_planar(&det_img, DET_MEAN, DET_STD, 1.0);

    let mut det = Session::builder(env)
        .map_err(|e| e.to_string())?
        .with_intra_threads(2)
        .map_err(|e| e.to_string())?
        .commit_from_memory(DET_MODEL)
        .map_err(|e| e.to_string())?;
    let shape = [1usize, 3, dh as usize, dw as usize];
    let tensor = ort::value::Tensor::from_array(
        ndarray::Array4::from_shape_vec(shape, input).map_err(|e| e.to_string())?,
    )
    .map_err(|e| e.to_string())?;
    let out = det.run(ort::inputs![tensor]).map_err(|e| e.to_string())?;
    let (_shape, prob) = out[0].try_extract_tensor::<f32>().map_err(|e| e.to_string())?;
    let prob = prob.to_vec();

    // binary map, dilated once with a 3x3 kernel (matches RapidOCR's
    // use_dilation: connects neighbouring strokes into whole lines before
    // connected-component grouping)
    let npix = (dw * dh) as usize;
    let hard: Vec<bool> = prob.iter().map(|p| *p > DET_THRESH).collect();
    let mut mask = hard.clone();
    for y in 0..dh as usize {
        for x in 0..dw as usize {
            let i = y * dw as usize + x;
            if !hard[i] {
                continue;
            }
            for dy in 0i64..=1 {
                for dx in 0i64..=1 {
                    let (ny, nx) = (y as i64 + dy - 1, x as i64 + dx - 1);
                    if ny < 0 || nx < 0 || ny >= dh as i64 || nx >= dw as i64 {
                        continue;
                    }
                    mask[(ny * dw as i64 + nx) as usize] = true;
                }
            }
        }
    }
    let mut label = vec![0i32; npix];
    let mut boxes: Vec<Box2> = Vec::new();
    let mut current = 0i32;
    let mut stack: Vec<u32> = Vec::new();
    const DIRS: [(i64, i64); 8] =
        [(1, 0), (-1, 0), (0, 1), (0, -1), (1, 1), (1, -1), (-1, 1), (-1, -1)];
    for start in 0..npix as u32 {
        if !mask[start as usize] || label[start as usize] != 0 {
            continue;
        }
        current += 1;
        stack.push(start);
        label[start as usize] = current;
        let (mut x0, mut y0, mut x1, mut y1) = (u32::MAX, u32::MAX, 0u32, 0u32);
        let (mut sum, mut count) = (0f32, 0u32);
        while let Some(p) = stack.pop() {
            let x = (p % dw) as i64;
            let y = (p / dw) as i64;
            sum += prob[p as usize];
            count += 1;
            x0 = x0.min(x as u32);
            y0 = y0.min(y as u32);
            x1 = x1.max(x as u32);
            y1 = y1.max(y as u32);
            for (dx, dy) in DIRS {
                let (nx, ny) = (x + dx, y + dy);
                if nx < 0 || ny < 0 || nx >= dw as i64 || ny >= dh as i64 {
                    continue;
                }
                let q = (ny * dw as i64 + nx) as u32;
                if mask[q as usize] && label[q as usize] == 0 {
                    label[q as usize] = current;
                    stack.push(q);
                }
            }
        }
        let bw = x1 - x0 + 1;
        let bh = y1 - y0 + 1;
        if bw < 3 || bh < 3 {
            continue;
        }
        if (sum / count as f32) < DET_BOX_THRESH {
            continue;
        }
        // Rectangular unclip. PaddleOCR computes distance = area*ratio/perim
        // on the source-image polygon and expands each edge by that distance
        // with NO clamp; mirror that exactly (mapping to src coords first).
        let sx = w0 as f32 / dw as f32;
        let sy = h0 as f32 / dh as f32;
        let fx0 = x0 as f32 * sx;
        let fy0 = y0 as f32 * sy;
        let fx1 = (x1 + 1) as f32 * sx;
        let fy1 = (y1 + 1) as f32 * sy;
        let (bw_s, bh_s) = (fx1 - fx0, fy1 - fy0);
        let dist = (bw_s * bh_s * DET_UNCLIP / (2.0 * (bw_s + bh_s))).max(0.0);
        boxes.push(Box2 {
            x0: (fx0 - dist).max(0.0) as u32,
            y0: (fy0 - dist).max(0.0) as u32,
            x1: ((fx1 + dist).min(w0 as f32) - 1.0).max(0.0) as u32,
            y1: ((fy1 + dist).min(h0 as f32) - 1.0).max(0.0) as u32,
        });
    }
    // reading order: lines by vertical overlap, left to right inside a line
    boxes.sort_by_key(|b| (b.y0, b.x0));
    let mut lines: Vec<Vec<Box2>> = Vec::new();
    for b in boxes {
        match lines.last_mut() {
            Some(line) => {
                let prev = line.last().unwrap();
                let overlap = (prev.y1.min(b.y1) as i64 - prev.y0.max(b.y0) as i64).max(0);
                let band = (prev.y1 - prev.y0).min(b.y1 - b.y0) as i64 / 2;
                if overlap >= band {
                    line.push(b);
                    continue;
                }
            }
            None => {}
        }
        lines.push(vec![b]);
    }
    let ordered: Vec<Box2> = lines
        .into_iter()
        .map(|mut line| {
            line.sort_by_key(|b| b.x0);
            line
        })
        .flatten()
        .collect();

    if std::env::var("OCR_DEBUG_BOXES").is_ok() {
        eprintln!("boxes={} img {}x{}", ordered.len(), w0, h0);
        for b in &ordered {
            eprintln!("box {} {} {} {}", b.x0, b.y0, b.x1, b.y1);
        }
    }
    let mut rec = Session::builder(env)
        .map_err(|e| e.to_string())?
        .with_intra_threads(2)
        .map_err(|e| e.to_string())?
        .commit_from_memory(REC_MODEL)
        .map_err(|e| e.to_string())?;
    let chars: Vec<&str> = DICT.lines().collect();
    // debug: replay a known-good input tensor from disk through the same session
    if std::env::var("OCR_REPLAY_IN").is_ok() {
        let dims: Vec<usize> = std::fs::read_to_string("/tmp/rust_rec_in.shape").unwrap()
            .split_whitespace().map(|x| x.parse().unwrap()).collect();
        let raw = std::fs::read("/tmp/rust_rec_in.raw").unwrap();
        let mut data = Vec::with_capacity(raw.len() / 4);
        for chunk in raw.chunks(4) { data.push(f32::from_le_bytes(chunk.try_into().unwrap())); }
        let t = ort::value::Tensor::from_array(
            ndarray::Array4::from_shape_vec((dims[0], dims[1], dims[2], dims[3]), data)
                .map_err(|e| e.to_string())?,
        )
        .map_err(|e| e.to_string())?;
        let o = rec.run(ort::inputs![t]).map_err(|e| e.to_string())?;
        let (sh, d) = o[0].try_extract_tensor::<f32>().map_err(|e| e.to_string())?;
        eprintln!("replay shape={:?} len={}", sh, d.len());
        let nc = sh[sh.len() - 1] as usize;
        let tt = sh[sh.len() - 2] as usize;
        let chars: Vec<&str> = DICT.lines().collect();
        let (txt, _) = ctc_greedy(&d[..tt * nc], tt, nc, &chars);
        eprintln!("replay text => {txt}");
        return Ok((String::new(), 0.0));
    }
    let rgb_img = img.to_rgb8();
    let mut box_idx = 0usize;
    let mut texts: Vec<String> = Vec::new();
    let mut confs: Vec<f32> = Vec::new();
    for b in ordered {
        if b.x1 <= b.x0 || b.y1 <= b.y0 {
            continue;
        }
        let cw = (b.x1 - b.x0 + 1).max(1);
        let chh = (b.y1 - b.y0 + 1).max(1);
        let crop = rgb_img.view(b.x0, b.y0, cw, chh).to_image();
        let mut rw = (REC_H as f32 * cw as f32 / chh as f32).ceil() as usize;
        rw = rw.clamp(16, REC_MAX_W);
        let resized = image::DynamicImage::ImageRgb8(crop)
            .resize_exact(rw as u32, REC_H as u32, FilterType::Triangle)
            .to_rgb8();
        let mut buf = vec![0f32; 3 * REC_H * rw];
        for y in 0..REC_H {
            for x in 0..rw {
                let p = resized.get_pixel(x as u32, y as u32);
                let i = y * rw + x;
                buf[i] = (p[2] as f32 / 255.0 - 0.5) / 0.5; // B plane
                buf[REC_H * rw + i] = (p[1] as f32 / 255.0 - 0.5) / 0.5; // G plane
                buf[2 * REC_H * rw + i] = (p[0] as f32 / 255.0 - 0.5) / 0.5; // R plane
            }
        }
        if std::env::var("OCR_DEBUG_CROP").is_ok() {
            let _ = image::DynamicImage::ImageRgb8(resized.clone())
                .save(format!("/tmp/rust_crop_{box_idx}.png"));
        }
        if std::env::var("OCR_DUMP_IN").is_ok() && box_idx == 0 {
            std::fs::write("/tmp/rust_rec_in.raw", bytemuck_bytes(&buf)).ok();
            std::fs::write("/tmp/rust_rec_in.shape", format!("1 3 {} {}", REC_H, rw)).ok();
        }
        if std::env::var("OCR_DEBUG_CTC").is_ok() && box_idx == 0 {
            let smin = buf.iter().fold(f32::INFINITY, |a, &b| a.min(b));
            let smax = buf.iter().fold(f32::NEG_INFINITY, |a, &b| a.max(b));
            let smean = buf.iter().sum::<f32>() as f64 / buf.len() as f64;
            eprintln!("input min/max/mean = {}/{}/{} len={} rw={}", smin, smax, smean, buf.len(), rw);
        }
        let shape = [1usize, 3, REC_H, rw];
        let rtensor = ort::value::Tensor::from_array(
            ndarray::Array4::from_shape_vec((shape[0], shape[1], shape[2], shape[3]), buf)
                .map_err(|e| e.to_string())?,
        )
        .map_err(|e| e.to_string())?;
        let out = rec.run(ort::inputs![rtensor]).map_err(|e| e.to_string())?;
        let (tshape, tdata) = out[0].try_extract_tensor::<f32>().map_err(|e| e.to_string())?;
        let dims: Vec<usize> = tshape.iter().map(|d| *d as usize).collect();
        let (tt, nc) = (dims[dims.len() - 2], dims[dims.len() - 1]);
        box_idx += 1;
        if std::env::var("OCR_DEBUG_CTC").is_ok() && box_idx == 1 {
            let bmin = tdata.iter().fold(f32::INFINITY, |a, &b| a.min(b));
            let bmax = tdata.iter().fold(f32::NEG_INFINITY, |a, &b| a.max(b));
            let bmean = tdata.iter().sum::<f32>() as f64 / tdata.len() as f64;
            eprintln!("out min/max/mean = {}/{}/{}", bmin, bmax, bmean);
            eprintln!("ctc shape={:?} t={} nc={}", tshape, tt, nc);
            let mut prev = usize::MAX;
            let mut seq: Vec<usize> = Vec::new();
            for ti2 in 0..tt.min(60) {
                let row = &tdata[ti2 * nc..(ti2 + 1) * nc];
                let bi = row.iter().enumerate().max_by(|a, b| a.1.partial_cmp(b.1).unwrap()).map(|(i, _)| i).unwrap_or(0);
                if bi != prev { seq.push(bi); }
                prev = bi;
            }
            eprintln!("ctc first path: {:?}", seq);
            if std::env::var("OCR_DUMP_OUT").is_ok() {
                std::fs::write("/tmp/rust_out.raw", bytemuck_bytes(tdata)).ok();
                std::fs::write("/tmp/rust_out.shape", format!("{:?}", tshape)).ok();
            }
        }
        let (text, conf) = ctc_greedy(tdata, tt, nc, &chars);
        if !text.is_empty() {
            texts.push(text);
            confs.push(conf);
        }
    }
    let mean = if confs.is_empty() {
        0.0
    } else {
        confs.iter().sum::<f32>() as f64 / confs.len() as f64
    };
    Ok((texts.join("\n"), (mean * 1e4).round() / 1e4))
}

fn bytemuck_bytes(data: &[f32]) -> Vec<u8> {
    let mut v = Vec::with_capacity(data.len() * 4);
    for f in data {
        v.extend_from_slice(&f.to_le_bytes());
    }
    v
}

fn ctc_greedy(data: &[f32], t: usize, classes: usize, chars: &[&str]) -> (String, f32) {
    let mut out = String::new();
    let mut prev = usize::MAX;
    let mut conf = 0f32;
    let mut n = 0usize;
    for ti in 0..t {
        let row = &data[ti * classes..(ti + 1) * classes];
        let (mut bi, mut bv) = (0usize, f32::MIN);
        for (i, v) in row.iter().enumerate() {
            if *v > bv {
                bv = *v;
                bi = i;
            }
        }
        if bi != 0 && bi != prev {
            if bi - 1 < chars.len() {
                out.push_str(chars[bi - 1]);
            } else if bi >= chars.len() + 1 {
                out.push(' ');
            }
            conf += bv;
            n += 1;
        }
        prev = bi;
    }
    (out, if n == 0 { 0.0 } else { conf / n as f32 })
}

// ---------------- pdf text layer / scanned pages --------------------------

fn deref_object<'d>(doc: &'d lopdf::Document, obj: &'d lopdf::Object) -> Option<&'d lopdf::Object> {
    let mut cur = obj;
    for _ in 0..8 {
        match cur {
            lopdf::Object::Reference(id) => cur = doc.get_object(*id).ok()?,
            other => return Some(other),
        }
    }
    None
}

fn stream_dict<'d>(doc: &'d lopdf::Document, obj: &'d lopdf::Object) -> Option<&'d lopdf::Dictionary> {
    let mut cur = obj;
    for _ in 0..8 {
        match cur {
            lopdf::Object::Reference(id) => cur = doc.get_object(*id).ok()?,
            lopdf::Object::Stream(s) => return Some(&s.dict),
            _ => return None,
        }
    }
    None
}

fn get_int(d: &lopdf::Dictionary, key: &[u8]) -> Option<i64> {
    d.get(key).ok().and_then(|o| o.as_i64().ok())
}

/// True stream bytes + dict: walk references, return the Stream object.
fn page_stream<'d>(doc: &'d lopdf::Document, obj: &'d lopdf::Object) -> Option<&'d lopdf::Stream> {
    let mut cur = obj;
    for _ in 0..8 {
        match cur {
            lopdf::Object::Reference(id) => cur = doc.get_object(*id).ok()?,
            lopdf::Object::Stream(s) => return Some(s),
            _ => return None,
        }
    }
    None
}

fn name_of(o: &lopdf::Object) -> Vec<u8> {
    o.as_name().map(|n| n.to_vec()).unwrap_or_default()
}

fn color_count(d: &lopdf::Dictionary) -> usize {
    match d.get(b"ColorSpace").ok().and_then(|o| deref_object_direct(o)) {
        Some(obj) => match obj {
            lopdf::Object::Name(n) => match n.as_slice() {
                b"DeviceRGB" | b"CalRGB" => 3,
                b"DeviceGray" | b"CalGray" => 1,
                b"DeviceCMYK" => 4,
                _ => 3,
            },
            lopdf::Object::Array(arr) => {
                if let Some(first) = arr.first() {
                    let n = name_of(first);
                    if n == b"ICCBased" || n == b"CalRGB" {
                                if let Some(spec) = arr.get(1).and_then(|o| deref_object_direct(o)) {
                            let comps = spec.as_array().ok().and_then(|a| {
                                a.iter().find(|o| name_of(o) == b"N")
                                    .and_then(|pair| pair.as_array().ok())
                                    .and_then(|p| p.get(1))
                                    .and_then(|v| v.as_i64().ok())
                            });
                            if let Some(c) = comps {
                                return c as usize;
                            }
                        }
                        3
                    } else if n == b"CalGray" {
                        1
                    } else if n == b"Separation" || n == b"DeviceN" {
                        1
                    } else {
                        3
                    }
                } else {
                    3
                }
            }
            _ => 3,
        },
        None => 3,
    }
}

fn deref_object_direct(o: &lopdf::Object) -> Option<&lopdf::Object> {
    // inline values in a dict are rarely references in real files; keep simple
    Some(o)
}

/// Reconstruct raw samples into an RGB8 image, honouring Predictor (PNG-style
/// 10..15 and TIFF-style 2) for FlateDecode images.
fn samples_to_rgb(samples: &[u8], w: usize, h: usize, comp: usize, predictor: i64) -> Option<image::RgbImage> {
    let stride = w * comp;
    let mut rows: Vec<u8> = Vec::new();
    if predictor >= 10 {
        // PNG predictors: one filter-type byte per row
        let need = h * (stride + 1);
        if samples.len() < need {
            return None;
        }
        let mut prev = vec![0u8; stride];
        for y in 0..h {
            let ft = samples[y * (stride + 1)];
            let row: Vec<u8> = samples[y * (stride + 1) + 1..(y + 1) * (stride + 1)].to_vec();
            let mut out = vec![0u8; stride];
            for x in 0..stride {
                let a = if x >= comp { out[x - comp] } else { 0 };
                let b = prev[x];
                let c = if x >= comp { prev[x - comp] } else { 0 };
                let v: i32 = match ft {
                    0 => row[x] as i32,
                    1 => (row[x] as i32 + a as i32) & 0xff,
                    2 => (row[x] as i32 + b as i32) & 0xff,
                    3 => (row[x] as i32 + ((a as i32 + b as i32) / 2)) & 0xff,
                    4 => {
                        let p = a as i32 + b as i32 - c as i32;
                        let (pa, pb, pc) = ((p - a as i32).abs(), (p - b as i32).abs(), (p - c as i32).abs());
                        let pr = if pa <= pb && pa <= pc { a as i32 } else if pb <= pc { b as i32 } else { c as i32 };
                        (row[x] as i32 + pr) & 0xff
                    }
                    _ => return None,
                };
                out[x] = v as u8;
            }
            rows.extend_from_slice(&out);
            prev = out;
        }
    } else if predictor == 2 {
        // TIFF horizontal differencing per component
        let mut src = samples.to_vec();
        for y in 0..h {
            let base = y * stride;
            if base + stride > src.len() {
                return None;
            }
            for x in comp..stride {
                src[base + x] = src[base + x].wrapping_add(src[base + x - comp]);
            }
        }
        rows = src;
    } else {
        if samples.len() < stride * h {
            return None;
        }
        rows = samples[..stride * h].to_vec();
    }
    let mut img = image::RgbImage::new(w as u32, h as u32);
    for y in 0..h {
        for x in 0..w {
            let i = y * stride + x * comp;
            let px = match comp {
                1 => [rows[i], rows[i], rows[i]],
                3 => [rows[i], rows[i + 1], rows[i + 2]],
                4 => {
                    // CMYK approximation
                    let (c, m, yl, k) = (rows[i] as u16, rows[i + 1] as u16, rows[i + 2] as u16, rows[i + 3] as u16);
                    [
                        (255.0f32.min(255.0 - (c as f32 * (255.0 - k as f32) / 255.0))) as u8,
                        (255.0f32.min(255.0 - (m as f32 * (255.0 - k as f32) / 255.0))) as u8,
                        (255.0f32.min(255.0 - (yl as f32 * (255.0 - k as f32) / 255.0))) as u8,
                    ]
                }
                _ => return None,
            };
            img.put_pixel(x as u32, y as u32, image::Rgb(px));
        }
    }
    Some(img)
}

fn decode_page_image(doc: &lopdf::Document, obj: &lopdf::Object) -> Option<image::RgbImage> {
    let s = page_stream(doc, obj)?;
    let d = &s.dict;
    let w = get_int(d, b"Width")? as usize;
    let h = get_int(d, b"Height")? as usize;
    let bpc = get_int(d, b"BitsPerComponent").unwrap_or(8) as usize;
    if w == 0 || h == 0 || bpc != 8 {
        return None;
    }
    let filters: Vec<Vec<u8>> = match d.get(b"Filter").ok() {
        Some(lopdf::Object::Name(n)) => vec![n.to_vec()],
        Some(lopdf::Object::Array(arr)) => arr.iter().map(name_of).collect(),
        None => vec![],
        _ => return None,
    };
    if filters.as_slice() == [b"DCTDecode".to_vec()] {
        let reader = image::ImageReader::new(std::io::Cursor::new(&s.content))
            .with_guessed_format()
            .ok()?;
        let dynimg = reader.decode().ok()?;
        return Some(dynimg.to_rgb8());
    }
    if filters.as_slice() == [b"FlateDecode".to_vec()] {
        // lopdf already inflated FlateDecode content at load
        let predictor = d
            .get(b"DecodeParms")
            .ok()
            .and_then(|dp| match dp {
                lopdf::Object::Dictionary(dd) => dd.get(b"Predictor").ok().and_then(|p| p.as_i64().ok()),
                _ => None,
            })
            .unwrap_or(1);
        let comp = color_count(d);
        let data = s.get_plain_content().unwrap_or_else(|_| s.content.clone());
        return samples_to_rgb(&data, w, h, comp, predictor);
    }
    None
}

/// Largest embedded page image across pages (scanned pages are one big image).
fn largest_page_image(doc: &lopdf::Document) -> Option<(image::RgbImage, f32)> {
    let mut best: Option<(image::RgbImage, f32)> = None;
    for (_, id) in doc.get_pages() {
        let Ok(page_o) = doc.get_object(id) else { continue };
        let Ok(page) = page_o.as_dict() else { continue };
        let Some(res_o) = page.get(b"Resources").ok().and_then(|o| deref_object(doc, o)) else {
            continue;
        };
        let Ok(res) = res_o.as_dict() else { continue };
        let Some(xo_o) = res.get(b"XObject").ok().and_then(|o| deref_object(doc, o)) else {
            continue;
        };
        let Ok(xo) = xo_o.as_dict() else { continue };
        for (_name, img_obj) in xo.iter() {
            if stream_dict(doc, img_obj).is_none() {
                continue;
            }
            let Some(d) = stream_dict(doc, img_obj) else { continue };
            let st = d.get(b"Subtype").ok().map(name_of).unwrap_or_default();
            if st != b"Image" {
                continue;
            }
            let (Some(w), Some(h)) = (get_int(d, b"Width"), get_int(d, b"Height")) else {
                continue;
            };
            let area = (w * h) as f32;
            if best.as_ref().is_some_and(|b| b.1 >= area) {
                continue;
            }
            if let Some(rgb) = decode_page_image(doc, img_obj) {
                best = Some((rgb, area));
            }
        }
    }
    best
}

fn extract_pdf(
    env: &ort::environment::Environment,
    raw: &[u8],
) -> Result<(String, serde_json::Value), String> {
    let doc = lopdf::Document::load_mem(raw).map_err(|e| format!("pdf parse: {e}"))?;
    let pages = doc.get_pages();
    let npages = pages.len();
    let mut all = Vec::new();
    for (i, _) in pages.iter().enumerate() {
        let text = doc
            .extract_text(&[(i + 1) as u32])
            .map_err(|e| format!("pdf text page {}: {e}", i + 1))?;
        all.push(text);
    }
    let joined = all.join("\n");
    let dense: usize = joined.chars().filter(|c| !c.is_whitespace()).count();
    if dense >= 20 {
        let meta = serde_json::json!({"kind": "pdf", "source": "text-layer", "pages": npages});
        return Ok((joined, meta));
    }
    if let Some((rgb, _)) = largest_page_image(&doc) {
        let dynimg = image::DynamicImage::ImageRgb8(rgb);
        let (text, conf) = ocr_image(env, &dynimg)?;
        let meta = serde_json::json!({"kind": "pdf", "source": "ocr",
            "pages": npages, "confidence": conf});
        return Ok((text, meta));
    }
    Err(
        "pdf has no usable text layer and no decodable page image \
         (vector or exotic-encoded PDF?): rasterize pages host-side, then OCR the images"
            .into(),
    )
}
