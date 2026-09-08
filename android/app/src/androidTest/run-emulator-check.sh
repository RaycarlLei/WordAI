#!/usr/bin/env bash
set -euo pipefail

# Called from the repository root on the fresh CI emulator, never a user device.
test "$(adb shell getprop ro.kernel.qemu | tr -d '\r')" = "1"
mkdir -p artifacts/android-backup
collect_results() {
  result=$?
  trap - EXIT
  timeout 30s adb pull /sdcard/Android/data/org.wordai.community.word_a_i/files/backup-test-artifacts artifacts/android-backup/ 2>/dev/null || true
  timeout 15s adb logcat -d -v threadtime AndroidRuntime:E '*:S' > artifacts/android-backup/android-runtime.log || true
  exit "$result"
}
trap collect_results EXIT
timeout --kill-after=30s 12m ./android/gradlew -p android :app:connectedDebugAndroidTest --no-daemon \
  -Pandroid.testInstrumentationRunnerArguments.class=org.wordai.community.word_a_i.BackupDocumentsTest \
  -Pandroid.testInstrumentationRunnerArguments.wordaiSyntheticEmulatorOnly=true
