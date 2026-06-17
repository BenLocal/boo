# Windows port feasibility

Can boo run on Windows, and what would it take? Short answer:
**yes, and the work is medium-to-large but not a rewrite.** The hard
dependency — libghostty-vt — already supports Windows, so the entire
effort lives in boo's own POSIX glue, which is concentrated in a handful
of small files.

This document is analysis only. No `src/` code was changed to produce
it.

## 1. Conclusion

- **Foundation is not a blocker.** libghostty-vt (the `ghostty-vt`
  module boo depends on) is explicitly cross-platform: macOS, Linux,
  Windows, WebAssembly. This is confirmed two ways:
  - **Officially** — Mitchell Hashimoto's "Libghostty Is Coming" and
    the Ghostty docs describe libghostty-vt as a zero-dependency C/Zig
    library targeting Windows. (Note: the *GUI app* Ghostty is
    macOS/Linux only; boo uses the *library*, not the app.)
  - **In the pinned source** boo actually builds
    (`ghostty-1.3.2-dev-5UdBC...`): the terminal page allocator branches
    per OS — `src/terminal/page.zig` `switch (builtin.os.tag) { .windows
    => AllocWindows (VirtualAlloc/VirtualFree), else => AllocPosix
    (mmap/munmap) }`; there is a dedicated `src/os/windows.zig`; and
    `build.zig` emits a Windows DLL + import library + static lib
    (`ghostty-vt.lib` / `ghostty-vt-static.lib`).
  - **Empirically** — see the spike in §2: `ghostty-vt` and its SIMD
    C++ cross-compiled cleanly to `x86_64-windows-gnu`. The only build
    failures were in boo's own code.

- **Effort: medium-to-large, not rewrite-level.** ~60-70% of boo is
  platform-agnostic and ports untouched: `protocol.zig`, `keys.zig` /
  the input parser, `ui.zig`'s render/diff/layout logic, `config.zig`,
  `help.zig`, and all libghostty-vt rendering. The remaining ~30-40% is
  a thin platform layer (process spawn, PTY, transport, event loop, raw
  mode) — but it is the hard 30-40%. boo is small (~9.7k LOC) and
  already factored along the right seams (`pty.zig`, `client.zig`
  transport, `protocol.zig`), which makes a clean OS-abstraction split
  feasible. Rough estimate: a few weeks of focused work.

- **The two biggest chunks** are the event loop (today a hand-rolled
  `poll()` over heterogeneous fds in three processes) and the daemon
  spawn model (today `fork()`-without-`exec`). Both have de-risked paths:
  libxev for the former (§4), a `__daemon` subcommand for the latter
  (§3).

## 2. The spike

Ran (read-only, no code changes):

```sh
zig build -Dtarget=x86_64-windows-gnu
```

Result: **13/16 build steps succeeded.** `ghostty-vt`, `simdutf`,
`highway`, and the ghostty SIMD C++ (`base64.cpp`, `codepoint_width.cpp`,
`index_of.cpp`, `vt.cpp`) all cross-compiled to Windows. The single
failing step was `compile exe boo` with **3 errors, all in boo's own
source.**

Zig halts semantic analysis at the first errors it reaches and analyzes
lazily, so the spike surfaces only the *first wave* of breakage, not
every call site (later POSIX calls are never analyzed because compilation
stops first). Iterating the spike to drain the full list would require
editing `src/`, which was out of scope. The worklist below therefore
**combines spike-confirmed errors with a static inventory**, labelled
per row:

- **[spike]** — a real compile error from the run above.
- **[static]** — found by grep over `src/`; will surface on a later
  spike iteration once the earlier errors are stubbed.

### The cross-cutting theme the spike exposed

On Windows, `std.posix.fd_t` is `*anyopaque` (a `HANDLE`), **not an
`i32`**. That is why `src/main.zig:57` fails: the integer constant
`posix.STDOUT_FILENO` will not coerce to a `HANDLE`. The same issue
ripples everywhere boo uses an fd as an integer — every
`fd: posix.fd_t = -1` sentinel, every `< 0` / `>= 0` fd test, every
`posix.close(fd)`-on-int. This is mechanical but pervasive, and is the
strongest argument for routing all fd/handle ownership through the OS
abstraction in §3 rather than sprinkling `if (windows)` at call sites.

### Worklist

Grouped by the five OS-interface buckets (§3). Effort: **S** trivial,
**M** a focused file, **L** structural.

#### rawmode + env + paths (small, mostly mechanical)

