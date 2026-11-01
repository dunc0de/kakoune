# Debugging Kakoune Scripts — Structured Methodology Adaptation

This reference adapts the 6-cycle hypothesis-driven debugging methodology specifically for Kakoune editor scripts, hooks, and commands. The principles are identical to generic structured-debugging (hypothesize → instrument → verify data collection → run & observe → document findings → iterate), but the instrumentation points, failure modes, and verification steps are Kakoune-specific.

## When to use this

Use it when debugging Kakoune scripts or hooks:
- A hook misfires, fires at wrong time, or doesn't fire at all (especially in draft mode)
- `execute-keys` keystrokes break under certain mappings
- Command quoting silently changes behavior between contexts
- `%{}` balanced-string parse errors or `%sh{}` expansion surprises
- FIFO hooks enter infinite reentrancy loops
- Multi-selection scripts silently drop selections (missing `-itersel`)
- POSIX shell inside `%sh{}` breaks on dash-based systems
- Status-line flicker, selection merging under rapid input, or TUI-only edge cases

## The Cycle — Kakoune Adaptation

### 1. Hypothesize

Write down what you think is happening and why, using Kakoune-specific language:
- Bad: "The command doesn't work." Good: "`execute-keys 'j'` inside the InsertChar hook isn't moving because a Normal-mode mapping for `j` intercepts it; I should use `evaluate-commands -no-hooks normal-mode` instead."

Create an investigation journal in `<scenario>-debug-YYYYMMDD-HHMMSS/investigation.md`. See the main SKILL.md for the full template.

### 2. Design Instrumentation

Kakoune has two primary instrumentation tools:
- **Headless**: `kak-validate.sh` with `--require` tokens and optional command execution — catches parse/scope/runtime errors before they reach TUI.
- **TUI**: tmux snapshots via `capture-pane -p` after each meaningful state change — for issues that only manifest in real editor interaction.

Identify the 2–3 places where your hypothesis makes a testable prediction; instrument those. Prefer logging *data* (validation exit codes, debug-buffer contents, pane text at key moments) over *presence checks* ("was this hook called?"). Code-path traces tell you what ran; data traces tell you what it ran on. Most Kakoune bugs are correct code processing wrong input — a stray `%`, an unbalanced `%{`, or a doubled delimiter can change everything.

Ask yourself: "If my hypothesis is correct, what will I see in the `\*debug*\` buffer? What exit code will `kak-validate.sh` return? What mode text will appear on screen?" If it's wrong, what will I see instead?

### 3. Verify Data Collection

Before running, confirm instrumentation output will be captured:
- Is `kak-validate.sh`'s stderr being saved to a file? (stderr from `%sh{}` goes to `\*debug*\`, which may not be visible in headless mode — redirect explicitly.)
- Does the tmux session exist before calling `capture-pane`? Poll for Kakoune's readiness (`-- Normal --` or similar status line) rather than blind sleeping.
- Will Kakoune's `\*debug*\` buffer capture `%sh{}` error messages? In headless mode, check stderr redirected to a file; in TUI mode, `:echo-debug`.

