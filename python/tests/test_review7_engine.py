"""Port von r/tests/testthat/test-review7-engine.R (A7-01 ... R8-05, Engine-Teile)."""
import math
import re

import numpy as np
import pandas as pd
import pytest

import simlev
from simlev import asset_config, create_strategy, simulation

from _helpers import days, idx, sim, sim_out, sim_warn
from simlev import dca_plan, harvest_rule, income_rate, rebalance_plan, sim_costs, split_rule, tax_profile  # Bausteine (Etappe 6.3)

approx = pytest.approx


def test_a7_01_bezugskurs_vp():
    dts = pd.to_datetime(["2024-12-30", "2024-12-31", "2025-01-02", "2025-06-02", "2025-12-31", "2026-01-02"])
    d = pd.DataFrame({"date": dts, "A": [100.0, 100, 110, 120, 130, 130]})
    st = create_strategy(A=asset_config(asset_class="etf", trading="bnh", share=1, spread=0, partial_exemption=0))
    r = sim(d, st, start_value=10000, tax=tax_profile(sparer_pauschbetrag=0, base_rate=50))
    lots = r.open_lots["A"]["lots"]
    assert lots.vp.sum() / lots.units.sum() == approx(20, rel=1.5e-8)
    cal = days("2024-12-30", "2026-01-02")
    dc = pd.DataFrame({"date": cal, "A": np.where(cal < pd.Timestamp("2025-01-01"), 100.0,
                                                  np.where(cal < pd.Timestamp("2025-12-31"), 110.0, 130.0))})
    lc = sim(dc, st, start_value=10000, tax=tax_profile(sparer_pauschbetrag=0, base_rate=50)).open_lots["A"]["lots"]
    assert lc.vp.sum() / lc.units.sum() == approx(20, rel=1.5e-8)


def test_a7_02_liquidationstag():
    rng = np.random.default_rng(1)
    cal = days("2024-01-01", "2024-12-02")
    d = pd.DataFrame({"date": cal, "A": 100 * np.cumprod(1 + rng.normal(3e-4, 0.01, len(cal))),
                      "B": 100 * np.cumprod(1 + rng.normal(0, 0.002, len(cal)))})
    d = d[d.date.dt.dayofweek < 5].reset_index(drop=True)
    st = create_strategy(A=asset_config(asset_class="etf", trading="bnh", share=0.6, spread=0.5),
                         B=asset_config(asset_class="etf", trading="bnh", share=0.4, spread=0.5))
    _, out = sim_out(d, st, start_value=1e5, liquidate=True, costs=sim_costs(order_fee=10), rebalance=rebalance_plan(unit="month"))
    day = [ln for ln in out if "am 2024-12-02" in ln]
    assert not any(ln.startswith("Rebalancing:") for ln in day)
    assert sum(ln.startswith("Liquidation:") for ln in day) == 2
    y = sim(d, st, start_value=1e5, liquidate=True, dca=dca_plan(value=5000, span=1))
    assert sum(a["flows"][-1] for a in y.report.values()) == 0


def test_a7_03_aktivierung_ohne_doppelorders():
    cal = days("2024-01-01", "2024-06-30")
    d = pd.DataFrame({"date": cal, "A": np.linspace(100, 130, len(cal)), "B": 50.0})
    st = create_strategy(A=asset_config(asset_class="etf", trading="bnh", share=0.5, spread=0.5),
                         B=asset_config(asset_class="etf", trading="bnh", share=0.5, spread=0.5, start="2024-03-01"))
    r, out = sim_out(d, st, start_value=10000, costs=sim_costs(order_fee=5), dca=dca_plan(value=1000, span=1))
    day = [ln for ln in out if "am 2024-03-01" in ln]
    assert not any(ln.startswith("Handelssignal:") for ln in day)
    assert sum(bool(re.match(r"^Rebalancing:\t(Kauf|Verkauf)", ln)) for ln in day) == 2
    assert r.fees_paid == 5 * (2 + 1 + 2 + 6)


