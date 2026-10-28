"""Port von test-engine-rest.R, test-review9-engine.R und test-tariff.R (Engine-Teile)."""
import math
import os
import re

import numpy as np
import pandas as pd
import pytest

import simlev
from simlev import asset_config, create_strategy, tax_tariff, simulation
from simlev.engine import xirr_rate
from simlev._tax_tariff import tariff_income_tax as T_, tariff_soli as S_

from _helpers import days, flag, idx, lin, sim, sim_out, sim_warn
from simlev import dca_plan, income_rate, income_tariff, rebalance_plan, sim_costs, tax_profile  # Bausteine (Etappe 6.3)

approx = pytest.approx


def _p23(end="2021-06-30", tax=None, **kw):
    d = days("2020-01-01", end)
    df = pd.DataFrame({"date": d, "G": np.where(d < pd.Timestamp("2020-06-01"), 100.0, 150.0)})
    df["cb"] = d == d[0]
    df["cs"] = d == pd.Timestamp("2020-06-01")
    st = create_strategy(G=asset_config(asset_class="etc", trading="signal", share=1, spread=0, deliverable=True,
                                        signal_buy="cb", signal_sell="cs"))
    return sim(df, st, start_value=1e4, tax=tax_profile(income=income_rate(marginal_rate=42)) if tax is None else tax, **kw)


def test_r3a02_p23_steuer_aus_cash():
    r = _p23()
    assert r.tax_report["total_taxes_paid"] == 2100 and r.worth[-1] == 12900
    i = idx(r, "2021-01-01")
    assert r.worth[i - 1] == 15000 and r.worth[i] == 12900 and r.report["G"]["money"][i] == 12900
    r2 = _p23(end="2020-12-31")
    assert r2.worth[-1] == 12900 and r2.tax_report["total_taxes_paid"] == 2100


def test_r3a02_zwangsverkauf_und_andere_assets():
    d = days("2020-01-01", "2021-06-30")
    df = pd.DataFrame({"date": d, "G": np.where(d < pd.Timestamp("2020-06-01"), 100.0, 150.0)})
    df["cb"] = flag(d, ["2020-01-01", "2020-07-01"])
    df["cs"] = d == pd.Timestamp("2020-06-01")
    st = create_strategy(G=asset_config(asset_class="etc", trading="signal", share=1, spread=0, deliverable=True,
                                        signal_buy="cb", signal_sell="cs"))
    r = sim(df, st, start_value=1e4, tax=tax_profile(income=income_rate(marginal_rate=42)))
    i = idx(r, "2021-01-01")
    assert r.report["G"]["worth"][i - 1] == 15000
    assert r.report["G"]["worth"][i] == approx(15000 - 2100, rel=1e-7)
    assert abs(r.report["G"]["money"][i]) < 0.005
    # hat das Asset weder Cash noch Bestand, zahlen die übrigen Assets
    d = days("2020-01-01", "2021-03-31")
    df = pd.DataFrame({"date": d, "G": np.where(d < pd.Timestamp("2020-06-01"), 100.0, 150.0), "H": 50.0})
    df["cb"] = d == d[0]
    df["cs"] = d == pd.Timestamp("2020-06-01")
    df["ev"] = d == pd.Timestamp("2020-07-01")
    df["wG"] = 0.0
    df["wH"] = 1.0
    st = create_strategy(G=asset_config(asset_class="etc", trading="signal", share=0.5, spread=0, deliverable=True,
                                        signal_buy="cb", signal_sell="cs"),
                         H=asset_config(asset_class="certificate", trading="bnh", share=0.5, spread=0))
    r = sim(df, st, start_value=1e4, rebalance=rebalance_plan(event_col="ev", event_mode="replace", skip=True, event_weight={"G": "wG", "H": "wH"}), tax=tax_profile(income=income_rate(marginal_rate=42)))
    i = idx(r, "2021-01-01")
    assert r.report["G"]["total"][i - 1] == 0
    assert r.report["H"]["worth"][i - 1] == 250 * 50 and r.report["H"]["worth"][i] == approx(229 * 50, rel=1.5e-8)
    assert r.worth[-1] == 12500 - 1050 and r.tax_report["total_taxes_paid"] == 1050


