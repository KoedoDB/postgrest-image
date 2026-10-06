#!/bin/bash
# Runs the pinned PostgREST image (the file IMAGE) in Docker, as the Pod will run it: a non-root user, a read-only root file system, no capabilities, with the public keys of the project's
# JWKS in a file, against PostgreSQL 18. It checks the behaviour KoedoDB relies on, above all that a request is served only for a token signed with one of the keys. Nothing is built: the
# image is upstream's (postgrest/postgrest), used as it is.
#
#   tests/run.sh        # a few minutes; ends with "ALL OK"
#
# Needs Docker, python3 and openssl. It uses no secrets: every password and key is made up here, for the run.
#
# What is NOT checked here: Kubernetes (the Secret mount, NetworkPolicy), the gateway in front of PostgREST (Envoy: it checks the token too), Supavisor between PostgREST and the database,
# Realtime, Storage, and PostgREST's own performance.
set -uo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
IMAGE="$(tr -d '[:space:]' < "$here/IMAGE")"
PG="postgres:18.6-trixie@sha256:5a5a84b19854a9ffaa54082c166ff4ec27473a361e496e5ea167f298f2da9722"
H="$here/tests/jwt_helper.py"
run="kbrest$$"
net="${run}-net"
# Under $HOME: the Docker daemon has to see it (a temporary directory may be private to the shell that made it).
work="${HOME}/.${run}"; rm -rf "$work"; mkdir -p "$work/cfg"; chmod 755 "$work" "$work/cfg"
cleanup() { docker ps -aq --filter "name=^${run}-" | xargs -r docker rm -f >/dev/null 2>&1; docker network rm "$net" >/dev/null 2>&1; rm -rf "$work"; }
trap '[ -n "${KEEP:-}" ] || cleanup' EXIT
fail=0
check() {
  local out; out="$(eval "$2" 2>&1)"; local rc=$?
  if [ $rc = 0 ]; then echo "ok:   $1"; else echo "FAIL: $1"; fail=1; [ -n "${DEBUG:-}" ] && echo "      -> $(printf %s "$out" | head -20 | cut -c1-260)"; fi
}
note() { echo "note: $1"; }
step() { echo; echo "== $1"; }

