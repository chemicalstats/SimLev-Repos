"""Referenzbäume: Vergleich von Python-Ergebnissen mit R-Referenzfällen.

Die Fälle in ``golden/modules/<modul>/*.json.gz`` erzeugt R mit
``golden/modules/ref_tools.R``. Jeder Fall enthält die Eingaben, den R-Code,
den passenden Python-Code und das R-Ergebnis als Baum (siehe dort). Dieses
Modul dekodiert die Eingaben in Python-Objekte, führt den Python-Code aus
und vergleicht das Ergebnis Bit für Bit mit dem Baum.

Abbildung R → Python (beim Dekodieren der Eingaben):

==========================  =============================================
R                           Python
==========================  =============================================
NULL                        ``None``
Vektor der Länge 1          Skalar (``float``, ``int``, ``bool``, ``str``)
Vektor                      ``numpy.ndarray``
benannter Vektor            ``pandas.Series`` (Index = Namen)
Date                        ``numpy.datetime64[D]`` bzw. Array davon
data.frame                  ``pandas.DataFrame``
Matrix ohne dimnames        2-D ``numpy.ndarray``
Matrix mit dimnames         ``pandas.DataFrame``
benannte Liste              ``dict``
unbenannte Liste            ``list``
==========================  =============================================

Beim Vergleich richtet sich die Umwandlung nach dem R-Baum; Python-Ergebnisse
dürfen Objekte mit Attributen, ``dict``-artige Objekte, ``Series``,
``DataFrame`` oder Arrays sein.
"""
from __future__ import annotations

import contextlib
import datetime as _dt
import gzip
import io
import json
import os
import math
import traceback
import warnings
from collections.abc import Mapping

import numpy as np
import pandas as pd

__all__ = ["load_case", "decode", "compare", "run_case"]

_EPOCH = np.datetime64("1970-01-01", "D")
# Die Referenzen entstanden mit R unter LC_ALL=C.UTF-8, d. h. ICU-Kollation "root".
# Für den Vergleich dieselbe Kollation erzwingen, unabhängig vom Locale des Rechners.
__import__("os").environ.setdefault("SIMLEV_COLLATE", "icu:root")
_STRICT_ZERO = __import__("os").environ.get("SIMLEV_STRICT_ZERO", "1") != "0"


# ── Dekodieren ─────────────────────────────────────────────────────────────

_NA_BITS_LO = 1954
_NA_REAL = __import__("struct").unpack("<d", __import__("struct").pack("<Q", 0x7FF00000000007A2))[0]
_STRICT_NA = __import__("os").environ.get("SIMLEV_LAX_NA", "0") != "1"


def _isna(x):
    """R_IsNA: NaN mit der Nutzlast 1954 im unteren Wort (R's NA_real_)."""
    return x != x and (__import__("struct").unpack("<Q", __import__("struct").pack("<d", x))[0] & 0xFFFFFFFF) == _NA_BITS_LO


def _unhex(v):
    if v is None or v == "NA":
        return _NA_REAL
    if v == "NaN":
        return math.nan
    if isinstance(v, (int, float)):
        return float(v)
    return float.fromhex(v)


def _aslist(v):
    if v is None:
        return []
    return v if isinstance(v, list) else [v]


def _vals(node):
    """Werte eines Vektorknotens; ``null`` = NA der Länge 1 (jsonlite auto_unbox)."""
    v = node.get("v")
    if v is None:
        return [None]
    return v if isinstance(v, list) else [v]


def _vec(node):
    t = node["t"]
    v = _vals(node)
    if t == "num":
        return np.array([_unhex(x) for x in v], dtype=np.float64)
    if t == "int":
        if any(x in (None, "NA") for x in v):
            return np.array([_unhex(x) for x in v], dtype=np.float64)
        return np.array([int(_unhex(x)) for x in v], dtype=np.int64)
    if t == "lgl":
        if any(x is None for x in v):
            return np.array(v, dtype=object)
        return np.array(v, dtype=bool)
    if t == "chr":
        return np.array(v, dtype=object)
    if t == "date":
        return np.array([np.datetime64("NaT") if x is None else _EPOCH + np.timedelta64(int(x), "D")
                         for x in v], dtype="datetime64[D]")
    raise ValueError(t)


