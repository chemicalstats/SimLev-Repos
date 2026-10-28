"""Verhaltenstests der Engine (Port von test-simulation.R).

Die Testdaten werden mit numpy erzeugt; geprüft werden – wie im R-Original –
Eigenschaften und fachliche Regeln. Die Bitgleichheit zu R prüft
``test_golden_master.py``.
"""
import contextlib
import io
import math
import re
import time

import numpy as np
import pandas as pd
import pytest

import simlev
from simlev import asset_config, rebalance_trigger, create_strategy, simulation
from simlev import dca_plan, rebalance_plan, tax_profile  # Bausteine (Etappe 6.3)


def days(start, n):
    return pd.date_range(start, periods=n, freq="D")


def make_data(n=100, seed=42):
    rng = np.random.default_rng(seed)
    return pd.DataFrame({"date": days("2020-01-01", n), "ETF": 100 * np.cumprod(1 + rng.normal(0.001, 0.02, n))})


def legacy_strategy():
    return {"ETF": {"asset_class": "etf", "trading": "bnh", "share": 1.0, "spread": 0.1,
                    "partial_exemption": 0}}


def weekdays(start, end):
    d = pd.date_range(start, end, freq="D")
    return d[d.dayofweek < 5]


def quiet(fn, *a, **k):
    with contextlib.redirect_stderr(io.StringIO()):
        return fn(*a, **k)


# ── Grundfunktionen ───────────────────────────────────────────────────────
def test_runs_and_structure():
    r = simulation(make_data(), legacy_strategy(), start_value=10000)
    for key in ("worth", "cagr", "ttwror", "drawdowns", "statistics", "report", "tax_report", "dates", "filled"):
        assert key in r.keys()
    assert len(r.worth) == 100
    assert r.worth[0] == pytest.approx(10000, rel=0.01)   # Spread kostet am Tag 1 ca. 0,05 %


def test_dca_increases_value_and_records_flows():
    d = make_data(365)
    r0 = simulation(d, legacy_strategy(), start_value=10000)
    r1 = simulation(d, legacy_strategy(), start_value=10000, dca=dca_plan(value=1000, span=1, days=1, unit="month"))
    assert r1.worth[-1] > r0.worth[-1]
    assert r1.report["ETF"]["flows"].sum() > 0


def test_tax_modes_run():
    d = make_data()
    simulation(d, legacy_strategy(), liquidate=True)
    simulation(d, legacy_strategy(), tax=tax_profile(rate=26.375), liquidate=True)


def test_rebalancing_runs():
    d = make_data(365)
    rng = np.random.default_rng(42)
    d["BOND"] = 50 * np.cumprod(1 + rng.normal(0.0002, 0.005, 365))
    s = {"ETF": {"asset_class": "etf", "trading": "bnh", "share": 0.6, "spread": 0.1, "partial_exemption": 0},
         "BOND": {"asset_class": "etf", "trading": "bnh", "share": 0.4, "spread": 0.05,
                  "partial_exemption": 30}}
    simulation(d, s, rebalance=rebalance_plan(span=1, days=1, unit="quarter"))


def test_single_day_and_zero_start():
    simulation(make_data(1), legacy_strategy(), start_value=10000)
    with pytest.raises(ValueError):
        simulation(make_data(), legacy_strategy(), start_value=0)


def test_weights_must_sum_to_one():
    s = create_strategy(A=asset_config(share=0.5), B=asset_config(share=0.4))
    d = make_data()
    d["A"] = d["ETF"]
    d["B"] = d["ETF"]
    with pytest.raises(ValueError, match="summieren sich auf 0.9000"):
        simulation(d, s)


def test_performance():
    t = time.time()
    simulation(make_data(3650), legacy_strategy(), start_value=10000)
    assert time.time() - t < 5


# ── LOCF-Markierung ───────────────────────────────────────────────────────
def gapped(seed=99):
    rng = np.random.default_rng(seed)
    wd = weekdays("2021-01-04", "2021-12-31")
    return pd.DataFrame({"date": wd, "ETF": 100 * np.cumprod(1 + rng.normal(4e-4, 0.011, len(wd)))})


