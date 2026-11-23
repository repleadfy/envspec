# Task: build or update this repo's envpact.yml

You are working in a code repository. Produce `envpact.yml` at the repo root: the
env var contract for this app, checked by `envpact` locally, before deploy and at
boot. The contract lists **names, types and rules only — never values.**

## 1. Discover every env var the app reads

Search the whole repo, in every language and place, for example:

- Code: Ruby `ENV["X"]`, `ENV.fetch("X", ...)`; Python `os.environ[...]`,
  `os.environ.get`, `os.getenv`; JS/TS `process.env.X`, `import.meta.env.X`;
  Go `os.Getenv`, `os.LookupEnv`; shell `$X`, `${X:-default}`; framework config
  (Rails `config/*.yml` with ERB, `config/initializers`, settings modules).
- Dockerfiles (`ENV`, `ARG`), docker-compose files, CI workflows.
- Deploy config: `kdep/*/app.yml` (`configmap:` keys and values),
  `kdep/*/secrets.yml` (key names only), Helm values.
- `.env*` files and `.env.example` — **key names only**.
- README and docs that tell people which vars to set.

Ignore vars the runtime provides by itself (`PATH`, `HOME`, `PWD`, `HOSTNAME`,
etc.) unless the app clearly depends on them.

**Hard rule: never copy values into the contract or the transcript.** Do not print, quote or
summarize the contents of `.env*`, `secrets.yml` or any credential. Read them only
to learn key names.

## 2. Classify each var

- **Secret or ConfigMap:** passwords, tokens, API keys, private keys, connection
  strings with credentials → `secrets:`. Everything else → `vars:` (ConfigMap).
- **Type:** `int`, `bool`, `url` or `enum(...)` when the code parses or compares
  it that way; otherwise `str`.
- **Optional (`optional: true`):** the code tolerates absence (fallback, `fetch` default,
  `|| default`, feature off when unset). Otherwise required.
- **Default (`default: "value"`):** only literal, non-secret defaults that the code itself
  uses. Never invent one.
- **Scope:** shared unless the var is clearly specific to some envs (e.g. only in
  production config or only in `app_<env>.yml`) → under `envs: <name>:`.

## 3. Write envpact.yml

Use exactly this syntax:

{{SYNTAX}}

Do not invent a `source`: if the file already has one, preserve it as is.

If the repo has a legacy `env.spec` and no `envpact.yml`, run `envpact convert`
first, delete the `env.spec`, and work on the `envpact.yml`.

Put shared keys first (`vars`, `secrets`), then `envs`. Use the long form
`{type: ..., description: "..."}` when a short note helps the next reader. Group related keys with a short comment. If `envpact.yml`
already exists, update it in place: keep its comments and existing decisions, add
what is missing, and never silently drop a key — if a declared key looks unused,
keep it and flag it.

## 4. Flag what you are unsure about

Above any key whose classification is a guess, add a comment:

```
secrets:
  # TODO(envpact): looks like a secret (used as Authorization header) — confirm
  API_TOKEN:
```

## 5. Validate and report

Run `envpact lint` and fix the file until it passes. Then report, briefly:

- how many vars you found and where (by file, no values);
- each `# TODO(envpact):` decision;
- declared keys that appear unused.
