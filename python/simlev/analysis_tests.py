"""Signal-Analyse, statistische Tests und Heatmaps (Port von ``r/R/analysis_tests.R``).

- :func:`signal_analysis`  Vorwärtsrenditen je Signalbereich (Regressogramm),
  optional für zwei Signale und je Zeitabschnitt
- :func:`sharpe_test`      Unterschied zweier Sharpe Ratios (Ledoit & Wolf 2008:
  HAC-Delta-Methode oder Block-Bootstrap)
- :func:`overfit_reality_check`    White (2000) Reality Check und Hansen (2005) SPA
- :func:`sharpe_min_track_record` Mindestlänge einer Historie für eine Sharpe-Aussage
  (Bailey & López de Prado 2012)
- :func:`result_heatmap`   annualisierte (reale) Renditen je Startjahr und
  Haltedauer
"""
from __future__ import annotations

import math
import warnings

import numpy as np
import pandas as pd

from ._r import fmt as _fmt
from ._r.fmt import NA_REAL
from ._r import nmath as _nm
from ._r.rlist import RList
from ._r.rnum import LD, r_isna, r_mean, r_median, r_pow, r_sd
from .deep_analysis import (
    _col_means, _da_deflate, _da_series, _dates, _days, _ext, _fill_na, _is_num_scalar, _key_isoweek,
    _key_month, _key_year, _last_of_key, _match_arg, _mean_lgl, _message, _quantile, _sp, _stats,
    _to_date_days,
)
from .svg import (_AnaSvg, _ana_hline, _ana_legend, _ana_lines, _ana_panel, _ana_points, _ana_ramp, _ana_rect,
                  _ana_svg_done)

__all__ = ["signal_analysis", "sharpe_test", "overfit_reality_check", "sharpe_min_track_record", "result_heatmap",
           "SimLevSignalAnalysis", "SimLevRealityCheck", "SimLevHeatmap"]

_NAN = NA_REAL   # R-NA_real_


def _num_col(v):
    """``as.numeric`` einer Spalte; NA/NaN-Bitmuster numerischer Spalten bleiben erhalten (sonst NA)."""
    if getattr(v, "dtype", None) is not None and v.dtype.kind == "f":
        return v.to_numpy(dtype=np.float64, copy=True)
    return pd.to_numeric(v, errors="coerce").to_numpy(dtype=np.float64, na_value=NA_REAL)


def _is_num_vector(x):
    """``is.numeric(x) && is.null(dim(x))``: Zahl, 1-D-Array, Liste von Zahlen, Series."""
    if _is_num_scalar(x):
        return True
    if isinstance(x, pd.Series):
        return x.dtype.kind in "iuf"
    if isinstance(x, np.ndarray):
        return x.ndim == 1 and x.dtype.kind in "iuf"
    if isinstance(x, (list, tuple)):
        return all(_is_num_scalar(e) for e in x)
    return False


def _num_vec(x):
    if isinstance(x, pd.Series):
        return x.to_numpy(dtype=np.float64)
    return np.atleast_1d(np.asarray(x, dtype=np.float64)).ravel()


def _ret_from(x, frequency, inflation=None):
    """Periodenrenditen aus Ergebnis, data.frame oder Vektor (``.ret_from``).

    Liefert dict ``r`` (Renditen) und ``date`` (``datetime64[D]``-Enddaten oder ``None``).
    """
    if _is_num_vector(x):
        return {"r": _num_vec(x), "date": None}
    s = _da_series(x, "x")
    if inflation is not None:
        s = _da_deflate(s, inflation)
    if frequency == "day":
        keep = np.concatenate([[True], ~s["filled"][1:]])
        d = s["date"][keep]
        v = s["value"][keep]
    else:
        key = _key_isoweek(s["date"]) if frequency == "week" else _key_month(s["date"])
        e = _last_of_key(key)
        d = s["date"][e]
        v = s["value"][e]
    return {"r": v[1:] / v[:-1] - 1, "date": _dates(d[1:])}


# ═══════════════════════════════════════════════════════════════════════════
# signal_analysis
# ═══════════════════════════════════════════════════════════════════════════

def _as_int(x):
    """``as.integer(x)`` (Abschneiden; ``None``/NaN → ``None``)."""
    if x is None:
        return None
    a = np.atleast_1d(np.asarray(x, dtype=object)).ravel()
    out = []
    for e in a:
        try:
            f = float(e)
        except (TypeError, ValueError):
            out.append(None)
            continue
        out.append(None if math.isnan(f) else int(f))
    return out


def _cut_quantile_breaks(v, k, br):
    """Grenzen wie ``cutb()`` in ``signal_analysis``."""
    if br is None:
        u = np.unique(v)
        if len(u) <= k:
            br = np.concatenate([[-math.inf], u[1:], [math.inf]])
        else:
            q = _quantile(v, _stats("seq_len_out")(0.0, 1.0, int(math.ceil(k + 1))))
            br = np.array(list(dict.fromkeys(q.tolist())), dtype=np.float64)
    br = np.array(br, dtype=np.float64)
    br[0] = -math.inf
    br[-1] = math.inf
    return br


def _cut(v, br, include_lowest=True, right=False):
    """``cut(v, br, include.lowest, right)`` → (Codes 0-basiert, -1 = NA; Level-Namen)."""
    f = _stats("cut")
    res = f(np.asarray(v, dtype=np.float64), np.asarray(br, dtype=np.float64), include_lowest=include_lowest,
            right=right)
    cat = res if isinstance(res, pd.Categorical) else pd.Categorical(res)
    return np.asarray(cat.codes, dtype=np.int64), [str(c) for c in cat.categories]


