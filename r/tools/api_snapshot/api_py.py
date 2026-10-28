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

Voreinstellung der Ausgabe: tools/api_snapshot/out/api_py.json
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
    out = sys.argv[1] if len(sys.argv) > 1 else os.path.join(ROOT, "tools", "api_snapshot", "out", "api_py.json")
    os.makedirs(os.path.dirname(out), exist_ok=True)
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


if __name__ == "__main__":
    main()
