/* SPDX-License-Identifier: Apache-2.0
 * Versioned discovery for the revision-2 review draft, NOT a stable ABI.
 * Table version and structure/boundary revision are separate identities.
 * Query does not create a core, authenticate a grant or advertise media.
 */
#ifndef SHARE_HUB_MEDIA_API_TABLE_DRAFT_H
#define SHARE_HUB_MEDIA_API_TABLE_DRAFT_H
#include "share_hub_media_operations.h"
#include <stddef.h>
#ifdef __cplusplus
extern "C" {
#endif

#define SHM_DRAFT_API_TABLE_VERSION UINT32_C(1)
#define SHM_DRAFT_API_TABLE_PREFIX_BYTES UINT32_C(24)
#define SHM_DRAFT_API_TABLE_V1_BYTES UINT32_C(480)
#define SHM_DRAFT_API_TABLE_MAX_OUTPUT_BYTES UINT32_C(16384)

/* Version-1 slot order is fixed within this draft table. Future table versions
 * append slots; they cannot reorder or change existing signatures. New fields
 * in operation structs still require their own boundary revision negotiation.
 */
#define SHM_DRAFT_API_TABLE_FUNCTIONS(X) \
    X(create, (const shm_core_config *config, uint32_t *available_revision, shm_core *out_core)) \
    X(clock_now, (shm_core core, uint64_t *out_micros)) \
    X(provider_register, (shm_core core, shm_provider *out_provider)) \
    X(seal_providers, (shm_core core)) \
    X(provider_import_grant, (shm_core core, shm_provider provider, const shm_grant_import *grant, shm_grant *out_grant)) \
    X(provider_activate_grant, (shm_core core, shm_provider provider, shm_grant grant, uint32_t generation)) \
    X(provider_suspend_grant, (shm_core core, shm_provider provider, shm_grant grant)) \
    X(provider_revoke_grant, (shm_core core, shm_provider provider, shm_grant grant)) \
    X(provider_import_authorization, (shm_core core, shm_provider provider, const shm_authorization_import *authorization, shm_authorization *out_authorization)) \
    X(provider_deliver_signal, (shm_core core, shm_provider provider, shm_authorization authorization, shm_bytes authenticated_body_utf8)) \
    X(provider_complete_send, (shm_core core, shm_provider provider, shm_job job, shm_status result)) \
    X(provider_close, (shm_core core, shm_provider provider)) \
    X(authorization_cancel, (shm_core core, shm_authorization authorization, uint32_t stop_reason)) \
    X(authorization_check, (shm_core core, shm_authorization authorization)) \
    X(authorization_release, (shm_core core, shm_authorization authorization)) \
    X(operation_stop, (shm_core core, shm_operation operation, uint32_t stop_reason)) \
    X(poll_event, (shm_core core, shm_event *out_event)) \
    X(event_read, (shm_core core, shm_event event, shm_event_info *out_info)) \
    X(event_release, (shm_core core, shm_event event)) \
    X(frame_acquire_latest, (shm_core core, shm_operation operation, uint32_t media_revision, shm_frame *out_frame)) \
    X(frame_read, (shm_core core, shm_frame frame, shm_frame_info *out_info)) \
    X(frame_release, (shm_core core, shm_frame frame)) \
    X(close, (shm_core core)) \
    X(query_close, (shm_core core, shm_close_info *out_info)) \
    X(release, (shm_core core)) \
    X(capabilities, (shm_core core, shm_capabilities *out_info)) \
    X(limits, (shm_core core, shm_limits *out_info)) \
    X(sources, (shm_core core, shm_task *out_task)) \
    X(source_count, (shm_core core, shm_source_snapshot snapshot, uint32_t *out_count)) \
    X(source_read, (shm_core core, shm_source_snapshot snapshot, uint32_t index, shm_source_info *out_info)) \
    X(source_snapshot_release, (shm_core core, shm_source_snapshot snapshot)) \
    X(preview_start, (shm_core core, const shm_start_options *options, shm_operation *out_operation, shm_task *out_task)) \
    X(remote_start, (shm_core core, const shm_start_options *options, shm_operation *out_operation, shm_task *out_task)) \
    X(playback, (shm_core core, shm_operation operation, uint32_t expected_revision, uint32_t action, shm_task *out_task)) \
    X(change_source, (shm_core core, shm_operation operation, uint32_t expected_revision, shm_source_selection source, shm_task *out_task)) \
    X(operation_read, (shm_core core, shm_operation operation, shm_operation_info *out_info)) \
    X(operation_geometry, (shm_core core, shm_operation operation, uint32_t expected_revision, shm_geometry *out_info)) \
    X(operation_local_source, (shm_core core, shm_operation operation, shm_source_snapshot *out_snapshot)) \
    X(operation_statistics, (shm_core core, shm_operation operation, uint32_t expected_revision, shm_statistics *out_info)) \
    X(operation_progress, (shm_core core, shm_operation operation, uint32_t expected_revision, uint32_t scope, shm_progress *out_info)) \
    X(operation_release, (shm_core core, shm_operation operation)) \
    X(task_read, (shm_core core, shm_task task, shm_task_info *out_info)) \
    X(task_take_result, (shm_core core, shm_task task, uint32_t *out_kind, uint64_t *out_handle)) \
    X(task_cancel, (shm_core core, shm_task task)) \
    X(task_release, (shm_core core, shm_task task)) \
    X(recovery_retain, (shm_core core, shm_operation previous, uint64_t max_deadline_micros, shm_recovery *out_intent)) \
    X(recovery_read, (shm_core core, shm_recovery intent, shm_recovery_info *out_info)) \
    X(recovery_copy_request, (shm_core core, shm_recovery intent, uint8_t *destination, uint64_t capacity, uint64_t *required_bytes)) \
    X(recovery_cancel, (shm_core core, shm_recovery intent)) \
    X(recovery_release, (shm_core core, shm_recovery intent)) \
    X(frame_consumed, (shm_core core, shm_frame frame)) \
    X(main_presented, (shm_core core, shm_frame frame)) \
    X(provider_next_send, (shm_core core, shm_provider provider, shm_job after_job, shm_send_info *out_info)) \
    X(provider_send_event, (shm_core core, shm_provider provider, shm_job job, shm_event *out_event)) \
    X(provider_begin_send, (shm_core core, shm_provider provider, shm_job job)) \
    X(change_sequence, (shm_core core, uint64_t *out_sequence)) \
    X(wait_change, (shm_core core, uint64_t observed_sequence, uint32_t timeout_ms, uint64_t *out_sequence))

typedef struct shm_draft_api_table {
    uint32_t available_bytes;
    uint32_t table_version;
    uint32_t boundary_revision;
    uint32_t pointer_bytes;
    uint32_t written_bytes;
    uint32_t reserved;
#define SHM_DRAFT_API_FIELD(name, arguments) shm_status (SHM_DRAFT_CALL *name) arguments;
    SHM_DRAFT_API_TABLE_FUNCTIONS(SHM_DRAFT_API_FIELD)
#undef SHM_DRAFT_API_FIELD
} shm_draft_api_table;

/* Caller owns valid writable output_bytes storage, up to the declared ceiling.
 * Null/over-limit calls do not write. A short prefix is zeroed but cannot carry
 * metadata; other insufficient buffers receive the prefix only. Mismatched
 * revision/minimum version also receive prefix only, with no function pointers.
 * Success needs the complete v1 prefix/table. Larger caller tails are zeroed.
 * written_bytes is the complete bytes delivered, never caller capacity.
 * Missing bootstrap symbols in old candidates are explicit unsupported discovery,
 * not a reason to reinterpret their structs or claim a stable ABI.
 */
SHM_DRAFT_EXPORT shm_status SHM_DRAFT_CALL shm_draft_get_api(
    uint32_t boundary_revision, uint32_t minimum_table_version,
    uint32_t output_bytes, void *out_table);
#ifdef __cplusplus
}
#endif
#endif
