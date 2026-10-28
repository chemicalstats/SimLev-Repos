"""Port von test-wrapper.R (Fonds-Wrapper, Etappe 6.5c): wrapper_config, asset_config(wrapper=), wrapper_nav,
Einbau in simulation(), Aufrufer, Druck und Paketzustand der Ordergebühren."""
import contextlib
import io
import math
import warnings

import numpy as np
import pandas as pd
import pytest

import simlev
from simlev import (SimLevWrapperConfig, SimLevWrapperNav, asset_config, create_strategy, funds_costs,
                    rebalance_plan, sim_costs, split_rule, strategy_add_asset, strategy_update_asset,
                    strategy_validate, tax_profile, wrapper_config, wrapper_nav)
from simlev._r import rng
from simlev._r.rnum import r_cumprod
from simlev._sim_base import _FEE
from simlev.config import _strategy_columns


def _data(n=500, seed=7):
    """``.wr_data``: Kursreihen A, B, C wie im R-Test (gleicher Zufallsstrom)."""
    rng.set_seed(seed)
    d = pd.DataFrame({"date": pd.date_range("2019-11-01", periods=n, freq="D")})
    d["A"] = 100 * r_cumprod(1 + np.asarray(rng.rnorm(n, 4e-4, 0.011)))
    d["B"] = 50 * r_cumprod(1 + np.asarray(rng.rnorm(n, 1e-4, 0.004)))
    d["C"] = 80 * r_cumprod(1 + np.asarray(rng.rnorm(n, 2e-4, 0.006)))
    return d


def _inner():
    return create_strategy(A=asset_config(asset_class="etf", trading="bnh", share=0.6),
                           B=asset_config(asset_class="etf", trading="bnh", share=0.4))


def _quiet(fn, *a, **k):
    """``suppressWarnings(suppressMessages(fn(...)))``."""
    with warnings.catch_warnings(), contextlib.redirect_stderr(io.StringIO()):
        warnings.simplefilter("ignore")
        return fn(*a, **k)


def _messages(fn, *a, **k):
    buf = io.StringIO()
    with contextlib.redirect_stderr(buf):
        out = fn(*a, **k)
    return out, buf.getvalue().splitlines()


def _close(a, b, tol):
    """``expect_equal(a, b, tolerance = tol)`` (mittlere relative Abweichung wie all.equal)."""
    a = np.asarray(a, dtype=float)
    b = np.asarray(b, dtype=float)
    assert a.shape == b.shape
    den = np.mean(np.abs(b))
    return float(np.mean(np.abs(a - b)) / (den if den > 0 else 1.0)) < tol


def test_plausibilitaet_ohne_kosten_gleich_innere_strategie():
    d = _data()
    inner = _inner()
    w = wrapper_config(inner, costs=funds_costs(fee=0, performance_fee=0))
    r_w = _quiet(simlev.simulation, d, create_strategy(Z=asset_config(asset_class="certificate", wrapper=w)))
    r_i = _quiet(simlev.simulation, d, inner)
    assert _close(r_w.worth[-1:], r_i.worth[-1:], 1e-10)
    assert _close(r_w.worth, r_i.worth, 1e-10)
    rb = rebalance_plan(unit="quarter")
    w2 = wrapper_config(inner, rebalance=rb, costs=funds_costs(fee=0, performance_fee=0), volume=10000)
    r_w2 = _quiet(simlev.simulation, d, create_strategy(Z=asset_config(asset_class="certificate", wrapper=w2)))
    r_i2 = _quiet(simlev.simulation, d, inner, rebalance=rb)
    assert _close(r_w2.worth[-1:], r_i2.worth[-1:], 1e-10)
    w3 = wrapper_config(inner, rebalance=rb, costs=funds_costs(fee=0, performance_fee=0))
    r_w3 = _quiet(simlev.simulation, d, create_strategy(Z=asset_config(asset_class="certificate", wrapper=w3)))
    assert _close(r_w3.worth[-1:], r_i2.worth[-1:], 1e-6)


