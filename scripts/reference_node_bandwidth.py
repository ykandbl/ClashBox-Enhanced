#!/usr/bin/env python3
"""Independent persistent-session reference through the phone mixed port."""

import concurrent.futures
import json
import sys
import time
import uuid

import requests


def usage() -> None:
    raise SystemExit(
        "Usage: python3 reference_node_bandwidth.py LOCAL_PORT BYTES_PER_STREAM SAMPLES"
    )


if len(sys.argv) != 4:
    usage()
port = int(sys.argv[1])
bytes_per_stream = int(sys.argv[2])
sample_count = int(sys.argv[3])
if port <= 0 or bytes_per_stream <= 0 or sample_count < 1:
    usage()

concurrency = 4
proxy = f"http://127.0.0.1:{port}"
sessions: list[requests.Session] = []
for _ in range(concurrency):
    session = requests.Session()
    session.trust_env = False
    session.proxies = {"http": proxy, "https": proxy}
    session.headers.update({"User-Agent": "FireflyReference/1.0", "Cache-Control": "no-store"})
    sessions.append(session)


def transfer(worker: int, direction: str, size: int) -> int:
    session = sessions[worker]
    if direction == "down":
        response = session.get(
            "https://speed.cloudflare.com/__down",
            params={"bytes": size, "reference": uuid.uuid4().hex},
            stream=True,
            timeout=(10, 100),
        )
        response.raise_for_status()
        count = sum(len(chunk) for chunk in response.iter_content(chunk_size=64 * 1024))
    else:
        response = session.post(
            "https://speed.cloudflare.com/__up",
            data=bytes(size),
            headers={"Content-Type": "application/octet-stream"},
            timeout=(10, 100),
        )
        response.raise_for_status()
        count = size
    response.close()
    if count < size * 0.98:
        raise RuntimeError(f"{direction} incomplete: {count}/{size}")
    return count


def group(pool: concurrent.futures.ThreadPoolExecutor, direction: str, size: int) -> dict:
    started = time.perf_counter()
    futures = [pool.submit(transfer, worker, direction, size) for worker in range(concurrency)]
    payload = sum(future.result() for future in futures)
    elapsed_ms = (time.perf_counter() - started) * 1000
    return {
        "mbps": round(payload * 8 / elapsed_ms / 1000, 2),
        "elapsedMs": round(elapsed_ms),
        "payloadBytes": payload,
    }


try:
    with concurrent.futures.ThreadPoolExecutor(max_workers=concurrency) as executor:
        group(executor, "down", 100_000)
        group(executor, "up", 100_000)
        result = {
            "bytesPerStream": bytes_per_stream,
            "concurrency": concurrency,
            "persistentSessions": True,
            "down": [],
            "up": [],
        }
        for direction in ("down", "up"):
            for _ in range(sample_count):
                result[direction].append(group(executor, direction, bytes_per_stream))
        print(json.dumps(result, separators=(",", ":")))
finally:
    for current in sessions:
        current.close()