def _cut_n(x, k):
    """``cut(x, k, labels = FALSE)`` (Anzahl gleich breiter Intervalle) → Codes 1..k."""
    f = _stats("cut")
    res = f(np.asarray(x, dtype=np.float64), int(k), labels=False)
    return np.asarray(res, dtype=np.float64)


def _st(z):
    n = len(z)
    m = r_mean(z)
    sd = r_sd(z)
    return {"n": float(n), "mean": m, "median": r_median(z), "win_rate": _mean_lgl(z > 0), "sd": sd,
            "t": m / (sd / math.sqrt(n))}


def _welch(x, y):
    """``stats::t.test(x, y)`` (Welch) → (statistic, p.value)."""
    tt = _stats("t_test")(np.asarray(x, dtype=np.float64), np.asarray(y, dtype=np.float64))
    stat, p = tt["statistic"], tt["p.value"]
    return float(np.asarray(stat, dtype=np.float64).ravel()[0]), float(np.asarray(p, dtype=np.float64).ravel()[0])


def _poly_lm(df, degree):
    """``lm(forward ~ stats::poly(signal, degree), data = df)``; liefert (Modell, R²)."""
    m = _stats("lm")("forward ~ stats::poly(signal, degree)", data=df[["signal", "forward"]], degree=int(degree))
    lab = "stats::poly(signal, degree)"
    co = m["coefficients"]
    if int(degree) == 1 and isinstance(co, pd.Series) and list(co.index) == ["(Intercept)", lab + "1"]:
        m["coefficients"] = pd.Series(co.to_numpy(), index=["(Intercept)", lab])   # R: Matrixterm mit einer Spalte ohne Suffix
    return m, float(_stats("summary_lm")(m)["r.squared"])


def _stats_mod():
    import importlib
    return importlib.import_module("simlev._r.stats")


def _sum_ld(x):
    x = np.asarray(x, dtype=np.float64)
    return float(np.cumsum(x.astype(LD))[-1]) if x.size else 0.0


