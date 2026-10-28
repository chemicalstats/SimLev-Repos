"""Regime-Erkennung mit einem Gauss'schen Hidden-Markov-Modell (Port von ``r/R/regimes.R``).

- :func:`regime_hmm`     schätzt K Marktphasen aus den Periodenrenditen einer
  oder mehrerer Reihen (Baum-Welch, mehrere Startwerte); liefert gefilterte
  und geglättete Wahrscheinlichkeiten sowie den Viterbi-Pfad
- :func:`regime_states`  legt die Regime auf einen Tageskalender
"""
from __future__ import annotations

import math
import warnings

import numpy as np
import pandas as pd

from . import _dependence_core as _core
from . import dependence as _dep
from ._r import fmt as _fmt
from ._r import libm as _libm
from ._r.rlist import RList
from ._r.rnum import r_colsums, r_mean, r_rowsums, r_sd, r_sum, r_var

__all__ = ["regime_hmm", "regime_states", "SimLevHMM"]

_NAN = float("nan")      # R's NaN
_NA = _fmt.NA_REAL       # R's NA_real_


def _ldmvn(X, mu, S):
    """Log-Dichte der multivariaten Normalverteilung je Zeile (``.ldmvn``)."""
    la = _dep._linalg()
    X = np.asarray(X, dtype=np.float64)
    L = np.asarray(la.chol(np.asarray(S, dtype=np.float64)), dtype=np.float64)
    Xc = X - np.asarray(mu, dtype=np.float64).reshape(1, -1)
    Z = np.asarray(la.backsolve(L, Xc.T, transpose=True), dtype=np.float64).T
    d = X.shape[1]
    return -0.5 * r_rowsums(Z * Z) - r_sum(_libm.log(np.diag(L))) - 0.5 * d * math.log(2 * math.pi)


def _which_max(v):
    """R ``which.max`` (erstes Maximum, NA ignoriert); ``None`` wenn leer."""
    v = np.asarray(v, dtype=np.float64)
    ok = ~np.isnan(v)
    if not ok.any():
        return None
    idx = np.nonzero(ok)[0]
    return int(idx[np.argmax(v[idx])])


def _hmm_viterbi(lB, lA, lp0):
    """Viterbi-Pfad (1-basiert) aus Log-Emissionen, Log-Übergangsmatrix, Log-Start."""
    lB = np.asarray(lB, dtype=np.float64)
    lA = np.asarray(lA, dtype=np.float64)
    Tn, k = lB.shape
    dl = np.asarray(lp0, dtype=np.float64) + lB[0, :]
    bp = np.zeros((Tn, k), dtype=np.int64)
    jj = np.arange(k)
    for t in range(1, Tn):
        cand = dl.reshape(-1, 1) + lA
        if np.isnan(cand).any():
            wm = [_which_max(cand[:, j]) for j in range(k)]
            if any(w is None for w in wm):      # apply(..., which.max) liefert integer(0) -> Liste
                raise ValueError("replacement has length zero")
            im = np.array(wm, dtype=np.int64)
            mx = np.array([_dep._rmax(cand[:, j]) for j in range(k)])
        else:
            im = np.argmax(cand, axis=0)
            mx = cand[im, jj]
        bp[t, :] = im + 1
        dl = mx + lB[t, :]
    path = np.zeros(Tn, dtype=np.int64)
    w = _which_max(dl)
    path[Tn - 1] = (w + 1) if w is not None else 0
    for t in range(Tn - 1, 0, -1):
        path[t - 1] = bp[t, path[t] - 1]
    return path


def _cov2cor(V):
    """``stats::cov2cor``."""
    V = np.asarray(V, dtype=np.float64)
    p = V.shape[0]
    Is = np.sqrt(1 / np.diag(V))
    r = Is.reshape(-1, 1) * V * Is.reshape(1, -1)
    r[np.arange(p), np.arange(p)] = 1.0
    return r


