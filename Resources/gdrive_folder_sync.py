#!/opt/homebrew/bin/python3.11
from __future__ import annotations
"""
Động cơ đồng bộ 2 chiều thời gian thực (Two-way Mirror & Symlink) giữa các thư mục
trên ổ cứng Mac (ví dụ ~/Documents/antigravity/...) và Google Drive Desktop (~/Library/CloudStorage/GoogleDrive-.../My Drive/...).
Hoạt động độc lập qua launchd (com.hunglx.drivebar.foldersync) + đồng bộ trạng thái tức thì với DriveBar.app qua ~/.config/drivebar-sync/sync_pairs.json.
"""
import argparse
import json
import os
import plistlib
import shutil
import stat
import subprocess
import sys
import time
import uuid
from pathlib import Path

CONFIG_DIR = Path.home() / ".config" / "drivebar-sync"
PAIRS_JSON_PATH = CONFIG_DIR / "sync_pairs.json"
STATUS_JSON_PATH = CONFIG_DIR / "last_sync_result.json"
TRIGGER_FLAG_PATH = CONFIG_DIR / "trigger.flag"
DAEMON_PID_PATH = CONFIG_DIR / "daemon.pid"
FINDER_TAG_NAME = "Đồng bộ GDrive\n2"  # Green tag (2) in macOS Finder

IGNORED_DIRS = {
    ".git", "node_modules", "__pycache__", ".build", ".swiftpm",
    ".venv", "venv", ".pytest_cache", ".mypy_cache", ".next",
    ".nuxt", ".tmp.driveupload", ".tmp", ".Trash"
}

IGNORED_FILES = {
    ".DS_Store", ".localized", "Icon\r"
}

CLOUD_STUB_EXTS = {
    ".gdoc", ".gsheet", ".gslides", ".gform", ".gdraw", ".gmap", ".gsite", ".gscript"
}

SF_DATALESS = 0x40000000


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
    std_local = os.path.abspath(os.path.expanduser(local_path))
    my_drive = find_my_drive_root()
    base_root = os.path.join(my_drive, base_subfolder.strip()) if base_subfolder.strip() else my_drive

    antigravity_root = os.path.abspath(os.path.expanduser("~/Documents/antigravity"))
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
    badge_helper = CONFIG_DIR / "folder_badge_helper"
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
    if not os.path.lexists(path):
        return False
    trash_dir = os.path.expanduser("~/.Trash")
    os.makedirs(trash_dir, exist_ok=True)
    base = os.path.basename(path)
    dst = os.path.join(trash_dir, f"{base}_{int(time.time())}_{uuid.uuid4().hex[:6]}")
    try:
        shutil.move(path, dst)
        return True
    except Exception:
        try:
            if os.path.isdir(path) and not os.path.islink(path):
                shutil.rmtree(path)
            else:
                os.remove(path)
            return True
        except Exception:
            return False


def scan_tree(root_path: str, is_cloud: bool):
    dirs = set()
    files = {}
    if not os.path.exists(root_path):
        return dirs, files

    for dirpath, dirnames, filenames in os.walk(root_path, followlinks=False):
        dirnames[:] = [
            d for d in dirnames
            if d not in IGNORED_DIRS and not d.startswith(".tmp") and not os.path.islink(os.path.join(dirpath, d))
        ]
        rel_dir = os.path.relpath(dirpath, root_path)
        if rel_dir != ".":
            dirs.add(rel_dir)

        for fname in filenames:
            if (
                fname in IGNORED_FILES
                or fname.startswith("~$")
                or fname.startswith(".~")
                or fname.startswith(".tmp")
                or fname.startswith(".drivebar_sync_tmp_")
            ):
                continue
            full_path = os.path.join(dirpath, fname)
            try:
                st = os.lstat(full_path)
            except OSError:
                continue
            if stat.S_ISLNK(st.st_mode) or not stat.S_ISREG(st.st_mode):
                continue

            rel_file = fname if rel_dir == "." else os.path.join(rel_dir, fname)
            ext = os.path.splitext(fname)[1].lower()
            is_dataless = bool(is_cloud and hasattr(st, "st_flags") and (st.st_flags & SF_DATALESS))
            is_stub = ext in CLOUD_STUB_EXTS
            files[rel_file] = {
                "mtime": float(st.st_mtime),
                "size": int(st.st_size),
                "is_dataless": is_dataless,
                "is_stub": is_stub,
            }
    return dirs, files


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


