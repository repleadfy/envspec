# envspec

Declarative env var contract for apps. Pure-Ruby gem with **zero runtime dependencies**.

`envspec` parses `env.spec` files — a small DSL that describes which env vars an app expects, their types, optionality, and ConfigMap-vs-Secret classification. Use it as a CI lint, a Rails boot check, or a deploy-time contract.

## Install

```sh
gem install envspec
```

Requires Ruby ≥ 2.5. No native extensions, no other gems.

## Quick start

```sh
# Generate env.spec from a scan of your repo
envspec init

# Validate the spec syntactically
envspec lint env.spec

# Check current ENV against the spec
envspec check env.spec --env=production
```

## env.spec syntax

```
# shared (all envs)
APP_NAME
LOG_LEVEL: enum(debug, info, warn, error) = info
DEBUG?: bool
PORT: int = 3000

[secrets]
DB_PASS
OPENAI_API_KEY

[env: production]
DB_HOST
[secrets]
STRIPE_LIVE_KEY

[env: production, staging]
SENTRY_DSN: dsn
```

- `KEY` — required string in shared scope, ConfigMap
- `KEY?` — optional
- `KEY: type` — typed (`str | int | bool | dsn | enum(a,b,c)`)
- `KEY = default` — default value (configmap only; secrets cannot have defaults)
- `[secrets]` — modifier; subsequent keys become Secrets (scope unchanged)
- `[env: name]` / `[env: a, b]` — selector; subsequent keys scoped to those envs (also resets type back to ConfigMap — explicit beats implicit)

## Library API

```ruby
require "envspec"

spec = EnvSpec.parse_file("env.spec")

spec.configmap        # => { "*" => {...}, "production" => {...} }
spec.secrets          # => { "*" => {...}, "production" => {...} }
spec.envs             # => ["production", "staging"]
spec.configmap_for("production")  # merged shared + production

spec.validate!(ENV.to_h, env: "production")  # raises EnvSpec::ValidationError if anything missing or wrong type
```

## License

MIT.
