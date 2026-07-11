#!/usr/bin/env bash
#
# mpv/mayhem/build.sh — build mpv-player/mpv's 19 OSS-Fuzz harnesses (fuzzers/*.c, wired up by
# fuzzers/meson.build's `fuzzers` alias target) as sanitized libFuzzer targets, adapted from the
# upstream OSS-Fuzz recipe at oss-fuzz/projects/mpv/{build.sh,Dockerfile}.
#
# mpv fuzzes real playback/parsing surface through libmpv's public client API (mpv_create +
# mpv_set_option_string/mpv_command/mpv_set_property) with `vo=null ao=null` — no display/audio
# device needed. The fuzzed surface pulls in FFmpeg (demux/decode), libplacebo (rendering, but
# vo=null keeps GPU paths mostly cold), libass (subtitle parsing/shaping — real target surface for
# the loadfile/protocol fuzzers), and its transitive text stack (freetype2/harfbuzz/fontconfig/
# fribidi). ALL of it is compiled HERE, from source, WITH $SANITIZER_FLAGS, so the instrumented
# surface matches what OSS-Fuzz itself fuzzes (not just mpv's own thin glue code).
#
# Everything network-fetched (FFmpeg source, libplacebo/libass, the libass-tests regression font)
# is pre-cached by mayhem/Dockerfile under /opt/mpv-deps + /opt/mpv-assets at docker-build time; this
# script only ever COPIES from that cache (idempotency-guarded so a repeat invocation is a no-op),
# so it re-runs fully offline (§6.2 item 9 / §6.5 — `docker run --network none ... build.sh`).
set -euo pipefail

# clang rejects SOURCE_DATE_EPOCH='' — must be unset or a valid integer.
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH

# `=` (not `:=`) for SANITIZER_FLAGS so an explicit empty --build-arg builds with NO sanitizers.
: "${SANITIZER_FLAGS=-fsanitize=address,undefined -fno-sanitize-recover=all -fno-omit-frame-pointer -g}"
: "${DEBUG_FLAGS:=-g -gdwarf-3}"
: "${CC:=clang}" ; : "${CXX:=clang++}" ; : "${LIB_FUZZING_ENGINE:=-fsanitize=fuzzer}"
: "${MAYHEM_JOBS:=$(nproc)}"
export SANITIZER_FLAGS DEBUG_FLAGS CC CXX LIB_FUZZING_ENGINE MAYHEM_JOBS

# DWARF <= 3 (§6.2 item 10): thread DEBUG_FLAGS AFTER SANITIZER_FLAGS into every compile+link below
# (ffmpeg's ./configure extra-cflags, and meson's c_args/cpp_args/*_link_args for mpv + ALL its
# subprojects) — clang-19's plain -g emits DWARF-5, so this must be explicit everywhere.
# A handful of the vendored subprojects' OWN bundled test/CLI tools (uchardet's test/, lcms2's
# testbed/) predate clang making implicit-function-declaration a hard error (clang >= 16); they are
# NOT part of the fuzzed surface (mpv never calls into them), so relax those two diagnostics back to
# warnings for C rather than trying to patch upstream test code we don't ship or exercise.
CFLAGS="$SANITIZER_FLAGS $DEBUG_FLAGS -Wno-error=implicit-function-declaration -Wno-error=int-conversion"
CXXFLAGS="$SANITIZER_FLAGS $DEBUG_FLAGS"
export CFLAGS CXXFLAGS

DEPS_CACHE=/opt/mpv-deps
ASSETS_CACHE=/opt/mpv-assets

cd "$SRC"

# ── 1) FFmpeg — vendored + built from source (demux/decode surface mpv fuzzes through). ───────────
# Built with the SAME sanitizer/debug flags so the fuzzed decode path is instrumented; disabled
# pieces (asm/bsfs/doc/encoders/filters/muxers/network/programs/shared) mirror the upstream OSS-Fuzz
# recipe — smaller attack surface mpv's fuzzers don't exercise (mpv only needs decode, not encode).
FFMPEG_SRC="$SRC/ffmpeg-src"
FFMPEG_PREFIX="$SRC/ffmpeg-install"
if [ ! -d "$FFMPEG_SRC" ]; then
  cp -r "$DEPS_CACHE/ffmpeg" "$FFMPEG_SRC"