def sync_single_pair(
    local_path: str,
    drive_target_path: str,
    mode: str = "two_way_mirror",
    known_files: list | None = None,
    last_synced_at: float | None = None,
) -> dict:
    local_path = os.path.abspath(os.path.expanduser(local_path))
    drive_target_path = os.path.abspath(os.path.expanduser(drive_target_path))
    prev_known = set(known_files or [])
    last_sync_ts = float(last_synced_at or 0.0)

    os.makedirs(os.path.dirname(drive_target_path), exist_ok=True)

    if mode == "symlink_to_drive":
        os.makedirs(drive_target_path, exist_ok=True)
        if not os.path.islink(local_path):
            if os.path.exists(local_path):
                l_dirs, l_files = scan_tree(local_path, is_cloud=False)
                for d in sorted(l_dirs):
                    os.makedirs(os.path.join(drive_target_path, d), exist_ok=True)
                for rel_f, meta in l_files.items():
                    copy_atomic(
                        os.path.join(local_path, rel_f),
                        os.path.join(drive_target_path, rel_f),
                        meta["mtime"],
                    )
                move_to_trash(local_path)
            os.symlink(drive_target_path, local_path)
        else:
            cur_target = os.path.abspath(os.readlink(local_path))
            if cur_target != drive_target_path:
                os.remove(local_path)
                os.symlink(drive_target_path, local_path)

        _, d_files = scan_tree(drive_target_path, is_cloud=True)
        total_files = len(d_files)
        total_bytes = sum(m["size"] for m in d_files.values())
        return {
            "ok": True,
            "copiedToDrive": total_files,
            "copiedToLocal": 0,
            "trashedCount": 0,
            "totalFiles": total_files,
            "totalBytes": total_bytes,
            "knownRelativeFiles": sorted(d_files.keys()),
            "syncedAt": time.time(),
            "errorMessage": None,
        }

    # Two-way mirror mode
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

    for rel_dir in sorted(l_dirs | d_dirs):
        in_l = rel_dir in l_dirs
        in_d = rel_dir in d_dirs
        prefix = rel_dir + os.sep
        if in_l and not in_d:
            if not any(k.startswith(prefix) for k in prev_known):
                os.makedirs(os.path.join(drive_target_path, rel_dir), exist_ok=True)
        elif in_d and not in_l:
            if not any(k.startswith(prefix) for k in prev_known):
                os.makedirs(os.path.join(local_path, rel_dir), exist_ok=True)

    copied_to_drive = 0
    copied_to_local = 0
    trashed_count = 0
    current_known = set()

    all_rel_files = sorted(set(l_files.keys()) | set(d_files.keys()))
    for rel_f in all_rel_files:
        l_full = os.path.join(local_path, rel_f)
        d_full = os.path.join(drive_target_path, rel_f)
        lm = l_files.get(rel_f)
        dm = d_files.get(rel_f)

        if lm and dm:
            diff = lm["mtime"] - dm["mtime"]
            if abs(diff) <= 2.0 and lm["size"] == dm["size"]:
                current_known.add(rel_f)
            elif diff > 2.0 or (abs(diff) <= 2.0 and lm["mtime"] >= dm["mtime"]):
                if copy_atomic(l_full, d_full, lm["mtime"]):
                    copied_to_drive += 1
                current_known.add(rel_f)
            else:
                if not dm["is_dataless"] and not dm["is_stub"]:
                    if copy_atomic(d_full, l_full, dm["mtime"]):
                        copied_to_local += 1
                current_known.add(rel_f)
        elif lm and not dm:
            if rel_f in prev_known and lm["mtime"] <= (last_sync_ts + 2.0):
                if move_to_trash(l_full):
                    trashed_count += 1
            else:
                if copy_atomic(l_full, d_full, lm["mtime"]):
                    copied_to_drive += 1
                    current_known.add(rel_f)
        elif dm and not lm:
            if rel_f in prev_known and dm["mtime"] <= (last_sync_ts + 2.0):
                if move_to_trash(d_full):
                    trashed_count += 1
            elif not dm["is_dataless"] and not dm["is_stub"]:
                if copy_atomic(d_full, l_full, dm["mtime"]):
                    copied_to_local += 1
                    current_known.add(rel_f)
            else:
                current_known.add(rel_f)

    set_finder_tag(local_path, True)
    _, final_l_files = scan_tree(local_path, is_cloud=False)
    total_files = len(final_l_files)
    total_bytes = sum(m["size"] for m in final_l_files.values())

    return {
        "ok": True,
        "copiedToDrive": copied_to_drive,
        "copiedToLocal": copied_to_local,
        "trashedCount": trashed_count,
        "totalFiles": total_files,
        "totalBytes": total_bytes,
        "knownRelativeFiles": sorted(current_known),
        "syncedAt": time.time(),
        "errorMessage": None,
    }


