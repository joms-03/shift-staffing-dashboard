#!/usr/bin/env python3
"""Remove individual Pro records from the GitHub Pages dashboard artifact."""

from pathlib import Path
import re


PUBLIC_ARRAYS = ("REVIEW_ROWS", "OUTREACH_ROWS")
PHONE_PATTERN = re.compile(r"\+1\d{10}")


def main() -> None:
    path = Path("index.html")
    html = path.read_text(encoding="utf-8")

    for key in PUBLIC_ARRAYS:
        pattern = re.compile(rf"(const {key} = )\[.*?\](;)", re.DOTALL)
        html, count = pattern.subn(r"\1[]\2", html, count=1)
        if count != 1:
            raise SystemExit(f"Could not find exactly one {key} array in {path}")

    if PHONE_PATTERN.search(html):
        raise SystemExit("Refusing to write: phone-like Pro data remains in index.html")

    path.write_text(html, encoding="utf-8")
    print("Sanitized index.html: individual Pro rows removed from public build")


if __name__ == "__main__":
    main()
