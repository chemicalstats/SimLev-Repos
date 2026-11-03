"""Phase 6 von ``simulation()``: Auswertung und Ergebnisobjekt (nachgebildet aus ``r/R/sim_evaluate.R``; Julia:
``sim_evaluate.jl``).

rechnet der C++-Kern ``core/evaluate_core_impl.h`` (``_ext.sim_evaluate``) Wertreihen, Renditen,
XIRR, Drawdowns, Kennzahlen und die Ursachen nicht definierter Kennzahlen; Warnungen, Abbrüche und Ursachen kommen
als Codes mit Werten, die Texte setzt dieses Modul wortgleich zu R. Hier bleiben ``risk_free`` (Spalte von ``data``),
die Texte und das Ergebnisobjekt.
"""
from __future__ import annotations

import math

import numpy as np
import pandas as pd

from . import _ext
from ._dates import fmt_date
from ._r.rexpr import as_numeric
from ._r.rnum import NA_REAL as NA  # R's NA_real_ (Nutzlast 1954)
from ._sim_base import (
    _FEE,
    _Frame,
    _is_num,
    _is_true,
    _isna,
    _n_tage,
    _rmax,
    _sp,
    _stop,
    _warn,
)


# Phase 6: Auswertung (sim_evaluate.R)
# ═══════════════════════════════════════════════════════════════════════════

def _sim_compact_trades(sim: dict, flag_assets: list) -> dict:
    out = {}
    for nm in flag_assets:
        tr = sim["trades"][nm]
        out[nm] = {"buys": tr["buys"][:tr["buy_count"]], "sells": tr["sells"][:tr["sell_count"]],
                   "taxes": tr["taxes"][:tr["tax_count"]]}
    return out


def _sim_risk_free(risk_free, fr: _Frame, n_days_sim: int) -> np.ndarray:
    """Reihe ``risk_free`` in Prozent (Zahl auf alle Tage, ``None`` wie 0, oder Spalte von ``data``)."""
    if risk_free is None:
        risk_free = 0
    if isinstance(risk_free, str):
        if risk_free not in fr:
            _stop("risk_free: Spalte '%s' fehlt im Datensatz." % risk_free)
        col = fr.get(risk_free)
        if fr.is_numeric(risk_free):
            return np.array(col, dtype=np.float64)
        if fr.kinds.get(risk_free) in ("logical", "character"):   # as.numeric wie R (Text: Warnung bei NA)
            return np.asarray(as_numeric(np.asarray(col, dtype=object)), dtype=np.float64)
        return np.array([NA if _isna(v) else (float(v) if _is_num(v) else NA) for v in col], dtype=np.float64)
    return np.full(n_days_sim, float(risk_free))


# Namen der Kennzahlen und Ursachen (enum Stat, Metric, Reason in core/evaluate_core_impl.h)
_EVAL_STATS = ("mean", "sd", "cv", "risk_free", "skewness", "kurtosis", "lpm", "hpm", "sharpe", "sortino", "calmar",
               "omega", "gain_to_pain", "serenity", "martin_ratio", "max_drawdown", "average_drawdown", "ulcer_index",
               "longest_drawdown", "avg_recovery_time")
_EVAL_METRICS = ("cagr", "ttwror") + _EVAL_STATS + ("buys", "sells")
_EVAL_REASONS = ("too_short", "negative_end_value", "no_irr_solution", "zero_start_value", "nonpositive_twr_index",
                 "not_finite", "zero_mean_return", "zero_volatility", "no_negative_returns", "no_drawdown",
                 "no_recovery")
_XIRR_WARN = {1: "-Inf replaced by maximally negative value", 2: "NA/Inf replaced by maximum positive value",
              3: "_NOT_ converged in 1000 iterations"}