def load_shared_pairs() -> list:
    CONFIG_DIR.mkdir(parents=True, exist_ok=True)
    if PAIRS_JSON_PATH.exists():
        try:
            return json.loads(PAIRS_JSON_PATH.read_text(encoding="utf-8"))
        except Exception:
            pass
    return []


def save_shared_pairs(pairs: list) -> None:
    CONFIG_DIR.mkdir(parents=True, exist_ok=True)
    tmp = CONFIG_DIR / f"sync_pairs_tmp_{uuid.uuid4().hex}.json"
    tmp.write_text(json.dumps(pairs, indent=2, ensure_ascii=False), encoding="utf-8")
    os.replace(tmp, PAIRS_JSON_PATH)


def parse_google_drive_link(url_or_id: str) -> tuple[str | None, str | None]:
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


def parse_rfc3339_epoch(ts_str: str | None) -> float:
    if not ts_str:
        return time.time()
    from datetime import datetime, timezone
    try:
        clean = ts_str.replace("Z", "+00:00")
        return datetime.fromisoformat(clean).timestamp()
    except Exception:
        return time.time()


def sanitize_filename(name: str) -> str:
    cleaned = (name or "Untitled").replace("/", "_").replace("\0", "").strip()
    return cleaned or "Untitled"


def inspect_remote_shared_folder(url_or_id: str) -> dict:
    import urllib.error
    import urllib.parse
    import urllib.request

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
        "?supportsAllDrives=true&fields=id,name,mimeType,trashed,owners(displayName,emailAddress),capabilities(canEdit,canAddChildren,canDownload)"
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


