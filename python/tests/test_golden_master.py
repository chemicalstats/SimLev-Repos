"""Bitgleichheit zu R: vergleicht jede Tageszahl, Kennzahl und Textausgabe
mit Referenzergebnissen, die mit dem R-Paket SimLev erzeugt wurden.

Die Referenzen liegen komprimiert im gemeinsamen Ordner ``golden/cases/`` des
Repositorys (für alle Sprachfassungen dieselben Fälle). Neu erzeugen lassen sie
sich mit ``golden/golden_cases.R`` (benötigt R und das R-Paket). Ein anderer
Ordner lässt sich über die Umgebungsvariable ``SIMLEV_GOLDEN_DIR`` setzen.
"""
import contextlib
import gzip
import io
import json
import math
import os
import platform
import warnings

import numpy as np
import pandas as pd
import pytest

import simlev

GOLDEN = os.environ.get("SIMLEV_GOLDEN_DIR") or os.path.join(
    os.path.dirname(__file__), "..", "..", "golden", "cases")
CASES = sorted(f for f in os.listdir(GOLDEN) if f.endswith(".json.gz")) if os.path.isdir(GOLDEN) else []


def test_golden_cases_present():
    # Ohne diesen Test würden die Bitgleichheits-Tests bei falschem Pfad
    # stillschweigend entfallen statt fehlzuschlagen.
    assert CASES, f"Keine Golden-Master-Fälle gefunden in {os.path.abspath(GOLDEN)}"

# Bitgleichheit setzt 80-Bit-long-double wie in R voraus (Linux/x86-64).
EXACT = np.finfo(np.longdouble).nmant >= 63


def unhex(v):
    if v is None or v in ("NA", "NaN"):
        return math.nan
    if isinstance(v, (int, float)):
        return float(v)
    return float.fromhex(v)


def load(path):
    with gzip.open(path, "rt", encoding="utf-8") as fh:
        d = json.load(fh)
    cols = {}
    for nm in d["data"]["order"]:
        c = d["data"]["cols"][nm]
        vals = c["values"] if isinstance(c["values"], list) else [c["values"]]
        if c["type"] == "date":
            cols[nm] = np.array(vals, dtype="int64").astype("datetime64[D]")
        elif c["type"] == "logical":
            cols[nm] = np.array(vals, dtype=bool if all(v is not None for v in vals) else object)
        else:
            cols[nm] = np.array([unhex(v) for v in vals], dtype=np.float64)
    strategy = {k: {kk: (unhex(vv["hex"]) if isinstance(vv, dict) and "hex" in vv else vv) for kk, vv in a.items()}
                for k, a in d["strategy"].items()}
    return d, pd.DataFrame(cols), strategy, dict(d["args"])


def assert_same(name, ref, got):
    ref = np.array([unhex(v) for v in (ref if isinstance(ref, list) else [ref])], dtype=np.float64)
    got = np.asarray(got, dtype=np.float64).ravel()
    assert ref.size == got.size, name
    ok = (ref == got) | (np.isnan(ref) & np.isnan(got))
    if EXACT:
        bad = np.flatnonzero(~ok)
        assert bad.size == 0, "%s: erste Abweichung bei %d (R=%r, Python=%r)" % (name, bad[0], ref[bad[0]], got[bad[0]])
    else:
        np.testing.assert_allclose(got, ref, rtol=1e-9, atol=1e-9, equal_nan=True, err_msg=name)


@pytest.mark.parametrize("case", CASES)
def test_bitgleich_zu_r(case):
    d, df, strategy, args = load(os.path.join(GOLDEN, case))
    buf = io.StringIO()
    with warnings.catch_warnings(), contextlib.redirect_stdout(buf), contextlib.redirect_stderr(io.StringIO()):
        warnings.simplefilter("ignore")
        res = simlev.simulation(df, strategy, **args)
    r = d["result"]
    assert_same("worth", r["worth"], res.worth)
    assert_same("drawdowns", r["drawdowns"], res.drawdowns)
    assert_same("cagr", r["cagr"], res.cagr)
    assert_same("ttwror", r["ttwror"], res.ttwror)
    for k, v in r["statistics"].items():
        assert_same("statistics." + k, v, res.statistics[k])
    for k, v in r["tax_report"].items():
        assert_same("tax_report." + k, v, res.tax_report[k])
    for k, v in r["buys"].items():
        assert_same("buys." + k, v, res.buys[k])
    for k, v in r["sells"].items():
        assert_same("sells." + k, v, res.sells[k])
    for a, fields in r["report"].items():
        for f, v in fields.items():
            assert_same("report.%s.%s" % (a, f), v, res.report[a][f])
    if EXACT:
        assert res.format() == r["print"]
        if "stdout" in d:
            out = buf.getvalue()
            assert (out[:-1] if out.endswith("\n") else out) == d["stdout"]
