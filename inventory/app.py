"""Inventory Service.

A small stock-lookup API. Two replicas of this app run behind the Kubernetes
Service `inventory-service`. Every response says which Pod served it, so the
client can show how requests are spread over the replicas.

Readiness is controlled by the app itself:
  * for the first WARMUP_SECONDS after start-up the Pod reports "not ready"
    (simulates loading the catalog), so a fresh Pod gets no traffic until it
    is actually able to serve;
  * while the flag file NOT_READY_FLAG (default /tmp/not-ready) exists the Pod
    reports "not ready". The demo creates/removes it with `kubectl exec`.
Liveness (/healthz) never depends on readiness, so an unready Pod keeps
running instead of being restarted.
"""

import logging
import os
import socket
import sys
import threading
import time

from flask import Flask, jsonify

POD_NAME = os.environ.get("POD_NAME", socket.gethostname())
POD_IP = os.environ.get("POD_IP", "unknown")
NODE_NAME = os.environ.get("NODE_NAME", "unknown")
WARMUP_SECONDS = float(os.environ.get("WARMUP_SECONDS", "5"))
NOT_READY_FLAG = os.environ.get("NOT_READY_FLAG", "/tmp/not-ready")

STOCK = {
    "SKU-1001": {"name": "Wireless Mouse", "quantity": 42},
    "SKU-1002": {"name": "Mechanical Keyboard", "quantity": 17},
    "SKU-1003": {"name": "USB-C Hub", "quantity": 0},
    "SKU-1004": {"name": "27-inch Monitor", "quantity": 8},
    "SKU-1005": {"name": "Laptop Stand", "quantity": 23},
}

logging.basicConfig(
    stream=sys.stdout,
    level=logging.INFO,
    format="%(asctime)s.%(msecs)03dZ  %(message)s",   # containers run in UTC
    datefmt="%Y-%m-%dT%H:%M:%S",
)
log = logging.getLogger("inventory")

app = Flask(__name__)

_started = time.monotonic()
_lock = threading.Lock()
_requests_served = 0
_last_ready_state = None


def _readiness():
    """Return (ready, reason)."""
    if time.monotonic() - _started < WARMUP_SECONDS:
        return False, f"warming up (first {WARMUP_SECONDS:g}s after start)"
    if os.path.exists(NOT_READY_FLAG):
        return False, f"flag file {NOT_READY_FLAG} is present"
    return True, "ok"


def _count_request():
    global _requests_served
    with _lock:
        _requests_served += 1
        return _requests_served


def _identity():
    return {"served_by": POD_NAME, "pod_ip": POD_IP, "node": NODE_NAME}


@app.get("/inventory")
def list_inventory():
    n = _count_request()
    log.info("[%s] served GET /inventory -> 200 (request #%d)", POD_NAME, n)
    return jsonify(items=STOCK, request_number=n, **_identity())


@app.get("/inventory/<sku>")
def get_item(sku):
    n = _count_request()
    item = STOCK.get(sku)
    if item is None:
        log.info("[%s] served GET /inventory/%s -> 404 (request #%d)", POD_NAME, sku, n)
        return jsonify(error=f"unknown sku {sku}", request_number=n, **_identity()), 404
    log.info("[%s] served GET /inventory/%s -> 200 qty=%d (request #%d)",
             POD_NAME, sku, item["quantity"], n)
    return jsonify(sku=sku, **item, in_stock=item["quantity"] > 0,
                   request_number=n, **_identity())


@app.get("/healthz")
def healthz():
    # Liveness: the process is up and answering HTTP. Deliberately ignores readiness.
    return jsonify(status="alive", pod=POD_NAME)


@app.get("/ready")
def ready():
    # Readiness: called by the kubelet every few seconds. Only state changes are logged.
    global _last_ready_state
    is_ready, reason = _readiness()
    if is_ready != _last_ready_state:
        log.info("[%s] READINESS -> %s (%s)", POD_NAME,
                 "READY" if is_ready else "NOT READY", reason)
        _last_ready_state = is_ready
    return jsonify(ready=is_ready, reason=reason, pod=POD_NAME), (200 if is_ready else 503)


@app.get("/stats")
def stats():
    is_ready, reason = _readiness()
    with _lock:
        served = _requests_served
    return jsonify(pod=POD_NAME, pod_ip=POD_IP, requests_served=served, ready=is_ready,
                   readiness_reason=reason,
                   uptime_seconds=round(time.monotonic() - _started, 1))


log.info("[%s] Inventory Service starting on %s (node %s), warm-up %gs",
         POD_NAME, POD_IP, NODE_NAME, WARMUP_SECONDS)
