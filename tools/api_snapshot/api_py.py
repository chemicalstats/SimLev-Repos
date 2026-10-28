#!/usr/bin/env python3
"""Schnittstellen-Auszug der Python-Fassung (Etappe 3, tools/api_snapshot).

Liest alle Namen in ``simlev.__all__`` und die öffentlichen Methoden der
Ergebnisklassen, die den R-S3-Methoden entsprechen. Nach
``python/DEVELOPING.md`` (Abschnitt „Datenstrukturen“) gilt:

- Jede Ergebnisklasse trägt in ``r_class`` den R-Klassenvektor.
- ``summary()`` ist eine Methode ``x.summary()``, ``plot`` ebenso
  (``Klasse.plot = _plot_method(...)``).
- ``print`` druckt über ``format()``/``__str__``; manche Klassen haben dazu
  eine eigene Methode ``x.print()``.

Gegenstück von R ``print.<Klasse>`` ist deshalb ``<Klasse>.print`` (falls
vorhanden), sonst ``<Klasse>.format`` (vermerkt in ``via``).

Je Funktion über ``inspect.signature``: Name, Art (positional_only,
positional_or_keyword, keyword_only, var_positional, var_keyword) und
Standardwert als Text (``repr``; die internen Platzhalter ``_Default``,
``_Dflt``, ``_DfltTrue`` zeigen den Wert, ``_MISSING`` heißt „kein Wert“).
Dazu Modul, Datei und Zeile.

Aufruf aus der Repo-Wurzel::

    LC_ALL=C.UTF-8 python3 tools/api_snapshot/api_py.py [ausgabe.json]
        [--frozen-out datei --stand text] [--frozen-check datei]

Voreinstellung der Ausgabe: tools/api_snapshot/out/api_py.json

``--frozen-out`` schreibt zusätzlich den eingefrorenen Stand (ohne Modul,
Datei, Zeile, Datum; sortiert), ``--stand`` ist die Überschrift des Eintrags
in ``CHANGES.md``. ``--frozen-check`` vergleicht den Auszug mit dem
eingefrorenen Stand und listet die Unterschiede (Rückgabewert 1);
``python/tests/test_api_frozen.py`` und ``run.sh --check`` rufen das auf.
"""
from __future__ import annotations

import datetime as _dt
import inspect
import json
import os
import sys

ROOT = os.getcwd()
if not os.path.isfile(os.path.join(ROOT, "python", "simlev", "__init__.py")):
    sys.exit("Bitte aus der Repo-Wurzel aufrufen (python/simlev fehlt).")
sys.path.insert(0, os.path.join(ROOT, "python"))

import simlev  # noqa: E402

GENERICS = ("print", "summary", "plot")

# Klassen ohne Attribut r_class, deren R-Klasse python/DEVELOPING.md nennt
# (Tabelle „Abbildung der Engine-Objekte“: SimLevTaxTariff ↔ SimLevTaxTariff).
DOC_CLASS_MAP = {"SimLevTaxTariff": "SimLevTaxTariff"}


def _r_classes(cls):
    rc = getattr(cls, "r_class", None)
    if isinstance(rc, (tuple, list)) and rc:
        return list(rc), None
    if cls.__name__ in DOC_CLASS_MAP:
        return [DOC_CLASS_MAP[cls.__name__]], "R-Klasse aus python/DEVELOPING.md (kein r_class)"
    return [], None


def _rel(path):
    if not path:
        return None
    p = os.path.realpath(path)
    r = os.path.realpath(ROOT) + os.sep
    return p[len(r):] if p.startswith(r) else p


def _default_text(v):
    """Standardwert als Text; die Platzhalter der Ports zeigen ihren Wert."""
    tn = type(v).__name__
    if tn == "_Default":
        return _default_text(v.value)
    if tn == "_Missing":
        return None
    if tn in ("_Dflt",):
        return repr(float(v))
    if tn == "_DfltTrue":
        return "True"
    if isinstance(v, float) and v != v:
        from simlev._r.rnum import r_isna
        return "NA" if r_isna(v) else "nan"
    if inspect.isfunction(v) or inspect.isbuiltin(v):
        return "<function %s>" % getattr(v, "__name__", "?")
    return repr(v)


