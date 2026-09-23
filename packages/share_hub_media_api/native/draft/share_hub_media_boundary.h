/* SPDX-License-Identifier: Apache-2.0
 * UNIMPLEMENTED REVIEW DRAFT. No SDK currently exports these symbols.
 * This is not the released Dart API version or a stable binary ABI.
 * Normative ownership/authorization rules: README.md in this directory.
 */
#ifndef SHARE_HUB_MEDIA_BOUNDARY_DRAFT_H
#define SHARE_HUB_MEDIA_BOUNDARY_DRAFT_H

#include <stdint.h>

#if defined(_WIN32)
#define SHM_DRAFT_CALL __cdecl
#else
#define SHM_DRAFT_CALL
#endif
#if defined(SHM_DRAFT_BUILD_SHARED) && defined(_WIN32)
#define SHM_DRAFT_EXPORT __declspec(dllexport)
#elif defined(SHM_DRAFT_USE_SHARED) && defined(_WIN32)
#define SHM_DRAFT_EXPORT __declspec(dllimport)
#elif defined(__GNUC__)
#define SHM_DRAFT_EXPORT __attribute__((visibility("default")))
#else
#define SHM_DRAFT_EXPORT
#endif
#ifdef __cplusplus
extern "C" {
#endif

#define SHM_DRAFT_REVISION UINT32_C(2)
#define SHM_DRAFT_MAX_BODY_BYTES UINT64_C(65536)
#define SHM_DRAFT_MAX_SESSION_ID_BYTES UINT64_C(512)

/* Runtime-validated, process-local, non-recycled IDs; zero is never valid.
 * Every function validates core ownership, object kind, lifetime and generation.
 * These IDs are not secrets and confer no authority outside the trusted process.
 */
typedef uint64_t shm_core;
typedef uint64_t shm_provider;
typedef uint64_t shm_grant;
typedef uint64_t shm_authorization;
typedef uint64_t shm_operation;
typedef uint64_t shm_job;
typedef uint64_t shm_event;
typedef uint64_t shm_frame;
typedef uint64_t shm_task;
typedef uint64_t shm_source_snapshot;
typedef uint64_t shm_source;
typedef uint64_t shm_recovery;
typedef uint32_t shm_status;

#define SHM_OK UINT32_C(0)
#define SHM_EMPTY UINT32_C(1)
#define SHM_INVALID_ARGUMENT UINT32_C(2)
#define SHM_INCOMPATIBLE_ABI UINT32_C(3)
#define SHM_STALE_HANDLE UINT32_C(4)
#define SHM_FOREIGN_OWNER UINT32_C(5)
#define SHM_UNAUTHORIZED UINT32_C(6)
#define SHM_EXPIRED UINT32_C(7)
#define SHM_BUSY UINT32_C(8)
#define SHM_UNAVAILABLE UINT32_C(9)
#define SHM_CLOSING UINT32_C(10)
#define SHM_CLEANUP_FAILED UINT32_C(11)
#define SHM_LIMIT UINT32_C(12)
#define SHM_CANCELLED UINT32_C(13)
#define SHM_FAILED UINT32_C(14)
#define SHM_BUFFER_TOO_SMALL UINT32_C(15)

#define SHM_ROLE_INITIATOR UINT32_C(1)
#define SHM_ROLE_RECEIVER UINT32_C(2)
#define SHM_REQUEST_LOCAL UINT32_C(1)
#define SHM_REQUEST_AUTHENTICATED_PEER UINT32_C(2)
#define SHM_OPERATION_WATCH UINT32_C(1)
#define SHM_OPERATION_CAST UINT32_C(2)
/* Control/file are not supported by this media boundary draft. Unknown values
 * fail closed; future features require an independently advertised capability.
 */
#define SHM_STOP_USER UINT32_C(1)
#define SHM_STOP_FAILED UINT32_C(2)
#define SHM_STOP_AUTHORIZATION UINT32_C(3)
#define SHM_STOP_SHUTDOWN UINT32_C(4)
#define SHM_STATE_CONFIGURING UINT32_C(5)
#define SHM_STATE_OPEN UINT32_C(1)
#define SHM_STATE_CLOSING UINT32_C(2)
#define SHM_STATE_CLEANUP_FAILED UINT32_C(3)
#define SHM_STATE_CLOSED UINT32_C(4)
#define SHM_EVENT_SEND_REQUEST UINT32_C(1)
#define SHM_EVENT_SEND_SIGNAL UINT32_C(2)
#define SHM_EVENT_JOB_CANCEL UINT32_C(3)
#define SHM_EVENT_OPERATION_STATE UINT32_C(4)
#define SHM_EVENT_CORE_STATE UINT32_C(5)
#define SHM_PIXEL_BGRA8 UINT32_C(1)

/* All supported targets are 64-bit. No packed structs, C enums, bool, long,
 * size_t, C++ types, Dart objects or Flutter handles cross this boundary.
 * Inputs are borrowed for the duration of the call and copied before return.
 * size/version must match this draft exactly; reserved fields must be zero.
 */
typedef struct shm_header {
    uint32_t size;
    uint32_t revision;
} shm_header;

typedef struct shm_bytes {
    const uint8_t *data;
    uint64_t length;
} shm_bytes;

typedef struct shm_core_config {
    shm_header header;
    /* Zero selects implementation defaults; nonzero can only LOWER limits.
     * Query effective limits after create. Counts cover SDK-owned immutable
     * frame storage/pools, not total process or decoder working-set memory.
     */
    uint64_t max_frame_bytes;
    uint32_t max_frame_buffers;
    uint32_t max_frame_leases;
} shm_core_config;

/* IMPORT ONLY from the registered local authenticated pairing service.
 * No recovery root, short code, private key or ciphertext is accepted here.
 * Keys/ID are exact 32-byte values, not discovered names or UI identifiers.
 * The deadline is in this core's continuous clock domain; never a peer epoch.
 */
typedef struct shm_grant_import {
    shm_header header;
    uint8_t grant_id[32];
    uint8_t initiator_key[32];
    uint8_t receiver_key[32];
    uint32_t local_role;
    uint32_t reserved;
    shm_bytes policy_type_utf8;
    uint64_t policy_lifetime_seconds;
    uint64_t original_deadline_micros;
} shm_grant_import;

/* The provider first verifies its real sealed authorization and local registry.
 * core derives sends/receives from role + kind + operation, never from SDP/UI.
 * Session IDs preserve Dart's <=128 UTF-16 code-unit bound; the byte cap is only
 * an allocation guard, not a replacement for UTF-8 validation/code-unit checks.
 */
typedef struct shm_authorization_import {
    shm_header header;
    shm_grant grant;
    uint32_t transport_generation;
    uint32_t request_kind;
    uint32_t operation;
    uint32_t reserved;
    shm_bytes session_id_utf8;
    shm_bytes authenticated_body_utf8;
} shm_authorization_import;

/* Owned event payload borrowed until event_release; never frees provider jobs.
 * For SEND events, job identifies one exact outstanding transport operation.
 * JOB_CANCEL refers to that same job and is not a resource-release receipt.
 * State notifications use status/state and have job == 0.
 */
typedef struct shm_event_info {
    shm_header header;
    uint32_t kind;
    uint32_t state;
    shm_status status;
    uint32_t reserved;
    shm_provider provider;
    shm_authorization authorization;
    shm_operation operation;
    shm_job job;
    shm_bytes body_utf8;
    uint64_t change_sequence;
} shm_event_info;

/* Closed means actual internal work/cleanup finished. External event/frame
 * leases can outlive close and must be released before destroying the core.
 */
typedef struct shm_close_info {
    shm_header header;
    uint32_t state;
    shm_status last_cleanup_status;
    uint64_t pending_provider_jobs;
    uint64_t pending_native_owners;
    uint64_t outstanding_event_leases;
    uint64_t outstanding_frame_leases;
    uint64_t outstanding_source_snapshots;
    uint64_t pending_waiters;
} shm_close_info;

/* A read-only CPU mapping belongs to the acquired frame lease; never caller-free
 * its data. Mapping is a baseline access path, not a GPU interop commitment.
 * Sequence/age are local evidence, not a main-view presentation receipt.
 */
typedef struct shm_frame_info {
    shm_header header;
    shm_operation operation;
    uint32_t media_revision;
    uint32_t pixel_format;
    uint32_t width;
    uint32_t height;
    uint64_t row_bytes;
    uint64_t sequence;
    uint64_t captured_or_decoded_at_micros;
    shm_bytes pixels;
} shm_frame_info;

/* Negotiation before any resources: available_revision is always written for
 * valid output storage, other inputs are not interpreted on revision mismatch.
 * This draft has no compatible minor extension rule yet.
 */
SHM_DRAFT_EXPORT shm_status SHM_DRAFT_CALL shm_draft_create(
    const shm_core_config *config, uint32_t *available_revision, shm_core *out_core);
SHM_DRAFT_EXPORT shm_status SHM_DRAFT_CALL shm_draft_clock_now(
    shm_core core, uint64_t *out_micros);
SHM_DRAFT_EXPORT shm_status SHM_DRAFT_CALL shm_draft_provider_register(
    shm_core core, shm_provider *out_provider);
/* Seal the composition root before exposing the core to application controls.
 * No provider can register afterwards. Imports/media require a sealed core.
 * Zero providers is valid for future preview-only consumers.
 */
SHM_DRAFT_EXPORT shm_status SHM_DRAFT_CALL shm_draft_seal_providers(shm_core core);
SHM_DRAFT_EXPORT shm_status SHM_DRAFT_CALL shm_draft_provider_import_grant(
    shm_core core, shm_provider provider, const shm_grant_import *grant,
    shm_grant *out_grant);
/* Import creates a suspended mirror. Activate only after successful current
 * authenticated transport proof. Generations strictly increase (1..2^32-1).
 * Suspension invalidates all old permits synchronously, including in-flight
 * native admission. Reactivation cannot change binding/policy/deadline.
 */
SHM_DRAFT_EXPORT shm_status SHM_DRAFT_CALL shm_draft_provider_activate_grant(
    shm_core core, shm_provider provider, shm_grant grant, uint32_t generation);
SHM_DRAFT_EXPORT shm_status SHM_DRAFT_CALL shm_draft_provider_suspend_grant(
    shm_core core, shm_provider provider, shm_grant grant);
SHM_DRAFT_EXPORT shm_status SHM_DRAFT_CALL shm_draft_provider_revoke_grant(
    shm_core core, shm_provider provider, shm_grant grant);
SHM_DRAFT_EXPORT shm_status SHM_DRAFT_CALL shm_draft_provider_import_authorization(
    shm_core core, shm_provider provider, const shm_authorization_import *authorization,
    shm_authorization *out_authorization);
/* Incoming data is accepted only from the provider holding the exact verified
 * signal and authorization mapping; a raw unauthenticated body is never routed
 * here by the UI. Core still validates media schema, direction, state/revision.
 */
SHM_DRAFT_EXPORT shm_status SHM_DRAFT_CALL shm_draft_provider_deliver_signal(
    shm_core core, shm_provider provider, shm_authorization authorization,
    shm_bytes authenticated_body_utf8);
/* Call only after actual transport send/cancellation has drained. A timeout
 * notification cannot complete a still-running host future or free its owner.
 */
SHM_DRAFT_EXPORT shm_status SHM_DRAFT_CALL shm_draft_provider_complete_send(
    shm_core core, shm_provider provider, shm_job job, shm_status result);
SHM_DRAFT_EXPORT shm_status SHM_DRAFT_CALL shm_draft_provider_close(
    shm_core core, shm_provider provider);
SHM_DRAFT_EXPORT shm_status SHM_DRAFT_CALL shm_draft_authorization_cancel(
    shm_core core, shm_authorization authorization, uint32_t stop_reason);

/* Release drops the caller's reference only. Live operations retain authority;
 * use cancel/stop for invalidation. IDs never become another object's ID.
 */
SHM_DRAFT_EXPORT shm_status SHM_DRAFT_CALL shm_draft_authorization_release(
    shm_core core, shm_authorization authorization);
SHM_DRAFT_EXPORT shm_status SHM_DRAFT_CALL shm_draft_operation_stop(
    shm_core core, shm_operation operation, uint32_t stop_reason);
SHM_DRAFT_EXPORT shm_status SHM_DRAFT_CALL shm_draft_poll_event(
    shm_core core, shm_event *out_event);
SHM_DRAFT_EXPORT shm_status SHM_DRAFT_CALL shm_draft_event_read(
    shm_core core, shm_event event, shm_event_info *out_info);
SHM_DRAFT_EXPORT shm_status SHM_DRAFT_CALL shm_draft_event_release(
    shm_core core, shm_event event);
SHM_DRAFT_EXPORT shm_status SHM_DRAFT_CALL shm_draft_frame_acquire_latest(
    shm_core core, shm_operation operation, uint32_t media_revision, shm_frame *out_frame);
SHM_DRAFT_EXPORT shm_status SHM_DRAFT_CALL shm_draft_frame_read(
    shm_core core, shm_frame frame, shm_frame_info *out_info);
SHM_DRAFT_EXPORT shm_status SHM_DRAFT_CALL shm_draft_frame_release(
    shm_core core, shm_frame frame);
/* All close/stop calls gate synchronously and return without waiting. Repeated
 * calls retry failed cleanup. query does not itself cancel work or finish jobs.
 * core_release succeeds only after CLOSED and zero outstanding leases.
 */
SHM_DRAFT_EXPORT shm_status SHM_DRAFT_CALL shm_draft_close(shm_core core);
SHM_DRAFT_EXPORT shm_status SHM_DRAFT_CALL shm_draft_query_close(
    shm_core core, shm_close_info *out_info);
SHM_DRAFT_EXPORT shm_status SHM_DRAFT_CALL shm_draft_release(shm_core core);

#ifdef __cplusplus
}
#endif
#endif