def test_r3a01_kursloses_folgejahr():
    d = days("2020-01-01", "2022-06-30")
    df = pd.DataFrame({"date": d, "A": lin(d, ["2020-01-01", "2020-12-31"], [100, 110]),
                       "C": lin(d, ["2020-01-01", "2022-02-01", "2022-02-02"], [100, 100, 90])})
    gap = (d > pd.Timestamp("2020-12-31")) & (d <= pd.Timestamp("2021-12-31"))
    df.loc[gap, "A"] = np.nan
    df.loc[gap, "C"] = np.nan
    df["cb"] = d == d[0]
    df["cs"] = d == pd.Timestamp("2022-03-01")
    st = create_strategy(A=asset_config(asset_class="etf", trading="bnh", share=0.5, spread=0),
                         C=asset_config(asset_class="certificate", trading="signal", share=0.5, spread=0, signal_buy="cb",
                                        signal_sell="cs"))
    r, out = sim_out(df, st, start_value=1e5, tax=tax_profile(base_rate=2.55))
    vp = [ln for ln in out if re.search(r"Vorabpauschale A \(festgesetzt 2020", ln)]
    assert len(vp) == 1 and re.search(r"892.50 EUR.*SPB 892.50 EUR, Steuer 0.00 EUR am 2021-01-01", vp[0])
    assert r.tax_report["loss_carryforward_capital"] == 5000


def test_r3a03_ganze_stuecke_aufgerundet():
    d = days("2020-01-01", "2021-01-31")
    df = pd.DataFrame({"date": d, "A": lin(d, ["2020-01-01", "2020-12-31", "2021-01-31"], [100, 110, 110])})
    st = create_strategy(A=asset_config(asset_class="etf", trading="bnh", share=1, spread=0, partial_exemption=0))
    r, out = sim_out(df, st, start_value=1e6, tax=tax_profile(base_rate=2.55), fractions=False)
    assert any("Verkauf 42.00x A zu 110.00" in ln for ln in out)
    i = idx(r, "2021-01-01")
    tax_vp, tax_sale = 16850 * 0.26375, 42 * 8.215 * 0.26375
    assert r.tax_report["total_taxes_paid"] == approx(tax_vp + tax_sale, rel=1e-10)
    assert r.worth[i - 1] - r.worth[i] == approx(tax_vp + tax_sale, rel=1e-9)
    assert r.report["A"]["money"][i] == approx(42 * 110 - tax_sale - tax_vp, rel=1e-9)


def test_r3a04_kein_rueckkauf():
    d = days("2020-01-01", "2020-12-30")
    df = pd.DataFrame({"date": d, "A": lin(d, ["2020-01-01", "2020-07-01", "2020-12-30"], [100, 120, 120]), "B": 50.0})
    st = create_strategy(A=asset_config(asset_class="etf", trading="bnh", share=0.5, spread=0.2),
                         B=asset_config(asset_class="etf", trading="bnh", share=0.5, spread=0.2, start="2020-07-01"))
    r, out = sim_out(df, st, start_value=1e4, tax=tax_profile())
    day = [ln for ln in out if "2020-07-01" in ln]
    assert any("Verkauf 50.00x A zu 119.88" in ln for ln in day)
    assert not any(re.search(r"Kauf .* A zu", ln) and "Verkauf" not in ln for ln in day)
    assert r.tax_report["total_taxes_paid"] == 0
    j = idx(r, "2020-07-01")
    assert r.report["A"]["worth"][j] == approx((10000 / 100.1 - 50) * 120, rel=1e-5)
    assert abs(r.report["A"]["money"][j]) < 0.005


