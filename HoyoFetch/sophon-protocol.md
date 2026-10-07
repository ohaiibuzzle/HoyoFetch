# miHoYo / HoYoverse "Sophon" download scheme

Implementation spec for writing a Sophon-compatible game downloader.

**Provenance.** Everything here was read from the open-source Collapse Launcher reimplementation, not from HoYoPlay's own binary, and cross-checked against live API responses on 2026-10-06.

| Source | Commit | Date |
|---|---|---|
| [CollapseLauncher/Hi3Helper.Sophon](https://github.com/CollapseLauncher/Hi3Helper.Sophon) (the protocol library) | `ed3344ea` | 2026-10-04 |
| [CollapseLauncher/Collapse](https://github.com/CollapseLauncher/Collapse) (the orchestration) | `59b1586f` | 2026-10-01 |

Statements are tagged where it matters:

- **[code]** read from the source above (file named in brackets).
- **[live]** observed in a real API response.
- **[unverified]** not confirmed; treat as an assumption and check it first.

---

## 1. Overview

Sophon is a content-addressed chunk store.

- Every game file is split into chunks.
- Each chunk is one object on a CDN, zstd-compressed, named by its hash.
- A zstd-compressed **protobuf manifest** lists every file and, per file, which chunk goes at which offset.
- A build is split into several manifests ("categories"), selected by a string called `matching_field`: base game, each voice language, optional content packs.

A downloader does: discovery API → pick manifests → fetch and parse manifests → fetch chunks → write at offsets → verify.

Updates have two mechanisms (section 6): reuse unchanged chunks from the installed files, or apply binary patches (HDiffPatch) from a separate "patch build".

---

## 2. Discovery APIs

All responses share the envelope `{ "retcode": int, "message": string, "data": {...} | null }`. `data == null` means failure; read `retcode` and `message`.

### 2.1 `getGameBranches`

```
GET https://sg-hyp-api.hoyoverse.com/hyp/hyp-connect/api/getGameBranches?launcher_id=VYTpXlbWo8
```

`VYTpXlbWo8` is the global HoYoPlay launcher ID **[live]**. The China launcher uses a different host and ID **[unverified]**.

Response, per game **[live]**:

```json
{
  "game": { "id": "U5hbdsT9W7", "biz": "nap_global" },
  "main": {
    "package_id": "qsoIbfMm4x",
    "branch": "main",
    "password": "lh0OmNjbhG9x",
    "tag": "3.2.0",
    "diff_tags": ["3.1.0", "3.0.0"],
    "categories": [ ... ],
    "required_client_version": "1.16.1.364"
  },
  "pre_download": null,
  "enable_base_pkg_predownload": true
}
```

- `biz` values seen: `nap_global` (ZZZ), `hkrpg_global` (Star Rail), `hk4e_global` (Genshin), `bh3_global` (Honkai Impact 3rd, several entries).
- `main` is the live version. `pre_download` is non-null only during a preload window, with the same shape.
- `tag` is the version string. `diff_tags` are the versions a patch build exists for.
- `package_id`, `password` and `branch` are the query parameters for the next calls. They can change between versions, so fetch them every run. Collapse does exactly this ("re-association") **[code: `PresetConfig.cs`, `SophonChunkUrls.EnsureReassociated`]**.

### 2.2 `getBuild` (full build)

```
GET https://sg-public-api.hoyoverse.com/downloader/sophon_chunk/api/getBuild
    ?branch=main|predownload
    &package_id=<package_id>
    &password=<password>
    &tag=<version>
```

- `branch` is `main` or `predownload` **[code]**.
- `tag` selects a specific version. Collapse appends it to request the *old* version's manifest during updates **[code: `InstallManagerBase.Sophon.cs`]**. Whether arbitrary old tags stay available is **[unverified]**.
- Some URLs in the library's test config also carry `plat_app=<id>`; the live request above worked without it **[live]**.

Response `data` **[live]**:

```json
{
  "build_id": "o4wTxTXmevvH",
  "tag": "3.2.0",
  "manifests": [
    {
      "category_id": "10037",
      "category_name": "游戏资源-外网",
      "matching_field": "game",
      "manifest": {
        "id": "manifest_9aaa2c8ad88af8a7_0d35fc0ac9d4ce16353cca1a2ea56e4b",
        "checksum": "0d35fc0ac9d4ce16353cca1a2ea56e4b",
        "compressed_size": "4862327",
        "uncompressed_size": "9525014"
      },
      "manifest_download": {
        "encryption": 0, "password": "", "compression": 1,
        "url_prefix": "https://autopatchos.zenlesszonezero.com/pclauncher/manifests/cxi9qfgtcu0w/20260822/3.2.0/s7BqLj43eJ52",
        "url_suffix": ""
      },
      "chunk_download": {
        "encryption": 0, "password": "", "compression": 1,
        "url_prefix": "https://autopatchos.zenlesszonezero.com/pclauncher/chunks/cxi9qfgtcu0w/20260822/3.2.0/s7BqLj43eJ52",
        "url_suffix": ""
      },
      "stats":              { "compressed_size": "60642059824", "uncompressed_size": "61915564404", "file_count": "10692", "chunk_count": "58382" },
      "deduplicated_stats": { "compressed_size": "60347143084", "uncompressed_size": "61608890594", "file_count": "10692", "chunk_count": "58086" }
    }
  ]
}
```

Parsing notes:

- **Numbers arrive as strings** (`"4862327"`). Accept both string and number.
- `compression` / `encryption` are `0`/`1` integers; accept booleans too (the library uses a tolerant converter) **[code: `SophonInfosJson.cs`]**.
- `encryption`, `password` and `url_suffix` are parsed but never used by the library, and are `0` / `""` live. If you ever see `encryption: 1`, stop and report it; nothing here covers it **[unverified]**.

### 2.3 `matching_field`

| Value | Meaning |
|---|---|
| `game` | Base game. Default when nothing is specified **[code]**. |
| `en-us`, `ja-jp`, `zh-cn`, `ko-kr`, `zh-tw` | Voice packs **[code]**. |
| anything else (ZZZ: `10101`, `200001`, `300002`, …) | Optional content packs: story chapters, event scenes, lip-sync data **[live]**. `category_name` is a Chinese label. |

Collapse's install logic: always `game`, plus the voice languages the user picked, plus (after asking) the additional packs **[code]**. A minimal downloader should take the list of matching fields as input and default to `game` plus one voice language.

### 2.4 `getPatchBuild` (patch build)

```
POST https://sg-public-api.hoyoverse.com/downloader/sophon_chunk/api/getPatchBuild
     ?branch=main|predownload&package_id=<package_id>&password=<password>
```

It is a `POST` with the parameters in the query string and no body **[code: `SophonPatchBranch.cs`]**. I could not issue a POST from my sandbox, so the shape below is from the library's JSON model, not a live capture.

`data` **[code: `SophonInfosJson.cs`]**:

```json
{
  "build_id": "...", "tag": "<target version>", "patch_id": "...",
  "manifests": [
    {
      "category_id": "...", "category_name": "...", "matching_field": "game",
      "manifest":          { "id": "...", "checksum": "...", "compressed_size": "...", "uncompressed_size": "..." },
      "manifest_download": { "url_prefix": "...", "compression": 1, ... },
      "diff_download":     { "url_prefix": "...", "compression": ..., ... },
      "stats": {
        "3.1.0": { "compressed_size": "...", "uncompressed_size": "...", "file_count": "...", "chunk_count": "..." },
        "3.0.0": { ... }
      }
    }
  ]
}
```

`stats` is a map keyed by **source version**. If your installed version is not a key, no patch exists for it; fall back to method A in section 6.

---

## 3. Manifest format

### 3.1 Fetching

```
GET {manifest_download.url_prefix}/{manifest.id}
```

Trim a trailing `/` from the prefix first. If `manifest_download.compression` is set, the body is one zstd stream. Decompress, then parse as protobuf **[code: `Extension.cs`, `ReadProtoFromManifestInfo`]**.

### 3.2 Integrity

- `manifest.id` has the form `manifest_<16 hex>_<32 hex>`.
- The 16-hex part is the **XXH64 of the file as downloaded** (still compressed). The library validates its on-disk cache this way **[code: `TryReadFromCached`]**.
- The hex is the hash in canonical big-endian byte order: compare against the digest bytes as written by a standard XXH64 implementation, not a little-endian integer dump **[code: `CheckChunkXxh64HashAsync` compares `HexToBytes(name)` with `XxHash64.GetHashAndReset()`]**.
- The 32-hex part equals `manifest.checksum` (MD5) **[live]**. Which bytes that MD5 covers (compressed or decompressed) is **[unverified]**; the library never checks it. Use the XXH64.

### 3.3 Schema (full build)

**[code: `Protos/SophonManifestProto.proto`]**

```proto
syntax = "proto3";

message SophonManifestProto {
  repeated SophonManifestAssetProperty Assets = 1;
}

message SophonManifestAssetProperty {
  string AssetName    = 1;   // relative path, forward or back slashes
  repeated SophonManifestAssetChunk AssetChunks = 2;
  int32  AssetType    = 3;   // 0 = file
  int64  AssetSize    = 4;   // final file size
  string AssetHashMd5 = 5;   // MD5 of the whole file, hex
}

message SophonManifestAssetChunk {
  string ChunkName                = 1;  // CDN object name
  string ChunkDecompressedHashMd5 = 2;  // MD5 of the decompressed chunk, hex
  int64  ChunkOnFileOffset        = 3;  // where it goes in the file
  int64  ChunkSize                = 4;  // compressed size (bytes on the wire)
  int64  ChunkSizeDecompressed    = 5;  // size after zstd
}
```

Rules:

- **Directory entry:** `AssetType != 0` **or** empty `AssetHashMd5`. Create the directory, no chunks **[code: `SophonManifest.cs`, `AssetProperty2SophonAsset`]**.
- **Chunk name:** `<16 hex>_<32 hex>`. The 16-hex prefix is the XXH64 of the **compressed** chunk as stored on the CDN **[code: `SophonAsset.Diff.cs` hashes the saved raw file against it]**.
- Chunks of one file are non-overlapping and cover `[0, AssetSize)`. Do not assume they are sorted, or that all are the same size.
- **Chunk size:** ZZZ averages about 1.06 MB decompressed (61.9 GB / 58,382 chunks) **[live]**. Whether chunking is fixed-size or content-defined is **[unverified]**. Never hard-code a size; use the manifest values.
- **Path safety:** `AssetName` comes from the network. Normalise separators and reject absolute paths and any `..` component before joining it to the install directory.

---

## 4. Chunk download

```
GET {chunk_download.url_prefix}/{ChunkName}
```

If `chunk_download.compression` is set, the body is one zstd frame of `ChunkSize` bytes that decompresses to exactly `ChunkSizeDecompressed` bytes. No auth headers, no range requests needed; chunks are plain static objects.

Per-chunk algorithm **[code: `SophonAsset.Download.cs`, `PerformWriteStreamThreadAsync` / `InnerWriteStreamToAsync`]**:

1. **Skip check (this is the resume mechanism).** If the output file's length ≥ `ChunkOnFileOffset + ChunkSizeDecompressed`, MD5 that region of the file. If it equals `ChunkDecompressedHashMd5`, the chunk is already done.
2. `GET` the chunk, stream through a zstd decoder.
3. Seek to `ChunkOnFileOffset`, write the decompressed bytes while feeding an MD5.
4. If fewer than `ChunkSizeDecompressed` bytes come out, treat as corrupt.
5. Compare the MD5 with `ChunkDecompressedHashMd5`. On mismatch, re-download.
6. Errors: retry up to 10 times with a 1 s delay; 20 s inactivity timeout, reset after every successful read **[code: `TaskExtensions.cs`]**.

File-level behaviour:

- If an existing output file is longer than `AssetSize`, truncate it to `AssetSize` first.
- Collapse writes to `<path>_tempSophon` and renames to the final path when the file completes, so a half-written file never sits under the real name **[code: `InstallManagerBase.Sophon.cs`]**.
- The library never checks `AssetHashMd5` after writing; it relies on per-chunk MD5s. A final whole-file MD5 pass is a cheap extra.

Concurrency in Collapse **[code]**:

- Files in parallel: `sqrt(logical CPUs)`, clamped to 2–64.
- Chunks per file in parallel: half of that, clamped to 2–32.
- HTTP connection limit: at least `2 × sqrt(logical CPUs)`, clamped to 4–128.
- Each chunk writer opens its own handle on the same file with shared read/write access.

Before starting, sum the sizes and check free disk space.

---

## 5. Fresh install procedure

1. `getGameBranches` → find the game by `biz` → take `main` (`package_id`, `password`, `tag`).
2. `getBuild` with those values.
3. Select `manifests[]` entries by `matching_field`.
4. For each selected entry: fetch and parse the manifest (section 3).
5. Create directories; download every file's chunks (section 4).
6. Rename temp files into place.
7. Record the installed version and the selected matching fields. You need both for updates.

---

## 6. Updates

Collapse tries method B first and falls back to method A if no patch URL or no patch for the installed version exists **[code: `InstallManagerBase.SophonPatch.cs`]**.

### 6.A Chunk reuse (old manifest vs new manifest)

**[code: `SophonUpdate.cs`, `SophonAsset.Update.cs`]**

Inputs: `getBuild` for the installed version (`&tag=<old>`) and for the target version, same matching field.

1. Parse both manifests.
2. For each file in the **new** manifest:
   - Not in the old manifest (match by `AssetName`, case-insensitive), or a directory → treat as a fresh download.
   - Otherwise build a map of the **old file's** chunks keyed by `ChunkDecompressedHashMd5`. For each new chunk, if its MD5 is in the map, record `oldOffset` = that old chunk's `ChunkOnFileOffset`.
3. Reuse is **per file only**: a chunk is matched against the same file's previous version, never against other files.
4. Download size = sum of new chunks with no `oldOffset`.

Applying one file:

- If the target already exists with length == `AssetSize`, the per-chunk skip check from section 4 handles it.
- Write into `<path>_tempUpdate`. For each new chunk, pick the source in this order:
  1. **Old file:** if `oldOffset` is set and the old file is at least `oldOffset + ChunkSizeDecompressed` long, copy that range.
  2. **Preloaded chunk:** a file in the staging directory (see below) with length == `ChunkSize`; zstd-decompress it.
  3. **CDN:** download as in section 4. If the new build's chunk URL fails, the library retries the same chunk name under the **old** build's `url_prefix`.
- In every case MD5-verify the written bytes against `ChunkDecompressedHashMd5`; on mismatch, fall back to the CDN.
- When done, replace the original file with the temp file.
- Files present in the old manifest but absent from the new one should be deleted. Collapse does this in a separate cleanup step.

Pre-download (staging chunks before release day) **[code: `SophonAsset.Diff.cs`]**:

- Download only chunks with no `oldOffset`, **without decompressing**, into a staging directory (Collapse: `<game>/chunk_collapse/`).
- Staging filename = hex of `XXH128(UTF-8("<AssetName>$<AssetHashMd5>$<ChunkName>"))`. This is Collapse's own convention, not part of the protocol; any unique name works for your own tool.
- Verify each staged chunk by XXH64 of the raw file against the 16-hex prefix of `ChunkName`, then drop a `<name>.verified` marker so it is not re-hashed next run.

### 6.B Patch build (HDiffPatch)

**[code: `SophonPatch.cs`, `SophonPatchAsset.Download.cs`, `SophonPatchAsset.Update.cs`]**

Inputs: `getPatchBuild` (section 2.4), plus `getBuild` for the target version (still needed as the list of target files and as the fallback).

Patch manifest: fetched and decompressed exactly like a normal manifest, different schema **[code: `Protos/SophonPatchProto.proto`]**:

```proto
syntax = "proto3";

message SophonPatchProto {
  repeated SophonPatchAssetProperty  PatchAssets  = 1;
  repeated SophonUnusedAssetProperty UnusedAssets = 2;
}

message SophonPatchAssetProperty {
  string AssetName    = 1;   // target file path
  int64  AssetSize    = 2;
  string AssetHashMd5 = 3;
  repeated SophonPatchAssetInfo AssetInfos = 4;   // one per source version
}

message SophonPatchAssetInfo {
  string VersionTag           = 1;   // source version this patch applies to
  SophonPatchAssetChunk Chunk = 2;
}

message SophonPatchAssetChunk {
  string PatchName          = 1;   // CDN object name of the patch blob
  string VersionTag         = 2;
  string BuildId            = 3;
  int64  PatchSize          = 4;   // size of the whole blob
  string PatchMd5           = 5;
  int64  PatchOffset        = 6;   // this file's slice inside the blob
  int64  PatchLength        = 7;
  string OriginalFileName   = 8;   // empty => slice is the complete new file
  int64  OriginalFileLength = 9;
  string OriginalFileMd5    = 10;
}

message SophonUnusedAssetProperty {
  string VersionTag = 1;
  repeated SophonUnusedAssetInfo AssetInfos = 2;
}
message SophonUnusedAssetInfo { repeated SophonUnusedAssetFile Assets = 1; }
message SophonUnusedAssetFile {
  string FileName = 1;
  int64  FileSize = 2;
  string FileMd5  = 3;
}
```

Planning: for each **file** in the target build's normal manifest, look up `PatchAssets` by `AssetName` (case-insensitive) and pick the `AssetInfos` entry whose `VersionTag` equals the installed version. That gives one of four methods:

| Method | Condition | Action |
|---|---|---|
| `DownloadOver` | No patch entry for this file and version | Normal chunk download (section 4). |
| `CopyOver` | Entry exists, `OriginalFileName` empty | The blob slice is the new file; copy it out. |
| `Patch` | Entry exists, `OriginalFileName` set | Apply the slice as an HDiffPatch diff to `OriginalFileName`. |
| `Remove` | File listed under `UnusedAssets` and not a target of any other entry | Delete it. |

Patch blobs:

```
GET {diff_download.url_prefix}/{PatchName}
```

- One blob holds many files' patches; each file uses `[PatchOffset, PatchOffset + PatchLength)`. Download each distinct `PatchName` once.
- The library saves the response body as-is, with **no zstd step** **[code: `InnerWriteChunkCopyAsync`]**. Expected length is `PatchSize`.
- Verify the blob: if `PatchName` has the `<16 hex>_<...>` shape, XXH64 of the file against the prefix; otherwise MD5 against `PatchMd5`.
- Collapse stores blobs in `<game>/ldiff/`, the same folder HoYoPlay uses, and will reuse blobs already there (also checks `chunk_collapse/`) **[code: `GetLegacyOrHoyoPlayPatchChunkPath`]**.

Applying, per file:

1. **Already done?** If the target exists with the right size and hash, skip.
2. **Check the source.** For `Patch`, the original file must exist, have length `OriginalFileLength`, and hash to `OriginalFileMd5`. If not, delete it and downgrade this file to `DownloadOver`.
3. **`CopyOver`:** copy the slice to the target. Quirk: if the slice starts with the ASCII magic `HDIFF`, it is actually a diff against an **empty file**; the library creates an empty `<target>.diff_ref`, patches against that, then removes it.
4. **`Patch`:** run HDiffPatch with old = original file, diff = the slice, output = a temp file, then move it over the target. Format is [sisong/HDiffPatch](https://github.com/sisong/HDiffPatch); the library uses the `SharpHPatchZ` package. The diff may be internally compressed, which the HDiffPatch format handles itself.
5. **Verify** the result against the target size and hash. Hash strings may be 16 hex (XXH64) or 32 hex (MD5); choose by length.
6. On any failure, downgrade to `DownloadOver` and retry.
7. After everything succeeds, perform the `Remove` entries and delete the patch blobs.

Hash-type note: every "check by hash" in the patch path switches on digest length, 8 bytes → XXH64, otherwise MD5 **[code]**. Build your verifier the same way.

---

## 7. Edge cases checklist

- JSON numbers as strings; flags as `0`/`1`.
- `data: null` with a non-zero `retcode` when a branch or tag does not exist.
- `pre_download: null` outside preload windows.
- Requested `matching_field` missing from `manifests[]` (voice pack not offered for that game).
- Installed version missing from `diff_tags` / patch `stats` → method A, or a full verify-and-download.
- Zero-length files: a file entry with no chunks. The library throws on these in its download call **[code: `EnsureOrThrowChunksState`]**; create an empty file instead.
- The same chunk appearing in several files (`deduplicated_stats` < `stats` **[live]**). A chunk cache keyed by `ChunkName` avoids repeat downloads; the library does not bother.
- Case-insensitive path matching between manifests (Windows origin). On Linux, pick one canonical casing from the new manifest.
- Path traversal in `AssetName`, `OriginalFileName`, `FileName`.
- Interrupted runs: the skip check in section 4 makes re-running safe; keep temp-file suffixes stable so resume finds them.

## 8. Suggested dependencies

| Need | Notes |
|---|---|
| protobuf | Compile the two `.proto` blocks above as-is. |
| zstd | Streaming decoder. |
| XXH64 | Canonical big-endian digest output. XXH128 only if you copy Collapse's staging names. |
| MD5 | Chunk and file verification. |
| HDiffPatch | Only for method 6.B. Upstream `hpatchz` CLI/library, or a port. Method 6.A needs none. |

A reasonable build order: discovery + manifest dump → fresh install → verify/repair (re-run with skip checks) → update method A → update method B.

## 9. Not verified

- Chunking algorithm and whether chunk boundaries are stable across versions (method A's effectiveness depends on it).
- A real `getPatchBuild` response and a real patch manifest.
- What `manifest.checksum` (MD5) is computed over.
- Behaviour when `encryption: 1`.
- China-region hosts and launcher ID.
- HoYoPlay's own client behaviour (threads, temp names, cleanup), beyond the `ldiff/` folder name that Collapse mirrors.

Start by dumping one real manifest and checking sections 3 and 4 against it before building on the rest.

## 10. Sources

Code (at the commits in the table above):

- [Hi3Helper.Sophon repository](https://github.com/CollapseLauncher/Hi3Helper.Sophon)
  - [`Protos/SophonManifestProto.proto`](https://github.com/CollapseLauncher/Hi3Helper.Sophon/blob/main/Protos/SophonManifestProto.proto), [`Protos/SophonPatchProto.proto`](https://github.com/CollapseLauncher/Hi3Helper.Sophon/blob/main/Protos/SophonPatchProto.proto): manifest schemas
  - [`Structs/SophonInfosJson.cs`](https://github.com/CollapseLauncher/Hi3Helper.Sophon/blob/main/Structs/SophonInfosJson.cs): API JSON model
  - [`Structs/SophonChunksBranch.cs`](https://github.com/CollapseLauncher/Hi3Helper.Sophon/blob/main/Structs/SophonChunksBranch.cs), [`Structs/SophonPatchBranch.cs`](https://github.com/CollapseLauncher/Hi3Helper.Sophon/blob/main/Structs/SophonPatchBranch.cs): `getBuild` (GET) and `getPatchBuild` (POST) handling
  - [`SophonManifest.cs`](https://github.com/CollapseLauncher/Hi3Helper.Sophon/blob/main/SophonManifest.cs): manifest enumeration, directory rule
  - [`SophonAsset.Download.cs`](https://github.com/CollapseLauncher/Hi3Helper.Sophon/blob/main/SophonAsset.Download.cs): chunk download, skip check, retries
  - [`SophonUpdate.cs`](https://github.com/CollapseLauncher/Hi3Helper.Sophon/blob/main/SophonUpdate.cs), [`SophonAsset.Update.cs`](https://github.com/CollapseLauncher/Hi3Helper.Sophon/blob/main/SophonAsset.Update.cs), [`SophonAsset.Diff.cs`](https://github.com/CollapseLauncher/Hi3Helper.Sophon/blob/main/SophonAsset.Diff.cs): update method A and preload staging
  - [`SophonPatch.cs`](https://github.com/CollapseLauncher/Hi3Helper.Sophon/blob/main/SophonPatch.cs), [`SophonPatchAsset.Download.cs`](https://github.com/CollapseLauncher/Hi3Helper.Sophon/blob/main/SophonPatchAsset.Download.cs), [`SophonPatchAsset.Update.cs`](https://github.com/CollapseLauncher/Hi3Helper.Sophon/blob/main/SophonPatchAsset.Update.cs): update method B
  - [`Helper/Extension.cs`](https://github.com/CollapseLauncher/Hi3Helper.Sophon/blob/main/Helper/Extension.cs): URL construction, hash checks, manifest cache, staging names
  - [`Helper/TaskExtensions.cs`](https://github.com/CollapseLauncher/Hi3Helper.Sophon/blob/main/Helper/TaskExtensions.cs): timeout and retry constants
- [Collapse repository](https://github.com/CollapseLauncher/Collapse)
  - [`InstallManagerBase.Sophon.cs`](https://github.com/CollapseLauncher/Collapse/blob/main/CollapseLauncher/Classes/InstallManagement/Base/InstallManagerBase.Sophon.cs): install, update A, preload, thread counts
  - [`InstallManagerBase.SophonPatch.cs`](https://github.com/CollapseLauncher/Collapse/blob/main/CollapseLauncher/Classes/InstallManagement/Base/InstallManagerBase.SophonPatch.cs): update B orchestration, `ldiff` directory
  - [`Helper/Metadata/PresetConfig.cs`](https://github.com/CollapseLauncher/Collapse/blob/main/CollapseLauncher/Classes/Helper/Metadata/PresetConfig.cs): branch → URL re-association

Live API responses (2026-10-06):

- [getGameBranches, global launcher](https://sg-hyp-api.hoyoverse.com/hyp/hyp-connect/api/getGameBranches?launcher_id=VYTpXlbWo8)
- [getBuild, ZZZ 3.2.0](https://sg-public-api.hoyoverse.com/downloader/sophon_chunk/api/getBuild?branch=main&package_id=qsoIbfMm4x&password=lh0OmNjbhG9x&tag=3.2.0)

Related:

- [HDiffPatch](https://github.com/sisong/HDiffPatch): the binary diff format used by patch builds
