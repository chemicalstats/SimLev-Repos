"""simulation(), Phasen 4 und 5 über den gemeinsamen C++-Kern: Tagesengine ``core/engine_core_impl.h``.

Der Kern rechnet die Tagesschleife (Batch- und Marktupdate, Aktivierung, Splits, Sparplan, Handel, Rebalancing,
Freibetrag, Vorabpauschale, Liquidation, Jahreswechsel und Abrechnungen mit Steuer) und den Abschluss des letzten
Jahres (bis 1.3.0 die Phasen ``_sim_run_days``, ``_Actions`` und ``_sim_close_years``). Warnungen,
``details``-Ausgaben und Abbrüche meldet der Kern als Codes mit Werten; die Texte setzt ``_sim_engine_signal``
wortgleich zu R 1.3.0, in derselben Reihenfolge (Ausgabe und Warnungen verzahnt). Gegenstücke:
``r/R/sim_engine.R``, ``julia/src/sim_engine.jl``.
"""
from __future__ import annotations

import numpy as np
import pandas as pd

from . import _ext
import math
import re
import sys

from ._dates import fmt_date, year_of
from ._meldungen import ENGINE_DETAIL as _MD, ENGINE_LABEL as _ML, ENGINE_REASON as _MR, ENGINE_SIGNAL as _MS
from ._r.rformat import r_format1, r_sprintf
from ._r.rnum import NA_REAL as NA
from ._sim_base import _FEE, _is_true, _stop, _warn

# Zeilen der Jahreszeile des Tarifwegs (core/tariff_core_impl.h, enum TR_*; wie _tariff_close)
_ROW_FIELDS = ("year", "taxable_income", "church_tax_paid_deductible", "church_tax_refunded",
               "church_tax_net_deduction", "taxable_income_net", "deduction_effect", "gain_p23", "income_tax_p23",
               "soli_p23", "church_tax_p23", "tax_p23", "capital_income", "abgeltung_burden", "church_tax_withheld_k",
               "tariff_income_tax_k", "tariff_soli_k", "tariff_church_tax_k", "tariff_burden", "burden_without_gp",
               "burden_with_gp", "guenstiger", "settlement", "refund", "church_tax_settlement_next_year")
_TOT_FIELDS = ("total_taxes", "loss_capital_gains", "loss_private_sales", "private_sale_gains_ytd",
               "private_sale_losses_ytd", "sparer_pauschbetrag_annual", "sparer_pauschbetrag_remaining",
               "sparer_pauschbetrag_used_total", "current_year", "cgt_base_taxed_ytd", "cgt_loss_added_ytd",
               "cgt_loss_used_ytd", "cgt_pool_start_ytd")
_REGIMES = (None, "investment_fund", "capital_gains", "private_sale")


def _signal(v) -> tuple[np.ndarray | None, int]:
    """Signalspalte als float64 (logisch: 0/1, NA als NaN) und Merker 'logisch' (isTRUE nur für TRUE); ``None``
    (keine Spalte) bleibt ``None``, der Kern bekommt dann einen leeren Zeiger (seit 1.6.1)."""
    if v is None:
        return None, 1
    if isinstance(v, np.ndarray) and v.dtype == np.float64:
        return v, 0
    a = np.asarray(v)
    if a.dtype == bool:
        return a.astype(np.float64), 1
    na = pd.isna(a)   # vektorisiert (None, NaN, pd.NA); sonst wie _isna je Wert
    out = np.zeros(a.size, dtype=np.float64)
    ok = ~na
    out[ok] = a[ok].astype(bool)   # Wahrheitswert je Wert wie bool(x)
    out[na] = np.nan
    return out, 1


def _fee(f) -> list:
    return [0.0] * 5 if f is None else [1.0, float(f["fixed"]), float(f["percent"]), float(f["min"]), float(f["max"])]


def _num(x, default=0.0) -> float:
    return default if x is None else float(x)


def _harvest_md(harvest_day) -> int:
    """Freibetrag ab harvest_day ("MM-TT"): erster Monat * 100 + Tag, den der Zeichenvergleich zulässt (wie R)."""
    if isinstance(harvest_day, str) and re.fullmatch(r"[0-9]{2}-[0-9]{2}", harvest_day):
        return int(harvest_day[:2]) * 100 + int(harvest_day[3:])
    ok = [m * 100 + d for m in range(1, 13) for d in range(1, 32) if "%02d-%02d" % (m, d) >= harvest_day]
    return min(ok) if ok else 9999