def test_handbeispiel_gebuehr_schaltjahr_abgrenzung_festschreibung():
    dates = pd.to_datetime(["2020-02-27", "2020-02-28", "2020-03-02", "2020-12-30", "2020-12-31", "2021-01-04",
                            "2021-06-30", "2021-12-31", "2022-01-03"])
    A = np.array([100, 101, 103, 110, 112, 111, 95, 120, 121], dtype=float)
    dh = pd.DataFrame({"date": dates, "A": A})
    fee, pf = 1.0, 20.0
    w = wrapper_config(create_strategy(A=asset_config(asset_class="etf")), costs=funds_costs(fee=fee, performance_fee=pf))
    x = wrapper_nav(dh, w)
    assert isinstance(x, SimLevWrapperNav)
    assert list(x.columns) == ["date", "nav", "gross", "fee", "perf_fee", "perf_paid", "hwm"]
    # von Hand: G_t / G_{t-1} = A_t / A_{t-1} (ein Asset, ohne Kosten innen), Start U = H = 100
    day = dates.values.astype("datetime64[D]").astype(np.int64)
    yr = dates.year.to_numpy()
    U, H, Gp, dp, n = 100.0, 100.0, 100.0, float(day[0]), len(dh)
    nav, fe, acc, paid, hwm = (np.zeros(n) for _ in range(5))
    for t in range(n):
        D = 366 if yr[t] % 4 == 0 else 365
        a = U * (A[t] / A[0] * 100 / Gp)
        fe[t] = a * (fee / 100 * (day[t] - dp) / D)
        U = a - fe[t]
        acc[t] = pf / 100 * max(0.0, U - H)
        nav[t] = U - acc[t]
        if t < n - 1 and yr[t + 1] != yr[t]:
            paid[t] = acc[t]
            U = nav[t]
            H = max(H, U)
        hwm[t] = H
        Gp = A[t] / A[0] * 100
        dp = float(day[t])
    for col, ref in (("nav", nav), ("fee", fe), ("perf_fee", acc), ("perf_paid", paid), ("hwm", hwm)):
        assert _close(x[col], ref, 1e-12), col
    assert _close(x["gross"], A / A[0] * 100, 1.5e-8)
    # Schaltjahr: 2020-02-28 -> 2020-03-02 sind 3 Kalendertage mit D = 366
    a3 = (x["nav"][1] + x["perf_fee"][1]) * A[2] / A[1]
    assert math.isclose(x["fee"][2], a3 * 0.01 * 3 / 366, rel_tol=1e-12)
    # Festschreibung am letzten Datentag 2020 und 2021, nicht am letzten Tag insgesamt
    assert list(x["perf_paid"] > 0) == [False, False, False, False, True, False, False, True, False]
    assert math.isclose(x["hwm"][4], x["nav"][4], rel_tol=1e-15)
    assert x["perf_fee"][5] == 0
    assert x["perf_fee"][8] > 0
    assert x["fee"][0] == 0
    assert isinstance(x.attrs["inner"], simlev.SimLevResult) and x.attrs["wrapper"] is w


def test_startkosten_ordergebuehr_und_innerer_spread():
    d = _data(60)
    w = wrapper_config(_inner(), costs=funds_costs(fee=0, performance_fee=0), order_fee={"fixed": 5, "percent": 0.1},
                       volume=1e6)
    x = wrapper_nav(d, w)
    assert math.isclose(x["nav"][0], 100 * ((6e5 - 5) / 1.001 + (4e5 - 5) / 1.001) / 1e6, rel_tol=1e-12)
    ws = _quiet(wrapper_config, create_strategy(A=asset_config(asset_class="etf", trading="bnh", share=1, spread=0.2)),
                costs=funds_costs(fee=0, performance_fee=0))
    assert wrapper_nav(d, ws)["nav"][0] < 100


