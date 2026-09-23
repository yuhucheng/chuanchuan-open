#!/usr/bin/env python3
"""Check the unimplemented C boundary draft; never claims SDK/runtime acceptance."""
import argparse
import hashlib
import json
import platform
import shutil
import subprocess
import tempfile
from pathlib import Path

CHECKS = r'''
#include "share_hub_media_operations.h"
#include <stddef.h>
#ifdef __cplusplus
#define CHECK static_assert
#define ALIGN alignof
#else
#define CHECK _Static_assert
#define ALIGN _Alignof
#endif
CHECK(sizeof(void *) == 8, "only supported 64-bit targets");
CHECK(sizeof(shm_status) == 4, "status width");
CHECK(sizeof(double) == 8 && ALIGN(double) == 8, "geometry scalar ABI");
CHECK(sizeof(shm_core) == 8, "handle width");
CHECK(sizeof(shm_header) == 8, "header size");
CHECK(sizeof(shm_bytes) == 16, "slice size");
CHECK(ALIGN(shm_bytes) == 8, "slice alignment");
CHECK(offsetof(shm_bytes, length) == 8, "slice length");
CHECK(sizeof(shm_core_config) == 24, "config size");
CHECK(sizeof(shm_grant_import) == 144, "grant size");
CHECK(ALIGN(shm_grant_import) == 8, "grant alignment");
CHECK(offsetof(shm_grant_import, policy_type_utf8) == 112, "policy offset");
CHECK(offsetof(shm_grant_import, original_deadline_micros) == 136, "deadline offset");
CHECK(sizeof(shm_authorization_import) == 64, "authorization size");
CHECK(offsetof(shm_authorization_import, session_id_utf8) == 32, "session offset");
CHECK(sizeof(shm_event_info) == 80, "event size");
CHECK(offsetof(shm_event_info, provider) == 24, "event handles");
CHECK(offsetof(shm_event_info, body_utf8) == 56, "event payload");
CHECK(sizeof(shm_close_info) == 64, "close size");
CHECK(offsetof(shm_close_info, pending_provider_jobs) == 16, "close counters");
CHECK(sizeof(shm_frame_info) == 72, "frame size");
CHECK(offsetof(shm_frame_info, row_bytes) == 32, "frame stride");
CHECK(offsetof(shm_frame_info, pixels) == 56, "frame pixels");
CHECK(sizeof(shm_capabilities) == 40, "capabilities size");
CHECK(sizeof(shm_limits) == 128, "limits size");
CHECK(offsetof(shm_limits, max_frame_bytes) == 72, "limits bytes offset");
CHECK(sizeof(shm_source_selection) == 16, "selection size");
CHECK(sizeof(shm_source_info) == 56, "source info size");
CHECK(offsetof(shm_source_info, name_utf8) == 40, "source label offset");
CHECK(sizeof(shm_task_info) == 48, "task info size");
CHECK(sizeof(shm_start_options) == 40, "start options size");
CHECK(offsetof(shm_start_options, recovery) == 32, "recovery handle offset");
CHECK(sizeof(shm_operation_info) == 56, "operation size");
CHECK(sizeof(shm_geometry) == 56, "geometry size");
CHECK(offsetof(shm_geometry, origin_x) == 24, "geometry doubles");
CHECK(sizeof(shm_statistics) == 56, "statistics size");
CHECK(sizeof(shm_progress) == 88, "progress size");
CHECK(offsetof(shm_progress, image_sequence) == 40, "progress counters");
CHECK(sizeof(shm_recovery_info) == 40, "recovery info size");
CHECK(sizeof(shm_send_info) == 48, "send info size");
CHECK(SHM_DRAFT_REVISION == 2, "draft revision");
'''
SIGNATURES = r'''
void check_declarations(void) {
    shm_status (SHM_DRAFT_CALL *create)(const shm_core_config *, uint32_t *, shm_core *) = shm_draft_create;
    shm_status (SHM_DRAFT_CALL *import_auth)(shm_core, shm_provider, const shm_authorization_import *, shm_authorization *) = shm_draft_provider_import_authorization;
    shm_status (SHM_DRAFT_CALL *signal)(shm_core, shm_provider, shm_authorization, shm_bytes) = shm_draft_provider_deliver_signal;
    shm_status (SHM_DRAFT_CALL *read_frame)(shm_core, shm_frame, shm_frame_info *) = shm_draft_frame_read;
    shm_status (SHM_DRAFT_CALL *close)(shm_core) = shm_draft_close;
    shm_status (SHM_DRAFT_CALL *start)(shm_core, const shm_start_options *, shm_operation *, shm_task *) = shm_draft_remote_start;
    shm_status (SHM_DRAFT_CALL *retain)(shm_core, shm_operation, uint64_t, shm_recovery *) = shm_draft_recovery_retain;
    shm_status (SHM_DRAFT_CALL *wait)(shm_core, uint64_t, uint32_t, uint64_t *) = shm_draft_wait_change;
    (void)create; (void)import_auth; (void)signal; (void)read_frame; (void)close;
    (void)start; (void)retain; (void)wait;
}
'''
HOST = r'''
#include <stdio.h>
int main(void) {
    printf("{\"pointerBytes\":%u,\"grantBytes\":%u,\"authorizationBytes\":%u,\"eventBytes\":%u,\"closeBytes\":%u,\"frameBytes\":%u}\n",
        (unsigned)sizeof(void *), (unsigned)sizeof(shm_grant_import),
        (unsigned)sizeof(shm_authorization_import), (unsigned)sizeof(shm_event_info),
        (unsigned)sizeof(shm_close_info), (unsigned)sizeof(shm_frame_info));
    return 0;
}
'''


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--clang", default="clang")
    args = parser.parse_args()
    compiler = shutil.which(args.clang)
    if not compiler:
        parser.error("clang is required for the four target syntax/layout checks")
    package = Path(__file__).resolve().parents[1]
    include = package / "native/draft"
    headers = [include / "share_hub_media_boundary.h", include / "share_hub_media_operations.h"]
    targets = ["arm64-apple-macos13.0", "x86_64-apple-macos13.0",
               "x86_64-pc-windows-msvc", "aarch64-pc-windows-msvc"]
    checks = []
    with tempfile.TemporaryDirectory(prefix="shm-abi-draft-") as directory:
        root = Path(directory)
        source = root / "check.c"
        source.write_text(CHECKS + SIGNATURES)
        for target in targets:
            for language, standard in [("c", "c11"), ("c++", "c++17")]:
                for definition in ["SHM_DRAFT_BUILD_SHARED", "SHM_DRAFT_USE_SHARED"]:
                    subprocess.run([compiler, "-target", target, "-x", language,
                                    f"-std={standard}", "-ffreestanding", "-fsyntax-only",
                                    "-Wall", "-Wextra", "-Werror", "-pedantic", f"-D{definition}",
                                    "-I", str(include), str(source)], check=True)
                    checks.append({"target": target, "language": standard, "definition": definition,
                                   "result": "syntax-and-layout-passed", "linked": False})
        host = root / "host.c"
        host.write_text(CHECKS + HOST)
        executable = root / "layout-probe"
        subprocess.run([compiler, "-std=c11", "-Wall", "-Wextra", "-Werror",
                        "-I", str(include), str(host), "-o", str(executable)], check=True)
        layout = json.loads(subprocess.run([str(executable)], text=True, capture_output=True,
                                          check=True, timeout=10).stdout)
    version = subprocess.run([compiler, "--version"], text=True, capture_output=True,
                             check=True).stdout.splitlines()[0]
    print(json.dumps({
        "draftRevision": 2,
        "headers": [{"path": header.relative_to(package).as_posix(),
                     "sha256": hashlib.sha256(header.read_bytes()).hexdigest()} for header in headers],
        "checkerSha256": hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),
        "compiler": version, "checks": checks,
        "host": {"system": platform.system(), "architecture": platform.machine(), "layout": layout},
        "sdkLoaded": False, "authorizationTested": False, "capturePerformed": False,
        "scope": "Unimplemented declaration/layout draft only; no target binary, provider or SDK behavior acceptance.",
    }, ensure_ascii=False, indent=2))


if __name__ == "__main__":
    main()
