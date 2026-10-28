"""Phasen 1 und 2 von ``simulation()``: Eingabeprüfung, Datenvorbereitung, ``sim_mem``, Termine und Plan
(nachgebildet aus ``r/R/sim_validate.R`` und ``r/R/sim_prepare.R``; Julia: ``sim_phases.jl``).
"""
from __future__ import annotations

import math
import re
from typing import Mapping

import numpy as np
import pandas as pd

from ._dates import fmt_date, from_days, year_of
from ._r.rformat import r_as_character, r_deparse, r_format, r_format1, r_round
from ._r.rnum import r_median, r_sum
from .config import _match_arg
from ._tax_tariff import SimLevTaxTariff, tax_tariff
from ._r.rnum import NA_REAL as NA  # R's NA_real_ (Nutzlast 1954)
from ._sim_base import (
    _FEE,
    _Frame,
    _TariffEnv,
    _as_date,
    _calculate_dates_flags,
    _calculate_split_flags,
    _cat,
    _check_taxable_income,
    _date_or_fail,
    _fee_spec,
    _filled_matrix,
    _is_bool,
    _is_num,
    _is_true,
    _isna,
    _message,
    _num_vec,
    _r_class_name,
    _r_strptime_ymd,
    _shift_off_filled,
    _sp,
    _stop,
    _to_frame,
    _truthy,
    _warn,
    _ym,
)


# ═══════════════════════════════════════════════════════════════════════════
# Phase 1: Eingabeprüfung (sim_validate.R)
# ═══════════════════════════════════════════════════════════════════════════

def _frac_warn_col(fr: _Frame, col: str, arg: str, hi: float) -> None:
    if not fr.is_numeric(col):
        return
    v = fr.get(col)
    v = v[~np.isnan(v) & (v != 0)]
    if v.size == 0:
        return
    m = r_median(v)
    if math.isfinite(m) and 0 < m < hi:
        _warn("simulation: %s-Spalte '%s' hat den Median %s und wird als %s %% gelesen (Prozent-Konvention); gemeint "
              "waren vermutlich Werte x 100 (Median %s)." % (arg, col, r_format1(m), r_format1(m), r_format1(m * 100)))


