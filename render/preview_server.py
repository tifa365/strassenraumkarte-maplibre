#!/usr/bin/env python3
"""
Local preview server for render/tiles/preview.html.

Serves XYZ tiles and preview.html, lists local PBFs under data/osm, and can
start ./run.sh with a bbox + data source chosen in the UI.

Usage (from repository root):
  ./render/preview_server.py
  # then open http://127.0.0.1:8000/preview.html
"""

from __future__ import annotations

import json
import mimetypes
import os
import re
import signal
import subprocess
import threading
import time
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import urlparse

REPO_ROOT = Path(__file__).resolve().parent.parent
# render_tiles.sh's default --out is now render/tiles-validated (render/tiles
# is only kept around as legacy/unverified output); prefer it when present,
# but fall back to the legacy directory for anyone who hasn't re-rendered.
# PREVIEW_TILES_DIR overrides both, e.g. for a custom --out.
_env_tiles_dir = os.environ.get("PREVIEW_TILES_DIR")
if _env_tiles_dir:
    TILES_DIR = Path(_env_tiles_dir)
else:
    _validated_tiles_dir = REPO_ROOT / "render" / "tiles-validated"
    TILES_DIR = _validated_tiles_dir if _validated_tiles_dir.is_dir() else REPO_ROOT / "render" / "tiles"
OSM_DIR = REPO_ROOT / "data" / "osm"
RUN_SCRIPT = REPO_ROOT / "run.sh"

HOST = os.environ.get("PREVIEW_HOST", "127.0.0.1")
PORT = int(os.environ.get("PREVIEW_PORT", "8000"))

BBOX_RE = re.compile(
    r"^-?\d+(?:\.\d+)?,-?\d+(?:\.\d+)?,-?\d+(?:\.\d+)?,-?\d+(?:\.\d+)?$"
)
GEOFABRIK_RE = re.compile(
    r"^https://download\.geofabrik\.de/[A-Za-z0-9_./-]+\.osm\.pbf$"
)

_run_lock = threading.Lock()
_run_state: dict = {
    "running": False,
    "pid": None,
    "started_at": None,
    "finished_at": None,
    "exit_code": None,
    "command": None,
    "lines": [],
}
_run_proc: subprocess.Popen | None = None


def _json_bytes(payload: dict, status: int = 200) -> tuple[int, bytes, str]:
    body = json.dumps(payload, ensure_ascii=False).encode("utf-8")
    return status, body, "application/json; charset=utf-8"


def list_local_pbfs() -> list[dict]:
    OSM_DIR.mkdir(parents=True, exist_ok=True)
    files = []
    for path in sorted(OSM_DIR.iterdir()):
        if not path.is_file():
            continue
        name = path.name
        if not (name.endswith(".osm.pbf") or name.endswith(".pbf")):
            continue
        # Skip temporary extracts produced by the pipeline
        if name.startswith("extract_"):
            continue
        files.append(
            {
                "name": name,
                "path": f"data/osm/{name}",
                "size": path.stat().st_size,
            }
        )
    return files


def resolve_data_source(data: str) -> tuple[str | None, str | None]:
    """Return (resolved_arg_for_run_sh, error)."""
    data = (data or "").strip()
    if not data:
        return None, "data is required"

    if data.startswith("http://") or data.startswith("https://"):
        if not GEOFABRIK_RE.match(data):
            return (
                None,
                "Only https://download.geofabrik.de/.../*.osm.pbf URLs are allowed",
            )
        return data, None

    # Local path relative to repo root, must stay under data/osm
    rel = data.lstrip("./")
    if not rel.startswith("data/osm/"):
        return None, "Local data must be under data/osm/"
    candidate = (REPO_ROOT / rel).resolve()
    try:
        candidate.relative_to(OSM_DIR.resolve())
    except ValueError:
        return None, "Local data path escapes data/osm/"
    if not candidate.is_file():
        return None, f"File not found: {rel}"
    return str(candidate.relative_to(REPO_ROOT)), None


def parse_bbox(bbox: str) -> tuple[str | None, str | None]:
    bbox = (bbox or "").strip()
    if not bbox:
        return None, "bbox is required"
    if not BBOX_RE.match(bbox):
        return None, "bbox must be xmin,ymin,xmax,ymax (WGS84)"
    parts = [float(x) for x in bbox.split(",")]
    xmin, ymin, xmax, ymax = parts
    if not (-180 <= xmin < xmax <= 180 and -90 <= ymin < ymax <= 90):
        return None, "bbox coordinates out of range or unordered"
    # Keep original formatting precision from client
    return bbox, None


def append_log(line: str) -> None:
    lines = _run_state["lines"]
    lines.append(line.rstrip("\n"))
    # Cap memory usage for long runs
    if len(lines) > 5000:
        del lines[: len(lines) - 5000]


