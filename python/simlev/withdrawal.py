"""Entnahme-Simulationen (Ruhestand / Decumulation), Gegenstück zu ``r/R/withdrawal.R``.

Öffentliche Funktionen:

- :func:`withdrawal_rule` – Regel-Objekt (14 Regeln)
- :func:`withdrawal_cohorts` – historische rollierende Kohorten (Bengen/Trinity)
- :func:`withdrawal_paths` – Periodenrenditen aus Bootstrap-Pfaden, Ergebnislisten
  oder Bootstrap-Studien
- :func:`result_index` – zeitgewichteter Wertindex eines Simulationsergebnisses
- :func:`withdrawal_simulation` – schneller Kern über viele Pfade, optional mit
  vereinfachter deutscher Besteuerung
- :func:`withdrawal_perfect_rate` – PWR nach Suarez, Suarez & Walz (2015)
- :func:`withdrawal_max_rate` – maximale Anfangsrate für eine Ziel-Erfolgsquote
- :func:`withdrawal_horizon` – Laufzeit der Entnahmephase

PROZENT-KONVENTION: rate, ceiling, floor, cut, raise, exp_return usw. in
Prozent (rate = 4 bedeutet 4 % p. a.), wie im restlichen Paket.
"""
from __future__ import annotations

import contextlib
import io
import math
import time
import warnings
from collections.abc import Mapping

import numpy as np
import pandas as pd

from . import _withdrawal_core as _wcore
from ._r import fmt as _fmt
from . import _lib as _sl
from ._r.rlist import RList
from ._r.rnum import r_rowsums, r_cumprod, r_mean_int, r_median, r_pow, r_pow_vec, r_prod, r_sum
from .bootstrap import (_quiet, _get, _is_boot_result, _is_num, _is_study, _keep_count, _message, _names, _num1, _num_vec,
                        _quantile7, _r_round0, _show, _sp, _stop, _strip1, _values, _warn, _weighted_mean,
                        _wquantile, summary, plot)
from ._util import _match_arg
from .data_prep import _to_date

__all__ = [
    "withdrawal_rule", "WithdrawalRule", "withdrawal_cohorts", "WithdrawalPaths", "result_index",
    "withdrawal_paths", "withdrawal_perfect_rate", "withdrawal_simulation", "SimLevWithdrawal",
    "SummarySimLevWithdrawal", "withdrawal_max_rate", "withdrawal_horizon", "SimLevHorizon", "summary", "plot",
]

_NAN = float("nan")      # R's NaN
_NA = _fmt.NA_REAL       # R's NA_real_

_WD_RULES = {"constant": 1, "percent": 2, "vanguard": 3, "guyton_klinger": 4, "floor_ceiling": 5, "clyatt": 6,
             "ratchet": 7, "endowment": 8, "one_over_n": 9, "vpw": 10, "abw": 11, "cape": 12, "sensible": 13,
             "hebeler": 14}

_WD_LABELS = {"constant": "Konstante reale Entnahme (Bengen/Trinity)",
              "percent": "Fester Prozentsatz des Depots",
              "vanguard": "Vanguard Dynamic Spending (Ceiling/Floor)",
              "guyton_klinger": "Guyton-Klinger-Entscheidungsregeln",
              "floor_ceiling": "Floor-and-Ceiling (Bengen 2001)",
              "clyatt": "Clyatt 95-%-Regel",
              "ratchet": "Kitces-Ratchet",
              "endowment": "Endowment-/Yale-Regel (Tobin)",
              "one_over_n": "1/N (Restlaufzeit)",
              "vpw": "Variable Percentage Withdrawal (Bogleheads)",
              "abw": "Amortisationsbasierte Entnahme (ABW)",
              "cape": "CAPE-basierte Regel",
              "sensible": "Sensible Withdrawals",
              "hebeler": "Hebeler Autopilot II"}

_DEF_IT = ("level", "rate_pa")
_DEF_FREQ = ("year", "quarter", "month")


class _Dflt(float):
    """Voreinstellung eines Arguments (für R's ``missing()``)."""

    def __repr__(self):
        return repr(float(self))


class _DfltTrue:
    """Voreinstellung ``TRUE`` (für R's ``missing()``)."""

    def __bool__(self):
        return True

    def __repr__(self):
        return "True"


_D_TRUE = _DfltTrue()


def _fmt1(x, **kw) -> str:
    r = _fmt.format(x, **kw)
    if isinstance(r, str):
        return r
    return ", ".join(str(s) for s in np.asarray(r, dtype=object).ravel())


def _fmt_nan(x, **kw) -> str:
    """``format()`` eines Rechenergebnisses: ``nan`` ist hier R's ``NaN`` (nicht NA)."""
    x = float(x)
    return _fmt1(math.nan if math.isnan(x) else x, **kw)


def _fmtv(x):
    """``format(x)`` eines Vektors -> Liste von Texten (gemeinsame Formatierung)."""
    r = _fmt.format(np.asarray(x, dtype=np.float64))
    if isinstance(r, str):
        return [r]
    return [str(s) for s in np.asarray(r, dtype=object).ravel()]


def _is_result(x) -> bool:
    try:
        from .result import SimLevResult
    except ImportError:  # pragma: no cover
        SimLevResult = ()
    return isinstance(x, SimLevResult) or "SimLevResult" in getattr(x, "r_class", ())


def _rget(x, name, default=None):
    """Element eines SimLevResult (Attribut, Schlüssel) oder ``default``."""
    v = None
    if isinstance(x, Mapping):
        v = x.get(name)
    else:
        v = getattr(x, name, None)
        if v is None:
            try:
                v = x[name]
            except (KeyError, TypeError, AttributeError, IndexError):
                v = None
    return default if v is None else v


def _dates_days(d):
    return np.asarray(d).astype("datetime64[D]").astype(np.int64)


def _ymd(d):
    a = np.asarray(d).astype("datetime64[D]")
    y = a.astype("datetime64[Y]").astype(np.int64) + 1970
    m = a.astype("datetime64[M]").astype(np.int64) % 12 + 1
    return y, m


def _pow_vec(x, y):
    """``x ^ y`` elementweise (Recycling), R-Semantik."""
    x = np.atleast_1d(np.asarray(x, dtype=np.float64)).ravel()
    y = np.atleast_1d(np.asarray(y, dtype=np.float64)).ravel()
    n = max(len(x), len(y)) if len(x) and len(y) else 0
    if n and len(y) == 1:
        return r_pow_vec(x, float(y[0]))      # gleiche Bits, schneller Weg
    x = np.resize(x, n)
    y = np.resize(y, n)
    return np.array([r_pow(a, b) for a, b in zip(x.tolist(), y.tolist())], dtype=np.float64)


def _apply_cols(M, f):
    """``apply(M, 2, f)``: Vektor bei Länge 1 je Spalte, sonst Matrix (Ergebnis x Spalten)."""
    res = [np.atleast_1d(np.asarray(f(M[:, j]), dtype=np.float64)) for j in range(M.shape[1])]
    if not res:
        return np.zeros(0)
    if all(len(r) == 1 for r in res):
        return np.array([r[0] for r in res])
    return np.column_stack(res)


def _vapply_mat(vecs, L):
    """``as.matrix(vapply(X, f, numeric(L)))`` (Länge 1 -> Spaltenvektor)."""
    if L == 1:
        return np.array([float(np.asarray(v).ravel()[0]) for v in vecs]).reshape(-1, 1)
    if not vecs:
        return np.zeros((L, 0))
    return np.column_stack([np.asarray(v, dtype=np.float64).ravel() for v in vecs])


def _as_matrix(x):
    """``as.matrix`` für Vektor/Matrix/DataFrame."""
    if isinstance(x, pd.DataFrame):
        return x.to_numpy(dtype=np.float64)
    a = np.asarray(x, dtype=np.float64)
    if a.ndim == 0:
        return a.reshape(1, 1)
    if a.ndim == 1:
        return a.reshape(-1, 1)
    return a


# ═══════════════════════════════════════════════════════════════════════════
# Regeln
# ═══════════════════════════════════════════════════════════════════════════

class WithdrawalRule(RList):
    """Entnahmeregel (R-Klasse ``c("withdrawal_rule", "list")``)."""

    r_class = ("withdrawal_rule", "list")

    def format(self) -> str:
        return _strip1(_cat_rule(self))


def _cat_rule(x) -> str:
    out = ["Entnahmeregel\n-------------\n", "  Typ:       %s (%s)\n" % (x["type"], _WD_LABELS[x["type"]])]
    if x["type"] not in ("one_over_n", "vpw", "abw", "cape", "hebeler"):
        out.append(_sp("  Rate:      %.2f %%\n", x["rate"]))
    t = x["type"]
    ex = ""
    if t == "vanguard":
        ex = _sp("  Ceiling/Floor (real): +%.2f %% / -%.2f %%\n", x["ceiling"], x["floor"])
    elif t == "guyton_klinger":
        ex = _sp("  Guardrails: +%.0f %% / -%.0f %%, Kürzung %.0f %%, Erhöhung %.0f %%, CPR bis %d J. vor Ende\n",
                 x["ceiling"], x["floor"], x["cut"], x["raise"], int(float(x["cpr_years"])))
    elif t == "floor_ceiling":
        ex = _sp("  Korridor:  -%.0f %% / +%.0f %% um reale Erstentnahme\n", x["floor"], x["ceiling"])
    elif t == "endowment":
        ex = _sp("  Glättung:  %.0f %%\n", x["smoothing"])
    elif t == "hebeler":
        ex = _sp("  Glättung:  %.0f %%, erwartete Realrendite %.2f %%\n", x["smoothing"], x["exp_return"])
    elif t == "vpw":
        ex = _sp("  Alter %d bis %d, erwartete Realrendite %.2f %%\n", int(float(x["age"])), int(float(x["max_age"])),
                 x["exp_return"])
    elif t == "abw":
        ex = _sp("  Erwartete Realrendite %.2f %%, Zielvermögen %.0f\n", x["exp_return"], x["fv"])
    elif t == "cape":
        ex = _sp("  Rate = %.2f %% + %.2f / CAPE\n", x["cape_a"], x["cape_b"])
    elif t == "ratchet":
        ex = _sp("  +%.0f %% bei Depot > %.2f x Start, alle %d Jahre\n", x["raise"], x["ratchet_threshold"],
                 int(float(x["ratchet_gap"])))
    elif t == "sensible":
        ex = _sp("  Zusatz: %.0f %% des realen Vorjahresgewinns\n", x["extra"])
    elif t == "clyatt":
        ex = _sp("  Mindestens %.0f %% der Vorjahresentnahme\n", x["floor95"])
    out.append(ex)
    if x["min_real"] > 0 or math.isfinite(x["max_real"]):
        out.append(_sp("  Grenzen:   %.0f bis %s (real)\n", x["min_real"], _fmt1(x["max_real"])))
    return "".join(out)


def _wshow(x) -> str:
    """``paste(format(x), collapse = ", ")`` (NULL -> "")."""
    if x is None:
        return ""
    return _rshow(x)


def _rshow(x) -> str:
    if x is None:
        return "NULL"
    if isinstance(x, (bool, np.bool_)):
        return "TRUE" if x else "FALSE"
    return _show(x)


