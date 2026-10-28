"""Port von r/tests/testthat/test-tax-law.R und test-flow-metrics.R (Handrechnungen)."""
import math

import numpy as np
import pandas as pd
import pytest

import simlev
from simlev import asset_config, create_strategy
from simlev.engine import xirr_rate

from _helpers import days, flag, idx, sim, sim_out, step
from simlev import dca_plan, funds_costs, income_rate, rebalance_plan, sim_costs, tax_profile  # Bausteine (Etappe 6.3)

approx = pytest.approx


# ── A1: VP bei Kauf im laufenden Jahr ─────────────────────────────────────
def test_a1_vp_kauf_im_jahr():
    dd = days("2021-01-01", "2022-01-10")

    def run(p_end):
        d = pd.DataFrame({"date": dd, "A": step(dd, ["2021-01-01", "2021-04-15", "2021-12-31"], [100, 120, p_end])})
        d["b"] = flag(dd, "2021-04-15")
        d["s"] = False
        st = create_strategy(A=asset_config(asset_class="etf", trading="signal", share=1, spread=0, signal_buy="b",
                                            signal_sell="s"))
        return sim(d, st, tax=tax_profile(sparer_pauschbetrag=0, base_rate=2.5), fractions=False)
    r = run(110)
    assert r.tax_report["total_taxes_paid"] == approx(83 * 1.75 * 0.75 * 0.26375, rel=1e-10)
    i = idx(r, "2021-12-31")
    assert r.report["A"]["money"][i] == approx(40)
    assert r.report["A"]["money"][i + 1] == approx(40 - 83 * 1.75 * 0.75 * 0.26375, rel=1e-10)
    assert run(101).tax_report["total_taxes_paid"] == approx(83 * 1 * 0.75 * 0.26375, rel=1e-10)


# ── A2: Basiszins vom ersten Handelstag des Jahres ─────────────────────────
def test_a2_basiszins_erster_handelstag():
    dd = days("2020-12-28", "2022-01-07")
    dd = dd[(dd.dayofweek < 5) & (dd != pd.Timestamp("2021-01-01"))]
    x = (dd - pd.Timestamp("2021-01-04")).days.to_numpy() / (pd.Timestamp("2021-12-31") - pd.Timestamp("2021-01-04")).days
    a = np.where(dd < pd.Timestamp("2021-01-04"), 100, 100 + 20 * x)
    a[dd > pd.Timestamp("2021-12-31")] = 120
    br = np.where(dd < pd.Timestamp("2021-01-01"), 9.0,
                  np.where(dd == pd.Timestamp("2021-12-31"), 0.5, np.where(dd > pd.Timestamp("2021-12-31"), 1.0, 2.5)))
    d = pd.DataFrame({"date": dd, "A": a, "br": br})
    st = create_strategy(A=asset_config(asset_class="etf", share=1, spread=0))
    r = sim(d, st, start_value=10050, tax=tax_profile(sparer_pauschbetrag=0, base_rate="br"), fractions=False)
    assert r.tax_report["total_taxes_paid"] == approx(175 * 0.26375, rel=1e-10)


# ── A3: Zufluss der VP am ersten Werktag des Folgejahres ──────────────────
def _a3(to, use_spb=True, base_rate=2, details=False):
    dd = days("2021-01-01", to)
    t = (dd - dd[0]).days.to_numpy()
    d = pd.DataFrame({"date": dd, "E": 100 + 10 * np.minimum(1, t / 364),
                      "C": step(dd, ["2021-01-01", "2021-06-01"], [100, 130])})
    d["b"] = flag(dd, ["2021-01-01", "2022-01-01"])
    d["s"] = flag(dd, "2021-06-01")
    st = create_strategy(E=asset_config(asset_class="etf", share=0.5, spread=0),
                         C=asset_config(asset_class="certificate", trading="signal", share=0.5, spread=0, signal_buy="b",
                                        signal_sell="s"))
    kw = dict(start_value=10100, tax=tax_profile(base_rate=base_rate, sparer_pauschbetrag=1000 if use_spb else 0),
              fractions=False)
    return sim_out(d, st, **kw) if details else sim(d, st, **kw)


