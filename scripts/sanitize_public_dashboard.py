#!/usr/bin/env python3
"""Enforce public-data boundaries for the GitHub Pages dashboards."""

from pathlib import Path
import re


PUBLIC_ARRAYS = ("REVIEW_ROWS", "OUTREACH_ROWS")
PHONE_PATTERN = re.compile(r"\+1\d{10}")


def main() -> None:
    bf5_path = Path("index.html")
    html = bf5_path.read_text(encoding="utf-8")

    for key in PUBLIC_ARRAYS:
        pattern = re.compile(rf"(const {key} = )\[.*?\](;)", re.DOTALL)
        html, count = pattern.subn(r"\1[]\2", html, count=1)
        if count != 1:
            raise SystemExit(f"Could not find exactly one {key} array in {bf5_path}")

    if PHONE_PATTERN.search(html):
        raise SystemExit("Refusing to write: phone-like Pro data remains in index.html")

    bf5_path.write_text(html, encoding="utf-8")

    vip_path = Path("vip-outreach.html")
    vip_html = vip_path.read_text(encoding="utf-8")
    if PHONE_PATTERN.search(vip_html):
        raise SystemExit("Refusing to publish: phone-like Pro data remains in vip-outreach.html")

    print("Validated public dashboards: BF5 individual rows removed and no Pro phone numbers found")


if __name__ == "__main__":
    main()
