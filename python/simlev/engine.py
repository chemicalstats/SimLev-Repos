"""Backtest-Engine (Port von ``simulation()`` aus simulation.R).

Die Struktur folgt bewusst eng dem R-Original, damit beide Implementierungen
Zeile für Zeile vergleichbar bleiben und bitgleich rechnen.
"""
from __future__ import annotations

import math
import sys
import warnings
from typing import Any, Mapping, Sequence

import numpy as np

from . import _core as core
from ._dates import (
    add_months_first,
    dates_to_days,
    days_from_civil,
    first_of_month,
    fmt_date,
    from_days,
    r_strptime_ymd,
    to_days,
    year_of,
    ym_key,
)
from ._rnum import (
    LD,
    r_mean,
    r_mean_int,
    r_mod1,
    r_pow,
    r_pow_vec,
    r_prod,
    r_rowsums,
    r_sd,
    r_sum,
)
from .config import _match_arg

__all__ = ["simulation"]

NA = float("nan")


def _cat(text: str) -> None:
    sys.stdout.write(text)


def _rmin(a: float, b: float) -> float:
    """R ``min(a, b)`` für zwei Skalare."""
    return b if b < a else a


def _rmax(a: float, b: float) -> float:
    """R ``max(a, b)`` für zwei Skalare."""
    return b if b > a else a


def _isna(x: Any) -> bool:
    return x is None or (isinstance(x, float) and math.isnan(x))


def _get(m: Mapping[str, Any], key: str, default: Any = None) -> Any:
    v = m.get(key) if isinstance(m, Mapping) else None
    return default if v is None else v


def _fmt_num(x: float) -> str:
    return "%.2f" % x


# ═══════════════════════════════════════════════════════════════════════════
# Datenvorbereitung
# ═══════════════════════════════════════════════════════════════════════════

class _Data:
    """Spaltenorientierte Sicht auf die Eingabedaten (nach R-Semantik)."""

    def __init__(self, data: Any):
        if data is None:
            raise ValueError("'data' must be a data.frame")
        if hasattr(data, "columns"):
            names = [str(c) for c in data.columns]
            raw = {str(c): data[c].to_numpy() if hasattr(data[c], "to_numpy") else np.asarray(data[c])
                   for c in data.columns}
        elif isinstance(data, Mapping):
            names = [str(k) for k in data.keys()]
            raw = {str(k): np.asarray(v) for k, v in data.items()}
        else:
            raise ValueError("'data' must be a data.frame")
        if "date" not in raw:
            raise ValueError("'data' must contain a 'date' column")
        self.names = names
        self.cols: dict[str, np.ndarray] = {}
        self.kind: dict[str, str] = {}
        for nm in names:
            v = raw[nm]
            if nm == "date":
                self.cols[nm] = dates_to_days(v)
                self.kind[nm] = "date"
                continue
            k, arr = self._classify(v)
            self.cols[nm] = arr
            self.kind[nm] = k
        lens = {len(a) for a in self.cols.values()}
        if len(lens) != 1:
            raise ValueError("all columns of 'data' must have the same length")
        self.nrow = lens.pop()

    @staticmethod
    def _classify(v: np.ndarray) -> tuple[str, np.ndarray]:
        if v.dtype.kind == "b":
            return "logical", v.astype(object)
        if v.dtype.kind in "iuf":
            return "numeric", v.astype(np.float64)
        if v.dtype.kind == "O":
            vals = [x for x in v if not _isna(x)]
            if vals and all(isinstance(x, (bool, np.bool_)) for x in vals):
                return "logical", np.array([None if _isna(x) else bool(x) for x in v], dtype=object)
            if vals and all(isinstance(x, (int, float, np.integer, np.floating)) and not isinstance(x, (bool, np.bool_))
                            for x in vals):
                return "numeric", np.array([NA if _isna(x) else float(x) for x in v], dtype=np.float64)
            if not vals:
                return "logical", np.array([None] * len(v), dtype=object)
        return "other", v.astype(object)

    def __contains__(self, name: str) -> bool:
        return name in self.cols

    def get(self, name: str):
        return self.cols.get(name)


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


def _fill_calendar(d: _Data) -> None:
    dates = d.cols["date"]
    start, stop = int(dates[0]), int(dates[-1])
    all_dates = np.arange(start, stop + 1, dtype=np.int64)
    pos = {}
    for i, z in enumerate(dates):
        z = int(z)
        if start <= z <= stop:
            if z in pos:
                raise ValueError("doppelte Datumswerte in 'data' werden nicht unterstützt")
            pos[z] = i
    n = all_dates.size
    src = np.full(n, -1, dtype=np.int64)
    for j, z in enumerate(all_dates):
        src[j] = pos.get(int(z), -1)
    filled = src < 0
    new_cols: dict[str, np.ndarray] = {"date": all_dates}
    for nm in d.names:
        if nm == "date":
            continue
        v = d.cols[nm]
        k = d.kind[nm]
        if k == "numeric":
            out = np.full(n, NA, dtype=np.float64)
            out[~filled] = v[src[~filled]]
            out = _locf_fill(out)
        else:
            out = np.empty(n, dtype=object)
            out[:] = None
            for j in np.flatnonzero(~filled):
                out[j] = v[src[j]]
            if k == "logical":
                out = np.array([False if x is None else x for x in out], dtype=object)
        new_cols[nm] = out
    d.cols = new_cols
    d.nrow = n
    d.filled = filled


def _as_logical(v: np.ndarray) -> np.ndarray:
    """``as.logical()`` für eine Spalte; NA -> False (für Event-Flags)."""
    out = np.zeros(len(v), dtype=bool)
    for i, x in enumerate(v):
        if _isna(x):
            out[i] = False
        elif isinstance(x, (bool, np.bool_)):
            out[i] = bool(x)
        elif isinstance(x, (int, float, np.integer, np.floating)):
            out[i] = x != 0
        elif isinstance(x, str):
            out[i] = x in ("TRUE", "true", "T", "True")
        else:
            out[i] = bool(x)
    return out


def _truthy(x: Any) -> bool:
    """Wert eines Signals in ``&&``-Ausdrücken (R: nicht-null -> TRUE)."""
    if _isna(x):
        return False
    return bool(x)


def _is_true(x: Any) -> bool:
    """R ``isTRUE()``: nur ein echtes logisches TRUE zählt."""
    return isinstance(x, (bool, np.bool_)) and bool(x)


# ═══════════════════════════════════════════════════════════════════════════
# Flag-Hilfsfunktionen
# ═══════════════════════════════════════════════════════════════════════════

def _calculate_dates_flags(mode, span, unit, days, dates, value, anchor, start_date,
                           skip_start, liquidate) -> np.ndarray:
    n = dates.size
    if not mode or unit is None or (value is not None and value <= 0):
        return np.zeros(n, dtype=bool)
    if span is None:
        span = 1
    unit = _match_arg(unit, ("month", "quarter", "year"), "unit")
    anchor = _match_arg(anchor, ("start", "end"), "anchor")
    dmin, dmax = int(dates.min()), int(dates.max())
    start = dmin if start_date is None else to_days(start_date)
    day_list = None
    if days is not None:
        day_list = list(np.atleast_1d(np.asarray(days, dtype=object)))

    schedule: list[float] = []

    def months_seq(step: int) -> list[int]:
        f = first_of_month(start)
        out = []
        if f > dmax:
            return out
        k = 0
        while True:
            z = add_months_first(f, k * step)
            if z > dmax:
                break
            out.append(z)
            k += 1
        return out

    if unit in ("month", "quarter"):
        step = int(span) * (3 if unit == "quarter" else 1)
        base_seq = months_seq(step)
        if day_list is None:
            schedule = [float(z) for z in base_seq]
        else:
            for z in base_seq:
                yr, mon = from_days(z).year, from_days(z).month
                for dd in day_list:
                    if anchor == "start":
                        r = r_strptime_ymd(yr, mon, dd)
                        schedule.append(NA if r is None else float(r))
                    else:
                        if unit == "month":
                            if mon == 12:
                                end = days_from_civil(yr + 1, 1, 1) - 1
                            else:
                                end = days_from_civil(yr, mon + 1, 1) - 1
                        else:
                            end_mon, end_yr = mon + 3, yr
                            if end_mon > 12:
                                end_mon -= 12
                                end_yr = yr + 1
                            end = days_from_civil(end_yr, end_mon, 1) - 1
                        schedule.append(float(end) - (float(dd) - 1))
    else:
        y0 = year_of(start)
        base_years = []
        if days_from_civil(y0, 1, 1) <= dmax:
            y = y0
            while days_from_civil(y, 1, 1) <= dmax:
                base_years.append(y)
                y += int(span)
        if day_list is None:
            schedule = [float(days_from_civil(y, 1, 1)) for y in base_years]
        else:
            for y in base_years:
                for dd in day_list:
                    if anchor == "start":
                        r = r_strptime_ymd(y, 1, dd)
                        schedule.append(NA if r is None else float(r))
                    else:
                        schedule.append(float(days_from_civil(y, 12, 31)) - (float(dd) - 1))

    date_set = set(int(z) for z in dates)
    sched = [s for s in schedule if not math.isnan(s) and s == int(s) and int(s) in date_set]
    if skip_start:
        sched = [s for s in sched if s != dmin]
    if liquidate:
        sched = [s for s in sched if s != dmax]
    sset = set(int(s) for s in sched)
    return np.array([int(z) in sset for z in dates], dtype=bool)


def _calculate_split_flags(sim: dict, base: float, mode: bool, dates: np.ndarray,
                           split_thresh) -> np.ndarray:
    n = dates.size
    if not mode or split_thresh is None:
        return np.zeros(n, dtype=bool)
    lo, hi = float(split_thresh[0]), float(split_thresh[1])
    flag = np.zeros(n, dtype=bool)
    for name in sim["market"]:
        prices = np.array(sim["market"][name]["asset_price"], dtype=np.float64)
        for i in range(n):
            cp = float(prices[i])
            if cp > hi:
                flag[i] = True
                ratio = cp / base
                prices[i:] = prices[i:] / ratio
            elif cp < lo:
                flag[i] = True
                ratio = base / cp
                prices[i:] = prices[i:] * ratio
    return flag