def test_na_tage_spaeterer_beginn_wochenenden():
    d = _data(200)
    w = wrapper_config(_inner(), costs=funds_costs(fee=0.95, performance_fee=10))
    dn = d.copy()
    dn.loc[[19, 20], ["A", "B"]] = simlev.NA
    x = _quiet(wrapper_nav, dn, w)
    xd = x["date"].to_numpy().astype("datetime64[D]")
    nd = dn["date"].to_numpy().astype("datetime64[D]")
    assert not np.isin(xd, nd[[19, 20]]).any()
    i = int(np.flatnonzero(xd == nd[18])[0])
    assert xd[i + 1] == nd[21]
    assert math.isclose(x["fee"][i + 1], (x["nav"][i] + x["perf_fee"][i]) * x["gross"][i + 1] / x["gross"][i]
                        * (0.95 / 100 * 3 / 365), rel_tol=1e-12)
    dl = d.copy()
    dl.loc[0:4, ["A", "B"]] = simlev.NA
    assert _quiet(wrapper_nav, dl, w)["date"].to_numpy().astype("datetime64[D]")[0] == nd[5]
    r = _quiet(simlev.simulation, dl, create_strategy(Z=asset_config(share=0.5, wrapper=w), C=asset_config(share=0.5)))
    assert list(r.report["Z"]["worth"][:5]) == [0.0] * 5
    with pytest.raises(ValueError, match="In der ersten Zeile"):
        _quiet(simlev.simulation, dl, create_strategy(Z=asset_config(wrapper=w)))
    dw = d[~d["date"].dt.dayofweek.isin([5, 6])].reset_index(drop=True)
    xw = _quiet(wrapper_nav, dw, w)
    mo = int(np.flatnonzero(xw["date"].dt.dayofweek.to_numpy() == 0)[1])   # Montag: Gebühr über 3 Kalendertage
    assert math.isclose(xw["fee"][mo], (xw["nav"][mo - 1] + xw["perf_fee"][mo - 1]) * xw["gross"][mo] / xw["gross"][mo - 1]
                        * (0.95 / 100 * 3 / 365), rel_tol=1e-12)


def test_fehler_hinweis_und_gebuehrenzustand():
    d = _data(100)
    inner = _inner()
    w = wrapper_config(inner)
    with pytest.raises(ValueError, match="verschachtelte Wrapper"):
        wrapper_config(create_strategy(Z=asset_config(wrapper=w)))
    with pytest.raises(ValueError, match='nur trading = "bnh"'):
        asset_config(asset_class="etf", trading="signal", signal_buy="b", signal_sell="s", wrapper=w)
    with pytest.raises(ValueError, match='nur trading = "bnh"'):
        simlev.simulation(d, {"Z": {"asset_class": "etf", "trading": "signal", "share": 1, "signal_buy": "b",
                                    "signal_sell": "s", "wrapper": w}})
    d2 = d.copy()
    d2["Z"] = 1.0
    with pytest.raises(ValueError, match="keine Spalte gleichen Namens"):
        simlev.simulation(d2, create_strategy(Z=asset_config(wrapper=w)))
    with pytest.raises(ValueError, match="keine Spalte gleichen Namens"):
        strategy_validate(create_strategy(Z=asset_config(wrapper=w)), data=d2)
    assert strategy_validate(create_strategy(Z=asset_config(wrapper=w)), data=d) is True
    with pytest.raises(ValueError, match="'B' fehlen"):
        strategy_validate(create_strategy(Z=asset_config(wrapper=w)), data=d[["date", "A"]])
    for of in (1, {"percent": 0.1, "min": 1}, {"percent": 0.1, "max": 5}):
        with pytest.raises(ValueError, match="Fondsvolumen 'volume'"):
            wrapper_config(inner, order_fee=of)
    wrapper_config(inner, order_fee={"percent": 0.1})
    with pytest.raises(ValueError, match="'volume' muss"):
        wrapper_config(inner, volume=0)
    with pytest.raises(ValueError, match="funds_costs"):
        wrapper_config(inner, costs=sim_costs())
    with pytest.raises(ValueError, match="rebalance_plan"):
        wrapper_config(inner, rebalance=1)
    with pytest.raises(ValueError, match="create_strategy"):
        wrapper_config(1)
    with pytest.raises(ValueError, match="summieren sich"):
        wrapper_config(create_strategy(A=asset_config(share=0.5)))
    with pytest.raises(ValueError, match="wrapper_config"):
        asset_config(wrapper=1)
    with pytest.raises(ValueError, match="wrapper_config"):
        wrapper_nav(d, inner)
    with pytest.raises(ValueError, match="split_rule"):
        wrapper_nav(d, w, splits=1)
    _, msg = _messages(wrapper_config, create_strategy(A=asset_config(spread=0.1)))
    assert msg == ["Hinweis: wrapper_config: innere Assets mit Spread > 0: 'A' (0.1 %); der Spread gilt in der inneren "
                   "Rechnung (Kauf und Umschichten)."]
    _, msg = _messages(wrapper_config, inner)
    assert msg == []
    # Paketzustand der Ordergebühren (R: .fee_env): nach wrapper_nav (auch mit Ordergebühr und nach Fehler) unverändert
    old = dict(vars(_FEE))
    try:
        _FEE.current = {"fixed": 1.0, "percent": 0.0, "min": 0.0, "max": math.inf}
        _FEE.paid = 12.5
        before = dict(vars(_FEE))
        wrapper_nav(d, wrapper_config(inner, rebalance=rebalance_plan(), order_fee={"fixed": 2, "percent": 0.1},
                                      volume=1e5))
        assert dict(vars(_FEE)) == before
        dm = d.copy()
        dm["A"] = -1.0
        with pytest.raises(ValueError, match="innere Rechnung"):
            _quiet(wrapper_nav, dm, w)
        assert dict(vars(_FEE)) == before
    finally:
        vars(_FEE).clear()
        vars(_FEE).update(old)


