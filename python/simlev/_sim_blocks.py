"""Bausteine für ``simulation()`` (Gegenstück zu ``r/R/sim_blocks.R``).

Jeder Baustein ist ein Konstruktor mit Prüfung der Argumente (deutsche Meldungen wie in R), einer
R-Klasse (``RList`` mit ``r_class``) und einer Druckausgabe wie die R-``print``-Methode:

- ``sim_costs(order_fee, dca_fee)``                                → ``costs``
- ``dca_plan(value, span, days, unit, anchor, start, skip, fill_deficits)``   → ``dca``
- ``rebalance_plan(span, days, unit, anchor, start, skip, thresh, thresh_type, event_col, event_mode,
  event_weight)``                                                  → ``rebalance``
- ``split_rule(thresh)``                                           → ``splits``
- ``tax_profile(rate, church_tax, sparer_pauschbetrag, private_sale_threshold, base_rate,
  guenstigerpruefung, income, harvest)`` mit ``income_rate``, ``income_tariff``, ``harvest_rule``
                                                                   → ``tax``

``None`` heißt aus. ``_sim_from_blocks`` übersetzt die Bausteine in die internen Werte der Engine
(``engine._simulation_flat``), die unverändert rechnet. ``funds_costs(fee, performance_fee)`` ist der
Kostenbaustein für den Fonds-Wrapper (folgt); ``simulation()`` nimmt ihn nicht an (der alte
Fondsmodus ist entfernt).
"""
from __future__ import annotations

import math
import re
from typing import Any, Mapping

import numpy as np
import pandas as pd

from ._r.rformat import r_as_character, r_deparse, r_format, r_format1
from ._r.rlist import RList
from ._sim_base import (_Default, _as_date, _check_taxable_income, _fee_spec, _is_bool, _is_num, _num_vec,
                        _stop, _unwrap, _warn)
from .config import _match_arg, _fmt15 as _fmt   # format(x, digits = 15), R: .blk_fmt (seit 1.6.4 eine Fassung)
from ._tax_tariff import SimLevTaxTariff, tax_tariff
from ._util import _MISSING, _Missing
from ._pruefen import _to_float, chk_int1, chk_scalar, chk_stop

__all__ = ["sim_costs", "dca_plan", "rebalance_plan", "split_rule", "tax_profile", "income_rate", "income_tariff",
           "harvest_rule", "funds_costs", "SimLevSimCosts", "SimLevDcaPlan", "SimLevRebalancePlan", "SimLevSplitRule",
           "SimLevTaxProfile", "SimLevIncomeRate", "SimLevIncomeTariff", "SimLevHarvestRule", "SimLevFundsCosts"]


class _Dflt(float):
    """Standardwert, der als angegeben/nicht angegeben unterscheidbar bleibt (R: ``missing(rate)``)."""


# ── Prüfhilfen ────────────────────────────────────────────────────────────────

def _one_num(x: Any) -> bool:
    return _is_num(x) and math.isfinite(_to_float(x))   # seit 1.6.4 (K43 T1-R4): 10**400 ohne OverflowError


# Meldungen seit 1.6.4 ohne Eingabewert (Entscheidung 8 des Nutzers vom 05.11.2026; bis 1.6.3 ", nicht <Wert>")
def _blk_num(who: str, x: Any, arg: str, what: str, mn: float | None = 0.0, null_ok: bool = False) -> None:
    if x is None and null_ok:
        return
    if not _one_num(x) or (mn is not None and x < mn):
        _stop("%s: '%s' muss %s sein." % (who, arg, what))


def _blk_lgl(who: str, x: Any, arg: str) -> None:
    if not _is_bool(x):
        _stop("%s: '%s' muss TRUE oder FALSE sein." % (who, arg))


def _blk_frac_warn(who: str, x: Any, arg: str, hi: float = 1.0) -> None:
    if _one_num(x) and 0 < x < hi:
        _warn("%s: %s = %s wird als %s %% gelesen (Prozent-Konvention); gemeint war vermutlich %s."
              % (who, arg, r_format1(x), r_format1(x), r_format1(x * 100)))


def _blk_days(who: str, x: Any) -> Any:
    if x is None:
        return None
    # seit 1.6.4 nur ein Vektor (keine Matrix, mindestens ein Tag; A-047) und die Meldung ohne Eingabewert
    flat = not ((isinstance(x, np.ndarray) and x.ndim > 1)
                or (isinstance(x, (list, tuple)) and any(isinstance(e, (list, tuple, np.ndarray)) for e in x)))
    v = _num_vec(x) if flat else None
    if (v is None or not v or any(d is None or math.isnan(d) for d in v)
            or any(d < 1 or d > 31 or d != round(d) for d in v)):
        _stop("%s: days muss ganze Zahlen von 1 bis 31 enthalten." % who)
    u: list = []
    for d in v:
        if d not in u:
            u.append(d)
    if len(u) < len(v):
        _warn("%s: days enthält doppelte Tage (%s); jeder Tag ergibt nur einen Termin, verwendet wird days = %s."
              % (who, ", ".join(r_format(v)), r_deparse(u)))
        return u
    return x


def _blk_start(who: str, x: Any) -> None:
    """Bezugsdatum: Datum, Zeitpunkt oder Text "JJJJ-MM-TT" (seit 1.6.4 wie ``asset_config(start)``: keine Zahl,
    Länge 1 (A-075), Meldung ohne Eingabewert)."""
    if x is None:
        return
    from .config import _is_date_like
    try:
        d = _as_date(x) if _is_date_like(x) else None
    except Exception:  # noqa: BLE001 - as.Date-Fehler: kein Datum
        d = None
    if d is None:
        _stop("%s: start ist kein Datum (erwartet Date oder \"JJJJ-MM-TT\")." % who)


def _fee_norm(x: Any) -> Any:
    """Gebührenangabe mit ausgepackten Vektoren der Länge 1 (Entscheidung 4; R: c(2) ist 2)."""
    if isinstance(x, (list, tuple, np.ndarray, pd.Series)) and _is_num(chk_scalar(x)):
        return chk_scalar(x)
    if isinstance(x, dict) and any(isinstance(v, (list, tuple, np.ndarray, pd.Series)) for v in x.values()):
        return {k: chk_scalar(v) for k, v in x.items()}
    return x


def _blk_span_max(unit: str) -> float:
    """Obergrenze des Abstands (A-009): der Schritt in Monaten muss eine R-Ganzzahl sein."""
    return 715827882 if unit == "quarter" else 2147483647


def _blk_check(x: Any, cls: type, arg: str, ctor: str) -> None:
    if x is not None and not isinstance(x, cls):
        _stop("simulation: %s muss NULL oder ein Objekt aus %s() sein." % (arg, ctor))   # seit 1.6.4 ohne Klasse


# ── Druckhilfen ──────────────────────────────────────────────────────────────

def _blk_print(title: str, rows: list) -> str:
    w = max(len(k) for k, _ in rows) + 1
    return "\n".join([title] + ["  %s %s" % ((k + ":").ljust(w), v) for k, v in rows])


def _fee_text(x: Any) -> str:
    if x is None:
        return "keine"
    if _is_num(x):
        return "%s EUR je Order" % _fmt(x)
    p = []
    if x.get("fixed") is not None:
        p.append("%s EUR" % _fmt(x["fixed"]))
    if x.get("percent") is not None:
        p.append("%s %%" % _fmt(x["percent"]))
    s = " + ".join(p) if p else "0 EUR"
    g = []
    if x.get("min") is not None:
        g.append("mindestens %s EUR" % _fmt(x["min"]))
    if x.get("max") is not None:
        g.append("höchstens %s EUR" % _fmt(x["max"]))
    if g:
        s = "%s (%s)" % (s, ", ".join(g))
    return s


def _sched_text(span: Any, unit: str, days: Any, anchor: str) -> str:
    span = 1 if span is None else span
    per = {"month": ("jeden Monat", "Monate"), "quarter": ("jedes Quartal", "Quartale"),
           "year": ("jedes Jahr", "Jahre")}[unit]
    s = per[0] if span == 1 else "alle %s %s" % (_fmt(span), per[1])
    if days is None:
        d = "am ersten Tag der Periode"
    else:
        dv = _num_vec(days) or []
        d = "%s %s %s" % ("an Tag" if len(dv) == 1 else "an den Tagen", ", ".join(_fmt(v) for v in dv),
                          "vom Periodenende gezählt" if anchor == "end" else "der Periode")
    return "%s, %s" % (s, d)


def _start_text(x: Any) -> str:
    if x is None:
        return "erster Datentag"
    from ._dates import fmt_date
    return fmt_date(_as_date(x))


def _is_scalar_income(ti: Any) -> bool:
    if isinstance(ti, (Mapping, pd.Series, pd.DataFrame)):
        return False
    v = _num_vec(ti)
    return v is not None and len(v) == 1


# ── Klassen ──────────────────────────────────────────────────────────────────

class SimLevSimCosts(RList):
    """Kosten (R: ``sim_costs()``)."""
    r_class = ("SimLevSimCosts",)

    def format(self) -> str:
        return _blk_print("Kosten (sim_costs)",
                          [("Ordergebühr", _fee_text(self["order_fee"])),
                           ("Sparplan-Gebühr", "wie Ordergebühr" if self["dca_fee"] is None
                            else _fee_text(self["dca_fee"]))])