def _reader_thread(proc: subprocess.Popen) -> None:
    assert proc.stdout is not None
    try:
        for raw in proc.stdout:
            append_log(raw.rstrip("\n"))
    finally:
        code = proc.wait()
        with _run_lock:
            _run_state["running"] = False
            _run_state["exit_code"] = code
            _run_state["finished_at"] = time.time()
            _run_state["pid"] = None
            append_log(f"[preview] run.sh exited with code {code}")


def start_run(
    data: str,
    bbox: str,
    *,
    refresh: bool = False,
    skip_render: bool = False,
    zmin: int | None = None,
    zmax: int | None = None,
    tile_format: str | None = None,
) -> tuple[dict, int]:
    global _run_proc

    resolved, err = resolve_data_source(data)
    if err:
        return {"ok": False, "error": err}, 400
    bbox_ok, err = parse_bbox(bbox)
    if err:
        return {"ok": False, "error": err}, 400

    cmd = [str(RUN_SCRIPT), "--data", resolved, "--bbox", bbox_ok]
    if refresh:
        cmd.append("--refresh")
    if skip_render:
        cmd.append("--skip-render")
    if zmin is not None:
        cmd.extend(["--zmin", str(zmin)])
    if zmax is not None:
        cmd.extend(["--zmax", str(zmax)])
    if tile_format is not None:
        cmd.extend(["--format", tile_format])

    with _run_lock:
        if _run_state["running"]:
            return {"ok": False, "error": "A run is already in progress"}, 409
        _run_state.update(
            {
                "running": True,
                "pid": None,
                "started_at": time.time(),
                "finished_at": None,
                "exit_code": None,
                "command": " ".join(cmd),
                "lines": [
                    f"[preview] Starting: {' '.join(cmd)}",
                ],
            }
        )

    try:
        proc = subprocess.Popen(
            cmd,
            cwd=str(REPO_ROOT),
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True,
            bufsize=1,
            start_new_session=True,
        )
    except OSError as exc:
        with _run_lock:
            _run_state["running"] = False
            _run_state["exit_code"] = 1
            _run_state["finished_at"] = time.time()
            append_log(f"[preview] Failed to start: {exc}")
        return {"ok": False, "error": str(exc)}, 500

    with _run_lock:
        _run_proc = proc
        _run_state["pid"] = proc.pid

    threading.Thread(target=_reader_thread, args=(proc,), daemon=True).start()
    return {
        "ok": True,
        "pid": proc.pid,
        "command": _run_state["command"],
    }, 202


def stop_run() -> tuple[dict, int]:
    global _run_proc
    with _run_lock:
        proc = _run_proc
        if not _run_state["running"] or proc is None:
            return {"ok": False, "error": "No run in progress"}, 409
        pid = proc.pid
    try:
        os.killpg(pid, signal.SIGTERM)
        append_log(f"[preview] Sent SIGTERM to process group {pid}")
    except ProcessLookupError:
        append_log("[preview] Process already gone")
    return {"ok": True}, 200


def run_status(since: int = 0) -> dict:
    with _run_lock:
        lines = _run_state["lines"]
        return {
            "running": _run_state["running"],
            "pid": _run_state["pid"],
            "started_at": _run_state["started_at"],
            "finished_at": _run_state["finished_at"],
            "exit_code": _run_state["exit_code"],
            "command": _run_state["command"],
            "since": since,
            "next": len(lines),
            "lines": lines[since:],
        }


TILE_PATH_RE = re.compile(r"^/(\d+)/(\d+)/(\d+)\.(jpg|jpeg|png)$", re.IGNORECASE)


def tile_format_info() -> dict:
    """Count tile files and suggest preview format."""
    jpg = png = 0
    if TILES_DIR.is_dir():
        for path in TILES_DIR.rglob("*"):
            if not path.is_file():
                continue
            ext = path.suffix.lower()
            if ext in (".jpg", ".jpeg"):
                jpg += 1
            elif ext == ".png":
                png += 1
    if jpg == 0 and png > 0:
        suggested = "png"
    elif png == 0 and jpg > 0:
        suggested = "jpg"
    elif jpg >= png:
        suggested = "jpg"
    else:
        suggested = "png"
    return {"jpg": jpg, "png": png, "suggested": suggested}


def resolve_tile_path(url_path: str) -> Path | None:
    """
    Resolve z/x/y.ext under TILES_DIR.

    If the requested extension is missing, fall back to the other format so
    mixed PNG/JPG directories still display after a format switch.
    """
    m = TILE_PATH_RE.match(url_path)
    if not m:
        return None
    z, x, y, ext = m.groups()
    ext = "jpg" if ext.lower() in ("jpg", "jpeg") else "png"
    alt = "png" if ext == "jpg" else "jpg"
    for suffix in (ext, alt):
        candidate = TILES_DIR / z / x / f"{y}.{suffix}"
        if candidate.is_file():
            return candidate
    return None