def _eval_detail(d: int, v, why_text) -> str:
    """Klartext einer Ursache (enum Detail in core/evaluate_core_impl.h)."""
    if d == 0:
        return "Zeitraum %s, Laufzeit 0 Jahre (Einzeltag)" % _n_tage(int(v[0]))
    if d == 1:
        return _sp("Endwert %.2f EUR negativ", v[0])
    if d == 2:
        return _sp("Endwert %.2f EUR negativ: offene Steuerschuld %.2f EUR", v[0], v[1])
    if d == 3:
        return _sp("kein interner Zinsfu\u00df: Startwert %.2f EUR, Einzahlungen %.2f EUR, Endwert %.2f EUR", v[0], v[1],
                   v[2])
    if d == 4:
        return _sp("Depotwert am Starttag %.2f EUR", v[0])
    if d == 5:
        return _sp("zeitgewichteter Wertindex am %s nicht positiv (Tagesrendite %.2f %%)", fmt_date(int(v[0])), v[1])
    if d == 8:
        k = int(v[0])
        return "nur %d %s, mindestens %d n\u00f6tig" % (k, "Tagesrendite" if k == 1 else "Tagesrenditen", int(v[1]))
    if d == 10:
        return "Standardabweichung der %d Tagesrenditen ist 0 (konstanter Verlauf)" % int(v[0])
    if d == 12:
        return "Standardabweichung der %d \u00dcberschussrenditen ist 0" % int(v[0])
    if d == 17:
        return "Drawdown bis zum Ende nicht aufgeholt (l\u00e4ngster Drawdown %s)" % _n_tage(int(v[0]))
    if d == 18:
        return "Zeitraum %s, Laufzeit 0 Jahre: keine Anzahl je Jahr (Einzeltag)" % _n_tage(int(v[0]))
    if d == 19:
        k = int(v[0])
        return "%s nicht definiert: %s" % (_EVAL_METRICS[k], why_text[k])
    return {6: "Rechnung ergibt keinen endlichen Wert", 7: "keine Tagesrendite (Einzeltag)",
            9: "kein Drawdown im Zeitraum (max_drawdown 0)", 11: "mittlere Tagesrendite ist 0",
            13: "keine negativen \u00dcberschussrenditen (Downside-Abweichung 0)", 14: "keine negativen Tagesrenditen",
            15: "kein Drawdown im Zeitraum (Ulcer Index 0)", 16: "kein Drawdown im Zeitraum"}[d]


def _eval_warn(code: int, v) -> None:
    """Warnung der Auswertung (Code des Kerns) mit dem Text von R."""
    if code in _XIRR_WARN:
        _warn(_XIRR_WARN[code])
    elif code == 10:
        _warn(_sp("simulation: geldgewichtete Rendite (cagr) mit Einzahlungen nicht bestimmbar (Startwert %.2f EUR, "
                  "Einzahlungen %.2f EUR, Endwert %.2f EUR): kein interner Zinsfu\u00df gefunden; cagr = NA.",
                  v[0], v[1], v[2]))
    elif code == 11:
        _warn(_sp("simulation: Endwert negativ (%.2f EUR, %s); Verlust \u00fcber 100 %%: cagr und ttwror sind nicht definiert "
                  "(NA), Drawdowns auf 100 %% begrenzt.", v[0],
                  _sp("offene Steuerschuld %.2f EUR", v[1]) if v[1] > 0 else "nicht gedeckte Steuerschuld"))
    elif code == 12:
        _warn("simulation: zeitgewichteter Wertindex wird negativ (Tagesrendite unter -100 %); ttwror ist nicht "
              "definiert (NA).")
    elif code == 13:
        _warn("simulation: Zeitraum %s (Laufzeit 0 Jahre): cagr und ttwror sind nicht definiert (NA)." % _n_tage(int(v[0])))
    elif code == 14:
        _warn(_sp("simulation: Depotwert am Starttag %.2f EUR: cagr ist nicht definiert (NA).", v[0]))
    elif code == 15:
        _warn(_sp("simulation: zeitgewichteter Wertindex am %s nicht positiv (Tagesrendite %.2f %% bei Depotwert %.2f EUR "
                  "am Vortag und Einzahlung %.2f EUR); TTWROR und die zeitgewichteten Drawdowns sind nicht "
                  "aussagekr\u00e4ftig (Drawdowns auf 100 %% begrenzt).", fmt_date(int(v[0])), v[1], v[2], v[3]))
    elif code == 16:
        _warn(_sp("simulation: Depotwert am %s negativ (%.2f EUR, Steuerschuld); Drawdowns auf 100 %% begrenzt.",
                  fmt_date(int(v[0])), v[1]))
    elif code == 17:
        _warn("no non-missing arguments to max; returning -Inf")
    else:
        _stop("simulation: interner Fehler: unbekannter Ereigniscode %d der Auswertung." % code)


