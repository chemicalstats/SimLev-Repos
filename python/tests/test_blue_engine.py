"""Port von r/tests/testthat/test-blue-engine.R (Befunde R1-01 ... R1-26, Engine-Teile)."""
import contextlib
import io
import math
import warnings

import numpy as np
import pandas as pd
import pytest

import simlev
from simlev import asset_config, compute_rebal_trigger, create_strategy, simulation, update_asset

from _helpers import days, idx, sim, sim_warn

approx = pytest.approx


def cal(frm, to, **cols):
    d = pd.DataFrame({"date": days(frm, to)})
    for k, v in cols.items():
        d[k] = v
    return d


def st1(**kw):
    return create_strategy(A=asset_config("etf", asset_share=1, asset_spread=0, **kw))


def quiet(*a, **k):
    with contextlib.redirect_stderr(io.StringIO()):
        return simulation(*a, **k)


def test_r1_01_funds_fee_voll_investiert():
    r = simulation(cal("2020-01-01", "2022-12-30", A=100.0), st1(), tax_mode="funds", funds_fee=10, bonus_fee=0)
    v = 10000.0
    v = v - 366 * (0.1 / 366) * v
    v = v - 365 * (0.1 / 365) * v
    v = v - 364 * (0.1 / 365) * v
    assert r.worth[-1] == approx(v, rel=1e-9) and r.worth[-1] < 7500


def test_r1_02_fondssteuer_bei_liquidation():
    def mk(end):
        d = cal("2020-01-01", end)
        d["A"] = 100 * 1.0005 ** np.arange(len(d))
        return d

    def run(end):
        return simulation(mk(end), st1(), tax_mode="funds", funds_fee=0, bonus_fee=0, liquidate=True)

    def g(n):
        v = 10000 * 1.0005 ** (n - 1)
        return v - 0.26375 * (v - 10000)
    a, b = run("2022-12-30"), run("2022-12-31")
    assert a.worth[-1] == approx(g(1095), rel=1e-9) and b.worth[-1] == approx(g(1096), rel=1e-9)
    c1 = simulation(mk("2021-12-31"), st1(), tax_mode="funds", funds_fee=1, bonus_fee=0)
    c2 = simulation(mk("2021-12-31"), st1(), tax_mode="funds", funds_fee=1, bonus_fee=0, liquidate=True)
    assert c2.worth[-1] + c2.tax_report["total_taxes_paid"] == approx(c1.worth[-1], rel=1e-9)


def test_r1_03_einzahlungen_kein_gewinn():
    r = simulation(cal("2020-01-01", "2022-12-30", A=100.0), st1(), tax_mode="funds", funds_fee=0, bonus_fee=0,
                   liquidate=True, dca_mode=True, dca_value=1000, dca_span=1)
    assert r.worth[-1] == 10000 + r.report["A"]["flows"].sum() and r.tax_report["total_taxes_paid"] == 0


def test_r1_04_dca_fee_nur_sparplankaeufe():
    rng = np.random.default_rng(2)
    n = 3 * 365
    d = pd.DataFrame({"date": pd.date_range("2020-01-01", periods=n), "A": 100 * np.cumprod(1 + rng.normal(5e-4, 0.015, n)),
                      "B": 100 * np.cumprod(1 + rng.normal(0, 0.003, n))})
    st = create_strategy(A=asset_config("etf", asset_share=0.5, asset_spread=0),
                         B=asset_config("etf", asset_share=0.5, asset_spread=0))
    r1 = simulation(d, st, balance_mode=True, dca_mode=True, dca_value=100, dca_span=1, order_fee=10, dca_fee=0)
    r2 = simulation(d, st, balance_mode=True, dca_mode=True, dca_value=100, dca_span=1, dca_days=2, order_fee=10, dca_fee=0)
    assert r1.fees_paid > 0 and r1.fees_paid == approx(r2.fees_paid, abs=0.1 * r2.fees_paid)
    r3 = simulation(d, st, dca_mode=True, dca_value=100, dca_span=1, dca_days=2, order_fee=10, dca_fee=0)
    assert r3.fees_paid == 20


def test_r1_05_split_ganze_stuecke():
    rng = np.random.default_rng(3)
    n = 3 * 365
    d = pd.DataFrame({"date": pd.date_range("2020-01-01", periods=n), "A": 100 * np.cumprod(1 + rng.normal(2e-3, 0.01, n))})
    i = int(np.flatnonzero(d.A > 250)[0])
    a = simulation(d, st1(), fractions=False)
    b = simulation(d, st1(), fractions=False, split_mode=True, split_thresh=(20, 250))
    assert b.worth[i] == approx(a.worth[i], rel=1e-12)
    cnt = b.report["A"]["worth"][i] / 100
    assert cnt == approx(round(cnt), abs=1e-9)