def _scalar(a):
    x = a[0]
    if isinstance(x, np.floating):
        return float(x)
    if isinstance(x, np.integer):
        return int(x)
    if isinstance(x, np.bool_):
        return bool(x)
    return x


def decode(node):
    """Baum → Python-Objekt (für Eingaben)."""
    t = node["t"]
    if t in ("null", "skip"):
        return None
    if t in ("num", "int", "lgl", "chr", "date"):
        a = _vec(node)
        names = node.get("names")
        if names is not None:
            return pd.Series(a, index=_aslist(names))
        if a.size == 1 and "dim" not in node:
            return _scalar(a)
        return a
    if t == "df":
        names = _aslist(node.get("names"))
        cols = [decode_col(c) for c in _aslist(node.get("cols"))] if node.get("cols") is not None else []
        d = {nm: c for nm, c in zip(names, cols)}
        df = pd.DataFrame(d, columns=names)
        if node.get("nrow") is not None and not cols:
            df = pd.DataFrame(index=range(int(node["nrow"])))
        if node.get("row_names") is not None:
            df.index = _aslist(node["row_names"])
        return df
    if t == "mat":
        dim = _aslist(node["dim"])
        vals = _vals(node)
        typ = node.get("type", "double")
        if typ in ("double", "integer"):
            a = np.array([_unhex(x) for x in vals], dtype=np.float64)
        elif typ == "logical":
            a = np.array(vals, dtype=object if any(x is None for x in vals) else bool)
        else:
            a = np.array(vals, dtype=object)
        if len(dim) == 2:
            a = a.reshape((dim[1], dim[0])).T.copy()
        else:
            a = a.reshape(tuple(reversed(dim))).transpose()
        dn = node.get("dimnames")
        if dn is not None and len(dim) == 2:
            dn = list(dn.values()) if isinstance(dn, dict) else (_aslist(dn) if isinstance(dn, list) else [dn])
            rn = _aslist(dn[0]) if len(dn) > 0 and dn[0] is not None else None
            cn = _aslist(dn[1]) if len(dn) > 1 and dn[1] is not None else None
            return pd.DataFrame(a, index=rn, columns=cn)
        return a
    if t == "list":
        vals = [decode(x) for x in _aslist(node.get("v"))] if node.get("v") is not None else []
        names = node.get("names")
        if names is not None:
            return {k: v for k, v in zip(_aslist(names), vals)}
        return vals
    raise ValueError("unbekannter Knotentyp %r" % t)


def decode_col(node):
    """Spalte eines data.frame: immer Array (auch bei Länge 1)."""
    if node["t"] in ("num", "int", "lgl", "chr", "date"):
        return _vec(node)
    return decode(node)


# ── Python-Objekt → Vektor ────────────────────────────────────────────────

def _get(obj, name):
    """Element ``name`` aus Python-Objekt holen (dict, Attribut, Spalte)."""
    if obj is None:
        return _MISSING
    if isinstance(obj, pd.DataFrame):
        return obj[name] if name in obj.columns else _MISSING
    if isinstance(obj, pd.Series):
        return obj[name] if name in obj.index else _MISSING
    if isinstance(obj, Mapping):
        return obj[name] if name in obj else _MISSING
    if hasattr(obj, "__getitem__") and hasattr(obj, "keys") and callable(obj.keys):
        try:
            if name in list(obj.keys()):
                return obj[name]
        except Exception:  # noqa: BLE001
            pass
    if isinstance(name, str) and hasattr(obj, name):
        v = getattr(obj, name)
        if not callable(v) or isinstance(v, (pd.Series, pd.DataFrame, np.ndarray)):
            return v
    return _MISSING


class _Missing:
    def __repr__(self):
        return "<fehlt>"


_MISSING = _Missing()


def _names_of(obj):
    if isinstance(obj, pd.Series):
        if isinstance(obj.index, pd.RangeIndex):
            return None
        return [str(x) for x in obj.index]
    if isinstance(obj, Mapping):
        return [str(k) for k in obj.keys()]
    return None


def _to_days(x):
    if x is None:
        return _NA_REAL
    if isinstance(x, float) and math.isnan(x):
        return x
    if isinstance(x, (np.datetime64,)):
        if np.isnat(x):
            return _NA_REAL
        return float((x.astype("datetime64[D]") - _EPOCH).astype(np.int64))
    if isinstance(x, pd.Timestamp):
        if pd.isna(x):
            return _NA_REAL
        return float((np.datetime64(x.date(), "D") - _EPOCH).astype(np.int64))
    if isinstance(x, _dt.datetime):
        x = x.date()
    if isinstance(x, _dt.date):
        return float(x.toordinal() - 719163)
    if x is pd.NaT:
        return _NA_REAL
    return float(x)


