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
from datetime import datetime, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

VERSION = "0.5.0"

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
DEVICE         = _cfg      ("DEVICE",         "WindowsMic")
LISTENER_UNIT  = _cfg      ("LISTENER_UNIT",  "windowsmic-listen.service")
HISTORY_LEN    = _cfg_int  ("HISTORY_LEN",    20)

# Continuous parec reader (v0.5): wire format and chunk sizing.
_BYTES_PER_SEC = 48000 * 2 * 2  # 48k samples/s * 2 channels * 2 bytes/sample
_CHUNK_SEC     = 0.25            # peak update granularity
_CHUNK_BYTES   = max(4, (int(_BYTES_PER_SEC * _CHUNK_SEC) // 4) * 4)

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
        "chunk_sec": _CHUNK_SEC,
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
        # v0.5: continuous parec reader keeps WindowsMic permanently RUNNING
        # so other consumers (Chrome WebRTC, etc) don't see the source flap.
        "parec_running": False,
        "parec_pid": None,
        "parec_restarts": 0,
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


# -------- v0.5 continuous parec reader --------
#
# Why: the v0.4 design opened parecord every 15s for 3s, then closed it. Each
# open/close cycled WindowsMic between SUSPENDED and RUNNING and forced a brief
# pulse renegotiation. Other consumers (Chrome WebRTC in particular) react to
# this by tearing down their stream -- "voice mode disconnected" symptom.
#
# v0.5 keeps a single long-lived `parec` running. Source stays RUNNING
# permanently. We read 16-bit stereo PCM in fixed-size chunks, compute peak
# per chunk in pure Python (struct.unpack is fast enough at our chunk size),
# and aggregate into windows of CHECK_INTERVAL seconds for the same /health
# JSON shape as before.

def _commit_window(window_peak, tcp_at_window_close):
    """Called once per CHECK_INTERVAL window with the max chunk peak observed."""
    if window_peak <= 0:
        peak_db = None
    else:
        peak_db = 20.0 * math.log10(window_peak / 32768.0)
    now = datetime.now(timezone.utc).isoformat()
    with _lock:
        a = _state["audio"]
        a["last_sample_at"] = now
        a["last_peak"] = window_peak
        a["last_peak_db"] = round(peak_db, 1) if peak_db is not None else None
        a["last_error"] = None
        if window_peak == 0 and tcp_at_window_close:
            a["consecutive_silent"] = a.get("consecutive_silent", 0) + 1
        elif window_peak == 0 and not tcp_at_window_close:
            # Windows offline -> zeros expected, don't accumulate.
            a["consecutive_silent"] = 0
        else:
            a["consecutive_silent"] = 0
        a["zombie_likely"] = bool(tcp_at_window_close and a["consecutive_silent"] >= SILENT_LIMIT)
    _push_history({
        "at": now,
        "peak": window_peak,
        "peak_db": (round(peak_db, 1) if peak_db is not None else None),
        "tcp_established": tcp_at_window_close,
        "error": None,
    })


def _parec_reader_loop():
    """Long-lived parec stream. Restart with backoff on any failure."""
    backoff = 1.0
    while _running.is_set():
        proc = None
        try:
            proc = subprocess.Popen(
                [
                    "parec",
                    "--raw",
                    f"--device={DEVICE}",
                    "--rate=48000",
                    "--channels=2",
                    "--format=s16le",
                ],
                stdout=subprocess.PIPE,
                stderr=subprocess.DEVNULL,
                bufsize=0,
            )
            with _lock:
                a = _state["audio"]
                a["parec_running"] = True
                a["parec_pid"] = proc.pid
                a["last_error"] = None
            backoff = 1.0  # reset backoff on successful spawn

            window_start = time.monotonic()
            window_peak = 0
            while _running.is_set():
                data = proc.stdout.read(_CHUNK_BYTES)
                if not data:
                    raise RuntimeError("parec stdout closed (process exited)")
                if len(data) < 2:
                    continue
                # Compute peak amplitude over the chunk.
                n = len(data) // 2
                samples = struct.unpack("<" + "h" * n, data)
                chunk_peak = max((abs(s) for s in samples), default=0)
                if chunk_peak > window_peak:
                    window_peak = chunk_peak

                now_mono = time.monotonic()
                if now_mono - window_start >= CHECK_INTERVAL:
                    tcp_now = _is_tcp_established()
                    _commit_window(window_peak, tcp_now)
                    window_peak = 0
                    window_start = now_mono
        except Exception as e:
            with _lock:
                a = _state["audio"]
                a["parec_running"] = False
                a["parec_pid"] = None
                a["parec_restarts"] = a.get("parec_restarts", 0) + 1
                a["last_error"] = f"parec: {e}"
        finally:
            if proc is not None:
                try:
                    proc.terminate()
                    proc.wait(timeout=2)
                except Exception:
                    try:
                        proc.kill()
                    except Exception:
                        pass

        # Sleep with backoff before respawn (responsive to shutdown).
        slept = 0.0
        while _running.is_set() and slept < backoff:
            time.sleep(0.1)
            slept += 0.1
        backoff = min(backoff * 2, 30.0)


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


def _shutdown(signum, frame):
    _running.clear()


def main():
    signal.signal(signal.SIGTERM, _shutdown)
    signal.signal(signal.SIGINT, _shutdown)

    # v0.5: continuous parec reader replaces the v0.4 periodic sampler.
    # Cheap observations (TCP, sink state, listener active) are now done
    # inline in _snapshot() on every /health request -- no separate poller.
    threading.Thread(target=_parec_reader_loop, daemon=True).start()

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
