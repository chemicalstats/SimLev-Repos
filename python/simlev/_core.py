"""Rechenkerne der Engine.

Reine Python-Ports der C++-Funktionen aus ``simulation_core.cpp``,
``fifo_core.cpp`` und ``tax_core.cpp``. Die Rechenreihenfolge ist
1:1 übernommen, damit Ergebnisse bitgleich zum R-Paket sind (IEEE-754-
Doubles, ``long double`` nur dort, wo auch der C++-Code ihn nutzt).

Seit Etappe 7.3a rechnen die Funktionen über die C-Erweiterung ``simlev._ext``
mit denselben Kernen wie R (``r/src/simulation_core_impl.h``, ``fifo_core_impl.h``,
``tax_core_impl.h``), sofern sie gebaut ist; die Python-Ports bleiben der Rückfall
(``SIMLEV_NO_EXT=1``).

Der Simulationszustand ``sim`` ist ein ``dict`` mit den Teilen ``assets``,
``status``, ``market``, ``trades``, ``report`` und ``totals`` – analog zu
``sim_mem`` im R-Paket. Lots werden als ``dict`` in ``trades[name]["buys"]``
geführt; ``fifo_front`` ist wie im Original 1-basiert.
"""
from __future__ import annotations

import math

import numpy as np

from ._dates import days_from_civil, is_leap, ymd
from ._r import env as _env
from ._r.rnum import c_div as _dv, n_add as _n_add, n_mul as _n_mul

LD = np.longdouble

# NaN-Nutzlast (Etappe 8.0): Treffen in einer Addition oder Multiplikation zwei NaN
# aufeinander (etwa NA und NaN), behält R (x86-64/SSE) das NaN des ersten Operanden der
# Maschinenanweisung, die der Compiler gewählt hat; Python wählt je nach Zustand des
# Interpreters (spezialisierter Bytecode oder nicht) verschieden. Deshalb wird ein
# NaN-Ergebnis mit ``n_add``/``n_mul`` (``simlev._r.rnum``) in der Operandenfolge des
# R-Baus (objdump von ``SimLev.so``, gcc -O2) neu gebildet; ohne NaN rechnet der Port wie
# bisher. Subtraktion und Division brauchen das nicht (nur eine Operandenfolge).


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
    ext = _env.ext()
    if ext is not None:
        ext.sim_dca_flows(sim, name, flows, index)
        return
    st = sim["status"][name]
    rp = sim["report"][name]
    i = index - 1
    rp["flows"][i] = flows
    m0 = st["money"]
    money = m0 + flows
    if money != money:
        money = _n_add(flows, m0)                # R: flows + money
    st["money"] = money
    rp["money"][i] = money
    worth = st["worth"]
    total = money + worth
    if total != total:
        total = _n_add(money, worth)
    st["total"] = total
    rp["total"][i] = total


def calculate_buy_report(sim: dict, name: str, index: int, trade_count: float,
                         trade_price: float, market_price: float) -> None:
    ext = _env.ext()
    if ext is not None:
        ext.sim_buy_report(sim, name, index, trade_count, trade_price, market_price)
        return
    st = sim["status"][name]
    rp = sim["report"][name]
    c0 = st["count"]
    count = c0 + trade_count
    if count != count:
        count = _n_add(c0, trade_count)
    st["count"] = count
    st["price"] = market_price
    worth = count * market_price
    if worth != worth:
        worth = _n_mul(count, market_price)
    st["worth"] = worth
    cost = trade_count * trade_price
    if cost != cost:
        cost = _n_mul(trade_count, trade_price)
    money = st["money"] - cost
    st["money"] = money
    total = worth + money
    if total != total:
        total = _n_add(worth, money)
    st["total"] = total
    i = index - 1
    rp["worth"][i] = worth
    rp["money"][i] = money
    rp["total"][i] = total


