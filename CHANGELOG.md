# Changelog

## 0.1.2 — 2026-05-04

- Split CLI into one file per subcommand under `lib/envspec/cli/`:
  `command.rb` (base class), `lint.rb`, `check.rb`, `init.rb`. Adding a new
  subcommand is now: write a class inheriting from `EnvSpec::CLI::Command`,
  register it in `EnvSpec::CLI::COMMANDS`.
- Aligned formatting in global help.

## 0.1.1 — 2026-05-04

- Refactor CLI into `EnvSpec::CLI` with proper subcommand structure (per-subcommand `OptionParser` with banners, options, and `-h` help). Still pure stdlib.
- `envspec help <command>` and `envspec <command> -h` now show subcommand-specific usage.
- Better exit codes (2 for usage errors, 1 for parse/validation errors, 0 for success).

## 0.1.0 — 2026-05-04

Initial release.

- Parser for `env.spec` syntax v5 (`[secrets]` modifier, `[env: …]` selector, scoped configmap/secrets, types `str | int | bool | dsn | enum`).
- Validator: presence + type-level checks (int/bool/enum/dsn).
- CLI: `envspec lint`, `envspec check`, `envspec init`.
- `init` scans Ruby/Python/JS/Go/Shell sources and generates a starter `env.spec` with heuristic-based suggestions.
- Zero runtime dependencies; Ruby ≥ 2.5.
