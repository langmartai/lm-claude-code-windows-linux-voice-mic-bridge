#!/usr/bin/env python3
# Linux-side health daemon for the Windows->Linux mic bridge.
#
# Replaces the legacy windowsmic-watchdog.sh (SSH-kill design). This daemon
# OBSERVES and EXPORTS only -- it never reaches across hosts. The Windows
# side polls this endpoint and self-kills its own ffmpeg when we report the
# zombie state.
#
# Truthful observations exported on GET /health (JSON):
#   stream.listener_active        : systemd unit windowsmic-listen.service active
#   stream.tcp_established        : a Windows ffmpeg is connected to :PORT
#   stream.windowsmic_state       : pulse source state (RUNNING / IDLE / SUSPENDED)
#   audio.last_peak               : peak amplitude of last sample (0 = digital silence)
#   audio.last_peak_db            : dBFS-ish (null for true zero)
#   audio.consecutive_silent      : streak of zero-peak samples WHILE TCP up
#   audio.zombie_likely           : the actionable conclusion the Windows monitor reads
#                                   (tcp_established AND consecutive_silent >= silent_limit)
#
# Sampler thread runs every CHECK_INTERVAL seconds; HTTP server serves /health
# from an in-memory snapshot. Stdlib only -- no extra deps.

import json
import math
import os
import signal
import struct
import subprocess
import threading
import time
import wave
from datetime import datetime, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

VERSION = "0.4.0"

# -------- config (env vars override config.env which overrides defaults) --------

CONFIG_PATH = Path.home() / ".config" / "windowsmic-bridge" / "config.env"


def _load_env_file(path):
    env = {}
    if not path.is_file():
        return env
    for raw in path.read_text(encoding="utf-8", errors="replace").splitlines():
        line = raw.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        k, _, v = line.partition("=")
        v = v.strip()
        if (v.startswith('"') and v.endswith('"')) or (v.startswith("'") and v.endswith("'")):
            v = v[1:-1]
        env[k.strip()] = v
    return env


_file_env = _load_env_file(CONFIG_PATH)


def _cfg(key, default):
    if os.environ.get(key):
        return os.environ[key]
    if _file_env.get(key):
        return _file_env[key]
    return default


def _cfg_int(key, default):
    return int(_cfg(key, default))


def _cfg_float(key, default):
    return float(_cfg(key, default))


PORT           = _cfg_int  ("PORT",           9999)
HEALTH_PORT    = _cfg_int  ("HEALTH_PORT",    9998)
HEALTH_BIND    = _cfg      ("HEALTH_BIND",    "0.0.0.0")
CHECK_INTERVAL = _cfg_float("CHECK_INTERVAL", 15.0)
SILENT_LIMIT   = _cfg_int  ("SILENT_LIMIT",   3)
SAMPLE_SEC     = _cfg_float("SAMPLE_SEC",     3.0)
SKIP_HEAD_SEC  = _cfg_float("SKIP_HEAD_SEC",  1.0)
DEVICE         = _cfg      ("DEVICE",         "WindowsMic")
LISTENER_UNIT  = _cfg      ("LISTENER_UNIT",  "windowsmic-listen.service")
HISTORY_LEN    = _cfg_int  ("HISTORY_LEN",    20)

# Playback-flow config (Linux audio out -> Windows playback)
EXPORT_PORT    = _cfg_int  ("EXPORT_PORT",    10000)
SPEAKERS_SINK  = _cfg      ("SPEAKERS_SINK",  "WindowsSpeakers")
EXPORT_UNIT    = _cfg      ("EXPORT_UNIT",    "windowsspeakers-export.service")

# Pulse sometimes can't find the user socket inside systemd --user services
# without an explicit PULSE_SERVER. The user sockets path is the systemd default.
os.environ.setdefault("PULSE_SERVER", f"unix:/run/user/{os.getuid()}/pulse/native")

# -------- shared state --------

_lock = threading.Lock()
_state = {
    "version": VERSION,
    "pid": os.getpid(),
    "started_at": datetime.now(timezone.utc).isoformat(),
    "config": {
        "port": PORT,
        "health_port": HEALTH_PORT,
        "check_interval": CHECK_INTERVAL,
        "silent_limit": SILENT_LIMIT,
        "sample_sec": SAMPLE_SEC,
        "skip_head_sec": SKIP_HEAD_SEC,
        "device": DEVICE,
        "listener_unit": LISTENER_UNIT,
        "export_port": EXPORT_PORT,
        "speakers_sink": SPEAKERS_SINK,
        "export_unit": EXPORT_UNIT,
    },
    "stream": {
        "listener_active": None,
        "tcp_established": None,
        "windowsmic_state": None,
    },
    "audio": {
        "last_sample_at": None,
        "last_peak": None,
        "last_peak_db": None,
        "consecutive_silent": 0,
        "zombie_likely": False,
        "last_error": None,
    },
    "playback": {
        "export_active": None,           # systemd unit windowsspeakers-export.service active
        "tcp_listening": None,           # ffmpeg bound on EXPORT_PORT in LISTEN state
        "tcp_clients": [],               # list of remote "host:port" strings currently connected
        "tcp_client_count": 0,
        "speakers_sink_state": None,    # WindowsSpeakers sink state (RUNNING/IDLE/SUSPENDED)
        "last_check_at": None,
    },
    "history": [],
}


