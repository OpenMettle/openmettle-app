"""Drive the Flutter web client and the stock Keycloak fixture in private Chrome."""

import json
from pathlib import Path
import sys


APPLICATION = "https://app.relying.test:18443"
ISSUER = "https://keycloak.provider.test:8443/realms/openmettle-qualification"
APP_SECONDS = 25

# Flutter exposes its controls and rendered labels through the semantics tree,
# inside open shadow roots. Enable semantics again after each new document.
SEMANTICS = """
function elements(root) {
    return [...root.querySelectorAll('*')].flatMap(
        element => [element, ...(element.shadowRoot ? elements(element.shadowRoot) : [])]);
}
const all = elements(document);
const matches = (element, label) =>
    element.getAttribute('aria-label')?.trim() === label ||
    element.textContent.trim() === label;
const text = label => all.some(
    element => element.tagName === 'FLT-SEMANTICS' && matches(element, label));
const button = label => all.find(
    element => element.getAttribute('role') === 'button' && matches(element, label));
const placeholder = all.find(element => element.tagName === 'FLT-SEMANTICS-PLACEHOLDER');
"""


def app_script(path, action):
    return f"""(() => {{
        if (location.href !== {json.dumps(APPLICATION + path)}) return false;
        {SEMANTICS}
        {action}
    }})()"""


def wait_app(browser, path, predicate, phase):
    browser.wait_for(app_script(path, f"return ({predicate});"), phase, APP_SECONDS)


def enable_semantics(browser, path, failure):
    wait_app(browser, path, "!!placeholder || text('OpenMettle')", "Flutter did not mount")
    if browser.evaluate(app_script(path, "placeholder?.click(); return true;")) is not True:
        raise failure("Flutter document changed before enabling semantics")


def click_app(browser, path, label, failure):
    action = f"""
        const control = button({json.dumps(label)});
        if (!control) return false;
        setTimeout(() => control.click(), 0);
        return true;
    """
    if browser.evaluate(app_script(path, action)) is not True:
        raise failure("Flutter action unavailable")


def provider_form(origin, realm):
    authorization = realm + "/protocol/openid-connect/auth"
    authenticate = realm + "/login-actions/authenticate"
    return f"""
        const origin = {json.dumps(origin)};
        const authenticate = {json.dumps(authenticate)};
        if (location.origin !== origin ||
            ![{json.dumps(authorization)}, authenticate].includes(location.pathname) ||
            document.readyState !== 'complete') return false;
        const username = document.getElementById('username');
        const password = document.getElementById('password');
        const submit = document.getElementById('kc-login');
        const form = username?.form;
        if (!(form instanceof HTMLFormElement) || form.method !== 'post' ||
            password?.form !== form ||
            password.type !== 'password' || submit?.form !== form ||
            submit.hasAttribute('formaction') || submit.hasAttribute('formmethod')) return false;
        const action = new URL(form.action);
        if (action.origin !== origin || action.pathname !== authenticate) return false;
    """


def sign_in(browser, provider, realm, account, keycloak, enter):
    guard = provider_form(provider, realm)
    phase = "provider login form did not load"
    keycloak.arrive(browser, APPLICATION, lambda: browser.wait_for(
        f"(() => {{ {guard} return true; }})()", phase, keycloak.PROVIDER_SECONDS), phase)
    enter("provider form submission")
    # Check the location and form destination again in the same evaluation
    # that enters the credentials. Never read the form or provider URL back.
    if browser.evaluate(f"""(() => {{
        {guard}
        username.value = {json.dumps(account['username'])};
        password.value = {json.dumps(account['password'])};
        setTimeout(() => submit.click(), 0);
        return true;
    }})()""") is not True:
        raise keycloak.Failure("provider form changed before submission")


def wait_http(browser, endpoint, status, phase):
    # Observe the Flutter request, without issuing a separate request that
    # could succeed even if Flutter never reached the API.
    wait_app(browser, "/app", f"""
        performance.getEntriesByName({json.dumps(APPLICATION + endpoint)}, 'resource')
            .some(entry => entry.responseStatus === {status} && entry.transferSize > 0)
    """, phase)


def signed_in(browser):
    wait_app(browser, "/app",
             "text('Signed in') && text('No capabilities were reported.') && !!button('Sign out')",
             "signed-in core-only capabilities did not render")
    wait_http(browser, "/v1/capabilities", 200, "live capabilities response was not HTTP 200")


