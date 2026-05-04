# lps

> **list & manage processes by listening port — grouped by project**

A tiny zero-dependency CLI for the moment you ask:

> *"Why is port 3000 already in use? I'm not running anything."*

`lps` shows every TCP listener on your machine, **labeled by which project owns it**, and lets you kill the ones you don't need.

```
$ lps
PID     PORT    COMMAND                          PROJECT                CWD
----------------------------------------------------------------------------------------------------
22761   5037    adb                              call-me                /Users/me/Desktop/call-me [orphan]
1596    6463    Discord Helper (Renderer)        (system)               —
664     7000    ControlCenter                    (system)               —
67663   1994    figma-mcp-go                     lp-decx                /Users/me/Desktop/mine/lp-decx
91872   9090    Reactotron Helper (Renderer)     (system)               —
```

The `[orphan]` tag flags processes whose parent terminal died (PPID=1) but kept running in the background — usually a forgotten `next dev` / `vite` from a closed terminal.

---

## Why not just `lsof`?

`lsof -i -P -n | grep LISTEN` works. But:

- It tells you the command (`node`) but not **which project** that node is serving.
- It can't tell you a process is **orphaned** from a dead terminal.
- It has no built-in **kill** flow.

`lps` is a 300-line bash script that wraps `lsof`/`ps`/`kill` to fill those gaps.

---

## Install

### One-liner (macOS / Linux)

```bash
curl -fsSL https://raw.githubusercontent.com/linhh-phv/lps/main/install.sh | bash
```

This installs `lps` to `/usr/local/bin/lps`. Override with `INSTALL_DIR=~/bin`.

### Manual

```bash
curl -fsSL https://raw.githubusercontent.com/linhh-phv/lps/main/lps -o /usr/local/bin/lps
chmod +x /usr/local/bin/lps
```

### From source

```bash
git clone https://github.com/linhh-phv/lps.git
cd lps
sudo cp lps /usr/local/bin/
```

---

## Usage

```bash
lps                    # list every TCP listener, grouped by project
lps orphans            # only show orphan processes (PPID=1, in user dirs)
lps kill 3000          # kill whatever's listening on :3000 (asks confirm)
lps kill 12345         # kill PID 12345
lps kill               # interactive picker
lps kill -f 3000       # skip confirmation
lps help               # full help
```

### Project detection

For each listening process, `lps` walks up its working directory and looks for:

1. `package.json` → uses the `name` field
2. `.git/` → uses the directory name
3. Fallback: the basename of the cwd

If the cwd lives under `/System`, `/Library`, `/usr`, `/Applications`, or a sandbox container, the project shows as `(system)`.

### Orphan detection

A process is flagged `[orphan]` when:

- `PPID = 1` (reparented to launchd/init — its original parent died)
- `cwd` lives under `/Users/` (so it's user code, not a launchd-managed daemon)
- `cwd` is not inside `Library/Containers/` (which are sandboxed system apps)

This is the typical signature of a dev server whose terminal was force-closed.

---

## Requirements

- macOS or Linux
- `bash` 3.2+ (the macOS default works)
- `lsof`, `ps`, `awk`, `grep`, `sed` (all standard)

---

## Environment

| Variable | Purpose |
| --- | --- |
| `NO_COLOR=1` | Disable ANSI colors. |

---

## Comparison

| | `lsof` | [`fkill`](https://github.com/sindresorhus/fkill-cli) | `lps` |
| --- | :---: | :---: | :---: |
| Lists listening ports | yes | yes | yes |
| Shows project name | no | no | **yes** |
| Detects orphans | no | no | **yes** |
| Interactive kill | no | yes | yes |
| Zero dependencies | yes | no (Node.js) | **yes** |

---

## License

MIT — see [LICENSE](./LICENSE).