def test_a3_vp_toepfe_des_zuflussjahres():
    r = _a3("2022-01-10")
    assert r.tax_report["total_taxes_paid"] == approx(500 * 0.26375, rel=1e-10)
    assert r.tax_report["sparer_pauschbetrag_used"] == approx(1070, rel=1e-10)
    _, o = _a3("2022-01-10", details=True)
    i_vp = [i for i, ln in enumerate(o) if "Vorabpauschale E (festgesetzt" in ln]
    i_tr = [i for i, ln in enumerate(o) if "Kauf" in ln and " C " in ln and "am 2022-01-01" in ln]
    assert len(i_vp) == 1 and len(i_tr) == 1 and i_vp[0] < i_tr[0]
    r2 = _a3("2021-12-31")
    assert r2.tax_report["total_taxes_paid"] == approx(500 * 0.26375, rel=1e-10)
    assert r2.tax_report["sparer_pauschbetrag_used"] == approx(1070, rel=1e-10)
    r3 = _a3("2021-12-31", use_spb=False)
    r0 = _a3("2021-12-31", use_spb=False, base_rate=None)
    assert r3.tax_report["total_taxes_paid"] == approx((1500 + 70) * 0.26375, rel=1e-10)
    assert r0.worth[-1] - r3.worth[-1] == approx(70 * 0.26375, rel=1e-10)
    assert r0.worth[-2] == r3.worth[-2]


# ── A4: Sparer-Pauschbetrag bei späteren Verlusten ────────────────────────
def test_a4_verlust_nach_pauschbetrag():
    dd = days("2021-01-01", "2021-12-31")
    d = pd.DataFrame({"date": dd, "X": step(dd, ["2021-01-01", "2021-03-01"], [100, 140]),
                      "Y": step(dd, ["2021-01-01", "2021-06-01"], [100, 100 - 1467.03 / 50])})
    d["b"] = flag(dd, "2021-01-01")
    d["sx"] = flag(dd, "2021-03-01")
    d["sy"] = flag(dd, "2021-06-01")
    st = create_strategy(X=asset_config(asset_class="certificate", trading="signal", share=0.5, spread=0, signal_buy="b",
                                        signal_sell="sx"),
                         Y=asset_config(asset_class="certificate", trading="signal", share=0.5, spread=0, signal_buy="b",
                                        signal_sell="sy"))
    r = sim(d, st, tax=tax_profile())
    assert r.tax_report["total_taxes_paid"] == approx(0, abs=1e-9)
    assert r.tax_report["sparer_pauschbetrag_used"] == approx(532.97, abs=1e-9)
    assert r.tax_report["loss_carryforward_capital"] == approx(0, abs=1e-9)
    dd = days("2021-01-01", "2022-12-31")
    d = pd.DataFrame({"date": dd, "X": step(dd, ["2021-01-01", "2022-03-01"], [100, 140]),
                      "Y": step(dd, ["2021-01-01", "2021-06-01"], [100, 94]),
                      "Z": step(dd, ["2021-01-01", "2022-06-01"], [100, 80])})
    d["b"] = flag(dd, "2021-01-01")
    for c, at in (("sx", "2022-03-01"), ("sy", "2021-06-01"), ("sz", "2022-06-01")):
        d[c] = flag(dd, at)

    def cf(s):
        return asset_config(asset_class="certificate", trading="signal", share=1 / 3, spread=0, signal_buy="b", signal_sell=s)
    r = sim(d, create_strategy(X=cf("sx"), Y=cf("sy"), Z=cf("sz")), start_value=15000, tax=tax_profile())
    assert r.tax_report["total_taxes_paid"] == approx(0, abs=1e-9)
    assert r.tax_report["sparer_pauschbetrag_used"] == approx(700, abs=1e-9)
    assert r.tax_report["loss_carryforward_capital"] == approx(0, abs=1e-9)


