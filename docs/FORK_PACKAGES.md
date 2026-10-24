# Fork Android and web packages

Fork binaries carry the security fixes in `kirill-markin/RaTeX` to Android and
web consumers. Public GitHub release assets avoid requiring npm or Sonatype
accounts. Checked-in upstream package identities stay suitable for upstream
contributions; only staged distribution metadata uses the fork identities.

The manual [workflow](../.github/workflows/fork-packages.yml) accepts only `main`
and version `0.1.15-fork.1`, based on root `VERSION`. It builds the source at the
dispatch SHA with JDK 17, NDK r28c and Node 24.22.1. Rust and build-tool versions,
the generated Cargo lockfile, source/ref/run identity and asset hashes accompany
the build. No registry credentials or release-writing token are used.

| Release tag `fork-packages-0.1.15-1` asset | Identity / purpose |
| --- | --- |
| `ratex-android-0.1.15-fork.1.aar` | `io.github.kirill-markin:ratex-android:0.1.15-fork.1`; arm64-v8a, armeabi-v7a, x86_64 |
| `ratex-android-0.1.15-fork.1.ivy.xml` | Default configuration, AAR publication and dependencies from Gradle's generated POM |
| `kirill-markin-ratex-wasm-0.1.15-fork.1.tgz` | `@kirill-markin/ratex-wasm`; existing exports, JS, WASM and fonts |
| `provenance.json`, `SHA256SUMS` | Source/toolchain/package provenance and hashes of the distributable bytes |

Android consumers use an Ivy repository rooted at the release download URL,
with descriptor pattern `[module]-[revision].ivy.xml` and artifact pattern
`[artifact]-[revision].[ext]`, restricted to `io.github.kirill-markin`. Enable
`ivyDescriptor()` metadata and retain Google/Maven Central for transitives.
Depend on the normal module coordinate so its runtime dependencies resolve.
Web consumers install the release tarball URL under the scoped package name.
Both artifacts include upstream MIT attribution and bundled-font OFL notices.

1. Merge the workflow change with required CI green, then dispatch it on `main`.
2. Require the entire manual run to succeed. It tests the real WASM build,
   reruns existing tests against the extracted tarball, verifies the final AAR's
   ELF alignment and resolves the AAR plus transitives through its Ivy metadata.
3. Download `fork-packages-<source SHA>-<run ID>-<attempt>`. Inspect provenance and
   `evidence/`, then run `sha256sum -c SHA256SUMS` in the downloaded directory.
4. Create a new public release at the exact recorded source SHA with the tag
   above. Upload the five top-level files unchanged from that successful run;
   preserve its evidence. Never rebuild, overwrite assets or reuse the tag.
5. Download the public assets and verify `SHA256SUMS` again before pinning
   consumers. Consumer adoption is a separate change. Enable GitHub immutable
   releases where available; otherwise enforce this no-replacement contract.

Syncing upstream is a separate manual review and merge. It does not publish a
fork package or enable the upstream release workflows. A new package version
requires an explicitly reviewed update to this release contract.
