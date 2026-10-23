//! Each sample gets a new process: no RaTeX font, glyph, parser, or layout cache is warm.
//! The OS file cache is not flushed. Run only in release mode.

use std::process::Command;
use std::time::Instant;

use ratex_layout::{layout, to_display_list, LayoutOptions};
use ratex_parser::parser::parse;
use ratex_render::{render_to_png, RenderOptions};

const CASES: &[(&str, &str)] = &[
    ("math", r"x^2 + y^2 = z^2"),
    (
        "complex",
        r"\frac{a}{b} + \int_0^\infty e^{-x} dx + \sum_{i=1}^n i \cdot \sqrt{x}",
    ),
    (
        "matrix",
        r"\begin{pmatrix} a & b \\ c & d \end{pmatrix} \cdot \begin{pmatrix} e & f \\ g & h \end{pmatrix}",
    ),
    ("cjk", r"\text{你好世界}\quad x^2 + y^2 = z^2"),
    ("emoji", r"\text{😊}\quad x^2 + y^2 = z^2 \quad \text{✅}"),
    ("chem", r"\ce{2H2 + O2 -> 2H2O}"),
];

// Keep debug test builds valid, but reject executing this opt-in benchmark in debug mode.
#[allow(clippy::assertions_on_constants)]
fn require_release() {
    assert!(!cfg!(debug_assertions), "use --release for timing");
}

#[test]
#[ignore = "run with --release --test cold_start -- --ignored --nocapture"]
fn cold_start() {
    require_release();
    let exe = std::env::current_exe().unwrap();
    let samples: usize = std::env::var("RATEX_COLD_SAMPLES")
        .unwrap_or_else(|_| "9".into())
        .parse()
        .expect("RATEX_COLD_SAMPLES must be a positive integer");
    assert!(samples > 0);
    for &(case, _) in CASES {
        for _ in 0..samples {
            let output = Command::new(&exe)
                .args(["--ignored", "--exact", "cold_start_sample", "--nocapture"])
                .env("RATEX_COLD_CASE", case)
                .output()
                .expect("launch fresh sample process");
            assert!(
                output.status.success(),
                "sample failed: {}\n{}",
                String::from_utf8_lossy(&output.stdout),
                String::from_utf8_lossy(&output.stderr)
            );
            let stdout = String::from_utf8(output.stdout).unwrap();
            println!(
                "{}",
                stdout
                    .lines()
                    .find(|line| line.starts_with("COLD_START "))
                    .unwrap()
            );
        }
    }
}

#[test]
#[ignore = "child entry point; set RATEX_COLD_CASE and use --exact cold_start_sample"]
fn cold_start_sample() {
    // `cargo test -- --ignored` also invokes this entry without the parent's environment.
    let Ok(case) = std::env::var("RATEX_COLD_CASE") else {
        return;
    };
    require_release();
    let (_, expr) = CASES
        .iter()
        .find(|(name, _)| *name == case)
        .expect("known case");
    let opts = RenderOptions {
        font_dir: std::env::var("RATEX_BENCH_FONT_DIR").unwrap_or_else(|_| {
            std::path::Path::new(env!("CARGO_MANIFEST_DIR"))
                .join("../../fonts")
                .to_string_lossy()
                .into_owned()
        }),
        ..RenderOptions::default()
    };
    let start = Instant::now();
    let ast = parse(expr).expect("parse");
    let list = to_display_list(&layout(&ast, &LayoutOptions::default()));
    let parse_layout_us = start.elapsed().as_secs_f64() * 1e6;
    let render_start = Instant::now();
    let cold = render_to_png(&list, &opts).expect("first render");
    let render_us = render_start.elapsed().as_secs_f64() * 1e6;
    let total_us = start.elapsed().as_secs_f64() * 1e6;

    // Optional second render is outside the cold timing. Disable it when measuring
    // process peak RSS so that the peak describes only first use.
    let hot_render_us = if std::env::var_os("RATEX_COLD_ONLY").is_none() {
        let hot_start = Instant::now();
        let hot = render_to_png(&list, &opts).expect("second render");
        let elapsed = hot_start.elapsed().as_secs_f64() * 1e6;
        assert_eq!(cold, hot, "cache reuse changed the PNG");
        Some(elapsed)
    } else {
        None
    };
    println!(
        "COLD_START {}",
        serde_json::json!({
            "case": case,
            "parse_layout_us": parse_layout_us,
            "render_us": render_us,
            "total_us": total_us,
            "hot_render_us": hot_render_us,
            "png_bytes": cold.len(),
        })
    );
}
