#!/opt/homebrew/bin/python3.11
"""
Comprehensive unit tests for DriveBar Local Folder <-> Google Drive Sync Engine.
Covers:
1. Initial sync (both directions) & idempotent second run (0 copies)
2. 3-way conflict detection (local edit only, Drive edit only, simultaneous edit -> conflict copy)
3. Single-side deletion (local delete -> Drive trashed; Drive delete -> local trashed)
4. Empty/unmounted Drive target protection (0 deletions, status = error or needs_confirmation)
5. Mass-deletion ratio guard & user resolution (apply_deletions / restore_from_other)
6. File rename (delete old + add new without data loss)
7. Legacy migration from knownRelativeFiles & bare-array sync_pairs.json (never deletes on first run)
8. Concurrent single-writer command channel & sync loop (schemaVersion 2 integrity)
9. Ignored names (.DS_Store, ~$*, .git/, node_modules/, .drivebar_sync_tmp_*, .gdoc)
"""
from __future__ import annotations

import importlib.util
import json
import os
import shutil
import subprocess
import sys
import tempfile
import time
import unittest
from pathlib import Path
from typing import List


ENGINE_PATH = Path(__file__).resolve().parent.parent / "Resources" / "gdrive_folder_sync.py"
spec = importlib.util.spec_from_file_location("gdrive_folder_sync", str(ENGINE_PATH))
assert spec and spec.loader
sync_mod = importlib.util.module_from_spec(spec)
sys.modules["gdrive_folder_sync"] = sync_mod
spec.loader.exec_module(sync_mod)