def _sim_engine_run(sim: dict, fl: dict, cfg: dict, fr, event_weight, split_thresh, balance_dca, harvest_loss_pot,
                    liquidate, stopp_date: int, details: bool, harvest_day) -> tuple[dict, float]:
    """Vorbereitung, Phasen 4 und 5 über den C++-Kern (Termine, Flags, Startgewichte, Tagesschleife
    und Abschluss des letzten Jahres); Rückgabe (sim, nicht gedeckte Steuerzahlungen in EUR). Setzt
    fl["flag_harvest"] und fl["tax_regimes"]."""
    ei = _sim_engine_input(sim, fl, cfg, fr, event_weight, split_thresh, balance_dca, harvest_loss_pot, liquidate,
                           stopp_date, details, harvest_day)
    reports = _engine_reports(ei)
    out = _ext.sim_engine_run(*ei["args"], [r[k] for r in reports for k in _REP_KEYS])
    return _sim_engine_finish(out, sim, fl, ei, reports, cfg.get("tariff_env") if ei["person"] else None)


_REP_KEYS = ("worth", "money", "flows", "total", "share")


def _engine_reports(ei: dict) -> list:
    """Report-Vektoren je Asset, die der Kern beschreibt (worth, money, flows, total, share)."""
    n = ei["n"]
    return [{k: np.zeros(n) for k in _REP_KEYS} for _ in ei["nm"]]


def _sim_engine_input(sim: dict, fl: dict, cfg: dict, fr, event_weight, split_thresh, balance_dca, harvest_loss_pot,
                      liquidate, stopp_date: int, details: bool, harvest_day) -> dict:
    """Eingabe der Tagesengine (seit 1.6.5 eigene Funktion, Paket E: der Studienkern ``_sim_prepared.py`` merkt sie
    sich je Strategie und tauscht je Pfad nur Kurse und Signale): ``args`` = die ersten 15 Argumente von
    ``_ext.sim_engine_run`` (ohne reports), dazu nm, n, person, tax_regimes."""
    nm = list(fl["flag_assets"])
    flag_date = np.asarray(fl["flag_date"], dtype=np.int64)
    n = int(flag_date.size)
    person = cfg["tax_mode"] == "person"
    mk = sim["market"]
    prices, sb, ss, sig_logical = [], [], [], []
    for a in nm:
        prices.append(np.ascontiguousarray(mk[a]["asset_price"], dtype=np.float64))
        v, lb = _signal(mk[a]["signal_buy"])
        w, ls = _signal(mk[a]["signal_sell"])
        sb.append(v)
        ss.append(w)
        sig_logical.append((lb, ls))
    ew = None
    if event_weight is not None:
        ew = [None if event_weight.get(a) is None else np.asarray(fr.get(event_weight[a]), dtype=np.float64)
              for a in nm]
    br = [np.ascontiguousarray(mk[a]["base_rates"], dtype=np.float64) for a in nm] if person else None
    regime_code = {"investment_fund": 1, "capital_gains": 2, "private_sale": 3}
    no_split = set(cfg.get("no_split") or [])
    tax_regimes = {a: sim["assets"][a]["tax_regime"] for a in nm}
    ai, ad = [], []
    for k, a in enumerate(nm):   # Startindizes und Start-Assets setzt die Vorbereitung
        ai += [1 if sim["assets"][a]["style"] == "signal" else 0, 0, 0, 0, regime_code.get(tax_regimes[a], 0),
               1 if a in no_split else 0, sig_logical[k][0], sig_logical[k][1]]
        bonus = sim["assets"][a].get("bonus")
        ad += [float(mk[a]["spread_rate"]), float(cfg["strategy"][a]["share"]), _num(bonus)]
    harvest_on = _is_true(cfg.get("harvest_mode")) and person
    split_on = _is_true(cfg.get("split_mode")) and split_thresh is not None
    lo = float(split_thresh[0]) if split_on else 0.0
    hi = float(split_thresh[1]) if split_on else 0.0
    dca, bal = fl["dca"], fl["balance"]
    pi = np.concatenate([np.array([bool(liquidate), bool(fl["event_replace"]), split_on, person, harvest_on,
                                   _harvest_md(harvest_day) if harvest_on else 0], dtype=np.int32),
                         dca[0], bal[0]]).astype(np.int32)
    pd_ = np.array([float(stopp_date), lo, hi, float(cfg["start_value"]), dca[1], bal[1]], dtype=np.float64)
    filled = np.asarray(fl["flag_filled"], dtype=bool)
    ev = fl["flag_event"]
    prep = (pi, pd_, np.array([float(sim["assets"][a]["start"]) for a in nm], dtype=np.float64),
            filled.astype(np.int32) if filled.any() else None, None if ev is None else np.asarray(ev, dtype=np.int32),
            dca[2], dca[3], bal[2], bal[3])
    tt = sim["totals"]
    tot0 = [_num(tt.get(f)) for f in _TOT_FIELDS]
    env = cfg.get("tariff_env") if person else None
    tariff_par = np.zeros(0)
    zve = []
    if env is not None:
        from .withdrawal import _wd_tariff_par
        tariff_par = _wd_tariff_par(env.tariff, env.church_k, env.use_gp)
        if env.zve_all is None and env.zve:
            for y, v in env.zve.items():
                zve += [float(int(y)), float(v)]
    bt = cfg.get("balance_thresh")
    ci = [int(bool(cfg.get("fractions"))), int(bool(cfg.get("fees_on"))), int(bool(cfg.get("balance_mode"))),
          int(bool(balance_dca)), int(bt is not None), int(cfg.get("balance_thresh_type") == "relative"), int(person),
          int(bool(cfg.get("use_sparer_pauschbetrag"))), int(bool(harvest_loss_pot)), int(bool(liquidate)),
          int(cfg.get("marginal_tax_rate") is not None), year_of(int(stopp_date)),
          int(env is not None and env.zve_all is not None), int(bool(details))]
    cd = [_num(bt), _num(cfg.get("dca_value")), float(_FEE.paid), _num(cfg.get("effective_tax_rate")),
          _num(cfg.get("marginal_tax_rate")), _num(cfg.get("private_sale_threshold")),
          _num(cfg.get("sparer_pauschbetrag")), _num(cfg.get("soli_factor_income"), 1.0), _num(cfg.get("church_k")),
          lo, hi,
          float(env.zve_all) if env is not None and env.zve_all is not None else 0.0]
    args = [prep, flag_date.astype(np.float64), prices, sb, ss, ew, br, np.array(ai, dtype=np.int32),
            np.array(ad, dtype=np.float64), np.array(ci, dtype=np.int32), np.array(cd, dtype=np.float64),
            np.array(_fee(cfg.get("fee_order")) + _fee(cfg.get("fee_dca")) + _fee(cfg.get("fee_cust")), dtype=np.float64),
            np.array(tot0, dtype=np.float64), np.asarray(tariff_par, dtype=np.float64), np.array(zve, dtype=np.float64)]
    return {"args": args, "nm": nm, "n": n, "person": person, "tax_regimes": tax_regimes, "flag_date": flag_date,
            "sig_logical": sig_logical}


