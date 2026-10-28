"""Phasen 3 bis 5 von ``simulation()``: Zahlungs- und Abrechnungshelfer ``_Actions``, Tagesschleife mit den
Tagesschritten ``_sim_day_*`` und Abschluss des letzten Jahres (nachgebildet aus ``r/R/sim_actions.R`` und
``r/R/sim_loop.R``; Julia: ``sim_loop.jl``).
"""
from __future__ import annotations

import copy
import math
import warnings

import numpy as np

from . import _core as core
from ._dates import days_from_civil, fmt_date, year_of
from ._r.rformat import r_format1
from ._r.rnum import r_sum
from ._r.rnum import NA_REAL as NA  # R's NA_real_ (Nutzlast 1954)
from ._sim_base import (
    _FEE,
    _Frame,
    _apply_spread,
    _calculate_buy_signal,
    _calculate_flat_rate,
    _calculate_fund_fees,
    _calculate_sell_count,
    _calculate_sell_signal,
    _cat,
    _fee_amount,
    _handle_year_change,
    _is_true,
    _perform_asset_split,
    _perform_gain_harvest,
    _perform_trade_buy,
    _perform_trade_sell,
    _rmax,
    _rmin,
    _sp,
    _tariff_book,
    _tariff_close,
    _warn,
)


# Phase 3: Zahlungs- und Abrechnungshelfer (sim_actions.R)
# ═══════════════════════════════════════════════════════════════════════════