fi
if [ ! -f "$FFMPEG_SRC/config.mak" ]; then
  (
    cd "$FFMPEG_SRC"
    ./configure --cc="$CC" --cxx="$CXX" --ld="$CXX $CXXFLAGS" \
                --prefix="$FFMPEG_PREFIX" \
                --enable-{gpl,nonfree} \
                --disable-{asm,bsfs,doc,encoders,filters,muxers,network,programs,shared} \
                --enable-filter={sine,yuvtestsrc} \
                --pkg-config-flags="--static" \
                --disable-{debug,optimizations} \
                --optflags=-O1 \
                --extra-cflags="$CFLAGS" --extra-cxxflags="$CXXFLAGS" --extra-ldflags="$SANITIZER_FLAGS"
  )
fi
make -C "$FFMPEG_SRC" -j"$MAYHEM_JOBS"
make -C "$FFMPEG_SRC" install
export PKG_CONFIG_PATH="$FFMPEG_PREFIX/lib/pkgconfig:$FFMPEG_PREFIX/lib64/pkgconfig:${PKG_CONFIG_PATH:-}"

# ── 2) mpv's meson subprojects (libplacebo/libass vendored source + expat/fontconfig/freetype2/
#       fribidi/harfbuzz/lcms2/uchardet/xxhash meson wraps) — populated from the pre-fetched cache,
#       idempotency-guarded so a repeat (offline) invocation touches neither git nor wrapdb. ────────
mkdir -p subprojects
[ -d subprojects/libplacebo ] || cp -r "$DEPS_CACHE/libplacebo" subprojects/libplacebo
[ -d subprojects/libass ]     || cp -r "$DEPS_CACHE/libass"     subprojects/libass
if [ ! -f subprojects/expat.wrap ]; then
  meson wrap install expat
  meson wrap install fontconfig
  meson wrap install freetype2
  meson wrap install fribidi
  meson wrap install harfbuzz
  meson wrap install lcms2
  meson wrap install uchardet
  meson wrap install xxhash
  meson subprojects download
fi

# meson.build's `fuzzers` option auto-adds its OWN sanitizer combo (including -fsanitize=fuzzer,
# which we instead want to gate behind $LIB_FUZZING_ENGINE so a --build-arg SANITIZER_FLAGS=
# override still works) — patched IN THE WORKING TREE, never committed (mayhem stays additive-only;
# git diff upstream..mayhem is all-A). Idempotent: the sed patterns only match the ORIGINAL upstream
# text, so re-running this on an already-patched tree is a silent no-op.
sed -i -e "/^\s*flags += \['-fsanitize=address,undefined,fuzzer', '-fno-omit-frame-pointer'\]/d; \
          s|^\s*link_flags += \['-fsanitize=address,undefined,fuzzer', '-fno-omit-frame-pointer'\]| \
          link_flags += \['$LIB_FUZZING_ENGINE'\]|" meson.build

# Additive KAT harness for mayhem/test.sh's oracle (§6.3) — appended to the fuzzers/meson.build
# working copy (never committed; mayhem/harnesses/mayhem_kat.c IS committed). Links against the
# same libmpv_dep as every real OSS-Fuzz harness, so it exercises the REAL sanitized build.
if ! grep -q "mayhem_kat" fuzzers/meson.build; then
  cat >> fuzzers/meson.build <<'EOF'

# --- mayhem KAT (mayhem/test.sh oracle) — appended by mayhem/build.sh; not part of upstream, not committed.
mayhem_kat_src = files(meson.current_source_dir() + '/../mayhem/harnesses/mayhem_kat.c')
executable('mayhem_kat', mayhem_kat_src, link_language: 'cpp', dependencies: libmpv_dep)
EOF
fi

FC_SYSROOT="fc_sysroot"
if [ -d build ]; then
  MESON_SETUP="meson setup build --reconfigure"
else
  MESON_SETUP="meson setup build"
fi