def test_r3a05_asset_start_nach_datenende():
    d = days("2020-01-01", "2021-03-31")
    df = pd.DataFrame({"date": d, "A": np.linspace(100, 110, len(d)), "B": 50.0})
    st = create_strategy(A=asset_config(asset_class="etf", trading="bnh", share=0.5, spread=0),
                         B=asset_config(asset_class="etf", trading="bnh", share=0.5, spread=0, start="2022-01-01"))
    with pytest.raises(ValueError, match=r"start von 'B' \(2022-01-01\) liegt nach dem letzten Datentag \(2021-03-31\)"):
        simulation(df, st, start_value=1e4)
    st = simlev.strategy_update_asset(st, "B", start="2021-03-31")
    assert isinstance(sim(df, st, start_value=1e4), simlev.SimLevResult)


def test_r3a06_kirchensteuer():
    r = _p23(tax=tax_profile(church_tax=9, income=income_rate(42)))
    assert r.tax_report["total_taxes_paid"] == approx(2289) and r.worth[-1] == approx(12711)
    r8 = _p23(tax=tax_profile(church_tax=8, income=income_rate(42, soli_rate=5.5)))
    assert r8.tax_report["total_taxes_paid"] == approx(5000 * 0.42 * (1 + 0.055 + 0.08))
    d = days("2020-01-01", "2020-12-31")
    df = pd.DataFrame({"date": d, "Z": np.where(d < pd.Timestamp("2020-06-01"), 100.0, 150.0)})
    df["cb"] = d == d[0]
    df["cs"] = d == pd.Timestamp("2020-06-01")
    st = create_strategy(Z=asset_config(asset_class="certificate", trading="signal", share=1, spread=0, signal_buy="cb",
                                        signal_sell="cs"))
    g = sim(df, st, start_value=1e4, tax=tax_profile(church_tax=9, guenstigerpruefung=True, income=income_rate(marginal_rate=20)))
    assert g.tax_report["total_taxes_paid"] == approx(4000 * 0.20 * 1.09)
    a = sim(df, st, start_value=1e4, tax=tax_profile(church_tax=9))
    assert a.tax_report["total_taxes_paid"] == approx(4000 * 0.25 / (1 + 0.25 * 0.09) * (1 + 0.055 + 0.09))
    # R4-01: Günstigerprüfung vergleicht einschließlich Zuschlagsteuern
    abg = 4000 * 0.25 / 1.0225 * 1.145
    r = sim(df, st, start_value=1e4, tax=tax_profile(church_tax=9, guenstigerpruefung=True, income=income_rate(marginal_rate=24.9, soli_rate=5.5)))
    assert r.tax_report["total_taxes_paid"] == approx(abg)
    assert sim(df, st, start_value=1e4, tax=tax_profile(guenstigerpruefung=True, income=income_rate(marginal_rate=25.5))).tax_report["total_taxes_paid"] == approx(4000 * 0.255)


def test_r3a07_na_basiszins():
    def run(d, na=True):
        df = pd.DataFrame({"date": d, "A": lin(d, ["2020-01-01", "2020-12-31", "2021-02-26"], [100, 110, 110]),
                           "BR": 2.0})
        if na:
            df.loc[df.date == pd.Timestamp("2020-01-02"), "BR"] = np.nan
        df = df[df.date != pd.Timestamp("2020-01-01")].reset_index(drop=True)
        return sim(df, create_strategy(A=asset_config(asset_class="etf", trading="bnh", share=1, spread=0)), start_value=1e6, tax=tax_profile(base_rate="BR"))
    d = days("2020-01-01", "2021-02-26")
    dt = d[d.dayofweek < 5]
    assert run(d).tax_report["total_taxes_paid"] == 0
    assert run(dt).tax_report["total_taxes_paid"] == 0
    assert run(dt, na=False).tax_report["total_taxes_paid"] > 0


def test_r3b01_knockout_mit_sparplan():
    dd = days("2020-01-01", "2023-12-31")
    p = np.full(len(dd), 100.0)
    p[dd >= pd.Timestamp("2023-12-20")] = 1e-3
    r, w = sim_warn(pd.DataFrame({"date": dd, "A": p}), create_strategy(A=asset_config(asset_class="etf", trading="bnh", share=1,
                                                                                        spread=0)), start_value=1000, dca=dca_plan(value=100, span=1))
    assert w == [] and math.isfinite(r.cagr)
    assert xirr_rate([0, 1], [1000, 100], 50, 1) != xirr_rate([0, 1], [1000, 100], 50, 1)   # NA