def calculate_sell_report(sim: dict, name: str, index: int, trade_count: float,
                          trade_price: float, market_price: float,
                          capital_gains_tax: float) -> None:
    ext = _env.ext()
    if ext is not None:
        ext.sim_sell_report(sim, name, index, trade_count, trade_price, market_price, capital_gains_tax)
        return
    st = sim["status"][name]
    rp = sim["report"][name]
    count = st["count"] - trade_count
    st["count"] = count
    st["price"] = market_price
    worth = count * market_price
    if worth != worth:
        worth = _n_mul(market_price, count)     # R: market_price * count
    st["worth"] = worth
    proceeds = trade_count * trade_price
    if proceeds != proceeds:
        proceeds = _n_mul(trade_count, trade_price)
    net = proceeds - capital_gains_tax
    m0 = st["money"]
    money = m0 + net
    if money != money:
        money = _n_add(net, m0)                  # R: (proceeds - tax) + money
    st["money"] = money
    total = worth + money
    if total != total:
        total = _n_add(worth, money)
    st["total"] = total
    i = index - 1
    rp["worth"][i] = worth
    rp["money"][i] = money
    rp["total"][i] = total


def calculate_total_report(sim: dict, assets: list[str], index: int) -> None:
    ext = _env.ext()
    if ext is not None:
        ext.sim_total_report(sim, assets, index)
        return
    i = index - 1
    status, market, report = sim["status"], sim["market"], sim["report"]
    for name in assets:
        st = status[name]
        rp = report[name]
        price = float(market[name]["asset_price"][i])
        st["price"] = price
        count = st["count"]
        worth = price * count
        if worth != worth:
            worth = _n_mul(price, count)
        st["worth"] = worth
        rp["worth"][i] = worth
        money = st["money"]
        rp["money"][i] = money
        total = money + worth
        if total != total:
            total = _n_add(worth, money)         # R: worth + money
        st["total"] = total
        rp["total"][i] = total
    total_worth = 0.0
    for name in assets:
        t = status[name]["total"]
        tw = total_worth + t
        if tw != tw:
            tw = _n_add(total_worth, t)
        total_worth = tw
    for name in assets:
        st = status[name]
        w = st["total"] / total_worth if total_worth > 0 else 0.0
        st["differ"] = w
        report[name]["share"][i] = w


def perform_trade_buy_cpp(sim: dict, name: str, index: int, trade_count: float,
                          trade_price: float, market_price: float) -> None:
    ext = _env.ext()
    if ext is not None:
        ext.sim_buy(sim, name, index, trade_count, trade_price, market_price)
        return
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
    ext = _env.ext()
    if ext is not None:
        ext.sim_market_update(sim, assets, index)
        return
    i = index - 1
    status, market, report = sim["status"], sim["market"], sim["report"]
    totals = []
    total_portfolio = 0.0
    for name in assets:
        st = status[name]
        rp = report[name]
        price = float(market[name]["asset_price"][i])
        money = st["money"]
        count = st["count"]
        worth = count * price
        if worth != worth:
            worth = _n_mul(count, price)
        total = worth + money
        if total != total:
            total = _n_add(worth, money)
        totals.append(total)
        tp = total_portfolio + total
        if tp != tp:
            tp = _n_add(total_portfolio, total)
        total_portfolio = tp
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
    ext = _env.ext()
    if ext is not None:
        ext.sim_market_update_batch(sim, assets, start_idx, end_idx)
        return
    n_days = end_idx - start_idx + 1
    if n_days <= 0:
        return
    s, e = start_idx - 1, end_idx
    status, market, report = sim["status"], sim["market"], sim["report"]
    portfolio = np.zeros(n_days, dtype=np.float64)
    parts = []
    nan = False
    for name in assets:
        st = status[name]
        count = st["count"]
        money = st["money"]
        prices = market[name]["asset_price"][s:e]
        worth = count * prices
        total = worth + money
        nan = nan or bool(np.isnan(total).any())
        parts.append((count, money, prices, worth, total))
    if nan:
        # NaN: Tag für Tag mit der Operandenfolge des R-Baus (price * count, worth + money,
        # portfolio + total); numpy wählt bei zwei NaN je nach Feldlänge anders
        port = [0.0] * n_days
        for k, (count, money, prices, _w, _t) in enumerate(parts):
            wl = []
            tl = []
            for d, price in enumerate(np.asarray(prices, dtype=np.float64).tolist()):
                w = _n_mul(price, count)
                t = _n_add(w, money)
                wl.append(w)
                tl.append(t)
                port[d] = _n_add(port[d], t)
            parts[k] = (count, money, prices, np.array(wl, dtype=np.float64), np.array(tl, dtype=np.float64))
    for name, (count, money, prices, worth, total) in zip(assets, parts):
        st = status[name]
        rp = report[name]
        rp["worth"][s:e] = worth
        rp["money"][s:e] = money
        rp["flows"][s:e] = 0.0
        rp["total"][s:e] = total
        if not nan:
            portfolio += total
        st["price"] = float(prices[-1])
        st["worth"] = float(worth[-1])
        st["total"] = float(total[-1])
    if nan:
        portfolio = np.array(port, dtype=np.float64)
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
# fifo_core.cpp
# ═══════════════════════════════════════════════════════════════════════════