def _flat(obj, kind):
    """Python-Objekt → 1-D-Liste/Array passend zu ``kind``."""
    if isinstance(obj, pd.DataFrame):
        a = obj.to_numpy().ravel(order="F")
    elif isinstance(obj, pd.Series):
        a = obj.to_numpy()
    elif isinstance(obj, pd.Index):
        a = obj.to_numpy()
    elif isinstance(obj, Mapping):
        a = list(obj.values())
    elif isinstance(obj, np.ndarray):
        a = obj.ravel(order="F")
    elif isinstance(obj, (list, tuple)):
        a = list(obj)
    elif isinstance(obj, pd.Categorical):
        a = np.asarray(obj, dtype=object)
    else:
        a = [obj]
    if kind == "date":
        if isinstance(a, np.ndarray) and np.issubdtype(a.dtype, np.datetime64):
            d = a.astype("datetime64[D]")
            out = (d - _EPOCH).astype(np.int64).astype(np.float64)
            out[np.isnat(d)] = _NA_REAL
            return out
        return np.array([_to_days(x) for x in a], dtype=np.float64)
    if kind in ("num", "int"):
        out = []
        for x in a:
            if x is None or x is pd.NA:
                out.append(_NA_REAL)
            elif isinstance(x, (bool, np.bool_)):
                out.append(float(x))
            else:
                try:
                    out.append(float(x))
                except (TypeError, ValueError):
                    out.append(_BAD)
        return out
    if kind == "lgl":
        out = []
        for x in a:
            if x is None or x is pd.NA or (isinstance(x, float) and math.isnan(x)):
                out.append(None)
            else:
                out.append(bool(x))
        return out
    if kind == "chr":
        out = []
        for x in a:
            if x is None or x is pd.NA or (isinstance(x, float) and math.isnan(x)):
                out.append(None)
            else:
                out.append(str(x))
        return out
    raise ValueError(kind)


_BAD = object()


def _num_eq(r, p):
    if p is _BAD:
        return False
    if math.isnan(r):
        if not math.isnan(p):
            return False
        return not _STRICT_NA or _isna(r) == _isna(p)
    if math.isnan(p):
        return False
    if r == 0.0 and p == 0.0:
        # Vorzeichen der Null wird mitgeprüft; SIMLEV_STRICT_ZERO=0 lässt -0 == +0 zu
        return not _STRICT_ZERO or math.copysign(1.0, r) == math.copysign(1.0, p)
    return r == p


# ── Vergleich ─────────────────────────────────────────────────────────────