| file:line | POSIX call | Windows mapping | src | effort |
|---|---|---|---|---|
| `paths.zig:26` (via `main.zig:264`) | `posix.getenv` (BOO_DIR / XDG_RUNTIME_DIR) | `std.process.getEnvVarOwned` / `getenvW` (WTF-16 env) | [spike] | S |
| `config.zig:122` | `posix.getenv` (BOO_CONFIG / XDG_CONFIG_HOME / HOME) | same as above | [static] | S |
| `main.zig:57` | `posix.STDOUT_FILENO` as `fd_t` | `std.fs.File.stdout().handle` / `GetStdHandle`; treat fds as `HANDLE` | [spike] | S |
| `paths.zig:76` | `posix.AT.FDCWD` + `fchmodat` | no POSIX modes on Windows — skip chmod, or set ACLs | [spike] | S |
| `client.zig:74,77,182,268`, `ui.zig:1111,1114` | `tcgetattr` / `tcsetattr` / `cfmakeraw` termios | `GetConsoleMode` / `SetConsoleMode`: input `ENABLE_VIRTUAL_TERMINAL_INPUT`, clear line-input/echo; output `ENABLE_VIRTUAL_TERMINAL_PROCESSING` | [static] | M |
| `daemon.zig:188` | `/proc/{pid}/cwd` (cwd snapshot) | no cheap live cwd on Windows — snapshot cwd at spawn instead (feature degrades) | [static] | S |
| `main.zig:1003`, `main.zig:1008-1019` | `setsid` + `dup2(/dev/null)` detach | `CreateProcess(DETACHED_PROCESS | CREATE_NO_WINDOW)`, stdio → `NUL` | [static] | S |

#### pty (ConPTY) — one file, see §5

| file:line | POSIX call | Windows mapping | src | effort |
|---|---|---|---|---|
| `pty.zig:7-10` | `posix_openpt` / `grantpt` / `unlockpt` / `ptsname_r` | `CreatePseudoConsole(size, hInRead, hOutWrite, 0, &hPC)` | [static] | M |
| `pty.zig:11,70,78,86` | `ioctl(TIOCSWINSZ/GWINSZ)` | `ResizePseudoConsole` (no get-size; track it in boo) | [static] | M |
| `pty.zig:126` | `posix.fork` (then exec) | single `CreateProcessW` with `STARTUPINFOEX` carrying `PROC_THREAD_ATTRIBUTE_PSEUDOCONSOLE` | [static] | M |
| `pty.zig:130,131,133-135` | `setsid` + `TIOCSCTTY` + `dup2(slave)` login_tty | not needed — ConPTY handles the console attach | [static] | S |
| `pty.zig:142` | `execvpeZ` | folded into `CreateProcessW` cmdline + env block | [static] | M |

#### spawn (daemon model) — structural

| file:line | POSIX call | Windows mapping | src | effort |
|---|---|---|---|---|
| `main.zig:320` | `posix.fork` **without exec** (child becomes daemon in-process) | no `fork` on Windows — `CreateProcess` a hidden `boo __daemon <args>` subcommand that re-enters `runDaemon` | [static] | L |
| `daemon.zig:318` | `std.c.waitpid` (reap child) | `WaitForSingleObject` on the child `HANDLE` + `GetExitCodeProcess` (bonus: gives `wait --exit` exit codes for free) | [static] | M |

#### transport (AF_UNIX) — protocol layer is free

| file:line | POSIX call | Windows mapping | src | effort |
|---|---|---|---|---|
| `client.zig:33-39`, `main.zig:1039-1061` | `socket(AF_UNIX)` / `bind` / `listen` / `connect` / `accept` (`daemon.zig:297`) | AF_UNIX works on Win10 1803+; **or** named pipes (`\\.\pipe\boo-<name>`) which integrate better with IOCP | [static] | M |
| bind→fork→inherit fd model | listen fd inherited across `fork` | no fork: daemon binds the socket itself (CLI retries connect), or `WSADuplicateSocket` to hand it over | [static] | M |
| `protocol.zig` (whole file) | framed bytes, **no fd passing (no SCM_RIGHTS)** | ports unchanged | — | 0 |

#### eventloop + signals — see §4

