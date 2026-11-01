---
name: kakoune-moe
description: |
  A merged skill for Kakoune editor work that combines three layers: authoring
  `.kak` scripts, hypothesis-driven debugging of Kakoune-specific failures, and
  real-TUI verification through tmux. Use this whenever the user wants to create
  or debug a Kakoune command, hook, mapping, highlighter, option, FIFO-backed
  async tool, or completion system — or when they need to validate a script in
  headless mode before running it as a real user would in tmux. This is the only
  skill that covers the full Kakoune scripting lifecycle: from writing the first
  line through validation and TUI testing. Do NOT use this for general Vim, nvim,
  or terminal multiplexing without Kakoune context — those need different skills.

---

# Kakoune-MoE (Merging Authoring + Debugging + Verification)

This skill covers the full Kakoune scripting lifecycle in one workflow:

1. **Author** — Write `.kak` scripts following conventions, with headless validation
2. **Debug** — Apply hypothesis-driven 6-cycle methodology to Kakoune-specific failures
3. **Verify** — Run real-TUI tests via tmux and produce readable logs

Both entry paths share the same infrastructure: all Kakoune reference docs, `kak-validate.sh` (headless gate), `tmux-real-user-log.sh` (TUI gate), and the investigation-journal pattern.

## Why this skill exists

Kakoune is a *modal* editor with a command model that differs sharply from vim-like editors:
- `execute-keys` runs keystrokes (subject to mappings) while `evaluate-commands` runs commands directly (and injects a `local` scope). Getting this wrong produces scripts that "work" in one context and silently misbehave in another.
- Command parsing is subtle: a stray `%`, an unbalanced `%{`, or a doubled delimiter can change what your script actually runs.
- Hooks can misfire (draft-context hooks discard selection/input changes but persist buffer writes), FIFOs enter infinite reentrancy loops, and POSIX shell inside `%sh{}` breaks on dash-based systems.

A skill that only covers authoring misses the failures that reach users. A debugging-only skill doesn't know what constructs to look for. A testing-only skill can't tell if a script is structurally valid before running it. This skill combines all three.

## When to use

### Authoring triggers
Use when the user wants to:
- create a new Kakoune script or add a command / option / keymap to an existing one,
- wire up a `hook` (e.g. react to file type change, character insertion),
- paint a `highlighter` (regex, column, number-lines, etc.),
- build a completion (`completers` option + candidate format) or an async/FIFO-backed tool,
- add a `-docstring` to a command or option so it shows in completion.

### Debugging triggers
Use when the user reports or asks about:
- why does my Kakoune script misbehave in certain contexts?
- debug Kakoune keystrokes / command quoting that silently change behavior,
- this hook doesn't fire (or fires at wrong time) — especially in draft mode,
- `execute-keys` vs `evaluate-commands` confusion producing different results,
- FIFO hooks hanging or re-entering infinitely,
- multi-selection scripts dropping selections without `-itersel`,
- POSIX shell code breaking on dash-based systems.

### Verification triggers
Use when the user wants to:
- test Kakoune like a real user (TUI session through tmux),
- generate readable TUI logs of Kakoune interaction,
- run a full end-to-end scenario with step-by-step snapshots and a final report.

## Prerequisites

- `kak` reachable on `PATH`. Confirm with `kak -version` (switch is `-version`, not `--version`). If missing, stop and tell the user — do not fabricate a validation run.
- For scripts that shell out, external tools must be available. Keep dependencies minimal (see `references/scripting.md`).
- `tmux` reachable on `PATH` for TUI verification paths.

## The workflow — two entry points, shared toolkit

| Path | Entry phrase | Primary workflow | Validation gate |
| --- | --- | --- | --- |
| **Write a script** | "Create a Kakoune hook/command/mapping" | Author → conventions → `kak-validate.sh` (headless) → report | Always headless; tmux optional if TUI-only behavior matters |
| **Debug an issue** | "This command's keystrokes break inside draft mode — why?" | Hypothesize → instrument (validation + snapshots) → verify data collection → run & observe → document findings → iterate | Headless first; tmux for TUI-only edge cases only |