class _Actions:
    """Helfer der Tagesschleife (R: ``.sim_make_actions``); teilt ``tax_unpaid_total``."""

    def __init__(self, cfg: dict, fl: dict, details: bool):
        self.cfg = cfg
        self.fl = fl
        self.details = details
        self.tax_unpaid_total = 0.0

    # ── Kauf mit Sparplan- bzw. Ordergebühr ─────────────────────────────────
    def buy_with_fee(self, sim: dict, name: str, time: int, reason: str) -> dict:
        cfg, fl = self.cfg, self.fl
        sr = fl["spread_rates"][name]
        if cfg["fees_on"] and fl["flag_dca"][time - 1] and fl["strategy_types"][name] == "bnh":
            money = sim["status"][name]["money"]
            dca_part = _rmin(_rmax(0.0, sim["report"][name]["flows"][time - 1]), money)
            if time == 1 and money - dca_part > 0.005:
                _FEE.current = cfg["fee_order"]
                sim["status"][name]["money"] = money - dca_part
                sim = _perform_trade_buy(sim, name, time, reason, sr, cfg["fractions"], self.details)
                sim["status"][name]["money"] = sim["status"][name]["money"] + dca_part
            _FEE.current = cfg["fee_dca"]
        sim = _perform_trade_buy(sim, name, time, reason, sr, cfg["fractions"], self.details)
        if cfg["fees_on"]:
            _FEE.current = cfg["fee_order"]
        return sim

    def _sell(self, sim, name, time, reason, spread, count=None, price=None, tax_mode=None):
        cfg = self.cfg
        return _perform_trade_sell(sim, name, time, cfg["tax_mode"] if tax_mode is None else tax_mode,
                                   cfg["tax_rate"], cfg["effective_tax_rate"], cfg["marginal_tax_rate"],
                                   cfg["private_sale_threshold"], cfg["use_sparer_pauschbetrag"],
                                   self.fl["tax_regimes"][name], reason, spread, self.details, count=count, price=price)

    # ── Verkaufsmenge nach Steuer und Gebühr ────────────────────────────────
    def sell_count_net(self, sim: dict, name: str, need: float, time: int, round_up: bool = False) -> dict:
        cfg, fl = self.cfg, self.fl
        fr_ = cfg["fractions"] or round_up

        def sc_of(target):
            return _calculate_sell_count(sim, name, target, time, fl["spread_rates"][name], fr_, cfg["tax_mode"],
                                         cfg["effective_tax_rate"], fl["tax_regimes"][name])
        fee = _FEE.current
        target = need
        if fee is not None:
            px = _apply_spread(float(sim["market"][name]["asset_price"][time - 1]), fl["spread_rates"][name], "sell")
            for _ in range(3):
                target = need + _fee_amount(fee, _rmax(sc_of(target)["sell_count"], 1e-12) * px)
        res = sc_of(target)
        if round_up and not cfg["fractions"] and res["sell_count"] > 0:
            res = {"sell_count": _rmin(sim["status"][name]["count"], float(math.ceil(res["sell_count"] - 1e-9))),
                   "fifo_price": None}
        return res

    # ── Bargeld für Fondskosten ────────────────────────────────────────────
    def raise_cash(self, sim: dict, name: str, need: float, time: int, reason: str) -> dict:
        cfg = self.cfg
        short = need - sim["status"][name]["money"]
        if short <= 0 or sim["status"][name]["count"] <= 0:
            return sim
        fee_keep = _FEE.current
        _FEE.current = None
        try:
            if cfg["tax_mode"] != "person":
                px = float(sim["market"][name]["asset_price"][time - 1])
                n_sell = _rmin(sim["status"][name]["count"],
                               short / px if cfg["fractions"] else float(math.ceil(short / px - 1e-9)))
            else:
                n_sell = _calculate_sell_count(sim, name, short, time, 0.0, cfg["fractions"], cfg["tax_mode"],
                                               cfg["effective_tax_rate"], self.fl["tax_regimes"][name])["sell_count"]
            sim = self._sell(sim, name, time, reason, 0.0, count=n_sell)
            if not cfg["fractions"] and sim["status"][name]["money"] < need - 1e-9 and sim["status"][name]["count"] > 0:
                sim = self._sell(sim, name, time, reason, 0.0, count=_rmin(1.0, sim["status"][name]["count"]))
        finally:
            _FEE.current = fee_keep
        return sim

    # ── Zahlung aus einem Asset ────────────────────────────────────────────
    def pay_one(self, sim: dict, name: str, amount: float, time: int, label: str) -> tuple[dict, float]:
        cfg, fl, details = self.cfg, self.fl, self.details
        fd = fmt_date(int(fl["flag_date"][time - 1]))
        money = sim["status"][name]["money"]
        if money >= amount:
            sim["status"][name]["money"] = money - amount
            if details:
                _cat(_sp("Steuerereignis:\tZahlung %s %.2f EUR f\u00fcr %s aus dem Geldbestand am %s\n",
                         label, amount, name, fd))
            return sim, 0.0
        remaining = amount
        if money > 0:
            remaining = amount - money
            sim["status"][name]["money"] = 0.0
            if details:
                _cat(_sp("Steuerereignis:\tTeilzahlung %s %.2f EUR aus dem Geldbestand am %s\n", label, money, fd))
        c0 = sim["status"][name]["money"]

        def raised(sm):
            return sm["status"][name]["money"] - c0
        for k in range(1, 11):
            short = remaining - raised(sim)
            if short <= 0.005 or sim["status"][name]["count"] <= 0:
                break
            sell_result = self.sell_count_net(sim, name, short, time, round_up=True)
            n_sell = sell_result["sell_count"]
            if k > 1 or not (n_sell > 0):
                cnt = sim["status"][name]["count"]
                n_sell = _rmax(n_sell, _rmin(cnt, 1e-6) if cfg["fractions"] else _rmin(1.0, cnt))
            before = raised(sim)
            sim = self._sell(sim, name, time, "Steuerereignis:", fl["spread_rates"][name], count=n_sell,
                             price=sell_result["fifo_price"])
            if raised(sim) <= before:
                break
        short = remaining - raised(sim)
        unpaid = 0.0
        if short <= 0.005:
            sim["status"][name]["money"] = sim["status"][name]["money"] - remaining
        else:
            sim["status"][name]["money"] = c0
            unpaid = short
        if details and remaining - unpaid > 0:
            _cat(_sp("\t\t=> Anteile verkauft f\u00fcr den Rest von %.2f EUR (%s)\n", remaining - unpaid, label))
        return sim, unpaid

    # ── Steuerzahlung mit Rückgriff auf die übrigen Assets ──────────────────
    def pay_tax(self, sim: dict, name: str, amount: float, time: int, label: str) -> dict:
        fl = self.fl
        sim, unpaid = self.pay_one(sim, name, amount, time, label)
        if unpaid > 1e-6:
            others = [nm for nm in fl["flag_assets"] if nm != name]
            val = {nm: sim["status"][nm]["count"] * float(sim["market"][nm]["asset_price"][time - 1]) +
                   _rmax(0.0, sim["status"][nm]["money"]) for nm in others}
            order = sorted(range(len(others)), key=lambda i: -val[others[i]])
            for i in order:
                nm = others[i]
                if unpaid <= 1e-6:
                    break
                if not (val[nm] > 0):
                    continue
                sim, unpaid = self.pay_one(sim, nm, unpaid, time, label)
        if unpaid > 1e-6:
            sim["status"][name]["money"] = sim["status"][name]["money"] - unpaid
            self.tax_unpaid_total = self.tax_unpaid_total + unpaid
            _warn(_sp("simulation: %s von %.2f EUR am %s: das Depot reicht nicht aus; %.2f EUR bleiben als negativer "
                      "Geldbestand (Steuerschuld) bei '%s'.", label, amount, fmt_date(int(fl["flag_date"][time - 1])),
                      unpaid, name))
        return sim

    # ── Vorabpauschale bezahlen ───────────────────────────────────────────
    def pay_vp(self, sim: dict, name: str, tax_debt: float, time: int, meta: dict, prepaid: float = 0.0) -> dict:
        if prepaid == 0:
            sim = self.pay_tax(sim, name, tax_debt, time, "Vorabpauschale")
        elif tax_debt - prepaid > 1e-9:
            sim = self.pay_tax(sim, name, tax_debt - prepaid, time, "Vorabpauschale")
        elif tax_debt - prepaid < -1e-9:
            sim["status"][name]["money"] = sim["status"][name]["money"] + (prepaid - tax_debt)
        sim["totals"]["total_taxes"] = sim["totals"]["total_taxes"] + tax_debt
        entry = {"event_date": int(self.fl["flag_date"][time - 1]), "assessment_date": meta["assessment_date"],
                 "event_type": "Vorabpauschale", "flat_rate_gross": meta["flat_rate"],
                 "bonus_applied": meta["bonus"], "flat_rate_taxable": meta["flat_rate"] * (1 - meta["bonus"]),
                 "spb_used": meta["spb_used"], "taxes_paid": tax_debt}
        tr = sim["trades"][name]
        tr["tax_count"] += 1
        tr["taxes"].append(entry)
        return sim

    # ── § 23-Steuer bzw. Nachzahlung der Veranlagung ───────────────────────
    def settle_p23(self, sim: dict, time: int) -> dict:
        tariff_env = self.cfg["tariff_env"]
        details = self.details
        due = sim["totals"].pop("p23_due", None) or {}
        info = tariff_env.due_info if tariff_env is not None else None
        if tariff_env is not None:
            tariff_env.due_info = None
        fd = fmt_date(int(self.fl["flag_date"][time - 1]))
        label = ("Steuer aus der Veranlagung %s" % "/".join(str(i["year"]) for i in info)) if info else "\u00a7 23-Steuer"
        if details and info and any(v > 0 for v in due.values()):
            for i in info:
                rest = i["D"] - i["p23"] - i["ded"]
                _cat(_sp("Steuerereignis:\tVeranlagung %d: Nachzahlung %.2f EUR (davon \u00a7 23 %.2f EUR, "
                         "Kirchensteuer-Sonderausgaben %.2f EUR%s) am %s, aufgeteilt %s\n", i["year"], i["D"], i["p23"],
                         i["ded"], _sp(", G\u00fcnstigerpr\u00fcfung %.2f EUR", rest) if abs(rest) >= 0.005 else "", fd,
                         "nach dem \u00a7 23-Jahressaldo je Asset" if i["by_p23"] else "zu gleichen Teilen auf die Assets"))
        for nm, v in due.items():
            if not (v > 0):
                continue
            if details:
                if info:
                    _cat(_sp("\t\t=> Anteil %s: %.2f EUR\n", nm, v))
                else:
                    _cat(_sp("Steuerereignis:\t\u00a7 23 EStG: Steuer %.2f EUR (%s) am %s\n", v, nm, fd))
            sim = self.pay_tax(sim, nm, v, time, label)
            tr = sim["trades"][nm]
            tr["tax_count"] += 1
            tr["taxes"].append({"event_date": int(self.fl["flag_date"][time - 1]), "event_type": "Private sale tax",
                                "taxes_paid": v})
        return sim

    # ── Erstattung aus der Günstigerprüfung ───────────────────────────────
    def gp_pending(self) -> bool:
        te = self.cfg["tariff_env"]
        return te is not None and te.refund_due > 0

    def settle_gp(self, sim: dict, time: int) -> dict:
        te = self.cfg["tariff_env"]
        refund = te.refund_due
        te.refund_due = 0.0
        fa = self.fl["flag_assets"]
        w = [float(sim["status"][nm].get("actual") if sim["status"][nm].get("actual") is not None else 0.0)
             for nm in fa]
        sw = r_sum(w)
        w = [x / sw for x in w] if sw > 0 else [1 / len(fa)] * len(fa)
        for nm, wi in zip(fa, w):
            sim["status"][nm]["money"] = sim["status"][nm]["money"] + refund * wi
        if self.details:
            _cat(_sp("Steuerereignis:\tG\u00fcnstigerpr\u00fcfung: Erstattung %.2f EUR in den Geldbestand am %s\n",
                     refund, fmt_date(int(self.fl["flag_date"][time - 1]))))
        return sim

    # ── Steuer der offenen Vorabpauschalen ─────────────────────────────────
    def vp_taxes(self, sim: dict, pend: list) -> tuple[dict, list]:
        cfg = self.cfg
        res: list = [None] * len(pend)
        if len(pend) > 1:
            taxable = [p["flat_rate"] * (1 - p["bonus"]) for p in pend]
            st = r_sum(taxable)
            pooled = core.vp_tax(st, 0.0, sim["totals"], cfg["effective_tax_rate"], cfg["use_sparer_pauschbetrag"])
            share = [t / st for t in taxable] if st > 0 else [1 / len(pend)] * len(pend)
            for j in range(len(pend)):
                res[j] = {"tax": pooled["tax"] * share[j], "spb_used": pooled["spb_used"] * share[j]}
        elif len(pend) == 1:
            p = pend[0]
            r1 = core.vp_tax(p["flat_rate"], p["bonus"], sim["totals"], cfg["effective_tax_rate"],
                             cfg["use_sparer_pauschbetrag"])
            res[0] = {"tax": r1["tax"], "spb_used": r1["spb_used"]}
        return sim, res

    # ── Zufluss der festgesetzten Vorabpauschalen ──────────────────────────
    def settle_vp(self, sim: dict, time: int, prepaid: list | None = None) -> dict:
        pend = sim["totals"].pop("vp_pending", None) or []
        sim, res = self.vp_taxes(sim, pend)
        fd = fmt_date(int(self.fl["flag_date"][time - 1]))
        for j, p in enumerate(pend):
            result = res[j]
            pre = 0.0 if prepaid is None else prepaid[j]
            if self.details:
                _cat(_sp("Steuerereignis:\tVorabpauschale %s (festgesetzt %s): %.2f EUR, nach TFS %.2f EUR, SPB %.2f EUR, "
                         "Steuer %.2f EUR am %s\n", p["name"], fmt_date(p["assessment_date"]), p["flat_rate"],
                         p["flat_rate"] * (1 - p["bonus"]), result["spb_used"], result["tax"], fd))
            if result["tax"] > 0 or pre > 0:
                sim = self.pay_vp(sim, p["name"], result["tax"], time,
                                  {"flat_rate": p["flat_rate"], "bonus": p["bonus"], "spb_used": result["spb_used"],
                                   "assessment_date": p["assessment_date"]}, prepaid=pre)
        return sim