# SanitizerCoverage on mpv's OWN sources (root cause of edges=0): meson.build's `fuzzers` option
# only forces -fsanitize=fuzzer onto the LINK line (via the sed above, folded into
# $LIB_FUZZING_ENGINE) — that gives libFuzzer's driver/main, not compile-time coverage
# instrumentation, so libFuzzer/Mayhem saw ZERO edges on mpv's own parsers (fuzzer_json,
# fuzzer_options_parser, etc. run straight off libmpv's compiled objects via
# extract_all_objects()). -Dc_args/-Dcpp_args are a top-level-PROJECT-only meson option (unlike
# the exported CFLAGS/CXXFLAGS above, which meson also threads into every subproject's own
# compile), so adding -fsanitize=fuzzer-no-link here instruments mpv's own C/C++ sources with
# SanitizerCoverage without (yet) paying the size/time cost of instrumenting all of vendored
# FFmpeg/libass/libplacebo/freetype/harfbuzz/etc. too.
MPV_CFLAGS="$CFLAGS -fsanitize=fuzzer-no-link"
MPV_CXXFLAGS="$CXXFLAGS -fsanitize=fuzzer-no-link"

$MESON_SETUP --wrap-mode=nodownload -Dbuildtype=plain -Dbackend_max_links=4 \
                  -Ddefault_library=static -Dprefer_static=true \
                  -Dfuzzers=true -Dlibmpv=true -Dcplayer=false -Dgpl=true \
                  -Duchardet=enabled -Dlcms2=enabled -Dtests=false \
                  -Dfreetype2:harfbuzz=disabled -Dfreetype2:zlib=disabled -Dfreetype2:png=disabled \
                  -Dharfbuzz:tests=disabled -Dharfbuzz:introspection=disabled -Dharfbuzz:docs=disabled \
                  -Dharfbuzz:utilities=disabled -Dfontconfig:doc=disabled -Dfontconfig:nls=disabled -Dfontconfig:xml-backend=expat \
                  -Dfontconfig:tests=disabled -Dfontconfig:tools=disabled -Dfontconfig:cache-build=disabled \
                  -Dfribidi:deprecated=false -Dfribidi:docs=false -Dfribidi:bin=false -Dfribidi:tests=false \
                  -Dlibplacebo:lcms=enabled -Dlibplacebo:xxhash=enabled -Dlibplacebo:demos=false \
                  -Dlcms2:jpeg=disabled -Dlcms2:tiff=disabled \
                  -Dlibass:fontconfig=enabled -Dlibass:asm=disabled \
                  -Dc_args="$MPV_CFLAGS" -Dcpp_args="$MPV_CXXFLAGS -DMPV_FONTCONFIG_SYSROOT=./$FC_SYSROOT" \
                  -Dc_link_args="$MPV_CFLAGS" -Dcpp_link_args="$MPV_CXXFLAGS"
meson compile -C build fuzzers mayhem_kat

# ── 3) Ship every fuzzer_* binary (all 19 OSS-Fuzz harnesses) + the KAT into /mayhem. ──────────────
find ./build/fuzzers -maxdepth 1 -type f -name 'fuzzer_*' -exec cp {} "$SRC/" \;
cp ./build/fuzzers/mayhem_kat "$SRC/mayhem_kat"

# ── 4) Fontconfig sysroot (DESTDIR install + the libass-tests regression font) so libass/harfbuzz
#       text-shaping paths (loadfile/protocol fuzzers that hit subtitles) work without depending on
#       real system fonts (set_fontconfig_sysroot() in fuzzers/common.h points FONTCONFIG_SYSROOT
#       at this tree via the MPV_FONTCONFIG_SYSROOT macro baked in above). ─────────────────────────
DESTDIR="$SRC/$FC_SYSROOT" meson install -C build --tags runtime
mkdir -p "$SRC/$FC_SYSROOT/usr/local/share/fonts"
cp "$ASSETS_CACHE/FansubBlock-CFF.otf" "$SRC/$FC_SYSROOT/usr/local/share/fonts/FansubBlock-CFF.otf"

echo "build.sh complete:"
ls -la "$SRC"/fuzzer_* "$SRC/mayhem_kat" 2>&1 || true

# mayhem-dict-fix: place the dictionaries the Mayhemfiles reference (build.sh never did -> libFuzzer exited 1 on missing -dict -> 0 edges)
find "$SRC/mayhem" -name "*.dict" -exec cp {} /mayhem/ \; 2>/dev/null || true