def test_r3b02_bewertung_zum_zahlungszeitpunkt():
    rng = np.random.default_rng(1)
    n = 400
    d = pd.DataFrame({"date": pd.date_range("2015-01-01", periods=n), "A": 100 * np.cumprod(1 + rng.normal(3e-4, 0.012, n))})
    st = create_strategy(A=asset_config(asset_class="etf", trading="bnh", share=1, spread=0.1))
    r = sim(d, st, start_value=1, dca=dca_plan(value=500, span=1, days=15))
    w = r.worth
    fl = r.report["A"]["flows"]
    g = r.twr_index[1:] / r.twr_index[:-1]
    f = np.flatnonzero(fl[1:] != 0)
    nf = np.flatnonzero(fl[1:] == 0)
    a = d.A.to_numpy()
    vpre = r.report["A"]["worth"][f] * a[f + 1] / a[f] + r.report["A"]["money"][f]
    assert g[f] == approx(vpre / w[f] * w[f + 1] / (vpre + fl[f + 1]), rel=1e-12)
    assert g[f[0]] > 0.99
    assert g[nf] == approx(1 + (w[nf + 1] - w[nf]) / w[nf], rel=1e-15)
    # ohne Kosten folgt der Index exakt dem Kurs
    st0 = create_strategy(A=asset_config(asset_class="etf", trading="bnh", share=1, spread=0))
    r0 = sim(d, st0, start_value=1, dca=dca_plan(value=500, span=1))
    assert r0.external_flows and r0.twr_index == approx(a / a[0], rel=1e-12)


def test_r3b03_invested_brutto():
    rng = np.random.default_rng(1)
    n = 1500
    d = pd.DataFrame({"date": pd.date_range("2015-01-01", periods=n), "A": 100 * np.cumprod(1 + rng.normal(3e-4, 0.012, n))})
    st = create_strategy(A=asset_config(asset_class="etf", trading="bnh", share=1, spread=2))
    r = sim(d, st, start_value=10000, costs=sim_costs(order_fee=10), dca=dca_plan(value=500, span=1))
    assert r.invested[0] == 10500 and r.invested[-1] == 10000 + 50 * 500
    fl = r.report["A"]["flows"]
    fi = np.flatnonzero((np.arange(n) > 0) & (fl != 0))
    a = np.r_[10000 + fl[0], fl[fi]]
    tau = (n - 1 - np.r_[0, fi]) / 365.25
    assert abs(sum(a * (1 + r.cagr) ** tau) - r.worth[-1]) < 1e-6
    r0 = sim(d, st, start_value=10000)
    assert r0.cagr == approx((r0.worth[-1] / r0.worth[0]) ** (365.25 / (n - 1)) - 1, rel=1e-14)


def test_r4_02_erstattung_im_endwert():
    def run(end, g_up=False):
        d = days("2020-01-01", end)
        df = pd.DataFrame({"date": d, "X": np.where(d < pd.Timestamp("2020-03-01"), 100.0, 150.0),
                           "Y": np.where(d < pd.Timestamp("2020-10-01"), 100.0, 70.0),
                           "G": np.where(d < pd.Timestamp("2020-06-01"), 100.0, 125.0 if g_up else 100.0)})
        df["b"] = d == d[0]
        for c, at in (("sx", "2020-03-01"), ("sy", "2020-10-01"), ("sg", "2020-06-01")):
            df[c] = d == pd.Timestamp(at)

        def cf(s, cls="certificate"):
            return asset_config(asset_class=cls, trading="signal", share=1 / 3, spread=0, deliverable=True, signal_buy="b",
                                signal_sell=s)
        return sim(df, create_strategy(X=cf("sx"), Y=cf("sy"), G=cf("sg", "etc")), start_value=15000, tax=tax_profile(income=income_rate(marginal_rate=42)))
    for end in ("2020-12-31", "2020-11-30", "2021-01-01"):
        r = run(end)
        assert r.worth[-1] == approx(16000) and r.tax_report["total_taxes_paid"] == approx(0, abs=1e-9)
    assert run("2020-12-31", True).worth[-1] == approx(16725)


