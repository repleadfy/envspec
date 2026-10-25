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
