#!/usr/bin/env python3
"""Generate the integration test fixtures: small EPUBs and StarDict dictionaries.

Everything is synthetic or public domain (the CJK book quotes the Analects, the
English book is generated prose), and generation is deterministic, so the
expected values in the scenarios can be hard-coded.

Usage: make_fixtures.py OUTPUT_DIR

Layout:
    OUTPUT_DIR/books/en.epub          English, 6 chapters, NCX + nav TOC
    OUTPUT_DIR/books/zh.epub          Chinese (zh), 5 chapters, CJK TOC
    OUTPUT_DIR/books/ja.epub          Japanese (ja), 1 chapter
    OUTPUT_DIR/dict/it-alpha/         plain text dictionary (first in order)
    OUTPUT_DIR/dict/it-beta/          plain text dictionary
    OUTPUT_DIR/dict/it-gamma/         HTML dictionary with a big res/ directory
    OUTPUT_DIR/dict/it-hanzi/         Chinese dictionary
    OUTPUT_DIR/manifest.json          what was generated (word lists, chapter titles…)
"""

import json
import os
import struct
import sys
import zipfile

# Books. {{{

EN_TITLE = "Integration Test Book"
EN_CHAPTERS = [
    "Chapter One: The Harbor",
    "Chapter Two: The Lantern",
    "Chapter Three: The Quiet Road",
    "Chapter Four: The Orchard",
    "Chapter Five: The Storm",
    "Chapter Six: The Return",
]
EN_WORDS = [
    "harbor", "lantern", "quiet", "orchard", "storm", "return", "keeper",
    "evening", "window", "river", "bridge", "garden", "letter", "morning",
]

ZH_TITLE = "論語選讀"
ZH_CHAPTERS = ["學而第一", "為政第二", "八佾第三", "里仁第四", "公冶長第五"]
ZH_LINES = [
    "子曰：學而時習之，不亦說乎？有朋自遠方來，不亦樂乎？人不知而不慍，不亦君子乎？",
    "有子曰：其為人也孝弟，而好犯上者，鮮矣；不好犯上，而好作亂者，未之有也。",
    "曾子曰：吾日三省吾身：為人謀而不忠乎？與朋友交而不信乎？傳不習乎？",
    "子曰：為政以德，譬如北辰，居其所而眾星共之。",
    "子曰：溫故而知新，可以為師矣。",
    "子曰：學而不思則罔，思而不學則殆。",
    "子曰：里仁為美。擇不處仁，焉得知？",
    "子曰：朝聞道，夕死可矣。",
]

JA_TITLE = "日本語テスト"
JA_LINES = [
    "吾輩は猫である。名前はまだ無い。どこで生れたかとんと見当がつかぬ。",
    "何でも薄暗いじめじめした所でニャーニャー泣いていた事だけは記憶している。",
]