def test_filled_days_marked_and_excluded():
    r = quiet(simulation, gapped(), legacy_strategy(), start_value=10000)
    dates = pd.DatetimeIndex(r.dates)
    assert r.filled.dtype == bool and len(r.filled) == len(r.dates)
    assert r.filled.sum() == (dates.dayofweek >= 5).sum()
    assert 0.005 < r.statistics["sd"] < 0.03
    assert math.isfinite(r.statistics["sharpe"])


# ── Risk-Free ─────────────────────────────────────────────────────────────
def rf_data(seed=77):
    rng = np.random.default_rng(seed)
    wd = weekdays("2022-01-01", "2022-12-31")
    return pd.DataFrame({"date": wd, "ETF": 100 * np.cumprod(1 + rng.normal(3e-4, 0.011, len(wd))),
                         "sofr": np.linspace(0.01, 0.04, len(wd))})


def test_risk_free_variants():
    d = rf_data()
    s = legacy_strategy()
    r_none = quiet(simulation, d, s, risk_free=None)
    r_zero = quiet(simulation, d, s, risk_free=0)
    r_def = quiet(simulation, d, s)
    assert r_none.statistics["sharpe"] == r_zero.statistics["sharpe"] == r_def.statistics["sharpe"]
    r3 = quiet(simulation, d, s, risk_free=3)
    assert r3.statistics["sharpe"] < r_zero.statistics["sharpe"]
    assert r3.statistics["sortino"] < r_zero.statistics["sortino"]
    d["rf_const"] = 3.0
    r_col = quiet(simulation, d, s, risk_free="rf_const")
    assert r_col.statistics["sharpe"] == pytest.approx(r3.statistics["sharpe"], abs=1e-9)
    r_ts = quiet(simulation, d, s, risk_free="sofr")
    r_avg = quiet(simulation, d, s, risk_free=float(d["sofr"].mean()))
    assert abs(r_ts.statistics["sharpe"] - r_avg.statistics["sharpe"]) > 1e-6
    with pytest.raises(ValueError, match="Spalte 'nonexistent' fehlt"):
        quiet(simulation, d, s, risk_free="nonexistent")
    assert quiet(simulation, d, s, risk_free=2).statistics["risk_free"] == pytest.approx(2, abs=1e-9)


# ── Terminplanung ─────────────────────────────────────────────────────────
def test_dca_without_days_and_rebalancing_sells():
    rng = np.random.default_rng(1)
    d = pd.DataFrame({"date": days("2022-01-01", 365), "ETF": 100 * np.cumprod(1 + rng.normal(4e-4, 0.01, 365))})
    r = simulation(d, legacy_strategy(), start_value=1000, dca=dca_plan(value=1000, span=1))
    assert (np.abs(r.report["ETF"]["flows"]) > 1e-9).sum() > 9
    rng = np.random.default_rng(3)
    d2 = pd.DataFrame({"date": days("2021-01-01", 730), "A": 100 * np.cumprod(1 + rng.normal(8e-4, 0.012, 730)),
                       "B": 100 * np.cumprod(1 + rng.normal(-2e-4, 0.004, 730))})
    s = create_strategy(A=asset_config(asset_class="etf", trading="bnh", share=0.5, spread=0, partial_exemption=30), B=asset_config(asset_class="etf", trading="bnh", share=0.5, spread=0, partial_exemption=30))
    r2 = simulation(d2, s, rebalance=rebalance_plan(span=1, unit="month"))
    assert r2.sells.sum() > 0


