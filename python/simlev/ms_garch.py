"""Eigene ML-Schätzung des MS-GARCH-Modells (Port von ``r/R/ms_garch.R``).

Modell nach Haas, Mittnik und Paolella (2004): K Regime, je Regime ein
GARCH(1,1)- (``"sGARCH"``) oder GJR-GARCH(1,1)-Varianzpfad
(``"gjrGARCH"``); die Varianzpfade aller Regime laufen parallel;
Normalverteilung mit Mittelwert 0; Regimewechsel als Markov-Kette.
Likelihood über den Hamilton-Filter
(:func:`simlev._bootstrap_core.ms_garch_filter`, Port von
``r/src/ms_garch.c``), Maximierung mit ``optim`` (BFGS) auf eigener
Parametrisierung auf R^p, deterministische Startwerte (kein Zufall): volles
HMM-EM (:func:`simlev.regimes._hmm_em`) und Rangeinteilung der
Volatilität, je mit kleinem Raster; ``optim`` von beiden Familien, die
höhere Log-Likelihood zählt. Genutzt von ``bootstrap._prepare_ms_info`` für
die Verfahren ``"ms_garch"``, ``"ms_ar_garch_m"`` und ``"tvtp_ms_garch"``.

Wie in R sind Summen weniger Werte fortlaufende double-Additionen (nicht
``sum``, das in R in ``long double`` summiert). Nur interne Funktionen.
"""
from __future__ import annotations

import math

import numpy as np

from . import _bootstrap_core as _core
from ._r import fmt as _fmt
from ._r import libm as _libm
from ._r.rnum import r_mean, r_var

__all__: list[str] = []


def _stats():
    from ._r import stats
    return stats


def _regimes():
    from . import regimes
    return regimes


def _div(a, b):
    """``a / b`` wie C (auch für ``b == 0``)."""
    if b != 0.0:
        return a / b
    with np.errstate(all="ignore"):
        return float(np.float64(a) / np.float64(b))


def _seq01(n):
    """``seq(0, 1, length.out = n)`` (n >= 2)."""
    if n > 2:
        n1 = n - 1.0
        return np.concatenate([[0.0], 0.0 + np.arange(1, n - 1, dtype=np.float64) * (1.0 / n1), [1.0]])
    return np.array([0.0, 1.0])[:n]


def _isfinite_all(*xs):
    return all(bool(np.isfinite(np.asarray(x, dtype=np.float64)).all()) for x in xs)


def _show(x):
    """``paste(format(x), collapse = ", ")``; ``None`` steht für ``NA``."""
    if x is None:
        return "NA"
    if isinstance(x, (list, tuple)):
        x = np.asarray(x, dtype=object if any(isinstance(v, str) or v is None for v in x) else None)
    if isinstance(x, np.ndarray) and x.dtype == object:
        return ", ".join("NA" if v is None else str(v) for v in x.ravel())
    r = _fmt.format(x)
    if isinstance(r, str):
        return r
    return ", ".join(str(s) for s in np.asarray(r, dtype=object).ravel())


def _ms_garch_check(K, model):
    """Varianzmodell und Regimezahl der MS-GARCH-Schätzung prüfen (``.ms_garch_check``)."""
    m = model
    if isinstance(m, (list, tuple, np.ndarray)):
        mv = list(np.asarray(m, dtype=object).ravel())
    else:
        mv = [m]
    ok_m = (len(mv) == 1 and isinstance(mv[0], str) and mv[0] in ("sGARCH", "gjrGARCH"))
    if not ok_m:
        raise ValueError("MS-GARCH: Varianzmodell je Regime (params ms_garch_model, ms_ar_garch_model bzw. "
                         "tvtp_garch_model) muss \"sGARCH\" oder \"gjrGARCH\" sein (erhalten: %s)." % _show(model))
    kv = K if isinstance(K, (list, tuple, np.ndarray)) else [K]
    kv = list(np.asarray(kv, dtype=object).ravel())
    ok_k = (len(kv) == 1 and isinstance(kv[0], (int, float, np.integer, np.floating))
            and not isinstance(kv[0], (bool, np.bool_)))
    if ok_k:
        k0 = float(kv[0])
        ok_k = math.isfinite(k0) and k0 == float(_fmt.r_round(k0)) and k0 >= 2
    if not ok_k:
        raise ValueError("MS-GARCH: Anzahl Regime (params ms_n_regimes, ms_ar_n_regimes bzw. tvtp_n_regimes) "
                         "muss eine ganze Zahl >= 2 sein (erhalten: %s)." % _show(K))
    return True