class SimLevDcaPlan(RList):
    """Sparplan (R: ``dca_plan()``)."""
    r_class = ("SimLevDcaPlan",)

    def format(self) -> str:
        return _blk_print("Sparplan (dca_plan)",
                          [("Betrag", "%s EUR je Termin" % _fmt(self["value"])),
                           ("Termine", _sched_text(self["span"], self["unit"], self["days"], self["anchor"])),
                           ("Bezugsdatum", _start_text(self["start"])),
                           ("Erster Simulationstag", "ausgelassen" if self["skip"] is True else "mit Termin"),
                           ("Verteilung", "zuerst Wert-Defizite auffüllen, Rest nach Strategie-Gewichten"
                            if self["fill_deficits"] is True else "nach Strategie-Gewichten")])


class SimLevRebalancePlan(RList):
    """Rebalancing (R: ``rebalance_plan()``)."""
    r_class = ("SimLevRebalancePlan",)

    def format(self) -> str:
        ev = self["event_col"] is not None
        repl = ev and self["event_mode"] == "replace"
        rows = [("Termine", "keine (nur Ereignisse)" if repl
                 else _sched_text(self["span"], self["unit"], self["days"], self["anchor"])),
                ("Ereignisse", "keine" if not ev else "Spalte '%s' (%s)" % (
                    self["event_col"], "statt der Termine" if repl else "zusätzlich zu den Terminen"))]
        if ev and self["event_weight"] is not None:
            w = self["event_weight"]
            items = list(w.items()) if isinstance(w, Mapping) else list(zip(w.index, w.values))
            rows.append(("Gewichte", ", ".join("%s = %s" % (k, v if isinstance(v, str) else r_as_character(v)) for k, v in items)))
        rows.append(("Toleranzband", "keines (an jedem Termin)" if self["thresh"] is None else "%s %s" % (
            _fmt(self["thresh"]), "% des Zielgewichts" if self["thresh_type"] == "relative" else "Prozentpunkte")))
        if not repl:
            rows.append(("Bezugsdatum", _start_text(self["start"])))
        rows.append(("Erster Simulationstag", "ausgelassen" if self["skip"] is True else "mit Termin"))
        return _blk_print("Rebalancing (rebalance_plan)", rows)


class SimLevSplitRule(RList):
    """Splits (R: ``split_rule()``)."""
    r_class = ("SimLevSplitRule",)

    def format(self) -> str:
        t = self["thresh"]
        return _blk_print("Splits (split_rule)", [("Split", "über %s auf Kurs 100" % _fmt(t[1])),
                                                  ("Zusammenlegung", "unter %s auf Kurs 100" % _fmt(t[0]))])


def _income_text(x: Any) -> str:
    if x is None:
        return "nicht angegeben"
    if isinstance(x, SimLevIncomeRate):
        return "Grenzsteuersatz %s %%%s" % (_fmt(x["marginal_rate"]), (" mit Soli %s %%" % _fmt(x["soli_rate"]))
                                             if x["soli_rate"] != 0 else "")
    ti = x["taxable_income"]
    return "Tarif (%s, zvE %s)" % ("mitgelieferte Tarifdatei" if x["tariff"] is None else "eigener Tarif",
                                   ("%s EUR je Jahr" % _fmt(_num_vec(ti)[0])) if _is_scalar_income(ti) else "je Kalenderjahr")


def _harvest_text(x: Any) -> str:
    if x is None:
        return "nein"
    return "jährlich ab %s, Verlusttopf %s" % (x["day"], "mitgenutzt" if x["loss_pot"] is True else "nicht genutzt")


class SimLevIncomeRate(RList):
    """Einkommen mit festem Grenzsteuersatz (R: ``income_rate()``)."""
    r_class = ("SimLevIncomeRate",)

    def format(self) -> str:
        return _blk_print("Einkommen (income_rate)",
                          [("Grenzsteuersatz", "%s %%" % _fmt(self["marginal_rate"])),
                           ("Soli", ("%s %%" % _fmt(self["soli_rate"])) if self["soli_rate"] != 0 else "ohne")])


class SimLevIncomeTariff(RList):
    """Einkommen mit Einkommensteuertarif (R: ``income_tariff()``)."""
    r_class = ("SimLevIncomeTariff",)

    def format(self) -> str:
        ti = self["taxable_income"]
        return _blk_print("Einkommen (income_tariff)",
                          [("zvE", ("%s EUR je Jahr" % _fmt(_num_vec(ti)[0])) if _is_scalar_income(ti) else "je Kalenderjahr"),
                           ("Tarif", "mitgelieferte Tarifdatei" if self["tariff"] is None else "eigener Tarif")])


class SimLevHarvestRule(RList):
    """Freibetrag jährlich ausschöpfen (R: ``harvest_rule()``)."""
    r_class = ("SimLevHarvestRule",)

    def format(self) -> str:
        return _blk_print("Freibetrag nutzen (harvest_rule)",
                          [("Termin", "jährlich ab %s (MM-TT, nächster Handelstag)" % self["day"]),
                           ("Verlusttopf", "mitgenutzt" if self["loss_pot"] is True else "nicht genutzt")])


class SimLevTaxProfile(RList):
    """Persönliche Besteuerung (R: ``tax_profile()``)."""
    r_class = ("SimLevTaxProfile",)

    def format(self) -> str:
        ct = 0 if self["church_tax"] is None else self["church_tax"]
        br = self["base_rate"]
        return _blk_print("Steuern (tax_profile)", [
            ("Abgeltungsteuer", ("mit Kirchensteuer %s %% (Satz nach § 32d Abs. 1 EStG)" % _fmt(ct)) if ct > 0
             else "%s %%" % _fmt(self["rate"])),
            ("Sparer-Pauschbetrag", "keiner" if self["sparer_pauschbetrag"] == 0
             else "%s EUR je Jahr" % _fmt(self["sparer_pauschbetrag"])),
            ("Freigrenze § 23", "%s EUR" % _fmt(self["private_sale_threshold"])),
            ("Basiszins", "keiner (keine Vorabpauschale)" if br is None else
             ("Spalte '%s'" % br if isinstance(br, str) else "%s %%" % _fmt(br))),
            ("Günstigerprüfung", "ja" if self["guenstigerpruefung"] is True else "nein"),
            ("Einkommen", _income_text(self["income"])),
            ("Freibetrag nutzen", _harvest_text(self["harvest"]))])


class SimLevFundsCosts(RList):
    """Kostenbaustein für den Fonds-Wrapper (folgt; R: ``funds_costs()``)."""
    r_class = ("SimLevFundsCosts",)

    def format(self) -> str:
        return _blk_print("Fondskosten (funds_costs)",
                          [("Fondskosten", "%s %% p. a." % _fmt(self["fee"])),
                           ("Performancegebühr", "%s %% des Wertzuwachses über dem Höchststand"
                            % _fmt(self["performance_fee"]))])


def _mk(cls: type, items: list) -> RList:
    x = cls()
    for k, v in items:
        x[k] = v
    return x


# Gemeinsamer Text der neun Baustein-Docstrings (seit 1.6.4 eine Fassung, A-109; bis 1.6.3 neunfach kopiert wie die
# gemeinsame Rd-Seite ?sim_costs): _blk_doc setzt ihn um die Argumente und das Beispiel des Bausteins.
_BLK_DOC_KOPF = 'Bausteine für simulation: Kosten, Sparplan, Rebalancing, Splits, Steuern; Fondskosten.\n\nDie Einstellungen von ``simulation`` werden als Bausteine übergeben: ``costs = sim_costs()``, ``dca =\ndca_plan()``, ``rebalance = rebalance_plan()``, ``splits = split_rule()``, ``tax = tax_profile()`` (mit\n``income = income_rate()`` oder ``income_tariff()`` und ``harvest = harvest_rule()``). ``None`` heißt aus\n(kein Sparplan, kein Rebalancing, keine Splits, keine Steuern). Jeder Baustein prüft seine Argumente beim\nAnlegen (deutsche Fehlermeldungen und Warnungen) und druckt eine kurze Zusammenfassung. ``simulation()`` prüft\nnur noch das Zusammenspiel mit den Daten (z. B. ob die Spalte ``event_col`` in ``data`` steht oder ob\n``start`` im Datenzeitraum liegt). Die Rechnung der Engine ist dieselbe wie mit den früheren Einzelargumenten.\n\n``funds_costs()`` ist der Kostenbaustein des Fonds-Wrappers (``wrapper_config(costs = funds_costs())``);\n``simulation()`` nimmt ihn nicht an.'
_BLK_DOC_SCHLUSS = 'Returns:\n    Ein Baustein: Liste mit den Argumenten (nach der Prüfung; ``unit``, ``anchor``, ``thresh_type`` und\n    ``event_mode`` aufgelöst, ``days`` ohne doppelte Tage, ``tariff`` aus einem Dateipfad gelesen) und der\n    Klasse ``SimLevSimCosts``, ``SimLevDcaPlan``, ``SimLevRebalancePlan``, ``SimLevSplitRule``,\n    ``SimLevTaxProfile``, ``SimLevIncomeRate``, ``SimLevIncomeTariff``, ``SimLevHarvestRule`` bzw.\n    ``SimLevFundsCosts``. Die ``print``-Methoden geben ``x`` unsichtbar zurück.\n\nÜbersetzung in die Engine:\n    ``simulation()`` übersetzt die Bausteine am Anfang in die internen Werte der Engine: ``dca_plan()``\n    schaltet den Sparplan ein, ``rebalance_plan()`` das Rebalancing (auch am ersten Simulationstag und am\n    Starttag später startender Assets wird dann über das Rebalancing gekauft); nur mit ``event_col``,\n    ``event_mode = "replace"`` und ``skip = True`` wird ausschließlich an Ereignistagen umgeschichtet. ``tax =\n    tax_profile()`` steht für die persönliche Besteuerung.\n\nFondskosten:\n    ``funds_costs(fee, performance_fee)`` ist der Kostenbaustein des Fonds-Wrappers:\n    ``wrapper_config(strategy, costs = funds_costs(...))``. Die Rechnung (Verwaltungsgebühr je Kalendertag,\n    Performancegebühr gegen die High-Water-Mark) steht in ``wrapper_nav``. ``print()`` zeigt die Überschrift\n    „Fondskosten (funds_costs)“. Der frühere Fondsmodus ``simulation(funds = funds_costs())`` ist entfernt;\n    ``simulation(funds = )`` ergibt den Fehler für ein unbekanntes Argument.'


