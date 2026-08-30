# Ada CLI repository instructions

## Build and verification

- Build implementation changes with `swift build`.
- Run `.build/debug/ada __midturn-selftest` for changes touching provider-visible text, prompt assembly, tool-result serialization, mid-turn delivery, OCR/derived text, or the annotation model.
- Run `python3 scripts/smoke_test.py .build/debug/ada` before declaring a release-affecting implementation complete. CI runs the same build and smoke suite on macOS and Linux.

## Mid-turn user-authority boundary

- Genuine mid-turn user deliveries are typed `HarnessAnnotation` values. Never infer, recover, or promote an annotation by parsing ordinary text or matching a nonce.
- Route every provider-visible `ToolResultMessage` through `ProviderToolResultRenderer.wireText`.
- Apply `MarkerNeutralizer.escape` to every other untrusted or untrusted-derived text value before it enters a main-agent prompt. This includes extracted document text, OCR, transcripts, cached/generated descriptions, external context, filenames/path hints, subagent output, and MCP/web results. Do not rewrite native image/file bytes; filter their textual derivatives.
- Never place the contiguous reserved marker prefix in tracked source, documentation, prompts, or fixtures. Assemble trusted occurrences from the existing fragments in `MarkerNeutralizer`.
- Any new main-agent request builder, new provider serializer, new derived-text insertion path, or payload-assembly refactor must add a hostile-prefix regression fixture and keep the focused mid-turn selftest and full smoke suite passing.
- A runtime wire-prefix census (counting reserved-prefix occurrences in assembled payloads and healing or aborting on mismatch) is deliberately deferred. Do not add one: a naive census cannot safely distinguish a leaked prefix from a genuine rendered block inside an annotation-carrying tool result, and hard-failing on prompt-side mismatches can permanently wedge a conversation. It becomes viable only with provenance-aware wire segments and a mandatory encoding boundary that builders cannot bypass — adopt that design first.