def _calculate_fifo_price(buys: list, units: float, front_index: int) -> float:
    ext = _env.ext()
    if ext is not None:
        return ext.sim_fifo_price(buys, units, front_index)
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
            cost = sell * b["price"]
            tp = total_price + cost
            if tp != tp:
                tp = _n_add(cost, total_price)   # R: price * sell + total_price
            total_price = tp
            units_trade -= sell
        i += 1
    return total_price / units if units > 0 else 0.0


def _calculate_fifo_vorabpauschale(buys: list, units: float, front_index: int) -> float:
    ext = _env.ext()
    if ext is not None:
        return ext.sim_fifo_vp(buys, units, front_index)
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


def _calculate_private_sale_tax(buys: list, front_index: int, trade_count: float,
                               sell_price: float, current_date: int) -> dict:
    ext = _env.ext()
    if ext is not None:
        return ext.sim_private_sale_tax(buys, front_index, trade_count, sell_price, current_date)
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
            # T-3: Fristende am gleichnamigen Tag des Folgejahres (§§ 187, 188 Abs. 2 BGB);
            # Kauf am 29.02.: Fristende 28.02. (§ 188 Abs. 3 BGB), ab 01.03. steuerfrei
            if m == 2 and d == 29 and not is_leap(y + 1):
                one_year_later = days_from_civil(y + 1, 2, 28)
            else:
                one_year_later = days_from_civil(y + 1, m, d)
            is_exempt = current_date > one_year_later
            lot_gain = sell * (sell_price - buy_price)
            # R: Gewinn als lot_gain + Summe, Verlust als Summe - lot_gain (das NaN von
            # lot_gain behält so sein Vorzeichen; -lot_gain würde es umkehren)
            if is_exempt:
                if lot_gain >= 0:
                    x = lot_gain + eg
                    eg = x if x == x else _n_add(lot_gain, eg)
                else:
                    el = el - lot_gain
            else:
                if lot_gain >= 0:
                    x = lot_gain + tg
                    tg = x if x == x else _n_add(lot_gain, tg)
                else:
                    tl = tl - lot_gain
            units_remaining -= sell
        i += 1
    return {
        "exempt_gain": eg,
        "exempt_loss": el,
        "taxable_gain": tg,
        "taxable_loss": tl,
        "total_gain": _n_add(eg - el, tg) - tl,
    }


def fifo_consume(sim: dict, name: str, trade_count: float) -> None:
    ext = _env.ext()
    if ext is not None:
        ext.sim_fifo_consume(sim, name, trade_count)
        return
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


def _update_fifo_front(buys: list, front_index: int) -> int:
    while front_index <= len(buys):
        b = buys[front_index - 1]
        if not b:
            break
        if b["remaining"] > 0:
            return front_index
        front_index += 1
    return front_index


# ═══════════════════════════════════════════════════════════════════════════
# tax_core.cpp
# ═══════════════════════════════════════════════════════════════════════════

