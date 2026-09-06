#!/usr/bin/env python3
"""Show what the sync server is holding, in a form a person can read.

The API returns opaque JSON documents, which is right for the protocol and
useless for answering "did my notes actually arrive". This prints them as a
summary, or as full records when asked.

    python inspect_data.py --url http://localhost:8001 --token SECRET
    python inspect_data.py --collection notes --full
    python inspect_data.py --search "plumber"

Reads TRUDIDO_URL and TRUDIDO_TOKEN from the environment if the flags are
omitted. Read-only: it never writes to the server.
"""
import argparse
import json
import os
import sys
import urllib.error
import urllib.request
from datetime import datetime

# The fields worth showing per collection, in the order they read best.
TITLE_FIELDS = ["text", "title", "name", "content"]


def fetch(url: str, token: str, path: str) -> dict:
    request = urllib.request.Request(url.rstrip("/") + path)
    if token:
        request.add_header("X-Trudido-Token", token)
    try:
        with urllib.request.urlopen(request, timeout=30) as response:
            return json.loads(response.read())
    except urllib.error.HTTPError as exc:
        if exc.code == 401:
            sys.exit("401 Unauthorized: wrong or missing token (--token).")
        sys.exit(f"HTTP {exc.code} for {path}: {exc.read().decode()[:200]}")
    except urllib.error.URLError as exc:
        sys.exit(f"Could not reach {url}: {exc.reason}")


def all_records(url: str, token: str) -> list[dict]:
    """Page through the whole history. Same cursor walk the app does."""
    records, cursor, guard = [], 0, 0
    while True:
        guard += 1
        if guard > 1000:
            sys.exit("Pull did not terminate; aborting.")
        page = fetch(url, token, f"/api/v1/sync/changes?since={cursor}")
        records.extend(page["records"])
        cursor = page["cursor"]
        if not page["has_more"]:
            return records


def describe(record: dict) -> str:
    payload = record.get("payload") or {}
    for field in TITLE_FIELDS:
        value = payload.get(field)
        if isinstance(value, str) and value.strip():
            text = " ".join(value.split())
            return text[:70] + ("…" if len(text) > 70 else "")
    return "(no title)"


def size(byte_count: int) -> str:
    """Bytes in whatever unit does not read as 0.0."""
    if byte_count < 1024:
        return f"{byte_count} B"
    if byte_count < 1024 * 1024:
        return f"{byte_count / 1024:.1f} KB"
    return f"{byte_count / 1024 / 1024:.1f} MB"


def when(value: str) -> str:
    try:
        return datetime.fromisoformat(value.replace("Z", "+00:00")).strftime(
            "%Y-%m-%d %H:%M"
        )
    except ValueError:
        return value


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--url", default=os.getenv("TRUDIDO_URL", "http://localhost:8001"))
    parser.add_argument("--token", default=os.getenv("TRUDIDO_TOKEN", ""))
    parser.add_argument("--collection", help="Only this collection (todos, notes, …)")
    parser.add_argument("--search", help="Only records whose payload contains this text")
    parser.add_argument("--full", action="store_true", help="Print whole payloads")
    parser.add_argument("--deleted", action="store_true", help="Include deleted records")
    args = parser.parse_args()

    status = fetch(args.url, args.token, "/api/v1/sync/status")
    records = all_records(args.url, args.token)

    if args.collection:
        records = [r for r in records if r["collection"] == args.collection]
    if not args.deleted:
        records = [
            r for r in records
            if not r["deleted"] and not (r.get("payload") or {}).get("isDeleted")
        ]
    if args.search:
        needle = args.search.lower()
        records = [r for r in records if needle in json.dumps(r.get("payload") or {}).lower()]

    print(f"Server   {args.url}")
    print(f"Revision {status['cursor']}")
    print()

    if not records:
        print("Nothing matches." if (args.collection or args.search) else "Server is empty.")
        return

    by_collection: dict[str, list[dict]] = {}
    for record in records:
        by_collection.setdefault(record["collection"], []).append(record)

    for collection in sorted(by_collection):
        rows = sorted(by_collection[collection], key=lambda r: r["updated_at"], reverse=True)
        heading = f"{collection}  ({len(rows)})"
        print(heading)
        print("-" * len(heading))
        for record in rows:
            flag = " [deleted]" if record["deleted"] else ""
            if (record.get("payload") or {}).get("isDeleted"):
                flag = " [in bin]"
            print(f"  {when(record['updated_at'])}  {describe(record)}{flag}")
            if args.full:
                body = json.dumps(record.get("payload"), indent=4, ensure_ascii=False)
                print("\n".join(f"      {line}" for line in body.splitlines()))
        print()

    blobs = fetch(args.url, args.token, "/api/v1/blobs/manifest")["blobs"]
    total = sum(b["size"] for b in blobs)
    heading = f"attachments  ({len(blobs)}, {size(total)})"
    print(heading)
    print("-" * len(heading))
    for blob in blobs:
        print(f"  {blob['sha256'][:12]}  {size(blob['size']):>9}  {blob['filename']}")


if __name__ == "__main__":
    main()
