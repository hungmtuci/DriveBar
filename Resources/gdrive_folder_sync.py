#!/opt/homebrew/bin/python3.11
from __future__ import annotations
"""
DriveBar Local Folder <-> Google Drive Sync Engine & LaunchAgent Daemon.
Provides:
- Real 3-way change detection with per-pair baseline state (`state/<pairId>.json`)
- Mass-deletion guard & Drive mount health verification
- Conflict copy generation (`<stem> (conflict <host> <yyyy-MM-dd HHmm>).<ext>`)
- Single-writer `sync_pairs.json` (schemaVersion 2) guarded by `fcntl.flock`
- Atomic file-based command channel (`commands/<epoch_ms>-<uuid>.json` -> `results/<uuid>.json`)
- Event-driven kqueue daemon loop with 300s safety-net interval and 15m shared-link polling
"""
import argparse
import datetime
import fcntl
import hashlib
import json
import logging
from logging.handlers import RotatingFileHandler
import os
import select
import shutil
import socket
import stat
import subprocess
import sys
import time
import unicodedata
import urllib.error
import urllib.parse
import urllib.request
import uuid
from contextlib import contextmanager
from pathlib import Path
from typing import Any, Callable, Dict, List, Optional, Set, Tuple

HELPER_VERSION = "2.0.1"

FINDER_TAG_NAME = "Đồng bộ GDrive\n2"  # Green tag (2) in macOS Finder

IGNORED_DIRS: Set[str] = {
    ".git", "node_modules", "__pycache__", ".build", ".swiftpm",
    ".venv", "venv", ".pytest_cache", ".mypy_cache", ".next",
    ".nuxt", ".tmp.driveupload", ".tmp", ".Trash",
}

IGNORED_FILES: Set[str] = {
    ".DS_Store", ".localized", "Icon\r",
}

CLOUD_STUB_EXTS: Set[str] = {
    ".gdoc", ".gsheet", ".gslides", ".gform", ".gdraw", ".gmap", ".gsite", ".gscript",
}

SF_DATALESS = 0x40000000
MAX_HASH_SIZE_BYTES = 64 * 1024 * 1024  # 64 MB
DEFAULT_MATERIALIZE_MAX_BYTES = 512 * 1024 * 1024  # 512 MB
DEFAULT_MATERIALIZE_TIMEOUT_SEC = 60.0
DEFAULT_MATERIALIZE_BUDGET_SEC = 300.0

# Injectable handlers for unit tests
TRASH_HANDLER: Optional[Callable[[str], bool]] = None
DATALESS_DETECTOR: Optional[Callable[[str, os.stat_result, bool], bool]] = None
MATERIALIZE_HANDLER: Optional[Callable[[str, float], bool]] = None


# ============================================================
# DYNAMIC CONFIGURATION PATHS (OVERRIDABLE FOR TESTS)
# ============================================================
def get_config_dir() -> Path:
    override = os.environ.get("DRIVEBAR_SYNC_CONFIG_DIR", "").strip()
    if override:
        return Path(os.path.abspath(os.path.expanduser(override)))
    return Path.home() / ".config" / "drivebar-sync"


def pairs_json_path() -> Path:
    return get_config_dir() / "sync_pairs.json"


def pairs_lock_path() -> Path:
    return get_config_dir() / "sync_pairs.lock"


def status_json_path() -> Path:
    return get_config_dir() / "last_sync_result.json"


def trigger_flag_path() -> Path:
    return get_config_dir() / "trigger.flag"


def daemon_pid_path() -> Path:
    return get_config_dir() / "daemon.pid"


def state_dir_path() -> Path:
    return get_config_dir() / "state"


def commands_dir_path() -> Path:
    return get_config_dir() / "commands"


def results_dir_path() -> Path:
    return get_config_dir() / "results"


def pair_status_dir_path() -> Path:
    return get_config_dir() / "status"


def remote_cache_dir_path() -> Path:
    return get_config_dir() / "remote_cache"


def setup_logger() -> logging.Logger:
    logger = logging.getLogger("drivebar.syncd")
    if logger.handlers:
        return logger
    logger.setLevel(logging.INFO)
    log_dir = Path.home() / "Library" / "Logs" / "DriveBar"
    try:
        log_dir.mkdir(parents=True, exist_ok=True)
        handler = RotatingFileHandler(
            log_dir / "syncd.log", maxBytes=5 * 1024 * 1024, backupCount=2, encoding="utf-8"
        )
        fmt = logging.Formatter("%(asctime)s [%(levelname)s] %(message)s")
        handler.setFormatter(fmt)
        logger.addHandler(handler)
    except Exception:
        logger.addHandler(logging.NullHandler())
    return logger


LOGGER = setup_logger()


# ============================================================
# ATOMIC JSON & FILE LOCKING HELPERS
# ============================================================
def write_json_atomic(target_path: Path, payload: Any, indent: Optional[int] = 2, mode: int = 0o644) -> None:
    target_path.parent.mkdir(parents=True, exist_ok=True)
    tmp_path = target_path.parent / f".{target_path.name}.tmp.{os.getpid()}.{uuid.uuid4().hex[:8]}"
    fd: Optional[int] = None
    try:
        data = json.dumps(payload, indent=indent, ensure_ascii=False).encode("utf-8")
        fd = os.open(str(tmp_path), os.O_WRONLY | os.O_CREAT | os.O_EXCL, mode)
        os.fchmod(fd, mode)
        view = memoryview(data)
        total_written = 0
        while total_written < len(view):
            written = os.write(fd, view[total_written:])
            if written <= 0:
                raise OSError("short write in write_json_atomic")
            total_written += written
        os.fsync(fd)
        os.close(fd)
        fd = None
        os.replace(tmp_path, target_path)
        os.chmod(target_path, mode)
    except Exception:
        if fd is not None:
            try:
                os.close(fd)
            except OSError:
                pass
        if tmp_path.exists():
            try:
                tmp_path.unlink()
            except OSError:
                pass
        raise


def enforce_secret_file_permissions() -> None:
    cfg = get_config_dir()
    if not cfg.exists():
        return
    targets: List[Path] = [
        cfg / "gdrive_oauth.json",
        cfg / "sync_pairs.json",
    ]
    for sub_name in ("state", "results", "commands"):
        sub_dir = cfg / sub_name
        if sub_dir.is_dir():
            try:
                for entry in sub_dir.iterdir():
                    if entry.is_file() and entry.name.endswith(".json"):
                        targets.append(entry)
            except OSError:
                pass
    for p in targets:
        if p.exists():
            try:
                cur_mode = stat.S_IMODE(p.stat().st_mode)
                if cur_mode != 0o600:
                    os.chmod(p, 0o600)
            except OSError:
                pass


@contextmanager
def locked_pairs_file():
    cfg_dir = get_config_dir()
    cfg_dir.mkdir(parents=True, exist_ok=True)
    lock_file = pairs_lock_path()
    fd = os.open(str(lock_file), os.O_CREAT | os.O_RDWR, 0o600)
    try:
        fcntl.flock(fd, fcntl.LOCK_EX)
        yield
    finally:
        try:
            fcntl.flock(fd, fcntl.LOCK_UN)
        finally:
            os.close(fd)


def normalize_rel_path(rel_path: str) -> str:
    norm = unicodedata.normalize("NFC", rel_path.replace("\\", "/"))
    return norm.lstrip("/")


def normalize_abs_path(path_str: str) -> str:
    if not path_str:
        return ""
    expanded = os.path.expanduser(path_str)
    # Do not resolve final symlink if the path itself is a symlink in symlink_to_drive mode
    parent = os.path.dirname(expanded)
    base = os.path.basename(expanded)
    if parent and os.path.exists(parent):
        return unicodedata.normalize("NFC", os.path.join(os.path.abspath(parent), base))
    return unicodedata.normalize("NFC", os.path.abspath(expanded))


# ============================================================
# BASELINE STATE MANAGEMENT (`state/<pairId>.json`)
# ============================================================
def baseline_file_path(pair_id: str) -> Path:
    clean_id = (pair_id or "default").upper()
    return state_dir_path() / f"{clean_id}.json"


def load_pair_baseline(pair_id: str, legacy_known_files: Optional[List[str]] = None) -> Dict[str, Any]:
    b_path = baseline_file_path(pair_id)
    if b_path.exists():
        try:
            data = json.loads(b_path.read_text(encoding="utf-8"))
            if isinstance(data, dict) and "files" in data:
                norm_files: Dict[str, Dict[str, Any]] = {}
                for k, v in data.get("files", {}).items():
                    if isinstance(v, dict):
                        norm_files[normalize_rel_path(k)] = v
                data["files"] = norm_files
                data["dirs"] = [normalize_rel_path(d) for d in data.get("dirs", []) if d]
                return data
        except Exception:
            pass

    if legacy_known_files:
        migrated_files: Dict[str, Dict[str, Any]] = {}
        for rel in legacy_known_files:
            n_rel = normalize_rel_path(rel)
            if n_rel:
                migrated_files[n_rel] = {
                    "size": -1,
                    "mtime": -1.0,
                    "localIno": 0,
                    "migrated": True,
                }
        return {
            "v": 1,
            "syncedAt": 0.0,
            "files": migrated_files,
            "dirs": [],
            "migratedFromLegacy": True,
        }

    return {"v": 1, "syncedAt": 0.0, "files": {}, "dirs": []}


def save_pair_baseline(
    pair_id: str,
    files_map: Dict[str, Dict[str, Any]],
    dirs_list: List[str],
    synced_at: float,
) -> None:
    if not pair_id:
        return
    payload = {
        "v": 1,
        "syncedAt": synced_at,
        "files": files_map,
        "dirs": sorted(set(dirs_list)),
    }
    write_json_atomic(baseline_file_path(pair_id), payload, indent=None, mode=0o600)


def remove_pair_baseline(pair_id: str) -> None:
    if not pair_id:
        return
    b_path = baseline_file_path(pair_id)
    if b_path.exists():
        try:
            b_path.unlink()
        except OSError:
            pass


def set_pair_running_flag(pair_id: str, running: bool) -> None:
    if not pair_id:
        return
    st_dir = pair_status_dir_path()
    st_file = st_dir / f"{pair_id.upper()}.json"
    try:
        if running:
            write_json_atomic(
                st_file,
                {"pairId": pair_id.upper(), "running": True, "pid": os.getpid(), "startedAt": time.time()},
                indent=None,
                mode=0o600,
            )
        else:
            if st_file.exists():
                st_file.unlink()
    except Exception:
        pass


# ============================================================
# PAIRS CONFIG STORAGE (`sync_pairs.json` v2 + Legacy Migration)
# ============================================================
def _decode_raw_pairs_unlocked() -> Tuple[List[Dict[str, Any]], bool]:
    p_path = pairs_json_path()
    if not p_path.exists():
        return [], False
    try:
        raw = json.loads(p_path.read_text(encoding="utf-8"))
    except Exception:
        return [], False

    needs_migration_save = False
    if isinstance(raw, list):
        pairs = [p for p in raw if isinstance(p, dict)]
        needs_migration_save = True
    elif isinstance(raw, dict):
        pairs = [p for p in raw.get("pairs", []) if isinstance(p, dict)]
        if raw.get("schemaVersion") != 2:
            needs_migration_save = True
    else:
        return [], False

    for p in pairs:
        pid = str(p.get("id") or "").upper()
        if not pid:
            pid = str(uuid.uuid4()).upper()
            p["id"] = pid
            needs_migration_save = True
        else:
            p["id"] = pid

        legacy_known = p.get("knownRelativeFiles")
        if isinstance(legacy_known, list) and len(legacy_known) > 0:
            b_path = baseline_file_path(pid)
            if not b_path.exists():
                migrated = load_pair_baseline(pid, legacy_known)
                save_pair_baseline(
                    pid,
                    migrated.get("files", {}),
                    migrated.get("dirs", []),
                    float(p.get("lastSyncedAt") or 0.0),
                )
            p.pop("knownRelativeFiles", None)
            needs_migration_save = True
        elif "knownRelativeFiles" in p:
            p.pop("knownRelativeFiles", None)
            needs_migration_save = True

        if "status" not in p:
            p["status"] = "broken_link" if p.get("isRemoteLinkBroken") else ("error" if p.get("lastError") else "ok")

    return pairs, needs_migration_save


def _write_pairs_unlocked(pairs: List[Dict[str, Any]]) -> None:
    cleaned: List[Dict[str, Any]] = []
    for p in pairs:
        copy_p = dict(p)
        copy_p.pop("knownRelativeFiles", None)
        cleaned.append(copy_p)
    payload = {
        "schemaVersion": 2,
        "updatedAt": time.time(),
        "pairs": cleaned,
    }
    write_json_atomic(pairs_json_path(), payload, indent=2, mode=0o600)


def load_shared_pairs() -> List[Dict[str, Any]]:
    with locked_pairs_file():
        pairs, needs_save = _decode_raw_pairs_unlocked()
        if needs_save:
            try:
                _write_pairs_unlocked(pairs)
            except Exception:
                pass
        return pairs


def save_shared_pairs(pairs: List[Dict[str, Any]]) -> None:
    with locked_pairs_file():
        _write_pairs_unlocked(pairs)


def mutate_shared_pairs(mutator: Callable[[List[Dict[str, Any]]], Any]) -> Any:
    with locked_pairs_file():
        pairs, _ = _decode_raw_pairs_unlocked()
        result = mutator(pairs)
        _write_pairs_unlocked(pairs)
        return result


# ============================================================
# PATH & FINDER HELPERS
# ============================================================
def find_my_drive_root() -> str:
    cloud_storage = Path.home() / "Library" / "CloudStorage"
    if cloud_storage.exists():
        for entry in sorted(cloud_storage.iterdir()):
            if entry.name.startswith("GoogleDrive-"):
                my_drive = entry / "My Drive"
                if my_drive.exists():
                    return str(my_drive)
    return str(cloud_storage / "GoogleDrive" / "My Drive")


