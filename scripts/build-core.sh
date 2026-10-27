#!/bin/bash
# Builds the Rust core (core/) for the iPhone and its simulator, writes its Swift bindings into
# Codealong/Generated, and bundles the libraries into build/CodealongCore.xcframework, which the
# Xcode project links. SIM_ONLY=1 builds the simulator's alone, for a quicker round.
#
# IF_CHANGED=1 (build.sh and install-device.sh) builds only when core/ isn't what the last build
# was built from, or a library asked for is missing: after a pull that moves the codealong-peer
# pin, say, rather than only when there's no core at all.
set -euo pipefail
cd "$(dirname "$0")/.."
export PATH="$HOME/.cargo/bin:$PATH"
# The C parts of the core's dependencies build for the app's oldest iOS, not the SDK's.
export IPHONEOS_DEPLOYMENT_TARGET=26.0

TARGETS=(aarch64-apple-ios-sim aarch64-apple-ios)
if [ "${SIM_ONLY:-}" = 1 ]; then TARGETS=(aarch64-apple-ios-sim); fi
LIB=libcodealong_mobile.a

# The core's sources and manifests, the pin among them, as one hash; build/core.stamp holds the
# last build's, written once it's done.
inputs=$(find core -path core/target -prune -o -type f \( -name '*.rs' -o -name Cargo.toml -o -name Cargo.lock \) -print0 | LC_ALL=C sort -z | xargs -0 shasum -a 256 | shasum -a 256 | cut -d' ' -f1)
if [ "${IF_CHANGED:-}" = 1 ] && [ "$(cat build/core.stamp 2>/dev/null)" = "$inputs" ]; then
  built=1
  [ -f Codealong/Generated/codealong_mobile.swift ] || built=0
  for t in "${TARGETS[@]}"; do
    case "$t" in
      aarch64-apple-ios-sim) slice=ios-arm64-simulator ;;
      *) slice=ios-arm64 ;;
    esac
    [ -d "build/CodealongCore.xcframework/$slice" ] || built=0
  done
  if [ "$built" = 1 ]; then exit 0; fi
fi

TARGET_DIR=$(cd core && cargo metadata --format-version 1 --no-deps | python3 -c 'import json,sys; print(json.load(sys.stdin)["target_directory"])')

rm -f build/core.stamp
for t in "${TARGETS[@]}"; do
  (cd core && cargo build --release --lib -p codealong-mobile --target "$t")
done
(cd core && cargo build --release -p uniffi-bindgen)

rm -rf build/generated build/include build/CodealongCore.xcframework
# The generator reads cargo metadata, so it runs from the crate.
(cd core && "$TARGET_DIR/release/uniffi-bindgen" generate --library "$TARGET_DIR/${TARGETS[0]}/release/$LIB" --language swift --out-dir ../build/generated)
mkdir -p build/include Codealong/Generated
cp build/generated/codealong_mobileFFI.h build/include/
cp build/generated/codealong_mobileFFI.modulemap build/include/module.modulemap
cp build/generated/codealong_mobile.swift Codealong/Generated/

args=()
for t in "${TARGETS[@]}"; do args+=(-library "$TARGET_DIR/$t/release/$LIB" -headers build/include); done
xcodebuild -create-xcframework "${args[@]}" -output build/CodealongCore.xcframework >/dev/null
echo "$inputs" > build/core.stamp
echo "Built build/CodealongCore.xcframework (${TARGETS[*]})"
