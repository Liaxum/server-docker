"""Bambu Lab printer status as an OBS browser source.

Holds one MQTT connection to the printer, folds its reports into a single
state, and serves that state as JSON next to the page that draws it.

Standard library only. The MQTT client below is the small subset of 3.1.1 a
read-only subscriber needs -- CONNECT, SUBSCRIBE, PUBLISH at QoS 0, PINGREQ --
which keeps this runnable on the stock python image with no install step.
"""

import json
import os
import secrets
import socket
import ssl
import struct
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

HOST = os.environ["BAMBU_HOST"]
ACCESS_CODE = os.environ["BAMBU_ACCESS_CODE"]
SERIAL = os.environ["BAMBU_SERIAL"]
MQTT_PORT = int(os.environ.get("BAMBU_MQTT_PORT", "8883"))
HTTP_PORT = int(os.environ.get("OVERLAY_HTTP_PORT", "8080"))

KEEPALIVE = 60
# A printing X2D reports about once a second and an idle one every few
# seconds, and PINGRESP answers our pings in between. Silence this long means
# the connection is gone even if the socket has not noticed.
STALE_AFTER = 2 * KEEPALIVE

PAGE = Path(__file__).with_name("overlay.html")

STATE_LABELS = {
    "IDLE": "Idle",
    "PREPARE": "Preparing",
    "SLICING": "Slicing",
    "RUNNING": "Printing",
    "PAUSE": "Paused",
    "FINISH": "Finished",
    "FAILED": "Failed",
}

_lock = threading.Lock()
_report = {}
_last_report = 0.0
_error = "connecting"


def merge(into, update):
    """Fold a report into the state. Reports are deltas: a message often
    carries one changed field and nothing else, so replacing would forget
    everything it left out."""
    for key, value in update.items():
        if isinstance(value, dict) and isinstance(into.get(key), dict):
            merge(into[key], value)
        else:
            into[key] = value


# --- MQTT ------------------------------------------------------------------


def _varint(n):
    out = bytearray()
    while True:
        byte, n = n % 128, n // 128
        out.append(byte | (0x80 if n else 0))
        if not n:
            return bytes(out)


def _str(s):
    data = s.encode()
    return struct.pack("!H", len(data)) + data


def _packet(kind, body):
    return bytes([kind]) + _varint(len(body)) + body


def _split(buf):
    """Take one whole packet off the front of buf, or None if it holds only
    part of one. Packets arrive split across reads and several to a read, so
    framing is done on a buffer rather than per recv."""
    length, mult = 0, 1
    for i in range(1, min(len(buf), 5)):
        byte = buf[i]
        length += (byte & 0x7F) * mult
        mult *= 128
        if not byte & 0x80:
            end = i + 1 + length
            if len(buf) < end:
                return None
            packet = (buf[0], bytes(buf[i + 1 : end]))
            del buf[:end]
            return packet
    return None


def _connect():
    # The printer's certificate is issued by Bambu's own CA for its serial
    # number, not for the address we dial, so it cannot be verified here.
    # The link stays on the LAN and the access code is the authentication.
    ctx = ssl.create_default_context()
    ctx.check_hostname = False
    ctx.verify_mode = ssl.CERT_NONE

    raw = socket.create_connection((HOST, MQTT_PORT), timeout=10)
    sock = ctx.wrap_socket(raw, server_hostname=HOST)

    client_id = "printcast-overlay-" + secrets.token_hex(4)
    flags = 0x80 | 0x40 | 0x02  # username, password, clean session
    body = _str("MQTT") + bytes([4, flags]) + struct.pack("!H", KEEPALIVE)
    body += _str(client_id) + _str("bblp") + _str(ACCESS_CODE)
    sock.sendall(_packet(0x10, body))

    buf = bytearray()
    while (packet := _split(buf)) is None:
        data = sock.recv(4096)
        if not data:
            raise ConnectionError("printer closed the connection during CONNECT")
        buf += data
    kind, body = packet
    if kind != 0x20 or len(body) < 2:
        raise ConnectionError(f"expected CONNACK, got packet type {kind >> 4}")
    if body[1] == 5:
        raise PermissionError("printer refused the access code (CONNACK 5)")
    if body[1] != 0:
        raise ConnectionError(f"printer refused the connection (CONNACK {body[1]})")

    sock.sendall(_packet(0x82, struct.pack("!H", 1) + _str(f"device/{SERIAL}/report") + b"\x00"))
    # Reports are deltas, so without this the state would fill in only as
    # fields happen to change. pushall makes the printer send everything once.
    request = {"pushing": {"sequence_id": "0", "command": "pushall"}}
    sock.sendall(_packet(0x30, _str(f"device/{SERIAL}/request") + json.dumps(request).encode()))
    return sock, buf