def test_aeussere_ordergebuehren_wie_mit_nav_als_kursspalte():
    # Wrapper mit innerer Ordergebühr = dieselbe Rechnung mit dem Anteilswert als gewöhnlicher Kursspalte
    d = _data(200)
    w = wrapper_config(_inner(), rebalance=rebalance_plan(), costs=funds_costs(fee=0.5, performance_fee=5),
                       order_fee={"fixed": 2, "percent": 0.1}, volume=1e5)
    st = create_strategy(Z=asset_config(asset_class="certificate", share=0.5, wrapper=w), C=asset_config(share=0.5))
    r1 = _quiet(simlev.simulation, d, st, costs=sim_costs(order_fee=1), rebalance=rebalance_plan())
    dZ = d.copy()
    dZ["Z"] = wrapper_nav(d, w)["nav"].to_numpy()
    r0 = _quiet(simlev.simulation, dZ, create_strategy(Z=asset_config(asset_class="certificate", share=0.5),
                                                       C=asset_config(share=0.5)),
                costs=sim_costs(order_fee=1), rebalance=rebalance_plan())
    assert r1.fees_paid == r0.fees_paid and r1.fees_paid > 0
    assert np.array_equal(r1.worth, r0.worth)


def test_meldungen_und_warnungen_der_inneren_rechnung():
    d = _data(100)
    w = wrapper_config(_inner(), costs=funds_costs(fee=0.95, performance_fee=10))
    dn = d.copy()
    dn.loc[[10, 11], ["A", "B"]] = simlev.NA
    _, msg = _messages(simlev.simulation, dn, create_strategy(Z=asset_config(asset_class="certificate", wrapper=w)))
    assert msg[0] == "Hinweis: Wrapper 'Z' (innere Rechnung): 'A': 2 fehlende Kurse (NA) per LOCF gefüllt."
    assert msg[-1] == "Hinweis: 'Z': 2 fehlende Kurse (NA) per LOCF gefüllt."
    # Werktagsdaten: Hinweis zum Auffüllen der Kalendertage zweimal (innere Rechnung mit Präfix)
    dw = d[~d["date"].dt.dayofweek.isin([5, 6])].reset_index(drop=True)
    _, msg = _messages(simlev.simulation, dw, create_strategy(Z=asset_config(asset_class="certificate", wrapper=w)))
    assert len(msg) == 2 and msg[0] == "Hinweis: Wrapper 'Z' (innere Rechnung): " + msg[1][len("Hinweis: "):]
    # ein Tag: Warnung der inneren Rechnung mit Präfix
    with warnings.catch_warnings(record=True) as wl:
        warnings.simplefilter("always")
        simlev.simulation(d.iloc[:1], create_strategy(Z=asset_config(asset_class="certificate", wrapper=w)))
    txt = [str(x.message) for x in wl]
    assert txt[0].startswith("simulation: Wrapper 'Z' (innere Rechnung): simulation: Zeitraum 1 Tag")
    assert txt[1].startswith("simulation: Zeitraum 1 Tag")