def suggested_drive_target(local_path: str, base_subfolder: str = "00. Antigravity_Sync") -> str:
    std_local = normalize_abs_path(local_path)
    my_drive = find_my_drive_root()
    base_root = os.path.join(my_drive, base_subfolder.strip()) if base_subfolder.strip() else my_drive

    antigravity_root = normalize_abs_path("~/Documents/antigravity")
    if std_local.startswith(antigravity_root + os.sep):
        rel = std_local[len(antigravity_root) + 1:]
        if rel:
            return os.path.join(base_root, rel)

    folder_name = os.path.basename(std_local)
    return os.path.join(base_root, folder_name)


def set_finder_badge(folder_path: str, state: str) -> None:
    """state: 'synced' | 'broken' | 'clear'"""
    if not folder_path or not os.path.exists(folder_path):
        return
    badge_helper = get_config_dir() / "folder_badge_helper"
    flag = "--set" if state == "synced" else ("--broken" if state == "broken" else "--clear")
    if badge_helper.exists() and os.access(badge_helper, os.X_OK):
        try:
            subprocess.run(
                [str(badge_helper), flag, folder_path],
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
                timeout=5,
            )
            return
        except Exception:
            pass


def set_finder_tag(folder_path: str, enabled: bool) -> None:
    set_finder_badge(folder_path, "synced" if enabled else "clear")


def move_to_trash(path: str) -> bool:
    if TRASH_HANDLER is not None:
        return TRASH_HANDLER(path)
    if not os.path.lexists(path):
        return False
    trash_dir = os.environ.get("DRIVEBAR_TEST_TRASH_DIR", "").strip()
    if not trash_dir:
        trash_dir = os.path.expanduser("~/.Trash")
    os.makedirs(trash_dir, exist_ok=True)
    base = os.path.basename(path.rstrip("/"))
    dst = os.path.join(trash_dir, f"{base}_{int(time.time())}_{uuid.uuid4().hex[:6]}")
    try:
        shutil.move(path, dst)
        return True
    except Exception as exc:
        LOGGER.warning("Failed to move %s to Trash (%s): %s", path, dst, exc)
        return False


def is_ignored_name(name: str, is_dir: bool = False) -> bool:
    if not name:
        return True
    if is_dir:
        return name in IGNORED_DIRS or name.startswith(".tmp") or name.startswith(".drivebar_sync_tmp_")
    return (
        name in IGNORED_FILES
        or name in IGNORED_DIRS
        or name.startswith("~$")
        or name.startswith(".~")
        or name.startswith(".tmp")
        or name.startswith(".drivebar_sync_tmp_")
    )


def _is_path_dataless(full_path: str, st: os.stat_result, is_cloud: bool) -> bool:
    if DATALESS_DETECTOR is not None:
        return bool(DATALESS_DETECTOR(full_path, st, is_cloud))
    return bool(is_cloud and hasattr(st, "st_flags") and (st.st_flags & SF_DATALESS))


def materialize_dataless(
    path: str,
    timeout: float = DEFAULT_MATERIALIZE_TIMEOUT_SEC,
    max_bytes: Optional[int] = None,
) -> bool:
    """
    Requests materialization (download) of a FileProvider dataless file by reading it in chunks
    with a per-file timeout and size cap, then re-lstat'ing to verify it is no longer dataless.
    """
    cap = (
        max_bytes
        if max_bytes is not None
        else int(os.environ.get("DRIVEBAR_MATERIALIZE_MAX_BYTES", str(DEFAULT_MATERIALIZE_MAX_BYTES)))
    )
    try:
        st_init = os.lstat(path)
    except OSError:
        return False

    if st_init.st_size > cap:
        LOGGER.warning("Skipping materialization of %s (%d bytes > cap %d)", path, st_init.st_size, cap)
        return False

    if MATERIALIZE_HANDLER is not None:
        try:
            ok = bool(MATERIALIZE_HANDLER(path, timeout))
            if not ok:
                return False
            st_after = os.lstat(path)
            return not _is_path_dataless(path, st_after, True)
        except Exception:
            return False

    deadline = time.monotonic() + max(0.1, float(timeout))
    try:
        with open(path, "rb") as f:
            while True:
                if time.monotonic() > deadline:
                    return False
                chunk = f.read(262144)
                if not chunk:
                    break
        st_after = os.lstat(path)
        return not _is_path_dataless(path, st_after, True)
    except Exception as exc:
        LOGGER.warning("Failed to materialize dataless file %s: %s", path, exc)
        return False


def scan_tree(root_path: str, is_cloud: bool) -> Tuple[Set[str], Dict[str, Dict[str, Any]]]:
    dirs: Set[str] = set()
    files: Dict[str, Dict[str, Any]] = {}
    if not os.path.exists(root_path):
        return dirs, files

    root_abs = os.path.abspath(root_path)
    stack: List[str] = [root_abs]

    while stack:
        cur_dir = stack.pop()
        try:
            scandir_it = os.scandir(cur_dir)
        except OSError:
            continue

        with scandir_it as entries:
            for entry in entries:
                name = entry.name
                try:
                    if entry.is_symlink():
                        continue
                    is_dir = entry.is_dir(follow_symlinks=False)
                except OSError:
                    continue

                if is_ignored_name(name, is_dir=is_dir):
                    continue

                full_path = entry.path
                rel_raw = os.path.relpath(full_path, root_abs)
                rel_norm = normalize_rel_path(rel_raw)

                if is_dir:
                    if rel_norm and rel_norm != ".":
                        dirs.add(rel_norm)
                    stack.append(full_path)
                else:
                    try:
                        st = entry.stat(follow_symlinks=False)
                    except OSError:
                        continue
                    if not stat.S_ISREG(st.st_mode):
                        continue
                    ext = os.path.splitext(name)[1].lower()
                    if ext in CLOUD_STUB_EXTS:
                        # Exclude Google Docs/Sheets/Slides cloud stubs from baseline & sync
                        continue
                    is_dataless = _is_path_dataless(full_path, st, is_cloud)
                    files[rel_norm] = {
                        "mtime": float(st.st_mtime),
                        "size": int(st.st_size),
                        "ino": int(st.st_ino),
                        "is_dataless": is_dataless,
                        "is_stub": False,
                        "real_rel": rel_raw,
                    }

    return dirs, files


def compute_file_sha1(path: str) -> Optional[str]:
    try:
        st = os.stat(path)
        if st.st_size > MAX_HASH_SIZE_BYTES:
            return None
        h = hashlib.sha1()
        with open(path, "rb") as f:
            while True:
                chunk = f.read(65536)
                if not chunk:
                    break
                h.update(chunk)
        return h.hexdigest()
    except Exception:
        return None


def copy_atomic(src: str, dst: str, mtime: float) -> bool:
    dst_parent = os.path.dirname(dst)
    os.makedirs(dst_parent, exist_ok=True)
    tmp_dst = os.path.join(dst_parent, f".drivebar_sync_tmp_{uuid.uuid4().hex}")
    try:
        shutil.copy2(src, tmp_dst)
        os.utime(tmp_dst, (mtime, mtime))
        os.replace(tmp_dst, dst)
        os.utime(dst, (mtime, mtime))
        return True
    except Exception:
        if os.path.exists(tmp_dst):
            try:
                os.remove(tmp_dst)
            except OSError:
                pass
        return False


def format_conflict_rel_path(rel_path: str, ts: Optional[float] = None) -> str:
    host = socket.gethostname().split(".")[0] or "Mac"
    dt = datetime.datetime.fromtimestamp(ts or time.time()).strftime("%Y-%m-%d %H%M")
    parent = os.path.dirname(rel_path)
    fname = os.path.basename(rel_path)
    stem, ext = os.path.splitext(fname)
    conflict_name = f"{stem} (conflict {host} {dt}){ext}"
    return os.path.join(parent, conflict_name) if parent else conflict_name


def check_mount_health(local_path: str, drive_target_path: str, has_prior_baseline: bool) -> Optional[str]:
    """
    Verifies that Google Drive mount and previously synced directories are healthy and mounted
    before any sync/delete operations take place.
    """
    # 1. If drive_target_path is inside ~/Library/CloudStorage/GoogleDrive-*, verify mount root
    marker = "/Library/CloudStorage/GoogleDrive-"
    if marker in drive_target_path:
        idx = drive_target_path.find(marker)
        rest = drive_target_path[idx + len("/Library/CloudStorage/"):]
        parts = rest.split(os.sep)
        account_dir = os.path.join(drive_target_path[:idx], "Library", "CloudStorage", parts[0])
        if not os.path.isdir(account_dir):
            return f"Google Drive mount unavailable: {account_dir}"
        try:
            acc_entries = os.listdir(account_dir)
            if not acc_entries:
                return f"Google Drive mount is empty/unmounted: {account_dir}"
        except OSError as exc:
            return f"Google Drive mount not listable: {exc}"

        if len(parts) > 1 and parts[1] in ("My Drive", "Shared drives", ".shortcut-targets-by-id"):
            sub_root = os.path.join(account_dir, parts[1])
            if not os.path.isdir(sub_root):
                return f"Google Drive '{parts[1]}' root unavailable: {sub_root}"
            try:
                if len(os.listdir(sub_root)) == 0:
                    return f"Google Drive '{parts[1]}' appears unmounted or empty"
            except OSError as exc:
                return f"Google Drive '{parts[1]}' not readable: {exc}"

    # 2. If this pair was previously synced (has baseline files), neither root may vanish
    if has_prior_baseline:
        if not os.path.exists(drive_target_path):
            return "Drive target folder is missing or unmounted (aborted to prevent data loss)"
        if not os.path.exists(local_path) and not os.path.islink(local_path):
            return "Local synced folder is missing (aborted to prevent data loss)"

    return None


def _is_file_changed_vs_baseline(
    full_path: str,
    meta: Dict[str, Any],
    base_entry: Dict[str, Any],
) -> bool:
    b_size = int(base_entry.get("size", -1))
    b_mtime = float(base_entry.get("mtime", -1.0))
    if b_size < 0 or b_mtime < 0:
        # Unmigrated legacy entry: not treated as changed unless size differs from counterpart
        return False
    if meta["size"] != b_size:
        return True
    if abs(meta["mtime"] - b_mtime) <= 2.0:
        return False
    # Size matches, mtime differs by > 2s: check optional sha1 if available
    b_sha1 = base_entry.get("sha1")
    if b_sha1 and not meta.get("is_dataless"):
        cur_sha1 = compute_file_sha1(full_path)
        if cur_sha1 and cur_sha1 == b_sha1:
            return False
    return True


def _are_files_identical(
    l_full: str,
    lm: Dict[str, Any],
    d_full: str,
    dm: Dict[str, Any],
) -> bool:
    if lm["size"] != dm["size"]:
        return False
    if abs(lm["mtime"] - dm["mtime"]) <= 2.0:
        return True
    if not dm.get("is_dataless") and lm["size"] <= MAX_HASH_SIZE_BYTES:
        l_hash = compute_file_sha1(l_full)
        d_hash = compute_file_sha1(d_full)
        if l_hash and d_hash and l_hash == d_hash:
            return True
    return False


def _ancestor_dirs_for_files(rel_files: Set[str]) -> Set[str]:
    ancestors: Set[str] = set()
    for rel in rel_files:
        parent = os.path.dirname(rel)
        while parent and parent != ".":
            if parent in ancestors:
                break
            ancestors.add(parent)
            parent = os.path.dirname(parent)
    return ancestors


# ============================================================
# CORE TWO-WAY MIRROR & SYMLINK SYNC ENGINE
# ============================================================
def sync_single_pair(
    local_path: str,
    drive_target_path: str,
    mode: str = "two_way_mirror",
    known_files: Optional[List[str]] = None,
    last_synced_at: Optional[float] = None,
    pair_id: Optional[str] = None,
    resolution: Optional[str] = None,
    delete_min_count: Optional[int] = None,
    delete_ratio: Optional[float] = None,
) -> Dict[str, Any]:
    local_path = normalize_abs_path(local_path)
    drive_target_path = normalize_abs_path(drive_target_path)
    effective_pair_id = (pair_id or hashlib.sha1(f"{local_path}::{drive_target_path}".encode("utf-8")).hexdigest()[:16]).upper()

    set_pair_running_flag(effective_pair_id, True)
    try:
        return _sync_single_pair_impl(
            local_path=local_path,
            drive_target_path=drive_target_path,
            mode=mode,
            known_files=known_files,
            last_synced_at=last_synced_at,
            pair_id=effective_pair_id,
            resolution=resolution,
            delete_min_count=delete_min_count,
            delete_ratio=delete_ratio,
        )
    finally:
        set_pair_running_flag(effective_pair_id, False)