# ── A5: § 23 Freigrenze vor Verlustvortrag ────────────────────────────────
def test_a5_freigrenze():
    dd = days("2021-01-01", "2022-12-31")

    def run(x_sell, z_sell):
        d = pd.DataFrame({"date": dd, "X": step(dd, ["2021-01-01", "2021-06-01"], [100, x_sell]),
                          "Z": step(dd, ["2021-01-01", "2022-06-01"], [100, z_sell])})
        d["bx"] = flag(dd, "2021-01-01")
        d["bz"] = flag(dd, "2022-02-01")
        d["sx"] = flag(dd, "2021-06-01")
        d["sz"] = flag(dd, "2022-06-01")

        def cf(b, s):
            return asset_config(asset_class="etc", trading="signal", share=0.5, spread=0, deliverable=True, signal_buy=b,
                                signal_sell=s)
        return sim(d, create_strategy(X=cf("bx", "sx"), Z=cf("bz", "sz")), tax=tax_profile(income=income_rate(marginal_rate=40)))
    r = run(90, 116)
    assert r.tax_report["total_taxes_paid"] == 0 and r.tax_report["loss_carryforward_private"] == 500
    r = run(90, 124)
    assert r.tax_report["total_taxes_paid"] == approx(700 * 0.4, rel=1e-10)
    assert r.tax_report["loss_carryforward_private"] == 0
    assert run(100, 120).tax_report["total_taxes_paid"] == approx(1000 * 0.4, rel=1e-10)
    assert run(100, 119.98).tax_report["total_taxes_paid"] == 0


# ── A6: Haltefrist bei Kauf am 29.02. ─────────────────────────────────────
@pytest.mark.parametrize("buy,sell,tax", [("2020-02-29", "2021-02-28", 4000), ("2020-02-29", "2021-03-01", 0),
                                          ("2021-03-10", "2022-03-10", 4000), ("2021-03-10", "2022-03-11", 0)])
def test_a6_haltefrist(buy, sell, tax):
    dd = days(buy, pd.Timestamp(sell) + pd.Timedelta(days=5))
    d = pd.DataFrame({"date": dd, "X": np.where(dd == pd.Timestamp(buy), 100.0, 200.0)})
    d["b"] = flag(dd, buy)
    d["s"] = flag(dd, sell)
    st = create_strategy(X=asset_config(asset_class="etc", trading="signal", share=1, spread=0, deliverable=True,
                                        signal_buy="b", signal_sell="s"))
    assert sim(d, st, tax=tax_profile(income=income_rate(marginal_rate=40))).tax_report["total_taxes_paid"] == tax


# ── B7-B9: Fondsmodus ─────────────────────────────────────────────────────
@pytest.mark.parametrize("frm,to,cost", [("2021-01-01", "2021-12-31", 100), ("2020-01-01", "2020-12-31", 100),
                                         ("2021-07-01", "2021-12-31", 184 * 100 / 365)])
def test_b7_funds_fee_linear(frm, to, cost):
    dd = days(frm, to)
    r = sim(pd.DataFrame({"date": dd, "A": 100.0}), create_strategy(A=asset_config(asset_class="etf", share=1, spread=0)), funds=funds_costs(fee=1, performance_fee=0))
    assert 10000 - r.worth[-1] == approx(cost, abs=1e-9)


def test_b8_high_watermark():
    dd = days("2021-01-01", "2022-12-31")
    d = pd.DataFrame({"date": dd, "A": step(dd, ["2021-01-01", "2021-12-31", "2022-12-31"], [100, 120, 123])})
    r = sim(d, create_strategy(A=asset_config(asset_class="etf", share=1, spread=0)), funds=funds_costs(fee=0, performance_fee=10))
    assert r.worth[-1] == approx(12095 - 29.5, abs=1e-8)


def test_b9_teilverkauf_fondskosten():
    dd = days("2021-01-01", "2021-12-31")
    r = sim(pd.DataFrame({"date": dd, "A": 100.0}), create_strategy(A=asset_config(asset_class="etf", share=1, spread=1)), costs=sim_costs(order_fee=5), funds=funds_costs(fee=1, performance_fee=0))
    n0 = 9995 / 100.5
    assert r.worth[-1] == approx(n0 * 100 * 0.99, abs=1e-8)
    assert r.fees_paid == 5