def _blk_doc(f):
    """Docstring eines Bausteins: gemeinsamer Kopf, eigene Argumente, gemeinsamer Schluss, eigenes Beispiel."""
    import inspect as _inspect
    d = _inspect.cleandoc(f.__doc__)
    a = d.index("\nArgs:")
    b = d.index("\nBeispiel::")
    f.__doc__ = _BLK_DOC_KOPF + "\n" + d[a:b] + "\n" + _BLK_DOC_SCHLUSS + "\n" + d[b:]
    return f


# ── Konstruktoren ────────────────────────────────────────────────────────────

@_blk_doc
def sim_costs(*, order_fee: Any = None, dca_fee: Any = None) -> SimLevSimCosts:
    """Baustein für simulation (gemeinsamer Text in ``_BLK_DOC_KOPF`` und ``_BLK_DOC_SCHLUSS``).
    Args:
        order_fee: ``sim_costs``: Ordergebühr: ``None`` (keine, Standard), eine Zahl (feste Gebühr in EUR je
            Order) oder ``{"fixed": ..., "percent": ..., "min": ..., "max": ...}`` mit ``fixed``, ``min``, ``max``
            in EUR und ``percent`` in Prozent des Ordervolumens, z. B. ``{"fixed": 4.9, "percent": 0.25, "max":
            59}``. Die Gebühr erhöht beim Kauf den Einstandskurs (Anschaffungsnebenkosten) und mindert beim
            Verkauf den Erlös (Veräußerungskosten); steuerlich wirkt sie damit gewinnmindernd. Zusätzlich zum
            Spread je Asset (``spread`` in ``asset_config``; einen Spread für die ganze Simulation gibt es nicht).
            Unbekannte Listenfelder (z. B. ``fix`` statt ``fixed``) und negative Gebühren führen zu einem Fehler;
            jedes Feld ist eine einzelne endliche Zahl (``max`` auch ``inf``), NaN, Text und ``True`` sind ein Fehler.
            Bei Zwangsverkäufen für die Vorabpauschale und die § 23-Steuer wird so viel verkauft, dass Steuer und
            Gebühr gedeckt sind.
        dca_fee: ``sim_costs``: Gebühr für die Sparplankäufe (Format wie ``order_fee``): Käufe von
            Buy-and-Hold-Assets an Sparplantagen. Rebalancing-Verkäufe und -Käufe, Signal-Trades,
            Steuer-Zwangsverkäufe und die Liquidation am selben Tag kosten ``order_fee``. Ist der erste
            Simulationstag ein Sparplantag, wird das Startkapital mit ``order_fee`` und nur die Sparrate mit
            ``dca_fee`` angelegt (zwei Orders); fällt ein Sparplantermin auf einen Rebalancing-Tag, wird die Rate
            im Rebalancing mit angelegt. Standard (``None``): wie ``order_fee``. Viele Broker führen Sparpläne
            kostenlos aus (``dca_fee = 0``).

    Beispiel::

        import simlev
        print(simlev.sim_costs(order_fee={"fixed": 1, "percent": 0.25, "min": 2, "max": 20}, dca_fee=0))
    """
    order_fee, dca_fee = _fee_norm(order_fee), _fee_norm(dca_fee)
    _fee_spec(order_fee, "sim_costs", "order_fee")
    _fee_spec(dca_fee, "sim_costs", "dca_fee")
    return _mk(SimLevSimCosts, [("order_fee", order_fee), ("dca_fee", dca_fee)])


@_blk_doc
def dca_plan(value: Any = _MISSING, span: Any = _MISSING, *, days: Any = None, unit: Any = ("month", "quarter", "year"),
             anchor: Any = ("start", "end"), start: Any = None, skip: Any = False, fill_deficits: Any = False) -> SimLevDcaPlan:
    """Baustein für simulation (gemeinsamer Text in ``_BLK_DOC_KOPF`` und ``_BLK_DOC_SCHLUSS``).
    Args:
        value: ``dca_plan``: Betrag je Sparplan-Termin in EUR; Pflicht, eine einzelne endliche Zahl ``> 0``
            (Vektor, ``NA`` oder Text: Fehler).
        span: ``dca_plan``: Abstand zwischen zwei Terminen in Perioden von ``unit`` (z. B. ``3`` mit ``"month"`` =
            alle drei Monate); Pflicht, eine einzelne ganze Zahl ``>= 1`` (sonst Fehler). ``rebalance_plan``:
            Rebalancing-Intervall in Perioden von ``unit``; ``None`` (Standard) = 1, sonst eine einzelne endliche
            Zahl ``>= 1`` (seit 1.6.4 eine ganze Zahl; vorher lief z. B. 1.5 wie 1), höchstens 2147483647 (bei ``"quarter"`` 715827882).
        days: Integer-Vektor (keine Matrix, mindestens ein Tag) oder ``None``. Tag(e) innerhalb jeder Periode (1--31): bei ``"month"`` Tag des
            Monats, bei ``"quarter"`` Tag im ersten Monat der Periode, bei ``"year"`` Tag im Januar; mit ``anchor
            = "end"`` rückwärts vom Periodenende gezählt (1 = letzter Tag). Nicht existierende Tage entfallen (z.
            B. Tag 31 im April, bei ``"end"`` Tag 31 vom Ende im Februar). Werte außerhalb von 1--31 oder nicht
            ganzzahlig: Fehler; doppelte Tage ergeben nur einen Termin (Warnung, der Baustein enthält jeden Tag
            einmal). Fallen bei Handelstagsdaten mehrere Sparplantermine auf denselben Handelstag (Verschiebung
            von Wochenenden), wird je Termin eine Rate eingezahlt. ``None`` (Standard) = erster Tag der Periode.
        unit: Einheit des Abstands: ``"month"`` (Standard), ``"quarter"`` oder ``"year"``. Perioden beginnen am
            Monatsersten des Startmonats (``start`` bzw. erster Datentag), bei ``"year"`` am 1. Januar; Quartale
            sind daher nicht zwingend Kalenderquartale.
        anchor: Bezugspunkt für ``days``: ``"start"`` (Standard, ab Periodenbeginn) oder ``"end"`` (ab
            Periodenende). Ohne ``days`` wirkungslos.
        start: Date, Zeitpunkt oder ``"JJJJ-MM-TT"`` (keine Zahl) oder ``None``. Bezugsdatum des Terminplans: Die Perioden beginnen am
            Monatsersten dieses Datums (bei ``"year"`` am 1. Januar); Termine vor dem ersten Datentag entfallen.
            Kein Datum: Fehler beim Anlegen; liegt das Datum nach dem letzten Datentag, bricht ``simulation()``
            mit Fehler ab. ``None`` (Standard) = erster Tag von ``data``.
        skip: Logisch. ``dca_plan``: Sparplan-Termin am ersten Simulationstag auslassen (Termine an anderen Tagen
            bleiben). ``rebalance_plan``: Rebalancing-Termin am ersten Simulationstag auslassen. Mit ``event_col``
            und ``event_mode = "replace"`` (Rebalancing nur an Ereignistagen) heißt ``skip = True``: am ersten Tag
            nicht umschichten, das Startkapital wird wie ohne Rebalancing angelegt; mit ``skip = False`` wird am
            ersten Tag (und am Starttag später startender Assets) über das Rebalancing nach Zielgewichten gekauft.
            Standard: ``False``.
        fill_deficits: ``dca_plan``: ``False`` (Standard): Jede Rate wird fix nach den **Strategie-Gewichten**
            (``share``) verteilt, renormiert über die aktiven Assets — 70:30 bleibt 70:30, unabhängig von der
            Depot-Drift. ``True``: Die Rate wirkt als Mini-Rebalancing — sie füllt zuerst die Wert-Defizite zu den
            Strategie-Zielen; ein Rest wird nach Strategie-Gewichten verteilt.

    Beispiel::

        import numpy as np, pandas as pd, simlev
        rng = np.random.default_rng(1)
        n = 730
        d = pd.DataFrame({"date": pd.date_range("2020-01-01", periods=n)})
        d["A"] = 100 * 1.0003 ** np.arange(n)
        r = simlev.simulation(d, simlev.create_strategy(A=simlev.asset_config(asset_class="etf")),
                              dca=simlev.dca_plan(100, 1))
        print(r["worth"][-1], r["invested"][-1])
    """
    who = "dca_plan"
    value = None if isinstance(value, _Missing) else chk_scalar(value)   # Länge 1 wie Einzelwert (Entscheidung 4)
    span = None if isinstance(span, _Missing) else chk_scalar(span)
    unit, anchor, start, skip, fill_deficits = (chk_scalar(v) for v in (unit, anchor, start, skip, fill_deficits))
    if not _one_num(value) or value <= 0:
        _stop("%s: 'value' muss eine einzelne endliche Zahl > 0 sein (Betrag je Sparplan-Termin in EUR)." % who)
    days = _blk_days(who, days)
    unit = _match_arg(unit, ("month", "quarter", "year"), "unit")
    anchor = _match_arg(anchor, ("start", "end"), "anchor")
    # seit 1.6.4 Obergrenze (A-009); seit K43 T1-R6 eine Meldung (ganz_bis) statt zweier Formen
    chk_int1(span, who, "span", lo=1, hi=_blk_span_max(unit))
    _blk_start(who, start)
    _blk_lgl(who, skip, "skip")
    _blk_lgl(who, fill_deficits, "fill_deficits")
    return _mk(SimLevDcaPlan, [("value", value), ("span", span), ("days", days), ("unit", unit), ("anchor", anchor),
                               ("start", start), ("skip", bool(skip)), ("fill_deficits", bool(fill_deficits))])


