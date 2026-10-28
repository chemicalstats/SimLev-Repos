"""Bausteine für ``simulation()`` (Port von ``r/R/sim_blocks.R``, Etappe 6.3, Anhang C).

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
- ``funds_costs(fee, performance_fee)``                            → ``funds``

``None`` heißt aus. ``_sim_from_blocks`` übersetzt die Bausteine in die internen Werte der Engine
(``engine._simulation_flat``), die unverändert rechnet.
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
                        _r_class_name, _stop, _unwrap, _warn)
from .config import _match_arg
from ._tax_tariff import SimLevTaxTariff, tax_tariff

__all__ = ["sim_costs", "dca_plan", "rebalance_plan", "split_rule", "tax_profile", "income_rate", "income_tariff",
           "harvest_rule", "funds_costs", "SimLevSimCosts", "SimLevDcaPlan", "SimLevRebalancePlan", "SimLevSplitRule",
           "SimLevTaxProfile", "SimLevIncomeRate", "SimLevIncomeTariff", "SimLevHarvestRule", "SimLevFundsCosts"]


class _Missing:
    """Platzhalter für ein R-Argument ohne Standardwert (R prüft ``missing()``)."""

    __slots__ = ()

    def __repr__(self) -> str:
        return "<missing>"


_MISSING = _Missing()


class _Dflt(float):
    """Standardwert, der als angegeben/nicht angegeben unterscheidbar bleibt (R: ``missing(rate)``)."""


# ── Prüfhilfen ────────────────────────────────────────────────────────────────

def _show(x: Any) -> str:
    return "NULL" if x is None else r_deparse(x)


def _one_num(x: Any) -> bool:
    return _is_num(x) and math.isfinite(float(x))


def _blk_num(who: str, x: Any, arg: str, what: str, mn: float | None = 0.0, null_ok: bool = False) -> None:
    if x is None and null_ok:
        return
    if not _one_num(x) or (mn is not None and x < mn):
        _stop("%s: '%s' muss %s sein, nicht %s." % (who, arg, what, _show(x)))


def _blk_lgl(who: str, x: Any, arg: str) -> None:
    if not _is_bool(x):
        _stop("%s: '%s' muss TRUE oder FALSE sein, nicht %s." % (who, arg, _show(x)))


def _blk_frac_warn(who: str, x: Any, arg: str, hi: float = 1.0) -> None:
    if _one_num(x) and 0 < x < hi:
        _warn("%s: %s = %s wird als %s %% gelesen (Prozent-Konvention); gemeint war vermutlich %s."
              % (who, arg, r_format1(x), r_format1(x), r_format1(x * 100)))


def _vec_of(x: Any) -> list:
    return list(x) if isinstance(x, (list, tuple, np.ndarray, pd.Series)) else [x]


def _blk_days(who: str, x: Any) -> Any:
    if x is None:
        return None
    v = _num_vec(x)
    if v is None or any(d is None or math.isnan(d) for d in v) or any(d < 1 or d > 31 or d != round(d) for d in v):
        _stop("%s: days muss ganze Zahlen von 1 bis 31 enthalten, nicht %s." % (who, ", ".join(r_format(_vec_of(x)))))
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
    if x is None:
        return
    try:
        d = _as_date(x)
    except Exception:  # noqa: BLE001 - as.Date-Fehler: kein Datum
        d = None
    if d is None:
        _stop("%s: start = '%s' ist kein Datum (erwartet Date oder \"JJJJ-MM-TT\")."
              % (who, x if isinstance(x, str) else r_format1(x)))


def _cls(x: Any) -> str:
    rc = getattr(x, "r_class", None)
    if isinstance(rc, tuple) and rc:
        return "/".join(rc)
    if isinstance(x, pd.DataFrame):
        return "data.frame"
    if isinstance(x, Mapping):
        return "list"
    return _r_class_name(x)


def _blk_check(x: Any, cls: type, arg: str, ctor: str) -> None:
    if x is not None and not isinstance(x, cls):
        _stop("simulation: %s muss NULL oder ein Objekt aus %s() sein, nicht %s." % (arg, ctor, _cls(x)))


# ── Druckhilfen ──────────────────────────────────────────────────────────────

def _blk_print(title: str, rows: list) -> str:
    w = max(len(k) for k, _ in rows) + 1
    return "\n".join([title] + ["  %s %s" % ((k + ":").ljust(w), v) for k, v in rows])


def _fmt(x: Any) -> str:
    return r_format1(float(x), digits=15)


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
    """Fondsmodus (R: ``funds_costs()``)."""
    r_class = ("SimLevFundsCosts",)

    def format(self) -> str:
        return _blk_print("Fondsmodus (funds_costs)",
                          [("Fondskosten", "%s %% p. a." % _fmt(self["fee"])),
                           ("Performancegebühr", "%s %% des Wertzuwachses über dem Höchststand"
                            % _fmt(self["performance_fee"]))])


def _mk(cls: type, items: list) -> RList:
    x = cls()
    for k, v in items:
        x[k] = v
    return x


# ── Konstruktoren ────────────────────────────────────────────────────────────

def sim_costs(*, order_fee: Any = None, dca_fee: Any = None) -> SimLevSimCosts:
    """Kosten für ``simulation()`` (Ordergebühr, Gebühr der Sparplankäufe); siehe R ``?sim_costs``."""
    _fee_spec(order_fee)
    _fee_spec(dca_fee)
    return _mk(SimLevSimCosts, [("order_fee", order_fee), ("dca_fee", dca_fee)])


def dca_plan(value: Any = _MISSING, span: Any = _MISSING, *, days: Any = None, unit: Any = ("month", "quarter", "year"),
             anchor: Any = ("start", "end"), start: Any = None, skip: Any = False, fill_deficits: Any = False) -> SimLevDcaPlan:
    """Sparplan für ``simulation()``; siehe R ``?dca_plan``."""
    who = "dca_plan"
    value = None if isinstance(value, _Missing) else value
    span = None if isinstance(span, _Missing) else span
    if not _one_num(value) or value <= 0:
        _stop("%s: 'value' muss eine einzelne endliche Zahl > 0 sein (Betrag je Sparplan-Termin in EUR), nicht %s."
              % (who, _show(value)))
    if not _one_num(span) or span < 1 or span != round(float(span)):
        _stop("%s: 'span' muss eine einzelne ganze Zahl >= 1 sein (Perioden zwischen zwei Terminen), nicht %s."
              % (who, _show(span)))
    days = _blk_days(who, days)
    unit = _match_arg(unit, ("month", "quarter", "year"), "unit")
    anchor = _match_arg(anchor, ("start", "end"), "anchor")
    _blk_start(who, start)
    _blk_lgl(who, skip, "skip")
    _blk_lgl(who, fill_deficits, "fill_deficits")
    return _mk(SimLevDcaPlan, [("value", value), ("span", span), ("days", days), ("unit", unit), ("anchor", anchor),
                               ("start", start), ("skip", bool(skip)), ("fill_deficits", bool(fill_deficits))])


def rebalance_plan(*, span: Any = None, days: Any = None, unit: Any = ("month", "quarter", "year"),
                   anchor: Any = ("start", "end"), start: Any = None, skip: Any = False, thresh: Any = None,
                   thresh_type: Any = ("absolute", "relative"), event_col: Any = None,
                   event_mode: Any = _Default(("additional", "replace")), event_weight: Any = None) -> SimLevRebalancePlan:
    """Rebalancing für ``simulation()``; siehe R ``?rebalance_plan``."""
    who = "rebalance_plan"
    days = _blk_days(who, days)
    unit = _match_arg(unit, ("month", "quarter", "year"), "unit")
    anchor = _match_arg(anchor, ("start", "end"), "anchor")
    _blk_start(who, start)
    _blk_lgl(who, skip, "skip")
    _blk_num(who, thresh, "thresh", "NULL oder eine einzelne endliche Zahl >= 0 in Prozent (z. B. 5)", null_ok=True)
    _blk_frac_warn(who, thresh, "thresh", hi=0.2)
    thresh_type = _match_arg(thresh_type, ("absolute", "relative"), "thresh_type")
    if event_col is None and not isinstance(event_mode, _Default):
        _warn("rebalance_plan: event_mode wirkt nur zusammen mit event_col und wird ignoriert.")
    event_mode = _match_arg(_unwrap(event_mode), ("additional", "replace"), "event_mode")
    if event_col is not None and not isinstance(event_col, str):
        _stop("rebalance_plan: event_col muss NULL oder der Name einer logischen Spalte in data sein, nicht %s."
              % _show(event_col))
    if event_col is None and event_weight is not None:
        _warn("rebalance_plan: event_weight wirkt nur zusammen mit event_col und wird ignoriert.")
    return _mk(SimLevRebalancePlan, [("span", span), ("days", days), ("unit", unit), ("anchor", anchor),
                                     ("start", start), ("skip", bool(skip)), ("thresh", thresh),
                                     ("thresh_type", thresh_type), ("event_col", event_col),
                                     ("event_mode", event_mode), ("event_weight", event_weight)])


def split_rule(thresh: Any = _MISSING) -> SimLevSplitRule:
    """Automatische Splits für ``simulation()``: ``thresh = (untere, obere)``; siehe R ``?split_rule``."""
    thresh = None if isinstance(thresh, _Missing) else thresh
    st = _num_vec(thresh) if thresh is not None else None
    if st is None or len(st) != 2 or any(v is None or math.isnan(v) for v in st):
        _stop("split_rule: thresh muss ein Zahlenvektor c(untere, obere) der Länge 2 sein, nicht %s."
              % ("NULL" if thresh is None else ", ".join(r_format(_vec_of(thresh)))))
    if not (st[0] < 100 < st[1]):
        _warn("split_rule: thresh = c(%s, %s) schließt den Zielkurs 100 nicht ein (erwartet untere < 100 < obere). "
              "Ein Split setzt den Kurs auf 100; liegt 100 außerhalb der Schwellen, folgt danach an jedem Tag ein "
              "weiterer Split (mit fractions = FALSE jeweils mit Spitzenausgleich)." % (r_format1(st[0]), r_format1(st[1])))
    return _mk(SimLevSplitRule, [("thresh", [float(v) for v in st])])


def income_rate(marginal_rate: Any = _MISSING, *, soli_rate: Any = 0) -> SimLevIncomeRate:
    """Einkommen mit festem Grenzsteuersatz (für ``tax_profile(income=)``); siehe R ``?income_rate``."""
    who = "income_rate"
    marginal_rate = None if isinstance(marginal_rate, _Missing) else marginal_rate
    _blk_num(who, marginal_rate, "marginal_rate", "eine einzelne Zahl in Prozent von 0 bis 50 (z. B. 42)")
    _blk_frac_warn(who, marginal_rate, "marginal_rate")
    if marginal_rate > 50:
        _stop("income_rate: marginal_rate muss ein Grenzsteuersatz in Prozent zwischen 0 und 50 sein (z. B. 42 für "
              "42 %%), nicht %s." % _show(marginal_rate))
    _blk_num(who, soli_rate, "soli_rate", "eine einzelne endliche Zahl >= 0 in Prozent (z. B. 5.5; 0 = ohne Soli)")
    return _mk(SimLevIncomeRate, [("marginal_rate", marginal_rate), ("soli_rate", soli_rate)])


def income_tariff(taxable_income: Any = _MISSING, *, tariff: Any = None) -> SimLevIncomeTariff:
    """Einkommen mit Einkommensteuertarif (für ``tax_profile(income=)``); siehe R ``?income_tariff``."""
    if isinstance(taxable_income, _Missing) or taxable_income is None:
        _stop("income_tariff: taxable_income (zu versteuerndes Einkommen in EUR je Kalenderjahr ohne die Erträge der "
              "Simulation) fehlt.")
    _check_taxable_income(taxable_income, [], who="income_tariff")
    if tariff is not None and not isinstance(tariff, SimLevTaxTariff):
        if isinstance(tariff, str):
            tariff = tax_tariff(file=tariff)
        else:
            _stop("income_tariff: tariff muss NULL (mitgelieferte Tarifdatei), ein Dateipfad oder ein Objekt aus "
                  "tax_tariff() sein.")
    return _mk(SimLevIncomeTariff, [("taxable_income", taxable_income), ("tariff", tariff)])


def harvest_rule(*, day: Any = "12-15", loss_pot: Any = True) -> SimLevHarvestRule:
    """Freibetrag jährlich ausschöpfen (für ``tax_profile(harvest=)``); siehe R ``?harvest_rule``."""
    if not isinstance(day, str) or not re.match(r"^\d{2}-\d{2}$", day) or day >= "12-31":
        _stop("harvest_rule: day im Format 'MM-TT' und vor dem 31.12. angeben (z. B. '12-15').")
    _blk_lgl("harvest_rule", loss_pot, "loss_pot")
    return _mk(SimLevHarvestRule, [("day", day), ("loss_pot", bool(loss_pot))])


def tax_profile(*, rate: Any = _Dflt(26.375), church_tax: Any = 0, sparer_pauschbetrag: Any = 1000,
                private_sale_threshold: Any = 1000, base_rate: Any = None, guenstigerpruefung: Any = False,
                income: Any = None, harvest: Any = None) -> SimLevTaxProfile:
    """Persönliche Besteuerung für ``simulation()``; siehe R ``?tax_profile``."""
    who = "tax_profile"
    rate_given = not isinstance(rate, _Dflt)
    if not _is_num(rate) or math.isnan(float(rate)) or rate < 0 or rate > 100:
        _stop("tax_profile: rate muss eine einzelne Zahl in Prozent zwischen 0 und 100 sein (z. B. 26.375 für "
              "26,375 %%), nicht %s." % _show(rate))
    rate = float(rate)
    _blk_frac_warn(who, rate, "rate")
    if church_tax is not None:
        if not _is_num(church_tax) or math.isnan(float(church_tax)) or church_tax < 0 or church_tax > 100:
            _stop("tax_profile: church_tax muss eine Zahl in Prozent zwischen 0 und 100 sein (in Deutschland 8 oder 9), "
                  "nicht %s." % ", ".join(r_format(_vec_of(church_tax))))
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
           "erlaubt) oder der Name einer Spalte in data sein, nicht %s.")
    if isinstance(base_rate, str):
        if base_rate == "":
            _stop(msg % _show(base_rate))
    else:
        if base_rate is not None and not _one_num(base_rate):
            _stop(msg % _show(base_rate))
        _blk_frac_warn(who, base_rate, "base_rate", hi=0.05)
    _blk_lgl(who, guenstigerpruefung, "guenstigerpruefung")
    if income is not None and not isinstance(income, (SimLevIncomeRate, SimLevIncomeTariff)):
        _stop("tax_profile: income muss NULL, ein Objekt aus income_rate() oder aus income_tariff() sein (beide "
              "schließen sich aus), nicht %s." % _cls(income))
    if harvest is not None and not isinstance(harvest, SimLevHarvestRule):
        _stop("tax_profile: harvest muss NULL oder ein Objekt aus harvest_rule() sein, nicht %s." % _cls(harvest))
    return _mk(SimLevTaxProfile, [("rate", rate), ("church_tax", church_tax), ("sparer_pauschbetrag", sparer_pauschbetrag),
                                  ("private_sale_threshold", private_sale_threshold), ("base_rate", base_rate),
                                  ("guenstigerpruefung", bool(guenstigerpruefung)), ("income", income),
                                  ("harvest", harvest)])


def funds_costs(*, fee: Any = 0.95, performance_fee: Any = 5) -> SimLevFundsCosts:
    """Fondsmodus für ``simulation()``; siehe R ``?funds_costs``."""
    for a, x in (("fee", fee), ("performance_fee", performance_fee)):
        if not _is_num(x) or math.isnan(float(x)) or x < 0 or x > 100:
            _stop("funds_costs: %s muss eine Zahl in Prozent zwischen 0 und 100 sein (z. B. %s), nicht %s."
                  % (a, "0.95 für 0,95 % p. a." if a == "fee" else "5 für 5 %",
                     "NULL" if x is None else ", ".join(r_format(_vec_of(x)))))
    return _mk(SimLevFundsCosts, [("fee", fee), ("performance_fee", performance_fee)])


# ── Übersetzer ───────────────────────────────────────────────────────────────

def _sim_from_blocks(costs, dca, rebalance, splits, tax, funds) -> dict:
    """Bausteine prüfen und in die Argumente der Engine übersetzen (R: ``.sim_from_blocks``).

    ``rebalance_plan()`` heißt ``balance_mode = True``; nur mit ``event_col``, ``event_mode = "replace"`` und
    ``skip = True`` wird ``balance_mode = False``. ``sparer_pauschbetrag = 0`` heißt
    ``use_sparer_pauschbetrag = False``. Fondsmodus (``funds``) mit ``tax``: ``tax_mode = "funds"`` mit den
    Angaben aus ``tax_profile()`` (wie R).
    """
    _blk_check(costs, SimLevSimCosts, "costs", "sim_costs")
    _blk_check(dca, SimLevDcaPlan, "dca", "dca_plan")
    _blk_check(rebalance, SimLevRebalancePlan, "rebalance", "rebalance_plan")
    _blk_check(splits, SimLevSplitRule, "splits", "split_rule")
    _blk_check(tax, SimLevTaxProfile, "tax", "tax_profile")
    _blk_check(funds, SimLevFundsCosts, "funds", "funds_costs")
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
        a.update(tax_mode="person" if funds is None else "funds", tax_rate=tax["rate"], church_tax=tax["church_tax"],
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
    if funds is not None:
        if tax is None:
            a["tax_mode"] = "funds"
        a.update(funds_fee=funds["fee"], bonus_fee=funds["performance_fee"])
    return a


# ── Aufrufer von simulation(): sim_args und Pfade (Etappe 6.4) ────────────────
# R: Abschnitt „Aufrufer von simulation()“ in r/R/sim_blocks.R. sim_args der Aufrufer sind Argumente von
# simulation() (auch Bausteine); Raster und Suchräume sprechen Parameter der Bausteine mit Pfad an
# („dca.value“, „rebalance.thresh“, „tax.income.marginal_rate“). Alte flache Namen ergeben einen Fehler.

_SIM_TOP = ("start_value", "costs", "dca", "rebalance", "splits", "tax", "funds", "risk_free", "fractions",
            "liquidate", "details")
_SIM_BLOCKS = {"costs": "sim_costs", "dca": "dca_plan", "rebalance": "rebalance_plan", "splits": "split_rule",
               "tax": "tax_profile", "funds": "funds_costs"}
_SIM_BLOCK_PARAMS = {
    "sim_costs": ("order_fee", "dca_fee"),
    "dca_plan": ("value", "span", "days", "unit", "anchor", "start", "skip", "fill_deficits"),
    "rebalance_plan": ("span", "days", "unit", "anchor", "start", "skip", "thresh", "thresh_type", "event_col",
                       "event_mode", "event_weight"),
    "split_rule": ("thresh",),
    "tax_profile": ("rate", "church_tax", "sparer_pauschbetrag", "private_sale_threshold", "base_rate",
                    "guenstigerpruefung", "income", "harvest"),
    "funds_costs": ("fee", "performance_fee"),
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
    "tax_mode": ("", "tax = tax_profile(\u2026) bzw. funds = funds_costs(\u2026) (NULL = ohne)"),
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
    "funds_fee": ("funds.fee", ""), "bonus_fee": ("funds.performance_fee", ""),
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
                  "split_rule": split_rule, "tax_profile": tax_profile, "funds_costs": funds_costs,
                  "income_rate": income_rate, "income_tariff": income_tariff, "harvest_rule": harvest_rule}
    return _CTORS[name]


def _sim_fields(obj) -> dict:
    return {} if obj is None else {str(k): obj[k] for k in obj.keys()}


def _sim_build(ctor: str, f: dict, set_: list):
    """Baustein aus Feldern neu bauen (R: ``.sim_build``)."""
    if ctor == "tax_profile" and "rate" not in set_:
        ct = f.get("church_tax")
        if ct is not None and _is_num(ct) and not math.isnan(float(ct)) and ct > 0:
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