# --- helpers -----------------------------------------------------------------------------------------------------------------------------------------------------------
jget() { python3 -c "
import sys, json
d = json.load(sys.stdin)
for k in sys.argv[1].split('.'):
    d = d[k] if isinstance(d, dict) else d[int(k)]
print(d)" "$1"; }
# req <path> [token] [method] [json body] [extra curl args...]  ->  CODE, BODY and HEADERS (against the main container)
req() {
  local path=$1 token=${2:-} method=${3:-GET} data=${4:-}; shift $(( $# > 4 ? 4 : $# ))
  local args=(-s -m 20 -X "$method" -D "$work/headers" -o "$work/body" -w '%{http_code}' "http://127.0.0.1:${port}${path}" -H 'Content-Type: application/json' -H 'Prefer: return=representation')
  [ -n "$token" ] && args+=(-H "Authorization: Bearer ${token}")
  [ -n "$data" ] && args+=(-d "$data")
  CODE="$(curl "${args[@]}" "$@")"; BODY="$(cat "$work/body")"; HEADERS="$(cat "$work/headers")"
}
code_of() { req "$@"; echo "$CODE"; }
mapped() { docker port "$1" "$2/tcp" | head -1 | sed 's/.*://'; }
wait_ready() { for _ in $(seq 1 60); do [ "$(curl -s -o /dev/null -w '%{http_code}' -m 3 "http://127.0.0.1:$1/ready")" = 200 ] && return 0; sleep 1; done; return 1; }
wait_exit() { for _ in $(seq 1 60); do [ "$(docker inspect -f '{{.State.Status}}' "$1" 2>/dev/null)" = exited ] && return 0; sleep 1; done; return 1; }
psql_db() { docker exec -i "${run}-db" psql -U postgres -v ON_ERROR_STOP=1 -At "$@"; }
now() { date +%s; }
token() { "$H" sign "$work/$1.pem" "$2" "$3"; }   # token <key> <kid> <claims>

# A container of PostgREST: no shell inside the image, so it is looked at from the outside (the admin port 3001: /live and /ready).
HARDENED=(--user 10001:10001 --read-only --cap-drop ALL --security-opt no-new-privileges)
start() {   # start <name> <env...>   (the common settings are in $work/rest.env; later -e options win)
  local name="${run}-$1"; shift
  docker run -d --name "$name" --network "$net" -p 127.0.0.1::3000 -p 127.0.0.1::3001 --env-file "$work/rest.env" -v "$work/cfg:/config:ro" "${HARDENED[@]}" "$@" "$IMAGE" >/dev/null
}

# --- the run's keys and passwords ---------------------------------------------------------------------------------------------------------------------------------
restpw="rest-$(openssl rand -hex 12)"
"$H" genkey k1 "$work/k1.pem" "$work/k1.priv.json" "$work/k1.pub.json"
"$H" genkey k2 "$work/k2.pem" "$work/k2.priv.json" "$work/k2.pub.json"
"$H" genkey other "$work/other.pem" "$work/other.priv.json" "$work/other.pub.json"   # a key PostgREST is never given
jwks() { python3 -c "import sys, json; print(json.dumps({'keys': [json.load(open(f)) for f in sys.argv[1:]]}))" "$@"; }   # jwks <public jwk file>...
jwks "$work/k1.pub.json" > "$work/cfg/jwks.json"
cat > "$work/rest.env" <<ENV
PGRST_DB_URI=postgres://authenticator:${restpw}@${run}-db:5432/postgres
PGRST_DB_SCHEMAS=public
PGRST_JWT_SECRET=@/config/jwks.json
PGRST_JWT_AUD=authenticated
PGRST_DB_MAX_ROWS=20
PGRST_ADMIN_SERVER_PORT=3001
ENV
# Note: no PGRST_DB_ANON_ROLE. A request without a token is refused; the publishable key of a project is a token with the role anon (made below).

step "PostgreSQL 18 and the roles and tables a project has"
docker network create "$net" >/dev/null
docker run -d --name "${run}-db" --network "$net" --network-alias "${run}-db" -e POSTGRES_PASSWORD="pg-$(openssl rand -hex 8)" "$PG" >/dev/null
for _ in $(seq 1 60); do docker exec "${run}-db" pg_isready -U postgres >/dev/null 2>&1 && break; sleep 1; done; sleep 3
check "the roles, the schema and the tables (tests/init.sql) are accepted" "psql_db -v restpw='$restpw' -q < '$here/tests/init.sql'"

step "PostgREST starts as the Pod will run it"
start rest
port="$(mapped "${run}-rest" 3000)"; admin="$(mapped "${run}-rest" 3001)"
check "it is ready (the admin port: /ready 200, and /live 200)" 'wait_ready $admin && [ "$(curl -s -o /dev/null -w "%{http_code}" -m 3 http://127.0.0.1:$admin/live)" = 200 ]'
check "it runs as user 10001, on a read-only root file system, with no capabilities" '[ "$(docker inspect -f "{{.Config.User}}" '"${run}"'-rest)" = 10001:10001 ] && [ "$(docker inspect -f "{{.HostConfig.ReadonlyRootfs}}" '"${run}"'-rest)" = true ] && [ "$(docker inspect -f "{{.HostConfig.CapDrop}}" '"${run}"'-rest)" = "[ALL]" ]'
tag="$(sed 's/^[^:]*:v\([0-9.]*\)@.*/\1/' "$here/IMAGE")"
check "it is the version in IMAGE ($tag)" '[ "$(docker run --rm --entrypoint /bin/postgrest "$IMAGE" --version)" = "PostgREST $tag" ]'
check "it loaded the schema (the tables and the functions it can see)" 'docker logs '"${run}"'-rest 2>&1 | grep -q "Schema cache loaded"'

step "A request is served only for a token signed with one of the project's keys"
n=$(now); uid1="$(python3 -c 'import uuid; print(uuid.uuid4())')"; uid2="$(python3 -c 'import uuid; print(uuid.uuid4())')"
claims() { printf '{"role":"%s","sub":"%s","aud":"authenticated","exp":%s}' "$1" "${2:-$uid1}" "${3:-$((n + 600))}"; }
t_user="$(token k1 k1 "$(claims authenticated)")"; t_user2="$(token k1 k1 "$(claims authenticated "$uid2")")"
t_anon="$(token k1 k1 "$(claims anon)")"; t_service="$(token k1 k1 "$(claims service_role)")"
refused() {   # refused <name> <token>: 401, a code from PostgREST, and none of the data
  req "/posts?limit=1" "$2"
  [ "$CODE" = 401 ] && ! printf %s "$BODY" | grep -q "post 1" && printf %s "$BODY" | grep -q '"code"'
}
check "no token at all: refused (anonymous access is disabled)" 'req "/posts?limit=1"; [ "$CODE" = 401 ] && printf %s "$BODY" | grep -q PGRST302 && ! printf %s "$BODY" | grep -q "post 1"'
check "the publishable key (a token with the role anon) is served" 'req "/posts?limit=1" "$t_anon"; [ "$CODE" = 200 ] && printf %s "$BODY" | grep -q "post 1"'
check "a token of the key in the JWKS is served" 'req "/rpc/who" "$t_user"; [ "$CODE" = 200 ]'
check "garbage instead of a token: refused" 'refused garbage "abc.def.ghi"'
check "a token signed with another key, with the kid of ours: refused" 'refused otherkey "$(token other k1 "$(claims service_role)")"'
check "a token with a kid that is not in the JWKS: refused" 'refused unknownkid "$(token k1 nope "$(claims service_role)")"'
check "a token of a key that is not in the JWKS yet (k2): refused" 'refused k2 "$(token k2 k2 "$(claims service_role)")"'
check "an unsigned token (alg none): refused" 'refused none "$("$H" none "$(claims service_role)")"'
check "an HS256 token made with the public key as a shared secret: refused" 'refused hs256 "$("$H" hs256 "$(cat "$work/cfg/jwks.json")" k1 "$(claims service_role)")"; '
check "an HS256 token made with the x coordinate of the key as the secret: refused" 'refused hs256x "$("$H" hs256 "$(jget keys.0.x < "$work/cfg/jwks.json")" k1 "$(claims service_role)")"'
check "a token whose payload was changed (anon to service_role), with the old signature: refused" 'refused tampered "$("$H" tamper "$t_anon" "$(claims service_role)")"'
check "a token with its signature cut short: refused" 'refused short "${t_user%?????}"'
check "an expired token: refused (JWT expired)" 'refused expired "$(token k1 k1 "$(claims authenticated "$uid1" $((n - 60)))")"; printf %s "$BODY" | grep -q "JWT expired"'
check "a token that is not valid yet (nbf in the future): refused" 'refused nbf "$(token k1 k1 "{\"role\":\"authenticated\",\"aud\":\"authenticated\",\"nbf\":$((n + 900)),\"exp\":$((n + 1200))}")"; printf %s "$BODY" | grep -q "not yet valid"'
check "a token for another audience: refused" 'refused aud "$(token k1 k1 "{\"role\":\"authenticated\",\"aud\":\"other\",\"exp\":$((n + 600))}")"'
check "a valid token in the apikey header only (no Authorization): refused, the apikey header is not authentication" 'req "/posts?limit=1" "" GET "" -H "apikey: $t_service"; [ "$CODE" = 401 ]'
check "a valid token in the query string: refused (only the Authorization header counts)" 'req "/posts?limit=1&access_token=$t_service"; [ "$CODE" = 401 ]'
note "a token WITHOUT an aud claim is served even when PGRST_JWT_AUD is set (PostgREST checks the claim only when it is there). Supabase Auth always sets it."
check "(that note) a token without aud is served" 'req "/rpc/who" "$(token k1 k1 "{\"role\":\"authenticated\",\"exp\":$((n + 600))}")"; [ "$CODE" = 200 ]'
check "no token or refused token ever put a row in the access log with a token in it (the logs hold no JWT)" '[ "$(docker logs '"${run}"'-rest 2>&1 | grep -c eyJ)" = 0 ]'

step "The role of the token decides what is allowed (the database does the checking)"
check "a user reads and writes only their own rows (row level security): the insert is served" 'req "/notes" "$t_user" POST "{\"owner\":\"$uid1\",\"body\":\"mine\"}"; [ "$CODE" = 201 ]'
check "  a row for someone else is refused by the policy (403, 42501)" 'req "/notes" "$t_user" POST "{\"owner\":\"$uid2\",\"body\":\"theirs\"}"; [ "$CODE" = 403 ] && printf %s "$BODY" | grep -q 42501'
check "  the user sees the row, another user sees none" 'req "/notes" "$t_user"; [ "$(printf %s "$BODY" | jget 0.body)" = mine ] && req "/notes" "$t_user2" && [ "$BODY" = "[]" ]'
check "  another user can not change or delete it (0 rows)" 'req "/notes?body=eq.mine" "$t_user2" PATCH "{\"body\":\"taken\"}"; [ "$BODY" = "[]" ] && req "/notes?body=eq.mine" "$t_user2" DELETE && [ "$BODY" = "[]" ] && [ "$(psql_db -c "select body from notes")" = mine ]'
check "service_role skips the policies (it sees the row of any user)" 'req "/notes" "$t_service"; [ "$CODE" = 200 ] && printf %s "$BODY" | grep -q mine'
check "a table with no grant: anon and a user get 403, service_role (granted) 200, and none but service_role sees the row" 'req /secrets "$t_anon"; a=$CODE; ! printf %s "$BODY" | grep -q secret; req /secrets "$t_user"; b=$CODE; ! printf %s "$BODY" | grep -q "top secret"; req /secrets "$t_service"; c=$CODE; [ "$a $b $c" = "403 403 200" ] && printf %s "$BODY" | grep -q "top secret"'
check "anon can not write to a table it can only read" 'req "/posts" "$t_anon" POST "{\"id\":99,\"title\":\"x\"}"; [ "$CODE" = 403 ] && [ "$(psql_db -c "select count(*) from posts")" = 30 ]'
check "the role claim postgres is refused (permission denied to set role)" 'req "/posts?limit=1" "$(token k1 k1 "$(claims postgres)")"; [ "$CODE" = 403 ] && printf %s "$BODY" | grep -q "permission denied to set role"'
check "the role claim authenticator (the login role) can do nothing" 'req "/posts?limit=1" "$(token k1 k1 "$(claims authenticator)")"; [ "$CODE" = 403 ]'
check "a role that does not exist, and an empty role: refused" 'req "/posts?limit=1" "$(token k1 k1 "$(claims nope)")"; a=$CODE; req "/posts?limit=1" "$(token k1 k1 "$(claims "")")"; [ "$a $CODE" = "401 401" ]'
check "a token with no role claim: refused (there is no anonymous role to fall back to)" 'req "/posts?limit=1" "$(token k1 k1 "{\"sub\":\"$uid1\",\"aud\":\"authenticated\",\"exp\":$((n + 600))}")"; [ "$CODE" = 401 ]'
check "the claims reach the database: auth.uid() is the sub of the token, current_user is its role" 'req /rpc/who "$t_user"; [ "$(printf %s "$BODY" | jget role)" = authenticated ] && [ "$(printf %s "$BODY" | jget sub)" = "$uid1" ]'
check "a schema that is not exposed (auth) is refused: 406" 'req / "$t_user" GET "" -H "Accept-Profile: auth"; [ "$CODE" = 406 ]'
check "the OpenAPI document lists what the role may use, and not a table it has no grant on" 'req / "$t_user"; [ "$CODE" = 200 ] && printf %s "$BODY" | grep -q "/notes" && ! printf %s "$BODY" | grep -q "/secrets"'

step "Limits"
check "at most PGRST_DB_MAX_ROWS (20) rows come back from a table of 30" 'req /posts "$t_anon"; [ "$(printf %s "$BODY" | python3 -c "import sys,json; print(len(json.load(sys.stdin)))")" = 20 ] && printf %s "$HEADERS" | grep -qi "content-range: 0-19"'
t0=$(now); req /rpc/slow "$t_user" POST; t1=$(now)
check "a query that runs too long is cancelled by the database (the role's statement_timeout, 3 s): 500, 57014" '[ "$CODE" = 500 ] && printf %s "$BODY" | grep -q 57014 && [ $((t1 - t0)) -lt 8 ]'

step "A new table, and a key rotation, without a restart"
psql_db -q -c "create table public.later(id int); grant select on public.later to authenticated;"
check "a new table is not served until the schema is reloaded" 'req /later "$t_user"; [ "$CODE" = 404 ]'
psql_db -q -c "notify pgrst, 'reload schema'"; sleep 1
check "NOTIFY pgrst, 'reload schema' loads it" 'req /later "$t_user"; [ "$CODE" = 200 ]'
t_k2="$(token k2 k2 "$(claims authenticated)")"
jwks "$work/k1.pub.json" "$work/k2.pub.json" > "$work/cfg/jwks.json"
check "the file changed, but nothing was told: the new key is not used yet" 'req /rpc/who "$t_k2"; [ "$CODE" = 401 ]'
docker kill -s USR2 "${run}-rest" >/dev/null; sleep 2
check "after SIGUSR2 (reload the configuration and the keys) both keys are served" 'req /rpc/who "$t_k2"; a=$CODE; req /rpc/who "$t_user"; [ "$a $CODE" = "200 200" ]'
jwks "$work/k2.pub.json" > "$work/cfg/jwks.json"
docker kill -s USR2 "${run}-rest" >/dev/null; sleep 2
check "with the old key taken out, its tokens are refused and the new keys are served" 'req /rpc/who "$t_user"; a=$CODE; req /rpc/who "$t_k2"; [ "$a $CODE" = "401 200" ]'
check "the process did not restart (it is still the same one: no new Starting line)" '[ "$(docker logs '"${run}"'-rest 2>&1 | grep -c "Starting PostgREST")" = 1 ]'

step "The database goes away and comes back"
docker stop "${run}-db" >/dev/null; sleep 3
check "while it is gone: /ready is 503, /live is 200, and a request gets 503 (never data)" 'a=$(curl -s -o /dev/null -w "%{http_code}" -m 3 http://127.0.0.1:$admin/ready); b=$(curl -s -o /dev/null -w "%{http_code}" -m 3 http://127.0.0.1:$admin/live); req /posts "$t_k2"; [ "$a $b $CODE" = "503 200 503" ]'
docker start "${run}-db" >/dev/null
check "when it is back PostgREST serves again by itself (within 40 s)" 'for _ in $(seq 1 40); do req /posts "$t_k2"; [ "$CODE" = 200 ] && exit 0; sleep 1; done; exit 1'

step "What must stop PostgREST, or refuse, and not serve"
start badpw -e "PGRST_DB_URI=postgres://authenticator:wrong-password@${run}-db:5432/postgres"; wait_exit "${run}-badpw"
check "a wrong database password: it exits with an error and does not serve" '[ "$(docker inspect -f "{{.State.ExitCode}}" '"${run}"'-badpw)" = 1 ]'
start short -e PGRST_JWT_SECRET=too-short; wait_exit "${run}-short"
check "a key shorter than 32 characters: it exits (The JWT secret must be at least 32 characters long)" '[ "$(docker inspect -f "{{.State.ExitCode}}" '"${run}"'-short)" = 1 ] && docker logs '"${run}"'-short 2>&1 | grep -q "at least 32"'
grep -v '^PGRST_JWT_SECRET=' "$work/rest.env" > "$work/nosecret.env"
docker run -d --name "${run}-nosecret" --network "$net" -p 127.0.0.1::3000 --env-file "$work/nosecret.env" "${HARDENED[@]}" "$IMAGE" >/dev/null; sleep 4
nsport="$(mapped "${run}-nosecret" 3000)"
check "NO key at all: it starts, but a token is never accepted (500 PGRST300), not even a forged one" 'for t in "$t_service" "$("$H" none "$(claims service_role)")"; do c=$(curl -s -o "$work/ns" -w "%{http_code}" -m 5 http://127.0.0.1:$nsport/secrets -H "Authorization: Bearer $t"); [ "$c" = 500 ] && grep -q PGRST300 "$work/ns" || exit 1; done'
check "NO key and no anonymous role: nothing is served (401)" '[ "$(curl -s -o /dev/null -w "%{http_code}" -m 5 http://127.0.0.1:$nsport/posts)" = 401 ]'
note "NO key AND an anonymous role (PGRST_DB_ANON_ROLE) would serve everything anon may read, to anyone. That is why the role is not set here."
docker rm -f "${run}-nosecret" >/dev/null

step "The logs"
check "after all of the above the logs still hold no token" '[ "$(for c in rest badpw short; do docker logs '"${run}"'-$c 2>&1; done | grep -c eyJ)" = 0 ]'

echo
[ "$fail" = 0 ] && echo "ALL OK" || { echo "SOME CHECKS FAILED"; exit 1; }
