"""Port von r/tests/testthat/test-tax.R und der Engine-Teile von test-cost-basis.R
(open_lots als exakte Basis; die Entnahmephase prüft das Modul withdrawal)."""
import math

import numpy as np
import pandas as pd
import pytest

from simlev import asset_config, create_strategy, simulation

from _helpers import days, sim


def test_steuerregime_ableitung():
    assert asset_config(asset_class="etf").tax_regime == "investment_fund"
    assert asset_config(asset_class="etn", deliverable=True).tax_regime == "private_sale"
    assert asset_config(asset_class="etn", deliverable=False).tax_regime == "capital_gains"
    assert asset_config(asset_class="etc", deliverable=True).tax_regime == "private_sale"
    assert asset_config(asset_class="certificate").tax_regime == "capital_gains"


@pytest.mark.parametrize("b", [30, 15, 0])
def test_teilfreistellung(b):
    assert asset_config(asset_class="etf", asset_bonus=b).asset_bonus == b


def test_tax_regime_override():
    assert asset_config(asset_class="etf", tax_regime="capital_gains").tax_regime == "capital_gains"
    assert asset_config(asset_class="etc", deliverable=True).tax_regime == "private_sale"


def _growth(frm, to):
    d = pd.DataFrame({"date": days(frm, to)})
    t = (d.date - d.date.iloc[0]).dt.days.to_numpy() / 365.25
    return d, t


def test_cost_basis_ein_lot_mit_vorabpauschalen():
    d, t = _growth("2015-01-01", "2019-12-31")
    d["A"] = [100 * math.pow(1.08, v) for v in t]
    st = create_strategy(A=asset_config("etf", "bnh", asset_spread=0, asset_bonus=30))
    r = simulation(d, st, start_value=1e5, tax_mode="person", base_rate=1)
    tage = (0, 365, 731, 1096, 1461)
    vp = sum(1000 * 0.7 * 0.01 * 100 * math.pow(1.08, k / 365.25) for k in tage)
    assert vp == pytest.approx(4106.7134, rel=1e-7)
    lots = r.open_lots["A"]["lots"]
    assert list(lots["units"]) == pytest.approx([1000])
    assert lots["vp"].sum() == pytest.approx(vp, rel=1e-10)
    sv = 1000 * 100 * math.pow(1.08, 1825 / 365.25)
    assert r.worth[-1] == pytest.approx(sv, rel=1e-12)
    spb1 = 1000 - 0.7 * 1000 * 0.7 * 0.01 * 100 * math.pow(1.08, 1461 / 365.25)
    assert r.tax_report["next_year"]["sparer_pauschbetrag_remaining"] == pytest.approx(spb1, rel=1e-10)
    assert spb1 == pytest.approx(333.36, abs=0.005)


def test_cost_basis_ganzer_bestand_gleich_engine_steuer():
    d, t = _growth("2015-01-01", "2020-12-31")
    d["A"] = [100 * math.pow(1.08, v) * (1 + 0.1 * math.sin(3 * v)) for v in t]
    d["B"] = [50 * math.pow(1.03, v) * (1 + 0.05 * math.cos(5 * v)) for v in t]
    st = create_strategy(A=asset_config("etf", "bnh", asset_share=0.6, asset_spread=0.2, asset_bonus=30),
                         B=asset_config("etf", "bnh", asset_share=0.4, asset_spread=0.2, asset_bonus=30))
    args = dict(start_value=1e5, tax_mode="person", base_rate=2, sparer_pauschbetrag=0, dca_mode=True, dca_value=500,
                dca_span=1, balance_mode=True, balance_span=6)
    r0 = sim(d, st, **args)
    r1 = sim(d, st, liquidate=True, **args)
    assert (r0.sells > 0).all()
    assert len(r0.open_lots["A"]["lots"]) > 50 and r0.open_lots["A"]["lots"]["vp"].sum() > 0
    tax_engine = r1.tax_report["total_taxes_paid"] - r0.tax_report["total_taxes_paid"]
    B = sum((a["lots"]["units"] * a["lots"]["price"]).sum() + a["lots"]["vp"].sum() + a["cash"]
            for a in r0.open_lots.values())
    assert tax_engine == pytest.approx((r0.worth[-1] * 0.999 - B) * 0.7 * 0.26375, rel=1e-9)


def test_ohne_steuern_keine_open_lots():
    d, t = _growth("2015-01-01", "2019-12-31")
    d["A"] = [100 * math.pow(1.08, v) for v in t]
    st = create_strategy(A=asset_config("etf", "bnh", asset_spread=0, asset_bonus=30))
    assert simulation(d, st, start_value=1e5, dca_mode=True, dca_value=100, dca_span=1).open_lots is None
    rp2 = simulation(d.iloc[:-1], st, start_value=1e5, tax_mode="person", base_rate=1)
    assert rp2.open_lots["A"]["regime"] == "investment_fund"


def test_regime_der_offenen_lots():
    d, t = _growth("2018-01-01", "2019-12-31")
    d["A"] = [100 * math.pow(1.05, v) for v in t]
    d["N"] = d.A
    d["C"] = d.A
    rm = sim(d, create_strategy(A=asset_config("etf", "bnh", asset_share=0.5, asset_spread=0, asset_bonus=30),
                                N=asset_config("etn", "bnh", asset_share=0.5, asset_spread=0)),
             start_value=1e4, tax_mode="person", base_rate=1)
    assert rm.open_lots["N"]["regime"] == "capital_gains" and rm.open_lots["A"]["asset_bonus"] == 30
    rc = sim(d, create_strategy(C=asset_config("etc", "bnh", asset_spread=0, deliverable=True)), start_value=1e4,
             tax_mode="person", base_rate=1, marginal_tax_rate=42)
    assert rc.open_lots["C"]["regime"] == "private_sale"