def withdrawal_rule(*, type=tuple(_WD_RULES), rate=4, ceiling=None, floor=None, cut=10, raise_=10,  # noqa: A002
                    cpr_years=15, inflation_cap=math.inf, skip_inflation=True, smoothing=None, exp_return=None,
                    stock_share=60, age=65, max_age=100, fv=0, cape_a=1.75, cape_b=0.5, ratchet_threshold=1.5,
                    ratchet_gap=3, extra=10, floor95=95, min_real=0, max_real=math.inf, max_rate=100, **kwargs):
    """Entnahmeregel definieren.

    Erzeugt eine validierte Entnahmeregel für ``withdrawal_simulation()`` und ``withdrawal_max_rate()``. Die
    Jahresentnahme wird zu Beginn jedes Planjahres festgelegt (Guyton & Klinger 2006; Suarez et al. 2015) und bei
    unterjährigen Perioden gleichmäßig ausgezahlt (Jahresbetrag / Perioden je Jahr). Alle Beträge sind
    Netto-Konsum; Steuern werden zusätzlich aus dem Depot verkauft. Alle Raten und Schranken werden in Prozent
    angegeben (``rate = 4`` bedeutet 4 % des Depots); welche Argumente eine Regel nutzt, zeigt die Tabelle unter
    Details. Jedes Argument muss eine einzelne Zahl ohne ``NA`` im zulässigen Bereich sein (Prozentsätze wie
    ``floor``, ``cut``, ``smoothing``, ``floor95``, ``extra``, ``max_rate`` 0 bis 100, ``ceiling``, ``raise``,
    ``inflation_cap`` >= 0, ``min_real <= max_real``, bei ``vpw`` ``age < max_age`` und ``max_rate > 0``); sonst
    bricht die Funktion mit einer Meldung ab. Schranken zwischen 0 und 0,2 lösen eine Warnung aus (vermutlich
    Anteil statt Prozent).

    Args:
        type: Regel (Zeichenkette, Standard ``"constant"``):

            - "constant": Bengen (1994) / Trinity-Studie: W_1 = rate · P_1, danach W_t-1(1+π) (real konstant).
            - "percent": Fester Prozentsatz des aktuellen Depots: rate · P.
            - "vanguard": Vanguard Dynamic Spending: rate · P, die Veränderung gegenüber W_t-1(1+π) (also real)
              begrenzt auf +``ceiling`` Prozent / -``floor`` Prozent (Standard 5 / 2,5).
            - "guyton_klinger": Guyton & Klinger (2006): Erstentnahme rate · P_1, Anfangsrate WR_0 = W_1 / P_1.
              Danach W_t-1 mit Inflationsausgleich (höchstens ``inflation_cap`` Prozent). Withdrawal-Rule
              (``skip_inflation``): kein Inflationsausgleich, wenn die nominale Depotrendite des Vorjahres negativ
              war und die inflationierte Entnahme eine Rate über WR_0 ergäbe. Capital-Preservation-Rule: Kürzung
              um ``cut`` Prozent, wenn die aktuelle Rate W / P über WR_0 (1 + ceiling/100) liegt und noch mehr als
              ``cpr_years`` Restjahre bleiben. Prosperity-Rule: sonst Erhöhung um ``raise`` Prozent, wenn die Rate
              unter WR_0 (1 - floor/100) liegt. Standard 20 / 20 / 10 / 10, 15 Jahre.
            - "floor_ceiling": Bengen (2001): rate · P, begrenzt auf das (1 - ``floor``/100)- bis (1 +
              ``ceiling``/100)-fache der realen Erstentnahme in heutigen Preisen (Standard 15 / 20).
            - "clyatt": Clyatt: max(rate · P, floor95/100 · W_t-1), nominal (ohne Inflationsausgleich).
            - "ratchet": Kitces: real konstant wie ``"constant"``; Erhöhung um ``raise`` Prozent (10), wenn das
              reale Depot das ``ratchet_threshold``-fache (1,5) des realen Startdepots übersteigt, höchstens alle
              ``ratchet_gap`` (3) Jahre (frühestens im Jahr 1 + ``ratchet_gap``).
            - "endowment": Yale/Tobin: λ W_t-1(1+π) + (1-λ) rate · P mit λ = ``smoothing``/100 (Standard 70).
            - "one_over_n": P / Restjahre; leert das Depot planmäßig bis zum Ende der Simulation.
            - "vpw": Bogleheads VPW: P · PMT(r, n) mit n = ``max_age`` - Alter im Planjahr (``age`` im ersten
              Jahr) und r = ``exp_return``/100, höchstens ``max_rate`` Prozent des Depots; bei n ≤ 1 das ganze
              Depot.
            - "abw": Amortisation: reale vorschüssige Annuität (P_real - fv / (1+r)^n) · PMT(r, n) über n =
              Restjahre mit r = ``exp_return``/100 und Zielvermögen ``fv``; nicht negativ.
            - "cape": (cape_a/100 + cape_b / CAPE) · P mit dem CAPE zu Beginn des Planjahres (CAPE <= 0: nur
              ``cape_a``). Standard ``cape_a`` = 1,75, ``cape_b`` = 0,5 (ERN); CAPE-Reihe nötig (Argument ``cape``
              in ``withdrawal_cohorts()`` bzw. ``withdrawal_paths()``).
            - "sensible": Erstes Jahr rate · P_1; danach diese Erstentnahme real (inflationiert) plus ``extra``
              Prozent (10) des realen Depotzuwachses seit der Vorjahresentnahme (nur Zuwächse).
            - "hebeler": Autopilot II: λ W_t-1(1+π) + (1-λ) PMT(r, n) · P mit λ = ``smoothing``/100 (Standard 75),
              r = ``exp_return``/100, n = Restjahre; im ersten Jahr nur die Annuität.
        rate: Entnahmerate in Prozent (4 = 4 % des Depots; Standard 4; zulässig 0 bis 100): Anfangsrate
            (``constant``, ``guyton_klinger``, ``ratchet``, ``sensible``) bzw. laufende Rate auf das aktuelle
            Depot (``percent``, ``vanguard``, ``floor_ceiling``, ``clyatt``, ``endowment``). Von ``one_over_n``,
            ``vpw``, ``abw``, ``cape`` und ``hebeler`` nicht genutzt. Werte zwischen 0 und 0,2 lösen bei
            ``constant``, ``percent``, ``vanguard`` und ``guyton_klinger`` eine Warnung aus (vermutlich Anteil
            statt Prozent).
        ceiling, floor: Obere bzw. untere Schranke in Prozent (>= 0), Bedeutung je Regel: ``vanguard`` = maximale
            reale Erhöhung / Senkung gegenüber dem Vorjahr (Standard 5 / 2,5); ``guyton_klinger`` = Abstand der
            Leitplanken von der Anfangsrate (20 / 20); ``floor_ceiling`` = Korridor um die reale Erstentnahme (20
            / 15). ``None`` = diese Regel-Standards; andere Regeln ignorieren die Werte (gespeichert als 0).
        cut, raise_: Kürzung bzw. Erhöhung der Entnahme in Prozent (>= 0, Standard 10 / 10): ``cut`` für
            ``guyton_klinger``, ``raise`` für ``guyton_klinger`` und ``ratchet``.
        cpr_years: Guyton-Klinger: Anzahl Jahre (Standard 15). Die Capital-Preservation-Rule greift nur, solange
            mehr als ``cpr_years`` Restjahre (einschließlich des aktuellen) bleiben.
        inflation_cap: Guyton-Klinger: maximaler Inflationsausgleich je Jahr in Prozent (Standard ``Inf`` =
            unbegrenzt, wie in der Fassung von 2006).
        skip_inflation: Logisch, Guyton-Klinger: Withdrawal-Rule aktiv (Standard ``True``; siehe ``type``).
        smoothing: Glättungsgewicht der Vorjahresentnahme in Prozent (0 bis 100) für ``endowment`` und
            ``hebeler``. ``None`` = 75 bei ``hebeler``, sonst 70.
        exp_return: Erwartete reale Rendite in Prozent p. a. für ``vpw``, ``abw`` und ``hebeler``. ``None`` = 5 x
            ``stock_share``/100 + 1,9 x (1 - ``stock_share``/100), beim Standard ``stock_share = 60`` also 3,76.
        stock_share: Aktienquote in Prozent (60 = 60 %, Standard 60); nur für den Standardwert von ``exp_return``
            verwendet.
        age, max_age: Alter bei Rentenbeginn und Planungsalter in Jahren (Standard 65 / 100), nur ``vpw``.
        fv: ``abw``: reales Zielvermögen am Ende als Geldbetrag in Kaufkraft des Startzeitpunkts (Standard 0 =
            Depot aufbrauchen).
        cape_a, cape_b: CAPE-Regel: Konstante in Prozent (Standard 1.75 = 1,75 %) und Faktor auf 1 / CAPE als
            Anteil (Standard 0.5; bei CAPE 25 also 0.5 / 25 = 0.02 = 2 %).
        ratchet_threshold: ``ratchet``: Faktor auf das reale Startdepot (Standard 1.5 = 150 %), ab dem erhöht
            wird.
        ratchet_gap: ``ratchet``: Mindestabstand zwischen Erhöhungen in Jahren (Standard 3).
        extra: ``sensible``: Anteil des realen Depotzuwachses in Prozent (Standard 10).
        floor95: ``clyatt``: Mindestanteil der Vorjahresentnahme in Prozent (Standard 95).
        min_real, max_real: Absolute Unter- bzw. Obergrenze der Jahresentnahme als Geldbetrag in Kaufkraft des
            Startzeitpunkts, für alle Regeln (Standard 0 und ``Inf`` = keine Grenze).
        max_rate: ``vpw``: Höchstsatz in Prozent des Depots (Standard 100).
        **kwargs: nur ``raise`` (``**{"raise": …}``) als Schreibweise für ``raise_`` (``raise`` ist in Python ein
            Schlüsselwort); andere Namen sind ein Fehler.

    Returns:
        Objekt der Klasse ``withdrawal_rule`` (Liste) mit ``type`` und allen Parametern in Prozent-Konvention,
        wobei ``ceiling``, ``floor``, ``smoothing`` und ``exp_return`` bereits mit den Standardwerten gefüllt sind
        (``stock_share`` wird nicht gespeichert). Ausgabe mit ``print()``.

    Details:
        Bezeichnungen: P = nominaler Depotwert zu Beginn des Planjahres vor der Entnahme, P_1 = Startdepot, W_t-1
        = nominale Entnahme des Vorjahres, π = Inflation des Vorjahres, Restjahre = verbleibende Planjahre der
        Simulation einschließlich des aktuellen Jahres, PMT(r, n) = vorschüssige Annuität je Geldeinheit Kapital
        (r / ((1 - (1+r)^-n)(1+r)), bei n ≤ 1 gleich 1). Nach jeder Regel werden ``min_real`` und ``max_real``
        angewendet.

        Genutzte Argumente je Regel (Standardwerte von ``ceiling``, ``floor`` und ``smoothing`` in Klammern;
        ``min_real`` und ``max_real`` gelten für alle Regeln):
        - Regel | genutzte Argumente
        - ``constant`` | ``rate``
        - ``percent`` | ``rate``
        - ``vanguard`` | ``rate``, ``ceiling`` (5), ``floor`` (2.5)
        - ``guyton_klinger`` | ``rate``, ``ceiling`` (20), ``floor`` (20), ``cut``, ``raise``, ``cpr_years``,
          ``inflation_cap``, ``skip_inflation``
        - ``floor_ceiling`` | ``rate``, ``ceiling`` (20), ``floor`` (15)
        - ``clyatt`` | ``rate``, ``floor95``
        - ``ratchet`` | ``rate``, ``raise``, ``ratchet_threshold``, ``ratchet_gap``
        - ``endowment`` | ``rate``, ``smoothing`` (70)
        - ``one_over_n`` | keine (nur Restjahre)
        - ``vpw`` | ``exp_return`` bzw. ``stock_share``, ``age``, ``max_age``, ``max_rate``
        - ``abw`` | ``exp_return`` bzw. ``stock_share``, ``fv`` (Restjahre)
        - ``cape`` | ``cape_a``, ``cape_b``; CAPE-Reihe in den Pfaden nötig
        - ``sensible`` | ``rate``, ``extra``
        - ``hebeler`` | ``exp_return`` bzw. ``stock_share``, ``smoothing`` (75) (Restjahre)

        Die Restjahre (``one_over_n``, ``abw``, ``hebeler`` und die Capital-Preservation-Rule von
        ``guyton_klinger``) sind kein Argument der Regel: Sie ergeben sich in ``withdrawal_simulation()`` aus der
        Zahl der Planjahre (Pfadlänge bzw. ``years``). Eine zufällige Laufzeit je Pfad (``horizon`` in
        ``withdrawal_simulation()``, Objekt aus ``withdrawal_horizon()``) ändert nur die Auswertung (Erfolg,
        Konsum und Endvermögen bis zum Horizont); die Regel rechnet weiter mit den Restjahren der vollen
        Pfadlänge.

    Quellen und Abweichungen:
        - ``clyatt``: Nach Clyatt (2005): jedes Jahr ``rate`` des aktuellen Depots, mindestens ``floor95`` Prozent
          der Vorjahresentnahme, nominal; Kürzungen in Folgejahren verketten sich (95 % von 95 %). Keine
          Abweichung.
        - ``endowment``: Angelehnt an die Yale-Regel (Swensen 2009, Kap. 3, mit Verweis auf Tobin 1974): Gewicht
          mal Vorjahresentnahme plus (1 - Gewicht) mal Zielrate mal Vermögen; Yale früher 70 %, heute 80 %.
          Abweichend: Yale wendet die Zielrate auf den Wert zum Ende des vorigen Geschäftsjahres an und schreibt
          die Summe beider Teile mit der Inflation fort; SimLev nimmt das Depot zu Beginn des Planjahres und
          inflationiert nur die Vorjahresentnahme.
        - ``one_over_n``: Nach Bogleheads Wiki, Withdrawal methods (1/N): Depot geteilt durch die Restjahre.
          Abweichend: das Wiki empfiehlt 1/N eher als Höchstbetrag; SimLev entnimmt genau 1/N.
        - ``abw``: Angelehnt an die jährlich neu berechnete virtuelle Annuität (ARVA) von Waring & Siegel (2015):
          Rate einer vorschüssigen Annuität mit dem aktuellen Depot über die Restjahre. Abweichend: feste
          erwartete Realrendite ``exp_return`` statt der aktuellen Marktzinsen; reales Zielvermögen ``fv`` als
          eigene Ergänzung.
        - ``cape``: Nach Jeske (2017): Rate = a + b / CAPE auf das aktuelle Depot; 1,75 % und 0,5 sind eine der
          dort gerechneten Varianten. Abweichend: dort monatlich mit den Werten vom Ende des Vormonats, in SimLev
          jährlich mit dem CAPE zu Beginn des Planjahres; CAPE <= 0 ergibt nur a (eigene Festlegung).
        - ``sensible``: Angelehnt an Ponzo (o. J.), Sensible Withdrawals: Grundentnahme plus ein Anteil (dort
          Beispiele 10 und 25 %) des Zuwachses, wenn das Depot nach der Grundentnahme stärker als die Inflation
          gewachsen ist. Abweichend bzw. dort offen: SimLev setzt die Grundentnahme als inflationierte
          Erstentnahme rate · P_1, misst den Zuwachs als reales Depot vor der Entnahme minus reales Depot nach der
          Vorjahresentnahme und begrenzt den Zusatz nicht.
        - ``hebeler``: Angelehnt an Hebelers Retirement Autopilot (Hebeler 2001); Gewichtung 75 % inflationierte
          Vorjahresentnahme plus 25 % Annuität nach Steiner (2015). Abweichend: Hebeler rechnet die Annuität über
          die Lebenserwartung (IRS-Tabellen) mit einem niedrigen Realzins, SimLev über die Restjahre der
          Simulation mit ``exp_return``.

    Literatur:
        Bengen (1994, 2001); Cooley, Hubbard & Walz (1998); Guyton & Klinger (2006), Journal of Financial Planning
        19(3); Vanguard (2021), Sustainable spending rates in turbulent markets; Bogleheads Wiki, Variable
        percentage withdrawal; Kitces (2015); Suarez, Suarez & Walz (2015), Financial Services Review 24; Clyatt,
        B. (2005), Work Less, Live More: The New Way to Retire Early, Nolo, Berkeley; Swensen, D. F. (2009),
        Pioneering Portfolio Management, Fully Revised and Updated, Free Press, Kap. 3; Tobin, J. (1974), What is
        permanent endowment income?, American Economic Review 64(2), 427-432; Bogleheads Wiki, Withdrawal methods,
        https://www.bogleheads.org/wiki/Withdrawal_methods; Waring, M. B. & Siegel, L. B. (2015), The only
        spending rule article you will ever need, Financial Analysts Journal 71(1), 91-107,
        doi:10.2469/faj.v71.n1.2; Jeske, K. (2017), The ultimate guide to safe withdrawal rates - Part 18:
        Flexibility and the mechanics of CAPE-based rules, earlyretirementnow.com, 30.08.2017; Ponzo, P. (o. J.),
        Sensible withdrawals, gummy-stuff,
        https://www.financialwisdomforum.org/gummy-stuff/sensible_withdrawals.htm; Hebeler, H. K. (2001), J.K.
        Lasser's Your Winning Retirement Plan, Wiley; Steiner, K. (2015), Bud Hebeler's Autopilot withdrawal rule,
        Blog How much can I afford to spend in retirement?, 22.01.2015.

    Hinweise (Python):
        ``raise`` ist in Python ein Schlüsselwort: Argument ``raise_`` (oder
        ``**{"raise": 5}``).

    Beispiel::

        import simlev
        print(simlev.withdrawal_rule(type="vanguard", rate=5, ceiling=5, floor=2.5))
    """
    if "raise" in kwargs:
        raise_ = kwargs.pop("raise")
    if kwargs:
        k = next(iter(kwargs))
        _stop("unused argument (%s = %s)" % (k, _deparse(kwargs[k])))
    type = _match_arg(type, tuple(_WD_RULES))  # noqa: A001

    def chk(x, arg, lo=-math.inf, hi=math.inf, what="", inf_ok=False, null_ok=False):
        if x is None and null_ok:
            return
        v = _num_vec(x)
        if v is None or v.size != 1 or math.isnan(v[0]) or (not inf_ok and not math.isfinite(v[0])) or \
                v[0] < lo or v[0] > hi:
            _stop("withdrawal_rule: %s muss %s sein (erhalten: %s)." % (arg, what, _rshow(x)))

    v = _num_vec(rate)
    if v is None or v.size != 1 or not math.isfinite(v[0]) or v[0] < 0 or v[0] > 100:
        _stop("rate muss zwischen 0 und 100 Prozent liegen (z. B. 4; erhalten: %s)." % _rshow(rate))
    if 0 < rate < 0.2 and type in ("constant", "percent", "vanguard", "guyton_klinger"):
        _warn("rate wirkt wie eine Dezimalzahl. PROZENT-KONVENTION: 4 bedeutet 4 %.")
    chk(ceiling, "ceiling", 0, what="NULL oder eine Zahl >= 0 in Prozent (z. B. 20)", null_ok=True)
    chk(floor, "floor", 0, 100, what="NULL oder eine Zahl von 0 bis 100 in Prozent (z. B. 20)", null_ok=True)
    chk(cut, "cut", 0, 100, what="eine Zahl von 0 bis 100 in Prozent (z. B. 10)")
    chk(raise_, "raise", 0, what="eine Zahl >= 0 in Prozent (z. B. 10)")
    chk(cpr_years, "cpr_years", 0, what="eine Zahl von Jahren >= 0 (z. B. 15)")
    chk(inflation_cap, "inflation_cap", 0, what="eine Zahl >= 0 in Prozent oder Inf (unbegrenzt)", inf_ok=True)
    if not isinstance(skip_inflation, (bool, np.bool_)):
        _stop("withdrawal_rule: skip_inflation muss TRUE oder FALSE sein (erhalten: %s)." % _rshow(skip_inflation))
    chk(smoothing, "smoothing", 0, 100, what="NULL oder eine Zahl von 0 bis 100 in Prozent (z. B. 70)", null_ok=True)
    chk(exp_return, "exp_return", -99.99, what="NULL oder eine Zahl in Prozent p. a. über -100 (z. B. 3.5)",
        null_ok=True)
    chk(stock_share, "stock_share", 0, 100, what="eine Zahl von 0 bis 100 in Prozent (z. B. 60)")
    chk(age, "age", 0, what="ein Alter in Jahren >= 0 (z. B. 65)")
    chk(max_age, "max_age", 0, what="ein Alter in Jahren >= 0 (z. B. 100)")
    if type == "vpw" and age >= max_age:
        _stop("withdrawal_rule('vpw'): age (%s) muss kleiner als max_age (%s) sein." % (_fmt1(age), _fmt1(max_age)))
    chk(fv, "fv", 0, what="ein Geldbetrag >= 0 (reales Zielvermögen)")
    chk(cape_a, "cape_a", 0, 100, what="eine Zahl von 0 bis 100 in Prozent (z. B. 1.75)")
    chk(cape_b, "cape_b", 0, what="eine Zahl >= 0 (Faktor auf 1 / CAPE, z. B. 0.5)")
    chk(ratchet_threshold, "ratchet_threshold", 0, what="ein Faktor > 0 (z. B. 1.5 = 150 %)")
    chk(ratchet_gap, "ratchet_gap", 0, what="eine Zahl von Jahren >= 0 (z. B. 3)")
    chk(extra, "extra", 0, 100, what="eine Zahl von 0 bis 100 in Prozent (z. B. 10)")
    chk(floor95, "floor95", 0, 100, what="eine Zahl von 0 bis 100 in Prozent (z. B. 95)")
    chk(min_real, "min_real", 0, what="ein Geldbetrag >= 0")
    chk(max_real, "max_real", 0, what="ein Geldbetrag >= 0 oder Inf", inf_ok=True)
    if min_real > max_real:
        _stop("withdrawal_rule: min_real (%s) darf nicht größer als max_real (%s) sein."
              % (_fmt1(min_real), _fmt1(max_real)))
    chk(max_rate, "max_rate", 0, 100, what="eine Zahl von 0 bis 100 in Prozent (z. B. 100)")
    if type == "vpw" and max_rate == 0:
        _stop("withdrawal_rule('vpw'): max_rate = 0 erlaubt keine Entnahme; Höchstsatz in Prozent > 0 angeben "
              "(z. B. 100).")
    frac = [("ceiling", _NAN if ceiling is None else float(ceiling)), ("floor", _NAN if floor is None else float(floor)),
            ("cut", float(cut)), ("raise", float(raise_)), ("smoothing", _NAN if smoothing is None else float(smoothing)),
            ("inflation_cap", float(inflation_cap)), ("extra", float(extra)), ("floor95", float(floor95)),
            ("max_rate", float(max_rate))]
    frac = [(k, v) for k, v in frac if not math.isnan(v) and 0 < v < 0.2]
    if frac:
        a = _fmtv([v for _, v in frac])
        b = _fmtv([100 * v for _, v in frac])
        _warn("withdrawal_rule: %s wirkt wie ein Anteil; PROZENT-KONVENTION: 5 bedeutet 5 %% (gemeint vermutlich %s)."
              % (", ".join("%s = %s" % (k, s) for (k, _), s in zip(frac, a)),
                 ", ".join("%s = %s" % (k, s) for (k, _), s in zip(frac, b))))
    dflt = {"vanguard": (5, 2.5), "guyton_klinger": (20, 20), "floor_ceiling": (20, 15)}.get(type, (0, 0))
    ceiling = dflt[0] if ceiling is None else ceiling
    floor = dflt[1] if floor is None else floor
    smoothing = (75 if type == "hebeler" else 70) if smoothing is None else smoothing
    exp_return = (5.0 * stock_share / 100 + 1.9 * (1 - stock_share / 100)) if exp_return is None else exp_return
    return WithdrawalRule([
        ("type", type), ("rate", rate), ("ceiling", ceiling), ("floor", floor), ("cut", cut), ("raise", raise_),
        ("cpr_years", cpr_years), ("inflation_cap", inflation_cap), ("skip_inflation", bool(skip_inflation)),
        ("smoothing", smoothing), ("exp_return", exp_return), ("age", age), ("max_age", max_age), ("fv", fv),
        ("cape_a", cape_a), ("cape_b", cape_b), ("ratchet_threshold", ratchet_threshold),
        ("ratchet_gap", ratchet_gap), ("extra", extra), ("floor95", floor95), ("min_real", min_real),
        ("max_real", max_real), ("max_rate", max_rate)])


def _deparse(v) -> str:
    from ._r.rformat import r_deparse
    return r_deparse(v)


def _is_rule(x) -> bool:
    return isinstance(x, WithdrawalRule) or "withdrawal_rule" in getattr(x, "r_class", ())


def _wd_param_vector(rule):
    """Parametervektor für den Kern (Reihenfolge = enum in withdrawal_core.cpp)."""
    r = rule
    f = float
    return np.array([f(r["rate"]) / 100, f(r["ceiling"]) / 100, f(r["floor"]) / 100, f(r["cut"]) / 100,
                     f(r["raise"]) / 100, f(r["cpr_years"]), f(r["inflation_cap"]) / 100, f(r["smoothing"]) / 100,
                     f(r["exp_return"]) / 100, f(r["cape_a"]) / 100, f(r["cape_b"]), f(r["ratchet_threshold"]),
                     f(r["ratchet_gap"]), f(r["extra"]) / 100, f(r["min_real"]), f(r["max_real"]), f(r["age"]),
                     f(r["max_age"]), f(r["fv"]), f(r["floor95"]) / 100,
                     1.0 if r["skip_inflation"] is True or r["skip_inflation"] is np.True_ else 0.0,
                     f(r["max_rate"]) / 100])


def _wd_ppy(frequency):
    """Perioden je Jahr (``.wd_ppy``)."""
    m = {"year": 1, "quarter": 4, "month": 12}
    if isinstance(frequency, str) and frequency in m:
        return m[frequency]
    _stop("frequency muss 'year', 'quarter' oder 'month' sein.")


def _period_ends(dates, frequency):
    """Letzte Zeile je Kalenderperiode (1-basiert), R: ``.period_ends``."""
    y, m = _ymd(dates)
    if frequency == "year":
        key = y
    elif frequency == "quarter":
        key = y * 10 + (m - 1) // 3
    else:
        key = y * 100 + m
    if not len(key):
        return np.zeros(0, dtype=np.int64)
    chg = np.concatenate([key[1:] != key[:-1], [True]])
    return np.flatnonzero(chg) + 1


# ═══════════════════════════════════════════════════════════════════════════
# withdrawal_paths-Objekte, Kohorten
# ═══════════════════════════════════════════════════════════════════════════

class WithdrawalPaths(RList):
    """Periodenmatrizen für die Entnahme (R-Klasse ``withdrawal_paths``)."""

    r_class = ("withdrawal_paths",)


def _is_wp(x) -> bool:
    return isinstance(x, WithdrawalPaths) or "withdrawal_paths" in getattr(x, "r_class", ())


def _fill_locf(v):
    from .backcast import _fill_na
    return np.asarray(_fill_na(np.asarray(v, dtype=np.float64), "locf"), dtype=np.float64)


def _df_col(data, name):
    if isinstance(data, pd.DataFrame):
        return data[name].to_numpy()
    return np.asarray(data[name])


