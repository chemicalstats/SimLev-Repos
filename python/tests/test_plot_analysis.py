"""Grafiken der Analysemodule als SVG mit ``SimLevPlot.data`` (wie die Julia-Fassung).

Klassen: SimLevSignalAnalysis, SimLevHeatmap (analysis_tests), SimLevBackcastFit,
SimLevBackcast (backcast), SimLevBootstrapStudy (bootstrap), SimLevAnalysis
(deep_analysis), SimLevDependence, SimLevTailRegression, SimLevCoVaR (dependence).
Die Objekte stammen aus den Referenzfällen unter ``golden/modules`` (Python-Code
der Fälle), damit Python und Julia dieselben Eingaben zeichnen.
"""
import contextlib
import io
import math
import os
import warnings

import numpy as np
import pandas as pd
import pytest

import simlev
from simlev._r import env as _env
from simlev._r.reftree import decode, load_case

ROOT = _env.module_dir() or os.path.join(
    os.path.dirname(__file__), "..", "..", "golden", "modules")
pytestmark = pytest.mark.skipif(not os.path.isdir(ROOT), reason="Referenzfälle golden/modules fehlen")

_CACHE = {}


def _obj(case):
    if case not in _CACHE:
        c = load_case(os.path.join(ROOT, case + ".json.gz"))
        ns = {"simlev": simlev, "np": np, "pd": pd, "math": math}
        for k, v in (c.get("inputs") or {}).items():
            ns[k] = decode(v)
        with warnings.catch_warnings(), contextlib.redirect_stdout(io.StringIO()), \
                contextlib.redirect_stderr(io.StringIO()):
            warnings.simplefilter("ignore")
            exec(c["py"], ns)  # noqa: S102 - Fälle stammen aus dem Repo
        _CACHE[case] = ns["result"]
    return _CACHE[case]


def _same(a, b):
    """Werte bitgleich (gleiche Länge, NaN-Bitmuster und Vorzeichen der Null eingeschlossen)."""
    a = np.asarray(a, dtype=np.float64).ravel()
    b = np.asarray(b, dtype=np.float64).ravel()
    return a.shape == b.shape and a.view(np.int64).tolist() == b.view(np.int64).tolist()


def _days(d):
    return np.asarray(d).astype("datetime64[D]").astype(np.int64).tolist()


def _cols(p):
    return {k: list(df.columns) for k, df in p.data.items()}


DA = {"growth": ["series", "date", "growth"], "drawdown": ["series", "date", "drawdown"],
      "rolling": ["series", "date", "cagr"], "annual": ["year", "al", "raw"]}

