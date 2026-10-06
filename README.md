# PostgREST image

KoedoDB runs [PostgREST](https://github.com/PostgREST/postgrest) **as upstream publishes it**. Nothing is built or patched here: this directory pins the image, says how KoedoDB runs it, and tests what KoedoDB relies on, above all that **a request is served only for a token signed with one of the project's keys**.

This is not an official PostgREST repository, and KoedoDB is not affiliated with the PostgREST project or with Supabase.

## The image

The file `IMAGE` holds the image, by tag and by digest of the multi-architecture index:

```
postgrest/postgrest:v16.4@sha256:d155c6718ed9a9f990d159a2ab7c0a3f16944dbb6d0a0344557421042acfe0df
```

To update it, change the tag and the digest together (`docker buildx imagetools inspect postgrest/postgrest:<tag>`), then run `tests/run.sh`. Read the [release notes](https://github.com/PostgREST/postgrest/releases) and the [security advisories](https://github.com/PostgREST/postgrest/security-advisories) first.

The image has no shell, only `/bin/postgrest`, and runs as uid 1000. KoedoDB runs it as uid 10001, with a read-only root file system, no capabilities and no new privileges; the test runs exactly that. It listens on 3000 (the API) and, when `PGRST_ADMIN_SERVER_PORT` is set, on that port for `/live` and `/ready`.

## How it is run

```sh
docker run --user 10001:10001 --read-only --cap-drop ALL --security-opt no-new-privileges \
  --env-file rest.env -v ./config:/config:ro <IMAGE>
```

`config/jwks.json` holds the **public** keys of the project (the JWKS Supabase Auth publishes, `{"keys": [...]}`). PostgREST never needs a private key.

## What the database needs first

`tests/init.sql` is what a project database has: the roles `anon`, `authenticated` and `service_role` (no login; `service_role` has `BYPASSRLS`), the login role `authenticator` that PostgREST connects as (`NOINHERIT`, and a member of the three), and grants. PostgREST switches from `authenticator` to the role of the token for each request. A table is reachable only with a grant to that role; row level security does the rest. `ALTER ROLE authenticator SET statement_timeout` is what limits how long a request may run.

## Settings

| Variable | Value | Note |
|---|---|---|
| `PGRST_DB_URI` | `postgres://authenticator:<password>@<host>:5432/postgres` | |
| `PGRST_DB_SCHEMAS` | `public` | The schemas served. Another schema asked for in `Accept-Profile` is refused (406). |
| `PGRST_JWT_SECRET` | `@/config/jwks.json` | **Always set it**, as a file (see "Rotating the keys"). At least 32 characters, or PostgREST exits. |
| `PGRST_JWT_AUD` | `authenticated` | The audience Supabase Auth puts in a token. |
| `PGRST_DB_MAX_ROWS` | e.g. `1000` | The most rows one response holds. |
| `PGRST_ADMIN_SERVER_PORT` | `3001` | `/live` (the process) and `/ready` (the database is reachable). |
| `PGRST_DB_ANON_ROLE` | **not set** | See below. |

## Things to know

- **No anonymous role.** Without `PGRST_DB_ANON_ROLE`, a request with no token gets 401 (`PGRST302`, "Anonymous access is disabled"). A project's publishable key is a token with `"role": "anon"` signed by the project's key, so supabase-js works unchanged, and every request still carries a token that was checked. Setting the anonymous role would serve everything `anon` may read to anyone **who sends no token at all**, and, if the key were ever missing, to everyone (next item).
- **No key means no token is accepted, not that every token is.** Without `PGRST_JWT_SECRET` PostgREST starts, and answers every request that has a token with 500 (`PGRST300`, "Server lacks JWT secret"), forged or not. With an anonymous role set it would still serve the requests without a token. A key shorter than 32 characters, or a wrong database password, makes it exit.
- **What is refused (401), and returns no data:** garbage, a token signed with another key (even with the `kid` of ours), an unknown `kid`, a key that is not in the JWKS, `alg: none`, an HS256 token made with the public key (or its coordinate) as the secret, a payload changed under the old signature, a cut signature, an expired token (`JWT expired`), a token that is not valid yet (`nbf`), another audience. A token in the `apikey` header only, or in the query string, is not authentication either.
- **The `aud` claim is checked only when the token has one.** A token with no `aud` is served even with `PGRST_JWT_AUD` set. Supabase Auth always sets it; a gateway in front can require it.
- **The role claim is the database's to judge.** `role: postgres` gets 403 ("permission denied to set role"), as does `authenticator` (it owns nothing); a role that does not exist or is empty gets 401; a token with no `role` gets 401 (no anonymous role to fall back to). A table the role has no grant on gives 403, and does not appear in the OpenAPI document.
- **Row level security works through the claims:** `request.jwt.claims` holds the token's claims, so `auth.uid()` (defined in `tests/init.sql` as the `sub` claim) and `current_user` are the user's. A row for someone else is refused by the policy (403), another user's rows are not seen, changed or deleted.
- **The statement timeout holds:** a query that runs past the role's `statement_timeout` is cancelled by the database (500, `57014`).
- **Rotating the keys:** with the secret as a file (`@/config/jwks.json`), change the file and send `SIGUSR2` (reload the configuration and the keys; `docker kill -s USR2 <container>` in the test). A rolling restart reads the file too, and is the way that does not depend on a signal. Put the new key in next to the old one, and take the old one out when its tokens have expired. Until the signal, the file is not read again (tested). No restart is needed.
- **A new table or function** is served only after the schema cache reloads: `NOTIFY pgrst, 'reload schema'` does it.
- **The database going away is survived:** `/ready` is 503 and requests get 503 (`PGRST001`) meanwhile, `/live` stays 200, and PostgREST serves again by itself when the database is back.
- **The logs hold no token.**

## What the tests check

`tests/run.sh` starts PostgreSQL 18 (pinned by digest), makes the roles and tables, and starts the image as described above, then checks:

- it starts hardened, is ready, is the version in `IMAGE`;
- the tokens above, one by one (53 checks in all), with tokens made by `tests/jwt_helper.py` (Python's standard library and `openssl` only);
- roles, grants, row level security, the claims reaching the database, the schema that is not exposed, the OpenAPI document;
- the row limit and the statement timeout;
- a new table and a schema reload; adding a key, using it only after the signal, and taking the old one out, without a restart;
- the database stopping and starting again;
- the failures: a wrong database password, a short key, no key at all (with and without an anonymous role);
- that the logs hold no token.

It needs Docker, Python 3 and `openssl`, and uses no secrets: every password and key is made up for the run. A weekly workflow runs it, so a change of the base images shows.

## Not checked

Kubernetes (the Secret mount, network policy), the gateway in front of PostgREST (Envoy checks the token as well, so a request needs to pass two checks), Supavisor between PostgREST and the database (the connection mode and prepared statements), the `Prefer: tx=rollback` and pre-request functions, large request bodies, and PostgREST's speed.

## License

Copyright (c) 2026 RadarWorks LLC. The files in this repository (`IMAGE`, the tests and this documentation) are licensed under the [MIT License](LICENSE). PostgREST itself is MIT-licensed too ([PostgREST/postgrest](https://github.com/PostgREST/postgrest)); the image is upstream's.
