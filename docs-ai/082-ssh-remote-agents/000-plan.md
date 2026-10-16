# 082 — SSH Remote Agents: Plan

| | |
| --- | --- |
| **Status** | Planned |
| **Anchor date** | 2026-10-16 |
| **Primary PRs** | (fill in as they merge) |
| **Related** | [002-spike-findings.md](002-spike-findings.md), [079-program-status-osc-7501](../079-program-status-osc-7501/000-plan.md), [068-agent-state-providers](../068-agent-state-providers/architecture.md), [064-agent-completion-signals](../064-agent-completion-signals/000-plan.md), [067-remote-mirror](../067-remote-mirror/000-plan.md), `docs/components/agent-detection.md` |

## Background

Users ask for repositories that live on another machine: add the repository in the local
sidebar, start and switch agent sessions there, and let the agents, builds and tests run on
the remote host. Prowl cannot do this today. A closed attempt (#98) added SSH hosts, remote
repositories and tmux flows but did not land. An external proposal (WAMaker, fork branch
`feature/remote-agent-server`, also numbered 082 there) put a resident `prowl serve` daemon
with HTTP, token pairing, a custom PTY stream and protocol clients on the remote host.

Constraint set by onevcat: no forced hooks, no forced shell integration, and manual sessions
(`ssh host`, then start an agent by hand) must be covered, not only Prowl-launched ones.

Every stage of local detection depends on the local process probe: `AgentProcessProbe` reads
the pane's foreground process group with libproc (`ProcessDetection.swift`), and
`WorktreeTerminalState+AgentDetection.swift` runs nothing else when no agent is identified.
In a pane that runs `ssh`, the foreground process is `ssh`, so the pane has no agent. But the
screen bytes and OSC 7501 reports already reach the local Ghostty surface through SSH. The
real gaps are (1) remote process identity, (2) remote file evidence (session stores,
transcripts, pid registries), and (3) session survival when the local side disconnects.

## Goals

The work is three independent layers. Each layer ships alone and adds value alone.

| Layer | Value | Remote requirement |
| --- | --- | --- |
| L0 — SSH-transparent detection | A manual `ssh host` + agent in any Prowl pane shows in Active Agents with exact identity and live state | None (no install, no file writes, no rc change) |
| L1 — Remote folders | Remote repositories and worktrees in the sidebar; tabs, splits, scripts and Profile launches open on the host | `git`, `/bin/bash`, `sh` |
| L2 — Persistent sessions | Remote tabs attach to Prowl-managed tmux automatically; sessions survive tab close, app quit, Mac sleep and network loss | `tmux` (default on when present) |

### Non-goals

- L3, a resident remote observer (observation and notifications while Prowl is not
  running, sessions outside Prowl's tmux that no Prowl pane shows, remote file evidence). Decided 2026-10-16: not planned. If a need appears, it must be a stdio-only
  observer (`ssh host prowl serve --stdio`), never HTTP with pairing.
- A custom PTY stream protocol or a new terminal component. SSH is the PTY transport; the
  local terminal stays a Ghostty surface.
- Agent protocol clients (Codex app-server, ACP).
- Remote managed hooks and workflow delivery from remote panes. The `ssh -R` socket channel
  works (002), but the remote side needs a Prowl CLI binary. Later work.
- Remote file-based evidence: session ids, transcripts, `agents read` results, Codex daemon
  child work.
- mosh, Eternal Terminal, nested ssh, `docker exec` chains.
- Remote diff window, workspaces, Finder/editor actions, clone to remote.

## Design / Approach

### L0 — SSH-transparent detection (detailed)

**1. Correlation key.** Each pane exports `LC_PROWL_PANE=<pane UUID>` next to `PROWL_PANE_ID`
(`launchEnvironment` in `App/Sources/Infrastructure/Ghostty/GhosttySurfaceView.swift`). The
`LC_` prefix rides the default `SendEnv LANG LC_*` (macOS client) and `AcceptEnv LANG LC_*`
(macOS and Debian sshd), so a hand-typed `ssh host` carries it with no configuration. The
value is as public as `PROWL_PANE_ID`. iTerm2's `LC_TERMINAL` uses the same channel.

**2. Remote pane trigger.** When the local probe's foreground job is `ssh`, the pane becomes
a remote candidate. Prowl parses the destination and connection options (`-p`, `-l`, `-i`,
`-J`, `-F`, `-o`) from the local `ssh` argv; it ignores the remote command.

**3. Side channel.** One Prowl-owned connection per destination:
`ssh -o ControlMaster=auto -o ControlPath=<short path> -o ControlPersist=<n> -o BatchMode=yes
<options> <destination> sh -s`. It reuses the user's `~/.ssh/config`, keys and the
`SSH_AUTH_SOCK` that launchd gives the app. ControlPath must stay below 104 bytes. When the
connection cannot open (unknown host key, password or 2FA), the host is "unprobed" and
retries with backoff.

**4. Probe.** A bundled POSIX `sh` script is piped through `sh -s` on every run; nothing is
installed. One run per host per tick serves every pane on that host. It prints one record per
line (contract and tested script in 002):

| Record | Meaning |
| --- | --- |
| `T <epoch> <uname>` | header |
| `S <pane> <anchor pid> <tty> <tpgid>` | an SSH session: anchor = process whose parent is `sshd`/`sshd-session:` and that has a tty |
| `P <pane> <pid> <ppid> <pgid> <comm> <args…>` | a member of the tty's foreground process group |
| `E <pane> <pid> <elapsed s> <cwd>` | elapsed time (clock-skew free) and cwd of that member |
| `M <pane> tmux <socket> <pane id> <pane tty> <path>` | foreground is a tmux client: the pane it shows (by client tty) |
| `C-BEGIN … C-END` | optional `tmux capture-pane` text of that pane |

Pane id source: Linux reads the anchor's `/proc/<pid>/environ`. macOS hides the environment
of platform binaries (the `/bin/zsh` login shell), so it reads the foreground members'
environment; agents are not platform binaries. Prowl caches anchor → pane once learned.

**5. Identity.** Probe records become a `ForegroundJob` with a new `origin` (`.local` or
`.remote(hostKey)`) and go to the unchanged `AgentClassifier`. All 17 agents get exact
identity. Classification uses argv (Claude's native binary has its version as `comm`).

**6. Origin isolation (required).** A remote pid must never reach code that reads local OS
state. Each seam checks `origin == .local`: `processGeneration` and `processIsLiveAncestor`,
`AgentSessionResolver` (fd scans, cwd/transcript scans, pid registries in
`AgentPidArtifacts.swift`, Codex `daemon.pid`), `AgentDetectionCoordinator` providers
(`CodexLogProvider`, `ClaudeRuntimeProvider`), Profile config roots,
`WorktreeTerminalManager.currentAgentEvidence`, CLI caller attribution, and the
`agents read` snapshot path in `ProwlApp.swift`. A remote generation is
`(hostKey, pid, startedAt = localNow − elapsed − 1 s)`.

**7. State.** Non-tmux: the screen rules read the local surface and OSC 7501 arrives through
SSH; both paths stay unchanged. The OSC fence (`ProgramStatusEvidence`) uses the derived
`startedAt`. tmux: no OSC 7501 (002); the detector reads the `C` capture text in place of
`readActiveText`.

**8. Cadence.** The remote prober is async and plugs into `probeForegroundJob`
(`WorktreeTerminalState+ProgramStatus.swift`). Per host: 1 s while a remote agent is active,
2 s otherwise; results are cached so the 300 ms pane tick does not cause extra runs.

**9. Release.** The agent leaves the foreground (including `kill -9`) → miss → release. OSC
`clear` and local `ssh` exit also release.

**10. Degraded mode (unprobed host).** Only verified producers (Claude Code, Pi, Oh My Pi)
show, identified by OSC `app`, with heuristic confidence. Screen-fingerprint identity is out
of scope.

**11. Surfaces.** Active Agents and `prowl agents --json` carry the host. Update
`docs/components/agent-detection.md` and `docs/components/cli.md`.

### L1 — Remote folders (plan)

L1 first makes "where the repository lives" an explicit dimension with one value (local),
then adds the second value (remote). Feature code asks capabilities, never the location.

**Architecture.**

- **Location dimension.** `RepositoryLocation` is `.local(URL)` or `.remote(host, path)`,
  orthogonal to `Repository.Kind` (git/plain). A `Worktree` shares its repository's host.
  Remote identity is `ssh://<host alias>/<canonical path>`, canonicalized on the host
  (`cd <p> && pwd -P`).
- **Compiler-enforced inventory.** `Repository.rootURL` and `Worktree.workingDirectory`
  (about 145 and 78 uses today) are replaced by `location` plus `localURL: URL?`, which is nil
  for a remote location. Each call site must then pick one: go through the host (below), sit
  behind a capability, or unwrap because it is local by construction (for example a path from
  `NSOpenPanel`). New code cannot assume a local path by accident.
- **Host execution boundary.** `RepositoryHost`, bound to a location, offers only command
  primitives: `run(command, in:)`, `runBundledScript(_:arguments:in:)` (local exec of `wt`;
  remote `bash -s` with the script on stdin) and `observeChanges(_:)` (FSEvents locally,
  polling remotely). `GitClient` gets its execution from the host instead of a global
  `ShellClient` and ad-hoc `GitClient()` instances. In-scope features use commands only, no
  direct file reads: reading `.git/HEAD`, `index.lock` or the index header becomes a git
  command, so the remote side needs no file-system API.
- **Capability resolution.** `Repository.Capabilities` changes from two fixed presets to one
  function `resolve(kind:location:)`, the only place that inspects the location. Each entry is
  `available` or `unavailable(reason)`; views disable controls with a tooltip built from the
  reason, and the command palette filters by it. Host reachability (reachable, unreachable,
  unprobed) is runtime state, kept apart from capabilities: actions on an unreachable host
  fail fast with a clear error.

**Feature classes.**

| Class | Features |
| --- | --- |
| Host-agnostic through primitives | Worktree list/create (copy flags)/remove/rename, branch and dirty state, GitHub PR status (resolve `owner/repo` once on the host, keep `gh` local with `--repo`), scripts and terminals |
| Local by nature | Open in Finder/editor, workspaces (`ProjectWorkspace`), external diff tool, clone destination |
| Deferred (remote later with more primitives) | Diff window (`git diff` + file read), line counts, icon detection |

Callers that bypass `ShellClient` today (clone, `ExternalDiffSnapshotClient`,
`DiffWindowState`, `OutgoingChangesClient`, workspace runner, archive script) either move
behind the host or sit behind a capability.

**Remote specifics.**

- **Persistence.** `PersistedRepositoryEntry` gains an optional host. Path-keyed `@Shared`
  stores and the repository settings key (`~/.prowl/repo/<name>`) include the host. The
  snapshot cache does not drop remote entries because of `fileExists`.
- **Add flow.** "Add Remote Folder…" takes a host alias and a path; validation runs on the
  side channel (`pwd -P`, `git rev-parse --show-toplevel`). An offline host shows as
  unavailable and is not removed.
- **Transport.** The remote host runs `cd <dir> && <cmd>` over the L0 side channel with POSIX
  quoting; the worktree base directory is on the host (default `~/.prowl/repos/<name>` there).
- **Refresh.** One polling exec returns HEAD, branch, porcelain status and the worktree list.
- **Terminals.** Tabs, splits and run scripts type `ssh -t <host> 'cd <path> && exec "$SHELL" -l'`
  (or the script command) as initial input, so the pane falls back to a local shell when ssh
  exits. A split inherits the remote cwd from the probe's `E` record. The layout snapshot
  gains the origin so restore reconnects.
- **Profile launches.** Unmanaged: the typed `AgentProfileLaunchPlan.terminalInput` runs
  through `ssh -t`; local carriers (`"$PROWL_LAUNCH_PROMPT"` …) are expanded locally and
  re-quoted for the remote shell. Managed hooks, home provisioning and Codex shell probes are
  skipped. L0 detection covers the session. Remote panes cannot be workflow participants.

**Slices.**

| Slice | Content | Behaviour change |
| --- | --- | --- |
| L1a | `RepositoryLocation`, `localURL: URL?`, call-site triage | None (every repository is local) |
| L1b | `RepositoryHost` with the local implementation; `GitClient` and file reads move to command primitives | None |
| L1c | `resolve(kind:location:)` with reasons; UI tooltips and palette filtering | None for local |
| L1d | Remote host, add flow, persistence, polling refresh | Remote folders appear |
| L1e | Remote terminals, splits, scripts, layout restore | Remote tabs |
| L1f | Remote Profile launches | Remote agents from Profiles |

### L2 — Persistent sessions (plan)

The session belongs to the remote tmux; a Prowl tab is only a window onto it. The user never
runs tmux by hand for this.

- **Option.** "Keep sessions alive (tmux)" per remote folder, with a global default in
  Settings. When the folder is added, the side channel checks for tmux through a login shell:
  present → on by default; absent → off, with a hint to install tmux.
- **Launch.** With the option on, every tab Prowl opens for the folder runs
  `ssh -t <host> 'cd <path> && exec "$SHELL" -lc "exec tmux -L prowl -f /dev/null
  new-session -A -s prowl-<tab id> -c <path> \; set-option -g status off \; set-option -g
  focus-events on"'`. The login shell gives the tmux PATH; `-A` creates or reattaches. Each
  session is tagged with tmux user options `@prowl_worktree` and `@prowl_tab`. The final
  option set (mouse, extended keys, history) is decided during implementation.
- **Lifecycle (decided 2026-10-17).** Closing a tab detaches; the session keeps running. App
  quit and connection loss also detach. Ending a session is explicit: "End Session" on the tab
  and in the session list, and a close variant (for example ⌥-close) that ends it. Removing or
  archiving a worktree ends its sessions after a confirmation that lists running agents. No
  time-based cleanup. Undo close tab (069) reattaches.
- **Discovery.** The remote tmux is the source of truth; the layout snapshot is an index.
  Restore reattaches each tab by session name. Opening a worktree lists its running sessions
  from `tmux -L prowl ls` with the tags, so a lost snapshot or a new Mac reattaches instead of
  creating duplicates.
- **Detached sessions are visible.** The worktree row shows "N background sessions"; the list
  reattaches one as a tab. The probe enumerates `tmux -L prowl list-panes -a` (no client
  needed), reads each pane tty's foreground group for identity, and captures the pane text for
  state, while Prowl runs and the folder is visible.
- **Detection when attached.** Identity from the probe (`M` record, by client tty). With the
  status bar off, the local surface equals the agent screen, so local screen rules apply.
- **History.** For Prowl-managed tmux tabs, `prowl read --last N` reads history through the
  side channel with `tmux capture-pane -S -N`. UI scrolling through tmux history (`mouse on`)
  changes mouse selection; decide after a hands-on check.
- **User-owned tmux** attached in a Prowl pane keeps the L0 tmux path (capture text).
- **Known limits.** No OSC 7501 inside tmux (screen rules give state); the alternate screen
  leaves Ghostty scrollback empty; mouse and copy mode follow tmux; several clients on one
  session share one size; nested tmux inside a Prowl session is unsupported (the probe follows
  one level).

### Acceptance criteria (draft)

| Id | Criterion |
| --- | --- |
| L0-1 | Manual `ssh host` + Claude Code or Codex in a Prowl pane appears in Active Agents within 2 s of start, with correct agent and host, on a macOS host and on a Linux host (OpenSSH ≥ 9.8 `sshd-session` and older `sshd`) |
| L0-2 | Claude Code state follows OSC 7501 with local latency; Codex state follows screen rules; Blocked shows for a permission prompt on both |
| L0-3 | Two panes on one host, and two hosts, map without cross-talk |
| L0-4 | `kill -9` of the remote agent releases the entry within 3 s; closing ssh releases at once |
| L0-5 | Unit tests per isolation seam; a remote pid equal to a live local pid binds no local session, file or registry |
| L0-6 | User tmux attached in a pane: identity via `M`, state from capture text |
| L0-7 | Unprobed host: verified producers show with heuristic confidence; backoff, no retry storm |
| L0-8 | At most one probe run per host per second; no CPU regression in `make measure-cpu`; probe < 0.5 s on the test hosts |
| L0-9 | The remote host has no new files and no changed rc files after a session |
| L1-1 | Add, persist and restore a remote folder; an offline host stays listed as unavailable |
| L1-2 | Worktree list/create/remove/rename on a bash 3.2 (macOS) host and a bash 5 (Linux) host |
| L1-3 | Branch and dirty state refresh within one polling interval |
| L1-4 | Tab, split and run script open at the remote path; splits inherit the remote cwd; restore reconnects |
| L1-5 | Remote Profile launch delivers prompts with quotes, newlines and `$` intact (tests) |
| L1-6 | Disabled features are hidden or disabled with a tooltip; PR status works |
| L1-7 | L1a–L1c ship with no behaviour change for local repositories (existing tests pass; no new local-path access outside `RepositoryHost` and capability-gated code) |
| L2-1 | Opening a remote worktree with the option on attaches tmux automatically; the user never types a tmux command |
| L2-2 | A session survives tab close, app quit and network loss; restore reattaches with the screen intact |
| L2-3 | Closing a tab detaches; "End Session", ⌥-close and worktree removal end sessions; no time-based cleanup |
| L2-4 | With a lost layout snapshot, opening the worktree lists its tagged sessions and reattaches without duplicates |
| L2-5 | Detached sessions show on the worktree row with agent identity and state |
| L2-6 | Inside Prowl tmux: identity via the probe, state via local screen rules; `prowl read --last N` returns tmux history |
| L2-7 | `docs/` documents the option, the detach semantics and the tmux limits |

## Alternatives & decisions

| Option | Decision |
| --- | --- |
| Resident `prowl serve` with HTTP, pairing and a PTY stream (external 082 proposal) | Rejected: daemon, linger and hook injection are more intrusive than hooks; manual non-tmux sessions get presence only; large scope |
| OSC `app` as the only identity | Rejected as the main path: 3 of 17 agents, no `kill -9` detection, self-declared. Kept as the degraded mode |
| Correlation by `SSH_CONNECTION` client port | Rejected: breaks with ControlMaster and ProxyJump |
| Preamble that reports the remote tty via OSC | Rejected: needs a Prowl-built command, misses manual `ssh` |
| Compiled remote probe binary | Rejected: a piped `sh` script works on macOS and Linux with no install |
| Read env of the anchor shell on macOS | Not possible (platform binary); read foreground members instead |
| Map tmux by inherited env | Rejected: the tmux server keeps the first client's variables; map by client tty |
| Capture text for Prowl-managed tmux | Not needed while attached: status bar off makes the local surface equal the agent screen. Used for detached sessions |
| Closing a remote tmux tab kills the session | Rejected (2026-10-17): against tmux's model and the "leave the agent running" use; close detaches, ending is explicit |
| tmux opt-in only | Rejected: default on when the host has tmux, because losing the agent on disconnect is the larger cost |
| L3 resident observer | Not planned (2026-10-16) |

## Amendments

- Updated 2026-10-16: spike record for L0–L2 — see [002-spike-findings.md](002-spike-findings.md)
