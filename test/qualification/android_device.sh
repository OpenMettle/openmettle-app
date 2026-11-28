#!/usr/bin/env bash
# Called inside run.sh after the per-run fixture and HTTPS servers are ready.
set -euo pipefail
[[ ${GITHUB_ACTIONS:-} == true && ${RUNNER_ENVIRONMENT:-} == github-hosted &&
   ${ANDROID_SERIAL:-} == emulator-5554 && $(adb shell getprop ro.build.version.sdk) == 33 ]]
app_ca=$1 provider_ca=$2 provider_ip=$3 apk=$4
package=org.openmettle.app.debug
[[ $(adb shell id -u) == 0 && $provider_ip =~ ^[0-9]+(\.[0-9]+){3}$ ]]
# The app and domain verifier use system roots. Chromium reads locally installed
# roots from the Android user's certificate store alongside the Chrome Root Store.
browser_roots=/data/misc/user/0/cacerts-added
adb shell mkdir -p "$browser_roots"
adb shell chown system:system "$browser_roots"
adb shell chmod 755 "$browser_roots"
for ca in "$app_ca" "$provider_ca"; do
  hash=$(openssl x509 -in "$ca" -subject_hash_old -noout)
  [[ $hash =~ ^[0-9a-f]{8}$ ]]
  dest=/system/etc/security/cacerts/$hash.0
  adb shell test ! -e "$dest"
  adb push "$ca" "$dest" >/dev/null
  adb shell chmod 644 "$dest"
  adb shell restorecon "$dest"
  adb shell test ! -e "$browser_roots/$hash.0"
  adb shell cp "$dest" "$browser_roots/$hash.0"
  adb shell chown system:system "$browser_roots/$hash.0"
  adb shell chmod 644 "$browser_roots/$hash.0"
done
adb shell restorecon -RF "$browser_roots"
# Emulator 10.0.2.2 is the Linux host loopback. The app-link verifier uses standard
# HTTPS port 443, forwarded to the unprivileged association server on the runner.
adb shell 'cat >> /system/etc/hosts' <<HOSTS

10.0.2.2 app.relying.test
127.0.0.1 return.relying.test
$provider_ip keycloak.provider.test
HOSTS
adb reboot
timeout 120 adb wait-for-device
timeout 240 bash -c 'until adb shell getprop sys.boot_completed 2>/dev/null | grep -qx 1; do sleep 2; done'
bash test/qualification/adb_root.sh
adb reverse tcp:443 tcp:18444
adb shell input keyevent KEYCODE_WAKEUP
adb shell wm dismiss-keyguard
adb shell cmd role add-role-holder android.app.role.BROWSER org.chromium.chrome
# Chromium's first-run onboarding is outside the sign-in journey. Leave TLS checks enabled.
adb shell am set-debug-app --persistent org.chromium.chrome
adb shell 'echo "chrome --disable-fre --no-first-run --no-default-browser-check" > /data/local/tmp/chrome-command-line'
adb install -t "$apk" >/dev/null
adb shell pm verify-app-links --re-verify "$package"
for _ in $(seq 90); do
  if adb shell pm get-app-links "$package" | grep -Eq '^ +return\.relying\.test: verified[[:space:]]*$'; then
    echo 'Android verified the HTTPS App Link against the installed signing certificate.'
    exit 0
  fi
  sleep 2
done
echo 'Android did not verify the app-link host.' >&2
adb shell pm get-app-links "$package" | grep -E '^ +return\.relying\.test: [[:alnum:]_]+$' >&2 || true
exit 1
