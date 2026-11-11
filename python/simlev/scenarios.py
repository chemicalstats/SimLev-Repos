"""Szenarien mit eigenen Annahmen und Stresstests (Gegenstück zu ``r/R/scenarios.R``).

- :func:`scenario_entropy_pooling`   gewichtet Szenarien so um, dass sie eigene Annahmen
  ("Views") erfüllen, bei minimaler relativer Entropie (Meucci 2008)
- :func:`view_mean`, :func:`view_prob`, :func:`view_vol`   Bausteine für Annahmen
- :func:`scenario_copula`  Szenarien aus t- bzw. Gauss-Copula mit empirischen
  Rändern, optional unter Stress
- :func:`scenario_risk`     Portfolio-Kennzahlen auf (gewichteten) Szenarien
- :func:`scenario_crisis`     ein Portfolio durch historische Krisenfenster
"""
from __future__ import annotations

import math
import warnings
from collections.abc import Mapping

import numpy as np
import pandas as pd

from . import _ext
from . import dependence as _dep
from ._r import fmt as _fmt
from ._r.base import env_from_caller
from ._r import libm as _libm
from ._r.rlist import RList
from ._r.rnum import r_colsums, r_cummax, r_cumsum, r_cumprod, r_rowsums, r_sd, r_sum
from ._util import _is_num_scalar, _match_arg
from ._util import _cov2cor

__all__ = ["view_mean", "view_prob", "view_vol", "scenario_entropy_pooling", "scenario_copula", "scenario_risk",
           "scenario_crisis", "SimLevScenarios"]

_NAN = _fmt.NA_REAL      # R's NA_real_ (alle Verwendungen hier sind NA)


def _view_value(value, what, lo=-math.inf, hi=math.inf):
    """Zielwert einer Annahme prüfen (eine endliche Zahl, ggf. mit Bereich)."""
    a = np.atleast_1d(np.asarray(value, dtype=object)) if value is not None else np.zeros(0, dtype=object)
    ok = (a.size == 1 and _is_num_scalar(a[0]) and math.isfinite(float(a[0])) and lo <= float(a[0]) <= hi
          and not _dep.chk_is_factor(value))
    if not ok:
        if math.isfinite(lo) and math.isfinite(hi):
            rng = _fmt.sprintf(" zwischen %g und %g", lo, hi)
        elif math.isfinite(lo):
            rng = _fmt.sprintf(" >= %g", lo)
        else:
            rng = ""
        raise ValueError("%s: value muss eine endliche Zahl%s sein." % (what, rng))   # seit 1.6.4 ohne Wert
    return value


def view_mean(var, value, *, op=("=", "<=", ">=")):
    """Annahme an den Erwartungswert einer Spalte (Einheit der Spalte).

    Bausteine für die Annahmen ("Views") von ``scenario_entropy_pooling()``. Jede Funktion beschreibt nur die
    Annahme; geprüft und umgesetzt wird sie erst in ``scenario_entropy_pooling()`` auf der Szenario-Tabelle. Werte
    stehen in der Einheit der Szenario-Spalten: Bei Kursdaten sind das einfache Renditen in Prozent je Periode (-5
    = -5 %), Zustandsvariablen in ihrer eigenen Einheit.

    - view_mean: Erwartungswert einer Spalte (Rendite in Prozent je Periode oder Zustandsvariable in ihrer
      Einheit).
    - view_prob: Wahrscheinlichkeit eines Ereignisses, als Ausdruck über die Spalten (z. B. ``"aktien < -5"``).
    - view_vol: Standardabweichung einer Spalte (um ihren Erwartungswert unter der Ausgangsverteilung bzw. einer
      ``view_mean``-Annahme mit ``op = "="`` für dieselbe Spalte). Umgesetzt wird die Bedingung an das zweite
      Moment um diesen festen Wert; verschiebt sich der Mittelwert durch andere Annahmen, kann die
      Standardabweichung nach der Umgewichtung davon abweichen.

    Args:
        var: Spaltenname der Szenario-Tabelle (Zeichenkette, Anlage oder Zustandsvariable).
        value: Zielwert: bei ``view_mean`` und ``view_vol`` in der Einheit der Spalte (bei Kursdaten Prozent je
            Periode), bei ``view_prob`` eine Wahrscheinlichkeit als Anteil (0.2 = 20 %). Eine endliche Zahl; bei
            ``view_vol`` >= 0, bei ``view_prob`` zwischen 0 und 1 (sonst Fehler).
        op: Art der Bedingung: ``"="`` (Standard), ``"<="`` oder ``">="``.

    Returns:
        Liste mit ``type`` (``"mean"``, ``"prob"`` oder ``"vol"``), ``var`` bzw. ``expr``, ``value`` und ``op``.

    Beispiel::

        import numpy as np, pandas as pd, simlev
        rng = np.random.default_rng(1)
        X = pd.DataFrame({"aktien": rng.normal(0.15, 2, 1000), "anleihen": rng.normal(0.05, 0.6, 1000)})
        ep = simlev.scenario_entropy_pooling(X, ["aktien", "anleihen"], [simlev.view_mean("aktien", -0.2)])
        print(ep["summary"])
    """
    var = _dep.chk_name1(var, "view_mean", "var")              # seit 1.6.4 (K42 E4)
    v = _view_value(value, "view_mean")
    return {"type": "mean", "var": var, "value": v, "op": _match_arg(op, ("=", "<=", ">="))}


def view_prob(expr, value, *, op=("=", "<=", ">=")):
    """Annahme an die Wahrscheinlichkeit eines Ereignisses (Ausdruck in R-Syntax über die Spalten, z. B. ``"aktien < -2 & inflation > 2"``; siehe :mod:`simlev._r.rexpr`).

    Bausteine für die Annahmen ("Views") von ``scenario_entropy_pooling()``. Jede Funktion beschreibt nur die
    Annahme; geprüft und umgesetzt wird sie erst in ``scenario_entropy_pooling()`` auf der Szenario-Tabelle. Werte
    stehen in der Einheit der Szenario-Spalten: Bei Kursdaten sind das einfache Renditen in Prozent je Periode (-5
    = -5 %), Zustandsvariablen in ihrer eigenen Einheit.

    - view_mean: Erwartungswert einer Spalte (Rendite in Prozent je Periode oder Zustandsvariable in ihrer
      Einheit).
    - view_prob: Wahrscheinlichkeit eines Ereignisses, als Ausdruck über die Spalten (z. B. ``"aktien < -5"``).
    - view_vol: Standardabweichung einer Spalte (um ihren Erwartungswert unter der Ausgangsverteilung bzw. einer
      ``view_mean``-Annahme mit ``op = "="`` für dieselbe Spalte). Umgesetzt wird die Bedingung an das zweite
      Moment um diesen festen Wert; verschiebt sich der Mittelwert durch andere Annahmen, kann die
      Standardabweichung nach der Umgewichtung davon abweichen.

    Args:
        expr: Ereignis als Zeichenkette, ein R-Ausdruck über die Spaltennamen der Szenario-Tabelle, der einen
            logischen Wert je Szenario liefert (z. B. ``"aktien < -5 & inflation > 3"``).
            Seit 1.6.4 in R, Python und Julia gleich im gemeinsamen Ausdrucksumfang wie die Regeltexte von
            ``tactical_rules()``; auch eine Funktion der Szenario-Tabelle (Ergebnis ein Wert je Szenario).
        value: Zielwert: bei ``view_mean`` und ``view_vol`` in der Einheit der Spalte (bei Kursdaten Prozent je
            Periode), bei ``view_prob`` eine Wahrscheinlichkeit als Anteil (0.2 = 20 %). Eine endliche Zahl; bei
            ``view_vol`` >= 0, bei ``view_prob`` zwischen 0 und 1 (sonst Fehler).
        op: Art der Bedingung: ``"="`` (Standard), ``"<="`` oder ``">="``.

    Returns:
        Liste mit ``type`` (``"mean"``, ``"prob"`` oder ``"vol"``), ``var`` bzw. ``expr``, ``value`` und ``op``.

    Beispiel::

        import numpy as np, pandas as pd, simlev
        rng = np.random.default_rng(1)
        X = pd.DataFrame({"aktien": rng.normal(0.15, 2, 1000), "anleihen": rng.normal(0.05, 0.6, 1000)})
        ep = simlev.scenario_entropy_pooling(X, ["aktien", "anleihen"], [simlev.view_prob("aktien < -2", 0.15, op=">=")])
        print(ep["summary"])
    """
    if not callable(expr):                                     # Python: auch eine Funktion (wie bisher)
        expr = _dep.chk_name1(expr, "view_prob", "expr")       # seit 1.6.4 (K42 E4)
    v = _view_value(value, "view_prob", 0, 1)
    return {"type": "prob", "expr": expr, "value": v, "op": _match_arg(op, ("=", "<=", ">="))}