def sync_remote_shared_folder(
    remote_url: str,
    local_path: str,
    drive_mirror_path: str | None = None,
) -> dict:
    """
    Additive & Update-Only sync from a shared Google Drive folder URL to local_path (and optional drive_mirror_path).
    NEVER deletes local files even if removed remotely or if the shared link is locked/revoked.
    When locked/revoked, marks the folder with the red broken-link badge ('broken').
    """
    import urllib.parse
    import urllib.request

    local_path = os.path.abspath(os.path.expanduser(local_path))
    os.makedirs(local_path, exist_ok=True)
    if drive_mirror_path:
        drive_mirror_path = os.path.abspath(os.path.expanduser(drive_mirror_path))

    info = inspect_remote_shared_folder(remote_url)
    if not info.get("ok"):
        _, l_files = scan_tree(local_path, is_cloud=False)
        total_files = len(l_files)
        total_bytes = sum(m["size"] for m in l_files.values())
        is_broken = bool(info.get("isBroken"))
        if is_broken:
            set_finder_badge(local_path, "broken")
            if drive_mirror_path and os.path.exists(drive_mirror_path) and drive_mirror_path != local_path:
                set_finder_badge(drive_mirror_path, "broken")
        return {
            "ok": False,
            "isBrokenLink": is_broken,
            "copiedToDrive": 0,
            "copiedToLocal": 0,
            "trashedCount": 0,
            "totalFiles": total_files,
            "totalBytes": total_bytes,
            "knownRelativeFiles": sorted(l_files.keys()),
            "syncedAt": time.time(),
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

    downloaded_count = 0
    copied_to_drive = 0

    def _download_stream(download_url: str, dst_file: str, mtime: float, item_rk: str | None = None, item_id: str | None = None) -> bool:
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

    def _sync_folder_recursive(remote_folder_id: str, cur_local_dir: str, folder_rk: str | None = None):
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
                remote_mtime = parse_rfc3339_epoch(item.get("modifiedTime"))

                if mime == "application/vnd.google-apps.folder":
                    sub_local = os.path.join(cur_local_dir, raw_name)
                    _sync_folder_recursive(item_id, sub_local, item_rk)
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
        else:
            # Single shared file link
            fname = info.get("folderName") or f"Shared_{fid[:8]}"
            dst_file = os.path.join(local_path, fname)
            dl_url = f"https://www.googleapis.com/drive/v3/files/{fid}?alt=media&supportsAllDrives=true"
            if _download_stream(dl_url, dst_file, time.time(), rk, fid):
                downloaded_count += 1
    except Exception as e:
        _, l_files = scan_tree(local_path, is_cloud=False)
        return {
            "ok": False,
            "isBrokenLink": False,
            "copiedToDrive": 0,
            "copiedToLocal": downloaded_count,
            "trashedCount": 0,
            "totalFiles": len(l_files),
            "totalBytes": sum(m["size"] for m in l_files.values()),
            "knownRelativeFiles": sorted(l_files.keys()),
            "syncedAt": time.time(),
            "folderName": info.get("folderName"),
            "ownerName": info.get("ownerName"),
            "errorMessage": str(e),
        }

    # Optional additive mirror from local_path into user's own Google Drive (drive_mirror_path)
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
                    os.path.join(local_path, rel_f),
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
        "isBrokenLink": False,
        "copiedToDrive": copied_to_drive,
        "copiedToLocal": downloaded_count,
        "trashedCount": 0,
        "totalFiles": total_files,
        "totalBytes": total_bytes,
        "knownRelativeFiles": sorted(l_files.keys()),
        "syncedAt": time.time(),
        "folderId": fid,
        "folderName": info.get("folderName"),
        "ownerName": info.get("ownerName"),
        "errorMessage": None,
    }


