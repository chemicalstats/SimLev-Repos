"""Grafiken (SVG) der Python-Fassung, die es in R nicht gibt (R zeichnet mit Basisgrafik): Dashboards und der
SVG-Rahmen ``simlev.svg``, Trigger und Dashboards der Ergebnisse, die Grafiken der Analyse- und
Forschungsmodule mit ``SimLevPlot.data`` (wie die Julia-Fassung). Seit 1.4.1 zusammengeführt aus test_dashboard.py,
test_output.py, test_plot_analysis.py und test_plot_research.py (Inhalt wörtlich, Namen eindeutig gemacht).

Die Objekte der Analyse- und Forschungsgrafiken stammen aus Referenzfällen des Katalogs ``tests/<gruppe>/faelle``
(Python-Code der Fälle), damit Python und Julia dieselben Eingaben zeichnen.
"""
import contextlib
import html
import inspect
import io
import math
import os
import re
import subprocess
import sys
import warnings

import numpy as np
import pandas as pd
import pytest

import simlev
from simlev import asset_config, create_strategy, rebalance_trigger, simulation
from simlev import dashboard as dash_mod
from simlev import dca_plan  # Bausteine
from reftree import decode
from simlev._r.rformat import r_sprintf
from simlev.dashboard import (
    _correlation, _comparison_rows, _dash_custom_layout, _dashboard_returns, _format_amount, _monthly_matrix,
    _r_cor, _rolling_returns, _stats_sections, export_dashboard, plot_dashboard)
from simlev.svg import SimLevPlot, _check_svg_file, _plot_method, _warn_unknown_kw

import faelle
from _helpers import _dca, sim


_NS = {}   # Zwischenspeicher: Namensraum je Szenario bzw. Tabellenzeile, einmal je Testlauf gerechnet


def _ns(c):
    """Namensraum nach dem Python-Code des Falls ``c`` (Eingaben aus dem Katalog)."""
    ns = {"simlev": simlev, "np": np, "pd": pd, "math": math}
    for k, v in (c.get("inputs") or {}).items():
        ns[k] = decode(v)
    with warnings.catch_warnings(), contextlib.redirect_stdout(io.StringIO()), \
            contextlib.redirect_stderr(io.StringIO()):
        warnings.simplefilter("ignore")
        exec(c["py"], ns)  # noqa: S102 - Fälle stammen aus dem Repo
    return ns


def _obj(case, var="result"):
    """Objekt eines Referenzfalls (Python-Code des Falls, Eingaben aus dem Katalog).

    Ein Szenario wird je Testlauf nur einmal gerechnet (Schlüssel: Modul und Kennung des Szenarios; seine Teile
    teilen sich den Lauf); die Grafiktests lesen die Objekte nur, sie verändern sie nicht."""
    c = faelle.fall(case)
    key = (c.get("module"), c["id"])
    if key not in _NS:
        _NS[key] = _ns(c)
    ns = _NS[key]
    if c.get("_teil") and var == "result":   # Teil eines Szenarios
        return ns[var][c["_teil"]]
    return ns[var]


def _gleich(a, b):
    """Werte bitgleich (gleiche Länge, NaN-Bitmuster und Vorzeichen der Null eingeschlossen)."""
    a = np.asarray(a, dtype=np.float64).ravel()
    b = np.asarray(b, dtype=np.float64).ravel()
    return a.shape == b.shape and a.view(np.int64).tolist() == b.view(np.int64).tolist()


def _cols(p):
    return {k: list(df.columns) for k, df in p.data.items()}



# ══════════════════════════════════════════════════════════════════════════════════════════════════════════════
# Dashboards und SVG-Rahmen (bis 1.4.0 test_dashboard.py)
# ══════════════════════════════════════════════════════════════════════════════════════════════════════════════
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
            "assert 'matplotlib' not in sys.modules\n" % os.path.dirname(os.path.dirname(simlev.__file__)))
    res = subprocess.run([sys.executable, "-c", code], capture_output=True, text=True,
                         env=dict(os.environ, LC_ALL="C.UTF-8"))
    assert res.returncode == 0, res.stderr


# ══════════════════════════════════════════════════════════════════════════════════════════════════════════════
# Trigger und Dashboards der Ergebnisse (bis 1.4.0 test_output.py)
# ══════════════════════════════════════════════════════════════════════════════════════════════════════════════
def _df():
    return pd.DataFrame({
        "date": pd.date_range("2020-01-01", periods=10),
        "target_leverage": [2.00, 2.05, 2.30, 2.28, 1.95, 1.90, 2.40, 2.42, 2.10, 2.00],
        "sigma_ewma": [0.10, 0.11, 0.16, 0.15, 0.10, 0.10, 0.20, 0.22, 0.14, 0.12],
    })


