"""Rechenkerne der Engine.

Reine Python-Ports der C++-Funktionen aus ``simulation_core.cpp``,
``fifo_core_RCpp.cpp`` und ``tax_core_RCpp.cpp``. Die Rechenreihenfolge ist
1:1 übernommen, damit Ergebnisse bitgleich zum R-Paket sind (IEEE-754-
Doubles, ``long double`` nur dort, wo auch der C++-Code ihn nutzt).

Der Simulationszustand ``sim`` ist ein ``dict`` mit den Teilen ``assets``,
``status``, ``market``, ``trades``, ``report`` und ``totals`` – analog zu
``sim_mem`` im R-Paket. Lots werden als ``dict`` in ``trades[name]["buys"]``
geführt; ``fifo_front`` ist wie im Original 1-basiert.
"""
from __future__ import annotations

import math

import numpy as np

from ._dates import days_from_civil, is_leap, ymd

LD = np.longdouble


def _min(a: float, b: float) -> float:
    """``std::min(a, b)``."""
    return b if b < a else a


def _max(a: float, b: float) -> float:
    """``std::max(a, b)``."""
    return b if a < b else a


# ═══════════════════════════════════════════════════════════════════════════
# simulation_core.cpp
# ═══════════════════════════════════════════════════════════════════════════

def dca_flows_allocation(sim: dict, name: str, flows: float, index: int) -> None:
    st = sim["status"][name]
    rp = sim["report"][name]
    i = index - 1
    rp["flows"][i] = flows
    money = st["money"] + flows
    st["money"] = money
    rp["money"][i] = money
    total = money + st["worth"]
    st["total"] = total
    rp["total"][i] = total


def calculate_buy_report(sim: dict, name: str, index: int, trade_count: float,
                         trade_price: float, market_price: float) -> None:
    st = sim["status"][name]
    rp = sim["report"][name]
    count = st["count"] + trade_count
    st["count"] = count
    st["price"] = market_price
    worth = count * market_price
    st["worth"] = worth
    money = st["money"] - (trade_count * trade_price)
    st["money"] = money
    total = worth + money
    st["total"] = total
    i = index - 1
    rp["worth"][i] = worth
    rp["money"][i] = money
    rp["total"][i] = total


def calculate_sell_report(sim: dict, name: str, index: int, trade_count: float,
                          trade_price: float, market_price: float,
                          capital_gains_tax: float) -> None:
    st = sim["status"][name]
    rp = sim["report"][name]
    count = st["count"] - trade_count
    st["count"] = count
    st["price"] = market_price
    worth = count * market_price
    st["worth"] = worth
    money = st["money"] + ((trade_count * trade_price) - capital_gains_tax)
    st["money"] = money
    total = worth + money
    st["total"] = total
    i = index - 1
    rp["worth"][i] = worth
    rp["money"][i] = money
    rp["total"][i] = total


def calculate_total_report(sim: dict, assets: list[str], index: int) -> None:
    i = index - 1
    status, market, report = sim["status"], sim["market"], sim["report"]
    for name in assets:
        st = status[name]
        rp = report[name]
        price = float(market[name]["asset_price"][i])
        st["price"] = price
        worth = price * st["count"]
        st["worth"] = worth
        rp["worth"][i] = worth
        money = st["money"]
        rp["money"][i] = money
        total = money + worth
        st["total"] = total
        rp["total"][i] = total
    total_worth = 0.0
    for name in assets:
        total_worth += status[name]["total"]
    for name in assets:
        st = status[name]
        w = st["total"] / total_worth if total_worth > 0 else 0.0
        st["differ"] = w
        report[name]["share"][i] = w


def perform_trade_buy_cpp(sim: dict, name: str, index: int, trade_count: float,
                          trade_price: float, market_price: float) -> None:
    calculate_buy_report(sim, name, index, trade_count, trade_price, market_price)
    tr = sim["trades"][name]
    event_date = int(sim["market"][name]["asset_day"][index - 1])
    lot = {
        "date": event_date,
        "type": "Buy",
        "count": trade_count,
        "price": trade_price,
        "remaining": trade_count,
        "original": trade_count,
    }
    tr["buy_count"] += 1
    tr["buys"].append(lot)


