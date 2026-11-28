"""Drive the installed Flutter app and Android's external Chrome through real sign-in."""
import http.client
import json
import re
import signal
import subprocess
import sys
import time
import xml.etree.ElementTree as ET
from pathlib import Path

from android_fixture import APP_ID, ISSUER
from journey import fixture_account, provider_form

CHROME = "com.android.chrome"
PROVIDER = "https://keycloak.provider.test:8443"
REALM = "/realms/openmettle-qualification"


class Failure(Exception):
    pass


def adb(*args):
    result = subprocess.run(["adb", *args], capture_output=True, timeout=15)
    if result.returncode:
        raise Failure("Android device command failed")
    return result.stdout


def app_control(label, *, tap=False):
    deadline = time.monotonic() + 55
    while time.monotonic() < deadline:
        # Query Android's foreground app without writing activity intents or view dumps to CI.
        activities = adb("shell", "dumpsys", "activity", "activities")
        if not re.search(rb"(?:mResumedActivity:|topResumedActivity[=:]).*? " + re.escape(APP_ID.encode()) + rb"/", activities):
            time.sleep(0.4)
            continue
        raw = adb("exec-out", "uiautomator", "dump", "/dev/tty")
        start, end = raw.find(b"<?xml"), raw.rfind(b"</hierarchy>")
        if start >= 0 and end > start:
            tree = ET.fromstring(raw[start:end + len(b"</hierarchy>")])
            for node in tree.iter("node"):
                attr = node.attrib
                if attr.get("package") != APP_ID or label not in (attr.get("text"), attr.get("content-desc")):
                    continue
                if tap:
                    bounds = re.fullmatch(r"\[(\d+),(\d+)\]\[(\d+),(\d+)\]", attr["bounds"])
                    if not bounds or attr.get("enabled") != "true":
                        raise Failure("Flutter control is unavailable")
                    left, top, right, bottom = map(int, bounds.groups())
                    adb("shell", "input", "tap", str((left + right) // 2), str((top + bottom) // 2))
                return
        time.sleep(0.4)
    raise Failure("Flutter control did not appear")


def start_app():
    # A launcher intent contains no callback data. Only Chrome can supply the return link.
    adb("shell", "am", "start", "-a", "android.intent.action.MAIN",
        "-c", "android.intent.category.LAUNCHER", "-p", APP_ID)


class Page:
    def __init__(self, ws):
        self.ws = ws
        self.ordinal = 0

    def call(self, method, **params):
        self.ordinal += 1
        self.ws.send(json.dumps({"id": self.ordinal, "method": method, "params": params}))
        while True:
            msg = json.loads(self.ws.recv())
            if msg.get("id") == self.ordinal:
                if "error" in msg:
                    raise Failure("Android Chrome refused a browser action")
                return msg["result"]

    def evaluate(self, script):
        reply = self.call("Runtime.evaluate", expression=script, returnByValue=True, userGesture=True)
        if "exceptionDetails" in reply:
            raise Failure("Android Chrome page action failed")
        return reply["result"].get("value")

    def press(self, script):
        pos = self.evaluate(script)
        if not isinstance(pos, list) or len(pos) != 2:
            raise Failure("browser form or origin changed")
        self.call("Input.dispatchTouchEvent", type="touchStart", touchPoints=[{"x": pos[0], "y": pos[1]}])
        self.call("Input.dispatchTouchEvent", type="touchEnd", touchPoints=[])


def wait_page(port, expected, websocket):
    deadline = time.monotonic() + 50
    while time.monotonic() < deadline:
        conn = http.client.HTTPConnection("127.0.0.1", port, timeout=3)
        try:
            conn.request("GET", "/json/list")
            targets = json.loads(conn.getresponse().read(256 * 1024))
        except (OSError, ValueError, http.client.HTTPException):
            targets = []
        finally:
            conn.close()
        for target in targets:
            if target.get("type") != "page" or not re.fullmatch("[A-Za-z0-9]+", target.get("id", "")):
                continue
            # Use the local ADB forward and target ID, never a URL supplied by page content.
            ws = websocket.create_connection(f"ws://127.0.0.1:{port}/devtools/page/{target['id']}",
                                             timeout=5, suppress_origin=True)
            page = Page(ws)
            if page.evaluate("(() => {" + expected + " return true; })()") is True:
                return page
            ws.close()
        time.sleep(0.3)
    raise Failure("expected external browser page did not appear")


def run(fixture, core):
    import websocket  # Ubuntu's python3-websocket, used only by the hosted test.
    sys.path.insert(0, str(core / "tests/browser"))
    import keycloak

    account = fixture_account(fixture, keycloak)
    port = int(adb("forward", "tcp:0", "localabstract:chrome_devtools_remote"))
    print("Android journey: Flutter sign-in", flush=True)
    start_app()
    app_control("Sign in", tap=True)
    confirmation = f"""
        if (location.origin !== {json.dumps(ISSUER)} || location.pathname !== '/auth/native/authorize')
            return false;
        const submit = document.querySelector('#confirm');
        if (submit?.form?.method !== 'post' || submit.form.action !== location.href) return false;
    """
    # Native touch input keeps browser user activation across the form submission and redirect.
    position = """
        submit.scrollIntoView({block:'center'});
        const r = submit.getBoundingClientRect();
        return [r.x+r.width/2, r.y+r.height/2];
    """
    print("Android journey: confirmation in system Chrome", flush=True)
    page = wait_page(port, confirmation, websocket)
    page.press("(() => {" + confirmation + position + "})()")
    page.ws.close()
    print("Android journey: Keycloak sign-in", flush=True)
    guard = provider_form(PROVIDER, REALM)
    page = wait_page(port, guard, websocket)
    page.press("(() => {" + guard +
               f"username.value={json.dumps(account['username'])};password.value={json.dumps(account['password'])};" +
               position + "})()")
    page.ws.close()
    print("Android journey: OS callback to Flutter and authenticated capabilities", flush=True)
    app_control("No capabilities were reported.")
    print("Android journey: restore session after process restart", flush=True)
    adb("shell", "am", "force-stop", APP_ID)
    start_app()
    app_control("No capabilities were reported.")
    print("Android journey: logout", flush=True)
    app_control("Sign out", tap=True)
    app_control("Signed out")
    adb("shell", "am", "force-stop", APP_ID)
    start_app()
    app_control("Sign in to view your capabilities.")


if __name__ == "__main__":
    signal.alarm(360)
    try:
        run(Path(sys.argv[1]), Path(sys.argv[2]))
    except Failure as exc:
        sys.exit(str(exc))
    except Exception:
        # ADB and Chrome replies can contain provider URLs and credentials.
        sys.exit("Android journey failed during the last recorded phase")
