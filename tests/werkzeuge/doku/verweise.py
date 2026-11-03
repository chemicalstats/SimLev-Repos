#!/usr/bin/env python3
"""Prüft relative Verweise und Bildpfade in Markdown-Dateien der Dokumentation.

    python3 tests/werkzeuge/doku/verweise.py <datei.md> ...

Geprüft werden Links ``[text](ziel)``, Bilder ``![alt](ziel)`` und ``<img src="ziel">``.
Externe Ziele (http, https, mailto) werden übersprungen. Ein relatives Ziel muss als Datei
oder Ordner existieren; ein Anker (``datei.md#anker`` oder ``#anker``) muss einer Überschrift
der Zieldatei entsprechen (Anker wie auf GitHub: Kleinbuchstaben, Leerzeichen zu ``-``,
Satzzeichen entfernt). Codeblöcke werden nicht gelesen. Ende 1 bei einem Fehler.
"""
import os
import re
import sys

LINK = re.compile(r"!?\[[^\]]*\]\(([^)\s]+)(?:\s+\"[^\"]*\")?\)")
IMG = re.compile(r"<img[^>]*\ssrc=\"([^\"]+)\"")


def text_lines(path):
    out, fence = [], False
    for line in open(path, encoding="utf-8"):
        if re.match(r"^\s*```", line):
            fence = not fence
            continue
        if not fence:
            out.append(line)
    return out


def anchors(path):
    found, seen = set(), {}
    for line in text_lines(path):
        m = re.match(r"^#{1,6}\s+(.*?)\s*#*\s*$", line)
        if not m:
            continue
        a = m.group(1).strip().lower()
        a = re.sub(r"<[^>]+>", "", a)
        a = re.sub(r"[^\w\- ]", "", a)
        a = a.replace(" ", "-")
        n = seen.get(a, 0)
        seen[a] = n + 1
        found.add(a if n == 0 else "%s-%d" % (a, n))
    return found


def check(path):
    bad = []
    base = os.path.dirname(os.path.abspath(path))
    for no, line in enumerate(text_lines(path), 1):
        for ziel in LINK.findall(line) + IMG.findall(line):
            if re.match(r"^(https?:|mailto:)", ziel):
                continue
            datei, _, anker = ziel.partition("#")
            ziel_pfad = os.path.normpath(os.path.join(base, datei)) if datei else os.path.abspath(path)
            if not os.path.exists(ziel_pfad):
                bad.append("%s: fehlt: %s" % (path, ziel))
                continue
            if anker and ziel_pfad.endswith(".md") and anker not in anchors(ziel_pfad):
                bad.append("%s: Anker fehlt: %s" % (path, ziel))
    return bad


def main(files):
    bad = [b for f in files for b in check(f)]
    for b in bad:
        print(b)
    print("%d Dateien, %d Fehler" % (len(files), len(bad)))
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
