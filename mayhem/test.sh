#!/usr/bin/env bash
#
# mayhem/test.sh — behavioral oracle for exfat.
#
# AUTHORED oracle: relan/exfat ships NO unit/functional test suite (no `make check`, no tests/ dir,
# no ctest/criterion). tests_found=0. This oracle drives the real CLI tools (built by build.sh with
# normal flags) through a create -> inspect -> check -> relabel round-trip and asserts on their
# OUTPUT/VALUES (not just exit status), so a PATCH that neuters a tool to exit(0) FAILS here. Emits a
# CTRF summary and exits non-zero on any failure.
set -uo pipefail
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH
cd "$SRC"

emit_ctrf() {
  local tool="$1" passed="$2" failed="$3" skipped="${4:-0}" pending="${5:-0}" other="${6:-0}"
  local tests=$(( passed + failed + skipped + pending + other ))
  cat > "${CTRF_REPORT:-$SRC/ctrf-report.json}" <<JSON
{
  "results": {
    "tool": { "name": "$tool" },
    "summary": {
      "tests": $tests,
      "passed": $passed,
      "failed": $failed,
      "pending": $pending,
      "skipped": $skipped,
      "other": $other
    }
  }
}
JSON
  printf 'CTRF {"results":{"tool":{"name":"%s"},"summary":{"tests":%d,"passed":%d,"failed":%d,"pending":%d,"skipped":%d,"other":%d}}}\n' \
    "$tool" "$tests" "$passed" "$failed" "$pending" "$skipped" "$other"
  [ "$failed" -eq 0 ]
}

MKFS="$SRC/mkfs/mkexfatfs"
DUMP="$SRC/dump/dumpexfat"
FSCK="$SRC/fsck/exfatfsck"
LABEL="$SRC/label/exfatlabel"

for t in "$MKFS" "$DUMP" "$FSCK" "$LABEL"; do
  if [ ! -x "$t" ]; then
    echo "test.sh: expected tool '$t' not built — build.sh bug" >&2
    emit_ctrf "exfat-oracle(authored)" 0 1; exit 1
  fi
done

passed=0; failed=0
pass() { passed=$((passed+1)); echo "ok   - $1"; }
fail() { failed=$((failed+1)); echo "FAIL - $1" >&2; }
# assert that "$2" (a string) contains substring "$3"
contains() { case "$2" in *"$3"*) pass "$1" ;; *) fail "$1 (missing '$3')" ;; esac; }
# assert "$2" == "$3"
equals() { if [ "$2" = "$3" ]; then pass "$1"; else fail "$1 (got '$2' want '$3')"; fi; }

WORK="$(mktemp -d /tmp/exfat_test.XXXXXX)"
IMG="$WORK/fs.img"
dd if=/dev/zero of="$IMG" bs=1M count=16 status=none 2>/dev/null || dd if=/dev/zero of="$IMG" bs=1M count=16 2>/dev/null

# 1) mkexfatfs creates a filesystem successfully.
mk_out="$("$MKFS" -n MAYHEMFS "$IMG" 2>&1)"; mk_rc=$?
if [ "$mk_rc" -eq 0 ]; then pass "mkexfatfs creates a filesystem (rc=0)"; else fail "mkexfatfs rc=$mk_rc"; fi
contains "mkexfatfs reports success" "$mk_out" "created successfully"

# 2) dumpexfat reads geometry + the volume label back.
dump_out="$("$DUMP" "$IMG" 2>&1)"
contains "dumpexfat prints the volume label" "$dump_out" "Volume label"
contains "dumpexfat round-trips the label MAYHEMFS" "$dump_out" "MAYHEMFS"
contains "dumpexfat prints sector size" "$dump_out" "Sector size"
contains "dumpexfat prints cluster size" "$dump_out" "Cluster size"

# 3) exfatfsck validates the freshly-created filesystem.
fsck_out="$("$FSCK" "$IMG" 2>&1)"; fsck_rc=$?
if [ "$fsck_rc" -eq 0 ]; then pass "exfatfsck accepts a clean filesystem (rc=0)"; else fail "exfatfsck rc=$fsck_rc"; fi
contains "exfatfsck reports no errors" "$fsck_out" "No errors found"

# 4) exfatlabel reads the current label.
lbl="$("$LABEL" "$IMG" 2>/dev/null | tr -d '[:space:]')"
equals "exfatlabel reads back MAYHEMFS" "$lbl" "MAYHEMFS"

# 5) exfatlabel sets a new label and it persists (relabel round-trip).
"$LABEL" "$IMG" NEWLABEL >/dev/null 2>&1
lbl2="$("$LABEL" "$IMG" 2>/dev/null | tr -d '[:space:]')"
equals "exfatlabel writes+reads back NEWLABEL" "$lbl2" "NEWLABEL"
dump2="$("$DUMP" "$IMG" 2>&1)"
contains "dumpexfat sees the updated label" "$dump2" "NEWLABEL"

# 6) filesystem still consistent after the relabel write.
"$FSCK" "$IMG" >/dev/null 2>&1 && pass "exfatfsck still clean after relabel" || fail "exfatfsck failed after relabel"

rm -rf "$WORK"
emit_ctrf "exfat-oracle(authored)" "$passed" "$failed"