@_quiet
def withdrawal_cohorts(data, *, price="value", inflation=None, years=30, frequency=_DEF_FREQ, step=("month", "year"),
                       wrap=False, cape=None, base_rate=None, inflation_type=_DEF_IT):
    """Historische Entnahme-Kohorten bilden.

    Erzeugt rollierende Start-Kohorten (wie Bengen 1994 und die Trinity-Studie) aus einer historischen Kursreihe:
    Für jeden Startmonat bzw. jedes Startjahr entsteht ein Pfad über ``years`` Jahre. Eingabe ist ein DataFrame
    mit Spalte ``date`` und einer Kursspalte (Niveau, keine Renditen) oder ein gespeichertes Ergebnis von
    ``simulation()``. Die Reihe wird auf Monatsenden verdichtet (letzter Wert je Kalendermonat, fehlende Werte
    fortgeschrieben); die Monatsrenditen werden zur gewählten ``frequency`` aufmultipliziert. Die Daten müssen
    jeden Kalendermonat zwischen erstem und letztem Datum enthalten (Tages-, Wochen- oder Monatsdaten); sonst,
    etwa bei Jahresdaten, bricht die Funktion ab. Das Ergebnis geht direkt an ``withdrawal_simulation()``,
    ``withdrawal_max_rate()`` oder ``withdrawal_perfect_rate()``.

    Args:
        data: DataFrame mit Spalte ``date`` (Klasse Date oder umwandelbar) und der Kursspalte ``price`` (ggf. auch
            Spalten für ``inflation``, ``cape``, ``base_rate``), oder ein ``SimLevResult``: dann wird dessen
            zeitgewichteter Wertindex ``result_index()`` verwendet, ``price`` ignoriert, und nur ``None`` oder ein
            Prozentsatz für ``inflation`` ist erlaubt (keine ``cape``- oder ``base_rate``-Spalten).
        price: Name der Kursspalte des Portfolios (Total-Return-Niveau, nach Kosten), z. B. eine Backcast-Reihe.
            Standard ``"value"``.
        inflation: ``None`` (Standard; keine Inflation), Zahl = konstante Inflation in Prozent p. a. (2 = 2 % p.
            a., tagesgenau über 365.25 Tage je Jahr umgerechnet) oder Zeichenkette = Name einer Preisindex-Spalte
            (CPI-Niveau, z. B. HVPI) bzw. einer Ratenspalte (siehe ``inflation_type``).
        years: Länge jeder Kohorte in Jahren (Standard 30; intern 12 x ``years`` Monate). Muss ganze Perioden der
            ``frequency`` ergeben (bei ``"year"`` ganze Jahre, bei ``"quarter"`` z. B. auch 2.5).
        frequency: Periodenlänge der Entnahme-Simulation: ``"year"`` (Standard), ``"quarter"`` oder ``"month"``.
        step: Abstand der Kohortenstarts: ``"month"`` (Standard; jede Kohorte beginnt einen Monat später) oder
            ``"year"`` (alle 12 Monate).
        wrap: Logisch (Standard ``False``). ``True``: Kohorten über das Datenende hinaus durch Fortsetzung am
            Datenanfang verlängern (wie FI Calc, Option "loop"), so dass jeder Startzeitpunkt gemäß ``step`` eine
            Kohorte ergibt; ``False``: nur Kohorten, die vollständig in den Daten liegen.
        cape: Optional Name einer Spalte mit CAPE-Werten (für die Regel ``"cape"`` in ``withdrawal_rule()``);
            verwendet wird der Wert zu Beginn jeder Periode.
        base_rate: Optional Name einer Spalte mit dem Basiszins in Prozent (2.5 = 2,5 %) für die Vorabpauschale
            (Wert zu Beginn jeder Periode); sonst gilt ``base_rate`` aus ``withdrawal_simulation()``.
        inflation_type: Behandlung einer Spalte in ``inflation``: ``"level"`` (Reihe ist ein Preisindex-Niveau;
            Inflation = Verhältnis der Monatsendwerte) oder ``"rate_pa"`` (Reihe ist eine Inflationsrate in
            Prozent pro Jahr, 2 = 2 % p. a., nicht je Datenperiode, kein Anteil; je Zeile über die Kalendertage
            seit der Vorzeile aufgezinst, Π (1 + r/100)^Tage/365.25). Stammt ``data`` aus ``bootstrap_data()`` und
            ist die Spalte in ``bootstrap_config()`` ausdrücklich als ``aux_type = "rate"`` gekennzeichnet
            (Attribut ``aux_type`` des DataFrames), ergibt sich ``"rate_pa"`` daraus; ``inflation_type`` kann dann
            entfallen und muss, wenn angegeben, dazu passen (sonst Fehler). Ohne Attribut gilt ``inflation_type``
            (Standard ``"level"``, bisheriges Verhalten). Das Attribut geht bei Umformungen wie ``transform()``,
            ``merge()``, ``cbind()`` oder Speichern als CSV verloren; dann ``inflation_type = "rate_pa"`` angeben.
            Bei Zahl oder ``None`` in ``inflation`` ohne Wirkung.

    Returns:
        Objekt der Klasse ``withdrawal_paths`` (Liste) mit ``returns`` (Matrix Perioden x Kohorten der
        Brutto-Periodenrenditen), ``inflation`` (gleiche Form, Brutto-Inflation je Periode; ohne Inflation 1),
        ``cape`` und ``base_rate`` (Matrizen der Werte zu Periodenbeginn oder ``None``), ``frequency``,
        ``start_dates`` (Datum des Monatsendwerts, ab dem jede Kohorte läuft), ``historical = True``, ``wrap`` und
        ``source`` (Name der Kursspalte).

    Beispiel::

        import numpy as np, pandas as pd, simlev
        rng = np.random.default_rng(1)
        d = pd.DataFrame({"date": pd.date_range("1990-01-01", "2019-12-01", freq="MS")})
        d["depot"] = 100 * np.cumprod(np.exp(rng.normal(0.005, 0.04, len(d))))
        coh = simlev.withdrawal_cohorts(d, price="depot", inflation=2, years=20, step="year")
        ws = simlev.withdrawal_simulation(coh, rule=simlev.withdrawal_rule(type="constant", rate=4))
        print(coh["returns"].shape)
    """
    it_given = inflation_type is not _DEF_IT
    frequency = _match_arg(frequency, _DEF_FREQ)
    step = _match_arg(step, ("month", "year"))
    inflation_type = _match_arg(inflation_type, _DEF_IT)
    if _is_result(data):
        if isinstance(inflation, str) or cape is not None or base_rate is not None:
            _stop("Bei einem SimLevResult sind nur numerische Inflation und keine Zusatzspalten möglich.")
        data = result_index(data)
        price = "value"
    names = [str(c) for c in data.columns] if isinstance(data, pd.DataFrame) else list(data.keys())
    if not all(c in names for c in ("date", price)):
        _stop("data braucht 'date' und die Kursspalte.")
    at = data.attrs.get("aux_type") if isinstance(data, pd.DataFrame) else None
    attr_rate = False
    if isinstance(inflation, str) and at is not None:
        nm = _names(at) or []
        vals = _values(at)
        attr_rate = inflation in nm and vals[nm.index(inflation)] == "rate"
    if attr_rate and it_given and inflation_type != "rate_pa":
        _stop(("inflation_type = '%s' passt nicht zu aux_type['%s'] = 'rate' (Attribut aus bootstrap_data()); "
               "inflation_type weglassen oder 'rate_pa' angeben.") % (inflation_type, inflation))
    infl_rate = isinstance(inflation, str) and (attr_rate or inflation_type == "rate_pa")
    dd = _to_date(_df_col(data, "date"), "withdrawal_cohorts: data$date")
    o = np.argsort(_dates_days(dd), kind="stable")
    dates = dd[o]

    def col(name):
        src = pd.Series(_df_col(data, name))
        v = np.array(pd.to_numeric(src, errors="coerce"), dtype=np.float64)
        if src.dtype.kind != "f":              # as.numeric: Fehlendes/Unlesbares → NA (Float-Werte behalten ihr Bitmuster)
            keep = np.array([isinstance(z, (float, np.floating)) for z in src.tolist()], dtype=bool)
            v[np.isnan(v) & ~keep] = _NA
        return v[o]

    px = _fill_locf(col(price))
    ends = _period_ends(dates, "month")
    mdates = dates[ends - 1]
    mpx = px[ends - 1]
    y, m = _ymd(mdates)
    mi = y * 12 + m
    gap = np.flatnonzero(np.diff(mi) != 1)
    if len(gap):
        _stop(("withdrawal_cohorts braucht l\u00fcckenlose Monatsdaten (mindestens ein Datum je Kalendermonat), "
               "aber nach %s folgt %s%s.") % (
            str(mdates[gap[0]]), str(mdates[gap[0] + 1]),
            (" (Jahresdaten? Dann Jahresrenditen als Matrix Jahre x Kohorten an withdrawal_simulation() \u00fcbergeben)"
             if r_median(np.diff(mi).astype(np.float64)) >= 12 else "")))
    if inflation is None:
        cpi = np.ones(len(ends))
    elif infl_rate:
        v = _fill_locf(col(inflation))
        dt = np.diff(_dates_days(dates)).astype(np.float64) / 365.25
        lvf = r_cumprod(np.concatenate([[1.0], _pow_vec(1 + v[1:] / 100, dt)]))
        lv = lvf[ends - 1]
        f = lv[1:] / lv[:-1]
        bad = ~np.isfinite(f) | (f <= 0)
        if bad.any():
            _stop("Spalte '%s' (Rate in Prozent p. a.) ergibt nicht endliche oder nicht positive Monatsfaktoren "
                  "(z. B. %s; Rate <= -100 %%?)." % (inflation, _fmt_nan(f[bad][0], digits=4)))
        cpi = lv
    elif isinstance(inflation, str):
        cpi = _fill_locf(col(inflation))[ends - 1]
    else:
        cpi = _pow_vec(1 + float(inflation) / 100,
                       (_dates_days(mdates) - _dates_days(mdates[:1])[0]).astype(np.float64) / 365.25)
    capev = _fill_locf(col(cape))[ends - 1] if cape is not None else None
    brv = _fill_locf(col(base_rate))[ends - 1] if base_rate is not None else None
    mret = mpx[1:] / mpx[:-1]
    minf = cpi[1:] / cpi[:-1]
    nm = len(mret)
    ppy = _wd_ppy(frequency)
    mpp = 12 / ppy
    yv = _num_vec(years)
    if yv is None or yv.size != 1 or not math.isfinite(yv[0]) or yv[0] <= 0 or \
            abs(yv[0] * 12 - _r_round0(yv[0] * 12)) > 1e-8 or math.fmod(_r_round0(yv[0] * 12), mpp) != 0:
        _stop("years muss eine positive Zahl sein, die ganze Perioden der frequency '%s' ergibt (bei 'year' ganze "
              "Jahre; erhalten: %s)." % (frequency, _show(years)))
    len_m = int(_r_round0(float(years) * 12))
    mpp = int(mpp)
    if step == "month":
        starts = np.arange(1, nm + 1)
    else:
        if nm < 1:
            _stop("wrong sign in 'by' argument")
        starts = np.arange(1, nm + 1, 12)
    if not wrap:
        starts = starts[starts + len_m - 1 <= nm]
    if not len(starts):
        _stop("Zu kurze Historie für die gewählte Kohortenlänge.")

    def take(v, s):
        return v[((s - 1 + np.arange(1, len_m + 1) - 1) % nm)]

    def agg(M):
        if mpp == 1:
            return M
        res = _apply_cols(M, lambda c: [r_prod(c[i:i + mpp]) for i in range(0, len(c), mpp)])
        return res

    Rm = agg(np.column_stack([take(mret, s) for s in starts]))
    Im = agg(np.column_stack([take(minf, s) for s in starts]))
    ns = len(starts)

    def to_mat(A):
        A = np.asarray(A, dtype=np.float64)
        return A.reshape(-1, ns, order="F") if A.ndim == 1 else A

    def pick_start(v):
        if v is None:
            return None
        Mx = np.column_stack([take(v[:-1], s) for s in starts])
        return Mx[np.arange(0, len_m, mpp), :]

    return WithdrawalPaths([
        ("returns", to_mat(Rm)), ("inflation", to_mat(Im)), ("cape", pick_start(capev)),
        ("base_rate", pick_start(brv)), ("frequency", frequency), ("start_dates", mdates[starts - 1]),
        ("historical", True), ("wrap", bool(wrap)), ("source", price)])


@_quiet
def result_index(x, *, base=100):
    """Zeitgewichteter Wertindex eines Simulationsergebnisses.

    Bildet aus einem ``SimLevResult`` den um Ein- und Auszahlungen bereinigten Wertindex (Basis der TTWROR). Damit
    lässt sich jedes gespeicherte Ergebnis von ``simulation()`` als Renditequelle für ``withdrawal_simulation()``
    verwenden. Verwendet wird der von ``simulation()`` gespeicherte Index ``twr_index``: an Tagen ohne Zahlung I_t
    = I_t-1 W_t / W_t-1; an Tagen mit Zahlung wird der Vortagesbestand zum Schlusskurs vor der Zahlung bewertet
    (siehe ``simulation()``, Abschnitt Kennzahlen), sodass die Zahlung die Rendite nicht verzerrt. W_t ist der
    Depotwert. Für ältere Ergebnisse ohne ``twr_index`` gilt I_t = I_t-1 (W_t - F_t) / W_t-1 mit F_t = Summe der
    Ein- und Auszahlungen aller Assets am Tag t; nicht endliche Tagesfaktoren (z. B. bei Depotwert 0) werden dabei
    als 1 gesetzt.

    Args:
        x: Objekt der Klasse ``SimLevResult`` (Ergebnis von ``simulation()``).
        base: Startwert des Index (Zahl, Standard 100).

    Returns:
        DataFrame mit einer Zeile je Simulationstag und den Spalten ``date`` (Date), ``value`` (Index, beginnt bei
        ``base``), ``worth`` (Depotwert) und ``flows`` (Summe der Ein-/Auszahlungen je Tag, Geldbetrag).

    Beispiel::

        import numpy as np, pandas as pd, simlev
        rng = np.random.default_rng(1)
        n = 400
        d = pd.DataFrame({"date": pd.date_range("2020-01-01", periods=n)})
        d["ETF"] = 100 * np.cumprod(1 + rng.normal(3e-4, 0.01, n))
        res = simlev.simulation(d, simlev.create_strategy(ETF=simlev.asset_config(asset_class="etf")),
                                dca=simlev.dca_plan(value=100, span=1))
        print(simlev.result_index(res).head())
    """
    if not _is_result(x):
        _stop("x muss ein SimLevResult (Ergebnis von simulation()) sein.")
    w = np.asarray(_rget(x, "worth"), dtype=np.float64).ravel()
    rep = _rget(x, "report", {})
    fls = [np.asarray(_get(a, "flows"), dtype=np.float64).ravel() for a in (rep.values() if isinstance(rep, Mapping)
                                                                          else rep)]
    if fls and len(w) > 1:
        M = np.column_stack(fls)
        fl = r_rowsums(M)   # C-Kern core/slc_rbase.cpp (long double wie R)
    elif fls:
        fl = np.array([float(f[0]) for f in fls])
    else:
        fl = np.zeros(0)
    twr = _rget(x, "twr_index")
    if twr is not None and len(np.asarray(twr).ravel()) == len(w):
        idx = np.asarray(twr, dtype=np.float64).ravel()
    else:
        with np.errstate(divide="ignore", invalid="ignore"):
            g = np.concatenate([[1.0], (w[1:] - fl[1:]) / w[:-1]])
        g[~np.isfinite(g)] = 1.0
        idx = r_cumprod(g)
    dates = np.asarray(_rget(x, "dates"))
    if dates.dtype.kind in "iuf":
        dates = (np.datetime64("1970-01-01", "D") + dates.astype(np.int64).astype("timedelta64[D]"))
    else:
        dates = dates.astype("datetime64[D]")
    return pd.DataFrame({"date": dates, "value": base * idx, "worth": w, "flows": fl})