def _update_stream(d):
    with _lock:
        _state["stream"].update(d)


def _push_history(entry):
    with _lock:
        _state["history"].append(entry)
        if len(_state["history"]) > HISTORY_LEN:
            _state["history"] = _state["history"][-HISTORY_LEN:]


def _snapshot():
    """Fresh observations on every request -- only the expensive audio sampling
    is cached (it runs in the sampler thread on CHECK_INTERVAL). The cheap
    queries (systemctl is-active, ss, pactl) re-run inline so the dashboard
    sees the current sink/TCP state, not a 15-second-old snapshot."""
    try:
        _sample_playback()
    except Exception:
        pass
    try:
        listener = _is_listener_active()
        src_state = _windowsmic_source_state()
        tcp = _is_tcp_established()
        with _lock:
            _state["stream"]["listener_active"] = listener
            _state["stream"]["tcp_established"] = tcp
            _state["stream"]["windowsmic_state"] = src_state
    except Exception:
        pass
    with _lock:
        return json.loads(json.dumps(_state, default=str))


# -------- observers --------

def _is_listener_active():
    try:
        r = subprocess.run(
            ["systemctl", "--user", "is-active", "--quiet", LISTENER_UNIT],
            timeout=3,
        )
        return r.returncode == 0
    except Exception:
        return False


def _is_tcp_established():
    try:
        out = subprocess.check_output(
            ["ss", "-tn", "state", "established", f"( sport = :{PORT} )"],
            timeout=3, text=True,
        )
        for line in out.splitlines()[1:]:
            if line.strip():
                return True
        return False
    except Exception:
        return False


def _windowsmic_source_state():
    try:
        out = subprocess.check_output(
            ["pactl", "list", "short", "sources"], timeout=3, text=True,
        )
        for line in out.splitlines():
            cols = line.split("\t")
            if len(cols) >= 4 and cols[1] == DEVICE:
                return cols[-1].strip()
        return None
    except Exception:
        return None


def _speakers_sink_state():
    try:
        out = subprocess.check_output(
            ["pactl", "list", "short", "sinks"], timeout=3, text=True,
        )
        for line in out.splitlines():
            cols = line.split("\t")
            if len(cols) >= 4 and cols[1] == SPEAKERS_SINK:
                return cols[-1].strip()
        return None
    except Exception:
        return None


def _is_unit_active(unit):
    try:
        r = subprocess.run(
            ["systemctl", "--user", "is-active", "--quiet", unit],
            timeout=3,
        )
        return r.returncode == 0
    except Exception:
        return False


def _export_listening():
    """Is some local process LISTENing on EXPORT_PORT?"""
    try:
        out = subprocess.check_output(
            ["ss", "-tln", f"( sport = :{EXPORT_PORT} )"],
            timeout=3, text=True,
        )
        for line in out.splitlines()[1:]:
            if line.strip():
                return True
        return False
    except Exception:
        return False


def _export_tcp_clients():
    """Return list of established peers connected to local EXPORT_PORT."""
    try:
        out = subprocess.check_output(
            ["ss", "-tn", "state", "established", f"( sport = :{EXPORT_PORT} )"],
            timeout=3, text=True,
        )
        peers = []
        for line in out.splitlines()[1:]:
            cols = line.split()
            # Columns: Recv-Q Send-Q Local Peer ...
            if len(cols) >= 4:
                peers.append(cols[3])
        return peers
    except Exception:
        return []


def _record_and_peak():
    """Record SAMPLE_SEC of DEVICE, return (peak_int|None, peak_db|None, error|None)."""
    tmp = Path(f"/tmp/windowsmic-health.{os.getpid()}.wav")
    p = None
    try:
        p = subprocess.Popen(
            ["parecord", f"--device={DEVICE}", "--file-format=wav", str(tmp)],
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
        )
        time.sleep(SAMPLE_SEC + 0.3)
        try:
            p.terminate()
            p.wait(timeout=2)
        except Exception:
            try:
                p.kill()
            except Exception:
                pass
        if not tmp.is_file() or tmp.stat().st_size < 64:
            return (None, None, "recording empty")
        with wave.open(str(tmp), "rb") as w:
            sr = w.getframerate()
            nframes = w.getnframes()
            skip = int(SKIP_HEAD_SEC * sr)
            if nframes <= skip:
                return (None, None, "recording shorter than skip head")
            w.setpos(skip)
            frames = w.readframes(nframes - skip)
        if not frames:
            return (None, None, "no frames after skip")
        n = len(frames) // 2
        samples = struct.unpack("<" + "h" * n, frames)
        peak = max((abs(s) for s in samples), default=0)
        if peak <= 0:
            return (0, None, None)
        peak_db = 20.0 * math.log10(peak / 32768.0)
        return (peak, peak_db, None)
    except FileNotFoundError as e:
        return (None, None, f"missing tool: {e}")
    except Exception as e:
        return (None, None, str(e))
    finally:
        try:
            tmp.unlink()
        except Exception:
            pass


