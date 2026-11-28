#!/usr/bin/env bash
# Hosted CI only: qualify the compiled Flutter web client and Android APK against openmettle-api
# binary, a migrated PostgreSQL 18 database and stock pinned Keycloak 26.8.2, all on one
# disposable GitHub-hosted Linux runner. Never run it against an operator system: it creates
# PostgreSQL roles, a Docker network and container, and an /etc/hosts entry, and removes only
# what this invocation created.
#
# Run from the app repository root with these set by the workflow:
#   CORE_DIR            core checkout at the pin in test/fixtures/core/MANIFEST, with
#                       target/debug/openmettle-api and target/debug/openmettle-migrate built
#   APP_WEB_DIR         `flutter build web` output (base href /)
#   APP_APK             debug APK for the emulator started by emulator.sh
#   RUNNER_TEMP         runner scratch directory
#   POSTGRES_CONTAINER  job PostgreSQL 18 service on 127.0.0.1:5432, superuser `fixture`
#   PROVIDER_IMAGE      Keycloak 26.8.2 image pinned by digest
#
# Output is fixed phase names and fixed failure labels. Database passwords, the login key,
# account passwords, codes, cookies and request targets are never printed.
set -euo pipefail
umask 077

readonly APP_HOST=app.relying.test
readonly APP_PORT=18443
readonly APP_ORIGIN="https://$APP_HOST:$APP_PORT"
readonly API_ADDRESS=127.0.0.1:18080
readonly PROVIDER_HOST=keycloak.provider.test
readonly PROVIDER_VERSION=26.8.2
readonly ROLES=(openmettle_owner openmettle_api openmettle_issuance openmettle_gateway openmettle_worker)
readonly HERE=test/qualification

current_phase=preflight
failure_reported=false
work=""
database=""
provider_container=""
provider_network=""
hosts_line=""
api_pid=""
nginx_started=false
declare -A passwords=()

phase() {
  current_phase=$1
  printf 'Qualification phase: %s\n' "$1"
}

fail() {
  failure_reported=true
  printf 'Qualification failed: %s\n' "$1" >&2
  exit 1
}

