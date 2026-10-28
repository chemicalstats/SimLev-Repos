"""Tests für Trigger und Dashboards."""
import numpy as np
import pandas as pd
import pytest

import simlev
from simlev import asset_config, compute_rebal_trigger, create_strategy, simulation


def _df():
    return pd.DataFrame({
        "date": pd.date_range("2020-01-01", periods=10),
        "target_leverage": [2.00, 2.05, 2.30, 2.28, 1.95, 1.90, 2.40, 2.42, 2.10, 2.00],
        "sigma_ewma": [0.10, 0.11, 0.16, 0.15, 0.10, 0.10, 0.20, 0.22, 0.14, 0.12],
    })


def test_trigger_types_match_r_reference():
    # Referenzwerte aus dem R-Paket (rebal_trigger_cookbook.R)
    df = compute_rebal_trigger(_df(), "abs_leverage", threshold=10, out_col="a")
    df = compute_rebal_trigger(df, "rel_leverage", threshold=10, out_col="r")
    df = compute_rebal_trigger(df, "vol_band", threshold=20, out_col="v")
    df = compute_rebal_trigger(df, "combined", triggers=[{"type": "abs_leverage", "threshold": 10},
                                                         {"type": "vol_band", "threshold": 20}], out_col="c")
    T, F = True, False
    assert df["a"].tolist() == [F, F, T, F, T, F, T, F, T, T]
    assert df["r"].tolist() == [F, F, T, F, T, F, T, F, T, F]
    assert df["v"].tolist() == [F, F, T, F, T, F, T, F, T, F]
    assert df["c"].tolist() == [F, F, T, F, T, F, T, F, T, T]


def test_trigger_errors():
    with pytest.raises(ValueError, match="Unbekannter type"):
        compute_rebal_trigger(_df(), "nope")
    with pytest.raises(ValueError, match="fehlt"):
        compute_rebal_trigger(_df(), "abs_leverage", lev_col="xx")
    with pytest.raises(ValueError, match="nicht-leere"):
        compute_rebal_trigger(_df(), "combined")


def _result(n=120):
    d = pd.DataFrame({"date": pd.date_range("2022-01-03", periods=n), "A": np.linspace(100, 130, n),
                      "B": np.linspace(100, 110, n)})
    s = create_strategy(A=asset_config("etf", "bnh", 0.6, 0, 30), B=asset_config("etf", "bnh", 0.4, 0, 0))
    return simulation(d, s)


def test_dashboard_and_exports(tmp_path):
    import contextlib
    import io
    r = _result(400)
    p = r.plot()
    assert isinstance(p, simlev.SimLevPlot) and p.svg.startswith("<svg") and len(p.data) == 6
    assert len(r.plot(style="compact").data) == 4
    assert list(r.plot(style="custom", panels=["performance", "stats"]).data) == ["performance", "stats"]
    assert len(r.plot(compare=r).data) == 8
    svg = tmp_path / "x.svg"
    with contextlib.redirect_stderr(io.StringIO()):
        simlev.export_dashboard(r, str(svg))
    assert svg.exists() and svg.stat().st_size > 1000
    with pytest.raises(ValueError, match="nur als SVG"):
        simlev.export_dashboard(r, str(tmp_path / "x.pdf"))