def test_r1_12_spaeter_startendes_asset():
    d = cal("2020-01-01", "2022-03-10", A=100.0, B=100.0)
    st = create_strategy(A=asset_config("etf", asset_share=0.5, asset_spread=0),
                         B=asset_config("etf", asset_share=0.5, asset_spread=0, asset_start="2020-06-01"))
    r = simulation(d, st, balance_mode=True, balance_unit="year")
    for dt in ("2020-06-01", "2021-01-01", "2022-01-01"):
        assert r.report["B"]["share"][idx(r, dt)] == approx(0.5, abs=1e-6)
    r2, w = sim_warn(d, st)
    assert w == [] and r2.report["B"]["share"][idx(r2, "2020-06-01")] == approx(0.5, abs=1e-6)


def test_r1_13_14_sortierung_und_duplikate(capsys):
    rng = np.random.default_rng(4)
    n = 400
    d = pd.DataFrame({"date": pd.date_range("2020-01-01", periods=n), "A": 100 * np.cumprod(1 + rng.normal(3e-4, 0.01, n))})
    ref = simulation(d, st1())
    r = simulation(d.sample(frac=1, random_state=5).reset_index(drop=True), st1())
    assert "sortiert" in capsys.readouterr().err
    assert np.array_equal(r.worth, ref.worth) and np.array_equal(r.dates, ref.dates)
    assert np.array_equal(quiet(d.iloc[::-1].reset_index(drop=True), st1()).worth, ref.worth)
    dd = pd.concat([d, d.iloc[[199]]]).sort_values("date").reset_index(drop=True)
    with pytest.raises(ValueError, match="mehrfach"):
        simulation(dd, st1())


def test_r1_15_na_und_ungueltige_kurse(capsys):
    rng = np.random.default_rng(4)
    n = 400
    d = pd.DataFrame({"date": pd.date_range("2020-01-01", periods=n), "A": 100 * np.cumprod(1 + rng.normal(3e-4, 0.01, n))})
    dn = d.copy()
    dn.loc[99, "A"] = np.nan
    r = simulation(dn, st1())
    assert "LOCF" in capsys.readouterr().err
    dl = d.copy()
    dl.loc[99, "A"] = dl.A[98]
    assert r.worth[99] == simulation(dl, st1()).worth[99]
    assert r.filled[99] and r.statistics["max_drawdown"] < 0.5
    d0 = d.copy()
    d0.loc[49, "A"] = 0
    with pytest.raises(ValueError, match="ungültige Kurse"):
        simulation(d0, st1())
    d1 = d.copy()
    d1.loc[0, "A"] = np.nan
    with pytest.raises(ValueError, match="ersten Zeile"):
        simulation(d1, st1())


def test_r1_16_zwei_termine_an_einem_handelstag():
    rng = np.random.default_rng(7)
    c = days("2020-01-01", "2022-12-31")
    wd = c[c.dayofweek < 5]
    d = pd.DataFrame({"date": wd, "A": 100 * np.cumprod(1 + rng.normal(4e-4, 0.01, len(wd)))})
    r = quiet(d, st1(), dca_mode=True, dca_value=100, dca_span=1, dca_days=[1, 2])
    assert r.report["A"]["flows"].sum() == 36 * 2 * 100


def test_r1_17_attribut_filled():
    rng = np.random.default_rng(11)
    c = days("2021-01-04", "2021-06-30")
    wd = c[c.dayofweek < 5]
    us = pd.DataFrame({"date": wd, "A": 100 * np.cumprod(1 + rng.normal(0, 0.01, len(wd)))})
    from simlev.data_prep import align_series
    with contextlib.redirect_stderr(io.StringIO()):
        al = align_series(A=us)
    kw = dict(dca_mode=True, dca_value=100, dca_span=1, balance_mode=True)
    ra = simulation(al, st1(), **kw)
    rb = quiet(us, st1(), **kw)
    assert np.array_equal(ra.filled, rb.filled) and ra.filled.any()
    assert np.array_equal(ra.worth, rb.worth) and ra.statistics["sd"] == rb.statistics["sd"]
    # Attribut mit anderer Zeilenzahl: Warnung, ignoriert
    bad = al.iloc[:-5].copy()
    bad.attrs["filled"] = al.attrs["filled"]
    _, w = sim_warn(bad, st1())
    assert any("Attribut 'filled' von 'data' hat" in x for x in w)


