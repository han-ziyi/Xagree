#!/usr/bin/env bash
# Multi-destination xcodebuild test runner for XAgree.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PROJECT="$ROOT/性同意.xcodeproj"
SCHEME="性同意"
MATRIX_FILE="$ROOT/scripts/matrix-core.txt"

PROFILES=()
DEST_FILTER=""
FAIL_FAST=0

usage() {
  cat <<'EOF'
Usage: run-matrix.sh [options]

  --profile core|unit|ui|export   Destination set and/or suite (repeatable)
  --destination <name|udid>       Single destination only
  --fail-fast                     Stop on first failed destination
  -h, --help

Profiles:
  core    Destinations from scripts/matrix-core.txt (default if none given)
  unit    XAgreeTests only
  ui      XAgreeUITests only
  export  Export-related UI tests only
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --profile) PROFILES+=("$2"); shift 2 ;;
    --destination) DEST_FILTER="$2"; shift 2 ;;
    --fail-fast) FAIL_FAST=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown option: $1" >&2; usage; exit 2 ;;
  esac
done

want_core=0
want_unit=0
want_ui=0
want_export=0
for p in "${PROFILES[@]+"${PROFILES[@]}"}"; do
  case "$p" in
    core) want_core=1 ;;
    unit) want_unit=1 ;;
    ui) want_ui=1 ;;
    export) want_export=1; want_ui=1 ;;
    *) echo "Unknown profile: $p" >&2; exit 2 ;;
  esac
done

if [[ $want_unit -eq 0 && $want_ui -eq 0 ]]; then
  want_unit=1
  want_ui=1
fi
if [[ $want_core -eq 0 && -z "$DEST_FILTER" ]]; then
  want_core=1
fi

ONLY_TESTING=()
if [[ $want_export -eq 1 ]]; then
  ONLY_TESTING=(
    "-only-testing:XAgreeUITests/OnboardingUITests/testNativeExporterUsesEditableTimestampFilename"
    "-only-testing:XAgreeUITests/OnboardingUITests/testDualNativeExporterPresentsSaveSheet"
    "-only-testing:XAgreeUITests/OnboardingUITests/testExportCancelCreatesDraftAndReopens"
  )
elif [[ $want_ui -eq 1 && $want_unit -eq 0 ]]; then
  ONLY_TESTING=("-only-testing:XAgreeUITests")
elif [[ $want_unit -eq 1 && $want_ui -eq 0 ]]; then
  ONLY_TESTING=("-only-testing:XAgreeTests")
fi

# Resolve device name → udid. Prefer exact name match among available devices.
resolve_udid() {
  local query="$1"
  if [[ "$query" =~ ^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}$ ]]; then
    printf '%s\n' "$query"
    return 0
  fi
  local list
  list=$(xcrun simctl list devices available 2>/dev/null) || return 1

  # Prefer exact "Name (UUID)" — avoid "iPhone 15 Pro" matching "iPhone 15 Pro Max"
  local line
  line=$(printf '%s\n' "$list" | grep -E "[[:space:]]${query//./\\.} \\([0-9A-Fa-f-]{36}\\)" | head -1 || true)
  if [[ -z "$line" ]]; then
    line=$(printf '%s\n' "$list" | grep -F "${query} (" | grep -v "Pro Max" | head -1 || true)
  fi
  if [[ -z "$line" ]]; then
    return 1
  fi
  printf '%s\n' "$line" | sed -n 's/.*(\([0-9A-Fa-f-]\{36\}\)).*/\1/p' | head -1
}

# Build ordered label/udid pairs
LABELS=()
UDIDS=()
add_dest() {
  local label="$1"
  local query="$2"
  local udid
  udid=$(resolve_udid "$query" || true)
  if [[ -z "${udid:-}" ]]; then
    echo "WARN: skip unresolved: $label ($query)" >&2
    return 0
  fi
  # de-dupe udid
  local u
  for u in "${UDIDS[@]+"${UDIDS[@]}"}"; do
    if [[ "$u" == "$udid" ]]; then
      return 0
    fi
  done
  LABELS+=("$label")
  UDIDS+=("$udid")
}

