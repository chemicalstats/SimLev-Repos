"""Referenzfälle aus R (Katalog nach Zweck): Lesen der Dateien und Vergleich mit Python.

Eine Datei ``tests/<gruppe>/faelle/<bereich>.jsonl.gz`` (Gruppen gleichlauf, fehler, ausgabe; erzeugt mit
``tests/gleichlauf/erzeugen/<bereich>.R``, Format in ``tests/gleichlauf/erzeugen/ref_tools.R``) hat in Zeile 1 den
Eingabespeicher, danach je Zeile einen Test: ein Szenario (Fall) oder eine Tabelle (Feld ``tabelle``, je Zeile ein
eigener Aufruf; Abweichungen nennen die Zeile). Die Zufallsprüfung der Engine (``tests/werkzeuge/zufall``) nutzt
daneben das Engine-Format:

* Modulformat (Feld ``module``): Eingaben, R-, Python- und Julia-Code, R-Ergebnis als Baum; Vergleich mit
  ``reftree.run_case`` (tests/lib) (Ergebnis, Konsolen- und Druckausgabe, Warnungen, Fehlermeldung).
* Engine-Format (ohne ``module``; Bereich engine, aus ``engine_faelle.R`` und ``engine_stress.R``): Daten,
  Strategie, Bausteine von ``simulation()`` und die exakten R-Ergebnisse; Vergleich mit :func:`run_engine`
  (``worth``, ``drawdowns``, ``filled``, ``cagr``, ``ttwror``, ``statistics``, ``tax_report``, ``buys``,
  ``sells``, ``report``, Druckausgabe und ``details``-Ausgabe; Fehlerfälle müssen auch in Python abbrechen).

Strikt: NA und NaN getrennt (``SIMLEV_LAX_NA=1``: NA = NaN), Vorzeichen der Null.
"""
from __future__ import annotations

import contextlib
import gzip
import io
import json
import os
import warnings

import numpy as np
import pandas as pd

import simlev
from simlev._r import env as _env
from reftree import run_case as _run_ref_case