def test_r1_18_zwangsverkauf_deckt_ordergebuehr():
    d = cal("2020-01-01", "2021-01-31")
    d["A"] = np.linspace(100, 110, len(d))
    a = simulation(d, st1(), tax_mode="person", base_rate=2, use_sparer_pauschbetrag=False)
    b = simulation(d, st1(), tax_mode="person", base_rate=2, use_sparer_pauschbetrag=False, order_fee=10)
    i = int(np.flatnonzero(d.date == pd.Timestamp("2021-01-01"))[0])

    def dlt(r):
        x = r.report["A"]
        return x["worth"][i] + x["money"][i] - (x["worth"][i - 1] + x["money"][i - 1])
    assert dlt(b) < dlt(a) - 7 and b.report["A"]["money"][i] >= 0 and b.fees_paid == 20


def test_r1_19_dashboard_returns():
    from simlev.dashboard import _dashboard_returns
    rng = np.random.default_rng(12)
    n = 3 * 365
    d = pd.DataFrame({"date": pd.date_range("2020-01-01", periods=n), "A": 100 * np.cumprod(1 + rng.normal(4e-4, 0.01, n))})
    r = simulation(d, st1(), dca_mode=True, dca_value=5000, dca_span=1)
    dr = _dashboard_returns(r)
    assert np.std(dr["returns"], ddof=1) == approx(r.statistics["sd"], rel=1e-12)
    assert dr["returns"].max() < 0.1
    assert dr["ppy"] == approx((n - 1) / ((n - 1) / 365.25), rel=1e-15)


def test_r1_21_trigger_fuehrendes_na():
    df = pd.DataFrame({"date": pd.date_range("2020-01-01", periods=6), "target_leverage": [np.nan, 2, 2.3, 2.3, 1.9, 2],
                       "sigma_ewma": [np.nan, np.nan, .1, .2, .1, .1]})
    assert list(compute_rebal_trigger(df, "abs_leverage").rebal_trigger) == [False, False, True, False, True, True]
    assert list(compute_rebal_trigger(df, "vol_band").rebal_trigger) == [False, False, False, True, True, False]
    assert not compute_rebal_trigger(df.assign(sigma_ewma=np.nan), "vol_band").rebal_trigger.any()


def test_r1_22_fehler_und_umwandlungen(capsys):
    rng = np.random.default_rng(4)
    n = 400
    d = pd.DataFrame({"date": pd.date_range("2020-01-01", periods=n), "A": 100 * np.cumprod(1 + rng.normal(3e-4, 0.01, n))})
    ref = simulation(d, st1())
    dc = d.copy()
    dc["date"] = dc.date.dt.strftime("%Y-%m-%d").astype(object)
    r = simulation(dc, st1())
    assert "Text" in capsys.readouterr().err and np.array_equal(r.worth, ref.worth)
    dfac = d.copy()
    dfac["date"] = pd.Categorical(dfac.date.dt.strftime("%Y-%m-%d"))
    assert np.array_equal(quiet(dfac, st1()).worth, ref.worth)
    dx = d.copy()
    dx["date"] = dx.date.dt.strftime("%d.%m.%Y").astype(object)
    with pytest.raises(ValueError, match="JJJJ-MM-TT"):
        simulation(dx, st1())
    with pytest.raises(ValueError, match="Kursspalte 'Z' fehlt"):
        simulation(d, create_strategy(Z=asset_config("etf")))
    with pytest.raises(ValueError, match="nach dem letzten Datentag"):
        simulation(d, st1(), dca_mode=True, dca_value=1, dca_span=1, dca_start="2025-01-01")
    with pytest.raises(ValueError, match="Kein Asset"):
        simulation(d, st1(asset_start="2020-06-01"))
    d["B"] = 100.0
    d["ev"] = False
    d.loc[99, "ev"] = True
    d["wA"] = 0.5
    st2 = create_strategy(A=asset_config("etf", asset_share=0.5), B=asset_config("etf", asset_share=0.5))
    assert any("nicht alle Assets" in w for w in sim_warn(d, st2, event_col="ev", event_weight={"A": "wA"})[1])
    with pytest.raises(ValueError, match="'xx'"):
        simulation(d, st2, event_col="ev", event_weight={"A": "wA", "B": "xx"})
    with pytest.raises(ValueError, match="benannt"):
        simulation(d, st2, event_col="ev", event_weight=["wA", "wA"])
    # POSIXct-ähnlich: Datum-Uhrzeit wird in Date umgewandelt
    dp = d[["date", "A"]].copy()
    dp["date"] = dp.date + pd.Timedelta(hours=12)
    r = simulation(dp, st1())
    assert "Datum-Uhrzeit" in capsys.readouterr().err and np.array_equal(r.worth, ref.worth)


