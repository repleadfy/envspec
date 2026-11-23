# envpact

An env var contract for apps. One file, `env.spec`, declares which env vars an
app needs — names, types, required/optional, defaults, Secret vs ConfigMap, and
per-env differences. It never holds values. The same contract is checked at
three moments:

1. **Locally** — `envpact check --env=development` against your `.env*` files.
2. **Before deploy** — a deploy tool (e.g. kdep) assembles the values that will be
   in the cluster and calls the Ruby API; a failure blocks the deploy.
3. **At boot** — `envpact exec --env=production -- <cmd>` checks the real process
   ENV and refuses to start the app if the contract isn't met.

Pure Ruby, **zero runtime dependencies**, Ruby ≥ 2.5. envpact knows nothing about
kdep or Kubernetes: its interface is *contract + env name + values → ok or a
list of problems*. It never prints a secret value (unless you pass
`--show-values` to a local `check`). Since 0.2 it can also fetch and store the
env's secrets in [OpenBao](https://openbao.org) (see below); that is the only
thing it talks to, and the only files it writes are `~/.ob_read`, `~/.ob_write`
and the target of `pull`, always mode 0600.

## Install

```sh
gem install envpact
```

## Commands

```sh
envpact lint                          # syntax check ./env.spec
envpact check --env=test              # check .env, .env.test, .env.test.local
envpact check --env=x --from-env      # check the current process ENV instead
envpact exec --env=production -- bin/rails server   # boot check, then exec
envpact scan-prompt | claude          # have an agent write env.spec for this repo

# secrets in OpenBao (0.2, see "Secrets with OpenBao")
envpact login --read                  # log in once a month, token stored encrypted
envpact unlock --for=2h               # keep the read token in a local agent
envpact pull --env=development        # secrets -> .env.development.local (0600)
envpact run --env=development -- bin/rails s   # secrets only in the process
envpact push --env=production --from=.env.new  # write secrets (asks you, on the tty)
envpact set --env=production STRIPE_KEY        # write one secret
envpact status | envpact lock
```

- The contract path defaults to `./env.spec`; override with `--spec=PATH` or
  `$ENVPACT_SPEC`.
- `--env` is always required (`exec` also reads `$ENVPACT_ENV`). Any env name
  is valid: an env without an `[env: …]` section gets only the shared keys, and
  every check says which sections it applied:
  `✓ env.spec satisfied (env: prod — shared only; sections in spec: production)`.
- `check` reads, in order (later overrides earlier): `.env`, `.env.<env>`,
  `.env.local` (skipped for `test`), `.env.<env>.local`. No interpolation, no
  multiline values.
- Keys present but not in the contract are warnings; `--strict` makes them
  errors. They are never reported when checking process ENV.
- `exec` fills defaults for absent or empty keys, then replaces itself with the
  command. Exit codes: 0 ok, 1 contract not satisfied, 2 usage error, 127 command
  not found.

Composes with Infisical (or anything that injects env) without coupling:

```sh
infisical run --env=dev -- envpact exec --env=development -- bin/rails s
```

## Secrets with OpenBao

The `[source]` section of `env.spec` says where each env's secrets live (KV v2):

```
[source]
openbao path=team/myapp/{env}
openbao path=cluster/selly/myapp-web env=production
```

The server address is `addr=` on the line, else `$BAO_ADDR`. A token is only ever
sent to the address it was issued for; a spec naming another address is refused.
The source holds only the keys declared under `[secrets]`; ConfigMap values keep
coming from `.env*`, `app.yml` and defaults.

| Command | What it does |
|---|---|
| `login --read` / `login --write --role=NAME` | OIDC login through a loopback listener (`--port=8250`, `--oidc-mount=oidc`), or `--token-stdin` for a token you already have. Asks for a passphrase (min 12 chars) on the terminal and stores the token AES-256-GCM encrypted (PBKDF2-SHA256, 600 000 iterations) in `~/.ob_read` or `~/.ob_write`. A file readable by others is refused, like ssh does. |
| `unlock [--for=2h]` | Hands the read token to a local agent (Unix socket, 0600, your uid only) for up to 8h and never past the token's expiry. While unlocked, `pull`/`run` ask for nothing. Writes never use the agent. |
| `lock`, `status` | Stop the agent; show agent and token-file state (never the tokens). |
| `pull --env=E [--out=PATH]` | Reads the env's secrets, checks them together with the `.env*` files (not the target itself) and, only if the contract is satisfied, writes `.env.<E>.local` (0600). Warns if the file is not git-ignored. |
| `run --env=E -- CMD` | Like `exec`, but the secrets come from OpenBao and go only into CMD's environment. They override the current ENV; the OpenBao token never reaches CMD. |
| `push --env=E --from=FILE\|-` | Validates the secret keys in a dotenv file and merges them into the env's path (never deletes a key). |
| `set --env=E KEY` | Same for one key; the value comes from stdin, or a no-echo prompt on a terminal. |
| `check --env=E --source` | `check` with the OpenBao secrets overlaid in memory. Not combinable with `--show-values`. |

