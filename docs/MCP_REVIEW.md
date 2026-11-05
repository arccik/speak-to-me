# MCP security and reliability review

Reviewed on 5 November 2026 against commit `8fd7798`.

Scope: MCP transports, tool routing, permissions, plugin loading, approval UI, and the voice-session execution loop. This began as a source review with local reproductions, not a penetration test of third-party servers. The numbered findings describe the original code at `8fd7798`; the implementation follow-up below records the fixes.

## Confirmed findings, in priority order

### 1. High: disabled built-in tools can still execute

`Sources/SpeakToMe/ToolHub.swift:222` falls back to `Tools.run` whenever an MCP tool cannot be resolved. Built-in switches are checked when producing definitions, but not during execution. `VoiceSession.generate` also does not check whether each returned call belonged to the tools offered for that model request.

Reproduced by disabling `get_time`, then calling `ToolHub.run`: it still returned the time. The same dispatch path handles web requests and opening apps/pages. A stale or hallucinated call can therefore bypass a switch intended to prevent it.

Fix: validate calls against the tools offered for that request, and recheck current global, server, and tool switches immediately before execution. Unknown and disabled calls must fail closed. Keep these checks in the dispatcher as well as the conversation loop.

### 2. High: approval silently hides some of the action

`Sources/SpeakToMe/ToolHub.swift:160` truncates pretty-printed arguments to 1,500 characters. The card has a scroll view, but the omitted text is already gone. The original, full arguments are executed.

Reproduced with a long `body` followed by a `destination`: the destination was absent from the approval card. File paths, recipients, or other consequential parameters can be hidden this way.

Fix: provide the full arguments in an expandable/scrollable view. A summary must clearly indicate omitted content and expose it before approval. Highlight destinations and affected files when the schema supports it.

### 3. Medium: trust and pending approval are not bound to server/tool identity

`Sources/SpeakToMe/ToolHub.swift:134` saves trust using only server ID and tool name. A different command, endpoint, schema, or implementation can inherit the same permission. The conversation loop checks approval, awaits the user's answer, then resolves the name again at execution time (`VoiceSession.swift:1216–1229`). Reloading or restarting during that wait can replace the connection without invalidating the card.

Reproduced by trusting `local__note`, replacing that server's configuration under the same name, and observing that `needsApproval` remained false.

Fix: bind grants to a fingerprint of the server configuration and tool definition. Bind each pending approval to an immutable call, connection generation, and tool fingerprint; reject it if these change. Avoid logging secret values when constructing or explaining fingerprints.

### 4. Medium: qualified tool names can collide and route incorrectly

`Sources/SpeakToMe/ToolHub.swift:235` sanitizes names and truncates the entire qualified name to 64 characters; `resolve` takes the first match.

Reproduced both `a.b` versus `a_b`, and two different tools under a 64-character server prefix: each pair produced identical names. Switching one colliding tool off can make the same model-visible name resolve to a different tool. Depending on timing, approval can describe one operation while execution resolves another.

Fix: maintain an explicit mapping from unique model-visible names to original server/tool identities. Reserve space for a stable hash suffix, check uniqueness, and use that mapping throughout request, approval, and execution.

### 5. Medium: tool-list pagination has no effective page bound

`Sources/SpeakToMe/MCPClient.swift:103` stops based on accumulated tool count. Empty pages with a non-null repeated cursor never reach that bound. One oversized page can also exceed the intended 500-tool limit.

A fake transport returning empty pages and the same cursor was requested 1,001 times before the test transport deliberately stopped it. A real server can leave startup running indefinitely and generate continual requests.

Fix: enforce page and total-tool limits, detect repeated cursors, and check task cancellation between pages. Report a useful server error when a bound is exceeded.

## Additional issues from source inspection

