```yaml
version: 1

source:                          # where the secrets live; {env} becomes the env name
  openbao:
    path: "team/myapp/{env}"
    # addr: "https://bao.example.com"   # optional
    # mount: secret                     # optional, default secret

vars:                            # ConfigMap keys, shared by every env
  APP_NAME:                      # empty value = required string
  LOG_LEVEL: {type: "enum(debug, info, warn, error)", default: "info"}
  DEBUG: {type: bool, optional: true}
  PORT: {type: int, default: "3000", description: "HTTP port"}
  PUBLIC_URL: url

secrets:                         # Secret keys, shared by every env
  DB_PASS:
  OPENAI_API_KEY:

envs:                            # only for what differs per env
  production:
    source:
      openbao:
        path: "cluster/selly/myapp-web"
    vars:
      SENTRY_DSN: url
    secrets:
      STRIPE_LIVE_KEY:
  "production, staging":         # one key, several envs
    vars:
      CDN_HOST:
```

- `version: 1` is required. Unknown keys and fields are errors.
- A key's value is one of:
  - empty — required string;
  - a type — `str` | `int` | `bool` | `url` | `url(a, b)` | `enum(a, b, c)`;
  - a mapping with `type`, `default`, `optional` (`true`/`false`) and
    `description`.
- Types:
  - `bool` accepts `true false 1 0 yes no` (any case).
  - `url` needs a scheme and a host: `postgres://u:p@h:5432/db`, `https://x.y`.
  - `url(postgres, redis)` also restricts the scheme (case-insensitive).
  - Inside `{...}` a comma splits fields: quote `enum(...)`/`url(...)` there,
    as in `{type: "enum(a, b)"}`. Quote paths with `{env}` too.
- `default` is ConfigMap only; secrets cannot have defaults. It must be valid
  for the type (`{type: int, default: "3OOO"}` is a lint error).
- Every value is read as plain text: `no`, `on`, `0.30` and `0800` stay
  strings, never YAML booleans or numbers. Quote to keep `#` or spaces.
- Anchors, aliases and tags (`&x`, `*x`, `!!str`) are not allowed.
- Key names are `A-Z`, `0-9` and `_`, starting with a letter. Env names are
  `[A-Za-z0-9_-]+`.
- An env with no entry under `envs` gets only the shared keys. A key may not be
  declared both shared and per env, may not be both ConfigMap and Secret, and
  must have the same type in every env.
- Empty values count as absent.
- `source` at the top is the fallback; `envs.<name>.source` wins for that env.
- The legacy `env.spec` format is still read, with a warning; `envpact convert`
  writes the equivalent `envpact.yml`.
