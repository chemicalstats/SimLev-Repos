"""Phasen 1 und 2 von ``simulation()``: Eingabeprüfung, Datenvorbereitung, ``sim_mem``, Termine und Plan
(nachgebildet aus ``r/R/sim_validate.R`` und ``r/R/sim_prepare.R``; Julia: ``sim_phases.jl``).
"""
from __future__ import annotations

import math
from typing import Mapping

import numpy as np
import pandas as pd

from . import _ext
from ._dates import fmt_date, year_of
from ._r.rformat import r_as_character, r_format1, r_round
from ._r.rnum import r_median, r_sum
from .config import _match_arg
from ._tax_tariff import SimLevTaxTariff, tax_tariff
from .config import AssetConfig, _asset_list_fields, _is_wrapper, _strategy_columns, _strategy_wrappers
from ._sim_blocks import SimLevSplitRule
from ._pruefen import (_finite_num, _to_float, chk_bool1, chk_col_nona, chk_col_signal, chk_col_type, chk_msg, chk_name1,
                       chk_num1, chk_range_text, chk_scalar, chk_stop)
from .wrapper import _nav_raw, _wrapper_nav_calc
from ._r.rnum import NA_REAL as NA  # R's NA_real_ (Nutzlast 1954)
from ._sim_base import (
    _FEE,
    _memo_arr,
    _memo_set,
    _memo_slice,
    _Frame,
    _TariffEnv,
    _as_date,
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
    _r_strptime_ymd,
    _sched_spec,
    _sp,
    _stop,
    _to_frame,
    _warn,
)


# ═══════════════════════════════════════════════════════════════════════════
# Phase 1: Eingabeprüfung (sim_validate.R)
# ═══════════════════════════════════════════════════════════════════════════

def _sim_check_asset_fields(a: dict, nm: str) -> None:
    """Felder eines Assets der Strategie prüfen (seit 1.6.4; R ``.sim_check_asset_fields``): Listen-Assets gehen
    durch dieselben Regeln wie ``asset_config()`` (FW1-1). Meldungen mit ``"simulation: Asset '<name>'"``."""
    from .config import _is_date_like, _to_date
    w = "simulation: Asset '%s'" % nm
    if a.get("share") is None:
        chk_stop("fehlt", w, "share")
    s = chk_scalar(a.get("share"))   # bei 1 < share <= 100 wertfreier Hinweis (Entscheidung 12; seit 1.6.4, K43 KE)
    if _finite_num(s) and 1 < _to_float(s) <= 100:
        chk_stop("ke.zahl_bereich_prozent", w, "share", chk_range_text(0, 1, lo_open=True))
    chk_num1(a.get("share"), w, "share", lo=0, hi=1, lo_open=True)
    chk_num1(a.get("spread"), w, "spread", lo=0, null_ok=True)
    chk_num1(a.get("partial_exemption"), w, "partial_exemption", lo=0, hi=100, null_ok=True)
    if a.get("deliverable") is not None:   # Feld fehlt: Standard FALSE
        chk_bool1(a.get("deliverable"), w, "deliverable")
    st = a.get("start")
    if st is not None and (not _is_date_like(st) or _to_date(st) is None):
        chk_stop("datum", w, "start")
    chk_name1(a.get("signal_buy"), w, "signal_buy", null_ok=True)
    chk_name1(a.get("signal_sell"), w, "signal_sell", null_ok=True)


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


