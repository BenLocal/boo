# boo ui — kitty-keyboard input to fix SSH scroll flicker (B-精简)

- **Date:** 2026-06-25
- **Branch:** self
- **Status:** Design — pending review

## 1. Problem

Over SSH (boo daemon on Linux, `boo ui` rendering to a Mac terminal), scrolling
the viewport up makes the screen flicker and snap back to the bottom. It does not
happen with boo run locally on the Mac. It is independent of window size and
happens on an idle, primary-screen shell.

## 2. Root cause (confirmed)

`boo ui` disambiguates a lone trailing `\x1b` (the ESC key vs the start of a split
escape sequence) with a 50 ms timeout (`esc_flush_ms = 50` in `src/ui.zig`):
`readTty` arms `esc_deadline` when a read ends with `held_len == 1`, and
`flushPendingEsc` later delivers it as an ESC keypress.

Over SSH, TCP splits a mouse-wheel report `\x1b[<64;col;rowM` so a `read()` can end
on just `\x1b`; the remainder arrives >50 ms later (network jitter), the timer
fires first, and boo treats it as a **spurious ESC keypress**. The `.esc` handler
(`src/ui.zig`, the `.esc` arm of `handleEvent`) does, while the view is scrolled:

```zig
if (self.viewScrolled()) { self.snapViewBottom(); return; }
```

So the view snaps to the bottom (= "comes back") and `full_render` repaints
(= flicker). Momentum scrolling streams wheel reports, so this repeats → continuous
flicker. Locally the whole sequence arrives in one read, so it never misfires.

## 3. Goals / Non-goals

**Goals**
- Eliminate the spurious-ESC misfire so scrolling over SSH neither snaps back nor
  flickers, with **no added ESC latency** for keys sent to the focused session.
- Keep correct key delivery for every focused-app keyboard protocol (legacy,
  xterm modifyOtherKeys mode 2, kitty).
- Degrade safely on terminals without kitty-keyboard support.

**Non-goals**
- No new boo features (this is a correctness fix).
- No change to how the daemon talks to clients, or to mouse handling beyond what
  the fix requires.
- Not adopting the full kitty "report all keys" mode (that is B-完整; rejected for
  a larger re-encode surface).

## 4. Approach overview (B-精简)

Make the **outer terminal** (the one `boo ui` writes to) keep the kitty
"disambiguate escape codes" flag (`0b1`) set whenever it supports kitty. Then a
real ESC key arrives unambiguously as `CSI 27 u`, a lone trailing `\x1b` is always
an incomplete sequence, and the 50 ms timeout is removed on that path — so a split
wheel report can never be misread as ESC.

