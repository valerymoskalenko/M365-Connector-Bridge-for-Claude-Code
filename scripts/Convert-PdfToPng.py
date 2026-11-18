"""Render pages of a PDF to PNG files, so Claude can read a PDF made of pictures (scans, design guides).

Usage:  py -E -P Convert-PdfToPng.py <file.pdf> <out folder> [first page] [last page] [dpi]
Default: pages 1-20, 110 dpi. Prints one PNG path per line; the page count goes to stderr.
Needs PyMuPDF:  py -m pip install pymupdf

Claude Code's Read tool reads PDF pages itself only when poppler (pdftoppm) is installed; this script
does not need it.
"""
import os
import sys

import pymupdf  # PyMuPDF (the older name "fitz" is deprecated)


def main() -> int:
    if len(sys.argv) < 3:
        print(__doc__, file=sys.stderr)
        return 2
    src, dst = sys.argv[1], sys.argv[2]
    first = int(sys.argv[3]) if len(sys.argv) > 3 else 1
    last = int(sys.argv[4]) if len(sys.argv) > 4 else first + 19
    dpi = int(sys.argv[5]) if len(sys.argv) > 5 else 110
    os.makedirs(dst, exist_ok=True)
    with pymupdf.open(src) as doc:
        n = doc.page_count
        last = min(last, n)
        for i in range(max(first, 1) - 1, last):
            out = os.path.join(dst, f"page-{i + 1:03}.png")
            doc[i].get_pixmap(dpi=dpi).save(out)
            print(out)
        print(f"pages {first}-{last} of {n}", file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main())
