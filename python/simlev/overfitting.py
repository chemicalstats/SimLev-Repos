"""Schutz vor Überanpassung bei Parametersuchen (R: ``overfitting.R``).

- :func:`overfit_pbo`                   Probability of Backtest Overfitting mit
                                Combinatorially Symmetric Cross-Validation
                                (Bailey, Borwein, López de Prado & Zhu 2017)
- :func:`sharpe_deflated`       Deflated Sharpe Ratio (Bailey & López de Prado
                                2014) inkl. effektiver Versuchsanzahl
- :func:`sharpe_probabilistic`  Probabilistic Sharpe Ratio (Bailey & López de
                                Prado 2012)
- :func:`overfit_walk_forward`          rollierende Auswahl In-Sample, Bewertung
                                Out-of-Sample
- :func:`param_bootstrap`       beste Punkte einer Suche auf Bootstrap-Pfaden
- :func:`sharpe_haircut`        Sharpe-Ratio-Abschlag für Mehrfachtests

Alle Verfahren arbeiten auf den täglichen TWR-Renditen, die
:func:`simlev.param_search` je Punkt speichert.
"""
from __future__ import annotations

import importlib
import itertools
import math
import warnings

import numpy as np
import pandas as pd

from ._r import libm as _libm
from . import _lib
from ._r import fmt as _fmt
from ._r.rlist import RList
from . import _dependence_core as _dcore
from ._r.rnum import r_colmeans, r_colsums, r_rowmeans, r_mean, r_mean_int, r_median, r_pow, r_prod, r_cumprod, r_sum, r_var, r_sd
# Grafik: Bausteine des Stils Ergebnisgrafiken und Zahlen wie in Julia aus svg.py
from .svg import (_jl_unique, _res_abline, _res_fig, _res_finish, _res_hline, _res_legend, _res_line, _res_panel,
                  _res_points, _res_range, _res_rect, _res_vline)
from ._util import _match_arg
from ._util import _geo_ann, _geo_ret
from ._util import _which_max
from ._util import _ext
from ._util import _fmt_vec

__all__ = ["overfit_pbo", "sharpe_probabilistic", "sharpe_deflated", "overfit_walk_forward", "param_bootstrap",
           "sharpe_haircut", "SimLevPBO", "SimLevDSR", "SimLevWalkForward"]

_NAN = float("nan")      # R's NaN
_NA = _fmt.NA_REAL       # R's NA_real_
_EPOCH = np.datetime64("1970-01-01", "D")


# ─────────────────────────────────────────────────────────────────────────────
# Fremdfunktionen (andere Bearbeiter) und R-Interna
# ─────────────────────────────────────────────────────────────────────────────

def _as_dates(x):
    """Datumswerte (bereits von ``_to_date`` geprüft) → ``datetime64[D]``-Array."""
    if x is None:
        return None
    a = np.asarray(x)
    if np.issubdtype(a.dtype, np.datetime64):
        return a.astype("datetime64[D]").ravel()
    return pd.to_datetime(pd.Series(np.asarray(x).ravel())).to_numpy().astype("datetime64[D]")


def _to_date(x, what):
    return _as_dates(_ext("data_prep", "_to_date")(x, what))


def _days(d):
    """Datum → Tage seit 1970 (float64)."""
    return (d.astype("datetime64[D]") - _EPOCH).astype(np.int64).astype(np.float64)


# colSums/colMeans/rowSums/rowMeans über den C-Kern core/slc_rbase.cpp (long double wie R; wie Julia)
def _colsums(M):
    """``colSums`` (long-double-Akkumulator, sequenziell)."""
    return r_colsums(M)


def _colmeans(M):
    """``colMeans``: long-double-Summe / n, dann double."""
    n, p = M.shape
    if n == 0:
        return np.full(p, _NAN)
    return r_colmeans(M)


def _rowmeans(M):
    return r_rowmeans(M)


def _rowsum(M, codes, ng):
    """``rowsum(x, g, reorder = FALSE)``: double-Akkumulation in Zeilenreihenfolge."""
    out = np.zeros((ng, M.shape[1]))
    with np.errstate(invalid="ignore"):     # NA (signalisierendes NaN) wie in R ohne Warnung
        for i in range(M.shape[0]):
            out[codes[i]] = out[codes[i]] + M[i]
    return out


def _matprod(A, B):
    """``A %m% B`` wie R (slc-Matrixprodukt)."""
    return np.asarray(_lib.matmul(A, B), dtype=np.float64)


def _rank_avg(x):
    """``rank(x)`` mit ``ties.method = "average"``."""
    from ._r.stats import rank
    return np.asarray(rank(np.asarray(x, dtype=np.float64)), dtype=np.float64)


def _stats(name):
    st = importlib.import_module("simlev._r.stats")
    return getattr(st, name)


def _lm_coef(x, y):
    """Koeffizienten (Achsenabschnitt, Steigung) wie ``.sl_lsfit(cbind(1, x), y)``."""
    f = _lib.lsfit
    x = np.asarray(x, float)
    y = np.asarray(y, float)
    ok = ~(np.isnan(x) | np.isnan(y))                 # na.action = na.omit
    # cbind(1, numeric(0)) ist 1 x 1: ohne Paar wie R "Längen von x und y passen nicht" (seit 1.5.1)
    X = np.column_stack([np.ones(int(ok.sum())), x[ok]]) if ok.any() else np.ones((1, 1))
    fit = f(X, y[ok])
    cf = fit["coefficients"] if isinstance(fit, dict) or hasattr(fit, "keys") else fit
    cf = np.asarray(cf, dtype=np.float64).ravel()
    return float(cf[0]), float(cf[1])


def _cor(M):
    return np.asarray(_stats("cor")(M), dtype=np.float64)


def _p_adjust(p, method, n):
    return np.asarray(_stats("p_adjust")(p, method=method, n=n), dtype=np.float64)


def _sprintf(f, *a):
    return _fmt.sprintf(f, *a)


def _cat(s):
    print(s, end="")


# ─────────────────────────────────────────────────────────────────────────────
# Renditematrix
# ─────────────────────────────────────────────────────────────────────────────

def _is_param_search(x):
    try:
        from .param_search import SimLevParamSearch
    except ImportError:          # pragma: no cover
        return False
    return isinstance(x, SimLevParamSearch)


def _as_return_matrix(x):
    """``as.matrix(x)`` einer numerischen Eingabe → (Matrix, Spaltennamen oder None, Zeilennamen)."""
    rn = None
    if isinstance(x, pd.DataFrame):
        ok = all(pd.api.types.is_numeric_dtype(x[c]) and not pd.api.types.is_bool_dtype(x[c]) for c in x.columns)
        if not ok:
            raise ValueError("x muss ein SimLevParamSearch oder eine numerische Renditematrix sein.")
        cn = None if isinstance(x.columns, pd.RangeIndex) else [str(c) for c in x.columns]
        if not isinstance(x.index, pd.RangeIndex):
            rn = [str(i) for i in x.index]
        return x.to_numpy(dtype=np.float64, na_value=_NA), cn, rn
    if isinstance(x, pd.Series):
        a = x.to_numpy()
        if a.dtype.kind not in "iuf":
            raise ValueError("x muss ein SimLevParamSearch oder eine numerische Renditematrix sein.")
        rn = None if isinstance(x.index, pd.RangeIndex) else [str(i) for i in x.index]
        return a.astype(np.float64).reshape(-1, 1), None, rn
    a = np.asarray(x)
    if a.dtype.kind not in "iuf":
        raise ValueError("x muss ein SimLevParamSearch oder eine numerische Renditematrix sein.")
    a = a.astype(np.float64)
    if a.ndim == 1:
        a = a.reshape(-1, 1)
    return a, None, None


def _returns_frame(R, cols, rn=None):
    df = pd.DataFrame(R, columns=list(cols))
    if rn is not None:
        df.index = list(rn)
    return df


def _combn(S, k):
    """``utils::combn(S, k)`` als Matrix C x k (int32, 1-basiert), ohne Zwischenliste. Wie R wird die Anzahl als
    Ganzzahl gebildet: jenseits von ``.Machine$integer.max`` (S >= 34) Warnung und Fehler, ohne die Kombinationen
    aufzubauen (seit 1.5.1)."""
    nc = math.comb(S, k)
    if nc > 2147483647:
        warnings.warn("NAs introduced by coercion to integer range", UserWarning, stacklevel=3)
        raise ValueError("invalid 'ncol' value (too large or NA)")
    flat = np.fromiter(itertools.chain.from_iterable(itertools.combinations(range(1, S + 1), k)), dtype=np.int32,
                       count=nc * k)
    return flat.reshape(nc, k)


def _log1p(R):
    """``log1p(R)`` mit R's Warnung "NaNs produced" (Werte unter -1, -Inf; seit 1.5.1)."""
    out = _libm.log1p(R)
    if np.any(np.isnan(out) & ~np.isnan(R)):
        warnings.warn("NaNs produced", UserWarning, stacklevel=3)
    return out