def test_simulation_details_keine_splits_auf_anteilswert():
    d = _data(300)
    w = wrapper_config(_inner(), rebalance=rebalance_plan(unit="quarter"), costs=funds_costs(fee=0.95, performance_fee=10))
    st = create_strategy(Z=asset_config(asset_class="certificate", share=0.7, spread=0.3, wrapper=w),
                         C=asset_config(share=0.3))
    r0 = _quiet(simlev.simulation, d, st, tax=tax_profile())
    assert "wrappers" not in r0
    with contextlib.redirect_stdout(io.StringIO()):
        r1 = _quiet(simlev.simulation, d, st, tax=tax_profile(), details=True)
    assert isinstance(r1.wrappers["Z"], SimLevWrapperNav)
    assert np.array_equal(r1.worth, r0.worth)
    assert list(r1.keys()) == list(r0.keys()) + ["wrappers"]
    nv = wrapper_nav(d, w)
    u = r0.report["Z"]["worth"] / nv["nav"].to_numpy()
    assert np.all(np.abs(u - u[0]) < 1e-9 * u[0])
    dsp = d.copy()
    rng.set_seed(3)
    dsp["A"] = 100 * r_cumprod(1 + np.asarray(rng.rnorm(300, 3e-3, 0.005)))
    nvs = wrapper_nav(dsp, w, splits=split_rule([50, 115]))
    assert nvs["nav"].max() > 115
    assert _close(nvs["nav"], wrapper_nav(dsp, w)["nav"], 1e-7)
    buf = io.StringIO()
    with contextlib.redirect_stdout(buf):
        rs = _quiet(simlev.simulation, dsp, create_strategy(Z=asset_config(asset_class="certificate", wrapper=w)),
                    splits=split_rule([50, 115]), fractions=False, details=True)
    assert "Split" not in buf.getvalue()
    us = rs.report["Z"]["worth"] / nvs["nav"].to_numpy()
    assert np.all(np.abs(us - us[0]) < 1e-9 * us[0])
    dN = pd.DataFrame({"date": nvs["date"], "N": nvs["nav"].to_numpy()})
    buf = io.StringIO()
    with contextlib.redirect_stdout(buf):
        _quiet(simlev.simulation, dN, create_strategy(N=asset_config()), splits=split_rule([50, 115]), fractions=False,
               details=True)
    assert "Split" in buf.getvalue()


def test_strategy_update_und_add_asset_mit_wrapper():
    w = wrapper_config(_inner())
    st = create_strategy(Z=asset_config(asset_class="etf", wrapper=w))
    st2 = strategy_update_asset(st, "Z", asset_class="certificate", spread=0.5)
    assert st2["Z"]["tax_regime"] == "capital_gains" and isinstance(st2["Z"]["wrapper"], SimLevWrapperConfig)
    with pytest.raises(ValueError, match="nur trading"):
        strategy_update_asset(st, "Z", trading="signal", signal_buy="a", signal_sell="b")
    st3 = strategy_update_asset(create_strategy(A=asset_config()), "A", wrapper=w)
    assert isinstance(st3["A"]["wrapper"], SimLevWrapperConfig)
    assert list(strategy_update_asset(st3, "A", wrapper=None)["A"].keys()) == list(asset_config().keys())
    st4 = strategy_add_asset(create_strategy(C=asset_config(share=0.5)), "Z", asset_config(share=0.5, wrapper=w))
    assert list(st4.keys()) == ["C", "Z"]
    assert "wrapper" not in asset_config()
    assert _strategy_columns(st4) == ["C", "A", "B"]
    assert _strategy_columns(_inner()) == ["A", "B"]