def signal_analysis(data, signal, target, *, horizon=21, step=None, bins=5, breaks=None,
                    signal2=None, bins2=3, splits=1, degree=2):
    """Signal-Analyse: Vorwärtsrenditen je Signalbereich.

    Für jeden Stichtag (Zeile 1, dann alle ``step`` Zeilen) wird die Rendite der
    Zielreihe über die folgenden ``horizon`` Zeilen gemessen und nach dem
    Signalwert am Stichtag in Bereiche eingeteilt (Regressogramm).

    Args:
        data: DataFrame mit Spalte ``date`` und der Kursspalte ``target``.
        signal: Spaltenname in ``data`` oder numerischer Vektor der Länge ``nrow(data)``.
        target: Name der Kursspalte (Niveaus).
        horizon: Vorwärtshorizont in Zeilen (1 bis nrow - 1, Standard 21).
        step: Abstand der Stichtage in Zeilen; ``None`` = ``horizon``.
        bins: Anzahl Bereiche nach Quantilen des Signals (>= 2).
        breaks: streng aufsteigende Bereichsgrenzen (mindestens 3) oder ``None``.
        signal2, bins2: optional zweites Signal und seine Bereichszahl (2D-Tabelle).
        splits: Anzahl Zeitabschnitte für die Stabilitätsprüfung.
        degree: Grad der Polynom-Regression (0 = keine).

    Returns:
        :class:`SimLevSignalAnalysis`.
    """
    if not isinstance(data, pd.DataFrame) or "date" not in [str(c) for c in data.columns]:
        raise ValueError("signal_analysis: data muss ein data.frame mit Spalte 'date' sein.")
    n = len(data)
    d = _to_date_days(data["date"], "signal_analysis: data$date")
    names = [str(c) for c in data.columns]

    def getcol(v, what):
        if isinstance(v, str) or (isinstance(v, (list, tuple, np.ndarray)) and len(v) and isinstance(np.ravel(v)[0], str)):
            vl = [v] if isinstance(v, str) else [str(e) for e in np.ravel(v)]
            if len(vl) != 1 or vl[0] not in names:
                raise ValueError("signal_analysis: %s: Spalte '%s' fehlt in data (vorhanden: %s)." % (
                    what, vl[0], ", ".join(names)))
            col = data[vl[0]]
            return _num_col(col) \
                if col.dtype != bool else col.to_numpy(dtype=np.float64)
        a = _num_vec(v) if not isinstance(v, pd.Series) else v.to_numpy(dtype=np.float64)
        if len(a) != n:
            raise ValueError("signal_analysis: %s hat Länge %d, data hat %d Zeilen." % (what, len(a), n))
        return a.astype(np.float64)

    sig = getcol(signal, "signal")
    if not isinstance(target, str):
        raise ValueError("signal_analysis: target muss ein Spaltenname sein.")
    px = getcol(target, "target")
    s2all = getcol(signal2, "signal2") if signal2 is not None else None
    o = np.argsort(np.where(np.isnan(d), np.inf, d), kind="stable")
    o = o[~np.isnan(d[o])]
    dd = d[o]
    seen = set()
    dup = np.zeros(len(o), dtype=bool)
    for i in range(len(o) - 1, -1, -1):
        if dd[i] in seen:
            dup[i] = True
        seen.add(dd[i])
    if dup.any():
        _message("Hinweis: signal_analysis: %d doppelte Daten; der letzte Wert je Datum wird verwendet." % int(dup.sum()))
    o = o[~dup]
    d, sig, px = d[o], sig[o], px[o]
    if s2all is not None:
        s2all = s2all[o]
    n = len(o)
    px = _fill_na(px, "locf", keep_leading=True)
    hz = _as_int(horizon)
    stp = _as_int(step if step is not None else horizon)
    if len(hz) != 1 or hz[0] is None or hz[0] < 1 or hz[0] >= n:
        raise ValueError("signal_analysis: horizon muss zwischen 1 und %d (Zeilen - 1) liegen (ist: %s)." % (
            n - 1, ", ".join("NA" if h is None else str(h) for h in hz)))
    if len(stp) != 1 or stp[0] is None or stp[0] < 1:
        raise ValueError("signal_analysis: step muss eine ganze Zahl >= 1 sein.")
    horizon, step = hz[0], stp[0]
    if breaks is not None:
        ba = np.atleast_1d(np.asarray(breaks, dtype=object)).ravel()
        okb = (all(_is_num_scalar(e) for e in ba) and len(ba) >= 3)
        if okb:
            bf = ba.astype(np.float64)
            okb = not np.isnan(bf).any() and bool(np.all(np.diff(bf) > 0))
        if not okb:
            raise ValueError("signal_analysis: breaks braucht mindestens 3 streng aufsteigende Grenzen (erste und letzte "
                             "werden zu -Inf und Inf), z. B. c(-Inf, 0, Inf).")
        breaks = bf
    if breaks is None:
        bl = np.atleast_1d(np.asarray(bins, dtype=np.float64)).ravel()
        if len(bl) != 1 or math.isnan(bl[0]) or bl[0] < 2:
            raise ValueError("signal_analysis: bins muss eine ganze Zahl >= 2 sein.")
    t0 = np.arange(0, n - horizon, step, dtype=np.int64)
    fwd = px[t0 + horizon] / px[t0] - 1
    s2 = s2all[t0] if s2all is not None else None
    df = pd.DataFrame({"date": d[t0], "signal": sig[t0], "forward": fwd}, index=np.arange(1, len(t0) + 1))
    if s2 is not None:
        df["signal2"] = s2
    cc = ~np.isnan(df.to_numpy(dtype=np.float64)).any(axis=1)
    df = df[cc]
    if len(df) < 20:
        raise ValueError("signal_analysis: zu wenige Stichtage (%d, mindestens 20) mit Signal und Vorwärtsrendite." % len(df))
    sv = df["signal"].to_numpy(dtype=np.float64)
    if len(np.unique(sv)) < 2:
        raise ValueError("signal_analysis: Signal ist an allen Stichtagen gleich (%s); keine Bereiche möglich." % _sp("%g", sv[0]))
    ppy = (n - 1) / (float(d[-1] - d[0]) / 365.25)

    def ann(m):
        return r_pow(1 + m, ppy / horizon) - 1

    codes, lv = _cut(sv, _cut_quantile_breaks(sv, float(np.ravel(bins)[0]) if breaks is None else 0, breaks))
    fw = df["forward"].to_numpy(dtype=np.float64)
    rows = []
    for j, lab in enumerate(lv):
        sel = codes == j
        if not sel.any():
            continue
        z = fw[sel]
        st = _st(z)
        rows.append({"bin": lab, "from": float(np.min(sv[sel])), "to": float(np.max(sv[sel])), **st,
                     "annualized": ann(r_mean(z))})
    tab = pd.DataFrame(rows, columns=["bin", "from", "to", "n", "mean", "median", "win_rate", "sd", "t", "annualized"])
    lo = fw[codes == 0]
    hi = fw[codes == len(lv) - 1]
    if len(lo) > 2 and len(hi) > 2:
        tstat, pval = _welch(hi, lo)
    else:
        tstat = pval = _NAN
    spread = pd.Series({"difference": r_mean(hi) - r_mean(lo), "t": tstat, "p": pval}, dtype=np.float64)
    fit = None
    if degree > 0 and len(np.unique(sv)) > degree + 1:
        model, r2 = _poly_lm(df, int(degree))
        fit = {"model": model, "r_squared": float(r2)}
    spl = None
    if splits > 1:
        seg = _cut_n(np.arange(1, len(df) + 1, dtype=np.float64), splits)
        M = np.full((len(lv), int(splits)), _NAN)
        dts = df["date"].to_numpy(dtype=np.float64)
        cn = []
        for k in range(1, int(splits) + 1):
            for j in range(len(lv)):
                z = fw[(seg == k) & (codes == j)]
                M[j, k - 1] = r_mean(z) if len(z) else _NAN
            dk = dts[seg == k]
            cn.append("-".join(_key_year(np.array([np.min(dk), np.max(dk)]))))
        spl = pd.DataFrame(M, index=lv, columns=cn)
    t2 = None
    bin2 = None
    if s2 is not None:
        s2v = df["signal2"].to_numpy(dtype=np.float64)
        codes2, lv2 = _cut(s2v, _cut_quantile_breaks(s2v, float(bins2), None))
        Mm = np.full((len(lv), len(lv2)), _NAN)
        Mn = np.zeros((len(lv), len(lv2)), dtype=np.int64)
        for i in range(len(lv)):
            for j in range(len(lv2)):
                z = fw[(codes == i) & (codes2 == j)]
                Mn[i, j] = len(z)
                if len(z):
                    Mm[i, j] = r_mean(z)
        t2 = {"mean": pd.DataFrame(Mm, index=lv, columns=lv2), "n": pd.DataFrame(Mn, index=lv, columns=lv2)}
        bin2 = pd.Categorical.from_codes(codes2, categories=lv2)
    out = pd.DataFrame({"date": _dates(df["date"].to_numpy(dtype=np.float64)), "signal": sv, "forward": fw})
    if s2 is not None:
        out["signal2"] = df["signal2"].to_numpy(dtype=np.float64)
    out["bin"] = pd.Categorical.from_codes(codes, categories=lv)
    if bin2 is not None:
        out["bin2"] = bin2
    overall = pd.Series(_st(fw), dtype=np.float64)
    return SimLevSignalAnalysis([
        ("bins", tab), ("overall", overall), ("spread", spread), ("splits", spl), ("table2d", t2), ("fit", fit),
        ("data", out), ("horizon", horizon), ("step", step), ("target", target),
        ("signal_name", signal if isinstance(signal, str) else "signal")])


