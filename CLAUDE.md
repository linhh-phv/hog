# CLAUDE.md — hog

hog tells a macOS developer what is eating the machine (RAM incl. compressed memory, CPU), who owns it (app, VS Code
window, project, Claude session), explains every number in plain words, and stops things only through hard safety gates.

The design is the source of truth: [docs/architecture/design-vi.md](docs/architecture/design-vi.md) (Vietnamese). When the
implementation has to differ from it, update the design in the same change.

## Layout

- `Sources/HogCore/` — everything: sensors, ownership, rules, catalog, explanations, stop planner + safety gates.
- `Sources/hog/` — the CLI. Thin: parses arguments, calls `HogCore`, prints.
- `Sources/HogBar/` — the menu bar app (phase 1, later step). Thin, like the CLI.
- `Sources/HogCore/Resources/{catalog,rules,explain}/` — data, one JSON file per entry. Never code-like: no commands.
- `Tests/HogCoreTests/` — Swift Testing. Fixtures in `Tests/HogCoreTests/Fixtures/` are **sanitized** real outputs.
- `legacy/` — the bash `lps` 0.1.0, kept only until `hog ports` matches it; then delete.

## Commands

```bash
swift build          # debug build
swift test           # all tests
swift run hog        # run the CLI
```

## Rules

- No third-party dependencies (`Package.swift` has no `dependencies`).
- Measure, don't guess: a value that could not be measured is `nil`/`null`, never `0` or `false`.
- Sensors are read-only and must never start a service (`watchman --no-spawn --no-local`, no Docker CLI, check sockets first).
- Tests only signal processes the test itself spawned. Never touch real processes of the machine.
- This repo is public: no real names, work emails, company or private project names, or machine paths in code, fixtures,
  docs or commit messages. Fixtures use fake user, project and path names (`me`, `web-app`).
- Commits: Conventional Commits in English (`feat(core): …`, `test(sensors): …`, `docs: …`).
