# envpact Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Turn envspec 0.1.2 into envpact 0.1.0: an env var contract checked locally (`.env*`), before deploy (Ruby API for kdep) and at boot (`exec` wrapper), then release it.

**Architecture:** Keep the existing parser/CLI skeleton, rename everything to `EnvPact`, delete the regex scanner/`init`, fix the parser edge cases, replace `validate` with a `check` API returning a `Result` of masked `Problem`s, add a stdlib dotenv loader and the `check`/`exec`/`scan-prompt` commands.

**Tech Stack:** Ruby ≥ 2.5, stdlib only (`optparse`, `uri`), minitest, rake.

**Spec:** `docs/superpowers/specs/2026-10-25-envpact-redesign-design.md` — read it before any task; section numbers below (§N) refer to it.

## Global Constraints

- Zero runtime gem dependencies; stdlib only.
- `required_ruby_version = ">= 2.5.0"` — no `filter_map`, `then`, pattern matching, endless methods, `Hash#except`, numbered block params.
- Gem `envpact`, module `EnvPact`, executable `envpact`, `VERSION = "0.1.0"`. Contract file default `./env.spec`.
- envpact never writes to disk and never prints a secret value unless the CLI user passed `--show-values`.
- envpact never references kdep, Infisical or kubectl.
- Exit codes: 0 ok, 1 contract/validation failure, 2 usage error. No `exit` inside commands.
- Run the suite with `bundle exec rake test` (all tests must pass at every commit).
- Commit messages end with `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`.

## Review Focus

1. **CRLF line endings** in `env.spec` or `.env` (file edited on Windows) — must parse exactly like LF. Test in Task 2 and Task 5.
2. **UTF-8 BOM** at the start of `env.spec` — first key must still parse. Test in Task 2.
3. **`.env` value containing `=`** (`TOKEN=abc==`) — kept intact. Test in Task 5.
4. **`exec` with a command that doesn't exist** — prints `envpact: command not found: <cmd>` and exits 127, no backtrace. Test in Task 8.
5. **`env.spec` missing** for `lint`/`check`/`exec` — prints `envpact: spec not found: <path>` and exits 1, no backtrace. Test in Task 6.

---

### Task 1: Rename to envpact and drop the scanner

**Files:**
- Rename (git mv): `lib/envspec.rb` → `lib/envpact.rb`, `lib/envspec/` → `lib/envpact/`, `envspec.gemspec` → `envpact.gemspec`, `exe/envspec` → `exe/envpact`
- Delete: `lib/envpact/init.rb`, `lib/envpact/scanner.rb`, `lib/envpact/heuristics.rb`, `lib/envpact/cli/init.rb`
- Modify: every `lib/`, `test/`, `exe/` file (`EnvSpec` → `EnvPact`, `envspec` → `envpact` in requires/strings), `lib/envpact/cli.rb` (drop `Init` from requires and `COMMANDS`), `lib/envpact/version.rb` (`"0.1.0"`), `envpact.gemspec` (name, `require "envpact/version"`, `EnvPact::VERSION`, homepage `https://github.com/repleadfy/envpact`, summary "Env var contract for apps: one file, checked locally, before deploy and at boot"), `test/test_helper.rb`

**Interfaces:**
- Produces: `EnvPact` class (same public API as 0.1.2 minus `init`), `require "envpact"`.

- [ ] **Step 1:** Do the renames/deletes/replacements above. `grep -rni envspec lib test exe *.gemspec` must return nothing.
- [ ] **Step 2:** Run `bundle exec rake test` → 38 runs, 0 failures. Run `ruby -Ilib exe/envpact help` → lists `lint`, `check`, `help`, `version` (no `init`).
- [ ] **Step 3:** Commit `refactor: rename envspec to envpact, drop regex scanner and init`.

---

### Task 2: Parser — comments, quoted defaults, CRLF/BOM

**Files:**
- Modify: `lib/envpact/parser.rb`
- Test: `test/test_parser.rb`

**Interfaces:**
- Produces: `Entry#default` holds the unquoted string.

- [ ] **Step 1: Write the failing tests**