@_quiet
def _anniv_ends(dates, frequency):
    """Periodenenden als Jahrestage ab Startdatum (1-basierte Zeilen), R: ``.anniv_ends``."""
    from .data_prep import _add_months
    step = {"year": 12, "quarter": 3, "month": 1}.get(frequency)
    d = np.asarray(dates).astype("datetime64[D]")
    d0, d1 = d[0], d[-1]
    y0, m0 = _ymd(d[:1])
    y1, m1 = _ymd(d[-1:])
    nm = int((y1[0] - y0[0]) * 12 + m1[0] - m0[0])
    last = (nm // step) * step
    ks = np.arange(0, last + 1, step) if last >= 0 else np.zeros(0, dtype=np.int64)
    tg = np.asarray(_add_months(d0, ks)).astype("datetime64[D]")
    tg = tg[tg <= d1]
    fi = np.searchsorted(_dates_days(d), _dates_days(tg), side="right")
    out = []
    for v in fi.tolist():
        if v not in out:
            out.append(v)
    return np.array(out, dtype=np.int64)


def _aux_kind(cfg, inflation, it_given, inflation_type):
    sets = list(_get(cfg, "aux_type_set", []) or [])
    if not isinstance(inflation, str) or inflation not in sets:
        return None
    at = _get(cfg, "aux_type")
    nm = _names(at) or []
    k = _values(at)[nm.index(inflation)]
    it = "level" if k == "level" else "rate_pa"
    if it_given and inflation_type != it:
        _stop("inflation_type = '%s' passt nicht zu aux_type['%s'] = '%s' in bootstrap_config(); inflation_type "
              "weglassen oder '%s' angeben." % (inflation_type, inflation, k, it))
    return k


def _is_result_list(x) -> bool:
    if isinstance(x, Mapping) and not isinstance(x, RList):
        vals = list(x.values())
    elif isinstance(x, (list, tuple)):
        vals = list(x)
    else:
        return False
    return bool(vals) and all(_is_result(v) for v in vals)


@_quiet
def withdrawal_paths(x, *, column=None, strategy=None, inflation=None, inflation_type=_DEF_IT, frequency=_DEF_FREQ,
                     dates=None, start="2000-01-01", cape=None):
    """Pfade in Perioden-Renditen für Entnahmen umwandeln.

    Wandelt fertige Simulationen in die Periodenmatrizen von ``withdrawal_simulation()`` um, damit sich eine
    Entnahmephase auf bereits gerechnete Pfade setzen lässt. Perioden beginnen am Startdatum der Pfade und enden
    an den Jahrestagen (bzw. Quartals- oder Monatstagen) danach, je vom Startdatum gezählt und auf das Monatsende
    begrenzt (Start 31.01.: 29.02., 31.03., 30.04. ...); eine unvollständige letzte Periode entfällt.

    Args:
        x: ``SimLevBootstrapStudy``, Liste von ``SimLevResult`` oder ``bootstrap_result`` (siehe oben).
        column: Nur bei ``bootstrap_result`` (dort Pflicht): Name der Kursspalte im Pfad (Index oder
            Hebelprodukt).
        strategy: Nur bei ``SimLevBootstrapStudy``: Strategiename. ``None`` (Standard) = erste gespeicherte
            Strategie.
        inflation: ``None`` (Standard; keine Inflation, Faktor 1), Zahl = konstante Inflation in Prozent p. a. (2
            = 2 % p. a., über die Kalendertage der Perioden umgerechnet) oder Zeichenkette = Name einer
            Zusatzreihe: bei ``bootstrap_result`` eine Spalte der Pfade (aus ``aux`` in ``bootstrap_config()``;
            Behandlung nach ``aux_type`` bzw. ``inflation_type``), bei Studien eine mit ``keep_aux`` gespeicherte
            Reihe (deren gespeicherte Periodenfaktoren werden direkt als Brutto-Inflation verwendet; nicht
            endliche Faktoren oder Werte <= 0 sind ein Fehler). Eine Reihe mit ``aux_type = "rate"`` gilt dabei
            immer als Inflationsrate in Prozent pro Jahr (2 = 2 % p. a.; nicht je Datenperiode, kein Anteil), je
            Pfadzeile über die Kalendertage aufgezinst, Π (1 + r/100)^Tage/365.25. Bei Ergebnislisten nur ``None``
            oder eine Zahl.
        inflation_type: Behandlung einer Zusatzreihe in ``inflation``: ``"level"`` (Reihe ist ein
            Preisindex-Niveau; Inflation = Verhältnis des kumulierten Niveaus an den Periodenenden, d. h. die
            historischen Zeilenverhältnisse der gezogenen Zeilen) oder ``"rate_pa"`` (Reihe ist eine
            Inflationsrate in Prozent pro Jahr, 2 = 2 % p. a., nicht je Datenperiode, kein Anteil; je Pfadzeile
            über die Kalendertage aufgezinst, Π (1 + r/100)^Tage/365.25). Ist die Art der Reihe in
            ``bootstrap_config()`` mit ``aux_type`` ausdrücklich angegeben, ergibt sich die Behandlung daraus
            (``"level"`` bzw. ``"rate"`` -> ``"rate_pa"``); ``inflation_type`` kann dann entfallen und muss, wenn
            angegeben, dazu passen (sonst Fehler). Ohne Angabe in ``aux_type`` gilt das bisherige Verhalten: bei
            ``bootstrap_result`` entscheidet ``inflation_type`` (Standard ``"level"``; verwendet wird die
            Niveau-Variante im Pfad, Attribut ``aux_level`` aus ``bootstrap()``); bei Studien werden die mit
            ``keep_aux`` gespeicherten Faktoren (Niveau-Variante) unverändert verwendet, ein ausdrückliches
            ``inflation_type = "rate_pa"`` ist dort ein Fehler (die Rate lässt sich aus den gespeicherten Faktoren
            nicht gewinnen; ``aux_type = [<Name> = "rate"]`` angeben und die Studie neu rechnen).
        frequency: Periodenlänge: ``"year"`` (Standard), ``"quarter"`` oder ``"month"``. Bei Studien gilt
            stattdessen die gespeicherte Frequenz.
        dates, start: Nur bei ``bootstrap_result``: Kalender der Pfadzeilen. ``dates`` = Date-Vektor (oder in Date
            umwandelbar) mit genau einem Datum je Pfadzeile, streng aufsteigend; ``None`` (Standard) = tägliche
            Kalenderdaten ab ``start`` (Standard ``"2000-01-01"``), d. h. jede Pfadzeile zählt als ein
            Kalendertag. Für Pfade aus Handelstagen passende ``dates`` angeben (siehe ``bootstrap_data()``).
        cape: Nur bei ``bootstrap_result``: optional Name einer Pfadspalte mit CAPE-Werten (Wert zu
            Periodenbeginn) für die Regel ``"cape"``.

    Returns:
        Objekt der Klasse ``withdrawal_paths`` (Liste) mit ``returns`` (Matrix Perioden x Pfade der
        Brutto-Periodenrenditen), ``inflation`` (gleiche Form, Brutto-Inflation je Periode), ``cape`` (Matrix oder
        ``None``), ``base_rate = None``, ``frequency``, ``start_dates = None``, ``historical = False``,
        ``weights`` (Pfadgewichte oder ``None``) und ``source`` (Spaltenname, ``"study:"`` mit angehängtem
        Strategienamen oder ``"results"``).

    Details:
        Akzeptierte Eingaben ``x``:

        - ``SimLevBootstrapStudy``: Ergebnis von ``bootstrap_study()``, das mit ``keep_returns = "year"``,
          ``"quarter"`` oder ``"month"`` gerechnet wurde. Verwendet die gespeicherten zeitgewichteten
          Periodenrenditen der Strategie ``strategy`` und deren Frequenz (``frequency`` wird ignoriert); Pfade mit
          fehlenden Werten entfallen; die Pfadgewichte der Studie werden übernommen.
        - Liste von ``SimLevResult``: z. B. gespeicherte Läufe von ``simulation()`` auf Bootstrap-Pfaden; je
          Element ein Pfad über dessen zeitgewichteten Wertindex (``result_index()``). Alle Ergebnisse müssen
          gleich viele Tage haben; der Kalender des ersten Ergebnisses gilt.
        - ``bootstrap_result``: Ergebnis von ``bootstrap()``; ``column`` wählt die Kursspalte der Pfade, die
          Pfadgewichte werden übernommen.

        Ein einzelnes ``SimLevResult`` wird hier nicht angenommen (dafür ``withdrawal_cohorts()``). Bereits
        fertige ``withdrawal_paths`` (aus ``withdrawal_cohorts()`` oder ``bootstrap_pooled()``) und
        Renditematrizen werden direkt an ``withdrawal_simulation()`` übergeben; ``withdrawal_simulation()`` ruft
        diese Funktion für Studien und Ergebnislisten auch selbst auf.

    Beispiel::

        import numpy as np, pandas as pd, simlev
        rng = np.random.default_rng(2)
        d = pd.DataFrame({"us": 1 + rng.normal(3e-4, 0.01, 1500), "infl": 2.0})
        cfg = simlev.bootstrap_config({"us": "us"}, aux={"infl": "infl"})
        b = simlev.bootstrap(d, cfg, method="stationary", n=20, params={"L": 50}, path_length=3653, seed=1, progress=False)
        wp = simlev.withdrawal_paths(b, column="us", inflation="infl", inflation_type="rate_pa")
        print(wp["returns"].shape)   # 10 Jahre x 20 Pfade
    """
    it_given = inflation_type is not _DEF_IT
    frequency = _match_arg(frequency, _DEF_FREQ)
    inflation_type = _match_arg(inflation_type, _DEF_IT)
    if inflation is not None:
        ok_inf = isinstance(inflation, str) or (_num1(inflation))
        if isinstance(inflation, (list, tuple, np.ndarray, pd.Series)) or not ok_inf:
            _stop("inflation muss NULL, eine Zahl (Prozent p. a.) oder der Name einer Zusatzreihe sein.")

    def infl_from(n_per, n_paths, ends_dates):
        if inflation is None:
            return np.ones((n_per, n_paths))
        if isinstance(inflation, str):
            return None
        f = _pow_vec(1 + float(inflation) / 100, np.diff(_dates_days(ends_dates)).astype(np.float64) / 365.25)
        return np.resize(f, n_per * n_paths).reshape((n_per, n_paths), order="F")

    def mk(R, I, C, w, src, freq):
        return WithdrawalPaths([
            ("returns", _as_matrix(R)), ("inflation", _as_matrix(I)), ("cape", _as_matrix(C) if C is not None else None),
            ("base_rate", None), ("frequency", freq), ("start_dates", None), ("historical", False), ("weights", w),
            ("source", src)])

    # 1) Gespeicherte Bootstrap-Studie
    if _is_study(x):
        if x.get("returns") is None:
            _stop("Die Studie enthält keine Periodenrenditen; bootstrap_study(..., keep_returns = 'year') "
                  "verwenden.")
        rets = x["returns"]
        strategy = list(rets.keys())[0] if strategy is None else strategy
        if strategy not in rets:
            _stop("Strategie '%s' nicht gespeichert. Verfügbar: %s" % (strategy, ", ".join(rets.keys())))
        freq = x["returns_frequency"]
        R = np.asarray(rets[strategy], dtype=np.float64)
        ok = np.isnan(R).sum(axis=0) == 0
        if isinstance(inflation, str):
            ar = x.get("aux_returns") or {}
            if ar.get(inflation) is None:
                _stop("Zusatzreihe '%s' nicht gespeichert (keep_aux)." % inflation)
            kind = _aux_kind(x["config"], inflation, it_given, inflation_type)
            if kind is None and it_given and inflation_type == "rate_pa":
                _stop(("inflation_type = 'rate_pa': die mit keep_aux gespeicherten Faktoren der Zusatzreihe '%s' sind "
                       "die Niveau-Variante (Reihe nicht in aux_type genannt). Für eine Rate in Prozent p. a. "
                       "aux_type = c(%s = 'rate') in bootstrap_config() angeben und die Studie neu rechnen.")
                      % (inflation, inflation))
            I0 = np.asarray(ar[inflation], dtype=np.float64)
            r = I0[:, ok]
            bad = ~np.isfinite(r) | (r <= 0)
            if bad.any():
                first = r.ravel(order="F")[bad.ravel(order="F")][0]
                if kind == "rate":
                    msg = "Zusatzreihe '%s' (aux_type 'rate') ergibt nicht endliche oder nicht positive Periodenfaktoren (z. B. %s)."
                else:
                    msg = ("Zusatzreihe '%s' ist kein positives Niveau (gespeicherte Periodenverhältnisse nicht "
                           "endlich oder <= 0, z. B. %s); für eine Rate in Prozent p. a. aux_type = c(<Name> = "
                           "'rate') in bootstrap_config() angeben.")
                _stop(msg % (inflation, _fmt_nan(first, digits=4)))
            I = I0
        else:
            I = infl_from(R.shape[0], R.shape[1], x["returns_dates"])
        w = x.get("path_weights")
        return mk(R[:, ok], I[:, ok], None, None if w is None else np.asarray(w, dtype=np.float64)[ok],
                  "study:" + strategy, freq)
    # 2) Liste von simulation()-Ergebnissen
    if not _is_boot_result(x) and _is_result_list(x):
        if isinstance(inflation, str):
            _stop("Bei Ergebnislisten ist 'inflation' ein Prozentsatz p. a.")
        lst = list(x.values()) if isinstance(x, Mapping) else list(x)
        idx = [result_index(r) for r in lst]
        ends = _anniv_ends(idx[0]["date"].to_numpy(), frequency)
        if len(ends) < 2:
            _stop("Ergebnisse zu kurz für eine volle Periode.")
        vecs = []
        for d in idx:
            if len(d) != len(idx[0]):
                _stop("Alle Ergebnisse müssen gleich lang sein.")
            v = d["value"].to_numpy()[ends - 1]
            vecs.append(v[1:] / v[:-1])
        R = _vapply_mat(vecs, len(ends) - 1)
        return mk(R, infl_from(R.shape[0], R.shape[1], idx[0]["date"].to_numpy()[ends - 1]), None, None, "results",
                  frequency)
    # 3) bootstrap()-Pfade
    if not _is_boot_result(x):
        _stop("x muss ein bootstrap_result, eine Liste von SimLevResult oder eine SimLevBootstrapStudy sein.")
    if column is None:
        _stop("Bei bootstrap_result muss 'column' angegeben werden.")
    P1 = x["paths"][0]
    cn = [str(c) for c in P1.columns]
    if column not in cn:
        _stop("Spalte '%s' nicht im Pfad. Verfügbar: %s" % (column, ", ".join(cn)))
    nr = P1.shape[0]
    if dates is None:
        d0 = np.asarray(_to_date(start, "start")).astype("datetime64[D]").ravel()[0]
        dates = d0 + np.arange(nr).astype("timedelta64[D]")
    else:
        dates = np.asarray(_to_date(dates, "dates")).astype("datetime64[D]")
        if len(dates) != nr:
            _stop("dates hat Länge %d, die Pfade haben %d Zeilen (path_length + 1); ein Datum je Pfadzeile angeben."
                  % (len(dates), nr))
        if np.isnat(dates).any() or (np.diff(_dates_days(dates)) <= 0).any():
            _stop("dates muss streng aufsteigend sein und darf kein NA enthalten.")
    ends = _anniv_ends(dates, frequency)
    if len(ends) < 2:
        _stop("Pfade zu kurz für eine volle Periode der gewählten frequency.")
    e1 = ends[1:] - 1
    e0 = ends[:-1] - 1

    def per(v):
        v = np.asarray(v, dtype=np.float64)
        return v[e1] / v[e0]

    n_per = len(ends) - 1
    R = _vapply_mat([per(P[column].to_numpy()) for P in x["paths"]], n_per)
    I = infl_from(R.shape[0], R.shape[1], dates[ends - 1])
    if I is None:
        if inflation not in cn:
            _stop("Zusatzreihe '%s' nicht im Pfad. Verfügbar: %s" % (inflation, ", ".join(cn)))
        kind = _aux_kind(_get(x, "config", {}), inflation, it_given, inflation_type)
        if kind is not None:
            inflation_type = "level" if kind == "level" else "rate_pa"
        dt = np.diff(_dates_days(dates)).astype(np.float64) / 365.25
        vecs = []
        for P in x["paths"]:
            if inflation_type == "rate_pa":
                v = P[inflation].to_numpy(dtype=np.float64)
                r = per(r_cumprod(np.concatenate([[1.0], _pow_vec(1 + v[1:] / 100, dt)])))
                bad = ~np.isfinite(r) | (r <= 0)
                if bad.any():
                    _stop("Zusatzreihe '%s' (Rate in Prozent p. a.) ergibt nicht endliche oder nicht positive "
                          "Periodenfaktoren (z. B. %s; Rate <= -100 %%?)." % (inflation, _fmt_nan(r[bad][0], digits=4)))
                vecs.append(r)
                continue
            lv = P.attrs.get("aux_level") if isinstance(P, pd.DataFrame) else None
            if kind == "level":
                v = P[inflation].to_numpy(dtype=np.float64)
            elif lv is not None and inflation in [str(c) for c in lv.columns]:
                v = lv[inflation].to_numpy(dtype=np.float64)
            elif _get(x, "method") in ("wild", "reset"):
                v = P[inflation].to_numpy(dtype=np.float64)
            else:
                _stop(("inflation_type = 'level': Pfad ohne Niveau-Variante der Reihe '%s' (Attribut aux_level); "
                       "beim Verfahren '%s' springen die Originalwerte an Blockgrenzen. Pfade mit bootstrap() neu "
                       "erzeugen.") % (inflation, _get(x, "method")))
            r = per(v)
            if (~np.isfinite(r) | (r <= 0)).any():
                _stop("Zusatzreihe '%s' ist kein positives Niveau (Verhältnisse nicht endlich oder <= 0); für "
                      "eine Rate inflation_type = 'rate_pa' verwenden." % inflation)
            vecs.append(r)
        I = _vapply_mat(vecs, n_per)
    C = None
    if cape is not None:
        cv = [P[cape].to_numpy(dtype=np.float64)[e0] for P in x["paths"]]
        C = np.array([v[0] for v in cv]) if n_per == 1 else np.column_stack(cv)
    w = _get(x, "weights")
    return mk(R, I, C, w, column, frequency)


# ═══════════════════════════════════════════════════════════════════════════
# Perfect Withdrawal Rate
# ═══════════════════════════════════════════════════════════════════════════

@_quiet
def _annual_real(wp):
    """Reale Jahresrenditen aus Perioden-Matrizen (R: ``.annual_real``)."""
    ppy = _wd_ppy(wp["frequency"])
    real = np.asarray(wp["returns"], dtype=np.float64) / np.asarray(wp["inflation"], dtype=np.float64)
    if ppy == 1:
        return real
    npr = real.shape[0]
    ny = npr // ppy
    if real.ndim != 2 or ny < 1 or not real.shape[1]:
        sub = real[:ny * ppy, :]
        return _apply_cols(sub, lambda c: [r_prod(c[i:i + ppy]) for i in range(0, len(c), ppy)])
    A = _wcore.wd_annual_prod(real, ppy)       # Produkt je Jahr im Kern; bei einem Jahr ein Vektor (wie apply)
    return A[0, :].copy() if ny == 1 else A


@_quiet
def withdrawal_perfect_rate(real_returns, *, legacy=0):
    """Perfect Withdrawal Rate (PWR) je Pfad in Prozent.

    Exakte konstante reale Entnahmerate, die ein Depot bei gegebener Renditefolge genau aufbraucht bzw. das
    Zielvermögen hinterlässt (Suarez, Suarez & Walz 2015; Entnahme jeweils zu Jahresbeginn): PWR = (R_n - K_E/K_S)
    · S_n, R_n = Π (1+r_i), S_n = 1 / Σ_i=1^n Π_j=i^n (1 + r_j)

    Args:
        real_returns: Numerische Matrix (Jahre x Pfade) realer Brutto-Jahresrenditen (z. B. 1.05 = +5 % real; ein
            Vektor gilt als ein Pfad) oder ein ``withdrawal_paths``-Objekt: dann werden ``returns / inflation`` je
            Periode zu Jahren aufmultipliziert (ein unvollständiges letztes Jahr entfällt).
        legacy: Reales Zielvermögen am Ende als Anteil des Startvermögens (K_E / K_S; 0 = aufbrauchen (Standard),
            0.5 = 50 % erhalten; >= 0). Renditen müssen Brutto-Renditen sein (1.05, nicht 0.05); eine Matrix mit
            Median unter 0.5, negativen oder nicht endlichen Werten ist ein Fehler.

    Returns:
        Numerischer Vektor der PWR je Pfad in Prozent des Startvermögens (4 = 4 % je Jahr).

    Details:
        Die PWR hängt nur von der realen Renditefolge ab (keine Steuern, Verkaufskosten oder weiteren Einkommen).

    Beispiel::

        import numpy as np, simlev
        R = np.exp(np.random.default_rng(1).normal(0.03, 0.12, (30, 5)))   # 30 Jahre, 5 Pfade, real
        print(simlev.withdrawal_perfect_rate(R))
    """
    if _is_wp(real_returns):
        real_returns = _annual_real(real_returns)
    try:
        R = _as_matrix(real_returns)
    except (TypeError, ValueError):
        R = None
    msg_a = ("withdrawal_perfect_rate: real_returns muss eine Matrix endlicher realer Brutto-Jahresrenditen sein "
             "(1.05 = +5 %).")
    if R is None or not R.size:
        _stop(msg_a)
    lv = _num_vec(legacy)
    lg_ok = lv is not None and lv.size == 1 and math.isfinite(lv[0]) and lv[0] >= 0
    # Prüfungen (nicht endlich, Median, negativ) und PWR je Spalte im Kern (core/withdrawal_core_impl.h, wd_pwr)
    out, st, _ = _wcore.wd_pwr(R, float(lv[0]) if lg_ok else 0.0)
    if st == 1:
        _stop(msg_a)
    if st == 2:
        med = r_median(R.ravel(order="F"))
        _stop(("withdrawal_perfect_rate: real_returns sieht nicht wie Brutto-Renditen aus (Median %s); erwartet z. B. "
               "1.05 für +5 %%, nicht 0.05 (Nettorendite: 1 + r übergeben).") % _fmt1(med, digits=4))
    if st == 3:
        _stop("withdrawal_perfect_rate: Brutto-Renditen in real_returns müssen >= 0 sein (0 = Totalverlust).")
    if not lg_ok:
        _stop("withdrawal_perfect_rate: legacy muss ein Anteil >= 0 sein (0.5 = 50 %% des Startvermögens; "
              "erhalten: %s)." % _show(legacy))
    return out


# ═══════════════════════════════════════════════════════════════════════════
# Lots der Ansparphase
# ═══════════════════════════════════════════════════════════════════════════

def _lots_df(a):
    L = _get(a, "lots")
    return L


def _last_worth(report, nm):
    r = _get(report, nm)
    wv = np.asarray(_get(r, "worth", np.zeros(0)), dtype=np.float64).ravel()
    return wv[-1:] if len(wv) else wv


def _wd_held(ol, report, sv, tol=1e-12):
    """Am Ende der Ansparphase gehaltene Assets (R: ``.wd_held``)."""
    out = []
    for nm in (ol.keys() if isinstance(ol, Mapping) else []):
        L = _lots_df(ol[nm])
        wv = _last_worth(report, nm)
        units = np.asarray(L["units"], dtype=np.float64) if L is not None and len(L) else np.zeros(0)
        if L is not None and len(L) > 0 and r_sum(units) > 0 and len(wv) == 1 and math.isfinite(wv[0]) and \
                wv[0] > tol * sv:
            out.append(nm)
    return out


@_quiet
def _wd_lots(ol, report, sv, tol=1e-12):
    """Offene Lots als FIFO-Bestand für den Kern (R: ``.wd_lots``)."""
    n, basis, vp, group = [], [], [], []
    g = 0
    assets = 0.0
    for nm in _wd_held(ol, report, sv, tol):
        L = _lots_df(ol[nm])
        units = np.asarray(L["units"], dtype=np.float64)
        U = r_sum(units)
        keep = units > 0
        u = units[keep]
        pr = np.asarray(L["price"], dtype=np.float64)[keep]
        v = np.asarray(L["vp"], dtype=np.float64)[keep]
        wv = float(_last_worth(report, nm)[0])
        n.extend((u / U * wv).tolist())
        basis.extend((u * pr).tolist())
        vp.extend(v.tolist())
        group.extend([g] * len(u))
        g += 1
        assets = assets + wv
    cash = sv - assets
    if abs(cash) > tol * sv:
        n.append(cash)
        basis.append(cash)
        vp.append(0.0)
        group.append(g)
    return {"n": np.array(n), "basis": np.array(basis), "vp": np.array(vp), "group": np.array(group, dtype=np.int64)}


def _wd_fee_set(f) -> bool:
    """Ist eine Ordergebühr gesetzt (Zahl oder dict(fixed, percent, min, max))?"""
    if f is None:
        return False
    if isinstance(f, Mapping):
        vals = [f[k] for k in f.keys() if k in ("fixed", "percent", "min")]
        v = []
        for z in vals:
            v.extend(np.atleast_1d(np.asarray(z, dtype=object)).ravel().tolist())
    else:
        v = np.atleast_1d(np.asarray(f, dtype=object)).ravel().tolist()
    out = []
    for z in v:
        try:
            out.append(float(z))
        except (TypeError, ValueError):
            out.append(_NAN)
    return any(math.isfinite(z) and z != 0 for z in out)


# ═══════════════════════════════════════════════════════════════════════════
# withdrawal_simulation()
# ═══════════════════════════════════════════════════════════════════════════

class SimLevWithdrawal(RList):
    """Ergebnis von :func:`withdrawal_simulation` (R-Klasse ``SimLevWithdrawal``)."""

    r_class = ("SimLevWithdrawal",)

    def summary(self, probs=(0.05, 0.25, 0.5, 0.75, 0.95)):
        return _summary_wd(self, probs=probs)

    # ``plot`` (SVG, ``SimLevPlot``) wird am Modulende über ``_plot_method`` gesetzt.

    def format(self, **kwargs) -> str:
        # R print.SimLevWithdrawal(x, ...): print(summary(x, ...)); ``probs`` geht an summary,
        # andere Schlüsselwörter fängt R's summary-Methode über ``...`` ab (ignoriert).
        return self.summary(**{k: v for k, v in kwargs.items() if k == "probs"}).format()

    def print(self, **kwargs):
        print(self.format(**kwargs))
        return self


class SummarySimLevWithdrawal(RList):
    """Zusammenfassung (R-Klasse ``summary.SimLevWithdrawal``)."""

    r_class = ("summary.SimLevWithdrawal",)

    def format(self) -> str:
        return _strip1(_cat_summary_wd(self))


_D30 = _Dflt(30.0)
_D1000 = _Dflt(1000.0)
_D0 = _Dflt(0.0)
_D100 = _Dflt(100.0)
_D0LC = _Dflt(0.0)


def _is_logical1(v) -> bool:
    return isinstance(v, (bool, np.bool_))


@_quiet
def _wd_tax_mode(tax):
    """Steuerangaben der Person prüfen (R: ``.wd_tax_mode``): ``None`` → ``"none"``,
    ``tax_profile()`` → ``"person"``. Ausgewertet werden ``rate``, ``church_tax``, ``sparer_pauschbetrag``,
    ``guenstigerpruefung`` und ``income_rate()`` bzw. ``income_tariff()`` (Tarifweg T1); ``private_sale_threshold``
    ≠ 1000, ``base_rate`` und ``harvest`` ergeben einen Fehler."""
    if tax is None:
        return "none"
    from ._sim_blocks import SimLevTaxProfile
    if not isinstance(tax, SimLevTaxProfile):
        from ._sim_blocks import _cls
        _stop("withdrawal_simulation: tax muss NULL oder ein Objekt aus tax_profile() sein, nicht %s." % _cls(tax))
    pst = tax["private_sale_threshold"]
    un = [("private_sale_threshold", not (_num1(pst) and float(pst) == 1000)),
          ("base_rate", tax["base_rate"] is not None), ("harvest", tax["harvest"] is not None)]
    bad = [k for k, v in un if v]
    if bad:
        _stop("withdrawal_simulation: tax_profile(%s) bildet die Entnahmephase nicht ab; ausgewertet werden rate, "
              "church_tax, sparer_pauschbetrag, guenstigerpruefung und income = income_rate() oder income_tariff() "
              "(Basiszins über base_rate von withdrawal_simulation())." % ", ".join(bad))
    return "person"


_WD_TARIFF_COLS = ("year", "taxable_income", "church_tax_paid_deductible", "church_tax_refunded",
                   "church_tax_net_deduction", "taxable_income_net", "deduction_effect", "gain_p23", "income_tax_p23",
                   "soli_p23", "church_tax_p23", "tax_p23", "capital_income", "abgeltung_burden", "church_tax_withheld_k",
                   "tariff_income_tax_k", "tariff_soli_k", "tariff_church_tax_k", "tariff_burden", "burden_without_gp",
                   "burden_with_gp", "guenstiger", "settlement", "refund", "church_tax_settlement_next_year")


def _wd_tariff_par(tt, church_k, use_gp):
    """Tarifparameter für den Kern (R: ``.wd_tariff_par``, ``core/tariff_core_impl.h``)."""
    z = tt.zones
    so = tt.soli
    out = [1.0 if use_gp is True else 0.0, church_k, 0.25 / (1 + 0.25 * church_k), float(so["freigrenze"]),
           float(so["satz"]), float(so["milderung"]), float(len(z))]
    for c in ("ab", "bezug", "teiler", "a", "b", "c"):
        out += [float(v) for v in z[c]]
    return np.array(out, dtype=np.float64)


def _wd_zve(x, ny, year1):
    """zvE je Planjahr für den Tarifweg der Entnahme (R: ``.wd_zve``): Zahl für alle Planjahre, Vektor ohne
    Namen der Länge ``ny``, nach Kalenderjahren benannt nur mit ``year1``; Länge ``ny + 1`` (Folgejahr ggf. NA)."""
    from ._sim_base import _check_taxable_income
    who = "withdrawal_simulation"
    form = ("eine Zahl (zvE in EUR für alle Planjahre), ein Vektor ohne Namen mit einem Wert je Planjahr (Länge %d)%s"
            % (ny, "" if year1 is None else
               " oder nach Kalenderjahren benannt (Vektor bzw. data.frame mit den Spalten year und taxable_income; "
               "Planjahr 1 = %d)" % year1))
    zv = _check_taxable_income(x, [], who="income_tariff", plan_ok=True)
    if zv["all"] is not None:
        return np.full(ny + 1, float(zv["all"]))
    if zv.get("plan") is not None:
        v = zv["plan"]
        if len(v) == ny:
            return np.array(list(v) + [_NA], dtype=np.float64)
        _stop("%s: taxable_income (income_tariff()) hat %d Werte, die Entnahme %d Planjahre; erwartet wird %s."
              % (who, len(v), ny, form))
    if year1 is None:
        _stop("%s: taxable_income (income_tariff()) nach Kalenderjahren lässt sich nur mit einem SimLevResult als "
              "start_value auf Planjahre abbilden (Planjahr 1 = tax_report$next_year$year); erwartet wird %s."
              % (who, form))
    zv = _check_taxable_income(x, list(range(year1, year1 + ny)), who=who)
    by = zv["by_year"]
    return np.array([float(by[str(y)]) if str(y) in by else _NA for y in range(year1, year1 + ny + 1)],
                    dtype=np.float64)


def _wd_tariff_years(M, ny):
    """Jahreszeilen des Tarifwegs als ``DataFrame`` (R: ``.wd_tariff_years``): ``path``, ``year`` (Planjahr) und
    die Spalten von ``tax_report["tariff_years"]`` aus ``simulation()``, nach Pfad und Jahr."""
    C = _wcore.wd_tariff_compact(M, ny)              # Spalten mit Jahr NA entfallen (Kern)
    d = {"path": C[:, 0].astype(np.int64)}
    for j, c in enumerate(_WD_TARIFF_COLS):
        col = C[:, j + 1].copy()
        if c == "year":
            col = col.astype(np.int64)
        elif c == "guenstiger":
            col = col != 0
        d[c] = col
    return pd.DataFrame(d)


def withdrawal_simulation(x, *, rule=None, start_value=1e6, inflation=0, frequency=_DEF_FREQ, strategy=None, years=None,
                          timing=("start", "end"), income=None, tax=None,
                          partial_exemption=_D30, base_rate=3.20, vorabpauschale=_D_TRUE,
                          sale_cost=_D0, cost_basis=_D100, loss_carryforward=_D0LC, gamma=2, keep_paths=True,
                          horizon=None):
    """Entnahme-Simulation über viele Pfade.

    Simuliert eine Entnahmeregel auf historischen Kohorten (``withdrawal_cohorts()``), Bootstrap-Pfaden
    (``withdrawal_paths()``, ``bootstrap_pooled()``), gespeicherten Ergebnissen von ``simulation()`` bzw.
    ``bootstrap_study()`` oder einer beliebigen Renditematrix. Je Pfad entstehen Erfolg, Erschöpfungsjahr, reales
    Endvermögen, Konsumkennzahlen, Steuern und die Perfect Withdrawal Rate. Der Rechenkern ist in C++
    implementiert.

    Args:
        x: Renditequelle, eine der folgenden:

            - ``withdrawal_paths``: aus ``withdrawal_cohorts()``, ``withdrawal_paths()`` oder
              ``bootstrap_pooled()``; Inflation und Frequenz stammen aus dem Objekt (``inflation`` und
              ``frequency`` werden ignoriert).
            - Matrix: (Perioden x Pfade) von Brutto-Periodenrenditen nach Produktkosten (1.05 = +5 Prozent); keine
              negativen Werte, Median >= 0.5.
            - ``SimLevResult``: historische Kohorten über dessen Verlauf, Länge ``years`` (Standard 30 Jahre).
            - ``SimLevWrapperNav``: Anteilswert eines Fonds-Wrappers aus ``wrapper_nav()``: historische Kohorten
              über die Spalte ``nav`` wie ``withdrawal_cohorts(x, price = "nav")``, Länge ``years`` (Standard 30
              Jahre). Nur das ganze Objekt: Ein Ausschnitt (``x[i, ]``, ``head()``, ``subset()``) ist ein
              gewöhnlicher ``data.frame``; Tabellen mit Spalte ``date`` ergeben einen Fehler mit Hinweis auf
              ``withdrawal_cohorts(x, price = "nav")``.
            - Liste von ``SimLevResult`` oder ``SimLevBootstrapStudy``: (mit ``keep_returns``; Strategie über
              ``strategy``) je Element bzw. Studienpfad ein Pfad.
        rule: Objekt aus ``withdrawal_rule()`` (Standard: konstante reale Entnahme mit 4 %).
        start_value: Startvermögen als Geldbetrag > 0 (Standard 1e6) oder ein ``SimLevResult`` der Ansparphase:
            dann gilt dessen letzter Depotwert (Stück x Schlusskurs ohne Spread plus Cash) als Startvermögen (ein
            Endwert <= 0, etwa durch eine offene Steuerschuld ``tax_report["open_tax_debt"]``, ist ein Fehler)
            und, sofern ``cost_basis`` nicht angegeben ist, wird ``cost_basis`` daraus abgeleitet (siehe dort).
            Mit Steuern (``tax = tax_profile()``) wird gewarnt, wenn die am Ende gehaltenen Assets eine andere
            Teilfreistellung als ``partial_exemption`` haben (Regime ``"capital_gains"`` zählt als 0 %) oder das
            Regime ``"private_sale"`` (§ 23 EStG) haben, das die Entnahmephase nicht abbildet. Mit Steuern werden
            außerdem die Lots (FIFO, siehe Details) und nicht angegebene ``partial_exemption``,
            ``loss_carryforward`` und ``sale_cost`` aus dem Ergebnis übernommen (siehe dort); was übernommen
            wurde, meldet ein Hinweis (``message()``) und steht im Ergebnis unter ``adopted``. Ausdrückliche
            Angaben haben immer Vorrang.
        inflation: Inflation für Eingaben ohne eigene Inflationsreihe: Zahl = konstante Inflation in Prozent p. a.
            (Standard 0; 2 = 2 % p. a.) bei Matrix-, Ergebnis-, Ergebnislisten- und Studien-Eingabe; bei
            Matrix-Eingabe auch eine Matrix gleicher Dimension mit Brutto-Periodeninflation (z. B. 1.002 je
            Monat); bei Studien auch der Name einer mit ``keep_aux`` gespeicherten Zusatzreihe (Behandlung wie in
            ``withdrawal_paths()`` ohne ``inflation_type``: eine Reihe mit ``aux_type = "rate"`` in
            ``bootstrap_config()`` gilt als Inflationsrate in Prozent pro Jahr, 2 = 2 % p. a., nicht je
            Datenperiode, kein Anteil, über die Kalendertage aufgezinst; ohne Angabe in ``aux_type`` wie bisher
            die gespeicherte Niveau-Variante). ``None`` wie 0. Bei ``withdrawal_paths`` ohne Wirkung.
        frequency: Periodenlänge der Zeilen bei Matrix-Eingabe bzw. der erzeugten Perioden bei Ergebnis- und
            Ergebnislisten-Eingabe: ``"year"`` (Standard), ``"quarter"`` oder ``"month"``. Bei
            ``withdrawal_paths`` und Studien gilt die gespeicherte Frequenz.
        strategy: Bei ``SimLevBootstrapStudy``: Name der Strategie (``None`` = erste gespeicherte).
        years: Optional Anzahl Jahre (> 0, ``years`` x Perioden je Jahr muss ganzzahlig sein): Kürzung auf die
            ersten ``years`` Jahre (``years`` x Perioden je Jahr Zeilen). Bei einem ``SimLevResult`` zugleich die
            Kohortenlänge (``None`` = 30). ``None`` (Standard) = volle Pfadlänge.
        timing: Zeitpunkt der Entnahme innerhalb jeder Periode: ``"start"`` (Standard; vor der Rendite) oder
            ``"end"`` (nach der Rendite).
        income: Optional weitere Einkommen (z. B. gesetzliche Rente): Liste von Listen ``{"start": Jahr, "end":
            Jahr, "amount": Betrag}``; ein einzelnes ``{"start": ..., "end": ..., "amount": ...}`` wird
            automatisch verpackt. ``start``/``end`` sind Planjahre (Standard 1 bzw. letztes Jahr, ``start <=
            end``; Jahre nach dem Pfadende entfallen), ``amount`` ist ein realer Jahresbetrag in Kaufkraft des
            Startzeitpunkts. Einkommen mindern die Depotentnahme (Entnahme = max(0, Regelbetrag - Einkommen)) und
            zählen im Konsum (``spending``) mit.
        tax: Steuerdaten der Person: ``None`` (Standard; keine Steuern) oder ein Objekt aus ``tax_profile()``
            (vereinfachte deutsche Besteuerung, siehe Details). Ausgewertet werden ``rate`` (Abgeltungsteuer inkl.
            Solidaritätszuschlag in Prozent, Standard 26.375), ``church_tax`` (Kirchensteuer in Prozent; der Satz
            der Abgeltungsteuer folgt dann § 32d Abs. 1 EStG wie in ``simulation()``), ``guenstigerpruefung`` mit
            ``income = income_rate()`` (Günstigerprüfung wie in ``simulation()``: einmal je Lauf; ist der
            Grenzsteuersatz einschließlich Soli und Kirchensteuer niedriger als die Abgeltungsteuer, gilt er für
            alle Verkäufe und Vorabpauschalen aller Pfade und Planjahre; ohne ``income`` Warnung und
            Abgeltungsteuer; ``income_rate()`` ohne ``guenstigerpruefung = True`` wirkt nicht) und
            ``sparer_pauschbetrag`` (Sparer-Pauschbetrag je Planjahr als nominaler Geldbetrag, Standard 1000; 2000
            bei Zusammenveranlagung; 0 = ohne). Bei ``start_value`` = ``SimLevResult`` mit
            ``tax_report["next_year"]`` steht im ersten Planjahr nur dieser Betrag minus
            ``next_year["sparer_pauschbetrag_used"]`` zur Verfügung (siehe Details, Kalender; bei gleichem
            Pauschbetrag wie in der Ansparphase ``next_year["sparer_pauschbetrag_remaining"]``). Angaben, die die
            Entnahmephase nicht abbildet (``private_sale_threshold`` ungleich 1000, ``base_rate``, ``harvest``),
            ergeben einen Fehler; der Basiszins kommt aus ``base_rate`` dieser Funktion. Mit ``income =
            income_tariff(taxable_income, tariff)`` rechnet die Entnahmephase den Tarifweg wie ``simulation()``:
            unterjährig Abgeltungsteuer, nach jedem Planjahr je Pfad eine Veranlagung (siehe Details, Tarifweg).
            ``taxable_income`` ist das zu versteuernde Einkommen ohne die Erträge der Entnahme, nominal in EUR
            genau wie angegeben (ohne Fortschreibung mit der Inflation): eine Zahl gilt für alle Planjahre, ein
            Vektor ohne Namen braucht einen Wert je Planjahr; nach Kalenderjahren benannt (Vektor oder DataFrame
            wie in ``simulation()``) nur mit einem ``SimLevResult`` als ``start_value`` (Planjahr 1 =
            ``tax_report["next_year"]$year``), sonst Fehler. ``income`` dieser Funktion zählt nicht zum zvE; einen
            steuerpflichtigen Teil (etwa einer Rente) selbst in ``taxable_income`` einrechnen. Kirchensteuer und
            Günstigerprüfung werden nicht aus der Ansparphase (``start_value`` = ``SimLevResult``) übernommen,
            sondern hier ausdrücklich in ``tax_profile()`` angegeben. Die Bestandsmerkmale (``partial_exemption``,
            ``vorabpauschale``, ``cost_basis``, ``loss_carryforward``, ``sale_cost``) sind eigene Argumente. Wie
            in ``simulation()`` sind ``partial_exemption``, ``sale_cost``, ``cost_basis``, ``loss_carryforward``
            und ``gamma`` einzelne endliche Zahlen im zulässigen Bereich (sonst Fehler); Werte zwischen 0 und 1
            bei ``partial_exemption`` und ``cost_basis`` sowie zwischen 0 und 0,05 bei ``inflation`` (Zahl) und
            ``base_rate`` (Zahl) lösen eine Warnung aus (vermutlich Anteil statt Prozent).
        partial_exemption: Teilfreistellung in Prozent (Standard 30 für Aktienfonds; 15 für Mischfonds). Nicht
            angegeben und ``start_value`` ein ``SimLevResult`` mit ``open_lots``: die gemeinsame Teilfreistellung
            der am Ende gehaltenen Assets (Regime ``"capital_gains"`` = 0), sofern alle denselben Wert haben und
            keines das Regime ``"private_sale"`` hat und keine Fonds neben anderen Regimen gehalten werden; sonst
            30 mit Warnung. Als gehalten gelten Assets mit Endwert > 1e-12 x Depotwert (Stückreste ohne Wert
            zählen nicht).
        base_rate: Basiszins für die Vorabpauschale in Prozent (Standard 3.20 für 2026; negative Werte zählen als
            0): Skalar oder Matrix (Perioden x Pfade, gleiche Dimension wie die Renditen vor einer Kürzung mit
            ``years``), maßgeblich ist der Wert der letzten Periode jedes Planjahres. Enthält ``x`` eine
            Basiszins-Reihe (Argument ``base_rate`` in ``withdrawal_cohorts()``), wird diese verwendet.
        vorabpauschale: Logisch: Vorabpauschale berücksichtigen (Standard ``True``; nur mit ``tax =
            tax_profile()`` wirksam). Nicht angegeben und ``start_value`` ein ``SimLevResult`` mit ``open_lots``,
            in dem kein gehaltenes Asset das Regime ``"investment_fund"`` hat (nur ETN/Zertifikate,
            ``"capital_gains"``, bzw. ``"private_sale"``): ``False``, da ``simulation()`` dort keine
            Vorabpauschale erhebt. Bei Fonds neben anderen Regimen Warnung, keine Übernahme.
        sale_cost: Verkaufskosten in Prozent des Verkaufsbetrags (Standard 0; z. B. halber Spread). Nicht
            angegeben und ``start_value`` ein ``SimLevResult`` mit ``open_lots``: der halbe Spread (``spread``)
            der am Ende gehaltenen Assets, sofern alle denselben Spread haben (sonst 0 mit Warnung; ohne
            Spread-Angabe im Ergebnis 0). Ordergebühren bildet die Entnahmephase nicht ab; waren sie in der
            Ansparphase gesetzt, warnt die Funktion.
        cost_basis: Anschaffungskosten in Prozent des Startwerts (Standard 100 = frisch gekauft; kleiner bei
            Altbestand mit stillen Reserven), einschließlich bereits versteuerter Vorabpauschalen, die beim
            Verkauf nach § 19 InvStG angerechnet werden. Mit ``cost_basis`` rechnet die Entnahmephase mit
            Durchschnittskosten: jede Entnahme verbraucht den Anteil Entnahme / Depotwert der Basis. Ein
            ausdrücklich angegebener Wert gilt immer (auch bei einem ``SimLevResult``; dann ohne FIFO-Lots). Ist
            ``start_value`` ein ``SimLevResult`` und ``cost_basis`` nicht angegeben:

            - nur Cash am letzten Tag: (z. B. ``liquidate = True``): 100, alle Gewinne sind bereits versteuert.
            - mit offenen Lots: (Element ``open_lots``, nur Ergebnisse mit ``simulation(tax = tax_profile())``):
              mit ``tax = tax_profile()`` die Lots selbst (FIFO, siehe Details); ihre Summe entspricht 100 x
              (Anschaffungskosten ``units`` x ``price`` plus anzurechnende Vorabpauschalen ``vp`` aller Assets
              plus Cash) / Endwert. Ein Verkauf ergibt dieselbe Steuer wie in ``simulation()`` beim Verkauf
              derselben Stückzahl, wenn ``sale_cost`` dem halben Spread entspricht, keine Ordergebühr anfällt,
              alle Assets die Teilfreistellung ``partial_exemption`` haben und Topf und Sparer-Pauschbetrag gleich
              stehen.
            - sonst: (Ergebnis ohne Steuern oder älter): die Näherung 100 x (Startwert brutto + Summe der
              Einzahlungen) / Endwert, mit Warnung bei ``tax = tax_profile()``. Sie behandelt bereits realisierte
              (und versteuerte) Gewinne, Vorabpauschalen und Cash wie stille Reserven und überschätzt die spätere
              Steuer dann.
        loss_carryforward: Anfangsbestand des Verlusttopfs als nominaler Geldbetrag (Standard 0; Betrag nach
            Teilfreistellung wie in ``simulation()``). Nicht angegeben und ``start_value`` ein ``SimLevResult``
            mit ``open_lots``: der allgemeine Verlusttopf (Topf für Fonds und sonstige Kapitalerträge) zu Beginn
            des ersten Planjahres, ``tax_report["next_year"]$loss_carryforward_capital`` (ältere Ergebnisse ohne
            ``next_year``: ``tax_report["loss_carryforward_capital"]``); der Verlustvortrag für private
            Veräußerungsgeschäfte wird nicht übernommen.
        gamma: Relative Risikoaversion (CRRA, Zahl, Standard 2) für das Sicherheitsäquivalent der realen
            jährlichen Konsumreihe (``gamma = 1``: geometrisches Mittel).
        keep_paths: Vermögensmatrix ``wealth`` zurückgeben: ``True`` (Standard) = alle Pfade, ``False`` oder 0 =
            keine, ganze Zahl k >= 1 = die ersten k Pfade (Spalten; k größer als die Pfadzahl: alle). Gerechnet
            werden immer alle Pfade; ``plot()`` zeichnet den Vermögensfächer dann nur aus den behaltenen Pfaden
            (Titel mit „erste k von n Pfaden“). Bei historischen Kohorten sind das die frühesten Starts.
        horizon: Optional Laufzeit je Pfad: Objekt aus ``withdrawal_horizon()`` (zufällige Laufzeit in Jahren je
            Pfad) oder eine Zahl > 0 = feste Laufzeit in Jahren. ``None`` (Standard) = volle Pfadlänge. Dann gilt
            ein Pfad als erfolgreich, wenn das Vermögen bis zu seinem Horizont reicht; reales Endvermögen,
            Steuern, Konsumkennzahlen und PWR (diese nur bei Jahresperioden, sonst ``NA``) beziehen sich auf den
            jeweiligen Horizont; Endvermögen und Steuern enthalten dabei die Abrechnung der Vorabpauschale des
            Horizontjahres wie am Pfadende (ein Pfad mit H Jahren und Horizont H auf längeren Pfaden ergeben
            dasselbe) (``paths["horizon"]``, Erfolg über die volle Pfadlänge in ``paths["success_full"]``).
            Horizonte über der Pfadlänge werden mit Warnung gekürzt. Die Regel selbst rechnet weiter mit den
            Restjahren der vollen Pfadlänge. Nicht zu verwechseln mit ``horizon`` in ``planning_goal()``
            (Perioden).

    Returns:
        Objekt der Klasse ``SimLevWithdrawal`` (Liste):

        - ``paths``: DataFrame mit einer Zeile je Pfad: ``success`` (logisch: alle geplanten Entnahmen voll
          bezahlt bzw. planmäßig vollständig geleert, siehe Details), ``depletion_year`` (Planjahr der ersten
          Unterdeckung, sonst ``NA``), ``terminal_real`` (reales Endvermögen), ``terminal_nominal`` (nominales
          Endvermögen am Pfadende), ``first_withdrawal`` (realer Konsum im ersten Planjahr), ``mean_spending``,
          ``min_spending``, ``total_spending`` (Mittel, Minimum, Summe des realen Jahreskonsums),
          ``spending_drawdown`` (größter Rückgang des realen Konsums gegenüber dem bisherigen Höchststand, als
          Anteil 0 bis 1), ``ce_spending`` (Sicherheitsäquivalent nach ``gamma``); Mittel, Minimum, Rückgang und
          Sicherheitsäquivalent nur über volle Planjahre (ein unvollständiges letztes Planjahr zählt nur in
          ``total_spending``; ohne volles Jahr ``NA``), ``taxes`` (Summe der Steuern, real) und ``pwr`` (Perfect
          Withdrawal Rate in Prozent); bei Kohorten zusätzlich ``start`` (Startdatum), mit ``horizon`` zusätzlich
          ``horizon`` (Jahre) und ``success_full``.
        - ``spending``: Matrix Planjahre x Pfade: realer Konsum (Netto-Entnahme plus ``income``).
        - ``planned``: Matrix Planjahre x Pfade: von der Regel geplante Jahresentnahme (real, vor Abzug von
          ``income``).
        - ``wealth``: Matrix (Planjahre + 1) x Pfade: reales Vermögen zu Beginn jedes Planjahres, letzte Zeile am
          Ende; mit ``keep_paths = k`` nur die ersten k Spalten, ``None`` bei ``keep_paths = False``.
        - ``rule``, ``start_value``, ``frequency``, ``horizon``, ``tax_mode`` (``"person"`` mit ``tax``, sonst
          ``"none"``), ``gamma``, ``timing``: Eingaben.
        - ``years``, ``full_years``: Anzahl Planjahre (einschließlich eines unvollständigen letzten Jahres) bzw.
          voller Planjahre.
        - ``historical``: ``True`` bei historischen Kohorten.
        - ``adopted``: Nur bei ``start_value`` = ``SimLevResult`` und ``tax = tax_profile()``: benannte Liste der
          aus der Ansparphase übernommenen Werte (``lots`` = Anzahl FIFO-Lots einschließlich Cash-Position,
          ``cost_basis`` bei Durchschnittskosten, ``partial_exemption``, ``loss_carryforward``, ``sale_cost``,
          ``sparer_pauschbetrag_used_year1`` = im ersten Planjahr bereits verbrauchter Pauschbetrag,
          ``vorabpauschale`` = ``False`` ohne gehaltene Fonds); sonst ``None``.
        - ``weights``: Pfadgewichte (Standard 1 je Pfad).
        - ``source``: Herkunft der Renditen.
        - ``elapsed``: Rechenzeit in Sekunden (ab Start des Kerns).
        - ``tariff_years``: Nur mit dem Tarifweg (``income_tariff()``): DataFrame mit einer Zeile je Pfad und
          veranlagtem Planjahr, nach Pfad und Jahr: ``path``, ``year`` (Planjahr; Planjahre + 1 = Folgejahr am
          Pfadende) und dieselben Spalten wie ``tax_report["tariff_years"]`` in ``simulation()`` (zvE,
          Kirchensteuer-Sonderausgaben und ihre Wirkung, § 23-Spalten, in der Entnahme 0, ``capital_income`` = K,
          Abgeltungsteuer, Tarif auf K, Belastung ohne und mit Günstigerprüfung, ``guenstiger``, ``settlement`` >
          0 Nachzahlung bzw. < 0 Erstattung, ``refund``, ``church_tax_settlement_next_year``); Beträge nominal in
          EUR.

        Auswertung mit ``print()``, ``summary()`` und ``plot()`` (siehe SimLevWithdrawal-methods).

    Details:
        Ablauf je Planjahr: Zu Beginn legt die Regel den Jahresbetrag fest; er wird gleichmäßig auf die Perioden
        des Jahres verteilt und je nach ``timing`` zu Beginn oder Ende jeder Periode als Netto-Betrag entnommen
        (abzüglich ``income``). Ein Pfad scheitert, sobald eine geplante Entnahme nicht mehr voll bezahlt werden
        kann. Ausnahme Verzehrregeln (``one_over_n``, ``vpw``, ``abw``, ``hebeler``): Sie leeren das Depot
        planmäßig im letzten Planjahr bzw. in dem Jahr, für das sie das ganze Depot vorsehen (Jahresbetrag >=
        Depotwert zu Jahresbeginn, z. B. ``vpw`` bei Erreichen von ``max_age``). Wird das Depot in einem solchen
        Jahr vollständig verkauft und fällt die Entnahme dabei kleiner aus (Steuern und Kosten aus dem Erlös
        bezahlt, bei unterjährigen Perioden auch Kursverluste im Jahr), ist das kein Fehlschlag, sofern der
        Jahresbetrag das Depot zu Jahresbeginn nicht übersteigt (sonst, z. B. bei ``hebeler`` durch die Glättung,
        bleibt es ein Fehlschlag). Bei allen anderen Regeln zählt jede nicht voll bezahlte Entnahme als
        Fehlschlag. Alle "realen" Größen sind durch die aufgelaufene Inflation geteilt, also in Kaufkraft des
        Startzeitpunkts.

        Besteuerung (``tax = tax_profile()``): vereinfachtes Modell eines einzelnen thesaurierenden Fondsbestands
        nach heutiger Rechtslage (Modellphilosophie des Pakets): Verkaufsgewinne mit Teilfreistellung,
        Verlustverrechnung vor Sparer-Pauschbetrag, Abgeltungsteuer; Vorabpauschale zum Jahresende festgesetzt;
        sie gilt nach § 18 Abs. 3 InvStG am ersten Werktag des Folgejahres als zugeflossen und wird daher wie in
        ``simulation()`` mit Verlusttopf und Sparer-Pauschbetrag des Folgejahres versteuert, durch Anteilsverkauf
        beglichen und beim späteren Verkauf angerechnet. Die Vorabpauschale des letzten Planjahres wird am
        Pfadende abgerechnet wie in ``simulation()`` bei Datenende am 31.12.: die Steuer auf die VP wird vorab mit
        den Töpfen des Folgejahres (neuer Pauschbetrag, Verlusttopf am Jahresende) bestimmt und per Zwangsverkauf
        noch im ablaufenden Jahr bezahlt (Gewinn mit dessen Pauschbetrag und Verlusttopf); danach wird die
        VP-Steuer mit dem Verlusttopf nach diesem Verkauf endgültig berechnet und die Differenz ausgeglichen
        (Nachzahlung per Verkauf im Folgejahr, Erstattung als Geld ins Depot). Alle diese Steuern mindern das
        Endvermögen und zählen in ``taxes``; ebenso beim Endvermögen am Horizont (``horizon``). Während des Pfades
        wird die VP-Steuer dagegen zusammen mit der ersten Entnahme des Folgejahres verkauft (Töpfe des
        Folgejahres). Ohne Lots einer Ansparphase rechnet der Kern mit Durchschnittskosten (``cost_basis``); bei
        einer Einmalanlage ohne Zukäufe ist das identisch mit FIFO. Das Planjahr wird als Steuerjahr behandelt;
        der Sparer-Pauschbetrag steht in jedem Planjahr neu und nominal unverändert zur Verfügung.

        FIFO mit den Lots einer Ansparphase: Ist ``start_value`` ein ``SimLevResult`` mit ``open_lots`` (gerechnet
        mit ``tax = tax_profile()``), ``cost_basis`` nicht angegeben und ``tax = tax_profile()``, übernimmt die
        Entnahmephase die einzelnen Lots: je Asset in FIFO-Reihenfolge mit Anschaffungskosten (``units`` x
        ``price``) und anzurechnender Vorabpauschale (``vp``); der Wert eines Lots ist sein Stückanteil am Endwert
        des Assets. Ein Verkauf nimmt jedem Asset seinen Wertanteil am Depot (die Entnahmephase hat nur eine
        Renditereihe, die Anteile bleiben daher konstant) und innerhalb des Assets die ältesten Lots zuerst;
        Gewinn je Lot = Erlös x (1 - ``sale_cost`` / 100) minus Anschaffungskosten minus anteilige Vorabpauschale
        (§ 19 InvStG), die Gewinne aller verkauften Lots werden summiert und mit Teilfreistellung
        ``partial_exemption``, Verlusttopf, Sparer-Pauschbetrag und Steuersatz ``rate`` besteuert (wie
        ``simulation()`` je Verkauf, siehe dort ``open_lots``). Cash am Ende der Ansparphase ist eine eigene
        Position mit Basis = Betrag, die wie bisher mit der Depotrendite wächst und anteilig verkauft wird. Neue
        Vorabpauschalen sind je Anteil für alle Lots gleich: es gibt keine Zukäufe, jedes Lot wird ganzjährig
        gehalten, und alle Assets haben dieselbe Rendite (in ``simulation()`` hängt die VP je Stück nur vom
        Kursverlauf des Jahres und der Haltedauer ab). Einkommen mindern nur die Entnahme, Umschichtungen gibt es
        in der Entnahmephase nicht; die Lots werden also nur durch Verkäufe und Vorabpauschalen fortgeschrieben.

        Tarifweg (``tax = tax_profile(income = income_tariff())``): Verkäufe und Vorabpauschalen werden
        unterjährig mit der Abgeltungsteuer belastet. Nach jedem Planjahr folgt je Pfad eine Veranlagung wie der
        Jahresabschluss von ``simulation()`` mit einem festen Tarif aus ``tax_tariff()``: Kapitalerträge K = mit
        Abgeltungsteuer belastete Bemessungsgrundlage des Planjahres (nach Teilfreistellung, Verlusttopf und
        Sparer-Pauschbetrag; die Vorabpauschale zählt im Jahr ihres Zuflusses), Kirchensteuer als Sonderausgabe im
        Zahlungsjahr (Saldo des Bescheids des Vorjahres; im ersten Planjahr 0), mit ``guenstigerpruefung = True``
        der Vergleich mit dem Tarif auf zvE + K. Der Saldo (Nachzahlung bzw. Erstattung) wird mit der ersten
        Entnahme des Folgejahres gezahlt bzw. mindert sie (wie die Steuer auf die Vorabpauschale); eine Erstattung
        über diese Entnahme hinaus fließt als Geld ins Depot. Am Pfadende und am Horizont wird das letzte Planjahr
        sofort veranlagt und abgerechnet wie in ``simulation()`` am letzten Tag (der Zwangsverkauf für die
        Vorabpauschale zählt zu diesem Jahr); mit Günstigerprüfung wird die Vorabpauschale des letzten Planjahres
        (Zufluss im Folgejahr) zusätzlich für das Folgejahr veranlagt, sofern dafür ein zvE vorliegt (eine Zahl
        für alle Jahre bzw. ein benannter Wert für dieses Kalenderjahr). Nachzahlungen werden per Verkauf,
        Erstattungen als Geld ins Depot abgerechnet; alle Salden zählen in ``taxes``. Ohne Kirchensteuer und ohne
        Günstigerprüfung ist der Saldo stets 0. Die Jahreszeilen stehen im Ergebnis unter ``tariff_years``.

        Kalender: Die Entnahmephase kennt keine Kalenderjahre; ihr erstes Planjahr gilt als das Jahr nach dem
        letzten Datentag der Ansparphase (``tax_report["next_year"]$year``), jedes weitere Planjahr als ein neues
        Steuerjahr. Was ``simulation()`` diesem Jahr schon zugerechnet hat (endet die Ansparphase am 31.12.: die
        dort festgesetzte und im Folgejahr verrechnete Vorabpauschale), geht ein: im ersten Planjahr steht nur
        ``sparer_pauschbetrag`` minus ``next_year["sparer_pauschbetrag_used"]`` zur Verfügung, der Verlusttopf
        beginnt mit ``next_year["loss_carryforward_capital"]``.

        Grenzen gegenüber ``simulation()``: (1) Verluste: Die Entnahmephase saldiert Gewinne und Verluste der Lots
        eines Verkaufs sofort und trägt einen verbleibenden Verlust in den Topf vor; eine Erstattung bereits
        versteuerter Erträge desselben Jahres gibt es nicht. ``simulation()`` besteuert jeden Verkauf eines Assets
        einzeln und erstattet zum Jahresende Steuer auf im Jahr versteuerte Erträge, wenn später im Jahr Verluste
        entstehen (unterjährige Verlustverrechnung, mit Freigabe des Pauschbetrags). Gleich sind beide, solange in
        einem Planjahr alle Verkäufe Gewinne ergeben. (2) Steuersatz: die Entnahmephase rechnet mit einem festen
        Satz aus ``tax_profile()`` (``rate`` bzw. mit ``church_tax`` der Satz nach § 32d Abs. 1 EStG, mit
        ``guenstigerpruefung`` und ``income_rate()`` gegebenenfalls der persönliche Satz). Kirchensteuer und
        Günstigerprüfung der Ansparphase werden nicht übernommen; sie sind in ``tax`` ausdrücklich anzugeben. Mit
        dem Tarifweg (``income_tariff()``) gilt unterjährig die Abgeltungsteuer und je Planjahr eine Veranlagung
        (siehe Tarifweg); das zvE gilt für alle Pfade gleich, wird nicht mit der Inflation fortgeschrieben, und
        ``income`` zählt nicht dazu. (3) Ordergebühren beim Verkauf bildet die Entnahmephase nicht ab (Warnung,
        wenn sie in der Ansparphase gesetzt waren). (4) Verschiedene Teilfreistellungen, Regime
        ``"capital_gains"`` neben Fonds und ``"private_sale"`` (§ 23 EStG) werden nicht getrennt besteuert
        (Warnung); Teilfreistellung und Vorabpauschale gelten für den ganzen Bestand. (5) Positionen ohne Wert
        (Endwert <= 1e-12 x Depotwert, etwa nach Knockout) entfallen; ein Verlust aus ihrem Verkauf entsteht in
        der Entnahmephase nicht.

        Renditequellen: Die Entnahmephase ist bewusst von ``simulation()`` getrennt. Ein gespeichertes Ergebnis
        von ``simulation()`` (etwa per ``saveRDS()``) liefert über seinen zeitgewichteten Wertindex
        (``result_index()``) die Renditen; bei einem Einzelergebnis werden daraus historische Kohorten gebildet
        (wie ``withdrawal_cohorts()`` mit monatlichen Starts), eine Liste von Ergebnissen (z. B. je
        Bootstrap-Pfad) oder eine ``bootstrap_study()`` mit ``keep_returns`` liefert je Element einen Pfad (über
        ``withdrawal_paths()``). Ein ``bootstrap_result`` aus ``bootstrap()`` zuerst mit ``withdrawal_paths()``
        umwandeln. Wurde das Quellergebnis bereits mit Steuern (``tax = tax_profile()``) gerechnet, enthält der
        Index schon Vorabpauschalen; dann hier ``vorabpauschale = False`` setzen oder die Quelle ohne Steuern
        rechnen (bei Ergebnissen und Ergebnislisten erscheint dazu eine Warnung).

    Beispiel::

        import numpy as np, simlev
        rng = np.random.default_rng(1)
        R = np.exp(rng.normal(0.05, 0.15, (30, 200)))   # 30 Jahre, 200 Pfade
        ws = simlev.withdrawal_simulation(R, rule=simlev.withdrawal_rule(type="guyton_klinger", rate=5),
                                          start_value=1e6, inflation=2)
        print(ws)
    """
    if rule is None:
        rule = withdrawal_rule(type="constant")
    ab_missing = isinstance(partial_exemption, _Dflt)
    vp_missing = vorabpauschale is _D_TRUE
    sc_missing = isinstance(sale_cost, _Dflt)
    cb_missing = isinstance(cost_basis, _Dflt)
    lc_missing = isinstance(loss_carryforward, _Dflt)
    if vp_missing:
        vorabpauschale = True
    partial_exemption = float(partial_exemption) if ab_missing else partial_exemption
    sale_cost = float(sale_cost) if sc_missing else sale_cost
    cost_basis = float(cost_basis) if cb_missing else cost_basis
    loss_carryforward = float(loss_carryforward) if lc_missing else loss_carryforward
    freq_arg = frequency
    timing = _match_arg(timing, ("start", "end"))
    tax_mode = _wd_tax_mode(tax)
    # Satz wie in simulation() (_tax_rates: Kirchensteuer, Günstigerprüfung einmal je Lauf); die Angaben stehen
    # ausdrücklich in tax_profile(), aus der Ansparphase wird nichts übernommen
    # Tarifweg (income_tariff()): unterjährig Abgeltungsteuer, Veranlagung je Planjahr und Pfad im Kern
    from ._sim_blocks import SimLevIncomeRate, SimLevIncomeTariff
    tariff_on = tax is not None and isinstance(tax["income"], SimLevIncomeTariff)
    if tax is None:
        tax_rate = 26.375 / 100
    else:
        from ._sim_phases import _tax_rates
        ti = tax["income"]
        ir = isinstance(ti, SimLevIncomeRate)
        tax_rate = _tax_rates(tax["rate"], tax["church_tax"], tax["guenstigerpruefung"],
                              ti["marginal_rate"] if ir else None, ir and ti["soli_rate"] != 0,
                              ti["soli_rate"] if ir else 5.5, "withdrawal_simulation",
                              tariff_on=tariff_on)["effective_tax_rate"]
    sparer_pauschbetrag = 1000 if tax is None else tax["sparer_pauschbetrag"]
    if horizon is not None and not _is_horizon(horizon):
        if not _num1(horizon) or float(horizon) <= 0:
            _stop("withdrawal_simulation: 'horizon' muss NULL, ein Objekt aus withdrawal_horizon() oder eine Zahl von Jahren "
                  "> 0 sein, nicht %s." % _show(horizon))
        horizon = withdrawal_horizon(type="fixed", years=horizon)
    if not _is_rule(rule):
        _stop("rule muss mit withdrawal_rule() erstellt werden.")
    if inflation is None:
        inflation = 0

    def chk(v, arg, what, lo=0.0, hi=math.inf):
        if not _num1(v) or float(v) < lo or float(v) > hi:
            _stop("withdrawal_simulation: '%s' muss %s sein, nicht %s." % (arg, what, _wshow(v)))

    def frac(v, arg, hi=1.0, unit="%"):
        if _num1(v) and 0 < float(v) < hi:
            _warn("withdrawal_simulation: %s = %s wird als %s %s gelesen (Prozent-Konvention); gemeint war vermutlich %s."
                  % (arg, _fmt1(v), _fmt1(v), unit, _fmt1(float(v) * 100)))

    chk(partial_exemption, "partial_exemption", "eine Zahl von 0 bis 100 in Prozent (z. B. 30)", 0, 100)
    frac(partial_exemption, "partial_exemption")
    chk(sale_cost, "sale_cost", "eine Zahl von 0 bis unter 100 in Prozent (z. B. 0.1)", 0, 99.999)
    chk(cost_basis, "cost_basis", "eine Zahl >= 0 in Prozent des Startwerts (z. B. 100)")
    frac(cost_basis, "cost_basis")
    chk(loss_carryforward, "loss_carryforward", "eine Zahl >= 0 (EUR)")
    chk(gamma, "gamma", "eine Zahl >= 0 (relative Risikoaversion, z. B. 2)")
    if not _is_logical1(vorabpauschale):
        _stop("withdrawal_simulation: '%s' muss TRUE oder FALSE sein, nicht %s." % ("vorabpauschale", _wshow(vorabpauschale)))
    kp = _keep_count(keep_paths, math.inf, "withdrawal_simulation")   # Anzahl behaltener Pfade, begrenzt nach ncol(R)
    infl_is_mat = isinstance(inflation, (np.ndarray, pd.DataFrame)) and np.ndim(inflation) == 2
    if _is_num(inflation) or (isinstance(inflation, np.ndarray) and inflation.ndim < 2 and inflation.size == 1):
        chk(inflation, "inflation", "eine Zahl in Prozent p. a. über -100 (z. B. 2) oder eine Matrix", -99.999)
        frac(inflation, "inflation", hi=0.05, unit="% p. a.")
    br_is_mat = isinstance(base_rate, (np.ndarray, pd.DataFrame)) and np.ndim(base_rate) == 2
    if not br_is_mat:
        frac(base_rate, "base_rate", hi=0.05)
    if years is not None and (not _num1(years) or float(years) <= 0):
        _stop("years muss eine positive Zahl von Jahren sein (erhalten: %s)." % _show(years))
    if not br_is_mat and not _num1(base_rate):
        _stop("base_rate muss eine Zahl (Prozent) oder eine Matrix Perioden x Pfade sein.")
    if isinstance(income, Mapping) and income.get("amount") is not None and \
            not isinstance(income.get("amount"), (Mapping, list)):
        income = [income]
    if income is not None:
        okinc = isinstance(income, (list, tuple)) and all(
            isinstance(e, Mapping) and _num1(e.get("amount")) for e in income)
        if not okinc:
            _stop("income muss eine Liste von list(start = Jahr, end = Jahr, amount = Betrag) sein (amount: realer "
                  "Jahresbetrag).")
    lots = None
    adopted = {}
    spb_used1 = 0.0
    year1 = None
    if _is_result(start_value):
        sres = start_value
        _ny1 = _get(_rget(sres, "tax_report", {}), "next_year")
        _y1 = _get(_ny1, "year") if isinstance(_ny1, Mapping) else None
        if _num1(_y1) and math.isfinite(float(_y1)):
            year1 = int(_y1)  # Kalenderjahr des ersten Planjahres (Tarifweg)
        acc = result_index(sres)
        sv = float(acc["worth"].to_numpy()[-1])
        if not math.isfinite(sv) or sv <= 0:
            debt = _get(_rget(sres, "tax_report"), "open_tax_debt", 0)
            extra = ""
            if _num1(debt) and math.isfinite(float(debt)) and float(debt) > 0:
                extra = (" (offene, nicht gedeckte Steuerschuld der Ansparphase: %s EUR, tax_report$open_tax_debt)"
                         % _sp("%.2f", float(debt)))
            _stop("start_value: Endwert der Ansparphase (SimLevResult) ist %s EUR; withdrawal_simulation() braucht ein "
                  "positives Startvermögen%s." % (_sp("%.2f", sv), extra))
        ol = _rget(sres, "open_lots")
        if ol is None:
            ol = {}
        has_lots = len(ol) > 0 and all(
            isinstance(_get(a, "lots"), pd.DataFrame) and all(c in _get(a, "lots").columns for c in ("units", "price", "vp"))
            and _is_num(_get(a, "cash")) for a in ol.values())
        cb_given = not cb_missing
        report = _rget(sres, "report", {})
        if not cb_given:
            held = [_last_worth(report, nm) for nm in report.keys()]
            held_v = [float(h[0]) if len(h) == 1 else _NAN for h in held]
            if held_v and all(math.isfinite(h) for h in held_v) and all(h == 0 for h in held_v):
                cost_basis = 100.0
            elif has_lots:
                bs = [r_sum(np.asarray(_get(a, "lots")["units"], dtype=np.float64) *
                            np.asarray(_get(a, "lots")["price"], dtype=np.float64)) +
                      r_sum(np.asarray(_get(a, "lots")["vp"], dtype=np.float64)) + float(_get(a, "cash"))
                      for a in ol.values()]
                basis = r_sum(np.array(bs))
                cost_basis = 100 * basis / sv
                if tax_mode == "person":
                    lots = _wd_lots(ol, report, sv)
            else:
                if tax_mode == "person":
                    _warn("cost_basis: Näherung 100 x (Startwert brutto + Einzahlungen) / Endwert, da das "
                          "Ansparergebnis keine offenen Lots enthält (simulation() ohne tax = tax_profile() oder "
                          "älteres Ergebnis); realisierte Gewinne und Cash zählen dabei als stille Reserven. "
                          "Für genaue Werte die Ansparphase mit tax = tax_profile() rechnen oder cost_basis angeben.")
                inv = _rget(sres, "invested")
                inv = np.asarray(inv, dtype=np.float64).ravel() if inv is not None else np.zeros(0)
                start_gross = float(inv[0]) if len(inv) else float(acc["worth"].to_numpy()[0])
                invested = start_gross + r_sum(np.maximum(acc["flows"].to_numpy()[1:], 0))
                cost_basis = 100 * invested / sv
        if tax_mode == "person" and has_lots:
            hold_n = _wd_held(ol, report, sv)
            hold = [ol[nm] for nm in hold_n]
            reg = [str(_get(a, "regime", "investment_fund")) for a in hold]
            fund = [r == "investment_fund" for r in reg]
            mixed = any(fund) and not all(fund)
            if hold and not any(fund) and vp_missing:
                vorabpauschale = False
                adopted["vorabpauschale"] = False
            if mixed:
                _warn(("Am Ende gehaltene Assets mit verschiedenen Regimen (Investmentfonds: %s; andere: %s): "
                       "withdrawal_simulation() wendet Vorabpauschale (vorabpauschale = %s) und Teilfreistellung "
                       "(partial_exemption = %s %%) auf den ganzen Bestand an; beide werden nicht übernommen.")
                      % (", ".join(n for n, f in zip(hold_n, fund) if f), ", ".join(n for n, f in zip(hold_n, fund) if not f),
                         "TRUE" if vorabpauschale is True else "FALSE", _sp("%g", float(partial_exemption))))
            if any(r == "private_sale" for r in reg):
                _warn(("Assets mit Regime 'private_sale' (Paragraf 23 EStG: %s) am Ende der Ansparphase: Spekulationsfrist "
                       "und Freigrenze bildet withdrawal_simulation() nicht ab; deren Gewinne werden wie Fondsgewinne mit "
                       "Teilfreistellung partial_exemption = %s %% besteuert.")
                      % (", ".join(n for n, r in zip(hold_n, reg) if r == "private_sale"), _sp("%g", float(partial_exemption))))
            fs = [r != "private_sale" for r in reg]
            tfs_all = [float(_get(a, "partial_exemption", 0)) if r == "investment_fund" else 0.0 for a, r in zip(hold, reg)]
            tfs = [t for t, f in zip(tfs_all, fs) if f]
            fs_names = [n for n, f in zip(hold_n, fs) if f]
            if ab_missing and not mixed and tfs and all(fs) and all(abs(t - tfs[0]) < 1e-9 for t in tfs):
                partial_exemption = tfs[0]
                adopted["partial_exemption"] = partial_exemption
            elif not mixed and tfs and any(abs(t - float(partial_exemption)) > 1e-9 for t in tfs):
                _warn(("partial_exemption = %s %%, aber die am Ende gehaltenen Assets haben die Teilfreistellung %s; "
                       "withdrawal_simulation() rechnet mit einer Teilfreistellung für den ganzen Bestand "
                       "(partial_exemption passend angeben; bei verschiedenen Werten keine exakte Abbildung).")
                      % (_sp("%g", float(partial_exemption)), ", ".join(_sp("%s %g %%", n, t) for n, t in zip(fs_names, tfs))))
            tr = _rget(sres, "tax_report", {})
            ny_ = _get(tr, "next_year")

            def num1p(v):
                return _num1(v) and float(v) >= 0

            lc = _get(ny_, "loss_carryforward_capital") if isinstance(ny_, Mapping) and \
                num1p(_get(ny_, "loss_carryforward_capital")) else _get(tr, "loss_carryforward_capital")
            if lc_missing and num1p(lc):
                loss_carryforward = float(lc)
                adopted["loss_carryforward"] = float(lc)
            if isinstance(ny_, Mapping) and num1p(_get(ny_, "sparer_pauschbetrag_used")):
                spb_used1 = float(_get(ny_, "sparer_pauschbetrag_used"))
            spr = []
            for a in hold:
                s = _get(a, "spread")
                spr.append(float(s) if _is_num(s) else _NA)
            if sc_missing and spr and not any(math.isnan(s) for s in spr):
                if all(abs(s - spr[0]) < 1e-12 for s in spr):
                    sale_cost = spr[0] / 2
                    adopted["sale_cost"] = sale_cost
                else:
                    _warn(("sale_cost nicht übernommen: die gehaltenen Assets haben verschiedene Spreads (%s); "
                           "withdrawal_simulation() rechnet mit einem Verkaufskostensatz für den ganzen Bestand "
                           "(sale_cost angeben).") % ", ".join(_sp("%s %g %%", n, s) for n, s in zip(hold_n, spr)))
            fee_set = [_wd_fee_set(_get(a, "order_fee")) for a in hold]
            if any(fee_set):
                _warn(("Ordergebühren der Ansparphase (%s) bildet withdrawal_simulation() beim Verkauf nicht ab; "
                       "gegebenenfalls in sale_cost (Prozent des Verkaufsbetrags) berücksichtigen.")
                      % ", ".join(n for n, f in zip(hold_n, fee_set) if f))
        if spb_used1 > 0:
            adopted["sparer_pauschbetrag_used_year1"] = spb_used1
        if lots is not None:
            adopted["lots"] = len(lots["n"])
        elif not cb_given and tax_mode == "person":
            adopted["cost_basis"] = cost_basis
        if adopted:
            parts = []
            for k, v in adopted.items():
                if k == "lots":
                    parts.append("%d Lots (FIFO)" % v)
                elif isinstance(v, (bool, np.bool_)):
                    parts.append("%s = %s" % (k, "TRUE" if v else "FALSE"))
                else:
                    parts.append("%s = %s" % (k, _fmt1(float(_fmt.signif(float(v), 8)))))
            _message("Hinweis: aus der Ansparphase übernommen: " + ", ".join(parts) + ".")
        start_value = sv
    if not _num1(start_value) or float(start_value) <= 0:
        _stop("start_value muss ein positiver Geldbetrag (Zahl > 0) oder ein SimLevResult sein (erhalten: %s)."
              % _wshow(start_value))
    start_value = float(start_value)
    src_taxed = False
    if _is_result(x):
        trx = _rget(x, "tax_report")
        tp = _get(trx, "total_taxes_paid")
        src_taxed = _num1(tp) and float(tp) > 0
        if not (_is_num(inflation)):
            _stop("Bei einem SimLevResult ist 'inflation' ein Prozentsatz p. a.")
        x = withdrawal_cohorts(x, inflation=inflation, years=30 if years is None else years,
                               frequency=_match_arg(freq_arg, _DEF_FREQ))
    elif "SimLevWrapperNav" in (getattr(x, "r_class", None) or ()):   # Anteilswert eines Fonds-Wrappers (wrapper_nav())
        if not (_is_num(inflation)):
            _stop("Bei einem SimLevWrapperNav ist 'inflation' ein Prozentsatz p. a.")
        x = withdrawal_cohorts(x, price="nav", inflation=inflation, years=30 if years is None else years,
                               frequency=_match_arg(freq_arg, _DEF_FREQ))
    elif isinstance(x, pd.DataFrame) and "date" in [str(c) for c in x.columns]:   # Kurstabelle
        _stop("x ist eine Tabelle mit Spalte 'date' (z. B. ein Ausschnitt aus wrapper_nav(), der eine gewöhnliche "
              "Tabelle ist); Kurse zuerst mit withdrawal_cohorts(x, price = \"<Kursspalte>\") in Renditen umwandeln "
              "oder das ganze Ergebnis von wrapper_nav() übergeben.")
    elif _is_study(x) or _is_result_list(x):
        if not _is_study(x):
            lst = list(x.values()) if isinstance(x, Mapping) else list(x)
            src_taxed = any(_num1(_get(_rget(r, "tax_report"), "total_taxes_paid")) and
                            float(_get(_rget(r, "tax_report"), "total_taxes_paid")) > 0 for r in lst)
        x = withdrawal_paths(x, strategy=strategy, inflation=inflation, frequency=_match_arg(freq_arg, _DEF_FREQ))
    if src_taxed and tax_mode == "person" and vorabpauschale is True:
        _warn("Das Quellergebnis wurde mit Steuern gerechnet (Vorabpauschale im Index enthalten); vorabpauschale = FALSE "
              "oder eine Quelle ohne Steuern (simulation(tax = NULL)) vermeidet Doppelzählung.")
    if not _is_wp(x):
        frequency = _match_arg(freq_arg, _DEF_FREQ)
        try:
            R = _as_matrix(x)
        except (TypeError, ValueError):
            R = None
        if R is None or not R.size:
            _stop("x muss eine numerische Matrix (Perioden x Pfade) von Brutto-Periodenrenditen sein.")
        if (R[~np.isnan(R)] < 0).any():
            _stop("x muss Brutto-Periodenrenditen enthalten (z. B. 1.05 für +5 %).")
        if np.isnan(R).any():
            _stop("missing value where TRUE/FALSE needed")
        if r_median(R.ravel(order="F")) < 0.5:
            _stop("x muss Brutto-Periodenrenditen enthalten (z. B. 1.05 für +5 %).")
        if infl_is_mat and tuple(np.shape(inflation)) != R.shape:
            _stop("inflation als Matrix braucht dieselbe Dimension wie die Renditen (%d x %d), hat aber %d x %d."
                  % (R.shape[0], R.shape[1], np.shape(inflation)[0], np.shape(inflation)[1]))
        if not infl_is_mat and not _num1(inflation):
            _stop("inflation muss eine Zahl (Prozent p. a.) oder eine Matrix Perioden x Pfade sein.")
        if infl_is_mat:
            I = _as_matrix(inflation)
        else:
            I = np.full(R.shape, r_pow(1 + float(inflation) / 100, 1 / _wd_ppy(frequency)))
        x = WithdrawalPaths([("returns", R), ("inflation", I), ("cape", None), ("base_rate", None),
                             ("frequency", frequency), ("historical", False), ("start_dates", None), ("weights", None),
                             ("source", "matrix")])
    ppy = _wd_ppy(x["frequency"])
    R = x["returns"]
    I = x["inflation"]
    if not isinstance(R, np.ndarray) or R.ndim != 2 or not R.shape[0] or not R.shape[1]:
        _stop("Keine Renditen (leere Matrix bzw. keine Pfade).")
    R = np.asarray(R, dtype=np.float64)
    I = np.asarray(I, dtype=np.float64)
    if np.isnan(R).any() or np.isnan(I).any():
        _stop("Renditen/Inflation enthalten NA.")
    if I.shape != R.shape:
        _stop("Inflation (%d x %d) passt nicht zu den Renditen (%d x %d)." % (I.shape[0], I.shape[1], R.shape[0],
                                                                              R.shape[1]))
    xcape = x.get("cape")
    xbase = x.get("base_rate")
    if br_is_mat:
        base_rate = _as_matrix(base_rate)
        if xbase is None and base_rate.shape != R.shape:
            _stop("base_rate als Matrix braucht dieselbe Dimension wie die Renditen (%d x %d Perioden x Pfade), hat aber "
                  "%d x %d." % (R.shape[0], R.shape[1], base_rate.shape[0], base_rate.shape[1]))
    if years is not None:
        if abs(float(years) * ppy - _r_round0(float(years) * ppy)) > 1e-8:
            _stop("years = %s ergibt keine ganze Zahl von Perioden (%d je Jahr)." % (_fmt1(years), ppy))
        kr = min(R.shape[0], int(_r_round0(float(years) * ppy)))
        R = R[:kr, :]
        I = I[:kr, :]
        if xcape is not None:
            xcape = _as_matrix(xcape)[:kr, :]
        if xbase is not None:
            xbase = _as_matrix(xbase)[:kr, :]
        if br_is_mat:
            base_rate = base_rate[:kr, :]
    if R.shape[0] % ppy != 0:
        _warn("Periodenzahl ist kein Vielfaches eines Jahres; letztes Planjahr unvollständig.")
    ny = -(-R.shape[0] // ppy)
    nfy = R.shape[0] // ppy
    if rule["type"] == "cape" and xcape is None:
        _stop("Die CAPE-Regel braucht eine CAPE-Reihe (Argument cape in withdrawal_cohorts/withdrawal_paths).")
    CAPE = _as_matrix(xcape) if xcape is not None else np.zeros((R.shape[0], 0))
    if xbase is not None:
        BASE = _as_matrix(xbase)
    elif br_is_mat:
        BASE = base_rate
    else:
        BASE = np.full(R.shape, float(base_rate))
    inc = np.zeros(ny)
    for e in (income or []):
        s0 = e.get("start")
        s0 = 1 if s0 is None else s0
        e0 = e.get("end")
        e0 = math.inf if e0 is None else e0
        sv0 = _num_vec(s0)
        ev0 = _num_vec(e0)
        if sv0 is None or ev0 is None or sv0.size != 1 or ev0.size != 1 or math.isnan(sv0[0]) or math.isnan(ev0[0]) \
                or ev0[0] < sv0[0]:
            _stop("income: start und end müssen Planjahre mit start <= end sein (erhalten: start = %s, end = %s)."
                  % (_wshow(s0), _wshow(e0)))
        s1 = max(1, math.ceil(sv0[0]))
        e1 = min(ny, math.floor(ev0[0]) if math.isfinite(ev0[0]) else ny)
        if s1 <= e1:
            inc[s1 - 1:e1] = inc[s1 - 1:e1] + float(e["amount"])
    rp = _wd_param_vector(rule)
    kp = min(kp, R.shape[1])
    # Tarifweg: zvE je Planjahr (nominal wie angegeben; income zählt nicht dazu) und Tarif wie in simulation()
    tariff_par = np.zeros(0)
    zve = np.zeros(0)
    if tariff_on:
        zve = _wd_zve(tax["income"]["taxable_income"], ny, year1)
        from ._tax_tariff import tax_tariff as _tax_tariff
        tt = tax["income"]["tariff"] if tax["income"]["tariff"] is not None else _tax_tariff()
        ct = tax["church_tax"]
        ck = float(ct) / 100 if ct is not None and float(ct) > 0 else 0.0
        tariff_par = _wd_tariff_par(tt, ck, tax["guenstigerpruefung"])
    t0 = time.time()
    core = _wcore.wd_simulate(
        R, I, CAPE, BASE, int(ppy), _WD_RULES[rule["type"]], rp, timing == "start", start_value, inc,
        tax_mode == "person", tax_rate, float(partial_exemption) / 100, float(sparer_pauschbetrag),
        vorabpauschale is True, float(sale_cost) / 100, float(cost_basis) / 100, float(loss_carryforward),
        kp > 0 or horizon is not None,
        lots["n"] if lots is not None else np.zeros(0), lots["basis"] if lots is not None else np.zeros(0),
        lots["vp"] if lots is not None else np.zeros(0),
        lots["group"] if lots is not None else np.zeros(0, dtype=np.int64),
        max(0.0, float(sparer_pauschbetrag) - spb_used1) if spb_used1 > 0 else -1.0, horizon is not None,
        tariff_par, zve)
    sp = core["spending"]
    w0 = sp[0, :].copy()
    gamma = float(gamma)
    ncol = sp.shape[1]
    # Konsumkennzahlen je Pfad im Kern (wd_metrics, core/withdrawal_core_impl.h): je Jahr nur über volle Planjahre
    mt = _wcore.wd_metrics(sp, nfy, None, gamma, start_value)
    if ppy == 1 or R.shape[0] >= ppy:
        pwr = withdrawal_perfect_rate(_annual_real({"returns": R, "inflation": I, "frequency": x["frequency"]}))
    else:
        pwr = np.array([_NA])
    pwr = np.resize(np.asarray(pwr, dtype=np.float64), ncol)
    with np.errstate(divide="ignore", invalid="ignore"):
        dep = np.ceil(core["depletion_period"] / ppy)
    paths = pd.DataFrame({
        "success": core["failed"] == 0,
        "depletion_year": dep,
        "terminal_real": core["terminal_real"],
        "terminal_nominal": core["terminal_nominal"],
        "first_withdrawal": w0,
        "mean_spending": mt["mean_spending"],
        "min_spending": mt["min_spending"],
        "spending_drawdown": mt["spending_drawdown"],
        "ce_spending": mt["ce_spending"],
        "total_spending": mt["total_spending"],
        "taxes": core["taxes_real"],
        "pwr": pwr})
    if x.get("start_dates") is not None:
        paths["start"] = np.asarray(x["start_dates"]).astype("datetime64[D]")
    wealth = core["wealth"]
    if horizon is not None:
        H = _draw_horizon(horizon, R.shape[1])
        if H.max() > ny:
            _warn("Horizont bis %d Jahre, Pfade nur %d Jahre: längere Horizonte werden auf %d gekürzt."
                  % (int(H.max()), ny, ny))
            H = np.minimum(H, ny)
        dy = dep
        paths["success_full"] = paths["success"].to_numpy()
        paths["horizon"] = H.astype(np.int64)
        paths["success"] = np.isnan(dy) | (dy > H)
        paths["depletion_year"] = np.where(~np.isnan(dy) & (dy <= H), dy, _NA)
        cols = np.arange(len(H))
        paths["terminal_real"] = core["wealth_end"][H, cols]
        paths["taxes"] = core["taxes_end"][H, cols]
        mt = _wcore.wd_metrics(sp, nfy, H, gamma, start_value)
        paths["mean_spending"] = mt["mean_spending"]
        paths["min_spending"] = mt["min_spending"]
        paths["total_spending"] = mt["total_spending"]
        paths["spending_drawdown"] = mt["spending_drawdown"]
        paths["ce_spending"] = mt["ce_spending"]
        if ppy == 1:
            AR = _annual_real({"returns": R, "inflation": I, "frequency": x["frequency"]})
            pc, st, path = _wcore.wd_pwr(AR, 0.0, H)       # PWR je Pfad bis zum Horizont (Prüfung je Pfad)
            if st:                                          # erster ungültiger Pfad: Fehler wie bisher
                i = path - 1
                withdrawal_perfect_rate(AR[:int(H[i]), i:i + 1])
            paths["pwr"] = pc
        else:
            paths["pwr"] = _NA
        if kp == 0:
            wealth = None
    w = x.get("weights")
    w = np.ones(R.shape[1]) if w is None else np.asarray(w, dtype=np.float64)
    out = SimLevWithdrawal([
        ("paths", paths), ("spending", sp), ("planned", core["planned"]),
        ("wealth", None if kp == 0 else (wealth[:, :int(kp)].copy() if kp < wealth.shape[1] else wealth)), ("rule", rule), ("start_value", start_value),
        ("frequency", x["frequency"]), ("years", ny), ("full_years", nfy), ("horizon", horizon),
        ("historical", x.get("historical") is True), ("weights", w), ("tax_mode", tax_mode), ("gamma", gamma),
        ("timing", timing), ("source", x.get("source")), ("adopted", adopted if adopted else None),
        ("elapsed", time.time() - t0)])
    if tariff_on:
        out["tariff_years"] = _wd_tariff_years(core["tariff_years"], ny)
    return out


@_quiet
def withdrawal_max_rate(x, *, rule=None, success=0.95, lower=0.5, upper=20, tol=0.005, **kwargs):
    """Maximale Anfangsrate für eine Ziel-Erfolgsquote (Bisektion).

    Bestimmt per Bisektion die höchste Entnahmerate (``rate`` der Regel), bei der der (mit den Pfadgewichten
    gewichtete) Anteil erfolgreicher Pfade mindestens ``success`` beträgt. Für die konstante Regel ohne Steuern
    und Einkommen entspricht das dem Quantil der Perfect Withdrawal Rate (historisch: Minimum über alle Kohorten =
    SWR). Jeder Suchschritt ruft ``withdrawal_simulation()`` mit ``keep_paths = False`` auf.

    Args:
        x: Renditequelle wie in ``withdrawal_simulation()``: ``withdrawal_paths`` (z. B. aus
            ``withdrawal_cohorts()``, ``withdrawal_paths()``, ``bootstrap_pooled()``), Renditematrix,
            ``SimLevResult``, Liste von ``SimLevResult`` oder ``SimLevBootstrapStudy``.
        rule: Objekt aus ``withdrawal_rule()``; dessen ``rate`` wird variiert (Standard:
            ``withdrawal_rule("constant")``). Nur für Regeln, die ``rate`` nutzen; bei ``one_over_n``, ``vpw``,
            ``abw``, ``cape`` und ``hebeler`` bricht die Funktion ab.
        success: Ziel-Erfolgsquote als Anteil (0.95 = 95 % der Pfade, Standard); 1 = historische SWR. Zulässig 0 <
            success <= 1 (95 statt 0.95 ist ein Fehler).
        lower, upper: Suchintervall für ``rate`` in Prozent (Standard 0.5 und 20).
        tol: Genauigkeit in Prozentpunkten (Standard 0.005; > 0). Es muss 0 <= lower < upper <= 100 gelten.
        **kwargs: weitere Argumente für ``withdrawal_simulation()`` (z. B. ``inflation``, ``tax_mode``,
            ``horizon``). Ein ``horizon`` aus ``withdrawal_horizon()`` mit ``seed = None`` wird einmal zu einem
            Startwert aufgelöst (ein Zug aus dem Zufallszustand von SimLev, ``simlev_seed()``); alle Suchschritte
            vergleichen damit dieselben Laufzeiten.

    Returns:
        Rate in Prozent (Zahl; 4 = 4 %) mit Attribut ``"success"`` (erreichte Erfolgsquote als Anteil). ``NA``,
        wenn schon ``lower`` die Zielquote verfehlt; ``upper``, wenn selbst ``upper`` sie erreicht.

    Beispiel::

        import numpy as np, simlev
        rng = np.random.default_rng(1)
        R = np.exp(rng.normal(0.05, 0.15, (30, 200)))   # 30 Jahre, 200 Pfade
        print(simlev.withdrawal_max_rate(R, rule=simlev.withdrawal_rule(type="constant"), success=0.9, inflation=2))
    """
    if rule is None:
        rule = withdrawal_rule(type="constant")
    if not _is_rule(rule):
        _stop("rule muss mit withdrawal_rule() erstellt werden.")
    if rule["type"] in ("one_over_n", "vpw", "abw", "cape", "hebeler"):
        _stop("withdrawal_max_rate: Die Regel '%s' nutzt rate nicht; eine Suche über rate ist dafür nicht "
              "möglich." % rule["type"])
    if not _num1(success) or float(success) <= 0 or float(success) > 1:
        hint = ""
        if _num1(success) and 1 < float(success) <= 100:
            hint = "; gemeint vermutlich %s" % _fmt1(float(success) / 100)
        _stop("withdrawal_max_rate: success muss ein Anteil mit 0 < success <= 1 sein (0.95 = 95 %%; erhalten: %s)%s."
              % (_show(success), hint))
    if not _num1(lower) or not _num1(upper) or lower < 0 or upper > 100 or lower >= upper:
        _stop("withdrawal_max_rate: lower und upper müssen Raten in Prozent mit 0 <= lower < upper <= 100 sein "
              "(erhalten: lower = %s, upper = %s)." % (_show(lower), _show(upper)))
    if not _num1(tol) or float(tol) <= 0:
        _stop("withdrawal_max_rate: tol muss eine Zahl > 0 in Prozentpunkten sein (z. B. 0.005; erhalten: %s)."
              % _show(tol))
    # Ein Horizont mit seed=None wird einmal zu k aufgelöst; alle Suchschritte
    # ziehen damit dieselben Laufzeiten
    hz = kwargs.get("horizon")
    if isinstance(hz, SimLevHorizon) and hz.get("seed") is None and hz.get("type") != "fixed":
        hz = SimLevHorizon(hz.items())
        hz["seed"] = _sl.next_seed()
        kwargs = dict(kwargs, horizon=hz)
    state = {"first": True}

    def f(rate):
        rl = WithdrawalRule(rule.items())
        rl["rate"] = rate
        if state["first"]:
            s = withdrawal_simulation(x, rule=rl, keep_paths=False, **kwargs)
        else:
            with warnings.catch_warnings(), contextlib.redirect_stderr(io.StringIO()):
                warnings.simplefilter("ignore")
                s = withdrawal_simulation(x, rule=rl, keep_paths=False, **kwargs)
        state["first"] = False
        return _weighted_mean(s["paths"]["success"].to_numpy(dtype=np.float64), s["weights"])

    s_lo = f(lower)
    if s_lo < success:
        return _Rate(_NA, s_lo)
    s_up = f(upper)
    if s_up >= success:
        return _Rate(upper, s_up)
    while upper - lower > tol:
        mid = (lower + upper) / 2
        s_mid = f(mid)
        if s_mid >= success:
            lower = mid
            s_lo = s_mid
        else:
            upper = mid
    return _Rate(lower, s_lo)


class _Rate(float):
    """Rate mit Attribut ``success`` (wie ``structure(rate, success = ...)``)."""

    def __new__(cls, value, success):
        obj = float.__new__(cls, value)
        obj.success = success
        return obj


# ═══════════════════════════════════════════════════════════════════════════
# Zusammenfassung, Ausgabe, Grafik
# ═══════════════════════════════════════════════════════════════════════════

@_quiet
def _summary_wd(obj, probs=(0.05, 0.25, 0.5, 0.75, 0.95)):
    p = obj["paths"]
    w = np.asarray(obj["weights"], dtype=np.float64)
    probs = np.atleast_1d(np.asarray(probs, dtype=np.float64))

    def wq(v):
        return _wquantile(np.asarray(v, dtype=np.float64), w, probs)

    def wm(v):
        return _weighted_mean(np.asarray(v, dtype=np.float64), w, na_rm=True)

    yrs = obj["years"]
    H = p["horizon"].to_numpy() if "horizon" in p.columns else None
    nfy = obj.get("full_years")
    nfy = yrs if nfy is None else nfy
    spm = np.asarray(obj["spending"], dtype=np.float64)

    def pick(y):
        j = np.arange(spm.shape[1]) if H is None else np.flatnonzero(H >= y)
        if y > nfy or not len(j):
            return np.full(len(probs), _NA)
        return _wquantile(spm[y - 1, j], w[j], probs)

    succ = p["success"].to_numpy(dtype=bool)
    sby = pd.DataFrame(np.vstack([pick(1), pick(10), pick(20), pick(30)]),
                       index=["Jahr 1", "Jahr 10", "Jahr 20", "Jahr 30"])
    pwr = p["pwr"].to_numpy(dtype=np.float64)
    if obj["historical"]:
        fin = pwr[~np.isnan(pwr)]
        if len(fin):
            swr = float(np.min(fin))
        else:
            _warn("no non-missing arguments to min; returning Inf")
            swr = math.inf
    else:
        swr = float(_wquantile(pwr, w, 0.05)[0])
    return SummarySimLevWithdrawal([
        ("rule", obj["rule"]), ("n_paths", len(p)), ("years", yrs), ("historical", obj["historical"]),
        ("success_rate", wm(succ)),
        ("depletion", _wquantile(p["depletion_year"].to_numpy(dtype=np.float64)[~succ], w[~succ], probs)
         if (~succ).any() else None),
        ("terminal_real", wq(p["terminal_real"])),
        ("preserve_rate", wm(p["terminal_real"].to_numpy() >= obj["start_value"])),
        ("first_withdrawal", wq(p["first_withdrawal"])),
        ("mean_spending", wq(p["mean_spending"])), ("min_spending", wq(p["min_spending"])),
        ("spending_drawdown", wq(p["spending_drawdown"])), ("ce_spending", wq(p["ce_spending"])),
        ("spending_by_year", sby), ("taxes", wq(p["taxes"])), ("pwr", wq(pwr)), ("swr", swr),
        ("probs", probs), ("start_value", obj["start_value"]), ("tax_mode", obj["tax_mode"]), ("gamma", obj["gamma"])])


def _cat_summary_wd(x) -> str:
    # Fehlwert als Gedankenstrich, rechtsbündig auf 10 Zeichen; nicht mit _sp("%10s"), das wie R bei %s
    # Bytes zählt (der Gedankenstrich hat in UTF-8 drei)
    def q(v, pct=False):
        out = []
        for z in np.asarray(v, dtype=np.float64).ravel():
            if math.isnan(z):
                out.append(" " * 9 + "–")
            elif pct:
                out.append(_sp("%9.2f%%", z))
            else:
                out.append(_sp("%10.0f", z))
        return "".join(out)

    def fw(s):
        return _fmt.format(s, width=28)

    probs = np.asarray(x["probs"], dtype=np.float64)
    hdr = "".join(_sp("%10s", _sp("q%02d", _r_round0(100 * p))) for p in probs)
    L = "═" * 62
    out = ["\n%s\n" % L, "                 SimLev Entnahme-Simulation                    \n", "%s\n\n" % L]
    out.append("  Regel:            %s\n" % _WD_LABELS[x["rule"]["type"]])
    out.append(_sp("  Pfade:            %d %s über %d Jahre, Startvermögen %.0f\n", int(x["n_paths"]),
                   "historische Kohorten" if x["historical"] else "Pfade", int(x["years"]), float(x["start_value"])))
    out.append("  Steuern:          %s\n\n" % ("deutsche Privatperson (vereinfacht)" if x["tax_mode"] == "person"
                                              else "keine"))
    out.append(_sp("  Erfolgsquote:     %.1f %% (Depot reicht für alle geplanten Entnahmen)\n",
                   100 * x["success_rate"]))
    out.append(_sp("  Kapitalerhalt:    %.1f %% (reales Endvermögen >= Start)\n", 100 * x["preserve_rate"]))
    if x.get("depletion") is not None:
        out.append(_sp("  Erschöpfung:      Median im Jahr %.0f (bei gescheiterten Pfaden)\n",
                       float(np.asarray(x["depletion"])[math.ceil(len(probs) / 2) - 1])))
    out.append(_sp("  %s: %.2f %% der Startsumme\n",
                   "SWR historisch (min. PWR)" if x["historical"] else "SWR (5-%-Quantil PWR)", float(x["swr"])))
    out.append("\n  %s%s\n" % (fw("real, in Startkaufkraft"), hdr))
    out.append("  %s%s\n" % (fw("Endvermögen"), q(x["terminal_real"])))
    out.append("  %s%s\n" % (fw("Entnahme Jahr 1"), q(x["first_withdrawal"])))
    sby = x["spending_by_year"]
    for r in sby.index:
        out.append("  %s%s\n" % (fw("Konsum " + str(r)), q(sby.loc[r].to_numpy())))
    out.append("  %s%s\n" % (fw("Konsum Durchschnitt"), q(x["mean_spending"])))
    out.append("  %s%s\n" % (fw("Konsum Minimum"), q(x["min_spending"])))
    out.append("  %s%s\n" % (fw(_sp("Sicherheitsäquiv. (g=%g)", float(x["gamma"]))), q(x["ce_spending"])))
    out.append("  %s%s\n" % (fw("Max. Konsumrückgang"), q(100 * np.asarray(x["spending_drawdown"]), True)))
    out.append("  %s%s\n" % (fw("PWR"), q(x["pwr"], True)))
    if x["tax_mode"] == "person":
        out.append("  %s%s\n" % (fw("Steuern gesamt"), q(x["taxes"])))
    out.append("\n%s\n" % L)
    return "".join(out)


def _plot_wd(x, probs=(0.05, 0.25, 0.5, 0.75, 0.95), width=900, height=380):
    """Fächer des realen Vermögens und des realen Jahreskonsums als SVG (R: ``plot.SimLevWithdrawal``).

    Liefert ``(svg, data)``: ``wealth`` (nur mit Vermögenspfaden) und ``spending``, je ``year`` und eine
    Spalte je Quantil (``q05``, ``q25``, ``q50``, …), unskaliert (gezeichnet in Tausend).
    """
    from ._r.rformat import r_sprintf
    from .svg import _jl_str
    probs = np.atleast_1d(np.asarray(probs, dtype=np.float64))
    w = np.asarray(x["weights"], dtype=np.float64)
    panels = []
    # keep_paths = k < Pfade: Vermögensfächer mit den Gewichten der behaltenen Spalten, Konsum mit allen;
    # Titel mit Zusatz, ebenso als Attribut ``title`` der Tabelle ``wealth`` in ``data``
    sp_m = np.asarray(x["spending"], dtype=np.float64)
    title = None
    if x.get("wealth") is not None:
        wm = np.asarray(x["wealth"], dtype=np.float64)
        kk, nn = wm.shape[1], sp_m.shape[1]
        title = _sp("Reales Vermögen (erste %d von %d Pfaden)", kk, nn) if kk < nn else None
        panels.append((wm, "Reales Vermögen" if title is None else title, 0, w[:kk]))
    panels.append((sp_m, "Realer Konsum je Jahr", 1, w))
    npn = len(panels)
    pw = width / npn
    qn = []
    for pr in probs:
        t = r_sprintf("%g", 100 * float(pr))
        qn.append("q0" + t if len(t) == 1 else "q" + t)
    data = {}
    out = ["<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"%s\" height=\"%s\" viewBox=\"0 0 %s %s\" "
           "font-family=\"sans-serif\" font-size=\"12\">\n" % (_jl_str(width), _jl_str(height), _jl_str(width), _jl_str(height)),
           "<rect width=\"100%\" height=\"100%\" fill=\"white\"/>\n"]
    k = len(probs)
    for pi_, (M, main, x0, wp) in enumerate(panels):
        Qr = np.column_stack([np.asarray(_wquantile(M[i, :], wp, probs), dtype=np.float64) for i in range(M.shape[0])])
        Q = Qr / 1000
        xs = list(range(x0, x0 + M.shape[0]))
        data["wealth" if x0 == 0 else "spending"] = pd.DataFrame(
            {"year": np.array(xs, dtype=np.int64), **{qn[i]: Qr[i, :].copy() for i in range(len(qn))}})
        if x0 == 0 and title is not None:
            data["wealth"].attrs["title"] = title
        fin = Q.ravel(order="F")
        fin = fin[np.isfinite(fin)]
        ylo, yhi = (0.0, 1.0) if fin.size == 0 else (float(fin.min()), float(fin.max()))
        if yhi == ylo:
            yhi = ylo + 1
        xlo, xhi = xs[0], max(xs[-1], xs[0] + 1)
        ox = pi_ * pw
        ml, mr, mt, mb = 60, 15, 35, 45
        aw, ah = pw - ml - mr, height - mt - mb

        def sx(v, ox=ox, xlo=xlo, xhi=xhi, aw=aw):
            return ox + ml + (v - xlo) / (xhi - xlo) * aw

        def sy(v, ylo=ylo, yhi=yhi, ah=ah):
            return mt + ah - (v - ylo) / (yhi - ylo) * ah
        out.append("<text x=\"%s\" y=\"20\" text-anchor=\"middle\" font-weight=\"bold\">%s</text>\n" % (_jl_str(ox + pw / 2), main))
        out.append("<rect x=\"%s\" y=\"%s\" width=\"%s\" height=\"%s\" fill=\"none\" stroke=\"black\"/>\n"
                   % (_jl_str(ox + ml), _jl_str(mt), _jl_str(aw), _jl_str(ah)))
        out.append("<text x=\"%s\" y=\"%s\" text-anchor=\"middle\">Jahr</text>\n" % (_jl_str(ox + ml + aw / 2), _jl_str(height - 10)))
        for i in range(k // 2):
            up = ["%.2f,%.2f" % (sx(xs[j]), sy(Q[i, j])) for j in range(len(xs)) if math.isfinite(Q[i, j])]
            dn = ["%.2f,%.2f" % (sx(xs[j]), sy(Q[k - 1 - i, j])) for j in reversed(range(len(xs))) if math.isfinite(Q[k - 1 - i, j])]
            out.append("<polygon fill=\"#2C6E9B\" fill-opacity=\"0.18\" stroke=\"none\" points=\"%s\"/>\n" % " ".join(up + dn))
        mid = -(-k // 2) - 1
        pts = ["%.2f,%.2f" % (sx(xs[j]), sy(Q[mid, j])) for j in range(len(xs)) if math.isfinite(Q[mid, j])]
        out.append("<polyline fill=\"none\" stroke=\"#2C6E9B\" stroke-width=\"2\" points=\"%s\"/>\n" % " ".join(pts))
    out.append("</svg>\n")
    return "".join(out), data


# ═══════════════════════════════════════════════════════════════════════════
# Laufzeitmodell
# ═══════════════════════════════════════════════════════════════════════════

class SimLevHorizon(RList):
    """Laufzeit der Entnahmephase (R-Klasse ``SimLevHorizon``)."""

    r_class = ("SimLevHorizon",)

    def format(self) -> str:
        d = _draw_horizon(self, 20000)
        return _sp("Laufzeit der Entnahmephase (%s): Mittel %.1f Jahre, Median %g, 90 %%-Quantil %g, Bereich %g bis %g",
                   self["type"], r_mean_int(d), r_median(d.astype(np.float64)), float(_quantile7(d, 0.9)[0]),
                   float(d.min()), float(d.max()))


def _is_horizon(x) -> bool:
    return isinstance(x, SimLevHorizon) or "SimLevHorizon" in getattr(x, "r_class", ())


def withdrawal_horizon(*, type=("fixed", "uniform", "discrete", "normal", "triangular", "sample"),  # noqa: A002
                  years=None, prob=None, min=None, max=None, mean=None, sd=None, mode=None, seed=1):  # noqa: A002
    """Laufzeit der Entnahmephase nach eigenen Annahmen.

    Beschreibt, wie lange die Entnahmephase dauern soll - fest oder als Verteilung nach eigenen Vorgaben. Jeder
    Pfad von ``withdrawal_simulation()`` erhält eine eigene Laufzeit, gezogen mit festem Startwert (gleiche
    Laufzeiten bei wiederholten Aufrufen; mit ``seed = None`` je Aufruf andere, außer innerhalb von
    ``withdrawal_max_rate()``).

    Args:
        type: Verteilung: ``"fixed"`` (Standard), ``"uniform"``, ``"discrete"``, ``"normal"``, ``"triangular"``
            oder ``"sample"`` (siehe oben). Fehlende Pflichtparameter führen zu einem Fehler.
        years: Laufzeit(en) in Jahren: feste Laufzeit (``fixed``), mögliche Laufzeiten (``discrete``) bzw.
            Stichprobe (``sample``). Bei ``discrete`` und ``sample`` ist auch ein einzelner Wert erlaubt (dann
            immer diese Laufzeit).
        prob: ``discrete``: Wahrscheinlichkeiten je Eintrag von ``years`` (gleiche Länge, >= 0, Summe > 0; werden
            normiert).
        min, max: Untere und obere Grenze in Jahren (``uniform``, ``normal``, ``triangular``); ``min <= max``.
        mean, sd: ``normal``: Mittelwert und Standardabweichung in Jahren.
        mode: ``triangular``: häufigster Wert in Jahren.
        seed: Startwert für die Ziehung der Laufzeiten (Standard 1; ganze Zahl mit |seed| < 2^53); der
            Zufallszustand von SimLev bleibt dann unverändert. ``None`` = bei jeder Ziehung wird genau einmal ein
            Startwert aus dem Zufallszustand von SimLev gezogen (siehe ``simlev_seed()``), jede Ziehung ist
            anders; ``withdrawal_max_rate()`` löst ``None`` einmal auf und nutzt in allen Suchschritten dieselben
            Laufzeiten. ``set.seed()`` wirkt nicht.

    Returns:
        Objekt der Klasse ``SimLevHorizon`` (Liste mit ``type``, ``seed`` und den benötigten Parametern) zur
        Übergabe an das Argument ``horizon`` von ``withdrawal_simulation()`` bzw. ``withdrawal_max_rate()``.
        Ausgabe mit ``print()`` (siehe SimLevWithdrawal-methods).

    Details:
        - fixed: ``years``: feste Laufzeit.
        - uniform: ``min``, ``max``: ganzzahlig gleichverteilt.
        - discrete: ``years``, ``prob``: eigene Wahrscheinlichkeiten je Laufzeit, z. B. ``years = [25, 30, 35,
          40], prob = [.3, .4, .2, .1]``.
        - normal: ``mean``, ``sd``, ``min``, ``max``: gerundet und auf ``[min, max]`` begrenzt.
        - triangular: ``min``, ``mode``, ``max`` mit ``min <= mode <= max``.
        - sample: ``years``: eigene Stichprobe von Laufzeiten, aus der mit Zurücklegen gezogen wird.

        Gezogene Laufzeiten werden auf ganze Jahre gebracht (bei ``normal`` und ``triangular`` gerundet) und sind
        mindestens 1 Jahr. Laufzeiten über der Pfadlänge kürzt ``withdrawal_simulation()`` mit Warnung. Die
        Laufzeit-Parameter ``years``, ``min``, ``max``, ``mean`` und ``mode`` müssen > 0 sein (sonst Fehler).

    Beispiel::

        import numpy as np, simlev
        h = simlev.withdrawal_horizon(type="discrete", years=[25, 30, 35, 40], prob=[0.3, 0.4, 0.2, 0.1])
        R = np.exp(np.random.default_rng(1).normal(0.05, 0.15, (40, 500)))
        print(simlev.withdrawal_simulation(R, rule=simlev.withdrawal_rule(type="constant", rate=4), inflation=2, horizon=h))
    """
    type = _match_arg(type, ("fixed", "uniform", "discrete", "normal", "triangular", "sample"))  # noqa: A001
    need = {"fixed": ["years"], "uniform": ["min", "max"], "discrete": ["years", "prob"],
            "normal": ["mean", "sd", "min", "max"], "triangular": ["min", "mode", "max"], "sample": ["years"]}[type]
    given = {"years": years, "prob": prob, "min": min, "max": max, "mean": mean, "sd": sd, "mode": mode}
    miss = [k for k in need if given[k] is None]
    if miss:
        _stop("withdrawal_horizon('%s') braucht: %s" % (type, ", ".join(miss)))
    for k in need:
        v = given[k]
        multi = k == "prob" or (k == "years" and type in ("discrete", "sample"))
        a = _num_vec(v)
        if a is None or not a.size or (~np.isfinite(a)).any() or (not multi and a.size != 1):
            _stop("withdrawal_horizon('%s'): %s muss %s sein (erhalten: %s)." % (
                type, k, "ein endlicher Zahlenvektor" if multi else "eine endliche Zahl", _show(v)))
    for k in [k for k in need if k in ("years", "min", "max", "mean", "mode")]:
        if (_num_vec(given[k]) <= 0).any():
            _stop("withdrawal_horizon('%s'): %s muss > 0 sein (Laufzeit in Jahren; erhalten: %s)." % (type, k, _show(given[k])))
    if type == "discrete":
        yv, pv = _num_vec(years), _num_vec(prob)
        if len(yv) != len(pv) or (pv < 0).any() or r_sum(pv) <= 0:
            _stop("withdrawal_horizon('discrete'): years und prob gleich lang, prob >= 0 mit Summe > 0.")
    if min is not None and max is not None and min > max:
        _stop("min <= max erforderlich.")
    if type == "triangular" and (mode < min or mode > max):
        _stop(_sp("withdrawal_horizon('triangular'): mode (%g) muss zwischen min (%g) und max (%g) liegen.",
                  float(mode), float(min), float(max)))
    if type == "normal" and sd < 0:
        _stop("withdrawal_horizon('normal'): sd muss >= 0 sein.")
    if seed is not None:
        _sl.check_seed(seed)                            # ganze Zahl, |seed| < 2^53
    return SimLevHorizon([("type", type), ("seed", seed)] + [(k, given[k]) for k in need])


def _seq_from_to(a, b):
    """``seq(a, b)`` (Schritt 1)."""
    a = float(a)
    b = float(b)
    n = int(math.floor(b - a + 1e-10))
    return a + np.arange(0, n + 1, dtype=np.float64)


@_quiet
def _draw_horizon(h, n):
    """Laufzeiten ziehen (R: ``.draw_horizon``); ganzzahlig, mindestens 1."""
    n = int(n)
    # Hauptstrom aus h["seed"]; "fixed" zieht nicht
    rs = None if h["type"] == "fixed" else _sl.main_stream(h.get("seed") if isinstance(h, Mapping) else None)

    def pick(x, prob=None):
        x = np.atleast_1d(np.asarray(x, dtype=np.float64))
        ix = np.asarray(_sl.sample(len(x), n, replace=True, prob=prob, stream=rs)).astype(np.int64)
        return x[ix - 1]

    def body():
        t = h["type"]
        if t == "fixed":
            return np.repeat(np.atleast_1d(np.asarray(h["years"], dtype=np.float64)), n) if n else np.zeros(0)
        if t == "uniform":
            return pick(_seq_from_to(h["min"], h["max"]))
        if t == "discrete":
            return pick(h["years"], np.atleast_1d(np.asarray(h["prob"], dtype=np.float64)))
        if t == "normal":
            z = np.asarray(_sl.rnorm(n, float(h["mean"]), float(h["sd"]), stream=rs), dtype=np.float64)
            r = np.array([_r_round0(v) for v in z])
            return np.minimum(float(h["max"]), np.maximum(float(h["min"]), r))
        if t == "triangular":
            u = np.atleast_1d(np.asarray(_sl.runif(n, stream=rs), dtype=np.float64))
            a, b, c = float(h["min"]), float(h["max"]), float(h["mode"])
            if b == a:
                return np.full(n, a)
            f = (c - a) / (b - a)
            v1 = a + np.sqrt(u * (b - a) * (c - a))
            v2 = b - np.sqrt((1 - u) * (b - a) * (b - c))
            return np.array([_r_round0(v) for v in np.where(u < f, v1, v2)])
        return pick(h["years"])

    out = body()
    out = np.maximum(1.0, np.asarray(out, dtype=np.float64))
    return np.trunc(out).astype(np.int64)


# plot.SimLevWithdrawal (SVG, ``SimLevPlot``) wie Julias ``_plot_method(_plot_wd, "SimLevWithdrawal")``
from .svg import _plot_method  # noqa: E402

SimLevWithdrawal.plot = _plot_method(_plot_wd, "SimLevWithdrawal")

# Rechnen mit NA (signalisierendes NaN) ohne numpy-Warnung "invalid value" wie in R (gemeinsamer Helfer)
from ._r.base import quiet_fp  # noqa: E402

quiet_fp(globals(), list(__all__) + ["_anniv_ends", "_annual_real", "_draw_horizon", "_period_ends", "_wd_fee_set", "_wd_held", "_wd_lots", "_wd_param_vector", "_wd_ppy"])