def _shift_off_filled(flags: np.ndarray, filled: np.ndarray, mon: list) -> np.ndarray:
    hit = np.flatnonzero(flags & filled)
    if hit.size == 0:
        return flags
    flags = flags.copy()
    n = flags.size
    for i in hit:
        j = i + 1
        while j < n and filled[j]:
            j += 1
        if j >= n or mon[j] != mon[i]:
            j = i - 1
            while j >= 0 and filled[j]:
                j -= 1
        flags[i] = False
        if 0 <= j < n:
            flags[j] = True
    return flags


# ═══════════════════════════════════════════════════════════════════════════
# Handels- und Steuerfunktionen
# ═══════════════════════════════════════════════════════════════════════════

def _apply_spread(price: float, spread: float, direction: str) -> float:
    if direction == "buy":
        return price * (1 + spread / 2)
    return price * (1 - spread / 2)


def _calculate_buy_signal(sim: dict, name: str, index: int) -> bool:
    a = sim["assets"][name]
    st = sim["status"][name]
    sig = False
    if a["style"] == "signal" and _truthy(sim["market"][name]["signal_buy"][index - 1]) \
            and st["money"] > 0 and st["count"] == 0:
        sig = True
    if a["style"] == "bnh" and st["money"] > 0:
        sig = True
    return sig


def _calculate_sell_signal(sim: dict, name: str, index: int) -> bool:
    a = sim["assets"][name]
    sig = False
    if a["style"] == "signal" and _truthy(sim["market"][name]["signal_sell"][index - 1]) \
            and sim["status"][name]["count"] > 0:
        sig = True
    if a["style"] == "bnh":
        sig = False
    return sig


def _perform_trade_buy(sim: dict, name: str, index: int, reason: str, spread: float,
                       fractions: bool, details: bool, count: float | None = None) -> dict:
    market_price = float(sim["market"][name]["asset_price"][index - 1])
    if math.isnan(market_price) or market_price <= 0:
        warnings.warn("Invalid market price (%.4f) for %s on %s - skipping trade"
                      % (market_price, name, fmt_date(sim["market"][name]["asset_day"][index - 1])))
        return sim
    trade_price = _apply_spread(market_price, spread, "buy")
    if count is None:
        money = sim["status"][name]["money"]
        trade_count = money / trade_price if fractions else float(math.floor(money / trade_price))
    else:
        trade_count = count
    if trade_count <= 0:
        return sim
    core.perform_trade_buy_cpp(sim, name, index, trade_count, trade_price, market_price)
    if details:
        _cat("%s\tBuying %.2fx %s at %.2f EUR per share on %s\n"
             % (reason, trade_count, name, trade_price, fmt_date(sim["market"][name]["asset_day"][index - 1])))
    return sim


def _perform_trade_sell(sim: dict, name: str, index: int, tax_mode: str, tax_rate: float,
                        effective_tax_rate: float | None, marginal_tax_rate, private_sale_threshold,
                        use_sparer_pauschbetrag: bool, tax_regime: str | None, reason: str,
                        spread: float, details: bool, count: float | None = None,
                        price: float | None = None) -> dict:
    if effective_tax_rate is None:
        effective_tax_rate = tax_rate
    market_price = float(sim["market"][name]["asset_price"][index - 1])
    trade_price = _apply_spread(market_price, spread, "sell")
    current_date = int(sim["market"][name]["asset_day"][index - 1])

    available = sim["status"][name]["count"]
    if count is None:
        trade_count = available
    else:
        if count > available:
            warnings.warn("Requested sell count (%.4f) exceeds available (%.4f) for %s. Selling all."
                          % (count, available, name))
        trade_count = _rmin(count, available)
    if trade_count <= 0:
        return sim

    tr = sim["trades"][name]
    if price is None and tax_mode == "person":
        fifo_price = core.calculate_fifo_price(tr["buys"], trade_count, int(tr["fifo_front"]))
    else:
        fifo_price = 0.0 if price is None else price

    trade_gain = (trade_price - fifo_price) * trade_count
    capital_gains_tax = 0.0
    if tax_regime is None:
        tax_regime = "none"
    lot_result = None

    if tax_mode == "person":
        if tax_regime == "none":
            tax_regime = sim["assets"][name]["tax_regime"]
        totals = sim["totals"]
        if tax_regime == "investment_fund":
            bonus = sim["assets"][name]["bonus"]
            vp_paid = core.calculate_fifo_vorabpauschale(tr["buys"], trade_count, int(tr["fifo_front"]))
            adjusted = trade_gain - vp_paid
            res = core.p20_tax(adjusted, bonus, totals, effective_tax_rate, use_sparer_pauschbetrag)
            capital_gains_tax = res["tax"]
            if details:
                if vp_paid > 0:
                    _cat("\t\t=> Vorabpauschale-Anrechnung (§ 19 InvStG): %.2f EUR\n" % vp_paid)
                if res["spb_used"] > 0:
                    _cat("\t\t=> Sparerpauschbetrag: %.2f EUR (verbleibend: %.2f EUR)\n"
                         % (res["spb_used"], totals["sparer_pauschbetrag_remaining"]))
        elif tax_regime == "capital_gains":
            res = core.p20_tax(trade_gain, 0, totals, effective_tax_rate, use_sparer_pauschbetrag)
            capital_gains_tax = res["tax"]
        elif tax_regime == "private_sale":
            lot_result = core.calculate_private_sale_tax(tr["buys"], int(tr["fifo_front"]),
                                                         trade_count, trade_price, current_date)
            if details:
                if lot_result["exempt_gain"] > 0:
                    _cat("\t\t=> Tax-exempt gain (held > 1 year): %.2f EUR\n" % lot_result["exempt_gain"])
                if lot_result["exempt_loss"] > 0:
                    _cat("\t\t=> Non-deductible loss (held > 1 year): %.2f EUR\n" % lot_result["exempt_loss"])
            if lot_result["taxable_gain"] > 0:
                totals["private_sale_gains_ytd"] = totals["private_sale_gains_ytd"] + lot_result["taxable_gain"]
                if details:
                    _cat("\t\t=> Taxable gain (held < 1 year): %.2f EUR (YTD total: %.2f EUR)\n"
                         % (lot_result["taxable_gain"], totals["private_sale_gains_ytd"]))
            if lot_result["taxable_loss"] > 0:
                totals["private_sale_losses_ytd"] = totals["private_sale_losses_ytd"] + lot_result["taxable_loss"]
                if details:
                    _cat("\t\t=> Deductible loss (held < 1 year): %.2f EUR (YTD total: %.2f EUR)\n"
                         % (lot_result["taxable_loss"], totals["private_sale_losses_ytd"]))
            capital_gains_tax = 0.0

    core.calculate_sell_report(sim, name, index, trade_count, trade_price, market_price, capital_gains_tax)
    if tax_mode == "person":
        core.fifo_consume(sim, name, trade_count)

    if details:
        _cat("%s\tSelling %.2fx %s at %.2f EUR per share on %s\n"
             % (reason, trade_count, name, trade_price, fmt_date(current_date)))
        if tax_mode == "person" and tax_regime not in ("none", "private_sale"):
            _cat("\t\t=> Trade %s: %.2f EUR; Tax: %.2f EUR\n"
                 % ("loss" if trade_gain < 0 else "gain", trade_gain, capital_gains_tax))

    person = tax_mode == "person"
    entry = {
        "event_date": current_date,
        "event_type": "Sell",
        "asset_count": trade_count,
        "asset_price": trade_price,
        "event_gain": trade_gain if person else NA,
        "event_taxes": capital_gains_tax if person else NA,
        "tax_regime": tax_regime if person else None,
        "tax_deferred": (tax_regime == "private_sale") if person else False,
        "holding_exempt": (lot_result["exempt_gain"]
                           if person and tax_regime == "private_sale" and lot_result is not None else NA),
    }
    tr["sell_count"] += 1
    tr["sells"].append(entry)
    return sim


def _calculate_sell_count(sim: dict, name: str, target: float, index: int, spread: float,
                          fractions: bool, tax_mode: str, tax_rate: float,
                          tax_regime: str | None = None) -> dict:
    market_price = float(sim["market"][name]["asset_price"][index - 1])
    trade_price = _apply_spread(market_price, spread, "sell")
    total_shares = sim["status"][name]["count"]
    if total_shares <= 0:
        return {"sell_count": 0.0, "fifo_price": 0.0}
    if target <= 0:
        return {"sell_count": 0.0, "fifo_price": 0.0}
    tr = sim["trades"][name]
    if tax_regime is None:
        tax_regime = sim["assets"][name]["tax_regime"]
    tax_regime = tax_regime if tax_mode == "person" else "none"
    bonus = sim["assets"][name]["bonus"] if tax_regime == "investment_fund" else 0.0
    loss_pool = sim["totals"]["loss_capital_gains"]
    regime_code = {"none": 0, "investment_fund": 1, "capital_gains": 2, "private_sale": 3}.get(tax_regime, 0)
    return core.sell_count(tr["buys"], int(tr["fifo_front"]), target, trade_price, total_shares,
                           bool(fractions), regime_code, bonus, loss_pool, tax_rate)


