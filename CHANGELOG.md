# Changelog

## 0.2.0 — 2026-11-22

envpact now talks to [OpenBao](https://openbao.org) (KV v2) and keeps the
env's secrets in sync with the contract.

- **Scope change:** 0.1 read only your files and wrote nothing. 0.2 talks to
  OpenBao and writes `~/.ob_read`, `~/.ob_write` and the `pull` target, always
  mode 0600 (temp file + rename, never through a symlink). Nothing else is
  written, and no secret or token is ever printed.
- **`[source]` section** in `env.spec`: `openbao path=team/app/{env}
  [mount=secret] [addr=URL] [env=a,b]`. API: `spec.source_for(env)`,
  `spec.sources`, `EnvPact::Source.fetch`.
- **`url(schemes)` type:** `url(postgres, redis)` restricts the URL scheme.
- **`login`:** OIDC through a loopback listener, or `--token-stdin`; the token
  is stored AES-256-GCM encrypted under a passphrase in `~/.ob_read` /
  `~/.ob_write`.
- **`unlock` / `lock` / `status`:** a local agent (Unix socket, your uid only)
  holds the read token for a window.
- **`pull`:** secrets into a 0600 `.env.<env>.local`, only if the contract is
  satisfied.
- **`run`:** like `exec`, with the secrets injected into the process only.
- **`push` / `set`:** merge validated secrets into OpenBao after a y/N and the
  write passphrase on the terminal; refused without a terminal.
- **`check --source`:** check with the OpenBao secrets overlaid in memory.
- Tests run with UTF-8 forced; `bundler` dev dependency is capped (`< 5`).

## 0.1.0 — 2026-10-25

envpact is the successor of [envspec](https://rubygems.org/gems/envspec) 0.1.2:
same idea, renamed and redesigned around three checkpoints (local, pre-deploy,
boot). Breaking changes throughout; envspec had no real users.

- **Renamed** gem/module/executable: `envspec`/`EnvSpec` → `envpact`/`EnvPact`.
- **New `check` API:** `spec.check(values, env:, strict:, extras:)` returns a
  `Result` (`ok?`, `errors`, `warnings`, `applied_sections`) of `Problem`s;
  `check!` raises `ValidationError#result`. Replaces `validate`/`validate!`.
  `env:` is always required.
- **Secret masking:** problem messages never include a secret value
  (`Problem#value` is nil for secrets); `check --show-values` reveals them.
- **Empty values count as absent** everywhere.
- **Unknown keys** are warnings (errors with `--strict`) and are never reported
  when checking process ENV.
- **Syntax:** `url` type (validated) replaces `dsn`; new `[shared]` header;
  `#` starts a comment only at line start or after whitespace; quoted defaults
  (`"..."`, escapes `\"` `\\`); CRLF and UTF-8 BOM accepted; a key declared
  as both ConfigMap and Secret, or a default that doesn't match its type, is a
  parse error. Files are read as UTF-8 regardless of locale.
- **CLI:** `check` reads `.env`, `.env.<env>`, `.env.local` (not for test),
  `.env.<env>.local`, or `--from-env`; new `exec` boot wrapper (fills defaults,
  then execs; env from `--env` or `$ENVPACT_ENV`); new `scan-prompt` for AI
  agents; `--spec`/`$ENVPACT_SPEC` on every command; commands return exit codes
  (0/1/2, 127 for `exec` command not found) instead of calling `exit`.
- **Removed:** `init` and the regex scanner/name heuristics (replaced by
  `scan-prompt`).

## envspec history

### 0.1.2 — 2026-05-04

- Split CLI into one file per subcommand under `lib/envspec/cli/`:
  `command.rb` (base class), `lint.rb`, `check.rb`, `init.rb`. Adding a new
  subcommand is now: write a class inheriting from `EnvSpec::CLI::Command`,
  register it in `EnvSpec::CLI::COMMANDS`.
- Aligned formatting in global help.

### 0.1.1 — 2026-05-04

- Refactor CLI into `EnvSpec::CLI` with proper subcommand structure (per-subcommand `OptionParser` with banners, options, and `-h` help). Still pure stdlib.
- `envspec help <command>` and `envspec <command> -h` now show subcommand-specific usage.
- Better exit codes (2 for usage errors, 1 for parse/validation errors, 0 for success).

### 0.1.0 — 2026-05-04

Initial release.

- Parser for `env.spec` syntax v5 (`[secrets]` modifier, `[env: …]` selector, scoped configmap/secrets, types `str | int | bool | dsn | enum`).
- Validator: presence + type-level checks (int/bool/enum/dsn).
- CLI: `envspec lint`, `envspec check`, `envspec init`.
- `init` scans Ruby/Python/JS/Go/Shell sources and generates a starter `env.spec` with heuristic-based suggestions.
- Zero runtime dependencies; Ruby ≥ 2.5.