def test_r4_05_negativer_endwert():
    d = days("2020-01-01", "2021-06-30")
    df = pd.DataFrame({"date": d, "G": np.where(d < pd.Timestamp("2020-06-01"), 100.0, 150.0),
                       "H": np.where(d < pd.Timestamp("2020-10-01"), 50.0, 1.0)})
    df["ev"] = d == pd.Timestamp("2020-07-01")
    df["wG"] = 0.0
    df["wH"] = 1.0
    st = create_strategy(G=asset_config(asset_class="etc", trading="bnh", share=0.5, spread=0, deliverable=True),
                         H=asset_config(asset_class="certificate", trading="bnh", share=0.5, spread=0))
    r, w = sim_warn(df, st, start_value=1e4, rebalance=rebalance_plan(event_col="ev", event_mode="replace", skip=True, event_weight={"G": "wG", "H": "wH"}), tax=tax_profile(income=income_rate(marginal_rate=42)))
    assert r.worth[-1] == -800 and r.tax_report["open_tax_debt"] == 800
    assert math.isnan(r.cagr) and math.isnan(r.ttwror)
    assert np.all((r.drawdowns >= 0) & (r.drawdowns <= 1)) and r.statistics["max_drawdown"] == 1
    assert any(re.search(r"Endwert negativ \(-800.00 EUR", x) for x in w)
    assert any("800.00 EUR bleiben als negativer Geldbestand" in x for x in w)
    um = r.undefined_metrics
    assert list(um.metric[:2]) == ["cagr", "ttwror"] and um.reason[0] == "negative_end_value"
    assert "CAGR:             nicht definiert (Endwert -800.00 EUR negativ: offene Steuerschuld 800.00 EUR)" in str(r)
    assert "  Steuerschuld:     800.00 EUR (offen, nicht gedeckt)" in str(r)


def test_r4_07_dca_pruefung():
    d = pd.DataFrame({"date": pd.date_range("2020-01-01", periods=400), "A": 100.0})
    st = create_strategy(A=asset_config(asset_class="etf", trading="bnh", share=1, spread=0))
    for v in ([100, 200], float("nan"), "100", 0, -5, float("inf"), None):
        with pytest.raises(ValueError, match="dca_plan: 'value' muss eine einzelne endliche Zahl > 0 sein"):
            dca_plan(value=v, span=1)
    for v in ([1, 2], float("nan"), 1.5, 0, "1"):
        with pytest.raises(ValueError, match="dca_plan: 'span' muss eine einzelne ganze Zahl >= 1 sein"):
            dca_plan(value=100, span=v)
    with pytest.raises(ValueError, match="dca_plan: 'span' muss .* nicht NULL"):
        dca_plan(100)
    assert isinstance(sim(d, st, dca=dca_plan(value=100, span=2)), simlev.SimLevResult)


# ═══════════════════════════════════════════════════════════════════════════
# test-review9-engine.R
# ═══════════════════════════════════════════════════════════════════════════