def test_event_col_runs():
    rng = np.random.default_rng(4)
    n = 300
    d = pd.DataFrame({"date": days("2022-01-01", n), "ETF": 100 * np.cumprod(1 + rng.normal(4e-4, 0.01, n)),
                      "target_leverage": 2 + 0.5 * np.sin(np.linspace(0, 4 * np.pi, n))})
    d = rebalance_trigger(d, type="abs_leverage", threshold=10)
    r = simulation(d, legacy_strategy(), rebalance=rebalance_plan(event_col="rebal_trigger", event_mode="replace", skip=True))
    assert math.isfinite(r.worth[-1])


def _wd_2022():
    rng = np.random.default_rng(1)
    wd = weekdays("2022-01-01", "2022-12-31")
    return pd.DataFrame({"date": wd, "ETF": 100 * np.cumprod(1 + rng.normal(4e-4, 0.01, len(wd)))})


def test_dca_shifted_off_filled_days():
    r = quiet(simulation, _wd_2022(), legacy_strategy(), start_value=1000, dca=dca_plan(value=1000, span=1))
    fl = np.flatnonzero(np.abs(r.report["ETF"]["flows"]) > 1e-9)
    assert r.filled[fl].sum() == 0
    flow_dates = set(str(x) for x in r.dates[fl])
    assert "2022-05-02" in flow_dates and "2022-10-03" in flow_dates


def test_month_end_pulled_back():
    r = quiet(simulation, _wd_2022(), legacy_strategy(), start_value=1000, dca=dca_plan(value=1000, span=1, days=1, anchor="end"))
    fl = np.flatnonzero(np.abs(r.report["ETF"]["flows"]) > 1e-9)
    flow_dates = set(str(x) for x in r.dates[fl])
    assert r.filled[fl].sum() == 0
    assert "2022-04-29" in flow_dates and "2022-07-29" in flow_dates
    assert not any(x[5:] in ("05-02", "08-01") for x in flow_dates)


# ── Signal-Logik beim Rebalancing ─────────────────────────────────────────
def pulse(buy_on, sell_on=None, n=120, seed=2):
    rng = np.random.default_rng(seed)
    d = pd.DataFrame({"date": days("2022-01-03", n), "SIG": 100 * np.cumprod(1 + rng.normal(4e-4, 0.01, n))})
    d["buy_sig"] = d["date"].isin(pd.to_datetime(buy_on if isinstance(buy_on, list) else [buy_on]))
    d["sell_sig"] = d["date"].isin(pd.to_datetime([sell_on])) if sell_on else False
    return d


SIG = create_strategy(SIG=asset_config(asset_class="etf", trading="signal", share=1, spread=0, partial_exemption=30, signal_buy="buy_sig", signal_sell="sell_sig"))


def idx(r, day):
    return int(np.flatnonzero(r.dates == np.datetime64(day))[0])


def test_signal_entry_exit_on_rebalance_day():
    r = simulation(pulse("2022-02-01"), SIG, rebalance=rebalance_plan(span=1, unit="month"))
    assert r.report["SIG"]["worth"][idx(r, "2022-02-02")] > 0
    assert r.report["SIG"]["worth"][idx(r, "2022-01-15")] == 0
    assert r.report["SIG"]["money"][idx(r, "2022-01-15")] > 9999
    r2 = simulation(pulse("2022-01-10", "2022-03-01"), SIG, rebalance=rebalance_plan(span=1, unit="month"))
    assert r2.report["SIG"]["worth"][idx(r2, "2022-02-28")] > 0
    assert r2.report["SIG"]["worth"][idx(r2, "2022-03-02")] == 0
    assert r2.report["SIG"]["money"][idx(r2, "2022-03-02")] > 0


