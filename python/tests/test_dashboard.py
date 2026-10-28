"""Port der Dashboard-Tests (test-review7-stats.R C7-08, R8-06, Layout, R9-04, R9-05;
test-blue-engine.R R1-19/R1-22; test-flow-metrics.R Punkt 2) sowie Tests des SVG-Rahmens
(``simlev.svg``: ``SimLevPlot``, ``_plot_method``, ``_check_svg_file``, ``_warn_unknown_kw``)."""
import contextlib
import html
import inspect
import io
import os
import re
import subprocess
import sys
import warnings

import numpy as np
import pandas as pd
import pytest

import simlev
from simlev import asset_config, create_strategy
from simlev import dashboard as dash_mod
from simlev._r.rformat import r_sprintf
from simlev.dashboard import (
    _correlation, _comparison_rows, _dash_custom_layout, _dashboard_returns, _format_amount, _monthly_matrix,
    _r_cor, _rolling_returns, _stats_sections, export_dashboard, plot_dashboard)
from simlev.svg import SimLevPlot, _check_svg_file, _plot_method, _warn_unknown_kw

from _helpers import sim
from simlev import dca_plan  # Bausteine (Etappe 6.3)
from test_tax_law import _dca

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
    return sim(d, create_strategy(ETF=asset_config(asset_class="etf", share=1)))


@pytest.fixture
def in_tmp(tmp_path, monkeypatch):
    """Im leeren Arbeitsordner zeichnen (prüft: ohne ``file`` wird nichts geschrieben)."""
    monkeypatch.chdir(tmp_path)
    return tmp_path


def silent(*a, **k):
    with warnings.catch_warnings(record=True) as wl:
        warnings.simplefilter("always")
        p = plot_dashboard(*a, **k)
    assert [str(w.message) for w in wl] == []
    assert isinstance(p, SimLevPlot) and p.svg.startswith("<svg") and p.svg.endswith("</svg>\n")
    return p


def texts(p):
    """Alle Textelemente des SVG (entschlüsselt)."""
    return {html.unescape(t) for t in re.findall(r"<text [^>]*>(.*?)</text>", p.svg)}


def caught(fn):
    with warnings.catch_warnings(record=True) as wl:
        warnings.simplefilter("always")
        out = fn()
    return out, [str(w.message) for w in wl]


class _PanelRecorder:
    """Merkt sich die Datenbereiche der Panels (Gegenstück zu ``ax.get_ylim()``)."""

    def __init__(self, monkeypatch):
        self.panels = []
        real = dash_mod._Panel

        def make(*a):
            p = real(*a)
            self.panels.append(p)
            return p
        monkeypatch.setattr(dash_mod, "_Panel", make)


def test_c7_08_panels_und_teilfarben(r500, in_tmp):
    r = r500
    with pytest.raises(ValueError, match=r'unbekannte\(s\) Panel\(s\) "perfromance", "drawdwon"'):
        plot_dashboard(r, style="custom", panels=["perfromance", "drawdwon"])
    with pytest.raises(ValueError, match='"xyz"'):
        plot_dashboard(r, style="custom", panels=["performance", "xyz"])
    p = silent(r, style="custom", panels=["perf", "draw", "performance"])
    assert list(p.data) == ["performance", "drawdown"]
    with pytest.warns(UserWarning, match='panels wirkt nur mit style = "custom"'):
        plot_dashboard(r, panels="performance")
    silent(r, style="compact")
    p = silent(r, colors={"primary": "#003366"})
    assert 'fill="#003366"' in p.svg and "#2E86AB" not in p.svg
    p = silent(r, colors=pd.Series({"primary": "#003366", "negative": "#AA0000"}))
    assert 'stroke="#AA0000"' in p.svg
    with pytest.raises(ValueError, match=r"unbekannte Farbe\(n\) 'primry'"):
        plot_dashboard(r, colors={"primry": "#003366"})
    with pytest.raises(ValueError, match="colors muss eine benannte Liste"):
        plot_dashboard(r, colors="#003366")
    with pytest.raises(ValueError, match="panels muss ein Zeichenvektor sein"):
        plot_dashboard(r, style="custom", panels=[])
    assert os.listdir(in_tmp) == []                 # kein stilles Schreiben