def _of_returns_np(x, frequency, dates=None, risk_free=0):
    """Wie ``.of_returns``; liefert ``(R, Spaltennamen, Zeilennamen, dates, ppy, cols)`` mit numpy."""
    if _is_param_search(x):
        if x.get("returns") is None:
            raise ValueError("Suche ohne gespeicherte Renditen (keep_returns = \"none\").")
        ret = x["returns"]
        if isinstance(ret, pd.DataFrame):
            R = ret.to_numpy(dtype=np.float64, na_value=_NA)
            cn = [str(c) for c in ret.columns]
        else:
            R = np.asarray(ret, dtype=np.float64)
            if R.ndim == 1:
                R = R.reshape(-1, 1)
            cn = ["p%d" % (j + 1) for j in range(R.shape[1])]
        rn = None
        dates = x.get("dates")
    else:
        R, cn, rn = _as_return_matrix(x)
        if cn is None:
            cn = ["p%d" % (j + 1) for j in range(R.shape[1])]
    keep = np.isfinite(R).sum(axis=0) > 0
    R = R[:, keep]
    cn = [c for c, k in zip(cn, keep) if k]
    if dates is not None:
        dates = _to_date(dates, "dates")
    if dates is not None and frequency != "day":
        key = _fmt.format_date(dates, "%G-%V" if frequency == "week" else "%Y-%m")
        key = [str(k) for k in key]
        if len(key) != R.shape[0]:
            raise ValueError("incorrect length for 'group'")
        lev = list(dict.fromkeys(key))
        pos = {k: i for i, k in enumerate(lev)}
        codes = np.array([pos[k] for k in key], dtype=np.int64)
        S = _rowsum(_log1p(R), codes, len(lev))
        R = _libm.expm1(S)                    # seit 1.6.2 expm1 (P2)
        rn = lev
        last = np.array([key[i] != key[i + 1] for i in range(len(key) - 1)] + [True], dtype=bool)
        dates = dates[last]
    ok = ~np.isnan(R).any(axis=1)
    R = R[ok]
    if rn is not None:
        rn = [r for r, k in zip(rn, ok) if k]
    if dates is not None:
        dates = dates[ok]
    if dates is not None and len(dates) > 1:
        span = float(_days(dates[-1:])[0] - _days(dates[:1])[0])
        ppy = (len(dates) - 1) / (span / 365.25)
    else:
        ppy = {"day": 252.0, "week": 52.0, "month": 12.0}[frequency]
    R = R - risk_free / 100 / ppy
    cols = np.nonzero(keep)[0].astype(np.int64) + 1
    return R, cn, rn, dates, ppy, cols


def _of_returns(x, frequency, dates=None, risk_free=0):
    """Renditematrix und Datum aus Suche oder Matrix holen, ggf. aggregieren (``.of_returns``).

    Liefert ein dict mit ``R`` (``pandas.DataFrame``, Spalten = Punkte, bei
    Aggregation Zeilennamen = Wochen-/Monatsschlüssel), ``dates``
    (``datetime64[D]``-Array oder ``None``), ``ppy`` (Perioden je Jahr) und
    ``cols`` (1-basierte Spaltennummern der ursprünglichen Matrix, int64).
    """
    R, cn, rn, dates, ppy, cols = _of_returns_np(x, frequency, dates, risk_free)
    return {"R": _returns_frame(R, cn, rn), "dates": dates, "ppy": ppy, "cols": cols}


class _RR:
    """Interne Renditequelle (numpy) wie die Liste ``rr`` in R."""

    def __init__(self, R, cn, rn, dates, ppy, cols):
        self.R, self.cn, self.rn, self.dates, self.ppy, self.cols = R, list(cn), rn, dates, ppy, cols


def _rr(x, frequency, dates=None, risk_free=0):
    return _RR(*_of_returns_np(x, frequency, dates, risk_free))


def _of_metric(n, s1, s2, sdn, sl, metric, c1=None):
    """Kennzahl aus Summen-Statistiken (spaltenweise, auch Matrizen); Argumente
    ``s2``, ``sdn``, ``sl``, ``c1`` dürfen Funktionen sein (verzögerte Auswertung wie in R)."""
    def ev(v):
        return v() if callable(v) else v
    s1 = ev(s1)
    m = s1 / n
    if metric == "sharpe":
        c1 = s1 if c1 is None else ev(c1)
        return m / np.sqrt(np.maximum((ev(s2) - c1 * c1 / n) / (n - 1), 1e-300))
    if metric == "sortino":
        return m / np.sqrt(np.maximum(ev(sdn) / n, 1e-300))
    if metric == "geometric":
        return _libm.expm1(ev(sl) / n)
    if metric == "mean":
        return m
    raise ValueError("metric: 'sharpe', 'sortino', 'geometric' oder 'mean'.")


def _of_col_metric(R, metric):
    """Kennzahl je Spalte einer Renditematrix (``.of_col_metric``)."""
    if isinstance(R, pd.DataFrame):
        names = [str(c) for c in R.columns]
        out = _of_col_metric(R.to_numpy(dtype=np.float64), metric)
        return pd.Series(out, index=names)
    R = np.asarray(R, dtype=np.float64)
    if R.ndim == 1:
        R = R.reshape(-1, 1)
    Rc = R - _colmeans(R)[None, :]
    return np.asarray(_of_metric(R.shape[0], _colsums(R), lambda: _colsums(Rc * Rc),
                                 lambda: (lambda P: _colsums(P * P))(np.minimum(R, 0.0)),
                                 lambda: _colsums(_log1p(R)), metric, c1=lambda: _colsums(Rc)),
                      dtype=np.float64)


def _of_drop_flat(rr, what):
    """Spalten ohne Schwankung (Sharpe Ratio nicht definiert) ausschließen."""
    R = rr.R
    sdv = np.array([r_sd(R[:, j]) for j in range(R.shape[1])])
    flat = np.nonzero(~(sdv > 1e-10) & ~np.isnan(sdv))[0]    # which(!(sdv > 1e-10)): NaN (z. B. bei Inf) zählt nicht
    if not flat.size:
        return rr
    if flat.size == R.shape[1]:
        raise ValueError("%s: alle Spalten ohne Schwankung (Standardabweichung <= 1e-10); Sharpe Ratio nicht definiert." % what)
    warnings.warn("%s: %d Spalte(n) ohne Schwankung (Standardabweichung <= 1e-10 je Periode, z. B. Geldmarkt mit festem Zins; "
                  "Punkt(e) %s) ausgeschlossen - Sharpe Ratio dort nicht definiert."
                  % (what, flat.size, ", ".join(str(int(rr.cols[j])) for j in flat)), UserWarning, stacklevel=3)
    keep = np.ones(R.shape[1], dtype=bool)
    keep[flat] = False
    rr.R = R[:, keep]
    rr.cn = [c for c, k in zip(rr.cn, keep) if k]
    rr.cols = rr.cols[keep]
    return rr


# Grafik: Bausteine `_res_*` (Stil Ergebnisgrafiken, auch für param_search, sensitivity) in svg.py

def _frame_data(**cols):
    return pd.DataFrame(cols)


# ─────────────────────────────────────────────────────────────────────────────
# PBO
# ─────────────────────────────────────────────────────────────────────────────

class SimLevPBO(RList):
    """Ergebnis von :func:`overfit_pbo` (R-Klasse ``SimLevPBO``)."""

    r_class = ("SimLevPBO",)

    def format(self):
        x = self
        out = ["Probability of Backtest Overfitting (PBO, CSCV)\n"]
        out.append(_sprintf("  %d Punkte, %d Beobachtungen (%s), S = %d Blöcke, %d Aufteilungen, Kennzahl %s\n",
                            x["n_points"], x["n_obs"], x["frequency"], x["S"], x["n_combos"], x["metric"]))
        out.append(_sprintf("  PBO:                              %.1f %%\n", 100 * x["pbo"]))
        out.append(_sprintf("  Median-Logit lambda:              %.2f\n", r_median(x["lambda"])))
        out.append(_sprintf("  Leistungsabfall (Steigung OOS~IS): %.2f\n", x["slope"]))
        out.append(_sprintf("  OOS-Verlustwahrscheinlichkeit:    %.1f %%\n", 100 * x["prob_loss"]))
        ob = np.asarray(x["oos_best"], float)
        om = np.asarray(x["oos_median"], float)
        out.append(_sprintf("  Gewählter Punkt OOS vor Median:   %.1f %%\n", 100 * _mean_lgl(ob > om, np.isnan(ob) | np.isnan(om))))
        N = int(x["n_points"])
        out.append(_sprintf("  Lesart: PBO nahe 0 = Auswahl trägt, um %.0f %% = Zufall%s, darüber = Auswahl schadet.\n",
                            100 * (N + N % 2) / (2 * N), " (ungerade Punktezahl: (N + 1) / (2N))" if N % 2 else ""))
        return "".join(out)[:-1]

    def print(self):
        print(self.format())
        return self

    # ``plot`` (SVG, ``SimLevPlot``) wird am Modulende über ``_plot_method`` gesetzt.


