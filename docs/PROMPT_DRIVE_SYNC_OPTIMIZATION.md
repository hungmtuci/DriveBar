# Task: Harden & optimize DriveBar's Google Drive index and Folder Sync

You are working in the DriveBar repository (`~/Documents/antigravity/BuildApp/DriveBar`), a native macOS 14+ Swift app (SwiftUI + AppKit, SwiftPM, no Xcode project) plus a Python helper/daemon. Read this whole prompt before changing anything. Work phase by phase; each phase must build cleanly and be committed before the next starts.

## 0. Context you must understand first

Read these files fully before editing:

| File | Role |
|---|---|
| `Sources/DriveBar/Services/GoogleDriveIndexService.swift` (~3.6k lines) | Scans `~/Library/CloudStorage/GoogleDrive-*` (My Drive, Shared drives, `.shortcut-targets-by-id`) + custom Mac folders into in-memory indexes; FSEvents incremental updates; JSON caches in `~/.config/alfred-scripts/`; history/frecency |
| `Sources/DriveBar/Services/LocalFolderDriveSyncService.swift` (~1.7k lines) | Local folder ↔ Drive sync pairs (modes `two_way_mirror`, `symlink_to_drive`, `remote_shared_link`), FSEvents monitor, 6 s timer, native Swift sync engine fallback, Finder Quick Action installer |
| `Resources/gdrive_folder_sync.py` (~1.3k lines) | Python sync engine + daemon (`--daemon`), Drive REST API calls (share permissions, shared-link pull), Finder badges/tags, Quick Action entry points |
| `Sources/DriveBar/Services/SyncAndLatchingService.swift` | Syncthing (`~/Sync/`) cross-Mac sync of history/settings |
| `Sources/DriveBar/UI/FolderSyncDialogController.swift`, `UI/SettingsView.swift` (Drive & Sync tab), `UI/LauncherViewModel.swift` | UI consumers of the two services |
| `build_drivebar.sh` | The only supported build/package script |

Runtime state on disk (do NOT commit any of it):
- `~/.config/alfred-scripts/{folder,shared,file,mac_folders}_cache.json` — currently ~113 MB total. **`folder_cache.json` is also read by the external Alfred script `~/.config/alfred-scripts/folder_search.py`; its JSON schema must keep working.**
- `~/.config/drivebar-sync/` — `sync_pairs.json`, `last_sync_result.json`, `trigger.flag`, `daemon.pid`, `gdrive_oauth.json` (OAuth tokens — never read, print, log or commit its contents), installed copy of `gdrive_folder_sync.py`.

Measured symptoms (baseline to beat):
- Python daemon: 25 min CPU over 5 days while syncing only 2 pairs / 44 files.
- `remote_shared_link` pairs hit the Drive API (inspect + recursive list) every 8 s (~10k calls/day per pair).
- Cold start decodes ~113 MB JSON and keeps entries twice in RAM.
- A stale `mac_folders_cache.json.tmp.<pid>` (2.7 MB) proves concurrent cache writes collide.

## 1. Global rules

- macOS 14+, Swift 5.10 toolchain, Swift 6-style concurrency annotations already in use (`@MainActor`, `nonisolated`, `Sendable`). Build with **zero new warnings**.
- Python: stdlib only (python3.11 from Homebrew is typical, but must also run on `/usr/bin/python3` 3.9 — avoid 3.10+ only syntax in new code, or guard it). No new pip dependencies unless optional and import-guarded.
- All user-visible strings stay bilingual via `L("Tiếng Việt", "English")`. Code, comments, commit messages in English.
- Never delete user data permanently: deletions go to Trash (`trashItem` / existing `move_to_trash`). Never `rm -rf` user folders.
- Preserve existing on-disk formats or migrate them forward with versioning; an older app build must not crash on a newer file (ignore unknown keys).
- Do not change unrelated features (window switcher, clipboard, Markdown converter, etc.).
- Do not touch or print secrets. Do not commit `.app`, `dist/`, caches, or data files.
- After each phase: `./build_drivebar.sh` must succeed, then commit & push from the repo root with
  `~/Documents/antigravity/scripts/git-sync.sh "type(scope): summary"` and report the script's final line.

## 2. Target architecture (decisions already made — implement these, don't re-debate)