def test_r8_06_farbnamen_und_pruefung(r500):
    r = r500
    p = silent(r, colors={"primary": "navy"})
    assert 'fill="#000080"' in p.svg
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
    from simlev.svg import _alpha, _col2rgba, _svgcol, _svgop
    for cl in ("#2E86AB", "#D62246"):
        for a in (0x30, 0x40, 0x80):
            rgb = _col2rgba(cl)
            assert _alpha(cl, a) == approx(rgb[:3] + (a / 255,))
    assert _col2rgba("Navy Blue") == _col2rgba("navy") == approx((0, 0, 128 / 255, 1))
    assert _svgcol(_col2rgba("navy")) == "#000080" and _svgop(_alpha("navy", 0x80)) == "0.502"


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
    p = silent(r500, style="custom", panels=["performance", "drawdown", "distribution"])
    assert list(p.data) == ["performance", "drawdown", "distribution"]
    p = silent(r500, style="custom", panels=["performance", "drawdown", "distribution", "rolling", "monthly"])
    assert 'height="1000"' in p.svg                 # 3 Zeilen: Höhe 10/14 der Breite (2 Zeilen: 8/12)
    assert 'height="933"' in silent(r500, style="compact").svg
    p = silent(r500, style="custom", panels=["performance", "drawdown", "distribution", "rolling", "monthly",
                                             "stats", "correlation"], compare=r500)
    assert list(p.data) == ["performance", "drawdown", "distribution", "rolling", "monthly", "stats", "correlation"]
    assert p.svg.count('font-weight="bold" dominant-baseline="middle">Kennzahlen<') == 1


def test_performance_y_bereich_ueber_alle_kurven(monkeypatch):
    d = _series(7, 500, ETF=(100, 4e-4, 0.012), B=(100, -6e-4, 0.008), C=(100, -1e-3, 0.01))
    r = sim(d, create_strategy(ETF=asset_config(asset_class="etf", share=1)))
    r2 = sim(d, create_strategy(B=asset_config(asset_class="etf", share=1)))
    rl = sim(d, create_strategy(C=asset_config(asset_class="etf", share=1)), dca=dca_plan(value=500, span=1))
    inv = _dashboard_returns(rl)["invested"]
    assert inv.max() > rl.worth.max()

    def ylim(x, **k):
        rec = _PanelRecorder(monkeypatch)
        silent(x, style="custom", panels="performance", **k)
        p = rec.panels[0]
        lo, hi = p.ylo, p.yhi
        d4 = (hi - lo) / 1.08 * 0.04          # R: yaxs = "r" (4 % Rand)
        return lo + d4, hi - d4
    both = np.concatenate([r.worth, r2.worth])
    assert ylim(r, compare=r2) == approx((both.min(), both.max()))
    assert ylim(r2, compare=r) == approx((both.min(), both.max()))
    assert ylim(rl) == approx((min(rl.worth.min(), inv.min()), max(rl.worth.max(), inv.max())))
    assert ylim(r) == approx((r.worth.min(), r.worth.max()))


def test_raender_und_export(tmp_path):
    d = _series(7, 3 * 365, ETF=(100, 4e-4, 0.012), B=(100, 1e-4, 0.008))
    r = sim(d, create_strategy(ETF=asset_config(asset_class="etf", share=0.6), B=asset_config(asset_class="etf", share=0.4)),
            start_value=250000)
    r2 = sim(d, create_strategy(B=asset_config(asset_class="etf", share=1)), start_value=250000)
    silent(r, compare=r2)
    silent(r, style="compact")
    silent(r, style="custom", panels=["performance", "rolling", "monthly"])
    f = tmp_path / "d.svg"
    err = io.StringIO()
    with contextlib.redirect_stderr(err):
        assert export_dashboard(r, filename=str(f), compare=r2) is None
    assert f.exists() and err.getvalue() == "export_dashboard: Dashboard gespeichert in %s\n" % f
    svg = f.read_text(encoding="utf-8")
    assert svg.startswith('<svg xmlns="http://www.w3.org/2000/svg" width="1400" height="1000"')
    assert svg == plot_dashboard(r, compare=r2, width=1400, height=1000).svg
    with pytest.raises(ValueError, match=r"export_dashboard: Grafiken werden nur als SVG gespeichert; '.*d\.pdf' hat "
                                         r"die Endung '\.pdf'\. Bitte einen Dateinamen auf \.svg angeben"):
        export_dashboard(r, filename=str(tmp_path / "d.pdf"))
    assert not (tmp_path / "d.pdf").exists()
    with contextlib.redirect_stderr(io.StringIO()):
        simlev.export_dashboard(r, filename=str(tmp_path / "e.svg"), width=7, height=5)
    assert (tmp_path / "e.svg").read_text(encoding="utf-8").startswith(
        '<svg xmlns="http://www.w3.org/2000/svg" width="700" height="500"')
    assert sorted(os.listdir(tmp_path)) == ["d.svg", "e.svg"]


