"""Abhängigkeiten, Tail-Risiko und Drittvariablen (Port von ``r/R/dependence.R``).

- :func:`dependence_analysis`  Korrelationen (Pearson, Spearman, Kendall),
  empirische Tail-Abhängigkeit, Exceedance-Korrelationen, Copula-Fits,
  rollierende Korrelation, DCC(1,1) und bedingte Analyse nach Regimen von
  Drittvariablen mit Block-Bootstrap-Konfidenzintervallen
- :func:`copula_fit`           Gauss, t, Clayton, Gumbel, Frank inkl. Rotationen
- :func:`tail_dependence`      empirische Tail-Koeffizienten und
  Exceedance-Korrelationen je Quantil
- :func:`dependence_dcc`              DCC(1,1) nach Engle (2002)
- :func:`quantile_regression`         lineare Quantilsregression
- :func:`tail_regression`      Renditequantile in Abhängigkeit von Drittvariablen
- :func:`tail_covar`       CoVaR / Delta-CoVaR (Adrian & Brunnermeier 2016)
- :func:`dependence_validate`  erhalten Bootstrap-Pfade die Abhängigkeitsstruktur?
- :func:`regime_subset`        Zeilen eines Regimes für Stress-Bootstraps

Drittvariablen gehen immer verzögert ein: Die Rendite der Periode t wird dem
Zustand zugeordnet, der am Ende der Periode t - 1 bekannt war.
"""
from __future__ import annotations

import math
import sys
import warnings
from collections.abc import Mapping

import numpy as np
import pandas as pd

from . import _dependence_core as _core
from ._r import fmt as _fmt
from ._r.base import env_from_caller
from ._r import libm as _libm
from ._r.rlist import RList
from ._r.rnum import LD, r_mean, r_pow, r_pow_vec, r_sd, r_sum

__all__ = ["copula_fit", "tail_dependence", "dependence_dcc", "dependence_analysis", "quantile_regression",
           "tail_regression", "tail_covar", "dependence_validate", "regime_subset",
           "SimLevDependence", "SimLevTailRegression", "SimLevCoVaR"]

_NAN = _fmt.NA_REAL      # R's NA_real_ (Standard hier; arithmetisches NaN: _RNAN)
_RNAN = float("nan")     # R's NaN

_PI = math.pi
_MISSING = object()


# ═════════════════════════════════════════════════════════════════════════════
# Zugriff auf gemeinsame Bausteine (andere Bearbeiter; erst beim Aufruf laden)
# ═════════════════════════════════════════════════════════════════════════════

def _stats():
    from ._r import stats
    return stats


def _linalg():
    from ._r import linalg
    return linalg


def _sl():
    from . import _lib
    return _lib


def _to_date(x, what="date"):
    from .data_prep import _to_date as f
    return f(x, what)


def _fill_na(x, method="locf", keep_leading=True):
    from .backcast import _fill_na as f
    return np.asarray(f(x, method, keep_leading=keep_leading), dtype=np.float64)


def _roll_var(x, n):
    from .signals import _roll_var as f
    return np.asarray(f(x, n), dtype=np.float64)


def _roll_cov(x, y, n):
    from .signals import _roll_cov as f
    return np.asarray(f(x, y, n), dtype=np.float64)


def _roll_mean(x, n):
    from .signals import _roll_mean as f
    return np.asarray(f(x, n), dtype=np.float64)


def _boot():
    from . import bootstrap
    return bootstrap


def _sl():
    """Zufall der C-Bibliothek slc (Entwurf C.5): ``simlev._lib``."""
    from . import _lib
    return _lib


def _boot_idx_stationary(n_src, n_out, L, stream):
    from ._lib_models import boot_idx_stationary
    return boot_idx_stationary(n_src, n_out, L, stream=stream)


def message(text):
    """R-``message()``: Text mit Zeilenumbruch auf ``sys.stderr``."""
    sys.stderr.write(str(text) + "\n")
    sys.stderr.flush()


# ═════════════════════════════════════════════════════════════════════════════
# Kleine R-Hilfen (base-Semantik)
# ═════════════════════════════════════════════════════════════════════════════

def _rnan_of(vals):
    """NaN-Ergebnis von R's ``min()``/``max()``: ein NA hat Vorrang, sonst das letzte NaN; ``None`` ohne NaN."""
    r = None
    for v in vals:
        if math.isnan(v):
            if not _fmt._is_rnan(v):
                return v
            r = v
    return r


def _rmin(*xs):
    """R ``min()``: NA/NaN pflanzt sich fort (NA vor NaN)."""
    vals = [float(v) for x in xs for v in np.atleast_1d(np.asarray(x, dtype=np.float64)).ravel()]
    r = _rnan_of(vals)
    if r is not None:
        return r
    return min(vals) if vals else math.inf


def _rmax(*xs):
    """R ``max()``: NA/NaN pflanzt sich fort (NA vor NaN)."""
    vals = [float(v) for x in xs for v in np.atleast_1d(np.asarray(x, dtype=np.float64)).ravel()]
    r = _rnan_of(vals)
    if r is not None:
        return r
    return max(vals) if vals else -math.inf


def _num(x):
    """``as.numeric(x)`` für Spalten/Vektoren (nicht Zahlen -> NA)."""
    if isinstance(x, (pd.Series, pd.Index)):
        x = x.to_numpy()
    a = np.asarray(x)
    if a.dtype.kind in "fiub":
        return a.astype(np.float64).ravel()
    out = np.empty(a.size)
    for i, v in enumerate(a.ravel()):
        try:
            out[i] = _NAN if v is None else float(v)
        except (TypeError, ValueError):
            out[i] = _NAN
    return out


def _rank_avg(x):
    """``rank(x, ties.method = "average")`` für endliche Werte."""
    x = np.asarray(x, dtype=np.float64).ravel()
    n = x.size
    o = np.argsort(x, kind="stable")
    xs = x[o]
    out = np.empty(n)
    i = 0
    while i < n:
        j = i
        while j + 1 < n and xs[j + 1] == xs[i]:
            j += 1
        out[o[i:j + 1]] = (i + j + 2) / 2.0
        i = j + 1
    return out


def _pobs(x):
    """Pseudo-Beobachtungen (Ränge / (n + 1))."""
    x = np.asarray(x, dtype=np.float64).ravel()
    return _rank_avg(x) / (x.size + 1)


def _combn2(k):
    """``combn(k, 2)`` als Liste von (i, j) (0-basiert) in R-Reihenfolge."""
    return [(i, j) for i in range(k) for j in range(i + 1, k)]


def _colmeans(X):
    """``colMeans`` (long-double-Summe / n, ohne Korrekturdurchlauf)."""
    X = np.asarray(X, dtype=np.float64)
    n = X.shape[0]
    if n == 0:
        return np.full(X.shape[1], _RNAN)
    s = np.cumsum(X.astype(LD), axis=0)[-1]
    return (s / LD(n)).astype(np.float64)


def _scale1(x):
    """``scale(x)[, 1]`` für einen Vektor."""
    x = np.asarray(x, dtype=np.float64)
    xc = x - _colmeans(x.reshape(-1, 1))[0]
    v = xc[~np.isnan(xc)]
    s = math.sqrt(r_sum(v * v) / max(1, v.size - 1))
    return xc / s


def _complete_rows(*cols):
    ok = np.ones(len(cols[0]) if cols else 0, dtype=bool)
    for c in cols:
        a = np.asarray(c)
        if a.dtype.kind == "M":
            ok &= ~np.isnat(a)
        elif a.dtype.kind in "fc":
            ok &= ~np.isnan(a)
        elif a.dtype == object:
            ok &= np.array([not (v is None or (isinstance(v, float) and math.isnan(v))) for v in a], dtype=bool)
    return ok


def _fmt1(x):
    """``format(x)`` eines Skalars bzw. ``paste(format(x), collapse = ", ")``."""
    r = _fmt.format(x)
    if isinstance(r, str):
        return r
    return ", ".join(str(s) for s in np.asarray(r, dtype=object).ravel())


def _date_str(d):
    s = _fmt.format_date(np.asarray([d], dtype="datetime64[D]"))
    return str(np.asarray(s, dtype=object).ravel()[0])


def _sprintf(fmt, *args):
    r = _fmt.sprintf(fmt, *args)
    if isinstance(r, str):
        return r
    a = np.asarray(r, dtype=object).ravel()
    return a.tolist()


def _sprintf_vec(fmt, *args):
    r = _fmt.sprintf(fmt, *args)
    if isinstance(r, str):
        return [r]
    return [str(s) for s in np.asarray(r, dtype=object).ravel()]


def _dates_arr(x):
    return np.asarray(x, dtype="datetime64[D]")


def _days(d):
    d = _dates_arr(d)
    out = (d - np.datetime64("1970-01-01", "D")).astype(np.int64).astype(np.float64)
    out[np.isnat(d)] = _NAN
    return out


def _seq_len_out(a, b, n):
    """``seq(a, b, length.out = n)`` (seq.default)."""
    if n == 1:
        return np.array([a], dtype=np.float64)
    if n == 2:
        return np.array([a, b], dtype=np.float64)
    if a == b:
        return np.full(n, a, dtype=np.float64)
    n1 = n - 1
    by = (b - a) / n1
    mid = [a + i * by for i in range(1, n1)]
    return np.array([a] + mid + [b], dtype=np.float64)


def _seq_int_len_out(a, b, n):
    """``seq.int(a, b, length.out = n)`` (C-Code aus seq.c)."""
    out = np.empty(n)
    if n > 0:
        out[0] = a
    if n > 1:
        out[n - 1] = b
    if n > 2:
        by = (b - a) / float(n - 1)
        for i in range(1, n - 1):
            out[i] = a + float(i) * by if i < n // 2 else b - float(n - 1 - i) * by
    return out


def _bincode(x, breaks, right=True, include_lowest=False):
    """``.bincode`` (Intervallnummern 1..; 0 = NA)."""
    x = np.asarray(x, dtype=np.float64).ravel()
    br = np.asarray(breaks, dtype=np.float64)
    nb1 = br.size - 1
    lft = not right
    code = np.zeros(x.size, dtype=np.int64)
    for i, xi in enumerate(x.tolist()):
        if math.isnan(xi):
            continue
        lo, hi = 0, nb1
        if xi < br[lo] or br[hi] < xi or (xi == br[hi if lft else lo] and not include_lowest):
            continue
        while hi - lo >= 2:
            new = (hi + lo) // 2
            if xi > br[new] or (lft and xi == br[new]):
                lo = new
            else:
                hi = new
        code[i] = lo + 1
    return code


def _cut_n(x, k):
    """``cut(x, k, labels = FALSE)`` mit einer Intervallanzahl ``k``."""
    x = np.asarray(x, dtype=np.float64)
    nb = int(k + 1)
    fin = x[~np.isnan(x)]
    rx = (float(np.min(fin)), float(np.max(fin)))
    dx = rx[1] - rx[0]
    if dx == 0:
        dx = abs(rx[0]) if rx[0] != 0 else 1.0
        br = _seq_int_len_out(rx[0] - dx / 1000, rx[1] + dx / 1000, nb)
    else:
        br = _seq_int_len_out(rx[0], rx[1], nb)
        br[0] = rx[0] - dx / 1000
        br[nb - 1] = rx[1] + dx / 1000
    return _bincode(x, br, right=True)


def _as_matrix(X):
    """Matrix und Spaltennamen (``as.matrix``)."""
    if isinstance(X, pd.DataFrame):
        return X.to_numpy(dtype=np.float64), [str(c) for c in X.columns]
    if isinstance(X, pd.Series):
        return X.to_numpy(dtype=np.float64).reshape(-1, 1), None
    a = np.asarray(X, dtype=np.float64)
    if a.ndim == 1:
        a = a.reshape(-1, 1)
    return a, None


