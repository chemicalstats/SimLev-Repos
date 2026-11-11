"""Einheitliche Eingabeprüfung (seit 1.6.4, Entscheidung 05.11.2026; Gegenstück zu ``r/R/pruefen.R``).

Prüfhilfen für die öffentlichen Funktionen: vorhanden, richtiger Typ, plausibler Wertebereich. Bei einem Verstoß
bricht die Hilfe mit dem Text aus der Tabelle ``eingabe`` ab (``core/meldungen.tsv``, ``_meldungen.EINGABE``):
deutsch, ``"<funktion>: <argument> muss …"``, in R, Python und Julia zeichengleich (der Eingabewert steht nicht im
Text); Fehlerklasse ``ValueError`` wie die übrigen Meldungen. Gegenstücke mit gleichen Namen und gleicher Semantik:
``r/R/pruefen.R``, ``julia/src/pruefen.jl``.

Regeln (wie R, auch wo R selbst still annimmt; Entscheidungen des Nutzers vom 05.11.2026):

- Länge 1: Vektoren der Länge 1 (``list``, ``tuple``, ``numpy.ndarray``, ``pandas.Series``) zählen wie Einzelwerte
  (R: ``c(TRUE)`` ist ``TRUE``); die Hilfen geben den Einzelwert zurück (:func:`chk_scalar`).
- Zahl: ``int``, ``float`` oder NumPy-Zahl (kein ``bool``, kein Text, keine Kategorie), ein Wert, nicht NA/NaN,
  endlich; ganze Zahl zusätzlich ``x == trunc(x)`` (2 und 2.0 sind ganz, 2.5 nicht).
- Wahrheitswert: nur ``bool``/``numpy.bool_``; keine Zahl, kein Text ``"FALSE"``, nie ``None`` (wer den Standard
  will, lässt das Argument weg).
- Text: ``str``, nicht NA; Leerraum (auch Unicode) wird nicht abgeschnitten.
- Datum: ``datetime.date``/``datetime``, ``pandas.Timestamp``, ``numpy.datetime64`` oder Text, den ``as.Date``
  liest; keine Zahl.
- Tabelle: nur ``pandas.DataFrame`` (wie R ``data.frame``); die Meldung sagt, wie man umwandelt.
- Signalspalte: Wahrheitswerte oder Zahlen 0/1, NA erlaubt; andere Zahlen (2, 0.5) nicht.
- ``None`` (R ``NULL``) nur, wo ``null_ok=True`` (nie bei Wahrheitswerten); ``pd.NA`` und ``NaN`` gelten als NA.
- Meldungen nennen den Eingabewert nicht (nur Funktion, Argument, Spalten- bzw. Asset-Namen und Grenzen).
- Kategorie (R-Faktor): weder als Argument noch als Spalte (:func:`chk_nofactor`, :func:`chk_col_nofactor`).
- Ganze Zahl: nie abschneiden, 2.5 ist ein Fehler (Entscheidung 19); Obergrenzen mit :func:`chk_max` (16, 36) und
  den gemeinsamen Werten ``SL_MAX_*`` (Laufzeiten 100 Jahre, Entscheidung 46); Jahre mit :func:`chk_jahre` (47).
- Namen eigener Kennzahlen eindeutig, nicht leer, keine feste Spalte (:func:`chk_kennzahlen`; Entscheidungen 28 und
  43).
- NA in Basiszins- und CAPE-Reihen ist ein Fehler (:func:`chk_col_nona`, :func:`chk_nona`; Entscheidung 17).
- Zahl aus Text nur mit ASCII-Zeichen (:func:`chk_as_num`; Entscheidung 27).
- Unbekannte und doppelte Argumente in ``**kwargs`` vor dem Aufruf melden (:func:`chk_dots`; Entscheidung 21).
"""
from __future__ import annotations

import datetime as _dt
import math
import re
from typing import Any, Mapping

import numpy as np
import pandas as pd

from ._meldungen import EINGABE
from ._r.rformat import r_format1


def _msg_val(v: Any) -> Any:
    # seit 1.6.5 (CR2-W1-4): Folgen (Liste, Tupel, Feld) mit ", " verbunden, None als "" – wie R und Julia
    if v is None:
        return ""
    if isinstance(v, (list, tuple, np.ndarray)):
        return ", ".join(str(t) for t in v)
    return v