def perform_market_update(sim: dict, assets: list[str], index: int) -> None:
    i = index - 1
    status, market, report = sim["status"], sim["market"], sim["report"]
    totals = []
    total_portfolio = 0.0
    for name in assets:
        st = status[name]
        rp = report[name]
        price = float(market[name]["asset_price"][i])
        money = st["money"]
        worth = st["count"] * price
        total = worth + money
        totals.append(total)
        total_portfolio += total
        rp["worth"][i] = worth
        rp["money"][i] = money
        rp["flows"][i] = 0.0
        rp["total"][i] = total
        st["price"] = price
        st["worth"] = worth
        st["total"] = total
    for name, total in zip(assets, totals):
        w = total / total_portfolio if total_portfolio > 0 else 0.0
        report[name]["share"][i] = w
        status[name]["differ"] = w


def batch_market_update(sim: dict, assets: list[str], start_idx: int, end_idx: int) -> None:
    n_days = end_idx - start_idx + 1
    if n_days <= 0:
        return
    s, e = start_idx - 1, end_idx
    status, market, report = sim["status"], sim["market"], sim["report"]
    portfolio = np.zeros(n_days, dtype=np.float64)
    for name in assets:
        st = status[name]
        rp = report[name]
        count = st["count"]
        money = st["money"]
        prices = market[name]["asset_price"][s:e]
        worth = count * prices
        total = worth + money
        rp["worth"][s:e] = worth
        rp["money"][s:e] = money
        rp["flows"][s:e] = 0.0
        rp["total"][s:e] = total
        portfolio += total
        st["price"] = float(prices[-1])
        st["worth"] = float(worth[-1])
        st["total"] = float(total[-1])
    pos = portfolio > 0.0
    safe = np.where(pos, portfolio, 1.0)
    for name in assets:
        rp = report[name]
        rt = rp["total"][s:e]
        with np.errstate(divide="ignore", invalid="ignore"):
            w = np.where(pos, rt / safe, 0.0)
        rp["share"][s:e] = w
        status[name]["differ"] = float(w[-1])


# ═══════════════════════════════════════════════════════════════════════════
# fifo_core_RCpp.cpp
# ═══════════════════════════════════════════════════════════════════════════

def calculate_fifo_price(buys: list, units: float, front_index: int) -> float:
    units_trade = units
    total_price = 0.0
    i = front_index
    n = len(buys)
    while units_trade > 0 and i <= n:
        b = buys[i - 1]
        if not b:
            break
        rem = b["remaining"]
        if rem > 0:
            sell = _min(rem, units_trade)
            total_price += sell * b["price"]
            units_trade -= sell
        i += 1
    return total_price / units if units > 0 else 0.0


def calculate_fifo_vorabpauschale(buys: list, units: float, front_index: int) -> float:
    units_trade = units
    total_vp = 0.0
    i = front_index
    n = len(buys)
    while units_trade > 0 and i <= n:
        b = buys[i - 1]
        if not b:
            break
        rem = b["remaining"]
        if rem > 0:
            sell = _min(rem, units_trade)
            lot_vp = b.get("vp", 0.0)
            if rem > 0 and lot_vp > 0:
                total_vp += sell * (lot_vp / rem)
            units_trade -= sell
        i += 1
    return total_vp


def calculate_private_sale_tax(buys: list, front_index: int, trade_count: float,
                               sell_price: float, current_date: int) -> dict:
    units_remaining = trade_count
    i = front_index
    n = len(buys)
    eg = el = tg = tl = 0.0
    while units_remaining > 0 and i <= n:
        b = buys[i - 1]
        if not b:
            break
        avail = b["remaining"]
        if avail > 0:
            sell = _min(avail, units_remaining)
            buy_days = int(b["date"])
            buy_price = b["price"]
            y, m, d = ymd(buy_days)
            if m == 2 and d == 29 and not is_leap(y + 1):
                one_year_later = days_from_civil(y + 1, 3, 1)
            else:
                one_year_later = days_from_civil(y + 1, m, d)
            is_exempt = current_date > one_year_later
            lot_gain = sell * (sell_price - buy_price)
            if is_exempt:
                if lot_gain >= 0:
                    eg += lot_gain
                else:
                    el += -lot_gain
            else:
                if lot_gain >= 0:
                    tg += lot_gain
                else:
                    tl += -lot_gain
            units_remaining -= sell
        i += 1
    return {
        "exempt_gain": eg,
        "exempt_loss": el,
        "taxable_gain": tg,
        "taxable_loss": tl,
        "total_gain": eg - el + tg - tl,
    }


