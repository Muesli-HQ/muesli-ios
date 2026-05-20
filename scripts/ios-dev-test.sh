#!/usr/bin/env bash
set -euo pipefail

# Build, install, and launch the iOS dev app while preserving app data.
#
# Defaults to the booted simulator. Use --device-id to install on a connected
# iPhone. Reinstalling over the same bundle ID preserves the app container.
#
# Usage:
#   ./scripts/ios-dev-test.sh
#   ./scripts/ios-dev-test.sh --reset
#   ./scripts/ios-dev-test.sh --reset --reset-permissions
#   ./scripts/ios-dev-test.sh --device-id 00008140-001C6D2C11FA801C --reset

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCHEME="${MUESLI_IOS_SCHEME:-Muesli}"
BUNDLE_ID="${MUESLI_IOS_BUNDLE_ID:-com.phequals7.muesli.ios}"
SIMULATOR_NAME="${MUESLI_IOS_SIMULATOR_NAME:-iPhone 17 Pro}"
SIMULATOR_OS="${MUESLI_IOS_SIMULATOR_OS:-26.5}"
DEVICE_ID="${MUESLI_IOS_DEVICE_ID:-}"
DERIVED_DATA="${MUESLI_IOS_DERIVED_DATA:-/tmp/muesli-ios-dev-test-dd}"
RESET_ONBOARDING=0
RESET_PERMISSIONS=0
SKIP_BUILD=0
RESET_ARG="--muesli-reset-onboarding"

usage() {
  cat <<'EOF'
Build/install/launch Muesli iOS for dev testing without deleting app data.

Options:
  --simulator-name NAME   Simulator name. Default: iPhone 17 Pro
  --simulator-os VERSION  Simulator OS. Default: 26.5
  --device-id ID          Install on a connected iPhone instead of simulator.
  --reset                 Reset onboarding progress via debug launch argument.
  --reset-permissions     Reset simulator privacy permissions. Physical iPhone
                          privacy permissions cannot be reset non-destructively.
  --skip-build            Reuse the current DerivedData build product.
  --help                  Show this help text.
EOF
}

die() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

log() {
  printf '%s\n' "$*"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --simulator-name)
      [[ $# -ge 2 ]] || die "--simulator-name requires a value."
      SIMULATOR_NAME="$2"
      shift 2
      ;;
    --simulator-os)
      [[ $# -ge 2 ]] || die "--simulator-os requires a value."
      SIMULATOR_OS="$2"
      shift 2
      ;;
    --device-id)
      [[ $# -ge 2 ]] || die "--device-id requires a value."
      DEVICE_ID="$2"
      shift 2
      ;;
    --reset)
      RESET_ONBOARDING=1
      shift
      ;;
    --reset-permissions)
      RESET_PERMISSIONS=1
      shift
      ;;
    --skip-build)
      SKIP_BUILD=1
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

command -v xcodebuild >/dev/null 2>&1 || die "xcodebuild is required."
command -v xcrun >/dev/null 2>&1 || die "xcrun is required."

if [[ -z "$DEVICE_ID" ]]; then
  DESTINATION="platform=iOS Simulator,name=${SIMULATOR_NAME},OS=${SIMULATOR_OS}"
  PRODUCT_DIR="$DERIVED_DATA/Build/Products/Debug-iphonesimulator"
  APP_PATH="$PRODUCT_DIR/Muesli.app"

  if [[ "$SKIP_BUILD" -ne 1 ]]; then
    log "Building $SCHEME for simulator: $SIMULATOR_NAME ($SIMULATOR_OS)"
    xcodebuild build -scheme "$SCHEME" -destination "$DESTINATION" -derivedDataPath "$DERIVED_DATA"
  fi

  [[ -d "$APP_PATH" ]] || die "App product not found at $APP_PATH"

  log "Installing on booted simulator (data preserved)."
  xcrun simctl install booted "$APP_PATH"

  if [[ "$RESET_PERMISSIONS" -eq 1 ]]; then
    log "Resetting simulator privacy permissions for $BUNDLE_ID."
    xcrun simctl privacy booted reset all "$BUNDLE_ID"
  fi

  if [[ "$RESET_ONBOARDING" -eq 1 ]]; then
    log "Resetting onboarding via debug launch argument."
    xcrun simctl terminate booted "$BUNDLE_ID" >/dev/null 2>&1 || true
    xcrun simctl launch booted "$BUNDLE_ID" "$RESET_ARG" >/dev/null
  else
    log "Launching $BUNDLE_ID."
    xcrun simctl launch booted "$BUNDLE_ID" >/dev/null
  fi
else
  DESTINATION="id=${DEVICE_ID}"
  PRODUCT_DIR="$DERIVED_DATA/Build/Products/Debug-iphoneos"
  APP_PATH="$PRODUCT_DIR/Muesli.app"

  if [[ "$SKIP_BUILD" -ne 1 ]]; then
    log "Building $SCHEME for device: $DEVICE_ID"
    xcodebuild build -scheme "$SCHEME" -destination "$DESTINATION" -derivedDataPath "$DERIVED_DATA"
  fi

  [[ -d "$APP_PATH" ]] || die "App product not found at $APP_PATH"

  log "Installing on device $DEVICE_ID (data preserved)."
  xcrun devicectl device install app --device "$DEVICE_ID" "$APP_PATH"

  if [[ "$RESET_PERMISSIONS" -eq 1 ]]; then
    log "iOS does not expose a non-destructive CLI reset for physical-device privacy permissions."
    log "To reset microphone prompts on a physical iPhone, use Settings or delete/reinstall the app, which deletes app data."
  fi

  if [[ "$RESET_ONBOARDING" -eq 1 ]]; then
    log "Resetting onboarding via debug launch argument."
    xcrun devicectl device process launch --device "$DEVICE_ID" "$BUNDLE_ID" --terminate-existing "$RESET_ARG" >/dev/null
  else
    log "Launching $BUNDLE_ID."
    xcrun devicectl device process launch --device "$DEVICE_ID" "$BUNDLE_ID" >/dev/null
  fi
fi

log ""
log "=== iOS Dev Test Ready ==="
log "  Bundle: $BUNDLE_ID"
log "  Data:   preserved"
if [[ "$RESET_ONBOARDING" -eq 1 ]]; then
  log "  Onboarding: reset"
fi
