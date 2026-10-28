#!/usr/bin/env python3
"""Umbenennungen nach ``tools/rename_map.tsv`` anwenden (Etappe 6.2).

Nur Standardbibliothek. Aufruf aus beliebigem Ordner::

    python3 tools/rename.py --dry-run [--report datei]   # nur zählen, nichts ändern
    python3 tools/rename.py [--report datei]             # anwenden
    python3 tools/rename.py --news                       # NEWS-Abschnitte schreiben

Kein blindes Suchen und Ersetzen: Jeder Treffer (Name mit Bezeichnergrenzen der
Sprache) wird nach seinem Zusammenhang eingeordnet.

Funktionen (Art ``funktion``, ``intern``): umbenannt werden Aufruf ``alt(``,
Definition (R ``alt <- function``, Python ``def``, Julia ``function``), Import-
und Exportlisten (``NAMESPACE``, ``__all__``, ``_LAZY``, ``quiet_fp``-Listen,
``from … import``, ``export``, ``using …:``), ``_ext("modul", "alt")``,
Julia-Symbole ``:alt``, qualifizierte Verweise (``simlev.alt``, ``SL.Modul.alt``,
``SimLev:::alt``), Rd ``\\alias``, ``\\name``, ``\\link``, Sphinx ``:func:``,
Meldungstexte ``alt: …`` und – bei Namen ohne zweite Bedeutung – auch bloße
Verweise (``metrics = study_metrics``, Text in Backticks, Fließtext). Nicht
umbenannt: Schlüsselwörter und Elementnamen (``alt =``, ``$alt``,
``["alt"]``, ``x.alt``), Dateinamen und Pfade (``alt.R``, ``modules/alt/``)
und Python-Modulpfade. Ein Treffer, der keiner Regel klar entspricht (vor
allem Zeichenketten ``"alt"`` außerhalb von Namenslisten und bloße Treffer
mehrdeutiger Namen), ist eine Ausnahme: Er wird nach
``tools/rename_exceptions.tsv`` entschieden; fehlt dort die Entscheidung,
bricht der echte Lauf ab.

Argumente (Art ``argument``, ``begriff``) gelten nur im Bereich der genannten
Funktionen: Formalargumente, Rumpf (mit dem vorangehenden roxygen-Block bzw.
Julia-Docstring), Rd-Seite der Funktion, benannte Übergaben ``alt =`` in
Aufrufen dieser Funktionen (auch in Code-Zeichenketten) und Julia-
Argumentlisten ``:f => (…, :alt, …)``. Ist ``alt`` sonst nirgends ein
Formalargument und kommt im Paket nur als Elementname des Ergebnisobjekts
vor (z. B. ``asset_share``), gilt die Zeile im ganzen Paket („global“): dann
auch alle Elementzugriffe und Meldungstexte.

Interne R-Helfer (Art ``intern``): R ``alt`` → ``.alt``, Python und Julia
``alt`` → ``_alt``.

Nicht bearbeitet: vergangene NEWS-Einträge (NEWS-Dateien bekommen nur den
neuen Abschnitt), ``golden/modules/*/``, ``golden/cases``, ``golden/extra``
(werden neu erzeugt bzw. umgestellt), ``tools/api_snapshot/out``,
``tools/api_snapshot/api.json`` (neu geschrieben), die Tabelle und dieses
Skript selbst.
"""
from __future__ import annotations

import argparse
import ast
import collections
import os
import re
import sys

ROOT = os.path.realpath(os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))
MAP = os.path.join(ROOT, "tools", "rename_map.tsv")
EXC = os.path.join(ROOT, "tools", "rename_exceptions.tsv")

SKIP_DIRS = {".git", "__pycache__", "out", ".pytest_cache", "node_modules"}
SKIP_FILES = {"tools/rename_map.tsv", "tools/rename_exceptions.tsv", "tools/rename.py",
              "tools/api_snapshot/api.json", "docs/STRUKTUR.md",
              "r/NEWS.md", "python/NEWS.md", "julia/NEWS.md",
              # Übersetzer der Etappe 6.3: nennen die alten Namen absichtlich
              "golden/tools/blocks_from_flat.py", "golden/tools/blocks_from_flat.R"}
SKIP_PREFIX = ("golden/cases/", "golden/extra/", "tools/api_snapshot/out/")
TEXT_EXT = {".R", ".Rd", ".Rmd", ".py", ".jl", ".md", ".tsv", ".sh", ".toml", ".txt", ".cfg"}
PY_MODULES = None   # Namen der Module von python/simlev (für Modulpfade)
AMB_NAMES = set()   # Funktionsnamen mit Zweitbedeutung (Aufruf nur ohne Leerzeichen vor "(")


# ── Tabelle ───────────────────────────────────────────────────────────────────