def _args(fn, drop_self=False):
    sig = inspect.signature(fn)
    out = []
    for i, p in enumerate(sig.parameters.values()):
        if drop_self and i == 0:
            continue
        has = p.default is not inspect.Parameter.empty
        txt = _default_text(p.default) if has else None
        a = {"name": p.name, "kind": p.kind.name.lower(), "has_default": has, "default": txt}
        if has and txt is None:   # _MISSING: Platzhalter für R's missing(), Wert entsteht im Rumpf
            a["default"] = "_MISSING"
            a["default_known"] = False
            a["default_note"] = "Platzhalter _MISSING (R missing()); Wert entsteht im Rumpf"
        out.append(a)
    return out


def _where(obj):
    tgt = inspect.unwrap(obj)
    # _plot_method: die Zeichenfunktion steht in method._plot_method
    pm = getattr(obj, "_plot_method", None)
    if isinstance(pm, tuple):
        tgt = pm[0]
    try:
        f = inspect.getsourcefile(tgt)
    except TypeError:
        f = None
    try:
        line = inspect.getsourcelines(tgt)[1]
    except (OSError, TypeError):
        line = None
    return getattr(tgt, "__module__", None), _rel(f), line


def main():
    import argparse
    ap = argparse.ArgumentParser(description="Schnittstellen-Auszug der Python-Fassung")
    ap.add_argument("out", nargs="?", default=os.path.join(ROOT, "tools", "api_snapshot", "out", "api_py.json"))
    ap.add_argument("--frozen-out")
    ap.add_argument("--frozen-check")
    ap.add_argument("--stand")
    opt = ap.parse_args()
    out = opt.out
    os.makedirs(os.path.dirname(os.path.abspath(out)), exist_ok=True)
    funcs, classes, other = [], [], []
    for name in simlev.__all__:
        obj = getattr(simlev, name)
        if inspect.isclass(obj):
            mod, f, line = _where(obj)
            rc = _r_classes(obj)[0]
            classes.append({"name": name, "r_class": rc, "module": mod, "file": f, "line": line,
                            "bases": [b.__name__ for b in obj.__mro__[1:-1]]})
            continue
        if not callable(obj):
            other.append({"name": name, "type": type(obj).__name__, "repr": repr(obj)})
            continue
        note = None
        if inspect.ismodule(obj):
            # _callable_module (simlev/__init__.py): Modul, das die gleichnamige Funktion aufruft
            obj = getattr(obj, name)
            note = "Modul und aufrufbare Funktion (_callable_module)"
        mod, f, line = _where(obj)
        try:
            args = _args(obj)
        except (TypeError, ValueError) as e:
            args, note = [], "Signatur nicht lesbar: %s" % e
        funcs.append({"name": name, "key": name, "kind": "function", "generic": None, "class": None,
                      "module": mod, "file": f, "line": line, "args": args, "defaults_known": True, "note": note})

    # Methoden der Ergebnisklassen: alle Klassen der Module mit r_class, auch solche,
    # die nicht in __all__ stehen (z. B. Rückgabeklassen, die nur intern benannt sind).
    seen = set()
    for modname, mod in sorted(sys.modules.items()):
        if not (modname == "simlev" or modname.startswith("simlev.")) or modname.startswith("simlev._r"):
            continue
        for cname, cls in sorted(vars(mod).items()):
            if not inspect.isclass(cls) or cls in seen:
                continue
            rcs, cnote = _r_classes(cls)
            if not rcs:
                continue
            if not cls.__module__.startswith("simlev"):
                continue
            seen.add(cls)
            for rc in rcs[:1]:
                for g in GENERICS:
                    meth, via = None, None
                    if g in vars(cls) or any(g in vars(b) for b in cls.__mro__[1:] if b.__module__.startswith("simlev")
                                             and b.__name__ != "RList"):
                        meth, via = getattr(cls, g), "%s.%s" % (cls.__name__, g)
                    elif g == "print" and callable(getattr(cls, "format", None)) \
                            and getattr(cls, "format") is not simlev._r.rlist.RList.format:
                        meth, via = cls.format, "%s.format (print über __str__)" % cls.__name__
                    if meth is None:
                        continue
                    m_mod, f, line = _where(meth)
                    try:
                        args = _args(meth)
                    except (TypeError, ValueError) as e:
                        args = []
                    funcs.append({"name": via.split(" ")[0], "key": "%s.%s" % (g, rc), "kind": "method",
                                  "generic": g, "class": rc, "py_class": cls.__name__, "module": cls.__module__,
                                  "file": f, "line": line, "args": args, "defaults_known": True,
                                  "note": "; ".join(x for x in (None if " " not in via else via.split(" ", 1)[1].strip("()"),
                                                               cnote) if x) or None})
    res = {
        "language": "Python",
        "source": "simlev.__all__, Klassen mit r_class",
        "generated": _dt.datetime.now().astimezone().strftime("%Y-%m-%d %H:%M:%S %Z"),
        "tool": "tools/api_snapshot/api_py.py",
        "notes": ["Standardwerte: repr(); Platzhalter _Default/_Dflt zeigen ihren Wert.",
                  "Methoden: erstes Argument ist self (entspricht R x/object)."],
        "functions": funcs,
        "classes": classes,
        "other": other,
    }
    with open(out, "w", encoding="utf-8") as fh:
        json.dump(res, fh, ensure_ascii=False, indent=1)
    nf = sum(1 for f in funcs if f["kind"] == "function")
    print("Python: %d Funktionen, %d Methoden, %d Klassen, %d sonstige -> %s"
          % (nf, len(funcs) - nf, len(classes), len(other), out))
    status = 0
    if opt.frozen_out or opt.frozen_check:
        fz = frozen_of(res)
        if opt.frozen_out:
            if opt.stand is None:
                sys.exit("--frozen-out braucht --stand (Überschrift des Eintrags in CHANGES.md)")
            os.makedirs(os.path.dirname(os.path.abspath(opt.frozen_out)), exist_ok=True)
            with open(opt.frozen_out, "w", encoding="utf-8") as fh:
                fh.write(frozen_text(fz, "Python", opt.stand))
            print("Python: eingefrorener Stand -> %s" % opt.frozen_out)
        if opt.frozen_check:
            ok, text = frozen_check(fz, opt.frozen_check, "Python")
            print(text)
            status = 0 if ok else 1
    return status


