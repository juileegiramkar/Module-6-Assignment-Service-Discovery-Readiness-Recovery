"""Inventory client.

Talks to the Inventory Service ONLY through its Kubernetes Service name
(INVENTORY_URL, default http://inventory-service). It never uses Pod names or
Pod IPs. Cluster DNS turns the name into the Service's stable ClusterIP and
kube-proxy forwards each new connection to one of the Ready Inventory Pods.

Modes:
  loop     (default, used by the Deployment) one request every INTERVAL seconds, forever
  burst    send --count requests and print how many each Pod served
  resolve  show what the Service name resolves to inside the cluster
"""

import argparse
import collections
import json
import os
import socket
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from datetime import datetime, timezone

INVENTORY_URL = os.environ.get("INVENTORY_URL", "http://inventory-service")
INTERVAL = float(os.environ.get("REQUEST_INTERVAL_SECONDS", "1"))
TIMEOUT = float(os.environ.get("REQUEST_TIMEOUT_SECONDS", "2"))
SKUS = ["SKU-1001", "SKU-1002", "SKU-1003", "SKU-1004", "SKU-1005"]


def now():
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%S.%f")[:-3] + "Z"


def call_inventory(sku):
    """One GET on a fresh TCP connection (urllib sends Connection: close), so
    kube-proxy makes a new load-balancing decision for every request."""
    url = f"{INVENTORY_URL}/inventory/{sku}"
    try:
        with urllib.request.urlopen(url, timeout=TIMEOUT) as resp:
            body = json.load(resp)
            return resp.status, body.get("served_by"), body
    except urllib.error.HTTPError as err:
        try:
            body = json.load(err)
        except ValueError:
            body = {}
        return err.code, body.get("served_by"), body
    except (urllib.error.URLError, OSError) as err:
        return None, None, {"error": str(getattr(err, "reason", err))}


def describe(seq, sku, status, served_by, body):
    if status is None:
        return f"{now()}  #{seq:04d}  FAILED  sku={sku}  error={body.get('error')}"
    qty = body.get("quantity", "-")
    return f"{now()}  #{seq:04d}  {status}  served_by={served_by}  sku={sku}  qty={qty}"


def resolve():
    host = urllib.parse.urlparse(INVENTORY_URL).hostname
    namespace = "unknown"
    try:
        with open("/var/run/secrets/kubernetes.io/serviceaccount/namespace") as f:
            namespace = f.read().strip()
    except OSError:
        pass
    fqdn = f"{host}.{namespace}.svc.cluster.local"
    for name in (host, fqdn):
        try:
            print(f"{name:45s} -> {socket.gethostbyname(name)}")
        except OSError as err:
            print(f"{name:45s} -> lookup failed: {err}")
    with open("/etc/resolv.conf") as f:
        search = [line.strip() for line in f if line.startswith("search")]
    print(f"/etc/resolv.conf: {search[0] if search else '(no search line)'}")


def burst(count):
    tally = collections.Counter()
    failures = 0
    print(f"Sending {count} requests to {INVENTORY_URL} (Service name, not Pod IPs)")
    for i in range(1, count + 1):
        sku = SKUS[(i - 1) % len(SKUS)]
        status, served_by, body = call_inventory(sku)
        print(describe(i, sku, status, served_by, body))
        if status is None:
            failures += 1
        else:
            tally[served_by] += 1
        time.sleep(0.05)
    print("\nRequests served per Inventory Pod:")
    for pod, n in sorted(tally.items()):
        print(f"  {pod:40s} {n:3d}  {'#' * n}")
    print(f"  {'failed requests':40s} {failures:3d}")
    print(f"  distinct Pods that answered: {len(tally)}")


def loop():
    host = urllib.parse.urlparse(INVENTORY_URL).hostname
    try:
        ip = socket.gethostbyname(host)
    except OSError as err:
        ip = f"(lookup failed: {err})"
    print(f"{now()}  inventory-client started. Target {INVENTORY_URL}; "
          f"'{host}' resolves to {ip} (the Service ClusterIP)", flush=True)
    seq = 0
    while True:
        seq += 1
        sku = SKUS[(seq - 1) % len(SKUS)]
        status, served_by, body = call_inventory(sku)
        print(describe(seq, sku, status, served_by, body), flush=True)
        time.sleep(INTERVAL)


def main():
    parser = argparse.ArgumentParser(description=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("mode", nargs="?", default="loop", choices=["loop", "burst", "resolve"])
    parser.add_argument("--count", type=int, default=20, help="requests to send in burst mode")
    args = parser.parse_args()
    if args.mode == "burst":
        burst(args.count)
    elif args.mode == "resolve":
        resolve()
    else:
        loop()


if __name__ == "__main__":
    sys.exit(main())