def _ms_garch_stat(P):
    """Stationäre Verteilung einer Übergangsmatrix (``.ms_garch_stat``).

    Potenziteration wie für ``pi_`` in ``.prepare_ms_info``: Start
    gleichverteilt, höchstens 1000 Schritte, Abbruch bei maximaler Änderung
    < 1e-12. ``pi_ %*% P`` in der Reihenfolge von R's ``matprod``
    (Referenz-BLAS ``dgemv``, bei nicht endlichen Werten ``linalg.matprod``).
    """
    P = np.asarray(P, dtype=np.float64)
    K = P.shape[0]
    pi_ = [1 / K] * K
    fin = bool(np.isfinite(P).all())
    Pc = [[float(P[i, j]) for i in range(K)] for j in range(K)]   # Spalten
    start = 0
    if K == 2 and fin:
        # Etappe 7.1: dieselbe Rechnung für zwei Regime mit lokalen Variablen
        # (s = 0.0 + P[0, j] * pi[0], dann s + P[1, j] * pi[1]); wird pi nicht
        # endlich, geht es im allgemeinen Weg mit demselben Schritt weiter
        (c00, c01), (c10, c11) = Pc
        p0 = p1 = pi_[0]
        isf = math.isfinite
        for it in range(1000):
            if not (isf(p0) and isf(p1)):
                start = it
                break
            q0 = 0.0 + c00 * p0
            q0 = q0 + c01 * p1
            q1 = 0.0 + c10 * p0
            q1 = q1 + c11 * p1
            d0 = abs(q0 - p0)
            if d0 != d0:
                raise ValueError("missing value where TRUE/FALSE needed")
            d1 = abs(q1 - p1)
            if d1 != d1:
                raise ValueError("missing value where TRUE/FALSE needed")
            if (d1 if d1 > d0 else d0) < 1e-12:
                return np.array([p0, p1], dtype=np.float64)
            p0 = q0
            p1 = q1
        else:
            return np.array([p0, p1], dtype=np.float64)
        pi_ = [p0, p1]
    for _ in range(start, 1000):
        if fin and all(math.isfinite(v) for v in pi_):
            p2 = []
            for col in Pc:
                s = 0.0
                for i in range(K):
                    s = s + col[i] * pi_[i]
                p2.append(s)
        else:
            from ._r import linalg as _la
            p2 = [float(v) for v in np.asarray(_la.matprod(np.asarray(pi_), P), dtype=np.float64).ravel()]
        mx = None
        for a, b in zip(p2, pi_):
            dv = abs(a - b)
            if dv != dv:
                raise ValueError("missing value where TRUE/FALSE needed")
            if mx is None or dv > mx:
                mx = dv
        if mx < 1e-12:
            break
        pi_ = p2
    return np.array(pi_, dtype=np.float64)


