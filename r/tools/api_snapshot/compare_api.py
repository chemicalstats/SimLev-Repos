#!/usr/bin/env python3
"""Schnittstellen-Abgleich R / Python / Julia (Etappe 3, tools/api_snapshot).

Liest die drei Auszüge (``api_r.json``, ``api_py.json``, ``api_jl.json``),
ordnet die Namen nach den Regeln der Ports einander zu, vergleicht
Argumentnamen, Reihenfolge und Standardwerte, schreibt die zusammengeführte
Tabelle ``tools/api_snapshot/api.json`` und einen lesbaren Bericht auf die
Konsole. Abweichungen, die in ``known_differences.tsv`` als ``bewusst``
stehen, werden nicht gemeldet; Einträge mit Status ``unklar`` werden gemeldet
und eigens aufgelistet.

Nur Standardbibliothek. Aufruf aus der Repo-Wurzel::

    python3 tools/api_snapshot/compare_api.py [--dir tools/api_snapshot/out]
        [--known tools/api_snapshot/known_differences.tsv]
        [--out tools/api_snapshot/api.json] [--md abweichungen.md] [--check] [-v]

``--check``: Rückgabewert 1, wenn nicht erklärte Abweichungen bleiben (für
den Test in Etappe 6). Ohne ``--check`` immer 0, sofern die Auszüge lesbar
sind.

Zuordnung der Namen (Quelle: python/DEVELOPING.md „Ziel“, julia/DEVELOPING.md
„Aufbau“ und „Datenstrukturen“):

- Funktionen: R ``a.b`` → Python/Julia ``a_b``; sonst gleicher Name.
- S3-Methoden ``<generic>.<Klasse>``: Python ``<PyKlasse>.<generic>`` der
  Klasse mit ``r_class[0] == <Klasse>`` (print: ``.print`` oder ``.format``),
  Julia die für ``<Klasse>`` registrierte Funktion (``register_print!`` →
  ``show``, ``register_summary!`` → ``r_summary``, ``register_plot!`` →
  ``r_plot``). Schlüssel ist in allen drei Sprachen ``<generic>.<Klasse>``.
- Generische Funktionen: Julia ``r_print``/``r_plot``/``r_summary`` ↔
  R/Python ``print``/``plot``/``summary`` (Tabelle ``JL_GENERICS``).
"""
from __future__ import annotations

import argparse
import datetime as _dt
import fnmatch
import json
import keyword
import os
import re
import sys

LANGS = ("R", "Python", "Julia")
FILES = {"R": "api_r.json", "Python": "api_py.json", "Julia": "api_jl.json"}

# Julia-Namen der R-Generika (julia/DEVELOPING.md: `r_summary` und `r_plot`
# verteilen nach S3-Klasse; Kollisionen mit Base bekommen das Präfix `r_`).
JL_GENERICS = {"r_print": "print", "r_plot": "plot", "r_summary": "summary"}

# Argumentnamen, die in der Zielsprache Schlüsselwörter sind, tragen ein `_`:
# python/DEVELOPING.md „Ziel“: yield_, raise_, from_ (allgemein: keyword.kwlist);
# julia/DEVELOPING.md „Aufbau“: from_, end_, function_, … (reservierte Wörter
# von Julia, dazu `from` laut DEVELOPING).
PY_KEYWORDS = set(keyword.kwlist)
JL_KEYWORDS = {"baremodule", "begin", "break", "catch", "const", "continue", "do", "else", "elseif", "end",
               "export", "false", "finally", "for", "function", "global", "if", "import", "let", "local",
               "macro", "module", "quote", "return", "struct", "true", "try", "using", "while", "from"}

