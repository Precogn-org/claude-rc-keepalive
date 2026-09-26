# claude-rc-keepalive

🇬🇧 English · 🇫🇷 [Français](README.fr.md)

Keeps **one Claude Code Remote Control session** alive on an always-on Linux machine (VPS, mini-PC): it is restarted
after a stop or a reboot and, whenever possible, **resumes the same claude.ai session**, so you can keep driving it from
your phone, tablet or claude.ai/code.

> **Status: prototype, one session.** Tested with Claude Code 2.1.282 on Ubuntu 24.04, including a real restart and a real
> reboot. Several important points are still unverified (the ~4-hour resume window, late network at boot…): see
> [docs/VERIFIED.md](docs/VERIFIED.md). Not affiliated with, or endorsed by, Anthropic.
> Note: the scripts' log messages and code comments are currently in French; the documentation is bilingual.

## Why

`claude remote-control` is a **local** process: if it stops (reboot, long network outage, crash), the session goes
"offline" and nothing brings it back. The official documentation recommends `tmux` or `screen` on a remote machine but
describes neither automatic start nor supervision. This repository provides a minimal answer: a few shell scripts and two
**user-level** systemd units (no administrator rights needed).

## How it works

```
   machine boot ─(60 s)─┐                every minute ─┐
                         ▼                              ▼
                 claude-rc@<id>.timer ───────► claude-rc@<id>.service (oneshot, ~1 s)
                                                          │  claude-rc-ensure <id>
                                                          ▼
        another check already running? ─yes─► let it finish        (flock lock)
        deliberate stop requested?     ─yes─► do nothing           (flag file <id>.stop)
        server already running?        ─yes─► check the Claude login (a hand-started session is ADOPTED)
        Anthropic API reachable?       ─no──► wait                 (never create a session "by mistake" because of the network)
        Claude login valid?            ─no──► log it, exit 3
        too many recent launches?      ─yes─► pause, exit 4        (resumes by itself)
                 │
                 ▼
        tmux new-session ─► claude-rc-run <id>
                                 └─ claude remote-control --name … --continue                (same claude.ai session)
                                         │ on failure the MESSAGE decides (the exit code is always 1)
                                         ├─ "No recent session found" / "has no environment_id" ─► new session
                                         ├─ "already being served / already running"             ─► nothing (duplicate avoided)
                                         └─ any other message                                    ─► nothing (human decision)
```

Why read the message: `--continue` exits with code 1 both when there is **nothing to resume** and when **the session
is already being served** by another process. Treating every failure as "create a new session" would create duplicates.
All known messages are listed in [docs/VERIFIED.md](docs/VERIFIED.md).

## Requirements

- Linux with **systemd** (user manager), `tmux`, `curl`, `bash`, `pgrep`, `flock` (util-linux; without it there is no lock).
- [Claude Code](https://code.claude.com/docs/en/quickstart) installed and **signed in** (`claude auth login`, claude.ai
  account: Pro, Max, Team or Enterprise; API keys do not work with Remote Control).
- `loginctl enable-linger <user>` (check with `loginctl show-user $USER -p Linger` → `Linger=yes`), otherwise the timer
  only starts at the first login.
- A working directory already **trusted** by Claude Code (the "trust" dialog) for the session.

## Layout

In the repository:

```
bin/claude-rc-ensure      checks / restarts (called by the timer)
bin/claude-rc-run         runs inside tmux: --continue, then, depending on the message, a new session
bin/claude-rc-ctl         status | start | stop | restart | fresh | logs | screen
lib/common.sh             shared functions
systemd/user/claude-rc@.service   template unit (oneshot, KillMode=process)
systemd/user/claude-rc@.timer     template timer (60 s after boot, then every minute)
conf/test-vps-cli.env.example     example configuration for one session
install.sh / uninstall.sh         (--dry-run available)
tests/run-tests.sh                automated tests with fake claude/tmux/curl
tests/hygiene.sh                  pre-publication scan (keys, IPv4, e-mails, personal terms)
docs/VERIFIED.md                  verified / unverified, Claude Code messages
```