Both paths share all 10 Kakoune reference files, `scripts/kak-validate.sh`, `scripts/tmux-real-user-log.sh`, and the investigation-journal pattern. See [Validation gate hierarchy](#validation-gate-hierarchy) for when to use each tool.

### Decision tree: write path — headless vs tmux

After writing a script, **always** run headless validation first (`kak-validate.sh`). Only proceed to tmux verification if one of these conditions holds:

1. Hooks are involved (mode transitions, draft behavior, reentrancy)
2. Key bindings / mappings need TUI confirmation
3. The user explicitly asks for a real-user test or wants a readable log
4. Headless validation passes but you suspect TUI-only edge cases (status-line flicker, selection merging, rapid-command-input dropping)

If none of these apply, headless is sufficient — report the script and its validation result and move on.

## Write a Script

1. **Scope.** Decide what the script adds: command (`define-command`, hyphen-separated name), option (`declare-option`, underscore-separated), mapping (`map`), hook (`:hook`), highlighter (`add-highlighter`), or shell bridge (`%sh{}`). Read the matching reference file first. See [References](#references).
2. **Write** following conventions below. Prefix every option/command with script name; give non-hidden commands/options a `-docstring`; keep shell code POSIX-portable.
3. **Validate in headless Kakoune.** Run `scripts/kak-validate.sh` (see [Validation](#validation)). It loads your script in `kak -ui json` and reports command-resolution, scope, and syntax problems. Fix anything it finds; re-run until clean.
4. **Report.** Show the final script and what validation confirmed. If `kak` is unavailable, say so explicitly rather than claiming success.

## Debug an Issue — The 6-Cycle Methodology (Kakoune-Adapted)

When debugging Kakoune-specific failures, follow this cycle. Each round narrows the search space; don't jump to fixes without evidence.

### 1. Hypothesize
Before touching code, write down what you think is happening and why — with Kakoune-specific detail:
- Bad: "The command doesn't work." Good: "`execute-keys 'j'` inside the hook isn't moving because a Normal-mode mapping for `j` intercepts it; I should use `evaluate-commands -no-hooks normal-mode` instead."

Create an investigation journal in `<scenario>-debug-YYYYMMDD-HHMMSS/investigation.md` (see [Investigation Journal](#investigation-journal)).

### 2. Design Instrumentation
Kakoune has two primary instrumentation tools:
- **Headless**: `kak-validate.sh` with `--require` tokens and optional command execution — catches parse/scope/runtime errors before they reach TUI.
- **TUI**: tmux snapshots via `capture-pane -p` after each meaningful state change — for issues that only manifest in real editor interaction (hook timing, status-line flicker, selection merging).

Identify the 2–3 places where your hypothesis makes a testable prediction; instrument those. Prefer logging *data* (validation exit codes, debug-buffer contents, pane text at key moments) over *presence checks* ("was this hook called?").

### 3. Verify Data Collection
Before running, confirm instrumentation output will be captured:
- Is `kak-validate.sh`'s stderr being saved to a file?
- Does the tmux session exist before calling `capture-pane`?
- Will Kakoune's `\*debug*\` buffer capture `%sh{}` error messages?

A test run that produces no data is wasted.

### 4. Run and Observe
Execute in order: headless first, TUI second only if needed. Read every line of output — don't assume what it says. When data contradicts your hypothesis, believe the data. Check Kakoune's `\*debug*\` buffer for `%sh{}` errors that are easy to miss.

### 5. Document Findings
Update `investigation.md` with: what the data showed (quote specific lines from validation output and tmux snapshots), what was confirmed vs disproved, updated hypothesis for next iteration.

### 6. Iterate
Update the hypothesis based on new evidence; go back to step 2. Each round should narrow the search space. If no progress after 3 rounds, question assumptions — the bug might be in a layer you haven't considered (external tool dependency, shell environment, tmux configuration).

Exit only when you can point to specific data that confirms the root cause, then apply the fix and verify with a clean run. See [references/debugging.md](./references/debugging.md) for Kakoune-specific failure modes to watch for during this cycle.

## Investigation Journal

Create a timestamped directory per debug session:
```text
tmp/<scenario>-debug-YYYYMMDD-HHMMSS/
└── investigation.md   # the journal (markdown, persists across turns)
```

The `investigation.md` template contains all six cycle phases:
1. **Hypothesis** — what you think is happening and why
2. **Instrumentation plan** — which tools/data will confirm or reject it
3. **Observations per run** — quote specific lines from validation output, tmux snapshots, `\*debug*\` buffer contents
4. **Updated hypothesis** — revised based on evidence
5. **Findings** — confirmed vs disproved per round
6. **Root cause** — when resolved: mechanism + specific evidence quotes

This replaces the shell-side-note pattern with a markdown file that persists across conversation turns and even sessions. Never overwrite previous runs; append new rounds.

## Validation Gate Hierarchy

The validation tools form a strict hierarchy:

### Always first: headless `kak-validate.sh`
Loads your script in `kak -ui json` (headless, no display). Reports command-resolution, scope, and syntax problems without any TUI interaction. This catches ~90% of structural errors instantly.

Usage:
```bash
# Validate a script file (loads it, then exits).
scripts/kak-validate.sh path/to/my.kak

# Validate AND exercise a specific command in the same headless session.
scripts/kak-validate.sh path/to/my.kak "my-command arg"

# Require the script to contain specific Kakoune constructs before passing.
scripts/kak-validate.sh --require define-command --require execute-keys path/to/my.kak
```

Returns non-zero on load error or command failure; echoes output so you can see where it broke. If `kak` is not on `PATH`, prints a clear message and exits non-zero — do not skip this gate.

**Two structural gates embedded in the validator:**
1. **Kakoune-DSL gate** — The file must contain at least one Kakoune keyword (`define-command`, `hook`, `add-highlighter`, `declare-option`, `execute-keys`, `evaluate-commands`, `%sh{`, `%val{`). Pure shell or prose fails here.
2. **`--require TOKEN` gate** — Every supplied token must appear in the file; catches wrong command names and wrong constructs (e.g., `define-key` instead of `define-command`).

### Optional second: tmux real-user testing (`tmux-real-user-log.sh`)
Only when headless validation passes but behavior still seems wrong — hook timing edge cases, TUI-only status-line flicker, selection merging under rapid input, or any scenario where the bug only manifests in a live editor session. This is explicitly documented as "when headless validation passes but behavior still seems wrong."

Usage:
```bash
eval "$(scripts/tmux-real-user-log.sh start <scenario> . ./src/kak <file>)"
# → $SESSION, $OUTDIR are now available
```

See [tmux decision tree](#decision-tree-write-path-headless-vs-tmux) for when to use it.

## Core Mental Models — The Two Trip-Ups

These two areas cause the vast majority of broken Kakoune scripts. Internalize them; they're also the most likely causes when debugging.

### `execute-keys` vs `evaluate-commands`

| | `execute-keys` | `execute-commands` |
| --- | --- | --- |
| Runs | keystrokes, as if pressed | commands, as if typed at prompt |
| Subject to mappings? | **yes** (unless `-with-maps`) | no |
| Registers saved by default | `* " | ^ @ :` (restored after) | — |
| Extra switches | `-with-maps`, `-with-hooks` | `-no-hooks`, `-verbatim` |

- Use `execute-keys` when driving the editor through normal key bindings. It re-runs whatever those keys are mapped to.
- Use `evaluate-commands` when a command should run *directly*, bypassing mappings. **It inserts a `local` scope.** An `option=` inside it sets a local option, not global — wrap in `evaluate-commands -no-hooks { ... }` and set options explicitly if you need global scope.
- `-draft` runs in a copy; changes are discarded after. `-itersel` runs once per selection (critical for multi-cursor workflows). See `references/execeval.md`.

### Command Parsing — Quoting, Balanced Strings, Expansions

- Commands end at `;` or end-of-line; words split on whitespace.
- Single quotes `'...'`: no expansion; close delimiter escaped by doubling (`''`).
- Double quotes `"..."`: `%`-strings processed unless doubled (`%%`); `"` escaped by doubling.
- **Balanced strings** `%X...` where X is `(`, `[`, `{`, `<`: closing matches opening, nestable, no escaping of delimiters even inside other strings. Mismatched `%{` = parse error.
- **Typed expansions**: `%sh`, `%reg`, `%opt`, `%val`, `%arg` expand content; any other type = parse error.
- A stray unbalanced `%{`, an unescaped `%` inside `"`, or a doubled `""` that became literal `"` are usual suspects when something does not parse as expected. See `references/command-parsing.md`.

## Conventions

Follow these (from Kakoune's own `writing_scripts.asciidoc`):
- **Prefix** every option and command with script name (or one-word purpose descriptor). Options use `_`; commands use `-`.
- **`-docstring`** every non-hidden command and option — completion shows its purpose.
- **Minimal dependencies.** A script is an API to external software, not a tool itself.
- **POSIX shell** inside `%sh{}`: `printf` over `echo`, `${var##*/}` over `basename`, `[ ]` over `[[ ]]`, `>/dev/null 2>&1` over `&>`.
- **Background processes** detach cleanly: `{ command } </dev/null >/dev/null 2>&1 &`.
- Follow the style of bundled example scripts (`git.kak`, `clang.kak`, `ctags.kak`, `fifo.kak`, `spell.kak`).

## References

The `references/` directory holds condensed documentation for Kakoune's DSL. Read the matching one before writing code that touches it; do not rely on memory.

| Concern | Resource |
| --- | --- |
| `execute-keys` / `evaluate-commands`, switches, `local` scope | `./references/execeval.md` |
| Quoting, balanced strings, typed expansions | `./references/command-parsing.md` |
| Script conventions, POSIX shell, FIFOs, async, completers | `./references/scripting.md` |
| Hook types, draft contexts, reentrancy, env vars | `./references/hooks.md` |
| Add-highlighter, scopes, regions, passes | `./references/highlighters.md` |
| Declare-option, option scopes, set-option | `./references/options.md` |
| Map / unmap, key names, modes, `-atomic` | `./references/mapping.md` |
| Registers, save/restore | `./references/registers.md` |
| Faces, markup, colors, attributes | `./references/faces.md` |
| Expansions (`%val{}`, typed expansions) | `./references/expansions.md` |
| **Kakoune-specific debugging methodology** | `./references/debugging.md` ← NEW |

## Examples

- Bundled `.kak` examples (from original skill): `git.kak`, `clang.kak`, `ctags.kak`, `fifo.kak`, `spell.kak`, `c-family.kak` — real-world structure for commands, hooks, highlighters, FIFO async tools, and shell bridges.
- Worked "bug" example (from original skill): `examples/headless-bg-agent-empty-stdout.md` — illustrates reproduction contradiction as data and instrumenting data over code paths. Adapt this pattern to Kakoune: instead of checking stdout capture, check Kakoune's `\*debug*\` buffer for `%sh{}` errors.

## Exit criteria

A script is **done** when:
1. `kak-validate.sh` exits 0 with no required-token failures
2. The journal (if debugging) has a root-cause section backed by specific evidence quotes
3. tmux verification was run only if conditions above were met, and its report shows PASS/FAIL tied to log evidence

## Safety notes

- Ask before deleting logs or reverting settings; do not sanitize unless explicitly requested.
- Mention likely side effects before starting: editing a file modifies it on disk; hooks may run external commands.
- Do not expose credentials, IP addresses, DNS addresses, or proprietary information in any output.
