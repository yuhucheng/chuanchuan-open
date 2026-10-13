# Versioned function-table discovery — review draft

`share_hub_media_api_table.h` adds the optional bootstrap `shm_draft_get_api` for
non-Flutter callers. Table version **1** describes the existing **draft boundary
revision 2**. These are different identities; neither is stable ABI major 1. Old
candidates may lack the bootstrap symbol: report unavailable discovery rather than
reinterpreting structs, fabricating pointers or claiming stable compatibility.

Query takes the expected boundary revision, minimum table version and caller's
writable output capacity. It creates no core, registers no provider, enumerates
no source and authenticates nothing. Supported targets have 8-byte pointers;
the 24-byte descriptor precedes 57 function pointers, with v1 total size 480.
The descriptor reports available bytes, table version, boundary revision, pointer
bytes, written bytes and zero reserved storage. Existing structs still require
exact draft-2 size/revision; existing handle, thread, cancellation, lease and
shutdown rules in [README.md](README.md) and [MEDIA.md](MEDIA.md) remain unchanged.

| Query result | Output |
| --- | --- |
| Null buffer | INVALID_ARGUMENT; no write |
| Capacity over 16 KiB | LIMIT; no write |
| Less than 24 bytes | Provided bytes zeroed; BUFFER_TOO_SMALL; no descriptor |
| Revision mismatch or unsupported minimum version | Descriptor only; INCOMPATIBLE_ABI; pointer area zeroed |
| Matching revision/version but less than 480 bytes | Descriptor only; BUFFER_TOO_SMALL; pointer area zeroed |
| Matching identities and v1 capacity | OK; 57 typed entries, written bytes 480; extra caller tail zeroed |

Do not read descriptor fields unless the output includes the complete descriptor.
Do not use pointer slots on an error, infer fields beyond `written_bytes` or read
beyond caller capacity. Missing functions remain explicit unavailable capability.
Pointers are callable entry points, not a media support promise: query a real
core's capabilities/limits and perform authenticated admission before allocation.
A Windows/authority library can expose these entry points while advertising no
remote media. The table does not grant an authorization or bypass provider sealing.

Example lifecycle (the library must already be validated and loaded):

```c
shm_draft_api_table api;
shm_status status = shm_draft_get_api(2, 1, sizeof(api), &api);
if (status != SHM_OK) { /* report explicit interface incompatibility */ }
/* Only after OK: api.create(...), api.seal_providers(...), api.capabilities(...).
 * Stop/close drain real owners; release leases/core before unloading the library.
 */
```

Version-1 slot offsets and signatures stay fixed within this draft table.
A future table version can append entries; it cannot silently reorder or alter
existing calls. The bootstrap must preserve older accepted table prefixes, copy
only complete pointer slots and report the actual written prefix. A caller needing
new entries requests their minimum table version and sufficient capacity. Struct
extension/versioning is separate and is not supplied by a larger table buffer.
Before formal ABI freezing, review the stable major/minor entry policy, struct
extensions, complete platform implementation and actual runtime acceptance.

Current checks cover four compiler-target layouts and actual non-Flutter Mac
binary discovery/lifecycle, including short buffers, mismatch gating and larger
zeroed tails. They do not provide Windows/Intel hardware, OS capture, GPU interop,
real device pairing/media, signing, stable ABI or release acceptance. Current Dart
factory/legacy draft calls keep their existing entry path.
