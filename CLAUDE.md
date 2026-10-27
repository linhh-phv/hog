# CLAUDE.md — hog

hog tells a macOS developer what is eating the machine (RAM incl. compressed memory, CPU), who owns it (app, VS Code
window, project, Claude session), explains every number in plain words, and stops things only through hard safety gates.

The design is the source of truth: [docs/architecture/design-vi.md](docs/architecture/design-vi.md) (Vietnamese). When the
implementation has to differ from it, update the design in the same change.

## Layout

- `Sources/HogCore/` — everything: sensors, ownership, rules, catalog, explanations, stop planner + safety gates.
- `Sources/hog/` — the CLI. Thin: parses arguments, calls `HogCore`, prints.
- `Sources/HogBar/` — the menu bar app. Thin, like the CLI. UI tokens in `Theme.swift` mirror docs/design/design-system.md.
- `scripts/` — `build-app.sh` (dist/Hog.app, ad-hoc signed) and `install.sh` (installs for the current user).
- `Sources/HogCore/Resources/{catalog,rules,explain,smc}/` — data, one JSON file per entry. Never code-like: no commands.
  Explanation texts are plain words, one point per line (`\n`, shown as bullets), ≤ 150 characters each (design 5.2).
- `Tests/HogCoreTests/` — Swift Testing. Fixtures in `Tests/HogCoreTests/Fixtures/` are **sanitized** real outputs.

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
  Only exception: cleaning up exactly what a timed-out `code --status` left behind (`ExternalSensors.cleanUpCodeStatus`).
- The SMC (temperatures, fans) is only ever read: key info (9) and read key (5), never write (6) — no fan control.
- External commands go through `Command.run` (own process group, timeout kills the group; the CLI forwards Ctrl-C).
- Tests only signal processes the test itself spawned. Never touch real processes of the machine.
- This repo is public: no real names, work emails, company or private project names, or machine paths in code, fixtures,
  docs or commit messages. Fixtures use fake user, project and path names (`me`, `web-app`).
- Commits: Conventional Commits in English (`feat(core): …`, `test(sensors): …`, `docs: …`).