# ── Gleichsetzungen der Schreibweise ────────────────────────────────────────
# Werte, die sich nur in der Schreibweise unterscheiden, gelten als gleich.
# Jede Zeile: (Muster in R, Python, Julia) -> Normalform.
EQUIV_TABLE = [
    # (Normalform, R, Python, Julia)
    ("NULL", "NULL", "None", "nothing"),
    ("TRUE", "TRUE", "True", "true"),
    ("FALSE", "FALSE", "False", "false"),
    ("NA", "NA / NA_real_", "NA (simlev.NA, NaN mit Nutzlast 1954)", "NA (SimLev.NA) / missing (nicht numerisches NA)"),
    ("Inf", "Inf", "inf / math.inf / float('inf')", "Inf"),
    ("-Inf", "-Inf", "-inf", "-Inf"),
    ("Zeichenkette", '"a"', "'a' oder \"a\"", '"a"'),
    ("Vektor", 'c("a", "b"), c(1, 2)', "('a', 'b'), ['a', 'b'], (1, 2)", '["a", "b"], ("a", "b"), [1, 2]'),
    ("Zahl", "1, 1L, 1e+06, 0.5", "1, 1.0, 1000000.0, 0.5", "1, 1.0, 1.0e6, 1_000_000, 0.5"),
    ("Funktion", "max", "<function max>", "max"),
    ("leere Liste", "list()", "(), [], {}", "Any[], [], (), NamedTuple(), RList()"),
    ("Rest-Argumente", "...", "*args, **kwargs (zusammen ein Eintrag)", "args..., kw... (zusammen ein Eintrag)"),
    ("Name x", "x (Schlüsselwort der Zielsprache)", "x_ (yield_, raise_, from_)", "x_ (end_, from_, macro_, local_, …)"),
]
# Darstellungsregeln der Ports (mechanisch, eigens gezählt und in api.json
# unter "normalisiert" aufgeführt):
# - Python: hat eine Funktion ein Argument x_ (Schlüsselwort) und **kwargs,
#   nimmt **kwargs nur x als Namen an (Code: `if "yield" in kw: yield_ = kw.pop("yield")`,
#   python/simlev/bonds.py, tactical.py); **kwargs entfällt dann, sofern R kein `...` hat.
# - Julia: Positionsalias. Ein positionelles Argument b_pos oder b_ neben dem
#   Schlüsselwort b (Muster `f(x, b_pos = nothing; b = b_pos)`,
#   z. B. julia/src/bootstrap.jl `bootstrap`, signals.jl `signal_sma`) und
#   ein Schlüsselwort b_ mit Standardwert b (`type_ = type`) sind Aliasse von b;
#   sie entfallen, b erhält den Standardwert des Alias, falls b = <alias>.
# Zusätzlich (kein Schreibweisen-, sondern ein Code-Befund, eigens gezählt):
# Ruft der R-Rumpf match.arg(<arg>) auf, ist der Standardwert c("a", "b", ...)
# die Auswahl und wirksam das erste Element; ein Port, der als Standardwert
# nur "a" angibt, gilt dann als gleich ("match.arg"). Ebenso Julia `nothing`,
# wenn der Julia-Rumpf das Argument an eine *match_arg-Funktion gibt (diese
# liefern für `nothing` das erste Element: julia/src/data_prep.jl `_match_arg`,
# config.jl `match_arg`, deep_analysis.jl `_match_arg`).

_NUM = re.compile(r"^[-+]?(\d[\d_]*\.?\d*|\.\d+)([eE][-+]?\d+)?L?$")


def _split_top(s):
    """Teilt 'a, b, c' auf oberster Ebene (Klammern und Anführungszeichen beachtet)."""
    out, depth, cur, q = [], 0, [], None
    i = 0
    while i < len(s):
        c = s[i]
        if q:
            cur.append(c)
            if c == "\\" and i + 1 < len(s):
                cur.append(s[i + 1]); i += 2; continue
            if c == q:
                q = None
        elif c in "\"'":
            q = c; cur.append(c)
        elif c in "([{":
            depth += 1; cur.append(c)
        elif c in ")]}":
            depth -= 1; cur.append(c)
        elif c == "," and depth == 0:
            out.append("".join(cur).strip()); cur = []
        else:
            cur.append(c)
        i += 1
    last = "".join(cur).strip()
    if last or out:
        out.append(last)
    return [x for x in out if x != ""]


