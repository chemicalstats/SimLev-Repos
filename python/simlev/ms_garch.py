"""Eigene ML-Schätzung des MS-GARCH-Modells (Port von ``r/R/ms_garch.R``).

Modell nach Haas, Mittnik und Paolella (2004): K Regime, je Regime ein
GARCH(1,1)- (``"sGARCH"``) oder GJR-GARCH(1,1)-Varianzpfad
(``"gjrGARCH"``); die Varianzpfade aller Regime laufen parallel;
Normalverteilung mit Mittelwert 0; Regimewechsel als Markov-Kette.
Likelihood über den Hamilton-Filter, Maximierung mit BFGS auf eigener
Parametrisierung auf R^p, deterministische Startwerte (kein Zufall): volles HMM-EM
und Rangeinteilung der Volatilität, je mit kleinem Raster. Seit Etappe 9.6b
rechnet die Schätzung wie in R ganz in der C-Bibliothek slc
(:func:`simlev._lib.ms_garch_fit`); seit 9.6c entfallen der frühere Filter-Port und die
Umrechnung der Parameter (``_ms_garch_unpack``/``_pack``). Genutzt von ``bootstrap._prepare_ms_info`` für
die Verfahren ``"ms_garch"``, ``"ms_ar_garch_m"`` und ``"tvtp_ms_garch"``.

Wie in R sind Summen weniger Werte fortlaufende double-Additionen (nicht
``sum``, das in R in ``long double`` summiert). Nur interne Funktionen.
"""
from __future__ import annotations

import math

import numpy as np

from . import _lib_models as _slm
from ._r import fmt as _fmt

__all__: list[str] = []


def _stats():
    from ._r import stats
    return stats


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
    < 1e-12. ``pi_ %m% P`` in der Reihenfolge des slc-Matrixprodukts (je Element ab 0,0
    aufsteigend summiert, Entwurf B.6; bei nicht endlichen Werten ``_lib.matmul``).
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
            from . import _lib
            p2 = [float(v) for v in np.asarray(_lib.matmul(np.asarray(pi_), P), dtype=np.float64).ravel()]
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
        Log-Likelihood und Konvergenzcode des besten BFGS-Laufs.

    Seit Etappe 9.6b wie R ganz in der C-Bibliothek slc (``_lib.ms_garch_fit``, Entwurf B.13):
    Starts aus HMM-EM und Rangeinteilung, BFGS von allen Rasterpunkten beider Familien (sGARCH 12,
    gjrGARCH seit N1 20), seit N1 mit analytischem Gradienten; GJR je Regime mit alpha + gamma >= 0,
    also auch gamma < 0.
    """
    return _slm.ms_garch_fit(y, K, model)


# Rechnen mit NA (signalisierendes NaN) ohne numpy-Warnung "invalid value" wie in R (gemeinsamer Helfer)
from ._r.base import quiet_fp  # noqa: E402

quiet_fp(globals(), ["_ms_garch_check", "_ms_garch_stat", "_ms_garch_fit"])