def test_strategievergleich_farben():
    d = _series(7, 3 * 365, ETF=(100, 4e-4, 0.012), B=(100, 1e-4, 0.008))
    r = sim(d, create_strategy(ETF=asset_config(asset_class="etf", share=0.6), B=asset_config(asset_class="etf", share=0.4)))
    r2 = sim(d, create_strategy(B=asset_config(asset_class="etf", share=1)))
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
    # die Differenzen erscheinen im SVG in ihrer Farbe
    p = silent(r, compare=r2)
    for z in _comparison_rows(r, r2):
        assert 'fill="%s" text-anchor="end" font-weight="bold" dominant-baseline="middle">%s</text>' % (
            z["diff_col"], z["diff"]) in p.svg


def test_betraege_startkapital_achsen(monkeypatch):
    d = _series(42, 365 * 4, start="2015-01-01", A=(100, 4e-4, 0.010))
    r = sim(d, create_strategy(A=asset_config(asset_class="etf", share=1)), start_value=10000)
    rec = _PanelRecorder(monkeypatch)
    p = silent(r, style="custom", panels=["performance", "stats"])
    tx = texts(p)
    fin = r.worth[-1]
    u = 1e6 if fin >= 1e6 else 1e3
    assert r_sprintf("Endwert: %.2f EUR", fin) in tx
    assert r_sprintf("Startkapital: %.2f EUR", r.invested[0]) in tx and r.invested[0] == 10000
    lab = r_sprintf("%.*f %s", 2 - int(np.floor(np.log10(fin / u))), fin / u, "Mio." if u == 1e6 else "Tsd.")
    assert lab in tx
    r_old = simlev.SimLevResult(r)
    del r_old["invested"]
    assert r_sprintf("Depotwert Starttag: %.2f EUR", r.worth[0]) in _stats_sections(r_old)["Depot"]
    # y-Achse der Wertentwicklung: Beschriftung (Tsd./Mio.) passt zur Lage der Marke
    pp = rec.panels[0]
    marks = re.findall(r'<text x="%.1f" y="([-0-9.]+)" font-size="10" fill="#495057" text-anchor="end" '
                       r'font-weight="normal" dominant-baseline="middle">([^<]*)</text>' % (pp.x0 - 6), p.svg)
    assert len(marks) >= 3
    for ypix, s in marks:
        t = pp.ylo + (pp.y0 + pp.h - float(ypix)) / pp.h * (pp.yhi - pp.ylo)
        mult = 1e6 if "Mio" in s else (1e3 if "Tsd" in s else 1)
        assert float(s.split(" ")[0]) * mult == approx(t, abs=0.06 / pp.h * (pp.yhi - pp.ylo))
    assert _format_amount([12500, 2.5e6, 999, 1234.5678], signif3=False) == ["12.5 Tsd.", "2.5 Mio.", "999",
                                                                             "1.235 Tsd."]
    assert _format_amount([18234.5, 250000, 1e6], signif3=True) == ["18.2 Tsd.", "250 Tsd.", "1.00 Mio."]