def compare(ref, py, path="result", errs=None, max_errs=40):
    """Vergleicht Python-Objekt ``py`` mit R-Baum ``ref``; Fehlerliste."""
    if errs is None:
        errs = []
    if len(errs) >= max_errs:
        return errs
    t = ref["t"]
    if t == "skip":
        return errs
    if py is _MISSING:
        if t == "null":
            return errs
        errs.append("%s: fehlt in Python" % path)
        return errs
    if t == "null":
        if py is None:
            return errs
        if isinstance(py, (list, tuple, dict, np.ndarray, pd.Series, pd.DataFrame)) and len(py) == 0:
            return errs
        errs.append("%s: R NULL, Python %s" % (path, type(py).__name__))
        return errs
    if t in ("num", "int", "lgl", "chr", "date"):
        if py is None:
            if isinstance(ref.get("v"), list) and not ref.get("v"):
                return errs
            if t in ("chr", "lgl") and ref.get("v") is None and "names" not in ref:
                return errs     # NA_character_/NA der Länge 1: decode() liefert dafür ebenfalls None
            errs.append("%s: Python None" % path)
            return errs
        rv = _vec(ref)
        kind = "num" if t == "int" else t
        if t == "date":
            rr = _flat_ref_dates(ref)
        else:
            rr = rv
        pv = _flat(py, kind)
        if len(pv) != len(rr):
            errs.append("%s: Länge R %d, Python %d" % (path, len(rr), len(pv)))
            return errs
        if kind in ("num", "date"):
            bad = [i for i in range(len(rr)) if not _num_eq(float(rr[i]), pv[i] if pv[i] is _BAD else float(pv[i]))]
        elif kind == "lgl":
            bad = [i for i in range(len(rr)) if (None if rr[i] is None else bool(rr[i])) != pv[i]]
        else:
            bad = [i for i in range(len(rr)) if rr[i] != pv[i]]
        if bad:
            i = bad[0]
            rx, px = rr[i], pv[i]
            if kind == "num" and px is not _BAD:
                errs.append("%s: %d/%d abweichend, erste [%d]: R=%s Py=%s" % (
                    path, len(bad), len(rr), i, float(rx).hex() if not math.isnan(float(rx)) else "NA",
                    float(px).hex() if not math.isnan(float(px)) else "NaN"))
            else:
                errs.append("%s: %d/%d abweichend, erste [%d]: R=%r Py=%r" % (path, len(bad), len(rr), i, rx, px))
        names = ref.get("names")
        if names is not None:
            pn = _names_of(py)
            if pn is not None and [str(x) for x in _aslist(names)] != pn:
                errs.append("%s: Namen R %s, Python %s" % (path, _aslist(names)[:6], pn[:6]))
        return errs
    if t == "df":
        names = _aslist(ref.get("names"))
        cols = _aslist(ref.get("cols")) if ref.get("cols") is not None else []
        nrow = ref.get("nrow")
        if isinstance(py, pd.DataFrame):
            if nrow is not None and len(py) != int(nrow):
                errs.append("%s: Zeilen R %d, Python %d" % (path, int(nrow), len(py)))
                return errs
        for nm, c in zip(names, cols):
            compare(c, _get(py, nm), "%s$%s" % (path, nm), errs, max_errs)
        rn = ref.get("row_names")
        if rn is not None and isinstance(py, pd.DataFrame) and not isinstance(py.index, pd.RangeIndex):
            if [str(x) for x in py.index] != [str(x) for x in _aslist(rn)]:
                errs.append("%s: Zeilennamen abweichend" % path)
        return errs
    if t == "mat":
        dim = _aslist(ref["dim"])
        if isinstance(py, (pd.DataFrame, np.ndarray)):
            shp = py.shape
            if list(shp) != list(dim) and not (len(dim) == 2 and int(np.prod(dim)) == int(np.prod(shp)) and 1 in dim and len(shp) == 1):
                errs.append("%s: Dimension R %s, Python %s" % (path, dim, list(shp)))
                return errs
        typ = ref.get("type", "double")
        kind = {"double": "num", "integer": "num", "logical": "lgl"}.get(typ, "chr")
        sub = {"t": kind, "v": ref.get("v")}
        compare(sub, py, path, errs, max_errs)
        dn = ref.get("dimnames")
        if dn is not None and isinstance(py, pd.DataFrame) and len(dim) == 2:
            dn = list(dn.values()) if isinstance(dn, dict) else (_aslist(dn) if isinstance(dn, list) else [dn])
            if len(dn) > 1 and dn[1] is not None and [str(x) for x in py.columns] != [str(x) for x in _aslist(dn[1])]:
                errs.append("%s: Spaltennamen R %s, Python %s" % (path, _aslist(dn[1])[:6], list(py.columns)[:6]))
            if len(dn) > 0 and dn[0] is not None and not isinstance(py.index, pd.RangeIndex) and \
                    [str(x) for x in py.index] != [str(x) for x in _aslist(dn[0])]:
                errs.append("%s: Zeilennamen R %s, Python %s" % (path, _aslist(dn[0])[:6], list(py.index)[:6]))
        return errs
    if t == "list":
        vals = _aslist(ref.get("v")) if ref.get("v") is not None else []
        names = ref.get("names")
        if names is not None:
            names = _aslist(names)
            for i, (nm, v) in enumerate(zip(names, vals)):
                if nm == "":
                    el = py[i] if isinstance(py, (list, tuple)) and i < len(py) else _MISSING
                    compare(v, el, "%s[[%d]]" % (path, i + 1), errs, max_errs)
                else:
                    compare(v, _get(py, nm), "%s$%s" % (path, nm), errs, max_errs)
            return errs
        if isinstance(py, Mapping):
            py = list(py.values())
        if isinstance(py, (pd.Series, np.ndarray)):
            py = list(py)
        if not isinstance(py, (list, tuple)):
            errs.append("%s: R Liste, Python %s" % (path, type(py).__name__))
            return errs
        if len(py) != len(vals):
            errs.append("%s: Listenlänge R %d, Python %d" % (path, len(vals), len(py)))
            return errs
        for i, v in enumerate(vals):
            compare(v, py[i], "%s[[%d]]" % (path, i + 1), errs, max_errs)
        return errs
    errs.append("%s: unbekannter Knotentyp %s" % (path, t))
    return errs