# ── C10: Später startende Assets ──────────────────────────────────────────
def test_c10_aktivierung():
    dd = days("2021-01-01", "2021-12-31")
    d = pd.DataFrame({"date": dd, "A": 100.0, "B": 50.0})
    st = create_strategy(A=asset_config(asset_class="etf", share=0.5, spread=0),
                         B=asset_config(asset_class="etf", share=0.5, spread=0, start="2021-07-01"))
    r = sim(d, st)
    ii = [idx(r, x) for x in ("2021-06-30", "2021-07-01", "2021-12-31")]
    assert list(r.report["A"]["worth"][ii]) == approx([10000, 5000, 5000], rel=1.5e-8)
    assert list(r.report["B"]["worth"][ii]) == approx([0, 5000, 5000], rel=1.5e-8)
    d2 = d.copy()
    d2.loc[dd < pd.Timestamp("2021-07-01"), "B"] = np.nan
    r2 = sim(d2, create_strategy(A=asset_config(asset_class="etf", share=0.5, spread=0),
                                 B=asset_config(asset_class="etf", share=0.5, spread=0)))
    assert list(r2.report["B"]["worth"][ii]) == approx([0, 5000, 5000], rel=1.5e-8)
    assert np.array_equal(r2.worth, r.worth)
    r3 = sim(d, st, rebalance=rebalance_plan(unit="year"))
    assert list(r3.report["B"]["worth"][ii]) == approx([0, 5000, 5000], rel=1.5e-8)


# ═══════════════════════════════════════════════════════════════════════════
# test-flow-metrics.R
# ═══════════════════════════════════════════════════════════════════════════

def _carry(z_price, vp=False):
    dd = days("2021-01-01", "2022-12-31")
    d = pd.DataFrame({"date": dd, "X": step(dd, ["2021-01-01", "2022-03-01"], [100, 160]),
                      "Y": step(dd, ["2021-01-01", "2021-06-01"], [100, 80]),
                      "Z": step(dd, ["2021-01-01", "2022-06-01"], [100, z_price])})
    d["b"] = flag(dd, "2021-01-01")
    for c, at in (("sx", "2022-03-01"), ("sy", "2021-06-01"), ("sz", "2022-06-01")):
        d[c] = flag(dd, at)
    k = 4 if vp else 3

    def cf(s):
        return asset_config(asset_class="certificate", trading="signal", share=1 / k, spread=0, signal_buy="b", signal_sell=s)
    st = {"X": cf("sx"), "Y": cf("sy"), "Z": cf("sz")}
    if vp:
        d["E"] = step(dd, ["2021-01-01", "2021-12-31"], [100, 120])
        st["E"] = asset_config(asset_class="etf", trading="bnh", share=0.25, spread=0, partial_exemption=0)
    return sim(d, create_strategy(**st), start_value=5000 * k, tax=tax_profile(base_rate=2.5 if vp else None))


@pytest.mark.parametrize("z,tax,pot,spb", [(90, 500 * 0.26375, 0, 1000), (70, 0, 0, 500), (50, 0, 500, 0)])
def test_fm1_erstattung_nach_vortrag(z, tax, pot, spb):
    r = _carry(z)
    assert r.tax_report["total_taxes_paid"] == approx(tax, abs=1e-10)
    assert r.tax_report["loss_carryforward_capital"] == approx(pot, abs=1e-10)
    assert r.tax_report["sparer_pauschbetrag_used"] == approx(spb, abs=1e-10)


def test_fm1_vp_ertrag_des_zuflussjahres():
    r = _carry(90, vp=True)
    assert r.tax_report["total_taxes_paid"] == approx(587.5 * 0.26375, rel=1e-10)
    assert r.tax_report["loss_carryforward_capital"] == approx(0, abs=1e-10)
    assert r.tax_report["sparer_pauschbetrag_used"] == approx(1000, rel=1e-10)


def _dca():
    dd = days("2020-01-01", "2021-12-31")
    p = np.where(dd < pd.Timestamp("2020-06-01"), 100.0, np.where(dd < pd.Timestamp("2021-07-01"), 80.0, 100.0))
    p[-1] = 150
    return sim(pd.DataFrame({"date": dd, "A": p}), create_strategy(A=asset_config(asset_class="etf", trading="bnh", share=1,
                                                                                   spread=0)), start_value=1000, dca=dca_plan(value=1000, span=1, unit="year", skip=True))