def test_r9_03_zahlenformat():
    dd = days("2024-01-01", "2024-12-31")
    n = len(dd)
    d = pd.DataFrame({"date": dd, "G": np.linspace(100, 130, n)})
    d["b"] = np.arange(n) == 0
    d["s"] = dd == pd.Timestamp("2024-09-02")
    s = create_strategy(G=asset_config(asset_class="etc", trading="signal", deliverable=True, spread=0, signal_buy="b", signal_sell="s"))
    r, w = sim_warn(d, s, start_value=10000, tax=tax_profile())
    msg = [x for x in w if "erreichen die Freigrenze" in x]
    assert len(msg) == 1 and "Gewinne (2013.70 EUR) erreichen die Freigrenze (1000.00 EUR)" in msg[0]
    out = str(r).splitlines()
    assert any(re.search("ngster DD:      1 Tag$", ln) for ln in out)
    assert any(re.search("Mittl. Erholung:  –$", ln) for ln in out)
    r1, w1 = sim_warn(pd.DataFrame({"date": [pd.Timestamp("2024-01-02")], "A": [100.0]}),
                      {"A": {"asset_class": "etf", "trading": "bnh", "share": 1}})
    assert any("Zeitraum 1 Tag (Laufzeit 0 Jahre)" in x for x in w1)
    assert not any("Tag(e)" in x for x in r1.undefined_metrics.detail)
    assert "Zeitraum:         1 Tag (" in str(r1.summary())
    assert math.isnan(r1.buys["A"]) and "buys" in list(r1.undefined_metrics.metric)


def test_r9_04_startkapital():
    rng = np.random.default_rng(42)
    n = 365 * 3
    data = pd.DataFrame({"date": pd.date_range("2015-01-01", periods=n),
                         "WORLD": 100 * np.cumprod(1 + rng.normal(4e-4, 0.010, n)),
                         "BONDS": 50 * np.cumprod(1 + rng.normal(1e-4, 0.003, n))})
    st = create_strategy(WORLD=asset_config(asset_class="etf", share=0.7), BONDS=asset_config(asset_class="etf", share=0.3))
    r = simulation(data, st, start_value=10000, dca=dca_plan(value=250, span=1, unit="month"))
    sm = r.summary()
    assert sm.start_capital == 10000 and sm.start_value == r.worth[0]
    out = str(sm)
    assert "Startkapital:     10000.00 EUR" in out and ("Depotwert Starttag: %.2f EUR" % r.worth[0]) in out
    assert simulation(data, st, start_value=5000).summary().start_capital == 5000


def test_r9_06_prozentwarnung_spalten():
    rng = np.random.default_rng(9)
    n = 900
    d = pd.DataFrame({"date": pd.date_range("2021-01-01", periods=n), "A": 100 * np.cumprod(1 + rng.normal(3e-4, 0.01, n))})
    d["rf_anteil"] = 0.025
    d["br_anteil"] = 0.0255
    d["rf_proz"] = 2.5
    d["br_proz"] = np.r_[0.07, np.repeat(2.55, n - 1)]
    d["rf_null"] = 0.0
    s = create_strategy(A=asset_config(asset_class="etf", partial_exemption=30))
    _, w = sim_warn(d, s, risk_free="rf_anteil")
    assert len(w) == 1 and "risk_free-Spalte 'rf_anteil' hat den Median 0.025 und wird als 0.025 % gelesen" in w[0]
    _, w = sim_warn(d, s, start_value=2e5, tax=tax_profile(base_rate="br_anteil"))
    assert len(w) == 1 and "base_rate-Spalte 'br_anteil' hat den Median 0.0255" in w[0]
    assert sim_warn(d, s, risk_free="rf_proz")[1] == [] and sim_warn(d, s, risk_free="rf_null")[1] == []
    assert sim_warn(d, s, start_value=2e5, tax=tax_profile(base_rate="br_proz"))[1] == []