def test_trigger_types_match_r_reference():
    # Referenzwerte aus dem R-Paket (rebal_trigger_cookbook.R)
    df = rebalance_trigger(_df(), "abs_leverage", threshold=10, out_col="a")
    df = rebalance_trigger(df, "rel_leverage", threshold=10, out_col="r")
    df = rebalance_trigger(df, "vol_band", threshold=20, out_col="v")
    df = rebalance_trigger(df, "combined", triggers=[{"type": "abs_leverage", "threshold": 10},
                                                         {"type": "vol_band", "threshold": 20}], out_col="c")
    T, F = True, False
    assert df["a"].tolist() == [F, F, T, F, T, F, T, F, T, T]
    assert df["r"].tolist() == [F, F, T, F, T, F, T, F, T, F]
    assert df["v"].tolist() == [F, F, T, F, T, F, T, F, T, F]
    assert df["c"].tolist() == [F, F, T, F, T, F, T, F, T, T]


def test_trigger_errors():
    with pytest.raises(ValueError, match="Unbekannter type"):
        rebalance_trigger(_df(), "nope")
    with pytest.raises(ValueError, match="fehlt"):
        rebalance_trigger(_df(), "abs_leverage", lev_col="xx")
    with pytest.raises(ValueError, match="nicht-leere"):
        rebalance_trigger(_df(), "combined")


def _result(n=120):
    d = pd.DataFrame({"date": pd.date_range("2022-01-03", periods=n), "A": np.linspace(100, 130, n),
                      "B": np.linspace(100, 110, n)})
    s = create_strategy(A=asset_config(asset_class="etf", trading="bnh", share=0.6, spread=0, partial_exemption=30), B=asset_config(asset_class="etf", trading="bnh", share=0.4, spread=0, partial_exemption=0))
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
        simlev.export_dashboard(r, filename=str(svg))
    assert svg.exists() and svg.stat().st_size > 1000
    with pytest.raises(ValueError, match="nur als SVG"):
        simlev.export_dashboard(r, filename=str(tmp_path / "x.pdf"))


# ══════════════════════════════════════════════════════════════════════════════════════════════════════════════
# Grafiken der Analysemodule (bis 1.4.0 test_plot_analysis.py)
# ══════════════════════════════════════════════════════════════════════════════════════════════════════════════
def _days(d):
    return np.asarray(d).astype("datetime64[D]").astype(np.int64).tolist()


DA = {"growth": ["series", "date", "growth"], "drawdown": ["series", "date", "drawdown"],
      "rolling": ["series", "date", "cagr"], "annual": ["year", "al", "raw"]}

