#!/usr/bin/env bash
#
# mayhem/build.sh — build the exfat fuzz harness(es) + the tools the oracle exercises.
#
# Runs inside the commit image (mayhem/Dockerfile) as `mayhem` in /mayhem. The base image
# (ghcr.io/mayhemheroes/base) exports the build contract (CC/CXX/SANITIZER_FLAGS/DEBUG_FLAGS/
# LIB_FUZZING_ENGINE/STANDALONE_FUZZ_MAIN/SRC). exfat's autotools build hardcodes
# `-imacros $(top_srcdir)/libexfat/config.h`, so it only supports an IN-TREE build; we therefore
# run two sequential in-tree builds, `make distclean` between them (idempotent + air-gapped):
#   pass 1  sanitized + DWARF-3  -> the fuzz targets (dumpexfat CLI target + libexfat harness)
#   pass 2  normal flags         -> the CLI tools the behavioral oracle (test.sh) drives
set -euo pipefail

# clang rejects SOURCE_DATE_EPOCH='' (empty) — it must be unset or a valid integer.
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH

: "${SANITIZER_FLAGS=-fsanitize=address,undefined -fno-sanitize-recover=all -fno-omit-frame-pointer}"
: "${DEBUG_FLAGS:=-g -gdwarf-3}"
: "${CC:=clang}" ; : "${CXX:=clang++}" ; : "${LIB_FUZZING_ENGINE:=-fsanitize=fuzzer}"
: "${MAYHEM_JOBS:=$(nproc)}"
: "${COVERAGE_FLAGS=}"
: "${STANDALONE_FUZZ_MAIN:=/opt/mayhem/StandaloneFuzzTargetMain.c}"
export SANITIZER_FLAGS DEBUG_FLAGS CC CXX LIB_FUZZING_ENGINE MAYHEM_JOBS COVERAGE_FLAGS

cd "$SRC"

# Regenerate the autotools build system (upstream ships only the *.am/*.ac sources).
autoreconf --install --force

# ---- pass 1: SANITIZED build (ASan+UBSan, halting; DWARF-3) ------------------------------------
# Instruments the whole project so the fuzzed libexfat code AND the dumpexfat CLI target are
# sanitized and carry DWARF < 4 symbols.
make distclean >/dev/null 2>&1 || true
./configure CC="$CC" CFLAGS="$SANITIZER_FLAGS $DEBUG_FLAGS"
make -j"$MAYHEM_JOBS"

# The raw file-input CLI target (parity with the original `dumpexfat` target).
cp -f "$SRC/dump/dumpexfat" /mayhem/dumpexfat

# libexfat in-process harness — drives exfat_mount()+directory traversal over the input image (the
# real filesystem parser), replacing the original exfat_debug() format-string stub. libexfat's
# compiler.h requires C99, so the .cpp harness is compiled AS C (-x c). Built TWICE: libFuzzer +
# standalone run-once reproducer.
HARNESS="$SRC/mayhem/fuzz_exfat_debug.cpp"
HDR="-I$SRC/libexfat -imacros $SRC/libexfat/config.h"

$CC $SANITIZER_FLAGS $DEBUG_FLAGS $LIB_FUZZING_ENGINE \
    $HDR -x c "$HARNESS" -x none "$SRC/libexfat/libexfat.a" -o /mayhem/fuzz_exfat_debug

$CC $SANITIZER_FLAGS $DEBUG_FLAGS -c "$STANDALONE_FUZZ_MAIN" -o /tmp/standalone_main.o
$CC $SANITIZER_FLAGS $DEBUG_FLAGS \
    $HDR -x c "$HARNESS" -x none /tmp/standalone_main.o "$SRC/libexfat/libexfat.a" -o /mayhem/fuzz_exfat_debug-standalone

# ---- pass 2: TEST build (normal flags) ---------------------------------------------------------
# A clean, independent build of the CLI tools the behavioral oracle (test.sh) drives. This is the
# tree state left in the image; test.sh reads $SRC/{mkfs,dump,fsck,label}/... from here.
make distclean >/dev/null 2>&1 || true
env -u CFLAGS -u LDFLAGS ./configure CC="$CC" CFLAGS="-O2 $COVERAGE_FLAGS" LDFLAGS="$COVERAGE_FLAGS"
make -j"$MAYHEM_JOBS"

echo "build.sh: done"