def test_aufrufer_planning_und_withdrawal():
    d = _data(900)
    w = wrapper_config(_inner(), costs=funds_costs(fee=0.5, performance_fee=0))
    pl = simlev.planning_lumpsum_vs_dca(d, create_strategy(Z=asset_config(wrapper=w)), amount=1200, months=4, horizon=1,
                                        step=6)
    assert bool(np.all(pl["exact"]))
    nv = wrapper_nav(d, w)
    ws = simlev.withdrawal_simulation(nv, rule=simlev.withdrawal_rule(type="percent", rate=4), years=1, frequency="quarter")
    assert isinstance(ws, simlev.SimLevWithdrawal)
    co = simlev.withdrawal_cohorts(nv, price="nav", years=1, frequency="quarter")
    ws2 = simlev.withdrawal_simulation(co, rule=simlev.withdrawal_rule(type="percent", rate=4))
    for k in ws["paths"]:
        a, b = ws["paths"][k], ws2["paths"][k]
        assert np.array_equal(np.asarray(a, dtype=float), np.asarray(b, dtype=float), equal_nan=True), k


def test_druck():
    w = wrapper_config(_inner(), costs=funds_costs(fee=0.95, performance_fee=10), order_fee={"percent": 0.1}, volume=1e6)
    out = w.format().splitlines()
    assert out[0] == "Fonds-Wrapper (wrapper_config)"
    assert any(ln.startswith("  Fondsvolumen:") and ln.endswith(" 1000000.00 EUR") for ln in out)
    assert any(ln.startswith("  Wrapper:      A 60 %, B 40 %") for ln in asset_config(wrapper=w).format().splitlines())
    assert funds_costs().format().splitlines()[0] == "Fondskosten (funds_costs)"
    out = str(wrapper_nav(_data(30), w)).splitlines()
    assert out[0] == "Anteilswert (wrapper_nav)"
    assert any(ln.startswith("  Zeitraum:") and ln.endswith("2019-11-01 bis 2019-11-30 (30 Datentage)") for ln in out)
    # Teilmenge: gewöhnlicher DataFrame (R: ohne Attribut wrapper, Druck als data.frame)
    sub = wrapper_nav(_data(30), w).iloc[:3]
    assert not isinstance(sub, SimLevWrapperNav)


def test_auswahl_gewoehnliche_tabelle_ohne_attrs():
    """Etappe 8.0: jede Auswahl aus SimLevWrapperNav ist ein pandas.DataFrame ohne attrs (R: data.frame)."""
    x = wrapper_nav(_data(400), wrapper_config(_inner(), costs=funds_costs(fee=0.95, performance_fee=10)))
    assert isinstance(x, SimLevWrapperNav) and set(x.attrs) == {"inner", "wrapper"}
    subs = [x.iloc[0:5], x[["date", "nav"]], x.loc[x["nav"] > 100, ["date", "nav"]], x[x["nav"] > 100], x[:],
            x.head(3), x.tail(3), x.query("nav > 100"), x.copy(), pd.DataFrame(x)]
    for s in subs:
        assert type(s) is pd.DataFrame
        assert dict(s.attrs) == {}
    assert dict(x["nav"].attrs) == {}
    import pickle
    y = pickle.loads(pickle.dumps(x))                 # auch nach pickle (z. B. Ergebnis aus einem Kindprozess)
    assert isinstance(y, SimLevWrapperNav) and set(y.attrs) == {"inner", "wrapper"}
    assert dict(y.iloc[0:2].attrs) == {} and dict(y[["nav"]].attrs) == {}
    np.testing.assert_array_equal(x.iloc[9:20]["nav"].to_numpy(), x["nav"].to_numpy()[9:20])
    # das ganze Objekt behält Klasse und attrs; withdrawal_simulation nimmt es, ein Ausschnitt ergibt einen Fehler
    assert x.attrs["inner"].r_class[0] == "SimLevResult" and "SimLevWrapperConfig" in x.attrs["wrapper"].r_class
    rule = simlev.withdrawal_rule(type="percent", rate=4)
    assert "SimLevWithdrawal" in simlev.withdrawal_simulation(x, rule=rule, years=1, frequency="quarter").r_class
    with pytest.raises(ValueError, match="x ist eine Tabelle mit Spalte 'date'"):
        simlev.withdrawal_simulation(x.iloc[29:400], rule=rule, years=1, frequency="quarter")
    wp = simlev.withdrawal_cohorts(x.iloc[29:400], price="nav", inflation=2, years=1, frequency="quarter")
    assert "SimLevWithdrawal" in simlev.withdrawal_simulation(wp, rule=rule).r_class


