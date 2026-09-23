# Windows receive-store API probe

Disposable, standalone native design evidence, not the production ReceiveStore.
Run `powershell -File windows/tests/receive_store_probe/run.ps1` from the client checkout.
The probe uses its own random directory under the OS temp directory and removes
only objects created by the probe. No elevation, Downloads changes, app-channel
integration, network access, or changes to the existing native-test CMake project.

The tests exercise real filesystem calls. Filesystem/build details and exact
Win32 error codes are printed, so a result on one local NTFS volume must not be
extrapolated to exFAT, removable drives, network shares, or another Windows build.
No test represents an end-to-end transfer, actual system sleep, disk exhaustion,
crash durability, or a dual-device acceptance test.

The strongest tested variant keeps the random temporary file directly in the
authorized directory, retains directory handles without write/delete sharing,
and calls native `NtSetInformationFile(FileRenameInformation)` with
`ReplaceIfExists = FALSE`, `RootDirectory = NULL`, and a validated single leaf
name. This native form renames within the source handle's current parent.

The probe also records an API difference on the tested host: the Win32
`SetFileInformationByHandle(FileRenameInfo)` wrapper rejects a non-null directory
handle plus relative leaf with error 87. Direct native directory-relative rename
works but requires directory write sharing; it remains a comparison experiment,
not the preferred strict-lock design. Build outputs live under ignored `build/`.
