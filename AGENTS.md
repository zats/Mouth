# AGENTS.md

## Codex Agent Runtime Rules

1. Capture long CLI output with `mktemp -d` + files, or filter at source if you can bound output.
2. Keep build artifacts and logs out of the repo; use temp directories only.
3. Never use `rm`; use `trash [--help][--stopOnError][--verbose] ...` for deletions.
4. `ast-grep` docs are at `~/.codex/docs/ast-grep.md` for syntax-aware search when needed.
5. When capturing large/unpredictable logs, capture full output and search for failure markers (e.g., `error:`), do not rely on tailing.

## Terminal
- User uses fish syntax; provide fish-compatible command examples when sharing commands.
- User prefers `uv` for Python env management and `pnpm` for JS.

## Swift
- In `guard let`, prefer the concise form when names match: `guard let self else { return }`.
- Avoid adding `@MainActor` in source; app/project data is already MainActor-driven by convention.
- Do not use default initializer params that instantiate objects; create instances at call sites.
- Delete unused code by default.
- Avoid adding defensive "just in case" logic unless explicitly requested.

## Version control
- Multiple agents may be working in the repo; avoid touching unrelated files.
- Detect `sl`/`git` repo via root markers (`.sl` or `.git`), or `sl root`.
- Avoid `sl status -s`; use `sl status`.
- For Sapling, use `sl addremove` for new files.
- For partial Sapling commits, use glob include patterns instead of direct paths.

## Build / validation habits
- When editing Swift, prefer running an Xcode build and scan logs for errors with `grep`-style patterns rather than streaming all output.
- Avoid stubs unless explicitly asked.
