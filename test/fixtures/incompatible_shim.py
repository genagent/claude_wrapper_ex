"""Legacy protocol peer: rejects HELLO, records requests, never runs a child."""
import json
import os
import struct
import sys


def read_frame():
    header = sys.stdin.buffer.read(4)
    if len(header) != 4:
        return None
    return sys.stdin.buffer.read(struct.unpack(">I", header)[0])


request_log = os.path.join(os.path.dirname(__file__), "shim-requests")
first = read_frame()
with open(request_log, "w") as log:
    if first:
        log.write(str(first[0]) + "\n")
        log.flush()
    # An older shim expects SPAWN (1); strict runs must send HELLO (7) first.
    payload = bytes([0x14]) + json.dumps({"reason": "expected SPAWN"}).encode()
    sys.stdout.buffer.write(struct.pack(">I", len(payload)) + payload)
    sys.stdout.buffer.flush()
    while True:
        request = read_frame()
        if request is None:
            break
        log.write(str(request[0]) + "\n")
        log.flush()
