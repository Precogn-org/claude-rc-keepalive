# What is verified, and what is not

🇬🇧 English · 🇫🇷 [Français](VERIFIED.fr.md)

Test environment: Ubuntu 24.04, Claude Code 2.1.282 (Linux x86_64), tmux 3.4, systemd 255 (user manager with
`Linger=yes`), Claude Max subscription, 24-26 September 2026. Two machines: a server (VPS) for the real Remote Control
tests, and a Windows workstation with WSL Ubuntu 24.04 (**real systemd 255**) for the tests that must not touch the server
(transient units only, never a unit file).

## Verified on the server (real tests)

| Point | How |
|---|---|
| `claude remote-control --name X` runs inside tmux and stays reachable from the mobile app and claude.ai/code | started, session driven from a phone, file written on the machine |
| `SIGTERM` on the server also stops the child session, without touching other processes | test of 25/09 |
| Restarted with `--continue` **in the same directory**, the server finds **the same claude.ai session** (same `cse_…` identifier, same `environmentId`) | test of 25/09, then a real restart on 26/09 |
| **A real machine reboot**: the user timer fired 66 s after boot, the working directory was recreated, `--continue` resumed the **same session** (same `sessionId`, `environmentId`, `cse_…`; new PIDs), one single instance, no duplicate | reboot of 26/09 (9 s reboot, session back ~73 s after boot) |
| The conversation is kept (`~/.claude/projects/<dir>/*.jsonl`) and the session answers with its context | question asked from a phone after the resume |
| After `--continue` the server is in **"single session" mode** ("Single session · exits when complete"): no on-demand sessions, and it exits when the session ends | screen observed on 25/09 |
| A systemd timer with default accuracy detects a stop in ~70 s | measured: 69 s (`AccuracySec=1s` is set) |
| `claude auth status` works without a terminal, in a minimal environment (`env -i`, `setsid`, closed stdin): exit 0, ~0.4 s, no error output, **credentials file not modified** | test of 26/09 |
| Credentials are in `~/.claude/.credentials.json` (mode 600); the access token (8 h) is refreshed automatically | file and refresh time observed |
| `claude` is not in a user service's PATH (`~/.local/bin` missing) | `systemctl --user show-environment` |
| On Ubuntu, `/tmp` is emptied at every boot (`D /tmp 1777 root root 30d`) | `systemd-tmpfiles --cat-config`, confirmed by the reboot |
| A new directory under an already trusted one (`/tmp/…`) does not trigger the "trust" dialog again | launch of `/tmp/test-vps-cli` |
| The process detection pattern (`pgrep -f`) recognises the real server and ignores the tmux process that contains it | test on the server, 26/09 |
| Boot timeline: network ready at T+8 s, user manager at T+9 s, timer at T+60 s | `systemctl show … ActiveEnterTimestamp`, confirmed by the reboot |
| Processes launched by a `oneshot` service with `KillMode=process` stay in the service's cgroup ("inactive (dead)") for a long time without being killed; systemd then logs a warning at each new start | observed on the server, 25-26/09 |

## Verified on WSL with real systemd (no unit installed)

