#!/usr/bin/env bash

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SMOKE_DIR="$(mktemp -d)"
trap 'rm -rf "$SMOKE_DIR"' EXIT

# The published manifest stays pinned to its release; only this temporary package
# consumes the just-built binary and the real Swift wrapper (including resources).
mkdir -p "$SMOKE_DIR/RaTeXPackage/Sources" "$SMOKE_DIR/CatalystSmoke.xcodeproj"
cp -R "$REPO_ROOT/platforms/ios/Sources/Ratex" "$SMOKE_DIR/RaTeXPackage/Sources/RaTeX"
cp -R "$REPO_ROOT/platforms/ios/RaTeX.xcframework" "$SMOKE_DIR/RaTeXPackage/"
cp "$REPO_ROOT/platforms/ios/catalyst/CatalystSmoke.swift" "$SMOKE_DIR/"
cat > "$SMOKE_DIR/RaTeXPackage/Package.swift" <<'SWIFT'
// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "RaTeX",
    platforms: [.iOS(.v14), .macOS(.v14)],
    products: [.library(name: "RaTeX", targets: ["RaTeX"])],
    targets: [
        .binaryTarget(name: "RaTeXFFI", path: "RaTeX.xcframework"),
        .target(name: "RaTeX", dependencies: ["RaTeXFFI"], resources: [.copy("Fonts")]),
    ]
)
SWIFT

# A bundled UIKit executable gives the real wrapper its Catalyst runtime and
# exercises SwiftPM binary variant selection without an external project generator.
cat > "$SMOKE_DIR/CatalystSmoke.xcodeproj/project.pbxproj" <<'PROJECT'
// !$*UTF8*$!
{
    archiveVersion = 1;
    classes = {};
    objectVersion = 56;
    objects = {
        A00000000000000000000001 = {
            isa = PBXProject;
            buildConfigurationList = A00000000000000000000002;
            compatibilityVersion = "Xcode 14.0";
            developmentRegion = en;
            knownRegions = (en, Base);
            mainGroup = A00000000000000000000003;
            productRefGroup = A00000000000000000000004;
            projectDirPath = "";
            projectRoot = "";
            targets = (A00000000000000000000005);
            packageReferences = (A00000000000000000000006);
        };
        A00000000000000000000002 = { isa = XCConfigurationList; buildConfigurations = (A00000000000000000000007); defaultConfigurationIsVisible = 0; defaultConfigurationName = Release; };
        A00000000000000000000003 = { isa = PBXGroup; children = (A00000000000000000000008, A00000000000000000000004); sourceTree = "<group>"; };
        A00000000000000000000004 = { isa = PBXGroup; children = (A00000000000000000000009); name = Products; sourceTree = "<group>"; };
        A00000000000000000000005 = {
            isa = PBXNativeTarget;
            buildConfigurationList = A0000000000000000000000A;
            buildPhases = (A0000000000000000000000B, A0000000000000000000000C, A0000000000000000000000D);
            buildRules = ();
            dependencies = ();
            name = CatalystSmoke;
            packageProductDependencies = (A0000000000000000000000E);
            productName = CatalystSmoke;
            productReference = A00000000000000000000009;
            productType = "com.apple.product-type.application";
        };
        A00000000000000000000006 = { isa = XCLocalSwiftPackageReference; relativePath = RaTeXPackage; };
        A00000000000000000000007 = { isa = XCBuildConfiguration; buildSettings = { SDKROOT = iphoneos; }; name = Release; };
        A00000000000000000000008 = { isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = CatalystSmoke.swift; sourceTree = "<group>"; };
        A00000000000000000000009 = { isa = PBXFileReference; explicitFileType = wrapper.application; includeInIndex = 0; path = CatalystSmoke.app; sourceTree = BUILT_PRODUCTS_DIR; };
        A0000000000000000000000A = { isa = XCConfigurationList; buildConfigurations = (A0000000000000000000000F); defaultConfigurationIsVisible = 0; defaultConfigurationName = Release; };
        A0000000000000000000000B = { isa = PBXSourcesBuildPhase; buildActionMask = 2147483647; files = (A00000000000000000000010); runOnlyForDeploymentPostprocessing = 0; };
        A0000000000000000000000C = { isa = PBXFrameworksBuildPhase; buildActionMask = 2147483647; files = (A00000000000000000000011); runOnlyForDeploymentPostprocessing = 0; };
        A0000000000000000000000D = { isa = PBXResourcesBuildPhase; buildActionMask = 2147483647; files = (); runOnlyForDeploymentPostprocessing = 0; };
        A0000000000000000000000E = { isa = XCSwiftPackageProductDependency; package = A00000000000000000000006; productName = RaTeX; };
        A0000000000000000000000F = {
            isa = XCBuildConfiguration;
            buildSettings = {
                GENERATE_INFOPLIST_FILE = YES;
                INFOPLIST_KEY_LSApplicationCategoryType = "public.app-category.developer-tools";
                IPHONEOS_DEPLOYMENT_TARGET = 14.0;
                PRODUCT_BUNDLE_IDENTIFIER = "com.ratex.catalyst-smoke";
                PRODUCT_NAME = "$(TARGET_NAME)";
                SUPPORTS_MACCATALYST = YES;
                SWIFT_VERSION = 5.0;
                TARGETED_DEVICE_FAMILY = "1,2";
            };
            name = Release;
        };
        A00000000000000000000010 = { isa = PBXBuildFile; fileRef = A00000000000000000000008; };
        A00000000000000000000011 = { isa = PBXBuildFile; productRef = A0000000000000000000000E; };
    };
    rootObject = A00000000000000000000001;
}
PROJECT

xcodebuild -project "$SMOKE_DIR/CatalystSmoke.xcodeproj" -scheme CatalystSmoke \
  -configuration Release -destination 'generic/platform=macOS,variant=Mac Catalyst' \
  -derivedDataPath "$SMOKE_DIR/DerivedData" \
  ARCHS='arm64 x86_64' ONLY_ACTIVE_ARCH=NO CODE_SIGNING_ALLOWED=NO build

APP="$SMOKE_DIR/DerivedData/Build/Products/Release-maccatalyst/CatalystSmoke.app"
BINARY="$APP/Contents/MacOS/CatalystSmoke"
lipo "$BINARY" -verify_arch arm64 x86_64
codesign --force --sign - "$APP"
python3 - "$BINARY" <<'PY'
import subprocess
import sys

result = subprocess.run([sys.argv[1]], capture_output=True, text=True, timeout=60)
print(result.stdout, end="")
print(result.stderr, end="", file=sys.stderr)
result.check_returncode()
if "Catalyst UIKit / Swift / C ABI formula smoke passed." not in result.stdout:
    raise RuntimeError("Catalyst app exited without completing the formula smoke.")
PY
