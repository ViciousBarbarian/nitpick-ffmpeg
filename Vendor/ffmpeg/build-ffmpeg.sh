#!/bin/bash
# Builds the FFmpeg that NitPick ships, exactly as it ships.
#
# Output: Packages/NitPickKit/Binaries/lib{avutil,avcodec,avformat,swresample}.xcframework
# Each xcframework holds one dynamic macOS framework (arm64, macOS 15+). FFmpegShim
# links them as SwiftPM binary targets, and Xcode embeds and signs them into
# NitPick.app/Contents/Frameworks/.
#
# Why each choice (see CLAUDE.md "Shipping FFmpeg inside the app"):
#   - LGPL v2.1 only: never --enable-gpl, --enable-nonfree or --enable-version3.
#   - Shared libraries, so users can replace FFmpeg (LGPL relinking requirement).
#   - No video decoders at all. Video is decoded by VideoToolbox directly; FFmpeg's
#     VideoToolbox hwaccel would pull in the software HEVC/H.264 decoders, which our
#     codec licensing policy forbids shipping.
#   - --disable-autodetect and a minimal PATH, so nothing from Homebrew or the build
#     machine leaks into the libraries. The only external library is the system zlib.
#
# Users rebuilding FFmpeg for LGPL relinking can run this same script.
#
# Usage: Vendor/ffmpeg/build-ffmpeg.sh [--force]
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
source "$SCRIPT_DIR/VERSION"

SRC_DIR="$SCRIPT_DIR/src"
WORK_DIR="$SCRIPT_DIR/build"
OUTPUT_DIR="$REPO_ROOT/Packages/NitPickKit/Binaries"
MIN_MACOS="15.0"
LIBRARIES=(libavutil libswresample libavcodec libavformat)   # dependency order

# The stamp is a hash of this script plus VERSION. If it matches the last build, the
# output is already exactly what this script would produce, so skip the 2-minute build.
STAMP="$(cat "$0" "$SCRIPT_DIR/VERSION" | shasum -a 256 | cut -d' ' -f1)"
STAMP_FILE="$OUTPUT_DIR/.ffmpeg-build-stamp"
if [[ "${1:-}" != "--force" && -f "$STAMP_FILE" && "$(cat "$STAMP_FILE")" == "$STAMP" ]]; then
    echo "FFmpeg $FFMPEG_VERSION is up to date in $OUTPUT_DIR"
    exit 0
fi

# ---------------------------------------------------------------------------
# 1. Fetch and verify the pinned source tarball.
# ---------------------------------------------------------------------------
fetch_source() {
    local tarball="$SRC_DIR/ffmpeg-$FFMPEG_VERSION.tar.xz"
    mkdir -p "$SRC_DIR"
    if [[ ! -f "$tarball" ]]; then
        curl -sSfL "https://ffmpeg.org/releases/ffmpeg-$FFMPEG_VERSION.tar.xz" -o "$tarball"
    fi
    # A mismatch means a corrupted download or a tampered mirror: never build from it.
    echo "$FFMPEG_SHA256  $tarball" | shasum -a 256 -c - >/dev/null \
        || { echo "error: SHA-256 mismatch for $tarball" >&2; exit 1; }

    rm -rf "$WORK_DIR" && mkdir -p "$WORK_DIR"
    tar -xf "$tarball" -C "$WORK_DIR"
}

# ---------------------------------------------------------------------------
# 2. Configure and build. Every component is off unless listed here.
# ---------------------------------------------------------------------------
configure_and_build() {
    local src="$WORK_DIR/ffmpeg-$FFMPEG_VERSION"
    local prefix="$WORK_DIR/install"

    # Containers in v1 scope. M2TS (Blu-ray) is handled by the mpegts demuxer;
    # BDMV playlists are parsed by MediaSource itself, not by FFmpeg.
    local demuxers=(matroska mov mpegts)

    # Parsers split raw streams into whole packets, needed for TS/M2TS where packet
    # boundaries are not stored. Video parsers are listed although video is not
    # decoded by FFmpeg: they find frame boundaries and keyframes.
    local parsers=(hevc h264 av1 aac ac3 flac opus)

    # Audio decoders in v1 scope. AAC goes through Apple's AudioToolbox (aac_at),
    # whose patent license comes with macOS. pcm_bluray and pcm_dvd are disc LPCM.
    local decoders=(
        aac_at ac3 eac3 flac opus
        pcm_s16le pcm_s16be pcm_s24le pcm_s24be pcm_s32le pcm_s32be
        pcm_f32le pcm_f32be pcm_bluray pcm_dvd
        pgssub
    )

    # extract_extradata pulls VPS/SPS/PPS out of Annex-B streams (TS/M2TS), which
    # FFmpegShim needs to build a VideoToolbox format description.
    local bsfs=(extract_extradata aac_adtstoasc)

    local args=(
        --prefix="$prefix"
        --target-os=darwin --arch=aarch64 --cc=clang
        --extra-cflags="-mmacosx-version-min=$MIN_MACOS"
        # Header padding lets make_framework rewrite install names to the longer
        # framework paths without relinking.
        --extra-ldflags="-mmacosx-version-min=$MIN_MACOS -Wl,-headerpad_max_install_names"
        --install-name-dir=@rpath
        --enable-shared --disable-static --enable-pic
        --disable-debug --disable-doc --disable-programs --disable-network
        --disable-autodetect --disable-everything
        --disable-avdevice --disable-avfilter --disable-swscale
        --enable-audiotoolbox --enable-zlib
        --enable-protocol=file
    )
    local name
    for name in "${demuxers[@]}"; do args+=(--enable-demuxer="$name"); done
    for name in "${parsers[@]}";  do args+=(--enable-parser="$name");  done
    for name in "${decoders[@]}"; do args+=(--enable-decoder="$name"); done
    for name in "${bsfs[@]}";     do args+=(--enable-bsf="$name");     done

    # Minimal PATH: Apple's toolchain only, so no Homebrew pkg-config, nasm or make
    # can change what gets built.
    (
        cd "$src"
        export PATH="/usr/bin:/bin:/usr/sbin:/sbin"
        ./configure "${args[@]}"
        make -j"$(sysctl -n hw.ncpu)"
        make install
    )
}

