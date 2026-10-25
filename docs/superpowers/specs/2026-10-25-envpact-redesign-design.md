# envpact — redesign of envspec

**Author:** Tom (with Claude)
**Date:** 2026-10-25
**Status:** Design; awaiting approval.
**Scope:** This repo (rename + redesign of envspec 0.1.2). Section 9 records the
contract kdep will build against; the kdep changes themselves are a separate
plan in the kdep repo.

---

## 0. Intent

One file per repo — the **contract** — declares which env vars the app needs:
name, type, required/optional, default, secret-or-configmap, and per-env
differences. It never holds values. The same contract is checked at three
moments, so a missing or malformed var is caught as early as possible:

1. **Local dev/test** — against the developer's `.env*` files.
2. **Before deploy** — kdep assembles the values that *will* be in the cluster
   (kdep ConfigMap + secrets source) and asks envpact to check them. Failure
   blocks the deploy.
3. **App boot** — an entrypoint wrapper checks the real process ENV inside the
   container and refuses to start the app if the contract isn't met.

Ruby is the house language; kdep is Ruby; every image can have Ruby installed.
The tool stays small, stdlib-only, home-made, and easy to maintain.

### Why now

envspec 0.1.2 exists but nothing uses it yet (the only `env.spec` in
`~/leadfy/code` is kdep's untouched template). Renaming, changing syntax and
breaking the API are free today. Infisical is coming to the cluster; the
contract has to work before Infisical (values from `secrets.yml`) and after it
(values from Infisical) without changing.

### Goals

- One contract, three checkpoints, same validation rules everywhere.
- Decoupled: envpact knows nothing about kdep or Infisical. Its whole interface
  is **contract + env name + values → ok | list of problems**.
- No copying of `.env` / `secrets.yml` between people. (Achieved by Infisical
  holding dev/test values; envpact's part is only to verify keys and types.)
- Prod values may pass through memory for checking, never to disk, never to a
  running process on a dev machine, never printed.

### Non-goals

- **No value storage or sync.** Moving values around is Infisical's job
  (`infisical run`, `infisical export`, the k8s operator).
- **No code scanning.** Replaced by `scan-prompt` (section 6) — Claude reads
  codebases far better than regexes.
- **No generation** of `.env.example`, manifests, Infisical keys, etc.
- **No per-env defaults.** Env-specific values come from `.env.<env>` /
  `app.yml`; the contract's default is a single fallback.

### Anti-goals (failure even if it "works")

- A secret value appearing in any output (terminal, CI log, agent transcript).
- envpact writing anything to disk.
- envpact importing or calling kdep / Infisical / kubectl.
- Runtime gem dependencies.

---

## 1. Name

**envpact** — Tom's choice (2026-10-25). Free on RubyGems as of that date.

- Gem `envpact`, module `EnvPact`, executable `envpact`, version restarts at
  `0.1.0`.
- The contract file stays **`env.spec`** at the repo root (my call — the name
  describes the file well and kdep's template already uses it).
- The old `envspec` gem: leave 0.1.2 published; kdep switches its dependency.
  Yanking is Tom's call, not part of this work.
- **Done = released.** Tom: publish as soon as everything is solid. The plan
  ends with the full release: rename the GitHub repo (`repleadfy/envspec` →
  `repleadfy/envpact`) and local dir, PR → merge, `gem build envpact.gemspec`
  → `gem push envpact-0.1.0.gem`, then update the `leadfy-dev-base:envspec`
  skill to document envpact. kdep's dependency switch (and
  `kdep-update-all-rubies`) belongs to the follow-up kdep plan (§9).

---

## 2. Contract syntax

The current syntax stays. The **top of the file is the shared default for every
env, whatever its name**. `[env: …]` sections exist only for envs that differ
from that default.

```
# shared (all envs)
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
```

- `KEY` — required str, configmap, in scope.
- `KEY?` — optional.
- `KEY: type` — `str | int | bool | url | enum(a, b, c)`.
- `KEY = default` — configmap only; secrets cannot have defaults.
- `[secrets]` — modifier: following keys are secrets, scope unchanged.
- `[env: a, b]` — selector: scope → those envs, type resets to configmap.
- `[shared]` — selector: scope → back to shared (all envs), type resets to
  configmap. Same semantics as `[env: …]`, just targeting the shared scope.
  Shared keys normally go on top (that's the default, no header needed);
  `[shared]` lets a file return to shared scope after an `[env: …]` section
  (Tom's call, name chosen over `reset-env`).

### Changes from 0.1.2

1. **Comments.** `#` starts a comment only at line start (after optional
   whitespace) or when preceded by whitespace. `COLOR = #fff` → still a
   comment (space before `#`), so values containing ` #` must be quoted.
   `URL = http://x/a#frag` → default is `http://x/a#frag`.
2. **Quoted defaults.** `KEY = "value with # or trailing spaces "`. Double
   quotes only; `\"` and `\\` are the only escapes. Unquoted defaults are
   stripped.
3. **`dsn` → `url`.** Validated (section 4). `dsn` is removed, not aliased —
   nobody uses it yet.
4. **Same key as configmap and secret** in overlapping scopes → `ParseError`.
   (0.1.2 allowed it silently.)
5. **New `[shared]` header** (see above).

Everything else (key regex `[A-Z][A-Z0-9_]*`, env name regex
`[A-Za-z0-9_-]+`, overlapping-scope error, cross-env type consistency) stays.

---

## 3. Environment semantics

- **An env name is always required** to check (CLI `--env`, API `env:`).
  There is no "check without env" — Tom: deploying without picking one should
  be an error.
- **Any name is valid.** An env with no `[env: …]` section gets the shared
  keys only. This is deliberate (see section 2).
- **Accepted trade-off:** a typo (`prod` vs `production`) is not an error; it
  silently gets only shared keys. Mitigation: every check result reports which
  sections were applied, and the CLI prints it on success *and* failure:
  - `✓ env.spec satisfied (env: production — shared + [env: production])`
  - `✓ env.spec satisfied (env: prod — shared only; sections in spec: production, staging)`

  Callers that know their env list (kdep) can enforce stricter rules on their
  side. The result object exposes `applied_sections` and `spec.envs` for that.

---

## 4. Validation rules

Input: contract, env name, a `Hash{String => String}` of values.

| Problem | Kind | When |
|---|---|---|
| Required key absent or empty, no default | `missing` | always |
| Value doesn't parse as declared type | `invalid` | always |
| Key in values but not in contract | `extra` | reported as **warning** by default; error with `strict: true` |

- **Empty is absent** (my call), everywhere: a key set to `""` is treated
  exactly like an unset key — counts as `missing` if required without
  default, skips the type check if optional, and `exec` replaces it with the
  default when one exists. So `PORT: int = 3000` with `PORT=""` boots with
  `PORT=3000`, never with `PORT=""`. kdep's pre-deploy assembly must follow
  the same rule (an app.yml value of `""` counts as absent).
- Optional keys and keys with defaults may be absent.
- `int`: `Integer(v, 10)`. `bool`: `true false 1 0 yes no` (case-insensitive).
  `enum`: exact match. `url`: `URI.parse` succeeds and has a scheme and a host
  (`postgres://u:p@h:5432/db`, `redis://h:6379/0`, `https://x.y` pass;
  `localhost:3000`, `not a url` fail).
- **Extras in process-ENV mode** (`check --from-env`, `exec`) are never
  reported — the process ENV is full of `PATH`, `HOME`, etc. Extras only make
  sense when the caller hands over exactly the app's values (kdep, `.env*`).
- Extra-key detection only considers names matching the key regex.

### Secret masking (hard rule)

- Problem messages for **secret** keys never include the value:
  `'DB_PORT' (secret) is not a valid int`.
- Configmap problems include the value: `'PORT' = "abc" is not a valid int`.
- CLI `--show-values` reveals secret values in messages (local debugging).
  `Problem` never carries a secret value: `Problem#value` is set for
  configmap keys and `nil` for secrets. Message wording lives in one place,
  `EnvPact::Message.format(problem, value: nil)`; `Problem#message` is that
  call with the problem's own (masked) value. The CLI, which already holds
  the values hash it passed in, calls `Message.format(problem, value:
  values[problem.key])` when `--show-values` is set (my call).
- An `extra` key's value is never printed (we don't know if it's secret).

### Result object

```ruby
result = spec.check(values, env: "production", strict: false)
result.ok?               # no errors (warnings allowed)
result.errors            # [Problem]  missing / invalid (+ extra if strict)
result.warnings          # [Problem]  extra (non-strict)
result.applied_sections  # ["shared", "production"]
Problem = Struct(:kind, :key, :secret, :line, :value)    # value nil for secrets
problem.message          # masked text, via EnvPact::Message.format
spec.check!(values, env:, strict:)  # raises EnvPact::ValidationError(result)
```

---

## 5. CLI

Every command returns an exit code (0 ok, 1 contract/validation failure,
2 usage error). No `exit` calls deep inside commands (0.1.2's `-h` and
`require_file` exit directly — fix). Contract path defaults to `./env.spec`,
overridable with `--spec=PATH` or `ENVPACT_SPEC`.

### `envpact lint [--spec=PATH]`
Parses the contract; reports syntax errors with line numbers.

### `envpact check --env=NAME [--strict] [--show-values] [--from-env]`
- Default source: dotenv files in the current dir, loaded in order, later
  overriding earlier: `.env`, `.env.<env>`, `.env.local`, `.env.<env>.local`.
  `.env.local` is skipped when env is `test` (dotenv convention — my call).
  Missing files are skipped; the files actually read are printed.
- `--from-env`: validate the current process ENV instead (no files).
- Dotenv parsing (stdlib, minimal): `KEY=value`, optional `export ` prefix,
  blank lines, `#` comments, single/double quoted values; no variable
  interpolation, no multiline (my call — document it).

### `envpact exec --env=NAME [--spec=PATH] -- CMD [ARGS…]`
The boot check. Env name also from `ENVPACT_ENV` when `--env` is absent (so an
image/deploy can set it once). Validates process ENV; on success, sets
defaults for absent keys that have one (so the app sees the same values the
cluster ConfigMap would carry — my call), then `Kernel.exec` the command
(process replaced, signals and PID 1 behave as if envpact weren't there). On
failure prints problems to stderr and exits 1 without starting CMD.

Composes with Infisical locally without coupling:
`infisical run --env=dev -- envpact exec --env=development -- bin/rails s`.

### `envpact scan-prompt`
See section 6.

### `envpact help [cmd]`, `envpact version`
As today.

Removed: `init`.

---

## 6. `scan-prompt`

Prints (stdout, Markdown) a self-contained instruction set for an AI agent
(Claude) to build or update `env.spec` for the repo it is run in. Typical use:
`envpact scan-prompt | claude` or paste into a session. The prompt must contain
everything needed; the agent should not need any other docs:

1. **Discover** every env var the app reads, in any language and place:
   source code (`ENV[]`/`ENV.fetch`, `os.environ`/`getenv`, `process.env`,
   `import.meta.env`, `os.Getenv`, framework config like Rails
   `credentials`/`config/*.yml` ERB, etc.), Dockerfiles, compose files, CI
   workflows, Helm/kdep `app.yml` configmap, `kdep/*/secrets.yml` key names,
   `.env*` files (key names only — **never copy values into the contract or the
   transcript**), README/docs.
2. **Classify** each: secret vs configmap; type; optional (code tolerates
   absence/has a fallback) vs required; default (only literal, non-secret
   defaults); shared vs specific env.
3. **Write** `env.spec` using the full syntax reference (embedded in the
   prompt, generated from the same source as the README section so they never
   drift). If `env.spec` exists, update it in place, preserving comments and
   existing decisions; never silently drop keys — flag them.
4. Mark uncertain decisions with `# TODO(envpact): …` comments above the key.
5. Run `envpact lint` and fix until it passes; then summarize what was found,
   what's uncertain, and keys that appear unused.

The prompt text lives in the gem (`lib/envpact/scan_prompt.md`), so it
versions with the syntax.

---

## 7. Library API

```ruby
require "envpact"
spec = EnvPact.parse_file("env.spec")   # or EnvPact.parse(text)
spec.envs                     # env names that have sections
spec.configmap_for("production")  # merged shared + env, {key => Entry}
spec.secrets_for("production")
spec.check(values, env:, strict: false)   # → Result (section 4)
spec.check!(values, env:, strict: false)
EnvPact::Dotenv.load(dir, env:)           # → {files:, values:} (used by CLI)
```

`env:` is a required keyword everywhere it appears. `configmap_for` /
`secrets_for` take any env name (kdep's renderer uses them).

---

## 8. What goes away / gets fixed from 0.1.2

| 0.1.2 issue | Resolution |
|---|---|
| `#` truncates values | §2 comment rule + quoting |
| Unknown env silently passes | Accepted by design; reported via applied sections (§3) |
| `--strict` unusable on process ENV | Extras never reported in ENV mode (§4) |
| `dsn` not validated | Replaced by validated `url` (§2, §4) |
| Key both configmap and secret | ParseError (§2) |
| Init name heuristics misfire | `init`, `scanner.rb`, `heuristics.rb`, `init.rb` deleted (§6) |
| `Command.name` overrides `Class#name` | Rename the DSL method (e.g. `command_name`) |
| `exit` inside commands | Return exit codes only (§5) |
| Secret values in error messages | Masking (§4) |
| Only parser/validator tested | Tests for every command, dotenv loader, masking, exec (exec via a subprocess test) |

Constraints kept: stdlib only, no runtime deps, Ruby ≥ 2.5 (kdep's floor),
minitest.

---

## 9. kdep integration contract (for the follow-up kdep plan)

Not built in this repo; recorded so the API above serves it.

- **Pre-deploy check** (in `bump`/`apply`, before applying): kdep builds
  `values = resolved ConfigMap (app.yml + overlay + contract defaults)
  ∪ secrets source`, where secrets source is `kdep/<deploy>/secrets.yml` today
  and an **in-memory** fetch from Infisical later. Calls
  `spec.check(values, env: <name>, strict: false)`; errors block the deploy,
  warnings are shown. Prod secret values are fetched only into memory and
  discarded.
- **Env name mapping is kdep's concern.** envpact only receives a name. kdep
  decides how its deploy target/overlay maps to a contract env (and, later, to
  an Infisical env slug) — e.g. an `app.yml` setting. kdep must always pass a
  name (no `"*"`).
- **Boot check:** kdep may wrap the container command with
  `envpact exec -- …` and set `ENVPACT_ENV` when the repo has a contract. The
  image must have Ruby + the gem; kdep may also ship `env.spec` into the image
  or mount it.
- **`kdep env check`** (live cluster) keeps working; switches to `strict:
  false` so ConfigMap keys kdep deliberately allows outside the contract are
  warnings, not failures.
- Known kdep bugs to fix in that plan (found 2026-10-24): renderer derives
  Infisical env from namespace suffix while the contract env comes from the CLI
  arg; renderer/`env check` disagree on extras; renderer emits no Secret at all
  when the contract has no secrets for the env — check that `envFrom` doesn't
  still reference it.

---

## 10. Left to the builder

- Internal file layout, class names beyond the public API above.
- Exact wording of CLI output and messages (keeping masking + applied
  sections).
- Whether `scan-prompt`'s embedded syntax reference is generated at build time
  or read from a shared file at runtime.
- Test structure.