class SyncEngineTestCase(unittest.TestCase):
    def setUp(self) -> None:
        self.tmp_root = tempfile.TemporaryDirectory(prefix="drivebar_sync_test_")
        self.root = Path(self.tmp_root.name)
        self.cfg_dir = self.root / "config"
        self.local_dir = self.root / "local"
        self.drive_dir = self.root / "drive"
        self.trash_dir = self.root / "trash"

        self.cfg_dir.mkdir(parents=True, exist_ok=True)
        self.local_dir.mkdir(parents=True, exist_ok=True)
        self.drive_dir.mkdir(parents=True, exist_ok=True)
        self.trash_dir.mkdir(parents=True, exist_ok=True)

        os.environ["DRIVEBAR_SYNC_CONFIG_DIR"] = str(self.cfg_dir)
        os.environ["DRIVEBAR_TEST_TRASH_DIR"] = str(self.trash_dir)
        self.trashed_paths: List[str] = []

        def fake_trash(path_str: str) -> bool:
            if not os.path.lexists(path_str):
                return False
            self.trashed_paths.append(path_str)
            dst = self.trash_dir / f"{len(self.trashed_paths)}_{ os.path.basename(path_str.rstrip('/')) }"
            shutil.move(path_str, dst)
            return True

        sync_mod.TRASH_HANDLER = fake_trash

    def tearDown(self) -> None:
        sync_mod.TRASH_HANDLER = None
        self.tmp_root.cleanup()

    def _write_file(self, base: Path, rel: str, content: str, mtime: float | None = None) -> Path:
        full = base / rel
        full.parent.mkdir(parents=True, exist_ok=True)
        full.write_text(content, encoding="utf-8")
        if mtime is not None:
            os.utime(full, (mtime, mtime))
        return full

    # ------------------------------------------------------------
    # 1. Initial sync both directions & idempotent second run
    # ------------------------------------------------------------
    def test_01_initial_sync_and_idempotency(self) -> None:
        self._write_file(self.local_dir, "a.txt", "from local", mtime=1700000000.0)
        self._write_file(self.local_dir, "sub/nested_local.txt", "nested local", mtime=1700000010.0)
        self._write_file(self.drive_dir, "b.txt", "from drive", mtime=1700000020.0)
        self._write_file(self.drive_dir, "sub2/nested_drive.txt", "nested drive", mtime=1700000030.0)

        rep1 = sync_mod.sync_single_pair(
            str(self.local_dir), str(self.drive_dir), pair_id="PAIR-INIT-1"
        )
        self.assertTrue(rep1["ok"])
        self.assertEqual(rep1["copiedToDrive"], 2)
        self.assertEqual(rep1["copiedToLocal"], 2)
        self.assertEqual(rep1["trashedCount"], 0)
        self.assertEqual(rep1["totalFiles"], 4)

        self.assertEqual((self.drive_dir / "a.txt").read_text(encoding="utf-8"), "from local")
        self.assertEqual((self.local_dir / "b.txt").read_text(encoding="utf-8"), "from drive")

        # Second run immediately after -> 0 copies, 0 trashed
        rep2 = sync_mod.sync_single_pair(
            str(self.local_dir), str(self.drive_dir), pair_id="PAIR-INIT-1"
        )
        self.assertTrue(rep2["ok"])
        self.assertEqual(rep2["copiedToDrive"], 0)
        self.assertEqual(rep2["copiedToLocal"], 0)
        self.assertEqual(rep2["trashedCount"], 0)

    # ------------------------------------------------------------
    # 2. Edit local only, Drive only, and both (3-way conflict)
    # ------------------------------------------------------------
    def test_02_three_way_edits_and_conflict_copy(self) -> None:
        t0 = 1700001000.0
        self._write_file(self.local_dir, "doc.txt", "v1", mtime=t0)
        sync_mod.sync_single_pair(str(self.local_dir), str(self.drive_dir), pair_id="PAIR-3WAY")

        # Edit local only -> propagates to Drive even if mtime is only +5s or even older than t0 with different size
        self._write_file(self.local_dir, "doc.txt", "v2 local edit", mtime=t0 + 10.0)
        rep_l = sync_mod.sync_single_pair(str(self.local_dir), str(self.drive_dir), pair_id="PAIR-3WAY")
        self.assertEqual(rep_l["copiedToDrive"], 1)
        self.assertEqual(rep_l["copiedToLocal"], 0)
        self.assertEqual((self.drive_dir / "doc.txt").read_text(encoding="utf-8"), "v2 local edit")

        # Edit Drive only -> propagates to local
        self._write_file(self.drive_dir, "doc.txt", "v3 drive edit longer", mtime=t0 + 25.0)
        rep_d = sync_mod.sync_single_pair(str(self.local_dir), str(self.drive_dir), pair_id="PAIR-3WAY")
        self.assertEqual(rep_d["copiedToLocal"], 1)
        self.assertEqual(rep_d["copiedToDrive"], 0)
        self.assertEqual((self.local_dir / "doc.txt").read_text(encoding="utf-8"), "v3 drive edit longer")

        # Edit BOTH sides since baseline -> conflict copy created on both sides, neither version lost!
        self._write_file(self.local_dir, "doc.txt", "v4 local older branch", mtime=t0 + 50.0)
        self._write_file(self.drive_dir, "doc.txt", "v4 drive newer winner", mtime=t0 + 90.0)
        rep_c = sync_mod.sync_single_pair(str(self.local_dir), str(self.drive_dir), pair_id="PAIR-3WAY")
        self.assertTrue(rep_c["ok"])
        self.assertEqual(len(rep_c["conflicts"]), 1)
        conflict_rel = rep_c["conflicts"][0]
        self.assertIn("(conflict ", conflict_rel)

        # Winner ("v4 drive newer winner") at original path on both sides
        self.assertEqual((self.local_dir / "doc.txt").read_text(encoding="utf-8"), "v4 drive newer winner")
        self.assertEqual((self.drive_dir / "doc.txt").read_text(encoding="utf-8"), "v4 drive newer winner")
        # Loser ("v4 local older branch") preserved at conflict_rel on both sides
        self.assertEqual((self.local_dir / conflict_rel).read_text(encoding="utf-8"), "v4 local older branch")
        self.assertEqual((self.drive_dir / conflict_rel).read_text(encoding="utf-8"), "v4 local older branch")

    # ------------------------------------------------------------
    # 3. Single-file deletion on local vs Drive
    # ------------------------------------------------------------
    def test_03_single_side_deletions_move_to_trash(self) -> None:
        t0 = 1700002000.0
        for i in range(5):
            self._write_file(self.local_dir, f"f{i}.txt", f"content {i}", mtime=t0)
        sync_mod.sync_single_pair(str(self.local_dir), str(self.drive_dir), pair_id="PAIR-DEL")

        # Delete f0.txt on local -> Drive copy moved to fake Trash
        (self.local_dir / "f0.txt").unlink()
        rep1 = sync_mod.sync_single_pair(str(self.local_dir), str(self.drive_dir), pair_id="PAIR-DEL")
        self.assertTrue(rep1["ok"])
        self.assertEqual(rep1["trashedCount"], 1)
        self.assertFalse((self.drive_dir / "f0.txt").exists())

        # Delete f1.txt on Drive -> local copy moved to fake Trash
        (self.drive_dir / "f1.txt").unlink()
        rep2 = sync_mod.sync_single_pair(str(self.local_dir), str(self.drive_dir), pair_id="PAIR-DEL")
        self.assertTrue(rep2["ok"])
        self.assertEqual(rep2["trashedCount"], 1)
        self.assertFalse((self.local_dir / "f1.txt").exists())
        self.assertEqual(len(self.trashed_paths), 2)

    # ------------------------------------------------------------
    # 4. Empty / unmounted Drive target protection
    # ------------------------------------------------------------
    def test_04_empty_or_unmounted_drive_aborts_without_deletions(self) -> None:
        t0 = 1700003000.0
        for i in range(6):
            self._write_file(self.local_dir, f"important_{i}.txt", "critical data", mtime=t0)
        sync_mod.sync_single_pair(str(self.local_dir), str(self.drive_dir), pair_id="PAIR-UNMOUNT")

        # Case A: Drive folder completely removed (unmounted)
        shutil.rmtree(self.drive_dir)
        rep_missing = sync_mod.sync_single_pair(
            str(self.local_dir), str(self.drive_dir), pair_id="PAIR-UNMOUNT"
        )
        self.assertFalse(rep_missing["ok"])
        self.assertEqual(rep_missing["status"], "error")
        self.assertEqual(len(self.trashed_paths), 0)
        self.assertEqual(len(list(self.local_dir.glob("important_*.txt"))), 6)

        # Case B: Drive folder exists as empty directory (0 files scanned while baseline > 0)
        self.drive_dir.mkdir(parents=True, exist_ok=True)
        rep_empty = sync_mod.sync_single_pair(
            str(self.local_dir), str(self.drive_dir), pair_id="PAIR-UNMOUNT"
        )
        self.assertFalse(rep_empty["ok"])
        self.assertEqual(rep_empty["status"], "needs_confirmation")
        self.assertEqual(len(self.trashed_paths), 0)
        self.assertEqual(len(list(self.local_dir.glob("important_*.txt"))), 6)

    # ------------------------------------------------------------
    # 5. Deletion ratio guard & confirmation resolution
    # ------------------------------------------------------------
    def test_05_mass_deletion_guard_and_resolution(self) -> None:
        t0 = 1700004000.0
        for i in range(30):
            self._write_file(self.local_dir, f"item_{i:02d}.txt", f"payload {i}", mtime=t0)
        sync_mod.sync_single_pair(str(self.local_dir), str(self.drive_dir), pair_id="PAIR-GUARD")

        # Delete 22 files on Drive (> max(20, 20% of 30 = 6)) -> trips guard!
        for i in range(22):
            (self.drive_dir / f"item_{i:02d}.txt").unlink()

        rep_trip = sync_mod.sync_single_pair(
            str(self.local_dir), str(self.drive_dir), pair_id="PAIR-GUARD"
        )
        self.assertFalse(rep_trip["ok"])
        self.assertEqual(rep_trip["status"], "needs_confirmation")
        self.assertIsNotNone(rep_trip["pendingDeletionPlan"])
        self.assertEqual(len(rep_trip["pendingDeletionPlan"]["localDeletes"]), 22)
        self.assertEqual(len(self.trashed_paths), 0)

        # Resolve with "restore_from_other" -> copies the 22 local files back to Drive
        rep_restore = sync_mod.sync_single_pair(
            str(self.local_dir),
            str(self.drive_dir),
            pair_id="PAIR-GUARD",
            resolution="restore_from_other",
        )
        self.assertTrue(rep_restore["ok"])
        self.assertEqual(rep_restore["status"], "ok")
        self.assertEqual(rep_restore["copiedToDrive"], 22)
        self.assertEqual(len(list(self.drive_dir.glob("item_*.txt"))), 30)

        # Now delete 22 files again and resolve with "apply_deletions"
        for i in range(22):
            (self.drive_dir / f"item_{i:02d}.txt").unlink()
        rep_apply = sync_mod.sync_single_pair(
            str(self.local_dir),
            str(self.drive_dir),
            pair_id="PAIR-GUARD",
            resolution="apply_deletions",
        )
        self.assertTrue(rep_apply["ok"])
        self.assertEqual(rep_apply["trashedCount"], 22)
        self.assertEqual(len(list(self.local_dir.glob("item_*.txt"))), 8)

    # ------------------------------------------------------------
    # 6. Rename = delete old + add new without data loss
    # ------------------------------------------------------------
    def test_06_rename_propagates_cleanly(self) -> None:
        t0 = 1700005000.0
        self._write_file(self.local_dir, "keep.txt", "stay", mtime=t0)
        self._write_file(self.local_dir, "old_name.txt", "renamed body", mtime=t0)
        sync_mod.sync_single_pair(str(self.local_dir), str(self.drive_dir), pair_id="PAIR-RENAME")

        (self.local_dir / "old_name.txt").rename(self.local_dir / "new_name.txt")
        rep = sync_mod.sync_single_pair(str(self.local_dir), str(self.drive_dir), pair_id="PAIR-RENAME")
        self.assertTrue(rep["ok"])
        self.assertEqual(rep["copiedToDrive"], 1)
        self.assertEqual(rep["trashedCount"], 1)
        self.assertFalse((self.drive_dir / "old_name.txt").exists())
        self.assertEqual((self.drive_dir / "new_name.txt").read_text(encoding="utf-8"), "renamed body")

    # ------------------------------------------------------------
    # 7. Migration from legacy knownRelativeFiles & bare-array sync_pairs.json
    # ------------------------------------------------------------
    def test_07_legacy_migration_never_deletes_on_first_run(self) -> None:
        t0 = 1700006000.0
        self._write_file(self.local_dir, "legacy_local_only.txt", "preserve me", mtime=t0)
        self._write_file(self.drive_dir, "legacy_drive_only.txt", "preserve drive too", mtime=t0)

        legacy_pairs = [
            {
                "id": "LEGACY-PAIR-1",
                "localPath": str(self.local_dir),
                "driveTargetPath": str(self.drive_dir),
                "syncMode": "two_way_mirror",
                "isEnabled": True,
                "createdAt": t0 - 100,
                "lastSyncedAt": t0 - 50,
                "knownRelativeFiles": ["legacy_local_only.txt", "legacy_drive_only.txt"],
            }
        ]
        (self.cfg_dir / "sync_pairs.json").write_text(json.dumps(legacy_pairs), encoding="utf-8")

        loaded = sync_mod.load_shared_pairs()
        self.assertEqual(len(loaded), 1)
        self.assertNotIn("knownRelativeFiles", loaded[0])

        # Verify sync_pairs.json upgraded to schemaVersion 2
        raw_saved = json.loads((self.cfg_dir / "sync_pairs.json").read_text(encoding="utf-8"))
        self.assertEqual(raw_saved.get("schemaVersion"), 2)

        # Run sync on migrated pair -> must NOT delete either file; must copy both so both sides match!
        rep = sync_mod.run_sync_all()
        self.assertTrue(rep["ok"])
        self.assertEqual(len(self.trashed_paths), 0)
        self.assertTrue((self.local_dir / "legacy_drive_only.txt").exists())
        self.assertTrue((self.drive_dir / "legacy_local_only.txt").exists())

    # ------------------------------------------------------------
    # 8. Concurrent command submissions + sync loop integrity
    # ------------------------------------------------------------
    def test_08_concurrent_command_channel_and_sync_loop(self) -> None:
        env = dict(os.environ)
        env["DRIVEBAR_SYNC_CONFIG_DIR"] = str(self.cfg_dir)
        env["DRIVEBAR_TEST_TRASH_DIR"] = str(self.trash_dir)

        total_pairs = 8
        for i in range(total_pairs):
            l_p = self.root / f"conc_local_{i}"
            d_p = self.root / f"conc_drive_{i}"
            l_p.mkdir(parents=True, exist_ok=True)
            d_p.mkdir(parents=True, exist_ok=True)
            (l_p / f"hello_{i}.txt").write_text(f"world {i}", encoding="utf-8")
            sync_mod.submit_command_file(
                op="add",
                pair_id=f"CONC-PAIR-{i}",
                payload={
                    "localPath": str(l_p),
                    "driveTargetPath": str(d_p),
                    "syncMode": "two_way_mirror",
                    "syncImmediately": True,
                },
                command_id=f"CMD-ADD-{i}",
            )

        # Spawn 2 concurrent "--process-commands" workers + 1 "--sync-all" worker
        procs = [
            subprocess.Popen(
                [sys.executable, str(ENGINE_PATH), "--process-commands"],
                env=env,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
            ),
            subprocess.Popen(
                [sys.executable, str(ENGINE_PATH), "--process-commands"],
                env=env,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
            ),
            subprocess.Popen(
                [sys.executable, str(ENGINE_PATH), "--sync-all"],
                env=env,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
            ),
        ]
        for p in procs:
            p.communicate(timeout=30)
            self.assertEqual(p.returncode, 0)

        # Ensure any remaining commands are processed
        sync_mod.process_pending_commands()

        raw_cfg = json.loads((self.cfg_dir / "sync_pairs.json").read_text(encoding="utf-8"))
        self.assertEqual(raw_cfg["schemaVersion"], 2)
        pair_ids = {p["id"] for p in raw_cfg["pairs"]}
        for i in range(total_pairs):
            self.assertIn(f"CONC-PAIR-{i}", pair_ids)
            res_file = self.cfg_dir / "results" / f"CMD-ADD-{i}.json"
            self.assertTrue(res_file.exists())

    # ------------------------------------------------------------
    # 9. Ignored names never synced
    # ------------------------------------------------------------
    def test_09_ignored_files_and_directories_never_synced(self) -> None:
        t0 = 1700007000.0
        self._write_file(self.local_dir, "valid.txt", "ok", mtime=t0)
        self._write_file(self.local_dir, ".DS_Store", "junk", mtime=t0)
        self._write_file(self.local_dir, "~$lock.docx", "word lock", mtime=t0)
        self._write_file(self.local_dir, ".drivebar_sync_tmp_1234", "temp", mtime=t0)
        self._write_file(self.local_dir, ".git/config", "git config", mtime=t0)
        self._write_file(self.local_dir, "node_modules/pkg/index.js", "js", mtime=t0)
        self._write_file(self.drive_dir, "Sheet.gsheet", "stub", mtime=t0)
        self._write_file(self.drive_dir, "Doc.gdoc", "stub", mtime=t0)

        rep = sync_mod.sync_single_pair(str(self.local_dir), str(self.drive_dir), pair_id="PAIR-IGNORE")
        self.assertTrue(rep["ok"])
        self.assertEqual(rep["copiedToDrive"], 1)
        self.assertEqual(rep["copiedToLocal"], 0)
        self.assertEqual(rep["trashedCount"], 0)

        self.assertTrue((self.drive_dir / "valid.txt").exists())
        self.assertFalse((self.drive_dir / ".DS_Store").exists())
        self.assertFalse((self.drive_dir / "~$lock.docx").exists())
        self.assertFalse((self.drive_dir / ".git").exists())
        self.assertFalse((self.drive_dir / "node_modules").exists())
        # Cloud stubs on Drive must neither copy to local nor get trashed on Drive
        self.assertFalse((self.local_dir / "Sheet.gsheet").exists())
        self.assertTrue((self.drive_dir / "Sheet.gsheet").exists())
        self.assertTrue((self.drive_dir / "Doc.gdoc").exists())


if __name__ == "__main__":
    unittest.main(verbosity=2)