def _sim_engine_finish(out, sim: dict, fl: dict, ei: dict, reports: list, env) -> tuple[dict, float]:
    """Ergebnis der Tagesengine in sim, fl, Tarifjahre (env), Gebühren und Meldungen übernehmen (seit 1.6.5 eigene
    Funktion, Paket E); env: Tarifzustand dieses Laufs (None ohne Steuer ``person``)."""
    nm, flag_date, tax_regimes = ei["nm"], ei["flag_date"], ei["tax_regimes"]
    mk, tt = sim["market"], sim["totals"]
    (status, totals, lots, sells, taxes, px, fee_paid, tax_unpaid, rows, ks, events, err, flags) = out
    for a, r in zip(nm, reports):
        sim["report"][a] = r
    stv = np.frombuffer(status, dtype=np.float64)
    fl["flag_harvest"] = (np.frombuffer(flags, dtype=np.int32) & 128) != 0
    fl["tax_regimes"] = tax_regimes
    for k, a in enumerate(nm):
        sim["status"][a] = {"money": float(stv[8 * k + 3])}   # Status je Asset: gelesen wird nur money (wie R seit 1.6.3)
        # Lots, Verkäufe und Steuerbuchungen als flache Felder (seit 1.6.3); die Dicts je Eintrag baut erst
        # SimLevResult.trades (_trades_dicts), die Auswertung liest Zähler und offene Lots aus den Feldern
        tr = sim["trades"][a]
        tr["raw"] = (np.frombuffer(lots[k], dtype=np.float64).reshape(-1, 7),
                     np.frombuffer(sells[k], dtype=np.float64).reshape(-1, 8),
                     np.frombuffer(taxes[k], dtype=np.float64).reshape(-1, 8))
        if px[k] is not None:
            mk[a]["asset_price"] = np.frombuffer(px[k], dtype=np.float64).copy()
    tv = np.frombuffer(totals, dtype=np.float64)
    for j, f in enumerate(_TOT_FIELDS):
        tt[f] = int(tv[j]) if f == "current_year" else float(tv[j])
    if env is not None:   # Tarifweg: Jahreszeilen (wie _tariff_close), KiSt-Salden
        rv = np.frombuffer(rows, dtype=np.float64).reshape(-1, len(_ROW_FIELDS))
        for x in rv:
            row = {f: float(v) for f, v in zip(_ROW_FIELDS, x)}
            row["year"] = int(x[0])
            row["guenstiger"] = bool(x[21] != 0)
            env.rows.append(row)
        kv = np.frombuffer(ks, dtype=np.float64).reshape(-1, 2)
        for y, v in kv:
            env.ks[str(int(y))] = float(v)
    _FEE.paid = fee_paid
    _sim_engine_signal(events, err, nm, flag_date)
    return sim, tax_unpaid