def norm_value(v, lang):
    """Normalform eines Standardwerts (Text) für den Vergleich."""
    if v is None:
        return None
    s = v.strip()
    low = s
    if low in ("NULL", "None", "nothing"):
        return "NULL"
    if low in ("TRUE", "True", "true", "T"):
        return "TRUE"
    if low in ("FALSE", "False", "false", "F"):
        return "FALSE"
    if low in ("NA", "NA_real_", "NA_integer_", "NA_character_", "SimLev.NA", "simlev.NA", "missing"):
        return "NA"
    if low in ("list()", "()", "[]", "{}", "Any[]", "NamedTuple()", "RList()", "SL.RList()", "Dict()"):
        return "leer"
    if low in ("Inf", "inf", "math.inf", "float('inf')", "Inf64"):
        return "Inf"
    if low in ("-Inf", "-inf", "-math.inf", "float('-inf')", "-Inf64"):
        return "-Inf"
    m = re.match(r"^<function (\w+)>$", s)
    if m:
        return "fn:" + {"maximum": "max", "minimum": "min"}.get(m.group(1), m.group(1))
    if _NUM.match(s):
        try:
            x = float(s.rstrip("L").replace("_", ""))
            return "num:" + repr(x)
        except ValueError:
            pass
    if len(s) >= 2 and s[0] == s[-1] and s[0] in "\"'" and s.count(s[0]) == 2:
        return 'str:"' + s[1:-1] + '"'
    # Vektoren
    inner = None
    if s.startswith("c(") and s.endswith(")"):
        inner = s[2:-1]
    elif (s.startswith("(") and s.endswith(")")) or (s.startswith("[") and s.endswith("]")):
        inner = s[1:-1]
    if inner is not None:
        parts = _split_top(inner)
        if all("=" not in p or p.strip().startswith(("'", '"')) for p in parts):
            items = [norm_value(p, lang) for p in parts]
            if len(items) == 1:
                return items[0]
            return "vec:[" + ", ".join(str(i) for i in items) + "]"
    if re.match(r"^[A-Za-z_][\w.]*$", s) and lang in ("R", "Julia"):
        # bloßer Name: Funktion (oder Verweis auf ein anderes Argument, siehe norm_args)
        return "fn:" + {"maximum": "max", "minimum": "min"}.get(s, s)
    return "txt:" + re.sub(r"\s+", " ", s)


def first_of(nv):
    if nv and nv.startswith("vec:["):
        parts = _split_top(nv[5:-1])
        return parts[0] if parts else None
    return nv


# ── Auszüge laden und normalisieren ─────────────────────────────────────────

def load(dirname):
    data = {}
    for lang, fn in FILES.items():
        p = os.path.join(dirname, fn)
        with open(p, encoding="utf-8") as fh:
            data[lang] = json.load(fh)
    return data


def canon_key(f, lang):
    if f["kind"] == "method":
        return "%s.%s" % (f["generic"], f["class"])
    n = f["name"]
    if lang == "R":
        return n.replace(".", "_")
    if lang == "Julia" and n in JL_GENERICS:
        return JL_GENERICS[n]
    return n


