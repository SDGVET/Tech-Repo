#!/usr/bin/env python3
"""Turn plain scripture references in Markdown into Blue Letter Bible links.

BLB verse URLs are fully computable from book/chapter/verse, so no network
lookups are needed:

    https://www.blueletterbible.org/<translation>/<code>/<ch>/<verse>/s_<N>

where <code> is BLB's 3-letter book code and N is the book's cumulative
chapter number across all 66 books, times 1000, plus the verse. Acts 7 is the
1025th chapter of the Bible, so Acts 7:58 is s_1025058.

Usage:
    blb-link.py notes.md                 # preview a diff, change nothing
    blb-link.py -w notes.md              # rewrite the file in place
    blb-link.py -w -t esv sermon.md      # link against the ESV
    blb-link.py --ref "Acts 7:58"        # just print one URL

Existing Markdown links, wikilinks, code spans/fences, bare URLs and YAML
frontmatter are left alone, so the script is safe to re-run on a file it has
already processed.
"""

from __future__ import annotations

import argparse
import difflib
import re
import sys
from dataclasses import dataclass

BASE = "https://www.blueletterbible.org"

# (canonical name, BLB code, chapter count, extra aliases)
# Numeric-prefix variants (1/I/First ...) are generated automatically.
BOOKS_RAW = [
    ("Genesis",         "gen",  50, ["Gen", "Ge", "Gn"]),
    ("Exodus",          "exo",  40, ["Exod", "Exo", "Ex"]),
    ("Leviticus",       "lev",  27, ["Lev", "Lv"]),
    ("Numbers",         "num",  36, ["Num", "Nu", "Nm"]),
    ("Deuteronomy",     "deu",  34, ["Deut", "Deu", "Dt"]),
    ("Joshua",          "jos",  24, ["Josh", "Jos", "Jsh"]),
    ("Judges",          "jdg",  21, ["Judg", "Jdg", "Jg"]),
    ("Ruth",            "rth",   4, ["Rut", "Rth", "Ru"]),
    ("1 Samuel",        "1sa",  31, ["Sam", "Sa", "Sm"]),
    ("2 Samuel",        "2sa",  24, ["Sam", "Sa", "Sm"]),
    ("1 Kings",         "1ki",  22, ["Kings", "Kgs", "Ki", "Kin"]),
    ("2 Kings",         "2ki",  25, ["Kings", "Kgs", "Ki", "Kin"]),
    ("1 Chronicles",    "1ch",  29, ["Chronicles", "Chron", "Chr", "Ch"]),
    ("2 Chronicles",    "2ch",  36, ["Chronicles", "Chron", "Chr", "Ch"]),
    ("Ezra",            "ezr",  10, ["Ezr"]),
    ("Nehemiah",        "neh",  13, ["Neh", "Ne"]),
    ("Esther",          "est",  10, ["Esth", "Est"]),
    ("Job",             "job",  42, ["Jb"]),
    ("Psalms",          "psa", 150, ["Psalm", "Psa", "Pslm", "Ps", "Pss"]),
    ("Proverbs",        "pro",  31, ["Prov", "Pro", "Prv", "Pr"]),
    ("Ecclesiastes",    "ecc",  12, ["Eccles", "Eccl", "Ecc", "Ec", "Qoh"]),
    ("Song of Solomon", "sng",   8, ["Song of Songs", "Canticles", "Song", "SoS", "Sng"]),
    ("Isaiah",          "isa",  66, ["Isa", "Is"]),
    ("Jeremiah",        "jer",  52, ["Jer", "Je"]),
    ("Lamentations",    "lam",   5, ["Lam", "La"]),
    ("Ezekiel",         "eze",  48, ["Ezek", "Eze", "Ezk"]),
    ("Daniel",          "dan",  12, ["Dan", "Dn"]),
    ("Hosea",           "hos",  14, ["Hos", "Ho"]),
    ("Joel",            "joe",   3, ["Joe", "Jol", "Jl"]),
    ("Amos",            "amo",   9, ["Amo", "Am"]),
    ("Obadiah",         "oba",   1, ["Obad", "Oba", "Ob"]),
    ("Jonah",           "jon",   4, ["Jon", "Jnh"]),
    ("Micah",           "mic",   7, ["Mic", "Mc"]),
    ("Nahum",           "nah",   3, ["Nah", "Na"]),
    ("Habakkuk",        "hab",   3, ["Hab", "Hb"]),
    ("Zephaniah",       "zep",   3, ["Zeph", "Zep", "Zp"]),
    ("Haggai",          "hag",   2, ["Hag", "Hg"]),
    ("Zechariah",       "zec",  14, ["Zech", "Zec", "Zc"]),
    ("Malachi",         "mal",   4, ["Mal", "Ml"]),
    ("Matthew",         "mat",  28, ["Matt", "Mat", "Mt"]),
    ("Mark",            "mar",  16, ["Mrk", "Mar", "Mk"]),
    ("Luke",            "luk",  24, ["Luk", "Lk"]),
    ("John",            "jhn",  21, ["Jhn", "Jn"]),
    ("Acts",            "act",  28, ["Act", "Ac"]),
    ("Romans",          "rom",  16, ["Rom", "Ro", "Rm"]),
    ("1 Corinthians",   "1co",  16, ["Corinthians", "Cor", "Co"]),
    ("2 Corinthians",   "2co",  13, ["Corinthians", "Cor", "Co"]),
    ("Galatians",       "gal",   6, ["Gal", "Ga"]),
    ("Ephesians",       "eph",   6, ["Ephes", "Eph"]),
    ("Philippians",     "phl",   4, ["Philip", "Phil", "Php", "Phi"]),
    ("Colossians",      "col",   4, ["Col", "Co"]),
    ("1 Thessalonians", "1th",   5, ["Thessalonians", "Thess", "Thes", "Th"]),
    ("2 Thessalonians", "2th",   3, ["Thessalonians", "Thess", "Thes", "Th"]),
    ("1 Timothy",       "1ti",   6, ["Timothy", "Tim", "Ti"]),
    ("2 Timothy",       "2ti",   4, ["Timothy", "Tim", "Ti"]),
    ("Titus",           "tit",   3, ["Tit"]),
    ("Philemon",        "phm",   1, ["Philem", "Phlm", "Phm", "Pm"]),
    ("Hebrews",         "heb",  13, ["Heb"]),
    ("James",           "jas",   5, ["Jas", "Jm"]),
    ("1 Peter",         "1pe",   5, ["Peter", "Pet", "Pe", "Pt"]),
    ("2 Peter",         "2pe",   3, ["Peter", "Pet", "Pe", "Pt"]),
    ("1 John",          "1jo",   5, ["John", "Jhn", "Jn"]),
    ("2 John",          "2jo",   1, ["John", "Jhn", "Jn"]),
    ("3 John",          "3jo",   1, ["John", "Jhn", "Jn"]),
    ("Jude",            "jde",   1, ["Jde", "Jud"]),
    ("Revelation",      "rev",  22, ["Revelations", "Rev", "Rv", "Apocalypse"]),
]

