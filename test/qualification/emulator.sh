#!/usr/bin/env bash
# Start one disposable, writable Google APIs AVD. Keep all device data in runner scratch.
set -euo pipefail
[[ ${GITHUB_ACTIONS:-} == true && ${RUNNER_ENVIRONMENT:-} == github-hosted ]]
[[ $ANDROID_SERIAL == emulator-5554 && -c /dev/kvm && -n $RUNNER_TEMP ]]
export ANDROID_AVD_HOME="$RUNNER_TEMP/openmettle-avd"
mkdir -m 700 "$ANDROID_AVD_HOME"
image='system-images;android-31;google_apis;x86_64'
sdkmanager --install "$image" >/dev/null
echo no | avdmanager create avd --name om_api31 --package "$image" --device pixel_4 >/dev/null
# Ubuntu runners provide KVM. Grant the runner user access for this job.
sudo -n setfacl -m "u:$(id -un):rw" /dev/kvm
"$ANDROID_HOME/emulator/emulator" -accel-check
nohup "$ANDROID_HOME/emulator/emulator" -avd om_api31 -port 5554 -no-window -no-audio \
  -no-snapshot -no-boot-anim -gpu swiftshader_indirect -writable-system -memory 2048 \
  </dev/null >"$RUNNER_TEMP/openmettle-emulator.log" 2>&1 &
timeout 180 adb wait-for-device
booted() {
  timeout 240 bash -c 'until adb shell getprop sys.boot_completed 2>/dev/null | grep -qx 1; do sleep 2; done'
}
booted
[[ $(adb shell getprop ro.build.version.sdk) == 31 && $(adb shell getprop ro.debuggable) == 1 ]]
# The test CAs and synthetic DNS names belong to this AVD only. Mount the image's
# temporary writable overlay before installing them. The AVD is never snapshotted.
adb root
timeout 30 adb wait-for-device
adb disable-verity
adb reboot
timeout 90 adb wait-for-device
booted
adb root
timeout 30 adb wait-for-device
adb remount
adb shell pm path com.android.chrome | grep -q '^package:'