def _tax_rates(rate, church_tax, guenstigerpruefung, marginal_rate, include_soli, soli_rate, who, *, details=False,
               tariff_on=False):
    """Steuersätze aus Abgeltungsteuer, Kirchensteuer und Günstigerprüfung (R: ``.tax_rates``).

    Gemeinsamer Helfer von ``simulation()`` (``_sim_check_inputs``) und ``withdrawal_simulation()``: Satz der
    Abgeltungsteuer mit Kirchensteuer (§ 32d Abs. 1 EStG), Prozentangaben als Anteile und effektiver Satz der
    Günstigerprüfung (einmal je Lauf mit dem Grenzsteuersatz aus ``income_rate()``). Rechenfolge, Warnungen und
    Druck wie in R; Meldungen beginnen mit ``who``. Ergebnis: dict ``tax_rate``, ``marginal_tax_rate``,
    ``soli_rate_income_tax`` (Anteile), ``effective_tax_rate``, ``church_k``, ``soli_factor_income``.
    """
    tax_rate = float(rate)
    marginal_tax_rate = marginal_rate
    soli_rate_income_tax = soli_rate
    use_guenstigerpruefung = bool(guenstigerpruefung)
    include_soli_on_income_tax = bool(include_soli)
    if church_tax is not None:
        church_tax = float(church_tax)
    if church_tax is not None and church_tax > 0:
        k = church_tax / 100
        tax_rate = 100 * 0.25 / (1 + 0.25 * k) * (1 + 0.055 + k)
    church_k = church_tax / 100 if (church_tax is not None and church_tax > 0) else 0.0
    tax_rate = tax_rate / 100
    if marginal_tax_rate is not None:
        marginal_tax_rate = float(marginal_tax_rate) / 100
    soli_rate_income_tax = float(soli_rate_income_tax) / 100
    effective_tax_rate = tax_rate
    if use_guenstigerpruefung and not tariff_on:
        if marginal_tax_rate is None:
            _warn(who + ": G\u00fcnstigerpr\u00fcfung aktiviert (tax_profile(guenstigerpruefung = TRUE)), aber der "
                  "Grenzsteuersatz (income_rate(marginal_rate)) ist nicht gesetzt.\nVerwendet wird die Abgeltungsteuer ("
                  + r_as_character(r_round(tax_rate * 100, 2)) + " %).\nF\u00fcr eine korrekte G\u00fcnstigerpr\u00fcfung "
                  "tax_profile(income = income_rate(marginal_rate)) in Prozent angeben (z. B. 42).")
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
    return {"tax_rate": tax_rate, "marginal_tax_rate": marginal_tax_rate, "soli_rate_income_tax": soli_rate_income_tax,
            "effective_tax_rate": effective_tax_rate, "church_k": church_k, "soli_factor_income": soli_factor_income}


