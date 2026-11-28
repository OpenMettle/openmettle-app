#!/usr/bin/env bash
# Start one disposable, writable Android Open Source Project AVD. Keep all device data in runner scratch.
set -euo pipefail
trap 'printf "Emulator setup failed at line %s (exit %s)\n" "$LINENO" "$?" >&2' ERR
[[ ${GITHUB_ACTIONS:-} == true && ${RUNNER_ENVIRONMENT:-} == github-hosted ]]
[[ $ANDROID_SERIAL == emulator-5554 && -c /dev/kvm && -n $RUNNER_TEMP ]]
export ANDROID_AVD_HOME="$RUNNER_TEMP/openmettle-avd"
mkdir -m 700 "$ANDROID_AVD_HOME"
image='system-images;android-33;default;x86_64'
# The AOSP image includes StatementService, which fetches Digital Asset Links on the device.
# Keep installer diagnostics visible and let missing licenses fail the job.
sdkmanager --install "$image" </dev/null
avdmanager create avd --name om_qualification --package "$image" --device pixel_4 <<<no
# Ubuntu runners provide KVM. Grant the runner user access for this job.
sudo -n setfacl -m "u:$(id -un):rw" /dev/kvm
"$ANDROID_HOME/emulator/emulator" -accel-check
nohup "$ANDROID_HOME/emulator/emulator" -avd om_qualification -port 5554 -no-window -no-audio \
  -no-snapshot -no-boot-anim -gpu swiftshader_indirect -writable-system -memory 2048 \
  </dev/null >"$RUNNER_TEMP/openmettle-emulator.log" 2>&1 &
timeout 180 adb wait-for-device
booted() {
  timeout 240 bash -c 'until adb shell getprop sys.boot_completed 2>/dev/null | grep -qx 1; do sleep 2; done'
}
booted
[[ $(adb shell getprop ro.build.version.sdk) == 33 && $(adb shell getprop ro.debuggable) == 1 ]]
# The test CAs and synthetic DNS names belong to this AVD only. Mount the image's
# temporary writable overlay before installing them. The AVD is never snapshotted.
bash test/qualification/adb_root.sh
adb disable-verity
adb reboot
timeout 90 adb wait-for-device
booted
bash test/qualification/adb_root.sh
adb remount
adb shell pm path com.android.statementservice | grep -q '^package:'

# Install an external Chromium browser on the AOSP image. Verify the upstream archive
# before extracting the x86_64 APK. Chromium runs with the emulator's normal TLS trust.
archive="$RUNNER_TEMP/openmettle-chromium.zip"
apk="$RUNNER_TEMP/openmettle-chromium.apk"
curl --fail --silent --show-error --retry 2 --output "$archive" \
  https://storage.googleapis.com/chromium-browser-snapshots/AndroidDesktop_x64/1757019/chrome-android-desktop.zip
printf '%s  %s\n' e9993289dfa45042a48ba26f2845bf536f57ff5eb1210fbc1bb71c5500624456 "$archive" |
  sha256sum --check --status
unzip -p "$archive" chrome-android-desktop/apks/ChromePublic.apk >"$apk"
adb install "$apk" >/dev/null
adb shell pm path org.chromium.chrome | grep -q '^package:'
rm -- "$archive" "$apk"