# Klasse, Fall, plot-Argumente, erwartete Panels/Spalten, Texte im SVG
CASES = [
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


@pytest.mark.parametrize("cls,case,kw,cols,texts", CASES,
                         ids=["%s-%s-%d" % (c[0], c[1].split("/")[1], i) for i, c in enumerate(CASES)])
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
    assert _same(p.data["bins"]["mean"], b["mean"])                         # Anteil (gezeichnet in %)
    assert _same(p.data["bins"]["lower"], b["mean"].to_numpy(dtype=float) - 2 * se)
    assert _same(p.data["bins"]["upper"], b["mean"].to_numpy(dtype=float) + 2 * se)
    assert _same(p.data["scatter"]["signal"], x["data"]["signal"]) and _same(p.data["scatter"]["forward"], x["data"]["forward"])
    assert _same(p.data["scatter"]["fitted"], x["fit"]["model"]["fitted.values"])
    assert p.svg.count("<circle") == len(x["data"])
    h = _obj("analysis_tests/hm_sim")
    d = h.plot().data["heatmap"]
    M = h["matrix"]
    ok = np.isfinite(M.to_numpy(dtype=float))
    assert d["start_year"].tolist() == [int(r) for r, row in zip(M.index, ok) for v in row if v]
    assert d["years"].tolist() == [j + 1 for row in ok for j, v in enumerate(row) if v]
    assert _same(d["value"], M.to_numpy(dtype=float)[ok])                    # zeilenweise, unbegrenzt
    assert d["start_year"].dtype == np.int64 and d["years"].dtype == np.int64


def test_backcast_values():
    f = _obj("backcast/bf_grid")
    p = f.plot()
    dev = f["diagnostics"]["deviation"]
    assert _days(p.data["deviation"]["date"]) == _days(dev["date"])
    assert _same(p.data["deviation"]["deviation"], dev["deviation"])         # Anteil (gezeichnet in %)
    assert _same(p.data["grid"]["value"], f["grid"]["value"]) and _same(p.data["grid"]["loss"], f["grid"]["loss"])
    q = f.plot(width=800, height=300)
    assert q.svg.startswith("<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"800\" height=\"600\"")
    b = _obj("backcast/bc_lead")
    d = b.plot().data["backcast"]
    ok = np.isfinite(b["value"].to_numpy(dtype=float))
    assert not ok.all() and len(d) == ok.sum()                               # nur gezeichnete Zeilen
    assert _same(d["value"], b["value"][ok]) and _same(d["model"], b["model"][ok])
    assert d["source"].tolist() == [str(v) for v in b["source"][ok]]
    assert _days(d["date"]) == _days(b["date"][ok])
    assert simlev.backcast.plot_SimLevBackcast(b).svg == b.plot().svg         # öffentliche Funktion = Methode


def test_bootstrap_study_values():
    from simlev._r import stats as rstats
    x = _obj("bootstrap/study_basic")
    p = x.plot(metric="max_drawdown", width=700)
    d = p.data["density"]
    tab = x["results"]
    assert list(dict.fromkeys(d["strategy"])) == list(x["strategies"])
    for s in x["strategies"]:
        v = tab.loc[tab["strategy"] == s, "max_drawdown"].to_numpy(dtype=float)
        v = v[np.isfinite(v)]
        dens = rstats.density(v)
        gx, gy = np.asarray(dens["x"], dtype=float), np.asarray(dens["y"], dtype=float)
        allv = tab["max_drawdown"].to_numpy(dtype=float)
        keep = (gx >= np.nanmin(allv)) & (gx <= np.nanmax(allv))             # gezeichneter Bereich
        assert _same(d.loc[d["strategy"] == s, "x"], gx[keep]) and _same(d.loc[d["strategy"] == s, "density"], gy[keep])
    assert "Verteilung max_drawdown" in p.svg and 'width="700"' in p.svg
    y = _obj("bootstrap/study_print_paired")                                 # zu wenige Werte: Meldung wie R's density()
    with pytest.raises(ValueError, match="need at least 2 points to select a bandwidth automatically"):
        y.plot()


def test_deep_analysis_values():
    x = _obj("deep_analysis/da_df_aligned")
    p = x.plot()
    g = p.data["growth"]
    for k, s in x["series"].items():
        v = s["value"].to_numpy(dtype=float)
        assert _same(g.loc[g["series"] == k, "growth"], v / v[0])
        assert _days(g.loc[g["series"] == k, "date"]) == _days(s["date"])
        dd = p.data["drawdown"]
        assert _same(dd.loc[dd["series"] == k, "drawdown"], v / np.maximum.accumulate(v) - 1)   # Anteil
        r = x["rolling"][k]
        ro = p.data["rolling"]
        assert _same(ro.loc[ro["series"] == k, "cagr"], r["cagr"])
    A = x["annual"]
    assert p.data["annual"]["year"].tolist() == [int(v) for v in A.index]
    for c in A.columns:
        assert _same(p.data["annual"][c], A[c])                               # NaN bleibt (gezeichnet als 0)
    m = x.plot(type="monthly", series="al").data["monthly"]
    M = x["monthly"]["al"].iloc[:, :12].to_numpy(dtype=float)
    ok = np.isfinite(M)
    assert _same(m["return"], M[ok]) and m["month"].tolist() == [j + 1 for row in ok for j, v in enumerate(row) if v]
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
    assert _same(p.data["rolling"]["rolling"], x["rolling"][pn]) and _same(p.data["rolling"]["dcc"], x["dcc"]["correlation"][pn])
    assert _days(p.data["rolling"]["date"]) == _days(x["rolling"]["date"])
    qg = [0.01, 0.02, 0.03, 0.05, 0.075, 0.1, 0.15, 0.2, 0.3, 0.4, 0.5]
    td = simlev.dependence.tail_dependence(x["returns"]["stocks"], x["returns"]["bonds"], qg)
    assert _same(p.data["tail"]["q"], qg) and _same(p.data["tail"]["lower"], td["lower"])
    assert _same(p.data["tail"]["independence"], qg)
    ct = x["conditional"]["inflation"]
    ct = ct[ct["pair"] == pn]
    for c in ("pearson", "pearson_lo", "pearson_hi", "lambda_lower"):
        assert _same(p.data["conditional"][c], ct[c])
    assert _same(p.data["scatter"]["u"], simlev.dependence._pobs(x["returns"]["stocks"]))
    t = _obj("dependence/treg_multi")
    q = t.plot(width=600)
    cf = t["coefficients"]
    for dv in t["drivers"]:
        sel = cf["term"] == dv
        for c in ("quantile", "estimate", "lower", "upper"):
            assert _same(q.data[dv][c], cf.loc[sel, c])
    c = _obj("dependence/covar_basic")
    d = c.plot().data["delta_covar"]
    s = c["series"]
    for a in dict.fromkeys(s["asset"]):
        assert _same(d.loc[d["asset"] == a, "delta_covar"], s.loc[s["asset"] == a, "delta_covar"])   # % wie in series


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