def test_inactive_signal_asset_holds_cash_reserve():
    rng = np.random.default_rng(5)
    n = 120
    d = pd.DataFrame({"date": days("2022-01-03", n), "W": 100 * np.cumprod(1 + rng.normal(4e-4, 0.01, n)),
                      "S": 100 * np.cumprod(1 + rng.normal(4e-4, 0.01, n)), "b": False, "sl": False})
    s = create_strategy(W=asset_config(asset_class="etf", trading="bnh", share=0.5, spread=0, partial_exemption=30),
                        S=asset_config(asset_class="etf", trading="signal", share=0.5, spread=0, partial_exemption=30, signal_buy="b", signal_sell="sl"))
    r = simulation(d, s, rebalance=rebalance_plan(span=1, unit="month", thresh=1))
    i = idx(r, "2022-02-02")
    assert r.report["S"]["worth"].max() == 0
    total = r.report["W"]["total"][i] + r.report["S"]["total"][i]
    assert abs(r.report["S"]["money"][i] / total - 0.5) < 0.02
    assert r.report["W"]["money"][i] < 0.01


# ── Vorabpauschale (§ 18 Abs. 3 InvStG) ───────────────────────────────────
VP_S = create_strategy(ETF=asset_config(asset_class="etf", trading="bnh", share=1, spread=0, partial_exemption=30))


def vp_data(end="2023-01-31", gaps=True, seed=9):
    rng = np.random.default_rng(seed)
    dd = weekdays("2022-01-01", end) if gaps else pd.date_range("2022-01-01", end)
    d = pd.DataFrame({"date": dd, "ETF": 100 * np.cumprod(1 + rng.normal(8e-4, 0.008, len(dd)))})
    d["base_rate"] = 2.55
    return d


def counts(r, d):
    px = d.set_index("date")["ETF"].reindex(pd.DatetimeIndex(r.dates)).ffill().to_numpy()
    return r.report["ETF"]["worth"] / px


def test_vp_settled_first_trading_day():
    d = vp_data()
    r = quiet(simulation, d, VP_S, tax=tax_profile(sparer_pauschbetrag=0, base_rate="base_rate"))
    c = counts(r, d)
    assert c[idx(r, "2022-12-30")] > c[idx(r, "2023-01-02")]
    assert r.tax_report["total_taxes_paid"] > 0


def test_vp_immediate_when_simulation_ends_dec31():
    d = vp_data("2022-12-31", gaps=False)
    r = simulation(d, VP_S, tax=tax_profile(sparer_pauschbetrag=0, base_rate="base_rate"))
    assert r.tax_report["total_taxes_paid"] > 0


def test_deferred_vp_not_double_counted():
    d = vp_data("2024-01-31")
    r = quiet(simulation, d, VP_S, tax=tax_profile(sparer_pauschbetrag=0, base_rate="base_rate"))
    c = counts(r, d)
    assert c[idx(r, "2022-12-30")] - c[idx(r, "2023-01-03")] > 0
    assert c[idx(r, "2023-12-29")] - c[idx(r, "2024-01-03")] > 0


# ── Prozent-Konvention ────────────────────────────────────────────────────
def linear_data():
    return pd.DataFrame({"date": days("2022-01-03", 200), "ETF": np.linspace(100, 150, 200)})


def test_tax_rate_in_percent():
    s = create_strategy(ETF=asset_config(asset_class="etf", trading="bnh", share=1, spread=0, partial_exemption=0))
    r = simulation(linear_data(), s, tax=tax_profile(rate=26.375, sparer_pauschbetrag=0), liquidate=True)
    gain = 10000 * 1.5 - 10000
    assert r.tax_report["total_taxes_paid"] / gain == pytest.approx(0.26375, rel=1e-6)


def test_asset_bonus_in_percent():
    s = create_strategy(ETF=asset_config(asset_class="etf", trading="bnh", share=1, spread=0, partial_exemption=30))
    r = simulation(linear_data(), s, tax=tax_profile(rate=25, sparer_pauschbetrag=0), liquidate=True)
    assert r.tax_report["total_taxes_paid"] == pytest.approx(5000 * 0.7 * 0.25, rel=1e-6)