def test_r9_04_startkapital_ohne_sparrate():
    d = _series(42, 365 * 2, start="2015-01-01", W=(100, 4e-4, 0.010), B=(50, 1e-4, 0.003))
    r = sim(d, create_strategy(W=asset_config(asset_class="etf", share=0.7), B=asset_config(asset_class="etf", share=0.3)), start_value=10000, dca=dca_plan(value=250, span=1, unit="month"))
    assert r.invested[0] == 10250
    dep = _stats_sections(r)["Depot"]
    assert "Startkapital: 10000.00 EUR" in dep
    assert r_sprintf("Eingezahlt: %.2f EUR", r.invested[-1]) in dep


def test_r9_05_korrelation():
    d = _series(42, 365 * 3, start="2015-01-01", W=(100, 4e-4, 0.010), B=(50, 1e-4, 0.003))
    r1 = sim(d, create_strategy(W=asset_config(asset_class="etf", share=0.7), B=asset_config(asset_class="etf", share=0.3)))
    r2 = sim(d, create_strategy(B=asset_config(asset_class="etf", share=1)))
    p = silent(r1, compare=r2)
    a, b = _dashboard_returns(r1)["all_returns"], _dashboard_returns(r2)["all_returns"]
    rho = _r_cor(a, b)
    assert rho == approx(np.corrcoef(a, b)[0, 1], rel=1e-12)
    assert r_sprintf("Gesamt: %.2f", rho) in texts(p)
    assert "Rollierende Korrelation (252 Tage)" in texts(p)
    c = _correlation(r1, r2)
    assert c["k"] == 252 and c["rho"].size == len(a) - 251
    with pytest.warns(UserWarning, match=r'Panel\(s\) "correlation", "comparison" nicht gezeichnet: benötigen ein '
                                         r'Vergleichsergebnis \(compare\)'):
        p = plot_dashboard(r1, style="custom", panels=["performance", "correlation", "comparison"])
    assert list(p.data) == ["performance"]
    with pytest.warns(UserWarning, match='"comparison" nicht gezeichnet: benötigt'):
        p = plot_dashboard(r1, style="custom", panels="comparison")
    assert "Keine zeichenbaren Panels:" in texts(p) and "comparison ohne Vergleichsergebnis (compare)" in texts(p)
    assert p.data == {}
    silent(r1)
    with pytest.raises(ValueError, match="compare muss ein SimLevResult über dieselben Tage"):
        plot_dashboard(r1, compare=sim(d.iloc[:400], create_strategy(B=asset_config(asset_class="etf"))))
    with pytest.raises(ValueError, match="Objekt der Klasse 'list'"):
        plot_dashboard(r1, compare=[1, 2])


def test_r1_19_r1_22_kurze_reihen_und_export(tmp_path):
    d = _series(12, 3 * 365, start="2020-01-01", A=(100, 4e-4, 0.01))
    st = create_strategy(A=asset_config(asset_class="etf", share=1, spread=0))
    r = sim(d, st, dca=dca_plan(value=5000, span=1))
    dr = _dashboard_returns(r)
    assert np.std(dr["returns"], ddof=1) == approx(r.statistics["sd"], rel=1e-12)
    assert dr["returns"].max() < 0.1
    assert dr["ppy"] == approx((len(d) - 1) / ((len(d) - 1) / 365.25), rel=1e-15)
    silent(r)
    p = silent(sim(d.iloc[:3], st))
    assert "Zu wenige Daten" in texts(p)
    assert list(p.data["distribution"].columns) == ["return"] and len(p.data["distribution"]) == 0
    bad = simlev.SimLevResult(r)
    del bad["worth"]
    with pytest.raises(Exception):
        with contextlib.redirect_stderr(io.StringIO()):
            export_dashboard(bad, filename=str(tmp_path / "x.svg"))
    assert os.listdir(tmp_path) == []


def test_flow_metrics_beschriftung():
    r = _dca()
    p = silent(r)
    assert list(p.data["performance"].columns) == ["date", "strategy", "invested"]
    assert "Drawdown-Analyse (zeitgewichtet)" in texts(p) and "Einzahlungen" in texts(p)
    p = silent(r, compare=r)
    assert list(p.data["performance"].columns) == ["date", "strategy", "compare", "invested"]
    assert p.data["comparison"]["label"].tolist() == ["CAGR (MWR)", "Max. DD (TWR)", "Volatilität", "Sharpe"]
    sec = _stats_sections(r)
    assert sec["Rendite"][0].startswith("CAGR (geldgew.): ") and sec["Risiko"][0].startswith("Max. Drawdown (TWR): ")