```ruby
def test_hash_inside_value_is_kept
  assert_equal "http://x/a#frag", parse("URL = http://x/a#frag").configmap["*"]["URL"].default
end
def test_hash_after_space_is_comment
  assert_equal "info", parse("LOG = info # level").configmap["*"]["LOG"].default
end
def test_quoted_default_keeps_hash_and_spaces
  assert_equal "olá # mundo ", parse(%(GREETING = "olá # mundo ")).configmap["*"]["GREETING"].default
end
def test_quoted_default_escapes
  assert_equal %(a"b\\c), parse(%(K = "a\\"b\\\\c")).configmap["*"]["K"].default
end
def test_unterminated_quote_raises
  assert_raises_parse(/unterminated quoted default/) { parse(%(K = "abc)) }
end
def test_crlf_lines
  spec = parse("A\r\nB: int = 3\r\n")
  assert_equal %w[A B], spec.configmap["*"].keys
  assert_equal "3", spec.configmap["*"]["B"].default
end
def test_utf8_bom
  assert parse("﻿A\n").configmap["*"].key?("A")
end
```

- [ ] **Step 2:** Run `bundle exec rake test TEST=test/test_parser.rb` → the new tests FAIL.
- [ ] **Step 3: Implement** in `parser.rb`: strip a leading `﻿` from the text and `\r` from each line; replace `raw.sub(/#.*/, "")` with `strip_comment(line) -> String`, which walks the line tracking whether it's inside double quotes and cuts at the first `#` that is outside quotes and either at position 0 or preceded by whitespace. In `parse_key_line`, a default starting with `"` must end with an unescaped `"` (else `ParseError "unterminated quoted default"`); unescape `\"` → `"` and `\\` → `\`; unquoted defaults are stripped.
- [ ] **Step 4:** Run `bundle exec rake test` → all pass.
- [ ] **Step 5:** Commit `fix(parser): '#' only starts a comment after whitespace; quoted defaults`.

---

### Task 3: Parser — `url` type, `[shared]`, configmap/secret conflict

**Files:**
- Modify: `lib/envpact/parser.rb`
- Test: `test/test_parser.rb`

**Interfaces:**
- Produces: `EnvPact::VALID_TYPES = %i[str int bool url enum]`.

- [ ] **Step 1: Write the failing tests**

```ruby
def test_url_type
  assert_equal :url, parse("DATABASE_URL: url").configmap["*"]["DATABASE_URL"].type
end
def test_dsn_type_removed
  assert_raises_parse(/unknown type 'dsn'/) { parse("X: dsn") }
end
def test_shared_header_returns_to_shared_scope
  spec = parse("[env: production]\nA\n[secrets]\nS\n[shared]\nB")
  assert spec.configmap["*"].key?("B")
  refute spec.secrets["*"]&.key?("B")
end
def test_key_both_configmap_and_secret_raises
  assert_raises_parse(/'A' declared as both configmap \(line 1\) and secret/) { parse("A\n[secrets]\nA") }
end
def test_configmap_and_secret_in_disjoint_envs_ok
  parse("[env: production]\nA\n[env: staging]\n[secrets]\nA")
end
```

Update existing tests that use `dsn` to `url`.

- [ ] **Step 2:** Run → new tests FAIL.
- [ ] **Step 3: Implement**: `VALID_TYPES` swaps `dsn` for `url`; header `[shared]` sets `scope = [SHARED]`, `type = :configmap`; update the unknown-header message to list `[secrets]`, `[shared]` and `[env: ...]`. In `store_entry`, also call `find_overlapping` on the *other* bucket and raise `ParseError "key 'A' declared as both configmap (line X) and secret (line Y)"` (configmap line first).
- [ ] **Step 4:** Run `bundle exec rake test` → all pass.
- [ ] **Step 5:** Commit `feat(parser): url type, [shared] header, reject configmap+secret key`.

---

### Task 4: `check` API — Problem, Message, Result

**Files:**
- Create: `lib/envpact/problem.rb` (`Problem`, `Message`), `lib/envpact/result.rb`, `lib/envpact/checker.rb`
- Delete: `lib/envpact/validator.rb`; replace `test/test_validator.rb` with `test/test_checker.rb` (port every existing case to the new API)
- Modify: `lib/envpact.rb` (requires), `lib/envpact/errors.rb` (`ValidationError` wraps a `Result`), `lib/envpact/cli/check.rb` (temporarily: call `check!` against `ENV.to_h`, `extras: false`, so the suite stays green until Task 7)

