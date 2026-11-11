#!/usr/bin/env python3
"""Meldungsinventar (seit 1.6.5, FB-7, Entscheidung 184): alle Fehler- und Warnungstexte der drei Sprachen, die nicht
aus der Tabelle ``core/meldungen.tsv`` kommen, mit Datei, Zeile und umgebender Funktion.

Gesucht werden Aufrufe mit einem Textliteral als (erstem) Argument:

- R: ``stop(``, ``warning(``, ``stop(sprintf(``, ``warning(sprintf(``, ``stop(gettextf(`` …
- Python: ``raise <Name>(``, ``warnings.warn(``, ``_warn(``, ``_error(``, ``_stop(`` (seit 1.6.5, Paket E)
- Julia: ``error(``, ``@warn``, ``throw(<Name>(``, ``_warn(``

Aufrufe über ``chk_stop``/``chk_msg``/``chk_warn`` und die Tabellen der Kerne zählen als „aus der Tabelle“ und erscheinen
nicht. Englische Texte in den R-Nachbildungen (``python/simlev/_r/``, ``julia/src/r/``) und in den R-Hüllen der
Nachbildung bilden R nach und stehen getrennt (Spalte ``art`` = ``R-Text``); deutsche Texte ohne Tabelle haben
``art`` = ``deutsch``. Die Erkennung ist zeilenweise und ohne Zerlegung des Codes (Texte über mehrere Zeilen erscheinen
mit ihrem Anfang).

Aufruf aus der Repo-Wurzel::

    python3 tests/werkzeuge/meldungen_inventar.py [--tsv DATEI] [--nur-deutsch]

Ausgabe: Tabelle mit den Spalten sprache, datei, zeile, funktion, art, aufruf, text (Standard: Standardausgabe) und eine
Zusammenfassung je Sprache und Art auf der Fehlerausgabe. Nur Standardbibliothek.
"""
from __future__ import annotations

import argparse
import os
import re
import sys

ROOT = os.path.normpath(os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", ".."))

_STR = r'("(?:[^"\\]|\\.)*"|\'(?:[^\'\\]|\\.)*\')'
_PAT = {
    "R": [
        ("stop", re.compile(r'\b(stop|warning)\(\s*(?:sprintf\(|gettextf\(|paste0?\()?\s*' + _STR)),
    ],
    "Python": [
        ("raise", re.compile(r'\braise\s+([A-Za-z_][\w.]*)\(\s*(?:\(?\s*)?[fr]?' + _STR)),
        ("warn", re.compile(r'\b(warnings\.warn|_warn|_error)\(\s*[fr]?' + _STR)),
        ("stop", re.compile(r'(?<![\w.])(_stop)\(\s*[fr]?' + _STR)),   # _sim_base._stop u. a. (seit 1.6.5)
    ],
    "Julia": [
        ("error", re.compile(r'(?<![\w.])(error|_warn)\(\s*' + _STR)),
        ("warn", re.compile(r'(@warn)\s*\(?\s*' + _STR)),
        ("throw", re.compile(r'\bthrow\(\s*([A-Za-z_][\w.]*)\(\s*' + _STR)),
    ],
}
_FUNC = {
    "R": re.compile(r'^\s*([A-Za-z.][\w.]*)\s*<-\s*function\b'),
    "Python": re.compile(r'^\s*(?:async\s+)?def\s+(\w+)'),
    "Julia": re.compile(r'^\s*(?:function\s+([\w.!]+)|([\w.!]+)\([^=]*\)\s*(?:where\b[^=]*)?=(?!=))'),
}
_UMLAUT = re.compile(r'[äöüÄÖÜß]|\\u00e4|\\u00f6|\\u00fc|\\u00c4|\\u00d6|\\u00dc|\\u00df')
_GERMAN = re.compile(r'\b(muss|müssen|nicht|keine?n?|oder|und|ist|sind|darf|fehlt|Spalte|Wert|Werte|Zahl|wird|werden|'
                     r'ohne|unbekannt|zu|für|fuer|bei|nach|vor)\b')


def _files():
    for lang, base, ext in (("R", "r/R", ".R"), ("Python", "python/simlev", ".py"), ("Julia", "julia/src", ".jl")):
        for dp, _, fs in os.walk(os.path.join(ROOT, base)):
            for f in sorted(fs):
                if f.endswith(ext) and not f.startswith(("meldungen", "_meldungen")):
                    yield lang, os.path.relpath(os.path.join(dp, f), ROOT)


def _art(lang, path, text):
    if _UMLAUT.search(text) or _GERMAN.search(text):
        return "deutsch"
    return "R-Text"


def scan():
    rows = []
    for lang, path in _files():
        func = ""
        with open(os.path.join(ROOT, path), encoding="utf-8", errors="replace") as fh:
            for no, line in enumerate(fh, 1):
                m = _FUNC[lang].match(line)
                if m:
                    func = next(g for g in m.groups() if g)
                if line.lstrip().startswith("#"):
                    continue
                for _, pat in _PAT[lang]:
                    for mm in pat.finditer(line):
                        call = mm.group(1)
                        text = mm.group(len(mm.groups()))[1:-1]
                        if not text.strip():
                            continue
                        rows.append((lang, path, no, func, _art(lang, path, text), call, text))
    return rows


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("--tsv", help="Tabelle in diese Datei statt auf die Standardausgabe")
    ap.add_argument("--nur-deutsch", action="store_true", help="nur deutsche Texte (ohne die R-Texte der Nachbildungen)")
    a = ap.parse_args(argv)
    rows = scan()
    if a.nur_deutsch:
        rows = [r for r in rows if r[4] == "deutsch"]
    out = open(a.tsv, "w", encoding="utf-8") if a.tsv else sys.stdout
    out.write("sprache\tdatei\tzeile\tfunktion\tart\taufruf\ttext\n")
    for r in rows:
        out.write("\t".join(str(v).replace("\t", " ") for v in r) + "\n")
    if a.tsv:
        out.close()
    cnt = {}
    for r in rows:
        cnt[(r[0], r[4])] = cnt.get((r[0], r[4]), 0) + 1
    for k in sorted(cnt):
        sys.stderr.write("%-7s %-8s %5d\n" % (k[0], k[1], cnt[k]))
    return 0


if __name__ == "__main__":
    sys.exit(main())
