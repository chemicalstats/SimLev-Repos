"""Nachbildung von imputeTS 3.4 (Teil: Interpolation), im R-Paket übernommen als ``.imputets_na_interpolation``.

Herkunft: R-Paket imputeTS 3.4 (CRAN, 2025-08-25), ``R/na_interpolation.R``,
``R/na_locf.R`` und ``src/locf.cpp``; Autoren: Steffen Moritz, Sebastian
Gatscha, Earo Wang, Ron Hause. Lizenz: GPL-3. Nach Python übertragen und
angepasst für SimLev (siehe ``python/COPYRIGHTS.md``).

Nachgebildet ist, was das R-Paket übernommen hat (``r/R/vendor_imputets.R``,
``r/src/vendor_imputets.cpp``): ``na_interpolation(x, option, maxgap, ...)``
für die Optionen ``"stine"`` (stinepack ``stinterp``, siehe
:mod:`simlev._r.stinepack`) und ``"linear"`` (``approx`` mit ``rule = 2``)
sowie ``na_locf(x, option, na_remaining, maxgap)``, das
``na_interpolation`` für NA am Rand der Stineman-Interpolation braucht (mit
dem C++-Kern ``locf`` aus ``src/locf.cpp``, der auch über ``Inf`` hinweg
fortschreibt). ``option = "spline"`` und ``na_remaining = "rm"``/``"mean"``
brechen wie in der Übernahme mit deren Meldung ab (nicht übernommen);
weitere Argumente für ``approx`` (in R über ``...``) sind nicht nachgebildet.
Eingabeprüfungen, Sonderfälle (keine NA, weniger als zwei
Werte, nicht numerisch), ``maxgap`` und alle Meldungen wie in imputeTS;
Vektoren (auch benannt, ``pandas.Series``) und numerische Matrizen
(spaltenweise, mit der Warnung von imputeTS für Spalten, die scheitern).

Nicht nachgebildet: Eingaben als data.frame, tibble oder ts (Fehler mit
deutscher Meldung);
die unendliche Rekursion von ``na_locf`` für Reihen ohne einen endlichen Wert
(R bricht mit „C stack usage … is too close to the limit“ ab) endet mit
einem eigenen Fehler.

SimLev nutzt ``na_interpolation(…, option = "stine")`` in ``.fill_na``
(``backcast``, ``backcast_fit`` mit ``fill``/``index_fill = "stine"``); R nutzt
dafür die übernommene Fassung, imputeTS selbst ist nicht mehr nötig.
"""
from __future__ import annotations

import math

import numpy as np
import pandas as pd

from . import stats as _stats
from . import stinepack as _sp
from .linalg import RError
from .rnum import NA_REAL

__all__ = ["na_interpolation", "na_locf"]

_MISSING = _sp.MISSING


def _if_str_eq(option, value):
    """R-``if (option == value)`` für ein Argument ``option``."""
    if option is None:
        raise RError("argument is of length zero")
    if isinstance(option, (list, tuple, np.ndarray, pd.Series)):
        opts = list(option)
        if len(opts) == 0:
            raise RError("argument is of length zero")
        if len(opts) > 1:
            raise RError("the condition has length > 1")
        option = opts[0]
    if option is None or (isinstance(option, float) and math.isnan(option)):
        raise RError("missing value where TRUE/FALSE needed")
    # Zahlen und Wahrheitswerte vergleicht R als Text ("1", "TRUE"): nie gleich `value`
    return isinstance(option, str) and option == value


def _is_finite_num(v):
    try:
        f = float(v)
    except (TypeError, ValueError):
        return False
    return math.isfinite(f) and not isinstance(v, (bool, np.bool_))


def _maxgap_active(maxgap):
    """``is.finite(maxgap) && maxgap >= 0``."""
    return maxgap is not None and _is_finite_num(maxgap) and float(maxgap) >= 0


def _maxgap_mask(na, maxgap):
    """Positionen, die ``maxgap`` wieder auf NA setzt (``inverse.rle`` nach ``rle``)."""
    r = _stats.rle(na)
    vals = np.array(r["values"], dtype=bool)
    lens = np.asarray(r["lengths"], dtype=np.int64)
    vals[lens <= float(maxgap)] = False
    return np.repeat(vals, lens)


