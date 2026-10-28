"""Port von r/tests/testthat/test-engine-notes.R: A Einkommensteuertarif (taxable_income),
B undefined_metrics, C summary-Renditen, D Warnung funds_fee/bonus_fee, E open_lots, next_year."""
import contextlib
import io
import math
import warnings

import numpy as np
import pandas as pd
import pytest

import simlev
from simlev import asset_config, create_strategy, read_tax_tariff, simulation

from _helpers import days, sim, sim_out, sim_warn


def E(v, tol=1.5e-8):
    """``expect_equal`` (mittlere relative Abweichung; bei Sollwert 0 absolut)."""
    return pytest.approx(v, rel=tol, abs=tol if np.all(np.asarray(v) == 0) else 0)


def T(x):
    """Unabhängige Handrechnung § 32a Abs. 1 EStG (VZ 2026)."""
    x = math.floor(max(0, x))
    if x <= 12348:
        t = 0
    elif x <= 17799:
        y = (x - 12348) / 1e4
        t = (914.51 * y + 1400) * y
    elif x <= 69878:
        z = (x - 17799) / 1e4
        t = (173.10 * z + 2397) * z + 1034.87
    elif x <= 277825:
        t = 0.42 * x - 11135.63
    else:
        t = 0.45 * x - 19470.38
    return math.floor(t)


def D(s):
    return pd.Timestamp(s)


def p23(p2=150, end="2021-03-31", **kw):
    d = days("2020-01-01", end)
    df = pd.DataFrame({"date": d, "G": np.where(d < D("2020-06-01"), 100.0, p2), "H": 50.0})
    df["ev"] = d == D("2020-07-01")
    df["wG"] = 0.0
    df["wH"] = 1.0
    st = create_strategy(G=asset_config("etc", "bnh", asset_share=0.5, asset_spread=0, deliverable=True),
                         H=asset_config("certificate", "bnh", asset_share=0.5, asset_spread=0))
    return sim(df, st, start_value=1e4, tax_mode="person", event_col="ev", event_mode="replace",
               event_weight={"G": "wG", "H": "wH"}, **kw)


def gp_df(end="2021-03-31", pz=70):
    d = days("2020-01-01", end)
    df = pd.DataFrame({"date": d, "Z": np.where(d < D("2020-06-01"), 50.0, pz), "M": 100.0})
    df["ev"] = d == D("2020-07-01")
    df["wZ"] = 0.0
    df["wM"] = 1.0
    return df


ST_ZM = None


def st_zm():
    return create_strategy(Z=asset_config("certificate", "bnh", asset_share=0.5, asset_spread=0),
                           M=asset_config("certificate", "bnh", asset_share=0.5, asset_spread=0))


def gp(end="2021-03-31", pz=70, out=False, **kw):
    f = sim_out if out else sim
    return f(gp_df(end, pz), st_zm(), start_value=2e4, tax_mode="person", event_col="ev", event_mode="replace",
             event_weight={"Z": "wZ", "M": "wM"}, **kw)


def col(ty, name):
    return ty[name].to_numpy()


# ── A a) § 23 mit Tarif ─────────────────────────────────────────────────────
def test_a_p23_tarif_soli_kist():
    r = p23(taxable_income=74000, church_tax=9)
    ty = r.tax_report["tariff_years"]
    assert ty["church_tax_paid_deductible"].iloc[1] == E(94.5)
    assert ty["deduction_effect"].iloc[1] == E(-43.6)
    assert col(ty, "settlement") == E([1221.13, -43.6])
    assert r.tax_report["total_taxes_paid"] == E(1221.13 - 43.6)
    assert r.worth[-1] == E(12500 - 1221.13 + 43.6)
    assert list(ty["year"]) == [2020, 2021]
    row = ty.iloc[0]
    assert [row[c] for c in ("gain_p23", "income_tax_p23", "soli_p23", "church_tax_p23", "tax_p23")] == \
        E([2500, 1050, 76.63, 94.5, 1221.13])
    assert p23(taxable_income=50000).tax_report["total_taxes_paid"] == E(T(52500) - T(50000))
    assert T(52500) - T(50000) == 889


