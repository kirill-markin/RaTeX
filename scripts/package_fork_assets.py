#!/usr/bin/env python3
"""Stage fork release assets from the manual workflow's tested build outputs."""

import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import tarfile
import tempfile
import xml.etree.ElementTree as ET
import zipfile


ROOT = Path(__file__).resolve().parents[1]
POM_NS = {"m": "http://maven.apache.org/POM/4.0.0"}
ANDROID_GROUP = "io.github.kirill-markin"
WEB_NAME = "@kirill-markin/ratex-wasm"


def sha256(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def write_json(path: Path, value: object) -> None:
    path.write_text(json.dumps(value, indent=2) + "\n", encoding="utf-8")


def run_recorded(command: list[str], directory: Path, log: Path) -> None:
    result = subprocess.run(command, cwd=directory, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
    log.write_text(result.stdout, encoding="utf-8")
    print(result.stdout, end="", flush=True)
    result.check_returncode()


def package_android(output: Path, version: str) -> None:
    android = ROOT / "platforms/android"
    pom_path = android / "build/publications/maven/pom-default.xml"
    pom = ET.parse(pom_path).getroot()
    if pom.findtext("m:version", namespaces=POM_NS) != version:
        raise ValueError(f"Generated Android POM version must be {version}: {pom_path}")
    ivy = ET.Element("ivy-module", {"version": "2.0"})
    ET.SubElement(ivy, "info", {"organisation": ANDROID_GROUP, "module": "ratex-android", "revision": version})
    configs = ET.SubElement(ivy, "configurations")
    ET.SubElement(configs, "conf", {"name": "default", "visibility": "public"})
    publications = ET.SubElement(ivy, "publications")
    ET.SubElement(publications, "artifact", {"name": "ratex-android", "type": "aar", "ext": "aar", "conf": "default"})
    dependencies = ET.SubElement(ivy, "dependencies")
    coordinates: list[str] = []
    for dependency in pom.findall("m:dependencies/m:dependency", POM_NS):
        fields = [dependency.findtext(f"m:{name}", namespaces=POM_NS) for name in ("groupId", "artifactId", "version")]
        if any(not field or "${" in field for field in fields):
            raise ValueError(f"Android POM dependency must have concrete coordinates: {fields}")
        group, module, revision = (str(field) for field in fields)
        scope = dependency.findtext("m:scope", "compile", POM_NS)
        if scope not in {"compile", "runtime"} or dependency.findtext("m:optional", "false", POM_NS) != "false":
            raise ValueError(f"Unsupported Android POM dependency scope/optional: {fields}")
        if dependency.find("m:classifier", POM_NS) is not None or dependency.findtext("m:type", "jar", POM_NS) != "jar":
            raise ValueError(f"Unsupported Android POM dependency classifier/type: {fields}")
        node = ET.SubElement(dependencies, "dependency", {"org": group, "name": module, "rev": revision, "conf": "default->default"})
        for exclusion in dependency.findall("m:exclusions/m:exclusion", POM_NS):
            org = exclusion.findtext("m:groupId", namespaces=POM_NS)
            name = exclusion.findtext("m:artifactId", namespaces=POM_NS)
            if not org or not name:
                raise ValueError(f"Incomplete Android POM exclusion: {fields}")
            ET.SubElement(node, "exclude", {"org": org, "module": name})
        coordinates.append(f"{group}:{module}:{revision}")
    required = {"androidx.annotation:annotation:1.7.1", "org.jetbrains.kotlinx:kotlinx-serialization-json:1.6.3", "org.jetbrains.kotlinx:kotlinx-coroutines-android:1.7.3"}
    if not required.issubset(coordinates):
        raise ValueError(f"Generated Android POM omits required runtime dependencies: {coordinates}")
    ET.indent(ivy)
    ET.ElementTree(ivy).write(output / f"ratex-android-{version}.ivy.xml", encoding="utf-8", xml_declaration=True)
    shutil.copy2(pom_path, output / "evidence/android-pom.xml")
    write_json(output / "evidence/android-dependencies.json", coordinates)
    aar = output / f"ratex-android-{version}.aar"
    shutil.copy2(android / "build/outputs/aar/ratex-android-release.aar", aar)
    with zipfile.ZipFile(aar, "a") as archive:
        for source in [ROOT / "LICENSE", ROOT / "THIRD_PARTY_NOTICES.txt", *sorted((ROOT / "licenses").glob("*.txt"))]:
            target = f"META-INF/{source.relative_to(ROOT)}"
            if target in archive.namelist():
                raise ValueError(f"Refusing to overwrite AAR entry: {target}")
            archive.write(source, target)
        for abi in ("arm64-v8a", "armeabi-v7a", "x86_64"):
            if not archive.read(f"jni/{abi}/libratex_ffi.so"):
                raise ValueError(f"Empty Android library: {abi}")
    run_recorded(["python3", str(ROOT / "scripts/verify_android_elf.py"), str(aar)], ROOT, output / "evidence/android-elf.txt")


def package_web(output: Path, version: str) -> None:
    web = ROOT / "platforms/web"
    with tempfile.TemporaryDirectory(prefix="ratex-fork-") as temporary:
        stage = Path(temporary) / "stage"
        stage.mkdir()
        manifest = json.loads((web / "package.json").read_text(encoding="utf-8"))
        exports = manifest["exports"]
        manifest.update(name=WEB_NAME, version=version, repository={"type": "git", "url": "https://github.com/kirill-markin/RaTeX.git"})
        manifest["homepage"] = "https://github.com/kirill-markin/RaTeX/tree/main/platforms/web#readme"
        manifest["files"] += ["THIRD_PARTY_NOTICES.txt", "licenses"]
        write_json(stage / "package.json", manifest)
        for name in ["dist", "pkg", "fonts", "src"]:
            shutil.copytree(web / name, stage / name)
        for name in ["fonts.css", "LICENSE", "README.md"]:
            shutil.copy2(web / name, stage / name)
        shutil.copy2(ROOT / "THIRD_PARTY_NOTICES.txt", stage)
        shutil.copytree(ROOT / "licenses", stage / "licenses")
        subprocess.run(["npm", "pack", "--pack-destination", str(output)], cwd=stage, check=True)
        tarball = output / f"kirill-markin-ratex-wasm-{version}.tgz"
        extracted = Path(temporary) / "extracted"
        with tarfile.open(tarball, "r:gz") as archive:
            archive.extractall(extracted, filter="data")
            write_json(output / "evidence/web-contents.json", archive.getnames())
        package = extracted / "package"
        packed = json.loads((package / "package.json").read_text(encoding="utf-8"))
        if packed["name"] != WEB_NAME or packed["version"] != version or packed["exports"] != exports:
            raise ValueError("Packed web identity or exports differ from the fork contract")
        for name in ["dist/index.js", "dist/index.d.ts", "dist/ratex-formula.js", "pkg/ratex_wasm.js", "pkg/ratex_wasm_bg.wasm", "LICENSE", "licenses/SIL-OFL-1.1.txt"]:
            if not (package / name).stat().st_size:
                raise ValueError(f"Empty web package file: {name}")
        for name in re.findall(r"url\(\./([^)]*)\)", (package / "fonts.css").read_text(encoding="utf-8")):
            if not (package / name).stat().st_size:
                raise ValueError(f"Empty packaged font: {name}")
        shutil.copytree(web / "tests", package / "tests")
        run_recorded(["node", "--test", *map(str, sorted((package / "tests").glob("*.test.mjs")))], package, output / "evidence/web-package-tests.txt")


def main() -> None:
    version = os.environ["FORK_VERSION"]
    output = Path(os.environ["FORK_ASSET_DIR"])
    output.mkdir(parents=True, exist_ok=False)
    (output / "evidence").mkdir()
    package_android(output, version)
    package_web(output, version)
    shutil.copy2(ROOT / "Cargo.lock", output / "evidence/Cargo.lock")
    shutil.copy2(ROOT / "out/fork-toolchains.txt", output / "evidence/toolchains.txt")
    assets = sorted(path for path in output.iterdir() if path.is_file())
    write_json(output / "provenance.json", {
        "repository": os.environ["GITHUB_REPOSITORY"], "source_sha": os.environ["GITHUB_SHA"],
        "source_ref": os.environ["GITHUB_REF"], "event": os.environ["GITHUB_EVENT_NAME"],
        "workflow_ref": os.environ["GITHUB_WORKFLOW_REF"], "workflow_sha": os.environ["GITHUB_WORKFLOW_SHA"],
        "run_id": os.environ["GITHUB_RUN_ID"], "run_attempt": os.environ["GITHUB_RUN_ATTEMPT"],
        "run_url": f"{os.environ['GITHUB_SERVER_URL']}/{os.environ['GITHUB_REPOSITORY']}/actions/runs/{os.environ['GITHUB_RUN_ID']}",
        "release_tag": os.environ["FORK_RELEASE_TAG"], "base_version": (ROOT / "VERSION").read_text().strip(),
        "packages": {"android": f"{ANDROID_GROUP}:ratex-android:{version}", "web": f"{WEB_NAME}@{version}"},
        "toolchains": (output / "evidence/toolchains.txt").read_text(),
        "assets_sha256": {path.name: sha256(path) for path in assets},
        "inputs_sha256": {name: sha256(ROOT / name) for name in ["Cargo.lock", "platforms/web/package-lock.json", "platforms/android/build.gradle.kts", "demo/android/gradle/wrapper/gradle-wrapper.properties"]},
    })
    checksummed = [*assets, output / "provenance.json"]
    (output / "SHA256SUMS").write_text("".join(f"{sha256(path)}  {path.name}\n" for path in checksummed))


if __name__ == "__main__":
    main()