def _sim_check_inputs(data, strategy, start_value, details, dca_mode, dca_value, dca_days,
                      balance_mode, balance_days, balance_thresh, balance_thresh_type, tax_mode, tax_rate,
                      marginal_tax_rate, use_guenstigerpruefung, private_sale_threshold, sparer_pauschbetrag,
                      use_sparer_pauschbetrag, include_soli_on_income_tax, soli_rate_income_tax, base_rate,
                      fractions, risk_free, split_mode, split_thresh, event_col, church_tax,
                      order_fee, dca_fee, harvest_mode, taxable_income, tariff, liquidate=False) -> dict:
    """Phase 1 (``.sim_check_inputs``). ``tariff`` = Argument ``tax_tariff`` von ``_simulation_flat``; Werte aus
    den Bausteinen von ``simulation()`` (deren Prüfungen entfallen hier, Meldungen nennen die Bausteine; der
    flache Weg ohne Bausteine mit eigenen Prüfungen ist entfallen)."""
    tax_mode = _match_arg(tax_mode, ("none", "person"), "tax_mode")
    # seit 1.6.4 nur pandas.DataFrame wie R data.frame (Entscheidung 6; bis 1.6.3 auch dict von Spalten), Meldung
    # ohne Klasse und mit der Umwandlung; der interne Rahmen _Frame (Aufrufe innerhalb von SimLev) gilt als Tabelle
    if not isinstance(data, (pd.DataFrame, _Frame)):
        _stop("simulation: data muss eine Tabelle mit Spalte 'date' und je Asset einer Kursspalte sein (%s)."
              % chk_msg("tabelle.formen"))
    if strategy is None or len(strategy) == 0:
        _stop("simulation: strategy muss eine nicht leere, benannte Liste von Asset-Konfigurationen sein (z. B. aus "
              "create_strategy()).")
    if not isinstance(strategy, Mapping) or any(k is None or str(k) == "" for k in strategy.keys()):   # 1.6.4: None
        _stop("simulation: Alle Assets in 'strategy' m\u00fcssen benannt sein (Name = Kursspalte in 'data').")
    fr = _to_frame(data)   # meldet doppelte Spaltennamen
    # seit 1.6.4: .filled ist der interne Name der aufgefüllten Tage (bis 1.6.3 schaltete eine solche Spalte den
    # Handel still ab)
    if ".filled" in fr.names:
        chk_stop("spalte_intern", "simulation", ".filled")
    filled_attr = fr.filled_attr
    strat: dict = {}
    for k, a in strategy.items():
        nm = str(k)
        if not isinstance(a, Mapping):
            _stop("simulation: Asset '%s' in 'strategy' muss eine Liste bzw. asset_config() sein." % nm)
        if not isinstance(a, AssetConfig):   # seit 1.6.4 (K43 T1-N1, Entscheidung 11)
            _asset_list_fields(a, nm, "simulation")
        strat[nm] = {k: chk_scalar(v) for k, v in a.items()}   # seit 1.6.4 Länge 1 wie Einzelwert (Entscheidung 4)
    cls_ok = ["etf", "etn", "etc", "certificate", "etn_standard", "etn_deliverable"]
    for nm, a in strat.items():
        ac = a.get("asset_class")
        if not isinstance(ac, str) or ac not in cls_ok:
            _stop("simulation: asset_class von Asset '%s' ist ung\u00fcltig; erlaubt sind %s (veraltet: etn_standard, "
                  "etn_deliverable). Strategie am besten mit create_strategy()/asset_config() bauen."
                  % (nm, ", ".join(cls_ok[:4])))
        tr_ = a.get("tax_regime")
        if tr_ is not None and (not isinstance(tr_, str) or tr_ not in ("investment_fund", "capital_gains",
                                                                           "private_sale")):
            _stop("simulation: tax_regime von Asset '%s' ist ung\u00fcltig; erlaubt sind investment_fund, capital_gains, "
                  "private_sale (oder weglassen: aus asset_class abgeleitet). Ohne Steuern %s verwenden."
                  % (nm, "tax = NULL"))
        at = a.get("trading")
        if not isinstance(at, str) or at not in ("bnh", "signal"):
            _stop("simulation: trading von Asset '%s' ist ung\u00fcltig; erlaubt sind \"bnh\" und \"signal\"." % nm)
        if a.get("wrapper") is not None:   # Fonds-Wrapper (wrapper.py)
            if not _is_wrapper(a["wrapper"]):
                _stop("simulation: wrapper von Asset '%s' muss ein Objekt aus wrapper_config() sein." % nm)
            if at != "bnh":
                _stop("simulation: Asset '%s' ist ein Fonds-Wrapper; daf\u00fcr ist nur trading = \"bnh\" m\u00f6glich "
                      "(keine Signale auf den Anteilswert)." % nm)
        _sim_check_asset_fields(a, nm)
    if "date" not in fr:
        _stop("simulation: Spalte 'date' fehlt in 'data'.")
    # Fonds-Wrapper: Asset-Name ist keine Kursspalte; gebraucht werden die inneren Spalten (_strategy_columns)
    wraps = _strategy_wrappers(strat)
    coll = [w for w in wraps if w in fr.names]
    if coll:
        _stop("simulation: Asset '%s' ist ein Fonds-Wrapper (asset_config(wrapper = )); 'data' darf keine Spalte "
              "gleichen Namens enthalten (der Anteilswert wird aus den inneren Spalten gerechnet). Spalte umbenennen "
              "oder entfernen." % coll[0])
    miss = [nm for nm in _strategy_columns(strat) if nm not in fr]
    if miss:
        _stop("simulation: %s %s in 'data'; je Asset der Strategie wird eine Spalte gleichen Namens erwartet "
              "(vorhanden: %s)." % ("Kursspalte" if len(miss) == 1 else "Kursspalten",
                                    ", ".join("'%s'" % m for m in miss) + " " + ("fehlt" if len(miss) == 1 else "fehlen"),
                                    ", ".join(nm for nm in fr.names if nm != "date")))
    if fr.nrow < 1:
        _stop("simulation: 'data' enth\u00e4lt keine Zeilen.")
    kind = fr.kinds["date"]
    if kind == "factor":   # seit 1.6.4 kein Faktor als Datumsspalte (Entscheidung 15; bis 1.6.3 still Text)
        chk_stop("spalte_faktor", "simulation", "date")
    if kind == "character":
        raw = fr.get("date")
        dd = np.array([NA if v is None else (NA if (z := _r_strptime_ymd(v)) is None else float(z)) for v in raw],
                      dtype=np.float64)
        bad = [i for i in range(len(raw)) if math.isnan(dd[i]) and raw[i] is not None]
        if bad:
            _stop("simulation: Spalte 'date' ist Text und Zeile %d ist kein Datum im Format JJJJ-MM-TT; vorher "
                  "mit as.Date(..., format = ...) umwandeln." % (bad[0] + 1))
        fr.set("date", dd, "date")
        _message("Hinweis: Spalte 'date' wurde von Text in Date umgewandelt.")
    elif kind == "posixct":
        fr.kinds["date"] = "date"
        _message("Hinweis: Spalte 'date' wurde von Datum-Uhrzeit in Date umgewandelt.")
    if fr.kinds["date"] != "date":
        _stop("simulation: Spalte 'date' muss die Klasse Date haben.")
    dvals = fr.get("date")
    if np.isnan(dvals).any():
        _stop("simulation: Spalte 'date' enth\u00e4lt NA (erstmals in Zeile %d)." % (int(np.flatnonzero(np.isnan(dvals))[0]) + 1))
    fa_m, fa_cols, fa_n = _filled_matrix(filled_attr)
    resorted = False
    if np.any(np.diff(dvals) < 0):
        o = np.argsort(dvals, kind="stable")
        fr.take(o)
        resorted = True
        if fa_m is not None and fa_m.shape[0] == len(o):
            fa_m = fa_m[o, :]
        _message("Hinweis: 'data' war nicht aufsteigend nach Datum sortiert und wurde sortiert.")
    dvals = fr.get("date")
    dup_first = None
    n_dup = 0
    dates_ok = (_memo_arr("dates", dvals) is not None      # Studie: einmal je Datumsspalte ohne Meldung (seit 1.5.1),
                or _memo_slice("dates_full", dvals) is not None)   # Fenster eindeutiger Tage sind eindeutig
    if not dates_ok and len(dvals) > 1:
        # dvals ist hier aufsteigend und ohne NA: Dubletten stehen nebeneinander (seit 1.5.2 ohne Schleife)
        same = np.flatnonzero(np.diff(dvals) == 0)
        n_dup = int(same.size)
        if n_dup:
            dup_first = dvals[same[0] + 1]
    if dup_first is None and not dates_ok:
        _memo_set("dates", dvals, True)
    if dup_first is not None:
        _stop("simulation: Datum %s kommt in 'data' mehrfach vor (%d doppelte Zeilen); je Tag genau eine Zeile."
              % (fmt_date(int(dup_first)), n_dup))
    # Fonds-Wrapper: Anteilswert je Wrapper-Asset aus den inneren Spalten (wrapper.py) als Kursspalte mit dem
    # Asset-Namen anhängen (NA vor dem Beginn und an Tagen ohne inneren Kurs); danach ist das Asset ein
    # gewöhnliches Asset ohne wrapper. splits gelten für die inneren Spalten, nicht für den Anteilswert.
    wrapper_navs = None
    if wraps:
        d_in = fr.copy()
        if fa_m is not None and fa_m.shape[0] == fr.nrow:
            d_in.filled_attr = pd.DataFrame(fa_m, columns=fa_cols) if fa_cols is not None else fa_m
        elif resorted:
            d_in.filled_attr = None
        sp = None
        if _is_true(split_mode) and split_thresh is not None:
            sp = SimLevSplitRule()
            sp["thresh"] = _num_vec(split_thresh)
        wrapper_navs = {nm: _wrapper_nav_calc(d_in, strat[nm]["wrapper"], sp, tag="Wrapper '%s'" % nm,
                                              who="simulation: Wrapper '%s'" % nm) for nm in wraps}
        dkey = {int(z): i for i, z in enumerate(fr.get("date"))}
        for nm in wraps:
            v = np.full(fr.nrow, NA)
            ndays, nnav = _nav_raw(wrapper_navs[nm])
            v[np.array([dkey[int(z)] for z in ndays], dtype=np.int64)] = nnav
            fr.set(nm, v, "numeric")
            del strat[nm]["wrapper"]
    nrow = fr.nrow
    if filled_attr is not None and fa_n != nrow:
        _warn("simulation: Attribut 'filled' von 'data' hat %d Zeilen, 'data' aber %d (z. B. nach Zeilenauswahl einer "
              "series_align()-Ausgabe); es wird ignoriert, aufgef\u00fcllte Tage gelten dann als Handelstage. Zeitraum "
              "besser mit series_align(..., start =, end =) w\u00e4hlen." % (fa_n, nrow))
        fa_m = None
    isna_of = {}   # NA-Maske je Asset (seit 1.6.3 einmal je Asset; nrow >= 1, also stets bool)
    for nm in strat:
        col = fr.get(nm)
        isna_of[nm] = np.isnan(col) if fr.is_numeric(nm) else np.array([_isna(v) for v in col], dtype=bool)
    pre_filled = np.zeros(nrow, dtype=bool)
    if fa_m is not None and fa_m.shape[0] == nrow and fa_cols is not None:
        fc = [nm for nm in strat if nm in fa_cols]
        if fc:
            real = np.zeros(nrow, dtype=np.int64)
            for nm in fc:
                real += (~fa_m[:, fa_cols.index(nm)] & ~isna_of[nm]).astype(np.int64)
            pre_filled = real == 0
    all_na = np.ones(nrow, dtype=bool)
    for nm in strat:
        all_na &= isna_of[nm]
    if all_na[0]:
        _stop("simulation: In der ersten Zeile von 'data' fehlen alle Kurse (NA); mindestens ein Asset muss am ersten "
              "Tag notieren. Daten erst ab dem ersten Kurs \u00fcbergeben.")
    pre_filled = pre_filled | all_na
    for nm in strat:
        if not fr.is_numeric(nm):
            _stop("simulation: Kursspalte '%s' muss numerisch sein." % nm)
        v = fr.get(nm)
        bad = np.flatnonzero(~np.isnan(v) & ~(np.isfinite(v) & (v > 0)))
        if bad.size:
            _stop("simulation: Kursspalte '%s' enth\u00e4lt ung\u00fcltige Kurse (<= 0 oder unendlich), erstmals am %s; "
                  "erwartet werden positive Kursniveaus." % (nm, fmt_date(int(dvals[bad[0]]))))
        # seit 1.6.4 (A-005, Entscheidung 103): Kurse von 1e-100 bis 1e100 (sonst läuft die Stückzahl Geld / Kurs über)
        bad = np.flatnonzero(~np.isnan(v) & ((v < 1e-100) | (v > 1e100)))
        if bad.size:
            from ._pruefen import chk_stop
            chk_stop("fa.kurs_bereich", "simulation", nm, fmt_date(int(dvals[bad[0]])))
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
        _stop("simulation: start_value muss eine positive Zahl sein (Anfangskapital in EUR, z. B. 10000).")
    if start_value == float("inf"):   # seit 1.6.4 endlich (bis 1.6.3 still ein Depot von 0)
        chk_stop("zahl", "simulation", "start_value")
    start_value = float(start_value)
    # Steuer-, Kosten-, Termin- und Split-Angaben haben die Bausteine geprüft (die Prüfungen des flachen
    # Wegs sind entfallen); fractions und risk_free prüft simulation() selbst
    tax_rate = float(tax_rate)
    if church_tax is not None:
        church_tax = float(church_tax)

    # seit 1.6.4 liquidate und details wie fractions (bis 1.6.3 nach bool(): Text "FALSE" galt als wahr)
    for lg, v in (("fractions", fractions), ("liquidate", liquidate), ("details", details)):
        if not _is_bool(v):
            _stop("simulation: '%s' muss TRUE oder FALSE sein." % lg)
    # seit 1.6.4 risk_free: None, eine endliche Zahl oder ein Spaltenname mit Zahlen
    if risk_free is not None:
        if not ((_is_num(risk_free) and math.isfinite(float(risk_free))) or (isinstance(risk_free, str) and risk_free != "")):
            chk_stop("zahl_oder_spalte", "simulation", "risk_free")
        if isinstance(risk_free, str) and risk_free in fr:   # nur Zahlen (Entscheidung 2; bis 1.6.3 Text/logisch umgewandelt)
            chk_col_type(fr, risk_free, "simulation", "numerisch")
    sparer_pauschbetrag = float(sparer_pauschbetrag)
    private_sale_threshold = float(private_sale_threshold)
    use_guenstigerpruefung = bool(use_guenstigerpruefung)
    include_soli_on_income_tax = bool(include_soli_on_income_tax)
    fractions = bool(fractions)
    use_sparer_pauschbetrag = bool(use_sparer_pauschbetrag)

    if _is_num(risk_free) and math.isfinite(float(risk_free)) and 0 < risk_free < 0.05:
        _warn("simulation: %s = %s wird als %s %% gelesen (Prozent-Konvention); gemeint war vermutlich %s."
              % ("risk_free", r_format1(risk_free), r_format1(risk_free), r_format1(risk_free * 100)))
    if isinstance(risk_free, str) and risk_free in fr:
        _frac_warn_col(fr, risk_free, "risk_free", hi=0.05)

    # taxable_income und tax_tariff nur aus income_tariff() in tax_profile(), also nur mit tax_mode = "person"
    tariff_on = taxable_income is not None and tax_mode == "person"
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
        tariff_env.use_gp = bool(use_guenstigerpruefung)

    def is_private(a):
        return (a.get("tax_regime") == "private_sale" or a.get("asset_class") == "etn_deliverable"
                or (a.get("asset_class") in ("etn", "etc") and _is_true(a.get("deliverable"))))
    has_private_sale = any(is_private(a) for a in strat.values())
    if has_private_sale and marginal_tax_rate is None and tax_mode == "person" and not tariff_on:
        _warn("simulation: Der Grenzsteuersatz ist nicht gesetzt (tax_profile(income = income_rate(marginal_rate))), die "
              "Strategie enth\u00e4lt aber Assets mit tax_regime = \"private_sale\"; Gewinne nach Paragraf 23 EStG werden "
              "dann m\u00f6glicherweise nicht korrekt besteuert. income_rate(marginal_rate) in Prozent angeben (z. B. 42).")
    # Kirchensteuer, Prozent-Konvention und Günstigerprüfung: _tax_rates() (unten, nach der Gewichtssumme)
    if balance_thresh is not None:
        balance_thresh = float(balance_thresh) / 100
    balance_thresh_type = _match_arg(balance_thresh_type, ("absolute", "relative"), "balance_thresh_type")
    fee_order = _fee_spec(order_fee, "simulation", "order_fee")
    fee_dca = fee_order if dca_fee is None else _fee_spec(dca_fee, "simulation", "dca_fee")
    fees_on = fee_order is not None or fee_dca is not None
    _FEE.paid = 0.0
    if dca_mode:
        dca_value = float(dca_value)
    shares = [a.get("share") for a in strat.values()]
    total_weight = r_sum([NA if s is None else float(s) for s in shares], na_rm=True)
    if abs(total_weight - 1.0) > 1e-6:
        # seit 1.6.4 ohne die Eingabewerte (bis 1.6.3 "Aktuelle Gewichte: A=0.300, ..."); die Summe bleibt
        _stop(_sp("simulation: Asset-Gewichte (share) summieren sich auf %.4f, m\u00fcssen aber exakt 1.0 ergeben "
                  "(Anteile, z. B. 0.6 und 0.4).", total_weight))
    # Steuersätze (Kirchensteuer, Prozent -> Anteil, Günstigerprüfung) im gemeinsamen Helfer (seit 1.1.0 auch für
    # withdrawal_simulation()); Rechenfolge, Warnungen und Druck wie bisher an dieser Stelle
    tr = _tax_rates(tax_rate, church_tax, use_guenstigerpruefung, marginal_tax_rate, include_soli_on_income_tax,
                    soli_rate_income_tax, "simulation", details=details, tariff_on=tariff_on)
    marginal_tax_rate = tr["marginal_tax_rate"]
    effective_tax_rate = tr["effective_tax_rate"]
    soli_factor_income = tr["soli_factor_income"]
    church_k = tr["church_k"]
    return {"data": fr, "strategy": strat, "tax_mode": tax_mode, "start_value": start_value,
            "marginal_tax_rate": marginal_tax_rate, "effective_tax_rate": effective_tax_rate,
            "soli_factor_income": soli_factor_income, "church_k": church_k, "tariff_env": tariff_env,
            "private_sale_threshold": private_sale_threshold, "sparer_pauschbetrag": sparer_pauschbetrag,
            "use_sparer_pauschbetrag": use_sparer_pauschbetrag, "fractions": fractions,
            "fee_order": fee_order, "fee_dca": fee_dca, "fees_on": fees_on, "order_fee": order_fee,
            "dca_mode": dca_mode, "dca_value": dca_value, "dca_days": dca_days,
            "balance_mode": balance_mode, "balance_days": balance_days,
            "balance_thresh": balance_thresh, "balance_thresh_type": balance_thresh_type,
            "base_rate": base_rate, "risk_free": risk_free, "harvest_mode": harvest_mode,
            "split_mode": split_mode, "event_col": event_col, "pre_filled": pre_filled,
            "no_split": list(wraps), "wrappers": wrapper_navs if _is_true(details) else None}