def _trades_dicts(raw) -> dict:
    """Trades eines Assets aus den flachen Feldern des Kerns (Lots 7, Verkäufe 8, Steuern 8 Werte je Eintrag) als
    Listen von Dicts wie bis 1.6.2 (``SimLevResult.trades``, nur Python)."""
    lv, sv, tv = raw
    buys = []
    for x in lv:
        lot = {"date": int(x[0]), "type": "Buy", "count": float(x[1]), "price": float(x[2]),
               "remaining": float(x[3]), "original": float(x[4])}
        if x[6] != 0:
            lot["vp"] = float(x[5])
        buys.append(lot)
    sl = []
    for x in sv:
        rg = int(x[5])
        sl.append({"event_date": int(x[0]), "event_type": "Sell", "asset_count": float(x[1]),
                   "asset_price": float(x[2]), "event_gain": float(x[3]) if rg else NA,
                   "event_taxes": float(x[4]) if rg else NA, "tax_regime": _REGIMES[rg],
                   "tax_deferred": rg == 3, "holding_exempt": float(x[6]) if x[7] != 0 else NA})
    tl = []
    for x in tv:
        if int(x[0]) == 1:
            tl.append({"event_date": int(x[1]), "assessment_date": int(x[2]), "event_type": "Vorabpauschale",
                       "flat_rate_gross": float(x[3]), "bonus_applied": float(x[4]),
                       "flat_rate_taxable": float(x[5]), "spb_used": float(x[6]), "taxes_paid": float(x[7])})
        else:
            tl.append({"event_date": int(x[1]), "event_type": "Private sale tax", "taxes_paid": float(x[7])})
    return {"buys": buys, "sells": sl, "taxes": tl}


# Anlass der Käufe und Verkäufe (enum Reason in engine_core_impl.h); Texte aus core/meldungen.tsv (_meldungen.py)
_REASONS = tuple(_MR[str(k)] for k in range(len(_MR)))


def _label(aux: int, ints) -> str:
    """Bezeichnung einer Steuerzahlung (.pay_tax label); 3 (Depotgebühr) seit 1.6.5."""
    if aux == 3:
        from ._pruefen import chk_msg
        return chk_msg("a.label_depot")
    return _ML[str(aux)] if aux < 2 else _ML["2"] % "/".join(str(y) for y in ints)


