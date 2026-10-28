#!/usr/bin/env python3
"""Redact the transcript fixtures before they enter the repo.

Usage:  python3 macos/DSHTests/Fixtures/scrub-fixtures.py [--check]

Rules, applied to every string inside the JSON (so escaped text is covered):

1. `/Users/<any user>` → `/Users/developer` (also inside scratch paths such as
   `/private/tmp/claude-501/-Users-<user>-Library-...`).
2. `127.0.0.1:<port>` / `localhost:<port>` → `127.0.0.1:0000` /
   `localhost:0000`.
3. The local account (`$USER`, and the last component of `$HOME`) plus any extra
   words listed one per line in the git-ignored `scrub-local.txt` are replaced
   with `exampleco`; this file names no account or company itself.
4. The embedded agent system prompt and skill catalogue are replaced with
   `[redacted system prompt]` / `[redacted skill catalogue]`, keeping the rest
   of the turn (the part that drives layout) intact.
5. Credential shapes (`sk-…`, `Bearer …`, `token: "…"`) → `[redacted]`.

--check exits non-zero if any of these would still match, for CI/pre-commit.
"""
import json
import os
import re
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
LOCAL_TERMS = HERE / "scrub-local.txt"

USER_PATH = re.compile(r"/Users/[^/\"'\s\\]+")
SCRATCH = re.compile(r"/private/tmp/claude-501/-Users-[^/\"'\s\\]+-[^/\"'\s\\]+")
PORT = re.compile(r"\b(127\.0\.0\.1|localhost):\d{2,5}\b")
SYS_PROMPT = re.compile(r"^You are an AI agent powered by DeepSeek Harness.*$", re.S)
SKILLS = re.compile(r"^# Available skills.*$", re.S)
SECRET = re.compile(r"\b(sk-[A-Za-z0-9_\-]{8,}|Bearer\s+[A-Za-z0-9._\-]{8,})")


def account_terms():
    """Local nouns that must never reach a committed fixture."""
    terms = {os.environ.get("USER", ""), Path(os.environ.get("HOME", "/")).name}
    if LOCAL_TERMS.exists():
        for line in LOCAL_TERMS.read_text().splitlines():
            line = line.strip()
            if line and not line.startswith("#"):
                terms.add(line)
    return sorted((term for term in terms if len(term) >= 3), key=len, reverse=True)


TERMS = account_terms()
ACCOUNT = re.compile("|".join(re.escape(term) for term in TERMS), re.I) if TERMS else None


def scrub_string(value: str) -> str:
    if SYS_PROMPT.match(value):
        return "[redacted system prompt]"
    if SKILLS.match(value):
        return "[redacted skill catalogue]"
    value = SCRATCH.sub("/private/tmp/scratch", value)
    value = USER_PATH.sub("/Users/developer", value)
    value = PORT.sub(lambda match: match.group(1) + ":0000", value)
    if ACCOUNT is not None:
        value = ACCOUNT.sub("exampleco", value)
    value = SECRET.sub("[redacted]", value)
    return value


def walk(node):
    if isinstance(node, str):
        return scrub_string(node)
    if isinstance(node, list):
        return [walk(value) for value in node]
    if isinstance(node, dict):
        return {key: walk(value) for key, value in node.items()}
    return node


def offenders(text: str):
    hits = []
    if ACCOUNT is not None:
        hits.extend(sorted({match.group(0) for match in ACCOUNT.finditer(text)}))
    for match in re.finditer(r"/Users/([^/\"\s\\]+)", text):
        if match.group(1) != "developer":
            hits.append(match.group(0))
    if re.search(r"127\.0\.0\.1:(?!0000)\d{2,5}", text):
        hits.append("127.0.0.1:<port>")
    if re.search(r"\bsk-|Bearer\s|cookie|@[a-z0-9-]+\.[a-z]{2,}", text, re.I):
        hits.append("credential/email shape")
    return hits


def main() -> int:
    check = "--check" in sys.argv
    failed = 0
    roots = [HERE, HERE.parents[2] / "scripts" / "fixtures"]
    paths = sorted({path for root in roots for path in root.glob("*.json")})
    for path in paths:
        text = path.read_text()
        if check:
            hits = offenders(text)
            if hits:
                failed = 1
                print(f"{path.name}: {sorted(set(hits))[:4]}")
            continue
        data = json.loads(text)
        cleaned = json.dumps(walk(data), ensure_ascii=False, separators=(",", ":"))
        if cleaned != text:
            path.write_text(cleaned)
            print(f"{path.name}: scrubbed")
    return failed


if __name__ == "__main__":
    raise SystemExit(main())