def _calculate_flat_rate(sim: dict, name: str, index: int, dates: np.ndarray,
                         tax_regime: str | None = None) -> dict:
    if tax_regime is None:
        tax_regime = sim["assets"][name]["tax_regime"]
    empty = {"total_vp": 0.0, "lot_indices": [], "lot_vps": []}
    if tax_regime != "investment_fund":
        return empty
    date_index = int(dates[index - 1])
    yr = year_of(date_index)
    start_of_year = days_from_civil(yr, 1, 1)
    end_of_year = days_from_civil(yr, 12, 31)
    raw = float(sim["market"][name]["base_rates"][index - 1]) / 100
    base_rate = _rmax(0.0, raw)
    if base_rate <= 0:
        return empty
    prices = sim["market"][name]["asset_price"]
    market_price = float(prices[index - 1])
    ysi = max(1, int(start_of_year - int(dates[0])) + 1)
    year_start_price = float(prices[ysi - 1])
    tr = sim["trades"][name]
    return core.flat_rate(tr["buys"], int(tr["fifo_front"]), base_rate, year_start_price,
                          market_price, start_of_year, end_of_year)


def _calculate_fund_fees(sim: dict, index: int, dates: np.ndarray, assets: list[str],
                         funds_fee: float, bonus_fee: float, details: bool) -> dict:
    event_date = days_from_civil(year_of(int(dates[index - 1])), 1, 1)
    cur = int(dates[index - 1])
    idx = np.flatnonzero((dates >= event_date) & (dates <= cur))
    if idx.size == 0:
        return {"total_fees": 0.0, "total_value": sim["totals"]["total_value"]}
    daily_rate = r_pow(funds_fee / 100 + 1, 1 / idx.size) - 1
    flat = np.concatenate([sim["report"][a]["total"][idx] for a in assets])
    basic_value = r_sum(flat * daily_rate, na_rm=True)
    total_value = sim["totals"]["total_value"]
    market_value = r_sum([st["total"] for st in sim["status"].values()], na_rm=True)
    if market_value > total_value:
        bonus_value = (market_value - total_value) * (bonus_fee / 100)
        total_value = market_value
    else:
        bonus_value = 0.0
    total_fees = basic_value + bonus_value
    if details:
        _cat("Funds Event:\tPaying funds fees of %.2f EUR on %s\n\t\t=> Basis fee: %.2f EUR; Bonus fee: %.2f EUR\n"
             % (total_fees, fmt_date(cur), basic_value, bonus_value))
    return {"total_fees": total_fees, "total_value": total_value}


def _split(sim: dict, name: str, ratio: float, index: int, fractions: bool, forward: bool) -> dict:
    st = sim["status"][name]
    current_count = st["count"]
    current_price = st["price"]
    current_worth = st["worth"]
    if forward:
        split_count = current_count * ratio
        split_price = current_price / ratio
    else:
        split_count = current_count / ratio
        split_price = current_price * ratio
    split_worth = current_worth
    if not fractions and r_mod1(split_count) != 0:
        split_fract = r_mod1(split_count)
        split_count = float(math.floor(split_count))
        st["money"] = st["money"] + split_fract * split_price
    tr = sim["trades"][name]
    n_lots = tr["buy_count"]
    if n_lots > 0:
        for k in range(n_lots):
            buy = tr["buys"][k]
            if not buy or buy["remaining"] <= 0:
                continue
            if forward:
                new_count = buy["count"] * ratio
                new_price = buy["price"] / ratio
                new_remaining = buy["remaining"] * ratio
                new_original = _get(buy, "original", buy["remaining"]) * ratio
            else:
                new_count = buy["count"] / ratio
                new_price = buy["price"] * ratio
                new_remaining = buy["remaining"] / ratio
                new_original = _get(buy, "original", buy["remaining"]) / ratio
            if not fractions and r_mod1(new_count) != 0:
                fract = r_mod1(new_count)
                new_count = float(math.floor(new_count))
                new_remaining = float(math.floor(new_remaining))
                new_original = float(math.floor(new_original))
                st["money"] = st["money"] + fract * new_price
            new_buy = dict(buy)
            new_buy["count"] = new_count
            new_buy["price"] = new_price
            new_buy["remaining"] = new_remaining
            new_buy["original"] = new_original
            tr["buys"][k] = new_buy
    tr["fifo_front"] = core.update_fifo_front(tr["buys"], 1)
    st["count"] = split_count
    st["price"] = split_price
    st["worth"] = split_worth
    prices = sim["market"][name]["asset_price"]
    if index <= prices.size:
        if forward:
            prices[index - 1:] = prices[index - 1:] / ratio
        else:
            prices[index - 1:] = prices[index - 1:] * ratio
    return sim


def _format_ratio(r: float) -> str:
    s = "%.5g" % r
    return s


def _perform_asset_split(sim: dict, name: str, ratio: float, index: int, type_: str,
                         fractions: bool = True, details: bool = False,
                         current_date: int | None = None) -> dict:
    if type_ not in ("forward", "reverse"):
        raise ValueError("'type' must be either 'forward' or 'reverse'")
    if ratio <= 0:
        raise ValueError("'ratio' must be positive")
    sim = _split(sim, name, ratio, index, fractions, forward=(type_ == "forward"))
    if details:
        desc = ("1 : " + _format_ratio(ratio)) if type_ == "forward" else (_format_ratio(ratio) + " : 1")
        action = "Splitting" if type_ == "forward" else "Reverse splitting"
        ds = fmt_date(current_date) if current_date is not None else "(date not provided)"
        _cat("Split Event:\t%s %s via %s on %s\n" % (action, name, desc, ds))
    return sim


def _handle_year_change(sim: dict, current_date: int, marginal_tax_rate, private_sale_threshold,
                        sparer_pauschbetrag, use_sparer_pauschbetrag, soli_factor_income=1.0,
                        effective_tax_rate=None, details=False) -> dict:
    totals = sim["totals"]
    current_year = year_of(current_date)
    stored_year = totals["current_year"]
    if current_year == stored_year:
        return sim
    if details:
        _cat("\n══════════════════════════════════════════════════════════════\n")
        _cat("  JAHRESWECHSEL: %d -> %d\n" % (stored_year, current_year))
        _cat("══════════════════════════════════════════════════════════════\n")
    ytd_gains = totals["private_sale_gains_ytd"]
    ytd_losses = totals["private_sale_losses_ytd"]
    internal_offset = _rmin(ytd_gains, ytd_losses)
    net_ytd_gains = ytd_gains - internal_offset
    net_ytd_losses = ytd_losses - internal_offset
    carry = 0.0
    if net_ytd_gains > 0 and totals["loss_private_sales"] > 0:
        carry = _rmin(net_ytd_gains, totals["loss_private_sales"])
        totals["loss_private_sales"] = totals["loss_private_sales"] - carry
        net_ytd_gains = net_ytd_gains - carry
        if details and carry > 0:
            _cat("  § 23 EStG: Verlustvortrag verwendet: %.2f EUR\n" % carry)
            _cat("             Verbleibender Vortrag: %.2f EUR\n" % totals["loss_private_sales"])
    net_gain = net_ytd_gains
    if details:
        _cat("  § 23 EStG Jahresübersicht %d:\n" % stored_year)
        _cat("    Bruttogewinne (< 1 Jahr):    %10.2f EUR\n" % ytd_gains)
        _cat("    Bruttoverluste (< 1 Jahr):   %10.2f EUR\n" % ytd_losses)
        _cat("    Interne Verrechnung:         %10.2f EUR\n" % internal_offset)
        _cat("    Verlustvortrag-Verrechnung:  %10.2f EUR\n" % carry)
        _cat("    ─────────────────────────────────────────\n")
        _cat("    Netto-Ergebnis:              %10.2f EUR\n" % (net_gain - net_ytd_losses))
    if net_gain > private_sale_threshold:
        if marginal_tax_rate is None:
            warnings.warn("§ 23 EStG: Gewinne (%s EUR) über Freigrenze (%s EUR), aber 'marginal_tax_rate' "
                          "nicht gesetzt.\nVerwende 42%% (Spitzensteuersatz)."
                          % (_fmt_num(net_gain), private_sale_threshold))
            marginal_tax_rate = 0.42
        tax_due = net_gain * marginal_tax_rate * soli_factor_income
        totals["total_taxes"] = totals["total_taxes"] + tax_due
        if details:
            _cat("\n  ⚠ FREIGRENZE ÜBERSCHRITTEN!\n")
            _cat("    Netto-Gewinn %.2f EUR > Freigrenze %.2f EUR\n" % (net_gain, private_sale_threshold))
            _cat("    → GESAMTER Gewinn steuerpflichtig (Freigrenze, kein Freibetrag!)\n")
            soli = (" + %.1f%%%% Soli" % ((soli_factor_income - 1) * 100)) if soli_factor_income > 1 else ""
            _cat("    → Steuersatz: %.1f%%%s\n" % (marginal_tax_rate * 100, soli))
            _cat("    → Steuerlast: %.2f EUR\n" % tax_due)
    elif net_ytd_losses > 0:
        totals["loss_private_sales"] = totals["loss_private_sales"] + net_ytd_losses
        if details:
            _cat("\n  Nettoverlust %.2f EUR → Vortrag ins nächste Jahr\n" % net_ytd_losses)
            _cat("  Gesamter Verlustvortrag: %.2f EUR\n" % totals["loss_private_sales"])
    elif net_gain > 0:
        if details:
            _cat("\n  ✓ Netto-Gewinn %.2f EUR ≤ Freigrenze %.2f EUR → STEUERFREI\n"
                 % (net_gain, private_sale_threshold))
    else:
        if details:
            _cat("\n  Keine steuerpflichtigen § 23 Vorgänge in %d\n" % stored_year)

    if details and use_sparer_pauschbetrag:
        spb_annual = totals["sparer_pauschbetrag_annual"]
        spb_remaining = totals["sparer_pauschbetrag_remaining"]
        _cat("\n  Sparerpauschbetrag %d:\n" % stored_year)
        _cat("    Jahresbetrag:    %10.2f EUR\n" % spb_annual)
        _cat("    Verwendet:       %10.2f EUR\n" % (spb_annual - spb_remaining))
        _cat("    Verfallen:       %10.2f EUR\n" % spb_remaining)

    cgt_loss_added = _get(totals, "cgt_loss_added_ytd", 0.0)
    cgt_loss_used = _get(totals, "cgt_loss_used_ytd", 0.0)
    cgt_base_taxed = _get(totals, "cgt_base_taxed_ytd", 0.0)
    unused_loss = _rmax(0.0, cgt_loss_added - cgt_loss_used)
    unused_loss = _rmin(unused_loss, totals["loss_capital_gains"])
    refund_base = _rmin(unused_loss, cgt_base_taxed)
    if refund_base > 0 and effective_tax_rate is not None and effective_tax_rate > 0:
        refund = refund_base * effective_tax_rate
        names = list(sim["status"].keys())
        w = [float(_get(sim["status"][nm], "actual", 0.0)) for nm in names]
        sw = r_sum(w)
        if sw > 0:
            sw2 = r_sum(w)
            w = [x / sw2 for x in w]
        else:
            w = [1 / len(names)] * len(names)
        for nm, wi in zip(names, w):
            sim["status"][nm]["money"] = sim["status"][nm]["money"] + refund * wi
        totals["total_taxes"] = totals["total_taxes"] - refund
        totals["loss_capital_gains"] = totals["loss_capital_gains"] - refund_base
        if details:
            _cat("  § 20 EStG: Unterjaehrige Verlustverrechnung -> Erstattung %.2f EUR in den Geldbestand\n"
                 % refund)

    totals["private_sale_gains_ytd"] = 0.0
    totals["private_sale_losses_ytd"] = 0.0
    totals["cgt_base_taxed_ytd"] = 0.0
    totals["cgt_loss_added_ytd"] = 0.0
    totals["cgt_loss_used_ytd"] = 0.0
    if use_sparer_pauschbetrag:
        totals["sparer_pauschbetrag_remaining"] = sparer_pauschbetrag
    totals["current_year"] = current_year
    if details:
        _cat("\n  Tracker zurückgesetzt für Jahr %d\n" % current_year)
        _cat("══════════════════════════════════════════════════════════════\n\n")
    return sim