Writes (`push`/`set`) need a human: they show what will be written, ask `y/N` on
`/dev/tty`, then the passphrase of `~/.ob_write`. With no terminal they refuse
before any network call. No env var or flag can supply the passphrase or the
confirmation. Each use of the read token also renews it (`renew-self`).

What changed from 0.1: envpact used to read nothing but your own files and write
nothing. Now it talks to OpenBao and writes `~/.ob_read`, `~/.ob_write` and the
`pull` target (always 0600, through a temp file and rename, never through a
symlink).

With Claude Code, let it read and run, but make writes and logins ask you, and
keep it away from the token files (`.claude/settings.json`):

```json
{
  "permissions": {
    "ask":  ["Bash(envpact push:*)", "Bash(envpact set:*)", "Bash(envpact login:*)"],
    "deny": ["Read(~/.ob_read)", "Read(~/.ob_write)", "Bash(cat ~/.ob_*)"]
  }
}
```

## env.spec syntax

```
# shared (all envs) -- the top of the file is the default for every env
APP_NAME
LOG_LEVEL: enum(debug, info, warn, error) = info
DEBUG?: bool
PORT: int = 3000
PUBLIC_URL: url

[source]
openbao path=team/myapp/{env}
openbao path=cluster/selly/myapp-web env=production

[secrets]
DB_PASS
OPENAI_API_KEY

[env: production]
SENTRY_DSN: url
[secrets]
STRIPE_LIVE_KEY

[env: production, staging]
CDN_HOST

[shared]
FEATURE_FLAGS?
```

- `KEY` — required string, ConfigMap, in the current scope.
- `KEY?` — optional.
- `KEY: type` — `str` (default) | `int` | `bool` | `url` | `enum(a, b, c)`.
  - `bool` accepts `true false 1 0 yes no` (any case).
  - `url` needs a scheme and a host: `postgres://u:p@h:5432/db`, `https://x.y`.
  - `url(postgres, redis)` also restricts the scheme (case-insensitive).
- `KEY = default` — default value, ConfigMap only; secrets cannot have defaults.
  The default must be valid for the type (`PORT: int = 3OOO` is a lint error).
  Quote it to keep `#` or surrounding spaces: `GREETING = "hi # there "`
  (only `\"` and `\\` are escapes; any other backslash is kept).
- `[secrets]` — modifier: following keys are Secrets; scope unchanged.
- `[env: name]` / `[env: a, b]` — selector: following keys apply only to those
  envs; type resets to ConfigMap. Env names are free-form (`[A-Za-z0-9_-]+`).
- `[shared]` — selector: back to the shared scope (all envs); type resets to
  ConfigMap.
- `#` starts a comment at the start of a line or after whitespace
  (`URL = http://x/a#frag` keeps the `#frag`).
- An env with no `[env: …]` section gets only the shared keys. A key may not be
  declared in overlapping scopes, may not be both ConfigMap and Secret, and must
  have the same type in every env.
- Empty values count as absent.
- `[source]` — where the secrets of each env live, one `openbao path=… [mount=secret]
  [addr=URL] [env=a,b]` line per source. A line without `env=` is the fallback; one
  with `env=` wins for those envs. `{env}` is the only placeholder in `path`.
- After `[source]` any other header resumes keys; `[secrets]` there applies to shared.

## Library API

```ruby
require "envpact"

spec = EnvPact.parse_file("env.spec")      # or EnvPact.parse(text)
spec.envs                                  # env names that have sections
spec.configmap_for("production")           # shared + production, {key => Entry}
spec.secrets_for("production")
spec.source_for("production")              # EnvPact::SourceRef (mount, path, addr) or nil
EnvPact::Source.fetch(spec, env: "production", client: client)  # {secret key => value} from OpenBao

result = spec.check(values, env: "production", strict: false)
result.ok?               # no errors (warnings allowed)
result.errors            # [EnvPact::Problem]  :missing / :invalid (+ :extra if strict)
result.warnings          # [EnvPact::Problem]  :extra
result.applied_sections  # ["shared", "production"]
result.errors.first.message   # secret values are already masked

spec.check!(values, env: "production")     # raises EnvPact::ValidationError (#result)
EnvPact::Dotenv.load(Dir.pwd, env: "test") # => { files: [...], values: {...} }
```

`Problem#value` is `nil` for secrets. To reveal one deliberately (as
`check --show-values` does): `EnvPact::Message.format(problem, value: values[problem.key])`.

## License

MIT.
