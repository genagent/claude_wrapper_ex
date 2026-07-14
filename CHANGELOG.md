# Changelog

## [0.14.0](https://github.com/genagent/claude_wrapper_ex/compare/v0.13.2...v0.14.0) (2026-07-14)


### ⚠ BREAKING CHANGES

* removed Commands.Mcp.login/3 and logout/2; Commands.Mcp list/get/add_from_desktop lost their scope/name arguments (arity changes); Commands.Agents now returns active sessions (not %{name, model}); renamed Bundled.pinned_version/0 to minimum_version/0.

### Features

* expose missing CLI flags, retry rate limits, codepoint-safe truncation ([#247](https://github.com/genagent/claude_wrapper_ex/issues/247)) ([ad20e3d](https://github.com/genagent/claude_wrapper_ex/commit/ad20e3d1cddc083dd158d822c714d9fff2d888f8))
* instrument DuplexSession with telemetry ([#215](https://github.com/genagent/claude_wrapper_ex/issues/215)) ([#245](https://github.com/genagent/claude_wrapper_ex/issues/245)) ([c554d37](https://github.com/genagent/claude_wrapper_ex/commit/c554d372c7637de74c600ea6d2ebb03b6cbdb2e3))


### Bug Fixes

* honor config.timeout across surfaces; observable stream truncation; reap duplex owner; harden :defer ([#242](https://github.com/genagent/claude_wrapper_ex/issues/242)) ([c0adcd9](https://github.com/genagent/claude_wrapper_ex/commit/c0adcd952889ed76e25ce59ee5a2e0758ec95d23))
* prune/repair CLI-contract drift (mcp, agents, bundled install, auth classifier) ([#244](https://github.com/genagent/claude_wrapper_ex/issues/244)) ([8bf2458](https://github.com/genagent/claude_wrapper_ex/commit/8bf2458c52b24dad850897158573e201dd77f802))

## [0.13.2](https://github.com/genagent/claude_wrapper_ex/compare/v0.13.1...v0.13.2) (2026-07-14)


### Bug Fixes

* support variadic --betas and give actionable enum-option errors ([#240](https://github.com/genagent/claude_wrapper_ex/issues/240)) ([f8e6811](https://github.com/genagent/claude_wrapper_ex/commit/f8e68118d9b150220a87c12efaaabcb1f3fd16c9))

## [0.13.1](https://github.com/genagent/claude_wrapper_ex/compare/v0.13.0...v0.13.1) (2026-07-14)


### Bug Fixes

* **ci:** gate Hex publish behind the quality suite; add hex.audit ([#238](https://github.com/genagent/claude_wrapper_ex/issues/238)) ([3815f43](https://github.com/genagent/claude_wrapper_ex/commit/3815f43356f30c7f421e0f72ebc8c430da053bc2)), closes [#203](https://github.com/genagent/claude_wrapper_ex/issues/203)
* harden the one-shot query path (dash-prefixed prompts, missing binary) ([#234](https://github.com/genagent/claude_wrapper_ex/issues/234)) ([01ccff4](https://github.com/genagent/claude_wrapper_ex/commit/01ccff4fbc2da8378e49b545938c49c67ac3ca7b))
* harden the streaming path (argv quoting, &gt;1MB lines, end-of-stream stall) ([#236](https://github.com/genagent/claude_wrapper_ex/issues/236)) ([8dd0add](https://github.com/genagent/claude_wrapper_ex/commit/8dd0add1e5db8f7f658a8cbd3472c31ba859e383))
* preserve http MCP servers on round-trip; fix `mcp add` argv order ([#237](https://github.com/genagent/claude_wrapper_ex/issues/237)) ([de7e862](https://github.com/genagent/claude_wrapper_ex/commit/de7e86289bf5cb0f77c40d921a4a6e176a6240b8))

## [0.13.0](https://github.com/genagent/claude_wrapper_ex/compare/v0.12.0...v0.13.0) (2026-07-09)


### Features

* add hermetic preset to seal ambient claude config ([#194](https://github.com/genagent/claude_wrapper_ex/issues/194)) ([7d93fb3](https://github.com/genagent/claude_wrapper_ex/commit/7d93fb3cfa0bcf50c4ec88ccf088d4cdae03727a))

## [0.12.0](https://github.com/genagent/claude_wrapper_ex/compare/v0.11.0...v0.12.0) (2026-07-07)


### Features

* **duplex:** accept a %Query{} for typed spawn-time knobs ([#189](https://github.com/genagent/claude_wrapper_ex/issues/189)) ([e66a73a](https://github.com/genagent/claude_wrapper_ex/commit/e66a73afcc400fb221549fc0ed8c84e860c82d29))
* **error:** detect --max-budget-usd cap and enrich rail-stop errors with cost/turn figures ([#188](https://github.com/genagent/claude_wrapper_ex/issues/188)) ([def7772](https://github.com/genagent/claude_wrapper_ex/commit/def77723b35b6a3357e430359f8358442b647668))
* optional leak-free claude subprocess control via forcola ([#192](https://github.com/genagent/claude_wrapper_ex/issues/192)) ([49afb76](https://github.com/genagent/claude_wrapper_ex/commit/49afb76d6fa9ae3103fa1537f56e7ca17a5c8e9d))

## [0.11.0](https://github.com/genagent/claude_wrapper_ex/compare/v0.10.0...v0.11.0) (2026-07-01)


### Features

* **bundled:** opt-in bundled-binary install (cli_path: :bundled) ([#153](https://github.com/genagent/claude_wrapper_ex/issues/153)) ([403134f](https://github.com/genagent/claude_wrapper_ex/commit/403134fc65c9fce02815a67a962788f1b8c5b951))
* **mcp:** wrap mcp login and mcp logout ([#163](https://github.com/genagent/claude_wrapper_ex/issues/163)) ([02d5284](https://github.com/genagent/claude_wrapper_ex/commit/02d52849692886e60ada6f4c9aa77623fe9ddbf9)), closes [#158](https://github.com/genagent/claude_wrapper_ex/issues/158)
* **query:** add --name, --plugin-url, --safe-mode flags ([#162](https://github.com/genagent/claude_wrapper_ex/issues/162)) ([62c7b83](https://github.com/genagent/claude_wrapper_ex/commit/62c7b83c06dacd3358404a6b8398bdbc4c5e7ff0)), closes [#157](https://github.com/genagent/claude_wrapper_ex/issues/157)
* wrap the ultrareview command ([#164](https://github.com/genagent/claude_wrapper_ex/issues/164)) ([02f2be9](https://github.com/genagent/claude_wrapper_ex/commit/02f2be9ea69dce85efca72fc19d2ae7a27096279)), closes [#159](https://github.com/genagent/claude_wrapper_ex/issues/159)


### Bug Fixes

* emit --debug instead of invalid --debug-filter flag ([#160](https://github.com/genagent/claude_wrapper_ex/issues/160)) ([a836ecd](https://github.com/genagent/claude_wrapper_ex/commit/a836ecde03a5dd1bb665b7c5b95028191b7b87c7)), closes [#156](https://github.com/genagent/claude_wrapper_ex/issues/156)

## [0.10.0](https://github.com/genagent/claude_wrapper_ex/compare/v0.9.0...v0.10.0) (2026-06-23)


### Features

* **history:** last_answer/1 and assistant_texts/1 over SessionLog ([#149](https://github.com/genagent/claude_wrapper_ex/issues/149)) ([2983449](https://github.com/genagent/claude_wrapper_ex/commit/2983449f5fae921a0179c2db4cbee4feb50580a9))
* **stream:** ClaudeWrapper.Stream combinators over DuplexSession ([#151](https://github.com/genagent/claude_wrapper_ex/issues/151)) ([abc946a](https://github.com/genagent/claude_wrapper_ex/commit/abc946aaf5f85865dab367e9ee67e8016314259d))
* **test:** adapter seam on DuplexSession + ClaudeWrapper.Test (network-free session tests) ([#152](https://github.com/genagent/claude_wrapper_ex/issues/152)) ([ab39b5f](https://github.com/genagent/claude_wrapper_ex/commit/ab39b5f98e761346fab5cf00d55ff99b94e57f1e))

## [0.9.0](https://github.com/genagent/claude_wrapper_ex/compare/v0.8.1...v0.9.0) (2026-06-23)


### Features

* high-level conversational API (Prompt + Session ergonomics + IEx skin) ([#134](https://github.com/genagent/claude_wrapper_ex/issues/134)) ([f2a45ce](https://github.com/genagent/claude_wrapper_ex/commit/f2a45ceb94f24fd278d25262ca5dbf7c1c42c8a2))
* Prompt git_log/git_status/vars composition; unify git block headers ([#141](https://github.com/genagent/claude_wrapper_ex/issues/141)) ([f7376df](https://github.com/genagent/claude_wrapper_ex/commit/f7376df177f61d31942be82c97d253062b0363d6))
* typed Result accessors -- usage/1, stop_reason/1, structured_output/1 ([#142](https://github.com/genagent/claude_wrapper_ex/issues/142)) ([ad6e0ca](https://github.com/genagent/claude_wrapper_ex/commit/ad6e0ca1a0686d346706ca56e5355fe309a1be11))


### Bug Fixes

* exclude cache-read tokens from session total_tokens; document cost gap ([#137](https://github.com/genagent/claude_wrapper_ex/issues/137)) ([437202f](https://github.com/genagent/claude_wrapper_ex/commit/437202f07baf128f75d29ac9169d86d1325decec))

## [0.8.1](https://github.com/genagent/claude_wrapper_ex/compare/v0.8.0...v0.8.1) (2026-06-15)


### Bug Fixes

* match CLI slug encoding for all non-alphanumeric path chars ([#135](https://github.com/genagent/claude_wrapper_ex/issues/135)) ([048cfd0](https://github.com/genagent/claude_wrapper_ex/commit/048cfd0e48831d73ae04cf47701f8f2c2da8511b))

## [0.8.0](https://github.com/genagent/claude_wrapper_ex/compare/v0.7.1...v0.8.0) (2026-06-15)


### ⚠ BREAKING CHANGES

* every {:error, reason} now carries a %ClaudeWrapper.Error{} struct instead of an ad-hoc atom/tuple. Match on %ClaudeWrapper.Error{kind: ...}.
* the Query :worktree field type widens from boolean() to boolean() | String.t(). Runtime behavior for existing worktree/1 callers is unchanged.

### Features

* add Auth login options (email, mode, force_sso) ([#126](https://github.com/genagent/claude_wrapper_ex/issues/126)) ([cb2b72e](https://github.com/genagent/claude_wrapper_ex/commit/cb2b72e227825b7aa6b393c62fd674473c2fbb4f)), closes [#101](https://github.com/genagent/claude_wrapper_ex/issues/101)
* add auto-mode, install, update, and project purge command wrappers ([#127](https://github.com/genagent/claude_wrapper_ex/issues/127)) ([0e84cb3](https://github.com/genagent/claude_wrapper_ex/commit/0e84cb3e091259404a6f247e30d71a365d5dbfb2)), closes [#102](https://github.com/genagent/claude_wrapper_ex/issues/102)
* add ClaudeWrapper.Agents for file-backed agent definitions ([#114](https://github.com/genagent/claude_wrapper_ex/issues/114)) ([7497fbc](https://github.com/genagent/claude_wrapper_ex/commit/7497fbcc764287ee9d91a9d3db87068b4f7ba5ae)), closes [#91](https://github.com/genagent/claude_wrapper_ex/issues/91)
* add ClaudeWrapper.Auth for env detection and failure classification ([#118](https://github.com/genagent/claude_wrapper_ex/issues/118)) ([6eebe2c](https://github.com/genagent/claude_wrapper_ex/commit/6eebe2cb6902b73dfd96ff6edc5575ab0ec95e8c)), closes [#93](https://github.com/genagent/claude_wrapper_ex/issues/93)
* add ClaudeWrapper.Budget client-side budget tracker ([#120](https://github.com/genagent/claude_wrapper_ex/issues/120)) ([47f2898](https://github.com/genagent/claude_wrapper_ex/commit/47f2898bdae5f032f8d20971eee7300a3adb5f68)), closes [#95](https://github.com/genagent/claude_wrapper_ex/issues/95)
* add ClaudeWrapper.CliVersion for parsing and checking the CLI version ([#119](https://github.com/genagent/claude_wrapper_ex/issues/119)) ([f9fc5a6](https://github.com/genagent/claude_wrapper_ex/commit/f9fc5a68f882d6d71b8bfb24f23224d524650653)), closes [#94](https://github.com/genagent/claude_wrapper_ex/issues/94)
* add ClaudeWrapper.DangerousClient env-gated bypass wrapper ([#122](https://github.com/genagent/claude_wrapper_ex/issues/122)) ([1a2f3e0](https://github.com/genagent/claude_wrapper_ex/commit/1a2f3e06c48c6de96b3be5632a6fe9ee46ac8c2f)), closes [#97](https://github.com/genagent/claude_wrapper_ex/issues/97)
* add ClaudeWrapper.History for reading on-disk session transcripts ([#112](https://github.com/genagent/claude_wrapper_ex/issues/112)) ([eedbe1d](https://github.com/genagent/claude_wrapper_ex/commit/eedbe1df0b60fdeedd6eb44571e4a6404cf9fc78)), closes [#87](https://github.com/genagent/claude_wrapper_ex/issues/87)
* add ClaudeWrapper.Jobs for reading background job state ([#117](https://github.com/genagent/claude_wrapper_ex/issues/117)) ([80a11d1](https://github.com/genagent/claude_wrapper_ex/commit/80a11d12bcdf578911ea3e27574cb610cb3dc741)), closes [#88](https://github.com/genagent/claude_wrapper_ex/issues/88)
* add ClaudeWrapper.Settings for reading on-disk settings layers ([#113](https://github.com/genagent/claude_wrapper_ex/issues/113)) ([ca89fa4](https://github.com/genagent/claude_wrapper_ex/commit/ca89fa4bb50e5eb504c738d22ca7a4df3753c2fd)), closes [#86](https://github.com/genagent/claude_wrapper_ex/issues/86)
* add ClaudeWrapper.Skills for reading ~/.claude/skills ([#116](https://github.com/genagent/claude_wrapper_ex/issues/116)) ([5f4ed1f](https://github.com/genagent/claude_wrapper_ex/commit/5f4ed1fd80dd42327a8b82279a12490abdf0e865)), closes [#89](https://github.com/genagent/claude_wrapper_ex/issues/89)
* add ClaudeWrapper.ToolPattern typed tool-spec builder ([#121](https://github.com/genagent/claude_wrapper_ex/issues/121)) ([b3e5aeb](https://github.com/genagent/claude_wrapper_ex/commit/b3e5aebca1241ee9b8527f90d5c4fa97a9f85e66)), closes [#96](https://github.com/genagent/claude_wrapper_ex/issues/96)
* add ClaudeWrapper.Worktrees for git worktree introspection ([#115](https://github.com/genagent/claude_wrapper_ex/issues/115)) ([fa8e449](https://github.com/genagent/claude_wrapper_ex/commit/fa8e449d0669602baf936ff1f45ae017d32a3b6b)), closes [#90](https://github.com/genagent/claude_wrapper_ex/issues/90)
* add DuplexSession health helpers and Conversation bookkeeping ([#128](https://github.com/genagent/claude_wrapper_ex/issues/128)) ([fc12af8](https://github.com/genagent/claude_wrapper_ex/commit/fc12af8bb5e5bc4ce780290f017589d7f8ab78a9)), closes [#103](https://github.com/genagent/claude_wrapper_ex/issues/103)
* add Mcp command parity (add-from-desktop, serve, richer add/add-json) ([#125](https://github.com/genagent/claude_wrapper_ex/issues/125)) ([eae71ea](https://github.com/genagent/claude_wrapper_ex/commit/eae71ea4d3bfe2f57ea39a2bcf7d9a0e01aac089)), closes [#100](https://github.com/genagent/claude_wrapper_ex/issues/100)
* add missing per-call query flags and :xhigh effort tier ([#109](https://github.com/genagent/claude_wrapper_ex/issues/109)) ([f4c8f60](https://github.com/genagent/claude_wrapper_ex/commit/f4c8f60ed72515bfcb7e00446e8ae715835ba7ee)), closes [#83](https://github.com/genagent/claude_wrapper_ex/issues/83)
* add Plugin command parity (tag, details, prune; uninstall --prune/--yes) ([#124](https://github.com/genagent/claude_wrapper_ex/issues/124)) ([9d82f73](https://github.com/genagent/claude_wrapper_ex/commit/9d82f733540ab1b7aa1de49a3a523176021837f3)), closes [#99](https://github.com/genagent/claude_wrapper_ex/issues/99)
* add Query.from_pr/2 to resume a PR-linked session ([#110](https://github.com/genagent/claude_wrapper_ex/issues/110)) ([873e28b](https://github.com/genagent/claude_wrapper_ex/commit/873e28bd01946a8b5be091162fd3e2f743b365fb)), closes [#85](https://github.com/genagent/claude_wrapper_ex/issues/85)
* add typed partial-message accessor to StreamEvent ([#123](https://github.com/genagent/claude_wrapper_ex/issues/123)) ([04936c5](https://github.com/genagent/claude_wrapper_ex/commit/04936c58c5bbd69108fc26dcc13d47e31ffbfc62)), closes [#98](https://github.com/genagent/claude_wrapper_ex/issues/98)
* introduce canonical ClaudeWrapper.Error exception ([#129](https://github.com/genagent/claude_wrapper_ex/issues/129)) ([cf67532](https://github.com/genagent/claude_wrapper_ex/commit/cf6753273cec1c93ae3af05f034068b810a253fa)), closes [#92](https://github.com/genagent/claude_wrapper_ex/issues/92)
* support named git worktrees in Query ([#111](https://github.com/genagent/claude_wrapper_ex/issues/111)) ([ed1875d](https://github.com/genagent/claude_wrapper_ex/commit/ed1875d811aa40e1fa520d28f8e30108170cae6e)), closes [#84](https://github.com/genagent/claude_wrapper_ex/issues/84)


### Bug Fixes

* correct mcp/auth command output handling; add live integration coverage ([#130](https://github.com/genagent/claude_wrapper_ex/issues/130)) ([ffc10bc](https://github.com/genagent/claude_wrapper_ex/commit/ffc10bc8a0e07a82f33039dd9048c6a1e5d87c77))
* emit correct CLI flag names in Query.build_args ([#106](https://github.com/genagent/claude_wrapper_ex/issues/106)) ([4aecda8](https://github.com/genagent/claude_wrapper_ex/commit/4aecda8b662247da08c11ba8448d0258aa4c7fd6))

## [0.7.1](https://github.com/genagent/claude_wrapper_ex/compare/v0.7.0...v0.7.1) (2026-05-13)


### Bug Fixes

* DuplexSession :allow defaults updatedInput to original input ([#76](https://github.com/genagent/claude_wrapper_ex/issues/76)) ([c91c780](https://github.com/genagent/claude_wrapper_ex/commit/c91c7807585dc6ace49b01540aea078835364e81))

## [0.7.0](https://github.com/genagent/claude_wrapper_ex/compare/v0.6.1...v0.7.0) (2026-05-06)


### Features

* DuplexSession on_permission supports 3-arity callback (request_id) ([#69](https://github.com/genagent/claude_wrapper_ex/issues/69)) ([e7a3076](https://github.com/genagent/claude_wrapper_ex/commit/e7a30765dd69693959eefcfacce55bc04479a199))

## [0.6.1](https://github.com/genagent/claude_wrapper_ex/compare/v0.6.0...v0.6.1) (2026-05-06)


### Bug Fixes

* handle integer cost_usd in IEx printers (Float.round coercion) ([#65](https://github.com/genagent/claude_wrapper_ex/issues/65)) ([10a8019](https://github.com/genagent/claude_wrapper_ex/commit/10a8019ae088339cecf7ecff0c761dd18b1a909e))

## [0.6.0](https://github.com/genagent/claude_wrapper_ex/compare/v0.5.1...v0.6.0) (2026-05-06)


### ⚠ BREAKING CHANGES

* remove Workshop and MCP code (migrated to agent_workshop) ([#63](https://github.com/genagent/claude_wrapper_ex/issues/63))

### Features

* add :telemetry events for exec/stream/session lifecycle ([#50](https://github.com/genagent/claude_wrapper_ex/issues/50)) ([191020a](https://github.com/genagent/claude_wrapper_ex/commit/191020a20a5787dcacc774fc17cd4667496573f0)), closes [#49](https://github.com/genagent/claude_wrapper_ex/issues/49)
* add ClaudeWrapper.DuplexIEx for interactive sessions ([#60](https://github.com/genagent/claude_wrapper_ex/issues/60)) ([7c7fb7f](https://github.com/genagent/claude_wrapper_ex/commit/7c7fb7fea840eb34075a77e9b17553a722bfa10c)), closes [#55](https://github.com/genagent/claude_wrapper_ex/issues/55)
* add ClaudeWrapper.DuplexSession (PR 1: minimal happy path) ([#56](https://github.com/genagent/claude_wrapper_ex/issues/56)) ([c1a8c82](https://github.com/genagent/claude_wrapper_ex/commit/c1a8c82f85573dd76a0f366898db057688e7bd31)), closes [#55](https://github.com/genagent/claude_wrapper_ex/issues/55)
* add interrupt and close to DuplexSession (PR 4) ([#59](https://github.com/genagent/claude_wrapper_ex/issues/59)) ([2a00aef](https://github.com/genagent/claude_wrapper_ex/commit/2a00aef044c04aed71b240d88286205cf7bdd966)), closes [#55](https://github.com/genagent/claude_wrapper_ex/issues/55)
* add permission callback to DuplexSession (PR 3) ([#58](https://github.com/genagent/claude_wrapper_ex/issues/58)) ([8dc0252](https://github.com/genagent/claude_wrapper_ex/commit/8dc02524ae04cde4fa989157f0a994623bc58263)), closes [#55](https://github.com/genagent/claude_wrapper_ex/issues/55)
* add subscribers to DuplexSession (PR 2) ([#57](https://github.com/genagent/claude_wrapper_ex/issues/57)) ([2d02e11](https://github.com/genagent/claude_wrapper_ex/commit/2d02e11198fb55cbc56ca137e1ba506df6c6ef11)), closes [#55](https://github.com/genagent/claude_wrapper_ex/issues/55)
* extract Query.apply_opts/2 and reach all Query setters via opts ([#62](https://github.com/genagent/claude_wrapper_ex/issues/62)) ([0bf337b](https://github.com/genagent/claude_wrapper_ex/commit/0bf337b627843661ede0a5e32b5da6d69fab6886))


### Miscellaneous Chores

* remove Workshop and MCP code (migrated to agent_workshop) ([#63](https://github.com/genagent/claude_wrapper_ex/issues/63)) ([e2f7630](https://github.com/genagent/claude_wrapper_ex/commit/e2f76308ef4bcff6e11df686419922bb8a916914)), closes [#55](https://github.com/genagent/claude_wrapper_ex/issues/55)

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
