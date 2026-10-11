"""Vergleicht die Python-Engine bitgenau mit Golden-Master-Ergebnissen aus R.

Aufruf: python compare_golden.py <golden_dir> [case_id ...]
"""
from __future__ import annotations

import contextlib
import io
import json
import math
import os
import sys
import warnings

import numpy as np
import pandas as pd

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))
import simlev  # noqa: E402


def unhex(v):
    if v is None or v == "NA":
        return float("nan")
    if v == "NaN":
        return float("nan")
    if isinstance(v, (int, float)):
        return float(v)
    return float.fromhex(v)


def load_case(path):
    d = json.load(open(path))
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
        a = {k: (unhex(v["hex"]) if isinstance(v, dict) and "hex" in v else v) for k, v in a.items()}
        strategy[nm] = a
    args = dict(d["args"])
    return d, df, strategy, args


def same(a, b):
    a = float(a)
    b = float(b)
    if math.isnan(a) and math.isnan(b):
        return True
    return a == b


def cmp_vec(name, ref, got, errs):
    ref = np.array([unhex(v) for v in (ref if isinstance(ref, list) else [ref])], dtype=np.float64)
    got = np.asarray(got, dtype=np.float64).ravel()
    if ref.size != got.size:
        errs.append("%s: Länge %d vs %d" % (name, ref.size, got.size))
        return
    bad = np.flatnonzero(~((ref == got) | (np.isnan(ref) & np.isnan(got))))
    if bad.size:
        i = bad[0]
        errs.append("%s: %d Abweichungen, erste bei %d: R=%r Py=%r" % (name, bad.size, i, ref[i], got[i]))


def run(path, verbose=False):
    d, df, strategy, args = load_case(path)
    buf = io.StringIO()
    with warnings.catch_warnings():
        warnings.simplefilter("ignore")
        try:
            with contextlib.redirect_stdout(buf):
                res = simlev.simulation(df, strategy, **args)
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
        cmp_vec("tax." + k, v, res.tax_report[k], errs)
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
            errs.append("\n".join(difflib.unified_diff(r["print"].splitlines(), res.format().splitlines(), lineterm="")))
    return errs


def main():
    gdir = sys.argv[1]
    ids = sys.argv[2:]
    files = sorted(os.listdir(gdir))
    if ids:
        files = [i + ".json" for i in ids]
    n_ok = 0
    failed = []
    for f in files:
        errs = run(os.path.join(gdir, f), verbose=bool(ids))
        if errs:
            failed.append(f)
            print("FAIL", f)
            for e in errs[:8]:
                print("   ", e)
        else:
            n_ok += 1
    print("\n%d/%d Fälle bitgleich" % (n_ok, len(files)))
    return 0 if not failed else 1


if __name__ == "__main__":
    sys.exit(main())