def test_a7_04_vp_reihenfolge_unabhaengig():
    cal = days("2024-01-01", "2025-03-31")
    t = (cal - cal[0]).days.to_numpy() / 365
    d = pd.DataFrame({"date": cal, "A": 100 * (1 + 1.0 * np.minimum(t, 1)), "B": 100 * (1 + 0.05 * np.minimum(t, 1))})
    cfg = {"A": asset_config(asset_class="etf", trading="bnh", share=0.5, spread=0, partial_exemption=0),
           "B": asset_config(asset_class="etf", trading="bnh", share=0.5, spread=0, partial_exemption=0)}

    def run(order, **kw):
        return sim(d, create_strategy(**{k: cfg[k] for k in order}), start_value=1e5, tax=tax_profile(base_rate=2.29), **kw)
    r1, r2 = run("AB"), run("BA")
    assert r1.worth[-1] == approx(r2.worth[-1], rel=1e-12)
    assert r1.tax_report["total_taxes_paid"] == approx(r2.tax_report["total_taxes_paid"], rel=1e-12)
    _, ex = sim_out(d, create_strategy(B=cfg["B"], A=cfg["A"]), start_value=1e5, tax=tax_profile(base_rate=2.29))
    vp = [ln for ln in ex if re.match(r"^Steuerereignis:\tVorabpauschale [AB] \(festgesetzt", ln)]
    assert len(vp) == 2 and all("801.50 EUR, nach TFS 801.50 EUR, SPB 500.00 EUR, Steuer 79.52 EUR" in ln for ln in vp)
    assert r1.tax_report["total_taxes_paid"] > 603 * 0.26375


def test_a7_05_mehr_kaeufe_als_datentage():
    rng = np.random.default_rng(3)
    cal = days("2024-01-01", "2024-12-31")
    d = pd.DataFrame({"date": cal, "A": 100 * np.cumprod(1 + rng.normal(5e-4, 0.01, len(cal)))})
    st = create_strategy(A=asset_config(asset_class="etf", trading="bnh", share=1, spread=0.1))
    r = sim(d, st, start_value=10000, costs=sim_costs(order_fee=1, dca_fee=0), dca=dca_plan(value=10, span=1, days=list(range(1, 32))), tax=tax_profile(harvest=harvest_rule()))
    assert math.isfinite(r.worth[-1]) and len(r.open_lots["A"]["lots"]) > 0
    assert len(r.harvest_days) == 1


def test_a7_06_rebalancing_zum_tageskurs():
    rng = np.random.default_rng(5)
    cal = days("2024-01-01", "2024-12-31")
    d = pd.DataFrame({"date": cal, "A": 100 * np.cumprod(1 + rng.normal(1e-3, 0.02, len(cal))),
                      "B": 100 * np.cumprod(1 + rng.normal(0, 0.003, len(cal)))})
    st = create_strategy(A=asset_config(asset_class="etf", trading="bnh", share=0.6, spread=0),
                         B=asset_config(asset_class="etf", trading="bnh", share=0.4, spread=0))
    r = sim(d, st, start_value=10000, rebalance=rebalance_plan(unit="month"))
    i = np.flatnonzero(cal.day == 1)[1:]
    assert r.report["A"]["share"][i] == approx(np.full(len(i), 0.6), abs=1e-8)
    a, b = d.A.to_numpy(), d.B.to_numpy()
    for th in (1, 2, 3):
        r5 = sim(d, st, start_value=10000, rebalance=rebalance_plan(unit="month", thresh=th))
        ra, rb = r5.report["A"], r5.report["B"]
        pre = []
        for k in i:
            x = ra["worth"][k - 1] * a[k] / a[k - 1] + ra["money"][k - 1]
            y = rb["worth"][k - 1] * b[k] / b[k - 1] + rb["money"][k - 1]
            pre.append(x / (x + y))
        pre = np.array(pre)
        done = np.abs(ra["share"][i] - pre) > 1e-9
        assert np.array_equal(done, np.abs(pre - 0.6) > th / 100)