# ── data: Schlüssel, Spalten und Werte ──────────────────────────────────────
_COLS = {"performance": ["date", "strategy"], "drawdown": ["date", "drawdown"], "distribution": ["return"],
         "rolling": ["date", "return_pct"], "monthly": ["year", "month", "return_pct"],
         "stats": ["section", "label", "value"], "correlation": ["date", "correlation"],
         "comparison": ["label", "value", "compare", "diff"]}


def _same(a, b):
    a, b = np.asarray(a, dtype=float), np.asarray(b, dtype=float)
    assert a.shape == b.shape
    assert np.array_equal(a.view(np.int64), b.view(np.int64))       # bitgleich


def test_data_schluessel_spalten_werte():
    d = _series(42, 365 * 3, start="2015-01-01", W=(100, 4e-4, 0.010), B=(50, 1e-4, 0.003))
    r1 = sim(d, create_strategy(W=asset_config(asset_class="etf", share=0.7), B=asset_config(asset_class="etf", share=0.3)))
    r2 = sim(d, create_strategy(B=asset_config(asset_class="etf", share=1)))
    p = silent(r1)
    assert list(p.data) == ["performance", "drawdown", "distribution", "rolling", "monthly", "stats"]
    p = silent(r1, compare=r2)
    assert p.kind == "SimLevResult" and p.source is r1
    assert list(p.data) == ["performance", "drawdown", "distribution", "rolling", "monthly", "stats", "correlation",
                            "comparison"]
    for k, df in p.data.items():
        assert isinstance(df, pd.DataFrame)
        assert list(df.columns) == (_COLS[k] + ["compare"] if k == "performance" else _COLS[k])
    dt = p.data
    dates = np.asarray(r1.dates).astype("datetime64[D]")
    assert np.array_equal(dt["performance"]["date"].values.astype("datetime64[D]"), dates)
    _same(dt["performance"]["strategy"], r1.worth)
    _same(dt["performance"]["compare"], r2.worth)
    _same(dt["drawdown"]["drawdown"], r1.drawdowns)
    _same(dt["distribution"]["return"], _dashboard_returns(r1)["returns"])
    rr = _rolling_returns(r1)
    _same(dt["rolling"]["return_pct"], rr["values"])
    assert np.array_equal(dt["rolling"]["date"].values.astype("datetime64[D]"), dates[rr["idx"]])
    years, mat = _monthly_matrix(r1)
    ok = ~np.isnan(mat)
    _same(dt["monthly"]["return_pct"], mat[ok])
    assert dt["monthly"]["year"].tolist() == [int(years[i]) for i, j in zip(*np.nonzero(ok))]
    assert dt["monthly"]["month"].tolist() == [int(j) + 1 for i, j in zip(*np.nonzero(ok))]
    secs = _stats_sections(r1, r2)
    st = dt["stats"]
    assert st["section"].tolist() == [s for s, ls in secs.items() for _ in ls]
    assert [a + ": " + b for a, b in zip(st["label"], st["value"])] == [v for ls in secs.values() for v in ls]
    c = _correlation(r1, r2)
    _same(dt["correlation"]["correlation"], c["rho"])
    assert np.array_equal(dt["correlation"]["date"].values.astype("datetime64[D]"), c["dates"])
    rows = _comparison_rows(r1, r2)
    assert dt["comparison"].to_dict("list") == {"label": [z["metric"] for z in rows], "value": [z["v1"] for z in rows],
                                                "compare": [z["v2"] for z in rows], "diff": [z["diff"] for z in rows]}
    # leere Panels: Tabelle mit Spalten, ohne Zeilen
    p = silent(sim(d.iloc[:30], create_strategy(B=asset_config(asset_class="etf"))),
               compare=sim(d.iloc[:30], create_strategy(W=asset_config(asset_class="etf"))))
    assert len(p.data["correlation"]) == 0 and list(p.data["correlation"].columns) == ["date", "correlation"]
    assert "Rollierende Korrelation" in texts(p)