def _sync_single_pair_impl(
    local_path: str,
    drive_target_path: str,
    mode: str,
    known_files: Optional[List[str]],
    last_synced_at: Optional[float],
    pair_id: str,
    resolution: Optional[str],
    delete_min_count: Optional[int],
    delete_ratio: Optional[float],
) -> Dict[str, Any]:
    baseline = load_pair_baseline(pair_id, legacy_known_files=known_files)
    base_files: Dict[str, Dict[str, Any]] = baseline.get("files", {})
    base_dirs: Set[str] = set(baseline.get("dirs", []))
    has_prior_baseline = len(base_files) > 0 or bool(last_synced_at and float(last_synced_at) > 0)

    # 1. Mount & Directory Health Guard (§3.1)
    health_err = check_mount_health(local_path, drive_target_path, has_prior_baseline=has_prior_baseline)
    if health_err:
        return {
            "ok": False,
            "status": "error",
            "copiedToDrive": 0,
            "copiedToLocal": 0,
            "trashedCount": 0,
            "conflicts": [],
            "pendingDeletionPlan": None,
            "totalFiles": len(base_files),
            "totalBytes": sum(max(0, int(m.get("size", 0))) for m in base_files.values()),
            "knownRelativeFiles": sorted(base_files.keys()),
            "syncedAt": time.time(),
            "errorMessage": health_err,
        }

    os.makedirs(os.path.dirname(drive_target_path), exist_ok=True)

    # 2. Symlink Mode
    if mode == "symlink_to_drive":
        os.makedirs(drive_target_path, exist_ok=True)
        if not os.path.islink(local_path):
            if os.path.exists(local_path):
                l_dirs, l_files = scan_tree(local_path, is_cloud=False)
                for d in sorted(l_dirs):
                    os.makedirs(os.path.join(drive_target_path, d), exist_ok=True)
                for rel_f, meta in l_files.items():
                    copy_atomic(
                        os.path.join(local_path, meta["real_rel"]),
                        os.path.join(drive_target_path, rel_f),
                        meta["mtime"],
                    )
                move_to_trash(local_path)
            os.symlink(drive_target_path, local_path)
        else:
            cur_target = normalize_abs_path(os.readlink(local_path))
            if cur_target != drive_target_path:
                os.remove(local_path)
                os.symlink(drive_target_path, local_path)

        d_dirs, d_files = scan_tree(drive_target_path, is_cloud=True)
        total_files = len(d_files)
        total_bytes = sum(m["size"] for m in d_files.values())
        now_ts = time.time()
        new_base_files = {
            rel: {"size": m["size"], "mtime": m["mtime"], "localIno": m["ino"]}
            for rel, m in d_files.items()
        }
        save_pair_baseline(pair_id, new_base_files, list(d_dirs), now_ts)
        return {
            "ok": True,
            "status": "ok",
            "copiedToDrive": total_files,
            "copiedToLocal": 0,
            "trashedCount": 0,
            "conflicts": [],
            "pendingDeletionPlan": None,
            "totalFiles": total_files,
            "totalBytes": total_bytes,
            "knownRelativeFiles": sorted(d_files.keys()),
            "syncedAt": now_ts,
            "errorMessage": None,
        }

    # 3. Two-Way Mirror Mode
    if os.path.islink(local_path):
        os.remove(local_path)
        if os.path.exists(drive_target_path):
            shutil.copytree(drive_target_path, local_path, dirs_exist_ok=True)
        else:
            os.makedirs(local_path, exist_ok=True)

    os.makedirs(local_path, exist_ok=True)
    os.makedirs(drive_target_path, exist_ok=True)

    l_dirs, l_files = scan_tree(local_path, is_cloud=False)
    d_dirs, d_files = scan_tree(drive_target_path, is_cloud=True)

    baseline_known_dirs = base_dirs | _ancestor_dirs_for_files(set(base_files.keys()))

    # Plan Phase (compute all actions before mutating)
    plan_copy_l2d: List[str] = []
    plan_copy_d2l: List[str] = []
    plan_trash_local: List[str] = []
    plan_trash_drive: List[str] = []
    plan_conflicts: List[str] = []
    plan_unchanged: List[str] = []
    deferred: List[str] = []
    deferred_set: Set[str] = set()

    materialize_budget = float(os.environ.get("DRIVEBAR_MATERIALIZE_BUDGET_SEC", str(DEFAULT_MATERIALIZE_BUDGET_SEC)))
    per_file_timeout = float(os.environ.get("DRIVEBAR_MATERIALIZE_TIMEOUT_SEC", str(DEFAULT_MATERIALIZE_TIMEOUT_SEC)))

    def _defer_file(rel_key: str) -> None:
        if rel_key not in deferred_set:
            deferred_set.add(rel_key)
            deferred.append(rel_key)

    def _ensure_drive_materialized(rel_key: str, d_full_path: str, dm_entry: Dict[str, Any]) -> bool:
        nonlocal materialize_budget
        if not dm_entry.get("is_dataless"):
            return True
        if materialize_budget <= 0.0:
            return False
        t0 = time.monotonic()
        file_timeout = min(per_file_timeout, materialize_budget)
        ok = materialize_dataless(d_full_path, timeout=file_timeout)
        elapsed = max(0.0, time.monotonic() - t0)
        materialize_budget = max(0.0, materialize_budget - elapsed)
        if not ok:
            return False
        try:
            st_after = os.lstat(d_full_path)
            if _is_path_dataless(d_full_path, st_after, True):
                return False
            dm_entry["mtime"] = float(st_after.st_mtime)
            dm_entry["size"] = int(st_after.st_size)
            dm_entry["ino"] = int(st_after.st_ino)
            dm_entry["is_dataless"] = False
            return True
        except OSError:
            return False

    all_rel_files = sorted(set(l_files.keys()) | set(d_files.keys()) | set(base_files.keys()))

    for rel_f in all_rel_files:
        lm = l_files.get(rel_f)
        dm = d_files.get(rel_f)
        bm = base_files.get(rel_f)
        l_full = os.path.join(local_path, lm["real_rel"] if lm else rel_f)
        d_full = os.path.join(drive_target_path, dm["real_rel"] if dm else rel_f)

        if lm and dm:
            if bm is not None:
                # Migrated legacy entry with unknown size/mtime
                if int(bm.get("size", -1)) < 0:
                    if dm["is_dataless"] and not _ensure_drive_materialized(rel_f, d_full, dm):
                        _defer_file(rel_f)
                        continue
                    if _are_files_identical(l_full, lm, d_full, dm):
                        plan_unchanged.append(rel_f)
                    else:
                        plan_conflicts.append(rel_f)
                else:
                    b_size = int(bm.get("size", -1))
                    b_mtime = float(bm.get("mtime", -1.0))
                    d_meta_changed = (dm["size"] != b_size) or (abs(dm["mtime"] - b_mtime) > 2.0)
                    if dm["is_dataless"] and d_meta_changed:
                        if not _ensure_drive_materialized(rel_f, d_full, dm):
                            _defer_file(rel_f)
                            continue

                    l_chg = _is_file_changed_vs_baseline(l_full, lm, bm)
                    d_chg = _is_file_changed_vs_baseline(d_full, dm, bm)
                    if not l_chg and not d_chg:
                        plan_unchanged.append(rel_f)
                    elif l_chg and not d_chg:
                        plan_copy_l2d.append(rel_f)
                    elif d_chg and not l_chg:
                        if dm["is_dataless"] and not _ensure_drive_materialized(rel_f, d_full, dm):
                            _defer_file(rel_f)
                            continue
                        plan_copy_d2l.append(rel_f)
                    else:
                        if dm["is_dataless"] and not _ensure_drive_materialized(rel_f, d_full, dm):
                            _defer_file(rel_f)
                            continue
                        if _are_files_identical(l_full, lm, d_full, dm):
                            plan_unchanged.append(rel_f)
                        else:
                            plan_conflicts.append(rel_f)
            else:
                # Not in baseline, exists on both sides -> decision depends on Drive content
                if dm["is_dataless"] and not _ensure_drive_materialized(rel_f, d_full, dm):
                    _defer_file(rel_f)
                    continue
                if _are_files_identical(l_full, lm, d_full, dm):
                    plan_unchanged.append(rel_f)
                else:
                    plan_conflicts.append(rel_f)

        elif lm and not dm:
            if bm is not None:
                if int(bm.get("size", -1)) < 0:
                    # Never delete on initial legacy migration run
                    plan_copy_l2d.append(rel_f)
                elif not _is_file_changed_vs_baseline(l_full, lm, bm):
                    # Unchanged locally, missing on Drive -> deleted on Drive
                    if resolution == "restore_from_other":
                        plan_copy_l2d.append(rel_f)
                    else:
                        plan_trash_local.append(rel_f)
                else:
                    # Changed locally while deleted on Drive -> resurrect to Drive
                    plan_copy_l2d.append(rel_f)
            else:
                # New on local
                plan_copy_l2d.append(rel_f)

        elif dm and not lm:
            if bm is not None:
                if int(bm.get("size", -1)) < 0:
                    # Never delete on initial legacy migration run -> copy d2l after materializing
                    if dm["is_dataless"] and not _ensure_drive_materialized(rel_f, d_full, dm):
                        _defer_file(rel_f)
                        continue
                    plan_copy_d2l.append(rel_f)
                else:
                    b_size = int(bm.get("size", -1))
                    b_mtime = float(bm.get("mtime", -1.0))
                    d_meta_changed = (dm["size"] != b_size) or (abs(dm["mtime"] - b_mtime) > 2.0)
                    if dm["is_dataless"] and d_meta_changed:
                        if not _ensure_drive_materialized(rel_f, d_full, dm):
                            _defer_file(rel_f)
                            continue
                    if not _is_file_changed_vs_baseline(d_full, dm, bm):
                        # Unchanged on Drive, missing locally -> deleted locally
                        if resolution == "restore_from_other":
                            if dm["is_dataless"] and not _ensure_drive_materialized(rel_f, d_full, dm):
                                _defer_file(rel_f)
                                continue
                            plan_copy_d2l.append(rel_f)
                        else:
                            plan_trash_drive.append(rel_f)
                    else:
                        # Changed on Drive while deleted locally -> resurrect to local
                        if dm["is_dataless"] and not _ensure_drive_materialized(rel_f, d_full, dm):
                            _defer_file(rel_f)
                            continue
                        plan_copy_d2l.append(rel_f)
            else:
                # New on Drive
                if dm["is_dataless"] and not _ensure_drive_materialized(rel_f, d_full, dm):
                    _defer_file(rel_f)
                    continue
                plan_copy_d2l.append(rel_f)

    # 4. Mass-Deletion Ratio & Empty-Side Guard (§3.1)
    baseline_count = len(base_files)
    if baseline_count > 0 and resolution not in ("apply_deletions", "restore_from_other"):
        min_cnt = delete_min_count if delete_min_count is not None else int(os.environ.get("DRIVEBAR_DELETE_MIN_COUNT", "20"))
        ratio = delete_ratio if delete_ratio is not None else float(os.environ.get("DRIVEBAR_DELETE_RATIO", "0.20"))
        threshold = max(min_cnt, int(ratio * baseline_count))

        trip_reason: Optional[str] = None
        if len(d_files) == 0 and len(plan_trash_local) > 0:
            trip_reason = f"Drive folder scanned 0 files while baseline has {baseline_count} files (possible Drive reset/offline)."
        elif len(l_files) == 0 and len(plan_trash_drive) > 0:
            trip_reason = f"Local folder scanned 0 files while baseline has {baseline_count} files."
        elif len(plan_trash_local) > threshold:
            trip_reason = f"Planned local deletions ({len(plan_trash_local)}) exceed safety threshold ({threshold} of {baseline_count})."
        elif len(plan_trash_drive) > threshold:
            trip_reason = f"Planned Drive deletions ({len(plan_trash_drive)}) exceed safety threshold ({threshold} of {baseline_count})."

        if trip_reason:
            plan_summary = {
                "localDeletes": plan_trash_local,
                "driveDeletes": plan_trash_drive,
                "localFileCount": len(l_files),
                "driveFileCount": len(d_files),
                "baselineFileCount": baseline_count,
                "reason": trip_reason,
            }
            return {
                "ok": False,
                "status": "needs_confirmation",
                "copiedToDrive": 0,
                "copiedToLocal": 0,
                "trashedCount": 0,
                "conflicts": [],
                "deferred": deferred,
                "pendingDeletionPlan": plan_summary,
                "totalFiles": len(l_files),
                "totalBytes": sum(m["size"] for m in l_files.values()),
                "knownRelativeFiles": sorted(base_files.keys()),
                "syncedAt": time.time(),
                "errorMessage": trip_reason,
            }

    # 5. Execute Directory Sync
    surviving_dirs: Set[str] = set()
    for rel_dir in sorted(l_dirs | d_dirs):
        in_l = rel_dir in l_dirs
        in_d = rel_dir in d_dirs
        l_dir_full = os.path.join(local_path, rel_dir)
        d_dir_full = os.path.join(drive_target_path, rel_dir)
        if in_l and in_d:
            surviving_dirs.add(rel_dir)
        elif in_l and not in_d:
            if rel_dir in baseline_known_dirs and resolution != "restore_from_other":
                # Directory was in baseline and removed from Drive -> remove if empty after file ops
                pass
            else:
                os.makedirs(d_dir_full, exist_ok=True)
                surviving_dirs.add(rel_dir)
        elif in_d and not in_l:
            if rel_dir in baseline_known_dirs and resolution != "restore_from_other":
                pass
            else:
                os.makedirs(l_dir_full, exist_ok=True)
                surviving_dirs.add(rel_dir)

    # 6. Execute File Sync Plan
    copied_to_drive = 0
    copied_to_local = 0
    trashed_count = 0
    conflicts_created: List[str] = []
    new_base_files: Dict[str, Dict[str, Any]] = {}

    def _record_baseline_entry(
        rel_key: str,
        size_val: int,
        mtime_val: float,
        local_full_path: str,
        existing_sha1: Optional[str] = None,
    ) -> None:
        ino_val = 0
        try:
            ino_val = int(os.lstat(local_full_path).st_ino)
        except OSError:
            pass
        entry: Dict[str, Any] = {
            "size": int(size_val),
            "mtime": float(mtime_val),
            "localIno": ino_val,
        }
        sha1_val = existing_sha1
        if not sha1_val and 0 <= int(size_val) <= MAX_HASH_SIZE_BYTES and os.path.exists(local_full_path):
            sha1_val = compute_file_sha1(local_full_path)
        if sha1_val:
            entry["sha1"] = sha1_val
        new_base_files[rel_key] = entry

    for rel_f in plan_unchanged:
        lm = l_files.get(rel_f)
        dm = d_files.get(rel_f)
        bm = base_files.get(rel_f)
        ref = lm or dm
        if ref:
            l_full = os.path.join(local_path, lm["real_rel"] if lm else rel_f)
            cached_sha1 = bm.get("sha1") if (bm and int(bm.get("size", -1)) == ref["size"]) else None
            _record_baseline_entry(rel_f, ref["size"], ref["mtime"], l_full, existing_sha1=cached_sha1)

    for rel_f in plan_copy_l2d:
        lm = l_files[rel_f]
        l_full = os.path.join(local_path, lm["real_rel"])
        d_full = os.path.join(drive_target_path, rel_f)
        if copy_atomic(l_full, d_full, lm["mtime"]):
            copied_to_drive += 1
            _record_baseline_entry(rel_f, lm["size"], lm["mtime"], l_full)

    for rel_f in plan_copy_d2l:
        dm = d_files[rel_f]
        d_full = os.path.join(drive_target_path, dm["real_rel"])
        l_full = os.path.join(local_path, rel_f)
        if dm.get("is_dataless") and not _ensure_drive_materialized(rel_f, d_full, dm):
            _defer_file(rel_f)
            continue
        if copy_atomic(d_full, l_full, dm["mtime"]):
            copied_to_local += 1
            _record_baseline_entry(rel_f, dm["size"], dm["mtime"], l_full)

    for rel_f in plan_conflicts:
        lm = l_files[rel_f]
        dm = d_files[rel_f]
        l_full = os.path.join(local_path, lm["real_rel"])
        d_full = os.path.join(drive_target_path, dm["real_rel"])
        if dm.get("is_dataless") and not _ensure_drive_materialized(rel_f, d_full, dm):
            _defer_file(rel_f)
            continue

        # Keep newer at original path; ALWAYS save older as conflict copy on both sides before any overwrite
        if lm["mtime"] >= dm["mtime"]:
            winner_meta = lm
            loser_meta = dm
            conflict_rel = format_conflict_rel_path(rel_f, dm["mtime"])
            l_conf = os.path.join(local_path, conflict_rel)
            d_conf = os.path.join(drive_target_path, conflict_rel)
            if not (copy_atomic(d_full, l_conf, dm["mtime"]) and copy_atomic(d_full, d_conf, dm["mtime"])):
                _defer_file(rel_f)
                continue
            if copy_atomic(l_full, d_full, lm["mtime"]):
                copied_to_drive += 1
        else:
            winner_meta = dm
            loser_meta = lm
            conflict_rel = format_conflict_rel_path(rel_f, lm["mtime"])
            l_conf = os.path.join(local_path, conflict_rel)
            d_conf = os.path.join(drive_target_path, conflict_rel)
            if not (copy_atomic(l_full, l_conf, lm["mtime"]) and copy_atomic(l_full, d_conf, lm["mtime"])):
                _defer_file(rel_f)
                continue
            if copy_atomic(d_full, l_full, dm["mtime"]):
                copied_to_local += 1

        conflicts_created.append(conflict_rel)
        _record_baseline_entry(rel_f, winner_meta["size"], winner_meta["mtime"], os.path.join(local_path, rel_f))
        _record_baseline_entry(conflict_rel, loser_meta["size"], loser_meta["mtime"], os.path.join(local_path, conflict_rel))

    # Preserve OLD baseline entry unchanged for any deferred files so next run re-evaluates accurately
    for rel_f in deferred:
        if rel_f in base_files:
            new_base_files[rel_f] = dict(base_files[rel_f])

    for rel_f in plan_trash_local:
        lm = l_files[rel_f]
        l_full = os.path.join(local_path, lm["real_rel"])
        if move_to_trash(l_full):
            trashed_count += 1

    for rel_f in plan_trash_drive:
        dm = d_files[rel_f]
        d_full = os.path.join(drive_target_path, dm["real_rel"])
        if move_to_trash(d_full):
            trashed_count += 1

    # Clean up empty directories that were deleted on one side
    active_ancestors = _ancestor_dirs_for_files(set(new_base_files.keys()) | set(deferred))
    for rel_dir in sorted(l_dirs | d_dirs, key=lambda x: x.count(os.sep), reverse=True):
        if rel_dir in surviving_dirs or rel_dir in active_ancestors:
            surviving_dirs.add(rel_dir)
            continue
        if rel_dir in baseline_known_dirs:
            l_dir_full = os.path.join(local_path, rel_dir)
            d_dir_full = os.path.join(drive_target_path, rel_dir)
            if rel_dir in l_dirs and rel_dir not in d_dirs and os.path.isdir(l_dir_full):
                try:
                    if not os.listdir(l_dir_full):
                        move_to_trash(l_dir_full)
                except OSError:
                    pass
            elif rel_dir in d_dirs and rel_dir not in l_dirs and os.path.isdir(d_dir_full):
                try:
                    if not os.listdir(d_dir_full):
                        move_to_trash(d_dir_full)
                except OSError:
                    pass

    now_ts = time.time()
    save_pair_baseline(pair_id, new_base_files, list(surviving_dirs), now_ts)
    set_finder_tag(local_path, True)

    total_files = len(new_base_files)
    total_bytes = sum(max(0, int(m.get("size", 0))) for m in new_base_files.values())

    return {
        "ok": True,
        "status": "ok",
        "copiedToDrive": copied_to_drive,
        "copiedToLocal": copied_to_local,
        "trashedCount": trashed_count,
        "conflicts": conflicts_created,
        "deferred": deferred,
        "pendingDeletionPlan": None,
        "totalFiles": total_files,
        "totalBytes": total_bytes,
        "knownRelativeFiles": sorted(new_base_files.keys()),
        "syncedAt": now_ts,
        "errorMessage": None,
    }


