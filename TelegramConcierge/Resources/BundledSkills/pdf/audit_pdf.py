#!/usr/bin/env python3
"""Audit a PDF programmatically before (not instead of) visual QA.

Emits a JSON report from Poppler's pdfinfo/pdftotext:
- page count and page size(s)
- per-page extracted-text character counts
- pages flagged near-empty (accidental blanks; covers, dividers, and
  references pages are legitimately sparse — judge the flags)

With --source input.html it also runs a text-completeness check: every
chunk of consecutive words from the HTML's visible text must appear in
the PDF's extracted text. Missing chunks usually mean content was
silently clipped (overflow:hidden on fixed-size pages) or dropped by a
layout bug — failures that a low-DPI thumbnail can hide.

Usage:
  python3 audit_pdf.py output.pdf
  python3 audit_pdf.py output.pdf --source input.html
  python3 audit_pdf.py output.pdf --near-empty-chars 80 --chunk-words 10
"""

from __future__ import annotations

import argparse
import json
import re
import shutil
import subprocess
import sys
import unicodedata
from html.parser import HTMLParser
from pathlib import Path
from typing import List


def run(cmd: List[str]) -> subprocess.CompletedProcess:
    return subprocess.run(cmd, capture_output=True, text=True)


def pdf_info(pdf: Path) -> dict:
    result = run(["pdfinfo", str(pdf)])
    if result.returncode != 0:
        print(f"error: pdfinfo failed: {result.stderr.strip()}", file=sys.stderr)
        raise SystemExit(1)
    info: dict = {}
    for line in result.stdout.splitlines():
        if ":" not in line:
            continue
        key, value = line.split(":", 1)
        info[key.strip()] = value.strip()
    return info


def page_text(pdf: Path, page: int) -> str:
    result = run(["pdftotext", "-f", str(page), "-l", str(page), str(pdf), "-"])
    return result.stdout if result.returncode == 0 else ""


def normalize(text: str) -> str:
    # Fold ligatures/accents pdftotext may emit differently than the source,
    # then keep only lowercase alphanumerics and single spaces.
    text = unicodedata.normalize("NFKD", text)
    text = "".join(c for c in text if not unicodedata.combining(c))
    text = re.sub(r"[^a-z0-9]+", " ", text.lower())
    return re.sub(r"\s+", " ", text).strip()


class VisibleTextExtractor(HTMLParser):
    SKIP = {"script", "style", "head", "title", "noscript", "template"}

    def __init__(self) -> None:
        super().__init__()
        self.parts: List[str] = []
        self._skip_depth = 0

    def handle_starttag(self, tag, attrs):
        if tag in self.SKIP:
            self._skip_depth += 1

    def handle_endtag(self, tag):
        if tag in self.SKIP and self._skip_depth > 0:
            self._skip_depth -= 1

    def handle_data(self, data):
        if self._skip_depth == 0:
            self.parts.append(data)


def html_visible_text(path: Path) -> str:
    parser = VisibleTextExtractor()
    parser.feed(path.read_text(encoding="utf-8", errors="replace"))
    return " ".join(parser.parts)


def completeness_check(pdf: Path, source: Path, page_count: int, chunk_words: int) -> dict:
    pdf_text = normalize(" ".join(page_text(pdf, p) for p in range(1, page_count + 1)))
    words = normalize(html_visible_text(source)).split()
    if not words:
        return {"error": "no visible text extracted from the HTML source"}

    chunks = [words[i:i + chunk_words] for i in range(0, len(words), chunk_words)]
    missing = []
    for index, chunk in enumerate(chunks):
        if " ".join(chunk) not in pdf_text:
            missing.append({
                "chunk_index": index,
                "approx_position": f"{index * chunk_words}/{len(words)} words in",
                "text": " ".join(chunk),
            })

    coverage = 1 - len(missing) / len(chunks)
    return {
        "source": str(source),
        "chunk_words": chunk_words,
        "chunks_total": len(chunks),
        "chunks_missing": len(missing),
        "coverage": round(coverage, 4),
        "missing": missing[:20],
        "missing_truncated": len(missing) > 20,
        "note": "Missing chunks = source text absent from the PDF (clipped, overflowed, or dropped). "
                "Isolated misses can be hyphenation/word-break artifacts — verify visually; "
                "clusters of consecutive misses are almost always real clipping.",
    }


def main() -> int:
    parser = argparse.ArgumentParser(description="Audit a PDF: structure report + optional text-completeness check.")
    parser.add_argument("pdf", type=Path, help="PDF to audit")
    parser.add_argument("--source", type=Path, help="HTML source to check text completeness against")
    parser.add_argument("--near-empty-chars", type=int, default=120,
                        help="Flag pages with fewer extracted characters than this (default 120)")
    parser.add_argument("--chunk-words", type=int, default=8,
                        help="Words per completeness chunk (default 8)")
    args = parser.parse_args()

    pdf = args.pdf.expanduser().resolve()
    if not pdf.exists():
        print(f"error: PDF not found: {pdf}", file=sys.stderr)
        return 2
    for tool in ("pdfinfo", "pdftotext"):
        if shutil.which(tool) is None:
            print(f"error: {tool} not found — install Poppler (brew install poppler)", file=sys.stderr)
            return 1

    info = pdf_info(pdf)
    page_count = int(info.get("Pages", "0"))

    pages = []
    near_empty = []
    for page in range(1, page_count + 1):
        chars = len(normalize(page_text(pdf, page)))
        pages.append({"page": page, "text_chars": chars})
        if chars < args.near_empty_chars:
            near_empty.append(page)

    report: dict = {
        "pdf": str(pdf),
        "pages": page_count,
        "page_size": info.get("Page size"),
        "pdf_version": info.get("PDF version"),
        "per_page_text_chars": pages,
        "near_empty_pages": near_empty,
        "near_empty_note": "Below threshold of "
                           f"{args.near_empty_chars} chars. Covers, section dividers, references and "
                           "image-only pages are legitimately sparse — flag, don't auto-fail.",
    }

    if args.source:
        source = args.source.expanduser().resolve()
        if not source.exists():
            report["completeness"] = {"error": f"source not found: {source}"}
        else:
            report["completeness"] = completeness_check(pdf, source, page_count, args.chunk_words)

    print(json.dumps(report, indent=2, ensure_ascii=False))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
