"""Port der Dashboard-Tests (test-review7-stats.R C7-08, R8-06, Layout, R9-04, R9-05;
test-blue-engine.R R1-19/R1-22; test-flow-metrics.R Punkt 2)."""
import contextlib
import io
import warnings

import matplotlib

matplotlib.use("Agg")
import matplotlib.pyplot as plt  # noqa: E402
import numpy as np  # noqa: E402
import pandas as pd  # noqa: E402
import pytest  # noqa: E402
from matplotlib.text import Text  # noqa: E402

import simlev  # noqa: E402
from simlev import asset_config, create_strategy  # noqa: E402
from simlev._r.rformat import r_sprintf  # noqa: E402
from simlev.dashboard import (  # noqa: E402
    _correlation, _comparison_rows, _dash_custom_layout, _dashboard_returns, _format_amount, _r_cor,
    _stats_sections, export_dashboard, plot_dashboard)

from _helpers import sim  # noqa: E402
from test_tax_law import _dca  # noqa: E402

approx = pytest.approx


def _series(seed, n, start="2021-01-01", **cols):
    rng = np.random.default_rng(seed)
    d = pd.DataFrame({"date": pd.date_range(start, periods=n)})
    for k, (s0, mu, sd) in cols.items():
        d[k] = s0 * np.cumprod(1 + rng.normal(mu, sd, n))
    return d


@pytest.fixture(scope="module")
def r500():
    d = _series(7, 500, ETF=(100, 4e-4, 0.012))
    return sim(d, create_strategy(ETF=asset_config("etf", asset_share=1)))


def silent(*a, **k):
    with warnings.catch_warnings(record=True) as wl:
        warnings.simplefilter("always")
        fig = plot_dashboard(*a, **k)
    plt.close(fig)
    assert [str(w.message) for w in wl] == []
    return fig


def texts(fig):
    out = set()
    for t in fig.findobj(Text):
        out.update(t.get_text().split("\n"))
    return out


def test_c7_08_panels_und_teilfarben(r500):
    r = r500
    with pytest.raises(ValueError, match=r'unbekannte\(s\) Panel\(s\) "perfromance", "drawdwon"'):
        plot_dashboard(r, style="custom", panels=["perfromance", "drawdwon"])
    with pytest.raises(ValueError, match='"xyz"'):
        plot_dashboard(r, style="custom", panels=["performance", "xyz"])
    silent(r, style="custom", panels=["perf", "draw", "performance"])
    with pytest.warns(UserWarning, match='panels wirkt nur mit style = "custom"'):
        plt.close(plot_dashboard(r, panels="performance"))
    silent(r, style="compact")
    silent(r, colors={"primary": "#003366"})
    silent(r, colors=pd.Series({"primary": "#003366", "negative": "#AA0000"}))
    with pytest.raises(ValueError, match=r"unbekannte Farbe\(n\) 'primry'"):
        plot_dashboard(r, colors={"primry": "#003366"})
    with pytest.raises(ValueError, match="colors muss eine benannte Liste"):
        plot_dashboard(r, colors="#003366")
    with pytest.raises(ValueError, match="panels muss ein Zeichenvektor sein"):
        plot_dashboard(r, style="custom", panels=[])
    assert plt.get_fignums() == []


def test_r8_06_farbnamen_und_pruefung(r500):
    r = r500
    silent(r, colors={"primary": "navy"})
    silent(r, colors={"negative": "darkred", "positive": "forestgreen"})
    silent(r, colors={"primary": "#00336680"})
    with pytest.raises(ValueError, match='ungültige Farbe\\(n\\) in colors: primary = "navyy"'):
        plot_dashboard(r, colors={"primary": "navyy"})
    with pytest.raises(ValueError, match='primary = "#12345"'):
        plot_dashboard(r, colors={"primary": "#12345"})
    with pytest.raises(ValueError, match="grid = NA"):
        plot_dashboard(r, colors={"grid": None})
    with pytest.raises(ValueError, match='ungültige Farbe.*c\\("red", "blue"\\)'):
        plot_dashboard(r, colors={"primary": ["red", "blue"]})
    from simlev.dashboard import _alpha_col, _col2rgba
    for cl in ("#2E86AB", "#D62246"):
        for a in (0x30, 0x40, 0x80):
            rgb = _col2rgba(cl)
            assert _alpha_col(cl, a) == approx(rgb[:3] + (a / 255,))
    assert _col2rgba("Navy Blue") == _col2rgba("navy") == approx((0, 0, 128 / 255, 1))