def chk_msg(key: str, *args: Any) -> str:
    """Text der Tabelle ``eingabe`` (nur ``%s``-Platzhalter)."""
    return EINGABE[key] % tuple(_msg_val(a) for a in args)


def chk_stop(key: str, *args: Any):
    """Abbruch mit einem Text der Tabelle ``eingabe``."""
    raise ValueError(chk_msg(key, *args))


def chk_fmt(x: Any) -> str:
    """Zahl in einer Meldung wie ``format(x, digits = 15)``; ganze Zahlen wie R-integer (Entscheidung 63)."""
    if isinstance(x, (int, np.integer)) and not isinstance(x, (bool, np.bool_)):
        return r_format1(x, digits=15)
    return r_format1(float(x), digits=15)


def chk_range_text(lo=None, hi=None, lo_open=False, hi_open=False) -> str:
    """Bereichstext wie R ``chk_range_text`` (z. B. ``"> 0"``, ``"≥ 0 und ≤ 1"``)."""
    p = []
    if lo is not None:
        p.append(chk_msg("bereich.gt" if lo_open else "bereich.ge", chk_fmt(lo)))
    if hi is not None:
        p.append(chk_msg("bereich.lt" if hi_open else "bereich.le", chk_fmt(hi)))
    return chk_msg("bereich.und", p[0], p[1]) if len(p) == 2 else (p[0] if p else "")


def chk_scalar(x: Any) -> Any:
    """Vektor der Länge 1 als Einzelwert (R: ``c(x)`` ist ``x``): ``list``/``tuple`` mit einem Element,
    ``numpy.ndarray`` mit einem Wert, ``pandas.Series`` der Länge 1; NumPy-Zahlen und -Wahrheitswerte daraus als
    Python-Werte. Alles andere (auch Text und ``dict``) unverändert."""
    if isinstance(x, (list, tuple)) and len(x) == 1:
        x = x[0]
    elif isinstance(x, np.ndarray) and x.size == 1:
        x = x.reshape(-1)[0]
    elif isinstance(x, pd.Series) and len(x) == 1:
        x = x.iloc[0]
    else:
        return x
    if isinstance(x, (np.bool_, np.integer, np.floating)):
        return x.item()
    return x


def _num_scalar(x: Any) -> bool:
    return isinstance(x, (int, float, np.integer, np.floating)) and not isinstance(x, (bool, np.bool_))


def _to_float(x: Any) -> float:
    """``float(x)`` für Prüfungen; seit 1.6.4 (K43 T1-R4) ergeben Python-Ganzzahlen außerhalb des double-Bereichs
    (``abs(x) >= 2**1024``, z. B. ``10**400``) ±inf statt ``OverflowError`` (Meldung wie R mit ``1e400`` und Julia).
    Gleiche Werte für alle anderen Eingaben."""
    try:
        return float(x)
    except OverflowError:
        return math.inf if x > 0 else -math.inf


def _finite_num(x: Any) -> bool:
    return _num_scalar(x) and math.isfinite(_to_float(x))


def chk_num1(x, fn, arg, lo=None, hi=None, lo_open=False, hi_open=False, null_ok=False):
    """Einzelne endliche Zahl, optional im Bereich ``[lo, hi]`` (``lo_open``/``hi_open``: Grenze ausgeschlossen)."""
    x = chk_scalar(x)
    if x is None and null_ok:
        return x
    ok = _finite_num(x)
    rng = lo is not None or hi is not None
    if ok and rng:
        v = _to_float(x)
        ok = (lo is None or (v > lo if lo_open else v >= lo)) and (hi is None or (v < hi if hi_open else v <= hi))
    if not ok:
        if rng:
            chk_stop("zahl_bereich", fn, arg, chk_range_text(lo, hi, lo_open, hi_open))
        chk_stop("zahl", fn, arg)
    return x


def chk_prob(x, fn, arg, null_ok=False):
    """Wahrscheinlichkeit bzw. Anteil in ``[0, 1]``."""
    return chk_num1(x, fn, arg, lo=0, hi=1, null_ok=null_ok)