class Row:
    def __init__(self, art, bereich, alt, neu, bem, ln):
        self.art, self.alt, self.neu, self.bem, self.ln = art, alt, neu, bem, ln
        self.bereich = None if bereich.strip() in ("*", "") else [b.strip() for b in bereich.split(",")]
        self.mode = None            # Argumente: "global" oder "bereich"

    def new_for(self, lang):
        if self.art == "intern" and lang in ("py", "jl"):
            return "_" + self.alt
        return self.neu

    @property
    def key(self):
        return "%d:%s:%s→%s" % (self.ln, self.art, self.alt, self.neu)


def read_map(path=MAP):
    rows = []
    with open(path, encoding="utf-8") as fh:
        for ln, line in enumerate(fh, 1):
            line = line.rstrip("\n")
            if not line.strip() or line.startswith("#"):
                continue
            f = line.split("\t")
            while len(f) < 5:
                f.append("")
            if f[0] not in ("funktion", "intern", "argument", "begriff"):
                sys.exit("%s:%d: unbekannte Art %r" % (path, ln, f[0]))
            rows.append(Row(f[0], f[1], f[2], f[3], f[4], ln))
    return rows


def read_exceptions(path=EXC):
    out = {}
    if not os.path.exists(path):
        return out
    with open(path, encoding="utf-8") as fh:
        for ln, line in enumerate(fh, 1):
            line = line.rstrip("\n")
            if not line.strip() or line.startswith("#"):
                continue
            f = line.split("\t")
            if f[0] == "datei":
                continue
            if len(f) < 5 or f[3] not in ("umbenennen", "belassen"):
                sys.exit("%s:%d: erwartet datei, alt, zeile, umbenennen|belassen, begruendung" % (path, ln))
            out[(f[0], f[1], f[2].strip())] = f[3]
    return out


# ── Dateien ───────────────────────────────────────────────────────────────────

def lang_of(rel):
    ext = os.path.splitext(rel)[1]
    base = os.path.basename(rel)
    if ext in (".R", ".Rmd") or base in ("NAMESPACE", "DESCRIPTION"):
        return "R"
    if ext == ".Rd":
        return "Rd"
    if ext == ".py":
        return "py"
    if ext == ".jl":
        return "jl"
    if rel.startswith("r/"):
        return "mdR"
    return "md"


def files():
    out = []
    for d, dirs, fs in os.walk(ROOT):
        rd = os.path.relpath(d, ROOT)
        rd = "" if rd == "." else rd.replace(os.sep, "/") + "/"
        dirs[:] = sorted(x for x in dirs if x not in SKIP_DIRS and not (rd + x + "/").startswith(SKIP_PREFIX)
                         and not re.match(r"golden/modules/[^/]+$", rd + x))
        for f in sorted(fs):
            rel = rd + f
            if rel in SKIP_FILES or rel.startswith(SKIP_PREFIX):
                continue
            ext = os.path.splitext(f)[1]
            if ext in TEXT_EXT or f in ("NAMESPACE", "DESCRIPTION"):
                out.append(rel)
    return out


# ── Hilfen für Text ───────────────────────────────────────────────────────────

def ident_re(name, lang):
    if lang in ("R", "Rd", "mdR"):
        # R-Bezeichner enthalten Punkte; ein Punkt nach einem Wortzeichen ist aber auch der
        # Modulzugriff in Python-/Julia-Code innerhalb von Zeichenketten (AT.name, SL.Mod.name)
        return re.compile(r"(?<![A-Za-z0-9_])(?<!(?<![A-Za-z0-9_])\.)%s(?![A-Za-z0-9_])" % re.escape(name))
    if lang == "jl":
        return re.compile(r"(?<![A-Za-z0-9_])%s(?![A-Za-z0-9_!])" % re.escape(name))
    return re.compile(r"(?<![A-Za-z0-9_])%s(?![A-Za-z0-9_])" % re.escape(name))


def line_at(text, pos):
    a = text.rfind("\n", 0, pos) + 1
    b = text.find("\n", pos)
    return text[a:len(text) if b < 0 else b]


def match_close(text, i, open_ch="(", close_ch=")", limit=20000):
    """Index der schließenden Klammer zu text[i] (= open_ch); Zeichenketten ("…", '…') werden
    übersprungen, Escapes (\\x) zählen nicht als Anführungszeichen."""
    depth, q, j, n = 0, None, i, min(len(text), i + limit)
    while j < n:
        c = text[j]
        if c == "\\":
            j += 2
            continue
        if q:
            if c == q:
                q = None
        elif c in "\"'":
            # Apostroph in Text (z. B. "Politis-White's") nur als Anführungszeichen, wenn danach eins kommt
            if c == "'" and text.find("'", j + 1, min(n, j + 400)) < 0:
                pass
            else:
                q = c
        elif c == open_ch:
            depth += 1
        elif c == close_ch:
            depth -= 1
            if depth == 0:
                return j
        j += 1
    return -1