A test run that produces no data is wasted. Common traps specific to Kakoune debugging:
- `%sh{}` errors go to `\*debug*\` buffer — invisible unless you look at it
- Headless `-ui json` may not render status-line changes; use TUI snapshots instead
- `capture-pane -p` records current rendered state, not transient flicker or very short messages

### 4. Run and Observe

Execute in order: headless first, TUI second only if needed (see [tmux decision tree](../SKILL.md#decision-tree-write-path-headless-vs-tmux)). Read every line of output — don't assume what it says. When data contradicts your hypothesis, believe the data. Don't rationalize it away.

The whole point of this step is to let reality override your theory. Kakoune's `\*debug*\` buffer may contain `%sh{}` error messages that are easy to miss; always check it even when headless validation "passes." The command-line sometimes drops rapid bulk input — send characters one at a time and watch the mode transition carefully.

### 5. Document Findings

Update `investigation.md` with:
- What the data showed (quote specific lines from validation output, tmux snapshots, `\*debug*\` buffer contents)
- What was confirmed vs disproved per round
- Updated hypothesis for next iteration

This is critical — hard Kakoune bugs typically take 3–5 rounds. Without notes, you'll forget what you ruled out and waste runs re-checking things. Re-read the journal before starting each new round.

### 6. Iterate

Update the hypothesis based on new evidence; go back to step 2. Each round should narrow the search space. If no progress after 3 rounds, question assumptions — the bug might be in a layer you haven't considered (external tool dependency, shell environment, tmux configuration, or an interaction between two scripts that individually pass validation).

Exit only when you can point to specific data from instrumentation that confirms the root cause:
```text
Root cause: [specific mechanism]
Evidence: [specific log lines / validation output / pane text that confirm it]
Fix: [what you're changing and why it addresses the root cause]
```

Then apply the fix, remove instrumentation, and verify with a clean run.

## Kakoune-Specific Failure Modes to Watch For

These are the most common traps this methodology is designed to prevent. When you notice yourself drifting toward any of them, stop and return to the cycle.

### Hook Misfires (Most Common)

Hooks fire based on **entire-parameter-string** matching (not substring). A filter like `.cc$` won't match a `BufSetOption` parameter that includes both filename and option name — use `$` anchors carefully or wrap in capture groups accessed via `$kak_hook_param_capture_N`.

- **Draft-context hooks** (`WinCreate`, `WinClose`, `WinResize`, `WinDisplay`, `WinSetOption`) discard selection/input changes but persist buffer writes. A hook calling `normal-mode` inside a draft context appears to work but the change is thrown away. Use `-always` for guaranteed trigger, and prefer `%sh{}` env vars or buffer-scoped hooks for persistent state.
- **RawKey** can't be triggered by `execute-keys`, even with `-with-hooks`. This prevents recursive key-trigger loops from within scripts — intentional but surprising.

### Keystroke Breaking Under Mappings

`execute-keys` runs keystrokes subject to mappings unless `-with-maps` is used. A Normal-mode mapping for the same key will intercept your keystrokes, silently changing what happens. Use `evaluate-commands -no-hooks` when calling commands from hooks to prevent reentrancy (a command you call triggers a hook → that hook calls back into `execute-keys` → infinite loop without `-no-hooks`).

### Command Quoting Silent Changes

- **Balanced strings `%{...}`**: backslash does NOT escape delimiters; even inside other strings. A genuine nested `{` must be genuinely nested, not escaped (`%{foo\{bar}}` contains `{` literally — the `\` is just a literal character). Unbalanced `%{` = parse error.
- **Double quotes `"..."`**: `%`-strings processed unless doubled (`%%`). Inside nested `%` strings, `"` must also be escaped. A stray unescaped `%` that isn't followed by a known type or delimiter may silently produce unexpected expansion.
- **Typed expansions**: only `sh`, `reg`, `opt`, `val`, `arg` (and empty) are valid; any other type = hard parse error, not warning — the command fails to load entirely.

### FIFO Hook Reentrancy Loops

FIFO hooks (`BufOpenFifo`, `BufReadFifo`, `BufCloseFifo`) can enter infinite loops: if your hook writes back to the same fifo being consumed by a hook, it re-fires infinitely. Use `-no-hooks` when writing back to a fifo being consumed by a hook. The `BufReadFifo` range parameter format (`<line>.<col>,<endline>.<endcol>`) is already in Kakoune range syntax — don't try to convert it.

### Multi-Selection Merging Without `-itersel`

Running `execute-keys`/`evaluate-commands` across multiple selections without `-itersel` merges the selection list, silently dropping work for all but the first cursor. Use `-itersel` whenever running commands across potentially multiple selections — this is critical for multi-cursor workflows and is almost always omitted by accident.

### POSIX Shell on Dash-Based Systems

Kakoune `%sh{}` blocks run in a POSIX-compliant shell (often dash on minimal systems). Bashisms silently break:
| Avoid | Use | Reason |
| --- | --- | --- |
| `echo "..."` with ambiguous content | `printf '%s\n' "${var}"` | Portability across dash, bash, ksh |
| `${var##*/}` over `$(basename "$var")` | — | Avoid external command dependency |
| `[ ... ]` over `[[ ... ]]` | — | Not POSIX; dash doesn't support it |
| `>/dev/null 2>&1` over `&>` | — | Portability |
| `expr "$x" : 'pattern'` over `[[ $x =~ re ]]` | — | Regex matches whole string only (anchors undefined) |

### Inspecting Code Paths But Not Data

You instrument the code and prove it executes correctly — right functions called, in order, no errors. But the bug persists. Why? Because the code can work perfectly while processing garbage input. A function that correctly reads an inbox, delivers messages, formats output is still broken if the inbox contains stale data. Always inspect the *content* flowing through the code, not just whether it runs. Check payloads, message contents, file data, and Kakoune's `\*debug*\` buffer for `%sh{}` errors.

### Blaming External Systems Without Evidence

"The model is hallucinating." "The API is flaky." These conclusions feel satisfying but are usually wrong. Before blaming an external system, inspect what it actually received. A Kakoune script that appears to misbehave may be responding rationally to stale data or malformed input you didn't know was there. Look at inputs (register contents, selection ranges, buffer state) not just outputs (mode text, pane content).

### Reframing the User's Report Instead of Investigating It

When the user reports a symptom your own run doesn't reproduce, the contradiction *is* the evidence — the two environments differ in some way you haven't identified yet. Catalogue what differs between their environment and yours (TTY vs pipe, terminal emulator, shell, locale, env vars, prior state) before forming any hypothesis. For ambiguous symptoms ("it's slow", "it looks wrong"), ask one disambiguating question first — e.g., "does it hang or exit cleanly?" That prunes the hypothesis space before any test run.

### Losing Context Across Attempts

After several debugging rounds, you start forgetting what you already tried and what you ruled out. You re-check things, go in circles, or abandon a promising line of investigation because you lost track of where it was heading. This is why the `investigation.md` file exists — update it after every run; re-read it first when starting a new round.

### Persistent State Contamination

Features that persist data across runs (caches, session recordings, temp files, FIFOs) often cause "impossible" bugs. The current run's behavior is contaminated by leftover state from previous runs. When behavior seems irrational, always check:
- Is there persistent state that carries across runs?
- Was it cleared before this run?
- Is the system responding to stale data rather than current data?

This is easy to miss because the code is correct — it's the data that's wrong. In Kakoune specifically: temp FIFOs from previous runs, leftover `\*debug*\` buffer content, or unclosed tmux sessions can all contaminate a fresh debug run. Always clean up before each round (delete old FIFO dirs, kill stray tmux sessions).