# Klasse, Fall, plot-Argumente, erwartete Panels/Spalten, Texte im SVG
CASES_ANALYSE = [
    ("SimLevSignalAnalysis", "analysis_tests/sa_basic", {},
     {"bins": ["bin", "mean", "lower", "upper"], "scatter": ["signal", "forward", "fitted"]},
     ["Je Signalbereich", "Signalbereich (niedrig -&gt; hoch)", "Mittlere Vorwärtsrendite (%)", "Streudiagramm",
      "Vorwärtsrendite (%)", ">mom</text>", "stroke-dasharray=\"5,4\"", "<circle"]),
    ("SimLevSignalAnalysis", "analysis_tests/sa_binary", {}, {"bins": ["bin", "mean", "lower", "upper"],
                                                             "scatter": ["signal", "forward"]}, ["Je Signalbereich"]),
    ("SimLevHeatmap", "analysis_tests/hm_sim", {}, {"heatmap": ["start_year", "years", "value"]},
     ["Annualisierte reale Rendite", "Startjahr", "Haltedauer (Jahre)", "+25 %", "-25 %", "+0 %"]),
    ("SimLevHeatmap", "analysis_tests/hm_week_all", {}, {"heatmap": ["start_year", "years", "value"]},
     ["Annualisierte nominale Rendite"]),
    ("SimLevBackcastFit", "backcast/bf_basic", {}, {"deviation": ["date", "deviation"]},
     ["Pfadabweichung im Fit-Fenster", "Datum", "1 - Sim/Produkt (%)", "stroke-dasharray=\"5,4\""]),
    ("SimLevBackcastFit", "backcast/bf_grid", {}, {"deviation": ["date", "deviation"], "grid": ["value", "loss"]},
     ["Gittersuche", "drag (% p. a.)", ">rmse</text>", "stroke-dasharray=\"2,3\"", "height=\"720\""]),
    ("SimLevBackcast", "backcast/bc_fit", {}, {"backcast": ["date", "value", "model", "source"]},
     ["Backcast und Produkt", "Wert (log. Skala)", "Modell durchgehend", "#B5562B", "#2C6E9B", "#A6A6A6"]),
    ("SimLevBackcast", "backcast/bc_fit", {"log": False}, {"backcast": ["date", "value", "model", "source"]},
     [">Wert</text>"]),
    ("SimLevBootstrapStudy", "bootstrap/study_basic", {}, {"density": ["strategy", "x", "density"]},
     ["Verteilung cagr (stationary, 3 Pfade)", "Dichte", "<polyline"]),
    ("SimLevAnalysis", "deep_analysis/da_df_aligned", {}, DA,
     ["Wertentwicklung (TWR, Start = 1)", "Wachstum (log)", "Drawdowns", "Drawdown (%)", "Rollierend 1 J.: cagr",
      "cagr (%)", "Jahresrenditen", "Rendite (%)", "width=\"1100\" height=\"760\""]),
    ("SimLevAnalysis", "deep_analysis/da_df_aligned", {"type": "monthly", "series": 2},
     {"monthly": ["year", "month", "return"]}, ["Monatsrenditen: raw", "Mär", "Dez", "width=\"900\" height=\"520\""]),
    ("SimLevAnalysis", "deep_analysis/da_df_aligned", {"type": "rolling", "metric": "sharpe"},
     {"rolling": ["series", "date", "sharpe"]}, ["Rollierend 1 J.: sharpe", ">sharpe</text>"]),
    ("SimLevAnalysis", "deep_analysis/da_short_series", {"type": "rolling"},
     {"rolling": ["series", "date", "cagr"]}, ["Rollierend: Zeitraum zu kurz"]),
    ("SimLevDependence", "dependence/da_breaks", {},
     {"rolling": ["date", "rolling", "dcc"], "tail": ["q", "lower", "upper", "independence"],
      "conditional": ["regime", "pearson", "pearson_lo", "pearson_hi", "lambda_lower"], "scatter": ["u", "v"]},
     ["stocks ~ bonds: rollierend (20) und DCC", "Korrelation", "stocks ~ bonds: Tail-Abhängigkeit",
      "Quantil q (log)", "unten (gemeinsame Verluste)", "oben (gemeinsame Gewinne)", "Unabhängigkeit",
      "stocks ~ bonds nach 'inflation'", "Pseudo-Beobachtungen", "Rang stocks", "Rang bonds", "DCC"]),
    ("SimLevDependence", "dependence/da_basic", {"type": "conditional"},
     {"conditional": ["regime", "pearson", "lambda_lower"]}, []),
    ("SimLevDependence", "dependence/da_warn", {"type": "rolling"}, {"rolling": ["date", "rolling"]}, []),
    ("SimLevTailRegression", "dependence/treg_multi", {},
     {"inflation": ["quantile", "estimate", "lower", "upper"], "zins": ["quantile", "estimate", "lower", "upper"]},
     ["Effekt von inflation", "Effekt von zins", "Quantilsregression", "Koeffizient", "Quantil"]),
    ("SimLevCoVaR", "dependence/covar_basic", {}, {"delta_covar": ["asset", "date", "delta_covar"]},
     ["Delta-CoVaR für", "Delta-CoVaR (%)"]),
]


@pytest.mark.parametrize("cls,case,kw,cols,texts", CASES_ANALYSE,
                         ids=["%s-%s-%d" % (c[0], c[1].split("/")[1], i) for i, c in enumerate(CASES_ANALYSE)])
def test_plot_svg_and_data(cls, case, kw, cols, texts):
    x = _obj(case)
    with warnings.catch_warnings():
        warnings.simplefilter("error")             # keine Warnung bei gültigen Argumenten
        p = simlev.plot(x, **kw)
    assert isinstance(p, simlev.SimLevPlot)
    assert p.kind == cls and p.source is x
    assert p.svg.startswith("<svg") and p.svg.endswith("</svg>\n")
    assert _cols(p) == cols
    for t in texts:
        assert t in p.svg, t
    assert repr(p) == "SimLevPlot(%s, SVG, %d Bytes, Panels: %s)" % (cls, len(p.svg.encode("utf-8")), ", ".join(cols))