**Interfaces:**
- Produces:
  - `EnvPact::Problem = Struct.new(:kind, :key, :secret, :line, :value, :type, :enum_values, keyword_init: true)` — `kind` ∈ `:missing, :invalid, :extra`; `value` nil for secrets and extras; `#message -> String` = `Message.format(self)`.
  - `EnvPact::Message.format(problem, value: problem.value) -> String`.
  - `EnvPact::Result` — `#ok? #errors #warnings #applied_sections #env`.
  - `EnvPact#check(values, env:, strict: false, extras: true) -> Result`; `#check!(...)` raises `EnvPact::ValidationError` (`#result`, message = header + `"  - "` lines of error messages).
  - `EnvPact::ValidationError#result -> Result`.

Exact message copy (§4):
- missing: `missing required env var 'KEY' (declared at line N)`
- invalid, configmap: `env var 'KEY' = "abc" is not a valid int` · bool: `env var 'KEY' = "x" is not a valid bool (expected true/false/1/0/yes/no)` · enum: `env var 'KEY' = "x" is not in enum(a, b)` · url: `env var 'KEY' = "x" is not a valid url`
- invalid, secret (no value given to `format`): same texts with `= "…"` replaced by `(secret)`, e.g. `env var 'KEY' (secret) is not a valid int`
- extra: `unknown env var 'KEY' (not declared in spec)`

- [ ] **Step 1: Write the failing tests** (`test/test_checker.rb`, besides the ported cases):

```ruby
def test_env_is_required_keyword
  assert_raises(ArgumentError) { spec("A").check({}) }
end
def test_empty_counts_as_missing
  r = spec("A").check({ "A" => "" }, env: "x")
  assert_equal [:missing], r.errors.map(&:kind)
end
def test_empty_with_default_is_ok_and_not_type_checked
  assert spec("PORT: int = 3000").check({ "PORT" => "" }, env: "x").ok?
end
def test_secret_value_never_in_message
  r = spec("[secrets]\nDB_PORT: int").check({ "DB_PORT" => "hunter2" }, env: "x")
  assert_equal "env var 'DB_PORT' (secret) is not a valid int", r.errors.first.message
  assert_nil r.errors.first.value
end
def test_configmap_value_in_message
  r = spec("PORT: int").check({ "PORT" => "abc" }, env: "x")
  assert_equal %(env var 'PORT' = "abc" is not a valid int), r.errors.first.message
end
def test_message_format_can_reveal
  r = spec("[secrets]\nDB_PORT: int").check({ "DB_PORT" => "hunter2" }, env: "x")
  assert_match(/"hunter2"/, EnvPact::Message.format(r.errors.first, value: "hunter2"))
end
def test_extras_are_warnings_by_default
  r = spec("A").check({ "A" => "1", "B" => "2" }, env: "x")
  assert r.ok?
  assert_equal ["unknown env var 'B' (not declared in spec)"], r.warnings.map(&:message)
end
def test_extras_are_errors_when_strict
  refute spec("A").check({ "A" => "1", "B" => "2" }, env: "x", strict: true).ok?
end
def test_extras_false_ignores_unknown_keys
  r = spec("A").check({ "A" => "1", "PATH" => "/bin" }, env: "x", extras: false, strict: true)
  assert r.ok?
  assert_empty r.warnings
end
def test_lowercase_extras_ignored
  assert_empty spec("A").check({ "A" => "1", "lower" => "x" }, env: "x").warnings
end
def test_url_validation
  s = spec("U: url")
  %w[postgres://u:p@h:5432/db redis://h:6379/0 https://x.y].each { |v| assert s.check({ "U" => v }, env: "x").ok?, v }
  ["localhost:3000", "not a url"].each { |v| refute s.check({ "U" => v }, env: "x").ok?, v }
end
def test_applied_sections
  s = spec("A\n[env: production]\nB")
  assert_equal %w[shared production], s.check({ "A" => "1", "B" => "1" }, env: "production").applied_sections
  assert_equal %w[shared], s.check({ "A" => "1" }, env: "prod").applied_sections
end
def test_check_bang_raises_with_result
  err = assert_raises(EnvPact::ValidationError) { spec("A").check!({}, env: "x") }
  assert_equal [:missing], err.result.errors.map(&:kind)
end
```