class PreviewHandler(SimpleHTTPRequestHandler):
    def __init__(self, *args, **kwargs):
        super().__init__(*args, directory=str(TILES_DIR), **kwargs)

    def log_message(self, fmt: str, *args) -> None:
        # Quieter default: skip tile GETs noise somewhat by only logging API / errors
        path = args[0] if args else ""
        if isinstance(path, str) and ("/api/" in path or "preview" in path):
            super().log_message(fmt, *args)

    def _send(self, status: int, body: bytes, content_type: str) -> None:
        self.send_response(status)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(body)

    def _read_json(self) -> dict:
        length = int(self.headers.get("Content-Length", "0") or "0")
        raw = self.rfile.read(length) if length else b"{}"
        if not raw:
            return {}
        return json.loads(raw.decode("utf-8"))

    def do_GET(self) -> None:  # noqa: N802
        parsed = urlparse(self.path)
        if parsed.path == "/api/pbfs":
            status, body, ctype = _json_bytes({"files": list_local_pbfs()})
            self._send(status, body, ctype)
            return
        if parsed.path == "/api/tiles/info":
            status, body, ctype = _json_bytes(tile_format_info())
            self._send(status, body, ctype)
            return
        if parsed.path == "/api/run/status":
            qs = parsed.query
            since = 0
            for part in qs.split("&"):
                if part.startswith("since="):
                    try:
                        since = max(0, int(part.split("=", 1)[1]))
                    except ValueError:
                        since = 0
            status, body, ctype = _json_bytes(run_status(since))
            self._send(status, body, ctype)
            return
        tile_path = resolve_tile_path(parsed.path)
        if tile_path is not None:
            ctype = mimetypes.guess_type(str(tile_path))[0] or "application/octet-stream"
            data = tile_path.read_bytes()
            self._send(200, data, ctype)
            return
        if parsed.path in ("/", "/preview.html"):
            # Always serve preview from tiles dir
            self.path = "/preview.html"
        return super().do_GET()

    def do_POST(self) -> None:  # noqa: N802
        parsed = urlparse(self.path)
        try:
            payload = self._read_json()
        except (json.JSONDecodeError, UnicodeDecodeError) as exc:
            status, body, ctype = _json_bytes({"ok": False, "error": str(exc)}, 400)
            self._send(status, body, ctype)
            return

        if parsed.path == "/api/run":
            zmin = payload.get("zmin")
            zmax = payload.get("zmax")
            if zmin is not None:
                try:
                    zmin = int(zmin)
                except (TypeError, ValueError):
                    status, body, ctype = _json_bytes(
                        {"ok": False, "error": "zmin must be an integer"}, 400
                    )
                    self._send(status, body, ctype)
                    return
            if zmax is not None:
                try:
                    zmax = int(zmax)
                except (TypeError, ValueError):
                    status, body, ctype = _json_bytes(
                        {"ok": False, "error": "zmax must be an integer"}, 400
                    )
                    self._send(status, body, ctype)
                    return
            tile_format = payload.get("format")
            if tile_format is not None:
                tile_format = str(tile_format).lower()
                if tile_format == "jpeg":
                    tile_format = "jpg"
                if tile_format not in ("png", "jpg"):
                    status, body, ctype = _json_bytes(
                        {"ok": False, "error": "format must be png or jpg"}, 400
                    )
                    self._send(status, body, ctype)
                    return
            result, code = start_run(
                str(payload.get("data", "")),
                str(payload.get("bbox", "")),
                refresh=bool(payload.get("refresh", False)),
                skip_render=bool(payload.get("skip_render", False)),
                zmin=zmin,
                zmax=zmax,
                tile_format=tile_format,
            )
            status, body, ctype = _json_bytes(result, code)
            self._send(status, body, ctype)
            return

        if parsed.path == "/api/run/stop":
            result, code = stop_run()
            status, body, ctype = _json_bytes(result, code)
            self._send(status, body, ctype)
            return

        status, body, ctype = _json_bytes({"ok": False, "error": "Not found"}, 404)
        self._send(status, body, ctype)

    def end_headers(self) -> None:
        # Allow opening from another local origin if needed
        self.send_header("Access-Control-Allow-Origin", "*")
        super().end_headers()

    def do_OPTIONS(self) -> None:  # noqa: N802
        self.send_response(204)
        self.send_header("Access-Control-Allow-Origin", "*")
        self.send_header("Access-Control-Allow-Methods", "GET, POST, OPTIONS")
        self.send_header("Access-Control-Allow-Headers", "Content-Type")
        self.end_headers()


def main() -> None:
    mimetypes.add_type("application/json", ".json")
    if not TILES_DIR.is_dir():
        raise SystemExit(f"Tiles directory missing: {TILES_DIR}")
    if not RUN_SCRIPT.is_file():
        raise SystemExit(f"run.sh missing: {RUN_SCRIPT}")

    server = ThreadingHTTPServer((HOST, PORT), PreviewHandler)
    print(f"Preview: http://{HOST}:{PORT}/preview.html")
    print(f"Tiles:   {TILES_DIR}")
    print(f"PBFs:    {OSM_DIR}")
    print("API:     GET /api/pbfs  POST /api/run  GET /api/run/status  POST /api/run/stop")
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        print("\nShutting down.")
    finally:
        server.server_close()


if __name__ == "__main__":
    main()