# ── Statistik-Bausteine (über simlev._r.stats/linalg und die C-Bibliothek simlev._lib) ──

def _quantile(x, probs, na_rm=False):
    return _stats().quantile(np.asarray(x, dtype=np.float64), probs, na_rm=na_rm, names=False)


def _q1(x, p, na_rm=False):
    r = np.atleast_1d(np.asarray(_quantile(x, [p], na_rm=na_rm), dtype=np.float64))
    return float(r[0])


def _cor(x, y=None, method="pearson"):
    return _stats().cor(x, y, method=method)


def _cor1(x, y, method="pearson"):
    r = _cor(np.asarray(x, dtype=np.float64), np.asarray(y, dtype=np.float64), method=method)
    return float(np.asarray(r, dtype=np.float64).ravel()[0])


def _cormat(X, method="pearson"):
    r = _cor(np.asarray(X, dtype=np.float64), None, method=method)
    if isinstance(r, pd.DataFrame):
        r = r.to_numpy(dtype=np.float64)
    return np.asarray(r, dtype=np.float64)


def _median(x, na_rm=False):
    return float(_stats().median(np.asarray(x, dtype=np.float64), na_rm=na_rm))


def _optimize(f, lower, upper):
    o = _stats().optimize(f, (lower, upper))
    return float(o["minimum"]), float(o["objective"])


# Verteilungen der C-Bibliothek slc (Entwurf B.3, B.4), wie .sl_qnorm usw. in R
def _qnorm(p):
    return _sl().qnorm(p)


def _qt(p, df):
    return _sl().qt(p, df)


def _pt(q, df):
    return _sl().pt(q, df)


def _lgamma(x):
    return float(_sl().lgamma(x))


def _plogis(x):
    return float(_sl().plogis(x))


def _qlogis(p):
    return float(_sl().qlogis(p))


# ═════════════════════════════════════════════════════════════════════════════
# Renditen und Pseudo-Beobachtungen
# ═════════════════════════════════════════════════════════════════════════════

def _as_frame(data):
    if isinstance(data, pd.DataFrame):
        return data
    if isinstance(data, Mapping):
        return pd.DataFrame(dict(data))
    raise TypeError


def _dep_sort_dates(data, what="data"):
    """Zeilen nach Datum ordnen (Port von ``.dep_sort_dates``).

    Fehlende oder doppelte Daten sind ein Fehler, unsortierte Zeilen werden
    mit Hinweis aufsteigend sortiert; ``date`` wird per ``_to_date`` in
    ``datetime64[D]`` gewandelt.
    """
    data = data.copy()
    d = _to_date(data["date"], "%s: Spalte 'date'" % what)
    data["date"] = d
    na = np.isnat(d)
    if na.any():
        idx = (np.nonzero(na)[0][:5] + 1).tolist()
        raise ValueError("%s: Spalte 'date' enthält fehlende Daten (Zeile %s)." % (what, ", ".join(str(i) for i in idx)))
    days = _days(d)
    _, first = np.unique(days, return_index=True)
    if first.size < days.size:
        seen = set()
        dup = []
        dset = set()
        for v in days.tolist():
            if v in seen and v not in dset:
                dup.append(v)
                dset.add(v)
            seen.add(v)
        txt = ", ".join(_date_str(np.datetime64("1970-01-01", "D") + np.timedelta64(int(v), "D")) for v in dup[:5])
        more = " und %d weitere" % (len(dup) - 5) if len(dup) > 5 else ""
        raise ValueError("%s: doppelte Daten in 'date' (%s%s); erwartet ist eine Zeile je Datum." % (what, txt, more))
    if np.any(days[1:] < days[:-1]):
        message("%s: Zeilen sind nicht nach 'date' sortiert und werden aufsteigend sortiert." % what)
        o = np.argsort(days, kind="stable")
        data = data.iloc[o]
    return data


def _dep_check_prices(v, a, d):
    """Kursspalte prüfen: vorhandene Werte müssen positiv und endlich sein."""
    v = np.asarray(v, dtype=np.float64)
    bad = np.nonzero(~np.isnan(v) & (~np.isfinite(v) | (v <= 0)))[0]
    if bad.size:
        more = " und %d weitere Werte" % (bad.size - 1) if bad.size > 1 else ""
        raise ValueError("Kursspalte '%s': Kurse müssen positiv und endlich sein, gefunden %s am %s%s "
                         "(fehlende Kurse als NA angeben)." % (a, _fmt1(float(v[bad[0]])), _date_str(_dates_arr(d)[bad[0]]), more))
    return v


def _period_keys(d, frequency):
    """``format(d, "%G-%V")`` bzw. ``"%Y-%m"`` als vergleichbare Schlüssel."""
    s = _fmt.format_date(_dates_arr(d), "%G-%V" if frequency == "week" else "%Y-%m")
    return [str(v) for v in np.asarray(s, dtype=object).ravel()]


def _dep_returns(data, assets, conditions=None, frequency="week", drop_flat=True):
    """Periodenrenditen und verzögerte Zustandsvariablen (Port von ``.dep_returns``)."""
    if not isinstance(data, pd.DataFrame) or "date" not in data.columns:
        raise ValueError("data.frame mit Spalte 'date' erwartet.")
    assets = _as_names(assets)
    conditions = _as_names(conditions)
    miss = [c for c in dict.fromkeys(assets + conditions) if c not in data.columns]
    if miss:
        raise ValueError("Spalten fehlen: %s" % ", ".join(miss))
    data = _dep_sort_dates(data)
    d = _dates_arr(data["date"].to_numpy())
    nr = d.size
    if frequency == "day":
        end = np.arange(nr)
    else:
        key = _period_keys(d, frequency)
        end = np.array([i for i in range(nr) if i == nr - 1 or key[i + 1] != key[i]], dtype=np.int64)
    V = np.empty((nr, len(assets)))
    for j, a in enumerate(assets):
        V[:, j] = _fill_na(_dep_check_prices(_num(data[a]), a, d), "locf", keep_leading=True)
    V = V[end, :]
    if V.shape[0] >= 1:
        lv = _libm.log(V) if V.size else V
        R = lv[1:, :] - lv[:-1, :]
    else:
        R = np.zeros((0, len(assets)))
    out = pd.DataFrame({"date": d[end][1:]})
    for j, a in enumerate(assets):
        out[a] = R[:, j]
    for cn in conditions:
        cv = _fill_na(_num(data[cn]), "locf", keep_leading=True)[end]
        out[cn] = cv[:-1] if cv.size else cv
    ok = ~np.isnan(R).any(axis=1) if R.size else np.ones(R.shape[0], dtype=bool)
    if drop_flat and frequency == "day":
        ok &= (np.abs(R) > 0).sum(axis=1) > 0
    out = out.loc[ok].reset_index(drop=True)
    return out


def _as_names(x):
    if x is None:
        return []
    if isinstance(x, str):
        return [x]
    return [str(v) for v in (x.tolist() if isinstance(x, (np.ndarray, pd.Series, pd.Index)) else x)]


def _kendall(x, y=None):
    """Kendalls Tau-b; für eine Matrix die Korrelationsmatrix (Port von ``.kendall``).

    Bei nicht endlichen Werten wie ``stats::cor(method = "kendall")``.
    """
    if y is None and (isinstance(x, pd.DataFrame) or (isinstance(x, np.ndarray) and x.ndim == 2)):
        if isinstance(x, pd.DataFrame):
            names = [str(c) for c in x.columns]
            A = x.to_numpy(dtype=np.float64)
        else:
            names = None
            A = np.asarray(x, dtype=np.float64)
        if not np.isfinite(A).all():
            r = _cor(A if names is None else pd.DataFrame(A, columns=names), None, method="kendall")
            return r
        k = A.shape[1]
        M = np.eye(k)
        for i in range(k - 1):
            for j in range(i + 1, k):
                M[i, j] = M[j, i] = _core.kendall_tau_core(A[:, i], A[:, j])
        if names is not None:
            return pd.DataFrame(M, index=names, columns=names)
        return M
    xa = _num(x)
    ya = _num(y)
    if not np.isfinite(xa).all() or not np.isfinite(ya).all():
        return _cor1(xa, ya, method="kendall")
    return _core.kendall_tau_core(xa, ya)


# ═════════════════════════════════════════════════════════════════════════════
# Copulas
# ═════════════════════════════════════════════════════════════════════════════

def _fam_parts(family):
    import re
    rot = re.sub(r"^[a-z]+_?", "", family, count=1)
    base = re.sub(r"_.*$", "", family, count=1)
    return base, rot


def _cop_ll(family, par, u, v):
    """Log-Dichte einer Copula (Summe), Familien inkl. Rotationen (``.cop_ll``)."""
    base, rot = _fam_parts(family)
    u = np.asarray(u, dtype=np.float64)
    v = np.asarray(v, dtype=np.float64)
    par = [float(p) for p in np.atleast_1d(np.asarray(par, dtype=np.float64))]
    if rot == "180":
        u = 1 - u
        v = 1 - v
    elif rot == "90":
        u = 1 - u
    elif rot == "270":
        v = 1 - v
    lg = _libm.log
    l1p = _libm.log1p
    with np.errstate(all="ignore"):
        if base == "gaussian":
            r = par[0]
            x = np.asarray(_qnorm(u), dtype=np.float64)
            y = np.asarray(_qnorm(v), dtype=np.float64)
            ll = _cop_g_ll(r, x, y, x * x, y * y)
        elif base == "t":                     # N2: Hilfen _cop_t_c0, _cop_t_ll
            r, nu = par[0], par[1]
            x = np.asarray(_qt(u, nu), dtype=np.float64)
            y = np.asarray(_qt(v, nu), dtype=np.float64)
            ll = _cop_t_ll(r, nu, _cop_t_c0(nu), x, y, x * x, y * y,
                           (nu + 1) / 2 * (l1p(x * x / nu) + l1p(y * y / nu)))
        elif base == "clayton":
            th = par[0]
            ll = (_libm.log1p(th) - (1 + th) * (lg(u) + lg(v))
                  - (2 + 1 / th) * lg(r_pow_vec(u, -th) + r_pow_vec(v, -th) - 1))
        elif base == "gumbel":
            th = par[0]
            a = -lg(u)
            b = -lg(v)
            A = r_pow_vec(a, th) + r_pow_vec(b, th)
            A1 = r_pow_vec(A, 1 / th)
            ll = (-A1 + a + b + (th - 1) * (lg(a) + lg(b)) + (2 / th - 2) * lg(A)
                  + l1p((th - 1) / A1))
        elif base == "frank":
            th = par[0]
            if abs(th) < 1e-8:
                return 0.0
            e1 = -_libm.expm1(-th)
            ll = (lg(th * e1) - th * (u + v)
                  - 2 * lg(np.abs(e1 - (-_libm.expm1(-th * u)) * (-_libm.expm1(-th * v)))))
        else:
            raise ValueError("Unbekannte Copula-Familie '%s'." % family)
    s = r_sum(ll)
    return -1e10 if not math.isfinite(s) else s


# N2: Teile der Log-Dichten der Gauss- und t-Copula je Beobachtung (wie .cop_g_ll, .cop_t_ll in R), auch für die
# Profil-Likelihood in _cop_fit_t; x2 = x^2, y2 = y^2, B = (nu + 1)/2 (log1p(x^2/nu) + log1p(y^2/nu)).
def _cop_g_ll(r, x, y, x2, y2):
    r2 = r * r
    with np.errstate(all="ignore"):
        return -0.5 * _libm.log(1 - r2) - (r2 * (x2 + y2) - 2 * r * x * y) / (2 * (1 - r2))


def _cop_t_ll(r, nu, c0, x, y, x2, y2, B):
    r2 = r * r
    with np.errstate(all="ignore"):
        c = c0 - 0.5 * _libm.log(1 - r2)
        return c - (nu + 2) / 2 * _libm.log1p((x2 - 2 * r * x * y + y2) / (nu * (1 - r2))) + B