# ============================================================
# SHARED GOOGLE DRIVE LINK INSPECTION & INCREMENTAL PULL
# ============================================================
def parse_google_drive_link(url_or_id: str) -> Tuple[Optional[str], Optional[str]]:
    import re
    s = (url_or_id or "").strip()
    if not s:
        return None, None
    rk_match = re.search(r"[?&]resourcekey=([a-zA-Z0-9_-]+)", s, re.IGNORECASE)
    rk = rk_match.group(1) if rk_match else None

    for pat in (
        r"/folders/([a-zA-Z0-9_-]{15,})",
        r"/file/d/([a-zA-Z0-9_-]{15,})",
        r"[?&]id=([a-zA-Z0-9_-]{15,})",
        r"^([a-zA-Z0-9_-]{15,})$",
    ):
        m = re.search(pat, s)
        if m:
            return m.group(1), rk
    return None, rk


def parse_rfc3339_epoch(ts_str: Optional[str]) -> float:
    if not ts_str:
        return time.time()
    try:
        clean = ts_str.replace("Z", "+00:00")
        return datetime.datetime.fromisoformat(clean).timestamp()
    except Exception:
        return time.time()


def sanitize_filename(name: str) -> str:
    cleaned = (name or "Untitled").replace("/", "_").replace("\0", "").strip()
    return cleaned or "Untitled"


def inspect_remote_shared_folder(url_or_id: str) -> Dict[str, Any]:
    fid, rk = parse_google_drive_link(url_or_id)
    if not fid:
        return {
            "ok": False,
            "isBroken": False,
            "folderId": None,
            "folderName": None,
            "ownerName": None,
            "errorMessage": "Đường dẫn không phải là link thư mục Google Drive hợp lệ.",
        }

    tok = get_valid_oauth_token("personal") or get_valid_oauth_token("system")
    if not tok:
        return {
            "ok": False,
            "isBroken": False,
            "folderId": fid,
            "folderName": None,
            "ownerName": None,
            "errorMessage": "Không tìm thấy token OAuth Google Drive hợp lệ.",
        }

    headers = {"Authorization": f"Bearer {tok}"}
    if rk:
        headers["X-Goog-Drive-Resource-Keys"] = f"{fid}/{rk}"

    meta_url = (
        f"https://www.googleapis.com/drive/v3/files/{fid}"
        "?supportsAllDrives=true&fields=id,name,mimeType,modifiedTime,trashed,owners(displayName,emailAddress),capabilities(canEdit,canAddChildren,canDownload)"
    )
    req = urllib.request.Request(meta_url, headers=headers, method="GET")
    try:
        with urllib.request.urlopen(req, timeout=15) as resp:
            meta = json.loads(resp.read().decode("utf-8"))
        if meta.get("trashed"):
            return {
                "ok": False,
                "isBroken": True,
                "folderId": fid,
                "folderName": meta.get("name"),
                "ownerName": None,
                "errorMessage": "Thư mục chia sẻ đã bị chủ sở hữu xóa hoặc đưa vào Thùng rác.",
            }
        owners = meta.get("owners") or []
        owner_str = None
        if owners:
            dn = owners[0].get("displayName", "")
            em = owners[0].get("emailAddress", "")
            owner_str = f"{dn} ({em})" if (dn and em and dn != em) else (dn or em)
        folder_name = sanitize_filename(meta.get("name") or f"Shared_{fid[:8]}")
        sug_local = os.path.abspath(os.path.expanduser(f"~/Documents/antigravity/00. Shared_GDrive/{folder_name}"))
        sug_drive = os.path.join(find_my_drive_root(), "00. Antigravity_Sync", "00. Shared_GDrive", folder_name)
        return {
            "ok": True,
            "isBroken": False,
            "folderId": fid,
            "resourceKey": rk,
            "folderName": folder_name,
            "mimeType": meta.get("mimeType"),
            "modifiedTime": meta.get("modifiedTime"),
            "ownerName": owner_str,
            "suggestedLocalPath": sug_local,
            "suggestedDrivePath": sug_drive,
            "errorMessage": None,
        }
    except urllib.error.HTTPError as he:
        is_broken = he.code in (401, 403, 404)
        return {
            "ok": False,
            "isBroken": is_broken,
            "httpCode": he.code,
            "folderId": fid,
            "folderName": None,
            "ownerName": None,
            "errorMessage": (
                "⚠️ Link Google Drive đã bị khóa hoặc thu hồi quyền truy cập."
                if is_broken
                else f"Lỗi kết nối Google Drive API ({he.code})."
            ),
        }
    except Exception as e:
        return {
            "ok": False,
            "isBroken": False,
            "folderId": fid,
            "folderName": None,
            "ownerName": None,
            "errorMessage": str(e),
        }


GOOGLE_WORKSPACE_EXPORTS = {
    "application/vnd.google-apps.document": (
        ".docx",
        "application/vnd.openxmlformats-officedocument.wordprocessingml.document",
    ),
    "application/vnd.google-apps.spreadsheet": (
        ".xlsx",
        "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
    ),
    "application/vnd.google-apps.presentation": (
        ".pptx",
        "application/vnd.openxmlformats-officedocument.presentationml.presentation",
    ),
}


def _load_remote_folder_cache(fid: str) -> Dict[str, Any]:
    c_path = remote_cache_dir_path() / f"{fid}.json"
    if c_path.exists():
        try:
            return json.loads(c_path.read_text(encoding="utf-8"))
        except Exception:
            pass
    return {"folderModifiedTimes": {}, "lastCheckedAt": 0.0, "backoffUntil": 0.0, "failCount": 0}


def _save_remote_folder_cache(fid: str, data: Dict[str, Any]) -> None:
    c_path = remote_cache_dir_path() / f"{fid}.json"
    try:
        write_json_atomic(c_path, data, indent=None)
    except Exception:
        pass


