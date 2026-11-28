#!/usr/bin/env bash
# adbd can close its transport while restarting, even after sys.boot_completed.
set -euo pipefail
[[ ${GITHUB_ACTIONS:-} == true && ${RUNNER_ENVIRONMENT:-} == github-hosted &&
   ${ANDROID_SERIAL:-} == emulator-5554 ]]

for attempt in {1..6}; do
  if timeout 5 adb root && timeout 10 adb wait-for-device &&
      uid=$(timeout 5 adb shell id -u) && [[ $uid == 0 ]]; then
    exit 0
  fi
  if (( attempt < 6 )); then sleep 2; fi
done
echo 'Android emulator did not confirm root access after six attempts.' >&2
exit 1
