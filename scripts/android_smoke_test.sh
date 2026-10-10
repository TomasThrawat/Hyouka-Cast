#!/usr/bin/env bash
set -euo pipefail

test -n "$GITHUB_WORKSPACE"
test -n "$ANDROID_HOME"

APK="$GITHUB_WORKSPACE/build/app/outputs/flutter-apk/app-release.apk"
DIAG="$GITHUB_WORKSPACE/ci-reports/emulator-smoke"
mkdir -p "$DIAG"

capture_failure() {
  result=$?
  trap - EXIT
  if (( result != 0 )); then
    timeout 12s adb logcat -d > "$DIAG/logcat-on-failure.txt" 2>&1 || true
    timeout 12s adb shell dumpsys activity activities > "$DIAG/activities-on-failure.txt" 2>&1 || true
    timeout 12s adb shell dumpsys package > "$DIAG/packages-on-failure.txt" 2>&1 || true
    timeout 12s adb shell screencap -p /sdcard/hyouka-smoke-failure.png >/dev/null 2>&1 || true
    timeout 12s adb pull /sdcard/hyouka-smoke-failure.png "$DIAG/screenshot-on-failure.png" >/dev/null 2>&1 || true
    echo "APK smoke test failed with exit code $result; diagnostics captured."
  fi
  exit "$result"
}
trap capture_failure EXIT

BUILD_TOOLS_VERSION="$(find "$ANDROID_HOME/build-tools" -mindepth 1 -maxdepth 1 -type d -printf '%f\n' | sort -V | tail -n1)"
AAPT="$ANDROID_HOME/build-tools/$BUILD_TOOLS_VERSION/aapt"
"$AAPT" dump badging "$APK" > "$DIAG/apk-badging.txt"
APP_ID="$(sed -n "s/^package: name='\([^']*\)'.*/\1/p" "$DIAG/apk-badging.txt" | head -n1)"
ACTIVITY="$(sed -n "s/^launchable-activity: name='\([^']*\)'.*/\1/p" "$DIAG/apk-badging.txt" | head -n1)"
test -n "$APP_ID" || { echo "::error::Could not determine the APK application ID."; exit 1; }

adb logcat -c
adb install -r "$APK"
if [[ -n "$ACTIVITY" ]]; then
  adb shell am start -W -n "$APP_ID/$ACTIVITY"
else
  adb shell monkey -p "$APP_ID" -c android.intent.category.LAUNCHER 1
fi
sleep 5
adb shell pidof "$APP_ID" > "$DIAG/application-pid.txt" || {
  echo "::error::APK application process did not stay alive after launch."
  exit 1
}
adb shell screencap -p /sdcard/hyouka-smoke-success.png
adb pull /sdcard/hyouka-smoke-success.png "$DIAG/screenshot-after-launch.png"
adb shell dumpsys package "$APP_ID" > "$DIAG/application-package.txt"
adb logcat -d -t 2000 > "$DIAG/logcat-after-launch.txt"
echo "Installed and launched $APP_ID successfully." | tee "$DIAG/result.txt"
trap - EXIT