def test_a_soli_freigrenze():
    r0 = p23(taxable_income=72466)
    assert r0.tax_report["total_taxes_paid"] == E(1050)
    assert r0.tax_report["tariff_years"]["soli_p23"].iloc[0] == 0
    assert p23(taxable_income=72469).tax_report["total_taxes_paid"] == E(1050.11)


def test_a_freigrenze_p23():
    r = p23(p2=119.98, taxable_income=50000)
    assert r.tax_report["total_taxes_paid"] == 0 and r.tax_report["tariff_years"]["gain_p23"].iloc[0] == 0
    r2 = p23(p2=120, taxable_income=50000)
    assert r2.tax_report["total_taxes_paid"] == E(T(51000) - T(50000))
    assert r2.tax_report["tariff_years"]["gain_p23"].iloc[0] == E(1000)


def test_a_verlustjahr_p23():
    d = days("2020-01-01", "2021-06-30")
    df = pd.DataFrame({"date": d, "G": np.where(d < D("2020-03-01"), 100.0, np.where(d < D("2021-03-01"), 70.0, 140.0)),
                       "H": 50.0})
    ev = pd.to_datetime(["2020-03-02", "2020-06-01", "2021-04-01"])
    df["ev"] = d.isin(ev)
    df["wG"] = np.where(d == ev[1], 0.5, 0.0)
    df["wH"] = 1 - df.wG
    st = create_strategy(G=asset_config("etc", "bnh", asset_share=0.5, asset_spread=0, deliverable=True),
                         H=asset_config("certificate", "bnh", asset_share=0.5, asset_spread=0))
    r = sim(df, st, start_value=1e4, tax_mode="person", taxable_income=50000, event_col="ev", event_mode="replace",
            event_weight={"G": "wG", "H": "wH"})
    ty = r.tax_report["tariff_years"]
    assert col(ty, "tax_p23") == E([0, T(52750) - T(50000)])
    assert col(ty, "gain_p23") == E([0, 2750])
    assert r.worth[-1] == E(8500 + 4250 - (T(52750) - T(50000)), 1e-9)


def test_a_pruefungen():
    d1 = p23(taxable_income=74000).tax_report["total_taxes_paid"]
    assert p23(taxable_income={"2020": 74000, "2021": 1}).tax_report["total_taxes_paid"] == E(d1)
    assert p23(taxable_income=pd.Series({"2020": 74000.0, "2021": 1.0})).tax_report["total_taxes_paid"] == E(d1)
    assert p23(taxable_income=pd.DataFrame({"year": [2020, 2021], "taxable_income": 74000.0})
               ).tax_report["total_taxes_paid"] == E(d1)
    with pytest.raises(ValueError, match="taxable_income fehlt für Simulationsjahr 2021"):
        p23(taxable_income={"2020": 74000})
    with pytest.raises(ValueError, match="muss nach Kalenderjahren benannt sein"):
        p23(taxable_income=[1, 2])
    with pytest.raises(ValueError, match="Name 'x' ist kein Kalenderjahr"):
        p23(taxable_income={"2020": 1, "x": 2})
    with pytest.raises(ValueError, match="ungültigen Wert"):
        p23(taxable_income=math.nan)
    with pytest.raises(ValueError, match="taxable_income muss eine Zahl"):
        p23(taxable_income="50000")
    small = pd.DataFrame({"date": days("2020-01-01", "2020-03-01"), "A": 100.0})
    st = create_strategy(A=asset_config("etf", "bnh", asset_share=1))
    _, w = sim_warn(small, st, tax_mode="person", taxable_income=50000, marginal_tax_rate=42,
                    include_soli_on_income_tax=True)
    assert any("marginal_tax_rate, include_soli_on_income_tax wirkt dann nicht" in x for x in w)
    assert p23(taxable_income=74000, marginal_tax_rate=20).tax_report["total_taxes_paid"] == E(d1)
    assert any('taxable_income wirkt nur bei tax_mode = "person"' in x
               for x in sim_warn(small, st, taxable_income=50000)[1])
    assert any("tax_tariff wirkt nur zusammen mit taxable_income" in x
               for x in sim_warn(small, st, tax_mode="person", tax_tariff=read_tax_tariff())[1])