def test_a7_07_split_ohne_bestand():
    cal = days("2024-01-01", "2024-12-31")
    tt = (cal - pd.Timestamp("2024-03-01")).days.to_numpy()
    B = np.minimum(np.where(cal < pd.Timestamp("2024-03-01"), 100.0, 100 * 1.02 ** tt), 30000)
    d = pd.DataFrame({"date": cal, "A": 100.0, "B": B, "bB": cal == pd.Timestamp("2024-06-03"), "sB": False})
    st = create_strategy(A=asset_config(asset_class="etf", trading="bnh", share=0.5, spread=0),
                         B=asset_config(asset_class="etf", trading="signal", share=0.5, spread=0, signal_buy="bB", signal_sell="sB"))
    r = sim(d, st, start_value=10000, splits=split_rule(thresh=(50, 200)), fractions=False)
    k = idx(r, "2024-06-03")
    p = 100 * 1.02 ** 22
    n = math.floor(5000 / p)
    assert r.report["B"]["worth"][k] == approx(n * p, rel=1e-9)
    assert r.report["B"]["money"][k] == approx(5000 - n * p, rel=1e-9)


def test_a7_08_sortino_alle_beobachtungen():
    rng = np.random.default_rng(11)
    cal = days("2020-01-01", "2024-12-31")
    d = pd.DataFrame({"date": cal, "A": 100 * np.cumprod(1 + rng.normal(3e-4, 0.01, len(cal)))})
    r = sim(d, create_strategy(A=asset_config(asset_class="etf", trading="bnh", share=1, spread=0)), start_value=10000)
    rr = np.diff(r.worth) / r.worth[:-1]
    ppy = len(rr) / ((cal[-1] - cal[0]).days / 365.25)
    assert r.statistics["sortino"] == approx(rr.mean() * ppy / (math.sqrt(np.mean(np.minimum(rr, 0) ** 2)) * math.sqrt(ppy)),
                                             rel=1e-12)


def test_a7_09_signal_asset_legt_sparraten_an():
    cal = days("2024-01-01", "2025-12-31")
    a = 100 * 1.0003 ** np.arange(len(cal))
    d = pd.DataFrame({"date": cal, "A": a, "buy": cal == pd.Timestamp("2024-01-02"), "sell": False})
    st = create_strategy(A=asset_config(asset_class="etf", trading="signal", share=1, spread=0, signal_buy="buy",
                                        signal_sell="sell"))
    r = sim(d, st, start_value=10000, dca=dca_plan(value=500, span=1))
    assert r.report["A"]["money"][-1] == 0 and r.report["A"]["money"][0] == 10500
    units = 10500 / a[1] + np.sum(500 / a[np.flatnonzero(cal.day == 1)[1:]])
    assert r.worth[-1] == approx(units * a[-1], rel=1e-9)
    d2 = d.copy()
    d2["sell"] = cal == pd.Timestamp("2025-06-01")
    d2["buy"] = d2["buy"] | (cal == pd.Timestamp("2025-09-15"))
    r2 = sim(d2, st, start_value=10000, dca=dca_plan(value=500, span=1))
    j, m = idx(r2, "2025-06-01"), idx(r2, "2025-09-01")
    assert r2.report["A"]["worth"][j] == 0
    assert r2.report["A"]["money"][m] == approx(r2.report["A"]["money"][j] + 3 * 500, rel=1e-9)