# ── Eingefrorener Stand (tools/api_snapshot/frozen/py.json) ─────────────────
# Je Funktion bzw. Methode die Argumente in Reihenfolge: Name, Art, Standardwert
# (Text; null = keiner), default_known = false bei Platzhaltern; dazu die Namen
# der exportierten Klassen und sonstigen Exporte. Ohne Modul, Datei, Zeile,
# Datum und Vermerke; Schlüssel sortiert, ein Argument je Zeile.
FROZEN_HINT = "Erzeugt von tools/api_snapshot/run.sh --freeze (mit Eintrag in CHANGES.md); nicht von Hand ändern."
FROZEN_FIELDS = ("name", "kind", "default", "value", "match_arg", "default_known")
FREEZE_HOWTO = (
    "Ist die Änderung gewollt, den Stand bewusst neu festschreiben:\n"
    "  1. Eintrag oben in tools/api_snapshot/CHANGES.md: \"## JJJJ-MM-TT – Titel\" mit \"- Was: …\" und \"- Warum: …\"\n"
    "  2. tools/api_snapshot/run.sh --freeze   (aus der Repo-Wurzel; schreibt frozen/ für R, Python und Julia neu)\n"
    "  3. frozen/ und CHANGES.md zusammen einchecken.\n"
    "Sonst die Änderung im Code zurücknehmen.")


def frozen_of(res):
    def one(a):
        r = {"name": a["name"], "kind": a["kind"], "default": a["default"] if a["has_default"] else None}
        if a.get("default_value") is not None:
            r["value"] = a["default_value"]
        if a.get("match_arg"):
            r["match_arg"] = True
        if a.get("default_known") is False:
            r["default_known"] = False
        return r

    def sect(kind):
        fs = sorted((f for f in res["functions"] if f["kind"] == kind), key=lambda f: f["key"])
        return {f["key"]: [one(a) for a in f["args"]] for f in fs}

    return {"functions": sect("function"), "methods": sect("method"),
            "classes": sorted(c["name"] for c in res.get("classes", [])),
            "other": sorted(o["name"] for o in res.get("other", []))}


def _j(x):
    return json.dumps(x, ensure_ascii=False)


def _j1(d):
    return "{" + ", ".join("%s: %s" % (_j(k), _j(v)) for k, v in d.items()) + "}"