def upsert_and_sync_shared_url(
    remote_url: str,
    local_path: str | None = None,
    drive_path: str | None = None,
) -> dict:
    info = inspect_remote_shared_folder(remote_url)
    fid, _ = parse_google_drive_link(remote_url)
    folder_name = info.get("folderName") or (f"Shared_{fid[:8]}" if fid else "Shared_Folder")
    std_local = (
        os.path.abspath(os.path.expanduser(local_path))
        if local_path
        else (info.get("suggestedLocalPath") or os.path.abspath(os.path.expanduser(f"~/Documents/antigravity/00. Shared_GDrive/{folder_name}")))
    )
    std_drive = (
        os.path.abspath(os.path.expanduser(drive_path))
        if drive_path
        else (info.get("suggestedDrivePath") or suggested_drive_target(std_local))
    )

    pairs = load_shared_pairs()
    target_pair = None
    for p in pairs:
        if (
            (fid and p.get("remoteFolderID") == fid)
            or os.path.abspath(os.path.expanduser(p.get("localPath", ""))) == std_local
        ):
            target_pair = p
            break

    now_ts = time.time()
    if target_pair is None:
        target_pair = {
            "id": str(uuid.uuid4()).upper(),
            "localPath": std_local,
            "driveTargetPath": std_drive,
            "syncMode": "remote_shared_link",
            "isEnabled": True,
            "createdAt": now_ts,
            "lastSyncedAt": None,
            "lastSyncFileCount": 0,
            "lastSyncTotalBytes": 0,
            "lastError": None,
            "knownRelativeFiles": [],
            "remoteSharedURL": remote_url.strip(),
            "remoteFolderID": fid,
            "remoteOwnerName": info.get("ownerName"),
            "isRemoteLinkBroken": False,
        }
        pairs.insert(0, target_pair)
    else:
        target_pair["localPath"] = std_local
        target_pair["driveTargetPath"] = std_drive
        target_pair["syncMode"] = "remote_shared_link"
        target_pair["remoteSharedURL"] = remote_url.strip()
        target_pair["remoteFolderID"] = fid
        if info.get("ownerName"):
            target_pair["remoteOwnerName"] = info.get("ownerName")
        target_pair["isEnabled"] = True

    rep = sync_remote_shared_folder(remote_url, std_local, std_drive)
    target_pair["lastSyncedAt"] = rep["syncedAt"]
    target_pair["lastSyncFileCount"] = rep["totalFiles"]
    target_pair["lastSyncTotalBytes"] = rep["totalBytes"]
    target_pair["knownRelativeFiles"] = rep["knownRelativeFiles"]
    target_pair["lastError"] = rep["errorMessage"]
    target_pair["isRemoteLinkBroken"] = bool(rep.get("isBrokenLink", False))
    if rep.get("ownerName"):
        target_pair["remoteOwnerName"] = rep.get("ownerName")

    save_shared_pairs(pairs)
    STATUS_JSON_PATH.write_text(
        json.dumps({"completedAt": time.time(), "results": {target_pair["id"]: rep}}, ensure_ascii=False),
        encoding="utf-8",
    )
    return rep


def run_sync_all() -> dict:
    pairs = load_shared_pairs()
    updated_pairs = []
    results = {}
    for p in pairs:
        if not p.get("isEnabled", True):
            updated_pairs.append(p)
            continue
        l_path = p.get("localPath", "")
        d_path = p.get("driveTargetPath", "")
        mode = p.get("syncMode", "two_way_mirror")
        known = p.get("knownRelativeFiles", [])
        last_ts = p.get("lastSyncedAt")
        remote_url = p.get("remoteSharedURL")

        if not l_path:
            updated_pairs.append(p)
            continue

        # Handle pending cleanup/removal flags if any
        if p.get("pendingRemove"):
            if p.get("restoreSymlink", True) and os.path.islink(l_path):
                os.remove(l_path)
                if d_path and os.path.exists(d_path):
                    shutil.copytree(d_path, l_path, dirs_exist_ok=True)
            set_finder_badge(l_path, "clear")
            if d_path and os.path.exists(d_path):
                set_finder_badge(d_path, "clear")
            continue

        try:
            if mode == "remote_shared_link" and remote_url:
                rep = sync_remote_shared_folder(remote_url, l_path, d_path)
                p["isRemoteLinkBroken"] = bool(rep.get("isBrokenLink", False))
                if rep.get("ownerName"):
                    p["remoteOwnerName"] = rep.get("ownerName")
            else:
                rep = sync_single_pair(l_path, d_path, mode=mode, known_files=known, last_synced_at=last_ts)
                p["isRemoteLinkBroken"] = False
            p["lastSyncedAt"] = rep["syncedAt"]
            p["lastSyncFileCount"] = rep["totalFiles"]
            p["lastSyncTotalBytes"] = rep["totalBytes"]
            p["knownRelativeFiles"] = rep["knownRelativeFiles"]
            p["lastError"] = rep["errorMessage"]
            results[p.get("id", l_path)] = rep
        except Exception as e:
            p["lastError"] = str(e)
        updated_pairs.append(p)

    save_shared_pairs(updated_pairs)
    STATUS_JSON_PATH.write_text(json.dumps({"completedAt": time.time(), "results": results}, ensure_ascii=False), encoding="utf-8")
    return {"ok": True, "syncedCount": len(results)}


