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
kdep, Infisical or Kubernetes: its interface is *contract + env name + values →
ok or a list of problems*. It never writes to disk and never prints a secret
value (unless you pass `--show-values`).

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

## env.spec syntax

```
# shared (all envs) -- the top of the file is the default for every env
APP_NAME
LOG_LEVEL: enum(debug, info, warn, error) = info
DEBUG?: bool
PORT: int = 3000
PUBLIC_URL: url

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
- `KEY = default` — default value, ConfigMap only; secrets cannot have defaults.
  Quote it to keep `#` or surrounding spaces: `GREETING = "hi # there "`
  (escapes: `\"` and `\\`).
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

## Library API

```ruby
require "envpact"

spec = EnvPact.parse_file("env.spec")      # or EnvPact.parse(text)
spec.envs                                  # env names that have sections
spec.configmap_for("production")           # shared + production, {key => Entry}
spec.secrets_for("production")

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