def test_a7_10_argumentpruefung():
    d = pd.DataFrame({"date": days("2024-01-01", "2024-03-31"), "A": 100.0})
    st = create_strategy(A=asset_config(asset_class="etf", trading="bnh", share=1))

    def f(**kw):
        return sim_warn(d, st, tax=tax_profile(**kw))
    with pytest.raises(ValueError, match="'sparer_pauschbetrag' muss eine einzelne endliche Zahl >= 0"):
        f(sparer_pauschbetrag=float("nan"))
    with pytest.raises(ValueError, match="nicht -1000"):
        f(sparer_pauschbetrag=-1000)
    with pytest.raises(ValueError, match="'private_sale_threshold' muss .* nicht \"1000\""):
        f(private_sale_threshold="1000")
    with pytest.raises(ValueError, match="'base_rate' muss NULL, eine einzelne endliche Zahl"):
        f(base_rate=[2.29, 0])
    with pytest.raises(ValueError, match="income_rate: 'marginal_rate'"):
        income_rate([20, 42])
    with pytest.raises(ValueError, match="tax_profile: 'guenstigerpruefung' muss TRUE oder FALSE sein, nicht NA"):
        f(guenstigerpruefung=simlev._r.rnum.NA_REAL)     # R: NA
    with pytest.raises(ValueError, match="'fractions' muss TRUE oder FALSE sein, nicht NA"):
        simulation(d, st, fractions=simlev._r.rnum.NA_REAL)
    with pytest.raises(ValueError, match="dca_plan: 'skip' muss TRUE oder FALSE sein"):
        dca_plan(100, 1, skip=1)
    with pytest.raises(ValueError, match="harvest_rule: 'loss_pot' muss TRUE oder FALSE sein"):
        harvest_rule(loss_pot="ja")
    with pytest.warns(UserWarning, match="base_rate = 0.0229 wird als 0.0229 % gelesen"):
        tax_profile(base_rate=0.0229)
    assert f(base_rate=0.07)[1] == [] and f(base_rate=-0.5)[1] == []
    with pytest.warns(UserWarning, match="income_rate: marginal_rate = 0.42 wird als 0.42 %"):
        income_rate(0.42)
    with pytest.warns(UserWarning, match="rebalance_plan: thresh = 0.05 wird als 0.05 %"):
        rebalance_plan(thresh=0.05)


def test_a7_11_ende_31_12():
    cal = days("2024-01-01", "2025-12-31")
    a = 100 * 1.0005 ** np.arange(len(cal))
    st = create_strategy(A=asset_config(asset_class="etf", trading="bnh", share=1, spread=0, partial_exemption=30))
    r, out = sim_out(pd.DataFrame({"date": cal, "A": a}), st, start_value=1e5, tax=tax_profile(base_rate=2.29))
    ny = r.tax_report["next_year"]
    P0, P1 = a[cal == pd.Timestamp("2025-01-01")][0], a[-1]
    vp_line = [ln for ln in out if "Vorabpauschale A (festgesetzt 2025-12-31)" in ln][0]
    vp = float(re.sub(r".*\): ([0-9.]+) EUR, nach TFS.*", r"\1", vp_line))
    assert vp / min(P0 * 0.7 * 0.0229, P1 - P0) == approx(999.72, rel=1e-5)
    assert abs(ny["capital_income_taxed"] - (vp * 0.7 - 1000)) < 0.005
    assert sum("=> Gewinn: 29.51 EUR; Steuer: 5.01 EUR" in ln for ln in out) == 1
    assert ny["sparer_pauschbetrag_used"] == 1000


def test_c7_01_listen_strategien():
    d = pd.DataFrame({"date": days("2020-01-01", "2020-03-31"), "A": 100.0})

    def mk(**kw):
        a = {"asset_class": "etf", "trading": "bnh", "share": 1, "spread": 0}
        a.update(kw)
        return {"A": a}
    with pytest.raises(ValueError, match="tax_regime \"none\" von Asset 'A' ist ungültig"):
        simulation(d, mk(tax_regime="none"), tax=tax_profile())
    with pytest.raises(ValueError, match="asset_class \"eft\" von Asset 'A' ist ungültig"):
        simulation(d, mk(asset_class="eft"))
    with pytest.raises(ValueError, match="trading \"hold\""):
        simulation(d, mk(trading="hold"))
    assert isinstance(simulation(d, mk(tax_regime="capital_gains"), tax=tax_profile()), simlev.SimLevResult)