def _pct(f, v):
    return [_sp(f, 100 * float(e)) for e in v]


class SimLevSignalAnalysis(RList):
    """Ergebnis von :func:`signal_analysis` (R-Klasse ``SimLevSignalAnalysis``)."""

    r_class = ("SimLevSignalAnalysis",)

    def format(self):
        out = []
        out.append(_sp("Signal-Analyse: %s -> Rendite von '%s' über %d Zeilen (%d Stichtage, Abstand %d)\n\n",
                       self["signal_name"], self["target"], int(self["horizon"]), len(self["data"]), int(self["step"])))
        b = self["bins"]
        tab = pd.DataFrame({
            "Bereich": np.array(b["bin"].tolist(), dtype=object), "n": b["n"].to_numpy(dtype=np.float64),
            "Mittel": np.array(_pct("%.2f %%", b["mean"]), dtype=object),
            "Median": np.array(_pct("%.2f %%", b["median"]), dtype=object),
            "Treffer": np.array(_pct("%.0f %%", b["win_rate"]), dtype=object),
            "t": np.array([_sp("%.2f", float(v)) for v in b["t"]], dtype=object),
            "p. a.": np.array(_pct("%.1f %%", b["annualized"]), dtype=object)})
        out.append(_fmt.print_data_frame(tab, row_names=False) + "\n")
        o = self["overall"]
        out.append(_sp("\nAlle Stichtage: Mittel %.2f %%, Trefferquote %.0f %%\n", 100 * o["mean"], 100 * o["win_rate"]))
        sp = self["spread"]
        out.append(_sp("Oberster minus unterster Bereich: %+.2f %% (Welch-t %.2f, p = %.3f)\n",
                       100 * sp["difference"], sp["t"], sp["p"]))
        if self.get("fit") is not None:
            out.append(_sp("Polynom-Glättung: R^2 = %.3f\n", self["fit"]["r_squared"]))
        if self.get("splits") is not None:
            out.append("\nMittelwerte je Zeitabschnitt (Stabilität)\n")
            out.append(_fmt.print_matrix(_fmt.r_round(100 * self["splits"], 2)) + "\n")
        if self.get("table2d") is not None:
            out.append("\nMittelwerte je Bereich beider Signale\n")
            out.append(_fmt.print_matrix(_fmt.r_round(100 * self["table2d"]["mean"], 2)) + "\n")
        txt = "".join(out)
        return txt[:-1] if txt.endswith("\n") else txt


# ═══════════════════════════════════════════════════════════════════════════
# sharpe_test
# ═══════════════════════════════════════════════════════════════════════════

def _crossprod(A, B=None):
    lin = __import__("simlev._r.linalg", fromlist=["crossprod"])
    r = lin.crossprod(A) if B is None else lin.crossprod(A, B)
    return np.asarray(r.to_numpy() if isinstance(r, pd.DataFrame) else r, dtype=np.float64)


def _matprod(A, B):
    lin = __import__("simlev._r.linalg", fromlist=["matprod"])
    r = lin.matprod(A, B)
    return np.asarray(r.to_numpy() if isinstance(r, pd.DataFrame) else r, dtype=np.float64)


def _hac_cov(Y, lag=None):
    """Newey-West-Kovarianz mit Bartlett-Kern (``.hac_cov``)."""
    Y = np.asarray(Y, dtype=np.float64)
    Tn = Y.shape[0]
    if lag is None:
        lag = math.floor(4 * r_pow(Tn / 100, 2 / 9))
    Yc = Y - _col_means(Y)[None, :]
    S = _crossprod(Yc) / Tn
    for l in range(1, int(lag) + 1):
        G = _crossprod(Yc[l:Tn, :], Yc[0:Tn - l, :]) / Tn
        S = S + (1 - l / (lag + 1)) * (G + G.T)
    return S


def _with_rng(fn, seed):
    return _ext("bootstrap", "_with_rng_restore")(fn, seed=seed)


def _boot_idx(n, m, L):
    from ._bootstrap_core import boot_idx_stationary
    return boot_idx_stationary(n, m, L) - 1


def _ppy_default(frequency):
    return {"day": 252.0, "week": 52.0, "month": 12.0}[frequency]


def _sr(r):
    return r_mean(r) / r_sd(r)


