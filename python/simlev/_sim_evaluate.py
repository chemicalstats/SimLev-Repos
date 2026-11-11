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
from ._meldungen import EVAL_DETAIL as _MV, EVAL_WARN as _MW
from ._r.rexpr import as_numeric
from ._r.rnum import NA_REAL as NA  # R's NA_real_ (Nutzlast 1954)
from ._sim_base import (
    _FEE,
    _Frame,
    _is_num,
    _is_true,
    _isna,
    _rmax,
    _sp,
    _stop,
    _warn,
)
from ._util import _n_tage


# Phase 6: Auswertung (sim_evaluate.R)
# ═══════════════════════════════════════════════════════════════════════════

def _sim_compact_trades(sim: dict, flag_assets: list) -> dict:
    """Je Asset die flachen Felder (Lots, Verkäufe, Steuern) des Kerns; Dicts erst in ``SimLevResult.trades``."""
    return {nm: sim["trades"][nm]["raw"] for nm in flag_assets}


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
_XIRR_WARN = {k: _MW[str(k)] for k in (1, 2, 3)}
# Ursachen ohne Werte (Text fest)
_EVAL_FIXED = {k: _MV[str(k)] for k in (6, 7, 9, 11, 13, 14, 15, 16)}


def _eval_detail(d: int, v, why_text) -> str:
    """Klartext einer Ursache (enum Detail in core/evaluate_core_impl.h); Texte aus ``_meldungen.EVAL_DETAIL``."""
    m = _MV
    if d == 0:
        return m["0"] % _n_tage(int(v[0]))
    if d == 1:
        return _sp(m["1"], v[0])
    if d == 2:
        return _sp(m["2"], v[0], v[1])
    if d == 3:
        return _sp(m["3"], v[0], v[1], v[2])
    if d == 4:
        return _sp(m["4"], v[0])
    if d == 5:
        return _sp(m["5"], fmt_date(int(v[0])), v[1])
    if d == 8:
        k = int(v[0])
        return m["8"] % (k, m["8.eins"] if k == 1 else m["8.mehr"], int(v[1]))
    if d == 10:
        return m["10"] % int(v[0])
    if d == 12:
        return m["12"] % int(v[0])
    if d == 17:
        return m["17"] % _n_tage(int(v[0]))
    if d == 18:
        return m["18"] % _n_tage(int(v[0]))
    if d == 19:
        k = int(v[0])
        return m["19"] % (_EVAL_METRICS[k], why_text[k])
    return _EVAL_FIXED[d]


def _eval_warn(code: int, v) -> None:
    """Warnung der Auswertung (Code des Kerns) mit dem Text von R; Texte aus ``_meldungen.EVAL_WARN``."""
    m = _MW
    if code in _XIRR_WARN:
        _warn(_XIRR_WARN[code])
    elif code == 10:
        _warn(_sp(m["10"], v[0], v[1], v[2]))
    elif code == 11:
        _warn(_sp(m["11"], v[0], _sp(m["11.offen"], v[1]) if v[1] > 0 else m["11.ungedeckt"]))
    elif code == 12:
        _warn(m["12"])
    elif code == 13:
        _warn(m["13"] % _n_tage(int(v[0])))
    elif code == 14:
        _warn(_sp(m["14"], v[0]))
    elif code == 15:
        _warn(_sp(m["15"], fmt_date(int(v[0])), v[1], v[2], v[3]))
    elif code == 16:
        _warn(_sp(m["16"], fmt_date(int(v[0])), v[1]))
    elif code == 17:
        _warn(m["17"])
    else:
        _stop(m["unbekannt"] % code)


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
        _f64([sim["status"][a]["money"] for a in nm]), _f64([len(trades[a][0]) for a in nm]),
        _f64([len(trades[a][1]) for a in nm]), rf, int(rf_err is None))
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
    # seit 1.6.4 (K43 T1-R10) ohne Zwischen-Series (je kleinem Lauf rund 0,2 ms weniger); dtype=object ist Pflicht
    # (pandas 3 macht aus Text sonst StringDtype), gleiche Spalten, Typen und Index wie bis dahin
    undefined_metrics = pd.DataFrame({"metric": [_EVAL_METRICS[u[0]] for u in um],
                                      "reason": [_EVAL_REASONS[u[1]] for u in um],
                                      "detail": [_eval_detail(u[2], u[3:], why_text) for u in um]}, dtype=object)
    r = {"total_worth": np.frombuffer(tw, dtype=np.float64), "twr_index": np.frombuffer(twr, dtype=np.float64),
         "invested": np.frombuffer(inv, dtype=np.float64), "has_ext_flows": bool(has_ext), "cagr": scal[0],
         "ttwror": scal[1], "open_tax_debt": scal[2], "drawdowns": np.frombuffer(dd, dtype=np.float64)}
    # je ein eigener Index wie index=list(nm) (ein gemeinsamer teilte Attribute wie den Namen)
    um_ = {"undefined_metrics": undefined_metrics,
           "buys": pd.Series(np.frombuffer(buys, dtype=np.float64).copy(), index=pd.Index(list(nm)), copy=False),
           "sells": pd.Series(np.frombuffer(sells, dtype=np.float64).copy(), index=pd.Index(list(nm)), copy=False)}
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
            lv = trades[nm][0]
            ol = lv[lv[:, 3] > 0]   # offene Lots (remaining > 0; NaN zählt nicht), FIFO-Reihenfolge
            sp_ = strategy[nm].get("spread")
            open_lots[nm] = {
                # seit 1.6.4 (A-056) direkt aus den Feldern (bis 1.6.3 über je eine pd.Series; gleiche Tabelle)
                "lots": pd.DataFrame({
                    "date": ol[:, 0].astype(np.int64).astype("datetime64[D]"),
                    "units": ol[:, 3].astype(np.float64, copy=True),
                    "price": ol[:, 2].astype(np.float64, copy=True),
                    "vp": np.where(ol[:, 6] != 0, ol[:, 5], 0.0).astype(np.float64, copy=False)}),
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