def _cop_t_c0(nu):
    """N2: c0(nu) = lgamma((nu+2)/2) + lgamma(nu/2) - 2 lgamma((nu+1)/2); für nu > 64 asymptotisch (``.cop_t_c0``)."""
    if nu <= 64:
        return _lgamma((nu + 2) / 2) + _lgamma(nu / 2) - 2 * _lgamma((nu + 1) / 2)
    a = nu / 2
    ia2 = 1 / (a * a)
    return ((((31 / 9216 * ia2 - 17 / 7168) * ia2 + 1 / 320) * ia2 - 1 / 96) * ia2 + 1 / 4) / a


def _cop_fit_t(u, v):
    """N2: t-Copula per Profil-Likelihood in nu (``.cop_fit_t``); Ergebnis [atanh rho, nu, -loglik]."""
    best = [0.0, math.inf, math.inf]

    def prof(nu):
        if math.isinf(nu):
            x = np.asarray(_qnorm(u), dtype=np.float64)
            y = np.asarray(_qnorm(v), dtype=np.float64)
            x2, y2 = x * x, y * y

            def g(th):
                s = r_sum(_cop_g_ll(math.tanh(th), x, y, x2, y2))
                return 1e10 if not math.isfinite(s) else -s
        else:
            x = np.asarray(_qt(u, nu), dtype=np.float64)
            y = np.asarray(_qt(v, nu), dtype=np.float64)
            x2, y2 = x * x, y * y
            B = (nu + 1) / 2 * (_libm.log1p(x2 / nu) + _libm.log1p(y2 / nu))
            c0 = _cop_t_c0(nu)

            def g(th):
                s = r_sum(_cop_t_ll(math.tanh(th), nu, c0, x, y, x2, y2, B))
                return 1e10 if not math.isfinite(s) else -s
        o = _stats().optimize(g, (-20.0, 20.0), tol=1e-10)
        mn, ob = float(o["minimum"]), float(o["objective"])
        if ob < best[2]:
            best[0], best[1], best[2] = mn, nu, ob
        return ob

    nus = [2 + 2.0 ** k for k in range(-4, 13)] + [math.inf]
    K = len(nus)
    f = [prof(nu) for nu in nus]
    k = int(np.argmin(f)) + 1                       # 1-basiert wie which.min
    if k >= K - 1:
        _stats().optimize(lambda s: prof(math.inf if s == 0 else 1 / s), (0.0, 1 / nus[K - 3]), tol=1e-9)
    else:
        lo = _libm.log(nus[0] - 2) - 30 if k == 1 else _libm.log(nus[k - 2] - 2)
        _stats().optimize(lambda t2: prof(2 + _libm.exp(t2)), (lo, _libm.log(nus[k] - 2)), tol=1e-6)
    return best


def _cop_lambda(family, par):
    """Tail-Koeffizienten einer Copula (unten, oben) als Series."""
    base, rot = _fam_parts(family)
    par = [float(p) for p in np.atleast_1d(np.asarray(par, dtype=np.float64))]
    if base in ("gaussian", "frank"):
        lam = [0.0, 0.0]
    elif base == "t":
        rho, nu = par[0], par[1]
        v = 2 * float(_pt(-math.sqrt((nu + 1) * (1 - rho) / (1 + rho)), nu + 1))
        lam = [v, v]
    elif base == "clayton":
        lam = [r_pow(2.0, -1 / par[0]), 0.0]
    elif base == "gumbel":
        lam = [0.0, 2 - r_pow(2.0, 1 / par[0])]
    else:
        lam = []
    if rot == "180":
        lam = lam[::-1]
    if rot in ("90", "270"):
        lam = [0.0, 0.0]
    return pd.Series(lam, index=["lower", "upper"], dtype=np.float64)


def _finite_pairs(x, y):
    x = _num(x)
    y = _num(y)
    ok = np.isfinite(x) & np.isfinite(y)
    return x[ok], y[ok]


def copula_fit(x, y, *, families=None):
    """Copulas an zwei Reihen anpassen (Pseudo-ML auf Rängen, Auswahl per AIC).

    Die t-Copula wird über die Profil-Likelihood in den Freiheitsgraden geschätzt (Raster
    nu = 2 + 2^k, k = -4 ... 12, und nu = Inf als Gauss-Grenzfall, danach eindimensionale Suche);
    bei nu > 500 steht in ``par2`` 500, ``loglik`` gilt für das gefundene nu.

    Args:
        x, y: Numerische Vektoren gleicher Länge (nur die Ränge zählen); Paare
            mit nicht endlichen Werten werden entfernt; mindestens 20 Paare.
        families: Familien ``"gaussian"``, ``"t"``, ``"clayton"``,
            ``"gumbel"``, ``"frank"``, optional mit Rotation ``"_90"``,
            ``"_180"``, ``"_270"`` (nur Clayton/Gumbel). ``None`` = Auswahl
            nach dem Vorzeichen von Kendalls Tau.

    Returns:
        ``pandas.DataFrame`` je Familie (aufsteigend nach AIC): ``family``,
        ``par1``, ``par2``, ``loglik``, ``aic``, ``bic``, ``lambda_lower``,
        ``lambda_upper``; ``attrs["tau"]``, ``attrs["n"]``.
    """
    lx, ly = len(np.atleast_1d(x)), len(np.atleast_1d(y))
    if lx != ly:
        raise ValueError("copula_fit: x und y müssen gleich lang sein (%d bzw. %d Werte)." % (lx, ly))
    x, y = _finite_pairs(x, y)
    n = x.size
    if n < 20:
        raise ValueError("copula_fit: mindestens 20 Beobachtungen nötig.")
    if families is not None:
        import re
        families = _as_names(families)
        bad = []
        for f in families:
            base = re.sub(r"_.*$", "", f, count=1)
            rot = re.sub(r"^[^_]*_", "", f, count=1) if "_" in f else ""
            if (base not in ("gaussian", "t", "clayton", "gumbel", "frank") or rot not in ("", "90", "180", "270")
                    or (base in ("gaussian", "t", "frank") and rot != "")):
                bad.append(f)
        if bad:
            raise ValueError("copula_fit: unbekannte Familie %s; erlaubt sind gaussian, t, frank sowie clayton und gumbel "
                             "mit optionaler Rotation _90, _180 oder _270." % ", ".join("'%s'" % b for b in bad))
    u = _pobs(x)
    v = _pobs(y)
    tau = _kendall(x, y)
    if not math.isfinite(tau):
        raise ValueError("copula_fit: x oder y ist konstant (keine Rangstreuung); keine Copula schätzbar.")
    if families is None:
        families = (["gaussian", "t", "clayton", "gumbel", "frank", "clayton_180", "gumbel_180"] if tau >= 0
                    else ["gaussian", "t", "frank", "clayton_90", "clayton_270", "gumbel_90", "gumbel_270"])
    # N2: Startwert rho0 entfällt (t-Copula per Profil-Likelihood, _cop_fit_t)
    rows = []
    for fam in families:
        base = fam.split("_", 1)[0]

        def f(p, fam=fam):
            return -_cop_ll(fam, p, u, v)
        if base == "gaussian":
            mn, ob = _optimize(lambda r: f([r]), -0.995, 0.995)
            par, nll, k = [mn, _NAN], ob, 1
        elif base == "t":                     # N2: Profil-Likelihood in nu
            o = _cop_fit_t(u, v)
            par, nll, k = [math.tanh(o[0]), min(o[1], 500)], o[2], 2
        elif base == "clayton":
            mn, ob = _optimize(lambda lt: f([_libm.exp(lt)]), math.log(1e-4), math.log(60))
            par, nll, k = [_libm.exp(mn), _NAN], ob, 1
        elif base == "gumbel":
            mn, ob = _optimize(lambda lt: f([1 + _libm.exp(lt)]), math.log(1e-5), math.log(60))
            par, nll, k = [1 + _libm.exp(mn), _NAN], ob, 1
        else:
            mn, ob = _optimize(lambda th: f([th]), -60, 60)
            par, nll, k = [mn, _NAN], ob, 1
        lam = _cop_lambda(fam, par)
        rows.append({"family": fam, "par1": par[0], "par2": par[1], "loglik": -nll,
                     "aic": 2 * k + 2 * nll, "bic": math.log(n) * k + 2 * nll,
                     "lambda_lower": float(lam.iloc[0]), "lambda_upper": float(lam.iloc[1])})
    out = pd.DataFrame(rows, columns=["family", "par1", "par2", "loglik", "aic", "bic", "lambda_lower", "lambda_upper"])
    o = np.argsort(out["aic"].to_numpy(), kind="stable")
    out = out.iloc[o].reset_index(drop=True)
    out.attrs["tau"] = tau
    out.attrs["n"] = n
    return out


def tail_dependence(x, y, *, q=(0.01, 0.025, 0.05, 0.10, 0.20)):
    """Empirische Tail-Abhängigkeit und Exceedance-Korrelationen.

    Args:
        x, y: Numerische Vektoren gleicher Länge; Paare mit nicht endlichen
            Werten werden entfernt.
        q: Tail-Wahrscheinlichkeiten als Anteil echt zwischen 0 und 1.

    Returns:
        ``pandas.DataFrame`` je Wert von ``q``: ``q``, ``lower``, ``upper``,
        ``exceed_lower``, ``exceed_upper``, ``n_lower``, ``n_upper``.
    """
    lx, ly = len(np.atleast_1d(x)), len(np.atleast_1d(y))
    if lx != ly:
        raise ValueError("tail_dependence: x und y müssen gleich lang sein (%d bzw. %d Werte)." % (lx, ly))
    qa = np.atleast_1d(np.asarray(q))
    if qa.dtype.kind not in "fiu" or not qa.size or (~np.isfinite(qa.astype(float)) | (qa <= 0) | (qa >= 1)).any():
        raise ValueError("tail_dependence: q muss aus Anteilen echt zwischen 0 und 1 bestehen (erhalten: %s)." % _fmt1(q))
    qa = qa.astype(np.float64)
    x, y = _finite_pairs(x, y)
    n = x.size
    if n < 2:
        raise ValueError("tail_dependence: mindestens zwei Paare mit endlichen Werten nötig.")
    u = _pobs(x)
    v = _pobs(y)

    def ec(s):
        if s.sum() >= 8 and r_sd(x[s]) > 0 and r_sd(y[s]) > 0:
            return _cor1(x[s], y[s])
        return _NAN
    rows = []
    for p in qa.tolist():
        lo = (u <= p) & (v <= p)
        hi = (u > 1 - p) & (v > 1 - p)
        el = (x <= _q1(x, p)) & (y <= _q1(y, p))
        eh = (x >= _q1(x, 1 - p)) & (y >= _q1(y, 1 - p))
        rows.append({"q": p, "lower": int(lo.sum()) / (n * p), "upper": int(hi.sum()) / (n * p),
                     "exceed_lower": ec(el), "exceed_upper": ec(eh), "n_lower": int(lo.sum()), "n_upper": int(hi.sum())})
    return pd.DataFrame(rows, columns=["q", "lower", "upper", "exceed_lower", "exceed_upper", "n_lower", "n_upper"])


# ═════════════════════════════════════════════════════════════════════════════
# DCC
# ═════════════════════════════════════════════════════════════════════════════