def sync_remote_shared_folder(
    remote_url: str,
    local_path: str,
    drive_mirror_path: Optional[str] = None,
    force_full: bool = False,
) -> Dict[str, Any]:
    """
    Additive & Update-Only sync from a shared Google Drive folder URL to local_path (and optional drive_mirror_path).
    NEVER deletes local files even if removed remotely or if the shared link is locked/revoked.
    Caches folder modifiedTime values and uses exponential backoff on 429/5xx.
    """
    local_path = normalize_abs_path(local_path)
    os.makedirs(local_path, exist_ok=True)
    if drive_mirror_path:
        drive_mirror_path = normalize_abs_path(drive_mirror_path)

    fid, _ = parse_google_drive_link(remote_url)
    rcache = _load_remote_folder_cache(fid or "unknown")
    now_ts = time.time()

    if not force_full and float(rcache.get("backoffUntil", 0.0)) > now_ts:
        _, l_files = scan_tree(local_path, is_cloud=False)
        return {
            "ok": True,
            "status": "ok",
            "isBrokenLink": False,
            "copiedToDrive": 0,
            "copiedToLocal": 0,
            "trashedCount": 0,
            "conflicts": [],
            "totalFiles": len(l_files),
            "totalBytes": sum(m["size"] for m in l_files.values()),
            "knownRelativeFiles": sorted(l_files.keys()),
            "syncedAt": now_ts,
            "errorMessage": None,
        }

    info = inspect_remote_shared_folder(remote_url)
    if not info.get("ok"):
        _, l_files = scan_tree(local_path, is_cloud=False)
        total_files = len(l_files)
        total_bytes = sum(m["size"] for m in l_files.values())
        is_broken = bool(info.get("isBroken"))
        http_code = info.get("httpCode")
        if http_code in (429, 500, 502, 503, 504):
            fails = int(rcache.get("failCount", 0)) + 1
            rcache["failCount"] = fails
            rcache["backoffUntil"] = now_ts + min(3600, 60 * (2 ** min(fails, 6)))
            if fid:
                _save_remote_folder_cache(fid, rcache)
        if is_broken:
            set_finder_badge(local_path, "broken")
            if drive_mirror_path and os.path.exists(drive_mirror_path) and drive_mirror_path != local_path:
                set_finder_badge(drive_mirror_path, "broken")
        return {
            "ok": False,
            "status": "broken_link" if is_broken else "error",
            "isBrokenLink": is_broken,
            "copiedToDrive": 0,
            "copiedToLocal": 0,
            "trashedCount": 0,
            "conflicts": [],
            "totalFiles": total_files,
            "totalBytes": total_bytes,
            "knownRelativeFiles": sorted(l_files.keys()),
            "syncedAt": now_ts,
            "folderName": info.get("folderName"),
            "ownerName": info.get("ownerName"),
            "errorMessage": info.get("errorMessage") or "Không thể truy cập link chia sẻ.",
        }

    fid = info["folderId"]
    rk = info.get("resourceKey")
    tok = get_valid_oauth_token("personal") or get_valid_oauth_token("system")
    headers = {"Authorization": f"Bearer {tok}"}
    if rk:
        headers["X-Goog-Drive-Resource-Keys"] = f"{fid}/{rk}"

    folder_mtimes: Dict[str, str] = dict(rcache.get("folderModifiedTimes") or {})
    downloaded_count = 0
    copied_to_drive = 0

    def _download_stream(
        download_url: str,
        dst_file: str,
        mtime: float,
        item_rk: Optional[str] = None,
        item_id: Optional[str] = None,
    ) -> bool:
        req_headers = dict(headers)
        if item_rk and item_id:
            req_headers["X-Goog-Drive-Resource-Keys"] = f"{item_id}/{item_rk}"
        os.makedirs(os.path.dirname(dst_file), exist_ok=True)
        tmp_dst = os.path.join(os.path.dirname(dst_file), f".drivebar_sync_tmp_{uuid.uuid4().hex}")
        try:
            req = urllib.request.Request(download_url, headers=req_headers, method="GET")
            with urllib.request.urlopen(req, timeout=60) as resp, open(tmp_dst, "wb") as out_f:
                shutil.copyfileobj(resp, out_f)
            os.utime(tmp_dst, (mtime, mtime))
            os.replace(tmp_dst, dst_file)
            os.utime(dst_file, (mtime, mtime))
            return True
        except Exception:
            if os.path.exists(tmp_dst):
                try:
                    os.remove(tmp_dst)
                except OSError:
                    pass
            return False

    def _sync_folder_recursive(remote_folder_id: str, cur_local_dir: str, folder_rk: Optional[str] = None) -> None:
        nonlocal downloaded_count
        os.makedirs(cur_local_dir, exist_ok=True)
        page_token = None
        while True:
            q_str = f"'{remote_folder_id}' in parents and trashed = false"
            params = {
                "q": q_str,
                "supportsAllDrives": "true",
                "includeItemsFromAllDrives": "true",
                "pageSize": "500",
                "fields": "nextPageToken,files(id,name,mimeType,size,modifiedTime,resourceKey)",
            }
            if page_token:
                params["pageToken"] = page_token
            list_url = "https://www.googleapis.com/drive/v3/files?" + urllib.parse.urlencode(params)
            req_headers = dict(headers)
            if folder_rk:
                req_headers["X-Goog-Drive-Resource-Keys"] = f"{remote_folder_id}/{folder_rk}"
            req = urllib.request.Request(list_url, headers=req_headers, method="GET")
            with urllib.request.urlopen(req, timeout=25) as resp:
                data = json.loads(resp.read().decode("utf-8"))

            for item in data.get("files", []):
                item_id = item.get("id")
                raw_name = sanitize_filename(item.get("name") or item_id)
                mime = item.get("mimeType") or ""
                item_rk = item.get("resourceKey")
                item_mtime_str = item.get("modifiedTime") or ""
                remote_mtime = parse_rfc3339_epoch(item_mtime_str)

                if mime == "application/vnd.google-apps.folder":
                    sub_local = os.path.join(cur_local_dir, raw_name)
                    _sync_folder_recursive(item_id, sub_local, item_rk)
                    if item_id and item_mtime_str:
                        folder_mtimes[item_id] = item_mtime_str
                elif mime in GOOGLE_WORKSPACE_EXPORTS:
                    ext, export_mime = GOOGLE_WORKSPACE_EXPORTS[mime]
                    fname = raw_name if raw_name.lower().endswith(ext) else (raw_name + ext)
                    dst_file = os.path.join(cur_local_dir, fname)
                    need_dl = True
                    if os.path.exists(dst_file):
                        st = os.stat(dst_file)
                        if st.st_mtime >= remote_mtime - 2.0 and st.st_size > 0:
                            need_dl = False
                    if need_dl:
                        exp_url = (
                            f"https://www.googleapis.com/drive/v3/files/{item_id}/export?"
                            + urllib.parse.urlencode({"mimeType": export_mime})
                        )
                        if _download_stream(exp_url, dst_file, remote_mtime, item_rk, item_id):
                            downloaded_count += 1
                elif not mime.startswith("application/vnd.google-apps."):
                    dst_file = os.path.join(cur_local_dir, raw_name)
                    remote_size = int(item.get("size") or 0)
                    need_dl = True
                    if os.path.exists(dst_file):
                        st = os.stat(dst_file)
                        if abs(st.st_mtime - remote_mtime) <= 2.0 and (remote_size == 0 or st.st_size == remote_size):
                            need_dl = False
                    if need_dl:
                        dl_url = f"https://www.googleapis.com/drive/v3/files/{item_id}?alt=media&supportsAllDrives=true"
                        if _download_stream(dl_url, dst_file, remote_mtime, item_rk, item_id):
                            downloaded_count += 1

            page_token = data.get("nextPageToken")
            if not page_token:
                break

    try:
        if info.get("mimeType") == "application/vnd.google-apps.folder":
            _sync_folder_recursive(fid, local_path, rk)
            if info.get("modifiedTime"):
                folder_mtimes[fid] = info["modifiedTime"]
        else:
            fname = info.get("folderName") or f"Shared_{fid[:8]}"
            dst_file = os.path.join(local_path, fname)
            dl_url = f"https://www.googleapis.com/drive/v3/files/{fid}?alt=media&supportsAllDrives=true"
            if _download_stream(dl_url, dst_file, time.time(), rk, fid):
                downloaded_count += 1
    except urllib.error.HTTPError as he:
        if he.code in (429, 500, 502, 503, 504):
            fails = int(rcache.get("failCount", 0)) + 1
            rcache["failCount"] = fails
            rcache["backoffUntil"] = time.time() + min(3600, 60 * (2 ** min(fails, 6)))
            _save_remote_folder_cache(fid, rcache)
        _, l_files = scan_tree(local_path, is_cloud=False)
        return {
            "ok": False,
            "status": "error",
            "isBrokenLink": False,
            "copiedToDrive": 0,
            "copiedToLocal": downloaded_count,
            "trashedCount": 0,
            "conflicts": [],
            "totalFiles": len(l_files),
            "totalBytes": sum(m["size"] for m in l_files.values()),
            "knownRelativeFiles": sorted(l_files.keys()),
            "syncedAt": time.time(),
            "folderName": info.get("folderName"),
            "ownerName": info.get("ownerName"),
            "errorMessage": str(he),
        }
    except Exception as e:
        _, l_files = scan_tree(local_path, is_cloud=False)
        return {
            "ok": False,
            "status": "error",
            "isBrokenLink": False,
            "copiedToDrive": 0,
            "copiedToLocal": downloaded_count,
            "trashedCount": 0,
            "conflicts": [],
            "totalFiles": len(l_files),
            "totalBytes": sum(m["size"] for m in l_files.values()),
            "knownRelativeFiles": sorted(l_files.keys()),
            "syncedAt": time.time(),
            "folderName": info.get("folderName"),
            "ownerName": info.get("ownerName"),
            "errorMessage": str(e),
        }

    rcache["folderModifiedTimes"] = folder_mtimes
    rcache["lastCheckedAt"] = time.time()
    rcache["backoffUntil"] = 0.0
    rcache["failCount"] = 0
    _save_remote_folder_cache(fid, rcache)

    l_dirs, l_files = scan_tree(local_path, is_cloud=False)
    if drive_mirror_path and drive_mirror_path != local_path:
        os.makedirs(drive_mirror_path, exist_ok=True)
        for d in sorted(l_dirs):
            os.makedirs(os.path.join(drive_mirror_path, d), exist_ok=True)
        _, d_files = scan_tree(drive_mirror_path, is_cloud=True)
        for rel_f, lm in l_files.items():
            dm = d_files.get(rel_f)
            if not dm or lm["mtime"] > dm["mtime"] + 2.0 or lm["size"] != dm["size"]:
                if copy_atomic(
                    os.path.join(local_path, lm["real_rel"]),
                    os.path.join(drive_mirror_path, rel_f),
                    lm["mtime"],
                ):
                    copied_to_drive += 1
        set_finder_badge(drive_mirror_path, "synced")

    set_finder_badge(local_path, "synced")
    total_files = len(l_files)
    total_bytes = sum(m["size"] for m in l_files.values())
    return {
        "ok": True,
        "status": "ok",
        "isBrokenLink": False,
        "copiedToDrive": copied_to_drive,
        "copiedToLocal": downloaded_count,
        "trashedCount": 0,
        "conflicts": [],
        "totalFiles": total_files,
        "totalBytes": total_bytes,
        "knownRelativeFiles": sorted(l_files.keys()),
        "syncedAt": time.time(),
        "folderId": fid,
        "folderName": info.get("folderName"),
        "ownerName": info.get("ownerName"),
        "errorMessage": None,
    }


# ============================================================
# PAIR OPERATIONS & COMMAND CHANNEL EXECUTION
# ============================================================
def _apply_sync_report_to_pair(pair: Dict[str, Any], rep: Dict[str, Any]) -> None:
    pair["lastSyncedAt"] = rep.get("syncedAt") or time.time()
    pair["lastSyncFileCount"] = int(rep.get("totalFiles", pair.get("lastSyncFileCount", 0)))
    pair["lastSyncTotalBytes"] = int(rep.get("totalBytes", pair.get("lastSyncTotalBytes", 0)))
    pair["lastError"] = rep.get("errorMessage")
    pair["status"] = rep.get("status") or ("ok" if rep.get("ok") else "error")
    pair["pendingDeletionPlan"] = rep.get("pendingDeletionPlan")
    pair["lastConflicts"] = rep.get("conflicts") or []
    pair["deferredFiles"] = rep.get("deferred") or []
    pair["isRemoteLinkBroken"] = bool(rep.get("isBrokenLink", False))
    if rep.get("ownerName"):
        pair["remoteOwnerName"] = rep.get("ownerName")
    pair.pop("knownRelativeFiles", None)


def sync_pair_by_dict(
    p: Dict[str, Any],
    force_remote: bool = False,
    resolution: Optional[str] = None,
    remote_poll_interval: float = 900.0,
) -> Dict[str, Any]:
    pid = str(p.get("id") or uuid.uuid4()).upper()
    p["id"] = pid
    l_path = p.get("localPath", "")
    d_path = p.get("driveTargetPath", "")
    mode = p.get("syncMode", "two_way_mirror")
    remote_url = p.get("remoteSharedURL")
    last_ts = p.get("lastSyncedAt")

    if mode == "remote_shared_link" and remote_url:
        now = time.time()
        if not force_remote and last_ts and (now - float(last_ts)) < remote_poll_interval:
            return {
                "ok": True,
                "status": p.get("status", "ok"),
                "skippedPoll": True,
                "copiedToDrive": 0,
                "copiedToLocal": 0,
                "trashedCount": 0,
                "conflicts": [],
                "totalFiles": p.get("lastSyncFileCount", 0),
                "totalBytes": p.get("lastSyncTotalBytes", 0),
                "knownRelativeFiles": [],
                "syncedAt": float(last_ts),
                "errorMessage": p.get("lastError"),
            }
        rep = sync_remote_shared_folder(remote_url, l_path, d_path, force_full=force_remote)
    else:
        rep = sync_single_pair(
            local_path=l_path,
            drive_target_path=d_path,
            mode=mode,
            known_files=p.get("knownRelativeFiles"),
            last_synced_at=last_ts,
            pair_id=pid,
            resolution=resolution,
        )
    _apply_sync_report_to_pair(p, rep)
    return rep


def upsert_and_sync_pair(
    local_path: str,
    drive_path: Optional[str] = None,
    mode: str = "two_way_mirror",
    pair_id: Optional[str] = None,
    sync_immediately: bool = True,
) -> Dict[str, Any]:
    std_local = normalize_abs_path(local_path)
    std_drive = normalize_abs_path(drive_path) if drive_path else suggested_drive_target(std_local)
    now_ts = time.time()

    with locked_pairs_file():
        pairs, _ = _decode_raw_pairs_unlocked()
        target_pair = None
        for p in pairs:
            if (pair_id and str(p.get("id", "")).upper() == pair_id.upper()) or (
                normalize_abs_path(p.get("localPath", "")) == std_local
            ):
                target_pair = p
                break

        if target_pair is None:
            target_pair = {
                "id": (pair_id or str(uuid.uuid4())).upper(),
                "localPath": std_local,
                "driveTargetPath": std_drive,
                "syncMode": mode,
                "isEnabled": True,
                "createdAt": now_ts,
                "lastSyncedAt": None,
                "lastSyncFileCount": 0,
                "lastSyncTotalBytes": 0,
                "lastError": None,
                "status": "ok",
                "pendingDeletionPlan": None,
            }
            pairs.insert(0, target_pair)
        else:
            target_pair["localPath"] = std_local
            target_pair["driveTargetPath"] = std_drive
            target_pair["syncMode"] = mode
            target_pair["isEnabled"] = True
            target_pair["lastError"] = None
            target_pair["status"] = "ok"

        _write_pairs_unlocked(pairs)
        pair_snapshot = dict(target_pair)

    if not sync_immediately:
        return {
            "ok": True,
            "status": "ok",
            "pair": pair_snapshot,
            "copiedToDrive": 0,
            "copiedToLocal": 0,
            "trashedCount": 0,
            "conflicts": [],
            "totalFiles": pair_snapshot.get("lastSyncFileCount", 0),
            "totalBytes": pair_snapshot.get("lastSyncTotalBytes", 0),
            "knownRelativeFiles": [],
            "syncedAt": now_ts,
            "errorMessage": None,
        }

    rep = sync_pair_by_dict(pair_snapshot, force_remote=True)

    with locked_pairs_file():
        pairs, _ = _decode_raw_pairs_unlocked()
        for idx, p in enumerate(pairs):
            if p.get("id") == pair_snapshot["id"]:
                _apply_sync_report_to_pair(p, rep)
                pair_snapshot = dict(p)
                break
        _write_pairs_unlocked(pairs)

    write_json_atomic(
        status_json_path(),
        {"completedAt": time.time(), "results": {pair_snapshot["id"]: rep}},
        indent=None,
        mode=0o600,
    )
    rep["pair"] = pair_snapshot
    return rep