# ═══════════════════════════════════════════════════════════════════════════
# Phase 4: Tagesschleife (sim_loop.R)
# ═══════════════════════════════════════════════════════════════════════════

def _sim_run_days(sim: dict, fl: dict, cfg: dict, act: _Actions, fr: _Frame, strategy: dict, liquidate,
                  event_weight, split_thresh, funds_fee, bonus_fee, balance_dca, harvest_loss_pot,
                  details: bool) -> dict:
    flag_date, flag_assets = fl["flag_date"], fl["flag_assets"]
    flag_rebalance = fl["flag_rebalance"].copy()
    flag_trade = fl["flag_trade"].copy()
    fl = dict(fl)
    fl["flag_rebalance"], fl["flag_trade"] = flag_rebalance, flag_trade
    tax_mode = cfg["tax_mode"]
    prev_end = 0
    active_assets: list = []
    for time in fl["individual_days"]:
        t0 = time - 1
        if time > prev_end + 1:
            core.batch_market_update(sim, flag_assets, prev_end + 1, time - 1)
        if fl["flag_year_change"][t0]:
            sim = _handle_year_change(sim, int(flag_date[t0]), cfg["marginal_tax_rate"], cfg["private_sale_threshold"],
                                      cfg["sparer_pauschbetrag"], cfg["use_sparer_pauschbetrag"],
                                      cfg["soli_factor_income"], cfg["effective_tax_rate"], details, cfg["church_k"],
                                      cfg["tariff_env"])
        if not fl["flag_slow_path"][t0]:
            core.perform_market_update(sim, flag_assets, time)
            prev_end = time
            continue
        if fl["flag_active"][t0] or len(active_assets) == 0:
            active_assets = [nm for nm, si in zip(flag_assets, fl["asset_start_indices"]) if si <= time]
        if cfg["fees_on"]:
            _FEE.current = cfg["fee_order"]
        flag_fast_report = True
        if tax_mode == "person" and fl["flag_vp_settle"][t0] and (sim["totals"].get("vp_pending") or
                                                                   sim["totals"].get("p23_due") or act.gp_pending()):
            if sim["totals"].get("vp_pending"):
                sim = act.settle_vp(sim, time)
            if sim["totals"].get("p23_due"):
                sim = act.settle_p23(sim, time)
            if act.gp_pending():
                sim = act.settle_gp(sim, time)
            core.calculate_total_report(sim, flag_assets, time)
            flag_fast_report = False
        if fl["flag_active"][t0]:
            sim, rebalance_now = _sim_day_activate(sim, time, active_assets, fl, cfg, details)
            if rebalance_now:
                flag_rebalance[t0] = True
                flag_trade[t0] = False
            flag_fast_report = False
        if fl["flag_split"][t0]:
            sim = _sim_day_split(sim, time, active_assets, fl, cfg, act, split_thresh, details)
            flag_fast_report = False
        if fl["flag_dca"][t0]:
            sim = _sim_day_dca(sim, time, active_assets, fl, cfg, strategy, balance_dca, details)
            flag_fast_report = False
        if flag_trade[t0]:
            sim, traded = _sim_day_trade(sim, time, active_assets, fl, cfg, act, details)
            if traded:
                flag_fast_report = False
        if flag_rebalance[t0]:
            sim = _sim_day_rebalance(sim, time, active_assets, fl, cfg, act, fr, event_weight, details)
            flag_fast_report = False
        if fl["flag_harvest"][t0]:
            sim = _sim_day_harvest(sim, time, active_assets, fl, cfg, harvest_loss_pot, details)
            flag_fast_report = False
        if fl["flag_taxes"][t0]:
            sim = _sim_day_assess_vp(sim, time, fl, cfg, liquidate, details)
            flag_fast_report = False
        if fl["flag_fund_fee"][t0]:
            sim = _sim_day_fund_fee(sim, time, fl, act, funds_fee, bonus_fee, details)
            flag_fast_report = False
        if fl["flag_liquidate"][t0]:
            sim = _sim_day_liquidate(sim, time, fl, cfg, act, details)
            flag_fast_report = False
        if flag_fast_report:
            core.perform_market_update(sim, flag_assets, time)
        prev_end = time
    if prev_end < fl["n_total_days"]:
        core.batch_market_update(sim, flag_assets, prev_end + 1, fl["n_total_days"])
    return sim


