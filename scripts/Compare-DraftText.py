"""Was a draft edited by hand? Compare the draft's text with the HTML you generated it from.

Usage:  py -I Compare-DraftText.py <draft.txt> <source.html>      (python3 on macOS / Linux)

  draft.txt    the draft (or the sent message) as plain text: read it with Invoke-M365Graph.ps1 without -Html,
               cut it at the signature, save it as UTF-8
  source.html  the HTML fragment the draft was made from

Both are split into sentences and compared. Prints "DIFF LINES: <n>" and the differing sentences:
"-" = only in source.html, "+" = only in the draft. "DIFF LINES: 0" = the draft was not edited.
"""
import difflib
import html
import re
import sys

sys.stdout.reconfigure(encoding="utf-8")   # a non-ASCII character would crash a cp1252 console


def sentences(text):
    text = re.sub(r"[\s\*]+", " ", text)
    return [s.strip() for s in re.split(r"(?<=[.:;?!])\s+", text) if s.strip()]


def main():
    if len(sys.argv) != 3:
        sys.exit(__doc__)
    draft = open(sys.argv[1], encoding="utf-8-sig").read()
    draft = re.sub(r"\[cid:[^\]]*\]", " ", draft)   # inline images appear as [cid:<name>] in the plain-text body
    src = open(sys.argv[2], encoding="utf-8-sig").read()
    src = re.sub(r"<(br|/p|/div|/li|/h\d|/tr|/td|/th)[^>]*>", "\n", src, flags=re.I)
    src = html.unescape(re.sub(r"<[^>]+>", "", src))
    diff = [line for line in difflib.unified_diff(sentences(src), sentences(draft), "source", "draft", lineterm="", n=0)
            if not line.startswith(("---", "+++", "@@"))]
    print("DIFF LINES:", len(diff))
    for line in diff:
        print(line[:260])


if __name__ == "__main__":
    main()