def upsert_and_sync_shared_url(
    remote_url: str,
    local_path: Optional[str] = None,
    drive_path: Optional[str] = None,
    pair_id: Optional[str] = None,
    folder_id_hint: Optional[str] = None,
    owner_name_hint: Optional[str] = None,
) -> Dict[str, Any]:
    info = inspect_remote_shared_folder(remote_url)
    fid, _ = parse_google_drive_link(remote_url)
    fid = fid or folder_id_hint
    folder_name = info.get("folderName") or (f"Shared_{fid[:8]}" if fid else "Shared_Folder")
    std_local = (
        normalize_abs_path(local_path)
        if local_path
        else (
            info.get("suggestedLocalPath")
            or normalize_abs_path(f"~/Documents/antigravity/00. Shared_GDrive/{folder_name}")
        )
    )
    std_drive = (
        normalize_abs_path(drive_path)
        if drive_path
        else (info.get("suggestedDrivePath") or suggested_drive_target(std_local))
    )

    now_ts = time.time()
    with locked_pairs_file():
        pairs, _ = _decode_raw_pairs_unlocked()
        target_pair = None
        for p in pairs:
            if (
                (pair_id and str(p.get("id", "")).upper() == pair_id.upper())
                or (fid and p.get("remoteFolderID") == fid)
                or normalize_abs_path(p.get("localPath", "")) == std_local
            ):
                target_pair = p
                break

        if target_pair is None:
            target_pair = {
                "id": (pair_id or str(uuid.uuid4())).upper(),
                "localPath": std_local,
                "driveTargetPath": std_drive,
                "syncMode": "remote_shared_link",
                "isEnabled": True,
                "createdAt": now_ts,
                "lastSyncedAt": None,
                "lastSyncFileCount": 0,
                "lastSyncTotalBytes": 0,
                "lastError": None,
                "status": "ok",
                "remoteSharedURL": remote_url.strip(),
                "shareURLString": remote_url.strip(),
                "remoteFolderID": fid,
                "remoteOwnerName": info.get("ownerName") or owner_name_hint,
                "isRemoteLinkBroken": False,
            }
            pairs.insert(0, target_pair)
        else:
            target_pair["localPath"] = std_local
            target_pair["driveTargetPath"] = std_drive
            target_pair["syncMode"] = "remote_shared_link"
            target_pair["remoteSharedURL"] = remote_url.strip()
            target_pair["shareURLString"] = remote_url.strip()
            target_pair["remoteFolderID"] = fid
            if info.get("ownerName") or owner_name_hint:
                target_pair["remoteOwnerName"] = info.get("ownerName") or owner_name_hint
            target_pair["isEnabled"] = True

        _write_pairs_unlocked(pairs)
        pair_snapshot = dict(target_pair)

    rep = sync_remote_shared_folder(remote_url, std_local, std_drive, force_full=True)

    with locked_pairs_file():
        pairs, _ = _decode_raw_pairs_unlocked()
        for p in pairs:
            if p.get("id") == pair_snapshot["id"]:
                _apply_sync_report_to_pair(p, rep)
                pair_snapshot = dict(p)
                break
        _write_pairs_unlocked(pairs)

    write_json_atomic(
        status_json_path(),
        {"completedAt": time.time(), "results": {pair_snapshot["id"]: rep}},
        indent=None,
        mode=0o600,
    )
    rep["pair"] = pair_snapshot
    return rep


def run_sync_all(force_remote: bool = False) -> Dict[str, Any]:
    pairs = load_shared_pairs()
    results: Dict[str, Any] = {}
    removed_ids: Set[str] = set()
    updated_by_id: Dict[str, Dict[str, Any]] = {}

    for p in pairs:
        pid = str(p.get("id") or "").upper()
        l_path = p.get("localPath", "")
        d_path = p.get("driveTargetPath", "")

        if p.get("pendingRemove"):
            if p.get("restoreSymlink", True) and l_path and os.path.islink(l_path):
                os.remove(l_path)
                if d_path and os.path.exists(d_path):
                    shutil.copytree(d_path, l_path, dirs_exist_ok=True)
            if l_path:
                set_finder_badge(l_path, "clear")
            if d_path and os.path.exists(d_path):
                set_finder_badge(d_path, "clear")
            remove_pair_baseline(pid)
            removed_ids.add(pid)
            continue

        if not p.get("isEnabled", True) or not l_path:
            continue

        # Skip pairs waiting for user confirmation of mass deletion
        if p.get("status") == "needs_confirmation":
            continue

        try:
            p_copy = dict(p)
            rep = sync_pair_by_dict(p_copy, force_remote=force_remote)
            if not rep.get("skippedPoll"):
                updated_by_id[pid] = p_copy
                results[pid] = rep
        except Exception as e:
            p_copy = dict(p)
            p_copy["lastError"] = str(e)
            p_copy["status"] = "error"
            updated_by_id[pid] = p_copy

    if removed_ids or updated_by_id:
        with locked_pairs_file():
            cur_pairs, _ = _decode_raw_pairs_unlocked()
            final_pairs: List[Dict[str, Any]] = []
            for cp in cur_pairs:
                cid = str(cp.get("id") or "").upper()
                if cid in removed_ids:
                    continue
                if cid in updated_by_id:
                    up = updated_by_id[cid]
                    for k in (
                        "lastSyncedAt", "lastSyncFileCount", "lastSyncTotalBytes",
                        "lastError", "status", "pendingDeletionPlan", "lastConflicts",
                        "deferredFiles", "isRemoteLinkBroken", "remoteOwnerName",
                    ):
                        if k in up:
                            cp[k] = up[k]
                final_pairs.append(cp)
            _write_pairs_unlocked(final_pairs)

    if results:
        write_json_atomic(
            status_json_path(),
            {"completedAt": time.time(), "results": results},
            indent=None,
            mode=0o600,
        )
    return {"ok": True, "syncedCount": len(results), "results": results}


# ============================================================
# COMMAND CHANNEL (`commands/<epoch_ms>-<uuid>.json` -> `results/<uuid>.json`)
# ============================================================
def submit_command_file(
    op: str,
    pair_id: Optional[str] = None,
    payload: Optional[Dict[str, Any]] = None,
    command_id: Optional[str] = None,
) -> str:
    cmd_id = (command_id or str(uuid.uuid4())).upper()
    epoch_ms = int(time.time() * 1000)
    cmd_dir = commands_dir_path()
    cmd_dir.mkdir(parents=True, exist_ok=True)
    cmd_path = cmd_dir / f"{epoch_ms}-{cmd_id}.json"
    body = {
        "v": 1,
        "id": cmd_id,
        "op": op,
        "pairId": pair_id.upper() if pair_id else None,
        "payload": payload or {},
        "submittedAt": time.time(),
    }
    write_json_atomic(cmd_path, body, indent=None, mode=0o600)
    return cmd_id


def execute_single_command(cmd: Dict[str, Any]) -> Dict[str, Any]:
    cmd_id = str(cmd.get("id") or uuid.uuid4()).upper()
    op = str(cmd.get("op") or "").lower()
    pair_id = str(cmd.get("pairId") or "").upper() if cmd.get("pairId") else None
    payload = cmd.get("payload") if isinstance(cmd.get("payload"), dict) else {}

    try:
        if op in ("add", "update"):
            mode = payload.get("syncMode") or "two_way_mirror"
            local_p = payload.get("localPath") or ""
            drive_p = payload.get("driveTargetPath")
            remote_url = payload.get("remoteSharedURL")
            sync_now = bool(payload.get("syncImmediately", True))

            if mode == "remote_shared_link" and remote_url:
                rep = upsert_and_sync_shared_url(
                    remote_url=remote_url,
                    local_path=local_p,
                    drive_path=drive_p,
                    pair_id=pair_id,
                    folder_id_hint=payload.get("remoteFolderID"),
                    owner_name_hint=payload.get("remoteOwnerName"),
                )
            else:
                rep = upsert_and_sync_pair(
                    local_path=local_p,
                    drive_path=drive_p,
                    mode=mode,
                    pair_id=pair_id,
                    sync_immediately=sync_now,
                )
            return {
                "ok": bool(rep.get("ok", True)),
                "commandId": cmd_id,
                "op": op,
                "completedAt": time.time(),
                "pair": rep.get("pair"),
                "report": rep,
                "errorMessage": rep.get("errorMessage"),
            }

        elif op == "remove":
            restore_symlink = bool(payload.get("restoreSymlink", True))
            removed_pair: Optional[Dict[str, Any]] = None
            with locked_pairs_file():
                pairs, _ = _decode_raw_pairs_unlocked()
                remaining: List[Dict[str, Any]] = []
                for p in pairs:
                    if pair_id and str(p.get("id", "")).upper() == pair_id:
                        removed_pair = p
                    else:
                        remaining.append(p)
                _write_pairs_unlocked(remaining)

            if removed_pair:
                l_path = removed_pair.get("localPath", "")
                d_path = removed_pair.get("driveTargetPath", "")
                if restore_symlink and l_path and os.path.islink(l_path):
                    try:
                        os.remove(l_path)
                        if d_path and os.path.exists(d_path):
                            shutil.copytree(d_path, l_path, dirs_exist_ok=True)
                    except Exception:
                        pass
                if l_path:
                    set_finder_badge(l_path, "clear")
                if d_path and os.path.exists(d_path):
                    set_finder_badge(d_path, "clear")
                remove_pair_baseline(pair_id or "")

            return {
                "ok": True,
                "commandId": cmd_id,
                "op": op,
                "completedAt": time.time(),
                "pair": removed_pair,
                "errorMessage": None,
            }

        elif op in ("enable", "disable"):
            enabled = (op == "enable") if "isEnabled" not in payload else bool(payload["isEnabled"])
            target_snapshot: Optional[Dict[str, Any]] = None
            with locked_pairs_file():
                pairs, _ = _decode_raw_pairs_unlocked()
                for p in pairs:
                    if pair_id and str(p.get("id", "")).upper() == pair_id:
                        p["isEnabled"] = enabled
                        target_snapshot = dict(p)
                        break
                _write_pairs_unlocked(pairs)

            rep = None
            if enabled and target_snapshot and bool(payload.get("syncImmediately", False)):
                rep = sync_pair_by_dict(target_snapshot, force_remote=True)
                with locked_pairs_file():
                    pairs, _ = _decode_raw_pairs_unlocked()
                    for p in pairs:
                        if pair_id and str(p.get("id", "")).upper() == pair_id:
                            _apply_sync_report_to_pair(p, rep)
                            target_snapshot = dict(p)
                            break
                    _write_pairs_unlocked(pairs)

            return {
                "ok": True,
                "commandId": cmd_id,
                "op": op,
                "completedAt": time.time(),
                "pair": target_snapshot,
                "report": rep,
                "errorMessage": None,
            }

        elif op in ("sync", "resolve_confirmation"):
            resolution = payload.get("resolution") if op == "resolve_confirmation" else None
            force_remote = bool(payload.get("force", True))
            target_snapshot = None
            with locked_pairs_file():
                pairs, _ = _decode_raw_pairs_unlocked()
                for p in pairs:
                    if pair_id and str(p.get("id", "")).upper() == pair_id:
                        target_snapshot = dict(p)
                        break

            if not target_snapshot:
                return {
                    "ok": False,
                    "commandId": cmd_id,
                    "op": op,
                    "completedAt": time.time(),
                    "errorMessage": f"Pair {pair_id} not found",
                }

            rep = sync_pair_by_dict(target_snapshot, force_remote=force_remote, resolution=resolution)
            with locked_pairs_file():
                pairs, _ = _decode_raw_pairs_unlocked()
                for p in pairs:
                    if pair_id and str(p.get("id", "")).upper() == pair_id:
                        _apply_sync_report_to_pair(p, rep)
                        target_snapshot = dict(p)
                        break
                _write_pairs_unlocked(pairs)

            write_json_atomic(
                status_json_path(),
                {"completedAt": time.time(), "results": {target_snapshot["id"]: rep}},
                indent=None,
                mode=0o600,
            )
            return {
                "ok": bool(rep.get("ok", False)),
                "commandId": cmd_id,
                "op": op,
                "completedAt": time.time(),
                "pair": target_snapshot,
                "report": rep,
                "errorMessage": rep.get("errorMessage"),
            }

        elif op == "sync_all":
            res = run_sync_all(force_remote=bool(payload.get("force", False)))
            return {
                "ok": True,
                "commandId": cmd_id,
                "op": op,
                "completedAt": time.time(),
                "report": res,
                "errorMessage": None,
            }

        elif op == "set_share":
            target_path = payload.get("path") or ""
            role = payload.get("role") or "status"
            share_res = manage_drive_share_permission(target_path, action=role)
            if share_res.get("ok"):
                std_t = normalize_abs_path(target_path)
                with locked_pairs_file():
                    pairs, _ = _decode_raw_pairs_unlocked()
                    for p in pairs:
                        if (
                            (pair_id and str(p.get("id", "")).upper() == pair_id)
                            or normalize_abs_path(p.get("localPath", "")) == std_t
                            or normalize_abs_path(p.get("driveTargetPath", "")) == std_t
                        ):
                            p["shareAccessLevel"] = share_res.get("accessLevel")
                            if share_res.get("shareUrl"):
                                p["shareURLString"] = share_res.get("shareUrl")
                    _write_pairs_unlocked(pairs)
            return {
                "ok": bool(share_res.get("ok")),
                "commandId": cmd_id,
                "op": op,
                "completedAt": time.time(),
                "shareResult": share_res,
                "errorMessage": share_res.get("errorMessage"),
            }

        else:
            return {
                "ok": False,
                "commandId": cmd_id,
                "op": op,
                "completedAt": time.time(),
                "errorMessage": f"Unsupported command op: {op}",
            }
    except Exception as exc:
        LOGGER.exception("Error executing command %s (%s)", cmd_id, op)
        return {
            "ok": False,
            "commandId": cmd_id,
            "op": op,
            "completedAt": time.time(),
            "errorMessage": str(exc),
        }