def _ms_garch_unpack(theta, K, gjr):
    """Parametervektor auf R^p in Modellparameter umrechnen (``.ms_garch_unpack``).

    Reihenfolge: je Regime 1 bis K (theta_omega, a, [g], b), danach P
    zeilenweise ohne Diagonale. omega = exp(theta_omega); sGARCH:
    e = exp(c(a, b)), alpha = e[1] / (1 + sum(e)), beta = e[2] / (1 + sum(e));
    gjrGARCH: e = exp(c(a, g, b)), alpha = e[1] / d, gamma = 2 * e[2] / d,
    beta = e[3] / d mit d = 1 + sum(e). Zeile i von P: exp(theta_i.) mit
    theta_ii = 0, geteilt durch die Zeilensumme.
    """
    th = [float(v) for v in np.asarray(theta, dtype=np.float64).ravel()]
    ex = _libm._exp
    npk = 4 if gjr else 3
    om = [0.0] * K
    al = [0.0] * K
    be = [0.0] * K
    ga = [0.0] * K
    for k in range(K):
        j = k * npk
        om[k] = ex(th[j])
        if gjr:
            e1 = ex(th[j + 1])
            e2 = ex(th[j + 2])
            e3 = ex(th[j + 3])
            d = 1 + ((e1 + e2) + e3)
            al[k] = e1 / d
            ga[k] = 2 * e2 / d
            be[k] = e3 / d
        else:
            e1 = ex(th[j + 1])
            e2 = ex(th[j + 2])
            d = 1 + (e1 + e2)
            al[k] = e1 / d
            be[k] = e2 / d
    P = [[0.0] * K for _ in range(K)]
    pos = K * npk
    for i in range(K):
        for j in range(K):
            if j == i:
                P[i][j] = 1.0
            else:
                P[i][j] = ex(th[pos])
                pos += 1
        s = 0.0
        for j in range(K):
            s = s + P[i][j]
        for j in range(K):
            P[i][j] = _div(P[i][j], s)
    with np.errstate(all="ignore"):
        return {"omega": np.array(om), "alpha": np.array(al), "beta": np.array(be), "gamma": np.array(ga),
                "P": np.array(P, dtype=np.float64).reshape(K, K)}


def _ms_garch_pack(om, al, be, ga, P, gjr):
    """Modellparameter in den Parametervektor auf R^p umrechnen (``.ms_garch_pack``).

    Umkehrung von :func:`_ms_garch_unpack`; Restanteil
    r = 1 - alpha - gamma/2 - beta = 1 / d.
    """
    lg = _libm._log
    om = [float(v) for v in np.asarray(om, dtype=np.float64).ravel()]
    al = [float(v) for v in np.asarray(al, dtype=np.float64).ravel()]
    be = [float(v) for v in np.asarray(be, dtype=np.float64).ravel()]
    ga = [float(v) for v in np.asarray(ga, dtype=np.float64).ravel()]
    P = np.asarray(P, dtype=np.float64)
    K = len(om)
    th = []
    for k in range(K):
        r = 1 - al[k] - ga[k] / 2 - be[k]
        th.append(lg(om[k]))
        th.append(lg(_div(al[k], r)))
        if gjr:
            th.append(lg(_div(ga[k] / 2, r)))
        th.append(lg(_div(be[k], r)))
    for i in range(K):
        for j in range(K):
            if j != i:
                th.append(lg(_div(float(P[i, j]), float(P[i, i]))))
    return np.array(th, dtype=np.float64)