| Point | Result |
|---|---|
| `systemd-analyze --user verify` on the installed units | exit 0, no warning; a **negative control** (broken unit) is detected |
| `oneshot` service + tmux, default `KillMode` | **the session is killed as soon as the script ends** (0 processes after 3 s) |
| Same with `KillMode=process` | the session **survives**; systemd notes "Unit process … (tmux: server) remains running after unit stopped" |
| Timer + `oneshot` service + `KillMode=process` (11 s test, a pass every 2-3 s) | **1 creation only**, then repeated "alive" checks |
| Same timer **without** `KillMode=process` | **a new creation at every pass** (4 in 11 s, 0 "alive") |
| Timer stop + service stop + `daemon-reload` (uninstall equivalent) | the session **survives** |
| `install.sh` in a fake HOME: files and modes | private directories **700**, scripts 755, units 644, **configuration 600**, symlink; the only systemctl command: `daemon-reload` |
| Second install | the user's modified configuration is **not overwritten** |
| `install.sh` then `uninstall.sh` with a simulated running session | the session **stays alive** (same pid); no `kill`, `tmux` or `stop` in these scripts |
| `install` replaces a script **that is running** | new inode: the running process finishes normally |
| Three simultaneous `claude-rc-ensure` runs **before** the lock | **3 launches** (defect confirmed); **with** the `flock` lock: 1 |
| State files with `umask 0002` **before** the fix | 664; **after**: 600 in a 700 directory, working directory unchanged |
| Screen reading with `tmux capture-pane -t $TMUX_PANE` and a **real tmux** | claude's error messages are read after the process exits (4 scenarios verified) |

## Behaviour of `claude remote-control` (extracted from the 2.1.282 binary; re-check at every update)

The exit code is **always 1**: only the messages tell the cases apart. They are printed on standard error.

| Message (start) | Meaning | Decision of `claude-rc-run` |
|---|---|---|
| `Resuming session <id> (<age>) …` | resume started (announced before connecting) | never a new session |
| `Error: No recent session found in this directory or its worktrees.` | nothing recorded for this directory (first time, or too old: ~4 h); **immediate exit, before any network call** | new session (if the API is reachable) |
| `Error: Session <id> has no environment_id.` | session never attached to a server | new session |
| `Error: Session <id> is already being served by another claude remote-control instance (pid N) …` | duplicate: another process already serves the session | **nothing** (code 5) |
| `Error: Environment <id> is already being served by another … (pid N) …` | same | **nothing** (code 5) |
| `Error: Another claude remote-control instance (pid N) is already running in this directory. Exiting to avoid a split-brain conflict.` | race between two launches | **nothing** (code 5) |
| any other message | network/server error, deleted or archived session… **not mapped** | **nothing** (code 6); human decision: `claude-rc-ctl fresh <id> --yes` |

## NOT verified (do not present as established)

| Point | Why it matters | How to verify |
|---|---|---|
| **The ~4-hour limit** (documentation: "about 4 hours") | exact value and real message beyond it not measured | stop, wait more than 4 h, restart |
| A reboot with a **late network** | the script waits and retries, but this was not observed | reboot with the network blocked |
| **Network/server messages** during a resume | not mapped: they fall under "unknown" (no new session) | cut the network during `--continue` |
| `--continue` when the session was **deleted** or **archived** on claude.ai | archiving is undone automatically (documentation); deletion is unknown | delete the session, restart |
| Abrupt stop (`SIGKILL`, power loss) | only `SIGTERM` was tried | `kill -9` on the server |
| Screen reading with the **real** claude (not a stand-in writing to standard error) | claude's full-screen interface might clear the messages | provoke a failure with the real claude |
| **Lifetime of the Claude login** | unattended sessions stop when it expires; the script only detects it | observation over several days |
| `claude remote-control` **without a terminal** (directly under systemd, no tmux) | deliberately not tried | dedicated test, not planned |
| Several real instances in parallel | verified only with fake executables (distinct names/directories, per-instance locks and counters) | two real sessions |
| Updating Claude Code while a session runs | server behaviour not observed | — |

## Known limitations, by design

- **One instance = one working directory = one session name**, all unique (`--continue` is tied to the directory, and a
  server refuses to start where another one already runs).
- **"Single session" mode after a resume**: no new sessions from the phone.
- **A new session** only in the "nothing to resume" cases; the old one stays "offline" in claude.ai/code: archive it.
- **`/tmp`** is fine for a test, not for real work.
- **Logs** contain the script's decisions and, on failure, the last lines printed by claude.
- **`Found left-over process … Ignoring` warnings** in the systemd user journal at every pass (consequence of
  `KillMode=process`); a cleaner design (tmux in its own transient scope) is not tested yet.