def process_pending_commands() -> int:
    cmd_dir = commands_dir_path()
    res_dir = results_dir_path()
    if not cmd_dir.exists():
        return 0
    res_dir.mkdir(parents=True, exist_ok=True)

    try:
        entries = sorted(
            f for f in cmd_dir.iterdir()
            if f.name.endswith(".json") and not f.name.startswith(".")
        )
    except OSError:
        return 0

    processed = 0
    for cmd_file in entries:
        try:
            raw_text = cmd_file.read_text(encoding="utf-8")
            cmd_data = json.loads(raw_text)
        except FileNotFoundError:
            continue
        except Exception as exc:
            LOGGER.warning("Removing malformed command file %s: %s", cmd_file, exc)
            try:
                cmd_file.unlink()
            except OSError:
                pass
            continue

        # Claim the command file atomically so concurrent workers never double-execute
        claimed_path = cmd_file.parent / f".processing.{os.getpid()}.{cmd_file.name}"
        try:
            os.replace(cmd_file, claimed_path)
        except OSError:
            continue

        cmd_id = str(cmd_data.get("id") or cmd_file.stem.split("-", 1)[-1]).upper()
        cmd_data["id"] = cmd_id
        result = execute_single_command(cmd_data)
        write_json_atomic(res_dir / f"{cmd_id}.json", result, indent=None, mode=0o600)
        try:
            claimed_path.unlink()
        except OSError:
            pass
        processed += 1

    # Prune result files older than 10 minutes
    try:
        cutoff = time.time() - 600
        for rf in res_dir.iterdir():
            if rf.name.endswith(".json") and not rf.name.startswith("."):
                try:
                    if rf.stat().st_mtime < cutoff:
                        rf.unlink()
                except OSError:
                    pass
    except OSError:
        pass

    return processed


# ============================================================
# EVENT-DRIVEN DAEMON LOOP (KQUEUE + 300s SAFETY NET)
# ============================================================
def run_daemon(
    poll_interval: float = 2.0,
    periodic_sync_interval: float = 300.0,
) -> None:
    cfg_dir = get_config_dir()
    cfg_dir.mkdir(parents=True, exist_ok=True)
    cmd_dir = commands_dir_path()
    cmd_dir.mkdir(parents=True, exist_ok=True)
    results_dir_path().mkdir(parents=True, exist_ok=True)
    state_dir_path().mkdir(parents=True, exist_ok=True)
    pair_status_dir_path().mkdir(parents=True, exist_ok=True)
    enforce_secret_file_permissions()

    pid_file = daemon_pid_path()
    if pid_file.exists():
        try:
            old_pid = int(pid_file.read_text(encoding="utf-8").strip())
            if old_pid != os.getpid():
                os.kill(old_pid, 0)
                return
        except Exception:
            pass

    pid_file.write_text(str(os.getpid()), encoding="utf-8")
    LOGGER.info("DriveBar syncd v%s started (pid=%d)", HELPER_VERSION, os.getpid())

    # Set up kqueue watching on commands/ and config_dir so we wake immediately on commands or trigger.flag
    kq = None
    watched_fds: List[int] = []
    if hasattr(select, "kqueue"):
        try:
            kq = select.kqueue()
            for watch_path in (cmd_dir, cfg_dir):
                fd = os.open(str(watch_path), os.O_RDONLY)
                watched_fds.append(fd)
                ev = select.kevent(
                    fd,
                    filter=select.KQ_FILTER_VNODE,
                    flags=select.KQ_EV_ADD | select.KQ_EV_ENABLE | select.KQ_EV_CLEAR,
                    fflags=select.KQ_NOTE_WRITE | select.KQ_NOTE_EXTEND | select.KQ_NOTE_RENAME,
                )
                kq.control([ev], 0, 0)
        except Exception as exc:
            LOGGER.warning("kqueue setup fallback to sleep: %s", exc)
            kq = None

    last_periodic = 0.0
    wait_timeout = max(1.0, float(poll_interval))

    try:
        while True:
            try:
                process_pending_commands()

                trig = trigger_flag_path()
                triggered = trig.exists()
                now = time.time()
                if triggered or (now - last_periodic >= periodic_sync_interval):
                    if triggered:
                        try:
                            trig.unlink()
                        except OSError:
                            pass
                    run_sync_all(force_remote=False)
                    last_periodic = time.time()
            except Exception as exc:
                LOGGER.warning("Daemon loop error: %s", exc)

            if kq is not None:
                try:
                    kq.control(None, 4, wait_timeout)
                except Exception:
                    time.sleep(wait_timeout)
            else:
                time.sleep(wait_timeout)
    finally:
        for fd in watched_fds:
            try:
                os.close(fd)
            except OSError:
                pass
        if kq is not None:
            try:
                kq.close()
            except Exception:
                pass


# ============================================================
# DRIVE PERMISSIONS & OAUTH HELPERS
# ============================================================
def resolve_drive_path(input_path: str) -> str:
    std_in = normalize_abs_path(input_path)
    if "/Library/CloudStorage/GoogleDrive-" in std_in:
        return std_in
    pairs = load_shared_pairs()
    for p in pairs:
        l_std = normalize_abs_path(p.get("localPath", ""))
        d_std = normalize_abs_path(p.get("driveTargetPath", ""))
        if std_in == l_std:
            return d_std
        if std_in.startswith(l_std + os.sep):
            rel = std_in[len(l_std) + 1:]
            return os.path.join(d_std, rel)
    return suggested_drive_target(std_in)


def read_drive_item_id(drive_path: str, wait_seconds: float = 4.0) -> Optional[str]:
    deadline = time.time() + wait_seconds
    while True:
        try:
            raw = subprocess.check_output(
                ["/usr/bin/xattr", "-p", "com.google.drivefs.item-id#S", drive_path],
                stderr=subprocess.DEVNULL,
                text=True,
                timeout=2,
            ).strip()
            if raw:
                return raw
        except Exception:
            pass
        if time.time() >= deadline:
            break
        time.sleep(0.3)
    return None


def copy_to_macos_clipboard(text: str) -> None:
    try:
        subprocess.run(["/usr/bin/pbcopy"], input=text.encode("utf-8"), check=False, timeout=2)
    except Exception:
        pass


KEYCHAIN_SERVICE = "com.hunglx.DriveBar.gdrive"
LAUNCH_AGENT_LABEL = "com.hunglx.DriveBar.syncd"


def _is_test_isolated_config_dir() -> bool:
    return bool(os.environ.get("DRIVEBAR_SYNC_CONFIG_DIR", "").strip())


def _keychain_helper_path() -> Optional[Path]:
    candidates = [
        get_config_dir() / "drivebar_keychain_helper",
        Path(__file__).resolve().parent / "drivebar_keychain_helper",
        Path("/Applications/DriveBar.app/Contents/Resources/drivebar_keychain_helper"),
    ]
    for cand in candidates:
        if cand.exists() and os.access(cand, os.X_OK):
            return cand
    return None


def _keychain_read_via_helper(account_name: str) -> Optional[Dict[str, Any]]:
    helper = _keychain_helper_path()
    if helper is None:
        return None
    try:
        proc = subprocess.run(
            [str(helper), "read", "--service", KEYCHAIN_SERVICE, "--account", account_name],
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            timeout=4,
            check=False,
        )
        if proc.returncode == 0 and proc.stdout:
            parsed = json.loads(proc.stdout.decode("utf-8", errors="replace").strip())
            if isinstance(parsed, dict) and parsed:
                return parsed
    except Exception:
        pass
    return None


def _keychain_read_json(account_name: str) -> Optional[Dict[str, Any]]:
    if _is_test_isolated_config_dir():
        return None
    via_helper = _keychain_read_via_helper(account_name)
    if via_helper is not None:
        return via_helper
    # Fallback for migrating legacy Keychain items written by `/usr/bin/security` (stdout only, no argv secret)
    try:
        raw = subprocess.check_output(
            ["/usr/bin/security", "find-generic-password", "-s", KEYCHAIN_SERVICE, "-a", account_name, "-w"],
            stderr=subprocess.DEVNULL,
            text=True,
            timeout=3,
        ).strip()
        if raw:
            parsed = json.loads(raw)
            if isinstance(parsed, dict) and parsed:
                # Migrate: 1) write via stdin-based helper, 2) verify read-back, 3) delete legacy item only after success
                if _keychain_write_json(account_name, parsed):
                    subprocess.run(
                        ["/usr/bin/security", "delete-generic-password", "-s", KEYCHAIN_SERVICE, "-a", account_name],
                        stdout=subprocess.DEVNULL,
                        stderr=subprocess.DEVNULL,
                        timeout=3,
                        check=False,
                    )
                return parsed
    except Exception:
        pass
    return None


def _keychain_write_json(account_name: str, payload: Dict[str, Any]) -> bool:
    """
    Writes secret JSON to macOS Keychain via `drivebar_keychain_helper` over stdin.
    NEVER passes secrets on argv to `/usr/bin/security` or any subprocess.
    """
    if _is_test_isolated_config_dir():
        return False
    helper = _keychain_helper_path()
    if helper is None:
        return False
    try:
        serialized = json.dumps(payload, ensure_ascii=False, separators=(",", ":"))
        proc = subprocess.run(
            [str(helper), "write", "--service", KEYCHAIN_SERVICE, "--account", account_name],
            input=serialized.encode("utf-8"),
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            timeout=4,
            check=False,
        )
        if proc.returncode != 0:
            return False
        readback = _keychain_read_via_helper(account_name)
        return isinstance(readback, dict) and bool(readback)
    except Exception:
        return False


def migrate_plaintext_oauth_to_keychain_if_needed(oauth_path: Path, cfg: Dict[str, Any]) -> Dict[str, Any]:
    """
    One-time automatic migration (§5.3):
    Moves plaintext `access_token`, `refresh_token`, and `client_secret` from
    `~/.config/drivebar-sync/gdrive_oauth.json` into macOS Keychain under service
    `com.hunglx.DriveBar.gdrive` and strips secret fields from the on-disk file
    after verifying Keychain read-back.
    """
    if _is_test_isolated_config_dir():
        return cfg

    client_id = str(cfg.get("client_id", "") or "")
    client_secret = str(cfg.get("client_secret", "") or "")
    migrated_any = False

    if client_secret:
        client_payload = {"client_id": client_id, "client_secret": client_secret}
        if _keychain_write_json("__oauth_client__", client_payload):
            migrated_any = True

    for acc_key in ("personal", "system"):
        acc_obj = cfg.get(acc_key)
        if isinstance(acc_obj, dict) and (acc_obj.get("access_token") or acc_obj.get("refresh_token")):
            kc_payload = {
                "access_token": acc_obj.get("access_token", ""),
                "refresh_token": acc_obj.get("refresh_token", ""),
                "expires_at": acc_obj.get("expires_at", ""),
                "client_id": client_id,
                "client_secret": client_secret,
            }
            if _keychain_write_json(acc_key, kc_payload):
                migrated_any = True
                cfg[acc_key] = {
                    k: v
                    for k, v in acc_obj.items()
                    if k not in ("access_token", "refresh_token", "client_secret")
                }
                cfg[acc_key]["storedInKeychain"] = True

    if migrated_any:
        if "client_secret" in cfg and _keychain_read_json("__oauth_client__"):
            del cfg["client_secret"]
        cfg["keychainService"] = KEYCHAIN_SERVICE
        try:
            write_json_atomic(oauth_path, cfg, indent=2, mode=0o600)
        except Exception:
            pass
    return cfg


def get_valid_oauth_token(account_type: str = "personal") -> Optional[str]:
    oauth_path = get_config_dir() / "gdrive_oauth.json"
    cfg: Dict[str, Any] = {}
    if oauth_path.exists():
        try:
            if stat.S_IMODE(oauth_path.stat().st_mode) != 0o600:
                os.chmod(oauth_path, 0o600)
        except OSError:
            pass
        try:
            loaded = json.loads(oauth_path.read_text(encoding="utf-8"))
            if isinstance(loaded, dict):
                cfg = migrate_plaintext_oauth_to_keychain_if_needed(oauth_path, loaded)
        except Exception:
            cfg = {}

    kc_acc = _keychain_read_json(account_type) or _keychain_read_json("personal") or {}
    kc_client = _keychain_read_json("__oauth_client__") or {}

    file_acc = cfg.get(account_type) or cfg.get("personal") or {}
    if not isinstance(file_acc, dict):
        file_acc = {}

    access_token = kc_acc.get("access_token") or file_acc.get("access_token")
    refresh_token = kc_acc.get("refresh_token") or file_acc.get("refresh_token")
    expires_at_str = kc_acc.get("expires_at") or file_acc.get("expires_at")
    client_id = kc_acc.get("client_id") or kc_client.get("client_id") or cfg.get("client_id", "")
    client_secret = kc_acc.get("client_secret") or kc_client.get("client_secret") or cfg.get("client_secret", "")

    if access_token and expires_at_str:
        try:
            if datetime.datetime.now() < datetime.datetime.fromisoformat(expires_at_str):
                return access_token
        except Exception:
            pass

    if not refresh_token:
        return access_token

    if not client_id or not client_secret:
        return access_token

    data = urllib.parse.urlencode({
        "client_id": client_id,
        "client_secret": client_secret,
        "refresh_token": refresh_token,
        "grant_type": "refresh_token",
    }).encode("utf-8")
    req = urllib.request.Request("https://oauth2.googleapis.com/token", data=data, method="POST")
    try:
        with urllib.request.urlopen(req, timeout=15) as resp:
            body = json.loads(resp.read().decode("utf-8"))
            new_tok = body.get("access_token")
            exp_in = int(body.get("expires_in", 3600))
            if new_tok:
                new_exp = (datetime.datetime.now() + datetime.timedelta(seconds=exp_in - 60)).isoformat()
                kc_payload = {
                    "access_token": new_tok,
                    "refresh_token": refresh_token,
                    "expires_at": new_exp,
                    "client_id": client_id,
                    "client_secret": client_secret,
                }
                stored_kc = _keychain_write_json(account_type, kc_payload)
                if not stored_kc and oauth_path.exists():
                    file_acc["access_token"] = new_tok
                    file_acc["expires_at"] = new_exp
                    cfg[account_type] = file_acc
                    write_json_atomic(oauth_path, cfg, indent=2, mode=0o600)
                elif oauth_path.exists():
                    file_acc["expires_at"] = new_exp
                    file_acc["storedInKeychain"] = True
                    file_acc.pop("access_token", None)
                    file_acc.pop("refresh_token", None)
                    cfg[account_type] = file_acc
                    cfg.pop("client_secret", None)
                    write_json_atomic(oauth_path, cfg, indent=2, mode=0o600)
                return new_tok
    except Exception:
        pass
    return access_token