if [[ -n "$DEST_FILTER" ]]; then
  add_dest "$DEST_FILTER" "$DEST_FILTER"
else
  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ -z "$line" || "$line" =~ ^[[:space:]]*# ]] && continue
    line=$(echo "$line" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
    [[ -z "$line" ]] && continue
    if [[ "$line" == *"|"* ]]; then
      label="${line%%|*}"
      query="${line#*|}"
      add_dest "$label" "$query"
    else
      add_dest "$line" "$line"
    fi
  done < "$MATRIX_FILE"
fi

if [[ ${#UDIDS[@]} -eq 0 ]]; then
  echo "No destinations resolved." >&2
  exit 1
fi

STAMP=$(date +%Y%m%d-%H%M%S)
OUT="$ROOT/build/test-runs/$STAMP"
mkdir -p "$OUT/logs" "$OUT/xcresults" "$OUT/derived"
REPORT="$OUT/REPORT.md"

{
  echo "# XAgree matrix run"
  echo
  echo "- Stamp: \`$STAMP\`"
  echo "- Profiles: ${PROFILES[*]:-(default unit+ui, core destinations)}"
  echo "- Unit=$want_unit UI=$want_ui ExportFilter=$want_export"
  echo "- Destinations: ${#UDIDS[@]}"
  echo
  echo "| # | Destination | UDID | Result | Exit | Log |"
  echo "|---|-------------|------|--------|------|-----|"
} > "$REPORT"

echo "Run stamp: $STAMP"
echo "Destinations: ${#UDIDS[@]}"
echo "Output: $OUT"

passed=0
failed=0
idx=0
for udid in "${UDIDS[@]}"; do
  label="${LABELS[$idx]}"
  safe=$(printf '%s' "$label" | tr -c 'A-Za-z0-9._-' '_' | cut -c1-72)
  log="$OUT/logs/${safe}.log"
  result_bundle="$OUT/xcresults/${safe}.xcresult"
  dd="$OUT/derived/${safe}"
  rm -rf "$result_bundle"
  mkdir -p "$dd"

  echo "==== [$idx] $label ($udid) ===="
  xcrun simctl boot "$udid" 2>/dev/null || true

  args=(
    test
    -project "$PROJECT"
    -scheme "$SCHEME"
    -destination "platform=iOS Simulator,id=$udid"
    -derivedDataPath "$dd"
    -resultBundlePath "$result_bundle"
  )
  if [[ ${#ONLY_TESTING[@]} -gt 0 ]]; then
    args+=("${ONLY_TESTING[@]}")
  fi

  set +e
  xcodebuild "${args[@]}" >"$log" 2>&1
  rc=$?
  set -e

  if [[ $rc -eq 0 ]]; then
    result="PASS"
    passed=$((passed + 1))
  else
    result="FAIL"
    failed=$((failed + 1))
  fi

  echo "| $idx | \`$label\` | \`$udid\` | **$result** | $rc | [log](logs/${safe}.log) |" >> "$REPORT"
  echo "→ $result (exit $rc)"

  if [[ $rc -ne 0 && $FAIL_FAST -eq 1 ]]; then
    echo "Fail-fast enabled; stopping." >&2
    break
  fi
  idx=$((idx + 1))
done

{
  echo
  echo "## Summary"
  echo
  echo "- Passed: **$passed**"
  echo "- Failed: **$failed**"
  echo "- Total: **$((passed + failed))**"
  echo
  if [[ $failed -gt 0 ]]; then
    echo "### Failure hints"
    echo
    echo '```'
    grep -h -E "error:|Test Case '.*' failed|\*\* TEST FAILED \*\*" "$OUT"/logs/*.log 2>/dev/null | tail -40 || true
    echo '```'
  fi
} >> "$REPORT"

echo
echo "Report: $REPORT"
echo "Passed=$passed Failed=$failed"

if [[ $failed -gt 0 ]]; then
  exit 1
fi
exit 0