# ═══════════════════════════════════════════════════════════════════════════
# Kennzahlen
# ═══════════════════════════════════════════════════════════════════════════

def _calculate_skewness(x: np.ndarray) -> float:
    x = x[~np.isnan(x)]
    n = x.size
    if n < 3:
        return NA
    mean_x = r_mean(x)
    sd_x = r_sd(x)
    if sd_x == 0:
        return NA
    return (n / ((n - 1.0) * (n - 2.0))) * r_sum(r_pow_vec(x - mean_x, 3.0)) / r_pow(sd_x, 3.0)


def _calculate_kurtosis(x: np.ndarray, excess: bool = True) -> float:
    x = x[~np.isnan(x)]
    n = x.size
    if n < 4:
        return NA
    mean_x = r_mean(x)
    sd_x = r_sd(x)
    if sd_x == 0:
        return NA
    nf = float(n)
    kurt = (nf * (nf + 1)) / ((nf - 1) * (nf - 2) * (nf - 3)) * r_sum(r_pow_vec(x - mean_x, 4.0)) \
        / r_pow(sd_x, 4.0)
    if excess:
        kurt = kurt - (3 * r_pow(nf - 1, 2.0)) / ((nf - 2) * (nf - 3))
    return kurt


def _calculate_partials(returns: np.ndarray, lower: bool) -> float:
    v = np.maximum(0.0, -returns) if lower else np.maximum(0.0, returns)
    return r_mean(v, na_rm=True)


# ═══════════════════════════════════════════════════════════════════════════
# Hauptfunktion
# ═══════════════════════════════════════════════════════════════════════════

