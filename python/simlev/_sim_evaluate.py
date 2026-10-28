"""Phase 6 von ``simulation()``: Renditen, Risikokennzahlen, nicht definierte Kennzahlen und Ergebnisobjekt
(nachgebildet aus ``r/R/sim_evaluate.R``; Julia: ``sim_evaluate.jl``).
"""
from __future__ import annotations

import math

import numpy as np
import pandas as pd

from ._dates import fmt_date
from ._r.rnum import (
    r_cummax,
    r_cumprod,
    r_cumsum,
    r_mean,
    r_mean_int,
    r_pow,
    r_pow_vec,
    r_prod,
    r_rowsums,
    r_sd,
    r_sum,
)
from ._r.rnum import NA_REAL as NA  # R's NA_real_ (Nutzlast 1954)
from ._sim_base import (
    _FEE,
    _Frame,
    _calculate_kurtosis,
    _calculate_partials,
    _calculate_skewness,
    _is_num,
    _is_true,
    _isna,
    _n_tage,
    _rmax,
    _sp,
    _stop,
    _warn,
    _xirr_rate,
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


def _sim_returns(sim: dict, flag_date: np.ndarray, flag_assets: list, flag_filled: np.ndarray, start_date: int,
                 stopp_date: int, start_value: float, tax_unpaid_total: float) -> dict:
    total_worth = r_rowsums(np.column_stack([sim["report"][nm]["total"] for nm in flag_assets]), na_rm=True)
    total_flows = r_rowsums(np.column_stack([sim["report"][nm]["flows"] for nm in flag_assets]), na_rm=True)
    start_worth = float(total_worth[0])
    n_days_sim = total_worth.size
    stopp_worth = float(total_worth[n_days_sim - 1])
    ann_factor = float(stopp_date - start_date) / 365.25
    cagr = r_pow(stopp_worth / start_worth, 1 / ann_factor) - 1 if (start_worth > 0 and ann_factor > 0) else NA
    n = n_days_sim
    if n >= 2:
        period_change = np.concatenate([[NA], total_worth[1:] - total_worth[:-1] - total_flows[1:]])
        prev_total = np.concatenate([[NA], total_worth[:-1]])
        with np.errstate(divide="ignore", invalid="ignore"):
            cond = (~np.isnan(prev_total)) & (prev_total > 0)
            period_return = np.where(cond, period_change / prev_total, 0.0)
        fday = np.flatnonzero(np.concatenate([[False], ~np.isnan(total_flows[1:]) & (total_flows[1:] != 0)]))
        if fday.size:
            v_pre = np.zeros(fday.size)
            with np.errstate(divide="ignore", invalid="ignore"):
                for nm in flag_assets:
                    rep_a = sim["report"][nm]
                    px = np.asarray(sim["market"][nm]["asset_price"], dtype=np.float64)
                    w_prev = rep_a["worth"][fday - 1]
                    gr = px[fday] / px[fday - 1]
                    v_pre = v_pre + np.where((w_prev != 0) & np.isfinite(gr), w_prev * gr, 0.0) + \
                        rep_a["money"][fday - 1]
                pt = prev_total[fday]
                g1 = np.where(~np.isnan(pt) & (pt > 0), v_pre / pt, 1.0)
                den = v_pre + total_flows[fday]
                g2 = np.where(np.isfinite(den) & (den > 0), total_worth[fday] / den, 1.0)
            period_return[fday] = g1 * g2 - 1
        period_return[0] = NA
    else:
        period_return = np.array([NA])
    ttwror = r_pow(r_prod(1 + period_return, na_rm=True), 1 / ann_factor) - 1 if ann_factor > 0 else NA
    has_ext_flows = n_days_sim >= 2 and bool(np.any(total_flows[1:][~np.isnan(total_flows[1:])] != 0))
    fl0 = total_flows.copy()
    fl0[np.isnan(fl0)] = 0.0
    invested = start_value + r_cumsum(fl0)
    twr_growth = 1 + period_return[1:] if n_days_sim >= 2 else np.zeros(0)
    twr_growth = np.where(np.isfinite(twr_growth), twr_growth, 1.0)
    twr_index = r_cumprod(np.concatenate([[1.0], twr_growth]))
    start_gross = NA
    fi = np.zeros(0, dtype=np.int64)
    if has_ext_flows:
        fi = np.flatnonzero((np.arange(n_days_sim) > 0) & ~np.isnan(total_flows) & (total_flows != 0))
        t_fl = (flag_date[fi] - start_date).astype(np.float64) / 365.25
        start_gross = start_value + fl0[0]
        cagr = _xirr_rate(np.concatenate([[0.0], t_fl]), np.concatenate([[start_gross], total_flows[fi]]),
                          stopp_worth, ann_factor) if ann_factor > 0 else NA
        if math.isnan(cagr) and ann_factor > 0 and not (math.isfinite(stopp_worth) and stopp_worth < 0):
            _warn(_sp("simulation: geldgewichtete Rendite (cagr) mit Einzahlungen nicht bestimmbar (Startwert %.2f EUR, "
                      "Einzahlungen %.2f EUR, Endwert %.2f EUR): kein interner Zinsfu\u00df gefunden; cagr = NA.",
                      start_gross, r_sum(total_flows[fi]), stopp_worth))
    if tax_unpaid_total > 0:
        open_tax_debt = r_sum([_rmax(0.0, -sim["status"][nm]["money"]) for nm in flag_assets])
    else:
        open_tax_debt = 0.0
    neg_detail = _sp("Endwert %.2f EUR negativ: offene Steuerschuld %.2f EUR", stopp_worth, open_tax_debt) \
        if open_tax_debt > 0 else _sp("Endwert %.2f EUR negativ", stopp_worth)
    if math.isfinite(stopp_worth) and stopp_worth < 0:
        if not has_ext_flows:
            cagr = NA
        if isinstance(ttwror, float) and math.isnan(ttwror):
            ttwror = NA
        _warn(_sp("simulation: Endwert negativ (%.2f EUR, %s); Verlust \u00fcber 100 %%: cagr und ttwror sind nicht definiert "
                  "(NA), Drawdowns auf 100 %% begrenzt.", stopp_worth,
                  _sp("offene Steuerschuld %.2f EUR", open_tax_debt) if open_tax_debt > 0 else
                  "nicht gedeckte Steuerschuld"))
    elif isinstance(ttwror, float) and math.isnan(ttwror) and ann_factor > 0:
        ttwror = NA
        if not (has_ext_flows and np.any(twr_index <= 0)):
            _warn("simulation: zeitgewichteter Wertindex wird negativ (Tagesrendite unter -100 %); ttwror ist nicht "
                  "definiert (NA).")

    def why_na(metric):
        if ann_factor <= 0:
            return ["too_short", "Zeitraum %s, Laufzeit 0 Jahre (Einzeltag)" % _n_tage(n_days_sim)]
        if math.isfinite(stopp_worth) and stopp_worth < 0:
            return ["negative_end_value", neg_detail]
        if metric == "cagr" and has_ext_flows:
            return ["no_irr_solution", _sp("kein interner Zinsfu\u00df: Startwert %.2f EUR, Einzahlungen %.2f EUR, Endwert "
                                           "%.2f EUR", start_gross, r_sum(total_flows[fi]), stopp_worth)]
        if metric == "cagr" and not (start_worth > 0):
            return ["zero_start_value", _sp("Depotwert am Starttag %.2f EUR", start_worth)]
        i0 = np.flatnonzero(twr_index <= 0)
        if i0.size:
            i0 = int(i0[0])
            return ["nonpositive_twr_index", _sp("zeitgewichteter Wertindex am %s nicht positiv (Tagesrendite %.2f %%)",
                                                 fmt_date(int(flag_date[i0])), 100 * period_return[i0])]
        return ["not_finite", "Rechnung ergibt keinen endlichen Wert"]
    why_ret = {"cagr": why_na("cagr") if math.isnan(cagr) else None,
               "ttwror": why_na("ttwror") if math.isnan(ttwror) else None}
    if ann_factor <= 0:
        _warn("simulation: Zeitraum %s (Laufzeit 0 Jahre): cagr und ttwror sind nicht definiert (NA)."
              % _n_tage(n_days_sim))
    elif not has_ext_flows and math.isnan(cagr) and why_ret["cagr"] is not None and why_ret["cagr"][0] == "zero_start_value":
        _warn(_sp("simulation: Depotwert am Starttag %.2f EUR: cagr ist nicht definiert (NA).", start_worth))
    ret_dd = ttwror if has_ext_flows else cagr
    dd_series = twr_index if has_ext_flows else total_worth
    running_max = r_cummax(dd_series)
    with np.errstate(divide="ignore", invalid="ignore"):
        drawdowns = np.where(running_max > 0, (running_max - dd_series) / running_max, 0.0)
    drawdowns = np.where(np.isnan(running_max), NA, drawdowns)
    if has_ext_flows and np.any(twr_index <= 0):
        i0 = int(np.flatnonzero(twr_index <= 0)[0])
        _warn(_sp("simulation: zeitgewichteter Wertindex am %s nicht positiv (Tagesrendite %.2f %% bei Depotwert %.2f EUR "
                  "am Vortag und Einzahlung %.2f EUR); TTWROR und die zeitgewichteten Drawdowns sind nicht "
                  "aussagekr\u00e4ftig (Drawdowns auf 100 %% begrenzt).", fmt_date(int(flag_date[i0])),
                  100 * period_return[i0], total_worth[i0 - 1], total_flows[i0]))
        drawdowns = np.where(np.isnan(drawdowns), drawdowns, np.minimum(drawdowns, 1.0))
    if np.any(drawdowns[~np.isnan(drawdowns)] > 1):
        i0 = int(np.flatnonzero(drawdowns > 1)[0])
        if not (math.isfinite(stopp_worth) and stopp_worth < 0):
            _warn(_sp("simulation: Depotwert am %s negativ (%.2f EUR, Steuerschuld); Drawdowns auf 100 %% begrenzt.",
                      fmt_date(int(flag_date[i0])), total_worth[i0]))
        drawdowns = np.where(np.isnan(drawdowns), drawdowns, np.minimum(drawdowns, 1.0))
    dd_ok = drawdowns[~np.isnan(drawdowns)]
    max_drawdown = float(dd_ok.max()) if dd_ok.size else -math.inf
    if not math.isfinite(max_drawdown):
        max_drawdown = 0.0
    with np.errstate(divide="ignore", invalid="ignore"):
        portfolio_returns = np.diff(total_worth) / total_worth[:-1]
    portfolio_returns[~np.isfinite(portfolio_returns)] = 0.0
    ttwror_returns = period_return[1:].copy()
    ttwror_returns[~np.isfinite(ttwror_returns)] = 0.0
    has_flows = bool(np.any(total_flows[~np.isnan(total_flows)] != 0))
    risk_returns = ttwror_returns if has_flows else portfolio_returns
    if flag_filled.size == risk_returns.size + 1:
        returns_filled_mask = flag_filled[1:]
    else:
        returns_filled_mask = np.zeros(risk_returns.size, dtype=bool)
    if returns_filled_mask.size == risk_returns.size and returns_filled_mask.any():
        risk_returns = risk_returns[~returns_filled_mask]
    ann_periods = risk_returns.size / ann_factor if (ann_factor > 0 and risk_returns.size > 0) else 365.25
    return {"total_worth": total_worth, "twr_index": twr_index, "invested": invested, "has_ext_flows": has_ext_flows,
            "cagr": cagr, "ttwror": ttwror, "why_ret": why_ret, "open_tax_debt": open_tax_debt, "ret_dd": ret_dd,
            "dd_series": dd_series, "running_max": running_max, "drawdowns": drawdowns, "max_drawdown": max_drawdown,
            "risk_returns": risk_returns, "returns_filled_mask": returns_filled_mask, "ann_factor": ann_factor,
            "ann_periods": ann_periods, "n_days_sim": n_days_sim}


def _sim_risk_stats(r: dict, risk_free, fr: _Frame) -> dict:
    risk_returns = r["risk_returns"]
    mask = r["returns_filled_mask"]
    days_per_year = r["ann_periods"]
    n_days_sim = r["n_days_sim"]
    drawdowns, dd_series, running_max = r["drawdowns"], r["dd_series"], r["running_max"]
    max_drawdown, ret_dd = r["max_drawdown"], r["ret_dd"]
    daily_mean = r_mean(risk_returns, na_rm=True)
    daily_sd = r_sd(risk_returns, na_rm=True)
    if not math.isfinite(daily_mean):
        daily_mean = 0.0
    if not math.isfinite(daily_sd):
        daily_sd = 0.0
    daily_cv = abs(daily_sd / daily_mean) if daily_mean != 0 else NA
    if risk_free is None:
        risk_free = 0
    if isinstance(risk_free, str):
        if risk_free not in fr:
            _stop("risk_free: Spalte '%s' fehlt im Datensatz." % risk_free)
        col = fr.get(risk_free)
        rf_full = np.array(col, dtype=np.float64) if fr.is_numeric(risk_free) else \
            np.array([NA if _isna(v) else (float(v) if _is_num(v) else NA) for v in col], dtype=np.float64)
    else:
        rf_full = np.full(n_days_sim, float(risk_free))
    rf_full[~np.isfinite(rf_full)] = 0.0
    rf_full = rf_full / 100
    rf_returns = rf_full[1:] if rf_full.size >= 2 else np.zeros(0)
    if mask.size == rf_returns.size and mask.any():
        rf_returns = rf_returns[~mask]
    if rf_returns.size != risk_returns.size:
        rf_returns = np.full(risk_returns.size, r_mean(rf_returns) if rf_returns.size else 0.0)
    rf_daily = r_pow_vec(1 + rf_returns, 1 / days_per_year) - 1
    excess = risk_returns - rf_daily
    rf_effective = r_mean(rf_returns) * 100 if rf_returns.size else 0.0
    mean_excess = r_mean(excess, na_rm=True)
    sd_excess = r_sd(excess, na_rm=True)
    if not math.isfinite(mean_excess):
        mean_excess = 0.0
    if not math.isfinite(sd_excess):
        sd_excess = 0.0
    downside = excess[excess < 0]
    if downside.size > 0:
        dmin = np.minimum(excess, 0.0)
        downside_sd_excess = math.sqrt(r_mean(dmin * dmin, na_rm=True))
    else:
        downside_sd_excess = 0.0
    sqrt_dpy = math.sqrt(days_per_year)
    sharpe = (mean_excess * days_per_year) / (sd_excess * sqrt_dpy) if sd_excess > 0 else NA
    sortino = (mean_excess * days_per_year) / (downside_sd_excess * sqrt_dpy) if downside_sd_excess > 0 else NA
    calmar = ret_dd / max_drawdown if (max_drawdown > 0 and not math.isnan(ret_dd)) else NA
    ulcer_index = math.sqrt(r_mean(drawdowns * drawdowns, na_rm=True)) if drawdowns.size else NA
    if not math.isfinite(ulcer_index):
        ulcer_index = 0.0
    martin_ratio = ret_dd / ulcer_index if (ulcer_index > 0 and not math.isnan(ret_dd)) else NA
    serenity = ret_dd / (ulcer_index * max_drawdown) if (ulcer_index > 0 and max_drawdown > 0
                                                         and not math.isnan(ret_dd)) else NA
    gains = r_sum(risk_returns[risk_returns > 0], na_rm=True)
    losses = abs(r_sum(risk_returns[risk_returns < 0], na_rm=True))
    omega = gains / losses if losses > 0 else NA
    gain_to_pain = r_sum(risk_returns, na_rm=True) / losses if losses > 0 else NA
    dd_active = drawdowns[drawdowns > 0]
    average_drawdown = r_mean(dd_active) if dd_active.size > 0 else 0.0
    longest_dd = 0
    current_dd = 0
    recovery_times: list = []
    in_dd = False
    dd_start = 0
    for i in range(dd_series.size):
        below = dd_series[i] < running_max[i]
        if below:
            current_dd += 1
            if current_dd > longest_dd:
                longest_dd = current_dd
        else:
            current_dd = 0
        if below:
            if not in_dd:
                dd_start = i + 1
                in_dd = True
        elif in_dd:
            recovery_times.append((i + 1) - dd_start)
            in_dd = False
    avg_recovery_time = r_mean_int(recovery_times) if recovery_times else NA
    statistics = {
        "mean": daily_mean, "sd": daily_sd, "cv": daily_cv, "risk_free": rf_effective,
        "skewness": _calculate_skewness(risk_returns), "kurtosis": _calculate_kurtosis(risk_returns),
        "lpm": _calculate_partials(risk_returns, lower=True), "hpm": _calculate_partials(risk_returns, lower=False),
        "sharpe": sharpe, "sortino": sortino, "calmar": calmar, "omega": omega, "gain_to_pain": gain_to_pain,
        "serenity": serenity, "martin_ratio": martin_ratio, "max_drawdown": max_drawdown,
        "average_drawdown": average_drawdown, "ulcer_index": ulcer_index, "longest_drawdown": int(longest_dd),
        "avg_recovery_time": avg_recovery_time,
    }
    return {"statistics": statistics, "longest_dd": longest_dd}


def _sim_undefined_metrics(r: dict, rs: dict, trades: dict, flag_assets: list) -> dict:
    n_r = r["risk_returns"].size
    why_ret, ret_dd, ann_factor, n_days_sim = r["why_ret"], r["ret_dd"], r["ann_factor"], r["n_days_sim"]
    statistics, longest_dd = rs["statistics"], rs["longest_dd"]

    def few(k):
        return ["too_short", "keine Tagesrendite (Einzeltag)" if n_r == 0 else
                "nur %d %s, mindestens %d n\u00f6tig" % (n_r, "Tagesrendite" if n_r == 1 else "Tagesrenditen", k)]
    ret_name = "ttwror" if r["has_ext_flows"] else "cagr"

    def inherit():
        w = why_ret[ret_name]
        return [w[0], "%s nicht definiert: %s" % (ret_name, w[1])]
    no_dd = ["no_drawdown", "kein Drawdown im Zeitraum (max_drawdown 0)"]
    zero_vol = ["zero_volatility", "Standardabweichung der %d Tagesrenditen ist 0 (konstanter Verlauf)" % n_r]
    rd_na = isinstance(ret_dd, float) and math.isnan(ret_dd)

    def why_stat(m):
        if m == "cv":
            return few(1) if n_r == 0 else ["zero_mean_return", "mittlere Tagesrendite ist 0"]
        if m == "skewness":
            return few(3) if n_r < 3 else zero_vol
        if m == "kurtosis":
            return few(4) if n_r < 4 else zero_vol
        if m in ("lpm", "hpm"):
            return few(1)
        if m == "sharpe":
            return few(2) if n_r < 2 else ["zero_volatility",
                                           "Standardabweichung der %d \u00dcberschussrenditen ist 0" % n_r]
        if m == "sortino":
            return few(1) if n_r < 1 else ["no_negative_returns",
                                           "keine negativen \u00dcberschussrenditen (Downside-Abweichung 0)"]
        if m in ("calmar", "serenity"):
            return inherit() if rd_na else no_dd
        if m in ("omega", "gain_to_pain"):
            return few(1) if n_r < 1 else ["no_negative_returns", "keine negativen Tagesrenditen"]
        if m == "martin_ratio":
            return inherit() if rd_na else ["no_drawdown", "kein Drawdown im Zeitraum (Ulcer Index 0)"]
        if m == "avg_recovery_time":
            if ann_factor <= 0:
                return ["too_short", "Zeitraum %s, Laufzeit 0 Jahre (Einzeltag)" % _n_tage(n_days_sim)]
            return ["no_recovery", "kein Drawdown im Zeitraum" if longest_dd == 0 else
                    "Drawdown bis zum Ende nicht aufgeholt (l\u00e4ngster Drawdown %s)" % _n_tage(longest_dd)]
        return ["not_finite", "Rechnung ergibt keinen endlichen Wert"]
    buys = pd.Series({x: (len(trades[x]["buys"]) / ann_factor if ann_factor > 0 else NA) for x in flag_assets},
                     dtype=np.float64)
    sells = pd.Series({x: (len(trades[x]["sells"]) / ann_factor if ann_factor > 0 else NA) for x in flag_assets},
                      dtype=np.float64)
    um: dict = {}
    for m in ("cagr", "ttwror"):
        if math.isnan(r[m]):
            um[m] = why_ret[m]
    for m, v in statistics.items():
        if isinstance(v, float) and math.isnan(v):
            um[m] = why_stat(m)
    for m, v in (("buys", buys), ("sells", sells)):
        if v.isna().any():
            um[m] = ["too_short", "Zeitraum %s, Laufzeit 0 Jahre: keine Anzahl je Jahr (Einzeltag)" % _n_tage(n_days_sim)]
    undefined_metrics = pd.DataFrame({"metric": pd.Series(list(um.keys()), dtype=object),
                                      "reason": pd.Series([v[0] for v in um.values()], dtype=object),
                                      "detail": pd.Series([v[1] for v in um.values()], dtype=object)})
    return {"undefined_metrics": undefined_metrics, "buys": buys, "sells": sells}


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