- [ ] **Step 2:** Run → FAIL.
- [ ] **Step 3: Implement** per the Interfaces block. `applied_sections` is `["shared"]` plus `env` when `env` is a key of `configmap` or `secrets`. `url`: `URI.parse(v)` (rescue `URI::InvalidURIError`) with non-nil `scheme` and non-empty `host`. Extra keys: names matching `/\A[A-Z][A-Z0-9_]*\z/` not in the merged key set; skipped entirely when `extras: false`.
- [ ] **Step 4:** Run `bundle exec rake test` → all pass.
- [ ] **Step 5:** Commit `feat: check API with Result, masked Problems; empty counts as absent`.

---

### Task 5: Dotenv loader

**Files:**
- Create: `lib/envpact/dotenv.rb`
- Test: `test/test_dotenv.rb`

**Interfaces:**
- Produces: `EnvPact::Dotenv.parse(text) -> Hash{String=>String}`; `EnvPact::Dotenv.files_for(env) -> Array<String>`; `EnvPact::Dotenv.load(dir, env:) -> { files: Array<String> (basenames actually read, in order), values: Hash }`.

- [ ] **Step 1: Write the failing tests**

```ruby
def test_parse_basic
  assert_equal({ "A" => "1", "B" => "two words", "C" => "lit $X", "D" => "x" },
    EnvPact::Dotenv.parse(%(A=1\nexport B="two words"\nC='lit $X'\n# c\n\nD=x # tail\n)))
end
def test_parse_keeps_equals_in_value
  assert_equal "abc==", EnvPact::Dotenv.parse("TOKEN=abc==")["TOKEN"]
end
def test_parse_crlf
  assert_equal({ "A" => "1", "B" => "2" }, EnvPact::Dotenv.parse("A=1\r\nB=2\r\n"))
end
def test_parse_double_quote_escapes
  assert_equal "a\nb\"c", EnvPact::Dotenv.parse(%(A="a\\nb\\"c"))["A"]
end
def test_lines_without_equals_ignored
  assert_equal({}, EnvPact::Dotenv.parse("garbage\n"))
end
def test_files_for
  assert_equal %w[.env .env.development .env.local .env.development.local], EnvPact::Dotenv.files_for("development")
  assert_equal %w[.env .env.test .env.test.local], EnvPact::Dotenv.files_for("test")
end
def test_load_overrides_in_order_and_skips_missing
  Dir.mktmpdir do |d|
    File.write(File.join(d, ".env"), "A=1\nB=1\n")
    File.write(File.join(d, ".env.local"), "B=2\n")
    r = EnvPact::Dotenv.load(d, env: "development")
    assert_equal %w[.env .env.local], r[:files]
    assert_equal({ "A" => "1", "B" => "2" }, r[:values])
  end
end
```

- [ ] **Step 2:** Run → FAIL.
- [ ] **Step 3: Implement** per Interfaces: key regex `[A-Za-z_][A-Za-z0-9_]*`, optional `export ` prefix, split on the first `=`; single quotes literal; double quotes unescape `\n`, `\"`, `\\`; unquoted values cut at ` #` and stripped. No interpolation, no multiline (§5).
- [ ] **Step 4:** Run `bundle exec rake test` → all pass.
- [ ] **Step 5:** Commit `feat: stdlib dotenv loader with dotenv file order`.

---

### Task 6: CLI framework fixes and `lint`

**Files:**
- Modify: `lib/envpact/cli.rb`, `lib/envpact/cli/command.rb`, `lib/envpact/cli/lint.rb`, `lib/envpact/errors.rb`
- Test: `test/test_cli.rb` (create; helper `run_cli(*argv) -> [code, out, err]` via `capture_io { EnvPact::CLI.run(argv) }`)