class SimLevHMM(RList):
    """Ergebnis von :func:`regime_hmm` (R-Klasse ``SimLevHMM``)."""

    r_class = ("SimLevHMM",)

    def format(self):
        x = self
        lines = [_fmt.sprintf("Hidden-Markov-Modell: %d Zustände auf %s (%s), %d Perioden, logL %.1f, BIC %.1f\n",
                              int(x["k"]), ", ".join(x["columns"]), x["frequency"], len(x["dates"]),
                              float(x["loglik"]), float(x["bic"]))]
        mu = np.asarray(x["means"], dtype=np.float64)
        vo = np.asarray(x["volatility"], dtype=np.float64)
        share = np.asarray(x["share"], dtype=np.float64)
        dur = np.asarray(x["duration"], dtype=np.float64)
        for j in range(int(x["k"])):
            lines.append(_fmt.sprintf("  Z%d: Anteil %.0f %%, erwartete Dauer %.1f Perioden, Rendite %s %% p. a., Vola %s %%",
                                      j + 1, 100 * share[j], dur[j], "/".join(_dep._sprintf_vec("%.1f", mu[j, :])),
                                      "/".join(_dep._sprintf_vec("%.1f", vo[j, :]))))
        lines.append("\nÜbergangsmatrix")
        T = x["transition"]
        lines.append(_fmt.print_matrix(pd.DataFrame(_fmt.r_round(np.asarray(T, dtype=np.float64), 3),
                                                    index=T.index, columns=T.columns)))
        F = np.asarray(x["filtered"], dtype=np.float64)
        last = F[F.shape[0] - 1, :]
        w = _which_max(last)
        lines.append(_fmt.sprintf("\nAktueller Zustand (gefiltert): Z%d mit %.0f %%", w + 1, 100 * _dep._rmax(last)))
        return "\n".join(lines)

    def plot(self, data=None, **kw):
        import matplotlib.pyplot as plt
        x = self
        top = np.asarray(x["filtered"], dtype=np.float64)[:, int(x["k"]) - 1]
        fig, ax = plt.subplots(figsize=(10, 4))
        ax.plot(x["dates"], top, color="#B5562B", **kw)
        ax.fill_between(x["dates"], top, 0, color="#B5562B", alpha=0.25)
        ax.axhline(0.5, ls=":", color="grey")
        ax.set_ylim(0, 1)
        ax.set_ylabel("P(Z%d | bis t)" % int(x["k"]))
        ax.set_title("Gefilterte Wahrscheinlichkeit des unruhigsten Zustands (Z%d)" % int(x["k"]))
        return x