def test_signal_heatmap_values():
    x = _obj("analysis_tests/sa_basic")
    p = x.plot()
    b = x["bins"]
    se = b["sd"].to_numpy(dtype=float) / np.sqrt(b["n"].to_numpy(dtype=float))
    assert p.data["bins"]["bin"].tolist() == [str(v) for v in b["bin"]]
    assert _gleich(p.data["bins"]["mean"], b["mean"])                         # Anteil (gezeichnet in %)
    assert _gleich(p.data["bins"]["lower"], b["mean"].to_numpy(dtype=float) - 2 * se)
    assert _gleich(p.data["bins"]["upper"], b["mean"].to_numpy(dtype=float) + 2 * se)
    assert _gleich(p.data["scatter"]["signal"], x["data"]["signal"]) and _gleich(p.data["scatter"]["forward"], x["data"]["forward"])
    assert _gleich(p.data["scatter"]["fitted"], x["fit"]["model"]["fitted"])         # Feld seit 1.0.0 "fitted"
    assert p.svg.count("<circle") == len(x["data"])
    h = _obj("analysis_tests/hm_sim")
    d = h.plot().data["heatmap"]
    M = h["matrix"]
    ok = np.isfinite(M.to_numpy(dtype=float))
    assert d["start_year"].tolist() == [int(r) for r, row in zip(M.index, ok) for v in row if v]
    assert d["years"].tolist() == [j + 1 for row in ok for j, v in enumerate(row) if v]
    assert _gleich(d["value"], M.to_numpy(dtype=float)[ok])                    # zeilenweise, unbegrenzt
    assert d["start_year"].dtype == np.int64 and d["years"].dtype == np.int64


def test_backcast_values():
    f = _obj("backcast/bf_grid")
    p = f.plot()
    dev = f["diagnostics"]["deviation"]
    assert _days(p.data["deviation"]["date"]) == _days(dev["date"])
    assert _gleich(p.data["deviation"]["deviation"], dev["deviation"])         # Anteil (gezeichnet in %)
    assert _gleich(p.data["grid"]["value"], f["grid"]["value"]) and _gleich(p.data["grid"]["loss"], f["grid"]["loss"])
    q = f.plot(width=800, height=300)
    assert q.svg.startswith("<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"800\" height=\"600\"")
    b = _obj("backcast/bc_lead")
    d = b.plot().data["backcast"]
    ok = np.isfinite(b["value"].to_numpy(dtype=float))
    assert not ok.all() and len(d) == ok.sum()                               # nur gezeichnete Zeilen
    assert _gleich(d["value"], b["value"][ok]) and _gleich(d["model"], b["model"][ok])
    assert d["source"].tolist() == [str(v) for v in b["source"][ok]]
    assert _days(d["date"]) == _days(b["date"][ok])
    assert simlev.backcast.plot_SimLevBackcast(b).svg == b.plot().svg         # öffentliche Funktion = Methode


def test_bootstrap_study_values():
    import simlev._lib as sl    # Kerndichte seit 1.0.0 aus der C-Bibliothek (.sl_kde), nicht mehr simlev._r.stats
    x = _obj("bootstrap/study_basic")
    p = x.plot(metric="max_drawdown", width=700)
    d = p.data["density"]
    tab = x["results"]
    assert list(dict.fromkeys(d["strategy"])) == list(x["strategies"])
    for s in x["strategies"]:
        v = tab.loc[tab["strategy"] == s, "max_drawdown"].to_numpy(dtype=float)
        v = v[np.isfinite(v)]
        dens = sl.kde(v)
        gx, gy = np.asarray(dens["x"], dtype=float), np.asarray(dens["y"], dtype=float)
        allv = tab["max_drawdown"].to_numpy(dtype=float)
        keep = (gx >= np.nanmin(allv)) & (gx <= np.nanmax(allv))             # gezeichneter Bereich
        assert _gleich(d.loc[d["strategy"] == s, "x"], gx[keep]) and _gleich(d.loc[d["strategy"] == s, "density"], gy[keep])
    assert "Verteilung max_drawdown" in p.svg and 'width="700"' in p.svg
    y = _obj("bootstrap/study_print_paired")                                 # zu wenige Werte: Meldung wie R (.sl_kde)
    with pytest.raises(ValueError, match="bw.nrd0: mindestens 2 Werte nötig"):
        y.plot()


def test_deep_analysis_values():
    x = _obj("deep_analysis/da_df_aligned")
    p = x.plot()
    g = p.data["growth"]
    for k, s in x["series"].items():
        v = s["value"].to_numpy(dtype=float)
        assert _gleich(g.loc[g["series"] == k, "growth"], v / v[0])
        assert _days(g.loc[g["series"] == k, "date"]) == _days(s["date"])
        dd = p.data["drawdown"]
        assert _gleich(dd.loc[dd["series"] == k, "drawdown"], v / np.maximum.accumulate(v) - 1)   # Anteil
        r = x["rolling"][k]
        ro = p.data["rolling"]
        assert _gleich(ro.loc[ro["series"] == k, "cagr"], r["cagr"])
    A = x["annual"]
    assert p.data["annual"]["year"].tolist() == [int(v) for v in A.index]
    for c in A.columns:
        assert _gleich(p.data["annual"][c], A[c])                               # NaN bleibt (gezeichnet als 0)
    m = x.plot(type="monthly", series="al").data["monthly"]
    M = x["monthly"]["al"].iloc[:, :12].to_numpy(dtype=float)
    ok = np.isfinite(M)
    assert _gleich(m["return"], M[ok]) and m["month"].tolist() == [j + 1 for row in ok for j, v in enumerate(row) if v]
    assert m["year"].dtype == np.int64