Because boo currently **passes keystrokes through to the focused app verbatim**
(the parser emits `.forward` with the original bytes; it relies on the outer
terminal already matching the app's protocol via mirroring), forcing disambiguate
means the disambiguated keys (ESC, Ctrl+key, Alt+key, a few modified specials)
arrive kitty-encoded and must be **re-encoded to the focused app's protocol** before
forwarding. Plain text keys are unaffected and pass through untouched (this is what
makes it "精简" vs report-all-keys).

When the outer terminal does **not** support kitty, fall back to today's behavior
but with the timeout raised (`esc_flush_ms` 50 → 200) as the degraded mode.

## 5. Detailed design

### 5.1 Capability detection (startup handshake)

After entering raw mode / alt-screen / mouse modes, `boo ui` queries the outer
terminal once:

1. Send the kitty query `\x1b[?u` followed by a Primary DA fence `\x1b[c`.
2. Read input during a bounded handshake window. A kitty-capable terminal replies
   `\x1b[?<flags>u` **before** the DA reply `\x1b[?<...>c`; a terminal without
   support replies only DA1.
3. Set `outer_kitty: bool` accordingly. The handshake bytes are consumed by the
   handshake, never delivered to the session.

Edge cases: if neither reply arrives within the window (rare/dumb pty), assume
**unsupported** and use the fallback. The DA fence guarantees the handshake
terminates promptly on every real terminal.

### 5.2 Outer-terminal mode management

`syncKeyboard` already computes the outer terminal's kitty flags as
`app_flags | (report_events while prefix engaged)`. Change to:

```
disambiguate_base = if (outer_kitty) 0b1 else 0
kitty = app_flags | disambiguate_base | (report_events if prefixEngaged)
```

So when supported, the outer terminal always has at least `0b1`, and the parser
runs in kitty mode (`prot.kitty == true`) at all times. `restore_sequence` already
clears kitty flags on exit (`\x1b[=0;1u`), so teardown is unchanged.

### 5.3 ESC-timeout removal (kitty path) + fallback

- When `outer_kitty` is true: `readTty` does **not** arm `esc_deadline` (a lone
  `\x1b` is always a held incomplete sequence; the parser already holds it — see
  the existing "raw ESC alone in kitty mode is held until disambiguated" behavior
  in `keys.zig`). The real ESC key arrives as `CSI 27 u`.
- When `outer_kitty` is false: keep `esc_deadline`, but `esc_flush_ms` becomes 200.

### 5.4 Parser: decode the keys boo must act on or re-encode

The parser must, in kitty mode, recognize the disambiguated keys it currently only
sees in legacy form:

- **ESC key** (`CSI 27 u`, optionally with mods): emit the existing `.esc` event so
  scroll-snap / browse-cancel still work, carrying the legacy bytes (`\x1b`) for the
  forward path.
- **Other forwarded keys** that arrived kitty-encoded (Ctrl+letter, Alt+letter,
  modified specials): the parser already replays held bytes via `.forward` when a
  CSI-u key is not a boo command. That replay must hand ui.zig enough to re-encode:
  emit a decoded key (`cp`, `mods`, `event`) rather than raw kitty bytes for the
  forward path.

`keys.zig` already has `parseKitty` → `KittyKey {cp, mods, event}` and
`effectiveCp`; this reuses them. Prefix/command detection (`finishCsiU`) is
unchanged.

### 5.5 Re-encode mapping (the crux)

A new pure function `encodeForApp(key: KittyKey, prot: Protocols) []const u8`
(in `keys.zig`) turns a decoded key into the bytes the focused app expects:

- **prot.kitty** (app uses kitty): pass the original kitty bytes through (no change).
- **prot.modify** (modifyOtherKeys mode 2): emit `CSI 27 ; mods ; cp ~`.
- **legacy** (default): emit the legacy encoding:
  - plain printable cp → the UTF-8 byte(s);
  - Ctrl+letter → the C0 control byte (`cp & 0x1f`);
  - Alt+X → `ESC` + legacy(X);
  - ESC → `\x1b`; Enter/Tab/Backspace → `\r`/`\t`/`0x7f`;
  - cursor/nav specials → their legacy `CSI`/`SS3` forms (respecting DECCKM).

Plain text never reaches this path under disambiguate-only (it is not CSI-u
encoded), so the mapping only needs the control/modified/special set. The mapping
is data-driven and unit-tested exhaustively against the three protocols.

### 5.6 Data flow

```
outer terminal (kitty, disambiguate) ──bytes──▶ readTty ──▶ Parser.feed (prot.kitty=true)
   ├─ prefix / command key      → consumed by boo (handlePrefix, scroll, browse)
   ├─ ESC key (CSI 27 u)         → .esc event → boo semantic, else forward(encodeForApp)
   └─ other key                  → forward: encodeForApp(key, focusedAppProtocol) → daemon → app
```

## 6. Error handling / edge cases

- Terminal advertises kitty but a key still arrives as a bare `\x1b` (non-conformant):
  the parser holds it; if a later byte diverges, `flushHeld` replays — never a
  spurious ESC, because we no longer arm the timeout in kitty mode.
- Focused app's protocol changes mid-session (e.g., launches vim): `syncKeyboard`
  already tracks the app's flags each loop; `encodeForApp` reads the current
  protocol at forward time, so it adapts.
- Outer terminal that supports kitty but the user later detaches/reattaches: handshake
  runs once per `boo ui` process; reattaching a view does not re-handshake.

## 7. Testing strategy (TDD)

Integration tests (PtyClient, run on Linux) and `keys.zig` unit tests:

1. **Regression for the bug:** in kitty mode, feed a wheel report split as `\x1b`
   then (after a >200 ms gap) `[<64;5;5M`; assert **no** `.esc`/snap and the wheel is
   handled as one scroll. Today this misfires; the test goes red→green.
2. **No ESC latency:** a real ESC as `CSI 27 u` produces the `.esc` event immediately
   (no timeout wait).
3. **Re-encode correctness:** `encodeForApp` unit tests for ESC, Ctrl+C, Alt+x,
   Enter/Tab/Backspace, arrows, against legacy / modifyOtherKeys / kitty — exact bytes.
4. **Capability handshake:** simulate a terminal that replies kitty+DA (→ supported)
   vs DA-only (→ fallback); assert the chosen path and that handshake bytes never
   reach the session.
5. **Fallback path:** with `outer_kitty=false`, the 200 ms timeout still flushes a
   genuine lone ESC.

Manual verification: cross-compile an `aarch64-macos` (and Linux) binary; user runs
it on the Linux box, SSHes from the Mac (Ghostty), confirms scrolling no longer
flickers and ESC/Ctrl-C/vim still work in a session.

## 8. Risks & mitigations

- **Highest risk: breaking key delivery for all users.** Mitigation: `encodeForApp`
  is pure and exhaustively unit-tested per protocol; the full integration suite
  (242 tests) must stay green; manual cross-protocol check (legacy shell, vim via
  modifyOtherKeys/kitty) before merge.
- **Handshake hangs / dumb terminals:** the DA1 fence bounds the wait; timeout →
  fallback.
- **Non-conformant terminals advertising kitty:** parser holds rather than misfires;
  worst case a key is delayed until the next byte, never a spurious action.

## 9. Phasing (for the implementation plan)

1. `esc_flush_ms` → 200 + parameterize; keep current behavior (the safe fallback,
   independently useful). Tests.
2. `encodeForApp` in `keys.zig` + exhaustive unit tests (no wiring yet).
3. Capability handshake at startup (`outer_kitty`). Tests.
4. Wire it: always-disambiguate via `syncKeyboard`, drop the kitty-path ESC timeout,
   route forwarded keys through `encodeForApp`. Integration tests incl. the bug
   regression.
5. Build + full suite + macOS cross-compile; manual SSH verification by the user.