def follow_run(browser, run_id, failure):
    # The driver supplies a state transition independently of the read-only
    # Flutter UI. Only the selected fixture run has a cancel route in nginx.
    path = "/v1/runs/" + run_id
    click_app(browser, "/app", "Open run", failure)
    field = """all.find(element => element instanceof HTMLInputElement
        && element.getAttribute('aria-label') === 'Run ID')"""
    wait_app(browser, "/app", f"!!button('View status') && !!{field}",
             "run ID form did not render")
    point = browser.evaluate(app_script("/app", f"""
        const rect = {field}?.getBoundingClientRect();
        if (!rect?.width || !rect.height) return false;
        return {{x: rect.x + rect.width / 2, y: rect.y + rect.height / 2}};
    """))
    if not isinstance(point, dict):
        raise failure("run ID field unavailable")
    for kind in ("mousePressed", "mouseReleased"):
        browser.call("Input.dispatchMouseEvent", type=kind, button="left", clickCount=1, **point)
    wait_app(browser, "/app", f"{field}?.matches(':focus')", "run ID field did not take focus")
    browser.call("Input.insertText", text=run_id)
    wait_app(browser, "/app", f"{field}?.value === {json.dumps(run_id)}",
             "run ID did not reach the text field")
    browser.call("Input.dispatchKeyEvent", type="keyDown", key="Enter", code="Enter",
                 windowsVirtualKeyCode=13, text="\r")
    browser.call("Input.dispatchKeyEvent", type="keyUp", key="Enter", code="Enter",
                 windowsVirtualKeyCode=13)
    wait_app(browser, "/app", "text('Queued')", "queued run snapshot did not render")
    wait_http(browser, path, 200, "run snapshot did not complete as HTTP 200")

    cancel = json.dumps(path + "/cancel")
    if browser.evaluate(app_script("/app", f"""
        return fetch({cancel}, {{method: 'POST', credentials: 'same-origin',
            mode: 'same-origin', redirect: 'error', referrerPolicy: 'same-origin',
            headers: {{'Idempotency-Key': 'qualification-cancel'}}
        }}).then(reply => reply.status === 200);
    """)) is not True:
        raise failure("core did not cancel the fixture run")
    wait_app(browser, "/app", "text('Run ended') && text('Cancelled')",
             "streamed cancellation did not render")
    click_app(browser, "/app", "Back", failure)
    signed_in(browser)


def reload_app(browser):
    # Let the predicate for the next document distinguish it from the old
    # document, whose signed-in controls may remain while reload commits.
    previous = browser.evaluate("performance.timeOrigin")
    browser.call("Page.reload", ignoreCache=True)
    browser.wait_for(
        f"performance.timeOrigin !== {json.dumps(previous)} && "
        "performance.getEntriesByType('navigation')[0]?.type === 'reload'",
        "app did not reload", APP_SECONDS)


def journey(browser, provider, realm, account, run_id, qualify, keycloak, enter):
    enter("signed-out Flutter landing")
    qualify.open_target(browser)
    browser.call("Page.navigate", url=APPLICATION + "/")
    enable_semantics(browser, "/", qualify.Failure)
    wait_app(browser, "/", "text('Sign in to view your capabilities.') && !!button('Sign in')",
             "signed-out landing did not render")

    enter("provider login form")
    click_app(browser, "/", "Sign in", qualify.Failure)
    sign_in(browser, provider, realm, account, keycloak, enter)

    enter("callback and signed-in Flutter landing")
    phase = "callback did not return to Flutter"
    keycloak.arrive(browser, APPLICATION, lambda: browser.wait_for(
        f"location.href === {json.dumps(APPLICATION + '/app')}", phase,
        keycloak.PROVIDER_SECONDS), phase)
    enable_semantics(browser, "/app", qualify.Failure)
    signed_in(browser)

    enter("signed-in reload")
    reload_app(browser)
    enable_semantics(browser, "/app", qualify.Failure)
    signed_in(browser)

    enter("Flutter run snapshot and event stream")
    follow_run(browser, run_id, qualify.Failure)

    enter("Flutter sign-out")
    click_app(browser, "/app", "Sign out", qualify.Failure)
    wait_app(browser, "/app", "text('Signed out') && !!button('Sign in')",
             "Flutter did not confirm sign-out")
    wait_http(browser, "/logout", 204, "live logout response was not HTTP 204")

    enter("signed-out reload")
    reload_app(browser)
    enable_semantics(browser, "/app", qualify.Failure)
    wait_app(browser, "/app", "text('Sign in to view your capabilities.') && !!button('Sign in')",
             "session remained signed in or could not be checked after reload")
    wait_http(browser, "/session", 403, "post-logout session response was not HTTP 403")


def fixture_account(directory, keycloak):
    with (directory / "accounts.json").open("rb") as source:
        raw = source.read(keycloak.MAX_INPUT_BYTES + 1)
    try:
        if len(raw) > keycloak.MAX_INPUT_BYTES:
            raise ValueError
        account = json.loads(raw)["approved"]
        if (account["username"] != "synthetic-approved"
                or account["subject"] != "00000000-0000-4000-8000-0000000000a1"
                or not isinstance(account["password"], str)
                or not account["password"]):
            raise ValueError
    except (KeyError, TypeError, ValueError):
        raise keycloak.Failure("approved fixture account invalid") from None
    return account


def run(directory, app_ca, run_id, qualify, keycloak, home, enter):
    enter("fixture input")
    account = fixture_account(directory, keycloak)
    _, app_host, _, _ = keycloak.site(APPLICATION, path_allowed=False)
    provider, host, port, realm = keycloak.site(ISSUER, path_allowed=True)
    address = keycloak.provider_address(host, port)
    qualify.drive(
        lambda browser: journey(browser, provider, realm, account, run_id, qualify, keycloak, enter),
        [app_ca.read_bytes(), (directory / "provider-ca.pem").read_bytes()],
        keycloak.resolver_rules(app_host, host, address), home, enter,
    )


def main():
    if len(sys.argv) != 5:
        sys.exit("usage: journey.py CORE_DIR FIXTURE_DIR APP_CA_PEM RUN_ID")
    core, directory, app_ca = map(Path, sys.argv[1:4])
    run_id = sys.argv[4]
    try:
        sys.path.insert(0, str(core.resolve() / "tests/browser"))
        import keycloak
        import qualify
    except Exception:
        sys.exit("core browser helpers unavailable")
    qualify.execute(lambda home, enter: run(directory, app_ca, run_id, qualify, keycloak, home, enter), 240)
    print("Flutter browser qualification passed")


if __name__ == "__main__":
    main()