def _sim_day_activate(sim, time, active_assets, fl, cfg, details):
    flag_assets, flag_date, asset_starts = fl["flag_assets"], fl["flag_date"], fl["asset_starts"]
    initial_assets = fl["initial_assets"]
    t0 = time - 1
    rebalance_now = False
    for nm in flag_assets:
        if nm in active_assets:
            continue
        for key in ("signal_buy", "signal_sell"):
            arr = sim["market"][nm][key]
            arr[t0] = 0.0 if arr.dtype == np.float64 else False
    today = int(flag_date[t0])
    late_now = any(sd == today and nm not in initial_assets for nm, sd in zip(flag_assets, asset_starts))
    if cfg["balance_mode"] or late_now:
        cws = r_sum([sim["status"][nm]["actual"] for nm in active_assets])
        for nm in active_assets:
            sim["status"][nm]["differ"] = sim["status"][nm]["actual"] / cws
        if details:
            new_assets = [nm for nm, sd in zip(flag_assets, asset_starts) if sd == today]
            if new_assets:
                _cat("Marktereignis:\tHandel mit %s ab jetzt m\u00f6glich.\n" % ", ".join(new_assets))
        rebalance_now = True
    core.calculate_total_report(sim, flag_assets, time)
    return sim, rebalance_now