def _sim_engine_signal(events, err, nm, flag_date) -> None:
    """Warnungen, details-Ausgaben und Abbruch des Kerns mit den Texten von R 1.3.0 auslösen (Reihenfolge des
    Protokolls); Texte aus ``_meldungen.ENGINE_SIGNAL``."""
    for code, site, day, asset, aux, ints, d0, d1, v in events:
        a = nm[asset] if asset >= 0 else None
        if code >= 200:
            _sim_engine_detail(code, a, aux, v, ints, nm, fmt_date(int(flag_date[day - 1])))
        elif code == 1:
            _warn(r_sprintf(_MS["1"], d0, a, fmt_date(int(flag_date[day - 1]))))
        elif code == 2:
            _warn(r_sprintf(_MS["2"], d0, d1, a))
        elif code == 3:
            _warn(r_sprintf(_MS["3"], a, d0))
        elif code == 4:
            _warn(_MS["4"])
        elif code == 5 and aux == 3:   # seit 1.6.5 (Paket E): nicht gedeckte Depotgebühr als offene Gebühr
            from ._pruefen import chk_msg
            _warn(chk_msg("e.gebuehr_ungedeckt", _label(aux, ints), r_sprintf("%.2f", d0),
                          fmt_date(int(flag_date[day - 1])), r_sprintf("%.2f", d1), a))
        elif code == 5:
            _warn(r_sprintf(_MS["5"], _label(aux, ints), d0, fmt_date(int(flag_date[day - 1])), d1, a))
        elif code == 6:
            _warn(r_sprintf(_MS["6"], d0, d1) + _MS["6.rest"])
        elif code == 7:   # seit 1.6.5 (CR2-G-6, K36): Hinweis zu unbrauchbaren event_weight an Ereignistagen
            from ._pruefen import chk_msg
            from ._sim_base import _message
            _message(chk_msg("a.event_gewicht", str(int(d0)), fmt_date(int(flag_date[day - 1]))))
        else:
            _stop(_MS["unbekannt"] % code)
    if err is not None:
        if err[3] == 101:
            _stop(_MS["101"] % r_format1(err[4]))
        if err[3] == 102:                                     # seit 1.6.4 (A-005, Entscheidung 103)
            from ._pruefen import chk_stop
            chk_stop("fa.nicht_endlich")
        if err[3] == 103:                                     # seit 1.6.4 (K43 T1-R9)
            from ._pruefen import chk_stop
            chk_stop("ut1.unterlauf")
        _stop(_MS["na"])