def test_deep_analysis_errors_before_drawing():
    x = _obj("deep_analysis/da_df_aligned")
    with pytest.raises(ValueError, match=r"^series: Name oder Nummer einer Reihe \(al, raw\)\.$"):
        x.plot(type="monthly", series=3)
    with pytest.raises(ValueError, match=r"^metric: 'cagr', 'volatility', 'sharpe', 'max_drawdown', 'beta' oder "
                                         r"'excess_cagr'\.$"):
        x.plot(metric="x")
    with pytest.raises(ValueError, match="should be one of"):
        x.plot(type="xyz")


def test_dependence_values():
    x = _obj("dependence/da_breaks")
    p = x.plot()
    pn = x["pairs"]["pair"].iloc[0]
    assert _gleich(p.data["rolling"]["rolling"], x["rolling"][pn]) and _gleich(p.data["rolling"]["dcc"], x["dcc"]["correlation"][pn])
    assert _days(p.data["rolling"]["date"]) == _days(x["rolling"]["date"])
    qg = [0.01, 0.02, 0.03, 0.05, 0.075, 0.1, 0.15, 0.2, 0.3, 0.4, 0.5]
    td = simlev.dependence.tail_dependence(x["returns"]["stocks"], x["returns"]["bonds"], q=qg)
    assert _gleich(p.data["tail"]["q"], qg) and _gleich(p.data["tail"]["lower"], td["lower"])
    assert _gleich(p.data["tail"]["independence"], qg)
    ct = x["conditional"]["inflation"]
    ct = ct[ct["pair"] == pn]
    for c in ("pearson", "pearson_lo", "pearson_hi", "lambda_lower"):
        assert _gleich(p.data["conditional"][c], ct[c])
    assert _gleich(p.data["scatter"]["u"], simlev.dependence._pobs(x["returns"]["stocks"]))
    t = _obj("dependence/treg_multi")
    q = t.plot(width=600)
    cf = t["coefficients"]
    for dv in t["drivers"]:
        sel = cf["term"] == dv
        for c in ("quantile", "estimate", "lower", "upper"):
            assert _gleich(q.data[dv][c], cf.loc[sel, c])
    c = _obj("dependence/covar_basic")
    d = c.plot().data["delta_covar"]
    s = c["series"]
    for a in dict.fromkeys(s["asset"]):
        assert _gleich(d.loc[d["asset"] == a, "delta_covar"], s.loc[s["asset"] == a, "delta_covar"])   # % wie in series


def test_plot_api_warnings_and_files(tmp_path):
    x = _obj("deep_analysis/da_df_aligned")
    with warnings.catch_warnings(record=True) as wl:
        warnings.simplefilter("always")
        y = x.plot(type="growth", figsize=(3, 4))
    assert [str(m.message) for m in wl] == [
        "plot.SimLevAnalysis: unbekanntes Argument 'figsize' wird ignoriert (Tippfehler?)."]
    assert list(y.data) == ["growth"]
    with warnings.catch_warnings(record=True) as wl:
        warnings.simplefilter("always")
        _obj("analysis_tests/hm_sim").plot(width=3, ax=None)
    assert [str(m.message) for m in wl] == [
        "plot.SimLevHeatmap: unbekannte Argumente 'width', 'ax' werden ignoriert (Tippfehler?)."]
    with pytest.raises(ValueError, match=r"plot\.SimLevBackcast: Grafiken werden nur als SVG gespeichert; '.*b\.png' hat "
                                         r"die Endung '\.png'\."):
        _obj("backcast/bc_fit").plot(file=str(tmp_path / "b.png"))
    assert not (tmp_path / "b.png").exists()
    f = tmp_path / "d.svg"
    p = _obj("dependence/covar_basic").plot(file=str(f))
    assert f.read_text(encoding="utf-8") == p.svg
    assert simlev.bootstrap.plot(_obj("bootstrap/study_basic"), metric="sharpe").data["density"].shape[0] > 0
    with warnings.catch_warnings(record=True) as wl:
        warnings.simplefilter("always")
        p = _obj("dependence/treg_basic").plot(600, 300, 1)   # wie Julia: Optionen nur als Schlüsselwort
    assert [str(m.message) for m in wl] == ["plot.SimLevTailRegression: 3 zusätzliche(s) Positionsargument(e) "
                                            "wird/werden ignoriert; Optionen bitte als Schlüsselwort angeben."]
    assert p.svg == _obj("dependence/treg_basic").plot().svg