**Interfaces:**
- Produces:
  - Command DSL `command_name "lint"` (replaces `name`, so `Class#name` is untouched), `summary`, `banner`, `description`.
  - `EnvPact::CLI::UsageError < EnvPact::Error` → dispatcher returns 2; `EnvPact::Error` (incl. `ParseError`) → 1; `OptionParser::ParseError` → 2.
  - `Command#spec_option(o, opts)` adds `--spec=PATH`; `Command#load_spec(opts) -> EnvPact` resolves `opts[:spec] || ENV["ENVPACT_SPEC"] || "env.spec"` and raises `EnvPact::Error "spec not found: <path>"` when absent.
  - `-h` prints help and makes `run` return 0 (no `exit`).

- [ ] **Step 1: Write the failing tests**

```ruby
def test_command_class_name_untouched
  assert_equal "EnvPact::CLI::Lint", EnvPact::CLI::Lint.name
end
def test_lint_ok_with_spec_flag
  Dir.mktmpdir do |d|
    File.write(p = File.join(d, "env.spec"), "A\n")
    code, out, = run_cli("lint", "--spec=#{p}")
    assert_equal 0, code
    assert_match(/valid/, out)
  end
end
def test_lint_uses_envpact_spec_env_var
  # write spec, set ENV["ENVPACT_SPEC"] in ensure-restored block, run_cli("lint") → 0
end
def test_lint_parse_error_exits_1
  # spec "x" (lowercase) → code 1, err matches /line 1: invalid key line/
end
def test_missing_spec_exits_1_without_backtrace
  code, _, err = run_cli("lint", "--spec=/nonexistent/env.spec")
  assert_equal 1, code
  assert_equal "envpact: spec not found: /nonexistent/env.spec\n", err
end
def test_help_flag_returns_0
  assert_equal 0, run_cli("lint", "-h").first
end
def test_unknown_option_exits_2
  assert_equal 2, run_cli("lint", "--nope").first
end
```

- [ ] **Step 2:** Run → FAIL.
- [ ] **Step 3: Implement** per Interfaces. `lint` drops its positional file argument.
- [ ] **Step 4:** Run `bundle exec rake test` → all pass.
- [ ] **Step 5:** Commit `refactor(cli): return exit codes, --spec/ENVPACT_SPEC, command_name DSL`.

---

### Task 7: `check` command

**Files:**
- Modify: `lib/envpact/cli/check.rb`
- Test: `test/test_cli.rb`

**Interfaces:**
- Consumes: `EnvPact#check`, `Message.format`, `Dotenv.load`, `Command#load_spec`.
- Produces: `envpact check --env=NAME [--spec=PATH] [--strict] [--show-values] [--from-env]`.

Output copy (§3): success line `✓ env.spec satisfied (env: production — shared + [env: production])` or `✓ env.spec satisfied (env: prod — shared only; sections in spec: production, staging)` (omit `; sections in spec: …` when the spec has none). Failure: `✗ env.spec not satisfied (env: …same suffix…)` then `  - <message>` per error, to stderr, exit 1. Warnings: `  ! <message>` to stderr in both cases. File mode prints `Read: .env, .env.test` first (or `Read: (no .env files found)`). The label uses the `--spec` basename.

- [ ] **Step 1: Write the failing tests** (each in a `Dir.mktmpdir` + `Dir.chdir` with `env.spec` and `.env*` files):

```ruby
def test_check_requires_env
  assert_equal 2, run_cli("check").first
end
def test_check_reads_dotenv_files_for_env
  # env.spec "A\nB", .env "A=1", .env.test "B=2" → code 0, out matches /Read: .env, .env.test/ and /shared only/
end
def test_check_reports_applied_section
  # env.spec "A\n[env: production]\nB", .env "A=1\nB=2", --env=production → out includes "shared + [env: production]"
end
def test_check_failure_lists_problems
  # env.spec "A\nB", .env "A=1" → code 1, err includes "missing required env var 'B'"
end
def test_check_masks_secrets_unless_show_values
  # env.spec "[secrets]\nP: int", .env "P=hunter2" → err refute_match /hunter2/; with --show-values → assert_match /hunter2/
end
def test_check_extras_warn_and_strict_fails
  # env.spec "A", .env "A=1\nZ=9" → code 0, err includes "! unknown env var 'Z'"; with --strict → code 1
end
def test_check_from_env_ignores_extras
  # ENV["A"]="1" (restored in ensure), env.spec "A", run_cli("check", "--env=x", "--from-env", "--strict") → 0, no "unknown env var" in err
end
```