def _sim_day_split(sim, time, active_assets, fl, cfg, act, split_thresh, details):
    flag_assets, flag_date = fl["flag_assets"], fl["flag_date"]
    t0 = time - 1
    lo, hi = float(split_thresh[0]), float(split_thresh[1])
    held = [nm for nm in active_assets if sim["status"][nm]["count"] > 0]
    for nm in [x for x in flag_assets if x not in held]:
        px0 = float(sim["market"][nm]["asset_price"][t0])
        if px0 > hi or px0 < lo:
            sim["market"][nm]["asset_price"] = sim["market"][nm]["asset_price"] / (px0 / 100)
            if details:
                _cat("Split-Ereignis:\t%s ohne Bestand: Kursreihe %s %s am %s\n"
                     % (nm, "1 :" if px0 > hi else ": 1",
                        r_format1(px0 / 100 if px0 > hi else 100 / px0, digits=5), fmt_date(int(flag_date[t0]))))
    for nm in active_assets:
        if sim["status"][nm]["count"] > 0:
            split_price = float(sim["market"][nm]["asset_price"][t0])
            if split_price > hi:
                sim = _perform_asset_split(sim, nm, split_price / 100, time, "forward", cfg["fractions"], details,
                                           int(flag_date[t0]))
            if split_price < lo:
                sim = _perform_asset_split(sim, nm, 100 / split_price, time, "reverse", cfg["fractions"], details,
                                           int(flag_date[t0]))
            split_cnt = sim["status"][nm]["count"]
            split_frac = split_cnt - math.floor(split_cnt + 1e-9)
            if not cfg["fractions"] and split_frac > 1e-9:
                fee_keep = _FEE.current
                _FEE.current = None
                sim = act._sell(sim, nm, time, "Split:", 0.0, count=split_frac)
                _FEE.current = fee_keep
    core.calculate_total_report(sim, flag_assets, time)
    return sim


def _sim_day_dca(sim, time, active_assets, fl, cfg, strategy, balance_dca, details):
    flag_assets, flag_date = fl["flag_assets"], fl["flag_date"]
    t0 = time - 1
    dca_amount = cfg["dca_value"] * fl["flag_dca_n"][t0]
    strat_w = np.array([float(strategy[nm]["share"]) for nm in active_assets], dtype=np.float64)
    strat_w = strat_w / r_sum(strat_w, na_rm=True)
    if balance_dca and len(active_assets) > 1:
        core.calculate_total_report(sim, flag_assets, time)
        totals_now = np.array([sim["status"][nm]["total"] for nm in active_assets], dtype=np.float64)
        desired = strat_w * (r_sum(totals_now, na_rm=True) + dca_amount)
        deficit = np.maximum(0.0, desired - totals_now)
        if r_sum(deficit) > dca_amount:
            alloc = dca_amount * deficit / r_sum(deficit)
        else:
            alloc = deficit + (dca_amount - r_sum(deficit)) * strat_w
        for nm, v in zip(active_assets, alloc):
            core.dca_flows_allocation(sim, nm, float(v), time)
    else:
        for nm, w in zip(active_assets, strat_w):
            core.dca_flows_allocation(sim, nm, float(w) * dca_amount, time)
    if details:
        parts = "; ".join(_sp("%s %.2f EUR", nm, sim["report"][nm]["flows"][t0]) for nm in active_assets)
        _cat(_sp("Einzahlung:\t%.2f EUR in das Depot am %s\n\t\t=> ", dca_amount, fmt_date(int(flag_date[t0]))) + parts
             + "\n")
    core.calculate_total_report(sim, flag_assets, time)
    return sim


def _sim_day_trade(sim, time, active_assets, fl, cfg, act, details):
    trade_event = False
    for nm in active_assets:
        f_buy = _calculate_buy_signal(sim, nm, time)
        f_sell = _calculate_sell_signal(sim, nm, time)
        if f_buy:
            sim = act.buy_with_fee(sim, nm, time, "Handelssignal:")
            trade_event = True
        if f_sell:
            sim = act._sell(sim, nm, time, "Handelssignal:", fl["spread_rates"][nm])
            trade_event = True
    if trade_event:
        core.calculate_total_report(sim, fl["flag_assets"], time)
    return sim, trade_event


