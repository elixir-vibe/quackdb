# AGENTS.md

Scope: this file applies to the whole `quackdb` repository.

- Build a remote DuckDB Quack protocol client first; keep Ecto as a layer on top of a DBConnection-ready core.
- Prefer protocol correctness and explicit unsupported-feature errors over broad but lossy behavior.
- Keep the low-level codec independent from HTTP, DBConnection, and Ecto.
- Keep result decoding row-friendly for Ecto while preserving room for columnar/Arrow integrations later.
- Keep optional integrations idiomatic: modules may live at conventional `lib/...` paths, but optional dependency-backed modules must guard definitions with `Code.ensure_loaded?/1` instead of relying on nonstandard source directories.
- Follow Ecto SQL adapter conventions when touching Ecto code: validate params are lists, return results with `:columns`, `:rows`, and `:num_rows`, and prefer explicit unsupported-feature errors over partial behavior.
- Docs should present DBConnection/direct SQL and Ecto as complementary surfaces. Do not tell users one is universally preferred; show Ecto examples where they improve readability, and raw SQL where DuckDB-specific SQL is clearer or more complete.
- In docs and examples, use aliases/imports to avoid noisy repeated module prefixes in code blocks, while keeping the first occurrence clear enough for readers to know where helpers come from.
- Avoid adding local HTTP/file-staging servers to core. DuckDB already reads local paths visible to the server plus HTTP(S), S3/R2/GCS, Azure/ADLS, Hugging Face, and lakehouse sources through extensions and secrets.
- Validate server-semantic changes with gated real DuckDB Quack integration tests in addition to fixture tests.
- Preserve command result semantics: DuckDB `Count` outputs for DML should normalize to affected-row `num_rows` without losing raw server output in metadata.
- Do not publish, tag, or create GitHub releases unless explicitly requested.
- Use `mix ci` before considering work complete once the CI alias exists.
- Before release-readiness/package changes, follow `CONTRIBUTING.md` and keep Hex package contents intentional: no `examples/`, `docs/research/`, `test/`, `deps/`, `_build/`, or local `tmp/` artifacts.
- Keep helper module names intentional and consistent: SQL-family helpers use established acronyms (`QuackDB.SQL`, `QuackDB.DDL`, `QuackDB.DML`, `QuackDB.FTS`), while domain helpers use clear nouns (`Source`, `Secret`, `Extension`, `Geometry`). Do not add long-name compatibility aliases for unreleased APIs.