def flat_rate(buys: list, front_index: int, base_rate: float, year_start_price: float,
              market_price: float, soy_days: int, eoy_days: int) -> dict:
    """Vorabpauschale je Lot (``flat_rate_rcpp``): Bezug Jahresanfangskurs, Deckel, Zwölftelung."""
    ext = _env.ext()
    if ext is not None:
        return ext.sim_flat_rate(buys, front_index, base_rate, year_start_price, market_price, soy_days, eoy_days)
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
            months_factor = 1.0
            if buy_days >= soy_days:
                _, m, _ = ymd(buy_days)
                months_factor = (12.0 - (m - 1)) / 12.0
            reference_value = rem * year_start_price
            base_worth = reference_value * base_rate * 0.7
            market_worth = rem * market_price
            growth = _max(0.0, market_worth - reference_value)
            vp = _max(0.0, _min(base_worth, growth)) * months_factor
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
    ext = _env.ext()
    if ext is not None:
        return ext.sim_p20_tax(trade_gain, bonus, totals, tax_rate, use_spb)
    # NaN-Nutzlast: Operandenfolge des R-Baus über n_add/n_mul (siehe Modulanfang)
    adjusted_gain = _n_mul(1.0 - bonus, trade_gain)
    if adjusted_gain < 0:
        totals["loss_capital_gains"] = totals["loss_capital_gains"] - adjusted_gain
        totals["cgt_loss_added_ytd"] = _tget(totals, "cgt_loss_added_ytd") - adjusted_gain
        return {"tax": 0.0, "spb_used": 0.0}
    pool = totals["loss_capital_gains"]
    loss_offset = _min(adjusted_gain, pool)
    totals["loss_capital_gains"] = pool - loss_offset
    totals["cgt_loss_used_ytd"] = _n_add(_tget(totals, "cgt_loss_used_ytd"), loss_offset)
    gain_after_loss = adjusted_gain - loss_offset
    spb_offset = 0.0
    spb_rem = totals["sparer_pauschbetrag_remaining"]
    if use_spb and spb_rem > 0:
        spb_offset = _min(gain_after_loss, spb_rem)
        totals["sparer_pauschbetrag_remaining"] = spb_rem - spb_offset
        totals["sparer_pauschbetrag_used_total"] = _n_add(spb_offset, totals["sparer_pauschbetrag_used_total"])
    taxable_gain = gain_after_loss - spb_offset
    totals["cgt_base_taxed_ytd"] = _n_add(_tget(totals, "cgt_base_taxed_ytd"), taxable_gain)
    tax = _n_mul(tax_rate, taxable_gain)
    totals["total_taxes"] = _n_add(tax, totals["total_taxes"])
    return {"tax": tax, "spb_used": spb_offset}


def vp_tax(flat_rate_value: float, bonus: float, totals: dict, tax_rate: float, use_spb: bool) -> dict:
    ext = _env.ext()
    if ext is not None:
        return ext.sim_vp_tax(flat_rate_value, bonus, totals, tax_rate, use_spb)
    taxable_flat_rate = _n_mul(1.0 - bonus, flat_rate_value)
    pool = totals["loss_capital_gains"]
    loss_offset = _min(taxable_flat_rate, pool)
    totals["loss_capital_gains"] = pool - loss_offset
    totals["cgt_loss_used_ytd"] = _n_add(_tget(totals, "cgt_loss_used_ytd"), loss_offset)
    vp_after_loss = taxable_flat_rate - loss_offset
    spb_offset = 0.0
    spb_rem = totals["sparer_pauschbetrag_remaining"]
    if use_spb and spb_rem > 0:
        spb_offset = _min(vp_after_loss, spb_rem)
        totals["sparer_pauschbetrag_remaining"] = spb_rem - spb_offset
        totals["sparer_pauschbetrag_used_total"] = _n_add(spb_offset, totals["sparer_pauschbetrag_used_total"])
    taxable_gain = vp_after_loss - spb_offset
    totals["cgt_base_taxed_ytd"] = _n_add(_max(0.0, taxable_gain), _tget(totals, "cgt_base_taxed_ytd"))
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
    x = rem * prices[lot_idx - 1]
    c = prev_cost + x
    if c != c:
        c = _n_add(x, prev_cost)                 # R: rem * price + prev_cost
    return c / units