def test_r9_02_veranlagung_details():
    rng = np.random.default_rng(42)
    n = 365 * 10
    data = pd.DataFrame({"date": pd.date_range("2015-01-01", periods=n),
                         "WORLD": 100 * np.cumprod(1 + rng.normal(4e-4, 0.010, n)),
                         "GOLD": 50 * np.cumprod(1 + rng.normal(3e-4, 0.012, n))})
    st = create_strategy(WORLD=asset_config(asset_class="etf", trading="bnh", share=0.6, spread=0.1, partial_exemption=30),
                         GOLD=asset_config(asset_class="etc", trading="bnh", share=0.4, spread=0.2, deliverable=True))
    kw = dict(start_value=100000, rebalance=rebalance_plan(span=1, unit="month", thresh=3),
              tax=tax_profile(base_rate=2.55, church_tax=9, guenstigerpruefung=True, income=income_tariff(14000)),
              liquidate=True)
    r, out = sim_out(data, st, **kw)
    r0 = sim(data, st, **kw)
    assert np.array_equal(r0.worth, r.worth) and r0.tax_report["total_taxes_paid"] == r.tax_report["total_taxes_paid"]
    assert not any("§ 23 EStG: Steuer" in ln for ln in out)
    ty = r.tax_report["tariff_years"]
    for _, row in ty.iterrows():
        lines = [ln for ln in out if "Veranlagung %d: Nachzahlung" % row.year in ln]
        if row.settlement > 0:
            assert len(lines) == 1
            assert ("Nachzahlung %.2f EUR (davon § 23 %.2f EUR" % (row.settlement, row.tax_p23)) in lines[0]


# ═══════════════════════════════════════════════════════════════════════════
# test-tariff.R
# ═══════════════════════════════════════════════════════════════════════════

_TT_OK = ["# Geltung: Testtarif", "art,ab,bezug,teiler,a,b,c", "zone,0,0,1,0,0,0", "zone,10001,10000,1,0,0.2,0",
          "soli,20350,,,5.5,11.9,"]


def _tt_file(tmp_path, lines, name="t.csv"):
    f = tmp_path / name
    f.write_text("\n".join(lines) + "\n", encoding="utf-8")
    return str(f)


def test_tarif_mitgeliefert():
    tt = tax_tariff()
    assert isinstance(tt, simlev.SimLevTaxTariff) and tt.geltung == "ab VZ 2026"
    assert list(tt.zones["ab"]) == [0, 12349, 17800, 69879, 277826]
    assert tt.soli == {"freigrenze": 20350, "satz": 5.5, "milderung": 11.9}
    out = str(tt)
    assert "Geltung: ab VZ 2026" in out and "69 879 - 277 825" in out
    assert "Soli: 5.5 % der ESt, wenn die ESt 20 350 EUR übersteigt" in out
    hd = open(os.path.join(os.path.dirname(simlev.__file__), "data", "steuertarif.csv"), encoding="utf-8").read()
    assert "Grenzsteuersatz als ANTEIL, 0.42 fuer 42 % (NICHT 42)" in hd


@pytest.mark.parametrize("x,t", [(12348, 0), (12349, 0), (17799, 1034), (17800, 1035), (69878, 18213), (69879, 18213),
                                 (277825, 105550), (277826, 105551), (15000, 435), (50000, 10548), (100000, 30864),
                                 (300000, 115529), (17799.99, 1034), (-5000, 0)])
def test_tarif_werte(x, t):
    assert T_(tax_tariff(), x) == t


@pytest.mark.parametrize("e,s", [(20350, 0), (20351, 0.11), (20994, 76.63), (30000, 1148.35), (37838, 2081.07),
                                 (37839, 2081.14), (40000, 2200)])
def test_soli(e, s):
    assert S_(tax_tariff(), e) == approx(s, abs=1e-12)


