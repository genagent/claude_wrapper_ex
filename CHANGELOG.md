# Changelog

## [0.5.1](https://github.com/genagent/claude_wrapper_ex/compare/v0.5.0...v0.5.1) (2026-04-11)


### Bug Fixes

* update source URL to genagent org ([#45](https://github.com/genagent/claude_wrapper_ex/issues/45)) ([91b13d4](https://github.com/genagent/claude_wrapper_ex/commit/91b13d4ecf62445d90087aef50e83ba9ceef3365))

## [0.5.0](https://github.com/joshrotenberg/claude_wrapper_ex/compare/v0.4.0...v0.5.0) (2026-04-10)


### Features

* add worktree support to Session.build_query ([#39](https://github.com/joshrotenberg/claude_wrapper_ex/issues/39)) ([0a1b078](https://github.com/joshrotenberg/claude_wrapper_ex/commit/0a1b078a44186c9443951081197fcb7c212722e7))


### Bug Fixes

* add mcp_config support to Session.build_query ([#37](https://github.com/joshrotenberg/claude_wrapper_ex/issues/37)) ([d12c82d](https://github.com/joshrotenberg/claude_wrapper_ex/commit/d12c82d5904cab36890dc56c7762080fd909d288))
* close stdin on Query.stream/2 Port path ([#43](https://github.com/joshrotenberg/claude_wrapper_ex/issues/43)) ([4b31435](https://github.com/joshrotenberg/claude_wrapper_ex/commit/4b3143584433ffe77f793e53cb055b3f2b3e0ba9)), closes [#42](https://github.com/joshrotenberg/claude_wrapper_ex/issues/42)

## [0.4.0](https://github.com/joshrotenberg/claude_wrapper_ex/compare/v0.3.0...v0.4.0) (2026-04-02)


### Features

* add streaming mode to Workshop (stream/2) ([#27](https://github.com/joshrotenberg/claude_wrapper_ex/issues/27)) ([24fd0e3](https://github.com/joshrotenberg/claude_wrapper_ex/commit/24fd0e39197daceb0e186935b8ce910a8a845e98)), closes [#19](https://github.com/joshrotenberg/claude_wrapper_ex/issues/19)
* add Workshop multi-agent IEx API ([#21](https://github.com/joshrotenberg/claude_wrapper_ex/issues/21)) ([5587520](https://github.com/joshrotenberg/claude_wrapper_ex/commit/5587520eb1e6a3025b3607cea3d7401522ac5c54))
* add Workshop.load/1 for setup files ([#28](https://github.com/joshrotenberg/claude_wrapper_ex/issues/28)) ([75f4753](https://github.com/joshrotenberg/claude_wrapper_ex/commit/75f4753d5c343cdc13afbc2fc4966f5ca45f397c))
* cast queuing for busy agents ([#26](https://github.com/joshrotenberg/claude_wrapper_ex/issues/26)) ([662872b](https://github.com/joshrotenberg/claude_wrapper_ex/commit/662872b1694debd1330766b10faa4b32225694eb)), closes [#20](https://github.com/joshrotenberg/claude_wrapper_ex/issues/20)
* MCP server exposing Workshop as tools ([#29](https://github.com/joshrotenberg/claude_wrapper_ex/issues/29)) ([3021cc4](https://github.com/joshrotenberg/claude_wrapper_ex/commit/3021cc49debe2d701b597edaebc5bf1f2824e248))
* Workshop permission mode defaults and validation ([#25](https://github.com/joshrotenberg/claude_wrapper_ex/issues/25)) ([454c84d](https://github.com/joshrotenberg/claude_wrapper_ex/commit/454c84d90208df9039da35bbd2e9115f44cc77e0))


### Bug Fixes

* pass request_timeout to MCP Plug to prevent session drops ([#31](https://github.com/joshrotenberg/claude_wrapper_ex/issues/31)) ([29ca19c](https://github.com/joshrotenberg/claude_wrapper_ex/commit/29ca19c14381eae6eb50266137503df5af8b709f)), closes [#30](https://github.com/joshrotenberg/claude_wrapper_ex/issues/30)

## [0.3.0](https://github.com/joshrotenberg/claude_wrapper_ex/compare/v0.2.1...v0.3.0) (2026-03-31)


### Features

* add agents command (list configured agents) ([#18](https://github.com/joshrotenberg/claude_wrapper_ex/issues/18)) ([0529109](https://github.com/joshrotenberg/claude_wrapper_ex/commit/05291094907098709d0fd79511e557919fafcc6e)), closes [#8](https://github.com/joshrotenberg/claude_wrapper_ex/issues/8)


### Bug Fixes

* strip --verbose from execute args to preserve JSON parsing ([#16](https://github.com/joshrotenberg/claude_wrapper_ex/issues/16)) ([5d8d51f](https://github.com/joshrotenberg/claude_wrapper_ex/commit/5d8d51f5af574696b6ea668976350e80b4f7d995))

## [0.2.1](https://github.com/joshrotenberg/claude_wrapper_ex/compare/v0.2.0...v0.2.1) (2026-03-31)


### Bug Fixes

* move hex publish into release workflow ([#13](https://github.com/joshrotenberg/claude_wrapper_ex/issues/13)) ([39f0446](https://github.com/joshrotenberg/claude_wrapper_ex/commit/39f0446724c9109a1baca2826afb5395d86056b8))
* resolve doc warnings for Config.new/1 references ([#15](https://github.com/joshrotenberg/claude_wrapper_ex/issues/15)) ([dcc6869](https://github.com/joshrotenberg/claude_wrapper_ex/commit/dcc6869db17102ab8165e1737657008528f1958b))

## [0.2.0](https://github.com/joshrotenberg/claude_wrapper_ex/compare/v0.1.0...v0.2.0) (2026-03-31)


### Features

* add IEx REPL helpers for conversational use ([#9](https://github.com/joshrotenberg/claude_wrapper_ex/issues/9)) ([3d31355](https://github.com/joshrotenberg/claude_wrapper_ex/commit/3d3135566f9608b1690f2745b943d98dab86a592))
* add plugin commands, marketplace commands, and SessionServer ([#7](https://github.com/joshrotenberg/claude_wrapper_ex/issues/7)) ([9fcaafb](https://github.com/joshrotenberg/claude_wrapper_ex/commit/9fcaafb2cc9692bf164639929fe4c0c6648b7660))
* extend wrapper with session, retry, mcp config, CI, and hex publish ([#1](https://github.com/joshrotenberg/claude_wrapper_ex/issues/1)) ([f05f65d](https://github.com/joshrotenberg/claude_wrapper_ex/commit/f05f65dc3ae35668df0434e7ff949b365e71c062))
* initial scaffold for Claude CLI wrapper ([c7e9047](https://github.com/joshrotenberg/claude_wrapper_ex/commit/c7e9047dbd59d4ada477bae950e30cf383af702e))


### Bug Fixes

* reset version to 0.1.0 and configure release-please manifest ([#11](https://github.com/joshrotenberg/claude_wrapper_ex/issues/11)) ([6a8f5a7](https://github.com/joshrotenberg/claude_wrapper_ex/commit/6a8f5a72a65234f5a2dc0a1a14989e5bf26db56a))

## Changelog
