"""Regime-Erkennung mit einem Gauss'schen Hidden-Markov-Modell (Gegenstück zu ``r/R/regimes.R``).

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
from ._r.rnum import r_mean, r_rowsums, r_sd, r_var
from ._util import _cov2cor
from ._util import _which_max

__all__ = ["regime_hmm", "regime_states", "SimLevHMM"]

_NAN = float("nan")      # R's NaN
_NA = _fmt.NA_REAL       # R's NA_real_


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


def _hmm_em(X, k, init, max_iter, tol, ridge):
    """Baum-Welch-EM des Gauss'schen HMM aus einem Startwert (``.hmm_em``).

    Args:
        X: Matrix Perioden x Spalten.
        k: Anzahl Zustände.
        init: dict ``mu`` (k x Spalten), ``S`` (Liste k Kovarianzmatrizen),
            ``A`` (Übergangsmatrix k x k); Startverteilung gleichverteilt.
        max_iter, tol: Höchstzahl Iterationen und relative Abbruchschranke
            (Abbruch, wenn sich die Log-Likelihood um weniger als
            ``tol * (1 + |logL|)`` ändert).
        ridge: Matrix, die jeder Kovarianzmatrix im M-Schritt zugeschlagen wird.

    Returns:
        dict ``mu``, ``S``, ``A``, ``p0``, ``ll``, ``filtered``, ``smoothed``,
        ``lB``, ``iter``; ``ll``, ``filtered``, ``smoothed`` und ``lB`` zu den
        gelieferten (zuletzt geschätzten) Parametern.
    """
    # E- und M-Schritte im Kern (core/research_core_impl.h, hmm_em; bis 1.4.3 hier in Python); ein Fehler dort
    # verwirft wie in R den Startwert (regime_hmm fängt ihn ab)
    ni = int(max_iter)                     # max_iter = 0: nur der E-Schritt zum Startwert
    if ni < 0:                             # R: seq_len(max_iter) scheitert
        raise ValueError("argument of length 0")
    r = _core.hmm_em(np.asarray(X, dtype=np.float64), int(k), init["mu"], init["S"], init["A"], ni, float(tol), ridge)
    if r is None:
        raise ValueError("regime_hmm: EM-Schritt fehlgeschlagen")
    return r


def _hmm_init_cl(X, cl, k, ridge):
    """HMM-Startwert aus einer Einteilung der Perioden in k Gruppen (``.hmm_init_cl``).

    Mittelwert und Kovarianz (plus ``ridge``) je Gruppe, Übergangsmatrix 0.9
    auf der Diagonale, Rest gleich verteilt.
    """
    X = np.asarray(X, dtype=np.float64)
    cl = np.asarray(cl).ravel()
    k = int(k)
    with np.errstate(all="ignore"):
        mu = np.vstack([_dep._colmeans(X[cl == j + 1, :]) for j in range(k)])
        S = [np.asarray(_dep._stats().cov(X[cl == j + 1, :]), dtype=np.float64) + ridge for j in range(k)]
    off = 0.1 / max(1, k - 1)
    A = np.full((k, k), off) + np.eye(k) * (0.9 - off)
    return {"mu": mu, "S": S, "A": A}


def _hmm_init_rank(X, k, win, ridge):
    """Deterministischer HMM-Startwert (``.hmm_init_rank``).

    Rangeinteilung einer rollierenden Volatilität (Wurzel des gleitenden
    Mittelwerts von ``rowSums(X^2)`` über ``win`` Perioden; fehlende
    Anfangswerte = Median) in k gleich große Gruppen (``cut(rank(vol), k)``),
    daraus :func:`_hmm_init_cl`.
    """
    X = np.asarray(X, dtype=np.float64)
    with np.errstate(invalid="ignore"):   # NA am Rand (signalisierendes NaN) ohne Warnung wie in R
        vol = np.sqrt(_dep._roll_mean(r_rowsums(X * X), win))
    na = np.isnan(vol)
    if na.any():
        vol[na] = _dep._median(vol, na_rm=True)
    return _hmm_init_cl(X, _dep._cut_n(_dep._rank_avg(vol), k), k, ridge)


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

    # ``plot`` (SVG, ``SimLevPlot``) wird am Modulende über ``_plot_method`` gesetzt.


def _plot_hmm(x, data=None, width=900, height=380):
    """``plot.SimLevHMM`` (SVG): gefilterte Wahrscheinlichkeit des unruhigsten Zustands über der Zeit.

    Zeichnet wie Julia mit den Bausteinen der Rastergrafiken (``_grid_svg``, ``_grid_lines`` aus svg.py).
    ``data`` wird wie in R angenommen und nicht verwendet.
    Liefert ``(svg, data)``: ``filtered`` (``date``, ``probability``).
    """
    del data  # R plot.SimLevHMM(x, data = NULL, ...): data bleibt ungenutzt
    k = int(x["k"])
    top = np.asarray(x["filtered"], dtype=np.float64)[:, k - 1].copy()
    dates = np.asarray(x["dates"]).astype("datetime64[D]")
    data = {"filtered": pd.DataFrame({"date": dates, "probability": top})}
    lab = "P(Z%d | bis t)" % k
    p = _grid_svg(["p"], lambda _: (lambda c, box: _grid_lines(
        c, box, [(_dep._days(x["dates"]), top, "#B5562B", lab)], ylim=(0.0, 1.0), hline=[(0.5, "grey")], dates=True,
        ylabel=lab, title="Gefilterte Wahrscheinlichkeit des unruhigsten Zustands (Z%d)" % k)),
        width=width, height=height)
    return p.svg, data


def regime_hmm(data, columns, *, k=2, frequency=("week", "day", "month"), n_start=5, max_iter=300, tol=1e-7, seed=1):
    """Hidden-Markov-Modell für Marktregime.

    Gauß'sches HMM mit ``k`` Zuständen (eigener Mittelwert und eigene Kovarianzmatrix je Zustand) auf den
    Periodenrenditen der Spalten, geschätzt mit dem Baum-Welch-Algorithmus aus mehreren Startwerten. Die Zustände
    werden nach Volatilität sortiert (Zustand 1 = ruhigster). Für Handelsregeln und bedingte Analysen sind die
    **gefilterten** Wahrscheinlichkeiten maßgeblich - sie nutzen nur Daten bis zum jeweiligen Zeitpunkt;
    geglättete Wahrscheinlichkeiten und der Viterbi-Pfad verwenden die ganze Historie und dienen nur der
    Beschreibung.

    Args:
        data: DataFrame mit Spalte ``date`` (Date oder umwandelbar) und den Kursspalten (Niveaus, keine Renditen);
            fehlende Kurse werden fortgeschrieben. Das Argument ``data`` von ``plot()`` wird nicht verwendet.
        columns: Zeichenvektor der Kursspalten (eine oder mehrere; bei mehreren ein multivariates Modell mit
            Kovarianzmatrix je Zustand).
        k: Anzahl Zustände (ganze Zahl >= 2, Standard 2); es werden mindestens ``50 * k`` Perioden benötigt.
            Spalten ohne Schwankung (z. B. konstante Kurse) sind ein Fehler.
        frequency: Periodenlänge der Renditen: ``"week"`` (Standard, ISO-Wochen), ``"day"`` oder ``"month"``. Bei
            ``"day"`` entfallen Tage, an denen alle Renditen 0 sind (z. B. fortgeschriebene Wochenenden).
        n_start: Anzahl Startwerte (ganze Zahl, Standard 5): der erste aus Quantilen einer rollierenden
            Volatilität, die übrigen zufällig; es zählt das Ergebnis mit der höchsten Log-Likelihood.
        max_iter, tol: Höchstzahl Baum-Welch-Iterationen je Start (Standard 300) und relative Abbruchschranke:
            Abbruch, wenn sich die Log-Likelihood um weniger als ``tol * (1 + |logL|)`` ändert (Standard 1e-7).
        seed: Startwert (Standard 1) für die zufälligen Startzuordnungen (nur bei ``n_start > 1``). Mit Startwert
            (ganze Zahl, |seed| < 2^53) ist das Ergebnis reproduzierbar und der Zufallszustand von SimLev bleibt
            unverändert; mit ``None`` wird genau einmal ein Startwert aus dem Zufallszustand von SimLev gezogen
            (siehe ``simlev_seed()``), wiederholte Aufrufe liefern dann verschiedene Ergebnisse. ``set.seed()``
            wirkt nicht.

    Returns:
        Objekt der Klasse ``SimLevHMM``, eine Liste mit

        - ``transition``: Übergangsmatrix k x k (Zeile = von, Spalte = nach; Namen ``Z1``, ..., ``Zk``).
        - ``means``: Matrix Zustand x Spalte: mittlere Log-Rendite, annualisiert (mal ``ppy``), in Prozent p. a.
        - ``volatility``: Matrix Zustand x Spalte: Volatilität, annualisiert (mal √(ppy)), in Prozent p. a.
        - ``correlation``: Liste der Korrelationsmatrizen je Zustand.
        - ``filtered``, ``smoothed``: Matrizen Perioden x Zustand der gefilterten bzw. geglätteten
          Wahrscheinlichkeiten (Anteil).
        - ``viterbi``: wahrscheinlichster Zustandspfad (ganze Zahlen 1 bis k).
        - ``dates``: Perioden-Enddaten (eine je Zeile von ``filtered``).
        - ``columns``, ``k``, ``frequency``: Einstellungen.
        - ``loglik``, ``bic``: Log-Likelihood und BIC zu den gelieferten Parametern (nach dem letzten M-Schritt
          neu berechnet, ebenso ``filtered`` und ``smoothed``).
        - ``initial``: Startverteilung der Zustände (Anteile).
        - ``duration``: erwartete Dauer je Zustand in Perioden, 1 / (1 - p_jj).
        - ``ppy``: Perioden je Jahr, geschätzt als (Anzahl Perioden - 1) / (Zeitspanne in Tagen / 365.25).
        - ``share``: mittlere geglättete Wahrscheinlichkeit je Zustand (Anteil).

        ``print()`` fasst die Zustände zusammen, ``plot()`` zeichnet die gefilterte Wahrscheinlichkeit des
        unruhigsten Zustands.

    Details:
        Eingabe ist ein DataFrame mit Kursniveaus; geschätzt wird auf den Log-Renditen von Periodenende zu
        Periodenende. Die Zustände werden danach mit ``regime_states()`` auf einen Tageskalender gelegt, z. B. als
        Signal oder als Bedingung für ``regime_subset()`` und ``dependence_analysis()``.

    Quellen und Abweichungen:
        Angelehnt an Hamilton (1989): gefilterte Wahrscheinlichkeiten wie im Hamilton-Filter; abweichend:
        Gauß'sches HMM ohne autoregressiven Teil (eigener Mittelwert und eigene Kovarianzmatrix je Zustand),
        geschätzt mit dem EM-Verfahren nach Baum u. a. (1970) statt durch numerische Maximierung der Likelihood.
        Vorwärts-Rückwärts-Rekursion mit Skalierung, Neuschätzung der Startverteilung und Viterbi-Pfad nach
        Rabiner (1989) bzw. Viterbi (1967); BIC nach Schwarz (1978) mit k - 1 + k(k - 1) + kd + kd(d + 1)/2
        Parametern. Eigene Festlegungen von SimLev: Ridge-Zuschlag auf die Kovarianzmatrizen, Startwerte aus einer
        Rangeinteilung der rollierenden Volatilität und zufälligen Zuordnungen, Sortierung der Zustände nach
        Volatilität. Anwendung auf Regime-Allokation wie bei Nystrup u. a. (2015); abweichend werden die Parameter
        einmal auf der ganzen Historie geschätzt (dort adaptiv), die gefilterten Wahrscheinlichkeiten sind also
        nur bei gegebenen Parametern frei von Zukunftsinformation.

    Literatur:
        Hamilton, J. D. (1989), A new approach to the economic analysis of nonstationary time series and the
        business cycle, Econometrica 57(2), 357-384, doi:10.2307/1912559; Baum, L. E., Petrie, T., Soules, G. &
        Weiss, N. (1970), Annals of Mathematical Statistics 41(1), 164-171, doi:10.1214/aoms/1177697196; Rabiner,
        L. R. (1989), A tutorial on hidden Markov models and selected applications in speech recognition,
        Proceedings of the IEEE 77(2), 257-286, doi:10.1109/5.18626; Viterbi, A. J. (1967), IEEE Transactions on
        Information Theory 13(2), 260-269, doi:10.1109/TIT.1967.1054010; Schwarz, G. (1978), Estimating the
        dimension of a model, Annals of Statistics 6(2), 461-464, doi:10.1214/aos/1176344136; Nystrup, P., Hansen,
        B. W., Madsen, H. & Lindström, E. (2015), Regime-based versus static asset allocation: Letting the data
        speak, Journal of Portfolio Management 42(1), 103-109, doi:10.3905/jpm.2015.42.1.103.

    Beispiel::

        import numpy as np, pandas as pd, simlev
        rng = np.random.default_rng(1)
        n = 2920
        d = pd.DataFrame({"date": pd.date_range("2010-01-01", periods=n)})
        vol = np.resize(np.repeat([0.006, 0.02], [500, 200]), n)   # ruhig / turbulent
        d["aktien"] = 100 * np.exp(np.cumsum(rng.normal(2e-4, vol)))
        hmm = simlev.regime_hmm(d, "aktien", k=2)
        print(hmm["volatility"])
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
    win = int(max(4, float(_fmt.r_round(ppy / 12))))

    sl = _dep._sl()
    rs = sl.main_stream(seed) if n_start >= 2 else None   # Hauptstrom, nur bei Zufallsstarts
    inits = []
    for s in range(1, int(n_start) + 1):
        if s == 1:
            inits.append(_hmm_init_rank(X, k, win, ridge))
        else:
            inits.append(_hmm_init_cl(X, np.asarray(sl.sample(k, Tn, replace=True, stream=rs), dtype=np.int64), k, ridge))
    fits = []
    for i in inits:
        try:
            fits.append(_hmm_em(X, k, i, max_iter, tol, ridge))
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
    with np.errstate(divide="ignore"):            # p_jj = 1: Inf ohne Warnung wie R
        out["duration"] = pd.Series(1 / (1 - np.diag(A)), index=zn)
    out["frequency"] = frequency
    out["ppy"] = ppy
    out["share"] = _dep._colmeans(f["smoothed"][:, o])
    return out