NUMERAL_WORDS = {1: ["1", "I", "First", "1st"], 2: ["2", "II", "Second", "2nd"],
                 3: ["3", "III", "Third", "3rd"]}

DASH = r"[-‐‑‒–—−]"


@dataclass(frozen=True)
class Book:
    name: str
    code: str
    chapters: int
    start: int      # cumulative chapter index of this book's chapter 1, minus 1
    ordinal: int    # 0 for unnumbered books, else 1/2/3

    def chapter_index(self, chapter: int) -> int:
        return self.start + chapter


def build_books() -> tuple[list[Book], re.Pattern, dict[str, str]]:
    """Build the canon table and the alternation regex that finds book names."""
    books: list[Book] = []
    running = 0
    patterns: list[tuple[str, str]] = []  # (regex source, canonical name)

    for name, code, chapters, aliases in BOOKS_RAW:
        ordinal = int(name[0]) if name[0].isdigit() else 0
        book = Book(name, code, chapters, running, ordinal)
        books.append(book)
        running += chapters

        stem = name.split(" ", 1)[1] if ordinal else name
        stems = [stem] + [a for a in aliases if not a[0].isdigit()]
        # Longest first so "Corinthians" wins over "Cor" at the same position.
        stems = sorted(set(stems), key=len, reverse=True)
        stem_alt = "|".join(re.escape(s) for s in stems)

        if ordinal:
            num_alt = "|".join(re.escape(n) for n in NUMERAL_WORDS[ordinal])
            src = rf"(?:{num_alt})\s*\.?\s*(?:{stem_alt})\b\.?"
        else:
            src = rf"(?:{stem_alt})\b\.?"
        patterns.append((src, name))

    # Numbered books must be tried before unnumbered ones sharing a stem
    # ("1 John" before "John"), and longer sources before shorter.
    patterns.sort(key=lambda p: (0 if p[1][0].isdigit() else 1, -len(p[0])))
    alt = "|".join(f"(?P<b{i}>{src})" for i, (src, _) in enumerate(patterns))
    group_to_name = {f"b{i}": nm for i, (_, nm) in enumerate(patterns)}

    regex = re.compile(rf"(?<![A-Za-z0-9])(?:{alt})")
    return books, regex, group_to_name