def sharpe_test(x, y, *, frequency=("week", "day", "month"), method=("hac", "bootstrap"), B=2000, block=None,
                ppy=None, seed=None):
    """Test auf gleiche Sharpe Ratios (Ledoit & Wolf 2008).

    Args:
        x, y: zwei Renditequellen derselben Art: numerische Vektoren einfacher
            Periodenrenditen oder ``SimLevResult``/``DataFrame(date, Wert)``.
        frequency: ``"week"`` (Standard), ``"day"`` oder ``"month"``.
        method: ``"hac"`` (Delta-Methode, Newey-West) oder ``"bootstrap"``.
        B: Bootstrap-Wiederholungen. block: mittlere Blocklänge (``None`` =
            ``max(2, round(T^(1/3)))``). seed: Startwert (``None`` = keiner).
        ppy: Perioden je Jahr (``None`` = Standard bzw. geschätzt).

    Returns:
        ``pandas.Series``: ``sharpe_x``, ``sharpe_y``, ``difference``, ``se``,
        ``z``, ``p_value``, ``ci_low``, ``ci_high``, ``n``.
    """
    frequency = _match_arg(frequency, ("week", "day", "month"))
    method = _match_arg(method, ("hac", "bootstrap"))
    a = _ret_from(x, frequency)
    b = _ret_from(y, frequency)
    if (a["date"] is None) != (b["date"] is None):
        raise ValueError("sharpe_test: x und y müssen dieselbe Art sein: beide Renditevektoren oder beide "
                         "Kursreihen/Ergebnisse (data.frame bzw. SimLevResult).")
    if a["date"] is not None:
        da, db = _days(a["date"]), _days(b["date"])
        sb = set(db.tolist())
        common = list(dict.fromkeys([v for v in da.tolist() if v in sb]))
        pa = {}
        for i, v in enumerate(da.tolist()):
            pa.setdefault(v, i)
        pb = {}
        for i, v in enumerate(db.tolist()):
            pb.setdefault(v, i)
        ra = a["r"][[pa[c] for c in common]]
        rb = b["r"][[pb[c] for c in common]]
        if ppy is None:
            ppy = (len(common) - 1) / ((max(common) - min(common)) / 365.25)
    else:
        if len(a["r"]) != len(b["r"]):
            raise ValueError("sharpe_test: Renditevektoren x und y müssen gleich lang und zeitgleich sein (Längen "
                             "%d und %d)." % (len(a["r"]), len(b["r"])))
        ra, rb = a["r"], b["r"]
        if ppy is None:
            ppy = _ppy_default(frequency)
    ok = np.isfinite(ra) & np.isfinite(rb)
    ra, rb = ra[ok], rb[ok]
    Tn = len(ra)
    if Tn < 10:
        raise ValueError("sharpe_test: zu wenige gemeinsame Renditepaare (%d, mindestens 10)." % Tn)
    for k, v in (("x", ra), ("y", rb)):
        if r_sd(v) == 0:
            raise ValueError("sharpe_test: Renditen von %s haben die Varianz 0; die Sharpe Ratio ist nicht definiert." % k)
    ppy = float(ppy)
    d0 = _sr(ra) - _sr(rb)
    names = ["sharpe_x", "sharpe_y", "difference", "se", "z", "p_value", "ci_low", "ci_high", "n"]
    if np.array_equal(ra, rb):
        return pd.Series([_sr(ra) * math.sqrt(ppy), _sr(rb) * math.sqrt(ppy), 0.0, 0.0, 0.0, 1.0, 0.0, 0.0, float(Tn)],
                         index=names, dtype=np.float64)
    if method == "hac":
        mu = [r_mean(ra), r_mean(rb)]
        g = [r_mean(ra * ra), r_mean(rb * rb)]
        v1 = r_pow(g[0] - mu[0] * mu[0], 1.5)
        v2 = r_pow(g[1] - mu[1] * mu[1], 1.5)
        grad = np.array([g[0] / v1, -g[1] / v2, -0.5 * mu[0] / v1, 0.5 * mu[1] / v2], dtype=np.float64)
        Psi = _hac_cov(np.column_stack([ra, rb, ra * ra, rb * rb]))
        q = _matprod(_matprod(grad.reshape(1, 4), Psi), grad.reshape(4, 1))
        se = math.sqrt(float(q.ravel()[0]) / Tn)
        z = d0 / se
        p = 2 * float(_nm.pnorm(-abs(z)))
        qq = float(_nm.qnorm(0.975))
        ci = [d0 + (-1 * qq) * se, d0 + (1 * qq) * se]
    else:
        if block is None:
            block = max(2.0, float(_fmt.r_round(r_pow(Tn, 1 / 3))))

        def run():
            out = np.empty(int(B))
            for i in range(int(B)):
                k = _boot_idx(Tn, Tn, block)
                out[i] = _sr(ra[k]) - _sr(rb[k])
            return out

        db = _with_rng(run, seed)
        se = r_sd(db)
        z = d0 / se
        p = _mean_lgl(np.abs(db - d0) >= abs(d0))
        ci = list(_quantile(db, [0.025, 0.975]))
    k = math.sqrt(ppy)
    return pd.Series([_sr(ra) * k, _sr(rb) * k, d0 * k, se * k, z, p, ci[0] * k, ci[1] * k, float(Tn)],
                     index=names, dtype=np.float64)


# ═══════════════════════════════════════════════════════════════════════════
# overfit_reality_check
# ═══════════════════════════════════════════════════════════════════════════

def _apply_sd(M):
    return np.array([r_sd(M[:, j]) for j in range(M.shape[1])], dtype=np.float64)