def chk_int1(x, fn, arg, lo=1, null_ok=False, hi=None):
    """Einzelne ganze Zahl ``>= lo`` (2 und 2.0 sind ganz, 2.5 nicht; nie abgeschnitten); mit ``hi``: von ``lo``
    bis ``hi`` (Meldung ``ganz_bis``)."""
    x = chk_scalar(x)
    if x is None and null_ok:
        return x
    ok = _finite_num(x) and _to_float(x) == math.trunc(_to_float(x)) and _to_float(x) >= lo
    if hi is not None:
        if not (ok and _to_float(x) <= hi):
            chk_stop("ganz_bis", fn, arg, chk_fmt(lo), chk_fmt(hi))
    elif not ok:
        chk_stop("ganz", fn, arg, chk_fmt(lo))
    return x


def _flat_vals(x):
    if isinstance(x, Mapping):
        return list(x.values())
    if isinstance(x, pd.Series):
        return list(x.to_numpy())
    if isinstance(x, (list, tuple, np.ndarray)):
        return list(np.asarray(x, dtype=object).ravel())
    return [x]


def chk_intvec(x, fn, arg, lo=1):
    """Vektor ganzer Zahlen ``>= lo`` (ohne NA; nie abgeschnitten; R ``chk_intvec``)."""
    vals = _flat_vals(x)
    if not (vals and all(_finite_num(v) and _to_float(v) == math.trunc(_to_float(v)) and _to_float(v) >= lo for v in vals)):
        chk_stop("ganz_vektor", fn, arg, chk_range_text(lo=lo))
    return x


def chk_cores(cores, fn, arg="cores"):
    """Zahl der Prozesse (seit 1.6.4, Entscheidung 41b): ``"auto"`` (Standard seit 1.6.4) oder ganze Zahl ``>= 1`` (sonst
    Fehler mit Meldung ``par.cores``, Entscheidung 113); mehr als die
    Zahl der Prozessoren (:func:`simlev._lib.nprocs`) wird mit einem Hinweis begrenzt (R ``chk_cores``). Ergebnis:
    die Zahl."""
    import sys
    from ._lib import nprocs
    v = chk_scalar(cores)
    if isinstance(v, str) and v == "auto":   # seit 1.6.4 Standard: Planer in _r.parallel.par_lapply
        return "auto"
    if not (_finite_num(v) and _to_float(v) == math.trunc(_to_float(v)) and _to_float(v) >= 1):
        chk_stop("par.cores", fn, arg)       # seit 1.6.4 (Entscheidung 113; vorher Meldung ganz)
    cores = v
    mx = nprocs()
    if cores > mx:
        sys.stderr.write(chk_msg("hinweis.prozessoren", "%s: %s" % (fn, arg), mx) + "\n")
        cores = mx
    return cores


def chk_max(x, hi, fn, arg):
    """Obergrenze (seit 1.6.4, Entscheidungen 16 und 36): Zahl bzw. alle Werte ``<= hi``; ``None``, Text und NA
    prüft der Aufrufer vorher. Die Grenze steht als ganze Zahl ohne Exponent in der Meldung (R ``chk_max``)."""
    vals = _flat_vals(chk_scalar(x))
    if any(_num_scalar(v) and not math.isnan(_to_float(v)) and _to_float(v) > hi for v in vals):
        chk_stop("obergrenze", fn, arg, "%.0f" % hi)
    return x


# Gemeinsame Obergrenzen (seit 1.6.4; Entscheidung 46 ersetzt die 1 000 Jahre aus 16 und 36 durch 100 Jahre; gleiche
# Namen und Werte in r/R/pruefen.R und julia/src/pruefen.jl, für alle Bereiche)
SL_MAX_JAHRE = 100          # Laufzeiten in Jahren (years, max_years, horizon in Jahren)
SL_MAX_TAGE = 36600         # Laufzeiten in Tagen bzw. Tagesperioden (path_length, planning_goal(horizon)): 100 Jahre
SL_MAX_MONATE = 1200        # Laufzeiten in Monaten (planning_lumpsum_vs_dca(months)): 100 Jahre
SL_MAX_N = 1e8              # Anzahlen (n, n_sim, B)
SL_MAX_GITTER = 1e6         # Gitterpunkte (n_grid)