def py_regions(text):
    """Bereiche der Namenslisten in Python: __all__, quiet_fp(globals(), [...]), _LAZY."""
    regs = []
    for m in re.finditer(r"__all__\s*\+?=\s*([\[(])|quiet_fp\(globals\(\),\s*([\[(])|_LAZY\s*=\s*(\{)", text):
        st = m.start(m.lastindex)
        oc = text[st]
        cc = {"[": "]", "(": ")", "{": "}"}[oc]
        en = match_close(text, st, oc, cc)
        if en > 0:
            regs.append((st, en, "lazy" if oc == "{" else "list"))
    return regs


def import_lines(text, lang):
    """Zeilen (Startpositionen) von Import-/Exportanweisungen samt Fortsetzungszeilen."""
    spans = []
    if lang == "py":
        for m in re.finditer(r"(?m)^[ \t]*(from\s+[\w.]+\s+)?import\s+", text):
            st = m.start()
            rest = text[m.end():]
            if rest.startswith("("):
                en = match_close(text, m.end())
            else:
                en = text.find("\n", m.end())
                while en > 0 and text[en - 1] == "\\":
                    en = text.find("\n", en + 1)
            spans.append((st, len(text) if en < 0 else en))
    elif lang == "jl":
        for m in re.finditer(r"(?m)^[ \t]*(export|using|import|public)\b", text):
            st = m.start()
            en = text.find("\n", m.end())
            while en > 0 and text[:en].rstrip().endswith(","):
                en2 = text.find("\n", en + 1)
                if en2 < 0:
                    en = len(text)
                    break
                en = en2
            spans.append((st, len(text) if en < 0 else en))
    return spans


def in_spans(pos, spans):
    return any(a <= pos < b for a, b, *_ in spans)


# ── Bereiche (Funktionsrümpfe) ────────────────────────────────────────────────

def r_scopes(text, fname):
    out = []
    for m in re.finditer(r"(?m)^%s\s*<-\s*function\s*\(" % re.escape(fname), text):
        po = text.index("(", m.end() - 1)
        pc = match_close(text, po)
        if pc < 0:
            continue
        k = pc + 1
        while k < len(text) and text[k] in " \t\n":
            k += 1
        en = match_close(text, k, "{", "}") if k < len(text) and text[k] == "{" else text.find("\n", k)
        st = m.start()
        # vorangehender roxygen-Block
        lines_before = text[:st].split("\n")
        j = len(lines_before) - 2
        while j >= 0 and lines_before[j].startswith("#'"):
            j -= 1
        st = len("\n".join(lines_before[:j + 1])) + (1 if j >= 0 else 0)
        out.append((st, en + 1))
    return out


def py_scopes(text, fname):
    try:
        tree = ast.parse(text)
    except SyntaxError:
        return []
    offs = [0]
    for ln in text.split("\n"):
        offs.append(offs[-1] + len(ln) + 1)
    out = []
    for node in tree.body:
        if isinstance(node, ast.FunctionDef) and node.name == fname:
            a = node.decorator_list[0].lineno if node.decorator_list else node.lineno
            out.append((offs[a - 1], offs[node.end_lineno]))
    return out


_JL_OPEN = re.compile(r"(?<![A-Za-z0-9_.:])(function|if|for|while|begin|let|do|try|struct|mutable struct|module|"
                      r"quote|macro|baremodule)(?![A-Za-z0-9_!])")


def jl_block_end(text, st):
    """Ende des Julia-Blocks, der bei st mit einem Schlüsselwort beginnt (grob: Zeichenketten und
    Kommentare übersprungen, Indexausdrücke mit `end` in [] nicht gezählt)."""
    depth, j, n, br = 0, st, len(text), 0
    while j < n:
        c = text[j]
        if c == "#":
            if text.startswith("#=", j):
                k = text.find("=#", j + 2)
                j = n if k < 0 else k + 2
                continue
            k = text.find("\n", j)
            j = n if k < 0 else k
            continue
        if text.startswith('"""', j):
            k = text.find('"""', j + 3)
            j = n if k < 0 else k + 3
            continue
        if c == '"':
            k = j + 1
            while k < n and text[k] != '"':
                k += 2 if text[k] == "\\" else 1
            j = k + 1
            continue
        if c == "'" and j + 2 < n and (text[j + 2] == "'" or (text[j + 1] == "\\" and j + 3 < n and text[j + 3] == "'")):
            j += 3 if text[j + 2] == "'" else 4
            continue
        if c in "[(":
            br += 1
        elif c in "])":
            br -= 1
        if c.isalpha() and (j == 0 or not (text[j - 1].isalnum() or text[j - 1] in "_.:")):
            m = re.match(r"[A-Za-z_][A-Za-z0-9_!]*", text[j:])
            w = m.group(0)
            if w in ("function", "if", "for", "while", "begin", "let", "do", "try", "struct", "module", "quote",
                     "macro", "baremodule") and not (w == "function" and br > 0 and False):
                # `x -> begin` u. ä. zählt; Kurzformen ohne end gibt es für diese Wörter nicht
                depth += 1
            elif w == "end" and br == 0:
                depth -= 1
                if depth == 0:
                    return j + 3
            j += len(w)
            continue
        j += 1
    return n


