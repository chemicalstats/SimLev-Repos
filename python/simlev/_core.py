"""Rechenkerne der Engine (Python-Hüllen).

Die Funktionen rufen die C++-Kerne aus ``simulation_core_impl.h``, ``fifo_core_impl.h`` und
``tax_core_impl.h`` über die C-Erweiterung ``simlev._ext`` auf, mit denselben Quellen wie R
(kanonisch in ``core/``, Etappe 9.6c). Die reinen Python-Ports als Rückfall
(``SIMLEV_NO_EXT=1``) sind mit Etappe 9.6c entfallen; die Erweiterung ist Pflicht.

Der Simulationszustand ``sim`` ist ein ``dict`` mit den Teilen ``assets``,
``status``, ``market``, ``trades``, ``report`` und ``totals`` – analog zu
``sim_mem`` im R-Paket. Lots werden als ``dict`` in ``trades[name]["buys"]``
geführt; ``fifo_front`` ist wie im Original 1-basiert.
"""
from __future__ import annotations

from . import _ext


# ═══════════════════════════════════════════════════════════════════════════
# simulation_core.cpp
# ═══════════════════════════════════════════════════════════════════════════

def dca_flows_allocation(sim: dict, name: str, flows: float, index: int) -> None:
    _ext.sim_dca_flows(sim, name, flows, index)


def calculate_buy_report(sim: dict, name: str, index: int, trade_count: float,
                         trade_price: float, market_price: float) -> None:
    _ext.sim_buy_report(sim, name, index, trade_count, trade_price, market_price)


def calculate_sell_report(sim: dict, name: str, index: int, trade_count: float,
                          trade_price: float, market_price: float,
                          capital_gains_tax: float) -> None:
    _ext.sim_sell_report(sim, name, index, trade_count, trade_price, market_price, capital_gains_tax)


def calculate_total_report(sim: dict, assets: list[str], index: int) -> None:
    _ext.sim_total_report(sim, assets, index)


def perform_trade_buy_cpp(sim: dict, name: str, index: int, trade_count: float,
                          trade_price: float, market_price: float) -> None:
    _ext.sim_buy(sim, name, index, trade_count, trade_price, market_price)


def perform_market_update(sim: dict, assets: list[str], index: int) -> None:
    _ext.sim_market_update(sim, assets, index)


def batch_market_update(sim: dict, assets: list[str], start_idx: int, end_idx: int) -> None:
    _ext.sim_market_update_batch(sim, assets, start_idx, end_idx)


# ═══════════════════════════════════════════════════════════════════════════
# fifo_core.cpp
# ═══════════════════════════════════════════════════════════════════════════

def _calculate_fifo_price(buys: list, units: float, front_index: int) -> float:
    return _ext.sim_fifo_price(buys, units, front_index)


def _calculate_fifo_vorabpauschale(buys: list, units: float, front_index: int) -> float:
    return _ext.sim_fifo_vp(buys, units, front_index)


def _calculate_private_sale_tax(buys: list, front_index: int, trade_count: float,
                               sell_price: float, current_date: int) -> dict:
    return _ext.sim_private_sale_tax(buys, front_index, trade_count, sell_price, current_date)


def fifo_consume(sim: dict, name: str, trade_count: float) -> None:
    _ext.sim_fifo_consume(sim, name, trade_count)


def _update_fifo_front(buys: list, front_index: int) -> int:
    """Erstes Lot mit Restbestand ab ``front_index`` (1-basiert; Hilfe von ``_sim_base`` bei Splits)."""
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
    return _ext.sim_flat_rate(buys, front_index, base_rate, year_start_price, market_price, soy_days, eoy_days)


def p20_tax(trade_gain: float, bonus: float, totals: dict, tax_rate: float, use_spb: bool) -> dict:
    return _ext.sim_p20_tax(trade_gain, bonus, totals, tax_rate, use_spb)


def vp_tax(flat_rate_value: float, bonus: float, totals: dict, tax_rate: float, use_spb: bool) -> dict:
    return _ext.sim_vp_tax(flat_rate_value, bonus, totals, tax_rate, use_spb)


def sell_count(buys: list, front_index: int, target: float, trade_price: float,
               total_shares: float, fractions: bool, regime: int, bonus: float,
               loss_pool: float, tax_rate: float) -> dict:
    """Verkaufsstückzahl für einen Ziel-Nettoerlös (``sell_count_rcpp``)."""
    return _ext.sim_sell_count(buys, front_index, target, trade_price, total_shares, fractions, regime, bonus,
                              loss_pool, tax_rate)