def chk_jahre(x, fn, arg, null_ok=False):
    """Laufzeit in ganzen Jahren (seit 1.6.4, Entscheidungen 19, 46 und 47): ganze Zahl ``>= 1`` (Meldung ``ganz``)
    und höchstens :data:`SL_MAX_JAHRE` (Meldung ``obergrenze``); auch bei unterjähriger ``frequency`` nur ganze
    Jahre (R ``chk_jahre``). Ergebnis: der Einzelwert."""
    x = chk_scalar(x)
    if x is None and null_ok:
        return x
    x = chk_int1(x, fn, arg)
    chk_max(x, SL_MAX_JAHRE, fn, arg)
    return x


def chk_oder(x) -> str:
    """Aufzählung ``"a, b oder c"`` (Namen in Meldungen; R ``chk_oder``)."""
    x = [str(v) for v in x]
    if len(x) <= 1:
        return "".join(x)
    return ", ".join(x[:-1]) + " oder " + x[-1]


def chk_kennzahlen(nm, n, fixed, fn):
    """Namen eigener Kennzahlen (seit 1.6.4, Entscheidungen 28 und 43): ``nm`` = Namen des Ergebnisses von
    ``metrics()`` (``None`` = unbenannt; Namen, die kein Text sind, etwa die Positionen einer Liste, gelten als
    fehlend), ``n`` = seine Länge; bei ``n > 0`` Fehler, wenn unbenannt, ein Name leer, doppelt oder gleich einer
    festen Spalte der Ergebnistabelle (``fixed``) ist (R ``chk_kennzahlen``)."""
    if n > 0:
        nm = None if nm is None else list(nm)
        if (nm is None or len(nm) != n or any(not isinstance(k, str) or k == "" for k in nm)
                or len(set(nm)) != len(nm) or any(k in fixed for k in nm)):
            chk_stop("n2.kennzahl_namen", fn, chk_oder(fixed))
    return nm


def chk_bool1(x, fn, arg):
    """Einzelner Wahrheitswert ``True``/``False`` (nur ``bool``; ``None`` ist ein Fehler)."""
    x = chk_scalar(x)
    if not isinstance(x, (bool, np.bool_)):
        chk_stop("wahr", fn, arg)
    return x


def chk_text1(x, fn, arg, null_ok=False):
    """Einzelner Text (leer erlaubt)."""
    x = chk_scalar(x)
    if x is None and null_ok:
        return x
    if not isinstance(x, str):
        chk_stop("text", fn, arg)
    return x


def chk_name1(x, fn, arg, null_ok=False):
    """Einzelner, nicht leerer Name (z. B. Spalten- oder Asset-Name)."""
    x = chk_scalar(x)
    if x is None and null_ok:
        return x
    if not (isinstance(x, str) and x != ""):
        chk_stop("name", fn, arg)
    return x


def chk_choice(x, fn, arg, choices, null_ok=False):
    """Einer von mehreren Texten (ohne Teilübereinstimmung)."""
    x = chk_scalar(x)
    if x is None and null_ok:
        return x
    if not (isinstance(x, str) and x in choices):
        chk_stop("auswahl", fn, arg, ", ".join('"%s"' % c for c in choices))
    return x


def chk_date1(x, fn, arg, null_ok=False):
    """Einzelnes Datum (Datum/Zeitpunkt oder Text wie ``as.Date``); Ergebnis als ``datetime.date``."""
    x = chk_scalar(x)
    if x is None and null_ok:
        return x
    from ._sim_base import _as_date
    z = None
    # seit 1.6.5 (CR2-X8-3): pd.NaT wie None (bis 1.6.4 Rohfehler aus toordinal); Tage vor dem 01.01.0001 (-719162)
    # überall abgelehnt (Python kennt kein Jahr 0; bis 1.6.4 dort OverflowError, in R und Julia angenommen)
    if x is not pd.NaT and isinstance(x, (str, _dt.date, np.datetime64)):
        z = _as_date(x)
    if z is None or z < -719162:
        chk_stop("datum", fn, arg)
    return _dt.date(1970, 1, 1) + _dt.timedelta(days=int(z))


