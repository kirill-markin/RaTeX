//! Directory-font regressions must run without feature unification enabling embed-fonts.
//! Run explicitly with `cargo test -p ratex-render --test font_parse_errors -- --ignored`.
//! Workspace members can enable ratex-font-loader/embed-fonts without enabling our feature.
#![cfg(not(feature = "embed-fonts"))]

use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU64, Ordering};

use ratex_layout::{layout, to_display_list, LayoutOptions};
use ratex_render::{render_to_png, RenderOptions};

struct FontDir(PathBuf);

impl FontDir {
    fn new(bytes: &[u8]) -> Self {
        static NEXT: AtomicU64 = AtomicU64::new(0);
        let path = std::env::temp_dir().join(format!(
            "ratex-font-parse-{}-{}",
            std::process::id(),
            NEXT.fetch_add(1, Ordering::Relaxed)
        ));
        std::fs::create_dir(&path).expect("create isolated font directory");
        std::fs::write(path.join("KaTeX_Main-Regular.ttf"), bytes).expect("write font");
        Self(path)
    }

    fn render(&self) -> Result<Vec<u8>, String> {
        let ast = ratex_parser::parser::parse(r"\mathrm{x}").unwrap();
        let list = to_display_list(&layout(&ast, &LayoutOptions::default()));
        render_to_png(
            &list,
            &RenderOptions {
                font_dir: self.0.to_string_lossy().into_owned(),
                ..RenderOptions::default()
            },
        )
    }
}

impl Drop for FontDir {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.0);
    }
}

#[test]
#[ignore = "requires an isolated cargo test -p ratex-render invocation without embedded fonts"]
fn malformed_fonts_fail_on_both_sides_of_the_parsed_cache_limit() {
    for size in [1024, 4 * 1024 * 1024, 4 * 1024 * 1024 + 1] {
        let dir = FontDir::new(&vec![0; size]);
        for _ in 0..2 {
            let error = dir
                .render()
                .expect_err("invalid font must not produce a blank PNG");
            assert!(error.contains("Main-Regular"), "{size}: {error}");
            assert!(error.contains("InvalidFont"), "{size}: {error}");
        }
    }
}

#[test]
#[ignore = "requires an isolated cargo test -p ratex-render invocation without embedded fonts"]
fn valid_large_font_matches_small_font_after_a_failed_render() {
    FontDir::new(&vec![0; 4 * 1024 * 1024 + 1])
        .render()
        .expect_err("malformed raw font");
    let mut bytes = std::fs::read(
        Path::new(env!("CARGO_MANIFEST_DIR")).join("../../fonts/KaTeX_Main-Regular.ttf"),
    )
    .unwrap();
    let expected = FontDir::new(&bytes).render().unwrap();
    // SFNT permits trailing bytes: force the same valid face onto the raw-font path.
    bytes.resize(4 * 1024 * 1024 + 1, 0);
    let large = FontDir::new(&bytes);
    for _ in 0..2 {
        assert_eq!(large.render().unwrap(), expected);
    }
}