def test_tarifdatei_fehler(tmp_path):
    with pytest.raises(ValueError, match="nicht gefunden"):
        tax_tariff(file=str(tmp_path / "gibt_es_nicht.csv"))
    cases = [([re.sub(",c$", ",x", ln) for ln in _TT_OK], "fehlen die Spalten c"),
             ([re.sub("^zone,10001", "zonen,10001", ln) for ln in _TT_OK], "art = 'zonen'"),
             ([re.sub("0.2,0$", "zwei,0", ln) for ln in _TT_OK], r"Spalte 'b' in Datenzeile 2 .*nicht numerisch"),
             ([re.sub("^zone,0,", "zone,5,", ln) for ln in _TT_OK], "erste Zone muss bei ab = 0"),
             (_TT_OK[:3] + ["zone,0,0,1,0,0,0", _TT_OK[4]], "streng aufsteigend"),
             (_TT_OK + ["soli,1,,,1,1,"], r"genau eine soli-Zeile geben \(gefunden: 2\)"),
             (_TT_OK[:4], r"genau eine soli-Zeile geben \(gefunden: 0\)"),
             ([ln.replace("10000,1,0,0.2", "10000,0,0,0.2") for ln in _TT_OK], "teiler muss > 0"),
             ([ln.replace("5.5,11.9", "155,11.9") for ln in _TT_OK], r"Zuschlagsatz \(a\) muss zwischen 0 und 100"),
             ([ln.replace(",", ";") for ln in _TT_OK], "nur eine Spalte gelesen.*Semikolon"),
             ([re.sub("0.2,0$", "0,2,0", ln) for ln in _TT_OK],
              r"hat die Zeile 'zone,10001,10000,1,0,0,2,0' 8 Felder, die Kopfzeile 7.*Punkt \(0.42, nicht 0,42\)")]
    for i, (lines, msg) in enumerate(cases):
        with pytest.raises(ValueError, match=msg):
            tax_tariff(file=_tt_file(tmp_path, lines, "c%d.csv" % i))
    with pytest.warns(UserWarning, match="springt an der Zonengrenze 10001 EUR um 2000.20 EUR"):
        tax_tariff(file=_tt_file(tmp_path, [ln.replace("10001,10000,1", "10001,0,1") for ln in _TT_OK], "j.csv"))
    base = ["art,ab,bezug,teiler,a,b,c", "zone,0,0,1,0,0,0"]
    soli = "soli,20350,,,5.5,11.9,"
    with pytest.raises(ValueError, match=r"Zone ab 10001 EUR \(Datenzeile 2\): Grenzsteuersatz 42 bei x = 10001 EUR"):
        tax_tariff(file=_tt_file(tmp_path, base + ["zone,10001,0,1,0,42,-420042", soli], "p.csv"))
    with pytest.raises(ValueError, match="Grenzsteuersatz 100 bei x = 10000000 EUR"):
        tax_tariff(file=_tt_file(tmp_path, base + ["zone,10001,10000,10000,500,1000,0", soli], "q.csv"))
    with pytest.raises(ValueError, match="Steuer 52000.20 EUR bei x = 10001 EUR übersteigt das Einkommen"):
        tax_tariff(file=_tt_file(tmp_path, base + ["zone,10001,0,1,0,0.2,50000", soli], "r.csv"))


def test_eigene_tarifdatei_in_simulation(tmp_path):
    f = _tt_file(tmp_path, _TT_OK)
    assert T_(tax_tariff(file=f), 50000) == 8000
    d = days("2020-01-01", "2021-03-31")
    df = pd.DataFrame({"date": d, "G": np.where(d < pd.Timestamp("2020-06-01"), 100.0, 150.0), "H": 50.0})
    df["ev"] = d == pd.Timestamp("2020-07-01")
    df["wG"] = 0.0
    df["wH"] = 1.0
    st = create_strategy(G=asset_config(asset_class="etc", trading="bnh", share=0.5, spread=0, deliverable=True),
                         H=asset_config(asset_class="certificate", trading="bnh", share=0.5, spread=0))

    def run(**kw):
        return sim(df, st, start_value=1e4, rebalance=rebalance_plan(event_col="ev", event_mode="replace", skip=True, event_weight={"G": "wG", "H": "wH"}), tax=tax_profile(income=income_tariff(taxable_income=50000, **kw)))
    assert run(tariff=f).tax_report["total_taxes_paid"] == 500
    assert run(tariff=tax_tariff(file=f)).tax_report["total_taxes_paid"] == 500
    r = run()
    assert r.tax_report["total_taxes_paid"] == 11437 - 10548
    ty = r.tax_report["tariff_years"]
    assert list(ty.year) == [2020, 2021] and ty.tax_p23[0] == 11437 - 10548
    assert r.tax_report["next_year"]["year"] == 2022
    with pytest.raises(ValueError, match="income_tariff: tariff muss NULL"):
        run(tariff=42)