def _sim_engine_detail(code: int, name, aux: int, v, ints, nm, ds: str) -> None:
    """details-Ausgabe eines Ereignisses (DT_* in engine_core_impl.h), wortgleich zu R 1.3.0; Texte aus
    ``_meldungen.ENGINE_DETAIL``."""
    sp = r_sprintf
    out = sys.stdout.write
    m = _MD
    if code == 201:
        out(sp(m["201"], _REASONS[aux], v[0], name, v[1], ds))
    elif code == 202:
        out(sp(m["202"], v[0]))
    elif code == 203:
        out(sp(m["203"], v[0], v[1]))
    elif code == 204:
        out(sp(m["204"], v[0]))
    elif code == 205:
        out(sp(m["205"], v[0]))
    elif code == 206:
        out(sp(m["206"], v[0], v[1]))
    elif code == 207:
        out(sp(m["207"], v[0], v[1]))
    elif code == 208:
        out(sp(m["208"], _REASONS[aux], v[0], name, v[1], ds))
    elif code == 209:   # ifelse(gain < 0, ...) mit NA: "NA" wie R
        out(sp(m["209"], "NA" if math.isnan(v[0]) else (m["209.verlust"] if v[0] < 0 else m["209.gewinn"]), v[0], v[1]))
    elif code == 210:
        out(sp(m["210"], v[0], v[1], name, v[2]))
    elif code == 211:
        desc = m["211.v1" if aux == 1 else "211.v2"] % r_format1(v[0], digits=5)
        out(m["211"] % (m["211.split"] if aux == 1 else m["211.reverse"], name, desc, ds))
    elif code == 212:
        out(m["212"] % (name, m["212.v1"] if aux == 1 else m["212.v2"], r_format1(v[0], digits=5), ds))
    elif code == 213:
        out(m["213"] % ", ".join(nm[k] for k in ints))
    elif code == 214:
        parts = "; ".join(sp(m["214.teil"], nm[k], x) for k, x in zip(ints, v[1:]))
        out(sp(m["214"], v[0], ds) + parts + "\n")
    elif code == 215:
        out(m["215"] % (ds, ", ".join(nm[k] for k in ints)))
    elif code == 216:
        out(sp(m["216"], ds, v[0], v[1]))
    elif code == 217:
        out(sp(m["217"], name, v[0], v[1], v[2]))
    elif code == 218:
        out(sp(m["218"], ds, v[0], v[1]))
    elif code == 219:
        out(sp(m["219"], v[0], name))
    elif code == 220:
        out(sp(m["220"], v[0], name))
    elif code == 221:
        out(sp(m["221"], name, v[0]))
    elif code == 222:
        out(sp(m["222"], v[0]))
    elif code == 223:
        out(sp(m["223"], v[0], name))
    elif code == 224:
        out(sp(m["224"], name, v[0], ds))
    elif code in (225, 226) and int(aux) == 3:   # seit 1.6.5 (Entscheidung 194): Depotgebühr mit Präfix „Depotgebühr:“
        from ._pruefen import chk_msg
        if code == 225:
            out(chk_msg("a.dt_gebuehr_zahlung", sp("%.2f", v[0]), name, ds))
        else:
            out(chk_msg("a.dt_gebuehr_teil", sp("%.2f", v[0]), ds))
    elif code == 225:
        out(sp(m["225"], _label(aux, ints), v[0], name, ds))
    elif code == 226:
        out(sp(m["226"], _label(aux, ints), v[0], ds))
    elif code == 227:
        out(sp(m["227"], v[0], _label(aux, ints)))
    elif code == 228:
        out(sp(m["228"], int(v[0]), v[1], v[2], v[3], sp(m["228.guenstiger"], v[4]) if aux & 1 else "", ds,
               m["228.asset"] if aux & 2 else m["228.gleich"]))
    elif code == 229:
        out(sp(m["229"], name, v[0]))
    elif code == 230:
        out(sp(m["230"], v[0], name, ds))
    elif code == 231:
        out(sp(m["231"], v[0], ds))
    elif code == 232:
        out(sp(m["232"], name, fmt_date(int(v[0])), v[1], v[2], v[3], v[4], ds))
    elif code in (233, 234):   # seit 1.6.5: Zahlung aus dem Geld eines anderen Assets (MA1-2), Depotgebühr (150)
        from ._pruefen import chk_msg
        if code == 233:
            if int(aux) == 3:
                out(chk_msg("a.dt_gebuehr_anderes", sp("%.2f", v[0]), nm[int(v[1])], name, ds))
            else:
                out(chk_msg("a.dt_zahlung_anderes", _label(aux, ints), sp("%.2f", v[0]), nm[int(v[1])], name, ds))
        else:
            out(chk_msg("a.dt_depot", sp("%.2f", v[0]), sp("%.2f", v[1]), sp("%.4f", v[2]), ds))
    elif code == 240:
        out(m["240.1"])
        out(m["240.2"] % (int(v[0]), int(v[1])))
        out(m["240.3"])
    elif code == 241:
        out(sp(m["241.1"], v[0]))
        out(sp(m["241.2"], v[1]))
    elif code == 242:
        out(m["242.1"] % int(v[0]))
        out(sp(m["242.2"], v[1]))
        out(sp(m["242.3"], v[2]))
        out(sp(m["242.4"], v[3]))
        out(sp(m["242.5"], v[4]))
        out(m["242.6"])
        out(sp(m["242.7"], v[5]))
    elif code == 243:
        out(m["243.1"])
        out(sp(m["243.2"], v[0], v[1]))
        out(sp(m["243.3"], v[2]))
        if aux == 1:
            out(m["243.tarif"])
        else:
            out(sp(m["243.satz"], v[3] * 100, sp(m["243.soli"], (v[4] - 1) * 100) if v[4] > 1 else "",
                   sp(m["243.kist"], v[5] * 100) if v[5] > 0 else ""))
            out(sp(m["243.last"], v[6]))
    elif code == 244:
        out(sp(m["244.1"], v[0]))
        out(sp(m["244.2"], v[1]))
    elif code == 245:
        out(sp(m["245"], v[0], v[1]))
    elif code == 246:
        out(m["246"] % int(v[0]))
    elif code == 247:
        out(m["247.1"] % int(v[0]))
        out(sp(m["247.2"], v[1]))
        out(sp(m["247.3"], v[2]))
        out(sp(m["247.4"], v[3]))
    elif code == 248:
        out(sp(m["248"], v[0]))
    elif code == 249:
        out(sp(m["249"], v[0], int(v[1]), v[2], v[3]))
    elif code == 250:   # Jahreszeile in der Reihenfolge TR_* (tariff_core_impl.h)
        year, X1, D = int(v[0]), v[20], v[22]
        out(sp(m["250.1"], year, v[1], v[4], v[2], v[3], v[5], v[6]))
        if aux & 2:
            out(sp(m["250.p23"], v[7], v[8], v[9], v[10], v[11]))
        if aux & 1:
            out(sp(m["250.guenstiger"], v[12], v[13], v[14], v[18], v[15], v[16], v[17], v[19],
                   "-" if math.isnan(X1) else sp(m["250.x1"], X1), m["250.tarif"] if v[21] != 0 else m["250.bleibt"]))
        out(sp(m["250.abrechnung"], m["250.nach"] if D >= 0 else m["250.erst"], abs(D), v[24], year + 1))
    elif code == 251:
        out(m["251.1"] % int(v[0]))
        out(m["251.2"])
    else:
        _stop(_MS["unbekannt"] % code)

