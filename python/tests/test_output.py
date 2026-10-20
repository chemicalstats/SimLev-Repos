"""Tests für Trigger, Dashboards und HTML-Export."""
import os
import re

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


def test_plot_interactive_html(tmp_path):
    r = _result()
    f = str(tmp_path / "d.html")
    out = simlev.plot_interactive(r, file=f, open=False, engine="html")
    assert out == f and os.path.exists(f)
    txt = open(f, encoding="utf-8").read()
    for token in ("makePanel", "Gesamt", "2022-01", "hover", "weights"):
        assert token in txt


def test_plot_interactive_panels_and_thinning(tmp_path):
    d = pd.DataFrame({"date": pd.date_range("2022-01-03", periods=500), "A": np.linspace(100, 150, 500)})
    r = simulation(d, create_strategy(A=asset_config("etf", "bnh", 1, 0, 0)))
    f = str(tmp_path / "d.html")
    simlev.plot_interactive(r, file=f, open=False, engine="html", panels="drawdown", max_points=100)
    txt = open(f, encoding="utf-8").read()
    assert '"drawdown"' in txt and 'id="performance"' not in txt
    assert len(re.findall(r"\d{4}-\d{2}-\d{2}", txt)) <= 110


def test_dashboard_and_exports(tmp_path):
    pytest.importorskip("matplotlib")
    import matplotlib
    matplotlib.use("Agg")
    r = _result(400)
    fig = r.plot()
    assert len(fig.axes) == 6
    assert len(r.plot(style="compact").axes) == 4
    assert len(r.plot(style="custom", panels=["performance", "stats"]).axes) == 2
    assert len(r.plot(compare=r).axes) == 8
    pdf = tmp_path / "x.pdf"
    simlev.export_dashboard(r, str(pdf))
    assert pdf.exists() and pdf.stat().st_size > 1000
    # wie R 0.5.0: Platzhalter (ohne plotly ein Fehler, sonst nur eine Meldung; keine Datei)
    html = tmp_path / "x.html"
    try:
        import plotly  # noqa: F401
        simlev.export_html_dashboard(r, str(html))
    except ImportError:
        with pytest.raises(ValueError, match="Das Paket 'plotly' wird für HTML-Dashboards benötigt"):
            simlev.export_html_dashboard(r, str(html))
    assert not html.exists()
    import matplotlib.pyplot as plt
    plt.close("all")