def test_strategy_from_weights_wrapper_je_asset():
    """Etappe 8.0: wrapper in strategy_from_weights/portfolio_template (ein Objekt für alle, dict je Asset)."""
    from simlev import portfolio_template, strategy_from_weights
    w = wrapper_config(_inner(), costs=funds_costs(fee=0.95, performance_fee=10))
    w2 = wrapper_config(create_strategy(C=asset_config(asset_class="etf", trading="bnh", share=1)))

    def has(st):
        return {k: "wrapper" in a for k, a in st.items()}

    assert has(strategy_from_weights({"x": 0.5, "y": 0.5}, wrapper=w)) == {"x": True, "y": True}
    st = strategy_from_weights({"x": 0.5, "y": 0.3, "z": 0.2}, spread={"z": 0.1}, wrapper={"y": w2, "x": w})
    assert has(st) == {"x": True, "y": True, "z": False}
    assert st["y"]["wrapper"] is w2
    assert dict(st["z"]) == dict(strategy_from_weights({"x": 0.5, "y": 0.3, "z": 0.2}, spread={"z": 0.1})["z"])
    assert has(strategy_from_weights({"x": 0.5, "y": 0.5}, wrapper=None)) == {"x": False, "y": False}
    assert has(strategy_from_weights({"x": 0.5, "y": 0.5}, wrapper={})) == {"x": False, "y": False}
    d = _data(300)
    r1 = simlev.simulation(d, strategy_from_weights({"Z": 0.7, "C": 0.3}, asset_class={"Z": "certificate"}, wrapper={"Z": w}))
    r2 = simlev.simulation(d, create_strategy(Z=asset_config(asset_class="certificate", share=0.7, wrapper=w),
                                              C=asset_config(asset_class="etf", share=0.3)))
    np.testing.assert_array_equal(np.asarray(r1.worth), np.asarray(r2.worth))
    st = portfolio_template(name="60_40", map={"stocks": "aktien"}, wrapper={"aktien": w, "bonds": w2})
    assert has(st) == {"aktien": True, "bonds": True}
    with pytest.raises(ValueError, match=r"^wrapper: 'stocks' ist kein Asset der Strategie \(Assets: aktien, bonds\)\.$"):
        portfolio_template(name="60_40", map={"stocks": "aktien"}, wrapper={"stocks": w})
    with pytest.raises(ValueError, match=r"Eintrag 'y' muss ein Objekt aus wrapper_config\(\) sein, nicht character\."):
        strategy_from_weights({"x": 0.5, "y": 0.5}, wrapper={"x": w, "y": "w"})
    with pytest.raises(ValueError, match="braucht jedes Element einen Namen"):
        strategy_from_weights({"x": 0.5, "y": 0.5}, wrapper=[w])
    with pytest.raises(ValueError, match=r"nicht numeric\.$"):
        strategy_from_weights({"x": 0.5, "y": 0.5}, wrapper=1)
    with pytest.raises(ValueError, match="wrapper: Asset 'y' hat trading = \"signal\""):
        strategy_from_weights({"x": 0.5, "y": 0.5}, trading={"y": "signal"}, signal_buy="b", signal_sell="s", wrapper={"y": w})
    with pytest.raises(ValueError, match="asset_config: bei trading = \"signal\" müssen signal_buy"):
        strategy_from_weights({"x": 0.5, "y": 0.5}, trading={"y": "signal"}, wrapper={"y": w})
