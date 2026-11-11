"""Eigene ML-Schätzung des MS-GARCH-Modells (Gegenstück zu ``r/R/ms_garch.R``).

Modell nach Haas, Mittnik und Paolella (2004): K Regime, je Regime ein
GARCH(1,1)- (``"sGARCH"``) oder GJR-GARCH(1,1)-Varianzpfad
(``"gjrGARCH"``); die Varianzpfade aller Regime laufen parallel;
Normalverteilung mit Mittelwert 0; Regimewechsel als Markov-Kette.
Likelihood über den Hamilton-Filter, Maximierung mit BFGS auf eigener
Parametrisierung auf R^p, deterministische Startwerte (kein Zufall): volles HMM-EM
und Rangeinteilung der Volatilität, je mit kleinem Raster. Seit 1.0.0
rechnet die Schätzung wie in R ganz in der C-Bibliothek slc
(:func:`simlev._lib.ms_garch_fit`); seit 1.0.0 entfallen der frühere Filter-Port und die
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
from ._pruefen import chk_stop

__all__: list[str] = []


def _ms_garch_check(K, model):
    """Varianzmodell und Regimezahl der MS-GARCH-Schätzung prüfen (``.ms_garch_check``)."""
    m = model
    if isinstance(m, (list, tuple, np.ndarray)):
        mv = list(np.asarray(m, dtype=object).ravel())
    else:
        mv = [m]
    ok_m = (len(mv) == 1 and isinstance(mv[0], str) and mv[0] in ("sGARCH", "gjrGARCH"))
    if not ok_m:
        chk_stop("b1.m_ms_garch_check")   # seit 1.6.4 ohne Wert
    kv = K if isinstance(K, (list, tuple, np.ndarray)) else [K]
    kv = list(np.asarray(kv, dtype=object).ravel())
    ok_k = (len(kv) == 1 and isinstance(kv[0], (int, float, np.integer, np.floating))
            and not isinstance(kv[0], (bool, np.bool_)))
    if ok_k:
        k0 = float(kv[0])
        ok_k = math.isfinite(k0) and k0 == float(_fmt.r_round(k0)) and 2 <= k0 <= 64   # seit 1.6.4 bis 64 (B-097)
    if not ok_k:
        chk_stop("b1.m_ms_garch_check_2")   # seit 1.6.4 ohne Wert
    return True


def _ms_garch_stat(P):
    """Stationäre Verteilung einer Übergangsmatrix (``.ms_garch_stat``).

    Seit 1.6.5 (CR2-M-1, Entscheidung 189) direkt im Kern gelöst (``sl_msgarch_stat``:
    LU von (I - P)' mit Einsenzeile; nur bei singulärem System die Potenziteration bis
    1.6.4 mit höchstens 1000 Schritten), wie R ``.sl_msgarch_stat``.
    """
    return np.asarray(_slm.msgarch_stat(np.asarray(P, dtype=np.float64)), dtype=np.float64)


def _ms_garch_fit(y, K, model, cores=1):
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

    Seit 1.0.0 wie R ganz in der C-Bibliothek slc (``_lib.ms_garch_fit``):
    Starts aus HMM-EM und Rangeinteilung, BFGS von allen Rasterpunkten beider Familien (sGARCH 12,
    gjrGARCH 20), mit analytischem Gradienten; GJR je Regime mit alpha + gamma >= 0,
    also auch gamma < 0. ``cores`` Threads für die Starts (Ergebnis unabhängig davon; Standard 1).
    """
    return _slm.ms_garch_fit(y, K, model, cores)


# Rechnen mit NA (signalisierendes NaN) ohne numpy-Warnung "invalid value" wie in R (gemeinsamer Helfer)
from ._r.base import quiet_fp  # noqa: E402

quiet_fp(globals(), ["_ms_garch_check", "_ms_garch_stat", "_ms_garch_fit"])