# ── A b) Günstigerprüfung ───────────────────────────────────────────────────
def test_b_guenstigerpruefung_erstattung():
    r = gp(taxable_income=10000, use_guenstigerpruefung=True)
    ty = r.tax_report["tariff_years"]
    assert ty["capital_income"].iloc[0] == E(3000)
    assert ty["abgeltung_burden"].iloc[0] == E(791.25)
    assert ty["tariff_burden"].iloc[0] == E(95)
    assert bool(ty["guenstiger"].iloc[0]) and ty["refund"].iloc[0] == E(696.25)
    assert r.tax_report["total_taxes_paid"] == E(95)
    i = [int(np.flatnonzero(r.dates == np.datetime64(s))[0]) for s in ("2020-12-31", "2021-01-01")]
    assert r.worth[i[1]] - r.worth[i[0]] == E(696.25)
    assert r.worth[-1] == E(24000 - 95)
    row = ty.iloc[1]
    assert [row["capital_income"], row["abgeltung_burden"], row["refund"]] == E([0, 0, 0])
    r0 = gp(taxable_income=10000)
    assert r0.tax_report["total_taxes_paid"] == E(791.25)
    assert np.isnan(r0.tax_report["tariff_years"]["tariff_burden"].iloc[0])
    rh = gp(taxable_income=100000, use_guenstigerpruefung=True)
    assert not bool(rh.tax_report["tariff_years"]["guenstiger"].iloc[0])
    assert rh.tax_report["tariff_years"]["tariff_burden"].iloc[0] == E(1409.94)
    assert rh.tax_report["total_taxes_paid"] == E(791.25)


def test_b_gp_finaler_abschluss_und_kist():
    r = gp(end="2020-12-30", taxable_income=10000, use_guenstigerpruefung=True)
    assert r.worth[-1] == E(24000 - 95)
    rk = gp(taxable_income=10000, use_guenstigerpruefung=True, church_tax=9)
    abg = 3000 * 0.25 / (1 + 0.25 * 0.09) * (1 + 0.055 + 0.09)
    kabg = 3000 * 0.25 / (1 + 0.25 * 0.09) * 0.09
    ty = rk.tax_report["tariff_years"]
    assert ty["abgeltung_burden"].iloc[0] == E(abg) and ty["church_tax_withheld_k"].iloc[0] == E(kabg)
    assert ty["church_tax_paid_deductible"].iloc[0] == E(kabg)
    assert ty["taxable_income_net"].iloc[0] == E(10000 - kabg)
    assert ty["burden_with_gp"].iloc[0] == E(92.65) and ty["tariff_burden"].iloc[0] == E(92.65)
    assert ty["refund"].iloc[0] == E(abg - 92.65)
    assert ty["church_tax_settlement_next_year"].iloc[0] == E(7.65 - kabg)
    assert ty["church_tax_refunded"].iloc[1] == E(kabg - 7.65)
    assert ty["church_tax_net_deduction"].iloc[1] == E(7.65 - kabg)
    assert ty["taxable_income_net"].iloc[1] == E(10000 + kabg - 7.65)
    rl = gp(pz=30, taxable_income=10000, use_guenstigerpruefung=True)
    assert rl.tax_report["tariff_years"]["capital_income"].iloc[0] == 0
    assert rl.tax_report["tariff_years"]["refund"].iloc[0] == 0


