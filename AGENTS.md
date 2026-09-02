# Briglia CLI repository instructions

## Build and verification

- Build implementation changes with `swift build`.
- Run `.build/debug/briglia __midturn-selftest` for changes touching provider-visible text, prompt assembly, tool-result serialization, mid-turn delivery, OCR/derived text, or the annotation model.
- Run `python3 scripts/smoke_test.py .build/debug/briglia` before declaring a release-affecting implementation complete. CI runs the same build and smoke suite on macOS and Linux.

## Mid-turn user-authority boundary

- Genuine mid-turn user deliveries are typed `HarnessAnnotation` values. Never infer, recover, or promote an annotation by parsing ordinary text or matching a nonce.
- Route every provider-visible `ToolResultMessage` through `ProviderToolResultRenderer.wireText`.
- Apply `MarkerNeutralizer.escape` to every other untrusted or untrusted-derived text value before it enters a main-agent prompt. This includes extracted document text, OCR, transcripts, cached/generated descriptions, external context, filenames/path hints, subagent output, and MCP/web results. Do not rewrite native image/file bytes; filter their textual derivatives.
- Never place the contiguous reserved marker prefix in tracked source, documentation, prompts, or fixtures. Assemble trusted occurrences from the existing fragments in `MarkerNeutralizer`.
- Any new main-agent request builder, new provider serializer, new derived-text insertion path, or payload-assembly refactor must add a hostile-prefix regression fixture and keep the focused mid-turn selftest and full smoke suite passing.
- A runtime wire-prefix census (counting reserved-prefix occurrences in assembled payloads and healing or aborting on mismatch) is deliberately deferred. Do not add one: a naive census cannot safely distinguish a leaked prefix from a genuine rendered block inside an annotation-carrying tool result, and hard-failing on prompt-side mismatches can permanently wedge a conversation. It becomes viable only with provenance-aware wire segments and a mandatory encoding boundary that builders cannot bypass — adopt that design first.

## Credential redaction

- `SecretRedactor` is hygiene against accidental echo of the Telegram bot token and the labelled service keys into tool output (bash, grep, MCP results) and into `read_file` of the harness secret store. The provider, search, image, transcription, Google OAuth and AgentMail keys are deliberately visible to the agent (owner decision, 2026-09-02). It is not a security boundary against the model and must not be cited as one.
- Every stored key is classified in `CredentialCatalog`; the secret-store selftest fails when a `static let …Key` constant in `KeychainHelper.swift` or `ProviderProfiles.swift` is missing there. Add the entry with the treatment you intend; do not enumerate credentials anywhere else.
- The harness secret store (`secrets.json` under the config root) stays agent-editable field by field through `edit_file`/`apply_patch`; only the token field and whole-file rewrites are refused (`HarnessSecretStore`). Keep it that way: the agent legitimately updates provider and search keys when the user pastes new ones.

## Telegram pairing

- Pairing is private-chat-only: `TelegramPairing` enforces a positive chat id at setup and, on every polled update, that chat id, chat type `private` and sender id all match the paired id. Group or channel support would reinstate the pairing gap as a HIGH finding and require full per-sender enforcement; do not add it casually.