def chk_numvec(x, fn, arg, null_ok=False):
    """Numerischer Vektor (mindestens ein Wert; NA erlaubt, Namen erlaubt: ``dict``/``Series``)."""
    if x is None and null_ok:
        return x
    # seit 1.6.5 (CR2-V2-2): Feld oder Series mit Zahlentyp und mindestens einem Wert sofort (bis 1.6.4 je Element im
    # Interpreter, bei sharpe_probabilistic 68–91 % der Laufzeit); Ergebnis und Meldungen gleich
    if isinstance(x, (np.ndarray, pd.Series)) and x.dtype.kind in "fiu" and x.size >= 1:
        return x
    if isinstance(x, Mapping):
        vals = list(x.values())
    elif isinstance(x, pd.Series):
        vals = list(x.to_numpy()) if x.dtype.kind in "fiu" else [None]
    elif isinstance(x, (list, tuple, np.ndarray)):
        vals = list(np.asarray(x, dtype=object).ravel())
    else:
        vals = [x]
    # wie R c(...): NA neben Zahlen ist numerisch, nur NA (logisch) nicht
    isna = [v is None or v is pd.NA or (isinstance(v, (float, np.floating)) and math.isnan(v)) for v in vals]
    if not vals or not all(_num_scalar(v) or na for v, na in zip(vals, isna)) or not any(_num_scalar(v) for v in vals):
        chk_stop("zahlen", fn, arg)
    return x


def chk_len(x, n, fn, arg):
    """Länge ``n``."""
    if (0 if x is None else len(x)) != n:
        chk_stop("laenge", fn, arg, chk_fmt(n))
    return x


def chk_df(x, fn, arg, null_ok=False):
    """Nur Tabelle: ``pandas.DataFrame`` (wie R ``data.frame``; seit E0b kein ``dict`` von Spalten mehr); die
    Meldung nennt die Umwandlung. Der interne Rahmen ``_Frame`` (Aufrufe innerhalb von SimLev) gilt als Tabelle."""
    from ._sim_base import _Frame
    if x is None and null_ok:
        return x
    if not isinstance(x, (pd.DataFrame, _Frame)):
        chk_stop("tabelle", fn, arg, chk_msg("tabelle.formen"))
    return x


def _names(data) -> list:
    if isinstance(data, pd.DataFrame):
        return [str(c) for c in data.columns]
    if hasattr(data, "names"):
        return list(data.names)
    return [str(k) for k in data.keys()]


def chk_cols(data, cols, fn):
    """Spalten vorhanden (Meldung nennt die fehlenden in der gegebenen Reihenfolge)."""
    nms = _names(data)
    miss = [c for c in dict.fromkeys(cols) if c not in nms]
    if miss:
        chk_stop("spalten", fn, ", ".join("'%s'" % c for c in miss))
    return data


def chk_col_type(data, col, fn, type="numerisch"):
    """Spaltentyp ``"numerisch"`` (Zahlen, keine Kategorie), ``"logisch"`` (Wahrheitswerte) oder
    ``"logisch_oder_numerisch"`` wie R."""
    from ._sim_base import _Frame, _to_frame
    fr = data if isinstance(data, _Frame) else _to_frame(data)
    kind = fr.kinds.get(col)
    ok = kind in {"logisch": ("logical",), "numerisch": ("numeric",)}.get(type, ("logical", "numeric"))
    if not ok:
        chk_stop("spalte_typ", fn, col, chk_msg("typ." + type))
    return data


def chk_is_factor(x) -> bool:
    """Kategorie (R-Faktor): ``pandas.Categorical`` bzw. Series/Index mit ``CategoricalDtype``."""
    return isinstance(x, pd.Categorical) or (isinstance(x, (pd.Series, pd.Index)) and isinstance(x.dtype, pd.CategoricalDtype))


def chk_nofactor(x, fn, arg):
    """Keine Kategorie (R-Faktor) als Argument (Entscheidungen 15 und 22; R ``chk_nofactor``)."""
    if chk_is_factor(x):
        chk_stop("faktor", fn, arg)
    return x


def chk_col_nofactor(data, col, fn):
    """Spalte keine Kategorie (R-Faktor; R rechnete sonst mit den Codes)."""
    from ._sim_base import _Frame, _to_frame
    fr = data if isinstance(data, _Frame) else _to_frame(data)
    if fr.kinds.get(col) == "factor":
        chk_stop("spalte_faktor", fn, col)
    return data


def chk_col_signal(data, col, fn):
    """Signalspalte: Wahrheitswerte (mit NA) oder Zahlen 0/1 (NaN als NA erlaubt); andere Zahlen (2, 0.5), Text,
    Kategorie und Datum nicht (R ``chk_col_signal``)."""
    from ._sim_base import _Frame, _to_frame
    fr = data if isinstance(data, _Frame) else _to_frame(data)
    kind = fr.kinds.get(col)
    ok = kind == "logical"
    if kind == "numeric":
        v = np.asarray(fr.get(col), dtype=np.float64)
        ok = bool(np.all(np.isnan(v) | (v == 0) | (v == 1)))
    if not ok:
        chk_stop("spalte_signal", fn, col)
    return data