BOOKS, BOOK_RE, GROUP_TO_NAME = build_books()
BY_NAME = {b.name: b for b in BOOKS}
assert sum(b.chapters for b in BOOKS) == 1189, "canon chapter count is wrong"
assert BY_NAME["Acts"].chapter_index(7) == 1025
assert BY_NAME["Romans"].chapter_index(1) == 1047
assert BY_NAME["1 Corinthians"].chapter_index(1) == 1063
assert BY_NAME["Philippians"].chapter_index(3) == 1106

# Regions whose contents must never be rewritten. Order matters: fenced code
# first, then links, so a URL inside a link is consumed once.
PROTECTED_RE = re.compile(
    r"""
      ^---\n.*?\n---\n            # YAML frontmatter (only at file start)
    | ```.*?```                   # fenced code
    | `[^`\n]+`                   # inline code
    | \[\[[^\]]*\]\]              # wikilink
    | \[[^\]\n]*\]\([^)\s]+\)     # existing markdown link
    | <https?://[^>\s]+>          # autolink
    | https?://\S+                # bare URL
    """,
    re.DOTALL | re.VERBOSE,
)

NUM = r"\d{1,3}"
# These are all used with Pattern.match(text, pos), which anchors at pos on its
# own -- a leading ^ would wrongly anchor to the start of the whole string.
# A verse spec: 3:16, 3:16-18, 3:16-4:2, 3:16, 18, 20
# ":" may be padded, but "." may not -- otherwise "as in Acts 15. 2 Timothy
# says..." would parse as Acts 15:2.
SEP = r"(?:\s*:\s*|\.)"
VERSE_SPEC_RE = re.compile(
    rf"""(?P<ch>{NUM}){SEP}(?P<v>{NUM})
         (?:\s*{DASH}\s*(?:(?P<ech>{NUM}){SEP})?(?P<ev>{NUM}))?
         (?P<extra>(?:\s*,\s*{NUM}(?:\s*{DASH}\s*{NUM})?)*)""",
    re.VERBOSE,
)
# A trailing "." is only a separator when a digit follows it, so a reference
# ending a sentence ("...as Acts 15.") still resolves as a whole chapter.
NOT_SPEC = r"(?![:\d])(?!\.\d)"
CHAPTER_RANGE_RE = re.compile(rf"(?P<ch>{NUM})\s*{DASH}\s*(?P<ech>{NUM}){NOT_SPEC}")
CHAPTER_RE = re.compile(rf"(?P<ch>{NUM}){NOT_SPEC}")
VERSE_WORD_RE = re.compile(r"(?:vv?\.?|verses?)\s*", re.IGNORECASE)
# A bare "6:11" continuing the previously named book, as in "Galatians 4:15 and 6:11".
CONTINUATION_RE = re.compile(rf"(?:\s*(?:and|cf\.?|see|;|,)\s*)+(?={NUM}\s*[:.]\s*{NUM})")
OPEN_PAREN_RE = re.compile(r"[ \t ]*\(\s*")
CLOSE_PAREN_RE = re.compile(r"\s*\)")
# Space between the book name and its numbers. Horizontal only, so a book name
# ending one paragraph can't bind to a number starting the next.
GAP_RE = re.compile(r"[ \t ]{0,3}")