def _sim_check_inputs(data, strategy, start_value, spread, details, dca_mode, dca_value, dca_span, dca_days,
                      balance_mode, balance_days, balance_thresh, balance_thresh_type, tax_mode, tax_rate,
                      marginal_tax_rate, use_guenstigerpruefung, private_sale_threshold, sparer_pauschbetrag,
                      use_sparer_pauschbetrag, include_soli_on_income_tax, soli_rate_income_tax, base_rate,
                      funds_fee, bonus_fee, fractions, risk_free, split_mode, split_thresh, event_col, church_tax,
                      order_fee, dca_fee, harvest_mode, harvest_day, taxable_income, tariff, given,
                      blocks=False) -> dict:
    """Phase 1 (``.sim_check_inputs``). ``tariff`` = Argument ``tax_tariff`` von ``_simulation_flat``;
    ``blocks=True``: Aufruf aus ``simulation()`` mit Bausteinen (Prüfungen der Bausteine entfallen hier,
    Meldungen nennen die Bausteine)."""
    tax_mode = _match_arg(tax_mode, ("none", "person", "funds"), "tax_mode")
    if not isinstance(data, (pd.DataFrame, Mapping)):
        _stop("simulation: data muss ein data.frame mit Spalte 'date' und je Asset einer Kursspalte sein, nicht %s."
              % ("fehlend" if data is None else _r_class_name(data)))
    if strategy is None or len(strategy) == 0:
        _stop("simulation: strategy muss eine nicht leere, benannte Liste von Asset-Konfigurationen sein (z. B. aus "
              "create_strategy()), nicht %s." % ("fehlend" if strategy is None else "leer (L\u00e4nge 0)"))
    if spread is not None:
        _warn("simulation: Das Argument 'spread' wird nicht ausgewertet; ma\u00dfgeblich ist spread je Asset "
              "(asset_config()).")
    if isinstance(data, pd.DataFrame):
        names_d = [str(c) for c in data.columns]
        dup = [nm for i, nm in enumerate(names_d) if nm in names_d[:i]]
    else:
        dup = []
    if not isinstance(strategy, Mapping) or any(str(k) == "" for k in strategy.keys()):
        _stop("simulation: Alle Assets in 'strategy' m\u00fcssen benannt sein (Name = Kursspalte in 'data').")
    if dup:
        _stop("simulation: Spaltenname '%s' kommt in 'data' mehrfach vor; jede Spalte muss eindeutig benannt sein."
              % dup[0])
    fr = _to_frame(data)
    filled_attr = fr.filled_attr
    strat: dict = {}
    for k, a in strategy.items():
        nm = str(k)
        if not isinstance(a, Mapping):
            _stop("simulation: Asset '%s' in 'strategy' muss eine Liste bzw. asset_config() sein." % nm)
        strat[nm] = dict(a)
    cls_ok = ["etf", "etn", "etc", "certificate", "etn_standard", "etn_deliverable"]
    for nm, a in strat.items():
        ac = a.get("asset_class")
        if not isinstance(ac, str) or ac not in cls_ok:
            _stop("simulation: asset_class %s von Asset '%s' ist ung\u00fcltig; erlaubt sind %s (veraltet: etn_standard, "
                  "etn_deliverable). Strategie am besten mit create_strategy()/asset_config() bauen."
                  % (r_deparse(ac), nm, ", ".join(cls_ok[:4])))
        tr_ = a.get("tax_regime")
        if tr_ is not None and (not isinstance(tr_, str) or tr_ not in ("investment_fund", "capital_gains",
                                                                           "private_sale")):
            _stop("simulation: tax_regime %s von Asset '%s' ist ung\u00fcltig; erlaubt sind investment_fund, capital_gains, "
                  "private_sale (oder weglassen: aus asset_class abgeleitet). Ohne Steuern %s verwenden."
                  % (r_deparse(tr_), nm, "tax = NULL" if blocks else "tax_mode = \"none\""))
        at = a.get("trading")
        if not isinstance(at, str) or at not in ("bnh", "signal"):
            _stop("simulation: trading %s von Asset '%s' ist ung\u00fcltig; erlaubt sind \"bnh\" und \"signal\"."
                  % (r_deparse(at), nm))
    if "date" not in fr:
        _stop("simulation: Spalte 'date' fehlt in 'data'.")
    miss = [nm for nm in strat if nm not in fr]
    if miss:
        _stop("simulation: %s %s in 'data'; je Asset der Strategie wird eine Spalte gleichen Namens erwartet "
              "(vorhanden: %s)." % ("Kursspalte" if len(miss) == 1 else "Kursspalten",
                                    ", ".join("'%s'" % m for m in miss) + " " + ("fehlt" if len(miss) == 1 else "fehlen"),
                                    ", ".join(nm for nm in fr.names if nm != "date")))
    if fr.nrow < 1:
        _stop("simulation: 'data' enth\u00e4lt keine Zeilen.")
    kind = fr.kinds["date"]
    if kind == "factor":
        kind = "character"
    if kind == "character":
        raw = fr.get("date")
        dd = np.array([NA if v is None else (NA if (z := _r_strptime_ymd(v)) is None else float(z)) for v in raw],
                      dtype=np.float64)
        bad = [i for i in range(len(raw)) if math.isnan(dd[i]) and raw[i] is not None]
        if bad:
            _stop("simulation: Spalte 'date' ist Text und '%s' (Zeile %d) ist kein Datum im Format JJJJ-MM-TT; vorher "
                  "mit as.Date(..., format = ...) umwandeln." % (raw[bad[0]], bad[0] + 1))
        fr.set("date", dd, "date")
        _message("Hinweis: Spalte 'date' wurde von Text in Date umgewandelt.")
    elif kind == "posixct":
        fr.kinds["date"] = "date"
        _message("Hinweis: Spalte 'date' wurde von Datum-Uhrzeit in Date umgewandelt.")
    if fr.kinds["date"] != "date":
        _stop("simulation: Spalte 'date' muss die Klasse Date haben (ist: %s)." % fr.r_class("date"))
    dvals = fr.get("date")
    if np.isnan(dvals).any():
        _stop("simulation: Spalte 'date' enth\u00e4lt NA (erstmals in Zeile %d)." % (int(np.flatnonzero(np.isnan(dvals))[0]) + 1))
    fa_m, fa_cols, fa_n = _filled_matrix(filled_attr)
    if np.any(np.diff(dvals) < 0):
        o = np.argsort(dvals, kind="stable")
        fr.take(o)
        if fa_m is not None and fa_m.shape[0] == len(o):
            fa_m = fa_m[o, :]
        _message("Hinweis: 'data' war nicht aufsteigend nach Datum sortiert und wurde sortiert.")
    dvals = fr.get("date")
    seen = set()
    dup_first = None
    n_dup = 0
    for z in dvals:
        if z in seen:
            n_dup += 1
            if dup_first is None:
                dup_first = z
        seen.add(z)
    if dup_first is not None:
        _stop("simulation: Datum %s kommt in 'data' mehrfach vor (%d doppelte Zeilen); je Tag genau eine Zeile."
              % (fmt_date(int(dup_first)), n_dup))
    nrow = fr.nrow
    if filled_attr is not None and fa_n != nrow:
        _warn("simulation: Attribut 'filled' von 'data' hat %d Zeilen, 'data' aber %d (z. B. nach Zeilenauswahl einer "
              "series_align()-Ausgabe); es wird ignoriert, aufgef\u00fcllte Tage gelten dann als Handelstage. Zeitraum "
              "besser mit series_align(..., start =, end =) w\u00e4hlen." % (fa_n, nrow))
        fa_m = None
    pre_filled = np.zeros(nrow, dtype=bool)
    if fa_m is not None and fa_m.shape[0] == nrow and fa_cols is not None:
        fc = [nm for nm in strat if nm in fa_cols]
        if fc:
            real = np.zeros(nrow, dtype=np.int64)
            for nm in fc:
                col = fr.get(nm)
                isna = np.isnan(col) if fr.is_numeric(nm) else np.array([_isna(v) for v in col])
                real += (~fa_m[:, fa_cols.index(nm)] & ~isna).astype(np.int64)
            pre_filled = real == 0
    all_na = np.ones(nrow, dtype=bool)
    for nm in strat:
        col = fr.get(nm)
        isna = np.isnan(col) if fr.is_numeric(nm) else np.array([_isna(v) for v in col], dtype=bool)
        all_na &= isna
    if all_na[0]:
        _stop("simulation: In der ersten Zeile von 'data' fehlen alle Kurse (NA); mindestens ein Asset muss am ersten "
              "Tag notieren. Daten erst ab dem ersten Kurs \u00fcbergeben.")
    pre_filled = pre_filled | all_na
    for nm in strat:
        if not fr.is_numeric(nm):
            _stop("simulation: Kursspalte '%s' muss numerisch sein (ist: %s)." % (nm, fr.r_class(nm)))
        v = fr.get(nm)
        bad = np.flatnonzero(~np.isnan(v) & ~(np.isfinite(v) & (v > 0)))
        if bad.size:
            _stop("simulation: Kursspalte '%s' enth\u00e4lt ung\u00fcltige Kurse (<= 0 oder unendlich), erstmals am %s "
                  "(Wert %s); erwartet werden positive Kursniveaus." % (nm, fmt_date(int(dvals[bad[0]])),
                                                                       r_format1(float(v[bad[0]]))))
        ok = np.flatnonzero(~np.isnan(v))
        if ok.size == 0:
            _stop("simulation: Kursspalte '%s' enth\u00e4lt nur NA." % nm)
        if ok.size < v.size:
            if ok[0] > 0:
                st0 = strat[nm].get("start")
                st_new = max(int(dvals[ok[0]]), int(dvals[0]) if st0 is None else _date_or_fail(st0))
                strat[nm]["start"] = st_new
                _message("Hinweis: '%s' hat erst ab %s Kurse; das Asset wird wie mit start = %s behandelt."
                         % (nm, fmt_date(int(dvals[ok[0]])), fmt_date(st_new)))
            n_gap = int(np.isnan(v).sum()) - int(ok[0])
            if n_gap > 0:
                _message("Hinweis: '%s': %d fehlende Kurse (NA) per LOCF gef\u00fcllt." % (nm, n_gap))
            idx = np.zeros(v.size, dtype=np.int64)
            idx[ok] = ok + 1
            idx = np.maximum.accumulate(idx)
            idx[idx == 0] = ok[0] + 1
            fr.cols[nm] = v[idx - 1]

    if start_value is None or (_is_num(start_value) and math.isnan(float(start_value))):
        start_value = 10000.0
        _message("Hinweis: start_value ist NULL oder NA; verwendet wird der Standardwert 10000 EUR.")
    if not _is_num(start_value) or start_value <= 0:
        _stop("simulation: start_value muss eine positive Zahl sein (Anfangskapital in EUR, z. B. 10000), nicht %s."
              % r_deparse(start_value))
    start_value = float(start_value)
    if not blocks and (not _is_num(tax_rate) or math.isnan(float(tax_rate)) or tax_rate < 0 or tax_rate > 100):
        _stop("simulation: tax_rate muss eine einzelne Zahl in Prozent zwischen 0 und 100 sein (z. B. 26.375 f\u00fcr "
              "26,375 %%), nicht %s." % r_deparse(tax_rate))
    tax_rate = float(tax_rate)
    if not blocks and 0 < tax_rate < 1:
        _warn("simulation: tax_rate = %s wird als %s %% gelesen (Prozent-Konvention); gemeint war vermutlich %s."
              % (r_format1(tax_rate), r_format1(tax_rate), r_format1(tax_rate * 100)))
    if church_tax is not None:
        if not blocks and (not _is_num(church_tax) or math.isnan(float(church_tax)) or church_tax < 0 or church_tax > 100):
            _stop("simulation: church_tax muss eine Zahl in Prozent zwischen 0 und 100 sein (in Deutschland 8 oder 9), "
                  "nicht %s." % ", ".join(r_format(church_tax)))
        church_tax = float(church_tax)
        if blocks:
            pass
        elif 0 < church_tax < 1:
            _warn("simulation: church_tax = %s wird als %s %% gelesen (Prozent-Konvention); gemeint war vermutlich %s."
                  % (r_format1(church_tax), r_format1(church_tax), r_format1(church_tax * 100)))
        elif church_tax > 9:
            _warn("simulation: church_tax = %s %% ist ungew\u00f6hnlich hoch (Kirchensteuer in Deutschland: 8 oder 9 %%)."
                  % r_format1(church_tax))
    if not blocks and _is_true(harvest_mode) and tax_mode != "person":
        _warn("simulation: harvest_mode wirkt nur mit tax_mode = \"person\" und wird hier ignoriert.")
    elif blocks and _is_true(harvest_mode) and tax_mode != "person":   # Fondsmodus mit tax_profile(harvest=)
        _warn("simulation: harvest (tax_profile(harvest = harvest_rule())) wirkt nicht im Fondsmodus "
              "(funds = funds_costs()) und wird hier ignoriert.")

    def show_arg(x):
        return "NULL" if x is None else r_deparse(x)

    def chk_num(x, arg, what, mn=0.0, null_ok=False):
        if x is None and null_ok or blocks:
            return
        if not _is_num(x) or not math.isfinite(float(x)) or (mn is not None and x < mn):
            _stop("simulation: '%s' muss %s sein, nicht %s." % (arg, what, show_arg(x)))
    chk_num(sparer_pauschbetrag, "sparer_pauschbetrag", "eine einzelne endliche Zahl >= 0 (EUR je Jahr, z. B. 1000)")
    chk_num(private_sale_threshold, "private_sale_threshold",
            "eine einzelne endliche Zahl >= 0 (Freigrenze in EUR, z. B. 1000)")
    chk_num(base_rate, "base_rate", "NULL oder eine einzelne endliche Zahl (Basiszins in Prozent, z. B. 2.29; "
            "negativ erlaubt)", mn=None, null_ok=True)
    chk_num(marginal_tax_rate, "marginal_tax_rate", "NULL oder eine einzelne Zahl in Prozent von 0 bis 50 (z. B. 42)",
            null_ok=True)
    chk_num(balance_thresh, "balance_thresh", "NULL oder eine einzelne endliche Zahl >= 0 in Prozent (z. B. 5)",
            null_ok=True)
    for a, x in (("use_guenstigerpruefung", use_guenstigerpruefung),
                 ("include_soli_on_income_tax", include_soli_on_income_tax),
                 ("fractions", fractions), ("use_sparer_pauschbetrag", use_sparer_pauschbetrag)):
        if (not blocks or a == "fractions") and not _is_bool(x):
            _stop("simulation: '%s' muss TRUE oder FALSE sein, nicht %s." % (a, show_arg(x)))
    sparer_pauschbetrag = float(sparer_pauschbetrag)
    private_sale_threshold = float(private_sale_threshold)
    use_guenstigerpruefung = bool(use_guenstigerpruefung)
    include_soli_on_income_tax = bool(include_soli_on_income_tax)
    fractions = bool(fractions)
    use_sparer_pauschbetrag = bool(use_sparer_pauschbetrag)

    def frac_warn(x, arg, hi=1.0):
        if blocks and arg != "risk_free":
            return
        if _is_num(x) and math.isfinite(float(x)) and 0 < x < hi:
            _warn("simulation: %s = %s wird als %s %% gelesen (Prozent-Konvention); gemeint war vermutlich %s."
                  % (arg, r_format1(x), r_format1(x), r_format1(x * 100)))
    frac_warn(base_rate, "base_rate", hi=0.05)
    frac_warn(marginal_tax_rate, "marginal_tax_rate")
    frac_warn(balance_thresh, "balance_thresh", hi=0.2)
    frac_warn(risk_free, "risk_free", hi=0.05)
    if isinstance(risk_free, str) and risk_free in fr:
        _frac_warn_col(fr, risk_free, "risk_free", hi=0.05)
    if not blocks and not _is_true(dca_mode) and dca_value is not None:
        _warn("simulation: dca_value wirkt nur mit dca_mode = TRUE und wird ignoriert.")
    if not blocks and not _is_true(balance_mode) and event_col is None and balance_thresh is not None:
        _warn("simulation: balance_thresh wirkt nur mit balance_mode = TRUE oder event_col (Rebalancing) und wird "
              "ignoriert.")
    if event_col is None and given["event_mode"]:
        _warn("simulation: event_mode wirkt nur zusammen mit event_col und wird ignoriert.")

    def check_days(x, arg):
        if x is None or blocks:
            return
        v = _num_vec(x)
        if v is None or any(math.isnan(d) for d in v) or any(d < 1 or d > 31 or d != r_round(d) for d in v):
            shown = r_format(list(x) if isinstance(x, (list, tuple, np.ndarray)) else x)
            _stop("simulation: %s muss ganze Zahlen von 1 bis 31 enthalten, nicht %s." % (arg, ", ".join(shown)))
    check_days(dca_days, "dca_days")
    check_days(balance_days, "balance_days")
    days_out = {}
    for a, x in (("dca_days", dca_days), ("balance_days", balance_days)):
        if x is not None and not blocks:
            v = _num_vec(x)
            u = []
            for d in v:
                if d not in u:
                    u.append(d)
            if len(u) < len(v):
                _warn("simulation: %s enth\u00e4lt doppelte Tage (%s); jeder Tag ergibt nur einen Termin, verwendet wird "
                      "%s = %s." % (a, ", ".join(r_format(v)), a, r_deparse(u)))
                x = u
        days_out[a] = x
    dca_days, balance_days = days_out["dca_days"], days_out["balance_days"]
    if not blocks and _is_true(split_mode) and split_thresh is not None:
        st_v = _num_vec(split_thresh)
        if st_v is None or len(st_v) != 2 or any(math.isnan(v) for v in st_v):
            shown = r_format(list(split_thresh) if isinstance(split_thresh, (list, tuple, np.ndarray)) else split_thresh)
            _stop("simulation: split_thresh muss ein Zahlenvektor c(untere, obere) der L\u00e4nge 2 sein, nicht %s."
                  % ", ".join(shown))
        if not (st_v[0] < 100 < st_v[1]):
            _warn("simulation: split_thresh = c(%s, %s) schlie\u00dft den Zielkurs 100 nicht ein (erwartet untere < 100 < "
                  "obere). Ein Split setzt den Kurs auf 100; liegt 100 au\u00dferhalb der Schwellen, folgt danach an jedem "
                  "Tag ein weiterer Split (mit fractions = FALSE jeweils mit Spitzenausgleich)."
                  % (r_format1(st_v[0]), r_format1(st_v[1])))
    if tax_mode != "funds" and (given["funds_fee"] or given["bonus_fee"]):
        gv = [a for a, g in (("funds_fee", given["funds_fee"]), ("bonus_fee", given["bonus_fee"])) if g]
        _warn("simulation: %s wirkt nur bei tax_mode = \"funds\" (hier tax_mode = \"%s\") und wird ignoriert."
              % (" und ".join(gv), tax_mode))
    if tax_mode == "funds" and not blocks:
        for a, x in (("funds_fee", funds_fee), ("bonus_fee", bonus_fee)):
            if not _is_num(x) or math.isnan(float(x)) or x < 0 or x > 100:
                _stop("simulation: %s muss eine Zahl in Prozent zwischen 0 und 100 sein (z. B. %s), nicht %s."
                      % (a, "0.95 f\u00fcr 0,95 % p. a." if a == "funds_fee" else "5 f\u00fcr 5 %",
                         ", ".join(r_format(x)) if x is not None else "NULL"))     # format(NULL) = "NULL"

    tariff_on = taxable_income is not None and tax_mode == "person"
    if taxable_income is not None and tax_mode != "person":
        _warn("simulation: income_tariff() (tax_profile(income =)) wirkt nicht im Fondsmodus (funds = funds_costs()) "
              "und wird ignoriert." if blocks else
              "simulation: taxable_income wirkt nur bei tax_mode = \"person\" (hier \"%s\") und wird ignoriert." % tax_mode)
    if taxable_income is None and tariff is not None:
        _warn("simulation: tax_tariff wirkt nur zusammen mit taxable_income (zu versteuerndes Einkommen je Jahr) und "
              "wird ignoriert.")
    tariff_env = None
    if tariff_on:
        y0, y1 = year_of(int(dvals.min())), year_of(int(dvals.max()))
        zv = _check_taxable_income(taxable_income, list(range(y0, y1 + 1)))
        if tariff is None:
            tt = tax_tariff()
        elif isinstance(tariff, SimLevTaxTariff):
            tt = tariff
        elif isinstance(tariff, str):
            tt = tax_tariff(file=tariff)
        else:
            _stop("simulation: tax_tariff muss NULL (mitgelieferte Tarifdatei), ein Dateipfad oder ein Objekt aus "
                  "tax_tariff() sein.")
        tariff_env = _TariffEnv()
        tariff_env.tariff = tt
        tariff_env.zve_all = zv["all"]
        tariff_env.zve = zv["by_year"]
        tariff_env.church_k = church_tax / 100 if (church_tax is not None and church_tax > 0) else 0.0
        tariff_env.kapest_rate = 0.25 / (1 + 0.25 * tariff_env.church_k)
        tariff_env.use_gp = bool(use_guenstigerpruefung)
        ign = [a for a, g in (("marginal_tax_rate", given["marginal_tax_rate"] and marginal_tax_rate is not None),
                              ("include_soli_on_income_tax", given["include_soli_on_income_tax"]),
                              ("soli_rate_income_tax", given["soli_rate_income_tax"])) if g]
        if ign:
            _warn("simulation: Mit taxable_income gilt der Einkommensteuertarif der Tarifdatei (ESt und Soli); %s wirkt "
                  "dann nicht." % ", ".join(ign))

    def is_private(a):
        return (a.get("tax_regime") == "private_sale" or a.get("asset_class") == "etn_deliverable"
                or (a.get("asset_class") in ("etn", "etc") and _is_true(a.get("deliverable"))))
    has_private_sale = any(is_private(a) for a in strat.values())
    if has_private_sale and marginal_tax_rate is None and tax_mode == "person" and not tariff_on and blocks:
        _warn("simulation: Der Grenzsteuersatz ist nicht gesetzt (tax_profile(income = income_rate(marginal_rate))), die "
              "Strategie enth\u00e4lt aber Assets mit tax_regime = \"private_sale\"; Gewinne nach Paragraf 23 EStG werden "
              "dann m\u00f6glicherweise nicht korrekt besteuert. income_rate(marginal_rate) in Prozent angeben (z. B. 42).")
    elif has_private_sale and marginal_tax_rate is None and tax_mode == "person" and not tariff_on:
        _warn("simulation: marginal_tax_rate ist nicht gesetzt, die Strategie enth\u00e4lt aber Assets mit tax_regime = "
              "\"private_sale\"; Gewinne nach Paragraf 23 EStG werden dann m\u00f6glicherweise nicht korrekt besteuert. "
              "marginal_tax_rate in Prozent angeben (z. B. 42).")
    if not blocks and marginal_tax_rate is not None and (marginal_tax_rate < 0 or marginal_tax_rate > 50):
        _stop("simulation: marginal_tax_rate muss ein Grenzsteuersatz in Prozent zwischen 0 und 50 sein (z. B. 42 f\u00fcr "
              "42 %%), nicht %s." % r_deparse(marginal_tax_rate))
    if church_tax is not None and church_tax > 0:
        if given["tax_rate"] and abs(tax_rate - 26.375) > 1e-9:
            _warn("church_tax \u00fcberschreibt das angegebene tax_rate.")
        k = church_tax / 100
        tax_rate = 100 * 0.25 / (1 + 0.25 * k) * (1 + 0.055 + k)
    church_k = church_tax / 100 if (church_tax is not None and church_tax > 0) else 0.0
    tax_rate = tax_rate / 100
    if marginal_tax_rate is not None:
        marginal_tax_rate = float(marginal_tax_rate) / 100
    soli_rate_income_tax = float(soli_rate_income_tax) / 100
    if balance_thresh is not None:
        balance_thresh = float(balance_thresh) / 100
    balance_thresh_type = _match_arg(balance_thresh_type, ("absolute", "relative"), "balance_thresh_type")
    fee_order = _fee_spec(order_fee)
    fee_dca = fee_order if dca_fee is None else _fee_spec(dca_fee)
    fees_on = fee_order is not None or fee_dca is not None
    _FEE.current = None
    _FEE.paid = 0.0
    if _is_true(harvest_mode) and not blocks:
        if not isinstance(harvest_day, str) or not re.match(r"^\d{2}-\d{2}$", harvest_day) or harvest_day >= "12-31":
            _stop("harvest_day im Format 'MM-TT' und vor dem 31.12. angeben (z. B. '12-15').")
    if dca_mode:
        def one_num(x):
            return _is_num(x) and math.isfinite(float(x))
        if not blocks and (not one_num(dca_value) or dca_value <= 0):
            _stop("simulation: 'dca_value' muss bei dca_mode = TRUE eine einzelne endliche Zahl > 0 sein (Betrag je "
                  "Sparplan-Termin in EUR), nicht %s." % show_arg(dca_value))
        if not blocks and (not one_num(dca_span) or dca_span < 1 or dca_span != r_round(float(dca_span))):
            _stop("simulation: 'dca_span' muss bei dca_mode = TRUE eine einzelne ganze Zahl >= 1 sein (Perioden "
                  "zwischen zwei Terminen), nicht %s." % show_arg(dca_span))
        dca_value = float(dca_value)
    shares = [a.get("share") for a in strat.values()]
    total_weight = r_sum([NA if s is None else float(s) for s in shares], na_rm=True)
    if abs(total_weight - 1.0) > 1e-6:
        _stop(_sp("simulation: Asset-Gewichte (share) summieren sich auf %.4f, m\u00fcssen aber exakt 1.0 ergeben "
                  "(Anteile, z. B. 0.6 und 0.4).\n  Aktuelle Gewichte: %s", total_weight,
                  ", ".join(_sp("%s=%.3f", k, NA if v.get("share") is None else float(v.get("share")))
                            for k, v in strat.items())))
    effective_tax_rate = tax_rate
    if use_guenstigerpruefung and not tariff_on:
        if marginal_tax_rate is None and blocks:
            _warn("simulation: G\u00fcnstigerpr\u00fcfung aktiviert (tax_profile(guenstigerpruefung = TRUE)), aber der "
                  "Grenzsteuersatz (income_rate(marginal_rate)) ist nicht gesetzt.\nVerwendet wird die Abgeltungsteuer ("
                  + r_as_character(r_round(tax_rate * 100, 2)) + " %).\nF\u00fcr eine korrekte G\u00fcnstigerpr\u00fcfung "
                  "tax_profile(income = income_rate(marginal_rate)) in Prozent angeben (z. B. 42).")
        elif marginal_tax_rate is None:
            _warn("simulation: G\u00fcnstigerpr\u00fcfung aktiviert (use_guenstigerpruefung = TRUE), aber 'marginal_tax_rate' "
                  "ist nicht gesetzt.\nVerwendet wird die Abgeltungsteuer (" + r_as_character(r_round(tax_rate * 100, 2)) +
                  " %).\nF\u00fcr eine korrekte G\u00fcnstigerpr\u00fcfung marginal_tax_rate in Prozent angeben (z. B. 42).")
        else:
            personal_rate = marginal_tax_rate * (((1 + soli_rate_income_tax) if include_soli_on_income_tax else 1.0)
                                                 + church_k)
            if personal_rate < tax_rate:
                effective_tax_rate = personal_rate
                if details:
                    _cat(_sp("\u2550\u2550\u2550 G\u00fcnstigerpr\u00fcfung aktiv \u2550\u2550\u2550\n  Pers\u00f6nlicher Steuersatz: "
                             "%.2f%%\n  Effektiver Steuersatz: %.2f%% (statt %.2f%% Abgeltungsteuer)\n  Ersparnis: %.2f "
                             "Prozentpunkte\n\n", marginal_tax_rate * 100, effective_tax_rate * 100, tax_rate * 100,
                             (tax_rate - effective_tax_rate) * 100))
            else:
                if details:
                    _cat(_sp("\u2550\u2550\u2550 G\u00fcnstigerpr\u00fcfung gepr\u00fcft \u2550\u2550\u2550\n  Pers\u00f6nlicher "
                             "Steuersatz: %.2f%%\n  Abgeltungsteuer: %.2f%% \u2192 bleibt g\u00fcnstiger\n\n",
                             personal_rate * 100, tax_rate * 100))
    soli_factor_income = (1 + soli_rate_income_tax) if include_soli_on_income_tax else 1.0
    return {"data": fr, "strategy": strat, "tax_mode": tax_mode, "start_value": start_value,
            "tax_rate": tax_rate, "marginal_tax_rate": marginal_tax_rate, "effective_tax_rate": effective_tax_rate,
            "soli_factor_income": soli_factor_income, "church_k": church_k, "tariff_env": tariff_env,
            "private_sale_threshold": private_sale_threshold, "sparer_pauschbetrag": sparer_pauschbetrag,
            "use_sparer_pauschbetrag": use_sparer_pauschbetrag, "fractions": fractions,
            "fee_order": fee_order, "fee_dca": fee_dca, "fees_on": fees_on, "order_fee": order_fee,
            "dca_mode": dca_mode, "dca_value": dca_value, "dca_days": dca_days,
            "balance_mode": balance_mode, "balance_days": balance_days,
            "balance_thresh": balance_thresh, "balance_thresh_type": balance_thresh_type,
            "base_rate": base_rate, "risk_free": risk_free, "harvest_mode": harvest_mode,
            "split_mode": split_mode, "event_col": event_col, "pre_filled": pre_filled}