# ---------------------------------------------------------------------------
# 3. Wrap each dylib as a versioned macOS framework, then as an xcframework.
# ---------------------------------------------------------------------------

# Install name a library has once it lives inside its framework in the app bundle.
framework_install_name() {
    echo "@rpath/$1.framework/Versions/A/$1"
}

make_framework() {
    local lib="$1"
    local prefix="$WORK_DIR/install"
    local fw="$WORK_DIR/frameworks/$lib.framework"
    local dylib
    dylib="$(find "$prefix/lib" -name "$lib.*.dylib" -type f | head -n 1)"

    rm -rf "$fw"
    mkdir -p "$fw/Versions/A/Headers" "$fw/Versions/A/Resources"
    cp "$dylib" "$fw/Versions/A/$lib"
    # Headers keep FFmpeg's own layout, so "#include <libavutil/avutil.h>" resolves
    # to libavutil.framework/Headers/avutil.h through clang's framework search.
    cp -R "$prefix/include/$lib/." "$fw/Versions/A/Headers/"

    # Point the library and its references to sibling FFmpeg libraries at the
    # framework paths. FFmpeg built them as @rpath/libX.N.dylib.
    install_name_tool -id "$(framework_install_name "$lib")" "$fw/Versions/A/$lib"
    local dep other
    for dep in $(otool -L "$fw/Versions/A/$lib" | awk 'NR>1 {print $1}' | grep '^@rpath/lib' || true); do
        other="$(basename "$dep" | cut -d. -f1)"     # @rpath/libavutil.60.dylib -> libavutil
        install_name_tool -change "$dep" "$(framework_install_name "$other")" "$fw/Versions/A/$lib"
    done

    # Version numbers come from the dylib name (libavcodec.62.11.100.dylib).
    local version
    version="$(basename "$dylib" | sed -E "s/^$lib\.([0-9.]+)\.dylib$/\1/")"
    cat > "$fw/Versions/A/Resources/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key><string>en</string>
    <key>CFBundleExecutable</key><string>$lib</string>
    <key>CFBundleIdentifier</key><string>org.ffmpeg.$lib</string>
    <key>CFBundleName</key><string>$lib</string>
    <key>CFBundlePackageType</key><string>FMWK</string>
    <key>CFBundleShortVersionString</key><string>$version</string>
    <key>CFBundleVersion</key><string>$version</string>
    <key>LSMinimumSystemVersion</key><string>$MIN_MACOS</string>
    <key>NitPickFFmpegRelease</key><string>$FFMPEG_VERSION</string>
</dict>
</plist>
PLIST

    # Standard versioned-bundle symlinks that codesign and the loader expect on macOS.
    ln -s A "$fw/Versions/Current"
    ln -s "Versions/Current/$lib" "$fw/$lib"
    ln -s Versions/Current/Headers "$fw/Headers"
    ln -s Versions/Current/Resources "$fw/Resources"

    rm -rf "$OUTPUT_DIR/$lib.xcframework"
    xcodebuild -create-xcframework -framework "$fw" -output "$OUTPUT_DIR/$lib.xcframework" >/dev/null
}

fetch_source
configure_and_build
mkdir -p "$OUTPUT_DIR"
for lib in "${LIBRARIES[@]}"; do make_framework "$lib"; done
echo "$STAMP" > "$STAMP_FILE"
echo "FFmpeg $FFMPEG_VERSION built into $OUTPUT_DIR"