# ── Verlusttopf vor SPB (R-2) ─────────────────────────────────────────────
def test_vp_offset_against_loss_pot():
    dd = pd.date_range("2019-01-01", "2020-03-31")
    t = (dd - dd[0]).days.to_numpy() / 365.25
    d = pd.DataFrame({"date": dd, "B": 100 * 1.06 ** t, "L": 100 - 40 * t, "base_rate": 3.0})
    d["buyL"] = d["date"] == pd.Timestamp("2019-02-01")
    d["sellL"] = d["date"] == pd.Timestamp("2019-11-01")
    s = create_strategy(B=asset_config(asset_class="etf", trading="bnh", share=0.9, spread=0, partial_exemption=0),
                        L=asset_config(asset_class="etf", trading="signal", share=0.1, spread=0, partial_exemption=0, signal_buy="buyL", signal_sell="sellL"))

    def run(with_loss):
        dl = d.copy()
        if not with_loss:
            dl["buyL"] = False
        buf = io.StringIO()
        with contextlib.redirect_stdout(buf):
            r = simulation(dl, s, start_value=10000, tax=tax_profile(rate=25, sparer_pauschbetrag=0, base_rate="base_rate"), details=True)
        out = buf.getvalue()
        paid = sum(float(x) for x in re.findall(r"Zahlung Vorabpauschale ([0-9.]+) EUR", out))
        paid += sum(float(x) for x in re.findall(r"Anteile verkauft für den Rest von ([0-9.]+) EUR", out))
        return r, paid

    ra, pa = run(False)
    rb, pb = run(True)
    assert pa > 40
    assert pb == 0
    assert rb.tax_report["loss_carryforward_capital"] < ra.tax_report["loss_carryforward_capital"] + 3000


# ── DCA nach Strategie-Gewichten (R-1) ────────────────────────────────────
def r1():
    rng = np.random.default_rng(1)
    n = 200
    d = pd.DataFrame({"date": days("2022-01-03", n), "A": 100 * np.cumprod(1 + rng.normal(15e-4, 0.01, n)),
                      "B": 100 * np.cumprod(1 + rng.normal(-2e-4, 0.004, n))})
    s = create_strategy(A=asset_config(asset_class="etf", trading="bnh", share=0.7, spread=0, partial_exemption=30), B=asset_config(asset_class="etf", trading="bnh", share=0.3, spread=0, partial_exemption=30))
    return d, s


def test_dca_split_by_strategy_weights():
    d, s = r1()
    r = simulation(d, s, dca=dca_plan(value=500, span=1))
    i = int(np.flatnonzero((r.report["A"]["flows"] > 0) & (r.dates > np.datetime64("2022-05-01")))[0])
    assert r.report["A"]["flows"][i] == pytest.approx(350, abs=1e-9)
    assert r.report["B"]["flows"][i] == pytest.approx(150, abs=1e-9)


def test_balance_dca_fills_deficits():
    d, s = r1()
    r = simulation(d, s, dca=dca_plan(value=500, span=1, fill_deficits=True))
    fa, fb = r.report["A"]["flows"], r.report["B"]["flows"]
    j = int(np.flatnonzero((fa + fb > 499) & (r.dates > np.datetime64("2022-05-01")))[0])
    ta, tb = r.report["A"]["total"][j - 1], r.report["B"]["total"][j - 1]
    assert abs((ta + fa[j]) / (ta + tb + 500) - 0.70) < 0.005


def test_dca_renormalized_over_active_assets():
    d, _ = r1()
    rng = np.random.default_rng(2)
    d["C"] = 100 * np.cumprod(1 + rng.normal(3e-4, 0.006, len(d)))
    s = create_strategy(A=asset_config(asset_class="etf", trading="bnh", share=0.63, spread=0, partial_exemption=30), B=asset_config(asset_class="etf", trading="bnh", share=0.27, spread=0, partial_exemption=30),
                        C=asset_config(asset_class="etf", trading="bnh", share=0.10, spread=0, partial_exemption=0, start="2022-04-01"))
    r = simulation(d, s, dca=dca_plan(value=500, span=1))
    k1 = int(np.flatnonzero((r.report["A"]["flows"] > 0) & (r.dates < np.datetime64("2022-04-01")))[0])
    k2 = int(np.flatnonzero(r.report["C"]["flows"] > 0)[0])
    assert r.report["A"]["flows"][k1] == pytest.approx(350, abs=1e-9)
    assert r.report["B"]["flows"][k1] == pytest.approx(150, abs=1e-9)
    got = [r.report[a]["flows"][k2] for a in "ABC"]
    assert got == pytest.approx([315, 135, 50], abs=1e-9)