@_blk_doc
def rebalance_plan(*, span: Any = None, days: Any = None, unit: Any = ("month", "quarter", "year"),
                   anchor: Any = ("start", "end"), start: Any = None, skip: Any = False, thresh: Any = None,
                   thresh_type: Any = ("absolute", "relative"), event_col: Any = None,
                   event_mode: Any = _Default(("additional", "replace")), event_weight: Any = None) -> SimLevRebalancePlan:
    """Baustein für simulation (gemeinsamer Text in ``_BLK_DOC_KOPF`` und ``_BLK_DOC_SCHLUSS``).
    Args:
        span: ``dca_plan``: Abstand zwischen zwei Terminen in Perioden von ``unit`` (z. B. ``3`` mit ``"month"`` =
            alle drei Monate); Pflicht, eine einzelne ganze Zahl ``>= 1`` (sonst Fehler). ``rebalance_plan``:
            Rebalancing-Intervall in Perioden von ``unit``; ``None`` (Standard) = 1, sonst eine einzelne endliche
            Zahl ``>= 1`` (seit 1.6.4 eine ganze Zahl; vorher lief z. B. 1.5 wie 1), höchstens 2147483647 (bei ``"quarter"`` 715827882).
        days: Integer-Vektor (keine Matrix, mindestens ein Tag) oder ``None``. Tag(e) innerhalb jeder Periode (1--31): bei ``"month"`` Tag des
            Monats, bei ``"quarter"`` Tag im ersten Monat der Periode, bei ``"year"`` Tag im Januar; mit ``anchor
            = "end"`` rückwärts vom Periodenende gezählt (1 = letzter Tag). Nicht existierende Tage entfallen (z.
            B. Tag 31 im April, bei ``"end"`` Tag 31 vom Ende im Februar). Werte außerhalb von 1--31 oder nicht
            ganzzahlig: Fehler; doppelte Tage ergeben nur einen Termin (Warnung, der Baustein enthält jeden Tag
            einmal). Fallen bei Handelstagsdaten mehrere Sparplantermine auf denselben Handelstag (Verschiebung
            von Wochenenden), wird je Termin eine Rate eingezahlt. ``None`` (Standard) = erster Tag der Periode.
        unit: Einheit des Abstands: ``"month"`` (Standard), ``"quarter"`` oder ``"year"``. Perioden beginnen am
            Monatsersten des Startmonats (``start`` bzw. erster Datentag), bei ``"year"`` am 1. Januar; Quartale
            sind daher nicht zwingend Kalenderquartale.
        anchor: Bezugspunkt für ``days``: ``"start"`` (Standard, ab Periodenbeginn) oder ``"end"`` (ab
            Periodenende). Ohne ``days`` wirkungslos.
        start: Date, Zeitpunkt oder ``"JJJJ-MM-TT"`` (keine Zahl) oder ``None``. Bezugsdatum des Terminplans: Die Perioden beginnen am
            Monatsersten dieses Datums (bei ``"year"`` am 1. Januar); Termine vor dem ersten Datentag entfallen.
            Kein Datum: Fehler beim Anlegen; liegt das Datum nach dem letzten Datentag, bricht ``simulation()``
            mit Fehler ab. ``None`` (Standard) = erster Tag von ``data``.
        skip: Logisch. ``dca_plan``: Sparplan-Termin am ersten Simulationstag auslassen (Termine an anderen Tagen
            bleiben). ``rebalance_plan``: Rebalancing-Termin am ersten Simulationstag auslassen. Mit ``event_col``
            und ``event_mode = "replace"`` (Rebalancing nur an Ereignistagen) heißt ``skip = True``: am ersten Tag
            nicht umschichten, das Startkapital wird wie ohne Rebalancing angelegt; mit ``skip = False`` wird am
            ersten Tag (und am Starttag später startender Assets) über das Rebalancing nach Zielgewichten gekauft.
            Standard: ``False``.
        thresh: ``rebalance_plan``: Minimale Gewichtsabweichung **in Prozent** (z. B. ``5`` = 5 Prozentpunkte,
            siehe ``thresh_type``) für einen Rebalancing-Trade; geprüft wird die größte Abweichung über alle
            aktiven Assets. ``None`` (Standard) = an jedem Termin rebalancieren. Gewichte, Abweichung und
            Depotwert werden an jedem Rebalancing-Tag zum Tageskurs vor dem Handel bestimmt (nach Sparrate und
            Signal-Ein-/Ausstieg des Tages), gehandelt wird zum selben Kurs. Werte unter 0,2 (vermutlich Anteil,
            z. B. ``0.05`` für 5 Prozentpunkte) werden mit Warnung als Prozent gelesen. ``split_rule``:
            Numerischer Vektor der Länge 2 ``[untere, obere]``: Kursschwellen in Preiseinheiten der Kursreihe.
            Steigt der Kurs über die obere Schwelle, folgt ein Split (Verhältnis Kurs/100), fällt er unter die
            untere, eine Zusammenlegung (100/Kurs); der Kurs wird jeweils auf 100 gesetzt. Bestand, Lots und die
            gesamte Kurshistorie (auch der Jahresanfangskurs für die Vorabpauschale) werden umgerechnet. Erwartet
            wird ``untere < 100 < obere``; sonst Warnung, da nach dem ersten Split (Kurs 100) an jedem folgenden
            Tag ein weiterer Split ausgelöst wird. Kein Zahlenvektor der Länge 2: Fehler. Hat ein Asset am
            Split-Tag keinen Bestand, wird seine Kursreihe trotzdem umgerechnet.
        thresh_type: ``"absolute"`` (Standard): ``thresh`` sind Prozentpunkte des Gewichts (5 = Ziel 40 % darf
            35--45 % sein). ``"relative"``: Prozent des Zielgewichts (25 = Ziel 40 % darf 30--50 % sein).
        event_col: Character oder ``None``. Name einer logischen Spalte in ``data``, die ereignisbasiertes
            Rebalancing auslöst (siehe ``rebalance_trigger``); fehlt die Spalte, bricht ``simulation()`` mit
            Fehler ab. Kein Rebalancing am ersten Tag und (mit ``liquidate``) am Liquidationstag. Standard:
            ``None``.
        event_mode: ``"additional"`` (Standard: zusätzlich zu den Terminen) oder ``"replace"`` (nur an
            Ereignistagen, die Termine entfallen; siehe ``skip``). Ohne ``event_col`` wirkungslos (Warnung, wenn
            angegeben).
        event_weight: Benannter Character-Vektor oder benannte Liste oder ``None``: je Asset-Name der Name einer
            numerischen Spalte in ``data`` mit dem Zielgewicht. Wirkt nur an Tagen, an denen ``event_col``
            ``True`` ist; die Werte werden auf Summe 1 normiert und nur verwendet, wenn alle aktiven Assets einen
            endlichen Wert haben und die Summe positiv ist (fehlt ein Asset, gelten mit Warnung an Event-Tagen die
            Strategie-Gewichte). Unbenannte oder doppelte Namen und Einträge, die kein einzelner Spaltenname sind, sind schon
            beim Anlegen ein Fehler; unbekannte Asset-Namen, fehlende Spalten und negative
            Gewichte führen in ``simulation()`` zu einem Fehler. ``None`` = Strategie-Gewichte. Ohne ``event_col``
            wirkungslos (Warnung).

    Beispiel::

        import numpy as np, pandas as pd, simlev
        rng = np.random.default_rng(1)
        n = 1500
        d = pd.DataFrame({"date": pd.date_range("2015-01-01", periods=n)})
        d["A"] = 100 * np.cumprod(1 + rng.normal(3e-4, 0.01, n))
        d["B"] = 100 * np.cumprod(1 + rng.normal(1e-4, 0.004, n))
        st = simlev.create_strategy(A=simlev.asset_config(asset_class="etf", share=0.6), B=simlev.asset_config(asset_class="etf", share=0.4))
        r = simlev.simulation(d, st, rebalance=simlev.rebalance_plan(unit="quarter", thresh=5))
        print(r["buys"], r["sells"])
    """
    who = "rebalance_plan"
    span, unit, anchor, start, skip, thresh, thresh_type, event_col = (
        chk_scalar(v) for v in (span, unit, anchor, start, skip, thresh, thresh_type, event_col))
    if not isinstance(event_mode, _Default):
        event_mode = chk_scalar(event_mode)
    days = _blk_days(who, days)
    unit = _match_arg(unit, ("month", "quarter", "year"), "unit")
    anchor = _match_arg(anchor, ("start", "end"), "anchor")
    # seit 1.6.4 (A-009, mildere Regel bis zur Entscheidung des Nutzers): None oder eine einzelne endliche Zahl >= 1 bis
    # zur Obergrenze; gebrochene Werte wie 1.5 laufen weiter wie bisher
    # seit 1.6.4 ganze Zahl (Entscheidungen 19, 32) bis zur Obergrenze (A-009); seit K43 T1-R6 eine Meldung (ganz_bis)
    chk_int1(span, who, "span", lo=1, hi=_blk_span_max(unit), null_ok=True)
    _blk_start(who, start)
    _blk_lgl(who, skip, "skip")
    _blk_num(who, thresh, "thresh", "NULL oder eine einzelne endliche Zahl >= 0 in Prozent (z. B. 5)", null_ok=True)
    _blk_frac_warn(who, thresh, "thresh", hi=0.2)
    thresh_type = _match_arg(thresh_type, ("absolute", "relative"), "thresh_type")
    if event_col is None and not isinstance(event_mode, _Default):
        _warn("rebalance_plan: event_mode wirkt nur zusammen mit event_col und wird ignoriert.")
    event_mode = _match_arg(_unwrap(event_mode), ("additional", "replace"), "event_mode")
    if event_col is not None and not (isinstance(event_col, str) and event_col != ""):
        _stop("rebalance_plan: event_col muss NULL oder der Name einer logischen Spalte in data sein.")
    if event_col is None and event_weight is not None:
        _warn("rebalance_plan: event_weight wirkt nur zusammen mit event_col und wird ignoriert.")
    # seit 1.6.4 (A-049): event_weight benannt, je Asset ein Spaltenname (die Spalten prüft simulation())
    if event_weight is not None:
        if isinstance(event_weight, Mapping):
            items = [(k, chk_scalar(v)) for k, v in event_weight.items()]
        elif isinstance(event_weight, pd.Series):
            items = [(k, v) for k, v in zip(event_weight.index, event_weight.values)]
        else:
            items = None
        if (not items or any(not isinstance(k, str) or k == "" for k, _ in items)
                or any(not isinstance(v, str) or v == "" for _, v in items)
                or len({k for k, _ in items}) != len(items)):
            chk_stop("e1.event_weight", who)
    return _mk(SimLevRebalancePlan, [("span", span), ("days", days), ("unit", unit), ("anchor", anchor),
                                     ("start", start), ("skip", bool(skip)), ("thresh", thresh),
                                     ("thresh_type", thresh_type), ("event_col", event_col),
                                     ("event_mode", event_mode), ("event_weight", event_weight)])