# ═══════════════════════════════════════════════════════════════════════════
# Phase 2: Datenvorbereitung, sim_mem, Termine (sim_prepare.R)
# ═══════════════════════════════════════════════════════════════════════════

def _sim_prepare_data(fr: _Frame, pre_filled: np.ndarray, base_rate_flex, base_rate_data) -> dict:
    dates = fr.get("date")
    start_date = int(dates[0])
    stopp_date = int(dates[-1])
    # Basiszins-Spalte (seit 1.6.4): keine Kategorie (Entscheidung 15), nur Zahlen (wie risk_free, Entscheidungen 2 und
    # F5: Text ist ein Fehler; nur NA zählt als Zahlenspalte, Entscheidung 14) und kein NA (Entscheidung 17; bis 1.6.3
    # zählte NA als 0), auch nicht in einer Spalte nur aus NA (Entscheidung 42)
    if _is_true(base_rate_flex) and isinstance(base_rate_data, str) and base_rate_data in fr:
        k = fr.kinds[base_rate_data]
        if k == "factor":
            chk_stop("spalte_faktor", "simulation", base_rate_data)
        if not (k == "numeric" or (k == "logical" and all(_isna(v) for v in fr.get(base_rate_data)))):
            chk_stop("spalte_typ", "simulation", base_rate_data, chk_msg("typ.numerisch"))
        chk_col_nona(fr, base_rate_data, "simulation", chk_msg("hinweis.basiszins"))
        _frac_warn_col(fr, base_rate_data, "base_rate", hi=0.05)
    expected_days = (stopp_date - start_date) + 1
    if fr.nrow != expected_days:
        _message("Hinweis: %d Zeilen, erwartet %d Kalendertage. Fehlende Tage werden aufgef\u00fcllt (LOCF; Signale = "
                 "FALSE)." % (fr.nrow, expected_days))
        all_dates = np.arange(start_date, stopp_date + 1, dtype=np.int64)
        n = all_dates.size
        # Zeile je Kalendertag und Zahlenspalten mit LOCF seit 1.6.0 im Kern (sl_cal_index, sl_cal_fill_real)
        src = np.empty(n, dtype=np.int64)
        _ext.slc_cal_index(np.trunc(np.asarray(fr.get("date"), dtype=np.float64)), float(start_date), src)  # int(z)
        have = src >= 0
        new_cols, new_kinds = {"date": all_dates.astype(np.float64)}, {"date": "date"}
        names = ["date"] + [nm for nm in fr.names if nm != "date"]
        for nm in names[1:]:
            v = fr.cols[nm]
            k = fr.kinds[nm]
            if k in ("numeric", "date", "posixct"):
                out = np.empty(n)
                _ext.slc_cal_fill_real(src, np.ascontiguousarray(v, dtype=np.float64), out, k == "numeric")
            else:
                out = np.empty(n, dtype=object)
                out[:] = None
                out[have] = v[src[have]]
                if k == "logical":
                    out[np.equal(out, None)] = False
            new_cols[nm], new_kinds[nm] = out, k
        filled = np.ones(n, dtype=bool)
        filled[have] = np.asarray(pre_filled, dtype=bool)[src[have]]
        new_cols[".filled"], new_kinds[".filled"] = filled, "filled"
        names.append(".filled")
        fr.names, fr.cols, fr.kinds = names, new_cols, new_kinds
    elif np.any(pre_filled):
        fr.set(".filled", np.asarray(pre_filled, dtype=bool), "filled")
    return {"data": fr, "start_date": start_date, "stopp_date": stopp_date}