def _sim_day_rebalance(sim, time, active_assets, fl, cfg, act, fr, event_weight, details):
    flag_assets, flag_date = fl["flag_assets"], fl["flag_date"]
    t0 = time - 1
    fd = fmt_date(int(flag_date[t0]))
    sr = fl["spread_rates"]
    balance_thresh = cfg["balance_thresh"]
    at = np.array([sim["status"][nm]["actual"] for nm in active_assets], dtype=np.float64)
    at = at / r_sum(at, na_rm=True)
    active_targets = dict(zip(active_assets, (float(v) for v in at)))
    if event_weight is not None and bool(fl["flag_event"][t0]):
        ow = []
        for nm in active_assets:
            col = event_weight.get(nm)
            ow.append(NA if col is None else float(fr.get(col)[t0]))
        ow_a = np.array(ow, dtype=np.float64)
        if np.all(np.isfinite(ow_a)) and r_sum(ow_a) > 0:
            ow_a = ow_a / r_sum(ow_a)
            active_targets = dict(zip(active_assets, (float(v) for v in ow_a)))
    signal_cash_only: list = []
    for nm in active_assets:
        if sim["assets"][nm]["style"] == "signal":
            has_pos = sim["status"][nm]["count"] > 0
            sig_buy = _is_true(sim["market"][nm]["signal_buy"][t0])
            sig_sell = _is_true(sim["market"][nm]["signal_sell"][t0])
            if has_pos and sig_sell:
                sim = act._sell(sim, nm, time, "Rebalancing/Signal-Ausstieg:", sr[nm])
                signal_cash_only.append(nm)
            elif not has_pos and sig_buy:
                sim = _perform_trade_buy(sim, nm, time, "Rebalancing/Signal-Einstieg:", sr[nm], cfg["fractions"],
                                         details)
            elif not has_pos and not sig_buy:
                signal_cash_only.append(nm)
    core.calculate_total_report(sim, flag_assets, time)
    actual_weights = {nm: sim["status"][nm]["differ"] for nm in active_assets}
    today = int(flag_date[t0])
    new_asset = any(sd == today for sd in fl["asset_starts"])
    force_rebalance = new_asset
    if force_rebalance and details:
        new_assets = [nm for nm, sd in zip(flag_assets, fl["asset_starts"]) if sd == today]
        _cat("Rebalancing:\tErzwungenes Rebalancing am %s wegen neu handelbarer Assets: %s\n"
             % (fd, ", ".join(new_assets)))
    if force_rebalance:
        event_rebalance = True
    elif balance_thresh is None:
        event_rebalance = True
    else:
        if cfg["balance_thresh_type"] == "relative":
            deviations = [abs(actual_weights[nm] / active_targets[nm] - 1) if active_targets[nm] != 0 else
                          (math.inf if actual_weights[nm] != 0 else NA) for nm in active_assets]
        else:
            deviations = [abs(active_targets[nm] - actual_weights[nm]) for nm in active_assets]
        devs_ok = [x for x in deviations if not math.isnan(x)]
        max_deviation = max(devs_ok) if devs_ok else -math.inf
        event_rebalance = max_deviation > balance_thresh
        if details:
            if event_rebalance:
                _cat(_sp("Rebalancing:\tRebalancing am %s (max. Abweichung: %.2f%% > Schwelle: %.2f%%)\n", fd,
                         max_deviation * 100, balance_thresh * 100))
                for nm, dev in zip(active_assets, deviations):
                    if dev > balance_thresh:
                        _cat(_sp("\t\t=> %s: Ziel=%.1f%%, Ist=%.1f%%, Abweichung=%.2f%%\n", nm, active_targets[nm] * 100,
                                 actual_weights[nm] * 100, dev * 100))
            else:
                _cat(_sp("Rebalancing:\tKein Rebalancing am %s (max. Abweichung: %.2f%% < Schwelle: %.2f%%)\n", fd,
                         max_deviation * 100, balance_thresh * 100))
    if event_rebalance:
        differ_weights = {nm: active_targets[nm] - actual_weights[nm] for nm in active_assets}
        total_strategy = r_sum([sim["status"][nm]["total"] for nm in active_assets], na_rm=True)
        transfer_pool = 0.0
        transfer_value = {nm: abs(differ_weights[nm] * total_strategy) for nm in active_assets}
        for nm in [x for x in active_assets if differ_weights[x] < 0]:
            sell_target = transfer_value[nm] - _rmax(0.0, sim["status"][nm]["money"])
            if sim["status"][nm]["count"] > 0 and sell_target > 0:
                srs = _calculate_sell_count(sim, nm, sell_target, time, sr[nm], cfg["fractions"], cfg["tax_mode"],
                                            cfg["effective_tax_rate"], fl["tax_regimes"][nm])
                sim = act._sell(sim, nm, time, "Rebalancing:", sr[nm], count=srs["sell_count"],
                                price=srs["fifo_price"])
            available_cash = _rmin(sim["status"][nm]["money"], transfer_value[nm])
            transfer_pool = transfer_pool + available_cash
            sim["status"][nm]["money"] = sim["status"][nm]["money"] - available_cash
            if details:
                _cat(_sp("\t\t%.2f EUR von %s in den Rebalancing-Topf\n", available_cash, nm))
        for nm in [x for x in active_assets if differ_weights[x] > 0]:
            allocation = _rmin(transfer_value[nm], transfer_pool)
            if allocation > 0:
                sim["status"][nm]["money"] = sim["status"][nm]["money"] + allocation
                transfer_pool = transfer_pool - allocation
                if details:
                    _cat(_sp("Rebalancing:\t%.2f EUR aus dem Rebalancing-Topf an %s\n", allocation, nm))
                if nm in signal_cash_only:
                    if details:
                        _cat(_sp("\t\t=> %s h\u00e4lt %.2f EUR als Cash-Reserve (Signal inaktiv)\n", nm,
                                 sim["status"][nm]["money"]))
                else:
                    sim = _perform_trade_buy(sim, nm, time, "Rebalancing:", sr[nm], cfg["fractions"], details)
        if transfer_pool > 0.01:
            if details:
                _cat(_sp("\t\tRestverteilung von %.2f EUR aus dem Rebalancing-Topf\n", transfer_pool))
            for nm in active_assets:
                redistribution = active_targets[nm] * transfer_pool
                sim["status"][nm]["money"] = sim["status"][nm]["money"] + redistribution
                if details:
                    _cat(_sp("\t\t=> %.2f EUR an %s\n", redistribution, nm))
    for nm in active_assets:
        st = sim["status"][nm]
        if nm not in signal_cash_only and st["money"] > 0.005 and \
                (sim["assets"][nm]["style"] != "signal" or st["count"] > 0):
            sim = act.buy_with_fee(sim, nm, time, "Rebalancing:")
    core.calculate_total_report(sim, flag_assets, time)
    return sim


