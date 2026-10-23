fn main() {
    let android = std::env::var("CARGO_CFG_TARGET_OS").as_deref() == Ok("android");
    let bits64 = std::env::var("CARGO_CFG_TARGET_POINTER_WIDTH").as_deref() == Ok("64");

    if android && bits64 {
        // LOAD alignment alone is insufficient: common-page-size also aligns
        // the end of GNU_RELRO on NDK r27 and earlier (see issue #165).
        println!("cargo:rustc-link-arg-cdylib=-Wl,-z,max-page-size=16384");
        println!("cargo:rustc-link-arg-cdylib=-Wl,-z,common-page-size=16384");
    }
}