def dependence_dcc(R):
    """DCC(1,1)-Modell (Engle 2002).

    Args:
        R: Renditematrix oder DataFrame (Zeilen = Zeit, mindestens zwei
            Spalten und 100 Zeilen, keine fehlenden Werte).

    Returns:
        dict mit ``a``, ``b``, ``loglik``, ``correlation`` (DataFrame Zeit x
        Paare), ``pairs``, ``garch`` (DataFrame; ``method`` = ``"ml"``, ``"momente"``
        oder ``"konstant"``), ``z``, ``Qbar``.

    Seit Etappe 9.6b wie R: GARCH-Stufe per ML der C-Bibliothek (Label ``"ml"`` statt
    ``"rugarch"``/``"optim"``), Stufe 2 ganz in C; die Schätzung ist deterministisch.
    """
    Rm, nm = _as_matrix(R)
    if Rm.shape[1] < 2 or Rm.shape[0] < 100:
        raise ValueError("dependence_dcc: mindestens zwei Reihen und 100 Beobachtungen.")
    if nm is None:
        nm = ["V%d" % (j + 1) for j in range(Rm.shape[1])]
    fg = _boot()._fit_garch11
    g = [fg(Rm[:, j], quiet=True) for j in range(Rm.shape[1])]
    Z = np.column_stack([np.asarray(gi["z"], dtype=np.float64) for gi in g])
    flat = [nm[j] for j in range(Z.shape[1]) if r_sd(Z[:, j]) == 0]
    if flat:
        raise ValueError("dependence_dcc: Reihe %s ist konstant; keine Korrelation schätzbar." % ", ".join("'%s'" % f for f in flat))
    Qb = _cormat(Z)
    ev = np.asarray(_sl().eigen_sym(Qb, only_values=True)["values"], dtype=np.float64)
    if _rmin(ev) < 1e-8:
        C0 = Qb.copy()
        np.fill_diagonal(C0, 0.0)
        ab = np.abs(C0)
        mx = np.max(ab)
        hits = np.argwhere((ab == mx).T)        # spaltenweise wie which(arr.ind = TRUE)
        j0, i0 = int(hits[0][0]), int(hits[0][1])
        raise ValueError("dependence_dcc: Korrelationsmatrix der standardisierten Residuen ist singulär (z. B. '%s' und '%s': "
                         "Korrelation %s); DCC nicht schätzbar. Doppelte bzw. linear abhängige Reihen entfernen."
                         % (nm[i0], nm[j0], _sprintf("%.6f", float(Qb[i0, j0]))))

    # Stufe 2 ganz in C (Entwurf B.11, wie .sl_dcc_fit in R): deterministisch
    o = _sl().dcc_fit(Z, Qb)
    a, b, oval = float(o["a"]), float(o["b"]), float(o["nll"])
    fl = _sl().dcc_filter(Z, a, b, Qb, True)
    if not fl["ok"]:
        raise ValueError("dependence_dcc: bedingte Korrelationsmatrix nicht positiv definit; DCC nicht schätzbar.")
    pn = ["%s ~ %s" % (nm[i], nm[j]) for i, j in _combn2(len(nm))]
    C = pd.DataFrame(fl["R"], columns=pn)
    garch = pd.DataFrame({"series": nm, "alpha": [float(gi["alpha"]) for gi in g],
                          "beta": [float(gi["beta"]) for gi in g], "method": [str(gi["method"]) for gi in g]})
    return {"a": a, "b": b, "loglik": -oval, "correlation": C, "pairs": pn, "garch": garch, "z": Z, "Qbar": Qb}


# ═════════════════════════════════════════════════════════════════════════════
# Bedingte Analyse
# ═════════════════════════════════════════════════════════════════════════════

def _signif_str(x):
    return _fmt1(float(_fmt.signif(float(x), 3)))


def _dep_regimes(cv, breaks=None, n_regimes=3):
    """Regime aus einer Zustandsvariable; liefert (Kategorien-Codes, Labels, Grenzen)."""
    cv = np.asarray(cv, dtype=np.float64)
    if breaks is None:
        qs = np.asarray(_quantile(cv, _seq_len_out(0.0, 1.0, int(n_regimes) + 1), na_rm=True), dtype=np.float64)
        inner = qs[1:-1]
        u = np.unique(cv[np.isfinite(cv)])
        if u.size < 2 or not inner.size:
            br = []
        else:
            u1 = u[1:]
            b = []
            for q in inner.tolist():
                w = np.nonzero(u1 >= q)[0]
                b.append(float(u1[w[0]]) if w.size else _NAN)
            vals = [inner[i] if inner[i] > u[0] else b[i] for i in range(inner.size)]
            seen = []
            br = []
            for i, bi in enumerate(b):
                key = "NA" if math.isnan(bi) else bi
                if key in seen:
                    continue
                seen.append(key)
                br.append(float(vals[i]))
        breaks = np.array([-math.inf] + list(br) + [math.inf], dtype=np.float64)
    else:
        breaks = np.asarray(breaks, dtype=np.float64).ravel()
    lab = []
    for i in range(breaks.size - 1):
        a, b = breaks[i], breaks[i + 1]
        if not math.isfinite(a):
            lab.append("< %s" % _signif_str(b))
        elif not math.isfinite(b):
            lab.append(">= %s" % _signif_str(a))
        else:
            lab.append("%s bis %s" % (_signif_str(a), _signif_str(b)))
    if np.unique(breaks).size < breaks.size:
        raise ValueError("'breaks' are not unique")
    br_s = np.sort(breaks)
    code = _bincode(cv, br_s, right=False)
    return code, lab, breaks


def _dep_reg_cor(X, reg, nlev, pairs, rank=False):
    """Korrelationen je Regime für alle Paare -> Matrix Paare x Regime."""
    out = np.full((len(pairs), nlev), _NAN)
    for li in range(nlev):
        s = np.nonzero(reg == li + 1)[0]
        if s.size < 10:
            continue
        Y = X[s, :]
        if rank:
            Y = np.column_stack([_rank_avg(Y[:, j]) for j in range(Y.shape[1])])
        with warnings.catch_warnings():
            warnings.simplefilter("ignore")
            C = _cormat(Y)
        out[:, li] = [C[i, j] for i, j in pairs]
    return out


def _match_arg(arg, choices, argname="frequency"):
    """R-``match.arg`` (über ``data_prep._match_arg``)."""
    from .data_prep import _match_arg as f
    return f(arg, choices)


def _rbind_named(dfs, names):
    """``do.call(rbind, <benannte Liste von data.frames>)`` inkl. Zeilennamen."""
    parts = []
    idx = []
    for nm, df in zip(names, dfs):
        parts.append(df)
        if len(df) == 1:
            idx.append(nm)
        else:
            idx.extend("%s.%d" % (nm, k + 1) for k in range(len(df)))
    out = pd.concat(parts, ignore_index=True)
    out.index = idx
    return out


class SimLevDependence(RList):
    """Ergebnis von :func:`dependence_analysis` (R-Klasse ``SimLevDependence``)."""

    r_class = ("SimLevDependence",)

    def format(self):
        return _print_dependence(self)