def jl_scopes(text, fname):
    out = []
    for m in re.finditer(r"(?m)^(function\s+)?%s\s*\(" % re.escape(fname), text):
        st = m.start()
        if m.group(1):
            en = jl_block_end(text, st)
        else:
            po = text.index("(", m.end() - 1)
            pc = match_close(text, po)
            if pc < 0 or not re.match(r"\s*=[^=]", text[pc + 1:]):
                continue
            en = text.find("\n", pc)
        # vorangehender Docstring
        before = text[:st].rstrip()
        if before.endswith('"""'):
            k = before.rfind('"""', 0, len(before) - 3)
            if k >= 0:
                st = k
        out.append((st, en))
    return out


def rd_is_for(text, fnames):
    al = set(re.findall(r"\\alias\{([^}]*)\}", text))
    return bool(al & set(fnames))


# ── Einordnung eines Funktionstreffers ────────────────────────────────────────

MODULE_LIKE = re.compile(r"^(simlev|SimLev|SL|[A-Z][A-Za-z0-9_]*)$")


def rel_is_tsv(ctx):
    return ctx.get("tsv", False)


def classify_fun(text, s, e, lang, name, ctx):
    """Liefert (art, umbenennen?) für einen Treffer eines Funktionsnamens."""
    nxt = text[e:e + 80]
    prv = text[max(0, s - 80):s]
    pc = text[s - 1] if s else ""
    nc = text[e] if e < len(text) else ""
    stripped = nxt.lstrip(" \t")
    # Pfade und Dateinamen
    if re.match(r"\.(R|Rd|Rmd|jl|py|md|json|gz|svg)\b", nxt) or nc == "/" or pc == "/" or \
            re.search(r"(golden|modules|test|tests)/$", prv):
        return "pfad", False
    # Python-Modulpfade (nur für Namen, die auch Modulnamen sind)
    if name in PY_MODULES:
        if True:   # auch Python-Code in Zeichenketten anderer Dateien
            if re.search(r"(from|import)\s+[\w.]*\.?$", prv) and pc in ". " or re.search(r"\bfrom\s+\.$", prv):
                return "modulpfad", False
            if pc == "." and re.search(r"\bsimlev\.$", prv) and not re.match(r"\s*\(", nxt):
                return "modulpfad", False   # simlev.<modul> ohne Aufruf ist das Modul
            if re.search(r"import\s+simlev\.$", prv):
                return "modulpfad", False
            if re.search(r"_ext\(\s*[\"']$", prv):
                return "modulpfad", False
    if (nxt.startswith("(") or (stripped.startswith("(") and name not in AMB_NAMES)) and not (pc in "\"'" and nc == pc):
        if lang == "R" and re.search(r"function\s*$", prv):
            return "aufruf", True
        return ("definition" if re.search(r"(def|function)\s+$", prv) else "aufruf"), True
    if lang in ("R", "mdR", "Rd") and re.match(r"\s*(<-|=)\s*function\b", nxt):
        return "definition", True
    # Zeichenkette genau "name"
    if pc in "\"'" and nc == pc:
        if lang == "py":
            for a, b, kind in ctx["pyreg"]:
                if a < s < b:
                    if kind == "lazy" and re.match(r"[\"']\s*:", text[e:e + 5]):
                        return "modulschluessel", False
                    return "namensliste", True
            if re.search(r"_ext\(\s*[\"'][\w.]+[\"']\s*,\s*[\"']$", prv) or re.search(r"getattr\([^,()]+,\s*[\"']$", prv):
                return "namensliste", True
        return "zeichenkette", None
    # Rd- und NAMESPACE-Kontexte
    if re.search(r"\\(alias|name|link)(\[[^\]]*\])?\{$", prv) and nc == "}":
        return "rd", True
    if prv.endswith("\\link[=") and nc == "]":
        return "rd", True
    if re.search(r"@(rdname|inheritParams|describeIn)\s+$", prv):
        return "roxygen", True
    if pc == "?" and lang in ("R", "mdR", "md", "Rd"):
        return "hilfe", True
    if re.search(r"#'?\s*─+\s*$", prv):
        return "abschnitt", True
    if rel_is_tsv(ctx) and (s == 0 or pc == "\n") and nc == "\t":
        return "tsvschluessel", True
    if re.search(r"(export|S3method)\(\s*$", prv) or re.search(r"(export|S3method)\([^()]*,\s*$", prv):
        return "namespace", True
    if prv.endswith(":func:`") or prv.endswith(":py:func:`"):
        return "sphinx", True
    # Julia-Symbole und Namensraumzugriffe
    if pc == ":" and lang == "jl" and not prv.endswith("::"):
        return "symbol", True
    if prv.endswith("::") and lang in ("R", "Rd", "mdR", "md"):
        return "namensraum", True
    if lang in ("py", "jl") and in_spans(s, ctx["imports"]):
        return "import", True
    if pc == ".":
        owner = re.search(r"([A-Za-z_][A-Za-z0-9_]*)\.$", prv)
        if owner and MODULE_LIKE.match(owner.group(1)):
            return "modulverweis", True
        return "attribut", None
    # Elemente und Schlüsselwörter
    if pc == "$" or prv.endswith('[["') or prv.endswith("[['"):
        return "element", False
    if re.match(r"\s*=(?![=>])", nxt) and not re.match(r"\s*=\s*function\b", nxt):
        return "schluesselwort", None
    # Meldungstext „name: …“ (nicht: Typangabe eines Python-Arguments, name: int,)
    if re.match(r":\s", nxt) and not (lang == "py" and re.match(r":\s*[A-Za-z_][\w\[\], |.]*\s*[,)=]", nxt)):
        return "meldung", True
    if pc == "`" and nc == "`":
        return "backtick", "bare"
    return "bloss", "bare"