def test_julia_number_helpers():
    from simlev.svg import _jl_log10, _jl_pow, _jl_range, _jl_round, _jl_round_sig, _jl_str
    assert _jl_pow(10.0, -2.0) == 0.010000000000000002            # Julia: 10.0^-2.0 (pow_body)
    assert _jl_pow(10.0, -7.0) == 1.0000000000000001e-07
    assert _jl_str(1e6) == "1.0e6" and _jl_str(1e-5) == "1.0e-5" and _jl_str(0.0001) == "0.0001"
    assert _jl_str(360.0) == "360.0" and _jl_str(70) == "70" and _jl_str(-0.0) == "-0.0"
    assert _jl_round(2.675, 2) == 2.68 and round(2.675, 2) == 2.67       # Julia: round(x * 100) / 100
    assert _jl_str(_jl_round(12.345, 2)) == "12.34" and _jl_round_sig(123456.0, 3) == 123000.0
    assert _jl_range(-0.2, 0.05, 0.3)[3] == -0.05 and _jl_range(0.0, 0.1, 1.0)[3] == 0.3
    assert _jl_log10(1000.0) == 3.0


def test_no_matplotlib():
    for m in ("analysis_tests", "backcast", "bootstrap", "deep_analysis", "dependence"):
        src = open(os.path.join(os.path.dirname(simlev.__file__), m + ".py"), encoding="utf-8").read()
        assert "matplotlib" not in src, m


# ══════════════════════════════════════════════════════════════════════════════════════════════════════════════
# Grafiken der Forschungsmodule (bis 1.4.0 test_plot_research.py)
# ══════════════════════════════════════════════════════════════════════════════════════════════════════════════
Q = ["year", "q05", "q25", "q50", "q75", "q95"]

# Klasse, Fall, plot-Argumente, erwartete Panels/Spalten, Texte im SVG
CASES_FORSCHUNG = [
    ("SimLevOptimization", "optimize/po4_min_variance", {}, {"weights": ["asset", "weight", "risk_share"]},
     ["Gewichte und Risikoanteile (min_variance)", "Risikoanteil", ">%</text>"]),
    ("SimLevFrontier", "optimize/ef_default", {},
     {"frontier": ["volatility", "expected_return"], "assets": ["asset", "volatility", "expected_return"],
      "max_sharpe": ["volatility", "expected_return"]},
     ["Effizienzgrenze", "Volatilität (% p. a.)", "Rendite (% p. a., historisch)", "<polygon"]),
    ("SimLevPBO", "overfitting/pbo_sharpe", {}, {"logits": ["lambda"], "degradation": ["is_best", "oos_best"]},
     ["Logits (PBO ", "Leistungsabfall", "sharpe In-Sample (bester Punkt)", "Out-of-Sample", "Häufigkeit"]),
    ("SimLevWalkForward", "overfitting/wf_basic", {},
     {"growth": ["date", "walk_forward", "hindsight", "average"]},
     ["Walk-Forward Out-of-Sample", "Wachstum (log)", "Rückschau-Bester", "Durchschnitt"]),
    ("SimLevParamSearch", "param_search/ps_grid", {}, {"heatmap": ["x", "y", "value"]},
     ["sharpe (blau = hoch)"]),
    ("SimLevParamSearch", "param_search/ps_grid", {"params": ["n"]}, {"profile": ["x", "value"]},
     ["sharpe nach n"]),
    ("SimLevParamSearch", "param_search/ps_random:x", {}, {"scatter": ["x", "y", "value"]},
     ["sharpe (Farbe; blau = hoch)"]),
    ("SimLevGoalPlan", "planning/go_ex", {}, {"policy": ["period", "wealth", "choice", "candidate"]},
     ["Optimale Wahl je Zeit und Vermögen", "Vermögen (log10)", "Periode"]),
    ("SimLevHMM", "regimes/hmm_week", {}, {"filtered": ["date", "probability"]},
     ["Gefilterte Wahrscheinlichkeit des unruhigsten Zustands (Z2)", "P(Z2 | bis t)"]),
    ("SimLevSensitivity", "sensitivity/lvs_basic", {}, {"leverage": ["leverage", "value"]},
     ["cagr nach Hebel", "Hebel"]),
    ("SimLevSensitivity", "sensitivity/rs_bands", {}, {"variants": ["label", "value"]},
     ["Rebalancing-Varianten: cagr"]),
    ("SimLevWeights", "tactical/bl_basic", {}, {"weights": ["date", "A", "C", "B", "CASH"]},
     ["Zielgewichte", "Gewicht", "CASH"]),
    ("SimLevWithdrawal", "withdrawal/ws_constant", {}, {"wealth": Q, "spending": Q},
     ["Reales Vermögen", "Realer Konsum je Jahr", "Jahr"]),
    ("SimLevWithdrawal", "withdrawal/ws_gamma1", {}, {"spending": Q}, ["Realer Konsum je Jahr"]),
]