- **Misleading completion feedback.** `VoiceSession.swift:1227` appends “Used …” before execution. `MCP.Connection.callTool` converts `isError` into plain text, so the UI cannot reliably distinguish success from failure. Return a typed outcome and update status after completion.
- **Cancellation does not cancel stdio requests.** `StdioTransport.request` has timeout handling but no cancellation handler or MCP cancellation notification. Interrupting a reply can leave server work running. Where supported, cancel pending requests and notify the server; show “outcome unknown” for side effects whose completion cannot be established. Never promise that stopping speech reverses an action.
- **Stale refresh responses.** `ToolHub.refreshTools` does not verify that its connection is still current after `await listTools()`. A response from an old connection can overwrite a restarted server's tool list. Check the connection generation after the await, and coalesce repeated list-change notifications.
- **Expired HTTP sessions do not recover.** A 404 clears the session ID but leaves the connection marked running and sends future calls without reinitialization. Reconnect and refresh discovery; never automatically replay a write whose outcome is uncertain.
- **Incomplete message limits.** The stdio reader checks size only when no newline exists, rather than checking every completed frame and remaining partial frame. Its incoming streams also have unbounded queues. HTTP error-body reads use `bytes.lines`, which can buffer an arbitrarily long line before the 300-character check. Bound frames, queues, and error bytes before decoding.
- **Plugin change protection is narrower than the README implies.** The fingerprint covers only `plugin.json` and `instructions.md`, and is recomputed only on reload. Editing a plugin executable alone does not revoke approval. Clarify the guarantee or extend package verification; treat external dependencies separately.

## Trust boundary

TLS enforcement, blocked HTTP redirects, a minimal child-process environment, plugins disabled by default, and destructive-call approval are useful existing safeguards.

However, `readOnlyHint` currently grants automatic execution based on the server's own assertion. That is an explicit trust choice, not proof that a tool is harmless. The [MCP tool specification](https://github.com/modelcontextprotocol/modelcontextprotocol/blob/main/docs/specification/2025-11-25/server/tools.mdx) requires clients to treat annotations as untrusted unless their server is trusted. Consider asking on first use of a remote tool until the user explicitly trusts its read-only claims. A read-only tool can still send sensitive arguments to its server.

Local servers execute with the user's permissions when started, before any per-tool approval; tool approvals cannot sandbox their executable. The existing warning to install only trusted servers remains essential.

## Verification

- `swift build -c debug --skip-update`: passed.
- `.build/debug/SpeakToMe --mcptest`: all 48 checks passed, including stdio, HTTP/SSE, permissions, plugin changes, and approval cancellation. Localhost tests required execution outside the filesystem/network sandbox.
- A temporary harness compiled against the actual `MCPClient.swift`, `ToolHub.swift`, and `Tools.swift` reproduced all five numbered findings. It used the app's safe test server and a fake pagination transport; no personal MCP configuration or accounts were used.
- These checks do not establish third-party interoperability, OAuth support, resistance to all malicious servers, or correctness of real account-changing actions.

## Recommended next feature: action history

The user's priority is more reliable actions and clearer tool feedback. Add an expandable action history inside the existing conversation view, backed by typed action records rather than a single free-text note.

Each record should show:

1. The actual tool and server, and a readable description of the requested action.
2. A distinct state: waiting for approval, running, succeeded, failed, denied, cancelled before starting, or outcome unknown.
3. Full inspectable arguments, an elapsed-time indicator, and a compact result or error. Redact credentials and avoid persisting sensitive payloads by default.
4. Clear recovery: reconnect a failed server, inspect an error, or deliberately retry. Write actions should never be retried automatically after an uncertain result.

Example: “Calendar · Create appointment → Waiting for permission → Running → Created” or “Connection lost · The appointment may have been created; check Calendar before retrying.”

Keep routine feedback quiet below the reply, with details available on demand. Use native controls and text states that remain accessible without animation or sound. Build the permission, identity, and typed-result fixes first so the history reports trustworthy outcomes.