@dataclass
class Ref:
    """A parsed reference: where it sits in the text and where it points."""
    start: int
    end: int
    book: Book
    chapter: int
    verse: int | None
    end_verse: int | None


def parse_spec(text: str, pos: int, book: Book) -> tuple[int, int, int | None, int | None] | None:
    """Parse the chapter/verse part at `pos`. Returns (end, ch, verse, end_verse)."""
    m = VERSE_SPEC_RE.match(text, pos)
    if m:
        ch, v = int(m["ch"]), int(m["v"])
        ev = int(m["ev"]) if m["ev"] and not m["ech"] else None
        if book.chapters == 1 and ch != 1:
            return None
        if ch > book.chapters:
            return None
        return m.end(), ch, v, ev

    if book.chapters == 1:
        # Philemon 19 / Jude 3 -- a bare number is a verse, not a chapter.
        m = CHAPTER_RANGE_RE.match(text, pos)
        if m:
            return m.end(), 1, int(m["ch"]), int(m["ech"])
        m = CHAPTER_RE.match(text, pos)
        if m:
            return m.end(), 1, int(m["ch"]), None
        return None

    m = CHAPTER_RANGE_RE.match(text, pos)
    if m and int(m["ch"]) <= book.chapters and int(m["ech"]) <= book.chapters:
        return m.end(), int(m["ch"]), None, None

    m = CHAPTER_RE.match(text, pos)
    if m and int(m["ch"]) <= book.chapters:
        return m.end(), int(m["ch"]), None, None

    return None


def find_refs(text: str, continuations: bool = True) -> list[Ref]:
    """Locate every linkable reference in a span of plain prose."""
    refs: list[Ref] = []
    pos = 0
    last_book: Book | None = None

    while pos < len(text):
        m = BOOK_RE.search(text, pos)
        if not m:
            break

        # Between the last ref and this book name, look for a bare "6:11"
        # continuing the book named just before it.
        if continuations and last_book is not None and refs:
            gap = text[refs[-1].end:m.start()]
            cont = try_continuation(text, refs[-1].end, m.start(), last_book)
            if cont:
                refs.append(cont)

        name = next(GROUP_TO_NAME[g] for g, val in m.groupdict().items() if val)
        book = BY_NAME[name]
        after = m.end()

        # Allow "1 Corinthians (1:1)" and "Philemon (v. 1)".
        paren = OPEN_PAREN_RE.match(text, after)
        inner = paren.end() if paren else GAP_RE.match(text, after).end()
        vm = VERSE_WORD_RE.match(text, inner)
        if vm:
            inner = vm.end()

        parsed = parse_spec(text, inner, book)
        if not parsed:
            pos = m.end()
            last_book = book
            continue

        end, ch, v, ev = parsed
        if paren:
            close = CLOSE_PAREN_RE.match(text, end)
            if not close:
                # "(Acts 13-14)" -- the paren belongs to the sentence, not the ref.
                parsed = parse_spec(text, GAP_RE.match(text, after).end(), book)
                if not parsed:
                    pos = m.end()
                    last_book = book
                    continue
                end, ch, v, ev = parsed
            else:
                end = close.end()

        refs.append(Ref(m.start(), end, book, ch, v, ev))
        last_book = book
        pos = end

    # A trailing continuation after the final book-anchored reference.
    if continuations and last_book is not None and refs:
        cont = try_continuation(text, refs[-1].end, len(text), last_book)
        if cont:
            refs.append(cont)

    refs.sort(key=lambda r: r.start)
    return refs