# ═══════════════════════════════════════════════════════════════════════════
# Phase 2: Datenvorbereitung, sim_mem, Termine (sim_prepare.R)
# ═══════════════════════════════════════════════════════════════════════════

def _locf_fill(v: np.ndarray) -> np.ndarray:
    isna = np.isnan(v)
    non_na = np.flatnonzero(~isna)
    if non_na.size == 0:
        return v
    idx = np.zeros(v.size, dtype=np.int64)
    idx[non_na] = non_na + 1
    idx = np.maximum.accumulate(idx)
    idx[idx == 0] = non_na[0] + 1
    return v[idx - 1]


def _sim_prepare_data(fr: _Frame, pre_filled: np.ndarray, base_rate_flex, base_rate_data, blocks=False) -> dict:
    dates = fr.get("date")
    start_date = int(dates[0])
    stopp_date = int(dates[-1])
    if _is_true(base_rate_flex) and isinstance(base_rate_data, str) and base_rate_data in fr:
        _frac_warn_col(fr, base_rate_data, "base_rate" if blocks else "base_rate_data", hi=0.05)
    if _is_true(base_rate_flex) and isinstance(base_rate_data, str) and base_rate_data in fr:
        col = fr.get(base_rate_data)
        k = fr.kinds[base_rate_data]
        if k == "numeric" and np.isnan(col).any():
            col = col.copy()
            col[np.isnan(col)] = 0.0
            fr.cols[base_rate_data] = col
        elif k != "numeric" and all(_isna(v) for v in col):
            fr.set(base_rate_data, np.zeros(len(col)), "numeric")
    expected_days = (stopp_date - start_date) + 1
    if fr.nrow != expected_days:
        _message("Hinweis: %d Zeilen, erwartet %d Kalendertage. Fehlende Tage werden aufgef\u00fcllt (LOCF; Signale = "
                 "FALSE)." % (fr.nrow, expected_days))
        all_dates = np.arange(start_date, stopp_date + 1, dtype=np.int64)
        pos = {int(z): i for i, z in enumerate(fr.get("date"))}
        src = np.array([pos.get(int(z), -1) for z in all_dates], dtype=np.int64)
        have = src >= 0
        n = all_dates.size
        new_cols, new_kinds = {"date": all_dates.astype(np.float64)}, {"date": "date"}
        names = ["date"] + [nm for nm in fr.names if nm != "date"]
        for nm in names[1:]:
            v = fr.cols[nm]
            k = fr.kinds[nm]
            if k in ("numeric", "date", "posixct"):
                out = np.full(n, NA)
                out[have] = v[src[have]]
                if k == "numeric":
                    out = _locf_fill(out)
            else:
                out = np.empty(n, dtype=object)
                out[:] = None
                out[have] = v[src[have]]
                if k == "logical":
                    out = np.array([False if x is None else x for x in out], dtype=object)
            new_cols[nm], new_kinds[nm] = out, k
        filled = np.ones(n, dtype=bool)
        filled[have] = np.asarray(pre_filled, dtype=bool)[src[have]]
        new_cols[".filled"], new_kinds[".filled"] = filled, "filled"
        names.append(".filled")
        fr.names, fr.cols, fr.kinds = names, new_cols, new_kinds
    elif np.any(pre_filled):
        fr.set(".filled", np.asarray(pre_filled, dtype=bool), "filled")
    return {"data": fr, "start_date": start_date, "stopp_date": stopp_date}


