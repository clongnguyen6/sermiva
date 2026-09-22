#!/bin/bash
# Verification for handing back work on this repo. See AGENTS.md "Verify before handing back"
# for what each step proves (compiles / runs / behaves) and what it does not cover.
#
# Exits non-zero on: build failure, test failure, a test run whose log carries a clone signature,
# or the named Simulator (by UDID) turning up missing or not Booted afterward. The failure message
# names which one happened, without asserting more than what was actually observed.
#
# --device: additionally builds and installs (never launches, never starts a session) on the
# owner's iPhone "Long", pinned by UDID, with development signing. The default run below stays
# Simulator-only either way.
set -uo pipefail

UDID="2D7326E3-8BFB-482C-ADB5-A449BD3E0CFD"
DEVICE_NAME="iPhone 17"  # display label only - selection below is always pinned to UDID, not name
PHONE_UDID="00008101-000138D801F8001E"
PHONE_NAME="Long"  # display label only, same reasoning as DEVICE_NAME above
PROJECT="Sermiva.xcodeproj"
SCHEME="Sermiva"
# `id=` pins xcodebuild to this exact device. `name=` would match any device with a matching
# name - including a second, unrelated device that happens to share the name "iPhone 17".
DESTINATION="platform=iOS Simulator,id=${UDID}"
LOG_DIR="$(mktemp -d "${TMPDIR:-/tmp}/sermiva-verify.XXXXXX")"
WITH_DEVICE=0
for arg in "$@"; do
  [ "$arg" = "--device" ] && WITH_DEVICE=1
done

fail() {
  echo "VERIFY FAILED: $1" >&2
  echo "Logs: ${LOG_DIR}" >&2
  exit 1
}

# Reads a Simulator's current state (e.g. "Booted", "Shutdown", "Shutting Down") from
# `xcrun simctl list devices`. Sets $SIMCTL_LIST_FAILED=1 if the command itself failed to run, as
# opposed to the device simply not being listed - the two must not be reported as the same thing.
read_simulator_state() {
  local target_udid="$1"
  SIMCTL_LIST_FAILED=0
  local list_output
  if ! list_output=$(xcrun simctl list devices 2>&1); then
    SIMCTL_LIST_FAILED=1
    echo "$list_output" >&2
    STATE=""
    return
  fi
  # The state can be more than one word ("Shutting Down"), so the capture group must allow spaces.
  STATE=$(echo "$list_output" | grep "$target_udid" | sed -E 's/.*\(([A-Za-z ]+)\)[[:space:]]*$/\1/')
}

echo "Logs: ${LOG_DIR}"

echo "== Checking ${DEVICE_NAME} (${UDID}) =="
read_simulator_state "$UDID"
[ "$SIMCTL_LIST_FAILED" -eq 0 ] || fail "\`xcrun simctl list devices\` itself failed before booting - this says nothing about whether ${UDID} exists, see stderr above"
if [ "$STATE" = "Shutting Down" ]; then
  fail "${DEVICE_NAME} (${UDID}) is stuck \"Shutting Down\" - booting it now would race the in-progress shutdown; wait for it to reach Shutdown (or Booted), or run \`xcrun simctl shutdown ${UDID}\` yourself, then retry"
