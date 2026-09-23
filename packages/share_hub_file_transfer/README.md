# share_hub_file_transfer

Pure Dart public file protocol v2 primitives over session protocol v2. This package provides immutable typed messages, strict JSON encoding, authenticated transfer context checks, bounded lifecycle bookkeeping and stop-and-wait arithmetic. It does not send data, read files, create temporary files, verify file contents, or authorize publication.

## Wire format

Every JSON object has integer `v: 2`, string `type`, and `transferId`. Version 1 is rejected without fallback. Random transfer IDs and resume attempt IDs are exactly 32 lowercase hexadecimal characters representing 128 bits; `newTransferId()` uses the secure random generator. Unknown, duplicate and missing fields are rejected. Sizes and offsets are canonical decimal strings in `0..9223372036854775807`. Metadata also carries `transferOrdinal`, a canonical decimal string in `1..9223372036854775807`, scoped to the original sealed grant endpoint and authenticated file sender. It must never wrap or reset on physical reconnection. SHA-256 values are 64 lowercase hexadecimal characters.

| Type | Additional required fields | Authenticated role |
| --- | --- | --- |
| offer | transferOrdinal, name, size, sha256, chunkBytes | file sender, request |
| accept | acceptedChunkBytes, window, offset | receiver |
| chunk | offset, data | sender |
| ack | nextOffset | receiver |
| finish | size, sha256 | sender |
| complete | actualName, size, sha256 | receiver |
| pause | none | either |
| paused | offset | either |
| resume | transferOrdinal, name, size, sha256, chunkBytes, attemptId | original sender, new request |
| resume-state | attemptId, offset, prefixSha256 | receiver |
| resume-accept | attemptId, offset, prefixSha256 | sender |
| cancel / cancelled | none | either |
| terminate | transferOrdinal, transferSender, name, size, sha256, chunkBytes | either, new request |
| failed | code | either |
| rejected | code | receiver of a request; not a terminal file result |
| retire | transferOrdinal, transferSender, name, size, sha256, chunkBytes, outcome | original file sender, new control request |
| retired | transferOrdinal | receiver of retire; not a delivery receipt |

`retire.outcome` is exactly `completed`, `cancelled` or `failed`. Completed requires `actualName`; failed requires `failureCode`; cancelled has neither. Extra or contradictory outcome fields are rejected. Only stable wire error codes are accepted.

`chunkBytes` and `acceptedChunkBytes` are integers 1..32768. Window is the integer 1. Accept starts at decimal offset `"0"`. Chunk data uses canonical **unpadded base64url**, is nonempty and at most 32768 decoded bytes. Offset plus length cannot overflow. Empty files send finish without a chunk. Resume-accept echoes both the verified offset and prefix digest.