def _ms_garch_fit(y, K, model):
    """MS-GARCH-Modell per Maximum Likelihood schätzen (``.ms_garch_fit``, eigene Fassung).

    Args:
        y: Numerischer Vektor (Tagesrenditen als Anteil, Mittelwert 0 angenommen).
        K: Anzahl Regime (ganze Zahl >= 2).
        model: Varianzmodell je Regime: ``"sGARCH"`` oder ``"gjrGARCH"``.

    Returns:
        dict ``omega``, ``alpha``, ``beta``, ``gamma``, ``P``, ``regimes``,
        ``s2``, ``loglik``, ``convergence``: Parameter je Regime (aufsteigend
        nach unbedingter Varianz omega / (1 - alpha - gamma/2 - beta)
        sortiert; gamma = 0 bei ``"sGARCH"``), Übergangsmatrix P (Zeile =
        von), Viterbi-Pfad (ganze Zahlen 1 bis K), vorhergesagte
        Mischungsvarianz s2[t] = sum_k P(s_t = k | F_{t-1}) h[t, k],
        Log-Likelihood und Konvergenzcode von ``optim``.
    """
    _ms_garch_check(K, model)
    K = int(float(np.asarray(K, dtype=np.float64).ravel()[0]))
    model = model if isinstance(model, str) else str(np.asarray(model, dtype=object).ravel()[0])
    gjr = model == "gjrGARCH"
    y = np.asarray(y, dtype=np.float64).ravel()
    h1 = r_var(y)
    st = _stats()
    R = _regimes()

    # Zielfunktion: negative Log-Likelihood, 1e10 statt -Inf
    def nll(theta):
        m = _ms_garch_unpack(theta, K, gjr)
        if not _isfinite_all(m["omega"], m["alpha"], m["beta"], m["gamma"], m["P"]):
            return 1e10
        ll = _core.ms_garch_filter(y, m["omega"], m["alpha"], m["beta"], m["gamma"], m["P"],
                                   _ms_garch_stat(m["P"]), h1)["loglik"]
        return -ll if math.isfinite(ll) else 1e10

    # Zeilen einer Start-Übergangsmatrix mit Nullen oder nicht endlichen Werten:
    # 0.9 auf der Diagonale, Rest gleich verteilt
    def fix_P(P0):
        P0 = np.array(P0, dtype=np.float64)
        for i in range(K):
            if not np.isfinite(P0[i, :]).all() or (P0[i, :] == 0).any():
                P0[i, :] = 0.1 / (K - 1)
                P0[i, i] = 0.9
        return P0

    # Zweite Start-Übergangsmatrix je Familie: 0.99 auf der Diagonale, Rest gleich verteilt
    P99 = np.full((K, K), 0.01 / (K - 1))
    for i in range(K):
        P99[i, i] = 0.99
    # Festes Raster (alpha, [gamma], beta), omega über Varianz-Targeting
    grid = ([(0.03, 0.06, 0.90), (0.05, 0.10, 0.82), (0.02, 0.04, 0.94)] if gjr
            else [(0.05, 0.0, 0.90), (0.10, 0.0, 0.85), (0.03, 0.0, 0.95)])

    # Bester Startpunkt einer Familie (Varianzen s2k aufsteigend, Start-Übergangsmatrix P0):
    # Raster mit P0, danach Raster mit P99; höchste Log-Likelihood, bei Gleichstand der erste Punkt
    def best_start(s2k, P0):
        par0 = None
        best = math.inf
        s2k = np.asarray(s2k, dtype=np.float64)
        for Pst in (P0, P99):
            for g in grid:
                al = np.full(K, g[0])
                ga = np.full(K, g[1])
                be = np.full(K, g[2])
                om = s2k * (1 - g[0] - g[1] / 2 - g[2])
                p = _ms_garch_pack(om, al, be, ga, Pst, gjr)
                v = nll(p)
                if par0 is None or v < best:
                    par0 = p
                    best = v
        return par0

    starts = []
    # Familie 1 (HMM-Start): volles Baum-Welch-EM des Gauss'schen HMM auf y wie in
    # regime_hmm (Startwert aus der Rangeinteilung der rollierenden Volatilität,
    # 21 Tage), Zustände aufsteigend nach Varianz; bei Abbruch nur Familie 2
    X = y.reshape(-1, 1)
    ridge = np.eye(1) * (1e-10 + 1e-6 * r_mean([r_var(X[:, 0])]))
    try:
        hm = R._hmm_em(X, K, R._hmm_init_rank(X, K, 21, ridge), 300, 1e-7, ridge)
    except Exception:  # noqa: BLE001 - tryCatch(..., error = function(e) NULL)
        hm = None
    if hm is not None:
        s2h = np.array([float(np.asarray(s)[0, 0]) for s in hm["S"]])
        A = np.asarray(hm["A"], dtype=np.float64)
        if np.isfinite(s2h).all() and (s2h > 0).all() and np.isfinite(A).all():
            o = np.asarray(st.order(s2h), dtype=np.int64) - 1
            starts.append(best_start(s2h[o], fix_P(A[np.ix_(o, o)])))
    # Familie 2 (Rang-Start): Regime aus Quantilen der rollierenden Volatilität (wie
    # .prepare_regime_info; .rolling_vol erwartet Brutto-Renditen), Varianz je Regime aufsteigend
    vol = _core.rolling_vol(y + 1, 21)
    th = np.asarray(st.quantile(vol, _seq01(K + 1), names=False, type=7), dtype=np.float64).ravel()
    th[-1] = th[-1] + 1e-10
    reg0 = _core.assign_regimes(vol, th)
    P0 = fix_P(_core.estimate_trans_mat(reg0, K))
    s2k = []
    for k in range(1, K + 1):
        i = np.flatnonzero(reg0 == k)
        s2k.append(h1 if len(i) < 30 else r_var(y[i]))
    s2k = np.array(s2k, dtype=np.float64)
    s2k = np.sort(s2k[~np.isnan(s2k)], kind="stable")
    starts.append(best_start(s2k, P0))
    # Optimierung (BFGS mit numerischem Gradienten, ohne Hesse-Matrix) von jedem
    # Startpunkt; genommen wird die höchste Log-Likelihood, bei Gleichstand der
    # erste Lauf (HMM-Start vor Rang-Start)
    o = None
    for par0 in starts:
        oi = st.optim(par0, nll, method="BFGS", control={"maxit": 500, "reltol": 1e-10})
        if o is None or float(oi["value"]) < float(o["value"]):
            o = oi
    oval = float(o["value"])
    opar = np.asarray(o["par"], dtype=np.float64).ravel()
    conv = int(o["convergence"])
    if not math.isfinite(oval) or oval >= 1e10 or not np.isfinite(opar).all():
        raise ValueError("Log-Likelihood nicht endlich (optim-Code %d)." % conv)
    # Identifikation: Regime aufsteigend nach unbedingter Varianz
    m = _ms_garch_unpack(opar, K, gjr)
    with np.errstate(all="ignore"):
        unc = m["omega"] / (1 - m["alpha"] - m["gamma"] / 2 - m["beta"])
    ord_ = np.asarray(st.order(unc), dtype=np.int64) - 1
    om = m["omega"][ord_]
    al = m["alpha"][ord_]
    be = m["beta"][ord_]
    ga = m["gamma"][ord_]
    P = m["P"][np.ix_(ord_, ord_)]
    # Letzter Filterlauf mit den sortierten Parametern
    xi0 = _ms_garch_stat(P)
    f = _core.ms_garch_filter(y, om, al, be, ga, P, xi0, h1)
    if not math.isfinite(f["loglik"]):
        raise ValueError("Log-Likelihood nicht endlich (letzter Filterlauf).")
    with np.errstate(all="ignore"):
        s2 = f["pred"][:, 0] * f["h"][:, 0]
        for k in range(1, K):
            s2 = s2 + f["pred"][:, k] * f["h"][:, k]
    regimes = R._hmm_viterbi(f["lB"], _libm.log(P), _libm.log(xi0))
    return {"omega": om, "alpha": al, "beta": be, "gamma": ga, "P": P,
            "regimes": np.asarray(regimes, dtype=np.int64), "s2": s2, "loglik": float(f["loglik"]),
            "convergence": conv}


# Rechnen mit NA (signalisierendes NaN) ohne numpy-Warnung "invalid value" wie in R (gemeinsamer Helfer)
from ._r.base import quiet_fp  # noqa: E402

quiet_fp(globals(), ["_ms_garch_check", "_ms_garch_stat", "_ms_garch_unpack", "_ms_garch_pack", "_ms_garch_fit"])