def _signal_col(fr: _Frame, col: str | None, n: int) -> np.ndarray:
    if col is None:
        return np.array([False] * n, dtype=object)
    v = fr.get(col)
    if fr.kinds[col] == "numeric":
        return np.array(v, dtype=np.float64)
    return np.array(v, dtype=object)


def _sim_build_state(fr: _Frame, strategy: dict, start_value: float, start_date: int, stopp_date: int,
                     sparer_pauschbetrag: float, use_sparer_pauschbetrag: bool, base_rate, base_rate_flex,
                     base_rate_data, blocks=False) -> dict:
    n = fr.nrow
    sim: dict = {
        "assets": {}, "status": {}, "market": {}, "trades": {}, "report": {},
        "totals": {
            "total_value": start_value, "total_taxes": 0.0, "loss_capital_gains": 0.0, "loss_private_sales": 0.0,
            "private_sale_gains_ytd": 0.0, "private_sale_losses_ytd": 0.0,
            "sparer_pauschbetrag_annual": sparer_pauschbetrag,
            "sparer_pauschbetrag_remaining": sparer_pauschbetrag if use_sparer_pauschbetrag else 0.0,
            "sparer_pauschbetrag_used_total": 0.0, "current_year": year_of(start_date),
            "cgt_base_taxed_ytd": 0.0, "cgt_loss_added_ytd": 0.0, "cgt_loss_used_ytd": 0.0,
            "cgt_pool_start_ytd": 0.0,
        },
    }
    for name, a in strategy.items():
        ac = a.get("asset_class")
        deliverable = _is_true(a.get("deliverable"))
        regime = a.get("tax_regime")
        if regime is None:
            regime = {"etf": "investment_fund", "etn": "private_sale" if deliverable else "capital_gains",
                      "etc": "private_sale" if deliverable else "capital_gains", "certificate": "capital_gains",
                      "etn_standard": "capital_gains", "etn_deliverable": "private_sale"}.get(ac, "capital_gains")
        st_raw = a.get("start")
        bonus = a.get("partial_exemption")
        sim["assets"][name] = {
            "class": ac, "style": a.get("trading"),
            "start": start_date if st_raw is None else _date_or_fail(st_raw),
            "tax_regime": regime, "bonus": (0.0 if bonus is None else float(bonus)) / 100,
            "deliverable": a.get("deliverable") if a.get("deliverable") is not None else False,
        }
        if a.get("trading") == "signal":
            sb, ss = a.get("signal_buy"), a.get("signal_sell")
            if sb is None or sb not in fr:
                _stop("simulation: signal_buy-Spalte '%s' fehlt im Datensatz (Asset '%s')." % (sb if sb is not None
                                                                                            else "NULL", name))
            if ss is None or ss not in fr:
                _stop("simulation: signal_sell-Spalte '%s' fehlt im Datensatz (Asset '%s')." % (ss if ss is not None
                                                                                             else "NULL", name))
        share = float(a.get("share"))
        sim["status"][name] = {"count": 0.0, "price": 0.0, "worth": 0.0, "money": share * start_value,
                               "total": share * start_value, "target": share, "actual": share, "differ": 0.0}
        if base_rate_flex:
            if base_rate_data is None or base_rate_data not in fr:
                if base_rate_data is None:
                    _stop("simulation: base_rate_flex = TRUE braucht base_rate_data (Name der Basiszins-Spalte in data, "
                          "Prozent p. a.); base_rate_data fehlt.")
                if blocks:
                    _stop("simulation: base_rate-Spalte '%s' fehlt in data (tax_profile(base_rate = \"%s\") braucht eine "
                          "Basiszins-Spalte in Prozent p. a.; vorhanden: %s)." % (base_rate_data, base_rate_data,
                                                                                  ", ".join(fr.names)))
                _stop("simulation: base_rate_data-Spalte '%s' fehlt in data (base_rate_flex = TRUE braucht eine "
                      "Basiszins-Spalte in Prozent p. a.; vorhanden: %s)." % (base_rate_data, ", ".join(fr.names)))
            br = np.array(fr.get(base_rate_data), dtype=np.float64)
            br[np.isnan(br)] = 0.0
        else:
            br = np.full(n, float(base_rate) if base_rate is not None else 0.0)
        spread_a = a.get("spread")
        sim["market"][name] = {
            "asset_day": np.arange(start_date, stopp_date + 1, dtype=np.int64),
            "base_rates": br,
            "asset_price": np.array(fr.get(name), dtype=np.float64),
            "signal_buy": _signal_col(fr, a.get("signal_buy"), n),
            "signal_sell": _signal_col(fr, a.get("signal_sell"), n),
            "spread_rate": (0.0 if spread_a is None else float(spread_a)) / 100,
        }
        sim["trades"][name] = {"buys": [], "buy_count": 0, "sells": [], "sell_count": 0, "taxes": [],
                               "tax_count": 0, "fees": [], "fee_count": 0, "fifo_front": 1}
        st = sim["status"][name]
        worth0, money0, total0 = np.zeros(n), np.zeros(n), np.zeros(n)
        worth0[0], money0[0], total0[0] = st["worth"], st["money"], st["total"]
        sim["report"][name] = {"worth": worth0, "money": money0, "flows": np.zeros(n), "total": total0,
                               "share": np.zeros(n)}
    return sim