1. **Single sync engine = the Python helper**, run as a **LaunchAgent** (`~/Library/LaunchAgents/com.hunglx.DriveBar.syncd.plist`, `KeepAlive=true`, `RunAtLoad=true`, `ProcessType=Background`, logs to `~/Library/Logs/DriveBar/syncd.log` with rotation ~5 MB). Reason: Finder Quick Actions must work even when the app is not running. The app installs/updates the agent and the helper on launch (`launchctl bootstrap gui/$UID …` / `bootout` on uninstall), replacing the ad-hoc `Popen` + `daemon.pid` mechanism (keep reading `daemon.pid` only for migration, then remove it).
2. **The daemon is the sole writer of `sync_pairs.json`.** The Swift app and Quick Actions never write it directly; they submit commands. Command channel: atomic JSON files in `~/.config/drivebar-sync/commands/` named `<epoch_ms>-<uuid>.json` with `{ "v":1, "op":"add|update|remove|enable|disable|sync|sync_all|set_share", "pairId":..., "payload":{...} }`. The daemon processes them in name order, writes `results/<command-uuid>.json`, deletes the command. Swift waits for the result with a `DispatchSource` file-system watch on `results/` (no `Thread.sleep` polling), timeout 60 s, non-blocking for other pairs.
   - Additionally guard every read-modify-write of `sync_pairs.json` with `fcntl.flock` on `sync_pairs.lock` (defense in depth; Quick Action CLI invocations also run the engine).
   - Schema: add top-level wrapper `{ "schemaVersion": 2, "pairs": [...] }`; reader accepts the legacy bare array. Move `knownRelativeFiles` **out** of `sync_pairs.json` and out of UserDefaults into per-pair baseline files (see §3.2). Swift keeps an in-memory cache of pairs, refreshed by a file watch on `sync_pairs.json` — never decode JSON per call.
3. **Delete the native Swift sync engine** (`performSyncOnBackgroundQueue` fallback, `performSymlinkModeSync`, `scanDirectoryTree`, `copyFileAtomically`) after the daemon path is proven. If the helper/agent is unavailable, the UI shows a clear error with a "Repair sync service" button that reinstalls helper + agent; it does not silently sync with a second engine.
4. **Event-driven, not polling.** The Swift app watches both sides of every enabled `two_way_mirror` pair with FSEvents and sends `sync` commands with the affected `pairId` (debounced 1.5 s, coalesced per pair). The daemon itself: if `watchdog` is importable use it for the same purpose; otherwise rely on app triggers. Periodic safety-net full sync: every **300 s** per pair (configurable), not 8 s. Daemon main loop must block (wait on directory changes with `select`/`kqueue` on `commands/` via `select.kqueue` with `KQ_FILTER_VNODE`, or sleep ≥ 1 s) — no 250 ms busy polling.

## 3. Phase 1 — Data-safety (highest priority)

### 3.1 Mass-deletion guard (`gdrive_folder_sync.py` `sync_single_pair` ~L178–312; Swift twin at `LocalFolderDriveSyncService.swift` ~L1087–1120)
Today, if the Drive side scans empty (Drive for Desktop restarting/offline/not yet enumerated), every previously known file is treated as "deleted on Drive" and the local copies are trashed (and vice-versa).
Implement before any delete/trash:
- **Mount health check:** the pair's `GoogleDrive-<email>` root and `My Drive` must exist, be a directory, and be listable; the Drive target dir must exist. If the target dir is missing but was known before → treat as "Drive unavailable", abort the pair with `lastError`, do NOT recreate it empty and do NOT delete anything.
- **Deletion ratio guard:** compute planned trash operations per side first (plan → execute model). If planned deletions on one side > `max(20, 20% of baseline files)` or the scanned side has 0 files while the baseline has > 0 → abort, set `pair.status = "needs_confirmation"`, store the plan summary, notify the app (toast + Settings row with "Apply deletions" / "Restore from other side" buttons). The user's choice is sent as a command.
- Never delete when the counterpart file is dataless/unmaterialized-uncertain; only act on positive evidence.