def view_vol(var, value, *, op=("=", "<=", ">=")):
    """Annahme an die Standardabweichung einer Spalte (Einheit der Spalte, >= 0).

    Bausteine für die Annahmen ("Views") von ``scenario_entropy_pooling()``. Jede Funktion beschreibt nur die
    Annahme; geprüft und umgesetzt wird sie erst in ``scenario_entropy_pooling()`` auf der Szenario-Tabelle. Werte
    stehen in der Einheit der Szenario-Spalten: Bei Kursdaten sind das einfache Renditen in Prozent je Periode (-5
    = -5 %), Zustandsvariablen in ihrer eigenen Einheit.

    - view_mean: Erwartungswert einer Spalte (Rendite in Prozent je Periode oder Zustandsvariable in ihrer
      Einheit).
    - view_prob: Wahrscheinlichkeit eines Ereignisses, als Ausdruck über die Spalten (z. B. ``"aktien < -5"``).
    - view_vol: Standardabweichung einer Spalte (um ihren Erwartungswert unter der Ausgangsverteilung bzw. einer
      ``view_mean``-Annahme mit ``op = "="`` für dieselbe Spalte). Umgesetzt wird die Bedingung an das zweite
      Moment um diesen festen Wert; verschiebt sich der Mittelwert durch andere Annahmen, kann die
      Standardabweichung nach der Umgewichtung davon abweichen.

    Args:
        var: Spaltenname der Szenario-Tabelle (Zeichenkette, Anlage oder Zustandsvariable).
        value: Zielwert: bei ``view_mean`` und ``view_vol`` in der Einheit der Spalte (bei Kursdaten Prozent je
            Periode), bei ``view_prob`` eine Wahrscheinlichkeit als Anteil (0.2 = 20 %). Eine endliche Zahl; bei
            ``view_vol`` >= 0, bei ``view_prob`` zwischen 0 und 1 (sonst Fehler).
        op: Art der Bedingung: ``"="`` (Standard), ``"<="`` oder ``">="``.

    Returns:
        Liste mit ``type`` (``"mean"``, ``"prob"`` oder ``"vol"``), ``var`` bzw. ``expr``, ``value`` und ``op``.

    Beispiel::

        import numpy as np, pandas as pd, simlev
        rng = np.random.default_rng(1)
        X = pd.DataFrame({"aktien": rng.normal(0.15, 2, 1000), "anleihen": rng.normal(0.05, 0.6, 1000)})
        ep = simlev.scenario_entropy_pooling(X, ["aktien", "anleihen"], [simlev.view_vol("anleihen", 0.8)])
        print(ep["summary"])
    """
    var = _dep.chk_name1(var, "view_vol", "var")               # seit 1.6.4 (K42 E4)
    v = _view_value(value, "view_vol", 0)
    return {"type": "vol", "var": var, "value": v, "op": _match_arg(op, ("=", "<=", ">="))}


def _scen_frame(x, assets, states, frequency, fn):
    """Szenario-Tabelle aus Daten (Renditen in Prozent je Periode, Zustände verzögert).

    Seit 1.6.4 vor der Rechnung geprüft (K42 E4, R ``.scen_frame``): Namen ohne NA, doppelte und ``'date'``, keine
    gemeinsame Spalte; Kursdaten wie ``_e4_data``, eine fertige Tabelle bzw. Matrix nur mit Zahlenspalten."""
    assets = _dep._e4_names(assets, fn, "assets")
    states = _dep._e4_names(states, fn, "states", null_ok=True)
    _dep._e4_disjoint(assets, states, fn, "assets", "states")
    cols = assets + (states or [])
    if isinstance(x, pd.DataFrame) and "date" in x.columns:
        _dep._e4_data(x, cols, fn)
    elif isinstance(x, pd.DataFrame):
        _dep.chk_cols(x, cols, fn)
        for k in cols:
            _dep._e4_numcol(x, k, fn)
    elif not (isinstance(x, np.ndarray) and x.ndim == 2 and x.dtype.kind in "fiu"):
        _dep.chk_stop("e4.szenarien", fn)
    if isinstance(x, pd.DataFrame) and "date" in x.columns:
        if len(x) < 2:
            _dep.chk_stop("e4.wenige", fn)                         # seit 1.6.4 (0 oder 1 Zeile)
        rd = _dep._dep_returns(x, assets, states, frequency)
        for a in _dep._as_names(assets):
            rd[a] = 100 * _libm.expm1(rd[a].to_numpy(dtype=np.float64))
        ok = _dep._complete_rows(*[rd[c].to_numpy() for c in rd.columns])
        if int(np.sum(ok)) < 2:
            _dep.chk_stop("e4.wenige", fn)
        return rd.loc[ok]
    if isinstance(x, pd.DataFrame):
        return x
    # sonst eine Zahlenmatrix (geprüft oben; seit 1.6.4 K43 T3-N10 ohne die unerreichbaren Zweige für dict und Vektor)
    a = np.asarray(x)
    return pd.DataFrame(a, columns=["V%d" % (j + 1) for j in range(a.shape[1])])


def _eval_expr(expr, S, env=None):
    """``as.numeric(eval(parse(text = expr), S, env))`` (R-Syntax über :mod:`simlev._r.rexpr`)."""
    from ._r import rexpr as _rexpr
    v = _dep._eval_condition(expr, S, env)
    return _rexpr.as_numeric(v) if isinstance(expr, str) else np.asarray(v)