def _locf_core(z, reverse):
    """C++-Kern ``locf(x, reverse)`` aus imputeTS ``src/locf.cpp``."""
    z = np.array(z, dtype=np.float64)
    n = z.size
    if not reverse:
        for i in range(1, n):
            if not math.isfinite(z[i]) and math.isfinite(z[i - 1]):
                z[i] = z[i - 1]
    else:
        for i in range(n - 2, -1, -1):
            if not math.isfinite(z[i]) and math.isfinite(z[i + 1]):
                z[i] = z[i + 1]
    return z


def _wrap(x, data):
    """Ergebnis in der Form der Eingabe (Series behält den Index)."""
    if isinstance(x, pd.Series):
        return pd.Series(data, index=x.index, name=x.name)
    return data


def _not_supported(x):
    if isinstance(x, pd.DataFrame):
        raise RError("imputeTS-Nachbildung: Eingaben als data.frame sind nicht nachgebildet.")


def _columns(x):
    """Spalten einer Matrix (2-D) oder ``None`` für Vektoren."""
    if isinstance(x, np.ndarray) and x.ndim == 2:
        return x.shape[1]
    return None


def na_locf(x, option="locf", na_remaining="rev", maxgap=math.inf):
    """Fehlende Werte durch den letzten (``"locf"``) oder nächsten (``"nocb"``) Wert ersetzen (imputeTS ``na_locf``).

    Args:
        x: numerischer Vektor (oder numerische Matrix, spaltenweise).
        option: ``"locf"`` (Standard) oder ``"nocb"``.
        na_remaining: Umgang mit verbleibenden NA: ``"rev"`` (Standard, aus
            der Gegenrichtung füllen) oder ``"keep"``.
        maxgap: Lücken mit mehr als ``maxgap`` NA bleiben NA (Standard: ``Inf``).

    Returns:
        Vektor (float-Array bzw. ``Series``) wie die Eingabe.
    """
    return _na_locf(x, option, na_remaining, maxgap, 0)


def _na_locf(x, option, na_remaining, maxgap, depth):
    _not_supported(x)
    ncol = _columns(x)
    if ncol is not None and ncol > 1:
        data = np.array(x, dtype=np.float64)
        for i in range(ncol):
            col = data[:, i].copy()
            if not np.isnan(col).any():
                continue
            try:
                data[:, i] = _na_locf(col, option, na_remaining, maxgap, depth)
            except ValueError as cond:
                _stats._warn("na_locf: No imputation performed for column %d of the input dataset.\n"
                             "                Reason: %s" % (i + 1, cond))
        return data
    kind, vals, _ = _sp.classify(x)
    missindx = _sp._isna_vals(kind, vals)
    if not missindx.any():
        return np.asarray(x) if isinstance(x, (list, tuple)) else x
    if missindx.all():
        raise RError("Input data has only NA values. At least 1 non-NA data point required in the time series to apply na_locf.")
    if kind != "num":
        raise RError("Input x is not numeric.")
    data = vals.copy()
    if _if_str_eq(option, "locf"):
        imputed = _locf_core(data, False)
    elif _if_str_eq(option, "nocb"):
        imputed = _locf_core(data, True)
    else:
        raise RError("Wrong parameter 'option' given. Value must be either 'locf' or 'nocb'.")
    data[missindx] = imputed[missindx]
    if not np.isnan(data).any() or _if_str_eq(na_remaining, "keep"):
        pass
    elif _if_str_eq(na_remaining, "rev"):
        if depth > 200:
            raise RError("imputeTS-Nachbildung: na_locf ohne endlichen Wert (R: unendliche Rekursion, "
                         "„C stack usage … is too close to the limit“).")
        if _if_str_eq(option, "locf"):
            data = np.asarray(_na_locf(data, "nocb", "rev", math.inf, depth + 1), dtype=np.float64)
        elif _if_str_eq(option, "nocb"):
            data = np.asarray(_na_locf(data, "locf", "rev", math.inf, depth + 1), dtype=np.float64)
    elif _if_str_eq(na_remaining, "rm"):
        raise RError('imputeTS-Uebernahme: na_locf mit na_remaining = "rm" (na_remove) nicht uebernommen')
    elif _if_str_eq(na_remaining, "mean"):
        raise RError('imputeTS-Uebernahme: na_locf mit na_remaining = "mean" (na_mean) nicht uebernommen')
    else:
        raise RError("Wrong parameter 'na_remaining' given. Value must be either 'keep', 'rm', 'mean' or 'rev'.")
    if _maxgap_active(maxgap):
        if ncol is not None:
            raise RError("'x' must be a vector of an atomic type")
        data[_maxgap_mask(missindx, maxgap)] = NA_REAL
    if ncol is not None:
        return data.reshape(-1, 1)
    return _wrap(x, data)