def dependence_analysis(data, assets, *, conditions=None, frequency=("week", "day", "month"),
                        quantiles=(0.05, 0.10), breaks=None, n_regimes=3, window=None,
                        dcc=True, copulas=True, B=499, block=None, tail_q=0.10, seed=None):
    """Abhängigkeitsanalyse mit Tail-Risiko und Drittvariablen.

    Args:
        data: DataFrame mit Spalte ``date``, Kursspalten und Zustandsspalten.
        assets: Kursspalten (mindestens zwei).
        conditions: Zustandsspalten (verzögert); ``None`` = keine bedingte Analyse.
        frequency: ``"week"`` (Standard), ``"day"`` oder ``"month"``.
        quantiles: Tail-Wahrscheinlichkeiten für die Kennzahlen der ganzen Stichprobe.
        breaks: dict mit Grenzen je Zustandsvariable; ``None`` = Quantilsgruppen.
        n_regimes: Anzahl Regime ohne ``breaks``.
        window: Fenster der rollierenden Korrelation (``None`` = Perioden je Jahr, mindestens 10).
        dcc: DCC(1,1) schätzen (ab 100 Perioden).
        copulas: Copula-Fits je Paar (und je Regime ab 40 Perioden).
        B: Bootstrap-Wiederholungen für die Regime-Vergleiche (0 = aus).
        block: mittlere Blocklänge (``None`` = Politis-White).
        tail_q: Tail-Wahrscheinlichkeit für die Kennzahlen je Regime.
        seed: Startwert (ganze Zahl, ``|seed| < 2**53``; ``None`` = genau einmal aus dem Zufallszustand von SimLev gezogen, siehe :func:`simlev.simlev_seed`) für den Bootstrap.

    Returns:
        :class:`SimLevDependence`.
    """
    frequency = _match_arg(frequency, ("week", "day", "month"))
    assets = _as_names(assets)
    if len(assets) < 2:
        raise ValueError("dependence_analysis: mindestens zwei Anlagen.")
    conditions = _as_names(conditions) if conditions is not None else None
    rd = _dep_returns(data, assets, conditions, frequency)
    X = rd[assets].to_numpy(dtype=np.float64)
    n = X.shape[0]
    if n < 30:
        raise ValueError("dependence_analysis: nur %d Perioden." % n)
    dd = _days(rd["date"].to_numpy())
    ppy = (n - 1) / ((dd[n - 1] - dd[0]) / 365.25)
    if window is None:
        window = max(10, float(_fmt.r_round(ppy)))
    quantiles = np.atleast_1d(np.asarray(quantiles, dtype=np.float64))
    pear = _cormat(X)
    spear = _cormat(X, "spearman")
    kend = np.asarray(_kendall(X), dtype=np.float64)
    cors = {"pearson": pd.DataFrame(pear, index=assets, columns=assets),
            "spearman": pd.DataFrame(spear, index=assets, columns=assets),
            "kendall": pd.DataFrame(kend, index=assets, columns=assets)}
    pidx = _combn2(len(assets))
    pn = ["%s ~ %s" % (assets[i], assets[j]) for i, j in pidx]
    tails = []
    for k, (i, j) in enumerate(pidx):
        td = tail_dependence(X[:, i], X[:, j], q=quantiles)
        td.insert(0, "pair", pn[k])
        tails.append(td)
    cops = None
    if copulas:
        cops = {pn[k]: copula_fit(X[:, i], X[:, j]) for k, (i, j) in enumerate(pidx)}
    ptab = pd.DataFrame({"pair": pn, "pearson": [pear[i, j] for i, j in pidx],
                         "spearman": [spear[i, j] for i, j in pidx], "kendall": [kend[i, j] for i, j in pidx]})
    for q in quantiles.tolist():
        qn = _sprintf("%g", q)
        ptab["lambda_lower_" + qn] = [float(t["lower"].to_numpy()[t["q"].to_numpy() == q][0]) for t in tails]
        ptab["lambda_upper_" + qn] = [float(t["upper"].to_numpy()[t["q"].to_numpy() == q][0]) for t in tails]
    if cops is not None:
        cl = list(cops.values())
        ptab["copula"] = [c["family"].iloc[0] for c in cl]
        ptab["copula_lambda_lower"] = [float(c["lambda_lower"].iloc[0]) for c in cl]
        ptab["copula_lambda_upper"] = [float(c["lambda_upper"].iloc[0]) for c in cl]
        tf = [c[c["family"] == "t"] for c in cl]
        ptab["t_rho"] = [float(t["par1"].iloc[0]) for t in tf]
        ptab["t_nu"] = [float(t["par2"].iloc[0]) for t in tf]
    roll = None
    if n > window:
        roll = pd.DataFrame({"date": rd["date"].to_numpy()})
        w = int(window)
        for k, (i, j) in enumerate(pidx):
            x = X[:, i]
            y = X[:, j]
            cv = _roll_cov(x, y, w)
            vx = _roll_var(x, w)
            vy = _roll_var(y, w)
            with np.errstate(invalid="ignore"):
                roll[pn[k]] = cv / np.sqrt(np.maximum(vx * vy, 1e-300))
    dc = None
    if dcc and n >= 100:
        try:
            dc = dependence_dcc(pd.DataFrame(X, columns=assets))
        except ValueError as e:
            message("DCC nicht geschätzt: " + str(e))
            dc = None
    cond = diffs = regimes = None
    diff_names = []
    if conditions:
        if block is None:
            bl = []
            for i, j in pidx:
                x = _scale1(X[:, i])
                y = _scale1(X[:, j])
                bl.append(float(_boot()._pw_block(x * y)["stationary"]))
            block = _rmin(_rmax(2, _rmax(bl)), n / 10)
        cond, diffs, regimes = {}, [], {}
        for cn in conditions:
            cv = rd[cn].to_numpy(dtype=np.float64)
            keep = np.nonzero(np.isfinite(cv))[0]
            if keep.size < 30:
                warnings.warn("Zustand '%s': zu wenige Beobachtungen." % cn)
                continue
            bcn = None
            if breaks is not None:
                bcn = breaks.get(cn) if isinstance(breaks, Mapping) else None
            code, lv, _br = _dep_regimes(cv[keep], bcn, n_regimes)
            Xk = X[keep, :]
            cvk = cv[keep]
            nlv = len(lv)
            ms = []
            for li in range(nlv):
                sel = code == li + 1
                vals = cvk[sel]
                if (code == 0).any():
                    vals = np.concatenate([vals, np.full(int((code == 0).sum()), _NAN)])
                ms.append(r_mean(vals))
            regimes[cn] = pd.DataFrame({"regime": lv, "n": [int((code == li + 1).sum()) for li in range(nlv)],
                                        "mean_state": ms}, index=lv)
            rows = []
            for k, (i, j) in enumerate(pidx):
                for li, l in enumerate(lv):
                    s = np.nonzero(code == li + 1)[0]
                    x = Xk[s, i]
                    y = Xk[s, j]
                    td = tail_dependence(x, y, q=tail_q) if s.size >= 20 else None
                    kt = _kendall(x, y) if s.size >= 2 else _NAN
                    fams = (["t", "gaussian", "clayton_90", "clayton_270"] if s.size >= 2 and kt < 0
                            else ["t", "gaussian", "clayton", "gumbel"])
                    tc = None
                    if copulas and s.size >= 40:
                        try:
                            tc = copula_fit(x, y, families=fams)
                        except Exception:  # noqa: BLE001 - tryCatch(error = NULL)
                            tc = None
                    tt = tc[tc["family"] == "t"] if tc is not None else None
                    rows.append({
                        "pair": pn[k], "regime": l, "n": int(s.size),
                        "vol_1": r_sd(x) * math.sqrt(ppy), "vol_2": r_sd(y) * math.sqrt(ppy),
                        "pearson": _cor1(x, y) if s.size >= 10 else _NAN,
                        "spearman": _cor1(x, y, "spearman") if s.size >= 10 else _NAN,
                        "kendall": _kendall(x, y) if s.size >= 10 else _NAN,
                        "lambda_lower": float(td["lower"].iloc[0]) if td is not None else _NAN,
                        "lambda_upper": float(td["upper"].iloc[0]) if td is not None else _NAN,
                        "exceed_lower": float(td["exceed_lower"].iloc[0]) if td is not None else _NAN,
                        "t_rho": float(tt["par1"].iloc[0]) if tt is not None and len(tt) else _NAN,
                        "t_nu": float(tt["par2"].iloc[0]) if tt is not None and len(tt) else _NAN,
                        "copula": tc["family"].iloc[0] if tc is not None else None,
                        "copula_lambda_lower": float(tc["lambda_lower"].iloc[0]) if tc is not None else _NAN})
            ct = pd.DataFrame(rows)
            if B > 0 and nlv >= 2:
                nk = Xk.shape[0]
                # Regel 3/4: seed=None -> einmal k aus G (beim ersten Bootstrap), dann je Zustand wie seed=k
                if seed is None:
                    seed = _sl().next_seed()
                S = _sl().main_stream(seed)
                boot = []
                for _b in range(int(B)):
                    idx = np.asarray(_boot_idx_stationary(nk, nk, block, S), dtype=np.int64) - 1
                    Xb = Xk[idx, :]
                    rb = code[idx]
                    boot.append((_dep_reg_cor(Xb, rb, nlv, pidx), _dep_reg_cor(Xb, rb, nlv, pidx, rank=True)))
                bp = np.stack([b[0] for b in boot], axis=2)
                bs = np.stack([b[1] for b in boot], axis=2)
                hi_ = np.full(len(ct), _NAN)
                lo_ = np.full(len(ct), _NAN)
                for r in range(len(ct)):
                    i = pn.index(ct["pair"].iloc[r])
                    j = lv.index(ct["regime"].iloc[r])
                    qv = np.asarray(_quantile(bp[i, j, :], [0.05, 0.95], na_rm=True), dtype=np.float64)
                    lo_[r] = qv[0]
                    hi_[r] = qv[1]
                ct["pearson_hi"] = hi_
                ct["pearson_lo"] = lo_
                dl = []
                last = lv[-1]
                first = lv[0]
                for i in range(len(pn)):
                    m_p = ct["pair"].to_numpy() == pn[i]
                    est_p = _sub1(ct["pearson"].to_numpy()[m_p & (ct["regime"].to_numpy() == last)]) - \
                        _sub1(ct["pearson"].to_numpy()[m_p & (ct["regime"].to_numpy() == first)])
                    est_s = _sub1(ct["spearman"].to_numpy()[m_p & (ct["regime"].to_numpy() == last)]) - \
                        _sub1(ct["spearman"].to_numpy()[m_p & (ct["regime"].to_numpy() == first)])
                    dp = bp[i, nlv - 1, :] - bp[i, 0, :]
                    ds = bs[i, nlv - 1, :] - bs[i, 0, :]
                    dl.append({"pair": pn[i], "condition": cn, "from": first, "to": last,
                               "diff_pearson": est_p, "lo_pearson": _q1(dp, 0.025, na_rm=True),
                               "hi_pearson": _q1(dp, 0.975, na_rm=True), "p_pearson": _pval(dp),
                               "diff_spearman": est_s, "lo_spearman": _q1(ds, 0.025, na_rm=True),
                               "hi_spearman": _q1(ds, 0.975, na_rm=True), "p_spearman": _pval(ds)})
                diffs.append(pd.DataFrame(dl))
                diff_names.append(cn)
            cond[cn] = ct
    out = SimLevDependence()
    out["returns"] = rd
    out["assets"] = assets
    out["conditions"] = conditions
    out["frequency"] = frequency
    out["ppy"] = ppy
    out["correlation"] = cors
    out["pairs"] = ptab
    out["tail"] = pd.concat(tails, ignore_index=True)
    out["copulas"] = cops
    out["rolling"] = roll
    out["window"] = window
    out["dcc"] = dc
    out["conditional"] = cond
    out["regimes"] = regimes
    out["differences"] = _rbind_named(diffs, diff_names) if diffs else None
    out["block"] = block
    out["B"] = B
    out["tail_q"] = tail_q
    return out


def _sub1(a):
    """R-Arithmetik mit möglicherweise leerem Vektor: leer -> NaN-Marker."""
    a = np.asarray(a, dtype=np.float64)
    return float(a[0]) if a.size else _NAN


def _pval(dd):
    dd = np.asarray(dd, dtype=np.float64)
    dd = dd[np.isfinite(dd)]
    if dd.size == 0:
        return _RNAN
    a = r_mean((dd <= 0).astype(np.float64))
    b = r_mean((dd >= 0).astype(np.float64))
    return min(1.0, 2 * min(a, b))


def _print_dependence(x):
    rd = x["returns"]
    lines = []
    d = rd["date"].to_numpy()
    lines.append("SimLev Abhängigkeitsanalyse: %d Perioden (%s), %s bis %s\n" % (
        len(rd), x["frequency"], _date_str(d[0]), _date_str(d[len(rd) - 1])))
    lines.append("Korrelation (Pearson unten links, Kendall oben rechts)")
    P = x["correlation"]["pearson"]
    M = P.to_numpy(dtype=np.float64).copy()
    K = np.asarray(x["correlation"]["kendall"], dtype=np.float64)
    iu = np.triu_indices(M.shape[0], 1)
    M[iu] = K[iu]
    lines.append(_fmt.print_matrix(pd.DataFrame(_fmt.r_round(M, 3), index=P.index, columns=P.columns)))
    p = x["pairs"]
    lines.append("\nTail-Abhängigkeit je Paar")
    qs = [c for c in p.columns if str(c).startswith("lambda_lower_")]
    y = pd.DataFrame({"Paar": p["pair"].to_numpy(dtype=object),
                      "Kendall": _sprintf_vec("%.3f", p["kendall"].to_numpy(dtype=np.float64))})
    for k in qs:
        q = k[len("lambda_lower_"):]
        y["lamL %s" % q] = _sprintf_vec("%.2f", p[k].to_numpy(dtype=np.float64))
        y["lamU %s" % q] = _sprintf_vec("%.2f", p[k.replace("lower", "upper", 1)].to_numpy(dtype=np.float64))
    if "copula" in p.columns:
        y["Copula"] = p["copula"].to_numpy(dtype=object)
        y["Cop. lamL"] = _sprintf_vec("%.2f", p["copula_lambda_lower"].to_numpy(dtype=np.float64))
        y["Cop. lamU"] = _sprintf_vec("%.2f", p["copula_lambda_upper"].to_numpy(dtype=np.float64))
        y["t: rho/nu"] = _sprintf_vec("%.2f / %.1f", p["t_rho"].to_numpy(dtype=np.float64), p["t_nu"].to_numpy(dtype=np.float64))
    lines.append(_fmt.print_data_frame(y, row_names=False))
    lines.append("  (Unabhängigkeit: lam(q) ~ q; Gauß-Abhängigkeit: lam -> 0 für kleine q)")
    dc = x["dcc"]
    if dc is not None:
        C = dc["correlation"]
        last = np.asarray(C, dtype=np.float64)[len(C) - 1, :]
        txt = ", ".join(_sprintf_vec("%s %.2f", list(dc["pairs"]), last))
        lines.append("\n" + _sprintf("DCC(1,1): a = %.4f, b = %.4f (Persistenz %.4f); Korrelation zuletzt: %s",
                                     dc["a"], dc["b"], dc["a"] + dc["b"], txt))
    diffs = x["differences"]
    for cn in (x["conditional"] or {}):
        ct = x["conditional"][cn]
        lines.append("\nBedingt auf '%s' (Zustand am Ende der Vorperiode)" % cn)
        z = pd.DataFrame({"Paar": ct["pair"].to_numpy(dtype=object), "Regime": ct["regime"].to_numpy(dtype=object),
                          "n": ct["n"].to_numpy(dtype=np.int64),
                          "Pearson": _sprintf_vec("%.2f", ct["pearson"].to_numpy(dtype=np.float64))})
        if "pearson_lo" in ct.columns:
            z["90%-KI"] = _sprintf_vec("[%.2f, %.2f]", ct["pearson_lo"].to_numpy(dtype=np.float64),
                                       ct["pearson_hi"].to_numpy(dtype=np.float64))
        else:
            z["90%-KI"] = ""
        z["Kendall"] = _sprintf_vec("%.2f", ct["kendall"].to_numpy(dtype=np.float64))
        z["lamL %s" % _sprintf("%g", x["tail_q"])] = _sprintf_vec("%.2f", ct["lambda_lower"].to_numpy(dtype=np.float64))
        z["t-rho"] = _sprintf_vec("%.2f", ct["t_rho"].to_numpy(dtype=np.float64))
        z["Copula"] = ct["copula"].to_numpy(dtype=object)
        lines.append(_fmt.print_data_frame(z, row_names=False, types={"Copula": "character"}))
        if diffs is not None:
            dd_ = diffs[diffs["condition"].to_numpy() == cn]
            for r in range(len(dd_)):
                row = dd_.iloc[r]
                lines.append(_sprintf("  %s: Pearson %s -> %s: %+.2f [%+.2f, %+.2f], p = %.3f; Spearman %+.2f, p = %.3f",
                                      row["pair"], row["from"], row["to"], float(row["diff_pearson"]),
                                      float(row["lo_pearson"]), float(row["hi_pearson"]), float(row["p_pearson"]),
                                      float(row["diff_spearman"]), float(row["p_spearman"])))
    if diffs is not None:
        lines.append(_sprintf("  (stationärer Block-Bootstrap, B = %d, mittlere Blocklänge %.1f Perioden)",
                              int(x["B"]), float(x["block"])))
    return "\n".join(lines)