class SimLevScenarios(RList):
    """Szenarien aus :func:`scenario_entropy_pooling` bzw. :func:`scenario_copula`."""

    r_class = ("SimLevScenarios",)

    def format(self):
        x = self
        fr = {"week": "Woche", "day": "Tag", "month": "Monat"}[x["frequency"]]
        lines = [_fmt.sprintf("SimLev-Szenarien (%s): %d Szenarien, effektiv %.0f, Renditen in %% je %s",
                              x["kind"], len(x["scenarios"]), float(x["effective_n"]), fr)]
        cop = x.get("copula")
        if cop is not None:
            st = x.get("stress")
            extra = ""
            if st:
                extra = ", Stress: " + "; ".join(_fmt.sprintf("%s in [%g, %g]", k, float(np.asarray(b, float)[0]),
                                                             float(np.asarray(b, float)[1])) for k, b in st.items())
            lines.append(_fmt.sprintf("Copula: %s, Freiheitsgrade %.1f%s", cop["family"], float(cop["df"]), extra))
        s = x["summary"]
        y = pd.DataFrame({"Variable": s["var"].to_numpy(dtype=object),
                          "Mittel vorher": _dep._sprintf_vec("%.3f", s["mean_prior"].to_numpy(dtype=np.float64)),
                          "Mittel nachher": _dep._sprintf_vec("%.3f", s["mean_post"].to_numpy(dtype=np.float64)),
                          "Sd vorher": _dep._sprintf_vec("%.3f", s["sd_prior"].to_numpy(dtype=np.float64)),
                          "Sd nachher": _dep._sprintf_vec("%.3f", s["sd_post"].to_numpy(dtype=np.float64))})
        lines.append(_fmt.print_data_frame(y, row_names=False))
        lines.append("\nKorrelation nachher")
        C = x["correlation"]
        if isinstance(C, pd.DataFrame):
            lines.append(_fmt.print_matrix(pd.DataFrame(_fmt.r_round(C.to_numpy(dtype=np.float64), 3),
                                                        index=C.index, columns=C.columns)))
        else:
            lines.append(_fmt.print_matrix(_fmt.r_round(np.asarray(C, dtype=np.float64), 3)))
        return "\n".join(lines)


