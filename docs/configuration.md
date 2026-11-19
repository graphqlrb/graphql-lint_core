# Shared configuration

Add `version: 1` to the product's YAML file. Each CLI searches from the current directory up to the Git root. Use `--config PATH` to select a file. CLI flags override file settings, and relative file settings resolve from the YAML file's directory.

- `extends` loads presets or configuration files in order. Later entries take precedence.
- `require` loads Ruby extensions. Both this setting and the `ruby:` schema source can execute Ruby code. Use trusted files.

## Schema sources

Use a file, a glob, or `sdl:PATH` to read SDL. A single `-` reads SDL from standard input. Use `git:REF:PATH` to read a file from a local Git revision, `introspection:PATH` for introspection JSON, or `ruby:ClassName` after loading the schema's Ruby code. A schema mapping can supply `sources` and a list of SDL files under `prelude`.

## Linter settings

Set `rules` entries to a severity or a mapping containing `severity`, `options`, or `exclude`. The value `off` disables a rule. The default `fail_level` is `error`. Set `max_warnings` to fail a check that exceeds a warning count.

Use an `ignore` entry to suppress a finding by `coordinate`, `path`, or `operation`. Each entry needs a `rule` and a `reason`. Set `suppression.require_reason` or `suppression.report_unused` to check suppression comments.

For a project with existing findings, run `baseline update` and commit the generated JSON alongside the configuration. CI can then fail on new findings. Run `baseline prune` after fixing recorded findings.

## Output

Available formats are `text`, `compact`, `json`, `github`, `sarif`, and `markdown`. Repeat `--format` to produce several outputs. Append `:PATH` to send a format to a file.

```sh
graphql-schema-lint check --format github --format sarif:graphql.sarif
```

The GitHub formatter appends a Markdown summary when `GITHUB_STEP_SUMMARY` is set.