# ═════════════════════════════════════════════════════════════════════════════
# Grafiken (SVG wie julia/src/dependence.jl; Bausteine `_grid_*` in svg.py)
# ═════════════════════════════════════════════════════════════════════════════
# Nicht bitgleich zu R's Grafik, zeigen aber dieselben Daten.

def _plot_dependence(x, type=("overview", "rolling", "tail", "conditional", "scatter"), pair=1, condition=1,  # noqa: A002
                     width=900, height=650):
    """``plot.SimLevDependence`` (SVG): rollierende/DCC-Korrelation, Tail-Abhängigkeit, Korrelation je Regime
    und Pseudo-Beobachtungen.

    Args:
        type: ``"overview"`` (alle vier im 2 x 2-Raster), ``"rolling"``, ``"tail"``, ``"conditional"`` oder
            ``"scatter"``.
        pair: Paar (Name ``"A ~ B"`` oder Nummer).
        condition: Drittvariable (Name oder Nummer) für ``"conditional"``.
        width, height: Größe in Pixeln.
        file: Dateiname auf ``.svg`` (sonst wird nichts geschrieben).

    Returns:
        :class:`simlev.SimLevPlot`; ``data`` je Panel: ``rolling`` (``date``, ``rolling`` und mit DCC ``dcc``),
        ``tail`` (``q``, ``lower``, ``upper``, ``independence``), ``conditional`` (``regime``, ``pearson``,
        gegebenenfalls ``pearson_lo``, ``pearson_hi``, und ``lambda_lower``), ``scatter`` (``u``, ``v``).
        Ohne rollierende Korrelation bzw. Drittvariable sind ``rolling`` bzw. ``conditional`` leer.
    """
    from .svg import _jl_log10
    type = _match_arg(type, ("overview", "rolling", "tail", "conditional", "scatter"), "type")  # noqa: A001
    pn = [str(v) for v in x["pairs"]["pair"]]
    i = pn.index(pair) if isinstance(pair, str) else int(pair) - 1
    ab = pn[i].split(" ~ ")
    X = x["returns"]
    data = {}

    def p_roll(c, box):
        if x["rolling"] is None:
            data["rolling"] = pd.DataFrame({"date": np.array([], dtype="datetime64[s]"),
                                            "rolling": np.array([], dtype=np.float64)})
            return
        rl = x["rolling"]
        rv = rl[pn[i]].to_numpy(dtype=np.float64)
        series = [(_days(rl["date"].to_numpy()), rv, "#2C6E9B", "rollierend")]
        d = {"date": rl["date"].to_numpy(), "rolling": rv.copy()}
        if x["dcc"] is not None:
            cv = x["dcc"]["correlation"][pn[i]].to_numpy(dtype=np.float64)
            series.append((_days(X["date"].to_numpy()), cv, "#B5562B", "DCC"))
            d["dcc"] = cv.copy()
        _grid_lines(c, box, series, ylim=(-1.0, 1.0), hline=[(0.0, "grey")], dates=True,
                    title="%s: rollierend (%d) und DCC" % (pn[i], int(x["window"])), ylabel="Korrelation")
        data["rolling"] = pd.DataFrame(d)

    def p_tail(c, box):
        qg = [0.01, 0.02, 0.03, 0.05, 0.075, 0.1, 0.15, 0.2, 0.3, 0.4, 0.5]
        td = tail_dependence(X[ab[0]], X[ab[1]], q=qg)
        lq = [_jl_log10(v) for v in qg]
        lo = np.asarray(td["lower"], dtype=np.float64)
        up = np.asarray(td["upper"], dtype=np.float64)
        series = [(lq, lo, "#B5562B", "unten (gemeinsame Verluste)"),
                  (lq, up, "#2C6E9B", "oben (gemeinsame Gewinne)"),
                  (lq, qg, "#666666", "Unabhängigkeit")]
        hl = []
        if x["copulas"] is not None:
            cp = x["copulas"][pn[i]]
            hl.append((float(cp["lambda_lower"].iloc[0]), "#B5562B"))
            hl.append((float(cp["lambda_upper"].iloc[0]), "#2C6E9B"))
        _grid_lines(c, box, series, ylim=(0.0, 1.0), hline=hl, points=True, xlabel="Quantil q (log)",
                    title="%s: Tail-Abhängigkeit" % pn[i],
                    xticks=[(_jl_log10(v), _sprintf("%g", v)) for v in (0.01, 0.05, 0.1, 0.5)])
        data["tail"] = pd.DataFrame({"q": np.array(qg, dtype=np.float64), "lower": lo.copy(), "upper": up.copy(),
                                     "independence": np.array(qg, dtype=np.float64)})

    def p_cond(c, box):
        if not x["conditional"]:
            data["conditional"] = pd.DataFrame({"regime": np.array([], dtype=object),
                                                "pearson": np.array([], dtype=np.float64),
                                                "lambda_lower": np.array([], dtype=np.float64)})
            return
        cn = condition if isinstance(condition, str) else list(x["conditional"].keys())[int(condition) - 1]
        ct = x["conditional"][cn]
        sel = np.flatnonzero(ct["pair"].to_numpy() == pn[i])
        lo = ct["pearson_lo"].to_numpy(dtype=np.float64)[sel] if "pearson_lo" in ct.columns else None
        hi = ct["pearson_hi"].to_numpy(dtype=np.float64)[sel] if "pearson_hi" in ct.columns else None
        reg = [str(v) for v in ct["regime"].to_numpy()[sel]]
        pe = ct["pearson"].to_numpy(dtype=np.float64)[sel]
        ll = ct["lambda_lower"].to_numpy(dtype=np.float64)[sel]
        _grid_bars(c, box, reg, pe, lo=lo, hi=hi, pts=ll, ylim=(-1.0, 1.0), title="%s nach '%s'" % (pn[i], cn),
                   ylabel="Korrelation")
        d = {"regime": np.array(reg, dtype=object), "pearson": pe.copy()}
        if lo is not None:
            d["pearson_lo"] = lo.copy()
        if hi is not None:
            d["pearson_hi"] = hi.copy()
        d["lambda_lower"] = ll.copy()
        data["conditional"] = pd.DataFrame(d)

    def p_scatter(c, box):
        u = np.asarray(_pobs(X[ab[0]]), dtype=np.float64)
        v = np.asarray(_pobs(X[ab[1]]), dtype=np.float64)
        q = float(x["tail_q"])
        col = ["#B5562B" if (a <= q and bb <= q) else ("#2C6E9B" if (a > 1 - q and bb > 1 - q) else "#A6A6A6")
               for a, bb in zip(u.tolist(), v.tolist())]
        _grid_scatter(c, box, u, v, col, rects=[(0.0, 0.0, q, q, "#B5562B"), (1 - q, 1 - q, 1.0, 1.0, "#2C6E9B")],
                      xlabel="Rang %s" % ab[0], ylabel="Rang %s" % ab[1], title="Pseudo-Beobachtungen")
        data["scatter"] = pd.DataFrame({"u": u.copy(), "v": v.copy()})

    fns = {"rolling": p_roll, "tail": p_tail, "conditional": p_cond, "scatter": p_scatter}
    ks = ["rolling", "tail", "conditional", "scatter"] if type == "overview" else [type]
    svg = _grid_svg(ks, lambda k: fns[k], width=width, height=height).svg
    return svg, data


def _plot_tail_regression(x, width=900, height=400):
    """``plot.SimLevTailRegression`` (SVG): Koeffizient je Quantil mit Band, OLS-Koeffizient und Null.

    Args:
        width, height: Größe in Pixeln (je Treiber ein Feld nebeneinander).
        file: Dateiname auf ``.svg`` (sonst wird nichts geschrieben).

    Returns:
        :class:`simlev.SimLevPlot`; ``data`` je Treiber (Schlüssel = Name des Treibers): ``quantile``,
        ``estimate``, ``lower``, ``upper``.
    """
    drv = [str(v) for v in x["drivers"]]
    cf = x["coefficients"]
    data = {}

    def make(dv):
        def f(c, box):
            sel = np.flatnonzero(cf["term"].to_numpy() == dv)
            qv = cf["quantile"].to_numpy(dtype=np.float64)[sel]
            est = cf["estimate"].to_numpy(dtype=np.float64)[sel]
            lo = cf["lower"].to_numpy(dtype=np.float64)[sel]
            hi = cf["upper"].to_numpy(dtype=np.float64)[sel]
            _grid_lines(c, box, [(qv, est, "#2C6E9B", "Quantilsregression")],
                        band=None if bool(np.all(np.isnan(lo))) else (qv, lo, hi),
                        hline=[(float(x["ols"][dv]), "#B5562B"), (0.0, "grey")], points=True, xlabel="Quantil",
                        ylabel="Koeffizient", title="%s: Effekt von %s" % (x["asset"], dv))
            data[dv] = pd.DataFrame({"quantile": qv, "estimate": est, "lower": lo, "upper": hi})
        return f

    svg = _grid_svg(drv, make, ncol=len(drv), width=width, height=height).svg
    return svg, data


def _plot_covar(x, width=800, height=450):
    """``plot.SimLevCoVaR`` (SVG): Delta-CoVaR je Anlage über die Zeit.

    Args:
        width, height: Größe in Pixeln.
        file: Dateiname auf ``.svg`` (sonst wird nichts geschrieben).

    Returns:
        :class:`simlev.SimLevPlot`; ``data``: ``delta_covar`` (``asset``, ``date``, ``delta_covar`` in % je
        Periode wie in ``series``; Zeilen je Anlage in Zeichenreihenfolge).
    """
    s = x["series"]
    cols = ["#2C6E9B", "#B5562B", "#3E8E5A", "#8A5BA8", "#C49A2C"]
    av = np.array([str(v) for v in s["asset"]], dtype=object)
    dts = s["date"].to_numpy()
    dc = s["delta_covar"].to_numpy(dtype=np.float64)
    a = list(dict.fromkeys(av.tolist()))
    series = [(_days(dts[av == aj]), dc[av == aj], cols[j % 5], aj) for j, aj in enumerate(a)]
    svg = _grid_svg(["x"], lambda _: (lambda c, box: _grid_lines(
        c, box, series, dates=True, ylabel="Delta-CoVaR (%)",
        title=_sprintf("Delta-CoVaR für '%s' (q = %g)", x["system"], x["q"]))), width=width, height=height).svg
    data = {"delta_covar": pd.DataFrame({"asset": np.concatenate([av[av == aj] for aj in a]) if a else av,
                                         "date": np.concatenate([dts[av == aj] for aj in a]) if a else dts,
                                         "delta_covar": np.concatenate([dc[av == aj] for aj in a]) if a else dc})}
    return svg, data


# ═════════════════════════════════════════════════════════════════════════════
# Quantilsregression, Tail-Regression, CoVaR
# ═════════════════════════════════════════════════════════════════════════════

def _qr_decomp(X, y):
    """OLS-Start über ``.sl_lsfit`` (Householder-QR, Entwurf B.7): dict(coefficients, rank, pivot, ...)."""
    return _sl().lsfit(X, y)