def fifo_consume(sim: dict, name: str, trade_count: float) -> None:
    tr = sim["trades"][name]
    buys = tr["buys"]
    buy_count = tr["buy_count"]
    front = tr["fifo_front"]
    units_remaining = trade_count
    i = front
    while units_remaining > 0 and i <= buy_count:
        b = buys[i - 1]
        if b:
            rem = b["remaining"]
            if rem > 0:
                red = _min(rem, units_remaining)
                if "vp" in b:
                    vp = b["vp"]
                    if vp > 0 and rem > 0:
                        b["vp"] = vp * (1.0 - red / rem)
                b["remaining"] = rem - red
                units_remaining -= red
        i += 1
    while front <= buy_count:
        b = buys[front - 1]
        if not b:
            break
        if b["remaining"] > 0:
            break
        front += 1
    tr["fifo_front"] = front


def update_fifo_front(buys: list, front_index: int) -> int:
    while front_index <= len(buys):
        b = buys[front_index - 1]
        if not b:
            break
        if b["remaining"] > 0:
            return front_index
        front_index += 1
    return front_index


# ═══════════════════════════════════════════════════════════════════════════
# tax_core_RCpp.cpp
# ═══════════════════════════════════════════════════════════════════════════

def flat_rate(buys: list, front_index: int, base_rate: float, year_start_price: float,
              market_price: float, soy_days: int, eoy_days: int) -> dict:
    n = len(buys)
    empty = {"total_vp": 0.0, "lot_indices": [], "lot_vps": []}
    if front_index > n:
        return empty
    idx: list[int] = []
    vps: list[float] = []
    for i in range(front_index, n + 1):
        b = buys[i - 1]
        if not b:
            break
        rem = b["remaining"]
        if rem <= 0:
            continue
        buy_days = int(b["date"])
        vp = 0.0
        if buy_days <= eoy_days:
            if buy_days < soy_days:
                months_factor = 1.0
                reference_value = rem * year_start_price
            else:
                _, m, _ = ymd(buy_days)
                months_factor = (12.0 - (m - 1)) / 12.0
                reference_value = rem * b["price"]
            base_worth = reference_value * base_rate * 0.7 * months_factor
            market_worth = rem * market_price
            growth = _max(0.0, market_worth - reference_value)
            vp = _max(0.0, _min(base_worth, growth))
        idx.append(i)
        vps.append(vp)
    total = LD(0)
    for v in vps:
        total += LD(v)
    return {"total_vp": float(total), "lot_indices": idx, "lot_vps": vps}


def _tget(t: dict, fld: str) -> float:
    v = t.get(fld)
    return 0.0 if v is None else float(v)


def p20_tax(trade_gain: float, bonus: float, totals: dict, tax_rate: float, use_spb: bool) -> dict:
    adjusted_gain = trade_gain * (1.0 - bonus)
    if adjusted_gain < 0:
        totals["loss_capital_gains"] = totals["loss_capital_gains"] - adjusted_gain
        totals["cgt_loss_added_ytd"] = _tget(totals, "cgt_loss_added_ytd") - adjusted_gain
        return {"tax": 0.0, "spb_used": 0.0}
    pool = totals["loss_capital_gains"]
    loss_offset = _min(adjusted_gain, pool)
    totals["loss_capital_gains"] = pool - loss_offset
    totals["cgt_loss_used_ytd"] = _tget(totals, "cgt_loss_used_ytd") + loss_offset
    gain_after_loss = adjusted_gain - loss_offset
    spb_offset = 0.0
    spb_rem = totals["sparer_pauschbetrag_remaining"]
    if use_spb and spb_rem > 0:
        spb_offset = _min(gain_after_loss, spb_rem)
        totals["sparer_pauschbetrag_remaining"] = spb_rem - spb_offset
        totals["sparer_pauschbetrag_used_total"] = totals["sparer_pauschbetrag_used_total"] + spb_offset
    taxable_gain = gain_after_loss - spb_offset
    totals["cgt_base_taxed_ytd"] = _tget(totals, "cgt_base_taxed_ytd") + taxable_gain
    tax = taxable_gain * tax_rate
    totals["total_taxes"] = totals["total_taxes"] + tax
    return {"tax": tax, "spb_used": spb_offset}