Acceptance checks: disabled tools never dispatch; long destinations remain inspectable; restarting invalidates pending approval; names remain unique; repeated cursors fail promptly; failed tools never show success; and interruption distinguishes stopping a reply from stopping an external action.


## Implementation follow-up — 5 November 2026

The five numbered findings have been fixed:

- Dispatch now requires an immutable prepared call from the catalog actually offered to the model. Global, built-in, server and tool switches are checked again at dispatch. Invalid JSON arguments are rejected instead of becoming an empty object.
- Approval retains full arguments and identifies the actual tool name. Prepared calls are tied to the connection generation, tool definition, server configuration and permission revision, so changes invalidate old approvals.
- Explicit trust is saved against a fingerprint of configuration and tool metadata. Old name-only grants are not migrated. Server-declared read-only tools ask by default until the user explicitly trusts the claim; plugin hints cannot bypass this or run writes in drafts.
- Lossy or long tool names get a stable digest suffix. Ambiguous mappings fail closed, and catalog identities prevent a name from silently targeting a replacement tool.
- Discovery checks repeated cursors, page count, tool count, duplicate names, cumulative metadata size and task cancellation.

Additional fixes:

- MCP and built-in tools return typed outcomes. A reported error is not shown as success. Action history exposes waiting, running, succeeded, failed, denied, cancelled, blocked and unknown states, timing and live details.
- Stdio cancellation releases the pending request promptly and sends a best-effort cancellation notification. HTTP requests also send best-effort cancellation. Uncertain writes are labelled unknown, and denied or uncertain writes cannot be repeated by the model in the same reply.
- Refreshes coalesce notifications and verify the connection generation after awaiting discovery. Old exit callbacks cannot clear a replacement connection.
- HTTP session expiry triggers a fresh handshake and discovery without replaying the call. Failed/unknown MCP history entries offer reconnect without retrying an action.
- Stdio input, output and queued writes are bounded. Reading and writing do not block the transport actor on a server waiting for its next request. Completed frames and partial tails are both checked. HTTP SSE is parsed from bounded bytes, with CRLF and multi-line data support; error bodies and notification bodies are bounded too.
- Plugin verification is explicitly documented as manifest/instruction comparison on reload. It is not executable or dependency verification. Local servers remain programs running with the user's permissions.

Action history saves only identity, state and timing; argument/result fields are excluded from encoded records. Credential fields are redacted in the live argument view. Old conversation lines remain compatible, and unfinished action records reopen with an honest status. Final assistant replies still follow the app's existing conversation-saving behavior.

The UI uses the existing conversation and stage disclosure pattern, with a bounded details region and native reconnect controls. Native snapshot fixtures cover waiting, running, succeeded, failed and unknown states at 360- and 480-point content widths. Snapshot rendering skips starting the user's MCP servers and avoids changing stored model settings.


### Final verification

- Signed release bundle built with `bash scripts/build-app.sh` at `build/SpeakToMe.app`; it was not installed over the copy in `/Applications`.
- `build/SpeakToMe.app/Contents/MacOS/SpeakToMe --mcptest`: **86 checks passed**. Coverage includes live tool-definition changes revoking trust, restart invalidation, disabled/global switches, cancelled-before-dispatch requests, lost write responses, session reinitialization without replay, pagination and cumulative metadata limits, frame/SSE bounds, and action-history privacy/backward compatibility.
- `bash scripts/test-speech-text.sh`: passed.
- Release `--snapshot` rendering: completed successfully. Native expanded action-history captures were inspected at 360- and 480-point content widths, including unknown outcomes and completion details. Captures are in `/tmp/speaktome-mcp-release-preview` on this machine.
- `git diff --check`: passed.

Remaining boundaries are intentional and documented: local servers execute with the user's permissions; cancellation is best effort and cannot undo a completed action; plugin executable/dependency contents are not verified; browser OAuth remains outside this implementation. These checks use controlled test servers and do not certify third-party services.