def test_layout_custom():
    for k in range(1, 9):
        m = _dash_custom_layout(k)
        assert sorted(m[m > 0].tolist()) == list(range(1, k + 1))
        assert int((m == 0).sum()) == (1 if k % 2 and k > 1 else 0)
    assert _dash_custom_layout(1).tolist() == [[1]]
    assert _dash_custom_layout(2).tolist() == [[1, 2]]
    assert _dash_custom_layout(3).tolist() == [[1, 2], [3, 0]]
    assert _dash_custom_layout(8).tolist() == [[1, 2], [3, 4], [5, 6], [7, 8]]


def test_layout_beispiele(r500):
    silent(r500, style="custom", panels=["performance", "drawdown", "distribution"])
    silent(r500, style="custom", panels=["performance", "drawdown", "distribution", "rolling", "monthly"])
    silent(r500, style="custom", panels=["performance", "drawdown", "distribution", "rolling", "monthly", "stats",
                                         "correlation"], compare=r500)


def test_performance_y_bereich_ueber_alle_kurven():
    d = _series(7, 500, ETF=(100, 4e-4, 0.012), B=(100, -6e-4, 0.008), C=(100, -1e-3, 0.01))
    r = sim(d, create_strategy(ETF=asset_config("etf", asset_share=1)))
    r2 = sim(d, create_strategy(B=asset_config("etf", asset_share=1)))
    rl = sim(d, create_strategy(C=asset_config("etf", asset_share=1)), dca_mode=True, dca_value=500, dca_span=1)
    inv = _dashboard_returns(rl)["invested"]
    assert inv.max() > rl.worth.max()

    def ylim(x, **k):
        fig = silent(x, style="custom", panels="performance", **k)
        lo, hi = fig.axes[0].get_ylim()
        d4 = (hi - lo) / 1.08 * 0.04          # R: yaxs = "r" (4 % Rand)
        return lo + d4, hi - d4
    both = np.concatenate([r.worth, r2.worth])
    assert ylim(r, compare=r2) == approx((both.min(), both.max()))
    assert ylim(r2, compare=r) == approx((both.min(), both.max()))
    assert ylim(rl) == approx((min(rl.worth.min(), inv.min()), max(rl.worth.max(), inv.max())))
    assert ylim(r) == approx((r.worth.min(), r.worth.max()))


def test_raender_und_export(tmp_path):
    d = _series(7, 3 * 365, ETF=(100, 4e-4, 0.012), B=(100, 1e-4, 0.008))
    r = sim(d, create_strategy(ETF=asset_config("etf", asset_share=0.6), B=asset_config("etf", asset_share=0.4)),
            start_value=250000)
    r2 = sim(d, create_strategy(B=asset_config("etf", asset_share=1)), start_value=250000)
    silent(r, compare=r2)
    silent(r, style="compact")
    silent(r, style="custom", panels=["performance", "rolling", "monthly"])
    f = tmp_path / "d.pdf"
    err = io.StringIO()
    with contextlib.redirect_stderr(err):
        export_dashboard(r, str(f), compare=r2)
    assert f.exists() and err.getvalue() == "export_dashboard: Dashboard gespeichert in %s\n" % f
    assert plt.get_fignums() == []


def test_strategievergleich_farben():
    d = _series(7, 3 * 365, ETF=(100, 4e-4, 0.012), B=(100, 1e-4, 0.008))
    r = sim(d, create_strategy(ETF=asset_config("etf", asset_share=0.6), B=asset_config("etf", asset_share=0.4)))
    r2 = sim(d, create_strategy(B=asset_config("etf", asset_share=1)))
    pos, neg, neu = "#06A77D", "#D62246", "#6C757D"

    def cols(a, b):
        return [z["diff_col"] for z in _comparison_rows(a, b)]
    assert r.drawdowns.max() > r2.drawdowns.max()
    cl = cols(r, r2)
    assert cl[1] == neg
    assert [cl[0], cl[3]] == [pos if r.cagr > r2.cagr else neg, pos if r.statistics["sharpe"] > r2.statistics["sharpe"]
                              else neg]
    assert cols(r2, r)[1] == pos
    assert cols(r, r) == [neu] * 4
    assert [z["metric"] for z in _comparison_rows(r, r2)] == ["CAGR", "Max. DD", "Volatilität", "Sharpe"]