# ── Rahmen: SimLevPlot, plot-Methode, Dateien, Warnungen ────────────────────
def test_simlevplot_objekt(r500, tmp_path):
    p = r500.plot(style="compact")
    assert isinstance(p, SimLevPlot) and isinstance(p, simlev.SimLevPlot)
    assert p.kind == "SimLevResult" and p.source is r500
    assert p._repr_svg_() is p.svg
    assert repr(p) == "SimLevPlot(SimLevResult, SVG, %d Bytes, Panels: performance, drawdown, distribution, stats)" \
        % len(p.svg.encode("utf-8"))
    assert repr(SimLevPlot("<svg/>", {}, None, "X")) == "SimLevPlot(X, SVG, 6 Bytes)"
    p.save(str(tmp_path / "a.svg"))
    assert (tmp_path / "a.svg").read_text(encoding="utf-8") == p.svg
    with pytest.raises(ValueError) as e:
        p.save(str(tmp_path / "a.png"))
    assert str(e.value) == ("SimLevPlot.save: Grafiken werden nur als SVG gespeichert; '%s' hat die Endung '.png'. "
                            "Bitte einen Dateinamen auf .svg angeben (z. B. \"dashboard.svg\")." % (tmp_path / "a.png"))
    with pytest.raises(ValueError, match="'a' hat keine Dateiendung"):
        _check_svg_file("a", "f")
    with pytest.raises(ValueError, match="f: file muss ein Dateiname \\(Zeichenkette\\) sein, nicht int."):
        _check_svg_file(3, "f")
    assert _check_svg_file("A.SVG", "f") == "A.SVG"


def test_plot_methode_datei_und_warnungen(r500, in_tmp):
    r = r500
    p, ws = caught(lambda: r.plot(style="compact", colour="red"))
    assert isinstance(p, SimLevPlot)
    assert ws == ["plot.SimLevResult: unbekanntes Argument 'colour' wird ignoriert (Tippfehler?)."]
    _, ws = caught(lambda: simlev.plot(r, style="compact", colour="red", widht=3))
    assert ws == ["plot.SimLevResult: unbekannte Argumente 'colour', 'widht' werden ignoriert (Tippfehler?)."]
    assert os.listdir(in_tmp) == []                       # kein stilles Schreiben
    assert isinstance(r.plot(file="a.svg"), SimLevPlot) and os.path.isfile("a.svg")
    with pytest.raises(ValueError, match="plot.SimLevResult: Grafiken werden nur als SVG gespeichert; 'a.png' hat "
                                         "die Endung '.png'"):
        r.plot(file="a.png")
    assert not os.path.exists("a.png")
    assert isinstance(plot_dashboard(r, file="b.svg"), SimLevPlot) and os.path.isfile("b.svg")
    with pytest.raises(ValueError, match="plot_dashboard: Grafiken werden nur als SVG"):
        plot_dashboard(r, file="b.pdf")
    _, ws = caught(lambda: plot_dashboard(r, widht=3))
    assert ws == ["plot_dashboard: unbekanntes Argument 'widht' wird ignoriert (Tippfehler?)."]
    # Optionen nur als Schlüsselwort (wie Julia): jedes Positionsargument → Warnung, wird ignoriert
    p, ws = caught(lambda: r.plot(style="compact"))
    assert ws == [] and list(p.data) == ["performance", "drawdown", "distribution", "stats"]
    p, ws = caught(lambda: r.plot("compact"))
    assert ws == ["plot.SimLevResult: 1 zusätzliche(s) Positionsargument(e) wird/werden ignoriert; Optionen bitte als "
                  "Schlüsselwort angeben."] and p.svg == r.plot().svg
    _, ws = caught(lambda: r.plot("custom", ["performance"], None, None, 900, 400, 7, 8))
    assert ws == ["plot.SimLevResult: 8 zusätzliche(s) Positionsargument(e) wird/werden ignoriert; Optionen bitte als "
                  "Schlüsselwort angeben."]
    p = r.plot(width=900, height=400)
    assert p.svg.startswith('<svg xmlns="http://www.w3.org/2000/svg" width="900" height="400" viewBox="0 0 900 400"')
    assert sorted(os.listdir(in_tmp)) == ["a.svg", "b.svg"]
    assert "file" in inspect.signature(r.plot).parameters and "style" in inspect.signature(simlev.SimLevResult.plot).parameters