@_blk_doc
def split_rule(thresh: Any = _MISSING) -> SimLevSplitRule:
    """Baustein für simulation (gemeinsamer Text in ``_BLK_DOC_KOPF`` und ``_BLK_DOC_SCHLUSS``).
    Args:
        thresh: ``rebalance_plan``: Minimale Gewichtsabweichung **in Prozent** (z. B. ``5`` = 5 Prozentpunkte,
            siehe ``thresh_type``) für einen Rebalancing-Trade; geprüft wird die größte Abweichung über alle
            aktiven Assets. ``None`` (Standard) = an jedem Termin rebalancieren. Gewichte, Abweichung und
            Depotwert werden an jedem Rebalancing-Tag zum Tageskurs vor dem Handel bestimmt (nach Sparrate und
            Signal-Ein-/Ausstieg des Tages), gehandelt wird zum selben Kurs. Werte unter 0,2 (vermutlich Anteil,
            z. B. ``0.05`` für 5 Prozentpunkte) werden mit Warnung als Prozent gelesen. ``split_rule``:
            Numerischer Vektor der Länge 2 ``[untere, obere]``: Kursschwellen in Preiseinheiten der Kursreihe.
            Steigt der Kurs über die obere Schwelle, folgt ein Split (Verhältnis Kurs/100), fällt er unter die
            untere, eine Zusammenlegung (100/Kurs); der Kurs wird jeweils auf 100 gesetzt. Bestand, Lots und die
            gesamte Kurshistorie (auch der Jahresanfangskurs für die Vorabpauschale) werden umgerechnet. Erwartet
            wird ``untere < 100 < obere``; sonst Warnung, da nach dem ersten Split (Kurs 100) an jedem folgenden
            Tag ein weiterer Split ausgelöst wird. Kein Zahlenvektor der Länge 2: Fehler. Hat ein Asset am
            Split-Tag keinen Bestand, wird seine Kursreihe trotzdem umgerechnet.

    Beispiel::

        import simlev
        print(simlev.split_rule([20, 500]))
    """
    thresh = None if isinstance(thresh, _Missing) else thresh
    st = _num_vec(thresh) if thresh is not None else None
    if st is None or len(st) != 2 or any(v is None or math.isnan(v) for v in st):
        _stop("split_rule: thresh muss ein Zahlenvektor c(untere, obere) der Länge 2 sein.")   # seit 1.6.4 ohne Eingabewert
    if not (st[0] < 100 < st[1]):
        _warn("split_rule: thresh = c(%s, %s) schließt den Zielkurs 100 nicht ein (erwartet untere < 100 < obere). "
              "Ein Split setzt den Kurs auf 100; liegt 100 außerhalb der Schwellen, folgt danach an jedem Tag ein "
              "weiterer Split (mit fractions = FALSE jeweils mit Spitzenausgleich)." % (r_format1(st[0]), r_format1(st[1])))
    return _mk(SimLevSplitRule, [("thresh", [float(v) for v in st])])


@_blk_doc
def income_rate(marginal_rate: Any = _MISSING, *, soli_rate: Any = 0) -> SimLevIncomeRate:
    """Baustein für simulation (gemeinsamer Text in ``_BLK_DOC_KOPF`` und ``_BLK_DOC_SCHLUSS``).
    Args:
        marginal_rate: ``income_rate``: Persönlicher Grenzsteuersatz **in Prozent** (z. B. ``42``), zulässig 0 bis
            50; Pflicht. Werte zwischen 0 und 1 (vermutlich Anteil) werden mit Warnung als Prozent gelesen. Die §
            23-Steuer (Satz mal (1 + Soli-Satz + Kirchensteuersatz)) entsteht mit dem Jahresabschluss und wird am
            Abrechnungstag der Vorabpauschale aus dem Depot gezahlt.
        soli_rate: ``income_rate``: Solidaritätszuschlag auf die Einkommensteuer **in Prozent** (z. B. ``5.5``);
            ``0`` (Standard) heißt ohne Soli (seit 2021 zahlen wegen der Freigrenze die meisten Steuerpflichtigen
            keinen Soli auf die Einkommensteuer). Eine einzelne endliche Zahl ``>= 0``.

    Beispiel::

        import simlev
        print(simlev.tax_profile(church_tax=9, guenstigerpruefung=True, income=simlev.income_rate(42)))
    """
    who = "income_rate"
    marginal_rate = None if isinstance(marginal_rate, _Missing) else chk_scalar(marginal_rate)
    soli_rate = chk_scalar(soli_rate)
    _blk_num(who, marginal_rate, "marginal_rate", "eine einzelne Zahl in Prozent von 0 bis 50 (z. B. 42)")
    _blk_frac_warn(who, marginal_rate, "marginal_rate")
    if marginal_rate > 50:
        _stop("income_rate: marginal_rate muss ein Grenzsteuersatz in Prozent zwischen 0 und 50 sein (z. B. 42 für "
              "42 %).")
    _blk_num(who, soli_rate, "soli_rate", "eine einzelne endliche Zahl >= 0 in Prozent (z. B. 5.5; 0 = ohne Soli)")
    return _mk(SimLevIncomeRate, [("marginal_rate", marginal_rate), ("soli_rate", soli_rate)])


@_blk_doc
def income_tariff(taxable_income: Any = _MISSING, *, tariff: Any = None) -> SimLevIncomeTariff:
    """Baustein für simulation (gemeinsamer Text in ``_BLK_DOC_KOPF`` und ``_BLK_DOC_SCHLUSS``).
    Args:
        taxable_income: ``income_tariff``: Zu versteuerndes Einkommen (zvE) in EUR je Kalenderjahr **ohne** die
            Kapitalerträge und § 23-Gewinne der Simulation; Pflicht. Eine Zahl (gilt für alle Jahre), ein nach
            Kalenderjahren benannter Zahlenvektor (z. B. ``{"2024": 50000, "2025": 52000}``) oder ein
            ``data.frame`` mit den Spalten ``year`` und ``taxable_income`` (oder genau zwei Spalten Jahr, Betrag).
            Fehlt ein Kalenderjahr der Simulation, bricht ``simulation()`` mit Fehler ab. Die Engine rechnet dann
            mit dem Einkommensteuertarif (Abschnitt „Einkommensteuertarif“ in ``simulation``). Für
            ``withdrawal_simulation`` gilt das zvE je **Planjahr**, nominal wie angegeben: eine Zahl für alle
            Planjahre oder ein Vektor **ohne** Namen mit einem Wert je Planjahr (in ``simulation()`` ein Fehler);
            nach Kalenderjahren benannt nur mit einem ``SimLevResult`` als ``start_value``. Das ``income`` von
            ``withdrawal_simulation()`` zählt nicht zum zvE; einen steuerpflichtigen Teil (etwa einer Rente)
            selbst in ``taxable_income`` einrechnen.
        tariff: ``income_tariff``: ``None`` (Standard: mitgelieferte Datei ``system.file("extdata",
            "steuertarif.csv", package = "SimLev")``, Rechtslage ab VZ 2026), ein Dateipfad (wird beim Anlegen mit
            ``tax_tariff`` gelesen) oder ein Objekt aus ``tax_tariff``.

    Beispiel::

        import simlev
        print(simlev.tax_profile(income=simlev.income_tariff(60000)))
    """
    if isinstance(taxable_income, _Missing) or taxable_income is None:
        _stop("income_tariff: taxable_income (zu versteuerndes Einkommen in EUR je Kalenderjahr ohne die Erträge der "
              "Simulation) fehlt.")
    _check_taxable_income(taxable_income, [], who="income_tariff", plan_ok=True)  # auch je Planjahr
    if tariff is not None and not isinstance(tariff, SimLevTaxTariff):
        if isinstance(tariff, str):
            tariff = tax_tariff(file=tariff)
        else:
            _stop("income_tariff: tariff muss NULL (mitgelieferte Tarifdatei), ein Dateipfad oder ein Objekt aus "
                  "tax_tariff() sein.")
    return _mk(SimLevIncomeTariff, [("taxable_income", taxable_income), ("tariff", tariff)])