def norm_args(f, lang, r_has_dots=False, log=None):
    """Liste (name, default_text, norm, match_arg, default_known) ohne Objektargument der
    Methoden; Rest-Argumente zusammengefasst als ein '...' (an der ersten Stelle)."""
    args = [dict(a) for a in (f.get("args") or [])]
    if f["kind"] == "method" and args:
        args = args[1:]          # x / object / self: Name gibt die Generik vor
    names = {a["name"] for a in args}

    def note(msg):
        if log is not None:
            log.append(msg)

    if lang == "Python":
        esc = [a for a in args if a["name"].endswith("_") and a["name"][:-1] in PY_KEYWORDS]
        for a in esc:
            note("%s: Python %s -> %s" % (f["name"], a["name"], a["name"][:-1]))
            a["name"] = a["name"][:-1]
        if esc and not r_has_dots:
            vk = [a for a in args if a.get("kind") == "var_keyword"]
            for a in vk:
                note("%s: Python **%s nur für Schlüsselwort-Alias" % (f["name"], a["name"]))
            args = [a for a in args if a.get("kind") != "var_keyword"]
    if lang == "Julia":
        kw = {a["name"]: a for a in args if a.get("kind") == "keyword"}
        keep = []
        for a in args:
            n = a["name"]
            base = n[:-4] if n.endswith("_pos") else n[:-1] if n.endswith("_") else None
            if base and base in kw and a is not kw.get(base):
                if a.get("kind") in ("positional", "keyword"):
                    b = kw[base]
                    if b.get("default") == n:
                        b["default"] = a.get("default")
                        b["has_default"] = a.get("has_default")
                        if "default_value" in a:
                            b["default_value"] = a["default_value"]
                        if a.get("default_known") is False:
                            b["default_known"] = False
                    if a.get("match_arg"):
                        b["match_arg"] = True
                    note("%s: Julia-Alias %s von %s" % (f["name"], n, base))
                    continue
            if n.endswith("_") and n[:-1] in JL_KEYWORDS and n[:-1] not in names:
                note("%s: Julia %s -> %s" % (f["name"], n, n[:-1]))
                a["name"] = n[:-1]
            keep.append(a)
        args = keep
    out = []
    for a in args:
        k = a.get("kind")
        if k in ("dots", "var_positional", "var_keyword", "varargs", "kwargs_rest"):
            if any(o[0] == "..." for o in out):
                continue
            out.append(("...", None, None, False, True, a.get("dots_used")))
            continue
        d = a.get("default") if a.get("has_default") else None
        dv = a.get("default_value", d)
        out.append((a["name"], d if a.get("has_default") else "<kein>",
                    norm_value(dv, lang) if a.get("has_default") else "<kein>",
                    bool(a.get("match_arg")), a.get("default_known", True), None))
    # Verweise auf andere Argumente (R: lazy evaluation, z. B. step = test)
    argn = {o[0] for o in out}
    out = [(o[0], o[1], ("argref:" + o[2][3:]) if o[2] and o[2].startswith("fn:") and o[2][3:] in argn else o[2],
            o[3], o[4], o[5]) for o in out]
    return out


# ── Vergleich ────────────────────────────────────────────────────────────────

