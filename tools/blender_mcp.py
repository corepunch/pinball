#!/usr/bin/env python3
"""Send a source file to Blender's installed MCP add-on bridge (localhost only).

Start the isolated bridge with the command documented in Art/MODEL_GUIDE.md.
No third-party Python packages are required.
"""
import argparse
import json
import socket
from pathlib import Path


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("script", type=Path)
    parser.add_argument("--port", type=int, default=9877)
    args = parser.parse_args()
    code = "__file__ = " + repr(str(args.script.resolve())) + "\n" + args.script.read_text()
    request = {"type": "execute", "strict_json": True, "code": code}
    with socket.create_connection(("127.0.0.1", args.port), timeout=30) as connection:
        connection.settimeout(300)
        connection.sendall(json.dumps(request).encode() + b"\0")
        response = bytearray()
        while b"\0" not in response:
            chunk = connection.recv(65536)
            if not chunk:
                raise RuntimeError("Blender closed the connection without a result")
            response.extend(chunk)
    result = json.loads(response.split(b"\0", 1)[0])
    print(json.dumps(result, indent=2))
    if result.get("status") != "ok":
        raise SystemExit(1)


if __name__ == "__main__":
    main()