def test_c7_04_wirkungslose_argumente():
    d = pd.DataFrame({"date": days("2020-01-01", "2020-03-31"), "A": 100.0})
    st = create_strategy(A=asset_config(asset_class="etf", trading="bnh", share=1))
    with pytest.warns(UserWarning, match="rebalance_plan: event_mode wirkt nur zusammen mit event_col"):
        rebalance_plan(event_mode="replace")
    with pytest.warns(UserWarning, match="rebalance_plan: event_weight wirkt nur zusammen mit event_col"):
        rebalance_plan(event_weight={"A": "wA"})
    assert sim_warn(d, st, rebalance=rebalance_plan(thresh=5))[1] == []
    assert sim_warn(d, st, tax=tax_profile())[1] == []


def test_c7_06_summary_druckt_nicht(capsys):
    rng = np.random.default_rng(7)
    cal = days("2021-01-01", "2022-05-15")
    d = pd.DataFrame({"date": cal, "ETF": 100 * np.cumprod(1 + rng.normal(4e-4, 0.012, len(cal)))})
    r = simulation(d, create_strategy(ETF=asset_config(asset_class="etf", share=1, partial_exemption=30)))
    s = r.summary()
    assert capsys.readouterr().out == ""
    assert isinstance(s, simlev.SimLevSummary)
    out = str(s).splitlines()
    assert any("SimLev Zusammenfassung" in ln for ln in out) and any(ln.startswith("  Sharpe ") for ln in out)
    assert all(k in s for k in ("total_return_twr", "return_on_invested", "undefined_metrics", "tax_report"))


def test_r8_04_keine_anteilwarnung():
    d = pd.DataFrame({"date": days("2016-01-01", "2016-06-30"), "A": 100.0, "B": 50.0})
    st = create_strategy(A=asset_config(asset_class="etf", trading="bnh", share=0.6), B=asset_config(asset_class="etf", trading="bnh", share=0.4))
    assert sim_warn(d, st, risk_free=0.25)[1] == []
    assert sim_warn(d, st, rebalance=rebalance_plan(thresh=0.5))[1] == []
    assert sim_warn(d, st, tax=tax_profile(base_rate=0.07))[1] == []
    assert any("risk_free = 0.02 wird als 0.02 % gelesen" in w for w in sim_warn(d, st, risk_free=0.02)[1])


def test_r8_05_erster_tag_ohne_doppelorders():
    rng = np.random.default_rng(1)
    cal = days("2024-01-15", "2024-03-31")
    d = pd.DataFrame({"date": cal, "A": 100 * np.cumprod(1 + rng.normal(0, 0.01, len(cal))), "B": 50.0, "C": 80.0})
    st = create_strategy(A=asset_config(asset_class="etf", trading="bnh", share=0.4, spread=1),
                         B=asset_config(asset_class="etf", trading="bnh", share=0.3, spread=0),
                         C=asset_config(asset_class="etf", trading="bnh", share=0.3, spread=0))
    r, out = sim_out(d, st, start_value=10000, costs=sim_costs(order_fee=5), rebalance=rebalance_plan(unit="month"))
    day1 = [ln for ln in out if "am 2024-01-15" in ln]
    assert sum(bool(re.search(r"\t(Kauf|Verkauf) [0-9]", ln)) for ln in day1) == 3
    assert r.fees_paid == 45
    st0 = create_strategy(A=asset_config(asset_class="etf", trading="bnh", share=0.4, spread=0),
                          B=asset_config(asset_class="etf", trading="bnh", share=0.3, spread=0),
                          C=asset_config(asset_class="etf", trading="bnh", share=0.3, spread=0))
    r0 = sim(d, st0, start_value=10000, rebalance=rebalance_plan(unit="month"))
    r1 = sim(d, st0, start_value=10000)
    assert r0.report["A"]["worth"][:17] == approx(r1.report["A"]["worth"][:17], rel=1e-12)
    assert r0.report["B"]["share"][0] == approx(0.3, rel=1e-12)