# True when a known database password occurs in FILE. printf is a builtin, so the patterns
# never appear in a process argument list.
disclosed() {
  ((${#passwords[@]} > 0)) && grep -qF -f <(printf '%s\n' "${passwords[@]}") -- "$1"
}

superuser_psql() {
  timeout 60 docker exec -i "$POSTGRES_CONTAINER" \
    psql -X -q -v ON_ERROR_STOP=1 -U fixture -d fixture "$@"
}

# The owner session over the service container's loopback with password authentication, as
# core's operator-script transport does. The password travels in the environment only.
owner_psql() {
  PGPASSWORD=${passwords[openmettle_owner]} timeout 60 docker exec -i -e PGPASSWORD \
    "$POSTGRES_CONTAINER" psql -X -q -h 127.0.0.1 -U openmettle_owner -d "$database" "$@"
}

role_url() {
  printf 'postgres://%s:%s@127.0.0.1:5432/%s?sslmode=disable' "$1" "${passwords[$1]}" "$database"
}

# Runs a core binary with only the settings given here: no inherited OPENMETTLE_* or PG*
# value can change its configuration.
core_env() {
  local name
  while read -r name; do
    unset "$name"
  done < <(compgen -e | grep -E '^(OPENMETTLE_|PG)' || true)
}

cleanup() {
  local status=$?
  trap - EXIT
  set +e
  if ((status != 0)) && [[ $failure_reported == false ]]; then
    printf 'Qualification failed: unexpected error during phase: %s (exit %s)\n' \
      "$current_phase" "$status" >&2
  fi
  printf 'Qualification phase: cleanup\n'
  if [[ -n $api_pid ]]; then
    kill "$api_pid" 2>/dev/null
    timeout 10 tail --pid="$api_pid" -f /dev/null 2>/dev/null || kill -9 "$api_pid" 2>/dev/null
    wait "$api_pid" 2>/dev/null
  fi
  if [[ $nginx_started == true && -s $work/nginx/nginx.pid ]]; then
    kill "$(cat "$work/nginx/nginx.pid")" 2>/dev/null
  fi
  # GitHub Actions disposes of the job service with its database and roles.
  if [[ -n $provider_container ]]; then
    # Container state only; the provider runs without a log driver.
    docker inspect --format 'provider state={{.State.Status}} exit={{.State.ExitCode}} oom={{.State.OOMKilled}}' \
      "$provider_container" 2>/dev/null
    docker rm --force "$provider_container" >/dev/null 2>&1
  fi
  if [[ -n $provider_network ]]; then
    docker network rm "$provider_network" >/dev/null 2>&1
  fi
  if [[ -n $hosts_line ]]; then
    local escaped=${hosts_line//./\\.}
    sudo -n sed -i "/^${escaped}\$/d" /etc/hosts ||
      printf 'Cleanup warning: provider hosts entry not removed\n' >&2
  fi
  if [[ -n $work ]]; then
    rm -rf -- "$work"
  fi
  exit "$status"
}

# --- Preflight -----------------------------------------------------------------------------
phase "preflight"
if [[ ${GITHUB_ACTIONS:-} != true || ${RUNNER_ENVIRONMENT:-} != github-hosted || $(uname -s) != Linux ]]; then
  fail "provisions only on a disposable GitHub-hosted Linux runner"
fi
for name in CORE_DIR APP_WEB_DIR APP_APK RUNNER_TEMP POSTGRES_CONTAINER PROVIDER_IMAGE; do
  [[ -n ${!name:-} ]] || fail "$name is required"
done
[[ -f $HERE/run.sh && -f test/fixtures/core/MANIFEST ]] || fail "run from the app repository root"
for tool in docker python3 openssl nginx curl certutil google-chrome sudo timeout git; do
  command -v "$tool" >/dev/null || fail "required runner tool missing: $tool"
done
sudo -n true 2>/dev/null || fail "runner sudo is unavailable for the provider hosts entry"
[[ $PROVIDER_IMAGE =~ ^[a-z0-9./-]+@sha256:[0-9a-f]{64}$ ]] ||
  fail "PROVIDER_IMAGE must be pinned by digest"

core_pin=$(sed -n '/^[0-9a-f]\{40\}$/p' test/fixtures/core/MANIFEST)
[[ $core_pin =~ ^[0-9a-f]{40}$ ]] || fail "core pin missing from test/fixtures/core/MANIFEST"
[[ $(git -C "$CORE_DIR" rev-parse HEAD 2>/dev/null) == "$core_pin" ]] ||
  fail "CORE_DIR is not the pinned core revision"
api_bin=$CORE_DIR/target/debug/openmettle-api
migrate_bin=$CORE_DIR/target/debug/openmettle-migrate
[[ -x $api_bin && -x $migrate_bin ]] ||
  fail "core binaries missing: build openmettle-api and openmettle-migrate in CORE_DIR"
for helper in tests/keycloak/fixture.py tests/browser/keycloak.py tests/browser/qualify.py \
  docs/operator/first-identity-approval.psql; do
  [[ -f $CORE_DIR/$helper ]] || fail "core helper missing: $helper"
done

# NGINX reads these paths from its configuration file, so only plain characters are accepted.
web=$(cd "$APP_WEB_DIR" 2>/dev/null && pwd -P) || fail "APP_WEB_DIR is not a directory"
temp=$(cd "$RUNNER_TEMP" 2>/dev/null && pwd -P) || fail "RUNNER_TEMP is not a directory"
for path in "$web" "$temp"; do
  [[ $path =~ ^/[A-Za-z0-9._/-]+$ ]] || fail "APP_WEB_DIR and RUNNER_TEMP need plain absolute paths"
done
[[ -f $web/index.html && -f $web/flutter_bootstrap.js && -f $web/main.dart.js ]] ||
  fail "APP_WEB_DIR is not a Flutter web build"
grep -qF '<base href="/">' "$web/index.html" || fail "Flutter build must use base href /"
wasm=$(cd "$web" && find . -type f -name '*.wasm' -print | sed -n '1s|^\./||p')
[[ -n $wasm && $wasm =~ ^[A-Za-z0-9._/-]+$ ]] ||
  fail "Flutter build has no bundled WebAssembly (build with --no-web-resources-cdn)"

trap cleanup EXIT
trap 'exit 143' TERM
trap 'exit 130' INT
work=$(mktemp -d "$temp/openmettle-app-qualification.XXXXXXXX")
suffix=$(openssl rand -hex 6)
database=om_app_qualification_$suffix
fixture=$work/keycloak
app_ca=$work/app-ca.pem
api_log=$work/api.log

# --- Provider ------------------------------------------------------------------------------
phase "pinned Keycloak image"
timeout 300 docker pull --quiet "$PROVIDER_IMAGE" >/dev/null || fail "Keycloak image pull failed"
version=$(docker image inspect --format '{{index .Config.Labels "org.opencontainers.image.version"}}' "$PROVIDER_IMAGE")
[[ $version == "$PROVIDER_VERSION" ]] || fail "Keycloak image is not version $PROVIDER_VERSION"

phase "provider fixture"
python3 "$CORE_DIR/tests/keycloak/fixture.py" prepare --directory "$fixture" ||
  fail "core Keycloak fixture prepare failed"

python3 "$HERE/android_fixture.py" realm "$fixture/import/realm.json"

phase "isolated provider network and container"
network_name=openmettle-app-qualification-$suffix
provider_network=$(timeout 30 docker network create --internal "$network_name") ||
  fail "internal provider network not created"
provider_container=$(timeout 60 docker create \
  --network "$provider_network" \
  --log-driver none \
  --cap-drop ALL --security-opt no-new-privileges \
  --volume "$fixture/provider:/etc/keycloak-tls:ro" \
  --volume "$fixture/import:/opt/keycloak/data/import:ro" \
  "$PROVIDER_IMAGE" \
  start \
  --db=dev-file \
  --cache=local \
  --http-enabled=false \
  --https-port=8443 \
  --https-certificate-file=/etc/keycloak-tls/tls-certificate.pem \
  --https-certificate-key-file=/etc/keycloak-tls/tls-key.pem \
  --hostname="https://$PROVIDER_HOST:8443" \
  --import-realm) || fail "Keycloak container not created"
timeout 60 docker start "$provider_container" >/dev/null || fail "Keycloak container did not start"

phase "provider name and auth settings"
address=$(docker inspect --format "{{with index .NetworkSettings.Networks \"$network_name\"}}{{.IPAddress}}{{end}}" "$provider_container")
[[ $address =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]] || fail "provider container has no network address"
getent hosts "$PROVIDER_HOST" >/dev/null && fail "$PROVIDER_HOST already resolves on this runner"
printf '%s %s\n' "$address" "$PROVIDER_HOST" | sudo -n tee -a /etc/hosts >/dev/null ||
  fail "provider hosts entry not written"
hosts_line="$address $PROVIDER_HOST"
python3 "$CORE_DIR/tests/keycloak/fixture.py" settings --directory "$fixture" --address "$address" ||
  fail "core auth settings refused the provider address"
python3 "$HERE/android_fixture.py" settings "$fixture/auth-settings.json"
(core_env && exec timeout 30 "$api_bin" --check-auth-config "$fixture/auth-settings.json") ||
  fail "openmettle-api refused the auth settings document"
IFS=$'\t' read -r provider_id issuer client_id revision origin landing < <(
  python3 -I - "$fixture/auth-settings.json" <<'PY'
import json, sys
document = json.load(open(sys.argv[1], encoding="utf-8"))
provider = document["providers"][0]
print("\t".join([provider["id"], provider["issuer"], provider["client_id"], provider["revision"],
                 document["browser"]["origin"], document["browser"]["landing_path"]]))
PY
) || fail "auth settings document unreadable"
[[ $origin == "$APP_ORIGIN" && $landing == /app ]] ||
  fail "core fixture origin or landing path differs from this harness"
subject=$(python3 -I -c 'import json, sys; print(json.load(open(sys.argv[1]))["approved"]["subject"])' \
  "$fixture/accounts.json") || fail "fixture accounts unreadable"

# --- Database ------------------------------------------------------------------------------
phase "PostgreSQL service"
for _ in $(seq 30); do
  timeout 10 docker exec "$POSTGRES_CONTAINER" pg_isready -q -U fixture -d fixture && break
  sleep 2
done
timeout 10 docker exec "$POSTGRES_CONTAINER" pg_isready -q -U fixture -d fixture ||
  fail "PostgreSQL service not ready"
[[ $(superuser_psql -tA -c 'SHOW server_version_num') == 18* ]] ||
  fail "PostgreSQL service is not version 18"

phase "database roles and per-run database"
existing=$(superuser_psql -tA -c "SELECT count(*) FROM pg_roles WHERE rolname LIKE 'openmettle\\_%'")
[[ $existing == 0 ]] || fail "openmettle roles already exist: use a fresh disposable PostgreSQL service"
for role in "${ROLES[@]}"; do
  passwords[$role]=$(openssl rand -hex 24)
done
# Statements reach psql on stdin. Error statements are kept out of the server log for this
# session, and psql errors are discarded, so a password cannot reach service logs or output.
{
  printf "SET log_min_error_statement = 'panic';\nSET log_statement = 'none';\n"
  for role in "${ROLES[@]}"; do
    printf "CREATE ROLE %s LOGIN PASSWORD '%s';\n" "$role" "${passwords[$role]}"
  done
} | superuser_psql >/dev/null 2>&1 || fail "database roles not created"
superuser_psql -c "CREATE DATABASE $database OWNER openmettle_owner" >/dev/null ||
  fail "qualification database not created"

phase "production migrations"
migrate_log=$work/migrate.log
if ! (core_env && OPENMETTLE_MIGRATE_DATABASE_URL=$(role_url openmettle_owner) exec timeout 120 "$migrate_bin") \
  >"$migrate_log" 2>&1; then
  fail "openmettle-migrate failed"
fi
disclosed "$migrate_log" && fail "openmettle-migrate output disclosed a credential"
grep -E '^schema is at migration [0-9]+$' "$migrate_log" || fail "openmettle-migrate did not report the schema"

phase "provider registration and synthetic identity"
seed_log=$work/seed.log
seeded=$(owner_psql -v provider="$provider_id" -v issuer="$issuer" -v client_id="$client_id" \
  -v revision="$revision" -v subject="$subject" -f - <"$HERE/seed.psql" 2>"$seed_log") || {
  fail "qualification seed refused"
}
[[ $seeded == "qualification identity seeded" && ! -s $seed_log ]] ||
  fail "qualification seed output unexpected"

phase "first identity approval (core operator script)"
expires_ms=$(owner_psql -tA -c 'SELECT floor(extract(epoch FROM clock_timestamp())*1000)::bigint + 1800000') ||
  fail "database clock unavailable"
approval_log=$work/approval.log
approved=$(owner_psql -v provider="$provider_id" -v issuer="$issuer" -v subject="$subject" \
  -v expires_ms="$expires_ms" -v actor=fixture-operator \
  -v reason="keycloak qualification first approval" \
  -f - <"$CORE_DIR/docs/operator/first-identity-approval.psql" 2>"$approval_log") || {
  fail "first identity approval refused"
}
[[ $approved == "first approval committed" && ! -s $approval_log ]] ||
  fail "first identity approval output unexpected"

# --- Application origin --------------------------------------------------------------------
phase "application test CA and certificate"
tls=$work/app-tls
mkdir -m 700 "$tls"
cat >"$tls/openssl.cnf" <<EOF
[req]
distinguished_name = subject
prompt = no
[subject]
CN = OpenMettle app qualification
[authority]
basicConstraints = critical, CA:TRUE, pathlen:0
keyUsage = critical, keyCertSign
subjectKeyIdentifier = hash
[leaf]
basicConstraints = critical, CA:FALSE
keyUsage = critical, digitalSignature, keyEncipherment
extendedKeyUsage = serverAuth
subjectAltName = DNS:$APP_HOST,DNS:return.relying.test
authorityKeyIdentifier = keyid
EOF
{
  openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:2048 -out "$tls/ca-key.pem" &&
    openssl req -new -x509 -key "$tls/ca-key.pem" -sha256 -days 2 -config "$tls/openssl.cnf" \
      -extensions authority -subj "/CN=OpenMettle app qualification CA" -out "$app_ca" &&
    openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:2048 -out "$tls/key.pem" &&
    openssl req -new -key "$tls/key.pem" -config "$tls/openssl.cnf" -subj "/CN=$APP_HOST" \
      -out "$tls/leaf.csr" &&
    openssl x509 -req -in "$tls/leaf.csr" -CA "$app_ca" -CAkey "$tls/ca-key.pem" -set_serial 2 \
      -sha256 -days 2 -extfile "$tls/openssl.cnf" -extensions leaf -out "$tls/certificate.pem"
} >/dev/null 2>&1 || fail "openssl refused an application certificate step"
# The CA signs one certificate for this run and is then removed.
rm -f -- "$tls/ca-key.pem" "$tls/leaf.csr" "$tls/openssl.cnf"

phase "Android debug APK signing association"
signer=$(find "$ANDROID_HOME/build-tools" -name apksigner | sort -V | tail -1)
[[ -x $signer && -f $APP_APK ]] || fail "Android APK or signer tool missing"
if ! "$signer" verify --print-certs-pem "$APP_APK" |
  python3 "$HERE/android_fixture.py" assetlinks >"$work/assetlinks.json"; then
  fail "could not verify the APK and associate its signing certificate"
fi

phase "NGINX application origin"
mkdir -m 700 "$work/nginx"
config=$(<"$HERE/nginx.conf.template")
config=${config//@WORK@/$work}
config=${config//@WEB@/$web}
config=${config//@API@/$API_ADDRESS}
printf '%s\n' "$config" >"$work/nginx/nginx.conf"
nginx_args=(-p "$work/nginx" -c "$work/nginx/nginx.conf" -e "$work/nginx/error.log")
timeout 10 nginx "${nginx_args[@]}" -t -q || fail "NGINX refused the generated configuration"
timeout 10 nginx "${nginx_args[@]}" || fail "NGINX did not start"
nginx_started=true

# --- API -----------------------------------------------------------------------------------
phase "provider discovery over TLS"
python3 "$CORE_DIR/tests/keycloak/fixture.py" wait --directory "$fixture" --deadline 180 ||
  fail "Keycloak did not serve the fixture realm"

phase "openmettle-api with browser and native sign-in"
(
  core_env
  export OPENMETTLE_API_BIND=$API_ADDRESS
  export OPENMETTLE_API_DATABASE_URL
  OPENMETTLE_API_DATABASE_URL=$(role_url openmettle_api)
  export OPENMETTLE_API_ISSUANCE_DATABASE_URL
  OPENMETTLE_API_ISSUANCE_DATABASE_URL=$(role_url openmettle_issuance)
  export OPENMETTLE_API_AUTH_CONFIG=$fixture/auth-settings.json
  exec "$api_bin"
) >"$api_log" 2>&1 </dev/null &
api_pid=$!
ready=false
for _ in $(seq 60); do
  kill -0 "$api_pid" 2>/dev/null || break
  if [[ $(curl -s -o /dev/null -w '%{http_code}' --max-time 2 "http://$API_ADDRESS/readyz") == 200 ]]; then
    ready=true
    break
  fi
  sleep 0.5
done
if [[ $ready != true ]]; then
  fail "openmettle-api did not become ready on loopback"
fi

phase "application origin routing"
# Verified against the per-run application CA only; the host resolves to loopback here alone.
probe() {
  curl -sS --max-time 5 --cacert "$app_ca" --resolve "$APP_HOST:$APP_PORT:127.0.0.1" \
    -o "$work/probe.body" -D "$work/probe.headers" -w '%{http_code} %{content_type}' "$APP_ORIGIN$1"
}
header() {
  tr -d '\r' <"$work/probe.headers" | grep -i "^$1:" | cut -d: -f2- | sed 's/^ *//'
}
for path in / /app; do
  [[ $(probe "$path") == "200 text/html" ]] || fail "app page $path not served as HTML"
  [[ $(header referrer-policy) == same-origin ]] || fail "app page $path lacks Referrer-Policy same-origin"
  grep -qF '<base href="/">' "$work/probe.body" || fail "app page $path is not the Flutter build"
done
[[ $(probe /main.dart.js) == "200 text/javascript" ]] || fail "compiled Dart is not served as JavaScript"
[[ $(probe "/$wasm") == "200 application/wasm" ]] || fail "bundled WebAssembly is not served as application/wasm"
[[ $(probe /v1/capabilities) == 401\ application/problem+json* ]] ||
  fail "capabilities route does not reach the API"
# Same verified TLS session, another Host: NGINX selects the refusing default server.
if [[ $(curl -s -o /dev/null -w '%{http_code}' --max-time 5 --cacert "$app_ca" \
  --resolve "$APP_HOST:$APP_PORT:127.0.0.1" -H "Host: other.relying.test:$APP_PORT" \
  "$APP_ORIGIN/v1/capabilities") != 421 ]]; then
  fail "a host other than the application origin reached the API"
fi
rm -f -- "$work/probe.body" "$work/probe.headers"

# --- Browser journey -----------------------------------------------------------------------
phase "Flutter browser journey"
if ! timeout 300 python3 "$HERE/journey.py" "$CORE_DIR" "$fixture" "$app_ca"; then
  fail "Flutter browser journey failed"
fi

phase "server session state"
sessions=$(owner_psql -tA -v issuer="$issuer" -v subject="$subject" -f - <<'SQL'
SELECT count(*) FILTER (WHERE s.revoked AND t.consumed AND t.session_issued
                          AND i.issuer = :'issuer' AND i.subject = :'subject')
       || '/' || count(*)
  FROM openmettle.local_sessions s
  JOIN openmettle.login_transactions t ON t.id = s.login_id
  LEFT JOIN openmettle.user_identities i ON i.user_id = s.user_id;
SQL
) || fail "session state unreadable"
[[ $sessions == 1/1 ]] || fail "expected one consumed sign-in with its session revoked by logout"
kill -0 "$api_pid" 2>/dev/null || fail "openmettle-api exited during the journey"
disclosed "$api_log" && fail "openmettle-api output disclosed a database credential"

phase "Android device trust and HTTPS App Link verification"
timeout 550 bash "$HERE/android_device.sh" "$app_ca" "$fixture/provider-ca.pem" "$address" "$APP_APK" ||
  fail "Android device setup or domain verification failed"

# This file contains only response status codes for the exact capabilities route.
web_successes=$(grep -cx 200 "$work/nginx/capabilities-status")
phase "Android emulator journey"
timeout 365 /usr/bin/python3 "$HERE/android_journey.py" "$fixture" "$CORE_DIR" ||
  fail "Android emulator sign-in journey failed"
successes=$(grep -cx 200 "$work/nginx/capabilities-status")
((successes >= web_successes + 2)) || fail "expected authenticated Android capabilities before and after restart"
native_sessions=$(owner_psql -tA -v issuer="$issuer" -v subject="$subject" -f - <<'SQL'
SELECT count(*)
  FROM openmettle.native_handoffs h
  JOIN openmettle.local_sessions s ON h.session_id = s.id
  JOIN openmettle.login_transactions t ON t.id = s.login_id
  JOIN openmettle.user_identities i ON i.user_id = s.user_id
 WHERE h.sealed IS NULL AND s.revoked AND t.consumed AND t.session_issued
   AND i.issuer = :'issuer' AND i.subject = :'subject';
SQL
) || fail "native session state unreadable"
[[ $native_sessions == 1 ]] || fail "expected one redeemed and revoked Android session for the approved identity"
echo "Android qualification passed: verified App Link, native capabilities, process restart and revoked session."

phase "passed"
printf 'Flutter web qualification passed: Keycloak %s, PostgreSQL 18, core %s\n' \
  "$PROVIDER_VERSION" "$core_pin"