def frozen_text(fz, lang, stand):
    L = ["{", ' "language": %s,' % _j(lang), ' "stand": %s,' % _j(stand), ' "hinweis": %s,' % _j(FROZEN_HINT)]
    secs = ("functions", "methods", "classes", "other")
    for s in secs:
        end = "" if s == secs[-1] else ","
        v = fz[s]
        if not v:
            L.append(" %s: %s%s" % (_j(s), "[]" if s in ("classes", "other") else "{}", end))
            continue
        if s in ("classes", "other"):
            L.append(" %s: [" % _j(s))
            L += ["  " + _j(x) + ("," if i < len(v) - 1 else "") for i, x in enumerate(v)]
            L.append(" ]" + end)
            continue
        L.append(" %s: {" % _j(s))
        keys = list(v)
        for i, k in enumerate(keys):
            e = "," if i < len(keys) - 1 else ""
            a = v[k]
            if not a:
                L.append("  %s: []%s" % (_j(k), e))
                continue
            L.append("  %s: [" % _j(k))
            L += ["   " + _j1(x) + ("," if j < len(a) - 1 else "") for j, x in enumerate(a)]
            L.append("  ]" + e)
        L.append(" }" + end)
    L.append("}")
    return "\n".join(L) + "\n"


def frozen_diff(old, new):
    """Unterschiede alt (eingefroren) -> neu (heute), als lesbare Zeilen."""
    msg = []

    def shown(a):
        return "(keiner)" if a.get("default") is None else a["default"]

    def sig(args):
        return ", ".join(a["name"] if a.get("default") is None else "%s = %s" % (a["name"], a["default"]) for a in args)

    for s, what in (("functions", "Funktion"), ("methods", "Methode")):
        o, n = old.get(s, {}), new.get(s, {})
        msg += ["%s weg: %s" % (what, k) for k in o if k not in n]
        msg += ["%s neu: %s(%s)" % (what, k, sig(n[k])) for k in n if k not in o]
        for k in (k for k in o if k in n):
            oa, na = o[k], n[k]
            on, nn = [a["name"] for a in oa], [a["name"] for a in na]
            msg += ["%s: Argument weg: %s" % (k, x) for x in on if x not in nn]
            msg += ["%s: Argument neu: %s (Stelle %d, Standardwert %s)" % (k, x, nn.index(x) + 1, shown(na[nn.index(x)]))
                    for x in nn if x not in on]
            co, cn = [x for x in on if x in nn], [x for x in nn if x in on]
            if co != cn:
                msg.append("%s: Argumente umsortiert: vorher %s; jetzt %s" % (k, ", ".join(co), ", ".join(cn)))
            for x in co:
                a, b = oa[on.index(x)], na[nn.index(x)]
                if a.get("kind") != b.get("kind"):
                    msg.append("%s: Art von %s geändert: %s -> %s" % (k, x, a.get("kind"), b.get("kind")))
                if a.get("default") != b.get("default"):
                    msg.append("%s: Standardwert von %s geändert: %s -> %s" % (k, x, shown(a), shown(b)))
                for f in FROZEN_FIELDS[3:]:
                    if a.get(f) != b.get(f):
                        msg.append("%s: Standardwert von %s geändert (%s): %s -> %s" % (
                            k, x, f, "(keiner)" if a.get(f) is None else a.get(f),
                            "(keiner)" if b.get(f) is None else b.get(f)))
    for s, what in (("classes", "Klasse"), ("other", "sonstiger Export")):
        o, n = old.get(s, []), new.get(s, [])
        msg += ["%s weg: %s" % (what, k) for k in o if k not in n]
        msg += ["%s neu: %s" % (what, k) for k in n if k not in o]
    return msg


def frozen_check(fz, path, lang="Python"):
    """(gleich?, Bericht) für den Auszug `fz` gegen die Datei `path`."""
    if not os.path.isfile(path):
        return False, "%s: eingefrorener Stand %s fehlt; anlegen mit tools/api_snapshot/run.sh --freeze" % (lang, path)
    with open(path, encoding="utf-8") as fh:
        old = json.load(fh)
    new = json.loads(frozen_text(fz, lang, old.get("stand")))
    d = frozen_diff(old, new)
    if d:
        return False, ("%s: Schnittstelle weicht vom eingefrorenen Stand ab (%s, Stand \"%s\"), %d Unterschied(e):\n"
                       % (lang, path, old.get("stand"), len(d))
                       + "".join("  - %s\n" % x for x in d) + FREEZE_HOWTO)
    return True, ("%s: Schnittstelle entspricht dem eingefrorenen Stand (%s; %d Funktionen, %d Methoden)"
                  % (lang, old.get("stand"), len(new["functions"]), len(new["methods"])))


if __name__ == "__main__":
    sys.exit(main())
