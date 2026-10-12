#!/usr/bin/env python3
"""Fetch pinned Pandoc corresponding-source materials and make a release archive.

The manifest separates versions observed in the binary from conservative source
supersets. This script verifies bytes; it does not certify license compliance.
"""

import argparse
import concurrent.futures
import gzip
import hashlib
import io
import json
from pathlib import Path
import re
import shutil
import tarfile
import time
import urllib.request


ROOT = Path(__file__).resolve().parents[2]
DEPENDENCIES = ROOT / "macos" / "Dependencies"


def digest(data):
    return hashlib.sha256(data).hexdigest()


def fetch(item, output):
    target = output / item["file"]
    if target.exists():
        data = target.read_bytes()
        if len(data) == item["size"] and digest(data) == item["sha256"]:
            return target
    for attempt in range(4):
        try:
            with urllib.request.urlopen(item["url"], timeout=120) as response:
                data = response.read()
            if len(data) != item["size"] or digest(data) != item["sha256"]:
                raise ValueError("checksum mismatch: " + item["file"])
            target.parent.mkdir(parents=True, exist_ok=True)
            temporary = target.with_suffix(target.suffix + ".partial")
            temporary.write_bytes(data)
            temporary.replace(target)
            return target
        except Exception:
            if attempt == 3:
                raise
            time.sleep(attempt + 1)


def license_members(archive):
    """Keep original notices, including license files named by Cabal metadata."""
    members = archive.getmembers()
    declared = set()
    for member in members:
        if member.isfile() and member.name.endswith(".cabal"):
            cabal = archive.extractfile(member).read().decode("utf-8", "replace")
            for match in re.finditer(r"(?im)^license-files?\s*:\s*(.+(?:\n[ \t]+[^\n]+)*)", cabal):
                for filename in re.split(r"[\s,]+", match.group(1).strip()):
                    declared.add(str(Path(member.name).parent / filename))
    for member in members:
        basename = Path(member.name).name
        # Lua's wrapper LICENSE has older dates; the bundled interpreter keeps
        # its current permission/copyright notice in lua.h itself.
        if member.isfile() and re.search(r"/lua-[0-9.]+/lua\.h$", member.name):
            header = archive.extractfile(member).read()
            for block in re.findall(rb"/\*.*?\*/", header, re.S):
                if b"Lua.org" in block and b"Permission is hereby granted" in block:
                    yield member.name + " (original license block)", block
        if member.isfile() and (
            re.match(r"^(?:licen[sc]e|copying|copyright|notice|patents)(?:$|[.\-_]|v\d)", basename, re.I)
            or member.name in declared
        ):
            yield member.name, archive.extractfile(member).read()


def notices(manifest, output):
    texts = {}

    def keep(label, data):
        # Identical texts are printed once; every originating file stays listed.
        key = digest(data)
        texts.setdefault(key, {"data": data, "labels": []})["labels"].append(label)

    for item in manifest["upstream_sources"] + manifest["haskell_sources"]:
        with tarfile.open(output / item["file"]) as archive:
            for name, data in license_members(archive):
                if item["name"].startswith("ghc-") and ("/tests/" in name or "/testsuite/" in name):
                    continue
                keep(item["name"] + ": " + name, data)
            if item["name"].startswith("ghc-"):
                for member in archive.getmembers():
                    if member.isfile() and re.search(r"/gmp-[^/]+\.tar\.(?:xz|bz2|gz)$", member.name):
                        with tarfile.open(fileobj=io.BytesIO(archive.extractfile(member).read())) as gmp:
                            for name, data in license_members(gmp):
                                keep("GHC bundled GMP: " + name, data)
    intro = (
        "PANDOC AND SOURCE-SUPERSET THIRD-PARTY NOTICES\n\n"
        "These original upstream notices cover the identified Pandoc dependencies\n"
        "and conservative historical source alternatives shipped with the source\n"
        "archive. Inclusion here does not assert that every listed version is\n"
        "linked into the app. See pandoc-source-manifest.json and Pandoc-SOURCE.txt.\n"
        "No upstream license or copyright text has been rewritten.\n\n"
    )
    sections = [intro]
    for entry in sorted(texts.values(), key=lambda value: value["labels"][0]):
        sections.append("=" * 72 + "\n" + "\n".join(entry["labels"]) + "\n\n")
        sections.append(entry["data"].decode("utf-8", "replace") + "\n\n")
    return "".join(sections)


def make_archive(output, manifest, notice_file):
    name = "pandoc-3.12.1-macos-arm64-source"
    destination = output.parent / (name + ".tar.gz")
    files = [(output / item["file"], item["file"]) for item in
             manifest["upstream_sources"] + manifest["haskell_sources"] + manifest["cabal_revisions"]]
    files += [(DEPENDENCIES / "pandoc-source-manifest.json", "manifest.json"),
              (DEPENDENCIES / "Pandoc-SOURCE.txt", "BUILD.txt"),
              (notice_file, "THIRD-PARTY-NOTICES.txt"),
              (Path(__file__).with_name("rebuild-pandoc.py"), "rebuild-pandoc.py"),
              (Path(__file__), "prepare-pandoc-source.py")]
    with destination.open("wb") as raw, gzip.GzipFile(filename="", mode="wb", fileobj=raw, mtime=0) as compressed:
        with tarfile.open(fileobj=compressed, mode="w|") as archive:
            for source, relative in sorted(files, key=lambda pair: pair[1]):
                info = tarfile.TarInfo(name + "/" + relative)
                info.size = source.stat().st_size
                info.mode = 0o755 if relative.endswith(".py") else 0o644
                info.mtime = 0
                with source.open("rb") as stream:
                    archive.addfile(info, stream)
    checksum = digest(destination.read_bytes())
    destination.with_suffix(destination.suffix + ".sha256").write_text(checksum + "  " + destination.name + "\n")
    print(str(destination))
    print("SHA256 " + checksum)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, default=ROOT / "macos/.build/distribution/source")
    parser.add_argument("--workers", type=int, default=12)
    parser.add_argument("--write-notices", action="store_true", help="refresh the checked-in app notices")
    arguments = parser.parse_args()
    manifest = json.loads((DEPENDENCIES / "pandoc-source-manifest.json").read_text())
    output = arguments.output.resolve()
    output.mkdir(parents=True, exist_ok=True)
    items = manifest["upstream_sources"] + manifest["haskell_sources"] + manifest["cabal_revisions"]
    with concurrent.futures.ThreadPoolExecutor(max_workers=arguments.workers) as executor:
        list(executor.map(lambda item: fetch(item, output), items))
    print("Verified " + str(len(items)) + " pinned source/metadata files")
    text = notices(manifest, output)
    notice_file = output / "Pandoc-THIRD-PARTY-NOTICES.txt"
    notice_file.write_text(text)
    if arguments.write_notices:
        shutil.copyfile(notice_file, DEPENDENCIES / notice_file.name)
    make_archive(output, manifest, notice_file)


if __name__ == "__main__":
    main()