### 3.2 Real three-way change detection & conflict copies
Replace "mtime ± 2 s, newer wins" with a baseline per pair stored at `~/.config/drivebar-sync/state/<pairId>.json` (atomic write): `{ "v":1, "syncedAt": <epoch>, "files": { "<rel>": { "size":…, "mtime":…, "localIno":…, "sha1": "<optional, only for files ≤ 64 MB when sizes match but mtimes differ>" } }, "dirs": [...] }`. Migrate from `knownRelativeFiles` (size/mtime unknown → first sync treats existing identical-size files as in sync, never deletes on the migration run).
Decision table per relative path (L = local now, D = drive now, B = baseline):
- L == B and D == B → nothing.
- L changed, D == B → copy L→D. D changed, L == B → copy D→L (skip if dataless; trigger download via existing `triggerOfflineDownload`-style materialization or leave for next run).
- Both changed and contents differ → **conflict**: keep the newer one at the original name, write the other as `<stem> (conflict <hostname> <yyyy-MM-dd HHmm>).<ext>` on both sides, record in result `conflicts: [...]`, show a toast.
- In B, missing on one side, unchanged on the other → propagate delete to Trash (subject to §3.1 guard).
- In B, missing on one side, changed on the other → resurrect (copy back), no delete.
- Not in B, exists on one side → copy over. Exists on both, not in B → if identical size(+hash) adopt, else conflict.
"Changed" = size differs or mtime differs by > 2 s (FAT/Drive rounding); use hash only to break ties when size equal.
Directories: create missing dirs; delete an empty dir only if it was in baseline and is gone on the other side.
`.gdoc/.gsheet/.gslides…` stubs: never copy to local, never delete, exclude from baseline.

### 3.3 Single writer for pair config
Implement §2.2 command channel and flock now (the safety part); the LaunchAgent migration can land in Phase 2. Remove `savePairs()` writes to `sync_pairs.json` from Swift; keep a UserDefaults copy only of the lightweight pair list for offline display (no file lists).

### 3.4 Quick Action robustness (`installSingleWorkflow` ~L1561)
- Resolve python at runtime in the shell script: first existing of `/opt/homebrew/bin/python3`, `/usr/local/bin/python3`, `/usr/bin/python3`.
- Always refresh the installed helper when the bundled one is newer: compare a `HELPER_VERSION = "x.y.z"` constant (add it to the .py) — the app does this on launch (copy atomically, chmod 755); the shell script also copies when the bundled version string differs.
- Quote all paths; handle multiple selected folders and names with spaces/Vietnamese NFC/NFD.

### 3.5 Cheap correctness fixes in the index (do in Phase 1)
- `writeCodableAtomic` (~L1738): replace tmp+replaceItemAt dance with a single `data.write(to:options:.atomic)`; per-target serial queue so writes to the same file never overlap; debounce (2.5 s) **shared** and **mac folders** persists like the folder one (each with its own task handle). Delete stale `*.tmp.*` siblings on startup.
- `recallPreviouslyUsedItems` (~L2024): `fastFileIndex.records.contains { $0.entry.path == itemKey }` is O(200k) per candidate per keystroke → add `pathSet: Set<String>` to `FastFileIndex` and use it.
- `LocalFolderDriveSyncService.mappedDrivePath(forLocalPath:)` (~L333) decodes JSON on every call → serve from a thread-safe in-memory snapshot (e.g. `OSAllocatedUnfairLock`-guarded array of `(localStd, driveStd)` updated on pair changes).

**Phase 1 acceptance:** unit-style test script (see §6) proves: Drive-empty scenario deletes nothing; both-sides-edit produces a conflict copy; delete on one side propagates to Trash; concurrent add-pair from app while daemon is syncing never loses the new pair. Build passes. Commit `fix(sync): mass-delete guard, 3-way conflict detection, single-writer config`.

## 4. Phase 2 — Performance

