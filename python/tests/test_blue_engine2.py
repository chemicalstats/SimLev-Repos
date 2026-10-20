"""Port von r/tests/testthat/test-blue-engine2.R (Befunde R2-01 ... R2-07)."""
import contextlib
import io
import math
import re

import numpy as np
import pandas as pd
import pytest

from simlev import asset_config, create_strategy, simulation
from simlev.data_prep import align_series

from _helpers import days, sim, sim_out, sim_warn

approx = pytest.approx


def mk_day(n, f):
    return pd.DataFrame({"date": pd.date_range("2020-01-01", periods=n), "A": f(n)})


def gbm(seed, mu, sd, s0=100):
    rng = np.random.default_rng(seed)
    return lambda n: s0 * np.cumprod(1 + rng.normal(mu, sd, n))


def st1():
    return create_strategy(A=asset_config("etf", asset_share=1, asset_spread=0))


def test_r2_01_startkapital_order_fee():
    d = mk_day(400, gbm(1, 4e-4, 0.01))
    fee = {"percent": 0.25}
    exp_fee = 0.0025 * 50000 / 1.0025
    kw = dict(start_value=50000, order_fee=fee, dca_fee=0, dca_mode=True, dca_value=100, dca_span=1)
    a = simulation(d, st1(), **kw)
    b = simulation(d, st1(), dca_days=2, **kw)
    assert a.fees_paid == approx(exp_fee, rel=1e-9) and b.fees_paid == approx(exp_fee, rel=1e-9)
    d["B"] = 50 * np.cumprod(1 + np.random.default_rng(2).normal(1e-4, 0.005, len(d)))
    st2 = create_strategy(A=asset_config("etf", asset_share=.6, asset_spread=0),
                          B=asset_config("etf", asset_share=.4, asset_spread=0))
    c2 = simulation(d, st2, balance_mode=True, balance_span=12, **kw)
    assert c2.fees_paid >= exp_fee - 1e-6
    e = simulation(d, st1(), start_value=50000, order_fee=fee, dca_fee=1, dca_mode=True, dca_value=100, dca_span=1)
    assert e.fees_paid == approx(exp_fee + (e.report["A"]["flows"] > 0).sum(), rel=1e-9)


def test_r2_02_split_thresh():
    rng = np.random.default_rng(5)
    d = mk_day(400, lambda n: 40 * np.exp(np.cumsum(rng.normal(8e-4, 0.01, n))))
    assert any("schließt den Zielkurs 100 nicht ein" in w
               for w in sim_warn(d, st1(), split_mode=True, split_thresh=(10, 60))[1])
    assert any("untere < 100 < obere" in w for w in sim_warn(d, st1(), split_mode=True, split_thresh=(150, 400))[1])
    assert sim_warn(d, st1(), split_mode=True, split_thresh=(50, 200))[1] == []
    assert sim_warn(d, st1(), split_mode=False, split_thresh=(10, 60))[1] == []
    with pytest.raises(ValueError, match="Länge 2"):
        sim(d, st1(), split_mode=True, split_thresh=(10, 60, 200))


def test_r2_03_filled_falsche_zeilenzahl():
    rng = np.random.default_rng(7)
    c = days("2019-01-01", "2020-12-31")
    wd = c[c.dayofweek < 5]
    us = pd.DataFrame({"date": wd, "A": 100 * np.exp(np.cumsum(rng.normal(4e-4, 0.011, len(wd))))})
    st = create_strategy(A=asset_config("etf", asset_share=1))
    with contextlib.redirect_stderr(io.StringIO()):
        al = align_series(A=us)
    al2 = al[al.date >= pd.Timestamp("2020-01-01")]
    r, w = sim_warn(al2, st)
    assert any(re.search("Attribut 'filled'.*ignoriert", x) for x in w)
    assert r.filled.sum() == 0
    r0, w0 = sim_warn(al, st)
    assert w0 == [] and r0.filled.sum() > 0


def test_r2_04_funds_fee_bonus_fee_bereich():
    d = mk_day(400, lambda n: np.full(n, 100.0))
    for v in (-1, math.nan, 150, None, "1"):
        with pytest.raises(ValueError, match="funds_fee muss eine Zahl in Prozent"):
            simulation(d, st1(), tax_mode="funds", funds_fee=v)
    for v in (-20, 150, math.nan):
        with pytest.raises(ValueError, match="bonus_fee muss eine Zahl in Prozent"):
            simulation(d, st1(), tax_mode="funds", bonus_fee=v)
    simulation(d, st1(), tax_mode="funds", funds_fee=0.95, bonus_fee=0)
    simulation(d, st1(), tax_mode="funds", funds_fee=100, bonus_fee=100)
    sim(d, st1(), tax_mode="none", funds_fee=math.nan)


def test_r2_06_fondskosten_vor_steuer_am_aufgefuellten_ende():
    c = days("2021-01-01", "2022-01-31")
    d = pd.DataFrame({"date": c, "A": 100 * 1.0015 ** np.arange(len(c))})
    wd = d[d.date.dt.dayofweek < 5]
    with contextlib.redirect_stderr(io.StringIO()):
        al = align_series(A=wd, end="2021-12-25")
    r, o = sim_out(al, st1(), tax_mode="funds", liquidate=True)
    assert any(re.search(r"^Fondskosten:\tFondsgebühren .* am 2021-12-24", ln) for ln in o)
    assert not any(re.search(r"Fondsgebühren .* am 2021-12-25", ln) for ln in o)
    E_, T_ = r.worth[-1], r.tax_report["total_taxes_paid"]
    assert T_ == approx(0.26375 * (E_ + T_ - 1e4), rel=1e-9)


def test_r2_07_marginal_tax_rate_warnung():
    d = pd.DataFrame({"date": pd.date_range("2020-01-01", periods=400), "A": 100.0, "G": 50.0})
    st = create_strategy(A=asset_config("etf", asset_share=.8), G=asset_config("etc", asset_share=.2, deliverable=True))
    assert sim_warn(d, st, tax_mode="none")[1] == []
    assert sim_warn(d, st, tax_mode="funds")[1] == []
    assert any("marginal_tax_rate" in w for w in sim_warn(d, st, tax_mode="person")[1])


def test_doppelte_dca_days_und_spaltennamen():
    d = mk_day(400, lambda n: 100 * 1.0005 ** np.arange(n))
    st = create_strategy(A=asset_config("etf", asset_share=1))
    r1 = sim(d, st, dca_mode=True, dca_value=100, dca_span=1, dca_days=15)
    r2, w = sim_warn(d, st, dca_mode=True, dca_value=100, dca_span=1, dca_days=[15, 15])
    assert any("doppelte Tage" in x for x in w) and np.array_equal(r1.worth, r2.worth)
    assert any("balance_days enthält doppelte" in x for x in sim_warn(d, st, balance_mode=True, balance_days=[1, 1])[1])
    d2 = pd.concat([d, d[["A"]]], axis=1)
    with pytest.raises(ValueError, match="Spaltenname 'A' kommt in 'data' mehrfach vor"):
        simulation(d2, st)