@_blk_doc
def harvest_rule(*, day: Any = "12-15", loss_pot: Any = True) -> SimLevHarvestRule:
    """Baustein für simulation (gemeinsamer Text in ``_BLK_DOC_KOPF`` und ``_BLK_DOC_SCHLUSS``).
    Args:
        day: ``harvest_rule``: Termin als ``"MM-TT"`` (Standard ``"12-15"``); genutzt wird der erste Handelstag ab
            diesem Datum, vor dem 31.12. (sonst Fehler). Nur Ziffern 0--9; seit 1.6.4 Monat 01 bis 12 und Tag 01 bis 31.
        loss_pot: ``harvest_rule``: Auch den Verlusttopf durch realisierte Gewinne nutzen? Standard ``True``.

    Beispiel::

        import simlev
        print(simlev.tax_profile(harvest=simlev.harvest_rule(day="12-15")))
    """
    day, loss_pot = chk_scalar(day), chk_scalar(loss_pot)
    # wie R: nur ASCII-Ziffern, kein Zeilenende (seit 1.6.4, A-012)
    # seit 1.6.4 Monat 01-12 und Tag 01-31 (Entscheidung 35)
    if not isinstance(day, str) or not re.fullmatch(r"(0[1-9]|1[0-2])-(0[1-9]|[12][0-9]|3[01])", day) or day >= "12-31":
        _stop("harvest_rule: day im Format 'MM-TT' (Monat 01 bis 12, Tag 01 bis 31) und vor dem 31.12. angeben "
              "(z. B. '12-15').")   # seit 1.6.4 mit den Bereichen (F8)
    _blk_lgl("harvest_rule", loss_pot, "loss_pot")
    return _mk(SimLevHarvestRule, [("day", day), ("loss_pot", bool(loss_pot))])


@_blk_doc
def tax_profile(*, rate: Any = _Dflt(26.375), church_tax: Any = 0, sparer_pauschbetrag: Any = 1000,
                private_sale_threshold: Any = 1000, base_rate: Any = None, guenstigerpruefung: Any = False,
                income: Any = None, harvest: Any = None) -> SimLevTaxProfile:
    """Baustein für simulation (gemeinsamer Text in ``_BLK_DOC_KOPF`` und ``_BLK_DOC_SCHLUSS``).
    Args:
        rate: ``tax_profile``: Kapitalertragsteuersatz inkl. Solidaritätszuschlag **in Prozent** (z. B. ``26.375``
            = 25 % KapESt + 5,5 % Soli), zulässig 0 bis 100. Werte zwischen 0 und 1 (vermutlich ein Anteil) werden
            mit Warnung als Prozent gelesen. Gilt nur ohne Kirchensteuer: ``rate`` zusammen mit ``church_tax > 0``
            ergibt einen Fehler. Standard: ``26.375``.
        church_tax: ``tax_profile``: Kirchensteuersatz in Prozent (``8`` oder ``9``; Standard ``0``). Setzt den
            Abgeltungsteuersatz nach § 32d Abs. 1 EStG (25 % / (1 + 0,25 k) zuzüglich Solidaritätszuschlag und
            Kirchensteuer), z. B. 27,99 % bei 9 %. Auf die Einkommensteuer (§ 23-Steuer mit ``income_rate()``,
            persönlicher Satz der Günstigerprüfung) wird die Kirchensteuer als ``church_tax`` Prozent der
            Einkommensteuer aufgeschlagen. Mit ``income_tariff()`` ist die Kirchensteuer ``church_tax`` Prozent
            der Einkommensteuer und wird als Sonderausgabe im Jahr ihrer Zahlung berücksichtigt. Zulässig ist eine
            Zahl von 0 bis 100; Werte zwischen 0 und 1 (Anteil statt Prozent) und über 9 werden mit Warnung
            angenommen.
        sparer_pauschbetrag: ``tax_profile``: Jährlicher Sparer-Pauschbetrag in EUR (Freibetrag; ``2000`` bei
            Zusammenveranlagung); ``0`` heißt ohne Pauschbetrag. Genutzt wird höchstens der positive Jahressaldo
            der Kapitalerträge nach Verlustverrechnung (§ 20 Abs. 9 Satz 4, § 43a Abs. 3 EStG), Verlusttopf vor
            Pauschbetrag (siehe ``simulation``). Eine einzelne endliche Zahl ``>= 0`` (sonst Fehler). Standard:
            ``1000``.
        private_sale_threshold: ``tax_profile``: Jährliche Freigrenze nach § 23 Abs. 3 Satz 5 EStG in EUR, für
            alle Jahre gleich. Ab Erreichen der Freigrenze ist der Jahressaldo abzüglich Verlustvortrag
            steuerpflichtig (BFH IX R 27/04), darunter steuerfrei. Eine einzelne endliche Zahl ``>= 0`` (sonst
            Fehler). Standard: ``1000``.
        base_rate: ``tax_profile``: Basiszins für die Vorabpauschale: ``None`` (Standard: keine Vorabpauschale),
            eine Zahl **in Prozent** (z. B. ``2.55`` = 2,55 %; negativ erlaubt und wie 0 behandelt) oder der Name
            einer Spalte in ``data`` mit täglichen Basiszinswerten in Prozent (wie ``risk_free``; seit 1.6.4 Zahlen ohne
            ``NA``, Jahre ohne Basiszins als 0; für ein Jahr zählt der Wert vom ersten Handelstag, § 18 Abs. 4 InvStG). Zahlen zwischen 0 und 0,05
            (vermutlich Anteil) werden mit Warnung als Prozent gelesen, für eine Spalte gilt dieselbe Schwelle für
            den Median; fehlt die Spalte, bricht ``simulation()`` mit Fehler ab.
        guenstigerpruefung: ``tax_profile``: Günstigerprüfung nach § 32d Abs. 6 EStG anwenden? Mit
            ``income_rate()`` wird statt ``rate`` der persönliche Satz (mit Soli und Kirchensteuer) verwendet,
            wenn die Belastung einschließlich Zuschlagsteuern niedriger ist; ohne Grenzsteuersatz warnt
            ``simulation()`` und rechnet mit der Abgeltungsteuer. Mit ``income_tariff()`` wird unterjährig die
            Abgeltungsteuer einbehalten und im Jahresabschluss mit dem Tarif verglichen; die Differenz wird
            erstattet. Standard: ``False``.
        income: ``tax_profile``: Einkommen für § 23 EStG und die Günstigerprüfung: ``None`` (Standard; sind §
            23-Gewinne steuerpflichtig, werden 42 % angesetzt, mit Warnung in ``simulation()``), ``income_rate()``
            (fester Grenzsteuersatz) oder ``income_tariff()`` (Einkommensteuertarif); beide Wege schließen sich
            aus.
        harvest: ``tax_profile``: ``None`` (Standard) oder ``harvest_rule()``: Einmal je Jahr werden bei Fonds und
            § 20-Produkten Gewinne bis zum noch freien Sparer-Pauschbetrag (und mit ``loss_pot`` bis zur Höhe des
            Verlusttopfs) realisiert und sofort wieder angelegt („Freibetrag ausschöpfen“); Spread und Gebühren
            fallen für Verkauf und Kauf an.

    Beispiel::

        import simlev
        print(simlev.tax_profile(church_tax=9, base_rate=2.29, income=simlev.income_rate(42), harvest=simlev.harvest_rule()))
    """
    who = "tax_profile"
    rate, church_tax, sparer_pauschbetrag, private_sale_threshold, base_rate, guenstigerpruefung = (
        chk_scalar(v) for v in (rate, church_tax, sparer_pauschbetrag, private_sale_threshold, base_rate,
                                guenstigerpruefung))
    rate_given = not isinstance(rate, _Dflt)
    if not _is_num(rate) or math.isnan(_to_float(rate)) or rate < 0 or rate > 100:
        _stop("tax_profile: rate muss eine einzelne Zahl in Prozent zwischen 0 und 100 sein (z. B. 26.375 für "
              "26,375 %).")
    rate = float(rate)
    _blk_frac_warn(who, rate, "rate")
    if church_tax is not None:
        if not _is_num(church_tax) or math.isnan(_to_float(church_tax)) or church_tax < 0 or church_tax > 100:
            _stop("tax_profile: church_tax muss eine Zahl in Prozent zwischen 0 und 100 sein (in Deutschland 8 oder 9).")
        if 0 < church_tax < 1:
            _warn("tax_profile: church_tax = %s wird als %s %% gelesen (Prozent-Konvention); gemeint war vermutlich %s."
                  % (r_format1(church_tax), r_format1(church_tax), r_format1(church_tax * 100)))
        elif church_tax > 9:
            _warn("tax_profile: church_tax = %s %% ist ungewöhnlich hoch (Kirchensteuer in Deutschland: 8 oder 9 %%)."
                  % r_format1(church_tax))
        if church_tax > 0 and rate_given:
            _stop("tax_profile: rate und church_tax schließen sich aus; rate gilt nur ohne Kirchensteuer (mit "
                  "church_tax gilt der Satz nach § 32d Abs. 1 EStG).")
    _blk_num(who, sparer_pauschbetrag, "sparer_pauschbetrag",
             "eine einzelne endliche Zahl >= 0 (EUR je Jahr, z. B. 1000; 0 = ohne)")
    _blk_num(who, private_sale_threshold, "private_sale_threshold",
             "eine einzelne endliche Zahl >= 0 (Freigrenze in EUR, z. B. 1000)")
    msg = ("tax_profile: 'base_rate' muss NULL, eine einzelne endliche Zahl (Basiszins in Prozent, z. B. 2.29; negativ "
           "erlaubt) oder der Name einer Spalte in data sein.")
    if isinstance(base_rate, str):
        if base_rate == "":
            _stop(msg)
    else:
        if base_rate is not None and not _one_num(base_rate):
            _stop(msg)
        _blk_frac_warn(who, base_rate, "base_rate", hi=0.05)
    _blk_lgl(who, guenstigerpruefung, "guenstigerpruefung")
    if income is not None and not isinstance(income, (SimLevIncomeRate, SimLevIncomeTariff)):
        _stop("tax_profile: income muss NULL, ein Objekt aus income_rate() oder aus income_tariff() sein (beide "
              "schließen sich aus).")
    if harvest is not None and not isinstance(harvest, SimLevHarvestRule):
        _stop("tax_profile: harvest muss NULL oder ein Objekt aus harvest_rule() sein.")
    return _mk(SimLevTaxProfile, [("rate", rate), ("church_tax", church_tax), ("sparer_pauschbetrag", sparer_pauschbetrag),
                                  ("private_sale_threshold", private_sale_threshold), ("base_rate", base_rate),
                                  ("guenstigerpruefung", bool(guenstigerpruefung)), ("income", income),
                                  ("harvest", harvest)])