def test_b_vp_nach_letztem_abschluss():
    d = days("2020-01-01", "2020-12-31")
    df = pd.DataFrame({"date": d, "A": 100 + 20 * np.arange(len(d)) / (len(d) - 1)})
    st = create_strategy(A=asset_config("etf", "bnh", asset_share=1, asset_spread=0, asset_bonus=30))
    r = sim(df, st, start_value=1e6, tax_mode="person", base_rate=2.29, taxable_income=10000,
            use_guenstigerpruefung=True)
    r0 = sim(df, st, start_value=1e6, tax_mode="person", base_rate=2.29)
    ty = r.tax_report["tariff_years"]
    assert list(ty["year"]) == [2020, 2021]
    abg = r0.tax_report["total_taxes_paid"]
    k = abg / 0.26375
    assert k == E(16030 * 0.7 - 1000, 1e-9)
    assert ty["capital_income"].iloc[1] == E(k, 1e-9)
    assert ty["abgeltung_burden"].iloc[1] == E(abg, 1e-9)
    assert ty["tariff_burden"].iloc[1] == E(T(10000 + k) - T(10000))
    assert ty["refund"].iloc[1] == E(abg - (T(10000 + k) - T(10000)), 1e-9)
    assert r.worth[-1] - r0.worth[-1] == E(ty["refund"].iloc[1], 1e-6)
    assert r.tax_report["total_taxes_paid"] == E(abg - ty["refund"].iloc[1], 1e-9)


# ── A c) KiSt als Sonderausgabe ─────────────────────────────────────────────
def test_c_kist_sonderausgabe_p23():
    d = days("2020-01-01", "2021-12-31")
    df = pd.DataFrame({"date": d, "G": np.where(d < D("2020-06-01"), 100.0, np.where(d < D("2021-06-01"), 150.0, 200.0)),
                       "H": 50.0})
    df["ev"] = d.isin(pd.to_datetime(["2020-07-01", "2020-08-01", "2021-07-01"]))
    df["wG"] = np.where(d == D("2020-08-01"), 0.5, 0.0)
    df["wH"] = 1 - df.wG
    st = create_strategy(G=asset_config("etc", "bnh", asset_share=0.5, asset_spread=0, deliverable=True),
                         H=asset_config("certificate", "bnh", asset_share=0.5, asset_spread=0))
    r = sim(df, st, start_value=1e4, tax_mode="person", taxable_income={"2020": 50000, "2021": 60000}, church_tax=9,
            event_col="ev", event_mode="replace", event_weight={"G": "wG", "H": "wH"})
    ty = r.tax_report["tariff_years"]
    t1, k1 = 889 * 1.09, 889 * 0.09
    assert ty["tax_p23"].iloc[0] == E(t1)
    assert col(ty, "church_tax_net_deduction") == E([0, k1])
    assert ty["church_tax_settlement_next_year"].iloc[0] == E(k1)
    g2, base = (6250 - t1) / 3, 60000 - k1
    assert ty["gain_p23"].iloc[1] == E(g2, 1e-9)
    assert ty["tax_p23"].iloc[1] == E((T(base + g2) - T(base)) * 1.09)
    assert ty["deduction_effect"].iloc[1] == E((T(base) - T(60000)) * 1.09)
    assert ty["settlement"].iloc[1] == E((T(base + g2) - T(60000)) * 1.09)
    assert r.tax_report["total_taxes_paid"] == E(t1 + (T(base + g2) - T(60000)) * 1.09)
    rg = gp(taxable_income=10000, church_tax=9)
    assert col(rg.tax_report["tariff_years"], "church_tax_net_deduction") == E([0, 0])
    assert col(rg.tax_report["tariff_years"], "settlement") == E([0, 0])