### 4.1 Sync engine
- Event-driven per §2.4; safety-net every 300 s; per-pair, not "sync all" on every trigger.
- `remote_shared_link`: first sync as today, then poll at most every **15 min** (configurable 5–60). Use `files.get(fields=modifiedTime,…)` on the root plus a stored `startPageToken`/`changes.list` when the user has access, otherwise compare a stored map `{fileId: modifiedTime,size}` and only descend into folders whose `modifiedTime` changed. Exponential backoff on 403/429/5xx; mark broken only on 403/404 for the root, as today.
- Fix O(dirs × files) prefix checks (`any(k.startswith(prefix) for k in prev_known)` py ~L247, Swift ~L1043): precompute a set of all ancestor dirs of baseline files once.
- Drop the third full re-scan for totals; compute totals from the in-memory result of the plan execution.
- `scan_tree`: use `os.scandir` recursion (uses cached d_type, avoids extra `lstat` for dirs), skip ignored dirs early.
- Swift: remove `Thread.sleep` loop (~L885); FSEvents callback off the main queue (dedicated utility queue), then hop to MainActor only to update published state.
- Watch **both** `localPath` and `driveTargetPath` (today only Drive side, ~L1340). Ignore events caused by the engine itself using the `.drivebar_sync_tmp_` prefix plus a per-pair "engine running" flag published by the daemon in `status/<pairId>.json`, instead of the 2.2 s timestamp heuristic.

### 4.2 Index rebuild (`rebuildFolderCacheInBackground` ~L1404, `rebuildSharedCacheInBackground` ~L1493, `rebuildFileCacheInBackground` ~L1616)
- **Single pass over My Drive / Shared drives** that produces folders *and* files (today My Drive is walked twice).
- Use `opendir/readdir` + `d_type` like `scanMacFolderSubtreePOSIX`; only `lstat` on `DT_UNKNOWN`. No `FileManager.fileExists` per entry.
- Carry the parent's precomputed `(cleanSegs, acrSegs)` down the stack; compute `extractSignatures` once per name (today every ancestor segment is recomputed for every descendant).
- Parallelize: one `TaskGroup` child per top-level folder of each root, bounded to `ProcessInfo.activeProcessorCount` (max 6) to avoid hammering FileProvider; merge and sort once.
- Progress updates throttled to ≤ 4/s.
- Target: ≥ 3× faster full rebuild on the current dataset; report before/after timings (log `os_signpost` or simple `ContinuousClock` measurements to the console).

### 4.3 Incremental FSEvents updates (`processPendingFSEvents` ~L430–589)
- Race: overlapping detached tasks each start from the same snapshot and the last writer wins. Make processing **serial** (a dedicated actor `DriveIndexMutator` or a serial task chain) with a generation counter; never drop events while a full rebuild runs — queue them and replay after the rebuild finishes.
- Mutate in place: keep `[String: Int]` path→index maps or a sorted array with binary-search insertion; deletes by prefix use a sorted-range removal, not `Dictionary.filter` over 90k entries per event.
- Rebuild only the affected Fast index (or apply delta to it) instead of full `FastFolderIndex.build`.
- Bound subtree rescans for Shared drives (`walkSharedTree` on a top-level event is unbounded today): cap depth and item count like the My Drive path, and fall back to scheduling a background full shared rebuild if the cap is hit.

### 4.4 Search hot path
- `evaluate*SearchHits`: replace full sort with bounded top-K (min-heap of `maxResults`).
- Incremental refinement: if the new query has the previous query as prefix (same mode), search only the previous candidate set (keep up to ~5k candidate indices).
- Keep search synchronous only if p95 < 4 ms on the 90k folder index; otherwise move to a detached task with the existing `searchGeneration` guard. Measure and report.

**Phase 2 acceptance:** daemon idle CPU ≈ 0% (`ps -o %cpu` < 0.5 averaged over 5 min with no file changes); remote link API calls ≤ 4/hour/pair when unchanged; local edit → Drive copy within ≤ 3 s; full index rebuild timing reported and improved ≥ 3×; no regressions in search ranking (spot-check queries `sdh`, Vietnamese unaccented queries, acronyms). Commit `perf(sync,index): event-driven sync engine, single-pass parallel indexer`.

## 5. Phase 3 — Architecture & footprint

### 5.1 LaunchAgent + engine consolidation
Finish §2.1 and §2.3: install/upgrade/repair agent from the app, remove the Swift sync engine and `daemon.pid` path, Settings → "Google Drive & Đồng bộ" shows agent status (running/pid/version/last error) with Restart and Repair buttons.