def _anyna(v) -> bool:
    if isinstance(v, (pd.Series, pd.DataFrame)):
        return bool(v.isna().to_numpy().any())
    a = np.asarray(v)
    # schneller Weg (1.6.4): reelle Zahlen vektorisiert, ganze Zahlen und Wahrheitswerte haben kein NA;
    # alles andere (Objekt, komplex, Datum, Text) wie bisher Element für Element
    if a.dtype.kind == "f":
        return bool(np.isnan(a).any())
    if a.dtype.kind in "iub":
        return False
    a = np.asarray(v, dtype=object).ravel()
    return any(e is None or e is pd.NA or (isinstance(e, (float, np.floating)) and math.isnan(e)) for e in a)


def chk_col_nona(data, col, fn, hint=""):
    """Spalte ohne NA (seit 1.6.4, Entscheidung 17: Basiszins- und CAPE-Reihen); ``hint`` aus der Tabelle
    ``eingabe`` (z. B. ``chk_msg("hinweis.basiszins")``) oder ``""``."""
    from ._sim_base import _Frame, _to_frame
    fr = data if isinstance(data, _Frame) else _to_frame(data)
    if _anyna(fr.get(col)):
        chk_stop("spalte_na", fn, col, hint)
    return data


def chk_nona(x, fn, arg, hint=""):
    """Werte ohne NA (Vektor oder Matrix; Entscheidung 17)."""
    if _anyna(x):
        chk_stop("na", fn, arg, hint)
    return x


# seit 1.6.4 nur ASCII-Ziffern und -Leerraum (Entscheidung 27; vorher in _tax_tariff.py)
_NUM_RE = re.compile(r"^\s*[-+]?((\d+\.?\d*|\.\d+)([eE][-+]?\d+)?|0[xX][0-9a-fA-F]+|Inf|inf|NaN|NA)\s*$", re.ASCII)


def chk_as_num(s: Any) -> float:
    """Zahl aus Text wie R ``as.numeric()`` (NA bei ungültigem Text), aber nur mit ASCII-Zeichen (Ziffern,
    Vorzeichen, Punkt, Exponent, ASCII-Leerraum); andere Zeichen (z. B. U+00A0, fremde Ziffern) ergeben NA
    (Entscheidung 27; R ``chk_as_num``)."""
    from ._r.rnum import NA_REAL as _NA
    if s is None:
        return _NA
    s = str(s)
    if not _NUM_RE.match(s):
        return _NA
    t = s.strip()
    if t == "NA":
        return _NA
    if t == "NaN":
        return math.nan
    if t.lstrip("+-").lower().startswith("0x"):
        sign = -1.0 if t.startswith("-") else 1.0
        return sign * float(int(t.lstrip("+-"), 16))
    if t.lstrip("+-") in ("Inf", "inf"):
        return -math.inf if t.startswith("-") else math.inf
    # Dezimalzahl seit 1.6.4 wie R's R_strtod (long double, C-Kern sl_r_strtod_num; B-059: float() rundet korrekt,
    # R und Julia nicht immer, z. B. "31.3198600204241" eine Stelle im letzten Bit anders); Julia chk_as_num ebenso
    from ._r.rnum import r_string_to_real
    return float(r_string_to_real(t)[0])


def chk_dots(nm, allowed, fn, taken=()):
    """Argumente aus ``**kwargs`` (seit 1.6.4, Entscheidung 21): Namen müssen in ``allowed`` stehen (sonst
    „unbekanntes Argument“) und dürfen nicht in ``taken`` (vom Aufrufer selbst gesetzt) vorkommen (sonst „doppeltes
    Argument“); R ``chk_dots``."""
    nm = [k for k in nm if k != ""]
    for k in nm:
        if k not in allowed and k not in taken:
            chk_stop("argument_unbekannt", fn, k)
    seen = set()
    for k in nm:
        if k in seen or k in taken:
            chk_stop("argument_doppelt", fn, k)
        seen.add(k)
    return nm