def _mean_lgl(v, na=None):
    """``mean()`` eines logischen Vektors (NA, falls ``na`` irgendwo wahr)."""
    v = np.asarray(v, dtype=bool)
    if na is not None and np.asarray(na).any():
        return _NA
    if v.size == 0:
        return _NAN
    return r_mean_int(v.astype(np.int64))


def overfit_pbo(x, *, S=16, metric=("sharpe", "sortino", "geometric", "mean"),
        frequency=("week", "day", "month"), dates=None, risk_free=0):
    """Probability of Backtest Overfitting (CSCV).

    Teilt die Renditehistorie aller Punkte einer Parametersuche in ``S`` gleich lange Blöcke und bildet alle
    binom(S, S/2) Aufteilungen in In-Sample- und Out-of-Sample-Hälften. Je Aufteilung wird der In-Sample- beste
    Punkt bestimmt und sein Rang Out-of-Sample gemessen (Logit λ). Die PBO ist der Anteil der Aufteilungen, in
    denen der gewählte Punkt Out-of-Sample nicht über dem Median landet (λ ≤ 0, Schätzer ∫_-∞^0 f(λ)dλ nach Bailey
    et al.; λ = 0, also genau der Median-Rang, zählt mit). Werte nahe 0 sprechen für echte Ueberlegenheit, Werte
    um 0.5 und darüber für eine Auswahl nach Zufall. Bei reinem Zufall und ungerader Punktezahl N landet der
    gewählte Punkt mit Wahrscheinlichkeit 1/N genau auf dem Median; der Erwartungswert der PBO ist dann (N + 1) /
    (2N) statt 0.5 (z. B. 0.67 bei N = 3, 0.6 bei N = 5). Gleichstände (z. B. identische Spalten) erhalten
    mittlere Ränge und können ebenfalls λ = 0 ergeben.

    Args:
        x: Renditequelle:

            - ``SimLevParamSearch`` aus ``param_search()`` mit gespeicherten Renditen (``keep_returns = "day"``);
              verwendet werden ``x["returns"]`` (tägliche Renditen je Punkt) und ``x["dates"]``;
            - numerische Matrix oder DataFrame nur aus numerischen Spalten (ohne Datumsspalte): Zeilen = Perioden,
              Spalten = Punkte bzw. Strategien, einfache Renditen als Anteil (0.01 = 1 %); ohne Spaltennamen
              heißen die Spalten ``p1``, ``p2``, ...

            Spalten ohne endlichen Wert werden verworfen, danach alle Zeilen mit einem fehlenden Wert; bei
            ``metric = "sharpe"`` außerdem Spalten ohne Schwankung (Standardabweichung <= 1e-10 je Periode, mit
            Warnung), deren Sharpe Ratio nicht definiert ist. Mindestens zwei Spalten nötig. Bei
            ``print()``/``plot()``: Objekt der Klasse ``SimLevPBO``.
        S: Anzahl Blöcke (gerade ganze Zahl >= 2, Standard 16 ergibt binom(16, 8) = 12870 Aufteilungen).
        metric: Kennzahl je Periode (nach Abzug von ``risk_free``, nicht annualisiert): ``"sharpe"`` (Standard;
            Mittelwert / Standardabweichung), ``"sortino"`` (Mittelwert / Wurzel des mittleren quadrierten
            negativen Teils), ``"geometric"`` (geometrische Periodenrendite exp(log(1 + r)) - 1, Anteil) oder
            ``"mean"`` (arithmetisches Mittel, Anteil). Höher = besser.
        frequency: Periodenlänge der Auswertung: ``"week"`` (Standard), ``"day"`` oder ``"month"``. Mit Datum (bei
            ``SimLevParamSearch`` immer, bei Matrizen über ``dates``) werden die Tagesrenditen geometrisch zu
            ISO-Wochen bzw. Kalendermonaten verkettet. Ohne Datum wird nicht aggregiert; die Zeilen gelten dann
            als Perioden dieser Frequenz (wichtig für ``ppy``). Achtung: Eine Matrix von Tagesrenditen ohne
            ``dates`` braucht ``frequency = "day"``; mit dem Standard ``"week"`` wird mit 52 statt 252 Perioden je
            Jahr annualisiert (betrifft annualisierte Sharpe Ratios und ``risk_free``).
        dates: Datum je Zeile von ``x`` (Date oder umwandelbar), nur bei Matrix-Eingabe; ``None`` (Standard) =
            keine Aggregation. Bei ``SimLevParamSearch`` wird ``x["dates"]`` verwendet.
        risk_free: Risikoloser Zins in Prozent p. a. (2 = 2 %, Standard 0); wird als ``risk_free / 100 / ppy`` von
            jeder Periodenrendite abgezogen. ``ppy`` (Perioden je Jahr) wird aus dem Datum geschätzt: (Anzahl
            Perioden - 1) / (Zeitspanne in Tagen / 365.25); ohne Datum 252 (``"day"``), 52 (``"week"``) bzw. 12
            (``"month"``).

    Returns:
        Objekt der Klasse ``SimLevPBO``, eine Liste mit ``pbo`` (Anteil der Aufteilungen mit λ ≤ 0), ``lambda``
        (Logit je Aufteilung), ``is_best`` (In-Sample-Kennzahl des gewählten Punkts je Aufteilung), ``oos_best``
        (seine Out-of-Sample-Kennzahl), ``oos_median`` (Median der Out-of-Sample-Kennzahl aller Punkte),
        ``slope``, ``intercept`` (Regression ``oos_best ~ is_best``; negative Steigung = Leistungsabfall),
        ``prob_loss`` (Anteil der Aufteilungen mit ``oos_best < 0``), ``S``, ``n_combos`` (Anzahl Aufteilungen),
        ``n_points`` (Anzahl Spalten), ``n_obs`` (verwendete Perioden), ``metric``, ``frequency`` und ``ppy``. Die
        Kennzahlen sind je Periode angegeben, nicht annualisiert.

    Details:
        Verwendet werden die letzten S ⌊ T/S ⌋ Perioden; jeder Block braucht mindestens 4 Perioden. Eingabe ist
        eine Parametersuche oder eine Renditematrix (eine Spalte je Variante). Mehrere fertige Simulationen (Liste
        von ``SimLevResult``) werden vorher zu einer Matrix zusammengefasst, siehe Beispiel bei
        ``overfit_reality_check()``.

    Literatur:
        Bailey, D. H., Borwein, J., Lopez de Prado, M. & Zhu, Q. J. (2017). The probability of backtest
        overfitting. Journal of Computational Finance 20(4), 39-69.

    Beispiel::

        import numpy as np, simlev
        rng = np.random.default_rng(1)
        R = rng.normal(2e-4, 0.01, (2000, 30))     # 30 Zufallsstrategien
        print(simlev.overfit_pbo(R, S=10, frequency="day")["pbo"])   # etwa 0.5
    """
    metric = _match_arg(metric, ("sharpe", "sortino", "geometric", "mean"), "metric")
    frequency = _match_arg(frequency, ("week", "day", "month"), "frequency")
    S = int(S)
    if S < 2 or S % 2:
        raise ValueError("S muss gerade und >= 2 sein.")
    rr = _rr(x, frequency, dates, risk_free)
    if metric == "sharpe":
        rr = _of_drop_flat(rr, "overfit_pbo")
    R = rr.R
    N = R.shape[1]
    Tn = R.shape[0]
    if N < 2:
        raise ValueError("Mindestens zwei Punkte nötig.")
    bl = Tn // S
    if bl < 4:
        raise ValueError("Zu wenige Beobachtungen (%d) für S = %d Blöcke." % (Tn, S))
    R = R[Tn - bl * S:Tn]
    blk = np.repeat(np.arange(S), bl)
    Rc = R - _colmeans(R)[None, :]
    B1 = _rowsum(R, blk, S)
    B2 = _rowsum(Rc * Rc, blk, S)
    Pm = np.minimum(R, 0.0)
    Bd = _rowsum(Pm * Pm, blk, S)
    Bl = _rowsum(_log1p(R), blk, S)
    Bc = _rowsum(Rc, blk, S)
    T1, T2, Td, Tl, Tc = (_colsums(B) for B in (B1, B2, Bd, Bl, Bc))
    combos = _combn(S, S // 2)                                                          # C x S/2, 1-basiert
    C = combos.shape[0]
    half = bl * S / 2
    # je Aufteilung im Kern (core/research_core_impl.h, pbo_cscv; bis 1.4.3 hier in Python)
    lam, isb, oosb, oosm = _dcore.pbo_cscv((B1, B2, Bd, Bl, Bc), (T1, T2, Td, Tl, Tc), combos, half, metric, S, N)
    intercept, slope = _lm_coef(isb, oosb)
    return SimLevPBO(pbo=_mean_lgl(lam <= 0, np.isnan(lam)), **{"lambda": lam}, is_best=isb, oos_best=oosb,
                     oos_median=oosm, slope=slope, intercept=intercept,
                     prob_loss=_mean_lgl(oosb < 0, np.isnan(oosb)), S=S, n_combos=C, n_points=N, n_obs=bl * S,
                     metric=metric, frequency=frequency, ppy=rr.ppy)


def _plot_pbo(x):
    """``plot.SimLevPBO`` (SVG): Histogramm der Logits und Leistungsabfall In-/Out-of-Sample.

    Liefert ``(svg, data)``: ``logits`` (``lambda``, endliche Logits) und ``degradation``
    (``is_best``, ``oos_best``).
    """
    f = _res_fig(900, 400)
    lam = [float(v) for v in np.asarray(x["lambda"], dtype=np.float64).ravel() if math.isfinite(v)]
    lo, hi = (-1.0, 1.0) if not lam else (min(lam), max(lam))
    if lo == hi:
        lo -= 0.5
        hi += 0.5
    nb = 40
    bw = (hi - lo) / nb
    cnt = [0] * nb
    for v in lam:
        cnt[min(max(math.floor((v - lo) / bw), 0), nb - 1)] += 1
    p = _res_panel(f, 60, 40, 360, 300, (lo, hi), (0.0, max(1, max(cnt, default=0)) * 1.05),
                   title="Logits (PBO " + _sprintf("%.0f", 100 * x["pbo"]) + " %)", xlab="λ", ylab="Häufigkeit")
    for i in range(nb):
        if cnt[i] > 0:
            _res_rect(f, p, lo + i * bw, 0.0, lo + (i + 1) * bw, cnt[i], fill="#2C6E9B", stroke="white")
    _res_vline(f, p, 0.0)
    xb = np.asarray(x["is_best"], dtype=np.float64).ravel()
    yb = np.asarray(x["oos_best"], dtype=np.float64).ravel()
    q = _res_panel(f, 520, 40, 360, 300, _res_range(xb), _res_range(yb), title="Leistungsabfall",
                   xlab="%s In-Sample (bester Punkt)" % x["metric"], ylab="Out-of-Sample")
    _res_points(f, q, xb, yb, r=2, opacity=0.4)
    _res_abline(f, q, float(x["intercept"]), float(x["slope"]))
    _res_hline(f, q, 0.0)
    data = {"logits": _frame_data(**{"lambda": np.array(lam, dtype=np.float64)}),
            "degradation": _frame_data(is_best=xb, oos_best=yb)}
    return _res_finish(f), data


# ─────────────────────────────────────────────────────────────────────────────
# PSR / DSR
# ─────────────────────────────────────────────────────────────────────────────

def sharpe_probabilistic(r, *, benchmark=0, ppy=52):
    """Probabilistic Sharpe Ratio.

    Wahrscheinlichkeit, dass die wahre Sharpe Ratio über ``benchmark`` liegt, unter Berücksichtigung von
    Stichprobenlänge, Schiefe und Wölbung: PSR = Φ(frac(SR - SR^*)√(T-1) √(1 - γ_3 SR + (γ_4 - 1)/(4)SR^2)) Dabei
    sind SR (Mittelwert / Standardabweichung) und SR^* Sharpe Ratios je Periode, T die Anzahl Renditen, γ_3 die
    Schiefe und γ_4 die Wölbung (nicht Exzess). Eingabe ist ein Renditevektor; für ein Ergebnis von
    ``simulation()`` z. B. ``v <- result_index(res)$value; r <- v[-1] / v[-length(v)] - 1``.

    Args:
        r: Numerischer Vektor einfacher Periodenrenditen als Anteil (0.01 = 1 %); nicht endliche Werte werden
            entfernt. Ein risikoloser Zins wird nicht abgezogen.
        benchmark: Vergleichs-Sharpe-Ratio SR^* p. a. (Standard 0); intern durch √(ppy) geteilt.
        ppy: Perioden je Jahr der Renditen in ``r`` (Standard 52 = Wochenrenditen; z. B. 252 für Handelstage, 12
            für Monate). Wird nicht geschätzt und dient nur der Umrechnung von ``benchmark``.

    Returns:
        Eine Zahl: Wahrscheinlichkeit als Anteil (0 bis 1).

    Literatur:
        Bailey, D. H. & Lopez de Prado, M. (2012). The Sharpe ratio efficient frontier. Journal of Risk 15(2),
        3-44.

    Beispiel::

        import numpy as np, simlev
        r = np.random.default_rng(1).normal(0.002, 0.02, 520)   # 10 Jahre Wochenrenditen
        print(simlev.sharpe_probabilistic(r, benchmark=0, ppy=52))
    """
    r = np.asarray(r, dtype=np.float64).ravel()
    r = r[np.isfinite(r)]
    n = r.size
    mu = r_mean(r)
    sd = r_sd(r)
    sr = mu / sd
    sr0 = benchmark / math.sqrt(ppy)
    z = (r - r_mean(r)) / r_sd(r)
    g3 = r_mean(np.array([r_pow(v, 3.0) for v in z]))
    g4 = r_mean(np.array([r_pow(v, 4.0) for v in z]))
    den = 1 - g3 * sr + (g4 - 1) / 4 * (sr * sr)
    den = den if (math.isnan(den) or den >= 1e-12) else 1e-12
    q = (sr - sr0) * math.sqrt(n - 1) / math.sqrt(den)
    return float(_lib.pnorm(q))


class SimLevDSR(RList):
    """Ergebnis von :func:`sharpe_deflated` (R-Klasse ``SimLevDSR``)."""

    r_class = ("SimLevDSR",)

    def format(self):
        x = self
        out = ["Deflated Sharpe Ratio\n"]
        out.append(_sprintf("  Punkt #%d, %d Beobachtungen (%s)\n", x["id"], x["n_obs"], x["frequency"]))
        out.append(_sprintf("  Sharpe Ratio (p. a.):                 %.3f\n", x["sharpe"]))
        out.append(_sprintf("  Versuche: %d nominal, %.1f effektiv (mittlere Korrelation %.2f), verwendet %.1f\n",
                            x["n_points"], x["n_eff"], x["rho"], float(x["n_trials"])))
        out.append(_sprintf("  Erwartetes Maximum ohne Können (p. a.):  %.3f\n", x["sr0"]))
        out.append(_sprintf("  PSR (SR > 0):                         %.1f %%\n", 100 * x["psr"]))
        out.append(_sprintf("  DSR (SR > erwartetes Maximum):        %.1f %%\n", 100 * x["dsr"]))
        out.append("  Lesart: DSR über 95 % = Ergebnis hält der Mehrfachtest-Korrektur stand.\n")
        return "".join(out)[:-1]

    def print(self):
        print(self.format())
        return self


def sharpe_deflated(x, *, id=None, n_trials=None, effective=True,  # noqa: A002 - R-Argumentname
                    frequency=("week", "day", "month"), dates=None, risk_free=0):
    """Deflated Sharpe Ratio.

    Korrigiert die Sharpe Ratio des besten Punkts einer Suche um die Zahl der Versuche: Die Nullhypothese ist
    nicht SR = 0, sondern die Sharpe Ratio, die man als Maximum aus N wertlosen Versuchen erwarten würde, SR_0 =
    √(V[SR_n])((1-γ)Φ^-1(1 - 1/N) + γ Φ^-1(1 - 1/(N e))) (γ Euler-Mascheroni). Weil die Punkte einer Suche stark
    korreliert sind, wird standardmäßig eine effektive Versuchsanzahl N_eff = barρ + (1 - barρ) N aus der
    mittleren paarweisen Korrelation verwendet (mindestens 1; bei negativer mittlerer Korrelation N). V[SR_n] ist
    die Varianz der Sharpe Ratios je Periode über alle Punkte. PSR und DSR werden mit ``sharpe_probabilistic()``
    berechnet. Spalten ohne Schwankung (Standardabweichung <= 1e-10 je Periode, z. B. ein Punkt, der nur Geldmarkt
    mit festem Zins hält) haben keine definierte Sharpe Ratio und werden mit Warnung ausgeschlossen.

    Args:
        x: Renditequelle wie bei ``overfit_pbo()``: ``SimLevParamSearch`` aus ``param_search()`` mit gespeicherten
            Renditen oder numerische Renditematrix bzw. DataFrame nur aus numerischen Spalten (Zeilen = Perioden,
            Spalten = Punkte, einfache Renditen als Anteil). Bei ``print()``: Objekt der Klasse ``SimLevDSR``.
        id: Zu prüfender Punkt: bei ``SimLevParamSearch`` die ``id`` aus ``x["results"]``, bei einer Matrix die
            Spaltennummer der ursprünglichen Matrix. ``None`` (Standard) = Punkt mit der höchsten Sharpe Ratio.
        n_trials: Versuchsanzahl N (positive Zahl, überschreibt die Schätzung), z. B. wenn vorher schon andere
            Suchen gelaufen sind. ``None`` (Standard) = aus ``x`` geschätzt (siehe ``effective``).
        effective: Logisch. ``True`` (Standard) = effektive Versuchsanzahl N_eff; ``False`` = Anzahl gültiger
            Spalten.
        frequency: Periodenlänge der Auswertung: ``"week"`` (Standard), ``"day"`` oder ``"month"``. Mit Datum (bei
            ``SimLevParamSearch`` immer, bei Matrizen über ``dates``) werden die Tagesrenditen geometrisch zu
            ISO-Wochen bzw. Kalendermonaten verkettet. Ohne Datum wird nicht aggregiert; die Zeilen gelten dann
            als Perioden dieser Frequenz (wichtig für ``ppy``). Achtung: Eine Matrix von Tagesrenditen ohne
            ``dates`` braucht ``frequency = "day"``; mit dem Standard ``"week"`` wird mit 52 statt 252 Perioden je
            Jahr annualisiert (betrifft annualisierte Sharpe Ratios und ``risk_free``).
        dates: Datum je Zeile von ``x`` (Date oder umwandelbar), nur bei Matrix-Eingabe; ``None`` (Standard) =
            keine Aggregation. Bei ``SimLevParamSearch`` wird ``x["dates"]`` verwendet.
        risk_free: Risikoloser Zins in Prozent p. a. (2 = 2 %, Standard 0); wird als ``risk_free / 100 / ppy`` von
            jeder Periodenrendite abgezogen. ``ppy`` (Perioden je Jahr) wird aus dem Datum geschätzt: (Anzahl
            Perioden - 1) / (Zeitspanne in Tagen / 365.25); ohne Datum 252 (``"day"``), 52 (``"week"``) bzw. 12
            (``"month"``).

    Returns:
        Objekt der Klasse ``SimLevDSR``, eine Liste mit ``id`` (geprüfter Punkt), ``sharpe`` (seine Sharpe Ratio
        p. a.), ``sr0`` (erwartetes Maximum ohne Können, p. a.), ``psr`` (Wahrscheinlichkeit SR > 0, Anteil),
        ``dsr`` (Wahrscheinlichkeit SR > ``sr0``, Anteil), ``n_trials`` (verwendete Versuchsanzahl), ``n_points``
        (Anzahl Spalten), ``n_eff``, ``rho`` (mittlere paarweise Korrelation), ``var_sr`` (Varianz der Sharpe
        Ratios, annualisiert: Varianz je Periode mal ``ppy``), ``n_obs`` (Anzahl Perioden) und ``frequency``.
        Annualisiert wird mit √(ppy); ``ppy`` wird wie unter ``risk_free`` beschrieben bestimmt.

    Literatur:
        Bailey, D. H. & Lopez de Prado, M. (2014). The deflated Sharpe ratio. Journal of Portfolio Management
        40(5), 94-107.

    Beispiel::

        import numpy as np, simlev
        rng = np.random.default_rng(1)
        R = rng.normal(2e-4, 0.01, (2000, 20))     # 20 Zufallsstrategien
        print(simlev.sharpe_deflated(R, frequency="day"))
    """
    frequency = _match_arg(frequency, ("week", "day", "month"), "frequency")
    rr = _of_drop_flat(_rr(x, frequency, dates, risk_free), "sharpe_deflated")
    R = rr.R
    N = R.shape[1]
    sr = _of_col_metric(R, "sharpe")
    if id is None:
        j = _which_max(sr)
    else:
        hits = np.nonzero(rr.cols == float(id))[0]
        if not hits.size:
            raise ValueError("id nicht unter den gültigen Punkten (Spalten ohne endliche Werte oder ohne Schwankung zählen nicht).")
        j = int(hits[0])
    if N > 1:
        Cm = _cor(R)
        iu = [Cm[i, jj] for jj in range(N) for i in range(jj)]
        rho = r_mean(np.array(iu, dtype=np.float64), na_rm=True)
    else:
        rho = 1.0
    n_eff = max(1.0, rho + (1 - max(rho, 0.0)) * N)
    if math.isnan(rho):
        raise ValueError("missing value where TRUE/FALSE needed")  # R: if (rho < 0) mit NaN
    if rho < 0:
        n_eff = N
    Nt = n_trials if n_trials is not None else (n_eff if effective else N)
    v = r_var(sr) if N > 1 else 0.0
    g = 0.5772156649
    if Nt > 1 and v > 0:
        sr0 = math.sqrt(v) * ((1 - g) * _lib.qnorm(1 - 1 / Nt) + g * _lib.qnorm(1 - 1 / (Nt * _libm.exp(1.0))))
    else:
        sr0 = 0.0
    r = R[:, j]
    sq = math.sqrt(rr.ppy)
    return SimLevDSR(id=int(rr.cols[j]), sharpe=float(sr[j]) * sq, sr0=sr0 * sq,
                     psr=sharpe_probabilistic(r, benchmark=0, ppy=rr.ppy), dsr=sharpe_probabilistic(r, benchmark=sr0 * sq, ppy=rr.ppy),
                     n_trials=Nt, n_points=N, n_eff=n_eff, rho=rho, var_sr=v * rr.ppy, n_obs=R.shape[0],
                     frequency=frequency)


# ─────────────────────────────────────────────────────────────────────────────
# Walk-Forward
# ─────────────────────────────────────────────────────────────────────────────

class SimLevWalkForward(RList):
    """Ergebnis von :func:`overfit_walk_forward` (R-Klasse ``SimLevWalkForward``)."""

    r_class = ("SimLevWalkForward",)

    def format(self):
        x = self
        out = [_sprintf("Walk-Forward (%s, Training %g J., Test %g J., Auswahl %s nach %s)\n",
                        "verankert" if x["anchored"] else "rollierend", x["train"], x["test"], x["select"], x["metric"])]
        W = x["windows"]
        ts = np.asarray(W["test_start"]).astype("datetime64[D]")
        te = np.asarray(W["test_end"]).astype("datetime64[D]")
        test = ["%s bis %s" % (a, b) for a, b in zip(_fmt.format_date(ts, "%Y-%m"), _fmt.format_date(te, "%Y-%m"))]
        cols = {"Test": np.array(test, dtype=object), "Punkt": np.asarray(W["id"])}
        for p in x["params"]:
            cols[p] = W[p].to_numpy()
        cols["IS"] = _fmt_vec("%.3f", W["is_metric"])
        cols["OOS"] = _fmt_vec("%.3f", W["oos_metric"])
        cols["OOS-Rang"] = _fmt_vec("%.0f %%", 100 * W["oos_rank"].to_numpy(dtype=float))
        cols["Rendite"] = _fmt_vec("%.1f %%", 100 * W["oos_return"].to_numpy(dtype=float))
        cols["Mittel"] = _fmt_vec("%.1f %%", 100 * W["oos_average"].to_numpy(dtype=float))
        y = pd.DataFrame(cols)
        out.append(_fmt.print_data_frame(y, row_names=False) + "\n")
        s = x["summary"]
        out.append(_sprintf("\nCAGR Walk-Forward %.2f %%, Rückschau-Bester (#%d) %.2f %%, Durchschnitt aller Punkte %.2f %%\n",
                            100 * s["cagr_walk_forward"], x["hindsight_id"], 100 * s["cagr_hindsight"], 100 * s["cagr_average"]))
        out.append(_sprintf("Mittlerer OOS-Rang %.0f %% (50 %% = Zufall), Effizienz OOS/IS %.2f, %d Wechsel\n",
                            100 * s["mean_oos_rank"], s["efficiency"], s["switches"]))
        return "".join(out)[:-1]

    def print(self):
        print(self.format())
        return self

    # ``plot`` (SVG, ``SimLevPlot``) wird am Modulende über ``_plot_method`` gesetzt.


def _plot_wf(x):
    """``plot.SimLevWalkForward`` (SVG): Wachstum Walk-Forward, Rückschau-Bester und Durchschnitt (log).

    Liefert ``(svg, data)``: ``growth`` (``date``, ``walk_forward``, ``hindsight``, ``average``).
    """
    s = x["series"]
    dates = np.asarray(s["date"]).astype("datetime64[D]")
    dd = _days(dates)
    ys = [np.asarray(s[k], dtype=np.float64) for k in ("walk_forward", "hindsight", "average")]
    allv = [float(v) for y in ys for v in y if math.isfinite(v) and v > 0]
    lo, hi = (0.5, 2.0) if not allv else (min(allv), max(allv))
    if lo == hi:
        lo /= 1.1
        hi *= 1.1
    f = _res_fig(760, 420)
    yrs = _jl_unique((dates.astype("datetime64[Y]").astype(np.int64) + 1970).tolist())
    jan1 = [float(np.datetime64(y - 1970, "Y").astype("datetime64[D]").astype(np.int64)) for y in yrs]
    xt = [z for z in jan1 if dd[0] <= z <= dd[-1]]
    p = _res_panel(f, 70, 40, 660, 320, (dd[0], dd[0] + 1 if dd[-1] == dd[0] else dd[-1]), (lo, hi), logy=True,
                   title="Walk-Forward Out-of-Sample", ylab="Wachstum (log)", xticks=xt,
                   xticklabels=[str(int(np.datetime64(int(t), "D").astype("datetime64[Y]").astype(np.int64)) + 1970)
                            for t in xt])
    cols = ["#2C6E9B", "#B5562B", "#737373"]
    for v, c, w in zip(ys, cols, (2, 1.3, 1.3)):
        _res_line(f, p, dd, v, color=c, width=w)
    _res_legend(f, 85, 60, ["Walk-Forward", "Rückschau-Bester", "Durchschnitt"], cols)
    data = {"growth": _frame_data(date=dates, walk_forward=ys[0], hindsight=ys[1], average=ys[2])}
    return _res_finish(f), data


def _r_round(x):
    from ._r.fmt import r_round
    return float(r_round(x))


def overfit_walk_forward(x, *, train=5, test=1, step=None, anchored=False,
                 metric=("sharpe", "sortino", "geometric", "mean"),
                 select=("best", "plateau"), risk_free=0):
    """Walk-Forward-Auswahl.

    Wählt in rollierenden Trainingsfenstern den besten Punkt einer Parametersuche (oder das beste Plateau) und
    verkettet dessen Renditen im jeweils folgenden Testfenster. So entsteht eine Out-of-Sample-Reihe, die nur
    Informationen nutzt, die zum Entscheidungszeitpunkt vorlagen. Verglichen wird mit dem nachträglich besten
    Punkt (Rückschau) und mit dem Durchschnitt aller Punkte (zufällige Wahl).

    Args:
        x: ``SimLevParamSearch`` aus ``param_search()`` mit gespeicherten Renditen (``keep_returns = "day"``).
            Renditematrizen oder Listen von Ergebnissen werden nicht angenommen, weil Parameterwerte (und bei
            ``select = "plateau"`` der Suchraum) gebraucht werden. Bei ``print()``/``plot()``: Objekt der Klasse
            ``SimLevWalkForward``.
        train, test, step: Länge des Trainingsfensters, Länge des Testfensters und Vorschub der Fenster, jeweils
            in Jahren (Standard 5, 1 und ``step = test``); intern in ganze Monate umgerechnet (``round(12 *
            Jahre)``; Fenstergrenzen = Startdatum plus Monate, auf das Monatsende begrenzt, z. B. 31.01. + 1 Monat
            = 29.02.). Mit ``step < test`` überlappen die Testfenster; in ``series`` und ``summary`` zählt jeder
            Tag dann nur einmal, für das jüngste Fenster, dessen Test schon begonnen hat (die Kennzahlen in
            ``windows`` beziehen sich auf das ganze Testfenster). Mit ``step > test`` entstehen Lücken zwischen
            den Testfenstern; sie fehlen in ``series`` und zählen nicht als Zeit.
        anchored: Logisch. ``False`` (Standard) = rollierendes Trainingsfenster der Länge ``train``; ``True`` =
            Training beginnt immer am ersten Tag (expandierendes Fenster).
        metric: Auswahl- und Bewertungskennzahl, je Fenster aus den Tagesrenditen: ``"sharpe"`` (Standard),
            ``"sortino"``, ``"geometric"`` oder ``"mean"`` (Definitionen wie bei ``overfit_pbo()``, je Tag, nicht
            annualisiert; höher = besser).
        select: ``"best"`` (Standard): Punkt mit der höchsten Trainings-Kennzahl; ``"plateau"``: Punkt mit dem
            höchsten Mittel der Trainings-Kennzahl über seine Nachbarschaft (Nachbarn wie in ``param_plateau()``
            mit ``radius = 1`` bzw. ``k = 5``).
        risk_free: Risikoloser Zins in Prozent p. a. (2 = 2 %, Standard 0); wird als ``risk_free / 100 / ppy`` von
            jeder Tagesrendite abgezogen, ``ppy`` = (Anzahl Tage - 1) / (Zeitspanne in Tagen / 365.25). Wirkt auch
            auf ``series`` und die CAGR in ``summary`` (dann Ueberrenditen).

    Returns:
        Objekt der Klasse ``SimLevWalkForward``, eine Liste mit

        - ``windows``: DataFrame je Testfenster: ``train_start``, ``test_start``, ``test_end`` (Date), ``id``
          (gewählter Punkt), eine Spalte je Parameter, ``is_metric`` und ``oos_metric`` (Kennzahl im Trainings-
          bzw. Testfenster), ``oos_rank`` (Rang des gewählten Punkts im Testfenster als Anteil, (Rang - 0.5) /
          Anzahl Punkte; nahe 1 = bester, 0.5 = Zufall), ``oos_return`` (Rendite des gewählten Punkts im
          Testfenster, Anteil) und ``oos_average`` (mittlere Rendite aller Punkte im Testfenster, Anteil).
        - ``series``: DataFrame mit ``date`` und den Wachstumsindizes (Startwert 1 vor dem ersten Testtag)
          ``walk_forward`` (verkettete gewählte Punkte), ``hindsight`` (Punkt mit dem höchsten Endwert über alle
          Testtage) und ``average`` (täglich gleichgewichteter Durchschnitt aller Punkte).
        - ``summary``: benannter Vektor ``cagr_walk_forward``, ``cagr_hindsight``, ``cagr_average`` (CAGR über die
          Testtage, Anteil p. a.; annualisiert über die von den Testtagen überdeckte Zeit, d. h. die Summe der
          Abstände jedes Testtags zum vorherigen Datentag ohne den ersten Testtag - bei lückenlosen Testfenstern
          die Spanne vom ersten bis zum letzten Testtag), ``mean_oos_rank``, ``efficiency`` (mittlere OOS- durch
          mittlere IS-Kennzahl) und ``switches`` (Anzahl Wechsel des gewählten Punkts).
        - ``hindsight_id``, ``metric``, ``select``, ``train``, ``test``, ``anchored``, ``params``: Rückschau-Punkt
          und Einstellungen.

    Details:
        Gerechnet wird auf den täglichen Renditen der Suche (keine Aggregation). Das erste Trainingsfenster
        beginnt am ersten Tag der gespeicherten Renditen; die Fenster rücken um ``step`` vor, bis das Testfenster
        am oder nach dem letzten Tag beginnen würde oder ein Fenster zu kurz ist (weniger als 20 Trainings- oder 5
        Testtage). Das letzte Testfenster kann kürzer als ``test`` sein.

    Beispiel::

        import numpy as np, pandas as pd, simlev
        rng = np.random.default_rng(1)
        n = 3000
        d = pd.DataFrame({"date": pd.date_range("2010-01-01", periods=n)})
        d["A"] = 100 * np.cumprod(1 + rng.normal(3e-4, 0.011, n))
        st = simlev.create_strategy(A=simlev.asset_config(asset_class="etf", trading="signal", signal_buy="buy",
                                                         signal_sell="sell"))
        ps = simlev.param_search(d, lambda p: {"strategy": st, "signal": lambda df: simlev.signal_sma(df["A"], n=p["n"], band=p["band"])},
                                 simlev.param_space(n=[50, 100, 200], band=[0, 2]), burn_in=250)
        wf = simlev.overfit_walk_forward(ps, train=3, test=1)
        print(wf["summary"])
    """
    if step is None:
        step = test
    metric = _match_arg(metric, ("sharpe", "sortino", "geometric", "mean"), "metric")
    select = _match_arg(select, ("best", "plateau"), "select")
    if not _is_param_search(x) or x.get("returns") is None:
        raise ValueError("x muss ein SimLevParamSearch mit Renditen sein.")
    rr = _rr(x, "day", risk_free=risk_free)
    R = rr.R
    d = rr.dates
    dn = _days(d)
    if select == "plateau":
        from .param_search import _ps_neighbours
        nb = _ps_neighbours(x)
    add_months = _ext("data_prep", "_add_months")

    def add_m(date, months):
        out = _as_dates(add_months(np.array([date], dtype="datetime64[D]"), _r_round(months)))
        return out[0]
    t0 = d[0]
    last = d[-1]
    win = []
    k = 0
    n_res = len(x["results"])
    while True:
        ts = add_m(t0, 12 * (train + k * step))
        if ts >= last:
            break
        tr = t0 if anchored else add_m(t0, 12 * k * step)
        te = add_m(t0, 12 * (train + k * step + test))
        is_rows = np.nonzero((d >= tr) & (d < ts))[0]
        oos_rows = np.nonzero((d >= ts) & (d < te))[0]
        if is_rows.size < 20 or oos_rows.size < 5:
            break
        m_is = _of_col_metric(R[is_rows], metric)
        score = m_is
        if select == "plateau":
            full = np.full(n_res, _NA)
            full[rr.cols - 1] = m_is
            score = np.array([r_mean(full[np.asarray(nb[int(cid) - 1]) - 1], na_rm=True) for cid in rr.cols])
        j = _which_max(score)
        m_oos = _of_col_metric(R[oos_rows], metric)
        Ro = R[oos_rows]
        win.append({"train_start": d[is_rows[0]], "test_start": d[oos_rows[0]], "test_end": d[oos_rows[-1]],
                    "id": int(rr.cols[j]), "is_metric": float(m_is[j]), "oos_metric": float(m_oos[j]),
                    "oos_rank": (_rank_avg(m_oos)[j] - 0.5) / m_oos.size,
                    "oos_return": _geo_ret(Ro[:, j]),
                    "oos_average": r_mean(np.array([_geo_ret(Ro[:, c]) for c in range(Ro.shape[1])]))})
        k += 1
    if not win:
        raise ValueError("Historie zu kurz für ein Trainings- und Testfenster.")
    params = list(x["params"])
    res = x["results"]
    ids = np.array([w["id"] for w in win], dtype=np.int64)
    Wd = {"train_start": np.array([w["train_start"] for w in win], dtype="datetime64[D]"),
          "test_start": np.array([w["test_start"] for w in win], dtype="datetime64[D]"),
          "test_end": np.array([w["test_end"] for w in win], dtype="datetime64[D]"),
          "id": ids}
    for p in params:
        Wd[p] = res[p].to_numpy()[ids - 1]
    for nm in ("is_metric", "oos_metric", "oos_rank", "oos_return", "oos_average"):
        Wd[nm] = np.array([w[nm] for w in win], dtype=np.float64)
    W = pd.DataFrame(Wd)
    nW = len(W)
    seg = []
    for i in range(nW):
        r = np.nonzero((d >= Wd["test_start"][i]) & (d <= Wd["test_end"][i]))[0]
        if i < nW - 1:
            r = r[d[r] < Wd["test_start"][i + 1]]
        seg.append(r)
    rows = np.concatenate(seg).astype(np.int64)
    colpos = {int(c): i for i, c in enumerate(rr.cols)}
    chosen = np.repeat(np.array([colpos[int(i)] for i in ids], dtype=np.int64), [len(s) for s in seg])
    wf = R[rows, chosen]
    span = R[rows]
    hind = _which_max(np.array([r_prod(1 + span[:, c]) for c in range(span.shape[1])]))
    gaps = dn[rows[1:]] - dn[rows[1:] - 1]
    yrs = r_sum(gaps) / 365.25

    def ann(r):
        return _geo_ann(r, yrs)
    avg = _rowmeans(span)
    series = pd.DataFrame({"date": d[rows], "walk_forward": r_cumprod(1 + wf), "hindsight": r_cumprod(1 + span[:, hind]),
                           "average": r_cumprod(1 + avg)})
    smry = pd.Series({"cagr_walk_forward": ann(wf), "cagr_hindsight": ann(span[:, hind]), "cagr_average": ann(avg),
                      "mean_oos_rank": r_mean(Wd["oos_rank"]),
                      "efficiency": r_mean(Wd["oos_metric"]) / r_mean(Wd["is_metric"]),
                      "switches": float(np.sum(ids[1:] != ids[:-1]))}, dtype=np.float64)
    return SimLevWalkForward(windows=W, series=series, summary=smry, hindsight_id=int(rr.cols[hind]), metric=metric,
                             select=select, train=train, test=test, anchored=anchored, params=params)


# ─────────────────────────────────────────────────────────────────────────────
# Bootstrap der besten Punkte
# ─────────────────────────────────────────────────────────────────────────────

def param_bootstrap(x, data, config, *, ids=None, top=5, by=("objective", "plateau"), map=None,  # noqa: A002
                    include=None, **kwargs):
    """Beste Punkte einer Parametersuche auf Bootstrap-Pfaden prüfen.

    Baut für die ``top`` besten Punkte (nach Zielgröße oder Plateau) die Strategie-Spezifikationen mit dem
    ``builder`` der Suche und wertet sie gemeinsam mit ``bootstrap_study()`` auf denselben Pfaden aus. Der
    ``builder`` muss mit den Spaltennamen der Pfade arbeiten (Indizes, Hebelprodukte, Zusatzreihen aus
    ``config``); abweichende Namen lassen sich über ``map`` in der Spezifikation abbilden.

    Args:
        x: ``SimLevParamSearch`` aus ``param_search()`` (verwendet werden ``results``, ``builder``, ``sim_args``
            und ``burn_in``; gespeicherte Renditen sind nicht nötig).
        data: Historie für die Pfaderzeugung: DataFrame oder Matrix mit den Spalten aus ``config``, Format wie bei
            ``bootstrap()``.
        config: Konfiguration aus ``bootstrap_config()``.
        ids: Ganzzahliger Vektor von ``id``-Werten aus ``x["results"]``; ``None`` (Standard) = die ``top`` besten
            Punkte nach ``by``.
        top: Anzahl bester Punkte (ganze Zahl, Standard 5); nur ohne ``ids``.
        by: Rangfolge für ``top``: ``"objective"`` (Standard, Zielgröße der Suche) oder ``"plateau"``
            (``plateau_mean`` aus ``param_plateau()``); Richtung nach ``x["maximize"]``, Punkte mit ``NA``
            entfallen.
        map: Benannter Zeichenvektor von Spalten-Aliasen, die jeder Spezifikation hinzugefügt werden, z. B.
            ``{"letf": "eu_l2"}``, wenn die Strategie in der Suche auf die Spalte ``letf`` zugreift und im Pfad
            das Hebelprodukt ``eu_l2`` heißt. ``None`` (Standard) = keine.
        include: Weitere Strategien als benannte Liste im Format von ``strategies`` in ``bootstrap_study()``, z.
            B. ein Buy-and-Hold (Standard: keine).
        **kwargs: Weitere Argumente für ``bootstrap_study()``, z. B. ``method``, ``n`` (Anzahl Pfade), ``params``,
            ``seed``, ``cores``, ``progress``, ``sim_args``, ``burn_in``.

    Returns:
        Objekt der Klasse ``SimLevBootstrapStudy`` (siehe ``bootstrap_study()``); die Strategien heißen ``p<id>``
        (plus die Namen aus ``include``). Attribut ``param_ids``: benannter Vektor Strategiename -> ``id``.

    Details:
        Die Signalfunktion der Spezifikation wird je Pfad neu berechnet; ein ``data``-Element der Spezifikation
        (Funktion ``df -> df``, siehe ``param_search()``) wertet ``bootstrap_study()`` nicht aus. ``sim_args`` und
        ``burn_in`` werden aus der Suche übernommen, lassen sich aber über ``...`` überschreiben.

    Beispiel::

        import numpy as np, pandas as pd, simlev
        rng = np.random.default_rng(2); n = 1500
        h = pd.DataFrame({"us": 1 + rng.normal(3e-4, 0.01, n)})
        d = pd.DataFrame({"date": pd.date_range("2010-01-01", periods=n + 1), "us": 100 * np.cumprod(np.r_[1, h["us"]])})
        st = simlev.create_strategy(us=simlev.asset_config(asset_class="etf", trading="signal", signal_buy="buy", signal_sell="sell"))
        ps = simlev.param_search(d, lambda p: {"strategy": st, "signal": lambda df: simlev.signal_sma(df["us"], n=p["n"])},
                                 simlev.param_space(n=[20, 50, 100]), burn_in=100)
        bs = simlev.param_bootstrap(ps, h, simlev.bootstrap_config({"us": "us"}), top=2, method="stationary", n=3,
                                    params={"L": 50}, seed=1, progress=False)
        print(bs["results"][["strategy", "path", "cagr"]])
    """
    from .param_search import _as_spec, param_plateau, _modify_list, _order, _row_params
    by = _match_arg(by, ("objective", "plateau"), "by")
    if not _is_param_search(x):
        raise ValueError("x muss ein SimLevParamSearch sein.")
    include = {} if include is None else include
    res = x["results"]
    if ids is None:
        v = param_plateau(x)["plateau_mean"].to_numpy(dtype=float) if by == "plateau" else res[x["objective"]].to_numpy(dtype=float)
        o = _order(v, decreasing=x.get("maximize") is True, na_last=None)
        ids = res["id"].to_numpy()[o[:int(top)]]
    ids = [int(i) for i in np.atleast_1d(ids)]
    specs = {}
    for i in ids:
        sp = dict(_as_spec(x["builder"](_row_params(res, i - 1, x["params"]))))
        if map is not None:
            sp["map"] = {**dict(sp.get("map") or {}), **dict(map)}
        specs["p%d" % i] = sp
    # sim_args aus kwargs ergänzen die der Suche (oberste Ebene; Bausteine werden ersetzt, nicht gemischt)
    dots = dict(kwargs)
    sa = dict(x.get("sim_args") or {})
    if "sim_args" in dots:
        from ._sim_blocks import _sim_args_set
        sa = _sim_args_set(sa, dots.pop("sim_args"), "param_bootstrap")
    args = _modify_list({"data": data, "config": config, "strategies": {**specs, **dict(include)},
                         "burn_in": x["burn_in"]}, dots)
    args["sim_args"] = sa
    st = _ext("bootstrap", "bootstrap_study")(**args)
    pid = pd.Series(ids, index=list(specs.keys()), dtype=np.int64)
    # R-Attribut param_ids: bei Listenobjekten als Python-Attribut ``attrs`` (kein Listenelement)
    attrs = getattr(st, "attrs", None)
    if not isinstance(attrs, dict):
        attrs = {}
        object.__setattr__(st, "attrs", attrs)
    attrs["param_ids"] = pid
    return st


# ─────────────────────────────────────────────────────────────────────────────
# Haircut
# ─────────────────────────────────────────────────────────────────────────────

def _sign(v):
    return np.where(v > 0, 1.0, np.where(v < 0, -1.0, np.where(np.isnan(v), v, 0.0)))


def sharpe_haircut(x, *, n_obs=None, n_tests=None, frequency=("week", "day", "month"), dates=None,
                   risk_free=0, ppy=52):
    """Sharpe-Ratio-Abschlag für Mehrfachtests (Harvey & Liu 2015).

    Wandelt die Sharpe Ratio jedes Punkts einer Suche (oder gegebene Sharpe Ratios) in einen t-Wert und p-Wert,
    korrigiert die p-Werte für die Zahl der Versuche (Bonferroni, Holm, Benjamini-Hochberg-Yekutieli) und rechnet
    sie in eine "abgeschlagene" Sharpe Ratio zurück: SR^adj = Φ^-1(1 - p^adj/2) / √(T). Der Abschlag 1 - SR^adj/SR
    zeigt, wie viel der gemessenen Sharpe Ratio die Suche selbst erklärt.

    Args:
        x: Eingabe: ``SimLevParamSearch`` aus ``param_search()`` mit gespeicherten Renditen, numerische
            Renditematrix bzw. DataFrame nur aus numerischen Spalten (Zeilen = Perioden, Spalten = Punkte,
            einfache Renditen als Anteil; wie bei ``overfit_pbo()``) oder numerischer Vektor annualisierter Sharpe
            Ratios (dann ``n_obs`` und ``ppy`` angeben).
        n_obs: Anzahl Perioden T, auf denen die Sharpe Ratios beruhen (Perioden der Länge, die ``ppy``
            beschreibt); nur und zwingend bei Vektor-Eingabe. Sonst die Zeilenzahl nach Aggregation.
        n_tests: Gesamtzahl der Versuche M (ganze Zahl). ``None`` (Standard) = Anzahl Sharpe Ratios bzw. Punkte;
            bei früheren Suchen entsprechend höher ansetzen (fehlende Versuche gehen mit p = 1 in die Korrektur
            ein).
        frequency, dates, risk_free: Aggregation, Datum und risikoloser Zins (Prozent p. a.) wie bei
            ``overfit_pbo()``; nur bei Suche oder Matrix.
        ppy: Perioden je Jahr, nur bei Vektor-Eingabe (Standard 52 = Wochen). Bei Suche oder Matrix wird es wie
            bei ``overfit_pbo()`` bestimmt (aus dem Datum geschätzt, sonst 252/52/12 je ``frequency``).

    Returns:
        DataFrame je Punkt, absteigend nach ``sharpe`` sortiert, mit ``id`` (Punkt bzw. Spaltennummer; bei
        Vektoren die Position), ``sharpe`` (p. a.), ``t``, ``p`` und für jedes Verfahren ``bonferroni``, ``holm``
        und ``bhy`` (Benjamini-Hochberg-Yekutieli) die Spalten ``p_<verfahren>`` (angepasster p-Wert),
        ``sharpe_<verfahren>`` (abgeschlagene Sharpe Ratio p. a.) und ``haircut_<verfahren>`` (Abschlag als
        Anteil; ``NA`` bei ``sharpe = 0``). Attribute ``n_tests`` und ``n_obs``.

    Details:
        Der t-Wert ist SR √(T) mit der Sharpe Ratio je Periode und T Perioden, der p-Wert zweiseitig
        (Normalverteilung). Die abgeschlagene Sharpe Ratio je Periode wird mit √(ppy) annualisiert und erhält das
        Vorzeichen von SR. Bei Renditen werden Spalten ohne Schwankung (Standardabweichung <= 1e-10 je Periode)
        mit Warnung ausgeschlossen (Sharpe Ratio nicht definiert).

    Literatur:
        Harvey, C. R. & Liu, Y. (2015), Backtesting, Journal of Portfolio Management 42(1), 13-28.

    Beispiel::

        import simlev
        print(simlev.sharpe_haircut([1, 0.5], n_obs=520, n_tests=50, ppy=52))
    """
    frequency = _match_arg(frequency, ("week", "day", "month"), "frequency")
    names = None
    is_vec = False
    if isinstance(x, pd.Series) or (isinstance(x, (list, tuple)) and not any(isinstance(e, (list, tuple, np.ndarray)) for e in x)) \
            or (isinstance(x, np.ndarray) and x.ndim <= 1) or isinstance(x, (int, float)) and not isinstance(x, bool):
        a = x.to_numpy() if isinstance(x, pd.Series) else np.asarray(x)
        if a.dtype.kind in "iuf":
            is_vec = True
            if isinstance(x, pd.Series) and not isinstance(x.index, pd.RangeIndex):
                names = [str(i) for i in x.index]
    if is_vec:
        if n_obs is None:
            raise ValueError("n_obs angeben.")
        sr = np.atleast_1d(np.asarray(a, dtype=np.float64)) / math.sqrt(ppy)
        Tn = n_obs
        ids = np.arange(1, sr.size + 1, dtype=np.int64)
    else:
        rr = _of_drop_flat(_rr(x, frequency, dates, risk_free), "sharpe_haircut")
        sr = _of_col_metric(rr.R, "sharpe")
        names = rr.cn
        Tn = rr.R.shape[0]
        ppy = rr.ppy
        ids = rr.cols
    M = n_tests if n_tests is not None else sr.size
    tstat = sr * math.sqrt(Tn)
    p = 2 * np.asarray(_lib.pnorm(-np.abs(tstat)), dtype=np.float64)

    def padj(method):
        pp = np.concatenate([p, np.ones(int(max(0, M - p.size)))])
        return _p_adjust(pp, method, max(M, p.size))[:p.size]

    def back(pa):
        return _sign(sr) * np.asarray(_lib.qnorm(np.minimum(pa, 1) / 2, lower_tail=False), dtype=np.float64) / math.sqrt(Tn) * math.sqrt(ppy)   # oberes Ende
    out = pd.DataFrame({"id": ids, "sharpe": sr * math.sqrt(ppy), "t": tstat, "p": p})
    if names is not None:
        out.index = names
    for nm, m in (("bonferroni", "bonferroni"), ("holm", "holm"), ("bhy", "BY")):
        pa = padj(m)
        sa = back(pa)
        out["p_" + nm] = pa
        out["sharpe_" + nm] = sa
        sh = out["sharpe"].to_numpy()
        with np.errstate(divide="ignore", invalid="ignore"):
            out["haircut_" + nm] = np.where(np.isnan(sh) | (sh == 0), _NA, 1 - sa / sh)   # ifelse: NA-Test → NA
    o = _order(-out["sharpe"].to_numpy())
    res = out.iloc[o]
    if names is None:
        res.index = (np.asarray(o) + 1)
    res.attrs["n_tests"] = M
    res.attrs["n_obs"] = Tn
    return res


def _order(v, decreasing=False, na_last=True):
    from .param_search import _order as o
    return o(v, decreasing=decreasing, na_last=na_last)


# plot-Methoden (SVG, ``SimLevPlot``) wie Julias ``_plot_method(_plot_pbo, "SimLevPBO")``
from .svg import _plot_method  # noqa: E402

SimLevPBO.plot = _plot_method(_plot_pbo, "SimLevPBO")
SimLevWalkForward.plot = _plot_method(_plot_wf, "SimLevWalkForward")

# Rechnen mit NA (signalisierendes NaN) ohne numpy-Warnung "invalid value" wie in R (gemeinsamer Helfer)
from ._r.base import quiet_fp  # noqa: E402

quiet_fp(globals(), list(__all__) + ["_of_col_metric", "_of_metric", "_of_returns"])