@env_from_caller
def scenario_entropy_pooling(x, assets, views, *, states=None, frequency=("week", "day", "month"), prior=None, env=None):
    """Entropy Pooling: Szenarien auf eigene Annahmen umgewichten.

    Sucht die Szenario-Wahrscheinlichkeiten q, die alle Annahmen erfüllen und dabei der Ausgangsverteilung p
    (Standard: gleichgewichtete Historie) am nächsten kommen, min_q Σ_j q_j log(q_j / p_j)quadu. d. N. Aq = b, Gq
    ≤ h, Σ q = 1. Gelöst über das duale Problem (projizierter BFGS der C-Bibliothek von SimLev). Damit lassen sich
    Fragen stellen wie: "Wie sieht die gemeinsame Verteilung von Aktien und Anleihen aus, wenn die Inflation im
    Mittel 5 % beträgt?" - alle Abhängigkeiten bleiben aus der Historie erhalten, nur die Gewichte der Szenarien
    ändern sich. Sind die Annahmen nicht (genau genug) erfüllbar, gibt die Funktion eine Warnung aus.

    Args:
        x: DataFrame mit Spalte ``date`` (Date) und Kursspalten (Kursniveaus; Renditen werden gebildet) oder eine
            fertige Szenario-Tabelle (DataFrame oder Matrix ohne ``date``, z. B. simulierte Renditen).
        assets: Zeichenvektor der Anlagespalten (bei Kursdaten Kursspalten).
        views: Liste von Annahmen aus ``view_mean()``, ``view_prob()``, ``view_vol()``; eine leere Liste liefert
            die Ausgangsverteilung.
        states: Zeichenvektor der Zustandsspalten (z. B. Inflation, in ihrer eigenen Einheit), bei Kursdaten
            verzögert wie in ``dependence_analysis()``. ``None`` (Standard) = keine.
        frequency: Renditefrequenz bei Kursdaten: ``"week"`` (Standard, ISO-Woche), ``"day"`` oder ``"month"``;
            bei einer fertigen Tabelle nur Beschriftung.
        prior: Ausgangswahrscheinlichkeiten als numerischer Vektor mit einem Wert je Szenario (also je Zeile nach
            der Aufbereitung; andere Längen, negative oder nicht endliche Werte sind ein Fehler), wird auf Summe 1
            normiert. ``None`` (Standard) = gleichverteilt.
        env: Mapping für freie Variablen und Funktionen in den Ausdrücken von :func:`view_prob` (Voreinstellung:
            Namensraum des Aufrufers).

    Returns:
        Objekt der Klasse ``SimLevScenarios``, eine Liste mit ``scenarios`` (Szenario-Tabelle; bei Kursdaten mit
        ``date``, Renditen in Prozent je Periode und Zuständen), ``prob`` (neue Wahrscheinlichkeiten, Summe 1),
        ``prior``, ``effective_n`` (effektive Szenarioanzahl exp(H), H = Entropie von ``prob``), ``summary``
        (DataFrame je Anlage und Zustand: ``var``, ``mean_prior``, ``mean_post``, ``sd_prior``, ``sd_post``, in
        der Einheit der Spalte), ``correlation`` (Korrelationsmatrix der Anlagen nachher), ``assets``, ``states``,
        ``views``, ``frequency`` und ``kind`` (``"entropy_pooling"``). Methode ``print``.

    Details:
        Szenarien: Bei einem DataFrame mit Spalte ``date`` wird je Periode ein Szenario gebildet. Die Kurse werden
        wie in ``dependence_analysis()`` aufbereitet (Fortschreiben fehlender Werte, letzte Zeile je ISO-Woche
        bzw. Kalendermonat) und in einfache Renditen in Prozent je Periode umgerechnet, 100 (P_t / P_t-1 - 1);
        Zustandsspalten gehen mit dem Wert am Ende der Vorperiode ein, Perioden mit fehlenden Werten entfallen.
        Jede andere Eingabe wird unverändert als Szenario-Tabelle verwendet (eine Zeile je Szenario, Einheiten wie
        geliefert).

    Literatur:
        Meucci, A. (2008), Fully Flexible Views: Theory and Practice, Risk 21(10), 97-102.

    Beispiel::

        import numpy as np, pandas as pd, simlev
        rng = np.random.default_rng(1)
        X = pd.DataFrame({"aktien": rng.normal(0.15, 2, 1000), "anleihen": rng.normal(0.05, 0.6, 1000)})
        ep = simlev.scenario_entropy_pooling(X, ["aktien", "anleihen"], [simlev.view_mean("aktien", -0.2)])
        print(ep["summary"])
    """
    frequency = _match_arg(frequency, ("week", "day", "month"))
    fn = "scenario_entropy_pooling"
    if not (isinstance(views, (list, tuple)) and all(isinstance(v, Mapping) and isinstance(v.get("type"), str)
                                                     and v.get("type") in ("mean", "prob", "vol") for v in views)):
        _dep.chk_stop("e4.views", fn)                          # seit 1.6.4 (K42 E4)
    S = _scen_frame(x, assets, states, frequency, fn)
    assets = _dep._as_names(assets)
    states_l = _dep._as_names(states)
    Tn = len(S)
    if prior is not None:
        pa = np.atleast_1d(np.asarray(prior.to_numpy() if isinstance(prior, pd.Series) else prior))
        isnum = pa.dtype.kind in "fiu" and not _dep.chk_is_factor(prior)
        bad = (not isnum or pa.size != Tn)
        if not bad:
            pf = pa.astype(np.float64)
            bad = (not np.isfinite(pf).all()) or (pf < 0).any() or r_sum(pf) <= 0
        if bad:
            raise ValueError("scenario_entropy_pooling: prior muss %d endliche Werte >= 0 mit positiver Summe haben "
                             "(einer je Szenario)." % Tn)   # seit 1.6.4 ohne Wert
        p = pa.astype(np.float64)
    else:
        p = np.full(Tn, 1 / Tn)
    p = p / r_sum(p)
    vars_ = [v for v in dict.fromkeys(assets + states_l) if v in S.columns]
    cols = {v: S[v].to_numpy(dtype=np.float64) for v in vars_}
    m0 = {v: r_sum(p * cols[v]) for v in vars_}
    mean_view = {}
    views = list(views) if views is not None else []
    for v in views:
        if v["type"] == "mean" and v["op"] == "=":
            mean_view[v["var"]] = v["value"]
    rows = []
    for v in views:
        t = v["type"]
        if t == "mean":
            f = S[v["var"]].to_numpy(dtype=np.float64) if v["var"] in S.columns else None
        elif t == "prob":
            f = _eval_expr(v["expr"], S, env)
            f = np.atleast_1d(np.asarray(f, dtype=np.float64))
        elif t == "vol":
            if v["var"] in S.columns:
                mu = mean_view.get(v["var"], m0.get(v["var"], _NAN))
                if mu is None or (isinstance(mu, float) and math.isnan(mu)):
                    mu = m0.get(v["var"], _NAN)
                d = S[v["var"]].to_numpy(dtype=np.float64) - mu
                f = d * d
            else:
                f = np.zeros(0)
        else:
            raise ValueError("Unbekannter View-Typ.")
        if f is None or len(f) != Tn:
            raise ValueError("View '%s' passt nicht zu den Szenarien." % (v.get("var") if v.get("var") is not None else
                                                                          "<Funktion>" if callable(v.get("expr")) else v.get("expr")))
        if t == "vol" and not (_is_num_scalar(v["value"]) and v["value"] >= 0):
            raise ValueError("view_vol: Standardabweichung muss >= 0 sein.")
        val = float(v["value"]) * float(v["value"]) if t == "vol" else float(v["value"])
        sg = {"=": 0, "<=": 1, ">=": -1}[v["op"]]
        rows.append((-f if sg == -1 else f, -val if sg == -1 else val, sg != 0))
    la = _dep._sl()                        # slc-Matrixprodukt
    if not rows:
        q = p
    else:
        A = np.asfortranarray(np.vstack([r[0] for r in rows]))   # spaltenweise: crossprod/matmul ohne Kopie
        b = np.array([r[1] for r in rows], dtype=np.float64)
        ineq = np.array([r[2] for r in rows], dtype=bool)

        last = [None, None]   # fn und gr fragen denselben Punkt ab: Ergebnis einmal je Punkt (seit 1.5.2)

        def dual(l):
            l = np.asarray(l, dtype=np.float64)
            key = l.tobytes()
            if key == last[0]:
                return last[1]
            e = -np.asarray(la.crossprod(A, l.reshape(-1, 1)), dtype=np.float64).ravel()
            mx = _dep._rmax(e)
            w = p * _libm.exp(e - mx)
            Z = r_sum(w)
            # seit 1.6.4 (T3-N2) R-Logarithmus: Z = 0 (Prior mit Nullen) ergibt -Inf wie in R und Julia statt
            # "math domain error"
            with np.errstate(divide="ignore", invalid="ignore"):
                last[0], last[1] = key, (float(_libm.log(Z)) + mx + r_sum(l * b), w / Z)
            return last[1]

        def fn(l):
            return dual(l)[0]

        def gr(l):
            q_ = dual(l)[1]
            return b - np.asarray(la.matmul(A, q_.reshape(-1, 1)), dtype=np.float64).ravel()
        lower = np.where(ineq, 0.0, -math.inf)
        o = la.optim(np.zeros(b.size), fn, gr, method="L-BFGS-B", lower=lower,
                     control={"maxit": 5000, "factr": 1e3, "pgtol": 1e-12})   # projizierter BFGS (slc)
        q = dual(np.asarray(o["par"], dtype=np.float64))[1]
        viol = np.asarray(la.matmul(A, q.reshape(-1, 1)), dtype=np.float64).ravel() - b
        viol[ineq] = np.maximum(viol[ineq], 0)
        mv = _dep._rmax(np.abs(viol))
        if mv > 1e-4 * _dep._rmax(1, np.abs(b)):
            warnings.warn("Annahmen nicht vollständig erfüllbar (Abweichung %s)." % _fmt.sprintf("%.2e", mv))

    def wsd(v, w):
        m = r_sum(w * v)
        d = v - m
        return math.sqrt(r_sum(w * (d * d)))
    summ = pd.DataFrame({"var": vars_, "mean_prior": [m0[v] for v in vars_],
                         "mean_post": [r_sum(q * cols[v]) for v in vars_],
                         "sd_prior": [wsd(cols[v], p) for v in vars_], "sd_post": [wsd(cols[v], q) for v in vars_]})
    Xa = S[assets].to_numpy(dtype=np.float64)
    mu = r_colsums(Xa * q.reshape(-1, 1))
    C = np.asarray(la.crossprod((Xa - mu.reshape(1, -1)) * np.sqrt(q).reshape(-1, 1)), dtype=np.float64)
    Cc = np.asarray(_dep._stats().cov2cor(C), dtype=np.float64)
    Cc[np.isnan(Cc)] = np.nan               # arithmetisch entstanden: NaN (nicht NA) wie in R
    qp = q[q > 0]
    out = SimLevScenarios()
    out["scenarios"] = S
    out["prob"] = q
    out["prior"] = p
    out["assets"] = assets
    out["states"] = states
    out["views"] = views
    out["effective_n"] = _libm.exp(-r_sum(qp * _libm.log(qp)))
    out["summary"] = summ
    out["correlation"] = pd.DataFrame(Cc, index=assets, columns=assets)
    out["frequency"] = frequency
    out["kind"] = "entropy_pooling"
    return out


def _approx_fn(xg, yg):
    st = _dep._stats()

    def f(u):
        return np.asarray(st.approx(xg, yg, xout=np.asarray(u, dtype=np.float64), rule=2)["y"], dtype=np.float64)
    return f


def _matprod(A, B):
    """``A %m% B`` (slc-Matrixprodukt)."""
    return np.asarray(_dep._sl().matmul(np.asarray(A, dtype=np.float64), np.asarray(B, dtype=np.float64)),
                      dtype=np.float64)


def _chol(A):
    """``.sl_chol(A)`` (Cholesky der C-Bibliothek slc)."""
    return np.asarray(_dep._sl().chol(np.asarray(A, dtype=np.float64)), dtype=np.float64)


def _solve(A):
    """``.sl_solve_spd(A)``: Inverse einer symmetrisch positiv definiten Matrix."""
    return np.asarray(_dep._sl().solve_spd(np.asarray(A, dtype=np.float64)), dtype=np.float64)


