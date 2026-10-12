#!/usr/bin/env python3
"""Generate disposable, nonprivate documents for the WebKit integration check."""
import base64
import json
from pathlib import Path
import sqlite3
import sys
import wave
import zipfile

root = Path(sys.argv[1])
root.mkdir(parents=True, exist_ok=True)
(root / "nested").mkdir(exist_ok=True)
(root / "sample.md").write_text(
    "# Embedded engine\n\nOriginal file, rendered with bundled Pandoc.\n\n"
    "[Relative link](nested/next.md)\n\n![Pixel](pixel.png)\n\n"
    "$$x^2 + y^2 = z^2$$\n"
)
(root / "nested/next.md").write_text("# Relative navigation works\n")
(root / "spaced & café #1.md").write_text("# Encoded filename works\n")
(root / "100%.md").write_text("# Percent filename works\n")
(root / "example.go").write_text("package main\n\nfunc main() {}\n")
(root / "sample.csv").write_text("name,amount\nalpha,10\nbeta,20\n")
(root / "pixel.png").write_bytes(base64.b64decode(
    "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+j53sAAAAASUVORK5CYII="
))
(root / "raw.html").write_text(
    "<!doctype html><title>Sandbox check</title><p>Raw HTML still displays</p>"
    "<script>window.fbUnsafeScriptExecuted = true</script>"
)
(root / "payload.txt~").write_text(
    "<!doctype html><p>Backup content stays plain text</p>"
    "<script>window.fbUnsafeScriptExecuted = true</script>"
)
db = sqlite3.connect(root / "sample.db")
db.execute("create table if not exists records (name text, amount integer)")
db.execute("delete from records")
db.executemany("insert into records values (?, ?)", [("alpha", 10), ("beta", 20)])
db.commit()
db.close()
with zipfile.ZipFile(root / "sample.zip", "w") as archive:
    archive.writestr("inside.md", "# Archive rendering works\n")
with wave.open(str(root / "sample.wav"), "wb") as audio:
    audio.setnchannels(1)
    audio.setsampwidth(2)
    audio.setframerate(8000)
    audio.writeframes(b"\0" * 16000)

# A minimal valid PDF, without depending on a PDF generator installation.
objects = [
    b"<< /Type /Catalog /Pages 2 0 R >>",
    b"<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
    b"<< /Type /Page /Parent 2 0 R /MediaBox [0 0 300 300] /Resources << /Font << /F1 4 0 R >> >> /Contents 5 0 R >>",
    b"<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>",
]
content = b"BT /F1 20 Tf 30 250 Td (Embedded PDF) Tj ET"
objects.append(b"<< /Length " + str(len(content)).encode() + b" >>\nstream\n" + content + b"\nendstream")
pdf = bytearray(b"%PDF-1.4\n")
offsets = [0]
for i, obj in enumerate(objects, 1):
    offsets.append(len(pdf))
    pdf.extend(f"{i} 0 obj\n".encode() + obj + b"\nendobj\n")
xref = len(pdf)
pdf.extend(f"xref\n0 {len(offsets)}\n0000000000 65535 f \n".encode())
for offset in offsets[1:]:
    pdf.extend(f"{offset:010d} 00000 n \n".encode())
pdf.extend(f"trailer\n<< /Size {len(offsets)} /Root 1 0 R >>\nstartxref\n{xref}\n%%EOF\n".encode())
(root / "sample.pdf").write_bytes(pdf)

print(json.dumps({"fixtures": str(root), "files": len(list(root.rglob("*")))}))