def upsert_and_sync_pair(local_path: str, drive_path: str | None = None, mode: str = "two_way_mirror") -> dict:
    std_local = os.path.abspath(os.path.expanduser(local_path))
    std_drive = os.path.abspath(os.path.expanduser(drive_path)) if drive_path else suggested_drive_target(std_local)
    pairs = load_shared_pairs()
    target_pair = None
    for p in pairs:
        if os.path.abspath(os.path.expanduser(p.get("localPath", ""))) == std_local:
            target_pair = p
            break

    now_ts = time.time()
    if target_pair is None:
        target_pair = {
            "id": str(uuid.uuid4()).upper(),
            "localPath": std_local,
            "driveTargetPath": std_drive,
            "syncMode": mode,
            "isEnabled": True,
            "createdAt": now_ts,
            "lastSyncedAt": None,
            "lastSyncFileCount": 0,
            "lastSyncTotalBytes": 0,
            "lastError": None,
            "knownRelativeFiles": [],
        }
        pairs.insert(0, target_pair)
    else:
        target_pair["driveTargetPath"] = std_drive
        target_pair["syncMode"] = mode
        target_pair["isEnabled"] = True
        target_pair["lastError"] = None

    rep = sync_single_pair(
        local_path=std_local,
        drive_target_path=std_drive,
        mode=mode,
        known_files=target_pair.get("knownRelativeFiles", []),
        last_synced_at=target_pair.get("lastSyncedAt"),
    )
    target_pair["lastSyncedAt"] = rep["syncedAt"]
    target_pair["lastSyncFileCount"] = rep["totalFiles"]
    target_pair["lastSyncTotalBytes"] = rep["totalBytes"]
    target_pair["knownRelativeFiles"] = rep["knownRelativeFiles"]
    target_pair["lastError"] = rep["errorMessage"]

    save_shared_pairs(pairs)
    STATUS_JSON_PATH.write_text(
        json.dumps({"completedAt": time.time(), "results": {target_pair["id"]: rep}}, ensure_ascii=False),
        encoding="utf-8",
    )
    return rep


def run_daemon(poll_interval: float = 0.25, periodic_sync_interval: float = 8.0) -> None:
    CONFIG_DIR.mkdir(parents=True, exist_ok=True)
    # Check if another daemon is already alive
    if DAEMON_PID_PATH.exists():
        try:
            old_pid = int(DAEMON_PID_PATH.read_text(encoding="utf-8").strip())
            if old_pid != os.getpid():
                os.kill(old_pid, 0)
                # Another daemon is already running
                return
        except Exception:
            pass

    DAEMON_PID_PATH.write_text(str(os.getpid()), encoding="utf-8")
    last_periodic = 0.0
    while True:
        try:
            now = time.time()
            triggered = TRIGGER_FLAG_PATH.exists()
            if triggered or (now - last_periodic >= periodic_sync_interval):
                if triggered:
                    try:
                        TRIGGER_FLAG_PATH.unlink()
                    except OSError:
                        pass
                run_sync_all()
                last_periodic = time.time()
        except Exception:
            pass
        time.sleep(poll_interval)


def resolve_drive_path(input_path: str) -> str:
    std_in = os.path.abspath(os.path.expanduser(input_path))
    if "/Library/CloudStorage/GoogleDrive-" in std_in:
        return std_in
    pairs = load_shared_pairs()
    for p in pairs:
        l_std = os.path.abspath(os.path.expanduser(p.get("localPath", "")))
        d_std = os.path.abspath(os.path.expanduser(p.get("driveTargetPath", "")))
        if std_in == l_std:
            return d_std
        if std_in.startswith(l_std + os.sep):
            rel = std_in[len(l_std) + 1:]
            return os.path.join(d_std, rel)
    return suggested_drive_target(std_in)


def read_drive_item_id(drive_path: str, wait_seconds: float = 4.0) -> str | None:
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