Names are preserved exactly, limited to 255 UTF-8 bytes. Empty names, dot/parent components, separators, absolute paths, NUL/control characters, Windows ADS/illegal characters, trailing space/dot, reserved device names and unpaired surrogates are rejected. Reserved device checks are case-insensitive and include the [Windows console devices `CONIN$` and `CONOUT$`](https://learn.microsoft.com/en-us/windows/win32/api/fileapi/nf-fileapi-createfilew#consoles). No path rewriting or normalization occurs.

Engineering framing limits are 4096 UTF-8 bytes per control message and 49152 per chunk JSON message, including whitespace. These are codec limits, not product file-size or throughput promises. Maximum blocks are tested through actual session encryption and decryption, including both grant directions. Outer transport integration remains the host's responsibility.

## Authorization and state

Use `FileTransferContext.fromRequest(registry, authorization)` for an offer. The authority must be minted by the session API and registered locally; no JSON grant, arbitrary sender role or external deadline can grant access. `decodeSignal(VerifiedSessionSignal)` binds the exact authorization object, session, file ID, operation, current generation and original deadline, then validates the authenticated sender/receiver role. `validateOutgoing(message)` checks local signals. File roles follow the original file request, independently of the grant initiator. Other operations retain their existing direction rules.

Use `originalContext.resumeWith(newAuthorization)` for resume requests. It requires the same sealed local grant endpoint, original grant binding object and deadline, same authenticated direction and immutable metadata, a current generation and a different session ID. Replacing the endpoint is rejected even when the new endpoint reuses the binding object and deadline. `SessionAuthorization.hasSameGrantAs` compares this endpoint lineage without granting or refreshing authority; the fresh authorization must still pass registry and current-state checks. Retain original contexts only for eligible in-process transfers. The host must track all previously used session IDs and attempts, terminal records, slot/epoch, suspension/cancellation, and source/temporary-file checkpoint proofs. A new grant must never reconstruct an old transfer.

Every I/O side effect must recheck authorization, then `requireCurrent()` immediately after awaits, and check the host slot/epoch. Native operations need their own synchronous stop barrier. `FileProgress` enforces contiguous nonoverlapping blocks, one unacknowledged block, exact acknowledgements and finish-before-complete. It is a deterministic arithmetic helper, not a transfer orchestrator. Calling complete is only legitimate after independently verified atomic storage commit; a valid complete message alone is not proof of disk integrity.

`terminate` is a terminal control request for cancellations whose original operation can no longer deliver signals after transport loss. `transferSender` is exactly `initiator` or `receiver`, identifying the original file direction, independently of who requests cancellation. The host must match the original sealed grant endpoint, direction, transfer ID and immutable metadata, retain a bounded process-local terminal fact before asynchronous cleanup, and reject subsequent offers or resumes for that file. It must verify the fresh request against the original deadline. This request cannot create a `FileTransferContext`, open a file or allocate an I/O scope.

A host replies with `cancelled` after stopping the matching owner, or with the original `complete` receipt if atomic commit already won the race; a stop failure uses `failed`. Temporary-file cleanup can remain separately retryable after the owner has stopped. The requester may accept a receipt only when its original transfer had reached a state where commit was possible and size/digest match. Repeated requests reuse terminal state and never republish the file. Local stop and peer acknowledgement are separate states; retrying notification must not reopen or resume the cancelled file. Terminal records are discarded on process/connection shutdown, and never reconstructed from a new grant.

## Retirement and bounded history

`FileTransferContext` binds the ordinal as immutable metadata and includes it in the native transfer key. Retirement controls cannot create or rebind that context. `FileRetirementContext.fromRequest` accepts only a fresh authenticated file request whose sender is the original `transferSender`. Replies bind the exact sealed operation and file ID; `retired` also binds the ordinal. A correcting `complete` must match size and digest; if the retirement already reports completion, its saved name must also match exactly. `retired` proves only that the ordinal cannot reopen, not that the claimed outcome is correct or a file was delivered.

The host must independently compare all retained metadata and the terminal result, wait for native cleanup and queued work, then recheck authority and ownership before deleting state. A cancelled or failed retirement may receive an authoritative completion correction; the sender must confirm that exact receipt in a subsequent retirement. Request rejection (`FileRejected`) does not prove terminal failure and cannot authorize retirement.

`FileOperationId` encodes canonical data-operation IDs as `file-v2-{i|r}-{ordinal}-{attempt}` with positive int63 counters. `FileTransferLedger<T>` retains at most 64 immutable owner slots plus a high-water mark. Admission consumes new ordinals even when full; observing a newer attempt preserves the currently bound operation until a single-use current ticket is committed. Retirement requires the current slot object. These helpers do not authenticate requests or perform cleanup. Each sealed endpoint and producer direction needs its own ledger, and first publication must follow ordinal order across offers, bootstrap resumes and termination controls.

The client currently uses v2 metadata, distinct request rejection and ordered first publication across offers, bootstrap resumes and local-producer termination. Physical recovery restores the order of files without a checked peer observation; a local write completion alone does not prove observation. Production data requests use canonical operation IDs with attempts increasing across recovery. The incoming channel validates the encoded producer, ordinal and full retained metadata before ledger admission or attempt observation. A busy resume consumes its valid attempt without replacing the current resolver. Successful native rebind also needs a current ticket and final authority/epoch checks; a superseded rebind is stopped and cleaned. Incoming terminal publications without an owner also reserve a ledger slot. The incoming operation history no longer needs to retain all prior session IDs.

The receiving channel now accepts authenticated `file-retire-` controls, compares the exact terminal result, drains local work and closes native ownership before releasing a retained slot. Cleanup failures retain retryable ownership. Completed files correct cancellation/failure claims with their original receipt. Removed ordinals remain closed by the high-water mark; bounded immutable receive history contains no authorization or native capability. Held data resolvers and matching termination records are removed in the same commit.

The production sender now requests retirement after authenticated peer termination/completion and local cleanup, retries under the original grant after physical recovery, and accepts an authoritative completion correction before confirming the corrected result. Both directions use bounded ledgers instead of retaining every operation ID. Failed retirement keeps its owner slot and retry action; successful retirement leaves at most 64 immutable display-history entries per direction. The UI retains actual saved names and completed progress after local selections are removed. Local cancellation or request rejection alone cannot authorize retirement. Rejected unknown reverse-direction cancellations cannot reserve a locally produced ordinal.

Client tests cover 521 sequential files over real loopback TCP and 70 sequential sends through the production controller. These tests use storage substitutes; they verify protocol capacity reclamation, not native-platform or two-device acceptance.

## Error vectors

- `size: "01"`, negative/overflow integers, out-of-file offsets: `invalid_range`.
- `data: "AA=="`, `"AB"` (nonzero pad bits), `"++//"`: `invalid_encoding`; empty/oversized blocks are rejected.
- `../x`, `C:x`, `CON.txt`, `CONIN$`, `conout$`, names above 255 UTF-8 bytes: `invalid_name`.
- Unknown version: `unsupported_version`; missing/extra/duplicate fields: `invalid_message`.
- Sender complete or receiver chunk: `direction_denied`.
- Cross-session/transfer or unrelated authority: `context_mismatch`; altered resume metadata: `resume_mismatch`.
- Expired/revoked/old generation authority propagates the session API's `SessionFailure`.

`failed.code` is restricted to stable wire errors: invalid_message, invalid_name, invalid_range, invalid_encoding, invalid_chunk, unsupported_version, context_mismatch, direction_denied, invalid_state, resource_limit, integrity_mismatch, source_changed, permission_denied, disk_full, io_failure, cancelled, expired, stale_authorization, resume_mismatch, unsupported_storage, timeout. Never send paths, secrets or arbitrary exception text.

Run `dart pub get`, `dart analyze`, and `dart test` with the repository's pinned Dart SDK. Unit and cryptographic peer tests are not disk, native-platform or real two-device acceptance evidence.
