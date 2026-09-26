# Changelog

## 2.2.0 — 2026-09-26

Behaviour changes (please read):

- **No silent new session.** `RC_FALLBACK=never` (default): "No recent session found" now stops with exit code 7 instead
  of creating a new session. `RC_FALLBACK=norecord` restores the previous behaviour, for that message only.
  "No environment_id" no longer creates a new session either (exit 6). A first session is created explicitly with
  `claude-rc-ctl fresh <id> --yes`.
- **`install.sh` no longer creates a `test-vps-cli.env`.** It creates no session at all; it installs
  `conf/session.env.example` and the durable folder `~/claude-rc/sessions/` (700).
- Working directories under `/tmp`, `/var/tmp`, `/dev/shm`, `/run` and relative paths are refused (exit 69).
- New sessions are launched with `--spawn same-dir` (avoids an interactive question that blocks unattended starts).

New:

- Free session names (spaces, accents, `/`, double spaces; 1-120 characters, no control character, no leading `-`).
- The running server is detected by its **working directory** (`/proc/<pid>/cwd`) instead of its name.
- `claude-rc-ctl create | enable | disable | list`; `status` shows the memory of the server and its children.
- Memory guard: nothing is launched below `RC_MIN_AVAILABLE_MB` of available memory (exit 8).
- Journal rotation at 1 MB (`<id>.log.1`).
- Timer jitter raised to 30 s for several instances.
- `start`, `restart`, `fresh` reset the anti-loop counter (human decisions).
- About 170 automated checks (fake `claude`, `tmux`, `curl`, `pgrep`, `systemctl`, fake `/proc`).

## 2.1

Locks (`flock`), private state files (600/700), message-based decisions for `--continue` failures, monotonic clock,
verified real restart and reboot.