def overfit_reality_check(x, *, benchmark=None, B=999, block=None, frequency=("week", "day", "month"), dates=None, seed=None):
    """White Reality Check und Hansen-SPA-Test.

    Args:
        x: ``SimLevParamSearch`` mit gespeicherten Renditen oder numerische
            Renditematrix (Zeilen = Perioden, Spalten = Strategien).
        benchmark: ``None`` (Rendite 0), Spaltennummer/-name in ``x`` oder
            Vektor der Benchmark-Renditen.
        B: Bootstrap-Wiederholungen. block: mittlere Blocklänge.
        frequency: ``"week"``, ``"day"`` oder ``"month"`` (Aggregation mit Datum).
        dates: Datum je Zeile (nur Matrix-Eingabe). seed: Startwert.

    Returns:
        :class:`SimLevRealityCheck`.
    """
    frequency = _match_arg(frequency, ("week", "day", "month"))
    rr = _ext("overfitting", "_of_returns")(x, frequency, dates)
    Rf = rr["R"]
    if isinstance(Rf, pd.DataFrame):
        R = Rf.to_numpy(dtype=np.float64)
        cn = [str(c) for c in Rf.columns]
    else:
        R = np.asarray(Rf, dtype=np.float64)
        cn = ["p%d" % (j + 1) for j in range(R.shape[1])]
    if benchmark is None:
        b = np.zeros(R.shape[0])
    else:
        bl = benchmark.to_numpy() if isinstance(benchmark, pd.Series) else benchmark
        barr = np.atleast_1d(np.asarray(bl, dtype=object)).ravel()
        if barr.size == 1:
            e = barr[0]
            if isinstance(e, str):
                j = cn.index(e) + 1 if e in cn else None
            else:
                try:
                    f = float(e)
                    j = None if math.isnan(f) else int(f)
                except (TypeError, ValueError):
                    j = None
            if j is None or j < 1 or j > R.shape[1]:
                raise ValueError("benchmark: unbekannte Spalte.")
            b = R[:, j - 1].copy()
            R = np.delete(R, j - 1, axis=1)
            cn = cn[:j - 1] + cn[j:]
        else:
            b = barr.astype(np.float64)
    if len(b) != R.shape[0]:
        raise ValueError("benchmark passt nicht zur Länge der Renditen.")
    D = R - b[:, None]
    Tn, K = D.shape
    fbar = _col_means(D)
    if block is None:
        block = max(2.0, float(_fmt.r_round(r_pow(Tn, 1 / 3))))

    def run():
        out = np.empty((int(B), K))
        for i in range(int(B)):
            out[i] = _col_means(D[_boot_idx(Tn, Tn, block), :])
        return out

    Fb = _with_rng(run, seed)
    sq = math.sqrt(Tn)
    om = np.maximum(_apply_sd(Fb), 1e-12) * sq
    V = float(np.max(sq * fbar))
    Vb = np.max(sq * (Fb - fbar[None, :]), axis=1)
    p_rc = _mean_lgl(Vb >= V)
    Tspa = max(float(np.max(sq * fbar / om)), 0.0)
    from ._r import libm as _libm
    thr = -np.sqrt(om * om / Tn * 2 * float(_libm.log(_libm.log(float(Tn)))))

    def spa_p(gv):
        Z = Fb - gv[None, :]
        Ts = np.maximum(np.max((sq * Z) / om[None, :], axis=1), 0.0)
        return _mean_lgl(Ts >= Tspa)

    jbest = int(np.argmax(fbar))
    return SimLevRealityCheck([
        ("p_rc", p_rc), ("p_spa", spa_p(fbar * (fbar >= thr))), ("p_spa_lower", spa_p(np.maximum(fbar, 0))),
        ("p_spa_upper", spa_p(fbar)), ("best", cn[jbest]), ("mean_excess", pd.Series(fbar, index=cn)),
        ("n", Tn), ("k", K), ("B", int(B))])


class SimLevRealityCheck(RList):
    """Ergebnis von :func:`overfit_reality_check` (R-Klasse ``SimLevRealityCheck``)."""

    r_class = ("SimLevRealityCheck",)

    def format(self):
        out = [_sp("Reality Check und SPA: %d Strategien, %d Perioden, B = %d\n", int(self["k"]), int(self["n"]), int(self["B"])),
               _sp("  Beste Strategie: %s (mittlere Überrendite %.4f je Periode)\n", str(self["best"]),
                   float(np.max(np.asarray(self["mean_excess"], dtype=np.float64)))),
               _sp("  p-Wert Reality Check (White):   %.3f\n  p-Wert SPA (Hansen, konsistent): %.3f  [untere %.3f, obere %.3f]\n",
                   self["p_rc"], self["p_spa"], self["p_spa_lower"], self["p_spa_upper"]),
               "  Lesart: kleiner p-Wert = die beste Strategie schlägt die Benchmark auch nach Berücksichtigung der Auswahl."]
        return "".join(out)


# ═══════════════════════════════════════════════════════════════════════════
# sharpe_min_track_record
# ═══════════════════════════════════════════════════════════════════════════

def sharpe_min_track_record(x, *, target=0, prob=0.95, frequency=("week", "day", "month"), ppy=None):
    """Mindestlänge einer Historie (Minimum Track Record Length, Bailey & López de Prado 2012).

    Args:
        x: Renditevektor, ``SimLevResult`` oder ``DataFrame(date, Wert)``.
        target: Vergleichs-Sharpe-Ratio p. a. (Standard 0).
        prob: geforderte Sicherheit (Standard 0.95).
        frequency: ``"week"``, ``"day"`` oder ``"month"``.
        ppy: Perioden je Jahr (``None`` = Standard bzw. geschätzt).

    Returns:
        ``pandas.Series``: ``sharpe``, ``periods``, ``needed_periods``,
        ``needed_years``, ``available_years``, ``sufficient``.
    """
    frequency = _match_arg(frequency, ("week", "day", "month"))
    a = _ret_from(x, frequency)
    r = a["r"][np.isfinite(a["r"])]
    if ppy is None:
        if a["date"] is not None:
            dd = _days(a["date"])
            ppy = (len(r) - 1) / ((float(np.max(dd)) - float(np.min(dd))) / 365.25)
        else:
            ppy = _ppy_default(frequency)
    ppy = float(ppy)
    m = r_mean(r)
    sdv = r_sd(r)
    sr = m / sdv
    sr0 = target / math.sqrt(ppy)
    z = (r - m) / sdv
    g3 = r_mean(np.array([r_pow(v, 3.0) for v in z]))
    g4 = r_mean(np.array([r_pow(v, 4.0) for v in z]))
    if sr <= sr0:
        need = math.inf
    else:
        qq = float(_nm.qnorm(prob)) / (sr - sr0)
        need = 1 + (1 - g3 * sr + (g4 - 1) / 4 * (sr * sr)) * (qq * qq)
    nr = len(r)
    return pd.Series([sr * math.sqrt(ppy), float(nr), need, need / ppy, nr / ppy, float(nr >= need)],
                     index=["sharpe", "periods", "needed_periods", "needed_years", "available_years", "sufficient"],
                     dtype=np.float64)


