#!/bin/bash
# Verification for handing back work on this repo. See AGENTS.md "Verify before handing back"
# for what each step proves (compiles / runs / behaves) and what it does not cover.
#
# Exits non-zero on: build failure, test failure, or a test run that landed on a cloned
# Simulator instead of the named device. The failure message names which of the three happened.
set -uo pipefail

UDID="2D7326E3-8BFB-482C-ADB5-A449BD3E0CFD"
DEVICE_NAME="iPhone 17"
PROJECT="Sermiva.xcodeproj"
SCHEME="Sermiva"
DESTINATION="platform=iOS Simulator,name=${DEVICE_NAME}"
LOG_DIR="$(mktemp -d "${TMPDIR:-/tmp}/sermiva-verify.XXXXXX")"

fail() {
  echo "VERIFY FAILED: $1" >&2
  echo "Logs: ${LOG_DIR}" >&2
  exit 1
}

echo "Logs: ${LOG_DIR}"

echo "== Booting ${DEVICE_NAME} (${UDID}) =="
# `simctl boot` on an already-booted device exits non-zero with
# "Unable to boot device in current state: Booted" - that is expected, not a failure, so its
# exit status is intentionally not checked here.
xcrun simctl boot "$UDID"
xcrun simctl bootstatus "$UDID" -b
BOOT_EXIT=$?
[ "$BOOT_EXIT" -eq 0 ] || fail "could not bring ${DEVICE_NAME} to a booted, settled state (bootstatus exit ${BOOT_EXIT})"

# Starting a test run against a Simulator that has not been booted and settled first has been
# observed to fail with `Busy ("Application failed preflight checks")` on the named device itself
# (no clone involved) on 2 of 3 cold-start attempts; the third attempt passed, but xcodebuild then
# shut the Simulator back down on its own, which would otherwise read as a false clone signal in
# the checks below. No cause deeper than "starting from Shutdown is unreliable" was established -
# the boot + bootstatus wait above is what avoids this; there is no retry loop here on purpose.

echo "== Building =="
BUILD_LOG="${LOG_DIR}/build.log"
xcodebuild -project "$PROJECT" -scheme "$SCHEME" -sdk iphonesimulator \
  -destination "$DESTINATION" build 2>&1 | tee "$BUILD_LOG"
BUILD_EXIT=${PIPESTATUS[0]}
[ "$BUILD_EXIT" -eq 0 ] || fail "build failure (see ${BUILD_LOG})"

run_tests() {
  local TARGET="$1"
  local TEST_LOG="${LOG_DIR}/${TARGET}.log"
  echo "== Running ${TARGET} =="
  xcodebuild -project "$PROJECT" -scheme "$SCHEME" -sdk iphonesimulator \
    -destination "$DESTINATION" -only-testing:"$TARGET" test 2>&1 | tee "$TEST_LOG"
  local TEST_EXIT=${PIPESTATUS[0]}

  # A clone run happens if tests do not run under the committed shared scheme's
  # parallelizable="NO" setting (see AGENTS.md Verify section for why that scheme must not be
  # deleted). Do not trust the run's own .xcresult bundle to check this: its deviceName/deviceId fields
  # report the named Simulator even when the run actually happened on a clone. Clones also do not
  # show up in `xcrun simctl list devices` (the default device set) - they live in a separate
  # device set, `xcrun simctl --set testing list devices`.
  #
  # The two signals that actually distinguish a clone run, both checked below:
  #   1. log signature: a clone run's xcodebuild lines read
  #      "... passed on 'Clone N of iPhone 17 - ...'"; a named-device run's lines carry no
  #      "on '...'" at all.
  #   2. device state: the named device must still be Booted right after the run: a clone run
  #      leaves it Shutdown. This is only a valid signal because the boot/bootstatus step above
  #      already settled the named device before any test ran - otherwise a normal named-device
  #      run could also end Shutdown and look like a false clone signal.
  if grep -q "on 'Clone" "$TEST_LOG"; then
    fail "clone run ($TARGET ran on a cloned Simulator, not ${DEVICE_NAME} - see ${TEST_LOG})"
  fi

  local STATE
  STATE=$(xcrun simctl list devices | grep "$UDID" | sed -E 's/.*\(([A-Za-z]+)\)[^()]*$/\1/')
  if [ "$STATE" != "Booted" ]; then
    fail "clone run ($TARGET left ${DEVICE_NAME} in state '${STATE}' instead of Booted, meaning the run happened on a clone - see ${TEST_LOG})"
  fi

  # A genuine test failure can make xcodebuild take several extra minutes here collecting
  # diagnostics from the Simulator before it exits - that is xcodebuild's own behavior on a
  # failure, not this script hanging.
  [ "$TEST_EXIT" -eq 0 ] || fail "test failure ($TARGET - see ${TEST_LOG})"
}

run_tests SermivaTests
run_tests SermivaUITests

echo "== Verify passed: build, SermivaTests, SermivaUITests all ran on ${DEVICE_NAME} (${UDID}) =="
echo "Logs: ${LOG_DIR}"