- [ ] **Step 2:** Run → FAIL.
- [ ] **Step 3: Implement**: file mode → `Dotenv.load(Dir.pwd, env:)`, `extras: true`; `--from-env` → `ENV.to_h`, `extras: false`. With `--show-values`, print each `:missing`/`:invalid` problem as `Message.format(p, value: values[p.key])`. Extras never show a value, even with `--show-values` (§4).
- [ ] **Step 4:** Run `bundle exec rake test` → all pass.
- [ ] **Step 5:** Commit `feat(cli): check against .env files or process ENV, with masking`.

---

### Task 8: `exec` command

**Files:**
- Create: `lib/envpact/cli/exec.rb`; register `"exec" => Exec` in `COMMANDS`
- Test: `test/test_exec.rb` (subprocess tests via `Open3.capture3("ruby", "-Ilib", "exe/envpact", ...)` with an explicit env hash and `unsetenv_others: false`)

**Interfaces:**
- Consumes: `EnvPact#check`, `Command#load_spec`.
- Produces: `envpact exec [--env=NAME] [--spec=PATH] -- CMD [ARGS...]`. Env from `--env`, else `ENV["ENVPACT_ENV"]`, else `UsageError`. No CMD → `UsageError`.

- [ ] **Step 1: Write the failing tests**

```ruby
def test_exec_runs_command_when_satisfied
  # spec "A", env {"A"=>"1"}, cmd: ruby -e 'print ENV["A"]' → status 0, stdout "1"
end
def test_exec_fills_defaults_for_absent_and_empty
  # spec "PORT: int = 3000", env {"PORT"=>""} → cmd prints ENV["PORT"] → "3000"
end
def test_exec_refuses_to_start_on_failure
  # spec "A", env {} → status 1, stdout "" (command never ran), stderr includes "missing required env var 'A'"
end
def test_exec_never_prints_secret_values
  # spec "[secrets]\nP: int", env {"P"=>"hunter2"} → status 1, stderr refute_match /hunter2/
end
def test_exec_env_from_envpact_env
  # spec "A\n[env: production]\nB", env {"ENVPACT_ENV"=>"production","A"=>"1"} → status 1 (B missing)
end
def test_exec_command_not_found
  # spec "A", env {"A"=>"1"}, cmd "definitely-not-a-command-xyz" → status 127, stderr == "envpact: command not found: definitely-not-a-command-xyz\n"
end
def test_exec_without_command_is_usage_error
  # → status 2
end
```

- [ ] **Step 2:** Run → FAIL.
- [ ] **Step 3: Implement**: `check(ENV.to_h, env:, extras: false)`; on failure print `✗ env.spec not satisfied (env: …)` + masked problems to stderr, return 1; on success set `ENV[k] = entry.default` for every merged entry with a default whose ENV value is nil or empty, then `Kernel.exec(*cmd)`; rescue `Errno::ENOENT` → message above, return 127. Split args on the first `--` before OptionParser sees them.
- [ ] **Step 4:** Run `bundle exec rake test` → all pass.
- [ ] **Step 5:** Commit `feat(cli): exec wrapper validates ENV and replaces itself with the app`.

---

### Task 9: `scan-prompt` and the shared syntax reference

**Files:**
- Create: `lib/envpact/syntax.md` (the syntax reference from §2, incl. `[shared]`, `url`, comment/quote rules, types), `lib/envpact/scan_prompt.md` (template with the literal placeholder `{{SYNTAX}}`), `lib/envpact/scan_prompt.rb`, `lib/envpact/cli/scan_prompt.rb`; register `"scan-prompt" => ScanPromptCommand`
- Modify: `README.md` (rewrite for envpact; embed `lib/envpact/syntax.md` verbatim as its syntax section; document lint/check/exec/scan-prompt, the Ruby API from §7, and the Infisical composition example from §5)
- Test: `test/test_scan_prompt.rb`

**Interfaces:**
- Produces: `EnvPact::ScanPrompt.render -> String` (template with `{{SYNTAX}}` replaced by `syntax.md`); CLI `envpact scan-prompt` prints it, exit 0.