def _f64(x) -> np.ndarray:
    return np.ascontiguousarray(x, dtype=np.float64)


def _sim_evaluate(sim: dict, trades: dict, fl: dict, cfg: dict, fr: _Frame, start_date: int, stopp_date: int,
                  tax_unpaid: float) -> dict:
    """Auswertung im Kern; Meldungen in der Reihenfolge von R (Warnungen, risk_free, Abbruch)."""
    nm = fl["flag_assets"]
    flag_date = fl["flag_date"]
    n = int(flag_date.size)
    rep = sim["report"]
    try:
        rf = _f64(_sim_risk_free(cfg["risk_free"], fr, n))
        rf_err = None
    except (ValueError, TypeError) as e:
        rf, rf_err = None, e
    filled = fl["flag_filled"]
    out = _ext.sim_evaluate(
        [_f64(rep[a]["total"]) for a in nm], [_f64(rep[a]["flows"]) for a in nm], [_f64(rep[a]["worth"]) for a in nm],
        [_f64(rep[a]["money"]) for a in nm], [_f64(sim["market"][a]["asset_price"]) for a in nm], _f64(flag_date),
        np.ascontiguousarray(filled, dtype=np.int32) if filled.any() else None,
        _f64([start_date, stopp_date, cfg["start_value"], tax_unpaid]),
        _f64([sim["status"][a]["money"] for a in nm]), _f64([len(trades[a]["buys"]) for a in nm]),
        _f64([len(trades[a]["sells"]) for a in nm]), rf, int(rf_err is None))
    (tw, twr, inv, dd, scal, has_ext, stats, ints, buys, sells, why, um, msgs, err) = out
    for m in msgs:
        _eval_warn(m[0], m[1:])
    if err[1] == 1:
        _stop("missing value where TRUE/FALSE needed")
    if rf_err is not None:
        raise rf_err
    if err[1] == 2:
        _stop("missing value where TRUE/FALSE needed")
    sv = np.frombuffer(stats, dtype=np.float64)
    statistics = {k: float(sv[j]) for j, k in enumerate(_EVAL_STATS)}
    statistics["longest_drawdown"] = int(ints[2])
    why_text = [_eval_detail(w[2], w[3:], None) if w[0] else None for w in why]
    undefined_metrics = pd.DataFrame({"metric": pd.Series([_EVAL_METRICS[u[0]] for u in um], dtype=object),
                                      "reason": pd.Series([_EVAL_REASONS[u[1]] for u in um], dtype=object),
                                      "detail": pd.Series([_eval_detail(u[2], u[3:], why_text) for u in um],
                                                          dtype=object)})
    r = {"total_worth": np.frombuffer(tw, dtype=np.float64), "twr_index": np.frombuffer(twr, dtype=np.float64),
         "invested": np.frombuffer(inv, dtype=np.float64), "has_ext_flows": bool(has_ext), "cagr": scal[0],
         "ttwror": scal[1], "open_tax_debt": scal[2], "drawdowns": np.frombuffer(dd, dtype=np.float64)}
    um_ = {"undefined_metrics": undefined_metrics,
           "buys": pd.Series(np.frombuffer(buys, dtype=np.float64).copy(), index=list(nm), dtype=np.float64),
           "sells": pd.Series(np.frombuffer(sells, dtype=np.float64).copy(), index=list(nm), dtype=np.float64)}
    return {"r": r, "rs": {"statistics": statistics}, "um": um_}