def _rnorm_mat(m, k, stream):
    v = np.asarray(_dep._sl().rnorm(int(m * k), stream=stream), dtype=np.float64)
    return v.reshape((k, m)).T.copy()


def scenario_copula(x, assets, *, n=10000, family=("t", "gaussian"), stress=None, frequency=("week", "day", "month"),
                     seed=None):
    """Szenarien aus einer Copula mit empirischen Rändern.

    Passt eine t-Copula (oder Gauß-Copula) an die Periodenrenditen an: Korrelationsmatrix aus Kendalls Tau (ρ =
    sin(πτ/2)), Freiheitsgrade per Profil-Likelihood auf den Rängen, Ränder empirisch. Mit ``stress`` wird bedingt
    simuliert: Die genannten Anlagen werden in ein Quantilband gezwungen (z. B. Aktien in ihre schlechtesten 5 %
    der Wochen), die übrigen folgen der bedingten Copula-Verteilung - so zeigt sich, was die Abhängigkeitsstruktur
    für die anderen Anlagen in solchen Phasen erwarten lässt (einschließlich gemeinsamer Abstürze bei der
    t-Copula).

    Args:
        x: DataFrame mit Spalte ``date`` (Date) und Kursspalten (Kursniveaus) oder fertige Tabelle von
            Periodenrenditen ohne ``date``.
        assets: Zeichenvektor der Kurs- bzw. Renditespalten.
        n: Anzahl Szenarien (ganze Zahl, Standard 10000).
            Seit 1.6.4 höchstens 10^8.
        family: Copula: ``"t"`` (Standard) oder ``"gaussian"``.
        stress: Optional benannte Liste von Quantilbändern je Anlage als Anteile ``[von, bis]`` mit 0 <= von < bis
            <= 1, z. B. ``{"aktien": [0, 0.05]}`` (schlechteste 5 % der Perioden). Unbenannte Einträge, unbekannte
            Anlagen und ungültige Bänder sind ein Fehler. ``None`` (Standard) = unbedingte Simulation.
        frequency: Renditefrequenz bei Kursdaten: ``"week"`` (Standard, ISO-Woche), ``"day"`` oder ``"month"``.
        seed: Startwert der Ziehung. Mit Startwert (ganze Zahl, |seed| < 2^53) ist das Ergebnis reproduzierbar und
            der Zufallszustand von SimLev bleibt unverändert; mit ``None`` wird genau einmal ein Startwert aus dem
            Zufallszustand von SimLev gezogen (siehe ``simlev_seed()``), wiederholte Aufrufe liefern dann
            verschiedene Ergebnisse. ``set.seed()`` wirkt nicht.

    Returns:
        Objekt der Klasse ``SimLevScenarios`` mit ``scenarios`` (DataFrame mit ``n`` Zeilen, eine Spalte je
        Anlage, in der Einheit der Eingangsrenditen, bei Kursdaten Prozent je Periode), ``prob`` und ``prior`` (je
        1 / n), ``effective_n`` (= n), ``copula`` (Liste: ``family``, ``correlation``, ``df``; ``Inf`` bei
        ``"gaussian"``), ``stress``, ``summary`` (``var``, ``mean_prior``, ``sd_prior`` der Historie,
        ``mean_post``, ``sd_post`` der Szenarien), ``correlation`` (Pearson-Korrelation der Szenarien),
        ``assets``, ``frequency``, ``kind`` (``"copula"``). Methode ``print``; weiter mit ``scenario_risk()``.

    Details:
        Die Periodenrenditen werden wie bei ``scenario_entropy_pooling()`` gebildet (einfache Renditen in Prozent
        je Periode aus Kursdaten; eine fertige Tabelle ohne ``date`` wird unverändert verwendet). Die Ränder sind
        die empirischen Quantilfunktionen mit linearer Interpolation; simulierte Werte liegen daher nie außerhalb
        der historischen Spannweite. Die Freiheitsgrade werden im Bereich 2.1 bis 100 gesucht. Bei einer Anlage in
        ``stress`` wird ihr Quantil gleichverteilt im Band gezogen; bei mehreren werden deren Werte gemeinsam aus
        der Copula gezogen und nur Ziehungen behalten, die in allen Bändern liegen (Verwerfungsverfahren, exakt
        bedingt; bei einer gemeinsamen Trefferquote, die nach 5e7 Ziehungen keine ``n`` Treffer liefert, bricht
        die Funktion ab).

    Beispiel::

        import numpy as np, pandas as pd, simlev
        rng = np.random.default_rng(1)
        n = 1095
        d = pd.DataFrame({"date": pd.date_range("2015-01-01", periods=n)})
        e = rng.normal(size=n)
        d["aktien"] = 100 * np.cumprod(1 + 0.01 * e)
        d["anleihen"] = 100 * np.cumprod(1 + 0.004 * (0.3 * e + rng.normal(size=n)))
        cs = simlev.scenario_copula(d, ["aktien", "anleihen"], n=2000, stress={"aktien": [0, 0.05]}, seed=1)
        print(simlev.scenario_risk(cs, {"aktien": 0.6, "anleihen": 0.4}))
    """
    family = _match_arg(family, ("t", "gaussian"))
    frequency = _match_arg(frequency, ("week", "day", "month"))
    fn = "scenario_copula"
    n = int(_dep._e4_count(n, fn, "n"))                        # B-026, Entscheidung 16
    S = _scen_frame(x, assets, None, frequency, fn)
    assets = _dep._as_names(assets)
    X = S[assets].to_numpy(dtype=np.float64)
    Tn, k = X.shape
    U = np.column_stack([_dep._pobs(X[:, j]) for j in range(k)])
    tau = np.asarray(_dep._kendall(pd.DataFrame(X, columns=assets)), dtype=np.float64)
    R = np.asarray(_libm.sin(math.pi * tau / 2), dtype=np.float64)   # sin(pi tau / 2) (bis 1.6.3 als _PI_HALF_FACTOR)
    named = True
    la = _dep._sl()
    ev = la.eigen_sym(R)
    vals = np.asarray(ev["values"], dtype=np.float64)
    if _dep._rmin(vals) < 1e-6:
        V = np.asarray(ev["vectors"], dtype=np.float64)
        R = _matprod(_matprod(V, np.diag(np.maximum(vals, 1e-6))), V.T)
        R = _cov2cor(R)
        named = False
    Ri = _solve(R)
    ldR = float(la.logdet_spd(R))
    nm = _dep._sl()                        # Verteilungen der C-Bibliothek slc

    def ll_t(nu):
        Z = np.asarray(nm.qt(U, nu), dtype=np.float64).reshape(U.shape)
        qv = r_rowsums(_matprod(Z, Ri) * Z)
        c0 = (_dep._lgamma((nu + k) / 2) + (k - 1) * _dep._lgamma(nu / 2) - k * _dep._lgamma((nu + 1) / 2) - 0.5 * ldR)
        terms = c0 - (nu + k) / 2 * _libm.log1p(qv / nu) + (nu + 1) / 2 * r_rowsums(_libm.log1p(Z * Z / nu))
        return r_sum(terms)
    # nu seit 1.6.0 im Kern (sl_tcop_nu, qt auf mehreren Threads); bei einer nicht endlichen Auswertung oder einer
    # Warnung von qt wie bisher (gleiche Meldungen)
    nu = math.inf
    if family == "t":
        nk = _ext.slc_tcop_nu(np.ascontiguousarray(np.asarray(U, dtype=np.float64).T),
                              np.ascontiguousarray(np.asarray(Ri, dtype=np.float64).T), int(k), float(ldR), 2.1, 100.0,
                              0.0001220703125, _dep._sl().nthreads()) if np.ndim(U) == 2 and np.shape(Ri) == (k, k) else None
        nu = nk if nk is not None else _dep._optimize(lambda v: -ll_t(v), 2.1, 100)[0]
    grid = (np.arange(1, Tn + 1) - 0.5) / Tn
    qmarg = [_approx_fn(grid, np.sort(X[:, j])) for j in range(k)]
    if stress is not None:
        if (not isinstance(stress, Mapping) or not len(stress) or any(str(nm_) == "" for nm_ in stress.keys())):
            raise ValueError("stress: benannte Liste von Quantilbändern je Anlage erwartet, z. B. list(aktien = c(0, 0.05)).")
        unk = [a for a in stress.keys() if a not in assets]
        if unk:
            raise ValueError("stress: unbekannte Anlage(n) %s; vorhanden: %s." % (", ".join("'%s'" % u for u in unk), ", ".join(assets)))
        for a, b in stress.items():
            ba = np.atleast_1d(np.asarray(b, dtype=object))
            good = (ba.size == 2 and all(_is_num_scalar(v) for v in ba) and all(math.isfinite(float(v)) for v in ba)
                    and float(ba[0]) >= 0 and float(ba[1]) <= 1 and float(ba[0]) < float(ba[1]))
            if not good:
                raise ValueError("stress: Band für '%s' muss c(von, bis) mit 0 <= von < bis <= 1 sein (Anteile, keine "
                                 "Prozent)." % a)   # seit 1.6.4 ohne Wert
    rng = _dep._sl()

    def draw(rs):
        st = [] if stress is None else [assets.index(a) for a in stress.keys()]
        Z = np.zeros((n, k))
        fin = math.isfinite(nu)
        if len(st) == 1:
            band = [float(v) for v in np.asarray(list(stress.values())[0], dtype=np.float64)]
            u = np.asarray(rng.runif(n, band[0], band[1], stream=rs), dtype=np.float64)
            Z[:, st[0]] = np.asarray(nm.qt(u, nu) if fin else nm.qnorm(u), dtype=np.float64)
        elif len(st) > 1:
            ks = len(st)
            Ls = _chol(R[np.ix_(st, st)])
            lo = np.array([float(np.asarray(b, float)[0]) for b in stress.values()])
            hi = np.array([float(np.asarray(b, float)[1]) for b in stress.values()])
            parts = []
            nz = 0
            drawn = 0.0
            m = 100000
            while True:
                E = _matprod(_rnorm_mat(m, ks, rs), Ls)
                if fin:
                    E = E / np.sqrt(np.asarray(rng.rchisq(m, nu, stream=rs), dtype=np.float64) / nu).reshape(-1, 1)
                Ub = np.asarray(nm.pt(E, nu) if fin else nm.pnorm(E), dtype=np.float64).reshape(E.shape)
                hit = ((Ub >= lo.reshape(1, -1)) & (Ub <= hi.reshape(1, -1))).sum(axis=1) == ks
                parts.append(E[hit, :])
                nz += int(hit.sum())
                drawn += m
                if nz >= n:
                    break
                if drawn >= 5e7:
                    raise ValueError("stress: Bänder gemeinsam zu unwahrscheinlich (Trefferquote %s bei %s Ziehungen); "
                                     "Bänder erweitern oder weniger Anlagen stressen."
                                     % (_fmt.sprintf("%.1e", nz / drawn), _fmt.sprintf("%.0e", drawn)))
                m = int(min(1e6, max(1e5, math.ceil(1.2 * (n - nz) / max(nz / drawn, 1e-7)))))
            Zs = np.vstack(parts)
            Z[:, st] = Zs[:n, :]
        if st:
            rest = [j for j in range(k) if j not in st]
            if rest:
                Rss = R[np.ix_(st, st)]
                Rrs = R[np.ix_(rest, st)]
                Rss_i = _solve(Rss)
                RR = _matprod(Rrs, Rss_i)
                M = _matprod(Z[:, st], RR.T)
                Sc = R[np.ix_(rest, rest)] - _matprod(RR, Rrs.T)
                L = _chol(Sc + np.eye(len(rest)) * 1e-12)
                E = _matprod(_rnorm_mat(n, len(rest), rs), L)
                if fin:
                    Zst = Z[:, st]
                    dq = r_rowsums(_matprod(Zst, Rss_i) * Zst)
                    ns = len(st)
                    chi = np.asarray(rng.rchisq(n, nu + ns, stream=rs), dtype=np.float64)
                    scale = np.sqrt((nu + dq) / (nu + ns) / (chi / (nu + ns)))
                    Z[:, rest] = M + E * scale.reshape(-1, 1)
                else:
                    Z[:, rest] = M + E
        else:
            Z = _matprod(_rnorm_mat(n, k, rs), _chol(R))
            if fin:
                Z = Z / np.sqrt(np.asarray(rng.rchisq(n, nu, stream=rs), dtype=np.float64) / nu).reshape(-1, 1)
        return Z
    sim = draw(rng.main_stream(seed, "scenario_copula"))              # Hauptstrom
    if math.isfinite(nu):
        V = np.asarray(nm.pt(sim, nu), dtype=np.float64).reshape(sim.shape)
    else:
        V = np.asarray(nm.pnorm(sim), dtype=np.float64).reshape(sim.shape)
    Y = np.column_stack([qmarg[j](V[:, j]) for j in range(k)]) if k else np.zeros((n, 0))
    out_df = pd.DataFrame(Y, columns=assets)
    out = SimLevScenarios()
    out["scenarios"] = out_df
    out["prob"] = np.full(n, 1 / n)
    out["prior"] = np.full(n, 1 / n)
    out["assets"] = assets
    out["states"] = None
    out["effective_n"] = n
    out["copula"] = {"family": family, "correlation": pd.DataFrame(R, index=assets, columns=assets) if named else R,
                     "df": nu}
    out["stress"] = stress
    out["summary"] = pd.DataFrame({"var": assets, "mean_prior": _dep._colmeans(X), "mean_post": _dep._colmeans(Y),
                                   "sd_prior": [r_sd(X[:, j]) for j in range(k)],
                                   "sd_post": [r_sd(Y[:, j]) for j in range(k)]})
    out["correlation"] = pd.DataFrame(_dep._cormat(Y), index=assets, columns=assets)
    out["frequency"] = frequency
    out["kind"] = "copula"
    return out



