#!/usr/bin/env bash
set -euo pipefail

# Reset iOS onboarding progress without deleting app data.
#
# Simulator:
#   ./scripts/ios-reset-onboarding.sh
#   ./scripts/ios-reset-onboarding.sh --reset-permissions
#
# Connected iPhone:
#   ./scripts/ios-reset-onboarding.sh --device-id 00008140-001C6D2C11FA801C

BUNDLE_ID="${MUESLI_IOS_BUNDLE_ID:-com.phequals7.muesli.ios}"
DEVICE_ID="${MUESLI_IOS_DEVICE_ID:-}"
RESET_PERMISSIONS=0
RESET_ARG="--muesli-reset-onboarding"

usage() {
  cat <<'EOF'
Reset Muesli iOS onboarding while preserving app data.

Options:
  --device-id ID        Target a connected iPhone. Defaults to booted simulator.
  --reset-permissions   Reset simulator privacy permissions too. Physical iPhone
                        permissions cannot be reset non-destructively by CLI.
  --help                Show this help text.
EOF
}

die() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --device-id)
      [[ $# -ge 2 ]] || die "--device-id requires a value."
      DEVICE_ID="$2"
      shift 2
      ;;
    --reset-permissions)
      RESET_PERMISSIONS=1
      shift
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    *)
      die "Unknown argument: $1"
      ;;
  esac
done

command -v xcrun >/dev/null 2>&1 || die "xcrun is required."

if [[ -z "$DEVICE_ID" ]]; then
  if [[ "$RESET_PERMISSIONS" -eq 1 ]]; then
    xcrun simctl privacy booted reset all "$BUNDLE_ID"
  fi
  xcrun simctl terminate booted "$BUNDLE_ID" >/dev/null 2>&1 || true
  xcrun simctl launch booted "$BUNDLE_ID" "$RESET_ARG" >/dev/null
else
  if [[ "$RESET_PERMISSIONS" -eq 1 ]]; then
    printf '%s\n' "Physical iPhone permission reset is not available non-destructively via CLI." >&2
    printf '%s\n' "Onboarding will still be reset and app data will be preserved." >&2
  fi
  xcrun devicectl device process launch --device "$DEVICE_ID" "$BUNDLE_ID" --terminate-existing "$RESET_ARG" >/dev/null
fi

printf '%s\n' "Onboarding reset requested for $BUNDLE_ID."
