#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"

# Pre-publish hygiene scan: secrets and personal information, in the
# working tree and across all git history. Run before pushing anywhere
# public; fails loudly on any finding.
#
# Usage:
#   ./scan.sh
#
# gitleaks and python3 are required; trufflehog joins in when installed.
# Both scanners inspect all Git refs and a snapshot of publishable working-tree
# files, plus the independent Git index (staged, unstaged, and untracked;
# ignored files are not published unless explicitly added to the index).
# A grep sweep then catches personal information that secret
# scanners don't consider leaks: email addresses (example.com/org/net
# fixtures excepted), home directory paths, and private key material.
# Findings judged acceptable live in .scanallow (one extended regex per
# line, comments allowed) — anything matching there is ignored, so the
# scan stays green without forgetting what it saw.
#
# Note: commit author names and emails publish with history too, and no
# content scan sees them. git log --format='%an <%ae>' | sort -u

fail=0

for tool in gitleaks python3; do
    if ! command -v "$tool" >/dev/null 2>&1; then
        echo "Missing scan dependency: $tool" >&2
        exit 1
    fi
done

# Scanner Git modes do not inspect uncommitted edits or untracked files. Copy
# both the Git index and publishable working-tree contents: a staged secret
# must still be caught if its working-tree copy is later replaced or deleted.
# Symlinks are scanned as the link text Git would publish, never followed to
# files outside the repository. The private snapshot is removed on every exit.
scan_tmp=$(mktemp -d "${TMPDIR:-/tmp}/fb-scan.XXXXXX")
trap 'rm -rf "$scan_tmp"' EXIT
snapshot="$scan_tmp/publishable"
mkdir "$snapshot"
if ! python3 - "$snapshot" <<'PYTHON'
import os
import re
import shutil
import subprocess
import sys
from pathlib import Path

snapshot = Path(sys.argv[1])
worktree_snapshot = snapshot / "worktree"
index_snapshot = snapshot / "index"
paths = subprocess.check_output([
    "git", "ls-files", "--cached", "--others", "--exclude-standard", "-z"
]).split(b"\0")
credential_name = re.compile(
    r"(?i)(?:^|/)(?:AuthKey_[^/]+\.p8|id_(?:rsa|dsa|ed25519|ecdsa)|"
    r"[^/]+\.(?:p8|p12|pfx|key|jks|keystore)|\.env(?:\.[^/]+)?|credentials(?:\.json)?)$"
)
example_name = re.compile(r"(?i)\.(?:example|sample|template|dist)$")
blocked = set()
index_conflicts = []
for record in subprocess.check_output(["git", "ls-files", "--stage", "-z"]).split(b"\0"):
    if not record:
        continue
    metadata, raw_path = record.split(b"\t", 1)
    mode, object_id, stage = metadata.split()
    relative = os.fsdecode(raw_path)
    if stage != b"0":
        index_conflicts.append(relative)
        continue
    if credential_name.search(relative) and not example_name.search(relative):
        blocked.add(relative)
    if mode == b"160000":
        continue  # A gitlink publishes only a commit ID, not submodule files.
    target = index_snapshot / relative
    target.parent.mkdir(parents=True, exist_ok=True)
    target.write_bytes(subprocess.check_output(["git", "cat-file", "blob", object_id]))
for raw in paths:
    if not raw:
        continue
    source = Path(os.fsdecode(raw))
    if not source.exists() and not source.is_symlink():
        continue  # A tracked deletion publishes no working-tree content.
    relative = source.as_posix()
    if credential_name.search(relative) and not example_name.search(relative):
        blocked.add(relative)
    target = worktree_snapshot / source
    target.parent.mkdir(parents=True, exist_ok=True)
    if source.is_symlink():
        target.write_bytes(os.fsencode(os.readlink(source)))
    elif source.is_file():
        shutil.copyfile(source, target)
if blocked:
    print("Credential-like filenames are publishable; remove or ignore them:")
    for name in sorted(blocked):
        print("  " + name)
if index_conflicts:
    print("Resolve unmerged index entries before the publication scan.")
if blocked or index_conflicts:
    sys.exit(1)
PYTHON
then
    fail=1
fi

echo "== gitleaks (all refs, index, and publishable working tree)"
for source in history worktree; do
    if [[ "$source" == history ]]; then
        command=(gitleaks git --log-opts='--all --full-history' .)
    else
        command=(gitleaks dir "$snapshot")
    fi
    if "${command[@]}" --no-banner --no-color --redact=100 \
        --ignore-gitleaks-allow --gitleaks-ignore-path "$scan_tmp" \
        >"$scan_tmp/gitleaks-$source.log" 2>&1; then
        echo "$source: clean"
    else
        # Gitleaks' own redaction applies to both findings and diagnostics.
        cat "$scan_tmp/gitleaks-$source.log"
        fail=1
    fi
done

if command -v trufflehog >/dev/null; then
    echo "== trufflehog (all refs, index, and publishable working tree)"
    for source in history worktree; do
        if [[ "$source" == history ]]; then
            command=(trufflehog git "file://$PWD")
        else
            command=(trufflehog filesystem "$snapshot")
        fi
        # Verification is unnecessary for a publish gate: any suspected
        # credential is a failure. Do not send candidate secrets to providers.
        if "${command[@]}" --no-update --no-verification --no-ignore-tag \
            --fail-on-scan-errors --json \
            >"$scan_tmp/trufflehog-$source.json" 2>"$scan_tmp/trufflehog-$source.log"; then
            findings=$(wc -l <"$scan_tmp/trufflehog-$source.json" | tr -d ' ')
            if [[ "$findings" != 0 ]]; then
                echo "$source: $findings potential credential findings (values withheld)"
                fail=1
            else
                echo "$source: clean"
            fi
        else
            echo "$source: trufflehog scan failed; no successful audit result"
            fail=1
        fi
    done
fi

echo "== personal information sweep (index, publishable working tree, and all refs)"
allow() {
    if [[ -f .scanallow ]]; then
        grep -v -E -f <(grep -v '^#' .scanallow | grep -v '^$') || true
    else
        cat
    fi
}
sweep() {
    local label="$1" pattern="$2" except="${3:-^$}"
    local hits
    hits=$( {
        grep -R -I -h -o -E --exclude-dir=assets "$pattern" "$snapshot" 2>/dev/null || true
        git rev-list --all | while read -r c; do
            git grep -I -h -o -E "$pattern" "$c" -- ':(exclude)assets' 2>/dev/null || true
        done
    } | sort -u | { grep -v -E "$except" || true; } | allow)
    if [[ -n "$hits" ]]; then
        echo "$label:"
        sed 's/^/  /' <<<"$hits"
        fail=1
    fi
}

sweep "email addresses" '[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}' '@example\.(com|org|net)$'
sweep "home directory paths" '/(Users|home)/[A-Za-z0-9_.-]+'
sweep "private key material" 'BEGIN [A-Z ]*PRIVATE KEY'

if [[ $fail != 0 ]]; then
    echo "SCAN FAILED — resolve (or allowlist in .scanallow) before publishing"
    exit 1
fi
echo "scan clean"