def _flat_ref_dates(ref):
    return np.array([_NA_REAL if x is None else float(x) for x in _vals(ref)], dtype=np.float64)


# ── Ausführen ─────────────────────────────────────────────────────────────

def load_case(path):
    op = gzip.open if str(path).endswith(".gz") else open
    with op(path, "rt", encoding="utf-8") as fh:
        return json.load(fh)


def _uniq(seq):
    out = []
    for s in seq:
        if s not in out:
            out.append(s)
    return out


def run_case(case, check_print=True, check_output=True, check_warnings=True):
    """Führt einen Fall aus; liefert Liste der Abweichungen (leer = bitgleich).

    Hat der Fall eine feste Uhrzeit (Feld ``sys_time``), gilt sie während des
    Falls über ``SIMLEV_R_SYS_TIME`` (:func:`simlev._r.base.sys_time`).
    """
    env = {}
    st = case.get("sys_time")
    if st is not None:
        env["SIMLEV_R_SYS_TIME"] = st if isinstance(st, str) else repr(float(st))
    old = {k: os.environ.get(k) for k in env}
    os.environ.update(env)
    try:
        return _run_case(case, check_print, check_output, check_warnings)
    finally:
        for k, v in old.items():
            if v is None:
                os.environ.pop(k, None)
            else:
                os.environ[k] = v


def _run_case(case, check_print, check_output, check_warnings):
    import simlev

    ns = {"simlev": simlev, "np": np, "pd": pd, "math": math}
    for k, v in (case.get("inputs") or {}).items():
        ns[k] = decode(v)
    buf = io.StringIO()
    caught = []
    err = None
    with warnings.catch_warnings(record=True) as wl:
        warnings.simplefilter("always")
        try:
            with contextlib.redirect_stdout(buf):
                exec(case["py"], ns)  # noqa: S102 - Fälle stammen aus dem Repo
        except Exception as exc:  # noqa: BLE001
            err = exc
            tb = traceback.format_exc()
        caught = _uniq([str(w.message) for w in wl])
    errs = []
    if "error" in case and case["error"] is not None:
        if err is None:
            errs.append("R bricht ab (%s), Python nicht" % case["error"])
        elif str(err) != case["error"]:
            errs.append("Fehlermeldung abweichend:\n  R:  %s\n  Py: %s" % (case["error"], err))
        return errs
    if err is not None:
        return ["Python-Fehler: %r\n%s" % (err, tb)]
    if "result" not in ns:
        return ["Python-Code setzt `result` nicht"]
    res = ns["result"]
    compare(case["result"], res, "result", errs)
    if check_output and case.get("output"):
        got = buf.getvalue()
        if got.endswith("\n"):
            got = got[:-1]
        if got != case["output"]:
            errs.append("Konsolenausgabe abweichend")
            errs.append(_diff(case["output"], got))
    if check_print and case.get("print") is not None:
        pbuf = io.StringIO()
        with warnings.catch_warnings():
            warnings.simplefilter("ignore")
            try:
                with contextlib.redirect_stdout(pbuf):
                    print(res)
            except Exception as exc:  # noqa: BLE001
                errs.append("print-Ausgabe: Python-Fehler %r" % (exc,))
                return errs
        got = pbuf.getvalue()
        if got.endswith("\n"):
            got = got[:-1]
        if got != case["print"]:
            errs.append("print-Ausgabe abweichend")
            errs.append(_diff(case["print"], got))
    if check_warnings:
        rw = _aslist(case.get("warnings"))
        if rw != caught:
            errs.append("Warnungen abweichend:\n  R:  %s\n  Py: %s" % (rw, caught))
    return errs


def _diff(a, b, n=40):
    import difflib
    return "\n".join(list(difflib.unified_diff(a.splitlines(), b.splitlines(), "R", "Python", lineterm="", n=1))[:n])