def regime_hmm(data, columns, k=2, frequency=("week", "day", "month"), n_start=5, max_iter=300, tol=1e-7, seed=1):
    """Hidden-Markov-Modell für Marktregime.

    Args:
        data: DataFrame mit ``date`` und Kursspalten (Niveaus).
        columns: Kursspalte(n).
        k: Anzahl Zustände (ganze Zahl >= 2); mindestens ``50 * k`` Perioden.
        frequency: ``"week"`` (Standard), ``"day"`` oder ``"month"``.
        n_start: Anzahl Startwerte.
        max_iter, tol: Baum-Welch-Iterationen je Start und relative Abbruchschranke.
        seed: Startwert der zufälligen Startwerte (``None`` = Zufallsstrom der Sitzung).

    Returns:
        :class:`SimLevHMM`.
    """
    frequency = _dep._match_arg(frequency, ("week", "day", "month"))
    kv = np.atleast_1d(np.asarray(k, dtype=object))
    ok = (kv.size == 1 and isinstance(kv[0], (int, float, np.integer, np.floating)) and not isinstance(kv[0], (bool, np.bool_))
          and math.isfinite(float(kv[0])) and float(kv[0]) == float(_fmt.r_round(float(kv[0]))) and float(kv[0]) >= 2)
    if not ok:
        raise ValueError("regime_hmm: k muss eine ganze Zahl >= 2 sein (erhalten: %s); ein Zustand wäre eine einzige "
                         "Normalverteilung ohne Regime." % _dep._fmt1(k))
    k = int(float(kv[0]))
    columns = _dep._as_names(columns)
    rd = _dep._dep_returns(data, columns, None, frequency)
    X = rd[columns].to_numpy(dtype=np.float64)
    Tn, d = X.shape
    if Tn < 50 * k:
        raise ValueError("regime_hmm: zu wenige Perioden für die Zustandszahl (%d Perioden, mindestens %d für k = %d)."
                         % (Tn, 50 * k, k))
    flat = [columns[j] for j in range(d) if r_sd(X[:, j]) == 0]
    if flat:
        raise ValueError("regime_hmm: Spalte(n) %s ohne Schwankung (alle Periodenrenditen gleich, z. B. konstante Kurse); "
                         "kein Modell schätzbar." % ", ".join("'%s'" % f for f in flat))
    dd = _dep._days(rd["date"].to_numpy())
    ppy = (Tn - 1) / ((dd[Tn - 1] - dd[0]) / 365.25)
    ridge = np.eye(d) * (1e-10 + 1e-6 * r_mean([r_var(X[:, j]) for j in range(d)]))
    la = _dep._linalg()

    def fit_once(init):
        mu = init["mu"].copy()
        S = [s.copy() for s in init["S"]]
        A = init["A"].copy()
        p0 = np.full(k, 1 / k)
        ll_old = -math.inf

        def estep():
            lB = np.column_stack([_ldmvn(X, mu[j, :], S[j]) for j in range(k)])
            m = lB[:, 0].copy()
            for j in range(1, k):
                b = lB[:, j]
                with np.errstate(invalid="ignore"):   # pmax: NaN/NA in b gewinnt, NaN/NA in m bleibt
                    m = np.where(np.isnan(b) | (b > m), b, m)
            fb = _core.hmm_forward_backward(_libm.exp(lB - m.reshape(-1, 1)), A, p0)
            ll = r_sum(_libm.log(fb["scale"])) + r_sum(m)
            return lB, fb, ll
        it = 0
        for it in range(1, int(max_iter) + 1):
            lB, fb, ll = estep()
            ga = fb["smoothed"]
            xi = fb["xi"]
            p0 = ga[0, :].copy()
            A = xi / r_rowsums(xi).reshape(-1, 1)
            for j in range(k):
                w = ga[:, j]
                sw = r_sum(w)
                mu[j, :] = r_colsums(X * w.reshape(-1, 1)) / sw
                Xc = X - mu[j, :].reshape(1, -1)
                S[j] = np.asarray(la.crossprod(Xc * np.sqrt(w).reshape(-1, 1)), dtype=np.float64) / sw + ridge
            if abs(ll - ll_old) < tol * (1 + abs(ll)):
                break
            ll_old = ll
        lB, fb, ll = estep()
        return {"mu": mu, "S": S, "A": A, "p0": p0, "ll": ll, "filtered": fb["filtered"], "smoothed": fb["smoothed"],
                "lB": lB, "iter": it}

    def make_inits():
        rng = _dep._rng()
        res = []
        for s in range(1, int(n_start) + 1):
            with np.errstate(invalid="ignore"):   # NA am Rand (signalisierendes NaN) ohne Warnung wie in R
                vol = np.sqrt(_dep._roll_mean(r_rowsums(X * X), int(max(4, float(_fmt.r_round(ppy / 12))))))
            na = np.isnan(vol)
            if na.any():
                vol[na] = _dep._median(vol, na_rm=True)
            if s == 1:
                cl = _dep._cut_n(_dep._rank_avg(vol), k)
            else:
                cl = np.asarray(rng.sample_int(k, Tn, replace=True), dtype=np.int64)
            mu = np.vstack([_dep._colmeans(X[cl == j + 1, :]) for j in range(k)])
            S = [np.asarray(_dep._stats().cov(X[cl == j + 1, :]), dtype=np.float64) + ridge for j in range(k)]
            off = 0.1 / max(1, k - 1)
            A = np.full((k, k), off) + np.eye(k) * (0.9 - off)
            res.append({"mu": mu, "S": S, "A": A})
        return res
    inits = _dep._with_rng_restore(make_inits, seed)
    fits = []
    for i in inits:
        try:
            with np.errstate(all="ignore"):
                fits.append(fit_once(i))
        except Exception:  # noqa: BLE001 - tryCatch(error = NULL)
            continue
    if not fits:
        raise ValueError("regime_hmm: Schätzung fehlgeschlagen.")
    f = fits[_which_max([fi["ll"] for fi in fits])]
    vol = np.array([math.sqrt(r_mean(np.diag(s))) for s in f["S"]])
    o = np.argsort(vol, kind="stable")
    A = f["A"][np.ix_(o, o)]
    mu = f["mu"][o, :]
    S = [f["S"][i] for i in o]
    lB = f["lB"][:, o]
    path = _hmm_viterbi(lB, _libm.log(A), _libm.log(f["p0"][o]))
    npar = k - 1 + k * (k - 1) + k * d + k * d * (d + 1) / 2
    zn = ["Z%d" % (j + 1) for j in range(k)]
    vols = np.vstack([np.sqrt(np.diag(s) * ppy) * 100 for s in S])
    out = SimLevHMM()
    out["transition"] = pd.DataFrame(A, index=zn, columns=zn)
    out["means"] = pd.DataFrame(mu * ppy * 100, index=zn, columns=columns)
    out["volatility"] = pd.DataFrame(vols, index=zn, columns=columns)
    out["correlation"] = [_cov2cor(s) for s in S]
    out["filtered"] = f["filtered"][:, o]
    out["smoothed"] = f["smoothed"][:, o]
    out["viterbi"] = path
    out["dates"] = rd["date"].to_numpy()
    out["columns"] = columns
    out["k"] = k
    out["loglik"] = f["ll"]
    out["bic"] = -2 * f["ll"] + npar * math.log(Tn)
    out["initial"] = pd.Series(f["p0"][o], index=zn)
    out["duration"] = pd.Series(1 / (1 - np.diag(A)), index=zn)
    out["frequency"] = frequency
    out["ppy"] = ppy
    out["share"] = _dep._colmeans(f["smoothed"][:, o])
    return out