def quantile_regression(y, *, X=None, tau=0.5, intercept=True, tol=1e-10, maxit=2000):
    """Lineare Quantilsregression (exakte Lösung mit Optimalitätsnachweis).

    Args:
        y: Zielvariable.
        X: Regressoren (Vektor, Matrix oder DataFrame, ohne Konstante);
            ``None`` = nur Konstante.
        tau: Quantil echt zwischen 0 und 1.
        intercept: Konstante aufnehmen.
        tol: Konvergenzschwelle der MM-Stufen.
        maxit: Höchstzahl Iterationen je MM-Stufe.

    Returns:
        ``pandas.Series`` der Koeffizienten (``"(Intercept)"``, Spaltennamen
        bzw. ``x1``, ``x2``, …).
    """
    tv = np.atleast_1d(np.asarray(tau, dtype=object))
    if (tv.size != 1 or isinstance(tv[0], (bool, np.bool_, str)) or tv[0] is None
            or not isinstance(tv[0], (int, float, np.integer, np.floating))
            or not math.isfinite(float(tv[0])) or float(tv[0]) <= 0 or float(tv[0]) >= 1):
        raise ValueError("quantile_regression: tau muss eine Zahl echt zwischen 0 und 1 sein (erhalten: %s)." % _fmt1(tau))
    tau = float(tv[0])
    ya = np.asarray(y.to_numpy() if isinstance(y, pd.Series) else y)
    if ya.dtype.kind not in "fiu":
        raise ValueError("quantile_regression: y muss numerisch sein.")
    y = ya.astype(np.float64).ravel()
    if isinstance(X, pd.DataFrame):
        nn = [str(c) for c in X.columns if X[c].dtype.kind not in "fiu"]
        if nn:
            raise ValueError("quantile_regression: Spalte(n) %s von X nicht numerisch (Faktoren vorher z. B. mit model.matrix() "
                             "in Indikatorspalten umwandeln)." % ", ".join("'%s'" % c for c in nn))
    if X is None:
        Xm = np.zeros((y.size, 0))
        nm = []
    else:
        if isinstance(X, pd.DataFrame):
            Xm = X.to_numpy(dtype=np.float64)
            nm = [str(c) for c in X.columns]
        else:
            Xa = np.asarray(X.to_numpy() if isinstance(X, pd.Series) else X)
            if Xa.dtype.kind not in "fiu":
                raise ValueError("quantile_regression: X muss numerisch sein.")
            Xm = Xa.astype(np.float64)
            if Xm.ndim == 1:
                Xm = Xm.reshape(-1, 1)
            nm = None
        if Xm.shape[0] != y.size:
            raise ValueError("quantile_regression: X hat %d Zeilen, y aber %d Werte." % (Xm.shape[0], y.size))
        if nm is None:
            nm = ["x%d" % (j + 1) for j in range(Xm.shape[1])]
    if intercept:
        Xm = np.column_stack([np.ones(y.size), Xm]) if Xm.size or Xm.shape[1] else np.ones((y.size, 1))
        nm = ["(Intercept)"] + nm
    ok = np.isfinite(y) & np.isfinite(Xm).all(axis=1)
    y = y[ok]
    Xm = Xm[ok, :]
    p = Xm.shape[1]
    if not p:
        raise ValueError("quantile_regression: keine Regressoren (X = NULL und intercept = FALSE).")
    if y.size < p:
        raise ValueError("quantile_regression: %d vollständige Beobachtungen für %d Koeffizienten." % (y.size, p))
    qx = _qr_decomp(Xm, y)
    rank = int(qx["rank"])
    if rank < p:
        piv = np.asarray(qx["pivot"], dtype=np.int64)
        bad = [nm[int(k) - 1] for k in piv[rank:]]
        raise ValueError("quantile_regression: Regressoren linear abhängig (%s); doppelte oder konstante Spalten entfernen "
                         "(die Konstante ist bei intercept = TRUE schon enthalten)." % ", ".join("'%s'" % b for b in bad))
    beta = np.asarray(qx["coefficients"], dtype=np.float64).ravel()
    sc = _rmax(r_sd(y), 1e-12)
    beta, opt = _core.quantile_reg_core(y, Xm, tau, beta, sc, tol, int(maxit))
    if not opt:
        warnings.warn("quantile_regression: Optimalität nicht nachgewiesen; Ergebnis ist eine Ecke mit nicht größerem "
                      "Zielwert als die MM-Näherung (bzw. die MM-Näherung selbst, falls keine solche Ecke gefunden wurde).")
    return pd.Series(np.asarray(beta, dtype=np.float64), index=nm)


class SimLevTailRegression(RList):
    """Ergebnis von :func:`tail_regression` (R-Klasse ``SimLevTailRegression``)."""

    r_class = ("SimLevTailRegression",)

    def format(self):
        x = self
        fr = {"week": "Woche", "day": "Tag", "month": "Monat"}[x["frequency"]]
        lines = ["Quantilsregression: Rendite '%s' (%% je %s) auf verzögerte %s; %d Perioden\n" % (
            x["asset"], fr, ", ".join(x["drivers"]), int(x["n"]))]
        cf = x["coefficients"]
        se = cf["se"].to_numpy(dtype=np.float64)
        lo = cf["lower"].to_numpy(dtype=np.float64)
        up = cf["upper"].to_numpy(dtype=np.float64)
        y = pd.DataFrame({
            "Quantil": _sprintf_vec("%g %%", 100 * cf["quantile"].to_numpy(dtype=np.float64)),
            "Term": cf["term"].to_numpy(dtype=object),
            "Koeffizient": _sprintf_vec("%.4f", cf["estimate"].to_numpy(dtype=np.float64)),
            "SE": ["" if math.isnan(s) else _sprintf("%.4f", s) for s in se],
            "90%-KI": ["" if math.isnan(a) else _sprintf("[%.4f, %.4f]", a, b) for a, b in zip(lo, up)]})
        lines.append(_fmt.print_data_frame(y, row_names=False))
        ols = x["ols"]
        lines.append("\nOLS (Mittelwert): %s" % ", ".join(_sprintf_vec("%s %.4f", [str(k) for k in ols.index],
                                                                       ols.to_numpy(dtype=np.float64))))
        return "\n".join(lines)


def _lm_coef(y, X1):
    """``.sl_lsfit(X1, y)$coefficients`` (OLS mit Konstante in ``X1``, Entwurf B.7)."""
    return np.asarray(_sl().lsfit(X1, y)["coefficients"], dtype=np.float64)


def tail_regression(data, asset, drivers, *, quantiles=(0.05, 0.25, 0.5, 0.75, 0.95),
                    frequency=("week", "day", "month"), B=199, block=None, seed=None):
    """Renditequantile in Abhängigkeit von Drittvariablen (Quantilsregression).

    Args:
        data: DataFrame mit ``date``, Kursspalte und Zustandsspalten.
        asset: Kursspalte.
        drivers: Zustandsspalten (Drittvariablen).
        quantiles: Quantile als Anteil.
        frequency: ``"week"``, ``"day"`` oder ``"month"``.
        B: Bootstrap-Wiederholungen (0 = keine Standardfehler).
        block: mittlere Blocklänge (``None`` = Politis-White).
        seed: Startwert (ganze Zahl, ``|seed| < 2**53``; ``None`` = genau einmal aus dem Zufallszustand von SimLev gezogen, siehe :func:`simlev.simlev_seed`) für den Bootstrap.

    Returns:
        :class:`SimLevTailRegression`.
    """
    frequency = _match_arg(frequency, ("week", "day", "month"))
    drivers = _as_names(drivers)
    quantiles = np.atleast_1d(np.asarray(quantiles, dtype=np.float64))
    rd = _dep_returns(data, [asset], drivers, frequency)
    ok = _complete_rows(*[rd[c].to_numpy() for c in [asset] + drivers])
    rd = rd.loc[ok].reset_index(drop=True) if not ok.all() else rd
    y = 100 * rd[asset].to_numpy(dtype=np.float64)
    X = rd[drivers].to_numpy(dtype=np.float64)
    n = y.size
    if n < 30:
        raise ValueError("tail_regression: zu wenige Perioden.")
    p = X.shape[1] + 1
    Xdf = pd.DataFrame(X, columns=drivers)
    est = np.column_stack([quantile_regression(y, X=Xdf, tau=q).to_numpy() for q in quantiles.tolist()])
    X1 = np.column_stack([np.ones(n), X])
    terms = ["(Intercept)"] + drivers
    nq = quantiles.size
    se = np.full((p, nq), _NAN)
    lo = se.copy()
    hi = se.copy()
    n_failed = 0
    if B > 0:
        if block is None:
            block = _rmin(_rmax(2, float(_boot()._pw_block(np.abs(y - r_mean(y)))["stationary"])), n / 10)

        S = _sl().main_stream(seed)                     # Hauptstrom (Entwurf C.5, Regeln 3 bis 5)
        bs = []
        for _b in range(int(B)):
            idx = np.asarray(_boot_idx_stationary(n, n, block, S), dtype=np.int64) - 1
            yb = y[idx]
            Xb = X1[idx, :]
            try:
                cols = []
                for k in range(nq):
                    bk, _o = _core.quantile_reg_core(yb, Xb, quantiles[k], est[:, k], _rmax(r_sd(yb), 1e-12), 1e-10, 2000)
                    cols.append(bk)
                bs.append(np.column_stack(cols))
            except _core.QuantileRegError:
                bs.append(np.full((p, nq), _NAN))
        n_failed = int(sum(bool(np.isnan(a).any()) for a in bs))
        if n_failed == B:
            warnings.warn("tail_regression: keine der %d Bootstrap-Stichproben schätzbar (singuläre Regressoren); "
                          "keine Standardfehler." % B)
        elif n_failed > 0:
            warnings.warn("tail_regression: %d von %d Bootstrap-Stichproben nicht schätzbar (singuläre Regressoren, "
                          "z. B. Treiber in der Stichprobe konstant); Standardfehler und Intervalle aus den übrigen %d."
                          % (n_failed, B, B - n_failed))
        A = np.stack(bs, axis=2)
        for i in range(p):
            for j in range(nq):
                v = A[i, j, :]
                se[i, j] = r_sd(v, na_rm=True)
                lo[i, j] = _q1(v, 0.05, na_rm=True)
                hi[i, j] = _q1(v, 0.95, na_rm=True)
    coefs = pd.DataFrame({"quantile": np.repeat(quantiles, len(terms)), "term": terms * nq,
                          "estimate": est.ravel(order="F"), "se": se.ravel(order="F"),
                          "lower": lo.ravel(order="F"), "upper": hi.ravel(order="F")})
    ols = pd.Series(_lm_coef(y, X1), index=terms)
    out = SimLevTailRegression()
    out["coefficients"] = coefs
    out["ols"] = ols
    out["asset"] = asset
    out["drivers"] = drivers
    out["quantiles"] = quantiles
    out["n"] = n
    out["frequency"] = frequency
    out["B"] = B
    out["B_failed"] = n_failed
    out["block"] = block
    out["data"] = rd
    return out


class SimLevCoVaR(RList):
    """Ergebnis von :func:`tail_covar` (R-Klasse ``SimLevCoVaR``)."""

    r_class = ("SimLevCoVaR",)

    def format(self):
        x = self
        st = x["state"]
        lines = [_sprintf("CoVaR (q = %g) für System '%s'%s; %d Perioden (%s), Werte in %% je Periode\n",
                          x["q"], x["system"], (", Zustand: %s" % ", ".join(st)) if st else "", int(x["n"]), x["frequency"])]
        s = x["summary"]
        y = pd.DataFrame({"Anlage": s["asset"].to_numpy(dtype=object),
                          "beta": _sprintf_vec("%.3f", s["beta"].to_numpy(dtype=np.float64)),
                          "VaR Anlage": _sprintf_vec("%.2f", s["var"].to_numpy(dtype=np.float64)),
                          "CoVaR": _sprintf_vec("%.2f", s["covar"].to_numpy(dtype=np.float64)),
                          "Delta-CoVaR": _sprintf_vec("%.2f", s["delta_covar"].to_numpy(dtype=np.float64)),
                          "Delta-CoVaR min": _sprintf_vec("%.2f", s["delta_covar_min"].to_numpy(dtype=np.float64))})
        lines.append(_fmt.print_data_frame(y, row_names=False))
        return "\n".join(lines)