def _as_logical_col(fr: _Frame, col: str) -> np.ndarray:
    v = fr.get(col)
    k = fr.kinds[col]
    out = np.zeros(len(v), dtype=bool)
    for i, x in enumerate(v):
        if _isna(x):
            continue
        if k == "numeric":
            out[i] = x != 0
        elif isinstance(x, str):
            out[i] = x in ("TRUE", "true", "T", "True")
        else:
            out[i] = bool(x)
    return out


def _sim_build_calendar(fr: _Frame, sim: dict, strategy: dict, start_date: int, stopp_date: int, liquidate,
                        dca_mode, dca_span, dca_unit, dca_days, dca_value, dca_anchor, dca_start, dca_skip,
                        balance_mode, balance_span, balance_unit, balance_days, balance_anchor, balance_start,
                        balance_skip, event_col, event_mode, event_weight, split_mode, split_thresh, blocks=False) -> dict:
    flag_date = np.arange(start_date, stopp_date + 1, dtype=np.int64)
    n = flag_date.size
    if ".filled" in fr:
        flag_filled = np.asarray(fr.get(".filled"), dtype=bool).copy()
    else:
        flag_filled = np.zeros(n, dtype=bool)
    fr.drop(".filled")
    flag_assets = list(strategy.keys())
    liquidate = bool(liquidate)
    flag_liquidate = liquidate & (flag_date == stopp_date)
    for a, sd0, mode in (("dca", dca_start, dca_mode), ("balance", balance_start, balance_mode)):
        if not _is_true(mode) or sd0 is None:
            continue
        sd1 = _as_date(sd0)
        if sd1 is None:
            _stop("simulation: %s_start = '%s' ist kein Datum (erwartet Date oder \"JJJJ-MM-TT\")."
                  % (a, r_format1(sd0) if not isinstance(sd0, str) else sd0))
        if sd1 > stopp_date:
            _stop("simulation: %s (%s) liegt nach dem letzten Datentag (%s); es g\u00e4be keine Termine."
                  % (("start von %s" % ("dca_plan()" if a == "dca" else "rebalance_plan()")) if blocks else a + "_start",
                     fmt_date(sd1), fmt_date(stopp_date)))
    flag_rebalance = _calculate_dates_flags(balance_mode, balance_span, balance_unit, balance_days, flag_date, None,
                                            balance_anchor, balance_start, balance_skip, liquidate)
    flag_dca = _calculate_dates_flags(dca_mode, dca_span, dca_unit, dca_days, flag_date, dca_value, dca_anchor,
                                      dca_start, dca_skip, liquidate)
    md = [from_days(int(z)) for z in flag_date]
    flag_taxes = np.array([x.month == 12 and x.day == 31 for x in md], dtype=bool)
    event_mode = _match_arg(event_mode, ("additional", "replace"), "event_mode")
    flag_event = np.zeros(n, dtype=bool)
    if event_col is not None:
        if event_col not in fr:
            _stop("simulation: event_col '%s' nicht im Datensatz gefunden." % event_col)
        flag_event = _as_logical_col(fr, event_col)
        if event_weight is not None:
            if not isinstance(event_weight, Mapping) or any(str(k) == "" for k in event_weight):
                _stop("simulation: event_weight muss benannt sein (Asset = Spaltenname), z. B. c(A = \"wA\", B = \"wB\").")
            event_weight = {str(k): v for k, v in event_weight.items()}
            unk = [k for k in event_weight if k not in strategy]
            if unk:
                _stop("simulation: event_weight nennt unbekannte Assets: %s." % ", ".join(unk))
            for nm, col in event_weight.items():
                if not isinstance(col, str) or col not in fr:
                    _stop("simulation: event_weight-Spalte '%s' (Asset '%s') fehlt in 'data'."
                          % (",".join(col) if isinstance(col, (list, tuple)) else str(col), nm))
                if not fr.is_numeric(col):
                    _stop("simulation: event_weight-Spalte '%s' muss nicht negative Zahlen enthalten." % col)
                wv = fr.get(col)[flag_event]
                if np.any(wv[~np.isnan(wv)] < 0):
                    _stop("simulation: event_weight-Spalte '%s' muss nicht negative Zahlen enthalten." % col)
            fehlt = [nm for nm in strategy if nm not in event_weight]
            if fehlt:
                _warn("simulation: event_weight nennt nicht alle Assets (es fehlt: %s); an Event-Tagen gelten dann die "
                      "Strategie-Gewichte." % ", ".join(fehlt))
        guard = (flag_date != flag_date[0]) & ((not liquidate) | (flag_date != stopp_date))
        flag_event = flag_event & guard
        if event_mode == "additional":
            flag_rebalance = flag_rebalance | flag_event
        else:
            flag_rebalance = flag_event.copy()
    flag_trade = ~flag_rebalance & (flag_date != stopp_date) & ~flag_filled
    flag_split = _calculate_split_flags(sim, 100.0, split_mode, flag_date, split_thresh)
    flag_dca_n = flag_dca.astype(np.float64)
    if flag_filled.any():
        mon = [_ym(int(z)) for z in flag_date]
        flag_rebalance = _shift_off_filled(flag_rebalance, flag_filled, mon)
        flag_dca_n = _shift_off_filled(flag_dca_n, flag_filled, mon)
        flag_dca = flag_dca_n > 0
        flag_split = _shift_off_filled(flag_split, flag_filled, mon)
        flag_liquidate = _shift_off_filled(flag_liquidate, flag_filled, mon)
        if flag_liquidate.any():
            flag_rebalance = flag_rebalance & ~flag_liquidate
            flag_dca_n = np.where(flag_liquidate, 0.0, flag_dca_n)
            flag_dca = flag_dca_n > 0
        flag_trade = ~flag_rebalance & (flag_date != stopp_date) & ~flag_filled
    for name in flag_assets:
        st_a = sim["assets"][name]["start"]
        if st_a is not None and st_a > stopp_date:
            _stop("simulation: start von '%s' (%s) liegt nach dem letzten Datentag (%s); das Asset w\u00e4re nie "
                  "handelbar. start auf ein Datum im Datenzeitraum setzen oder das Asset aus der Strategie "
                  "entfernen." % (name, fmt_date(st_a), fmt_date(stopp_date)))
    return {"data": fr,
            "flags": {"flag_date": flag_date, "flag_filled": flag_filled, "flag_assets": flag_assets,
                      "flag_liquidate": flag_liquidate, "flag_rebalance": flag_rebalance, "flag_dca": flag_dca,
                      "flag_dca_n": flag_dca_n, "flag_taxes": flag_taxes, "flag_event": flag_event,
                      "flag_trade": flag_trade, "flag_split": flag_split},
            "event_weight": event_weight if event_col is not None else None}