def try_continuation(text: str, lo: int, hi: int, book: Book) -> Ref | None:
    """Match a bare 'C:V' immediately joined to the previous ref by and/,/;/cf."""
    m = CONTINUATION_RE.match(text, lo)
    if not m or m.end() > hi:
        return None
    parsed = parse_spec(text, m.end(), book)
    if not parsed:
        return None
    end, ch, v, ev = parsed
    if end > hi:
        return None
    return Ref(m.end(), end, book, ch, v, ev)


def build_url(ref: Ref, translation: str) -> str:
    ch = ref.chapter
    idx = ref.book.chapter_index(ch)
    if ref.verse is None:
        return f"{BASE}/{translation}/{ref.book.code}/{ch}/1/s_{idx * 1000 + 1}"
    seg = f"{ref.verse}-{ref.end_verse}" if ref.end_verse else str(ref.verse)
    return f"{BASE}/{translation}/{ref.book.code}/{ch}/{seg}/s_{idx * 1000 + ref.verse}"


def split_spans(text: str) -> list[tuple[str, bool]]:
    """Split into (chunk, is_protected) pieces."""
    spans: list[tuple[str, bool]] = []
    pos = 0
    for m in PROTECTED_RE.finditer(text):
        if m.start() > pos:
            spans.append((text[pos:m.start()], False))
        spans.append((m.group(0), True))
        pos = m.end()
    if pos < len(text):
        spans.append((text[pos:], False))
    return spans


def linkify(text: str, translation: str, continuations: bool = True) -> tuple[str, list[Ref]]:
    out: list[str] = []
    found: list[Ref] = []
    for chunk, protected in split_spans(text):
        if protected:
            out.append(chunk)
            continue
        refs = find_refs(chunk, continuations)
        cursor = 0
        for ref in refs:
            label = chunk[ref.start:ref.end].rstrip()
            trailing = chunk[ref.start:ref.end][len(label):]
            out.append(chunk[cursor:ref.start])
            out.append(f"[{label}]({build_url(ref, translation)}){trailing}")
            cursor = ref.end
            found.append(ref)
        out.append(chunk[cursor:])
    return "".join(out), found


def parse_single(ref_text: str, translation: str) -> str | None:
    refs = find_refs(ref_text.strip(), continuations=False)
    if not refs:
        return None
    return build_url(refs[0], translation)


def main() -> int:
    ap = argparse.ArgumentParser(
        description="Turn scripture references in Markdown into Blue Letter Bible links.")
    ap.add_argument("files", nargs="*", help="Markdown files to process")
    ap.add_argument("-t", "--translation", default="kjv",
                    help="BLB translation slug (kjv, esv, nasb95, nkjv, ...); default kjv")
    ap.add_argument("-w", "--write", action="store_true",
                    help="rewrite files in place (default is a preview diff)")
    ap.add_argument("--no-continuations", action="store_true",
                    help="don't link bare refs like the '6:11' in 'Galatians 4:15 and 6:11'")
    ap.add_argument("--ref", help="print the URL for a single reference and exit")
    args = ap.parse_args()

    if args.ref:
        url = parse_single(args.ref, args.translation)
        if not url:
            print(f"could not parse reference: {args.ref}", file=sys.stderr)
            return 1
        print(url)
        return 0

    if not args.files:
        ap.error("give at least one file, or use --ref")

    for path in args.files:
        with open(path, encoding="utf-8") as fh:
            original = fh.read()
        updated, refs = linkify(original, args.translation, not args.no_continuations)

        if updated == original:
            print(f"{path}: no changes")
            continue

        if args.write:
            with open(path, "w", encoding="utf-8") as fh:
                fh.write(updated)
            print(f"{path}: linked {len(refs)} references ({args.translation})")
        else:
            diff = difflib.unified_diff(
                original.splitlines(keepends=True), updated.splitlines(keepends=True),
                fromfile=path, tofile=f"{path} (linked)")
            sys.stdout.writelines(diff)
            print(f"\n{path}: would link {len(refs)} references "
                  f"({args.translation}). Re-run with -w to apply.", file=sys.stderr)

    return 0


if __name__ == "__main__":
    sys.exit(main())