# ── Ausgabe ───────────────────────────────────────────────────────────────
def test_print_and_summary(capsys):
    r = simulation(make_data(400), legacy_strategy(), tax=tax_profile(), liquidate=True)
    r.print()
    res = r.summary()
    print(res)
    out = capsys.readouterr().out
    assert "SimLev Simulationsergebnisse" in out and "SimLev Zusammenfassung" in out
    assert res["n_days"] == 400 and res.n_days == 400


# ── Nachgetragen aus test-simulation.R ─────────────────────────────────────
def test_liquidation_runs():
    r = quiet(simulation, make_data(), legacy_strategy(), start_value=10000, liquidate=True)
    assert len(r.worth) == 100


def test_skewness_kurtosis_numeric():
    x = np.random.default_rng(1).normal(size=100)
    for f in (simlev.engine.calculate_skewness, simlev.engine.calculate_kurtosis):
        v = f(x)
        assert isinstance(v, float) and not math.isnan(v)


def test_trading_day_annualisation_after_locf():
    rng = np.random.default_rng(99)
    wd = weekdays("2021-01-04", "2021-12-31")
    gapped = pd.DataFrame({"date": wd, "ETF": 100 * np.cumprod(1 + rng.normal(4e-4, 0.011, len(wd)))})
    full_d = pd.date_range("2021-01-04", "2021-12-31")
    full = pd.DataFrame({"date": full_d, "ETF": 100 * np.cumprod(1 + rng.normal(4e-4, 0.011, len(full_d)))})
    assert math.isfinite(quiet(simulation, gapped, legacy_strategy(), start_value=10000).statistics["sharpe"])
    assert math.isfinite(quiet(simulation, full, legacy_strategy(), start_value=10000).statistics["sharpe"])


def test_liquidate_keeps_vp_in_earlier_years():
    rng = np.random.default_rng(9)
    wd = weekdays("2022-01-01", "2023-06-30")
    d = pd.DataFrame({"date": wd, "ETF": 100 * np.cumprod(1 + rng.normal(8e-4, 0.008, len(wd))), "base_rate": 2.55})
    s = create_strategy(ETF=asset_config(asset_class="etf", trading="bnh", share=1, spread=0, partial_exemption=30))
    r = quiet(simulation, d, s, start_value=10000, tax=tax_profile(rate=26.375, sparer_pauschbetrag=0, base_rate="base_rate"), liquidate=True)
    px = d.set_index("date").ETF.reindex(pd.DatetimeIndex(r.dates)).to_numpy()
    cnt = r.report["ETF"]["worth"] / px
    assert cnt[idx(r, "2022-12-30")] > cnt[idx(r, "2023-01-02")]


def test_balance_thresh_in_percent():
    rng = np.random.default_rng(3)
    n = 730
    data = pd.DataFrame({"date": days("2021-01-01", n), "A": 100 * np.cumprod(1 + rng.normal(8e-4, 0.012, n)),
                         "B": 100 * np.cumprod(1 + rng.normal(-2e-4, 0.004, n))})
    st = create_strategy(A=asset_config(asset_class="etf", trading="bnh", share=0.5, spread=0, partial_exemption=30),
                         B=asset_config(asset_class="etf", trading="bnh", share=0.5, spread=0, partial_exemption=30))
    assert simulation(data, st, start_value=10000, rebalance=rebalance_plan(span=1, unit="month", thresh=5)).sells.sum() > 0
    assert simulation(data, st, start_value=10000, rebalance=rebalance_plan(span=1, unit="month", thresh=90)).sells.sum() == 0