def vp_tax(flat_rate_value: float, bonus: float, totals: dict, tax_rate: float, use_spb: bool) -> dict:
    taxable_flat_rate = flat_rate_value * (1.0 - bonus)
    pool = totals["loss_capital_gains"]
    loss_offset = _min(taxable_flat_rate, pool)
    totals["loss_capital_gains"] = pool - loss_offset
    totals["cgt_loss_used_ytd"] = _tget(totals, "cgt_loss_used_ytd") + loss_offset
    vp_after_loss = taxable_flat_rate - loss_offset
    spb_offset = 0.0
    spb_rem = totals["sparer_pauschbetrag_remaining"]
    if use_spb and spb_rem > 0:
        spb_offset = _min(vp_after_loss, spb_rem)
        totals["sparer_pauschbetrag_remaining"] = spb_rem - spb_offset
        totals["sparer_pauschbetrag_used_total"] = totals["sparer_pauschbetrag_used_total"] + spb_offset
    taxable_gain = vp_after_loss - spb_offset
    totals["cgt_base_taxed_ytd"] = _tget(totals, "cgt_base_taxed_ytd") + _max(0.0, taxable_gain)
    tax = _max(0.0, taxable_gain * tax_rate)
    return {"tax": tax, "spb_used": spb_offset, "taxable_amount": taxable_flat_rate}


def _fifo_fast(units: float, cu: list, cc: list, prices: list) -> float:
    n = len(cu)
    if units <= 0:
        return 0.0
    if units >= cu[n - 1]:
        return cc[n - 1] / cu[n - 1]
    lot = 0
    while lot < n and cu[lot] < units:
        lot += 1
    lot_idx = min(lot + 1, n)
    if lot_idx == 1:
        return prices[0]
    prev_cost = cc[lot_idx - 2]
    prev_units = cu[lot_idx - 2]
    rem = units - prev_units
    return (prev_cost + rem * prices[lot_idx - 1]) / units


def sell_count(buys: list, front_index: int, target: float, trade_price: float,
               total_shares: float, fractions: bool, regime: int, bonus: float,
               loss_pool: float, tax_rate: float) -> dict:
    zero = {"sell_count": 0.0, "fifo_price": 0.0}
    n = len(buys)
    if front_index > n:
        return zero
    units: list[float] = []
    prices: list[float] = []
    for i in range(front_index, n + 1):
        b = buys[i - 1]
        if not b:
            break
        rem = b["remaining"]
        if rem > 0:
            units.append(rem)
            prices.append(b["price"])
    if not units:
        return zero
    cu: list[float] = []
    cc: list[float] = []
    su = LD(0)
    sc = LD(0)
    for u, p in zip(units, prices):
        su += LD(u)
        cu.append(float(su))
        sc += LD(u * p)
        cc.append(float(sc))

    def objective(sell: float) -> float:
        if sell <= 0:
            return -target
        if sell > total_shares:
            sell = total_shares
        fp = _fifo_fast(sell, cu, cc, prices)
        gain = (trade_price - fp) * sell
        tax = 0.0
        if regime == 1:
            adj = gain * (1.0 - bonus)
            tax = _max(adj - loss_pool, 0.0) * tax_rate
        elif regime == 2:
            tax = _max(gain - loss_pool, 0.0) * tax_rate
        return sell * trade_price - tax - target

    initial = target / trade_price
    lower = _max(1e-6, initial * 0.1)
    upper = _min(initial * 3.0, total_shares)
    f_lower = objective(lower)
    f_upper = objective(upper)
    tol = 1e-6 if fractions else 0.5

    if f_lower >= 0:
        sell = lower
    elif f_upper <= 0:
        sell = upper
    elif math.fabs(f_lower) < tol:
        sell = lower
    elif math.fabs(f_upper) < tol:
        sell = upper
    else:
        sell = (lower + upper) * 0.5
        for _ in range(30):
            mid = (lower + upper) * 0.5
            fm = objective(mid)
            if math.fabs(fm) < tol or (upper - lower) < tol:
                sell = mid
                break
            if fm * f_lower < 0:
                upper = mid
                f_upper = fm
            else:
                lower = mid
                f_lower = fm
            sell = (lower + upper) * 0.5

    if not fractions:
        tl = float(math.floor(sell))
        tu = float(math.ceil(sell))
        if tl < 1:
            tl = 1.0
        if tu > total_shares:
            tu = total_shares
        sell = tl if math.fabs(objective(tl)) <= math.fabs(objective(tu)) else tu

    final_fp = _fifo_fast(sell, cu, cc, prices)
    out = _max(0.0, _min(sell, total_shares))
    return {"sell_count": float(out), "fifo_price": final_fp}