def test_r1_23_plausibilitaet():
    d = cal("2020-01-01", "2021-02-03")
    d["A"] = np.linspace(100, 200, len(d))
    st = create_strategy(A=asset_config("certificate", asset_share=1, asset_spread=0))
    assert any("Prozent" in w for w in sim_warn(d, st, church_tax=0.09)[1])
    for v in (-9, "9"):
        with pytest.raises(ValueError, match="church_tax"):
            simulation(d, st, church_tax=v)
    assert any("ungewöhnlich" in w for w in sim_warn(d, st, church_tax=100)[1])
    assert any("Prozent" in w for w in sim_warn(d, st, tax_rate=0.26375)[1])
    for v in (40, 0):
        with pytest.raises(ValueError, match="dca_days"):
            simulation(d, st, dca_mode=True, dca_value=100, dca_span=1, dca_days=v)
    with pytest.raises(ValueError, match="fix"):
        simulation(d, st, order_fee={"fix": 5})
    d0 = d.copy()
    d0["A"] = 100.0
    assert any("nicht verkauft" in w for w in sim_warn(d0, st, start_value=100, order_fee=60, liquidate=True)[1])
    assert any("harvest_mode" in w for w in sim_warn(d, st, harvest_mode=True)[1])
    d["ev"] = False
    d.loc[99, "ev"] = True
    d["wN"] = -1.0
    d["B"] = 100.0
    st2 = create_strategy(A=asset_config("etf", asset_share=0.5), B=asset_config("etf", asset_share=0.5))
    with pytest.raises(ValueError, match="nicht negative"):
        simulation(d, st2, event_col="ev", event_weight={"A": "wN", "B": "wN"})


def test_r1_24_dca_anchor_end():
    d = cal("2020-01-01", "2020-12-31", A=100.0)
    r = simulation(d, st1(), dca_mode=True, dca_value=100, dca_span=1, dca_days=31, dca_anchor="end")
    dts = pd.DatetimeIndex(r.dates[r.report["A"]["flows"] > 0])
    assert list(dts.strftime("%m-%d")) == ["01-01", "03-01", "05-01", "07-01", "08-01", "10-01", "12-01"]
    r29 = simulation(d, st1(), dca_mode=True, dca_value=100, dca_span=1, dca_days=29, dca_anchor="end")
    assert (r29.report["A"]["flows"] > 0).sum() == 12


def test_r1_25_update_asset():
    s = update_asset(create_strategy(X=asset_config("certificate")), "X", asset_class="etf", asset_bonus=30)
    assert s.X.tax_regime == "investment_fund"
    assert update_asset(create_strategy(G=asset_config("etc")), "G", deliverable=True).G.tax_regime == "private_sale"
    s = update_asset(create_strategy(E=asset_config("etf", tax_regime="capital_gains")), "E", deliverable=True)
    assert s.E.tax_regime == "capital_gains"


def test_r1_26_spread_warnt():
    assert any("spread" in w for w in sim_warn(cal("2020-01-01", "2020-03-01", A=100.0), st1(), spread=5)[1])


def test_harvest_mode_realisiert_bis_pauschbetrag():
    """harvest_mode: Gewinne einmal im Jahr bis zum freien Sparer-Pauschbetrag realisieren."""
    d = cal("2020-01-01", "2021-12-31")
    d["A"] = np.linspace(100, 200, len(d))
    st = create_strategy(A=asset_config("etf", asset_share=1, asset_spread=0, asset_bonus=0))
    r = sim(d, st, start_value=10000, tax_mode="person", harvest_mode=True)
    hd = pd.DatetimeIndex(r.harvest_days)
    assert list(hd.strftime("%Y-%m-%d")) == ["2020-12-15", "2021-12-15"]
    assert r.tax_report["sparer_pauschbetrag_used"] == approx(2000, abs=0.02)
    assert r.tax_report["total_taxes_paid"] == approx(0, abs=0.01)
    with pytest.raises(ValueError, match="harvest_day im Format 'MM-TT'"):
        simulation(d, st, tax_mode="person", harvest_mode=True, harvest_day="12-31")