@pytest.mark.parametrize("cls,case,kw,cols,texts", CASES_FORSCHUNG, ids=["%s-%s" % (c[0], c[1].split("/")[1]) for c in CASES_FORSCHUNG])
def test_plot_forschung_svg_and_data(cls, case, kw, cols, texts):
    case, _, var = case.partition(":")
    x = _obj(case, var or "result")
    with warnings.catch_warnings():
        warnings.simplefilter("error")             # keine Warnung bei gültigen Argumenten
        p = simlev.plot(x, **kw)
    assert isinstance(p, simlev.SimLevPlot)
    assert p.kind == cls and p.source is x
    assert p.svg.startswith("<svg") and p.svg.endswith("</svg>\n")
    assert _cols(p) == cols
    for t in texts:
        assert t in p.svg, t
    assert repr(p).startswith("SimLevPlot(%s, SVG, %d Bytes, Panels: " % (cls, len(p.svg.encode("utf-8"))))


def test_optimization_frontier_values():
    x = _obj("optimize/po4_min_variance")
    d = x.plot().data["weights"]
    assert d["asset"].tolist() == [str(a) for a in x["risk"]["asset"]]
    assert _gleich(d["weight"], x["risk"]["weight"]) and _gleich(d["risk_share"], x["risk"]["risk_share"])
    assert "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"800\" height=\"500\"" in x.plot(width=800, height=500).svg
    f = _obj("optimize/ef_default")
    p = f.plot()
    assert _gleich(p.data["frontier"]["volatility"], f["frontier"]["volatility"])
    assert _gleich(p.data["assets"]["expected_return"], f["assets"]["expected_return"])
    k = int(np.nanargmax(f["frontier"]["sharpe"].to_numpy(dtype=float)))
    assert _gleich(p.data["max_sharpe"]["volatility"], [f["frontier"]["volatility"].iloc[k]])


def test_pbo_walk_forward_values():
    x = _obj("overfitting/pbo_sharpe")
    p = x.plot()
    lam = np.asarray(x["lambda"], dtype=float)
    assert _gleich(p.data["logits"]["lambda"], lam[np.isfinite(lam)])
    assert _gleich(p.data["degradation"]["is_best"], x["is_best"]) and _gleich(p.data["degradation"]["oos_best"], x["oos_best"])
    w = _obj("overfitting/wf_basic")
    g = w.plot().data["growth"]
    s = w["series"]
    assert (g["date"].to_numpy().astype("datetime64[D]") == np.asarray(s["date"]).astype("datetime64[D]")).all()
    for c in ("walk_forward", "hindsight", "average"):
        assert _gleich(g[c], s[c])


def test_param_search_values():
    x = _obj("param_search/ps_grid")
    tab = x["results"]
    h = x.plot().data["heatmap"]
    for _, r in h.iterrows():                         # Zelle = Maximum der endlichen Werte der Gruppe
        sel = (tab["n"] == r["x"]) & (tab["band"] == r["y"])
        v = tab.loc[sel, "sharpe"].to_numpy(dtype=float)
        assert r["value"] == np.max(v[np.isfinite(v)])
    pr = x.plot(params="n", metric="cagr", fun=min).data["profile"]
    assert pr["x"].tolist() == [10.0, 20.0, 40.0]
    assert pr["value"].tolist() == [tab.loc[tab["n"] == n, "cagr"].min() for n in (10.0, 20.0, 40.0)]
    assert "cagr nach n" in x.plot(params="n", metric="cagr").svg
    r = _obj("param_search/ps_random", "x")
    sc = r.plot().data["scatter"]
    assert _gleich(sc["x"], r["results"]["n"]) and _gleich(sc["y"], r["results"]["band"])
    assert _gleich(sc["value"], r["results"]["sharpe"])