def test_betraege_startkapital_achsen():
    d = _series(42, 365 * 4, start="2015-01-01", A=(100, 4e-4, 0.010))
    r = sim(d, create_strategy(A=asset_config("etf", asset_share=1)), start_value=10000)
    fig = silent(r, style="custom", panels=["performance", "stats"])
    tx = texts(fig)
    fin = r.worth[-1]
    u = 1e6 if fin >= 1e6 else 1e3
    assert r_sprintf("Endwert: %.2f EUR", fin) in tx
    assert r_sprintf("Startkapital: %.2f EUR", r.invested[0]) in tx and r.invested[0] == 10000
    lab = r_sprintf("%.*f %s", 2 - int(np.floor(np.log10(fin / u))), fin / u, "Mio." if u == 1e6 else "Tsd.")
    assert lab in tx
    r_old = simlev.SimLevResult(r)
    del r_old["invested"]
    assert r_sprintf("Depotwert Starttag: %.2f EUR", r.worth[0]) in _stats_sections(r_old)["Depot"]
    ax = fig.axes[0]
    for t, lb in zip(ax.get_yticks(), ax.get_yticklabels()):
        s = lb.get_text()
        mult = 1e6 if "Mio" in s else (1e3 if "Tsd" in s else 1)
        assert float(s.split(" ")[0]) * mult == approx(t)
    assert _format_amount([12500, 2.5e6, 999, 1234.5678], signif3=False) == ["12.5 Tsd.", "2.5 Mio.", "999",
                                                                             "1.235 Tsd."]
    assert _format_amount([18234.5, 250000, 1e6], signif3=True) == ["18.2 Tsd.", "250 Tsd.", "1.00 Mio."]


def test_r9_04_startkapital_ohne_sparrate():
    d = _series(42, 365 * 2, start="2015-01-01", W=(100, 4e-4, 0.010), B=(50, 1e-4, 0.003))
    r = sim(d, create_strategy(W=asset_config("etf", asset_share=0.7), B=asset_config("etf", asset_share=0.3)),
            start_value=10000, dca_mode=True, dca_value=250, dca_span=1, dca_unit="month")
    assert r.invested[0] == 10250
    dep = _stats_sections(r)["Depot"]
    assert "Startkapital: 10000.00 EUR" in dep
    assert r_sprintf("Eingezahlt: %.2f EUR", r.invested[-1]) in dep


def test_r9_05_korrelation():
    d = _series(42, 365 * 3, start="2015-01-01", W=(100, 4e-4, 0.010), B=(50, 1e-4, 0.003))
    r1 = sim(d, create_strategy(W=asset_config("etf", asset_share=0.7), B=asset_config("etf", asset_share=0.3)))
    r2 = sim(d, create_strategy(B=asset_config("etf", asset_share=1)))
    fig = silent(r1, compare=r2)
    a, b = _dashboard_returns(r1)["all_returns"], _dashboard_returns(r2)["all_returns"]
    rho = _r_cor(a, b)
    assert rho == approx(np.corrcoef(a, b)[0, 1], rel=1e-12)
    assert r_sprintf("Gesamt: %.2f", rho) in texts(fig)
    c = _correlation(r1, r2)
    assert c["k"] == 252 and c["rho"].size == len(a) - 251
    with pytest.warns(UserWarning, match=r'Panel\(s\) "correlation", "comparison" nicht gezeichnet: benötigen ein '
                                         r'Vergleichsergebnis \(compare\)'):
        plt.close(plot_dashboard(r1, style="custom", panels=["performance", "correlation", "comparison"]))
    with pytest.warns(UserWarning, match='"comparison" nicht gezeichnet: benötigt'):
        fig = plot_dashboard(r1, style="custom", panels="comparison")
    assert any(t.startswith("Keine zeichenbaren Panels") for t in texts(fig))
    plt.close(fig)
    silent(r1)
    with pytest.raises(ValueError, match="compare muss ein SimLevResult über dieselben Tage"):
        plot_dashboard(r1, compare=sim(d.iloc[:400], create_strategy(B=asset_config("etf"))))
    with pytest.raises(ValueError, match="Objekt der Klasse 'list'"):
        plot_dashboard(r1, compare=[1, 2])


def test_r1_19_r1_22_kurze_reihen_und_export(tmp_path):
    d = _series(12, 3 * 365, start="2020-01-01", A=(100, 4e-4, 0.01))
    st = create_strategy(A=asset_config("etf", asset_share=1, asset_spread=0))
    r = sim(d, st, dca_mode=True, dca_value=5000, dca_span=1)
    dr = _dashboard_returns(r)
    assert np.std(dr["returns"], ddof=1) == approx(r.statistics["sd"], rel=1e-12)
    assert dr["returns"].max() < 0.1
    assert dr["ppy"] == approx((len(d) - 1) / ((len(d) - 1) / 365.25), rel=1e-15)
    silent(r)
    silent(sim(d.iloc[:3], st))
    bad = simlev.SimLevResult(r)
    del bad["worth"]
    with pytest.raises(Exception):
        with contextlib.redirect_stderr(io.StringIO()):
            export_dashboard(bad, str(tmp_path / "x.pdf"))
    assert plt.get_fignums() == []


def test_flow_metrics_beschriftung():
    r = _dca()
    silent(r)
    silent(r, compare=r)
    sec = _stats_sections(r)
    assert sec["Rendite"][0].startswith("CAGR (geldgew.): ") and sec["Risiko"][0].startswith("Max. Drawdown (TWR): ")