def test_c_kist_gp_drei_jahre():
    d = days("2020-01-01", "2022-12-31")
    df = pd.DataFrame({"date": d, "Z": np.where(d < D("2020-06-01"), 50.0, np.where(d < D("2021-06-01"), 70.0, 90.0)),
                       "M": 100.0})
    ev = pd.to_datetime(["2020-07-01", "2020-08-01", "2021-07-01"])
    df["ev"] = d.isin(ev)
    df["wZ"] = np.where(d == ev[1], 1.0, 0.0)
    df["wM"] = 1 - df.wZ
    r = sim(df, st_zm(), start_value=2e4, tax_mode="person", taxable_income=14000, use_guenstigerpruefung=True,
            church_tax=9, event_col="ev", event_mode="replace", event_weight={"Z": "wZ", "M": "wM"})
    ty = r.tax_report["tariff_years"]
    q = 0.25 / 1.0225
    rate = q * (1 + 0.055 + 0.09)

    def F(x):
        return T(x) * 1.09
    assert list(ty["year"]) == [2020, 2021, 2022]
    kabg1 = 3000 * q * 0.09
    assert (T(13933), T(16933), T(14000)) == (244, 834, 256)
    assert bool(ty["guenstiger"].iloc[0]) and ty["church_tax_paid_deductible"].iloc[0] == E(kabg1)
    assert ty["burden_with_gp"].iloc[0] == E(630.02) and ty["burden_without_gp"].iloc[0] == E(3000 * rate)
    assert ty["settlement"].iloc[0] == E(630.02 - 3000 * rate)
    ks1 = 0.09 * 578 - kabg1
    assert ty["church_tax_settlement_next_year"].iloc[0] == E(ks1)
    k2 = ty["capital_income"].iloc[1]
    kabg2 = k2 * q * 0.09
    assert k2 > 0
    assert ty["church_tax_refunded"].iloc[1] == E(-ks1) and ty["church_tax_paid_deductible"].iloc[1] == E(kabg2)
    assert ty["church_tax_net_deduction"].iloc[1] == E(kabg2 + ks1)
    b2 = 14000 - ks1 - kabg2
    assert ty["burden_with_gp"].iloc[1] == E(F(b2 + k2) - F(14000))
    assert ty["burden_without_gp"].iloc[1] == E(F(14000 - ks1) - F(14000) + k2 * rate)
    assert ty["settlement"].iloc[1] == E(F(b2 + k2) - F(14000) - k2 * rate)
    ks2 = 0.09 * (T(b2 + k2) - T(14000)) - kabg2
    assert ks2 < 0 and ty["church_tax_settlement_next_year"].iloc[1] == E(ks2)
    assert ty["church_tax_paid_deductible"].iloc[2] == 0 and ty["church_tax_refunded"].iloc[2] == E(-ks2)
    assert ty["taxable_income_net"].iloc[2] == E(14000 - ks2)
    assert ty["settlement"].iloc[2] == E(F(14000 - ks2) - F(14000)) and ty["settlement"].iloc[2] > 0
    assert r.tax_report["total_taxes_paid"] == E(3000 * rate + k2 * rate + ty["settlement"].sum(), 1e-9)


def test_e_details_tarifrechnung():
    _, out = gp(out=True, taxable_income=10000, use_guenstigerpruefung=True)
    import re
    assert any("Tarif 2020: zvE 10000.00 EUR - KiSt-Sonderausgaben 0.00 EUR (gezahlt 0.00, erstattet 0.00) = "
               "10000.00 EUR" in ln for ln in out)
    assert any(re.search(r"K 3000.00 EUR, Abgeltungsteuer 791.25 EUR .*Tarif auf K 95.00 EUR .*-> Tarif", ln)
               for ln in out)
    assert any("Abrechnung: Erstattung 696.25 EUR" in ln for ln in out)
    assert any("Erstattung 696.25 EUR in den Geldbestand am 2021-01-01" in ln for ln in out)


# ── B undefined_metrics ─────────────────────────────────────────────────────
# Negativer Endwert mit offener Steuerschuld (R: "B negative_end_value"), nonpositive_twr_index
# mit no_recovery und no_irr_solution prüfen die Referenzfälle golden/modules/engine/um01–um04
# (gleiche Daten, Strategie und Argumente; Ergebnis, Warnungen, print und summary bitgleich).
def um(r, m, field="reason"):
    u = r.undefined_metrics
    v = u.loc[u.metric == m, field]
    return v.iloc[0] if len(v) else None


def test_b_too_short():
    df = pd.DataFrame({"date": [pd.Timestamp("2020-01-01")], "A": [100.0]})
    st = create_strategy(A=asset_config("etf", "bnh", asset_share=1))
    with pytest.warns(UserWarning, match=r"Zeitraum 1 Tag \(Laufzeit 0 Jahre\): cagr und ttwror sind nicht definiert"):
        r = simulation(df, st)
    assert um(r, "cagr") == "too_short" and um(r, "ttwror") == "too_short"
    assert um(r, "skewness", "detail") == "keine Tagesrendite (Einzeltag)"
    assert np.isnan(r.buys["A"]) and np.isnan(r.sells["A"])
    assert um(r, "buys") == "too_short" and um(r, "sells") == "too_short"
    assert um(r, "avg_recovery_time") == "too_short"
    assert list(r.undefined_metrics.metric)[-2:] == ["buys", "sells"]
    assert any("CAGR:             nicht definiert (Zeitraum 1 Tag, Laufzeit 0 Jahre (Einzeltag))" in ln
               for ln in str(r).splitlines())
    r2 = simulation(pd.DataFrame({"date": days("2020-01-01", "2020-01-02"), "A": [100.0, 101.0]}), st)
    assert um(r2, "skewness", "detail") == "nur 1 Tagesrendite, mindestens 3 nötig"
    assert um(r2, "kurtosis") == "too_short" and um(r2, "sharpe") == "too_short"
    assert not set(r2.undefined_metrics.metric) & {"cagr", "buys", "sells"}


