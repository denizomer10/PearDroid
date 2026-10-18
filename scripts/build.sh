#!/usr/bin/env bash
#
# Builds the PearDroid proof-of-concept app bundle:
#   1. compiles the GLSL shaders to SPIR-V with glslc
#   2. compiles the Swift sources against MoltenVK
#   3. assembles build/PearDroid.app
#
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

BREW_PREFIX="$(brew --prefix)"
VULKAN_INCLUDE="$BREW_PREFIX/include"
VULKAN_LIB="$BREW_PREFIX/lib"
GLSLC="$BREW_PREFIX/bin/glslc"

APP="$ROOT/build/PearDroid.app"
MACOS_DIR="$APP/Contents/MacOS"
RESOURCES_DIR="$APP/Contents/Resources"

BUILD_DIR="$ROOT/build"
SHADER_DIR="$BUILD_DIR/shaders"

echo "==> Compiling shaders (SPIR-V)"
mkdir -p "$SHADER_DIR"
for shader in shaders/*.vert shaders/*.frag; do
    [ -e "$shader" ] || continue
    output="$SHADER_DIR/$(basename "$shader").spv"
    "$GLSLC" -O "$shader" -o "$output"
    echo "    $(basename "$shader") -> $(basename "$output")"
done

echo "==> Assembling app bundle"
rm -rf "$APP"
mkdir -p "$MACOS_DIR" "$RESOURCES_DIR"

SWIFT_SOURCES=()
while IFS= read -r file; do
    SWIFT_SOURCES+=("$file")
done < <(find Sources -name '*.swift' | sort)

echo "==> Compiling Swift (${#SWIFT_SOURCES[@]} files)"
swiftc \
    -O \
    -swift-version 5 \
    -parse-as-library \
    -target arm64-apple-macosx14.0 \
    -import-objc-header Sources/PearDroid/Vulkan/VulkanBridge.h \
    -Xcc -I"$VULKAN_INCLUDE" \
    -L"$VULKAN_LIB" -lMoltenVK \
    -framework Metal -framework QuartzCore -framework AppKit -framework SwiftUI \
    -framework Hypervisor -framework Security \
    -o "$MACOS_DIR/PearDroid" \
    "${SWIFT_SOURCES[@]}"

cp Resources/Info.plist "$APP/Contents/Info.plist"
cp "$SHADER_DIR"/*.spv "$RESOURCES_DIR/"

echo "==> Signing (ad-hoc, with hypervisor entitlement)"
codesign --force --deep --sign - --entitlements Resources/entitlements.plist "$APP"

echo "==> Built $APP"