# ── Hauptarbeit ───────────────────────────────────────────────────────────────

class Hit:
    __slots__ = ("rel", "s", "e", "new", "row", "kind", "line", "decision", "ln")

    def __init__(self, rel, s, e, new, row, kind, line, decision, ln=0):
        self.rel, self.s, self.e, self.new, self.row, self.kind, self.line, self.decision, self.ln = \
            rel, s, e, new, row, kind, line, decision, ln


def py_module_names():
    d = os.path.join(ROOT, "python", "simlev")
    return {os.path.splitext(f)[0] for f in os.listdir(d) if f.endswith(".py")}


def formals_owner_map():
    """Formalargumente je Funktion (R-Quellen, grob): {arg: {funktionen}}."""
    own = collections.defaultdict(set)
    rdir = os.path.join(ROOT, "r", "R")
    for f in os.listdir(rdir):
        if not f.endswith(".R"):
            continue
        t = open(os.path.join(rdir, f), encoding="utf-8").read()
        for m in re.finditer(r"(?m)^([A-Za-z.][A-Za-z0-9._]*)\s*<-\s*function\s*\(", t):
            po = t.index("(", m.end() - 1)
            pc = match_close(t, po)
            sig = t[po + 1:pc]
            for a in re.findall(r"(?:^|,)\s*([A-Za-z.][A-Za-z0-9._]*)\s*(?==|,|$)", sig, flags=re.S):
                own[a].add(m.group(1))
    return own


def decide_modes(rows, texts):
    """Argumentzeilen: global, wenn alt nur in den Bereichsfunktionen Formalargument ist."""
    own = formals_owner_map()
    for r in rows:
        if r.art in ("argument", "begriff"):
            others = own.get(r.alt, set()) - set(r.bereich or [])
            r.mode = "bereich" if others or r.art == "begriff" or len(r.alt) < 6 or "_" not in r.alt else "global"


def ambiguous_names(rows, texts):
    """Funktionsnamen mit zweiter Bedeutung im Paket (Schlüsselwort, Element, Zeichenkette als Wert)."""
    amb = {}
    for r in rows:
        if r.art not in ("funktion", "intern"):
            continue
        why = collections.Counter()
        for rel, (lang, text, ctx) in texts.items():
            if not rel.startswith(("r/R/", "python/simlev/", "julia/src/")):
                continue
            for m in ident_re(r.alt, lang).finditer(text):
                kind, ok = classify_fun(text, m.start(), m.end(), lang, r.alt, ctx)
                if kind in ("schluesselwort", "element", "zeichenkette", "attribut", "modulpfad", "modulschluessel"):
                    why[kind] += 1
        if why:
            amb[r.alt] = dict(why)
    return amb


def scan(rows, exc, only_rel=None):
    rels = files() if only_rel is None else only_rel
    texts = {}
    for rel in rels:
        p = os.path.join(ROOT, rel)
        try:
            text = open(p, encoding="utf-8").read()
        except UnicodeDecodeError:
            continue
        lang = lang_of(rel)
        ctx = {"tsv": rel.endswith(".tsv"),
               "pyreg": py_regions(text) if lang == "py" else [],
               "imports": import_lines(text, lang) if lang in ("py", "jl") else []}
        texts[rel] = (lang, text, ctx)
    decide_modes(rows, texts)
    amb = ambiguous_names(rows, texts)
    AMB_NAMES.clear()
    AMB_NAMES.update(amb)
    hits, openx = [], []
    for rel, (lang, text, ctx) in texts.items():
        hits.extend(scan_file(rel, lang, text, ctx, rows, amb, exc, openx))
    return texts, hits, openx, amb


