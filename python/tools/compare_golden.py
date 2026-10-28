"""Vergleicht die Python-Engine bitgenau mit Golden-Master-Ergebnissen aus R.

Aufruf::

    python compare_golden.py [<ordner_oder_datei> ...] [-k fall ...] [-v]

Ohne Pfad werden ``golden/cases`` und ``golden/extra`` geprüft. Gelesen werden
``.json.gz`` und ``.json``. Verglichen werden ``worth``, ``drawdowns``, ``filled``,
``cagr``, ``ttwror``, ``statistics``, ``tax_report``, ``buys``, ``sells``, ``report``,
die Druckausgabe (``print``) und – bei ``details = TRUE`` – die Konsolenausgabe
(``stdout``). Fehlerfälle (``error``) müssen auch in Python einen Fehler auslösen.
"""
from __future__ import annotations

import argparse
import contextlib
import gzip
import io
import json
import math
import os
import sys
import warnings

import numpy as np
import pandas as pd

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, ".."))
import simlev  # noqa: E402
from simlev._r import env as _env  # noqa: E402

ROOT = os.path.abspath(os.path.join(HERE, "..", ".."))
DEFAULT_DIRS = [os.path.join(ROOT, "golden", "cases"), os.path.join(ROOT, "golden", "extra")]


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


def read_json(path):
    if path.endswith(".gz"):
        with gzip.open(path, "rt", encoding="utf-8") as fh:
            return json.load(fh)
    with open(path, encoding="utf-8") as fh:
        return json.load(fh)


def load_case(path):
    d = read_json(path)
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
    """Baustein aus dem Fall (``{"block": <Konstruktor>, "args": {...}}``, Etappe 6.3) anlegen."""
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


def run(path, verbose=False):
    d, df, strategy, args = load_case(path)
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


def collect(paths, ids):
    files = []
    for p in paths:
        if os.path.isdir(p):
            for f in sorted(os.listdir(p)):
                if f.endswith(".json.gz") or f.endswith(".json"):
                    files.append(os.path.join(p, f))
        else:
            files.append(p)
    if ids:
        files = [f for f in files if os.path.basename(f).split(".json")[0] in ids]
    return files


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("paths", nargs="*", help="Ordner oder Dateien (Standard: golden/cases und golden/extra)")
    ap.add_argument("-k", "--case", nargs="*", default=[], help="nur diese Fälle (ohne Endung)")
    ap.add_argument("-v", "--verbose", action="store_true", help="Unterschiede ausführlich zeigen")
    ap.add_argument("-q", "--quiet", action="store_true", help="nur die Zusammenfassung")
    a = ap.parse_args(argv)
    paths = a.paths or DEFAULT_DIRS
    total_ok = total = 0
    failed_all = []
    for p in paths:
        files = collect([p], a.case)
        if not files:
            continue
        n_ok = 0
        for f in files:
            errs = run(f, verbose=a.verbose)
            if errs:
                failed_all.append(f)
                if not a.quiet:
                    print("FAIL", os.path.basename(f))
                    for e in errs[:8]:
                        print("   ", e)
            else:
                n_ok += 1
        print("%s: %d/%d Fälle bitgleich" % (p, n_ok, len(files)))
        total_ok += n_ok
        total += len(files)
    if len(paths) > 1:
        print("gesamt: %d/%d Fälle bitgleich" % (total_ok, total))
    return 0 if not failed_all else 1


if __name__ == "__main__":
    sys.exit(main())
