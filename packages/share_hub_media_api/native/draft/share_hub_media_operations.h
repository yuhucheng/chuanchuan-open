/* SPDX-License-Identifier: Apache-2.0
 * UNIMPLEMENTED review draft 2. See MEDIA.md and README.md.
 * Includes no platform/UI types. No SDK exports these declarations yet.
 */
#ifndef SHARE_HUB_MEDIA_OPERATIONS_DRAFT_H
#define SHARE_HUB_MEDIA_OPERATIONS_DRAFT_H
#include "share_hub_media_boundary.h"
#ifdef __cplusplus
extern "C" {
#endif

#define SHM_CAP_PREVIEW UINT64_C(1)
#define SHM_CAP_WATCH UINT64_C(2)
#define SHM_CAP_CAST UINT64_C(4)
#define SHM_CAP_SOURCE_CHANGE UINT64_C(8)
#define SHM_CAP_RECOVERY UINT64_C(16)
#define SHM_CAP_CPU_BGRA UINT64_C(32)
#define SHM_CAP_STATISTICS UINT64_C(64)
#define SHM_CAP_FRAME_PROGRESS UINT64_C(128)
#define SHM_SOURCE_SCREEN UINT32_C(1)
#define SHM_SOURCE_WINDOW UINT32_C(2)
#define SHM_TASK_PENDING UINT32_C(1)
#define SHM_TASK_CANCELLING UINT32_C(2)
#define SHM_TASK_FINISHED UINT32_C(3)
#define SHM_RESULT_NONE UINT32_C(0)
#define SHM_RESULT_SOURCE_SNAPSHOT UINT32_C(1)
#define SHM_OP_STARTING UINT32_C(1)
#define SHM_OP_WAITING_FIRST_FRAME UINT32_C(2)
#define SHM_OP_STREAMING UINT32_C(3)
#define SHM_OP_PAUSED UINT32_C(4)
#define SHM_OP_TRANSITIONING UINT32_C(5)
#define SHM_OP_STOPPING UINT32_C(6)
#define SHM_OP_CLEANUP_FAILED UINT32_C(7)
#define SHM_OP_ENDED UINT32_C(8)
#define SHM_PLAYBACK_PAUSE UINT32_C(1)
#define SHM_PLAYBACK_RESUME UINT32_C(2)
#define SHM_SEND_QUEUED UINT32_C(1)
#define SHM_SEND_RUNNING UINT32_C(2)
#define SHM_SEND_CANCEL_REQUESTED UINT32_C(3)
#define SHM_PROGRESS_LOCAL UINT32_C(1)
#define SHM_PROGRESS_PEER UINT32_C(2)
#define SHM_STAGE_CAPTURE UINT32_C(1)
#define SHM_STAGE_RECEIVER UINT32_C(2)
#define SHM_PATH_DIRECT UINT32_C(1)
#define SHM_PATH_RELAY UINT32_C(2)
#define SHM_STATS_PATH UINT64_C(1)
#define SHM_STATS_RTT UINT64_C(2)
#define SHM_STATS_BITRATE UINT64_C(4)
#define SHM_STATS_DIMENSIONS UINT64_C(8)
#define SHM_PROGRESS_ACTIVE UINT64_C(1)
#define SHM_PROGRESS_IMAGE UINT64_C(2)
#define SHM_PROGRESS_IMAGE_AGE UINT64_C(4)
#define SHM_PROGRESS_OUTPUT UINT64_C(8)
#define SHM_PROGRESS_OUTPUT_AGE UINT64_C(16)
#define SHM_PROGRESS_UNCHANGED UINT64_C(32)
#define SHM_PROGRESS_CONSUMED UINT64_C(64)
#define SHM_PROGRESS_CONSUMED_AGE UINT64_C(128)

typedef struct shm_capabilities {
    shm_header header;
    uint32_t media_api_major;
    uint32_t media_api_minor;
    uint32_t media_api_patch;
    uint32_t session_protocol;
    uint64_t features;
    uint32_t max_remote_video_sessions;
    uint32_t max_local_previews;
} shm_capabilities;

/* Effective immutable ceilings, not suggestions. MEDIA.md defines defaults,
 * accounting, overflow and independently reserved/queryable control state.
 */
typedef struct shm_limits {
    shm_header header;
    uint32_t max_providers;
    uint32_t max_live_grants;
    uint32_t max_operations;
    uint32_t max_tasks;
    uint32_t max_sends_per_grant;
    uint32_t max_signals_per_operation;
    uint32_t max_event_records;
    uint32_t max_event_leases;
    uint32_t max_source_snapshots;
    uint32_t max_sources_per_snapshot;
    uint32_t max_recovery_intents;
    uint32_t max_frame_buffers;
    uint32_t max_frame_leases;
    uint32_t max_operations_per_grant;
    uint32_t max_authorizations;
    uint32_t reserved;
    uint64_t max_frame_bytes;
    uint64_t max_event_body_bytes;
    uint64_t max_signal_body_bytes;
    uint64_t max_history_entries;
    uint64_t max_source_snapshot_bytes;
    uint64_t max_recovery_wait_micros;
    uint64_t max_peer_ready_wait_micros;
} shm_limits;

typedef struct shm_source_selection {
    shm_source_snapshot snapshot;
    shm_source source;
} shm_source_selection;

/* Text is borrowed until snapshot_release. source is scoped to this snapshot.
 * is_primary is 0/1 actual platform evidence, never "first enumerated screen".
 */
typedef struct shm_source_info {
    shm_header header;
    shm_source source;
    uint32_t type;
    uint32_t is_primary;
    shm_bytes stable_local_id_utf8;
    shm_bytes name_utf8;
} shm_source_info;

/* Successful task result handles are BORROWED until task_take_result transfers
 * them once. task_release frees any untaken result; reading is not transfer.
 * Start returns its operation immediately; its task has RESULT_NONE.
 */
typedef struct shm_task_info {
    shm_header header;
    uint32_t state;
    shm_status result_status;
    uint32_t result_kind;
    uint32_t reserved;
    uint64_t result_handle;
    shm_operation operation;
    uint64_t change_sequence;
} shm_task_info;

typedef struct shm_start_options {
    shm_header header;
    shm_authorization authorization; /* zero only for preview_start */
    shm_source_selection source;    /* zero for receiver or recovery */
    shm_recovery recovery;          /* zero for ordinary start/preview */
} shm_start_options;

typedef struct shm_operation_info {
    shm_header header;
    uint32_t state;
    shm_status failure_status;
    uint32_t transport_generation;
    uint32_t media_revision;
    uint32_t sends;                 /* 0/1, derived from authority */
    uint32_t is_preview;            /* 0/1 */
    shm_authorization authorization;
    shm_task active_task;
    uint64_t change_sequence;
} shm_operation_info;

typedef struct shm_geometry {
    shm_header header;
    uint32_t media_revision;
    uint32_t source_type;
    uint32_t width;
    uint32_t height;
    double origin_x;
    double origin_y;
    double scale;
    uint32_t rotation_degrees;
    uint32_t reserved;
} shm_geometry;

typedef struct shm_statistics {
    shm_header header;
    uint64_t valid_fields;
    uint64_t sampled_at_micros;
    uint64_t round_trip_micros;
    uint64_t bits_per_second;
    uint32_t width;
    uint32_t height;
    uint32_t path;
    uint32_t media_revision;
} shm_statistics;

/* Unknown fields have their validity bit clear and storage zero, NOT a known
 * zero measurement. Capture output/idle is distinct from image sequence; texture
 * consumption is distinct from main presentation. Peer values require a matching
 * authenticated frame probe, never an untrusted host-supplied sample.
 */
typedef struct shm_progress {
    shm_header header;
    uint64_t valid_fields;
    uint64_t sampled_at_micros;
    uint32_t stage;
    uint32_t active;
    uint32_t source_unchanged;
    uint32_t media_revision;
    uint64_t image_sequence;
    uint64_t image_age_micros;
    uint64_t output_sequence;
    uint64_t output_age_micros;
    uint64_t consumed_sequence;
    uint64_t consumed_frame_age_micros;
} shm_progress;

/* Derived only from a previously admitted operation, never caller-built lineage.
 * request body is copied separately; exact saved source remains private to core.
 */
typedef struct shm_recovery_info {
    shm_header header;
    uint32_t previous_generation;
    uint32_t previous_revision;
    uint32_t paused;
    uint32_t claim_started;
    uint64_t deadline_micros;
    shm_operation previous_operation;
} shm_recovery_info;

typedef struct shm_send_info {
    shm_header header;
    shm_job job;
    shm_authorization authorization;
    shm_operation operation;
    uint32_t state;
    uint32_t reserved;
    uint64_t change_sequence;
} shm_send_info;

SHM_DRAFT_EXPORT shm_status SHM_DRAFT_CALL shm_draft_capabilities(
    shm_core core, shm_capabilities *out_info);
SHM_DRAFT_EXPORT shm_status SHM_DRAFT_CALL shm_draft_limits(
    shm_core core, shm_limits *out_info);
/* Nonblocking creation; enumeration result is an owned snapshot from the task.
 * UI/system permission prompting belongs to host; core never prompts silently.
 */
SHM_DRAFT_EXPORT shm_status SHM_DRAFT_CALL shm_draft_sources(
    shm_core core, shm_task *out_task);
SHM_DRAFT_EXPORT shm_status SHM_DRAFT_CALL shm_draft_source_count(
    shm_core core, shm_source_snapshot snapshot, uint32_t *out_count);
SHM_DRAFT_EXPORT shm_status SHM_DRAFT_CALL shm_draft_source_read(
    shm_core core, shm_source_snapshot snapshot, uint32_t index, shm_source_info *out_info);
SHM_DRAFT_EXPORT shm_status SHM_DRAFT_CALL shm_draft_source_snapshot_release(
    shm_core core, shm_source_snapshot snapshot);
/* Acceptance returns op/task handles BEFORE asynchronous allocation; source
 * identity is copied, then rechecked on the platform before effects.
 */
SHM_DRAFT_EXPORT shm_status SHM_DRAFT_CALL shm_draft_preview_start(
    shm_core core, const shm_start_options *options, shm_operation *out_operation, shm_task *out_task);
SHM_DRAFT_EXPORT shm_status SHM_DRAFT_CALL shm_draft_remote_start(
    shm_core core, const shm_start_options *options, shm_operation *out_operation, shm_task *out_task);
SHM_DRAFT_EXPORT shm_status SHM_DRAFT_CALL shm_draft_playback(
    shm_core core, shm_operation operation, uint32_t expected_revision,
    uint32_t action, shm_task *out_task);
SHM_DRAFT_EXPORT shm_status SHM_DRAFT_CALL shm_draft_change_source(
    shm_core core, shm_operation operation, uint32_t expected_revision,
    shm_source_selection source, shm_task *out_task);
SHM_DRAFT_EXPORT shm_status SHM_DRAFT_CALL shm_draft_operation_read(
    shm_core core, shm_operation operation, shm_operation_info *out_info);
SHM_DRAFT_EXPORT shm_status SHM_DRAFT_CALL shm_draft_operation_geometry(
    shm_core core, shm_operation operation, uint32_t expected_revision, shm_geometry *out_info);
/* Single-entry owned snapshot of the settled LOCAL source; EMPTY on receiver,
 * BUSY during source transition. Does not enumerate or choose another source.
 */
SHM_DRAFT_EXPORT shm_status SHM_DRAFT_CALL shm_draft_operation_local_source(
    shm_core core, shm_operation operation, shm_source_snapshot *out_snapshot);
SHM_DRAFT_EXPORT shm_status SHM_DRAFT_CALL shm_draft_operation_statistics(
    shm_core core, shm_operation operation, uint32_t expected_revision, shm_statistics *out_info);
SHM_DRAFT_EXPORT shm_status SHM_DRAFT_CALL shm_draft_operation_progress(
    shm_core core, shm_operation operation, uint32_t expected_revision,
    uint32_t scope, shm_progress *out_info);
SHM_DRAFT_EXPORT shm_status SHM_DRAFT_CALL shm_draft_operation_release(
    shm_core core, shm_operation operation);
SHM_DRAFT_EXPORT shm_status SHM_DRAFT_CALL shm_draft_task_read(
    shm_core core, shm_task task, shm_task_info *out_info);
SHM_DRAFT_EXPORT shm_status SHM_DRAFT_CALL shm_draft_task_take_result(
    shm_core core, shm_task task, uint32_t *out_kind, uint64_t *out_handle);
SHM_DRAFT_EXPORT shm_status SHM_DRAFT_CALL shm_draft_task_cancel(shm_core core, shm_task task);
SHM_DRAFT_EXPORT shm_status SHM_DRAFT_CALL shm_draft_task_release(shm_core core, shm_task task);
/* Retain only an actual operation's settled playback/source lineage after a
 * recoverable transport interruption. Max deadline may only shorten its grant.
 * Explicit stop/revoke/change-in-progress prevent retention or later claiming.
 */
SHM_DRAFT_EXPORT shm_status SHM_DRAFT_CALL shm_draft_recovery_retain(
    shm_core core, shm_operation previous, uint64_t max_deadline_micros, shm_recovery *out_intent);
SHM_DRAFT_EXPORT shm_status SHM_DRAFT_CALL shm_draft_recovery_read(
    shm_core core, shm_recovery intent, shm_recovery_info *out_info);
/* Query required length with capacity 0/null destination; BUFFER_TOO_SMALL
 * writes required_bytes only. Never partially copy a request body.
 */
SHM_DRAFT_EXPORT shm_status SHM_DRAFT_CALL shm_draft_recovery_copy_request(
    shm_core core, shm_recovery intent, uint8_t *destination,
    uint64_t capacity, uint64_t *required_bytes);
SHM_DRAFT_EXPORT shm_status SHM_DRAFT_CALL shm_draft_recovery_cancel(shm_core core, shm_recovery intent);
SHM_DRAFT_EXPORT shm_status SHM_DRAFT_CALL shm_draft_recovery_release(shm_core core, shm_recovery intent);
/* Texture consumption and actual main-view paint are separate notifications.
 * Both require a current receiver frame lease; presentation is not a new frame.
 */
SHM_DRAFT_EXPORT shm_status SHM_DRAFT_CALL shm_draft_frame_consumed(shm_core core, shm_frame frame);
SHM_DRAFT_EXPORT shm_status SHM_DRAFT_CALL shm_draft_main_presented(shm_core core, shm_frame frame);
/* Durable send table: cursor 0 starts enumeration, otherwise strictly greater
 * job IDs; restart after a change sequence. Events are hints, not sole discovery.
 */
SHM_DRAFT_EXPORT shm_status SHM_DRAFT_CALL shm_draft_provider_next_send(
    shm_core core, shm_provider provider, shm_job after_job, shm_send_info *out_info);
SHM_DRAFT_EXPORT shm_status SHM_DRAFT_CALL shm_draft_provider_send_event(
    shm_core core, shm_provider provider, shm_job job, shm_event *out_event);
/* QUEUED -> RUNNING once, before invoking host transport. A cancelled queued
 * job may already be settled; do not send when begin fails.
 */
SHM_DRAFT_EXPORT shm_status SHM_DRAFT_CALL shm_draft_provider_begin_send(
    shm_core core, shm_provider provider, shm_job job);
/* Durable sequence covers queryable state, not just queue content. Wait checks
 * observed_sequence under the same lock as subscription, preventing lost wakeup.
 * Call on a host worker, never the UI thread. timeout_ms <= 60000; zero polls.
 */
SHM_DRAFT_EXPORT shm_status SHM_DRAFT_CALL shm_draft_change_sequence(
    shm_core core, uint64_t *out_sequence);
SHM_DRAFT_EXPORT shm_status SHM_DRAFT_CALL shm_draft_wait_change(
    shm_core core, uint64_t observed_sequence, uint32_t timeout_ms, uint64_t *out_sequence);

#ifdef __cplusplus
}
#endif
#endif