The prompt content is §6 items 1–5, written as direct instructions to an agent, including verbatim: "never copy values into the contract or the transcript" and the `# TODO(envpact): …` convention.

- [ ] **Step 1: Write the failing tests**

```ruby
def test_render_embeds_syntax_and_has_no_placeholder
  out = EnvPact::ScanPrompt.render
  assert_includes out, File.read(File.expand_path("../lib/envpact/syntax.md", __dir__))
  refute_includes out, "{{SYNTAX}}"
end
def test_prompt_forbids_copying_values
  assert_includes EnvPact::ScanPrompt.render, "never copy values into the contract or the transcript"
end
def test_readme_syntax_matches_gem_reference
  readme = File.read(File.expand_path("../README.md", __dir__))
  assert_includes readme, File.read(File.expand_path("../lib/envpact/syntax.md", __dir__)), "README syntax section drifted from lib/envpact/syntax.md"
end
def test_cli_scan_prompt
  # run_cli("scan-prompt") → code 0, out == ScanPrompt.render + "\n" (or exactly render, builder's choice — assert consistently)
end
```

- [ ] **Step 2:** Run → FAIL.
- [ ] **Step 3: Implement** the files above; `ScanPrompt` reads both `.md` files relative to `__dir__` (they ship via `lib/**/*` in the gemspec).
- [ ] **Step 4:** Run `bundle exec rake test` → all pass. Manually run `ruby -Ilib exe/envpact scan-prompt | head -40` and read it as the agent would.
- [ ] **Step 5:** Commit `feat: scan-prompt for agents; README shares the gem's syntax reference`.

---

### Task 10: CHANGELOG, final verification, PR

**Files:**
- Modify: `CHANGELOG.md` (new top entry `## 0.1.0 — <date>`: "envpact is the successor of envspec 0.1.2", then the changes per spec §8; keep envspec history below under `## envspec history`)

- [ ] **Step 1:** Write the CHANGELOG entry.
- [ ] **Step 2:** Verify: `bundle exec rake test` → 0 failures; `gem build envpact.gemspec` → builds `envpact-0.1.0.gem`; `gem spec envpact-0.1.0.gem files | grep -c md` includes `syntax.md` and `scan_prompt.md`; `ruby -Ilib exe/envpact help` lists lint, check, exec, scan-prompt, help, version. Delete the built `.gem` (don't commit it).
- [ ] **Step 3:** Commit `docs: changelog for envpact 0.1.0`. Push the branch and open a PR (body ends with `🤖 Generated with [Claude Code](https://claude.com/claude-code)`).

---

### Task 11: Release (needs Tom's go-ahead at each outward step)

Outward-facing and hard to reverse — confirm with Tom before each of steps 1, 3 and 5.

- [ ] **Step 1:** Merge the PR.
- [ ] **Step 2:** Rename the GitHub repo: `gh repo rename envpact --repo repleadfy/envspec`; update the local remote (`git remote set-url origin git@github.com:repleadfy/envpact.git`); rename the local dir `~/leadfy/code/envspec` → `~/leadfy/code/envpact` (last, after the session no longer needs the old path).
- [ ] **Step 3:** On updated `main`: `gem build envpact.gemspec` → `gem push envpact-0.1.0.gem`. Per `~/.claude/CLAUDE.md`: plain `gem push` works; if it fails, retry the push — don't test the key via `/api/v1/profile/me` (401 there is expected).
- [ ] **Step 4:** Verify: `gem list -r envpact` shows `0.1.0`; `gem install envpact && envpact version` → `0.1.0`.
- [ ] **Step 5:** Update the skill in `~/leadfy/code/leadfy-ai-plugins`: rename `plugins-claude-code/leadfy-dev-base/skills/envspec/` → `.../envpact/`, rewrite `SKILL.md` for envpact (commands, syntax, scan-prompt, kdep/Infisical relationship; keep "envspec" and "env.spec" as trigger phrases) and `trigger-eval.json`. Load `leadfy-plugins-management:leadfy-skill-conventions` first and follow that repo's release flow (version bump, README via `update-plugins-readme`).
- [ ] **Step 6:** Hand off: kdep's dependency switch (`envspec ~> 0.1` → `envpact ~> 0.1`) and the §9 integration are the separate kdep plan.
