# AGENTS.md

Scope: this file applies to the whole `quackdb_ex` repository.

- Build a remote DuckDB Quack protocol client first; keep Ecto as a layer on top of a DBConnection-ready core.
- Prefer protocol correctness and explicit unsupported-feature errors over broad but lossy behavior.
- Keep the low-level codec independent from HTTP, DBConnection, and Ecto.
- Keep result decoding row-friendly for Ecto while preserving room for columnar/Arrow integrations later.
- Do not publish, tag, or create GitHub releases unless explicitly requested.
- Use `mix ci` before considering work complete once the CI alias exists.