def _sim_day_harvest(sim, time, active_assets, fl, cfg, harvest_loss_pot, details):
    if cfg["fees_on"]:
        _FEE.current = cfg["fee_order"]
    for nm in active_assets:
        sim = _perform_gain_harvest(sim, nm, time, fl["tax_regimes"][nm], fl["spread_rates"][nm], cfg["fractions"],
                                    bool(harvest_loss_pot), cfg["use_sparer_pauschbetrag"], cfg["tax_mode"],
                                    cfg["tax_rate"], cfg["effective_tax_rate"], cfg["marginal_tax_rate"],
                                    cfg["private_sale_threshold"], details)
    core.calculate_total_report(sim, fl["flag_assets"], time)
    return sim


def _sim_day_assess_vp(sim, time, fl, cfg, liquidate, details):
    flag_assets, flag_date, flag_filled = fl["flag_assets"], fl["flag_date"], fl["flag_filled"]
    t0 = time - 1
    if cfg["tax_mode"] == "person" and not (bool(liquidate) and fl["flag_liquidate"][t0]):
        for nm in flag_assets:
            regime = fl["tax_regimes"][nm]
            if regime == "investment_fund" and sim["status"][nm]["count"] > 0:
                vp_result = _calculate_flat_rate(sim, nm, time, flag_date, regime, flag_filled)
                flat_rate = vp_result["total_vp"]
                buys_l = sim["trades"][nm]["buys"]
                for vp_i, lv in zip(vp_result["lot_indices"], vp_result["lot_vps"]):
                    lot = buys_l[vp_i - 1]
                    cur = lot.get("vp")
                    lot["vp"] = (0.0 if cur is None else cur) + lv
                if flat_rate > 0:
                    pend = sim["totals"].get("vp_pending")
                    if pend is None:
                        pend = []
                    pend = list(pend) + [{"name": nm, "flat_rate": flat_rate, "bonus": sim["assets"][nm]["bonus"],
                                          "assessment_date": int(flag_date[t0])}]
                    sim["totals"]["vp_pending"] = pend
                    if details:
                        _cat(_sp("Steuerereignis:\tVorabpauschale %s: %.2f EUR festgesetzt am %s (Zufluss und Steuer am "
                                 "ersten Handelstag des Folgejahres)\n", nm, flat_rate, fmt_date(int(flag_date[t0]))))
    core.calculate_total_report(sim, flag_assets, time)
    return sim


def _sim_day_fund_fee(sim, time, fl, act, funds_fee, bonus_fee, details):
    flag_assets, flag_date = fl["flag_assets"], fl["flag_date"]
    core.calculate_total_report(sim, flag_assets, time)
    result_fees = _calculate_fund_fees(sim, time, flag_date, flag_assets, funds_fee, bonus_fee, details)
    sim["totals"]["total_value"] = result_fees["total_value"]
    for nm in flag_assets:
        fee_i = result_fees["asset_fees"][nm]
        if not math.isfinite(fee_i) or fee_i <= 0:
            continue
        if sim["status"][nm]["money"] < fee_i:
            sim = act.raise_cash(sim, nm, fee_i, time, "Fondskosten:")
        paid = _rmin(fee_i, _rmax(0.0, sim["status"][nm]["money"]))
        sim["status"][nm]["money"] = sim["status"][nm]["money"] - paid
        if details:
            _cat(_sp("\t\t=> %.2f EUR Geb\u00fchren von %s abgezogen\n", paid, nm))
        tr = sim["trades"][nm]
        tr["fee_count"] += 1
        tr["fees"].append({"event_date": int(flag_date[time - 1]), "event_type": "Fees", "fees_paid": paid})
    core.calculate_total_report(sim, flag_assets, time)
    return sim