def scan_file(rel, lang, text, ctx, rows, amb, exc, openx):
    out = []
    pl = "R" if lang in ("R", "Rd", "mdR") else ("py" if lang == "py" else "jl" if lang == "jl" else "md")
    # Sprache der Port-Namen für interne Helfer: nach Ordner
    port = "py" if rel.startswith("python/") else "jl" if rel.startswith("julia/") else "R"
    if lang == "py":
        port = "py"
    elif lang == "jl":
        port = "jl"
    for r in rows:
        if r.art in ("funktion", "intern"):
            new = r.new_for(port)
            if r.art == "intern" and port in ("py", "jl"):
                # Ports: nur, wo der Name ohne _ noch vorkommt (Regel der Ports)
                pass
            for m in ident_re(r.alt, lang).finditer(text):
                s, e = m.start(), m.end()
                kind, ok = classify_fun(text, s, e, lang, r.alt, ctx)
                if ok == "bare":
                    ok = None if r.alt in amb else True
                if r.art == "intern" and kind == "meldung":
                    ok = False          # Meldungstexte bleiben gleich (R und Ports müssen denselben Text geben)
                    kind = "meldung (intern)"
                line = line_at(text, s).strip()
                dec = None
                if ok is None and r.alt in amb:
                    # Name mit Zweitbedeutung: ohne Entscheidung in der Ausnahmeliste bleibt der Treffer
                    dec = exc.get((rel, r.alt, line))
                    ok = dec == "umbenennen"
                    kind = kind + (" (ausnahme)" if dec else " (zweitbedeutung)")
                if ok is None:
                    dec = exc.get((rel, r.alt, line))
                    if dec is None:
                        openx.append((rel, r.alt, line, kind))
                        ok = False
                        kind = kind + " (offen)"
                    else:
                        ok = dec == "umbenennen"
                        kind = kind + " (ausnahme)"
                if r.art == "intern" and port == "R" and kind.startswith("aufruf") and text[s - 1:s] == ".":
                    continue
                out.append(Hit(rel, s, e, new if ok else None, r, kind, line, dec))
        else:
            out.extend(scan_arg(rel, lang, text, ctx, r, exc, openx))
    return out


def call_spans(text, fnames, lang):
    """(Start der Argumente, Ende) aller Aufrufe der Funktionen fnames (auch in Code-Zeichenketten)."""
    spans = []
    for f in fnames:
        for m in re.finditer(r"(?<![A-Za-z0-9_])%s\s*\(" % re.escape(f), text):
            po = m.end() - 1
            pc = match_close(text, po)
            if pc > 0:
                spans.append((po, pc, f))
    return spans


def top_level_positions(text, a, b):
    """Positionen in text[a+1:b], die auf Tiefe 1 (relativ zu a) liegen (Zeichenketten übersprungen)."""
    ok = bytearray(b - a + 1)
    depth, q, j = 0, None, a
    while j <= b:
        c = text[j]
        if c == "\\":
            j += 2
            continue
        if q:
            if c == q:
                q = None
        elif c in "\"'":
            if c == "'" and text.find("'", j + 1, b) < 0:
                pass
            else:
                q = c
        elif c in "([{":
            depth += 1
        elif c in ")]}":
            depth -= 1
        if depth == 1 and not q:
            ok[j - a] = 1
        j += 1
    return ok


def scan_arg(rel, lang, text, ctx, r, exc, openx):
    out = []
    rx = ident_re(r.alt, lang)
    seen = set()

    def add(s, e, kind):
        if s in seen:
            return
        seen.add(s)
        out.append(Hit(rel, s, e, r.neu, r, kind, line_at(text, s).strip(), None))

    if r.mode == "global":
        for m in rx.finditer(text):
            s = m.start()
            pc = text[s - 1] if s else ""
            kind = "element" if (pc == "$" or pc in "\"'" or pc == ".") else "global"
            add(s, m.end(), kind)
        return out
    fn = r.bereich
    # Rümpfe
    scopes = []
    if lang == "R":
        for f in fn:
            scopes += r_scopes(text, f)
    elif lang == "py":
        for f in fn:
            scopes += py_scopes(text, f)
    elif lang == "jl":
        for f in fn:
            scopes += jl_scopes(text, f)
    elif lang == "Rd" and rd_is_for(text, fn):
        scopes = [(0, len(text))]
    for a, b in scopes:
        for m in rx.finditer(text, a, b):
            add(m.start(), m.end(), "bereich")
    # benannte Übergaben in Aufrufen
    for po, pc, f in call_spans(text, fn, lang):
        top = top_level_positions(text, po, pc)
        for m in rx.finditer(text, po, pc):
            if top[m.start() - po] and re.match(r"\s*=(?![=>])", text[m.end():m.end() + 4]):
                add(m.start(), m.end(), "uebergabe")
    # Julia-Argumentlisten :f => (…)
    if lang == "jl":
        for f in fn:
            for m in re.finditer(r":%s\s*=>\s*\(" % re.escape(f), text):
                po = m.end() - 1
                pc = match_close(text, po)
                for mm in re.finditer(r":%s(?![A-Za-z0-9_])" % re.escape(r.alt), text[po:pc]):
                    add(po + mm.start() + 1, po + mm.end(), "argumentliste")
    return out