def _on_publish(flags, body):
    global _last_report
    (topic_len,) = struct.unpack("!H", body[:2])
    offset = 2 + topic_len
    if (flags >> 1) & 0x03:
        offset += 2  # packet identifier, present only above QoS 0
    try:
        message = json.loads(body[offset:])
    except ValueError:
        return
    update = message.get("print")
    if not isinstance(update, dict):
        return
    with _lock:
        merge(_report, update)
        _last_report = time.monotonic()


def _session():
    global _error
    sock, buf = _connect()
    sock.settimeout(5)
    with _lock:
        _error = None
    last_sent = last_heard = time.monotonic()
    try:
        while True:
            try:
                data = sock.recv(65536)
                if not data:
                    raise ConnectionError("printer closed the connection")
                buf += data
                last_heard = time.monotonic()
            except TimeoutError:
                pass
            while (packet := _split(buf)) is not None:
                kind, body = packet
                if kind & 0xF0 == 0x30:
                    _on_publish(kind & 0x0F, body)
            now = time.monotonic()
            # Keepalive counts what the broker receives from us, and a
            # subscriber only ever receives -- so ping on a timer regardless
            # of how busy the inbound side is.
            if now - last_sent > KEEPALIVE / 2:
                sock.sendall(b"\xc0\x00")
                last_sent = now
            if now - last_heard > STALE_AFTER:
                raise ConnectionError("no traffic from the printer")
    finally:
        sock.close()


def mqtt_loop():
    global _error
    delay = 1
    while True:
        started = time.monotonic()
        try:
            _session()
        except Exception as exc:  # any failure means reconnect, never exit
            with _lock:
                _error = str(exc) or type(exc).__name__
            print(f"mqtt: {_error}", flush=True)
        # Back off on repeated failure, but not after a session that ran for a
        # while -- that was a drop, and the printer is likely already back.
        delay = 1 if time.monotonic() - started > 60 else min(delay * 2, 60)
        time.sleep(delay)


# --- HTTP ------------------------------------------------------------------


def _num(value):
    return round(value) if isinstance(value, (int, float)) else None


def snapshot():
    """What the page draws. Derived here so the page stays a template, and so
    nothing from the printer reaches the browser unless it is listed below."""
    with _lock:
        report = json.loads(json.dumps(_report))
        age = time.monotonic() - _last_report if _last_report else None
        error = _error

    online = error is None and age is not None and age < STALE_AFTER
    state = report.get("gcode_state")
    temps = {}
    # Flat fields only. Dual-nozzle printers can also report per-extruder
    # temperatures under print.device in a packed form that is not publicly
    # documented; a reading that cannot be checked is left out rather than
    # shown wrong, so missing ones just do not appear.
    for name, current, target in (
        ("nozzle", "nozzle_temper", "nozzle_target_temper"),
        ("bed", "bed_temper", "bed_target_temper"),
        ("chamber", "chamber_temper", None),
    ):
        if _num(report.get(current)) is not None:
            temps[name] = {"current": _num(report[current]), "target": _num(report.get(target))}

    return {
        "online": online,
        "error": error if not online else None,
        "state": state,
        "label": STATE_LABELS.get(state, state.title() if isinstance(state, str) else None),
        "name": report.get("subtask_name") or report.get("gcode_file") or None,
        "percent": _num(report.get("mc_percent")),
        "remaining_min": _num(report.get("mc_remaining_time")),
        "layer": _num(report.get("layer_num")),
        "total_layers": _num(report.get("total_layer_num")),
        "temps": temps,
    }


class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        path = self.path.split("?", 1)[0]
        if path == "/state.json":
            self._send(200, "application/json", json.dumps(snapshot()).encode())
        elif path in ("/", "/overlay.html"):
            self._send(200, "text/html; charset=utf-8", PAGE.read_bytes())
        else:
            self._send(404, "text/plain", b"not found\n")

    def _send(self, status, kind, body):
        self.send_response(status)
        self.send_header("Content-Type", kind)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *args):
        pass  # the page polls every second; logging it would bury the MQTT lines


if __name__ == "__main__":
    threading.Thread(target=mqtt_loop, daemon=True).start()
    print(f"overlay: serving on :{HTTP_PORT}, printer {HOST}:{MQTT_PORT}", flush=True)
    ThreadingHTTPServer(("", HTTP_PORT), Handler).serve_forever()