@_blk_doc
def funds_costs(*, fee: Any = 0.95, performance_fee: Any = 5) -> SimLevFundsCosts:
    """Baustein für simulation (gemeinsamer Text in ``_BLK_DOC_KOPF`` und ``_BLK_DOC_SCHLUSS``).
    Args:
        fee: ``funds_costs``: Jährliche Verwaltungsgebühr (Fondskostenquote) **in Prozent** (z. B. ``0.95``), im
            Wrapper täglich je Kalendertag vom Anteilswert abgezogen. Zulässig 0 bis 100 (sonst Fehler). Standard:
            ``0.95``.
        performance_fee: ``funds_costs``: Performancegebühr **in Prozent** des Wertzuwachses des Anteilswerts über
            dem Höchststand (High-Water-Mark über die ganze Laufzeit); im Wrapper täglich abgegrenzt und am
            letzten Datentag jedes Kalenderjahres festgeschrieben. Zulässig 0 bis 100 (sonst Fehler). Standard:
            ``5``.

    Beispiel::

        import simlev
        print(simlev.funds_costs(fee=0.5, performance_fee=10))
    """
    fee, performance_fee = chk_scalar(fee), chk_scalar(performance_fee)
    for a, x in (("fee", fee), ("performance_fee", performance_fee)):
        if not _is_num(x) or math.isnan(_to_float(x)) or x < 0 or x > 100:
            _stop("funds_costs: %s muss eine Zahl in Prozent zwischen 0 und 100 sein (z. B. %s)."
                  % (a, "0.95 für 0,95 % p. a." if a == "fee" else "5 für 5 %"))
    return _mk(SimLevFundsCosts, [("fee", fee), ("performance_fee", performance_fee)])


# ── Übersetzer ───────────────────────────────────────────────────────────────

def _sim_from_blocks(costs, dca, rebalance, splits, tax) -> dict:
    """Bausteine prüfen und in die Argumente der Engine übersetzen (R: ``.sim_from_blocks``).

    ``rebalance_plan()`` heißt ``balance_mode = True``; nur mit ``event_col``, ``event_mode = "replace"`` und
    ``skip = True`` wird ``balance_mode = False``. ``sparer_pauschbetrag = 0`` heißt
    ``use_sparer_pauschbetrag = False``.
    """
    _blk_check(costs, SimLevSimCosts, "costs", "sim_costs")
    _blk_check(dca, SimLevDcaPlan, "dca", "dca_plan")
    _blk_check(rebalance, SimLevRebalancePlan, "rebalance", "rebalance_plan")
    _blk_check(splits, SimLevSplitRule, "splits", "split_rule")
    _blk_check(tax, SimLevTaxProfile, "tax", "tax_profile")
    a: dict = {"order_fee": None if costs is None else costs["order_fee"],
               "dca_fee": None if costs is None else costs["dca_fee"]}
    if dca is not None:
        a.update(dca_mode=True, dca_value=dca["value"], dca_span=dca["span"], dca_days=dca["days"],
                 dca_unit=dca["unit"], dca_anchor=dca["anchor"], dca_start=dca["start"], dca_skip=dca["skip"],
                 balance_dca=dca["fill_deficits"])
    if rebalance is not None:
        events_only = rebalance["event_col"] is not None and rebalance["event_mode"] == "replace"
        a.update(balance_mode=not (events_only and rebalance["skip"] is True), balance_span=rebalance["span"],
                 balance_days=rebalance["days"], balance_unit=rebalance["unit"], balance_anchor=rebalance["anchor"],
                 balance_start=rebalance["start"], balance_skip=rebalance["skip"], balance_thresh=rebalance["thresh"],
                 balance_thresh_type=rebalance["thresh_type"], event_col=rebalance["event_col"],
                 event_mode=rebalance["event_mode"], event_weight=rebalance["event_weight"])
    if splits is not None:
        a.update(split_mode=True, split_thresh=splits["thresh"])
    if tax is not None:
        br = tax["base_rate"]
        a.update(tax_mode="person", tax_rate=tax["rate"], church_tax=tax["church_tax"],
                 sparer_pauschbetrag=tax["sparer_pauschbetrag"], use_sparer_pauschbetrag=tax["sparer_pauschbetrag"] > 0,
                 private_sale_threshold=tax["private_sale_threshold"],
                 base_rate=None if isinstance(br, str) else br, base_rate_flex=isinstance(br, str),
                 base_rate_data=br if isinstance(br, str) else None,
                 use_guenstigerpruefung=tax["guenstigerpruefung"])
        inc = tax["income"]
        if isinstance(inc, SimLevIncomeRate):
            a.update(marginal_tax_rate=inc["marginal_rate"], include_soli_on_income_tax=inc["soli_rate"] != 0,
                     soli_rate_income_tax=inc["soli_rate"])
        elif isinstance(inc, SimLevIncomeTariff):
            a.update(taxable_income=inc["taxable_income"], tax_tariff=inc["tariff"])
        if tax["harvest"] is not None:
            a.update(harvest_mode=True, harvest_day=tax["harvest"]["day"], harvest_loss_pot=tax["harvest"]["loss_pot"])
    return a


# ── Aufrufer von simulation(): sim_args und Pfade ────────────────
# R: Abschnitt „Aufrufer von simulation()“ in r/R/sim_blocks.R. sim_args der Aufrufer sind Argumente von
# simulation() (auch Bausteine); Raster und Suchräume sprechen Parameter der Bausteine mit Pfad an
# („dca.value“, „rebalance.thresh“, „tax.income.marginal_rate“). Alte flache Namen ergeben einen Fehler.

_SIM_TOP = ("start_value", "costs", "dca", "rebalance", "splits", "tax", "risk_free", "fractions",
            "liquidate", "details")
_SIM_BLOCKS = {"costs": "sim_costs", "dca": "dca_plan", "rebalance": "rebalance_plan", "splits": "split_rule",
               "tax": "tax_profile"}
_SIM_BLOCK_PARAMS = {
    "sim_costs": ("order_fee", "dca_fee"),
    "dca_plan": ("value", "span", "days", "unit", "anchor", "start", "skip", "fill_deficits"),
    "rebalance_plan": ("span", "days", "unit", "anchor", "start", "skip", "thresh", "thresh_type", "event_col",
                       "event_mode", "event_weight"),
    "split_rule": ("thresh",),
    "tax_profile": ("rate", "church_tax", "sparer_pauschbetrag", "private_sale_threshold", "base_rate",
                    "guenstigerpruefung", "income", "harvest"),
    "income_rate": ("marginal_rate", "soli_rate"),
    "income_tariff": ("taxable_income", "tariff"),
    "harvest_rule": ("day", "loss_pot")}
_SIM_SUB = {"income": ("income_rate", "income_tariff"), "harvest": ("harvest_rule",)}
_SIM_CLASS_CTOR = {"SimLevIncomeRate": "income_rate", "SimLevIncomeTariff": "income_tariff",
                   "SimLevHarvestRule": "harvest_rule"}
