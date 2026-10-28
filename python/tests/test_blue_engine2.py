"""Port von r/tests/testthat/test-blue-engine2.R (Befunde R2-01 ... R2-07)."""
import contextlib
import io
import math
import re

import numpy as np
import pandas as pd
import pytest

from simlev import asset_config, create_strategy, simulation
from simlev.data_prep import series_align

from _helpers import days, sim, sim_warn
from simlev import dca_plan, funds_costs, rebalance_plan, sim_costs, split_rule, tax_profile  # Bausteine (Etappe 6.3)

approx = pytest.approx


def mk_day(n, f):
    return pd.DataFrame({"date": pd.date_range("2020-01-01", periods=n), "A": f(n)})


def gbm(seed, mu, sd, s0=100):
    rng = np.random.default_rng(seed)
    return lambda n: s0 * np.cumprod(1 + rng.normal(mu, sd, n))


def st1():
    return create_strategy(A=asset_config(asset_class="etf", share=1, spread=0))


def test_r2_01_startkapital_order_fee():
    d = mk_day(400, gbm(1, 4e-4, 0.01))
    fee = {"percent": 0.25}
    exp_fee = 0.0025 * 50000 / 1.0025
    kw = dict(start_value=50000, costs=sim_costs(order_fee=fee, dca_fee=0))
    a = simulation(d, st1(), dca=dca_plan(value=100, span=1), **kw)
    b = simulation(d, st1(), dca=dca_plan(value=100, span=1, days=2), **kw)
    assert a.fees_paid == approx(exp_fee, rel=1e-9) and b.fees_paid == approx(exp_fee, rel=1e-9)
    d["B"] = 50 * np.cumprod(1 + np.random.default_rng(2).normal(1e-4, 0.005, len(d)))
    st2 = create_strategy(A=asset_config(asset_class="etf", share=.6, spread=0),
                          B=asset_config(asset_class="etf", share=.4, spread=0))
    c2 = simulation(d, st2, dca=dca_plan(value=100, span=1), rebalance=rebalance_plan(span=12), **kw)
    assert c2.fees_paid >= exp_fee - 1e-6
    e = simulation(d, st1(), start_value=50000, costs=sim_costs(order_fee=fee, dca_fee=1), dca=dca_plan(value=100, span=1))
    assert e.fees_paid == approx(exp_fee + (e.report["A"]["flows"] > 0).sum(), rel=1e-9)


def test_r2_02_split_thresh():
    rng = np.random.default_rng(5)
    d = mk_day(400, lambda n: 40 * np.exp(np.cumsum(rng.normal(8e-4, 0.01, n))))
    with pytest.warns(UserWarning, match="schließt den Zielkurs 100 nicht ein"):
        sim(d, st1(), splits=split_rule(thresh=(10, 60)))
    with pytest.warns(UserWarning, match="untere < 100 < obere"):
        split_rule(thresh=(150, 400))
    assert sim_warn(d, st1(), splits=split_rule(thresh=(50, 200)))[1] == []
    assert sim_warn(d, st1())[1] == []
    with pytest.raises(ValueError, match="split_rule: thresh muss .* Länge 2"):
        split_rule(thresh=(10, 60, 200))


def test_r2_03_filled_falsche_zeilenzahl():
    rng = np.random.default_rng(7)
    c = days("2019-01-01", "2020-12-31")
    wd = c[c.dayofweek < 5]
    us = pd.DataFrame({"date": wd, "A": 100 * np.exp(np.cumsum(rng.normal(4e-4, 0.011, len(wd))))})
    st = create_strategy(A=asset_config(asset_class="etf", share=1))
    with contextlib.redirect_stderr(io.StringIO()):
        al = series_align(A=us)
    al2 = al[al.date >= pd.Timestamp("2020-01-01")]
    r, w = sim_warn(al2, st)
    assert any(re.search("Attribut 'filled'.*ignoriert", x) for x in w)
    assert r.filled.sum() == 0
    r0, w0 = sim_warn(al, st)
    assert w0 == [] and r0.filled.sum() > 0


def test_r2_04_funds_costs_bereich():
    for v in (-1, math.nan, 150, None, "1"):
        with pytest.raises(ValueError, match="funds_costs: fee muss eine Zahl in Prozent"):
            funds_costs(fee=v)
    for v in (-20, 150, math.nan):
        with pytest.raises(ValueError, match="funds_costs: performance_fee muss eine Zahl in Prozent"):
            funds_costs(performance_fee=v)
    funds_costs(fee=0.95, performance_fee=0)
    funds_costs(fee=100, performance_fee=100)


def test_r2_07_marginal_tax_rate_warnung():
    d = pd.DataFrame({"date": pd.date_range("2020-01-01", periods=400), "A": 100.0, "G": 50.0})
    st = create_strategy(A=asset_config(asset_class="etf", share=.8), G=asset_config(asset_class="etc", share=.2, deliverable=True))
    assert sim_warn(d, st)[1] == []
    assert any("income_rate(marginal_rate)" in w for w in sim_warn(d, st, tax=tax_profile())[1])


def test_doppelte_dca_days_und_spaltennamen():
    d = mk_day(400, lambda n: 100 * 1.0005 ** np.arange(n))
    st = create_strategy(A=asset_config(asset_class="etf", share=1))
    r1 = sim(d, st, dca=dca_plan(value=100, span=1, days=15))
    with pytest.warns(UserWarning, match="dca_plan: days enthält doppelte Tage"):
        r2 = sim(d, st, dca=dca_plan(value=100, span=1, days=[15, 15]))
    assert np.array_equal(r1.worth, r2.worth)
    with pytest.warns(UserWarning, match="rebalance_plan: days enthält doppelte"):
        rebalance_plan(days=[1, 1])
    d2 = pd.concat([d, d[["A"]]], axis=1)
    with pytest.raises(ValueError, match="Spaltenname 'A' kommt in 'data' mehrfach vor"):
        simulation(d2, st)