def test_b_zero_volatility():
    r = simulation(pd.DataFrame({"date": days("2020-01-01", "2020-06-30"), "A": 100.0}),
                   create_strategy(A=asset_config("etf", "bnh", asset_share=1, asset_spread=0)))
    for m in ("skewness", "kurtosis", "sharpe"):
        assert um(r, m) == "zero_volatility"
    assert um(r, "cv") == "zero_mean_return"
    assert any("Schiefe:          nicht definiert (Standardabweichung der 181 Tagesrenditen ist 0" in ln
               for ln in str(r).splitlines())


def test_b_steigender_kurs():
    d = days("2020-01-01", "2020-12-31")
    r = simulation(pd.DataFrame({"date": d, "A": 100 * 1.001 ** np.arange(len(d))}),
                   create_strategy(A=asset_config("etf", "bnh", asset_share=1, asset_spread=0)))
    for m in ("sortino", "omega", "gain_to_pain"):
        assert um(r, m) == "no_negative_returns"
    for m in ("calmar", "serenity", "martin_ratio"):
        assert um(r, m) == "no_drawdown"
    assert um(r, "avg_recovery_time", "detail") == "kein Drawdown im Zeitraum"
    assert not set(r.undefined_metrics.metric) & {"cagr", "ttwror", "sharpe"}


def test_b_alles_definiert():
    d = days("2020-01-01", "2020-12-31")
    i = np.arange(1, len(d) + 1)
    p = 100 + 10 * np.array([math.sin(v / 20) for v in i]) + i / 10
    r = simulation(pd.DataFrame({"date": d, "A": p}),
                   create_strategy(A=asset_config("etf", "bnh", asset_share=1, asset_spread=0)))
    assert r.undefined_metrics.shape == (0, 3)
    assert list(r.undefined_metrics.columns) == ["metric", "reason", "detail"]
    assert r.tax_report["open_tax_debt"] == 0
    assert "nicht definiert" not in str(r)


# ── C summary ───────────────────────────────────────────────────────────────
def test_c_summary_renditen():
    from test_tax_law import _dca
    r = _dca()
    s = simlev.summary(r)
    out = str(s).splitlines()
    assert s.total_return_twr == pytest.approx(0.5, rel=1e-12)
    assert s.total_return == s.total_return_twr and s.invested == 2000
    end = r.worth[-1]
    assert s.return_on_invested == E((end - 2000) / 2000)
    assert any("Gesamtrendite (zeitgewichtet): +50.00 %" in ln for ln in out)
    want = simlev._r.rformat.r_sprintf("Gewinn je eingezahltem EUR:    %+.2f %% (Endwert %.2f EUR / Eingezahlt 2000.00 EUR - 1)",
                                  100 * (end - 2000) / 2000, end)
    assert any(want in ln for ln in out)
    dd = days("2020-01-01", "2021-12-31")
    p = np.where(dd < D("2020-06-01"), 100.0, np.where(dd < D("2021-07-01"), 80.0, 100.0))
    p[-1] = 150
    r0 = sim(pd.DataFrame({"date": dd, "A": p}), create_strategy(A=asset_config("etf", "bnh", asset_share=1,
                                                                                 asset_spread=0)))
    s0 = simlev.summary(r0)
    out0 = str(s0)
    assert "Gesamtrendite:    +50.00%" in out0 and "Gewinn je eingezahltem" not in out0
    assert s0.return_on_invested == pytest.approx(s0.total_return_twr, rel=1e-12)