def _matvec(M, b):
    """``drop(M %m% b)`` (slc-Matrixprodukt, Entwurf B.6)."""
    return np.asarray(_sl().matmul(np.asarray(M, dtype=np.float64), np.asarray(b, dtype=np.float64).reshape(-1, 1)),
                      dtype=np.float64).ravel()


def tail_covar(data, system, assets, *, state=None, q=0.05, frequency=("week", "day", "month")):
    """CoVaR und Delta-CoVaR (Adrian & Brunnermeier 2016).

    Args:
        data: DataFrame mit ``date``, Kursspalten und gegebenenfalls Zustandsspalten.
        system: Kursspalte des Systems bzw. Portfolios.
        assets: Kursspalten der einzelnen Anlagen.
        state: Zustandsspalten (``None`` = zeitkonstante Quantile).
        q: Quantil als Anteil.
        frequency: ``"week"``, ``"day"`` oder ``"month"``.

    Returns:
        :class:`SimLevCoVaR`.
    """
    frequency = _match_arg(frequency, ("week", "day", "month"))
    assets = _as_names(assets)
    state = _as_names(state) if state is not None else None
    cols = list(dict.fromkeys([system] + assets))
    rd = _dep_returns(data, cols, state, frequency)
    ok = _complete_rows(*[rd[c].to_numpy() for c in rd.columns])
    rd = rd.loc[ok].reset_index(drop=True)
    M = rd[state].to_numpy(dtype=np.float64) if state else None
    Mdf = pd.DataFrame(M, columns=state) if state else None
    ys = 100 * rd[system].to_numpy(dtype=np.float64)
    summ = []
    series = []
    nr = len(rd)
    for a in assets:
        xi = 100 * rd[a].to_numpy(dtype=np.float64)
        bq = quantile_regression(xi, X=Mdf, tau=q).to_numpy()
        bm = quantile_regression(xi, X=Mdf, tau=0.5).to_numpy()
        Mi = np.ones((nr, 1)) if M is None else np.column_stack([np.ones(nr), M])
        var_q = _matvec(Mi, bq)
        var_m = _matvec(Mi, bm)
        Xs = pd.DataFrame({"xi": xi}) if M is None else pd.concat([pd.DataFrame({"xi": xi}), Mdf], axis=1)
        bs = quantile_regression(ys, X=Xs, tau=q).to_numpy()
        covar = bs[0] + bs[1] * var_q + (_matvec(M, bs[2:]) if M is not None else 0)
        dcv = bs[1] * (var_q - var_m)
        summ.append({"asset": a, "beta": float(bs[1]), "var": r_mean(var_q), "covar": r_mean(covar),
                     "delta_covar": r_mean(dcv), "delta_covar_min": _rmin(dcv)})
        series.append(pd.DataFrame({"date": rd["date"].to_numpy(), "asset": a, "var": var_q, "covar": covar,
                                    "delta_covar": dcv}))
    out = SimLevCoVaR()
    out["summary"] = pd.DataFrame(summ, columns=["asset", "beta", "var", "covar", "delta_covar", "delta_covar_min"])
    out["series"] = pd.concat(series, ignore_index=True) if series else None
    out["system"] = system
    out["state"] = state
    out["q"] = q
    out["frequency"] = frequency
    out["n"] = nr
    return out


# ═════════════════════════════════════════════════════════════════════════════
# Bootstrap-Validierung und Stress-Regime
# ═════════════════════════════════════════════════════════════════════════════

def _rowsum_blocks(L, agg, k):
    """``rowsum(L[1:(k*agg), ], rep(1:k, each = agg))`` (double-Akkumulation)."""
    L = np.asarray(L, dtype=np.float64)[: k * agg, :]
    out = np.zeros((k, L.shape[1]))
    for r in range(agg):
        out = out + L[r::agg, :][:k, :]
    return out


def dependence_validate(boot, data, *, agg=5, q=0.10, max_paths=200):
    """Abhängigkeitsstruktur von Bootstrap-Pfaden prüfen.

    Args:
        boot: Ergebnis von ``bootstrap()`` (Klasse ``bootstrap_result``) mit
            mindestens zwei Indizes.
        data: historische Daten wie für ``bootstrap()``.
        agg: Zeilen je Periode für die Aggregation.
        q: Tail-Wahrscheinlichkeit.
        max_paths: höchstens so viele Pfade auswerten.

    Returns:
        ``pandas.DataFrame`` mit ``pair``, ``metric``, ``historical``,
        ``median``, ``p05``, ``p95``, ``percentile``.
    """
    rc = getattr(boot, "r_class", ())
    if "bootstrap_result" not in tuple(rc):
        raise ValueError("boot muss ein bootstrap_result sein.")
    cfg = boot["config"]
    idx_names = _as_names(cfg["index_names"])
    if len(idx_names) < 2:
        raise ValueError("dependence_validate: mindestens zwei Indizes in der Konfiguration.")
    ret = _boot()._extract_returns(data, cfg)["ret"]
    hist = _libm.log(np.asarray(ret, dtype=np.float64))
    agg = int(agg)

    def aggr(L):
        k = L.shape[0] // agg
        if k < 20:
            raise ValueError("Zu wenige Perioden nach Aggregation.")
        return _rowsum_blocks(L, agg, k)

    def stats_of(L):
        A = aggr(L)
        out = []
        for i, j in _combn2(A.shape[1]):
            x = A[:, i]
            y = A[:, j]
            td = tail_dependence(x, y, q=q)
            out += [_kendall(x, y), _cor1(x, y), float(td["lower"].iloc[0]), float(td["upper"].iloc[0]),
                    float(td["exceed_lower"].iloc[0])]
        return np.array(out, dtype=np.float64)
    h = stats_of(hist)
    paths = list(boot["paths"])[: int(max_paths)]
    cols = []
    for pth in paths:
        if isinstance(pth, pd.DataFrame):
            Pm = pth[idx_names].to_numpy(dtype=np.float64)
        else:
            Pm = np.asarray(pth, dtype=np.float64)
        lg = _libm.log(Pm)
        cols.append(stats_of(lg[1:, :] - lg[:-1, :]))
    P = np.column_stack(cols) if cols else np.zeros((h.size, 0))
    pr = ["%s ~ %s" % (idx_names[i], idx_names[j]) for i, j in _combn2(len(idx_names))]
    metrics = ["kendall", "pearson", "lambda_lower", "lambda_upper", "exceed_lower"]
    pct = []
    for i in range(h.size):
        cmp_ = P[i, :] <= h[i]
        valid = ~(np.isnan(P[i, :]) | np.isnan(h[i]))
        pct.append(r_mean(cmp_[valid].astype(np.float64)))
    return pd.DataFrame({"pair": [p for p in pr for _ in range(5)], "metric": metrics * len(pr), "historical": h,
                         "median": [_median(P[i, :], na_rm=True) for i in range(h.size)],
                         "p05": [_q1(P[i, :], 0.05, na_rm=True) for i in range(h.size)],
                         "p95": [_q1(P[i, :], 0.95, na_rm=True) for i in range(h.size)],
                         "percentile": pct})


def _eval_condition(expr, data, env=None):
    """Bedingung als Text über den Spalten von ``data`` auswerten.

    Wie ``eval(parse(text = expr), data, env)`` in R mit dem gemeinsamen
    Auswerter :mod:`simlev._r.rexpr` (R-Syntax, Vorrang und NA-Logik wie in R);
    freie Variablen aus ``env``. Eine Python-Funktion ``f`` wird als ``f(data)``
    aufgerufen.
    """
    if callable(expr):
        return expr(data)
    from ._r import rexpr as _rexpr
    df = data if isinstance(data, pd.DataFrame) else pd.DataFrame(data)
    return _rexpr.eval_r(expr, df, env={} if env is None else env)


@env_from_caller
def regime_subset(data, condition, *, min_run=1, env=None):
    """Zeilen eines Regimes für Stress-Bootstraps.

    Args:
        data: DataFrame (Spalte ``date`` optional).
        condition: Logischer Vektor der Länge ``len(data)`` (NA = FALSE),
            Ausdruck als Text in R-Syntax (z. B. ``"inflation >= 4 & zins < 2"``,
            siehe :mod:`simlev._r.rexpr`) oder Funktion ``data -> Vektor``.
        min_run: Mindestlänge einer Episode in Zeilen.
        env: Mapping für freie Variablen und Funktionen in ``condition``
            (Voreinstellung: Namensraum des Aufrufers).

    Returns:
        Teilmenge von ``data`` mit ``attrs["episodes"]`` (DataFrame ``start``,
        ``end``, ``length`` und ggf. ``start_date``, ``end_date``).
    """
    if isinstance(condition, str) or callable(condition):
        cond = _eval_condition(condition, data, env)
        if isinstance(condition, str):
            from ._r import rexpr as _rexpr
            cond = _rexpr.as_logical(cond)
    else:
        cond = condition
    if isinstance(cond, (pd.Series, pd.Index)):
        cond = cond.to_numpy()
    ca = np.atleast_1d(np.asarray(cond, dtype=object))
    c = np.array([False if (v is None or (isinstance(v, float) and math.isnan(v))) else bool(v) for v in ca], dtype=bool)
    if c.size != len(data):
        raise ValueError("condition muss die Länge nrow(data) haben.")
    # rle
    vals, lens = [], []
    for v in c.tolist():
        if vals and vals[-1] == v:
            lens[-1] += 1
        else:
            vals.append(v)
            lens.append(1)
    lens = np.array(lens, dtype=np.int64)
    ends = np.cumsum(lens)
    starts = ends - lens + 1
    keep = np.array(vals, dtype=bool) & (lens >= min_run)
    if not keep.any():
        raise ValueError("regime_subset: keine Episode erfüllt condition und min_run.")
    rows = np.concatenate([np.arange(s - 1, e) for s, e in zip(starts[keep], ends[keep])])
    out = data.iloc[rows].copy()
    ep = pd.DataFrame({"start": starts[keep], "end": ends[keep], "length": lens[keep]})
    if "date" in data.columns:
        d = _to_date(data["date"], "regime_subset: data$date")
        ep["start_date"] = d[ep["start"].to_numpy() - 1]
        ep["end_date"] = d[ep["end"].to_numpy() - 1]
    out.attrs["episodes"] = ep
    return out


# Rechnen mit NA (signalisierendes NaN) ohne numpy-Warnung "invalid value" wie in R (gemeinsamer Helfer)
from .svg import _grid_bars, _grid_lines, _grid_scatter, _grid_svg, _plot_method  # noqa: E402

SimLevDependence.plot = _plot_method(_plot_dependence, "SimLevDependence")
SimLevTailRegression.plot = _plot_method(_plot_tail_regression, "SimLevTailRegression")
SimLevCoVaR.plot = _plot_method(_plot_covar, "SimLevCoVaR")

from ._r.base import quiet_fp  # noqa: E402

quiet_fp(globals(), list(__all__) + ["_cop_lambda", "_cop_ll", "_dep_check_prices", "_dep_reg_cor", "_dep_regimes", "_dep_returns", "_dep_sort_dates", "_kendall", "_pobs", "_roll_mean"])  # regime_subset: env aus dem Aufrufer (env_from_caller)