def regime_states(x, dates, type=("filtered", "smoothed", "viterbi"), output=("state", "probability"),
                  state_prob=None, lag=1):
    """Regime auf einen Tageskalender legen.

    Args:
        x: :class:`SimLevHMM` aus :func:`regime_hmm`.
        dates: Zieldaten (Date-Vektor oder DataFrame mit Spalte ``date``).
        type: ``"filtered"`` (Standard), ``"smoothed"`` oder ``"viterbi"``.
        output: ``"state"`` (Standard) oder ``"probability"``.
        state_prob: Zustandsnummer für ``output = "probability"`` (Standard ``x.k``).
        lag: Verzögerung in Kalendertagen.

    Returns:
        ``numpy.ndarray`` mit einem Wert je Datum (NA = ``nan``).
    """
    type = _dep._match_arg(type, ("filtered", "smoothed", "viterbi"), "type")
    output = _dep._match_arg(output, ("state", "probability"), "output")
    if state_prob is None:
        state_prob = x["k"]
    if type != "filtered":
        warnings.warn("Geglättete bzw. Viterbi-Zustände nutzen Zukunftsdaten - nur zur Beschreibung verwenden.")
    src = dates["date"] if isinstance(dates, pd.DataFrame) else dates
    d = _dep._to_date(src, "regime_states: dates")
    P = {"filtered": x["filtered"], "smoothed": x["smoothed"], "viterbi": None}[type]
    if output == "probability":
        if P is None:
            raise ValueError("Wahrscheinlichkeit nicht für Viterbi.")
        v = np.asarray(P, dtype=np.float64)[:, int(state_prob) - 1]
    elif P is None:
        v = np.asarray(x["viterbi"], dtype=np.float64)
    else:
        Pm = np.asarray(P, dtype=np.float64)
        v = np.array([(_which_max(r) + 1) if not np.isnan(r).any() else _NA for r in Pm], dtype=np.float64)
    dv = _dep._days(d)
    ref = _dep._days(x["dates"]) + lag
    kk = np.searchsorted(ref, dv, side="right")
    out = np.where(kk > 0, v[np.maximum(kk, 1) - 1], _NA)
    out[np.isnan(dv)] = _NA
    return out


# Rechnen mit NA (signalisierendes NaN) ohne numpy-Warnung "invalid value" wie in R (gemeinsamer Helfer)
from ._r.base import quiet_fp  # noqa: E402

quiet_fp(globals(), list(__all__) + ["_hmm_viterbi", "_ldmvn"])