def _sample_playback():
    """Cheap, non-recording observations for the playback flow."""
    export_active = _is_unit_active(EXPORT_UNIT)
    tcp_listen = _export_listening()
    clients = _export_tcp_clients()
    sink_state = _speakers_sink_state()
    with _lock:
        p = _state["playback"]
        p["export_active"] = export_active
        p["tcp_listening"] = tcp_listen
        p["tcp_clients"] = clients
        p["tcp_client_count"] = len(clients)
        p["speakers_sink_state"] = sink_state
        p["last_check_at"] = datetime.now(timezone.utc).isoformat()


def _sample_once():
    # Playback observations are cheap and always run.
    try:
        _sample_playback()
    except Exception as e:
        with _lock:
            _state["playback"]["last_check_at"] = datetime.now(timezone.utc).isoformat()
            _state["playback"]["last_error"] = str(e)

    listener = _is_listener_active()
    src_state = _windowsmic_source_state()
    tcp = _is_tcp_established()

    _update_stream({
        "listener_active": listener,
        "tcp_established": tcp,
        "windowsmic_state": src_state,
    })

    if not listener or src_state is None:
        with _lock:
            a = _state["audio"]
            a["last_sample_at"] = datetime.now(timezone.utc).isoformat()
            a["last_peak"] = None
            a["last_peak_db"] = None
            a["last_error"] = "listener inactive" if not listener else "source missing"
            a["zombie_likely"] = False
            # do NOT mutate consecutive_silent here -- preserve last known streak
        _push_history({
            "at": _state["audio"]["last_sample_at"],
            "peak": None, "peak_db": None,
            "tcp_established": tcp,
            "error": _state["audio"]["last_error"],
        })
        return

    peak, peak_db, err = _record_and_peak()
    now = datetime.now(timezone.utc).isoformat()

    with _lock:
        a = _state["audio"]
        a["last_sample_at"] = now
        a["last_error"] = err
        if err:
            # Sample failed -- don't update streak (conservative).
            a["last_peak"] = None
            a["last_peak_db"] = None
        elif peak == 0 and tcp:
            a["consecutive_silent"] = a.get("consecutive_silent", 0) + 1
            a["last_peak"] = 0
            a["last_peak_db"] = None
        elif peak == 0 and not tcp:
            # Windows offline -> zeros expected. Don't accumulate.
            a["consecutive_silent"] = 0
            a["last_peak"] = 0
            a["last_peak_db"] = None
        else:
            a["consecutive_silent"] = 0
            a["last_peak"] = peak
            a["last_peak_db"] = round(peak_db, 1) if peak_db is not None else None
        a["zombie_likely"] = bool(tcp and a["consecutive_silent"] >= SILENT_LIMIT)

    _push_history({
        "at": now,
        "peak": peak,
        "peak_db": (round(peak_db, 1) if peak_db is not None else None),
        "tcp_established": tcp,
        "error": err,
    })


# -------- HTTP server --------

class HealthHandler(BaseHTTPRequestHandler):
    def log_message(self, fmt, *args):
        return  # silence default access log

    def _send(self, status, body):
        encoded = body.encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(encoded)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        try:
            self.wfile.write(encoded)
        except Exception:
            pass

    def do_GET(self):
        path = self.path.split("?", 1)[0].rstrip("/") or "/"
        if path in ("/", "/health"):
            self._send(200, json.dumps(_snapshot()))
        elif path == "/version":
            self._send(200, json.dumps({"version": VERSION}))
        else:
            self._send(404, json.dumps({"error": "not found"}))


# -------- main --------

_running = threading.Event()
_running.set()


def _sampler_loop():
    while _running.is_set():
        try:
            _sample_once()
        except Exception as e:
            with _lock:
                _state["audio"]["last_error"] = f"sampler crashed: {e}"
        # responsive shutdown
        for _ in range(int(max(CHECK_INTERVAL * 10, 1))):
            if not _running.is_set():
                return
            time.sleep(0.1)


def _shutdown(signum, frame):
    _running.clear()


def main():
    signal.signal(signal.SIGTERM, _shutdown)
    signal.signal(signal.SIGINT, _shutdown)

    threading.Thread(target=_sampler_loop, daemon=True).start()

    server = ThreadingHTTPServer((HEALTH_BIND, HEALTH_PORT), HealthHandler)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    print(f"[windowsmic-health] listening on {HEALTH_BIND}:{HEALTH_PORT}", flush=True)

    try:
        while _running.is_set():
            time.sleep(0.5)
    finally:
        try:
            server.shutdown()
            server.server_close()
        except Exception:
            pass


if __name__ == "__main__":
    main()
