# Claude CLI compatibility

Verified on macOS arm64, 2026-10-24. Exact npm-native CLI 2.1.220 and 2.1.309
binaries passed the emitted-argv contract. Both points are pinned in PR CI; this
is not a bisected minimum or an implicit change to caller-selected version windows.
Tracks #289.

The new mix claude.contract checks query/resident spawn flags and command builders.
It selects CLAUDE_CONTRACT_BIN explicitly and can require CLAUDE_CONTRACT_VERSION.
Real native calls read version/help or intentionally omit a required hidden-option
operand. Command construction uses a task-local shell fake to capture actual argv,
including legacy direct execution paths; no real authentication or installation
operation is invoked. Query args use the actual public argument builder.

Four legacy query options and max-turns remain hidden but recognized. They must
produce their own missing-operand parse error on every audit, not pass a blanket
waiver. Unknown subcommands cannot pass with root help. Five fake-executable tests
cover missing flags/commands, hidden-option recognition and pre-spawn auth refusal.

Auth.setup_token/2 previously sent a supplied credential to the nonexistent auth
setup-token command. The top-level setup-token generates a credential instead.
The legacy arity now returns Error.kind :unsupported_command before spawning,
without putting the supplied token in diagnostic fields (#295). The regression
failed before the correction and passes now.

All required format, warnings-as-errors compile, strict Credo, unit, Dialyzer and
docs checks passed. Unit suite: Result: 819 passed (27 doctests, 792 tests), 40 excluded.

Help acceptance does not prove every value or runtime semantic. Existing controlled
fixtures cover schema/results, resident permission/interrupt and process evidence.
No new authenticated native smoke or full new-option coverage claim is made.