def _sim_day_liquidate(sim, time, fl, cfg, act, details):
    flag_assets, flag_date = fl["flag_assets"], fl["flag_date"]
    tax_mode = cfg["tax_mode"]
    for nm in flag_assets:
        if sim["status"][nm]["count"] > 0:
            tax_type = "person" if tax_mode == "person" else "none"
            sim = act._sell(sim, nm, time, "Liquidation:", fl["spread_rates"][nm], tax_mode=tax_type)
            if sim["status"][nm]["count"] > 0:
                _warn(_sp("simulation: liquidate = TRUE: Position '%s' (Wert %.2f EUR) wurde nicht verkauft, weil die "
                          "Ordergeb\u00fchr den Erl\u00f6s \u00fcbersteigt.", nm, sim["status"][nm]["worth"]))
    if tax_mode == "funds":
        core.calculate_total_report(sim, flag_assets, time)
        final_value = r_sum([sim["status"][x]["total"] for x in flag_assets], na_rm=True)
        deposits = r_sum([r_sum(sim["report"][x]["flows"][:time]) for x in flag_assets])
        total_gains = final_value - cfg["start_value"] - deposits
        if total_gains > 0:
            total_taxes = total_gains * cfg["tax_rate"]
            cash = {x: _rmax(0.0, sim["status"][x]["money"]) for x in flag_assets}
            sc = r_sum(list(cash.values()))
            tax_weights = {x: cash[x] / sc for x in flag_assets} if sc > 0 else \
                {x: 1 / len(flag_assets) for x in flag_assets}
            for nm in flag_assets:
                tpa = _rmin(total_taxes * tax_weights[nm], cash[nm])
                sim["status"][nm]["money"] = sim["status"][nm]["money"] - tpa
                sim["totals"]["total_taxes"] = sim["totals"]["total_taxes"] + tpa
            if details:
                _cat(_sp("Liquidation:\tSteuern %.2f EUR auf den Gesamtgewinn von %.2f EUR am %s\n", total_taxes,
                         total_gains, fmt_date(int(flag_date[time - 1]))))
    core.calculate_total_report(sim, flag_assets, time)
    return sim


# ═══════════════════════════════════════════════════════════════════════════
# Phase 5: Abschluss des letzten Jahres
# ═══════════════════════════════════════════════════════════════════════════

def _sim_close_years(sim: dict, fl: dict, cfg: dict, act: _Actions, stopp_date: int, details: bool) -> dict:
    n_total_days = fl["n_total_days"]
    tariff_env = cfg["tariff_env"]
    next_jan1 = days_from_civil(year_of(stopp_date) + 1, 1, 1)

    def final_year_change(s, te=tariff_env, det=details):
        return _handle_year_change(s, next_jan1, cfg["marginal_tax_rate"], cfg["private_sale_threshold"],
                                   cfg["sparer_pauschbetrag"], cfg["use_sparer_pauschbetrag"],
                                   cfg["soli_factor_income"], cfg["effective_tax_rate"], det, cfg["church_k"], te)
    if cfg["tax_mode"] == "person":
        if sim["totals"].get("vp_pending"):
            vp_year = year_of(sim["totals"]["vp_pending"][0]["assessment_date"])
            prepaid = None
            if sim["totals"]["current_year"] <= vp_year:
                # Probelauf: Jahreswechsel ohne Tarif und vp_taxes ändern nur
                # sim["totals"] und sim["status"] (Etappe 7.1: nur diese tief kopieren,
                # market/trades/report/assets werden nur gelesen und bleiben geteilt)
                dry = dict(sim)
                dry.update(copy.deepcopy({"totals": sim["totals"], "status": sim["status"]}))
                with warnings.catch_warnings():
                    warnings.simplefilter("ignore")
                    dry = final_year_change(dry, None, False)
                pend = sim["totals"]["vp_pending"]
                _, res = act.vp_taxes(dry, pend)
                prepaid = [r["tax"] for r in res]
                for j, p in enumerate(pend):
                    if prepaid[j] > 0:
                        sim = act.pay_tax(sim, p["name"], prepaid[j], n_total_days, "Vorabpauschale")
                sim = final_year_change(sim)
            sim = act.settle_vp(sim, n_total_days, prepaid=prepaid)
        sim = final_year_change(sim)
        if tariff_env is not None:
            y_last = sim["totals"]["current_year"]
            cbt = sim["totals"].get("cgt_base_taxed_ytd") or 0.0
            if tariff_env.use_gp and y_last > year_of(stopp_date) and cbt > 0:
                D = _tariff_close(tariff_env, y_last, 0.0, cbt, cfg["effective_tax_rate"], details)
                sim = _tariff_book(sim, tariff_env, D)
        if sim["totals"].get("p23_due"):
            sim = act.settle_p23(sim, n_total_days)
        if tariff_env is not None and act.gp_pending():
            sim = act.settle_gp(sim, n_total_days)
        core.calculate_total_report(sim, fl["flag_assets"], n_total_days)
    return sim


# ═══════════════════════════════════════════════════════════════════════════