def compare(data):
    table = {}
    for lang in LANGS:
        for f in data[lang]["functions"]:
            k = canon_key(f, lang)
            table.setdefault(k, {})
            if lang in table[k]:      # doppelt (sollte nicht vorkommen)
                table[k].setdefault("_dup", []).append(lang)
                continue
            table[k][lang] = f
    diffs, equiv_hits, normlog, unknown = [], [], [], []

    def add(key, lang, art, detail, info=""):
        diffs.append({"key": key, "sprache": lang, "art": art, "detail": detail, "info": info})

    for key in sorted(table):
        ent = table[key]
        have = [l for l in LANGS if l in ent]
        for l in LANGS:
            if l not in ent:
                add(key, l, "fehlt", "fehlt in %s" % l, "vorhanden in " + ", ".join(have))
        if len(have) < 2:
            continue
        ref = "R" if "R" in ent else have[0]
        ra = norm_args(ent[ref], ref, log=normlog)
        r_dots = any(a[0] == "..." for a in ra)
        rnames = [a[0] for a in ra]
        rmap = {a[0]: a for a in ra}
        for l in have:
            if l == ref:
                continue
            pa = norm_args(ent[l], l, r_has_dots=r_dots, log=normlog)
            pnames = [a[0] for a in pa]
            pmap = {a[0]: a for a in pa}
            for n in rnames:
                if n not in pmap:
                    det = n
                    if n == "..." and ref == "R":
                        det = "... (in R genutzt)" if rmap[n][5] else "... (in R ungenutzt)"
                    add(key, l, "argument_fehlt", det, "in %s, nicht in %s" % (ref, l))
            for n in pnames:
                if n not in rmap:
                    add(key, l, "argument_extra", n, "in %s, nicht in %s" % (l, ref))
            common_r = [n for n in rnames if n in pmap]
            common_p = [n for n in pnames if n in rmap]
            if common_r != common_p:
                add(key, l, "reihenfolge", ", ".join(common_p), "%s: %s" % (ref, ", ".join(common_r)))
            if not ent[l].get("defaults_known", True) or not ent[ref].get("defaults_known", True):
                unknown.append((key, l, "*", "Standardwerte der Funktion nicht ermittelbar"))
                continue
            for n in common_r:
                if n == "...":
                    continue
                rv, pv = rmap[n], pmap[n]
                if not rv[4] or not pv[4]:
                    unknown.append((key, l if not pv[4] else ref, n, "Platzhalter %s" % (pv[1] if not pv[4] else rv[1])))
                    continue
                if rv[2] == pv[2]:
                    continue
                if rv[3] and first_of(rv[2]) == pv[2]:
                    equiv_hits.append((key, l, n, rv[1], pv[1]))
                    continue
                if rv[3] and l == "Julia" and pv[3] and pv[2] == "NULL":
                    equiv_hits.append((key, l, n, rv[1], pv[1]))
                    continue
                add(key, l, "standardwert", "%s: %s=%s | %s=%s" % (n, ref, rv[1], l, pv[1]))
    return table, diffs, equiv_hits, normlog, unknown


# ── Bekannte Abweichungen ────────────────────────────────────────────────────
KNOWN_COLS = ("schluessel", "sprache", "art", "detail", "status", "begruendung", "quelle")


def load_known(path):
    rows = []
    if not os.path.isfile(path):
        return rows
    with open(path, encoding="utf-8") as fh:
        hdr = None
        for ln, line in enumerate(fh, 1):
            line = line.rstrip("\n")
            if not line.strip() or line.startswith("#"):
                continue
            parts = line.split("\t")
            if hdr is None:
                hdr = parts
                miss = [c for c in KNOWN_COLS if c not in hdr]
                if miss:
                    sys.exit("%s: Kopfzeile ohne Spalten %s" % (path, ", ".join(miss)))
                continue
            r = dict(zip(hdr, parts + [""] * (len(hdr) - len(parts))))
            r["_line"] = ln
            r["_hits"] = 0
            if r["status"] not in ("bewusst", "unklar"):
                sys.exit("%s:%d: Status muss 'bewusst' oder 'unklar' sein, nicht %r" % (path, ln, r["status"]))
            rows.append(r)
    return rows


def match_known(d, rows):
    for r in rows:
        if (fnmatch.fnmatchcase(d["key"], r["schluessel"]) and fnmatch.fnmatchcase(d["sprache"], r["sprache"])
                and fnmatch.fnmatchcase(d["art"], r["art"]) and fnmatch.fnmatchcase(d["detail"], r["detail"] or "*")):
            r["_hits"] += 1
            return r
    return None


# ── Ausgabe ──────────────────────────────────────────────────────────────────

def fmt_args(f, lang):
    if f is None:
        return ""
    return ", ".join(a[0] if a[1] is None else "%s=%s" % (a[0], a[1]) for a in norm_args(f, lang))