def regime_states(x, dates, *, type=("filtered", "smoothed", "viterbi"), output=("state", "probability"),
                  state_prob=None, lag=1):
    """Regime auf einen Tageskalender legen.

    Ordnet jedem Tag den Zustand bzw. die Wahrscheinlichkeit zu, die zum Ende der letzten abgeschlossenen Periode
    (plus ``lag`` Tage) bekannt war. Mit ``type = "filtered"`` (Standard) enthält das Ergebnis keine
    Zukunftsinformation und kann als Signal oder Bedingung dienen.

    Args:
        x: Objekt der Klasse ``SimLevHMM`` aus ``regime_hmm()``.
        dates: Zieldaten: Date-Vektor (oder umwandelbar) oder DataFrame mit Spalte ``date``, z. B. derselbe
            Datensatz wie in ``regime_hmm()``.
        type: ``"filtered"`` (Standard), ``"smoothed"`` oder ``"viterbi"`` (die beiden letzten nutzen die ganze
            Historie - nur zur Beschreibung; es erscheint eine Warnung).
        output: ``"state"`` (Standard: Nummer 1 bis k des wahrscheinlichsten Zustands bzw. Viterbi-Zustand) oder
            ``"probability"`` (Wahrscheinlichkeit von ``state_prob`` als Anteil; nicht mit ``type = "viterbi"``).
        state_prob: Zustandsnummer (1 bis k) für ``output = "probability"``; Standard ``x["k"]``, der unruhigste
            Zustand.
        lag: Verzögerung in Kalendertagen (Standard 1): Der Wert einer Periode gilt ab Periodenende + ``lag``
            Tage; 0 = schon am Periodenende.

    Returns:
        Vektor mit einem Wert je Datum in ``dates``: ganze Zahlen (Zustand) bzw. Wahrscheinlichkeiten als Anteil;
        ``NA`` vor dem ersten Periodenende + ``lag``.

    Beispiel::

        import numpy as np, pandas as pd, simlev
        rng = np.random.default_rng(1)
        n = 2920
        d = pd.DataFrame({"date": pd.date_range("2010-01-01", periods=n)})
        vol = np.resize(np.repeat([0.006, 0.02], [500, 200]), n)
        d["aktien"] = 100 * np.exp(np.cumsum(rng.normal(2e-4, vol)))
        hmm = simlev.regime_hmm(d, "aktien", k=2)
        print(pd.Series(simlev.regime_states(hmm, d)).value_counts())
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


# plot.SimLevHMM (SVG, ``SimLevPlot``) wie Julias ``_plot_method(_plot_hmm, "SimLevHMM")``
from .svg import _grid_lines, _grid_svg, _plot_method  # noqa: E402

SimLevHMM.plot = _plot_method(_plot_hmm, "SimLevHMM")

# Rechnen mit NA (signalisierendes NaN) ohne numpy-Warnung "invalid value" wie in R (gemeinsamer Helfer)
from ._r.base import quiet_fp  # noqa: E402

quiet_fp(globals(), list(__all__) + ["_hmm_viterbi", "_hmm_em", "_hmm_init_cl", "_hmm_init_rank"])
