"""Call this Pod's own Inventory app on localhost and print the JSON reply.

Used with `kubectl exec <pod> -- python check.py /stats` to look at one
specific Pod directly, without going through the Service (an unready Pod is
not reachable through the Service, but it still answers on localhost).
"""

import sys
import urllib.error
import urllib.request

path = sys.argv[1] if len(sys.argv) > 1 else "/stats"
try:
    with urllib.request.urlopen(f"http://localhost:8080{path}", timeout=2) as resp:
        print(resp.status, resp.read().decode().strip())
except urllib.error.HTTPError as err:
    print(err.code, err.read().decode().strip())