def main():
    here = os.path.dirname(os.path.abspath(__file__))
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--dir", default=os.path.join(here, "out"))
    ap.add_argument("--known", default=os.path.join(here, "known_differences.tsv"))
    ap.add_argument("--out", default=os.path.join(here, "api.json"))
    ap.add_argument("--md", default=None, help="vollständige Liste der nicht erklärten Abweichungen als Markdown")
    ap.add_argument("--check", action="store_true", help="Rückgabewert 1 bei nicht erklärten Abweichungen")
    ap.add_argument("-v", "--verbose", action="store_true", help="auch bekannte (bewusste) Abweichungen zeigen")
    a = ap.parse_args()

    data = load(a.dir)
    table, diffs, equiv, normlog, unknown = compare(data)
    known = load_known(a.known)
    for d in diffs:
        r = match_known(d, known)
        d["status"] = r["status"] if r else "neu"
        d["begruendung"] = r["begruendung"] if r else ""
        d["known_line"] = r["_line"] if r else None

    # zusammengeführte Tabelle
    merged = []
    for key in sorted(table):
        ent = table[key]
        row = {"key": key}
        kinds = {ent[l]["kind"] for l in LANGS if l in ent}
        row["kind"] = "method" if "method" in kinds else "function"
        for l in LANGS:
            f = ent.get(l)
            row[l] = None if f is None else {k: f.get(k) for k in
                                             ("name", "kind", "generic", "class", "module", "file", "line", "args",
                                              "defaults_known", "args_source", "note", "py_class") if k in f}
        row["abweichungen"] = [{k: d[k] for k in ("sprache", "art", "detail", "info", "status")}
                               for d in diffs if d["key"] == key]
        merged.append(row)
    counts = {l: {"functions": sum(1 for f in data[l]["functions"] if f["kind"] == "function"),
                  "methods": sum(1 for f in data[l]["functions"] if f["kind"] == "method"),
                  "classes": len(data[l].get("classes") or [])} for l in LANGS}
    out = {
        "generated": _dt.date.today().isoformat(),  # nur Datum, damit api.json bei gleichem Stand stabil bleibt
        "tool": "tools/api_snapshot/compare_api.py",
        "sources": {l: {k: data[l].get(k) for k in ("source", "tool")} for l in LANGS},
        "counts": counts,
        "equivalences": [dict(zip(("norm", "R", "Python", "Julia"), r)) for r in EQUIV_TABLE],
        "match_arg_equal": [dict(zip(("key", "sprache", "arg", "R", "port"), e)) for e in equiv],
        "normalisiert": sorted(set(normlog)),
        "standardwert_nicht_ermittelbar": [dict(zip(("key", "sprache", "arg", "grund"), u)) for u in unknown],
        "classes": {l: data[l].get("classes") or [] for l in LANGS},
        "other": {l: data[l].get("other") or [] for l in LANGS},
        "functions": merged,
    }
    with open(a.out, "w", encoding="utf-8") as fh:
        json.dump(out, fh, ensure_ascii=False, indent=1)
        fh.write("\n")

    new = [d for d in diffs if d["status"] == "neu"]
    unclear = [d for d in diffs if d["status"] == "unklar"]
    okd = [d for d in diffs if d["status"] == "bewusst"]
    stale = [r for r in known if r["_hits"] == 0]

    P = print
    P("Schnittstellen-Abgleich SimLev (R / Python / Julia)")
    P("=" * 52)
    for l in LANGS:
        c = counts[l]
        P("  %-7s %3d Funktionen, %3d Methoden  (Typen/Klassen: %d)" % (l, c["functions"], c["methods"], c["classes"]))
    P("  Zuordnungen gesamt: %d Schlüssel" % len(table))
    P("  Abweichungen: %d gesamt, %d bewusst (known_differences.tsv), %d unklar, %d neu"
      % (len(diffs), len(okd), len(unclear), len(new)))
    P("  Gleichgesetzt über match.arg (R-Auswahl; Port erstes Element bzw. Julia nothing): %d" % len(equiv))
    P("  Namensregeln angewandt (Schlüsselwort-Namen, Julia-Aliasse): %d" % len(set(normlog)))
    P("  Standardwert nicht verglichen (Platzhalter/nicht ermittelbar): %d" % len(unknown))
    by_art = {}
    for d in new + unclear:
        by_art[d["art"]] = by_art.get(d["art"], 0) + 1
    if by_art:
        P("  Nicht erklärt nach Art: " + ", ".join("%s %d" % kv for kv in sorted(by_art.items())))

    def show(lst, title):
        if not lst:
            return
        P("")
        P(title)
        P("-" * len(title))
        last = None
        for d in sorted(lst, key=lambda d: (d["key"], d["sprache"], d["art"], d["detail"])):
            if d["key"] != last:
                P("  %s" % d["key"])
                last = d["key"]
            P("    [%s] %-15s %s%s" % (d["sprache"], d["art"], d["detail"], ("  (" + d["info"] + ")") if d["info"] else ""))
    show(new, "Neue (nicht in known_differences.tsv)")
    show(unclear, "Unklar (in known_differences.tsv als 'unklar')")
    if a.verbose:
        show(okd, "Bewusst (known_differences.tsv)")
    if stale:
        P("")
        P("Einträge in known_differences.tsv ohne Treffer (veraltet?):")
        for r in stale:
            P("  Zeile %d: %s %s %s %s" % (r["_line"], r["schluessel"], r["sprache"], r["art"], r["detail"]))
    P("")
    P("api.json: %s" % os.path.relpath(a.out))

    if a.md:
        with open(a.md, "w", encoding="utf-8") as fh:
            fh.write("# Nicht erklärte Abweichungen der Schnittstelle\n\n")
            fh.write("Erzeugt von `tools/api_snapshot/compare_api.py` am %s. "
                     "Bezug: R (maßgeblich); fehlt R, ist Python der Bezug.\n\n" % out["generated"])
            fh.write("| Funktionen | R | Python | Julia |\n|---|---|---|---|\n")
            fh.write("| Funktionen | %s |\n| Methoden | %s |\n\n" % (
                " | ".join(str(counts[l]["functions"]) for l in LANGS),
                " | ".join(str(counts[l]["methods"]) for l in LANGS)))
            fh.write("Abweichungen gesamt %d: bewusst %d, unklar %d, neu %d.\n\n" % (len(diffs), len(okd), len(unclear), len(new)))
            for title, lst in (("Neu (nicht in known_differences.tsv)", new), ("Unklar", unclear)):
                fh.write("## %s (%d)\n\n" % (title, len(lst)))
                if not lst:
                    fh.write("keine\n\n")
                    continue
                fh.write("| Schlüssel | Sprache | Art | Detail | Info | Begründung |\n|---|---|---|---|---|---|\n")
                for d in sorted(lst, key=lambda d: (d["key"], d["sprache"], d["art"], d["detail"])):
                    fh.write("| `%s` | %s | %s | `%s` | %s | %s |\n" % (
                        d["key"], d["sprache"], d["art"], d["detail"].replace("|", "\\|"),
                        d["info"].replace("|", "\\|"), d["begruendung"].replace("|", "\\|")))
                fh.write("\n")
            fh.write("## Bewusst (%d)\n\n" % len(okd))
            fh.write("| Schlüssel | Sprache | Art | Detail | Begründung |\n|---|---|---|---|---|\n")
            for d in sorted(okd, key=lambda d: (d["key"], d["sprache"], d["art"], d["detail"])):
                fh.write("| `%s` | %s | %s | `%s` | %s |\n" % (d["key"], d["sprache"], d["art"],
                                                           d["detail"].replace("|", "\\|"), d["begruendung"].replace("|", "\\|")))
            fh.write("\n## Standardwert nicht verglichen (%d)\n\n" % len(unknown))
            fh.write("Platzhalter für R's `missing()` (Julia `_UNSET`/`_MISSING`, Python `_MISSING`): "
                     "der wirksame Wert entsteht erst im Rumpf.\n\n")
            for u in unknown:
                fh.write("- `%s` [%s] `%s`: %s\n" % u)
            fh.write("\n## Gleichgesetzt über match.arg (%d)\n\n" % len(equiv))
            for e in equiv:
                fh.write("- `%s` [%s] `%s`: R `%s`, Port `%s`\n" % e)
    return 1 if (a.check and (new or unclear)) else 0


if __name__ == "__main__":
    sys.exit(main())