ROOT = os.path.normpath(os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", ".."))
GRUPPEN = ("gleichlauf", "fehler", "ausgabe")


def faelle_dir(gruppe):
    """Ordner der Dateien einer Gruppe: ``tests/<gruppe>/faelle`` bzw. ``$SIMLEV_FAELLE_DIR/<gruppe>``."""
    d = os.environ.get("SIMLEV_FAELLE_DIR")
    return os.path.join(d, gruppe) if d else os.path.join(ROOT, "tests", gruppe, "faelle")


def bereiche(d):
    """Pfade der Bereichsdateien in ``d`` (sortiert)."""
    if not os.path.isdir(d):
        return []
    return [os.path.join(d, f) for f in sorted(os.listdir(d)) if f.endswith(".jsonl.gz")]


def lies_bereich(path):
    """Kopf (mit Eingabespeicher) und Fälle einer Bereichsdatei; Verweise auf den Speicher bleiben."""
    with gzip.open(path, "rt", encoding="utf-8") as fh:
        head = json.loads(fh.readline())
        cases = [json.loads(ln) for ln in fh if ln.strip()]
    return head, cases


def kennung(case):
    """``<modul>/<id>``; Engine-Format: ``cases/<id>`` (f…, r…) bzw. ``extra/<id>`` (x…, y…)."""
    if "module" in case:
        return "%s/%s" % (case["module"], case["id"])
    return ("cases/" if case["id"][0] in "fr" else "extra/") + case["id"]


def aufloesen(case, store):
    """Eingaben ``{"t": "ref", "k": …}`` durch die Bäume aus dem Eingabespeicher ersetzen (Kopie)."""
    inp = case.get("inputs")
    if not isinstance(inp, dict):
        return case
    out = dict(case)
    out["inputs"] = {k: (store[v["k"]] if isinstance(v, dict) and v.get("t") == "ref" else v) for k, v in inp.items()}
    return out


def zeilen(case, store):
    """Zeilen einer Tabelle als eigene Fälle: Kennung ``<id>/<z>``, gemeinsame und eigene Eingaben aufgelöst."""
    gemein = aufloesen(case, store).get("inputs") or {}
    for row in case["tabelle"]:
        rc = dict(row, id="%s/%s" % (case["id"], row["z"]), module=case.get("module"))
        rc["inputs"] = dict(gemein, **(aufloesen(row, store).get("inputs") or {}))
        yield rc


_INDEX = {}


def fall(key):
    """Fall bzw. Tabellenzeile ``<modul>/<id>`` aus dem Katalog (alle Gruppen), Eingaben aufgelöst (Grafiktests);
    Zeilen der Tabellen und Teile der Szenarien (Feld ``_teil``: Ergebnis ``result[_teil]``) tragen die bisherige
    Fallkennung als Namen."""
    if not _INDEX:
        for g in GRUPPEN:
            for p in bereiche(faelle_dir(g)):
                head, cases = lies_bereich(p)
                for c in cases:
                    if "tabelle" in c:
                        for rc in zeilen(c, head["inputs"]):
                            _INDEX.setdefault("%s/%s" % (c["module"], rc["z"]), (rc, None))
                    for t in ([c["teile"]] if isinstance(c.get("teile"), str) else c.get("teile") or []):
                        _INDEX.setdefault("%s/%s" % (c["module"], t), (dict(c, _teil=t), head["inputs"]))
                    _INDEX.setdefault(kennung(c), (c, head["inputs"]))
    c, store = _INDEX[key]
    return c if store is None else aufloesen(c, store)


def pruefe(case, store, verbose=False):
    """Einen Fall in Python nachrechnen; Liste der Abweichungen (leer = bitgleich).

    Tabelle (Feld ``tabelle``): jede Zeile ein eigener Aufruf mit den gemeinsamen Eingaben; Abweichungen
    nennen die Zeile (``Zeile <z>: …``).
    """
    if "tabelle" in case:
        errs = []
        for rc in zeilen(case, store):
            errs += ["Zeile %s: %s" % (rc["z"], e) for e in _run_ref_case(rc)]
        return errs
    if "module" in case:
        return _run_ref_case(aufloesen(case, store))
    return run_engine(case, verbose=verbose)


_NA_REAL = np.array([0x7FF00000000007A2], dtype=np.uint64).view(np.float64)[0]
STRICT_NA = not _env.lax_na()   # NA und NaN unterscheiden wie R (SIMLEV_LAX_NA=1: NA = NaN)


def _isna_arr(a):
    a = np.ascontiguousarray(a, dtype=np.float64)
    return np.isnan(a) & ((a.view(np.uint64) & np.uint64(0xFFFFFFFF)) == np.uint64(1954))


def unhex(v):
    if v is None or v == "NA":
        return float(_NA_REAL)
    if v == "NaN":
        return float("nan")
    if isinstance(v, (int, float)):
        return float(v)
    return float.fromhex(v)


def load_case(d):
    """Engine-Fall (Engine-Format, dict) → (Fall, Daten, Strategie, Argumente)."""
    cols = {}
    for nm in d["data"]["order"]:
        c = d["data"]["cols"][nm]
        vals = c["values"]
        if not isinstance(vals, list):
            vals = [vals]
        if c["type"] == "date":
            cols[nm] = np.array(vals, dtype="int64").astype("datetime64[D]")
        elif c["type"] == "logical":
            cols[nm] = np.array(vals, dtype=object)
            if all(v is not None for v in vals):
                cols[nm] = np.array(vals, dtype=bool)
        else:
            cols[nm] = np.array([unhex(v) for v in vals], dtype=np.float64)
    df = pd.DataFrame(cols)
    strategy = {}
    for nm, a in d["strategy"].items():
        strategy[nm] = {k: (unhex(v["hex"]) if isinstance(v, dict) and "hex" in v else v) for k, v in a.items()}
    args = dict(d["args"])
    return d, df, strategy, args


def _block(v):
    """Baustein aus dem Fall (``{"block": <Konstruktor>, "args": {...}}``) anlegen."""
    if isinstance(v, dict) and "block" in v and "args" in v:
        return getattr(simlev, v["block"])(**{k: _block(x) for k, x in v["args"].items()})
    return v


def cmp_vec(name, ref, got, errs):
    ref = np.array([unhex(v) for v in (ref if isinstance(ref, list) else [ref])], dtype=np.float64)
    got = np.asarray(got, dtype=np.float64).ravel()
    if ref.size != got.size:
        errs.append("%s: Länge %d vs %d" % (name, ref.size, got.size))
        return
    same = (ref == got) & (np.signbit(ref) == np.signbit(got))      # Vorzeichen der Null mitprüfen
    both_nan = np.isnan(ref) & np.isnan(got)
    if STRICT_NA:
        both_nan &= _isna_arr(ref) == _isna_arr(got)
    bad = np.flatnonzero(~(same | both_nan))
    if bad.size:
        i = bad[0]
        errs.append("%s: %d Abweichungen, erste bei %d: R=%r Py=%r" % (name, bad.size, i, ref[i], got[i]))


def run_engine(d, verbose=False):
    """Engine-Fall (dict) in Python nachrechnen; Liste der Abweichungen (leer = bitgleich)."""
    d, df, strategy, args = load_case(d)
    buf = io.StringIO()
    with warnings.catch_warnings():
        warnings.simplefilter("ignore")
        try:
            with contextlib.redirect_stdout(buf), contextlib.redirect_stderr(io.StringIO()):
                res = simlev.simulation(df, strategy, **{k: _block(v) for k, v in args.items()})
        except Exception as exc:  # noqa: BLE001
            if "error" in d:
                return []
            import traceback
            return ["Python-Fehler: %r\n%s" % (exc, traceback.format_exc() if verbose else "")]
    if "error" in d:
        return ["R-Fehler, Python lief durch: %s" % d["error"]]
    r = d["result"]
    errs: list[str] = []
    cmp_vec("worth", r["worth"], res.worth, errs)
    cmp_vec("drawdowns", r["drawdowns"], res.drawdowns, errs)
    filled_ref = np.array(r["filled"] if isinstance(r["filled"], list) else [r["filled"]], dtype=bool)
    if not np.array_equal(filled_ref, res.filled):
        errs.append("filled unterschiedlich")
    cmp_vec("cagr", r["cagr"], res.cagr, errs)
    cmp_vec("ttwror", r["ttwror"], res.ttwror, errs)
    for k, v in r["statistics"].items():
        cmp_vec("stat." + k, v, res.statistics[k], errs)
    for k, v in r["tax_report"].items():
        got = res.tax_report.get(k)
        if isinstance(got, dict):          # next_year (neuere Fälle): Werte in R-Reihenfolge
            got = [float(x) for x in got.values()]
        elif isinstance(got, pd.DataFrame):  # tariff_years: nicht im Golden-Format
            continue
        cmp_vec("tax." + k, v, got, errs)
    for k, v in r["buys"].items():
        cmp_vec("buys." + k, v, res.buys[k], errs)
    for k, v in r["sells"].items():
        cmp_vec("sells." + k, v, res.sells[k], errs)
    for a, fields in r["report"].items():
        for f, v in fields.items():
            cmp_vec("report.%s.%s" % (a, f), v, res.report[a][f], errs)
    if "stdout" in d:
        got = buf.getvalue()
        if got.endswith("\n"):
            got = got[:-1]
        if got != d["stdout"]:
            errs.append("details-Ausgabe unterscheidet sich")
            if verbose:
                import difflib
                errs.append("\n".join(list(difflib.unified_diff(d["stdout"].splitlines(), got.splitlines(),
                                                                 lineterm="", n=1))[:60]))
    if res.format() != r["print"]:
        errs.append("print()-Ausgabe unterscheidet sich")
        if verbose:
            import difflib
            errs.append("\n".join(difflib.unified_diff(r["print"].splitlines(), res.format().splitlines(),
                                                       lineterm="")))
    return errs


def katalog(gruppe):
    """Tests einer Gruppe für pytest: Liste (Kennung ``<bereich>/<modul>/<id>``, Test, Eingabespeicher)."""
    out = []
    for p in bereiche(faelle_dir(gruppe)):
        b = os.path.basename(p)[: -len(".jsonl.gz")]
        head, cases = lies_bereich(p)
        out += [("%s/%s" % (b, kennung(c)), c, head["inputs"]) for c in cases]
    return out