# ── D funds_fee/bonus_fee ───────────────────────────────────────────────────
def test_d_funds_fee_ohne_fondsmodus():
    df = pd.DataFrame({"date": days("2020-01-01", "2020-03-01"), "A": 100.0})
    st = create_strategy(A=asset_config("etf", "bnh", asset_share=1))
    assert any('funds_fee wirkt nur bei tax_mode = "funds" (hier tax_mode = "none")' in x
               for x in sim_warn(df, st, funds_fee=0.5)[1])
    assert any("funds_fee und bonus_fee wirkt nur" in x
               for x in sim_warn(df, st, tax_mode="person", funds_fee=1, bonus_fee=0)[1])
    assert sim_warn(df, st, tax_mode="funds", funds_fee=0.5)[1] == []
    assert sim_warn(df, st, tax_mode="person")[1] == []


# ── E open_lots ─────────────────────────────────────────────────────────────
def test_e_open_lots_liquidation():
    d = days("2020-01-01", "2021-11-30")
    n = len(d)
    k = np.arange(n)
    df = pd.DataFrame({"date": d, "A": 100 * 1.0005 ** k, "G": 50 * 1.002 ** k})
    st = create_strategy(A=asset_config("etf", "bnh", asset_share=0.6, asset_spread=0.2, asset_bonus=30),
                         G=asset_config("etc", "bnh", asset_share=0.4, asset_spread=0.2, deliverable=True))
    args = dict(start_value=1e4, tax_mode="person", base_rate=2, marginal_tax_rate=30, dca_mode=True, dca_value=5000,
                dca_span=3, use_sparer_pauschbetrag=False)
    r = sim(df, st, **args)
    rl = sim(df, st, liquidate=True, **args)
    ol = r.open_lots
    assert list(ol) == ["A", "G"]
    assert ol["A"]["regime"] == "investment_fund" and ol["A"]["asset_bonus"] == 30
    assert ol["A"]["asset_spread"] == E(0.2) and ol["G"]["asset_spread"] == E(0.2)
    assert "order_fee" in ol["A"] and ol["A"]["order_fee"] is None
    fee = {"fixed": 4.9, "percent": 0.25, "max": 59}
    rf = sim(df.iloc[:60], st, start_value=1e4, tax_mode="person", order_fee=fee)
    assert rf.open_lots["G"]["order_fee"] == fee
    la, lg = ol["A"]["lots"], ol["G"]["lots"]
    assert la["vp"].sum() > 0
    assert la["units"].sum() == pytest.approx(r.report["A"]["worth"][-1] / df.A.iloc[-1], rel=1e-12)
    P = df.A.iloc[-1] * (1 - 0.002 / 2)
    gain_A = (la["units"] * (P - la["price"])).sum()
    tax_A = (gain_A - la["vp"].sum()) * (1 - 0.3) * 0.26375
    PG = df.G.iloc[-1] * (1 - 0.002 / 2)
    lot_g = (lg["units"] * (PG - lg["price"])).to_numpy()
    ld = pd.to_datetime(lg["date"])
    plus1 = pd.to_datetime([f"{t.year + 1}-{t.month:02d}-{t.day:02d}" for t in ld])
    short = (d[-1] <= plus1)
    assert lot_g[short].sum() > 1000 and lot_g[~short].sum() > 0
    t23 = lot_g[short].sum() * 0.30 if lot_g[short].sum() >= 1000 else 0
    assert r.worth[-1] - rl.worth[-1] == E(la["units"].sum() * df.A.iloc[-1] * 0.001 +
                                           lg["units"].sum() * df.G.iloc[-1] * 0.001 + tax_A + t23, 1e-6)
    assert rl.tax_report["total_taxes_paid"] - r.tax_report["total_taxes_paid"] == E(tax_A + t23, 1e-6)
    assert simulation(df.iloc[:30, :2], create_strategy(A=asset_config("etf", "bnh", asset_share=1))).open_lots is None


