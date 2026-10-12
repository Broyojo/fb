#!/usr/bin/env python3
"""Prepare a local Cabal source repository; optionally rebuild Pandoc.

Run inside the extracted corresponding-source bundle. Requires Python 3.12+;
building also requires GHC 9.10.3, cabal-install 3.14 and Xcode command-line tools.
"""

import argparse
import hashlib
import json
from pathlib import Path
import shutil
import subprocess
import sys
import tarfile


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--build", action="store_true")
    args = parser.parse_args()
    if sys.version_info < (3, 12):
        raise SystemExit("Python 3.12 or later is required for safe archive extraction")
    root = Path(__file__).resolve().parent
    manifest = json.loads((root / "manifest.json").read_text())
    for item in manifest["upstream_sources"] + manifest["haskell_sources"] + manifest["cabal_revisions"]:
        data = (root / item["file"]).read_bytes()
        if len(data) != item["size"] or hashlib.sha256(data).hexdigest() != item["sha256"]:
            raise SystemExit("Source checksum mismatch: " + item["file"])
    work = root / "work"
    repository = work / "packages"
    repository.mkdir(parents=True, exist_ok=True)
    for item in manifest["haskell_sources"]:
        destination = repository / (item["name"] + ".tar.gz")
        if not destination.exists():
            shutil.copyfile(root / item["file"], destination)
    latest = {}
    for item in manifest["cabal_revisions"]:
        if item["name"] not in latest or item["revision"] > latest[item["name"]]["revision"]:
            latest[item["name"]] = item
    for name, item in latest.items():
        shutil.copyfile(root / item["file"], repository / (name + ".cabal"))
    source = work / "pandoc-3.12.1"
    if not source.exists():
        with tarfile.open(root / "upstream/pandoc-3.12.1.tar.gz") as archive:
            archive.extractall(work, filter="data")
    constraints = sorted({unit["name"] + " == " + unit["version"]
                          for unit in manifest["binary_units"] if not unit["local_or_ghc"]})
    project = source / "cabal.project.local"
    project.write_text(
        "active-repositories: source-bundle\n"
        "offline: True\n"
        "tests: False\nbenchmarks: False\n"
        "constraints: " + ",\n  ".join(constraints) + "\n"
        "package pandoc\n  flags: +embed_data_files +http\n"
        "package pandoc-cli\n  flags: +server +lua\n"
    )
    config = work / "cabal.config"
    config.write_text(
        "repository source-bundle\n  url: " + repository.as_uri().replace("file:", "file+noindex:", 1) + "\n"
        "remote-repo-cache: " + str(work / "cabal-cache") + "\n"
        "store-dir: " + str(work / "cabal-store") + "\n"
    )
    command = ["cabal", "--config-file=" + str(config), "build", "exe:pandoc", "--offline",
               "-fembed_data_files", "-fserver", "-flua", "-fhttp"]
    print("Prepared local source repository and version constraints.")
    print("Upstream release recipe: " + str(source / "macos/make_macos_release.sh"))
    if args.build:
        version = subprocess.check_output(["ghc", "--numeric-version"], text=True).strip()
        if version != "9.10.3":
            raise SystemExit("This reconstruction requires GHC 9.10.3; found " + version)
        subprocess.run(command, cwd=source, check=True)
    else:
        print("Run this script again with --build after installing GHC 9.10.3 and cabal-install 3.14.")


if __name__ == "__main__":
    main()