def _signal_col(fr: _Frame, col: str | None) -> np.ndarray | None:
    if col is None:
        return None   # keine Spalte: der Kern liest FALSE an jedem Tag (seit 1.6.1; bis 1.6.0 ein Feld aus False je Tag)
    v = fr.get(col)
    if fr.kinds[col] == "numeric":
        return np.array(v, dtype=np.float64)
    return np.array(v, dtype=object)


def _sim_build_state(fr: _Frame, strategy: dict, start_date: int, stopp_date: int,
                     sparer_pauschbetrag: float, use_sparer_pauschbetrag: bool, base_rate, base_rate_flex,
                     base_rate_data) -> dict:
    n = fr.nrow
    sim: dict = {
        "assets": {}, "status": {}, "market": {}, "trades": {}, "report": {},
        "totals": {
            "total_taxes": 0.0, "loss_capital_gains": 0.0, "loss_private_sales": 0.0,
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
            "style": a.get("trading"),
            "start": start_date if st_raw is None else _date_or_fail(st_raw),
            "tax_regime": regime, "bonus": (0.0 if bonus is None else float(bonus)) / 100,
        }
        if a.get("trading") == "signal":
            sb, ss = a.get("signal_buy"), a.get("signal_sell")
            if sb is None or sb not in fr:
                _stop("simulation: signal_buy-Spalte '%s' fehlt im Datensatz (Asset '%s')." % (sb if sb is not None
                                                                                            else "NULL", name))
            if ss is None or ss not in fr:
                _stop("simulation: signal_sell-Spalte '%s' fehlt im Datensatz (Asset '%s')." % (ss if ss is not None
                                                                                             else "NULL", name))
            # seit 1.6.4 nur True/False oder 0/1 mit NA (Entscheidung 1; bis 1.6.3 jeder Wert nach bool(), Text
            # "FALSE" als wahr, jede Zahl ungleich 0 als wahr)
            chk_col_signal(fr, sb, "simulation")
            chk_col_signal(fr, ss, "simulation")
        if base_rate_flex:
            if base_rate_data is None or base_rate_data not in fr:
                if base_rate_data is None:
                    _stop("simulation: base_rate_flex = TRUE braucht base_rate_data (Name der Basiszins-Spalte in data, "
                          "Prozent p. a.); base_rate_data fehlt.")
                _stop("simulation: base_rate-Spalte '%s' fehlt in data (tax_profile(base_rate = \"%s\") braucht eine "
                      "Basiszins-Spalte in Prozent p. a.; vorhanden: %s)." % (base_rate_data, base_rate_data,
                                                                              ", ".join(fr.names)))
            br = np.array(fr.get(base_rate_data), dtype=np.float64)
            br[np.isnan(br)] = 0.0
        else:
            br = np.full(n, float(base_rate) if base_rate is not None else 0.0)
        spread_a = a.get("spread")
        sim["market"][name] = {
            "base_rates": br,
            "asset_price": np.array(fr.get(name), dtype=np.float64),
            "signal_buy": _signal_col(fr, a.get("signal_buy")),
            "signal_sell": _signal_col(fr, a.get("signal_sell")),
            "spread_rate": (0.0 if spread_a is None else float(spread_a)) / 100,
        }
        sim["trades"][name] = {"raw": None}   # flache Felder des Kerns (_sim_engine_run, seit 1.6.3)
    return sim   # status und report setzt der Kern (Startgewichte, Anfangszustand)


def _as_logical_col(fr: _Frame, col: str) -> np.ndarray:
    v = fr.get(col)
    k = fr.kinds[col]
    if k == "numeric":   # Schnellweg (seit 1.6.3): NA/NaN -> FALSE, sonst x != 0 wie die Schleife
        a = np.asarray(v, dtype=np.float64)
        return ~np.isnan(a) & (a != 0)
    if k == "logical" and all(x is True or x is False or x is None for x in v):
        return np.array([x is True for x in v], dtype=bool)
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


def _sim_build_calendar(fr: _Frame, sim: dict, strategy: dict, start_date: int, stopp_date: int,
                        dca_mode, dca_span, dca_unit, dca_days, dca_value, dca_anchor, dca_start, dca_skip,
                        balance_mode, balance_span, balance_unit, balance_days, balance_anchor, balance_start,
                        balance_skip, event_col, event_mode, event_weight) -> dict:
    """Angaben der Termine und Tages-Flags (wie ``.sim_build_calendar`` in R): Kalender, Terminpläne
    (``_sched_spec``), Ereignis-Spalte und die Prüfungen; Termine, Splits, Flags, Aktivierung, Freibetrag und
    Startgewichte rechnet der Kern (core/prepare_core_impl.h, über ``_sim_engine_run``)."""
    flag_date = np.arange(start_date, stopp_date + 1, dtype=np.int64)
    n = flag_date.size
    if ".filled" in fr:
        flag_filled = np.asarray(fr.get(".filled"), dtype=bool).copy()
    else:
        flag_filled = np.zeros(n, dtype=bool)
    fr.drop(".filled")
    flag_assets = list(strategy.keys())
    for a, sd0, mode in (("dca", dca_start, dca_mode), ("balance", balance_start, balance_mode)):
        if not _is_true(mode) or sd0 is None:
            continue
        sd1 = _as_date(sd0)
        if sd1 is None:
            _stop("simulation: %s_start ist kein Datum (erwartet Date oder \"JJJJ-MM-TT\")." % a)   # seit 1.6.4 ohne Wert
        if sd1 > stopp_date:
            _stop("simulation: %s liegt nach dem letzten Datentag (%s); es g\u00e4be keine Termine."
                  % ("start von %s" % ("dca_plan()" if a == "dca" else "rebalance_plan()"), fmt_date(stopp_date)))
    balance = _sched_spec(balance_mode, balance_span, balance_unit, balance_days, flag_date, None, balance_anchor,
                         balance_start, balance_skip)
    dca = _sched_spec(dca_mode, dca_span, dca_unit, dca_days, flag_date, dca_value, dca_anchor, dca_start, dca_skip)
    event_mode = _match_arg(event_mode, ("additional", "replace"), "event_mode")
    flag_event = None
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
    for name in flag_assets:
        st_a = sim["assets"][name]["start"]
        if st_a is not None and st_a > stopp_date:
            _stop("simulation: start von '%s' liegt nach dem letzten Datentag (%s); das Asset w\u00e4re nie "
                  "handelbar. start auf ein Datum im Datenzeitraum setzen oder das Asset aus der Strategie "
                  "entfernen." % (name, fmt_date(stopp_date)))   # seit 1.6.4 ohne Eingabewert
    # bis 1.3.0 _sim_init_weights: mindestens ein Asset ab dem ersten Tag handelbar
    if not any(sim["assets"][nm]["start"] <= int(flag_date[0]) for nm in flag_assets):
        _stop("simulation: Kein Asset ist am ersten Datentag (%s) handelbar (start bzw. erste Kurse sp\u00e4ter); "
              "mindestens ein Asset muss ab Beginn handelbar sein." % fmt_date(int(flag_date[0])))
    return {"data": fr,
            "flags": {"flag_date": flag_date, "flag_filled": flag_filled, "flag_assets": flag_assets, "dca": dca,
                      "balance": balance, "flag_event": flag_event, "event_replace": event_mode == "replace"},
            "event_weight": event_weight if event_col is not None else None}


# ═══════════════════════════════════════════════════════════════════════════