def manage_drive_share_permission(input_path: str, action: str = "status") -> Dict[str, Any]:
    """action: 'status' | 'reader' | 'writer' | 'restricted'"""
    std_in = normalize_abs_path(input_path)
    drive_path = resolve_drive_path(std_in)
    if not os.path.exists(drive_path) and os.path.isdir(std_in):
        upsert_and_sync_pair(std_in, mode="two_way_mirror")
        drive_path = resolve_drive_path(std_in)

    is_dir = os.path.isdir(drive_path) or drive_path.endswith("/")
    file_id = read_drive_item_id(drive_path, wait_seconds=4.5)
    if not file_id:
        return {
            "ok": False,
            "fileId": None,
            "accessLevel": "unknown",
            "shareUrl": None,
            "errorMessage": "Google Drive Desktop đang tạo ID đám mây cho thư mục này, vui lòng thử lại sau vài giây.",
        }

    share_url = (
        f"https://drive.google.com/drive/folders/{file_id}?usp=sharing"
        if is_dir
        else f"https://drive.google.com/file/d/{file_id}/view?usp=sharing"
    )

    account_type = "system" if "GoogleDrive-ai@spmph.edu.vn" in drive_path else "personal"
    tok = get_valid_oauth_token(account_type=account_type) or get_valid_oauth_token(account_type="personal")
    if not tok:
        return {
            "ok": False,
            "fileId": file_id,
            "accessLevel": "unknown",
            "shareUrl": share_url,
            "errorMessage": "Không tìm thấy token OAuth Google Drive hợp lệ.",
        }

    headers = {"Authorization": f"Bearer {tok}", "Content-Type": "application/json"}
    try:
        if action in ("reader", "writer"):
            payload = json.dumps({"role": action, "type": "anyone"}).encode("utf-8")
            req = urllib.request.Request(
                f"https://www.googleapis.com/drive/v3/files/{file_id}/permissions",
                data=payload,
                headers=headers,
                method="POST",
            )
            with urllib.request.urlopen(req, timeout=15) as resp:
                _ = resp.read()
            copy_to_macos_clipboard(share_url)
            return {
                "ok": True,
                "fileId": file_id,
                "accessLevel": action,
                "shareUrl": share_url,
                "errorMessage": None,
            }

        list_req = urllib.request.Request(
            f"https://www.googleapis.com/drive/v3/files/{file_id}/permissions?fields=permissions(id,type,role)",
            headers=headers,
            method="GET",
        )
        with urllib.request.urlopen(list_req, timeout=15) as list_resp:
            perms_data = json.loads(list_resp.read().decode("utf-8"))

        perms = perms_data.get("permissions", [])
        anyone_perms = [p for p in perms if p.get("type") == "anyone" or p.get("id") == "anyoneWithLink"]

        if action == "restricted":
            for ap in anyone_perms:
                pid = ap.get("id", "anyoneWithLink")
                del_req = urllib.request.Request(
                    f"https://www.googleapis.com/drive/v3/files/{file_id}/permissions/{pid}",
                    headers=headers,
                    method="DELETE",
                )
                try:
                    with urllib.request.urlopen(del_req, timeout=15) as _:
                        pass
                except Exception:
                    pass
            return {
                "ok": True,
                "fileId": file_id,
                "accessLevel": "restricted",
                "shareUrl": share_url,
                "errorMessage": None,
            }

        if not anyone_perms:
            cur_level = "restricted"
        else:
            roles = {ap.get("role", "reader") for ap in anyone_perms}
            cur_level = "writer" if ("writer" in roles or "organizer" in roles or "fileOrganizer" in roles) else "reader"
        return {
            "ok": True,
            "fileId": file_id,
            "accessLevel": cur_level,
            "shareUrl": share_url,
            "errorMessage": None,
        }
    except urllib.error.HTTPError as he:
        err_body = ""
        try:
            err_body = he.read().decode("utf-8")[:160]
        except Exception:
            pass
        return {
            "ok": False,
            "fileId": file_id,
            "accessLevel": "unknown",
            "shareUrl": share_url,
            "errorMessage": f"Google Drive API ({he.code}): {err_body}",
        }
    except Exception as e:
        return {
            "ok": False,
            "fileId": file_id,
            "accessLevel": "unknown",
            "shareUrl": share_url,
            "errorMessage": str(e),
        }


def ensure_daemon_started(allow_standalone_spawn: bool = False) -> None:
    pid_file = daemon_pid_path()
    if pid_file.exists():
        try:
            old_pid = int(pid_file.read_text(encoding="utf-8").strip())
            os.kill(old_pid, 0)
            return
        except Exception:
            pass

    # Prefer launchd LaunchAgent (`com.hunglx.DriveBar.syncd`, §5.1)
    plist_path = Path.home() / "Library" / "LaunchAgents" / f"{LAUNCH_AGENT_LABEL}.plist"
    if plist_path.exists():
        uid = os.getuid()
        domain_target = f"gui/{uid}"
        service_target = f"{domain_target}/{LAUNCH_AGENT_LABEL}"
        try:
            r = subprocess.run(
                ["/bin/launchctl", "kickstart", service_target],
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
                timeout=3,
                check=False,
            )
            if r.returncode != 0:
                subprocess.run(
                    ["/bin/launchctl", "bootstrap", domain_target, str(plist_path)],
                    stdout=subprocess.DEVNULL,
                    stderr=subprocess.DEVNULL,
                    timeout=3,
                    check=False,
                )
            return
        except Exception:
            pass

    if allow_standalone_spawn:
        try:
            subprocess.Popen(
                [sys.executable, os.path.abspath(__file__), "--daemon"],
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
                stdin=subprocess.DEVNULL,
                start_new_session=True,
            )
        except Exception:
            pass


def main() -> None:
    parser = argparse.ArgumentParser(description="DriveBar Local Folder <-> Google Drive Sync Engine")
    parser.add_argument("--version", action="store_true", help="Print helper version and exit")
    parser.add_argument("--daemon", action="store_true", help="Run continuous event-driven sync daemon (managed by launchd)")
    parser.add_argument("--standalone-daemon", action="store_true", help="Spawn or run standalone background daemon for manual CLI use")
    parser.add_argument("--process-commands", action="store_true", help="Process all queued commands in commands/ once")
    parser.add_argument("--sync-all", action="store_true", help="Sync all enabled pairs in sync_pairs.json")
    parser.add_argument("--quick-action", nargs="+", help="Finder Quick Action entry point for selected folders")
    parser.add_argument("--quick-action-paste-link", nargs="*", help="Finder Quick Action entry point to paste shared Google Drive link and copy into folder")
    parser.add_argument("--local", help="Local Mac folder path")
    parser.add_argument("--drive", help="Google Drive target folder path")
    parser.add_argument("--mode", default="two_way_mirror", choices=["two_way_mirror", "symlink_to_drive"])
    parser.add_argument("--state-file", help="Optional legacy JSON file containing knownRelativeFiles & lastSyncedAt")
    parser.add_argument("--untag", help="Remove Finder sync tag from folder path")
    parser.add_argument("--restore-symlink", nargs=2, metavar=("LOCAL_PATH", "DRIVE_PATH"), help="Restore symlink to real folder")
    parser.add_argument("--share-status", help="Check current Google Drive share permission for local/Drive path")
    parser.add_argument("--share-set", nargs=2, metavar=("ROLE", "PATH"), help="Set Google Drive share permission: reader | writer | restricted")
    parser.add_argument("--inspect-shared-url", help="Inspect metadata and suggested destination for a shared Google Drive URL")
    parser.add_argument("--sync-shared-url", help="Download and subscribe to a shared Google Drive folder URL")
    args = parser.parse_args()

    if args.version:
        print(HELPER_VERSION)
        return

    if args.daemon:
        run_daemon()
        return

    if args.standalone_daemon:
        ensure_daemon_started(allow_standalone_spawn=True)
        return

    if args.process_commands:
        cnt = process_pending_commands()
        print(json.dumps({"ok": True, "processed": cnt}))
        return

    if args.inspect_shared_url:
        res = inspect_remote_shared_folder(args.inspect_shared_url)
        print(json.dumps(res, ensure_ascii=False))
        return

    if args.sync_shared_url:
        ensure_daemon_started()
        res = upsert_and_sync_shared_url(args.sync_shared_url, local_path=args.local, drive_path=args.drive)
        print(json.dumps(res, ensure_ascii=False))
        return

    if args.share_status:
        res = manage_drive_share_permission(args.share_status, action="status")
        print(json.dumps(res, ensure_ascii=False))
        return

    if args.share_set:
        role, target_p = args.share_set
        res = manage_drive_share_permission(target_p, action=role)
        print(json.dumps(res, ensure_ascii=False))
        return

    if args.quick_action_paste_link is not None:
        ensure_daemon_started()
        parent_dir = ""
        if args.quick_action_paste_link:
            first_raw = args.quick_action_paste_link[0]
            abs_p = normalize_abs_path(first_raw)
            if not os.path.isdir(abs_p) and not os.path.islink(abs_p):
                abs_p = os.path.dirname(abs_p)
            parent_dir = abs_p
        if not parent_dir:
            try:
                out = subprocess.check_output(
                    ["/usr/bin/osascript", "-e", 'tell application "Finder" to if (count of Finder windows) > 0 then get POSIX path of (target of front Finder window as alias)'],
                    stderr=subprocess.DEVNULL,
                    text=True,
                    timeout=2,
                ).strip()
                if out and os.path.isdir(out):
                    parent_dir = normalize_abs_path(out)
            except Exception:
                pass
        enc_parent = urllib.parse.quote(parent_dir) if parent_dir else ""
        try:
            subprocess.run(
                ["/usr/bin/open", f"drivebar://sync-shared-url?parent={enc_parent}"],
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
                timeout=3,
            )
        except Exception:
            pass
        return

    if args.quick_action:
        ensure_daemon_started()
        for raw_path in args.quick_action:
            abs_p = normalize_abs_path(raw_path)
            if not os.path.isdir(abs_p) and not os.path.islink(abs_p):
                abs_p = os.path.dirname(abs_p)
            try:
                cmd_id = submit_command_file(
                    op="add",
                    payload={"localPath": abs_p, "syncMode": "two_way_mirror", "syncImmediately": True},
                )
                process_pending_commands()
                _ = cmd_id
            except Exception:
                pass
            enc = urllib.parse.quote(abs_p)
            try:
                subprocess.run(
                    ["/usr/bin/open", f"drivebar://sync-folder?mode=dialog&path={enc}"],
                    stdout=subprocess.DEVNULL,
                    stderr=subprocess.DEVNULL,
                    timeout=3,
                )
            except Exception:
                pass
        return

    if args.sync_all:
        process_pending_commands()
        res = run_sync_all()
        print(json.dumps(res, ensure_ascii=False))
        return

    if args.untag:
        set_finder_tag(normalize_abs_path(args.untag), False)
        print(json.dumps({"ok": True}))
        return

    if args.restore_symlink:
        l_path, d_path = args.restore_symlink
        l_path = normalize_abs_path(l_path)
        d_path = normalize_abs_path(d_path)
        if os.path.islink(l_path):
            os.remove(l_path)
            if os.path.exists(d_path):
                shutil.copytree(d_path, l_path, dirs_exist_ok=True)
        set_finder_tag(l_path, False)
        print(json.dumps({"ok": True}))
        return

    if not args.local:
        parser.error("--local or --sync-all is required")

    if not args.state_file:
        try:
            res = upsert_and_sync_pair(args.local, args.drive, mode=args.mode)
            print(json.dumps(res, ensure_ascii=False))
        except Exception as e:
            print(json.dumps({
                "ok": False,
                "copiedToDrive": 0,
                "copiedToLocal": 0,
                "trashedCount": 0,
                "totalFiles": 0,
                "totalBytes": 0,
                "knownRelativeFiles": [],
                "syncedAt": time.time(),
                "errorMessage": str(e),
            }, ensure_ascii=False))
        return

    drive_path = args.drive or suggested_drive_target(args.local)
    known_files = []
    last_synced_at = 0.0
    if args.state_file and os.path.exists(args.state_file):
        try:
            with open(args.state_file, "r", encoding="utf-8") as f:
                st_data = json.load(f)
                known_files = st_data.get("knownRelativeFiles", [])
                last_synced_at = float(st_data.get("lastSyncedAt", 0.0) or 0.0)
        except Exception:
            pass

    try:
        res = sync_single_pair(
            local_path=args.local,
            drive_target_path=drive_path,
            mode=args.mode,
            known_files=known_files,
            last_synced_at=last_synced_at,
        )
        print(json.dumps(res, ensure_ascii=False))
    except Exception as e:
        print(json.dumps({
            "ok": False,
            "copiedToDrive": 0,
            "copiedToLocal": 0,
            "trashedCount": 0,
            "totalFiles": 0,
            "totalBytes": 0,
            "knownRelativeFiles": known_files,
            "syncedAt": time.time(),
            "errorMessage": str(e),
        }, ensure_ascii=False))


if __name__ == "__main__":
    main()
