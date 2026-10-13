#!/bin/bash
# Builds the Rust core (core/) for the iPhone and its simulator, writes its Swift bindings into
# Codealong/Generated, and bundles the libraries into build/CodealongCore.xcframework, which the
# Xcode project links. SIM_ONLY=1 builds the simulator's alone, for a quicker round.
set -euo pipefail
cd "$(dirname "$0")/.."
export PATH="$HOME/.cargo/bin:$PATH"
# The C parts of the core's dependencies build for the app's oldest iOS, not the SDK's.
export IPHONEOS_DEPLOYMENT_TARGET=26.0

TARGET_DIR=$(cd core && cargo metadata --format-version 1 --no-deps | python3 -c 'import json,sys; print(json.load(sys.stdin)["target_directory"])')
TARGETS=(aarch64-apple-ios-sim aarch64-apple-ios)
if [ "${SIM_ONLY:-}" = 1 ]; then TARGETS=(aarch64-apple-ios-sim); fi
LIB=libcodealong_mobile.a

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
# What sessions' emblems are drawn with, from the same commit of the main repo.
scripts/build-emblems.sh
echo "Built build/CodealongCore.xcframework (${TARGETS[*]})"