def _sim_init_weights(sim: dict, flag_assets: list, flag_date: np.ndarray, start_value: float) -> dict:
    initial_assets = [nm for nm in flag_assets if sim["assets"][nm]["start"] <= int(flag_date[0])]
    if not initial_assets:
        _stop("simulation: Kein Asset ist am ersten Datentag (%s) handelbar (start bzw. erste Kurse sp\u00e4ter); "
              "mindestens ein Asset muss ab Beginn handelbar sein." % fmt_date(int(flag_date[0])))
    initial_weights_sum = r_sum([sim["status"][nm]["actual"] for nm in initial_assets])
    all_weights_sum = r_sum([sim["status"][nm]["actual"] for nm in flag_assets])
    for nm in flag_assets:
        st = sim["status"][nm]
        target_weight = st["actual"] / all_weights_sum
        if nm in initial_assets:
            normalized_weight = st["actual"] / initial_weights_sum
            st["actual"] = target_weight
            st["money"] = start_value * normalized_weight
            st["total"] = start_value * normalized_weight
        else:
            st["actual"] = target_weight
            st["differ"] = 0.0
            st["money"] = 0.0
            st["total"] = 0.0
    return {"sim": sim, "initial_assets": initial_assets}


def _sim_build_schedule(sim: dict, fl: dict, stopp_date: int, tax_mode: str, harvest_mode, harvest_day) -> dict:
    flag_date, flag_filled, flag_assets = fl["flag_date"], fl["flag_filled"], fl["flag_assets"]
    n = flag_date.size
    asset_starts = [int(sim["assets"][nm]["start"]) for nm in flag_assets]
    if flag_filled.any():
        mon = [_ym(int(z)) for z in flag_date]
        pos = {int(z): i for i, z in enumerate(flag_date)}
        shifted = []
        for dz in asset_starts:
            i = pos.get(dz)
            if i is None or not flag_filled[i]:
                shifted.append(dz)
                continue
            j = i + 1
            while j < n and flag_filled[j]:
                j += 1
            if j >= n or mon[j] != mon[i]:
                j = i - 1
                while j >= 0 and flag_filled[j]:
                    j -= 1
            shifted.append(int(flag_date[max(min(j, n - 1), 0)]))
        asset_starts = shifted
    start_set = set(asset_starts)
    flag_active = np.array([int(z) in start_set for z in flag_date], dtype=bool)
    pos_all = {int(z): i + 1 for i, z in enumerate(flag_date)}
    asset_start_indices = [pos_all.get(z, 1) for z in asset_starts]
    flag_harvest = np.zeros(n, dtype=bool)
    if _is_true(harvest_mode) and tax_mode == "person":
        mds = [from_days(int(z)) for z in flag_date]
        md_s = ["%02d-%02d" % (d.month, d.day) for d in mds]
        yrs = [d.year for d in mds]
        seen_years = []
        for y in yrs:
            if y not in seen_years:
                seen_years.append(y)
        for y in seen_years:
            js = [i for i in range(n) if yrs[i] == y and md_s[i] >= harvest_day and md_s[i] < "12-31"
                  and not flag_filled[i]]
            if js:
                flag_harvest[js[0]] = True
    flag_fund_fee = (tax_mode == "funds") & (fl["flag_taxes"] | (flag_date == stopp_date))
    flag_liquidate = fl["flag_liquidate"]
    if tax_mode == "funds" and flag_liquidate.any() and not flag_liquidate[n - 1]:
        liq_i = int(np.flatnonzero(flag_liquidate).max())
        flag_fund_fee = flag_fund_fee.copy()
        flag_fund_fee[liq_i + 1:] = False
        flag_fund_fee[liq_i] = True
    flag_definite = flag_active | fl["flag_split"] | fl["flag_dca"] | fl["flag_rebalance"] | fl["flag_taxes"] | \
        flag_liquidate | flag_harvest | flag_fund_fee
    strategy_types = {nm: sim["assets"][nm]["style"] for nm in flag_assets}
    has_bnh = any(t == "bnh" for t in strategy_types.values())
    has_signal = any(t == "signal" for t in strategy_types.values())
    tax_regimes = {nm: sim["assets"][nm]["tax_regime"] for nm in flag_assets}
    spread_rates = {nm: sim["market"][nm]["spread_rate"] for nm in flag_assets}
    flag_signal = np.zeros(n, dtype=bool)
    if has_signal:
        for nm in flag_assets:
            if sim["assets"][nm]["style"] == "signal":
                b = np.array([_truthy(x) for x in sim["market"][nm]["signal_buy"]], dtype=bool)
                s = np.array([_truthy(x) for x in sim["market"][nm]["signal_sell"]], dtype=bool)
                flag_signal = flag_signal | b | s
    flag_bnh_potential = np.zeros(n, dtype=bool)
    if has_bnh:
        flag_bnh_potential[0] = True
    flag_slow_path = flag_definite | flag_signal | flag_bnh_potential
    flag_year_change = np.zeros(n, dtype=bool)
    flag_vp_settle = np.zeros(n, dtype=bool)
    if tax_mode == "person":
        years = np.array([year_of(int(z)) for z in flag_date], dtype=np.int64)
        if n > 1:
            flag_year_change[1:] = np.diff(years) > 0
        for ys in np.flatnonzero(flag_year_change):
            j = ys
            while j < n and flag_filled[j] and years[j] == years[ys]:
                j += 1
            if j >= n or years[j] != years[ys]:
                j = ys
            flag_vp_settle[j] = True
    flag_slow_path = flag_slow_path | flag_vp_settle
    flag_individual = flag_slow_path | flag_year_change
    out = dict(fl)
    out.update({"asset_starts": asset_starts, "flag_active": flag_active, "asset_start_indices": asset_start_indices,
                "flag_harvest": flag_harvest, "flag_fund_fee": flag_fund_fee, "strategy_types": strategy_types,
                "tax_regimes": tax_regimes, "spread_rates": spread_rates, "flag_slow_path": flag_slow_path,
                "flag_year_change": flag_year_change, "flag_vp_settle": flag_vp_settle,
                "individual_days": [int(i) + 1 for i in np.flatnonzero(flag_individual)], "n_total_days": n})
    return out


# ═══════════════════════════════════════════════════════════════════════════