def simulation(
    data: Any,
    strategy: Mapping[str, Mapping[str, Any]],
    start_value: float = 10000,
    spread: float | None = None,
    details: bool = False,
    liquidate: bool = False,
    # DCA
    dca_mode: bool = False,
    dca_value: float | None = None,
    dca_span: float | None = None,
    dca_days: Any = None,
    dca_unit: str | Sequence[str] = ("month", "quarter", "year"),
    dca_anchor: str | Sequence[str] = ("start", "end"),
    dca_start: Any = None,
    dca_skip: bool = False,
    # Rebalancing
    balance_mode: bool = False,
    balance_span: float | None = None,
    balance_days: Any = None,
    balance_unit: str | Sequence[str] = ("month", "quarter", "year"),
    balance_anchor: str | Sequence[str] = ("start", "end"),
    balance_start: Any = None,
    balance_skip: bool = False,
    balance_dca: bool = False,
    balance_thresh: float | None = None,
    # Steuern
    tax_mode: str | Sequence[str] = ("none", "person", "funds"),
    tax_rate: float = 26.375,
    marginal_tax_rate: float | None = None,
    use_guenstigerpruefung: bool = False,
    private_sale_threshold: float = 1000,
    sparer_pauschbetrag: float = 1000,
    use_sparer_pauschbetrag: bool = True,
    include_soli_on_income_tax: bool = False,
    soli_rate_income_tax: float = 5.5,
    # Basiszins
    base_rate: float | None = None,
    base_rate_flex: bool = False,
    base_rate_data: str | None = None,
    # Fonds
    funds_fee: float = 0.95,
    bonus_fee: float = 5,
    # Sonstiges
    fractions: bool = True,
    risk_free: float | str | None = 0,
    split_mode: bool = False,
    split_thresh: Sequence[float] | None = None,
    # Ereignisbasiertes Rebalancing
    event_col: str | None = None,
    event_mode: str | Sequence[str] = ("additional", "replace"),
    event_weight: Mapping[str, str] | None = None,
):
    """Backtestet eine Strategie auf täglichen Preisreihen.

    Alle Raten und Schwellen werden **in Prozent** angegeben (``tax_rate=26.375``,
    ``balance_thresh=5``, ``risk_free=2`` …). Die Argumente entsprechen 1:1
    denen von ``simulation()`` im R-Paket SimLev; ``None`` steht für ``NULL``.

    Rückgabe ist ein :class:`simlev.SimLevResult`.
    """
    from .result import SimLevResult  # zirkulären Import vermeiden

    tax_mode = _match_arg(tax_mode, ("none", "person", "funds"), "tax_mode")
    d = _Data(data)
    if strategy is None or len(strategy) == 0:
        raise ValueError("'strategy' must be a non-empty list")
    strategy = {str(k): dict(v) for k, v in strategy.items()}

    if start_value is None or (isinstance(start_value, float) and math.isnan(start_value)):
        start_value = 10000
        sys.stderr.write("Note: Using default start_value = 10000\n")
    if not isinstance(start_value, (int, float, np.integer, np.floating)) or isinstance(start_value, bool) \
            or start_value <= 0:
        raise ValueError("'start_value' must be a positive number")
    start_value = float(start_value)

    if not isinstance(tax_rate, (int, float, np.integer, np.floating)) or tax_rate < 0 or tax_rate > 100:
        raise ValueError("'tax_rate' must be between 0 and 100 percent (e.g., 26.375 for 26.375%)")

    def _is_private(a: Mapping[str, Any]) -> bool:
        return (a.get("tax_regime") == "private_sale" or a.get("asset_class") == "etn_deliverable"
                or (a.get("asset_class") in ("etn", "etc") and a.get("deliverable") is True))

    has_private_sale = any(_is_private(a) for a in strategy.values())
    if has_private_sale and marginal_tax_rate is None:
        warnings.warn("'marginal_tax_rate' not set but private_sale assets present. "
                      "§ 23 EStG gains may not be taxed correctly.")
    if marginal_tax_rate is not None and (marginal_tax_rate < 0 or marginal_tax_rate > 50):
        raise ValueError("'marginal_tax_rate' must be between 0 and 50 percent (e.g., 42 for 42%)")

    tax_rate = float(tax_rate) / 100
    if marginal_tax_rate is not None:
        marginal_tax_rate = float(marginal_tax_rate) / 100
    soli_rate_income_tax = float(soli_rate_income_tax) / 100
    if balance_thresh is not None:
        balance_thresh = float(balance_thresh) / 100

    if dca_mode:
        if dca_value is None or dca_value <= 0:
            raise ValueError("'dca_value' must be positive when dca_mode = TRUE")
        if dca_span is None or dca_span < 1:
            raise ValueError("'dca_span' must be >= 1 when dca_mode = TRUE")

    shares = [a.get("asset_share") for a in strategy.values()]
    total_weight = r_sum([NA if s is None else float(s) for s in shares], na_rm=True)
    if abs(total_weight - 1.0) > 1e-6:
        raise ValueError(
            "Asset-Gewichte (asset_share) summieren sich auf %.4f, müssen aber exakt 1.0 ergeben.\n"
            "  Aktuelle Gewichte: %s" % (total_weight, ", ".join(
                "%s=%.3f" % (k, float(v.get("asset_share"))) for k, v in strategy.items())))

    effective_tax_rate = tax_rate
    if use_guenstigerpruefung:
        if marginal_tax_rate is None:
            warnings.warn("Günstigerprüfung aktiviert, aber 'marginal_tax_rate' nicht gesetzt.\n"
                          "Verwende Standard-Abgeltungsteuer (%s%%).\n"
                          "Setze 'marginal_tax_rate' für korrekte Günstigerprüfung." % round(tax_rate * 100, 2))
        elif marginal_tax_rate < 0.25:
            soli_factor = (1 + soli_rate_income_tax) if include_soli_on_income_tax else 1.0
            effective_tax_rate = marginal_tax_rate * soli_factor
            if details:
                _cat("═══ Günstigerprüfung aktiv ═══\n  Persönlicher Steuersatz: %.2f%%\n  Effektiver Steuersatz: "
                     "%.2f%% (statt %.2f%% Abgeltungsteuer)\n  Ersparnis: %.2f Prozentpunkte\n\n"
                     % (marginal_tax_rate * 100, effective_tax_rate * 100, tax_rate * 100,
                        (tax_rate - effective_tax_rate) * 100))
        else:
            if details:
                _cat("═══ Günstigerprüfung geprüft ═══\n  Persönlicher Steuersatz: %.2f%%\n  Abgeltungsteuer: "
                     "%.2f%% → bleibt günstiger\n\n" % (marginal_tax_rate * 100, tax_rate * 100))

    soli_factor_income = (1 + soli_rate_income_tax) if include_soli_on_income_tax else 1.0

    # ── Datenvorbereitung ──────────────────────────────────────────────────
    start_date = int(d.cols["date"][0])
    stopp_date = int(d.cols["date"][-1])
    expected_days = (stopp_date - start_date) + 1
    d.filled = None
    if d.nrow != expected_days:
        sys.stderr.write("Hinweis: %d Zeilen, erwartet %d Kalendertage. Fehlende Tage werden aufgefuellt "
                         "(LOCF; Signale = FALSE).\n" % (d.nrow, expected_days))
        _fill_calendar(d)
    n_rows = d.nrow

    # ── Speicherobjekte ────────────────────────────────────────────────────
    sim: dict[str, Any] = {
        "assets": {}, "status": {}, "market": {}, "trades": {}, "report": {},
        "totals": {
            "total_value": start_value,
            "total_taxes": 0.0,
            "loss_capital_gains": 0.0,
            "loss_private_sales": 0.0,
            "private_sale_gains_ytd": 0.0,
            "private_sale_losses_ytd": 0.0,
            "sparer_pauschbetrag_annual": sparer_pauschbetrag,
            "sparer_pauschbetrag_remaining": sparer_pauschbetrag if use_sparer_pauschbetrag else 0.0,
            "sparer_pauschbetrag_used_total": 0.0,
            "current_year": year_of(start_date),
            "cgt_base_taxed_ytd": 0.0,
            "cgt_loss_added_ytd": 0.0,
            "cgt_loss_used_ytd": 0.0,
        },
    }
    asset_day = np.arange(start_date, stopp_date + 1, dtype=np.int64)

    for name, a in strategy.items():
        ac = a.get("asset_class")
        deliverable = a.get("deliverable") is True
        regime = a.get("tax_regime")
        if regime is None:
            regime = {
                "etf": "investment_fund",
                "etn": "private_sale" if deliverable else "capital_gains",
                "etc": "private_sale" if deliverable else "capital_gains",
                "certificate": "capital_gains",
                "etn_standard": "capital_gains",
                "etn_deliverable": "private_sale",
            }.get(ac, "capital_gains")
        start_raw = a.get("asset_start")
        sim["assets"][name] = {
            "class": ac,
            "style": a.get("action_type"),
            "start": to_days(start_raw) if start_raw is not None else start_date,
            "tax_regime": regime,
            "bonus": float(_get(a, "asset_bonus", 0)) / 100,
            "deliverable": _get(a, "deliverable", False),
        }
        if a.get("action_type") == "signal":
            sb, ss = a.get("signal_buy"), a.get("signal_sell")
            if sb is None or sb not in d:
                raise ValueError("simulation: signal_buy-Spalte '%s' fehlt im Datensatz (Asset '%s')."
                                 % (sb if sb is not None else "NULL", name))
            if ss is None or ss not in d:
                raise ValueError("simulation: signal_sell-Spalte '%s' fehlt im Datensatz (Asset '%s')."
                                 % (ss if ss is not None else "NULL", name))
        share = float(a.get("asset_share"))
        sim["status"][name] = {
            "count": 0.0, "price": 0.0, "worth": 0.0,
            "money": share * start_value, "total": share * start_value,
            "target": share, "actual": share, "differ": 0.0,
        }
        if base_rate_flex:
            if base_rate_data is None or base_rate_data not in d:
                raise ValueError("base_rate_data column '%s' not found in data" % base_rate_data)
            br = np.array(d.get(base_rate_data), dtype=np.float64)
            br[np.isnan(br)] = 0.0
        else:
            br = np.full(n_rows, float(base_rate) if base_rate is not None else 0.0)
        if name not in d:
            raise ValueError("Preisspalte '%s' fehlt in 'data'" % name)
        price_col = d.get(name)
        prices = np.array(price_col, dtype=np.float64)

        def _signal(col_name):
            # Je Asset eine eigene Kopie (R: copy-on-modify bei Asset-Aktivierung)
            if col_name is None:
                return np.array([False] * n_rows, dtype=object)
            v = d.get(col_name)
            if d.kind[col_name] == "logical":
                return np.array([None if x is None else bool(x) for x in v], dtype=object)
            return np.array(v, dtype=np.float64) if d.kind[col_name] == "numeric" else np.array(v, dtype=object)

        sig_b = _signal(a.get("signal_buy"))
        sig_s = _signal(a.get("signal_sell"))
        sim["market"][name] = {
            "asset_day": asset_day,
            "base_rates": br,
            "asset_price": prices,
            "signal_buy": sig_b,
            "signal_sell": sig_s,
            "spread_rate": float(_get(a, "asset_spread", 0)) / 100,
        }
        sim["trades"][name] = {
            "buys": [], "buy_count": 0, "sells": [], "sell_count": 0,
            "taxes": [], "tax_count": 0, "fees": [], "fee_count": 0, "fifo_front": 1,
        }
        st = sim["status"][name]
        worth0 = np.zeros(n_rows)
        money0 = np.zeros(n_rows)
        total0 = np.zeros(n_rows)
        if n_rows > 0:
            worth0[0] = st["worth"]
            money0[0] = st["money"]
            total0[0] = st["total"]
        sim["report"][name] = {
            "worth": worth0, "money": money0, "flows": np.zeros(n_rows),
            "total": total0, "share": np.zeros(n_rows),
        }

    # ── Flags ──────────────────────────────────────────────────────────────
    flag_date = asset_day
    n = flag_date.size
    flag_filled = np.asarray(d.filled, dtype=bool) if d.filled is not None else np.zeros(n, dtype=bool)
    flag_assets = list(strategy.keys())
    flag_liquidate = (flag_date == stopp_date) & bool(liquidate)
    flag_rebalance = _calculate_dates_flags(balance_mode, balance_span, balance_unit, balance_days, flag_date,
                                            None, balance_anchor, balance_start, balance_skip, liquidate)
    flag_dca = _calculate_dates_flags(dca_mode, dca_span, dca_unit, dca_days, flag_date, dca_value,
                                      dca_anchor, dca_start, dca_skip, liquidate)
    md = [from_days(z) for z in flag_date]
    flag_taxes = np.array([x.month == 12 and x.day == 31 for x in md], dtype=bool)
    event_mode = _match_arg(event_mode, ("additional", "replace"), "event_mode")
    flag_event = np.zeros(n, dtype=bool)
    if event_col is not None:
        if event_col not in d:
            raise ValueError("simulation: event_col '%s' nicht im Datensatz gefunden." % event_col)
        flag_event = _as_logical(d.get(event_col))
        guard = (flag_date != flag_date[0]) & ((not liquidate) | (flag_date != stopp_date))
        flag_event = flag_event & guard
        if event_mode == "additional":
            flag_rebalance = flag_rebalance | flag_event
        else:
            flag_rebalance = flag_event.copy()

    flag_trade = ~flag_rebalance & (flag_date != stopp_date) & ~flag_filled
    flag_split = _calculate_split_flags(sim, 100.0, split_mode, flag_date, split_thresh)

    mon = [ym_key(z) for z in flag_date]
    if flag_filled.any():
        flag_rebalance = _shift_off_filled(flag_rebalance, flag_filled, mon)
        flag_dca = _shift_off_filled(flag_dca, flag_filled, mon)
        flag_split = _shift_off_filled(flag_split, flag_filled, mon)
        flag_liquidate = _shift_off_filled(flag_liquidate, flag_filled, mon)
        flag_trade = ~flag_rebalance & (flag_date != stopp_date) & ~flag_filled

    initial_assets = [nm for nm in flag_assets if sim["assets"][nm]["start"] <= int(flag_date[0])]
    if not initial_assets:
        raise ValueError("invalid 'type' (list) of argument")
    initial_weights_sum = r_sum([sim["status"][nm]["actual"] for nm in initial_assets])
    for nm in flag_assets:
        st = sim["status"][nm]
        if nm in initial_assets:
            w = st["actual"] / initial_weights_sum
            st["actual"] = w
            st["money"] = start_value * w
            st["total"] = start_value * w
        else:
            st["differ"] = 0.0
            st["money"] = 0.0
            st["total"] = 0.0

    asset_starts = [int(sim["assets"][nm]["start"]) for nm in flag_assets]
    if flag_filled.any():
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
            j = max(min(j, n - 1), 0)
            shifted.append(int(flag_date[j]))
        asset_starts = shifted
    start_set = set(asset_starts)
    flag_active = np.array([int(z) in start_set for z in flag_date], dtype=bool)
    pos_all = {int(z): i + 1 for i, z in enumerate(flag_date)}
    asset_start_indices = [pos_all.get(z, 1) for z in asset_starts]

    flag_definite = flag_active | flag_split | flag_dca | flag_rebalance | flag_taxes | flag_liquidate
    strategy_types = [sim["assets"][nm]["style"] for nm in flag_assets]
    has_bnh = any(t == "bnh" for t in strategy_types)
    has_signal = any(t == "signal" for t in strategy_types)
    tax_regimes = {nm: sim["assets"][nm]["tax_regime"] for nm in flag_assets}
    spread_rates = {nm: sim["market"][nm]["spread_rate"] for nm in flag_assets}

    def _pay_vp(sim: dict, name: str, tax_debt: float, time: int, meta: dict) -> dict:
        tax_regime = tax_regimes[name]
        st = sim["status"][name]
        if st["money"] >= tax_debt:
            st["money"] = st["money"] - tax_debt
            sim["totals"]["total_taxes"] = sim["totals"]["total_taxes"] + tax_debt
            if details:
                _cat("Tax Event:\tPaying Vorabpauschale of %.2f EUR for %s from cash on %s\n"
                     % (tax_debt, name, fmt_date(flag_date[time - 1])))
        else:
            remaining_tax = tax_debt
            if st["money"] > 0:
                cash_used = st["money"]
                remaining_tax = tax_debt - cash_used
                st["money"] = 0.0
                if details:
                    _cat("Tax Event:\tUsing %.2f EUR cash for partial Vorabpauschale payment on %s\n"
                         % (cash_used, fmt_date(flag_date[time - 1])))
            if remaining_tax > 0:
                sr = _calculate_sell_count(sim, name, remaining_tax, time, spread_rates[name], fractions,
                                           tax_mode, tax_rate, tax_regime)
                sim = _perform_trade_sell(sim, name, time, tax_mode, tax_rate, effective_tax_rate,
                                          marginal_tax_rate, private_sale_threshold, use_sparer_pauschbetrag,
                                          tax_regime, "Tax Event:", spread_rates[name], details,
                                          count=sr["sell_count"], price=sr["fifo_price"])
                st = sim["status"][name]
                st["money"] = st["money"] - remaining_tax
                if details:
                    _cat("\t\t=> Sold shares to pay remaining %.2f EUR Vorabpauschale\n" % remaining_tax)
            sim["totals"]["total_taxes"] = sim["totals"]["total_taxes"] + tax_debt
            st = sim["status"][name]
            if st["money"] < 0:
                st["money"] = 0.0
        entry = {
            "event_date": int(flag_date[time - 1]),
            "assessment_date": meta.get("assessment_date"),
            "event_type": "Vorabpauschale",
            "flat_rate_gross": meta.get("flat_rate"),
            "bonus_applied": meta.get("bonus"),
            "flat_rate_taxable": meta["flat_rate"] * (1 - meta["bonus"]),
            "spb_used": meta.get("spb_used"),
            "taxes_paid": tax_debt,
        }
        tr = sim["trades"][name]
        tr["tax_count"] += 1
        tr["taxes"].append(entry)
        return sim

    flag_signal = np.zeros(n, dtype=bool)
    if has_signal:
        for nm in flag_assets:
            if sim["assets"][nm]["style"] == "signal":
                b = np.array([_truthy(x) for x in sim["market"][nm]["signal_buy"]], dtype=bool)
                s = np.array([_truthy(x) for x in sim["market"][nm]["signal_sell"]], dtype=bool)
                flag_signal = flag_signal | b | s

    flag_bnh_potential = np.zeros(n, dtype=bool)
    if has_bnh and n > 0:
        flag_bnh_potential[0] = True

    flag_slow_path = flag_definite | flag_signal | flag_bnh_potential

    flag_year_change = np.zeros(n, dtype=bool)
    flag_vp_settle = np.zeros(n, dtype=bool)
    if tax_mode == "person":
        years = np.array([x.year for x in md], dtype=np.int64)
        if n > 1:
            flag_year_change[1:] = np.diff(years) > 0
        for ys in np.flatnonzero(flag_year_change):
            j = ys
            while j < n and flag_filled[j]:
                j += 1
            if j < n:
                flag_vp_settle[j] = True

    flag_slow_path = flag_slow_path | flag_vp_settle
    flag_individual = flag_slow_path | flag_year_change
    individual_days = [int(i) + 1 for i in np.flatnonzero(flag_individual)]
    n_total_days = n_rows

    # ── Hauptschleife ──────────────────────────────────────────────────────
    sell_kw = dict(tax_rate=tax_rate, effective_tax_rate=effective_tax_rate,
                   marginal_tax_rate=marginal_tax_rate, private_sale_threshold=private_sale_threshold,
                   use_sparer_pauschbetrag=use_sparer_pauschbetrag)

    def sell(sim, name, time, reason, count=None, price=None, tmode=None):
        return _perform_trade_sell(sim, name, time, tmode if tmode is not None else tax_mode,
                                   sell_kw["tax_rate"], sell_kw["effective_tax_rate"],
                                   sell_kw["marginal_tax_rate"], sell_kw["private_sale_threshold"],
                                   sell_kw["use_sparer_pauschbetrag"], tax_regimes[name], reason,
                                   spread_rates[name], details, count=count, price=price)

    def buy(sim, name, time, reason):
        return _perform_trade_buy(sim, name, time, reason, spread_rates[name], fractions, details)

    prev_end = 0
    active_assets: list[str] = []

    for time in individual_days:
        t0 = time - 1
        if time > prev_end + 1:
            core.batch_market_update(sim, flag_assets, prev_end + 1, time - 1)

        if flag_year_change[t0]:
            sim = _handle_year_change(sim, int(flag_date[t0]), marginal_tax_rate, private_sale_threshold,
                                      sparer_pauschbetrag, use_sparer_pauschbetrag, soli_factor_income,
                                      effective_tax_rate, details)

        if not flag_slow_path[t0]:
            core.perform_market_update(sim, flag_assets, time)
            prev_end = time
            continue

        if flag_active[t0] or len(active_assets) == 0:
            active_assets = [nm for nm, si in zip(flag_assets, asset_start_indices) if si <= time]
        flag_fast_report = True

        # Asset-Aktivierung
        if flag_active[t0]:
            for nm in flag_assets:
                if nm in active_assets:
                    continue
                for key in ("signal_buy", "signal_sell"):
                    arr = sim["market"][nm][key]
                    arr[t0] = 0.0 if arr.dtype == np.float64 else False
            if balance_mode:
                cws = r_sum([sim["status"][nm]["actual"] for nm in active_assets])
                for nm in active_assets:
                    sim["status"][nm]["differ"] = sim["status"][nm]["actual"] / cws
                if details:
                    new_assets = [nm for nm, sd in zip(flag_assets, asset_starts) if sd == int(flag_date[t0])]
                    if new_assets:
                        _cat("Market Event:\tActive trading of %s now enabled.\n" % ", ".join(new_assets))
                flag_rebalance[t0] = True
            core.calculate_total_report(sim, flag_assets, time)
            flag_fast_report = False

        # Splits
        if flag_split[t0]:
            for nm in active_assets:
                if sim["status"][nm]["count"] > 0:
                    split_price = float(sim["market"][nm]["asset_price"][t0])
                    if split_price > split_thresh[1]:
                        sim = _perform_asset_split(sim, nm, split_price / 100, time, "forward", fractions,
                                                   details, int(flag_date[t0]))
                    if split_price < split_thresh[0]:
                        sim = _perform_asset_split(sim, nm, 100 / split_price, time, "reverse", fractions,
                                                   details, int(flag_date[t0]))
            core.calculate_total_report(sim, flag_assets, time)
            flag_fast_report = False

        # DCA
        if flag_dca[t0]:
            strat_w = np.array([float(strategy[nm]["asset_share"]) for nm in active_assets])
            strat_w = strat_w / r_sum(strat_w, na_rm=True)
            if balance_dca and len(active_assets) > 1:
                totals_now = np.array([sim["status"][nm]["total"] for nm in active_assets])
                desired = strat_w * (r_sum(totals_now, na_rm=True) + dca_value)
                deficit = np.maximum(0.0, desired - totals_now)
                if r_sum(deficit) > dca_value:
                    alloc = dca_value * deficit / r_sum(deficit)
                else:
                    alloc = deficit + (dca_value - r_sum(deficit)) * strat_w
                for nm, v in zip(active_assets, alloc):
                    core.dca_flows_allocation(sim, nm, float(v), time)
            else:
                for nm, w in zip(active_assets, strat_w):
                    core.dca_flows_allocation(sim, nm, float(w) * dca_value, time)
            if details:
                fv = [sim["report"][nm]["flows"][t0] for nm in active_assets]
                parts = "; ".join("%s %.2f EUR" % (nm, v) for nm, v in zip(active_assets, fv))
                _cat("Transferring:\tDepositing %.2f EUR to brokerage account on %s\n\t\t=> %s\n"
                     % (dca_value, fmt_date(flag_date[t0]), parts))
            core.calculate_total_report(sim, flag_assets, time)
            flag_fast_report = False

        # Handel
        if flag_trade[t0]:
            trade_event = False
            for nm in active_assets:
                f_buy = _calculate_buy_signal(sim, nm, time)
                f_sell = _calculate_sell_signal(sim, nm, time)
                if f_buy:
                    sim = buy(sim, nm, time, "Trade Event:")
                    trade_event = True
                if f_sell:
                    sim = sell(sim, nm, time, "Trade Event:")
                    trade_event = True
            if trade_event:
                core.calculate_total_report(sim, flag_assets, time)
                flag_fast_report = False

        # Rebalancing
        if flag_rebalance[t0]:
            at = np.array([sim["status"][nm]["actual"] for nm in active_assets], dtype=np.float64)
            at = at / r_sum(at, na_rm=True)
            active_targets = dict(zip(active_assets, at))
            if event_weight is not None and bool(flag_event[t0]):
                ow = []
                for nm in active_assets:
                    col = event_weight.get(nm) if isinstance(event_weight, Mapping) else None
                    if col is None:
                        ow.append(NA)
                    else:
                        v = d.get(col)
                        ow.append(float(v[t0]) if v is not None else NA)
                ow_a = np.array(ow, dtype=np.float64)
                if np.all(np.isfinite(ow_a)) and r_sum(ow_a) > 0:
                    ow_a = ow_a / r_sum(ow_a)
                    active_targets = dict(zip(active_assets, ow_a))

            signal_cash_only: list[str] = []
            for nm in active_assets:
                if sim["assets"][nm]["style"] == "signal":
                    has_pos = sim["status"][nm]["count"] > 0
                    sig_buy = _is_true(sim["market"][nm]["signal_buy"][t0])
                    sig_sell = _is_true(sim["market"][nm]["signal_sell"][t0])
                    if has_pos and sig_sell:
                        sim = sell(sim, nm, time, "Rebalancing/Signal-Exit:")
                        signal_cash_only.append(nm)
                    elif not has_pos and sig_buy:
                        sim = buy(sim, nm, time, "Rebalancing/Signal-Entry:")
                    elif not has_pos and not sig_buy:
                        signal_cash_only.append(nm)

            actual_weights = {nm: sim["status"][nm]["differ"] for nm in active_assets}
            new_asset = any(sd == int(flag_date[t0]) for sd in asset_starts)
            force_rebalance = new_asset
            if force_rebalance and details:
                new_assets = [nm for nm, sd in zip(flag_assets, asset_starts) if sd == int(flag_date[t0])]
                _cat("Rebalancing:\tForcing rebalance on %s due to new asset activation: %s\n"
                     % (fmt_date(flag_date[t0]), ", ".join(new_assets)))

            if force_rebalance:
                event_rebalance = True
            elif balance_thresh is None:
                event_rebalance = True
            else:
                deviations = [abs(active_targets[nm] - actual_weights[nm]) for nm in active_assets]
                devs_ok = [x for x in deviations if not math.isnan(x)]
                max_deviation = max(devs_ok) if devs_ok else -math.inf
                event_rebalance = max_deviation > balance_thresh
                if details:
                    if event_rebalance:
                        _cat("Rebalancing:\tExecuting rebalancing on %s (max deviation: %.2f%% > threshold: %.2f%%)\n"
                             % (fmt_date(flag_date[t0]), max_deviation * 100, balance_thresh * 100))
                        for nm, dev in zip(active_assets, deviations):
                            if dev > balance_thresh:
                                _cat("\t\t=> %s: target=%.1f%%, actual=%.1f%%, deviation=%.2f%%\n"
                                     % (nm, active_targets[nm] * 100, actual_weights[nm] * 100, dev * 100))
                    else:
                        _cat("Rebalancing:\tSkipping rebalancing on %s (max deviation: %.2f%% < threshold: %.2f%%)\n"
                             % (fmt_date(flag_date[t0]), max_deviation * 100, balance_thresh * 100))

            if event_rebalance:
                differ_weights = {nm: active_targets[nm] - actual_weights[nm] for nm in active_assets}
                total_strategy = r_sum([sim["status"][nm]["total"] for nm in active_assets], na_rm=True)
                transfer_pool = 0.0
                transfer_value = {nm: abs(differ_weights[nm] * total_strategy) for nm in active_assets}

                for nm in [x for x in active_assets if differ_weights[x] < 0]:
                    if sim["status"][nm]["count"] > 0:
                        sr = _calculate_sell_count(sim, nm, transfer_value[nm], time, spread_rates[nm],
                                                   fractions, tax_mode, tax_rate, tax_regimes[nm])
                        sim = sell(sim, nm, time, "Rebalancing:", count=sr["sell_count"], price=sr["fifo_price"])
                    available_cash = _rmin(sim["status"][nm]["money"], transfer_value[nm])
                    transfer_pool = transfer_pool + available_cash
                    sim["status"][nm]["money"] = sim["status"][nm]["money"] - available_cash
                    if details:
                        _cat("\t\tDepositing %.2f EUR from %s to rebalancing pool\n" % (available_cash, nm))

                for nm in [x for x in active_assets if differ_weights[x] > 0]:
                    allocation = _rmin(transfer_value[nm], transfer_pool)
                    if allocation > 0:
                        sim["status"][nm]["money"] = sim["status"][nm]["money"] + allocation
                        transfer_pool = transfer_pool - allocation
                        if details:
                            _cat("Rebalancing:\tWithdrawing %.2f EUR from pool to %s\n" % (allocation, nm))
                        if nm in signal_cash_only:
                            if details:
                                _cat("\t\t=> %s haelt %.2f EUR als Cash-Reserve (Signal inaktiv)\n"
                                     % (nm, sim["status"][nm]["money"]))
                        else:
                            sim = buy(sim, nm, time, "Rebalancing:")

                if transfer_pool > 0.01:
                    if details:
                        _cat("\t\tRedistributing remaining %.2f EUR from rebalancing pool\n" % transfer_pool)
                    for nm in active_assets:
                        redistribution = active_targets[nm] * transfer_pool
                        sim["status"][nm]["money"] = sim["status"][nm]["money"] + redistribution
                        if details:
                            _cat("\t\t=> Transferring %.2f EUR to %s\n" % (redistribution, nm))

            for nm in active_assets:
                st = sim["status"][nm]
                if nm not in signal_cash_only and st["money"] > 0.005 and \
                        (sim["assets"][nm]["style"] != "signal" or st["count"] > 0):
                    sim = buy(sim, nm, time, "Rebalancing:")

            core.calculate_total_report(sim, flag_assets, time)
            flag_fast_report = False

        # Fälligkeit der Vorabpauschale (§ 18 Abs. 3 InvStG)
        if tax_mode == "person" and flag_vp_settle[t0]:
            pend = sim["totals"].get("vp_pending")
            vp_paid_any = pend is not None and len(pend) > 0
            if vp_paid_any:
                for p in pend:
                    sim = _pay_vp(sim, p["name"], p["tax_debt"], time,
                                  {"flat_rate": p["flat_rate"], "bonus": p["bonus"],
                                   "spb_used": p["spb_used"], "assessment_date": p["assessment_date"]})
                sim["totals"].pop("vp_pending", None)
            if vp_paid_any:
                core.calculate_total_report(sim, flag_assets, time)
                flag_fast_report = False

        # Steuern und Gebühren (31.12.)
        if flag_taxes[t0]:
            if tax_mode == "person" and not (liquidate and flag_liquidate[t0]):
                for nm in flag_assets:
                    regime = tax_regimes[nm]
                    if regime == "investment_fund" and sim["status"][nm]["count"] > 0:
                        vp_result = _calculate_flat_rate(sim, nm, time, flag_date, regime)
                        fr = vp_result["total_vp"]
                        buys_l = sim["trades"][nm]["buys"]
                        for vp_i, lv in zip(vp_result["lot_indices"], vp_result["lot_vps"]):
                            lot = buys_l[vp_i - 1]
                            lot["vp"] = _get(lot, "vp", 0.0) + lv
                        if fr > 0:
                            prior = 0.0
                            n_tax = sim["trades"][nm]["tax_count"]
                            if n_tax > 0:
                                cy = from_days(flag_date[t0]).year
                                vals = []
                                for x in sim["trades"][nm]["taxes"][:n_tax]:
                                    ad = x.get("assessment_date")
                                    if ad is None:
                                        ad = x.get("event_date")
                                    vals.append(x["taxes_paid"] if ad is not None and year_of(ad) == cy else 0.0)
                                prior = r_sum(vals, na_rm=True)
                            bonus = sim["assets"][nm]["bonus"]
                            res = core.vp_tax(fr, bonus, sim["totals"], effective_tax_rate, use_sparer_pauschbetrag)
                            tax_debt = _rmax(res["tax"] - prior, 0.0)
                            if details and res["spb_used"] > 0:
                                _cat("Tax Event:\tVorabpauschale %s: %.2f EUR (nach TFS: %.2f EUR, SPB: %.2f EUR)\n"
                                     % (nm, fr, fr * (1 - bonus), res["spb_used"]))
                            if tax_debt > 0:
                                vp_meta = {"flat_rate": fr, "bonus": bonus, "spb_used": res["spb_used"],
                                           "assessment_date": int(flag_date[t0])}
                                has_future = time < n and bool(flag_vp_settle[time:].any())
                                if has_future:
                                    pend = sim["totals"].get("vp_pending")
                                    if pend is None:
                                        pend = []
                                    item = dict(vp_meta)
                                    item["name"] = nm
                                    item["tax_debt"] = tax_debt
                                    pend = list(pend) + [item]
                                    sim["totals"]["vp_pending"] = pend
                                    if details:
                                        _cat("Tax Event:\tVorabpauschale %s: %.2f EUR festgesetzt am %s "
                                             "(faellig am ersten Handelstag des Folgejahres)\n"
                                             % (nm, tax_debt, fmt_date(flag_date[t0])))
                                else:
                                    if details:
                                        _cat("Tax Event:\tVorabpauschale %s: %.2f EUR festgesetzt am %s "
                                             "(sofort faellig: kein weiterer Handelstag)\n"
                                             % (nm, tax_debt, fmt_date(flag_date[t0])))
                                    sim = _pay_vp(sim, nm, tax_debt, time, vp_meta)

            if tax_mode == "funds":
                rf_ = _calculate_fund_fees(sim, time, flag_date, flag_assets, funds_fee, bonus_fee, details)
                sim["totals"]["total_value"] = rf_["total_value"]
                annual_fees = rf_["total_fees"]
                asset_share = {nm: annual_fees * st["actual"] for nm, st in sim["status"].items()}
                asset_money = {nm: st["money"] for nm, st in sim["status"].items()}
                for nm in flag_assets:
                    if asset_money[nm] > asset_share[nm]:
                        if sim["status"][nm]["money"] < asset_share[nm]:
                            asset_share[nm] = _rmax(0.0, sim["status"][nm]["money"])
                        sim["status"][nm]["money"] = sim["status"][nm]["money"] - asset_share[nm]
                        if details:
                            _cat("\t\t=> Deducting %.2f EUR from %s's cash reserve for fees\n"
                                 % (asset_share[nm], nm))

            core.calculate_total_report(sim, flag_assets, time)
            flag_fast_report = False

        # Liquidation
        if flag_liquidate[t0]:
            for nm in flag_assets:
                if sim["status"][nm]["count"] > 0:
                    tax_type = "person" if tax_mode == "person" else "none"
                    sim = sell(sim, nm, time, "Liquidating:", tmode=tax_type)
            if from_days(flag_date[t0]).strftime("%m-%d") != "12-31" and tax_mode == "funds":
                rf_ = _calculate_fund_fees(sim, time, flag_date, flag_assets, funds_fee, bonus_fee, details)
                sim["totals"]["total_value"] = rf_["total_value"]
                annual_fees = rf_["total_fees"]
                asset_share = {nm: annual_fees * st["differ"] for nm, st in sim["status"].items()}
                for nm in flag_assets:
                    sim = sell(sim, nm, time, "")
                    if sim["status"][nm]["money"] < asset_share[nm]:
                        asset_share[nm] = _rmax(0.0, sim["status"][nm]["money"])
                    sim["status"][nm]["money"] = sim["status"][nm]["money"] - asset_share[nm]
                tax_weights = {nm: st["differ"] for nm, st in sim["status"].items()}
                final_value = r_sum([st["total"] for st in sim["status"].values()], na_rm=True)
                total_gains = final_value - start_value
                if total_gains > 0:
                    total_taxes = total_gains * tax_rate
                    for nm in flag_assets:
                        tpa = total_taxes * tax_weights[nm]
                        if sim["status"][nm]["money"] < tpa:
                            tpa = _rmax(0.0, sim["status"][nm]["money"])
                        sim["status"][nm]["money"] = sim["status"][nm]["money"] - tpa
                    if details:
                        _cat("Liquidating:\tPaying taxes of %.2f EUR on %.2f EUR total gain on %s\n"
                             % (total_taxes, total_gains, fmt_date(flag_date[t0])))
                for nm in flag_assets:
                    tr = sim["trades"][nm]
                    tr["fee_count"] += 1
                    tr["fees"].append({"event_date": int(flag_date[t0]), "event_type": "Fees",
                                       "fees_paid": annual_fees})
            core.calculate_total_report(sim, flag_assets, time)
            flag_fast_report = False

        if flag_fast_report:
            core.perform_market_update(sim, flag_assets, time)
        prev_end = time

    if prev_end < n_total_days:
        core.batch_market_update(sim, flag_assets, prev_end + 1, n_total_days)

    if tax_mode == "person":
        sim = _handle_year_change(sim, days_from_civil(year_of(stopp_date) + 1, 1, 1), marginal_tax_rate,
                                  private_sale_threshold, sparer_pauschbetrag, use_sparer_pauschbetrag,
                                  soli_factor_income, effective_tax_rate, details)

    trades_out = {}
    for nm in flag_assets:
        tr = sim["trades"][nm]
        trades_out[nm] = {
            "buys": tr["buys"][:tr["buy_count"]],
            "sells": tr["sells"][:tr["sell_count"]],
            "taxes": tr["taxes"][:tr["tax_count"]],
            "fees": tr["fees"][:tr["fee_count"]],
        }

    # ── Ergebnis-Berechnung ────────────────────────────────────────────────
    total_worth = r_rowsums(np.column_stack([sim["report"][nm]["total"] for nm in flag_assets]), na_rm=True)
    total_flows = r_rowsums(np.column_stack([sim["report"][nm]["flows"] for nm in flag_assets]), na_rm=True)
    start_worth = float(total_worth[0])
    stopp_worth = float(total_worth[n - 1])
    n_days_sim = total_worth.size

    ann_factor = float(stopp_date - start_date) / 365.25
    if start_worth > 0 and ann_factor > 0:
        cagr = r_pow(stopp_worth / start_worth, 1 / ann_factor) - 1
    else:
        cagr = NA

    running_max = np.maximum.accumulate(total_worth)
    with np.errstate(divide="ignore", invalid="ignore"):
        drawdowns = np.where(running_max > 0, (running_max - total_worth) / running_max, 0.0)
    dd_ok = drawdowns[~np.isnan(drawdowns)]
    max_drawdown = float(dd_ok.max()) if dd_ok.size else -math.inf
    if not math.isfinite(max_drawdown):
        max_drawdown = 0.0

    nn = n_days_sim
    if nn >= 2:
        period_change = np.concatenate([[NA], total_worth[1:] - total_worth[:-1] - total_flows[1:]])
        prev_total = np.concatenate([[NA], total_worth[:-1]])
        with np.errstate(divide="ignore", invalid="ignore"):
            cond = (~np.isnan(prev_total)) & (prev_total > 0)
            period_return = np.where(cond, period_change / prev_total, 0.0)
        period_return[0] = NA
    else:
        period_return = np.array([NA])
    ttwror = r_pow(r_prod(1 + period_return, na_rm=True), 1 / ann_factor) - 1 if ann_factor > 0 else NA

    with np.errstate(divide="ignore", invalid="ignore"):
        portfolio_returns = np.diff(total_worth) / total_worth[:-1]
    portfolio_returns[~np.isfinite(portfolio_returns)] = 0.0
    ttwror_returns = period_return[1:].copy()
    ttwror_returns[~np.isfinite(ttwror_returns)] = 0.0
    has_flows = bool(np.any(total_flows[~np.isnan(total_flows)] != 0))
    risk_returns = ttwror_returns if has_flows else portfolio_returns

    if flag_filled.size == risk_returns.size + 1:
        mask = flag_filled[1:]
    else:
        mask = np.zeros(risk_returns.size, dtype=bool)
    if mask.size == risk_returns.size and mask.any():
        risk_returns = risk_returns[~mask]
    ann_periods = risk_returns.size / ann_factor if (ann_factor > 0 and risk_returns.size > 0) else 365.25

    daily_mean = r_mean(risk_returns, na_rm=True)
    daily_sd = r_sd(risk_returns, na_rm=True)
    if not math.isfinite(daily_mean):
        daily_mean = 0.0
    if not math.isfinite(daily_sd):
        daily_sd = 0.0
    daily_cv = abs(daily_sd / daily_mean) if daily_mean != 0 else NA

    days_per_year = ann_periods
    if risk_free is None:
        risk_free = 0
    if isinstance(risk_free, str):
        if risk_free not in d:
            raise ValueError("risk_free: Spalte '%s' fehlt im Datensatz." % risk_free)
        rf_full = np.array(d.get(risk_free), dtype=np.float64)
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
    down_ex = excess[excess < 0]
    downside_sd_excess = math.sqrt(r_mean(down_ex * down_ex, na_rm=True)) if down_ex.size > 0 else 0.0

    sqrt_dpy = math.sqrt(days_per_year)
    sharpe = (mean_excess * days_per_year) / (sd_excess * sqrt_dpy) if sd_excess > 0 else NA
    sortino = (mean_excess * days_per_year) / (downside_sd_excess * sqrt_dpy) if downside_sd_excess > 0 else NA
    calmar = cagr / max_drawdown if (max_drawdown > 0 and not math.isnan(cagr)) else NA
    ulcer_index = math.sqrt(r_mean(drawdowns * drawdowns, na_rm=True)) if drawdowns.size else NA
    if not math.isfinite(ulcer_index):
        ulcer_index = 0.0
    martin_ratio = cagr / ulcer_index if (ulcer_index > 0 and not math.isnan(cagr)) else NA
    serenity = cagr / (ulcer_index * max_drawdown) if (ulcer_index > 0 and max_drawdown > 0
                                                        and not math.isnan(cagr)) else NA
    gains = r_sum(risk_returns[risk_returns > 0], na_rm=True)
    losses = abs(r_sum(risk_returns[risk_returns < 0], na_rm=True))
    omega = gains / losses if losses > 0 else NA
    gain_to_pain = r_sum(risk_returns, na_rm=True) / losses if losses > 0 else NA
    dd_active = drawdowns[drawdowns > 0]
    average_drawdown = r_mean(dd_active) if dd_active.size > 0 else 0.0

    longest_dd = 0
    current_dd = 0
    recovery_times: list[int] = []
    in_dd = False
    dd_start = 0
    for i in range(n_days_sim):
        below = total_worth[i] < running_max[i]
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
        else:
            if in_dd:
                recovery_times.append((i + 1) - dd_start)
                in_dd = False
    avg_recovery_time = r_mean_int(recovery_times) if recovery_times else NA

    statistics = {
        "mean": daily_mean,
        "sd": daily_sd,
        "cv": daily_cv,
        "risk_free": rf_effective,
        "skewness": _calculate_skewness(risk_returns),
        "kurtosis": _calculate_kurtosis(risk_returns),
        "lpm": _calculate_partials(risk_returns, lower=True),
        "hpm": _calculate_partials(risk_returns, lower=False),
        "sharpe": sharpe,
        "sortino": sortino,
        "calmar": calmar,
        "omega": omega,
        "gain_to_pain": gain_to_pain,
        "serenity": serenity,
        "martin_ratio": martin_ratio,
        "max_drawdown": max_drawdown,
        "average_drawdown": average_drawdown,
        "ulcer_index": ulcer_index,
        "longest_drawdown": int(longest_dd),
        "avg_recovery_time": avg_recovery_time,
    }

    buys_out = {nm: len(trades_out[nm]["buys"]) / ann_factor if ann_factor != 0 else
                (math.inf if trades_out[nm]["buys"] else NA) for nm in flag_assets}
    sells_out = {nm: len(trades_out[nm]["sells"]) / ann_factor if ann_factor != 0 else
                 (math.inf if trades_out[nm]["sells"] else NA) for nm in flag_assets}

    totals = sim["totals"]
    tax_report = {
        "total_taxes_paid": totals["total_taxes"],
        "loss_carryforward_capital": totals["loss_capital_gains"],
        "loss_carryforward_private": totals["loss_private_sales"],
        "sparer_pauschbetrag_annual": totals["sparer_pauschbetrag_annual"],
        "sparer_pauschbetrag_used": totals["sparer_pauschbetrag_used_total"],
        "sparer_pauschbetrag_tax_saved": totals["sparer_pauschbetrag_used_total"] * effective_tax_rate,
    }

    return SimLevResult(
        dates=flag_date.astype("datetime64[D]"),
        filled=flag_filled.copy(),
        worth=total_worth,
        cagr=cagr,
        ttwror=ttwror,
        drawdowns=drawdowns,
        statistics=statistics,
        buys=buys_out,
        sells=sells_out,
        report=sim["report"],
        tax_report=tax_report,
        trades=trades_out,
    )