def test_fm2_cagr_xirr():
    r = _dca()
    assert r.external_flows is True
    assert r.worth[-1] == 3375
    assert [r.invested[0], r.invested[-1]] == [1000, 2000]
    T, t1 = 730 / 365.25, 366 / 365.25

    def f(x):
        return 1000 * (1 + x) ** T + 1000 * (1 + x) ** (T - t1) - 3375
    assert abs(f(r.cagr)) < 1e-8
    assert r.cagr == approx(0.4046127, abs=1e-6)
    assert r.ttwror == approx(1.5 ** (1 / T) - 1, rel=1e-12)


def test_fm2_drawdowns_zeitgewichtet():
    r = _dca()
    s = r.statistics
    assert s["max_drawdown"] == approx(0.2, rel=1e-12)
    assert s["longest_drawdown"] == 395 and s["avg_recovery_time"] == 395
    dd_days = np.flatnonzero(r.drawdowns > 0)
    assert (dd_days[0], dd_days[-1]) == (idx(r, "2020-06-01"), idx(r, "2021-06-30"))
    assert [r.twr_index[idx(r, x)] for x in ("2020-05-31", "2021-01-02", "2021-12-31")] == approx([1, 0.8, 1.5], rel=1e-12)
    assert s["calmar"] == approx(r.ttwror / 0.2, rel=1e-12)
    assert s["martin_ratio"] == approx(r.ttwror / s["ulcer_index"], rel=1e-12)


def test_fm2_ohne_zufluesse_unveraendert():
    rng = np.random.default_rng(3)
    n = 900
    d = pd.DataFrame({"date": pd.date_range("2018-01-01", periods=n), "A": 100 * np.exp(np.cumsum(rng.normal(3e-4, 0.012, n)))})
    r = sim(d, create_strategy(A=asset_config(asset_class="etf", share=1, spread=0.1)), start_value=10000)
    w = r.worth
    yrs = (n - 1) / 365.25
    assert r.external_flows is False
    assert r.cagr == simlev._r.rnum.r_pow(w[-1] / w[0], 1 / yrs) - 1
    rm = np.maximum.accumulate(w)
    assert np.array_equal(r.drawdowns, np.where(rm > 0, (rm - w) / rm, 0))
    assert list(np.unique(r.invested)) == [10000]
    out = str(r)
    assert "geldgewichtet" not in out and "Eingezahlt" not in out
    assert ("  CAGR:             %+.2f%%" % (r.cagr * 100)) in out.splitlines()
    assert xirr_rate([0], [w[0]], w[-1], yrs) == approx((w[-1] / w[0]) ** (1 / yrs) - 1, rel=1e-13)


def test_fm2_xirr_randfaelle():
    assert math.isnan(xirr_rate([0, 1], [100, 100], 50, 1))
    assert xirr_rate([0, 0.5], [100, 100], 0, 1) == -1
    t, a, v = [0, 0.25, 0.5, 0.75], [1000, 500, 500, 500], 2700
    x = xirr_rate(t, a, v, 1)
    assert abs(sum(ai * (1 + x) ** (1 - ti) for ai, ti in zip(a, t)) - v) < 1e-9
    # R3B-01: Nullstelle unter u = -200
    V = 1000 * math.exp(-300) + 100 * math.exp(-10 * 0.1)
    assert xirr_rate([0, 29.9], [1000, 100], V, 30) == approx(math.expm1(-10), rel=1e-10)


def test_fm2_print_und_summary():
    r = _dca()
    out = str(r).splitlines()
    assert any("(geldgewichtet, XIRR)" in ln and "CAGR:" in ln for ln in out)
    assert any("Risiko (zeitgewichtet" in ln for ln in out)
    assert "  Eingezahlt:       2000.00 EUR (Start + Sparraten)" in out
    sm = simlev.summary(r)
    assert sm.total_return == approx(0.5, rel=1e-12) and sm.invested == 2000
    assert "Gesamtrendite (zeitgewichtet): +50.00 %" in str(sm)