def _named_weights(weights):
    if isinstance(weights, pd.Series):
        return [str(i) for i in weights.index], weights.to_numpy()
    if isinstance(weights, Mapping):
        return [str(k) for k in weights.keys()], np.array(list(weights.values()), dtype=object)
    return None, np.atleast_1d(np.asarray(weights))


def _isnum_arr(a):
    a = np.asarray(a)
    if a.dtype.kind in "fiu":
        return True
    if a.dtype == object:
        return all(_is_num_scalar(v) for v in a)
    return False


def scenario_risk(x, weights, *, alpha=0.05):
    """Portfolio-Kennzahlen auf Szenarien (gewichtet mit ``x.prob``).

    Berechnet die Portfoliorendite r_j = Σ_i w_i X_ji je Szenario und daraus Kennzahlen, gewichtet mit den
    Szenario-Wahrscheinlichkeiten ``x["prob"]`` (z. B. nach ``scenario_entropy_pooling()``). Quantile sind die
    kleinste Szenariorendite, bei der die kumulierte Wahrscheinlichkeit den Wert erreicht. Der CVaR ist der
    erwartete Verlust in der Wahrscheinlichkeitsmasse ``alpha`` der schlechtesten Szenarien (Rockafellar & Uryasev
    2002): Szenarien unterhalb des VaR zählen voll, das Grenzszenario (das den VaR bestimmt) mit dem Teil seiner
    Wahrscheinlichkeit, der die Masse auf ``alpha`` auffüllt. Damit ist der CVaR kohärent und fällt monoton in
    ``alpha``.

    Args:
        x: Objekt der Klasse ``SimLevScenarios`` aus ``scenario_entropy_pooling()`` oder ``scenario_copula()``.
        weights: Benannter Gewichtsvektor (Anteile, Namen = Anlagespalten der Szenarien); wird nicht normiert.
        alpha: Tail-Wahrscheinlichkeit als Anteil für VaR und CVaR (Standard 0.05).

    Returns:
        Benannter numerischer Vektor: ``mean``, ``volatility``, ``var``, ``cvar`` (Verluste positiv), ``q05``,
        ``q50``, ``q95`` (Quantile der Portfoliorendite mit Vorzeichen) in der Einheit der Szenarien (bei
        Kursdaten Prozent je Periode) sowie ``prob_loss`` (Wahrscheinlichkeit einer negativen Rendite als Anteil 0
        bis 1).

    Literatur:
        Rockafellar, R. T. & Uryasev, S. (2002), Conditional value-at-risk for general loss distributions, Journal
        of Banking & Finance 26(7), 1443-1471.

    Beispiel::

        import numpy as np, pandas as pd, simlev
        rng = np.random.default_rng(1)
        X = pd.DataFrame({"aktien": rng.normal(0.15, 2, 1000), "anleihen": rng.normal(0.05, 0.6, 1000)})
        ep = simlev.scenario_entropy_pooling(X, ["aktien", "anleihen"], [simlev.view_mean("aktien", -0.2)])
        print(simlev.scenario_risk(ep, {"aktien": 0.6, "anleihen": 0.4}))
    """
    if not isinstance(x, SimLevScenarios):
        raise ValueError("x muss ein SimLevScenarios sein.")
    av = np.atleast_1d(np.asarray(alpha, dtype=object))
    if not (av.size == 1 and _is_num_scalar(av[0]) and math.isfinite(float(av[0])) and 0 < float(av[0]) < 1
            and not _dep.chk_is_factor(alpha)):                # seit 1.6.4 ohne Wert
        raise ValueError("scenario_risk: alpha muss ein Anteil echt zwischen 0 und 1 sein.")
    alpha = float(av[0])
    names, vals = _named_weights(weights)
    if (not _isnum_arr(vals) or names is None or not names or any(nm_ == "" for nm_ in names)
            or _dep.chk_is_factor(weights)):                   # seit 1.6.4 auch leer wie R (B-016)
        raise ValueError("scenario_risk: weights muss ein benannter numerischer Vektor sein (Namen = Anlagespalten der Szenarien).")
    if not np.isfinite(np.asarray(vals, dtype=np.float64)).all():
        _dep.chk_stop("e3.werte", "scenario_risk", "weights")   # seit 1.6.4 (B-026)
    if len(set(names)) < len(names):
        _dep.chk_stop("e2.doppelt", "scenario_risk", "weights")
    unk = [nm_ for nm_ in names if nm_ not in x["scenarios"].columns]
    if unk:
        raise ValueError("scenario_risk: unbekannte Anlage(n) %s." % ", ".join("'%s'" % u for u in dict.fromkeys(unk)))
    w = np.asarray(vals, dtype=np.float64)
    X = x["scenarios"][names].to_numpy(dtype=np.float64)
    q = np.asarray(x["prob"], dtype=np.float64)
    r = _matprod(X, w.reshape(-1, 1)).ravel()
    o = np.argsort(r, kind="stable")
    nan = np.isnan(r[o])
    o = np.concatenate([o[~nan], o[nan]])
    qo = q[o]
    ro = r[o]
    cw = r_cumsum(qo)   # C-Kern (cumsum in long double wie R)

    def qf(a):
        h = np.nonzero(cw >= a)[0]
        return float(ro[h[0]]) if h.size else _NAN
    var_a = -qf(alpha)
    prev = np.concatenate([[0.0], cw[:-1]])
    take = np.minimum(qo, np.maximum(0, alpha - prev))
    cvar = -r_sum(take * ro) / r_sum(take)
    m = r_sum(q * r)
    d = r - m
    return pd.Series({"mean": m, "volatility": math.sqrt(r_sum(q * (d * d))), "var": var_a, "cvar": cvar,
                      "q05": qf(0.05), "q50": qf(0.5), "q95": qf(0.95), "prob_loss": r_sum(q[r < 0])})