def na_interpolation(x, option="linear", maxgap=math.inf, yp=_MISSING, method=_MISSING):
    """Fehlende Werte interpolieren (imputeTS ``na_interpolation``).

    Args:
        x: numerischer Vektor (auch ``Series``) oder numerische Matrix
            (spaltenweise; jede Spalte ohne ``yp``/``method``).
        option: ``"linear"`` (Standard, ``approx`` mit ``rule = 2``) oder
            ``"stine"`` (Stineman, stinepack ``stinterp``); ``"spline"``
            bricht wie die Übernahme in R ab (nicht übernommen).
        maxgap: Lücken mit mehr als ``maxgap`` NA bleiben NA (Standard: ``Inf``).
        yp, method: an ``stinterp`` weitergereicht (nur ``option = "stine"``).

    Returns:
        Vektor wie die Eingabe; ganzzahlige Eingaben mit NA werden double.
    """
    _not_supported(x)
    ncol = _columns(x)
    if ncol is not None and ncol > 1:
        data = np.array(x, dtype=np.float64)
        for i in range(ncol):
            col = data[:, i].copy()
            if not np.isnan(col).any():
                continue
            try:
                data[:, i] = na_interpolation(col, option, maxgap)
            except ValueError as cond:
                _stats._warn("na_interpolation: No imputation performed for column %d of the input dataset.\n"
                             "                Reason: %s" % (i + 1, cond))
        return data
    kind, vals, _ = _sp.classify(x)
    missindx = _sp._isna_vals(kind, vals)
    if not missindx.any():
        return np.asarray(x) if isinstance(x, (list, tuple)) else x
    if int((~missindx).sum()) < 2:
        raise RError("At least 2 non-NA data points required in the time series to apply na_interpolation.")
    if kind != "num":
        raise RError("Input x is not numeric.")
    n = vals.size
    indx = np.flatnonzero(~missindx) + 1               # 1-basiert wie allindx[!missindx]
    data_vec = vals
    allx = np.arange(1, n + 1, dtype=np.float64)
    if _if_str_eq(option, "linear"):
        if yp is not _MISSING or method is not _MISSING:
            raise RError("imputeTS-Nachbildung: weitere Argumente für approx sind nicht nachgebildet.")
        interp = np.asarray(_stats.approx(indx.astype(np.float64), data_vec[indx - 1], xout=allx, rule=2)["y"],
                            dtype=np.float64)
    elif _if_str_eq(option, "spline"):
        raise RError('imputeTS-Uebernahme: na_interpolation mit option = "spline" nicht uebernommen')
    elif _if_str_eq(option, "stine"):
        interp = np.asarray(_sp.stinterp(indx.astype(np.float64), data_vec[indx - 1], allx, yp=yp, method=method)["y"],
                            dtype=np.float64)
        if np.isnan(interp).any():
            interp = np.asarray(na_locf(interp, na_remaining="rev"), dtype=np.float64)
    else:
        raise RError("Wrong parameter 'option' given. Value must be either 'linear', 'spline' or 'stine'.")
    data = data_vec.copy()
    data[missindx] = interp[missindx]
    if _maxgap_active(maxgap):
        if ncol is not None:
            raise RError("'x' must be a vector of an atomic type")
        data[_maxgap_mask(missindx, maxgap)] = NA_REAL
    if ncol is not None:
        return data.reshape(-1, 1)
    return _wrap(x, data)


from .base import quiet_fp  # noqa: E402

quiet_fp(globals(), ["na_interpolation", "na_locf"])
_sp._quiet_all(globals(), ["na_interpolation", "na_locf"])