def _cfloor(x: float) -> float:
    """C ``floor`` (NaN und ±Inf unverändert, statt Ausnahme)."""
    return float(math.floor(x)) if math.isfinite(x) else x


def _cceil(x: float) -> float:
    return float(math.ceil(x)) if math.isfinite(x) else x


def sell_count(buys: list, front_index: int, target: float, trade_price: float,
               total_shares: float, fractions: bool, regime: int, bonus: float,
               loss_pool: float, tax_rate: float) -> dict:
    """Verkaufsstückzahl für einen Ziel-Nettoerlös (``sell_count_rcpp``)."""
    ext = _env.ext()
    if ext is not None:
        return ext.sim_sell_count(buys, front_index, target, trade_price, total_shares, fractions, regime, bonus,
                                  loss_pool, tax_rate)
    zero = {"sell_count": 0.0, "fifo_price": 0.0}
    n = len(buys)
    if front_index > n:
        return zero
    units: list[float] = []
    prices: list[float] = []
    vpu: list[float] = []
    any_vp = False
    for i in range(front_index, n + 1):
        b = buys[i - 1]
        if not b:
            break
        rem = b["remaining"]
        if rem > 0:
            units.append(rem)
            prices.append(b["price"])
            lot_vp = b.get("vp", 0.0)
            v = lot_vp / rem if (regime == 1 and lot_vp > 0) else 0.0
            if v > 0:
                any_vp = True
            vpu.append(v)
    if not units:
        return zero
    nl = len(units)
    cu: list[float]
    cc: list[float]
    cv: list[float]
    if nl >= 16:
        # Etappe 7.1: dieselben long-double-Summen ab 0 (np.cumsum mit dtype=LD läuft
        # fortlaufend wie die Schleife darunter; Produkte u * p in double wie dort)
        ua = np.array(units)
        z = np.zeros(1)
        cu = np.cumsum(np.concatenate((z, ua)), dtype=LD)[1:].astype(np.float64).tolist()
        cc = np.cumsum(np.concatenate((z, ua * np.array(prices))), dtype=LD)[1:].astype(np.float64).tolist()
        cv = np.cumsum(np.concatenate((z, ua * np.array(vpu))), dtype=LD)[1:].astype(np.float64).tolist()
    else:
        cu = []
        cc = []
        cv = []
        su = LD(0)
        sc = LD(0)
        sv = LD(0)
        for u, p, v in zip(units, prices, vpu):
            su += LD(u)
            cu.append(float(su))
            sc += LD(u * p)
            cc.append(float(sc))
            sv += LD(u * v)
            cv.append(float(sv))

    def fifo_vp(sell: float) -> float:
        if not any_vp or sell <= 0:
            return 0.0
        if sell >= cu[nl - 1]:
            return cv[nl - 1]
        lot = 0
        while lot < nl and cu[lot] < sell:
            lot += 1
        if lot >= nl:
            lot = nl - 1
        prev_u = cu[lot - 1] if lot > 0 else 0.0
        prev_v = cv[lot - 1] if lot > 0 else 0.0
        return prev_v + (sell - prev_u) * vpu[lot]

    def objective(sell: float) -> float:
        if sell <= 0:
            return -target
        if sell > total_shares:
            sell = total_shares
        fp = _fifo_fast(sell, cu, cc, prices)
        gain = (trade_price - fp) * sell
        tax = 0.0
        if regime == 1:
            adj = (gain - fifo_vp(sell)) * (1.0 - bonus)
            tax = _max(adj - loss_pool, 0.0) * tax_rate
        elif regime == 2:
            tax = _max(gain - loss_pool, 0.0) * tax_rate
        return sell * trade_price - tax - target

    initial = _dv(target, trade_price)
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
        tl = _cfloor(sell)
        tu = _cceil(sell)
        if tl < 1:
            tl = 1.0
        if tu > total_shares:
            tu = total_shares
        sell = tl if math.fabs(objective(tl)) <= math.fabs(objective(tu)) else tu

    final_fp = _fifo_fast(sell, cu, cc, prices)
    out = _max(0.0, _min(sell, total_shares))
    return {"sell_count": float(out), "fifo_price": final_fp}