# alte flache Argumente: (Pfad, Hinweis); leerer Hinweis = aus dem Pfad gebildet
_SIM_FLAT = {
    "spread": ("", "den Spread je Asset (asset_config(spread = \u2026))"),
    "dca_mode": ("", "dca = dca_plan(\u2026) (NULL = ohne Sparplan)"),
    "dca_value": ("dca.value", ""), "dca_span": ("dca.span", ""), "dca_days": ("dca.days", ""),
    "dca_unit": ("dca.unit", ""), "dca_anchor": ("dca.anchor", ""), "dca_start": ("dca.start", ""),
    "dca_skip": ("dca.skip", ""), "balance_dca": ("dca.fill_deficits", ""),
    "balance_mode": ("", "rebalance = rebalance_plan(\u2026) (NULL = ohne Rebalancing)"),
    "balance_span": ("rebalance.span", ""), "balance_days": ("rebalance.days", ""),
    "balance_unit": ("rebalance.unit", ""), "balance_anchor": ("rebalance.anchor", ""),
    "balance_start": ("rebalance.start", ""), "balance_skip": ("rebalance.skip", ""),
    "balance_thresh": ("rebalance.thresh", ""), "balance_thresh_type": ("rebalance.thresh_type", ""),
    "event_col": ("rebalance.event_col", ""), "event_mode": ("rebalance.event_mode", ""),
    "event_weight": ("rebalance.event_weight", ""),
    "split_mode": ("", "splits = split_rule(\u2026) (NULL = ohne Splits)"),
    "split_thresh": ("splits.thresh", ""),
    "tax_mode": ("", "tax = tax_profile(\u2026) (NULL = ohne)"),
    "tax_rate": ("tax.rate", ""), "church_tax": ("tax.church_tax", ""),
    "sparer_pauschbetrag": ("tax.sparer_pauschbetrag", ""),
    "use_sparer_pauschbetrag": ("", "tax = tax_profile(sparer_pauschbetrag = 0) (0 = ohne Pauschbetrag)"),
    "private_sale_threshold": ("tax.private_sale_threshold", ""), "base_rate": ("tax.base_rate", ""),
    "base_rate_flex": ("", 'tax = tax_profile(base_rate = "<Spalte>")'),
    "base_rate_data": ("tax.base_rate", 'tax = tax_profile(base_rate = "<Spalte>")'),
    "use_guenstigerpruefung": ("tax.guenstigerpruefung", ""),
    "marginal_tax_rate": ("tax.income.marginal_rate", ""),
    "include_soli_on_income_tax": ("", "tax = tax_profile(income = income_rate(marginal_rate, soli_rate = \u2026))"),
    "soli_rate_income_tax": ("tax.income.soli_rate", ""),
    "taxable_income": ("tax.income.taxable_income", ""), "tax_tariff": ("tax.income.tariff", ""),
    "harvest_mode": ("", "tax = tax_profile(harvest = harvest_rule(\u2026))"),
    "harvest_day": ("tax.harvest.day", ""), "harvest_loss_pot": ("tax.harvest.loss_pot", ""),
    "order_fee": ("costs.order_fee", ""), "dca_fee": ("costs.dca_fee", "")}


def _sim_path_hint(path: str) -> str:
    s = path.split(".")
    ctor = _SIM_BLOCKS[s[0]]
    if len(s) == 2:
        return "%s = %s(%s = \u2026)" % (s[0], ctor, s[1])
    sub = [c for c in _SIM_SUB[s[1]] if s[2] in _SIM_BLOCK_PARAMS[c]][0]
    return "%s = %s(%s = %s(%s = \u2026))" % (s[0], ctor, s[1], sub, s[2])


def _sim_path_text() -> str:
    out = []
    for b, ctor in _SIM_BLOCKS.items():
        p = list(_SIM_BLOCK_PARAMS[ctor])
        sub = []
        for sname in [k for k in p if k in _SIM_SUB]:
            seen = []
            for c in _SIM_SUB[sname]:
                for q in _SIM_BLOCK_PARAMS[c]:
                    if q not in seen:
                        seen.append(q)
            sub += ["%s.%s" % (sname, q) for q in seen]
        out.append("%s (%s)" % (b, ", ".join(p + sub)))
    return "; ".join(out)


def _sim_path_ok(p: str) -> bool:
    s = p.split(".")
    if len(s) < 2 or len(s) > 3 or any(x == "" for x in s) or s[0] not in _SIM_BLOCKS:
        return False
    if s[1] not in _SIM_BLOCK_PARAMS[_SIM_BLOCKS[s[0]]]:
        return False
    return len(s) == 2 or (s[1] in _SIM_SUB and any(s[2] in _SIM_BLOCK_PARAMS[c] for c in _SIM_SUB[s[1]]))


def _sim_check_names(nms, who: str) -> None:
    """Namen von sim_args, Raster oder Suchraum prüfen (R: ``.sim_check_names``)."""
    for k in nms:
        k = str(k)
        if k in _SIM_TOP:
            continue
        if k in _SIM_FLAT:
            path, hint = _SIM_FLAT[k]
            if not hint:
                hint = _sim_path_hint(path)
            _stop("%s: %s gibt es nicht mehr; bitte %s%s." % (who, k, hint, ' (Pfad "%s")' % path if path else ""))
        if "." in k:
            if not _sim_path_ok(k):
                _stop('%s: unbekannter Pfad "%s"; möglich sind die Bausteine mit ihren Parametern: %s.'
                      % (who, k, _sim_path_text()))
            continue
        _stop('%s: unbekanntes Argument %s für simulation(); möglich sind %s sowie Pfade zu Parametern der '
              'Bausteine (z. B. "dca.value").' % (who, k if k else "ohne Namen", ", ".join(_SIM_TOP)))


_CTORS = None


def _ctor(name: str):
    global _CTORS
    if _CTORS is None:
        _CTORS = {"sim_costs": sim_costs, "dca_plan": dca_plan, "rebalance_plan": rebalance_plan,
                  "split_rule": split_rule, "tax_profile": tax_profile,
                  "income_rate": income_rate, "income_tariff": income_tariff, "harvest_rule": harvest_rule}
    return _CTORS[name]


def _sim_fields(obj) -> dict:
    return {} if obj is None else {str(k): obj[k] for k in obj.keys()}


def _sim_build(ctor: str, f: dict, set_: list):
    """Baustein aus Feldern neu bauen (R: ``.sim_build``)."""
    if ctor == "tax_profile" and "rate" not in set_:
        ct = f.get("church_tax")
        if ct is not None and _is_num(ct) and not math.isnan(_to_float(ct)) and ct > 0:
            f.pop("rate", None)
    if ctor == "rebalance_plan" and "event_mode" not in set_ and f.get("event_col") is None:
        f.pop("event_mode", None)
    return _ctor(ctor)(**f)


def _class_of(obj) -> str | None:
    rc = getattr(obj, "r_class", None)
    return rc[0] if rc else None


def _sim_args_set(args: dict, over, who: str) -> dict:
    """Argumente für ``simulation()`` setzen (R: ``.sim_args_set``): oberste Ebene wie ``modifyList``
    (``None`` entfernt das Argument), Pfade bauen den Baustein neu."""
    args = dict(args)
    if not over:
        return args
    over = dict(over)
    nm = [str(k) for k in over]
    _sim_check_names(nm, who)
    for k in [k for k in nm if "." not in k]:
        if over[k] is None:
            args.pop(k, None)
        else:
            args[k] = over[k]
    paths = [k for k in nm if "." in k]
    if not paths:
        return args
    parts = {p: p.split(".") for p in paths}
    blocks = []
    for p in paths:
        if parts[p][0] not in blocks:
            blocks.append(parts[p][0])
    for b in blocks:
        ctor = _SIM_BLOCKS[b]
        f = _sim_fields(args.get(b))
        set_ = []
        mine = [p for p in paths if parts[p][0] == b]
        for p in [p for p in mine if len(parts[p]) == 2]:
            k = parts[p][1]
            f[k] = over[p]
            set_.append(k)
        three = [p for p in mine if len(parts[p]) == 3]
        subs = []
        for p in three:
            if parts[p][1] not in subs:
                subs.append(parts[p][1])
        for sname in subs:
            jj = [p for p in three if parts[p][1] == sname]
            keys = [parts[p][2] for p in jj]
            base = f.get(sname)
            bctor = None if base is None else _SIM_CLASS_CTOR.get(_class_of(base))
            if bctor is not None and all(k in _SIM_BLOCK_PARAMS[bctor] for k in keys):
                sctor = bctor
            else:
                cand = [c for c in _SIM_SUB[sname] if all(k in _SIM_BLOCK_PARAMS[c] for k in keys)]
                if not cand:
                    _stop("%s: die Pfade %s passen zu keinem Baustein für %s (%s)."
                          % (who, ", ".join('"%s"' % p for p in jj), sname, ", ".join("%s()" % c for c in _SIM_SUB[sname])))
                sctor = cand[0]
            sf = _sim_fields(base) if sctor == bctor else {}
            for p in jj:
                sf[parts[p][2]] = over[p]
            f[sname] = _ctor(sctor)(**sf)
            set_.append(sname)
        args[b] = _sim_build(ctor, f, set_)
    return args


def _sim_call(data, strategy, args: dict):
    """``simulation()`` mit sim_args aufrufen (R: ``.sim_call``)."""
    from .engine import simulation
    return simulation(data, strategy, **args)


from ._r.base import quiet_fp  # noqa: E402

quiet_fp(globals(), __all__)