def get_valid_oauth_token(account_type: str = "personal") -> str | None:
    import urllib.parse
    import urllib.request
    from datetime import datetime, timedelta

    oauth_path = CONFIG_DIR / "gdrive_oauth.json"
    if not oauth_path.exists():
        return None
    try:
        cfg = json.loads(oauth_path.read_text(encoding="utf-8"))
    except Exception:
        return None

    acc = cfg.get(account_type) or cfg.get("personal") or {}
    access_token = acc.get("access_token")
    refresh_token = acc.get("refresh_token")
    expires_at_str = acc.get("expires_at")

    if access_token and expires_at_str:
        try:
            if datetime.now() < datetime.fromisoformat(expires_at_str):
                return access_token
        except Exception:
            pass

    if not refresh_token:
        return access_token

    client_id = cfg.get("client_id", "")
    client_secret = cfg.get("client_secret", "")
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
                acc["access_token"] = new_tok
                acc["expires_at"] = (datetime.now() + timedelta(seconds=exp_in - 60)).isoformat()
                cfg[account_type] = acc
                oauth_path.write_text(json.dumps(cfg, indent=2), encoding="utf-8")
                return new_tok
    except Exception:
        pass
    return access_token


def manage_drive_share_permission(input_path: str, action: str = "status") -> dict:
    """
    action: 'status' | 'reader' | 'writer' | 'restricted'
    """
    import urllib.error
    import urllib.request

    std_in = os.path.abspath(os.path.expanduser(input_path))
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


def ensure_daemon_started() -> None:
    if DAEMON_PID_PATH.exists():
        try:
            old_pid = int(DAEMON_PID_PATH.read_text(encoding="utf-8").strip())
            os.kill(old_pid, 0)
            return
        except Exception:
            pass
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


def main():
    parser = argparse.ArgumentParser(description="DriveBar Local Folder <-> Google Drive Sync Engine")
    parser.add_argument("--daemon", action="store_true", help="Run continuous real-time sync daemon")
    parser.add_argument("--sync-all", action="store_true", help="Sync all enabled pairs in ~/.config/drivebar-sync/sync_pairs.json")
    parser.add_argument("--quick-action", nargs="+", help="Finder Quick Action entry point for selected folders")
    parser.add_argument("--local", help="Local Mac folder path")
    parser.add_argument("--drive", help="Google Drive target folder path")
    parser.add_argument("--mode", default="two_way_mirror", choices=["two_way_mirror", "symlink_to_drive"])
    parser.add_argument("--state-file", help="Optional JSON file containing knownRelativeFiles & lastSyncedAt")
    parser.add_argument("--untag", help="Remove Finder sync tag from folder path")
    parser.add_argument("--restore-symlink", nargs=2, metavar=("LOCAL_PATH", "DRIVE_PATH"), help="Restore symlink to real folder")
    parser.add_argument("--share-status", help="Check current Google Drive share permission for local/Drive path")
    parser.add_argument("--share-set", nargs=2, metavar=("ROLE", "PATH"), help="Set Google Drive share permission: reader | writer | restricted")
    parser.add_argument("--inspect-shared-url", help="Inspect metadata and suggested destination for a shared Google Drive URL")
    parser.add_argument("--sync-shared-url", help="Download and subscribe to a shared Google Drive folder URL")
    args = parser.parse_args()

    if args.daemon:
        run_daemon()
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

    if args.quick_action:
        import urllib.parse
        ensure_daemon_started()
        for raw_path in args.quick_action:
            abs_p = os.path.abspath(os.path.expanduser(raw_path))
            if not os.path.isdir(abs_p) and not os.path.islink(abs_p):
                abs_p = os.path.dirname(abs_p)
            try:
                upsert_and_sync_pair(abs_p, mode="two_way_mirror")
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
        res = run_sync_all()
        print(json.dumps(res, ensure_ascii=False))
        return

    if args.untag:
        set_finder_tag(os.path.abspath(os.path.expanduser(args.untag)), False)
        print(json.dumps({"ok": True}))
        return

    if args.restore_symlink:
        l_path, d_path = args.restore_symlink
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