def en_paragraphs(chapter_no, count=28):
    """Deterministic English prose."""
    subjects = ["The keeper", "A traveller", "The old woman", "Her brother", "The child", "Nobody"]
    verbs = ["watched", "carried", "remembered", "crossed", "described", "waited by"]
    objects = ["the harbor", "a lantern", "the quiet road", "the orchard", "the river", "the bridge",
               "a letter", "the garden", "the window"]
    times = ["in the evening", "before the storm", "every morning", "on the day of the return",
             "long after midnight", "while the bells rang"]
    paras = []
    for i in range(count):
        sentences = []
        for j in range(5):
            k = chapter_no * 131 + i * 17 + j * 7
            sentences.append("%s %s %s %s." % (
                subjects[k % len(subjects)], verbs[(k // 3) % len(verbs)],
                objects[(k // 5) % len(objects)], times[(k // 7) % len(times)]))
        paras.append(" ".join(sentences))
    return paras


def zh_paragraphs(chapter_no, count=60):
    return [ZH_LINES[(chapter_no * 3 + i) % len(ZH_LINES)] for i in range(count)]


def xhtml(lang, title, paragraphs):
    body = "\n".join("<p>%s</p>" % p for p in paragraphs)
    return (
        '<?xml version="1.0" encoding="utf-8"?>\n'
        '<!DOCTYPE html>\n'
        '<html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops"'
        ' lang="%s" xml:lang="%s">\n'
        '<head><title>%s</title></head>\n'
        '<body><h1>%s</h1>\n%s\n</body></html>\n' % (lang, lang, title, title, body))


def write_epub(path, ident, lang, title, chapters):
    """chapters: list of (title, paragraphs)."""
    manifest, spine, nav_points, nav_items = [], [], [], []
    files = {}
    for n, (ctitle, paras) in enumerate(chapters, 1):
        name = "chap%02d.xhtml" % n
        files["OEBPS/" + name] = xhtml(lang, ctitle, paras)
        manifest.append('<item id="c%d" href="%s" media-type="application/xhtml+xml"/>' % (n, name))
        spine.append('<itemref idref="c%d"/>' % n)
        nav_points.append(
            '<navPoint id="n%d" playOrder="%d"><navLabel><text>%s</text></navLabel>'
            '<content src="%s"/></navPoint>' % (n, n, ctitle, name))
        nav_items.append('<li><a href="%s">%s</a></li>' % (name, ctitle))
    files["OEBPS/nav.xhtml"] = (
        '<?xml version="1.0" encoding="utf-8"?>\n<!DOCTYPE html>\n'
        '<html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops">'
        '<head><title>%s</title></head><body><nav epub:type="toc"><ol>%s</ol></nav></body></html>\n'
        % (title, "".join(nav_items)))
    files["OEBPS/toc.ncx"] = (
        '<?xml version="1.0" encoding="utf-8"?>\n'
        '<ncx xmlns="http://www.daisy.org/z3986/2005/ncx/" version="2005-1">'
        '<head><meta name="dtb:uid" content="%s"/></head>'
        '<docTitle><text>%s</text></docTitle><navMap>%s</navMap></ncx>\n'
        % (ident, title, "".join(nav_points)))
    files["OEBPS/content.opf"] = (
        '<?xml version="1.0" encoding="utf-8"?>\n'
        '<package xmlns="http://www.idpf.org/2007/opf" version="3.0" unique-identifier="uid">'
        '<metadata xmlns:dc="http://purl.org/dc/elements/1.1/">'
        '<dc:identifier id="uid">%s</dc:identifier><dc:title>%s</dc:title>'
        '<dc:language>%s</dc:language><dc:creator>KOReader integration tests</dc:creator>'
        '<meta property="dcterms:modified">2026-01-01T00:00:00Z</meta></metadata>'
        '<manifest><item id="nav" href="nav.xhtml" media-type="application/xhtml+xml" properties="nav"/>'
        '<item id="ncx" href="toc.ncx" media-type="application/x-dtbncx+xml"/>%s</manifest>'
        '<spine toc="ncx">%s</spine></package>\n'
        % (ident, title, lang, "".join(manifest), "".join(spine)))
    files["META-INF/container.xml"] = (
        '<?xml version="1.0"?>\n'
        '<container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">'
        '<rootfiles><rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/>'
        '</rootfiles></container>\n')
    with zipfile.ZipFile(path, "w") as z:
        # mimetype must come first, stored.
        info = zipfile.ZipInfo("mimetype", date_time=(2026, 1, 1, 0, 0, 0))
        z.writestr(info, "application/epub+zip", compress_type=zipfile.ZIP_STORED)
        for name in sorted(files):
            info = zipfile.ZipInfo(name, date_time=(2026, 1, 1, 0, 0, 0))
            z.writestr(info, files[name].encode("utf-8"), compress_type=zipfile.ZIP_DEFLATED)

# }}}

# StarDict. {{{


def stardict_key(word):
    """Sort order of StarDict .idx files (stardict_strcmp: ASCII case-insensitive, then bytes)."""
    b = word.encode("utf-8")
    return (b.lower(), b)


def write_stardict(directory, basename, bookname, entries, sametypesequence="m", lang=None):
    """entries: dict word -> definition."""
    os.makedirs(directory, exist_ok=True)
    idx = bytearray()
    data = bytearray()
    for word in sorted(entries, key=stardict_key):
        definition = entries[word].encode("utf-8")
        idx += word.encode("utf-8") + b"\0" + struct.pack(">II", len(data), len(definition))
        data += definition
    with open(os.path.join(directory, basename + ".idx"), "wb") as f:
        f.write(idx)
    with open(os.path.join(directory, basename + ".dict"), "wb") as f:
        f.write(data)
    ifo = [
        "StarDict's dict ifo file",
        "version=2.4.2",
        "bookname=%s" % bookname,
        "wordcount=%d" % len(entries),
        "idxfilesize=%d" % len(idx),
        "sametypesequence=%s" % sametypesequence,
    ]
    if lang:
        ifo.append("lang=%s" % lang)
    with open(os.path.join(directory, basename + ".ifo"), "w", encoding="utf-8") as f:
        f.write("\n".join(ifo) + "\n")


def make_dicts(out):
    dict_dir = os.path.join(out, "dict")
    alpha = {w: "alpha: definition of %s." % w for w in EN_WORDS}
    beta = {w: "beta: another meaning of %s." % w for w in EN_WORDS[:8]}
    beta["beacon"] = "beta: a signal fire (only in beta)."
    gamma = {w: "<b>%s</b> <i>gamma</i>: html definition of %s.<br/><img src=\"%s.png\"/>" % (w, w, w)
             for w in EN_WORDS[::2]}
    gamma["beacon"] = "<b>beacon</b> gamma: a light used as a signal."
    hanzi = {
        "學而": "hanzi: 篇名，論語第一篇。",
        "君子": "hanzi: 才德出眾的人。",
        "朋友": "hanzi: 彼此有交情的人。",
        "溫故而知新": "hanzi: 溫習舊的知識，從而得到新的理解。",
        "北辰": "hanzi: 北極星。",
        "學": "hanzi: 學習。",
    }
    write_stardict(os.path.join(dict_dir, "it-alpha"), "it-alpha", "IT Alpha", alpha, lang="en-en")
    write_stardict(os.path.join(dict_dir, "it-beta"), "it-beta", "IT Beta", beta, lang="en-en")
    gamma_dir = os.path.join(dict_dir, "it-gamma")
    write_stardict(gamma_dir, "it-gamma", "IT Gamma", gamma, sametypesequence="h", lang="en-en")
    # A res/ directory with many (tiny) resource files, in nested directories, as big HTML
    # dictionaries have: neither KOReader nor sdcv should walk into it on lookups.
    res = os.path.join(gamma_dir, "res")
    for i in range(40):
        sub = os.path.join(res, "img%02d" % i)
        os.makedirs(sub, exist_ok=True)
        for j in range(50):
            with open(os.path.join(sub, "r%03d.png" % j), "wb") as f:
                f.write(b"\x89PNG\r\n\x1a\n")
    # A decoy .ifo inside res/: it must never show up as a dictionary.
    write_stardict(os.path.join(res, "decoy"), "decoy", "IT Decoy In Res", {"lantern": "decoy!"})
    write_stardict(os.path.join(dict_dir, "it-hanzi"), "it-hanzi", "IT Hanzi", hanzi, lang="zh-zh")
    return {
        "alpha": sorted(alpha), "beta": sorted(beta), "gamma": sorted(gamma), "hanzi": sorted(hanzi),
        "res_files": 40 * 50,
    }

# }}}


def main():
    if len(sys.argv) != 2:
        sys.exit(__doc__)
    out = sys.argv[1]
    books = os.path.join(out, "books")
    os.makedirs(books, exist_ok=True)
    write_epub(os.path.join(books, "en.epub"), "urn:uuid:5f0e1c1e-0000-4000-8000-000000000001", "en",
               EN_TITLE, [(t, en_paragraphs(n)) for n, t in enumerate(EN_CHAPTERS)])
    write_epub(os.path.join(books, "zh.epub"), "urn:uuid:5f0e1c1e-0000-4000-8000-000000000002", "zh",
               ZH_TITLE, [(t, zh_paragraphs(n)) for n, t in enumerate(ZH_CHAPTERS)])
    write_epub(os.path.join(books, "ja.epub"), "urn:uuid:5f0e1c1e-0000-4000-8000-000000000003", "ja",
               JA_TITLE, [("第一章", JA_LINES * 6)])
    dicts = make_dicts(out)
    manifest = {
        "books": {
            "en": {"file": "books/en.epub", "title": EN_TITLE, "toc": EN_CHAPTERS},
            "zh": {"file": "books/zh.epub", "title": ZH_TITLE, "toc": ZH_CHAPTERS},
            "ja": {"file": "books/ja.epub", "title": JA_TITLE, "toc": ["第一章"]},
        },
        "dicts": dicts,
    }
    with open(os.path.join(out, "manifest.json"), "w", encoding="utf-8") as f:
        json.dump(manifest, f, ensure_ascii=False, indent=1, sort_keys=True)


if __name__ == "__main__":
    main()

# vim: foldmethod=marker foldlevel=0