def test_plot_method_rahmen(in_tmp):
    import warnings as _w

    def f_data(x, a=1, width=100):
        return "<svg>%s %s</svg>" % (a, width), {"wealth": pd.DataFrame({"year": [1, 2], "q50": [x, x]}),
                                                 "spending": {"year": [1], "value": [2.0]}}

    def f_str(x, file=None, **kw):
        assert file is None
        return "<svg/>"

    def f_obj(x):
        return SimLevPlot("<svg>o</svg>", {"a": pd.DataFrame({"v": [1]})})

    def f_bad(x):
        return 42
    m = _plot_method(f_data, "Dummy")
    p, ws = caught(lambda: m(3.0, a=5, file="d.svg", b=1))
    assert ws == ["plot.Dummy: unbekanntes Argument 'b' wird ignoriert (Tippfehler?)."]
    assert p.svg == "<svg>5 100</svg>" and p.kind == "Dummy" and p.source == 3.0
    assert list(p.data) == ["wealth", "spending"] and all(isinstance(v, pd.DataFrame) for v in p.data.values())
    assert open("d.svg", encoding="utf-8").read() == p.svg
    assert repr(p) == "SimLevPlot(Dummy, SVG, 16 Bytes, Panels: wealth, spending)"
    p, ws = caught(lambda: m(1, 2, a=3))
    assert ws == ["plot.Dummy: 1 zusätzliche(s) Positionsargument(e) wird/werden ignoriert; Optionen bitte als "
                  "Schlüsselwort angeben."] and p.svg == "<svg>3 100</svg>"
    assert [q.kind for q in inspect.signature(m).parameters.values()][1:] == [inspect.Parameter.KEYWORD_ONLY] * 3
    p, ws = caught(lambda: _plot_method(f_str, "S")(object(), 1, typo=2))
    assert p.svg == "<svg/>" and p.data == {} and p.kind == "S"
    assert ws == ["plot.S: 1 zusätzliche(s) Positionsargument(e) wird/werden ignoriert; Optionen bitte als "
                  "Schlüsselwort angeben.", "plot.S: unbekanntes Argument 'typo' wird ignoriert (Tippfehler?)."]
    p = _plot_method(f_obj, "O")("src")
    assert p.svg == "<svg>o</svg>" and list(p.data) == ["a"] and p.source == "src" and p.kind == "O"
    with pytest.raises(ValueError, match="plot.B: die Grafikmethode lieferte kein SVG \\(sondern int\\)."):
        _plot_method(f_bad, "B")(1)
    with pytest.raises(ValueError, match="plot.Dummy: Grafiken werden nur als SVG"):
        m(1, file="x.png")
    with _w.catch_warnings(record=True) as wl:
        _w.simplefilter("always")
        _warn_unknown_kw("w", [])
    assert wl == []
    assert sorted(os.listdir(in_tmp)) == ["d.svg"]


def test_dashboard_ohne_matplotlib():
    code = ("import sys; sys.path.insert(0, %r)\n"
            "import numpy as np, pandas as pd, simlev\n"
            "d = pd.DataFrame({'date': pd.date_range('2022-01-03', periods=200), 'A': np.linspace(100, 130, 200)})\n"
            "r = simlev.simulation(d, simlev.create_strategy(A=simlev.asset_config(asset_class='etf', share=1)))\n"
            "p = r.plot(compare=r); simlev.plot(r)\n"
            "assert 'matplotlib' not in sys.modules\n" % os.path.join(os.path.dirname(__file__), ".."))
    res = subprocess.run([sys.executable, "-c", code], capture_output=True, text=True,
                         env=dict(os.environ, LC_ALL="C.UTF-8"))
    assert res.returncode == 0, res.stderr