def _sim_result(sim: dict, trades: dict, fl: dict, cfg: dict, r: dict, rs: dict, um: dict):
    from .result import SimLevResult
    flag_date, flag_assets = fl["flag_date"], fl["flag_assets"]
    tax_mode, strategy = cfg["tax_mode"], cfg["strategy"]
    tariff_env = cfg["tariff_env"]
    open_lots = None
    if tax_mode == "person":
        open_lots = {}
        for nm in flag_assets:
            lots = [b for b in trades[nm]["buys"] if b and b["remaining"] > 0]
            sp_ = strategy[nm].get("spread")
            open_lots[nm] = {
                "lots": pd.DataFrame({
                    "date": pd.Series(np.array([b["date"] for b in lots], dtype=np.int64).astype("datetime64[D]")),
                    "units": pd.Series([b["remaining"] for b in lots], dtype=np.float64),
                    "price": pd.Series([b["price"] for b in lots], dtype=np.float64),
                    "vp": pd.Series([b.get("vp") if b.get("vp") is not None else 0.0 for b in lots], dtype=np.float64)}),
                "regime": fl["tax_regimes"][nm],
                "partial_exemption": 100 * sim["assets"][nm]["bonus"],
                "cash": sim["status"][nm]["money"],
                "spread": 0.0 if sp_ is None else float(sp_),
                "order_fee": cfg["order_fee"],
            }
    totals = sim["totals"]
    tax_report = {
        "total_taxes_paid": totals["total_taxes"],
        "loss_carryforward_capital": totals["loss_capital_gains"],
        "loss_carryforward_private": totals["loss_private_sales"],
        "sparer_pauschbetrag_annual": totals["sparer_pauschbetrag_annual"],
        "sparer_pauschbetrag_used": totals["sparer_pauschbetrag_used_total"],
        "sparer_pauschbetrag_tax_saved": totals["sparer_pauschbetrag_used_total"] * cfg["effective_tax_rate"],
        "open_tax_debt": r["open_tax_debt"],
    }
    if tariff_env is not None and tariff_env.rows:
        tax_report["tariff_years"] = pd.DataFrame(tariff_env.rows)
    if tax_mode == "person":
        use_spb = cfg["use_sparer_pauschbetrag"]
        ny = int(totals["current_year"])

        def g0(k):
            v = totals.get(k)
            return 0.0 if v is None else v
        nyd = {
            "year": ny,
            "sparer_pauschbetrag_used": _rmax(0.0, totals["sparer_pauschbetrag_annual"] -
                                              totals["sparer_pauschbetrag_remaining"]) if use_spb else 0.0,
            "sparer_pauschbetrag_remaining": totals["sparer_pauschbetrag_remaining"] if use_spb else 0.0,
            "loss_carryforward_capital": totals["loss_capital_gains"],
            "loss_carryforward_private": totals["loss_private_sales"],
            "capital_income_taxed": g0("cgt_base_taxed_ytd"),
            "loss_capital_added": g0("cgt_loss_added_ytd"),
            "loss_capital_used": g0("cgt_loss_used_ytd"),
            "loss_capital_start": g0("cgt_pool_start_ytd"),
            "private_sale_net": g0("private_sale_gains_ytd") - g0("private_sale_losses_ytd"),
        }
        if tariff_env is not None:
            ks = tariff_env.ks.get(str(ny))
            nyd["church_tax_settlement"] = ks if (ks is not None and not math.isnan(ks)) else 0.0
            nyd["tariff_assessed"] = any(rw["year"] == ny for rw in tariff_env.rows)
        tax_report["next_year"] = nyd
    res = SimLevResult()
    res["dates"] = flag_date.astype("datetime64[D]")
    res["filled"] = fl["flag_filled"].copy()
    res["worth"] = r["total_worth"]
    res["twr_index"] = r["twr_index"]
    res["invested"] = r["invested"]
    res["external_flows"] = bool(r["has_ext_flows"])
    res["cagr"] = float(r["cagr"])
    res["ttwror"] = float(r["ttwror"])
    res["drawdowns"] = r["drawdowns"]
    res["statistics"] = rs["statistics"]
    res["buys"] = um["buys"]
    res["sells"] = um["sells"]
    res["report"] = sim["report"]
    res["tax_report"] = tax_report
    res["undefined_metrics"] = um["undefined_metrics"]
    res["open_lots"] = open_lots
    if cfg["fees_on"]:
        res["fees_paid"] = _FEE.paid
    if _is_true(cfg["harvest_mode"]):
        res["harvest_days"] = flag_date[fl["flag_harvest"]].astype("datetime64[D]")
    if cfg.get("wrappers"):   # nur mit details = TRUE und Wrapper-Assets
        res["wrappers"] = cfg["wrappers"]
    res._trades = trades
    return res
