#!/usr/bin/env bash

set -euo pipefail

cleanup() {
  if [[ -n "${SIM_DIR-}" && -d "$SIM_DIR" ]]; then rm -rf "$SIM_DIR"; fi
  if [[ -n "${MAC_DIR-}" && -d "$MAC_DIR" ]]; then rm -rf "$MAC_DIR"; fi
  if [[ -n "${CATALYST_DIR-}" && -d "$CATALYST_DIR" ]]; then rm -rf "$CATALYST_DIR"; fi
}
trap cleanup EXIT

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
HEADER_DIR="$REPO_ROOT/crates/ratex-ffi/include"
OUTPUT="$REPO_ROOT/platforms/ios/RaTeX.xcframework"
BUILD_IOS=true
BUILD_MACOS=true
BUILD_CATALYST=true
# Controls missing-target behavior:
# - auto (default): auto-install locally, fail in CI
# - true: always auto-install
# - false: never auto-install (fail with instruction)
AUTO_INSTALL_RUST_TARGETS="${RATEX_AUTO_INSTALL_RUST_TARGETS:-auto}"

for arg in "$@"; do
  case $arg in
    --ios)   BUILD_MACOS=false; BUILD_CATALYST=false ;;
    --macos) BUILD_IOS=false; BUILD_CATALYST=false ;;
  esac
done

LIBS=()

ensure_rust_target_installed() {
  local target="$1"
  local installed_targets
  installed_targets="$(rustup target list --installed)"
  if [[ "
$installed_targets
" == *"
$target
"* ]]; then
    return
  fi

  local should_auto_install=false
  case "$AUTO_INSTALL_RUST_TARGETS" in
    true) should_auto_install=true ;;
    false) should_auto_install=false ;;
    auto)
      if [[ -z "${CI-}" ]]; then
        should_auto_install=true
      fi
      ;;
    *)
      echo "Unknown RATEX_AUTO_INSTALL_RUST_TARGETS value: $AUTO_INSTALL_RUST_TARGETS" >&2
      exit 2
      ;;
  esac

  if $should_auto_install; then
    echo "    Installing missing Rust target: $target"
    rustup target add "$target"
    return
  fi

  echo "Missing Rust target: $target" >&2
  echo "Install it first: rustup target add $target" >&2
  exit 1
}

if $BUILD_IOS; then
  echo "==> Building ratex-ffi for iOS targets..."
  ensure_rust_target_installed aarch64-apple-ios
  ensure_rust_target_installed aarch64-apple-ios-sim
  ensure_rust_target_installed x86_64-apple-ios
  cargo build --release -p ratex-ffi --manifest-path "$REPO_ROOT/Cargo.toml" \
      --target aarch64-apple-ios
  cargo build --release -p ratex-ffi --manifest-path "$REPO_ROOT/Cargo.toml" \
      --target aarch64-apple-ios-sim
  cargo build --release -p ratex-ffi --manifest-path "$REPO_ROOT/Cargo.toml" \
      --target x86_64-apple-ios

  echo "==> Creating fat iOS simulator binary..."
  SIM_DIR=$(mktemp -d)
  lipo -create \
      "$REPO_ROOT/target/aarch64-apple-ios-sim/release/libratex_ffi.a" \
      "$REPO_ROOT/target/x86_64-apple-ios/release/libratex_ffi.a" \
      -output "$SIM_DIR/libratex_ffi.a"

  LIBS+=(-library "$REPO_ROOT/target/aarch64-apple-ios/release/libratex_ffi.a" -headers "$HEADER_DIR")
  LIBS+=(-library "$SIM_DIR/libratex_ffi.a" -headers "$HEADER_DIR")
fi

if $BUILD_MACOS; then
  echo "==> Building ratex-ffi for macOS targets..."

  ensure_rust_target_installed aarch64-apple-darwin
  ensure_rust_target_installed x86_64-apple-darwin

  cargo build --release -p ratex-ffi --manifest-path "$REPO_ROOT/Cargo.toml" \
      --target aarch64-apple-darwin
  cargo build --release -p ratex-ffi --manifest-path "$REPO_ROOT/Cargo.toml" \
      --target x86_64-apple-darwin

  echo "==> Creating fat macOS binary..."
  MAC_DIR=$(mktemp -d)
  lipo -create \
      "$REPO_ROOT/target/aarch64-apple-darwin/release/libratex_ffi.a" \
      "$REPO_ROOT/target/x86_64-apple-darwin/release/libratex_ffi.a" \
      -output "$MAC_DIR/libratex_ffi.a"

  LIBS+=(-library "$MAC_DIR/libratex_ffi.a" -headers "$HEADER_DIR")
fi

if $BUILD_CATALYST; then
  echo "==> Building ratex-ffi for Mac Catalyst targets..."
  ensure_rust_target_installed aarch64-apple-ios-macabi
  ensure_rust_target_installed x86_64-apple-ios-macabi

  CATALYST_SDK="$(xcrun --sdk macosx --show-sdk-path)"
  for target in aarch64-apple-ios-macabi x86_64-apple-ios-macabi; do
    SDKROOT="$CATALYST_SDK" IPHONEOS_DEPLOYMENT_TARGET=14.0 \
      cargo build --release -p ratex-ffi --manifest-path "$REPO_ROOT/Cargo.toml" \
      --target "$target"
  done

  echo "==> Creating fat Mac Catalyst binary..."
  CATALYST_DIR=$(mktemp -d)
  lipo -create \
      "$REPO_ROOT/target/aarch64-apple-ios-macabi/release/libratex_ffi.a" \
      "$REPO_ROOT/target/x86_64-apple-ios-macabi/release/libratex_ffi.a" \
      -output "$CATALYST_DIR/libratex_ffi.a"

  LIBS+=(-library "$CATALYST_DIR/libratex_ffi.a" -headers "$HEADER_DIR")
fi

echo "==> Packaging XCFramework..."
rm -rf "$OUTPUT"
xcodebuild -create-xcframework "${LIBS[@]}" -output "$OUTPUT"

echo "==> Adding module.modulemap to XCFramework headers..."
for HDIR in "$OUTPUT"/*/Headers; do
  cat > "$HDIR/module.modulemap" << 'EOF'
module RaTeXFFI {
    header "ratex.h"
    export *
}
EOF
done

echo "==> Done: $OUTPUT"
echo "   Slices:"
ls -d "$OUTPUT"/*/