Created by `install.sh` (inside the user's home directory only):

| Path | Mode | Purpose |
|---|---|---|
| `~/.local/lib/claude-rc/` (4 files) | directory **700**, scripts 755, `common.sh` 644 | scripts |
| `~/.local/bin/claude-rc-ctl` | symlink | command |
| `~/.config/systemd/user/claude-rc@.service`, `claude-rc@.timer` | 644 | units |
| `~/.config/claude-rc/` and `test-vps-cli.env` | directory **700**, file **600** (never overwritten) | configuration |

Created at run time, **all 600 in a 700 directory**: `~/.local/state/claude-rc/<id>.{log,last,launches,stop,lock}`.
Shared directories (`~/.local/bin`, `~/.config/systemd/user`) are never modified.

## Install

```bash
./install.sh --dry-run          # prints everything it would do, writes nothing
./install.sh                    # copies files; starts NOTHING, stops NOTHING
$EDITOR ~/.config/claude-rc/test-vps-cli.env     # name, working directory, permission mode
systemctl --user enable --now claude-rc@test-vps-cli.timer
claude-rc-ctl status test-vps-cli
```

A session **already started by hand** with the same `--name` is **adopted**: the timer sees it alive and leaves it alone;
it only takes over the next time it stops.

## Uninstall

```bash
./uninstall.sh --dry-run
./uninstall.sh                  # removes units and scripts; the running session is NOT stopped
./uninstall.sh --purge          # also removes configuration and logs
```

## Day-to-day use

```bash
claude-rc-ctl status  <id>      # state, Claude login, last journal lines
claude-rc-ctl stop    <id>      # DELIBERATE stop: the timer will not restart it until you run start
claude-rc-ctl start   <id>      # clears the deliberate stop and launches (resume with --continue)
claude-rc-ctl restart <id>      # stops the process (and waits until it is gone), restarts with --continue
claude-rc-ctl fresh   <id> --yes   # NEW session (the old one stays offline in claude.ai: archive it)
claude-rc-ctl logs    <id> 100  # journal
claude-rc-ctl screen  <id>      # current screen of the session (read-only)
tmux attach -t rc-<id>          # watch/drive the session in a terminal (Ctrl-b d to leave)
```

## `claude-rc-ensure` exit codes

| Code | Meaning |
|---|---|
| 0 | all good (running, launched, deliberate stop, network absent, or a check is already running) |
| 1 | tmux failed to start / working directory could not be created |
| 3 | Claude login invalid: nothing is launched (the service shows as "failed") |
| 4 | anti-loop pause (3 launches within 10 minutes); **resumes by itself** when the window has elapsed |
| 64-68 | invalid configuration (identifier, refused mode, missing, name/directory already taken, invalid session name) |

`claude-rc-run`: claude's own exit code, or **5** (session already served by another instance), or **6** (unknown
failure of `--continue`).

## What happens when…

- **the machine reboots**: the user manager starts (thanks to linger) and the timer fires about 60 s after boot (plus up to
  10 s of jitter). The working directory is recreated if it vanished (`/tmp` is emptied at every boot). If the network is
  not up yet, the script waits and retries every minute without launching anything.
- **`--continue` succeeds** (stopped for less than about 4 h, session still known to the server): **same claude.ai
  session**, same conversation. The server is then in "single session" mode; when the session ends, it exits and the timer
  picks it up again a minute later.
- **nothing to resume** ("No recent session found", e.g. after more than 4 h) and the API is reachable: a **new session**
  with the same name. The old one stays "offline" in claude.ai/code: archive it.
- **the session is already being served** by another process ("already being served" message): **no new session**, exit 5.
  Typical case: a manual restart that was too quick (`claude-rc-ctl restart` waits for the old process to disappear).
- **unknown error** (network, server…): **no new session**, exit 6, the message is logged; the timer retries (at most 3
  launches per 10 minutes). If the session is definitely lost: `claude-rc-ctl fresh <id> --yes`.
- **the Claude login expires**: nothing is launched, a clear error is logged and the service fails
  (`systemctl --user --failed`). Run `claude auth login` again.
- **several instances**: each has its own `<id>.env`, tmux session (`rc-<id>`), log, lock and counter. Two instances
  **cannot** share the same `RC_NAME` or the same `RC_DIR` (refused, code 67; a server also refuses to start in a directory
  where another one already runs). The timer spreads its triggers by up to 10 s. Budget roughly 365 MB of memory per
  session at rest.

## Security

- No administrator rights, no open port: Remote Control only makes **outbound** connections.
- No secret in this repository nor in the configuration files; the login is the one from `claude auth login`
  (`~/.claude/.credentials.json`, mode 600): these scripts **never read that file** and only call `claude auth status`.
- Allowed permission modes: `default`, `acceptEdits`, `plan`. **`bypassPermissions`, `auto` and `dontAsk` are refused** by the
  script. A remotely driven session can run commands on the machine: choose the working directory and the account's
  rights accordingly.
- `<id>.env` is loaded as shell code: it must belong to the user and be writable only by them (600).
- State files are 600 in a 700 directory, whatever the `umask`. The normal `umask` is kept for tmux and claude (files the
  session creates keep the usual permissions).

## Known limitations

- **One instance = one working directory = one session name**, all unique (`--continue` is tied to the directory).
- After a resume the server is in **"single session"** mode: no new sessions from the phone.
- With `KillMode=process`, tmux and claude stay in the finished service's cgroup, and systemd logs "Found left-over
  process … Ignoring" warnings at each pass. Harmless, but noisy; a cleaner design is planned (see
  [docs/VERIFIED.md](docs/VERIFIED.md)).
- Session names currently accept letters, digits, `.`, `_` and `-` only (no spaces).
- The ~4-hour resume window and a reboot with a late network are **not verified**.

## Tests

```bash
bash tests/run-tests.sh          # on Linux (or WSL); about 100 checks
```

The tests use fake `claude`, `tmux`, `curl` and `pgrep`: they touch neither the network nor a real session. They do not
replace a real test (see [docs/VERIFIED.md](docs/VERIFIED.md)). On Windows (Git Bash), the permission and lock tests are
skipped.

**Before publishing a fork or a contribution:** `bash tests/hygiene.sh` scans for keys, IPv4 addresses, e-mail addresses and
long random strings. To add your own terms that must never be published (names, projects, hosts), create
`tests/private-patterns.local` (one pattern per line). That file is in `.gitignore` and must **never** be committed.

## License

MIT (see [LICENSE](LICENSE)).
