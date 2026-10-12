#!/usr/bin/env python3
"""Collect release notices from the actual macOS Go package dependency graph."""

import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import sys


ROOT = Path(__file__).resolve().parents[2]
OUTPUT = ROOT / "macos" / "Dependencies"
LICENSE_NAME = re.compile(r"^(?:licen[sc]e|copying|copyright|notice|patents)(?:[._-].*)?$", re.I)
TARGET = {"GOOS": "darwin", "GOARCH": "arm64", "CGO_ENABLED": "1"}


def go_output(*arguments):
    environment = os.environ.copy()
    environment.update(TARGET)
    return subprocess.check_output(["go", *arguments], cwd=ROOT, env=environment, text=True)


def decode_stream(text):
    decoder = json.JSONDecoder()
    while text.strip():
        text = text.lstrip()
        item, end = decoder.raw_decode(text)
        yield item
        text = text[end:]


def relevant_licenses(root, package_directories):
    """Include package-local licenses and inherited ones, without testdata walks."""
    directories = {root}
    for package_directory in package_directories:
        package_directory.relative_to(root)  # Reject unexpected module locations.
        current = package_directory
        while current != root:
            directories.add(current)
            current = current.parent
    return sorted(
        {
            item
            for directory in directories
            for item in directory.iterdir()
            if item.is_file() and LICENSE_NAME.fullmatch(item.name)
        },
        key=lambda item: item.relative_to(root).as_posix(),
    )


def build_outputs():
    packages = list(decode_stream(go_output("list", "-mod=readonly", "-deps", "-tags", "fbmac", "-json", ".")))
    modules = {}
    standard_directories = set()
    for package in packages:
        if package.get("Standard"):
            standard_directories.add(Path(package["Dir"]))
        module = package.get("Module")
        if not module or module.get("Main"):
            continue
        source = module.get("Replace", module)
        if not source.get("Version"):
            raise ValueError(f"Unversioned module replacement cannot produce release notices: {module['Path']}")
        entry = modules.setdefault(
            module["Path"],
            {"source": source, "version": module["Version"], "directories": set(), "packages": set()},
        )
        entry["directories"].add(Path(package["Dir"]))
        entry["packages"].add(package["ImportPath"])

    environment = json.loads(go_output("env", "-json", "GOROOT", "GOVERSION"))
    go_root = Path(environment["GOROOT"])
    records = []
    sections = []

    def add_component(name, version, root, license_files, **metadata):
        if not license_files:
            raise ValueError(f"No applicable license files found for {name}@{version}")
        documents = []
        for path in license_files:
            relative = path.relative_to(root).as_posix()
            data = path.read_bytes()
            documents.append({"path": relative, "sha256": hashlib.sha256(data).hexdigest()})
            sections.append(
                "=" * 78
                + f"\n{name} {version}\nUpstream file: {relative}\n"
                + "=" * 78
                + "\n\n"
                + data.decode("utf-8")
                + "\n"
            )
        records.append({"name": name, "version": version, **metadata, "notices": documents})

    add_component(
        "Go toolchain and standard library",
        environment["GOVERSION"],
        go_root,
        relevant_licenses(go_root, standard_directories),
        source="https://go.dev/",
    )
    for module_path, entry in sorted(modules.items()):
        source = entry["source"]
        module_root = Path(source["Dir"])
        add_component(
            module_path,
            entry["version"],
            module_root,
            relevant_licenses(module_root, entry["directories"]),
            sourceModule=source["Path"],
            sourceVersion=source["Version"],
            packages=sorted(entry["packages"]),
        )

    mathjax_root = ROOT / "assets" / "mathjax"
    mathjax_entry = mathjax_root / "tex-mml-chtml.js"
    javascript = mathjax_entry.read_text(encoding="utf-8")
    match = re.search(r'\bversion\s*[:=]\s*["\'](3\.[0-9]+\.[0-9]+)["\']', javascript, re.I)
    if not match:
        raise ValueError("Could not determine the bundled MathJax 3 version; review its notice metadata.")
    add_component(
        "MathJax (embedded JavaScript and fonts)",
        match.group(1),
        mathjax_root,
        relevant_licenses(mathjax_root, [mathjax_root]),
        source="https://github.com/mathjax/MathJax",
        asset="assets/mathjax/tex-mml-chtml.js",
        assetSHA256=hashlib.sha256(mathjax_entry.read_bytes()).hexdigest(),
    )

    manifest = {
        "generator": "macos/Scripts/prepare-go-notices.py",
        "target": {**TARGET, "buildTags": ["fbmac"]},
        "packageCount": len(packages),
        "moduleCount": len(modules),
        "selection": (
            "Production go list -deps graph, without tests. License/notice files in each compiled "
            "package directory and its ancestors through the module root are retained. "
            "Upstream aggregate notices remain intact, including any conditional or test-related "
            "attribution they contain; that does not imply those additional components are linked."
        ),
        "components": records,
    }
    preface = (
        "fb macOS — Go engine and embedded asset notices\n\n"
        "Generated by macos/Scripts/prepare-go-notices.py from the darwin/arm64,\n"
        "CGO_ENABLED=1, fbmac production package dependency graph (without tests).\n"
        f"Go version: {environment['GOVERSION']}; {len(packages)} packages; {len(modules)} dependency modules.\n\n"
        "The following upstream license and notice files are reproduced in full.\n"
        "Nested package notices and upstream aggregate third-party notices are\n"
        "preserved. Such documents can describe optional architectures, tooling,\n"
        "or test-only material; retaining those notices does not assert that all\n"
        "such material is present in this app. See ThirdParty-Go.json for the\n"
        "actual module/package inventory and hashes of every included notice.\n\n"
        "The bundled Pandoc executable has separate notices and source materials\n"
        "described in NOTICE.md and pandoc.json in this same directory.\n\n"
    )
    return {
        "fb-LICENSE.txt": (ROOT / "LICENSE").read_bytes(),
        "ThirdParty-Go.txt": (preface + "\n".join(sections)).encode("utf-8"),
        "ThirdParty-Go.json": (json.dumps(manifest, indent=2, ensure_ascii=False) + "\n").encode("utf-8"),
    }, len(modules), sum(len(record["notices"]) for record in records)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--check", action="store_true", help="fail if committed notice assets differ; do not write")
    args = parser.parse_args()
    outputs, modules, notices = build_outputs()
    stale = []
    for filename, expected in outputs.items():
        path = OUTPUT / filename
        if path.exists() and path.read_bytes() == expected:
            continue
        if args.check:
            stale.append(filename)
        else:
            OUTPUT.mkdir(parents=True, exist_ok=True)
            path.write_bytes(expected)
    if stale:
        print("Go/asset notices are stale: " + ", ".join(stale), file=sys.stderr)
        print("Run python3 macos/Scripts/prepare-go-notices.py and review/commit the generated notices.", file=sys.stderr)
        return 1
    print(f"{'Verified' if args.check else 'Prepared'} {notices} upstream notice files for {modules} Go modules, Go itself, and MathJax.")
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (OSError, ValueError, subprocess.CalledProcessError) as error:
        print(f"Cannot prepare Go/asset notices: {error}", file=sys.stderr)
        sys.exit(1)