_DEFAULT_CRISES = pd.DataFrame({
    "crisis": ["Ölkrise 1973/74", "Schwarzer Montag 1987", "Dotcom 2000-02", "Finanzkrise 2007-09",
               "Eurokrise 2011", "Covid 2020", "Inflation/Zinsen 2022"],
    "start": np.array(["1973-01-11", "1987-08-25", "2000-03-24", "2007-10-09", "2011-04-29", "2020-02-19", "2022-01-03"],
                      dtype="datetime64[D]"),
    "end": np.array(["1974-10-03", "1987-12-04", "2002-10-09", "2009-03-09", "2011-10-03", "2020-03-23", "2022-10-12"],
                    dtype="datetime64[D]")})


def scenario_crisis(data, weights, *, crises=None, rebalance=False):
    """Portfolio durch historische Krisen führen.

    Rechnet ein heutiges Portfolio durch historische Krisenfenster (Standard: große Aktienkrisen von 1973 bis
    2022, Hoch bis Tief des US-Aktienmarkts) und meldet Rendite, maximalen Drawdown und die Erholungsdauer nach
    dem Fensterende, je Anlage und für das Portfolio. Das Fenster beginnt an der ersten Datenzeile ab ``start``
    und endet an der letzten Zeile bis ``end``; fehlende Kurse werden mit dem letzten Wert fortgeschrieben. Krisen
    außerhalb des Datenzeitraums (oder mit fehlendem Startkurs einer Anlage) werden übersprungen; liegt keine im
    Zeitraum, bricht die Funktion ab.

    Args:
        data: DataFrame mit Spalte ``date`` (Date) und Kursspalten (Kursniveaus, keine Renditen, positiv),
            typischerweise täglich. Die Zeilen werden nach ``date`` sortiert (mit Hinweis, falls nötig); fehlende
            oder doppelte Daten sind ein Fehler.
        weights: Benannter Gewichtsvektor (Namen = Kursspalten), wird auf Summe 1 normiert (Summe muss positiv
            sein; unbekannte Namen sind ein Fehler).
        crises: DataFrame mit ``crisis`` (Name), ``start``, ``end`` (Date). ``None`` (Standard) = eingebaute Liste
            (siehe oben).
        rebalance: Logisch: ``False`` (Standard, Kaufen und Halten ab Fensterbeginn) oder ``True`` (an jeder
            Datenzeile auf die Gewichte zurück).

    Returns:
        DataFrame je Krise im Datenzeitraum: ``crisis``, ``start``, ``end`` (tatsächlich verwendete Datenzeilen),
        ``portfolio`` (Portfoliorendite im Fenster in Prozent), ``max_drawdown`` (maximaler Drawdown des
        Portfolios im Fenster in Prozent, negativ), ``days_to_recover`` (Kalendertage ab Fensterende, bis der
        Kaufen-und-Halten-Wert des Portfolios (auch bei ``rebalance = True``) wieder den Wert bei Fensterbeginn
        erreicht; 0 = am Fensterende nicht darunter; ``NA`` = nicht erholt bzw. Daten enden) und je Anlage deren
        Rendite im Fenster in Prozent.

    Details:
        Eingebaute Krisen (``crises = None``): Ölkrise 1973/74 (1973-01-11 bis 1974-10-03), Schwarzer Montag 1987
        (1987-08-25 bis 1987-12-04), Dotcom 2000-02 (2000-03-24 bis 2002-10-09), Finanzkrise 2007-09 (2007-10-09
        bis 2009-03-09), Eurokrise 2011 (2011-04-29 bis 2011-10-03), Covid 2020 (2020-02-19 bis 2020-03-23),
        Inflation/Zinsen 2022 (2022-01-03 bis 2022-10-12).

    Beispiel::

        import numpy as np, pandas as pd, simlev
        rng = np.random.default_rng(1)
        n = 1460
        d = pd.DataFrame({"date": pd.date_range("2018-01-01", periods=n)})
        d["aktien"] = 100 * np.cumprod(1 + rng.normal(3e-4, 0.012, n))
        d["anleihen"] = 100 * np.cumprod(1 + rng.normal(1e-4, 0.003, n))
        kr = pd.DataFrame({"crisis": ["Test"], "start": pd.to_datetime(["2019-05-01"]), "end": pd.to_datetime(["2019-09-30"])})
        print(simlev.scenario_crisis(d, {"aktien": 0.6, "anleihen": 0.4}, crises=kr))
    """
    if crises is None:
        crises = _DEFAULT_CRISES
    if not isinstance(data, pd.DataFrame) or "date" not in data.columns:
        raise ValueError("scenario_crisis: data.frame mit Spalte 'date' erwartet.")
    if not isinstance(crises, pd.DataFrame) or not all(c in crises.columns for c in ("crisis", "start", "end")):
        raise ValueError("scenario_crisis: crises muss ein data.frame mit den Spalten crisis, start, end sein.")
    fn = "scenario_crisis"
    names, vals = _named_weights(weights)
    if (not _isnum_arr(vals) or names is None or not names or any(nm_ == "" for nm_ in names) or _dep.chk_is_factor(weights)
            or not np.isfinite(np.asarray(vals, dtype=np.float64)).all()):
        raise ValueError("scenario_crisis: weights muss ein benannter numerischer Vektor ohne NA sein (Namen = Kursspalten).")
    if len(set(names)) < len(names):
        _dep.chk_stop("e2.doppelt", fn, "weights")             # seit 1.6.4 (B-052)
    unk = [nm_ for nm_ in names if nm_ not in [c for c in data.columns if c != "date"]]
    if unk:
        raise ValueError("scenario_crisis: Kursspalte(n) %s fehlen in data." % ", ".join("'%s'" % u for u in dict.fromkeys(unk)))
    _dep.chk_col_nofactor(data, "date", fn)                    # seit 1.6.4 (Entscheidung 15, B-009)
    for k in names:
        _dep._e4_numcol(data, k, fn)
    for k in ("start", "end"):
        if _dep.chk_is_factor(crises[k]):
            _dep.chk_stop("spalte_faktor", fn, k)
    rebalance = _dep.chk_bool1(rebalance, fn, "rebalance")
    wv = np.asarray(vals, dtype=np.float64)
    sw = r_sum(wv)
    if sw <= 0:
        _dep.chk_stop("ut3.krise_summe", fn)                   # seit 1.6.4 ohne Wert und Zusatz (Entscheidung 8, T3-B2)
    data = _dep._dep_sort_dates(data)
    d = _dep._dates_arr(data["date"].to_numpy())
    dd = _dep._days(d)
    w = wv / sw
    cs = _dep._days(_dep._to_date(crises["start"], "scenario_crisis: crises$start"))
    ce = _dep._days(_dep._to_date(crises["end"], "scenario_crisis: crises$end"))
    P = np.column_stack([_dep._fill_na(_dep._dep_check_prices(_dep._num(data[a]), a, d), "locf", keep_leading=True)
                         for a in names])
    rows = []
    nd = dd.size
    for i in range(len(crises)):
        s_ = np.nonzero(dd >= cs[i])[0]
        e_ = np.nonzero(dd <= ce[i])[0]
        if not s_.size or not e_.size:
            continue
        s, e = int(s_[0]), int(e_[-1])
        if e <= s or np.isnan(P[s, :]).any():
            continue
        rel = P[s:e + 1, :] / P[s, :].reshape(1, -1)
        if rebalance:
            g = _matprod(rel[1:, :] / rel[:-1, :], w.reshape(-1, 1)).ravel()
            port = r_cumprod(np.concatenate([[1.0], g]))
        else:
            port = _matprod(rel, w.reshape(-1, 1)).ravel()
        cm = r_cummax(port)   # C-Kern; ohne NaN bitgleich zu np.maximum.accumulate (seit 1.6.4 ein Weg)
        ddn = _dep._rmin(port / cm - 1)
        if e < nd - 1:
            relx = P[e:, :] / P[s, :].reshape(1, -1)
            px = _matprod(relx, w.reshape(-1, 1)).ravel()
            kk = np.nonzero(px >= 1)[0]
            after = float(dd[e + kk[0]] - dd[e]) if kk.size else _NAN
        else:
            after = _NAN
        row = {"crisis": crises["crisis"].iloc[i], "start": d[s], "end": d[e], "portfolio": 100 * (port[-1] - 1),
               "max_drawdown": 100 * ddn, "days_to_recover": after}
        last = 100 * (rel[-1, :] - 1)
        for j, a in enumerate(names):
            row[a] = float(last[j])
        rows.append(row)
    if not rows:
        raise ValueError("Keine Krise liegt im Datenzeitraum.")
    out = pd.DataFrame(rows, columns=["crisis", "start", "end", "portfolio", "max_drawdown", "days_to_recover"] +
                       list(dict.fromkeys(names)))
    out["start"] = out["start"].to_numpy(dtype="datetime64[D]")
    out["end"] = out["end"].to_numpy(dtype="datetime64[D]")
    return out


# Rechnen mit NA (signalisierendes NaN) ohne numpy-Warnung "invalid value" wie in R (gemeinsamer Helfer)
from ._r.base import quiet_fp  # noqa: E402

quiet_fp(globals(), __all__)  # scenario_entropy_pooling: env aus dem Aufrufer (env_from_caller)