# ═══════════════════════════════════════════════════════════════════════════
# result_heatmap
# ═══════════════════════════════════════════════════════════════════════════

def result_heatmap(x, *, inflation=None, max_years=30):
    """Renditen je Startjahr und Haltedauer (annualisiert, wahlweise real).

    Args:
        x: ``SimLevResult`` oder ``DataFrame(date, Wert)`` (eine Reihe).
        inflation: ``None`` (nominal), Inflationsrate in Prozent p. a. oder
            Preisindex als ``DataFrame(date, Wert)`` bzw. benannter Vektor.
        max_years: längste Haltedauer in Jahren (Standard 30).

    Returns:
        :class:`SimLevHeatmap` mit ``matrix``, ``summary`` und ``real``.
    """
    s = _da_series(x, "x")
    if inflation is not None:
        s = _da_deflate(s, inflation)
    d = s["date"]
    yr = np.array([int(k) for k in _key_year(d)], dtype=np.int64)
    m = len(yr)
    e = list(_last_of_key(list(yr)))
    keep = np.concatenate([[True], ~s["filled"][1:]])
    tol = min(7.0, float(np.max(np.diff(d[keep]))))
    dec31 = float(_days(np.array(["%04d-12-31" % yr[-1]], dtype="datetime64[D]"))[0])
    if dec31 - d[m - 1] >= tol:
        e = e[:-1]
    v = s["value"]
    base = [float(v[0])] + [float(v[i]) for i in e]
    years = [int(yr[0]) - 1] + [int(yr[i]) for i in e]
    if _fmt.format_date(_dates(d[:1]), "%m-%d")[0] != "01-01":
        base = [float(v[i]) for i in e]
        years = [int(yr[i]) for i in e]
    ny = len(base) - 1
    if ny < 1:
        raise ValueError("result_heatmap: Die Reihe umfasst kein vollständiges Kalenderjahr.")
    H = int(min(max_years, ny))
    M = np.full((ny, H), _NAN)
    for i in range(ny):
        for h in range(1, min(H, ny - i) + 1):
            M[i, h - 1] = r_pow(base[i + h] / base[i], 1 / h) - 1
    Mdf = pd.DataFrame(M, index=[str(y) for y in years[1:]], columns=[str(h) for h in range(1, H + 1)])
    mins, meds, maxs, neg, cnt = [], [], [], [], []
    for j in range(H):
        c = M[:, j]
        c = c[~np.isnan(c)]
        mins.append(float(np.min(c)))
        meds.append(r_median(c))
        maxs.append(float(np.max(c)))
        neg.append(_mean_lgl(c < 0))
        cnt.append(float(len(c)))
    summ = pd.DataFrame({"years": np.arange(1, H + 1, dtype=np.int64), "min": mins, "median": meds, "max": maxs,
                         "share_negative": neg, "n": cnt}, index=[str(h) for h in range(1, H + 1)])
    return SimLevHeatmap([("matrix", Mdf), ("summary", summ), ("real", inflation is not None)])


class SimLevHeatmap(RList):
    """Ergebnis von :func:`result_heatmap` (R-Klasse ``SimLevHeatmap``)."""

    r_class = ("SimLevHeatmap",)

    def format(self):
        out = ["Renditen je Startjahr und Haltedauer (%s, annualisiert)\n\n" % ("real" if self["real"] else "nominal")]
        s = self["summary"]
        s = s[s["years"].isin([1, 3, 5, 10, 15, 20, 25, 30])]
        tab = pd.DataFrame({
            "Jahre": s["years"].to_numpy(dtype=np.int64),
            "Minimum": np.array(_pct("%.1f %%", s["min"]), dtype=object),
            "Median": np.array(_pct("%.1f %%", s["median"]), dtype=object),
            "Maximum": np.array(_pct("%.1f %%", s["max"]), dtype=object),
            "negativ": np.array(_pct("%.0f %%", s["share_negative"]), dtype=object),
            "Zeitraeume": s["n"].to_numpy(dtype=np.float64)})
        out.append(_fmt.print_data_frame(tab, row_names=False))
        return "".join(out)


# ═══════════════════════════════════════════════════════════════════════════
# Grafiken (SVG wie julia/src/analysis_tests.jl; Bausteine `_ana_*` in svg.py)
# ═══════════════════════════════════════════════════════════════════════════

def _r_minmax(x, op):
    """R's ``min()``/``max()`` für Doubles (NA vor NaN; leer: Warnung, ±Inf) wie Julias ``_rmin``/``_rmax``."""
    s = math.inf if op == "min" else -math.inf
    upd = False
    for v in np.asarray(x, dtype=np.float64).tolist():
        if math.isnan(v):
            if not upd or not r_isna(s):
                s = v
            upd = True
        elif not upd or (v < s if op == "min" else v > s):
            s = v
            upd = True
    if not upd:
        warnings.warn("no non-missing arguments to %s; returning %s" % (op, "Inf" if op == "min" else "-Inf"))
    return s