| file:line | POSIX call | Windows mapping | src | effort |
|---|---|---|---|---|
| `daemon.zig:274`, `client.zig:110,234`, `ui.zig:1293-1303` | `poll()` over socket + PTY fd + self-pipe + tty | cannot mix sockets and HANDLEs in one wait on Windows — move to **libxev** (IOCP backend), see §4 | [static] | L |
| `daemon.zig:108-120` | `sigaction(SIGCHLD/SIGPIPE/SIGHUP)` | SIGCHLD → child-handle wait; SIGPIPE → gone (write returns error); SIGHUP → `SetConsoleCtrlHandler` | [static] | M |
| `client.zig:63-66`, `ui.zig:1102-1105` | `sigaction(SIGWINCH/SIGTERM/SIGHUP/SIGPIPE)` | SIGWINCH → console `WINDOW_BUFFER_SIZE_EVENT` via `ReadConsoleInput` | [static] | M |
| `daemon.zig:106`, `client.zig:56`, `ui.zig:1095` | self-pipe trick (`pipe` + write-from-handler) | unnecessary — signals become waitable objects / console events | [static] | S |

## 3. `src/os/` abstraction layer

Rather than `if (builtin.os.tag == .windows)` at every call site, define
a small OS interface and select the implementation at comptime. Main
logic (`main.zig`, `daemon.zig`, `ui.zig`, `client.zig` control flow)
calls the interface and stays platform-agnostic; only the backends know
about POSIX vs Win32.

Proposed shape:

```
src/os/
  root.zig        // pub const impl = switch (builtin.os.tag) { .windows => @import("windows/..."), else => @import("posix/...") };
  spawn.zig       // interface
  pty.zig         // interface
  transport.zig   // interface
  eventloop.zig   // interface
  rawmode.zig     // interface
  posix/  { spawn, pty, transport, eventloop, rawmode }.zig
  windows/{ spawn, pty, transport, eventloop, rawmode }.zig
```

The five interfaces:

1. **spawn** — start the session daemon. POSIX: `fork` without `exec`.
   Windows: `CreateProcess` of `boo __daemon`. Returns an opaque
   `ProcHandle` (pid on POSIX, `HANDLE` on Windows) plus a way to wait
   for exit. Absorbs `main.zig:320`, the detach logic
   (`setsid`/`dup2` ↔ `DETACHED_PROCESS`), and `waitpid` ↔
   `WaitForSingleObject`+`GetExitCodeProcess`.

2. **pty** — `open(size) -> Pty`, `setSize`, `spawnInPty(argv, env, cwd)
   -> { proc, master }`, where `master` is a read/write byte stream.
   POSIX: openpty + fork + login_tty. Windows: ConPTY (§5). Keep the
   existing `Spawned { pid, master }`-shaped result so callers barely
   change.

3. **transport** — `listen(name) -> Listener`, `accept`, `connect(name)
   -> Conn`, with `read`/`write` over a byte stream. The framed
   `protocol.zig` sits on top unchanged. POSIX: AF_UNIX. Windows:
   AF_UNIX or named pipes.

4. **eventloop** — register readable sources (transport conns, pty
   master, child-exit, console input/resize, timers) and dispatch
   callbacks. This is where `poll()` and signals are replaced; backed by
   libxev (§4). The daemon/client/ui loops are rewritten in terms of
   this single abstraction.

5. **rawmode** — `enter(tty) -> Saved`, `restore(Saved)`. POSIX:
   termios. Windows: `GetConsoleMode`/`SetConsoleMode` with VT flags.

A cross-cutting `Fd`/`Handle` newtype in `os/` should own the
"fd is int on POSIX, HANDLE on Windows" difference (the §2 theme) so the
`-1` sentinels and `< 0` tests disappear from shared code.

## 4. Event loop via libxev

The single largest item is replacing the hand-rolled `poll()` loops.
On Windows you cannot wait on a socket, a ConPTY pipe `HANDLE`, a process
`HANDLE`, and console input in one call (`WSAPoll` is sockets-only;
`WaitForMultipleObjects` is handles-only and caps at 64). Hand-rolling
IOCP is possible but costly.

**libxev** solves this directly and is already in boo's dependency
graph — it is a transitive dependency of ghostty (present in the zig
cache as `libxev-0.0.0-86vtc4...`). It is a cross-platform event loop by
Ghostty's author with backends for epoll, kqueue, **IOCP**, and
io_uring, exposing a uniform completion-based API.

Plan: model each readable source (transport conn, pty master, timer,
child-exit, console resize) as a libxev completion. On POSIX this also
*replaces* the current `poll()` + self-pipe-trick code, so the loop
becomes one implementation across platforms instead of two — a net
simplification, not just a Windows bolt-on. SIGCHLD becomes a process
watcher; SIGWINCH becomes a console-input read; SIGPIPE disappears.

## 5. ConPTY notes (gotchas to budget for)