def number_lines(texts, hits):
    nl = {}
    for h in hits:
        if h.rel not in nl:
            t = texts[h.rel][1]
            nl[h.rel] = [i for i, c in enumerate(t) if c == "\n"]
        import bisect
        h.ln = bisect.bisect_left(nl[h.rel], h.s) + 1


def apply(texts, hits):
    by = collections.defaultdict(list)
    for h in hits:
        if h.new is not None:
            by[h.rel].append(h)
    changed = []
    for rel, hs in by.items():
        lang, text, _ = texts[rel]
        hs.sort(key=lambda h: h.s)
        for a, b in zip(hs, hs[1:]):
            if a.e > b.s:
                sys.exit("Überlappende Treffer in %s bei %d" % (rel, b.s))
        parts, last = [], 0
        for h in hs:
            parts.append(text[last:h.s])
            parts.append(h.new)
            last = h.e
        parts.append(text[last:])
        new = "".join(parts)
        if new != text:
            with open(os.path.join(ROOT, rel), "w", encoding="utf-8") as fh:
                fh.write(new)
            changed.append(rel)
    return changed


def rename_rd_files(rows, dry):
    moved = []
    for r in rows:
        if r.art != "funktion":
            continue
        p = os.path.join(ROOT, "r", "man", r.alt + ".Rd")
        q = os.path.join(ROOT, "r", "man", r.neu + ".Rd")
        if os.path.exists(p):
            if os.path.exists(q):
                sys.exit("Rd-Datei %s gibt es schon" % q)
            moved.append(("r/man/%s.Rd" % r.alt, "r/man/%s.Rd" % r.neu))
            if not dry:
                os.rename(p, q)
    return moved


def report(path, rows, hits, openx, amb, moved, held, dry):
    cnt = collections.defaultdict(collections.Counter)
    skip = collections.defaultdict(collections.Counter)
    for h in hits:
        (cnt if h.new is not None else skip)[h.row.key][h.kind] += 1
    L = ["# Umbenennung (tools/rename.py) – %s" % ("Probelauf" if dry else "Lauf"), ""]
    L.append("Zeilen: %d aktiv, %d angehalten (auskommentiert in tools/rename_map.tsv)." % (len(rows), len(held)))
    L.append("Treffer umbenannt: %d, nicht umbenannt: %d, offene Ausnahmen: %d." %
             (sum(h.new is not None for h in hits), sum(h.new is None for h in hits), len(openx)))
    L += ["", "## Treffer je Zeile und Art", "", "| Zeile | Art | alt | neu | Modus | umbenannt (je Zusammenhang) | belassen (je Zusammenhang) |",
          "|---|---|---|---|---|---|---|"]
    for r in rows:
        c, k = cnt[r.key], skip[r.key]
        fmt = lambda x: ", ".join("%s %d" % kv for kv in sorted(x.items())) or "–"
        L.append("| %d | %s | `%s` | `%s` | %s | %d: %s | %d: %s |" % (r.ln, r.art, r.alt, r.neu, r.mode or ("mehrdeutig" if r.alt in amb else "eindeutig"),
                                                              sum(c.values()), fmt(c), sum(k.values()), fmt(k)))
    tot = collections.Counter()
    for h in hits:
        if h.new is not None:
            tot[h.row.art] += 1
    L += ["", "Summe umbenannt je Art: " + ", ".join("%s %d" % kv for kv in sorted(tot.items())), ""]
    L += ["## Mehrdeutige Funktionsnamen (Zweitbedeutung im Paket)", ""]
    for n, why in sorted(amb.items()):
        L.append("- `%s`: %s" % (n, ", ".join("%s %d" % kv for kv in sorted(why.items()))))
    L += ["", "## Rd-Dateien umbenannt", ""] + ["- `%s` → `%s`" % m for m in moved]
    L += ["", "## Offene Ausnahmen (%d)" % len(openx), ""]
    for rel, alt, line, kind in openx:
        L.append("- `%s` [%s] `%s`: %s" % (rel, kind, alt, line[:200]))
    L += ["", "## Angehaltene Zeilen", ""] + ["- " + h for h in held]
    L += ["", "## Alle Treffer (umbenannt = U, belassen = B)", ""]
    for h in sorted(hits, key=lambda h: (h.rel, h.s)):
        L.append("%s %s:%d [%s] %s: %s" % ("U" if h.new is not None else "B", h.rel, h.ln, h.kind, h.row.alt, h.line[:160]))
    with open(path, "w", encoding="utf-8") as fh:
        fh.write("\n".join(L) + "\n")