def test_r5_05_kein_fliesskommarest():
    d = days("2019-01-01", "2021-02-28")
    df = pd.DataFrame({"date": d, "Z": np.where(d < D("2020-02-15"), 50.0, 70.0),
                       "M": np.where(d < D("2020-08-15"), 100.0, 90.0)})
    ev = pd.to_datetime(["2020-03-01", "2020-09-01"])
    df["ev"] = d.isin(ev)
    df["wZ"] = np.where(d == ev[1], 1.0, 0.0)
    df["wM"] = 1 - df.wZ
    r = sim(df, st_zm(), start_value=2e4, tax_mode="person", event_col="ev", event_mode="replace",
            event_weight={"Z": "wZ", "M": "wM"}, taxable_income=10000, use_guenstigerpruefung=True)
    assert r.tax_report["total_taxes_paid"] == 0
    assert r.tax_report["tariff_years"]["refund"].iloc[1] > 0
    assert "Gezahlte Steuern" not in str(r)


def test_next_year():
    def mk(end):
        d = days("2020-01-01", end)
        df = pd.DataFrame({"date": d, "A": np.where(d < D("2020-12-01"), 100.0, 120.0),
                           "Z": np.where(d < D("2020-06-01"), 50.0, 30.0), "M": 100.0})
        df["ev"] = d == D("2020-07-01")
        df["wA"] = 5000.0
        df["wZ"] = 0.0
        df["wM"] = 4000.0
        return df
    st = create_strategy(A=asset_config("etf", "bnh", asset_share=0.5, asset_spread=0, asset_bonus=30),
                         Z=asset_config("certificate", "bnh", asset_share=0.25, asset_spread=0),
                         M=asset_config("certificate", "bnh", asset_share=0.25, asset_spread=0))

    def run(end, **kw):
        return sim(mk(end), st, start_value=1e4, tax_mode="person", base_rate=2.29, event_col="ev",
                   event_mode="replace", event_weight={"A": "wA", "Z": "wZ", "M": "wM"}, **kw)
    ny = run("2020-12-31").tax_report["next_year"]
    assert ny["year"] == 2021
    assert ny["loss_capital_start"] == E(1000) and ny["loss_capital_used"] == E(56.105)
    assert ny["loss_carryforward_capital"] == E(1000 - 56.105)
    assert ny["sparer_pauschbetrag_used"] == 0 and ny["sparer_pauschbetrag_remaining"] == E(1000)
    assert ny["capital_income_taxed"] == 0
    ny2 = run("2020-09-30").tax_report["next_year"]
    assert ny2["year"] == 2021
    assert [ny2[k] for k in ("sparer_pauschbetrag_used", "loss_capital_used", "capital_income_taxed",
                             "private_sale_net")] == [0, 0, 0, 0]
    assert ny2["loss_carryforward_capital"] == E(1000) and ny2["sparer_pauschbetrag_remaining"] == E(1000)
    d = days("2020-01-01", "2020-12-31")
    sa = create_strategy(A=asset_config("etf", "bnh", asset_share=1, asset_spread=0, asset_bonus=30))
    da = pd.DataFrame({"date": d, "A": np.where(d < D("2020-12-01"), 100.0, 120.0)})
    ny3 = sim(da, sa, tax_mode="person", base_rate=2.29).tax_report["next_year"]
    assert ny3["sparer_pauschbetrag_used"] == E(112.21)
    assert ny3["sparer_pauschbetrag_remaining"] == E(1000 - 112.21)
    r4 = sim(da, sa, tax_mode="person", base_rate=2.29, use_sparer_pauschbetrag=False)
    ny4 = r4.tax_report["next_year"]
    assert ny4["sparer_pauschbetrag_used"] == 0 and ny4["sparer_pauschbetrag_remaining"] == 0
    assert ny4["capital_income_taxed"] == E(112.21)
    assert r4.tax_report["total_taxes_paid"] > 112.21 * 0.26375
    ny5 = sim(da, sa, tax_mode="person", base_rate=2.29, taxable_income=10000).tax_report["next_year"]
    assert ny5["church_tax_settlement"] == 0 and ny5["tariff_assessed"] is False
    assert "next_year" not in sim(da, sa).tax_report or sim(da, sa).tax_report.get("next_year") is None