def _plot_signal(x):
    """``plot.SimLevSignalAnalysis`` (SVG): Balken je Bereich (± 2 Standardfehler) und Streudiagramm.

    Returns:
        :class:`simlev.SimLevPlot`; ``data``: ``bins`` (``bin``, ``mean``, ``lower``, ``upper``: Mittel und
        Mittel ± 2 Standardfehler als Anteil) und ``scatter`` (``signal``, ``forward`` und mit
        Polynom-Glättung ``fitted``).
    """
    from .svg import _jl_maximum, _jl_minimum
    b = x["bins"]
    nb = len(b)
    mean = b["mean"].to_numpy(dtype=np.float64)
    sd = b["sd"].to_numpy(dtype=np.float64)
    nn = b["n"].to_numpy(dtype=np.float64)
    m = 100 * mean
    se = 100 * sd / np.sqrt(nn)
    lo = m - 2 * se
    hi = m + 2 * se
    fin = np.concatenate([lo, hi, [0.0]])
    fin = fin[np.isfinite(fin)]
    s = _AnaSvg(1000, 460)
    p = _ana_panel(s, 0, 0, 500, 460, (0.5, nb + 0.5), (_jl_minimum(fin), _jl_maximum(fin)),
                   title="Je Signalbereich", xlab="Signalbereich (niedrig -> hoch)",
                   ylab="Mittlere Vorwärtsrendite (%)", xticks=list(range(1, nb + 1)))
    for i in range(1, nb + 1):
        _ana_rect(s, p, i - 0.35, 0.0, i + 0.35, m[i - 1], fill="#2C6E9B")
        _ana_lines(s, p, [i, i], [lo[i - 1], hi[i - 1]], col="#000", lwd=1)
    _ana_hline(s, p, 100 * x["overall"]["mean"], col="#B5562B", dash="5,4")
    dd = x["data"]
    sv = dd["signal"].to_numpy(dtype=np.float64)
    fw = dd["forward"].to_numpy(dtype=np.float64)
    fv = 100 * fw
    q = _ana_panel(s, 500, 0, 500, 460, (_r_minmax(sv, "min"), _r_minmax(sv, "max")),
                   (_r_minmax(fv, "min"), _r_minmax(fv, "max")), title="Streudiagramm", xlab=x["signal_name"],
                   ylab="Vorwärtsrendite (%)")
    _ana_points(s, q, sv, fv)
    sc = {"signal": sv.copy(), "forward": fw.copy()}
    if x.get("fit") is not None:
        fitted = np.asarray(x["fit"]["model"]["fitted.values"], dtype=np.float64).ravel()
        o = np.argsort(sv, kind="stable")
        _ana_lines(s, q, sv[o], 100 * fitted[o], col="#B5562B", lwd=2)
        sc["fitted"] = fitted.copy()
    _ana_hline(s, q, 0.0)
    se1 = sd / np.sqrt(nn)
    data = {"bins": pd.DataFrame({"bin": np.array([str(v) for v in b["bin"]], dtype=object), "mean": mean.copy(),
                                  "lower": mean - 2 * se1, "upper": mean + 2 * se1}),
            "scatter": pd.DataFrame(sc)}
    return _ana_svg_done(s), data


def _plot_heatmap(x):
    """``plot.SimLevHeatmap`` (SVG): Heatmap Startjahr x Haltedauer (Farbskala bei ± 25 % begrenzt).

    Returns:
        :class:`simlev.SimLevPlot`; ``data``: ``heatmap`` (``start_year``, ``years``, ``value``: gezeichnete
        Zellen, annualisierte Rendite als Anteil wie in ``matrix``).
    """
    from .svg import _jl_maximum, _jl_min
    Mm = x["matrix"]
    raw = Mm.to_numpy(dtype=np.float64)
    M = 100 * raw
    fin = M[np.isfinite(M)]
    lim = _jl_min(1.0 if fin.size == 0 else _jl_maximum(np.abs(fin)), 25.0)
    pal = _ana_ramp(["#B5562B", "#F2E9DC", "#2C6E9B"], 51)
    yrs = [int(r) for r in Mm.index]
    H = M.shape[1]
    s = _AnaSvg(900, 520)
    by = max(1, -(-len(yrs) // 12))
    p = _ana_panel(s, 0, 0, 820, 520, (yrs[0] - 0.5, yrs[-1] + 0.5), (0.5, H + 0.5),
                   title="Annualisierte %s Rendite" % ("reale" if x["real"] else "nominale"), xlab="Startjahr",
                   ylab="Haltedauer (Jahre)", xticks=[float(v) for v in yrs[::by]], xlabels=[str(v) for v in yrs[::by]])
    sy, hy, vv = [], [], []
    for i in range(len(yrs)):
        for h in range(1, H + 1):
            v = float(M[i, h - 1])
            if not math.isfinite(v):
                continue
            v = -lim if v < -lim else (lim if v > lim else v)
            c = pal[min(max(int(round((v + lim) / (2 * lim) * 50)) + 1, 1), 51) - 1]
            _ana_rect(s, p, yrs[i] - 0.5, h - 0.5, yrs[i] + 0.5, h + 0.5, fill=c)
            sy.append(yrs[i])
            hy.append(h)
            vv.append(float(raw[i, h - 1]))
    for k, t in enumerate((-lim, 0.0, lim)):
        _ana_legend(s, p, [_sp("%+.0f %%", t)], [pal[(0, 25, 50)[k]]], x=830.0, y=60.0 + 20 * k, box=True)
    data = {"heatmap": pd.DataFrame({"start_year": np.array(sy, dtype=np.int64), "years": np.array(hy, dtype=np.int64),
                                     "value": np.array(vv, dtype=np.float64)})}
    return _ana_svg_done(s), data


from .svg import _plot_method  # noqa: E402

SimLevSignalAnalysis.plot = _plot_method(_plot_signal, "SimLevSignalAnalysis")
SimLevHeatmap.plot = _plot_method(_plot_heatmap, "SimLevHeatmap")


from ._r.base import quiet_fp  # noqa: E402

quiet_fp(globals(), __all__ + ["_hac_cov", "_ret_from"])