def held_rows(path=MAP):
    out = []
    with open(path, encoding="utf-8") as fh:
        for line in fh:
            if line.startswith("#angehalten\t"):
                out.append(line.rstrip("\n").split("\t", 1)[1].replace("\t", " | "))
    return out


# ── NEWS ──────────────────────────────────────────────────────────────────────

NEWS_HEAD = "### Umbenennungen (Etappe 6)"


def news_block(rows, lang):
    pre = {"R": "", "py": "", "jl": ""}[lang]
    L = [NEWS_HEAD, "",
         "Mechanisch umbenannt mit `tools/rename.py` nach `tools/rename_map.tsv`; die Rechnung "
         "ist unverändert (Nachweis über die Referenzfälle). Die alten Namen gibt es nicht mehr.", "",
         "| Art | gilt für | alt | neu |", "|---|---|---|---|"]
    for r in rows:
        if r.art == "intern":
            continue
        art = {"funktion": "Funktion", "argument": "Argument", "begriff": "Argument"}[r.art]
        ber = "–" if r.bereich is None else ", ".join("`%s`" % b for b in r.bereich)
        L.append("| %s | %s | `%s%s` | `%s%s` |" % (art, ber, pre, r.alt, pre, r.neu))
    intern = [r for r in rows if r.art == "intern"]
    if intern:
        L += ["", "Interne Helfer der Engine (nicht exportiert) folgen dem Namensschema: in R mit Punkt, "
              "in Python und Julia mit `_`: " + ", ".join("`%s`" % r.alt for r in intern) + "."]
    held = held_rows()
    if held:
        L += ["", "Zurückgestellt (Kollision, Entscheidung offen): " +
              "; ".join("`%s` → `%s`" % (h.split(" | ")[2], h.split(" | ")[3]) for h in held) + "."]
    return "\n".join(L) + "\n"


def write_news(rows):
    for lang, rel in (("R", "r/NEWS.md"), ("py", "python/NEWS.md"), ("jl", "julia/NEWS.md")):
        p = os.path.join(ROOT, rel)
        t = open(p, encoding="utf-8").read()
        blk = news_block(rows, lang)
        if NEWS_HEAD in t:
            a = t.index(NEWS_HEAD)
            m = re.compile(r"(?m)^#{1,3} ").search(t, a + len(NEWS_HEAD))
            t = t[:a] + blk + ("\n" + t[m.start():] if m else "")
        else:
            m = re.search(r"(?m)^##\s.*0\.5\.0.*\n", t)
            if not m:
                sys.exit("%s: Abschnitt 0.5.0 nicht gefunden" % rel)
            k = re.compile(r"(?m)^### ").search(t, m.end())     # vor dem ersten Unterabschnitt
            k = k.start() if k else len(t)
            t = t[:k] + blk + "\n" + t[k:]
        with open(p, "w", encoding="utf-8") as fh:
            fh.write(t)
        print("NEWS:", rel)


def main():
    global PY_MODULES
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--dry-run", action="store_true")
    ap.add_argument("--report", default=None)
    ap.add_argument("--news", action="store_true", help="nur die NEWS-Abschnitte schreiben")
    a = ap.parse_args()
    PY_MODULES = py_module_names()
    rows = read_map()
    if a.news:
        write_news(rows)
        return 0
    exc = read_exceptions()
    texts, hits, openx, amb = scan(rows, exc)
    number_lines(texts, hits)
    held = held_rows()
    rep = a.report or os.path.join(ROOT, "tools", "rename_report.md")
    if a.dry_run:
        moved = rename_rd_files(rows, True)
        report(rep, rows, hits, openx, amb, moved, held, True)
        print("Probelauf: %d Treffer umzubenennen, %d belassen, %d offene Ausnahmen -> %s" %
              (sum(h.new is not None for h in hits), sum(h.new is None for h in hits), len(openx), rep))
        return 0
    if openx:
        report(rep, rows, hits, openx, amb, [], held, True)
        sys.exit("%d offene Ausnahmen (siehe %s); erst in tools/rename_exceptions.tsv entscheiden" % (len(openx), rep))
    changed = apply(texts, hits)
    moved = rename_rd_files(rows, False)
    report(rep, rows, hits, openx, amb, moved, held, False)
    print("Lauf: %d Treffer in %d Dateien umbenannt, %d Rd-Dateien verschoben -> %s" %
          (sum(h.new is not None for h in hits), len(changed), len(moved), rep))
    return 0


if __name__ == "__main__":
    sys.exit(main())