Zig has no mature ConPTY wrapper (unlike Go's `UserExistsError/conpty`
or Rust's `conpty` crate), so `os/windows/pty.zig` hand-rolls Win32 via
`std.os.windows`. Hand-rolling ConPTY is a known trap — bank time for
these:

- **Read the master with raw `ReadFile`/`WriteFile` (or overlapped I/O),
  never by wrapping the pipe HANDLE in a generic file abstraction.** In a
  prior Go ConPTY effort, wrapping an externally-created `CreatePipe`
  HANDLE in `os.NewFile` produced **silent zero-byte output** — the
  process started, the ConPTY created, but no bytes ever arrived. The
  fix was a tiny wrapper calling `ReadFile`/`WriteFile` directly. The
  Zig equivalent: feed the libxev IOCP loop the raw HANDLE with
  overlapped reads; do not route it through assumptions meant for
  Go/Zig-runtime-owned handles.
- **`ClosePseudoConsole` kills the attached child** ("there is no return
  value"). Teardown order matters: close the pseudoconsole, then the
  process/thread/pipe handles. Wire this into the spawn interface's
  close path.
- **There is no half-close.** ConPTY is a single underlying handle pair;
  you cannot close just stdin. Model teardown as one operation.
- Build the child command line and an environment block (`TERM=` etc.);
  pass dimensions via `COORD`. Resize via `ResizePseudoConsole`; ConPTY
  has no "get size", so boo must track the current size itself.

## 6. Phased plan

1. **Spike & worklist (done).** Cross-compile, confirm libghostty-vt
   builds for Windows, collect the breakage. Iterate the spike (stubbing
   each error) to drain the full list — this *does* touch `src/`, so it
   belongs to phase 2, not the read-only assessment.
2. **Carve the `os/` layer on POSIX first.** Introduce the five
   interfaces and move existing POSIX code behind them, with the POSIX
   backend only. No behavior change; native build and tests stay green.
   This is pure refactor and de-risks everything after it.
3. **Event loop onto libxev (POSIX).** Replace the three `poll()` loops
   and the self-pipe trick with the libxev-backed `eventloop` interface,
   still on Linux/macOS. Verify no regression. Now the hardest Windows
   item is already cross-platform.
4. **Windows backends, one interface at a time**, each verified by
   re-running the spike and shrinking the error list:
   rawmode → transport → pty (ConPTY) → spawn (`__daemon`) → eventloop
   (IOCP). rawmode/transport first because they unblock a minimal
   `boo ls`/`send`/`peek` headless path before the full attach UI.
5. **CI + packaging.** Add an `x86_64-windows` build (and `aarch64`) to
   `ci.yml` and `release.yml`; produce a `.zip`/`.exe` asset.

## 7. Risks & unknowns

- **The full worklist is partial.** Only 3 errors are spike-confirmed;
  the rest are static predictions that Zig has not yet reached. New
  breakage *will* appear during phase 2 (especially around the
  `fd_t`-is-`HANDLE` ripple and any deeper `std.posix` use in shared
  code). Treat §2's table as a floor, not a ceiling.
- **AF_UNIX vs named pipes** is an unforced design choice. AF_UNIX is
  less code now but does not compose with IOCP as cleanly as named
  pipes; choosing named pipes means a bigger transport rewrite but a
  more coherent Windows event model. Decide before phase 3.
- **Daemon lifecycle without fork-without-exec.** Re-entering via
  `boo __daemon` reintroduces the daemon-startup race the current code
  deliberately avoids by binding the socket before forking. Needs a
  deliberate handshake (daemon signals "listening" before the CLI
  returns) — design work, not just translation.
- **Console fidelity.** boo emits ANSI/VT directly. Modern Windows
  (conhost with VT processing, Windows Terminal) handles it, but legacy
  consoles and edge cases (mouse, bracketed paste, kitty keyboard
  protocol negotiation in `keys.zig`) need real-terminal testing on
  Windows, which the Linux CI cannot cover.
- **libxev API stability / fit.** Assumed adequate for ConPTY-pipe +
  socket + process-exit + console-input on Windows; not yet validated
  against its IOCP backend specifically.
- **No Windows test runner here.** Everything above is cross-compile +
  static analysis. Runtime behavior (ConPTY output, attach/detach,
  resize) is unverified until run on an actual Windows host.

## Appendix: reproducing the spike

```sh
# zig 0.15.2; ghostty dep already in the zig cache
zig build -Dtarget=x86_64-windows-gnu
# => 13/16 steps succeed; "compile exe boo" fails with 3 errors in src/.
# ghostty-vt + SIMD C++ compile clean for Windows.
```