def test_goalplan_hmm_values():
    x = _obj("planning/go_ex")
    d = x.plot().data["policy"]
    g = np.asarray(x["grid"], dtype=float)
    keep = (g >= x["goal"] / 20) & (g <= x["goal"] * 3)
    P = np.asarray(x["policy"])[:, keep]
    assert d["choice"].tolist() == P.ravel().tolist()            # Periode außen, Vermögen innen
    assert d["period"].tolist() == np.repeat(np.arange(1, x["horizon"] + 1), keep.sum()).tolist()
    assert _gleich(d["wealth"], np.tile(g[keep], x["horizon"]))
    assert d["candidate"].tolist() == [list(x["candidates"])[c - 1] for c in d["choice"]]
    assert d["choice"].dtype == np.int64 and d["period"].dtype == np.int64
    h = _obj("regimes/hmm_week")
    f = h.plot().data["filtered"]
    assert _gleich(f["probability"], np.asarray(h["filtered"], dtype=float)[:, int(h["k"]) - 1])
    assert pd.api.types.is_datetime64_any_dtype(f["date"])


def test_sensitivity_weights_values():
    x = _obj("sensitivity/lvs_basic")
    d = x.plot(metric="sharpe").data["leverage"]
    assert _gleich(d["leverage"], x["leverage"]) and _gleich(d["value"], x["sharpe"])      # unskaliert
    assert _gleich(x.plot().data["leverage"]["value"], x["cagr"])                        # Anteil, nicht ×100
    v = _obj("sensitivity/rs_bands").plot().data["variants"]
    assert any("±" in s for s in v["label"])
    w = _obj("tactical/bl_basic")
    d = w.plot(main="Mein Titel").data["weights"]
    for c in ("A", "C", "B", "CASH"):
        assert _gleich(d[c], w[c])
    assert "Mein Titel" in w.plot(main="Mein Titel").svg


def test_withdrawal_values():
    from simlev.bootstrap import _wquantile
    x = _obj("withdrawal/ws_constant")
    p = x.plot()
    W = np.asarray(x["wealth"], dtype=float)
    S = np.asarray(x["spending"], dtype=float)
    w = np.asarray(x["weights"], dtype=float)
    assert p.data["wealth"]["year"].tolist() == list(range(W.shape[0]))
    assert p.data["spending"]["year"].tolist() == list(range(1, S.shape[0] + 1))
    q = np.column_stack([_wquantile(S[i, :], w, np.array([0.05, 0.25, 0.5, 0.75, 0.95])) for i in range(S.shape[0])])
    for i, c in enumerate(Q[1:]):
        assert _gleich(p.data["spending"][c], q[i])                 # unskaliert (gezeichnet in Tausend)
    p2 = x.plot(probs=[0.1, 0.5, 0.9])
    assert list(p2.data["wealth"].columns) == ["year", "q10", "q50", "q90"]
    assert _gleich(p2.data["wealth"]["q50"], p.data["wealth"]["q50"])


def test_plot_forschung_api_warnings_and_files(tmp_path):
    x = _obj("withdrawal/ws_constant")
    with warnings.catch_warnings(record=True) as wl:
        warnings.simplefilter("always")
        y = x.plot(probz=1)
    assert [str(m.message) for m in wl] == [
        "plot.SimLevWithdrawal: unbekanntes Argument 'probz' wird ignoriert (Tippfehler?)."]
    assert isinstance(y, simlev.SimLevPlot) and list(y.data) == ["wealth", "spending"]
    with pytest.raises(ValueError, match=r"plot\.SimLevWithdrawal: Grafiken werden nur als SVG gespeichert; '.*w\.png' hat "
                                         r"die Endung '\.png'\."):
        x.plot(file=str(tmp_path / "w.png"))
    assert not (tmp_path / "w.png").exists()
    f = tmp_path / "w.svg"
    p = x.plot(file=str(f))
    assert f.read_text(encoding="utf-8") == p.svg
    h = _obj("regimes/hmm_week")
    with warnings.catch_warnings(record=True) as wl:              # wie R: data wird angenommen und nicht verwendet
        warnings.simplefilter("always")
        h.plot(data=None)
    assert [str(m.message) for m in wl] == []
    o = _obj("optimize/po4_min_variance")
    assert 'width="640"' in simlev.plot(o, width=640).svg
    with warnings.catch_warnings(record=True) as wl:               # wie Julia: Optionen nur als Schlüsselwort
        warnings.simplefilter("always")
        assert 'width="700"' in simlev.plot(o, 640).svg
    assert [str(m.message) for m in wl] == [
        "plot.SimLevOptimization: 1 zusätzliche(s) Positionsargument(e) wird/werden ignoriert; Optionen bitte als Schlüsselwort angeben."]
    with warnings.catch_warnings(record=True) as wl:
        warnings.simplefilter("always")
        _obj("overfitting/pbo_sharpe").plot(1)
    assert [str(m.message) for m in wl] == [
        "plot.SimLevPBO: 1 zusätzliche(s) Positionsargument(e) wird/werden ignoriert; Optionen bitte als Schlüsselwort angeben."]
