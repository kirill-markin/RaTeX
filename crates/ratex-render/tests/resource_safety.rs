use std::alloc::{GlobalAlloc, Layout, System};

// Reject a regressed giant pixel allocation before it reaches the OS. Keep
// failure isolated so an OOM cannot abort the main test runner.
struct GuardedAllocator;
fn check(size: usize) {
    if size > 64 * 1024 * 1024 {
        std::process::exit(77);
    }
}
unsafe impl GlobalAlloc for GuardedAllocator {
    unsafe fn alloc(&self, layout: Layout) -> *mut u8 {
        check(layout.size());
        System.alloc(layout)
    }
    unsafe fn alloc_zeroed(&self, layout: Layout) -> *mut u8 {
        check(layout.size());
        System.alloc_zeroed(layout)
    }
    unsafe fn realloc(&self, ptr: *mut u8, layout: Layout, size: usize) -> *mut u8 {
        check(size);
        System.realloc(ptr, layout, size)
    }
    unsafe fn dealloc(&self, ptr: *mut u8, layout: Layout) {
        System.dealloc(ptr, layout);
    }
}
#[global_allocator]
static ALLOCATOR: GuardedAllocator = GuardedAllocator;

#[test]
fn huge_rule_is_rejected_before_requesting_its_pixel_buffer() {
    const ENV: &str = "RATEX_PIXEL_RESOURCE_CHILD";
    if std::env::var_os(ENV).is_some() {
        let input = r"\rule{1000em}{1000em}";
        assert_eq!(input.len(), 21);
        let ast = ratex_parser::parse(input).unwrap();
        let boxes = ratex_layout::layout(&ast, &ratex_layout::LayoutOptions::default());
        let display = ratex_layout::to_display_list(&boxes);
        let error = ratex_render::render_to_png(&display, &ratex_render::RenderOptions::default())
            .unwrap_err();
        assert!(error.contains("PNG pixel limit exceeded"), "{error}");
        return;
    }
    let status = std::process::Command::new(std::env::current_exe().unwrap())
        .args([
            "--exact",
            "huge_rule_is_rejected_before_requesting_its_pixel_buffer",
            "--nocapture",
        ])
        .env(ENV, "1")
        .status()
        .unwrap();
    assert!(status.success(), "pixel allocation guard failed: {status}");
}

#[test]
fn clipped_horizontal_dashes_finish_in_an_isolated_process() {
    const ENV: &str = "RATEX_DASH_RESOURCE_CHILD";
    if std::env::var_os(ENV).is_some() {
        use ratex_types::{Color, DisplayItem, DisplayList};
        let options = ratex_render::RenderOptions {
            font_size: 1.0,
            padding: 0.0,
            font_dir: format!("{}/../../fonts", env!("CARGO_MANIFEST_DIR")),
            ..Default::default()
        };
        let dashed = |x, width, thickness| DisplayList {
            width: 64.0,
            height: 8.0,
            depth: 0.0,
            items: vec![DisplayItem::Line {
                x,
                y: 4.0,
                width,
                thickness,
                color: Color::BLACK,
                dashed: true,
            }],
        };
        // At the distant origin, f32 addition of the period cannot advance
        // the old loop. Check both a zero phase (8px period) and a nonzero
        // phase (12px period) against the equivalent short line.
        for (thickness, origin) in [(1.0, 0.0), (1.5, -4.0)] {
            let expected =
                ratex_render::render_to_png(&dashed(origin, 64.0 - origin, thickness), &options)
                    .unwrap();
            let actual = ratex_render::render_to_png(
                &dashed(-1_000_000_000.0, 2_000_000_000.0, thickness),
                &options,
            )
            .unwrap();
            assert_eq!(actual, expected);
        }
        for width in ["10", "1000000000"] {
            let input = format!(
                r"x\mathllap{{\begin{{array}}{{c}}\hdashline\rule{{{width}em}}{{1em}}\end{{array}}}}"
            );
            let ast = ratex_parser::parse(&input).unwrap();
            let boxes = ratex_layout::layout(&ast, &ratex_layout::LayoutOptions::default());
            ratex_layout::validate_layout(&boxes).unwrap();
            let display = ratex_layout::to_display_list(&boxes);
            assert_eq!(display.items.len(), 3);
            assert!(display.width < 1.0);
            let options = ratex_render::RenderOptions {
                font_size: 40.0,
                padding: 10.0,
                font_dir: options.font_dir.clone(),
                ..Default::default()
            };
            assert!(!ratex_render::render_to_png(&display, &options)
                .unwrap()
                .is_empty());
        }
        return;
    }
    let mut child = std::process::Command::new(std::env::current_exe().unwrap())
        .args([
            "--exact",
            "clipped_horizontal_dashes_finish_in_an_isolated_process",
            "--nocapture",
        ])
        .env(ENV, "1")
        .spawn()
        .unwrap();
    let deadline = std::time::Instant::now() + std::time::Duration::from_secs(10);
    loop {
        if let Some(status) = child.try_wait().unwrap() {
            assert!(
                status.success(),
                "dashed-line regression child failed: {status}"
            );
            break;
        }
        if std::time::Instant::now() >= deadline {
            child.kill().unwrap();
            child.wait().unwrap();
            panic!("dashed-line rendering exceeded the 10-second watchdog");
        }
        std::thread::sleep(std::time::Duration::from_millis(10));
    }
}