fi

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

  # A clone run happens when tests do not run under the committed shared scheme - see AGENTS.md's
  # Verify section for why that scheme must not be deleted. Do not trust the run's own .xcresult
  # bundle to check this: its deviceName/deviceId fields report the named Simulator even when the
  # run actually happened on a clone. Clones also do not show up in `xcrun simctl list devices`
  # (the default device set) - they live in a separate device set,
  # `xcrun simctl --set testing list devices`. The signal that actually distinguishes a clone run:
  # a clone run's xcodebuild lines read "... passed on 'Clone N of iPhone 17 - ...'"; a
  # named-device run's lines carry no "on '...'" at all.
  if grep -q "on 'Clone" "$TEST_LOG"; then
    fail "clone run ($TARGET ran on a cloned Simulator, not ${UDID} - see ${TEST_LOG})"
  fi

  # A genuine test failure can make xcodebuild take several extra minutes here collecting
  # diagnostics from the Simulator before it exits - that is xcodebuild's own behavior on a
  # failure, not this script hanging.
  [ "$TEST_EXIT" -eq 0 ] || fail "test failure ($TARGET - see ${TEST_LOG})"

  # No clone signature and a reported pass, but the device itself is now missing or not Booted:
  # something is still wrong, but it is not established to be a clone, so it is not reported as
  # one. A clone run does leave the named device Shutdown - but that signal is only meaningful
  # because the boot/bootstatus step above already settled the device as Booted before this test
  # ran. xcodebuild has also been observed to shut a named device down on its own (see the
  # boot-order comment above) even on a genuine named-device run, so "not Booted" alone does not
  # mean "clone" - it is reported as exactly that, not asserted to be a clone.
  read_simulator_state "$UDID"
  if [ "$SIMCTL_LIST_FAILED" -eq 1 ]; then
    fail "\`xcrun simctl list devices\` itself failed after running ${TARGET} - this says nothing about whether ${UDID} exists, see stderr above and ${TEST_LOG}"
  elif [ -z "$STATE" ]; then
    fail "Simulator ${UDID} is genuinely missing from \`xcrun simctl list devices\` after running ${TARGET} - see ${TEST_LOG}"
  elif [ "$STATE" != "Booted" ]; then
    fail "Simulator ${UDID} was left in state '${STATE}' (not Booted) after running ${TARGET} - not itself proof of a clone run, but the run is not trusted - see ${TEST_LOG}"
  fi
}

run_tests SermivaTests
run_tests SermivaUITests

echo "== Verify passed: build, SermivaTests, SermivaUITests all ran on ${DEVICE_NAME} (${UDID}) =="

if [ "$WITH_DEVICE" -eq 1 ]; then
  echo "== Building for ${PHONE_NAME} (${PHONE_UDID}) =="
  # Development signing under the owner's personal team, per AGENTS.md - CODE_SIGN_STYLE is
  # already Automatic in the project. This only builds and installs; it never launches the app and
  # never starts a session, per the outcome's hard constraints.
  DEVICE_BUILD_LOG="${LOG_DIR}/device-build.log"
  xcodebuild -project "$PROJECT" -scheme "$SCHEME" -sdk iphoneos \
    -destination "platform=iOS,id=${PHONE_UDID}" -allowProvisioningUpdates \
    build 2>&1 | tee "$DEVICE_BUILD_LOG"
  DEVICE_BUILD_EXIT=${PIPESTATUS[0]}
  [ "$DEVICE_BUILD_EXIT" -eq 0 ] || fail "device build failure for ${PHONE_NAME} - commonly a missing Apple account in Xcode, Developer Mode not enabled on the phone, or the Mac not yet trusted on it (all owner-only steps per AGENTS.md); see ${DEVICE_BUILD_LOG}"

  APP_PATH=$(xcodebuild -project "$PROJECT" -scheme "$SCHEME" -sdk iphoneos \
    -destination "platform=iOS,id=${PHONE_UDID}" -showBuildSettings 2>/dev/null \
    | awk -F'= ' '/ BUILT_PRODUCTS_DIR =/{print $2}')/Sermiva.app
  [ -d "$APP_PATH" ] || fail "built app not found at expected path ${APP_PATH}"

  echo "== Installing on ${PHONE_NAME} (${PHONE_UDID}) =="
  INSTALL_LOG="${LOG_DIR}/device-install.log"
  xcrun devicectl device install app --device "$PHONE_UDID" "$APP_PATH" 2>&1 | tee "$INSTALL_LOG"
  INSTALL_EXIT=${PIPESTATUS[0]}
  [ "$INSTALL_EXIT" -eq 0 ] || fail "install failure on ${PHONE_NAME} - the phone may be locked, unreachable, or not yet trusted; see ${INSTALL_LOG}"

  echo "== Installed on ${PHONE_NAME} (${PHONE_UDID}) - not launched, no session started =="
fi

echo "Logs: ${LOG_DIR}"