### 5.2 Compact index cache
- New binary cache `~/.config/alfred-scripts/drivebar_index_v1.bin` (or one file per index kind): header `magic "DBIX"`, `u32 version`, `u32 count`, root path table, then per record length-prefixed UTF-8 relative path + precomputed clean/acronym byte segments. Load with `Data(contentsOf:options:.alwaysMapped)` and build Fast indexes directly from bytes — **do not** materialize `DriveFolderEntry` arrays in RAM; Fast index becomes the single source of truth (expose path/children APIs from it).
- Keep writing `folder_cache.json` in the **existing schema** for `folder_search.py` (Alfred) compatibility, but at background priority and debounced (≥ 30 s), behind a Settings toggle "Giữ tương thích cache Alfred / Keep Alfred cache compatible" (default ON). `shared_cache.json` / `file_cache.json` become read-only migration sources: read once if the binary cache is missing, then stop writing them (unless the toggle requires them — check `folder_search.py` for which files it reads and keep exactly those).
- Targets: cold-start index load < 400 ms for current data; resident memory for indexes reduced ≥ 40%. Report measurements.

### 5.3 Token storage (optional, if time permits)
Move OAuth refresh tokens from `gdrive_oauth.json` to the macOS Keychain (service `com.hunglx.DriveBar.gdrive`), with the Python helper reading via `/usr/bin/security find-generic-password -w`. Migrate once, then delete the plaintext file only after a successful Keychain read-back. Never log token values.

**Phase 3 acceptance:** fresh install and upgrade from current version both work; Quick Actions work with the app quit; Alfred `folder_search.py` still returns results; README "Google Drive & Đồng bộ" section updated. Commit `refactor(sync): launchd sync agent, binary index cache`.

## 6. Testing requirements

Create `Tests/sync_engine_test.py` (stdlib `unittest`, temp dirs only — never touch real Drive or `~/.config/drivebar-sync`; make config dir overridable via env `DRIVEBAR_SYNC_CONFIG_DIR`). Cover at least:
1. Initial sync both directions; idempotent second run (0 copies).
2. Edit local only / Drive only / both (conflict copy created, both versions preserved).
3. Delete local → Drive copy goes to (fake) Trash; delete Drive → local to Trash.
4. Drive target emptied/unmounted → zero deletions, status `needs_confirmation` or error.
5. Deletion ratio guard trips at threshold.
6. Rename = delete + add without data loss.
7. Migration from legacy `knownRelativeFiles` + bare-array `sync_pairs.json`.
8. Concurrency: spawn two processes issuing commands + one sync loop; final `sync_pairs.json` contains every added pair, valid JSON.
9. Ignored names (`.DS_Store`, `~$*`, `.git/`, `node_modules/`, `.drivebar_sync_tmp_*`) never synced.
Make `move_to_trash` injectable for tests.

For Swift, if adding a test target is too invasive for the SwiftPM layout, add a debug-only benchmark entry (`DriveBar --bench-index`) that times full rebuild, cache load, and 20 sample queries, printing a table.

Manual verification checklist to run and report:
- Pair in `~/Documents/antigravity/...` syncs both ways; Finder badge/tag still applied.
- Quit Drive for Desktop during sync → nothing deleted, clear error shown; relaunch → recovers.
- `symlink_to_drive` and `remote_shared_link` modes still work.
- Real-time index: create/rename/delete a folder in My Drive → searchable/removed within ~2 s.

## 7. Deliverables

1. Code changes per phase, each phase a separate commit pushed via `git-sync.sh` (report final line).
2. `docs/SYNC_ARCHITECTURE.md` (English): components, command channel protocol, state/baseline file schemas, decision table, safety guards, LaunchAgent lifecycle, cache formats.
3. A short results report: before/after numbers (daemon CPU, API calls/hour, index rebuild time, cold-start load time, memory), tests run and their output, any item you could not complete and why.

If something in this spec conflicts with what you find in the code (e.g. `folder_search.py` reads more files than assumed, or a TCC restriction blocks the LaunchAgent from reading `~/Documents`), stop and document the conflict with a proposed alternative instead of guessing. In particular, verify whether a LaunchAgent-run Python can access `~/Documents` under TCC; if not, the fallback design is: the DriveBar app (which already has the user's grant) hosts the engine loop by spawning the helper as its child process, and Quick Actions submit commands that the app processes when running, plus run the CLI engine directly when the app is not running (with the same flock).
