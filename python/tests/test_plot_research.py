"""Grafiken der Erweiterungsmodule als SVG mit ``SimLevPlot.data`` (wie die Julia-Fassung).

Klassen: SimLevOptimization, SimLevFrontier, SimLevPBO, SimLevWalkForward,
SimLevParamSearch, SimLevGoalPlan, SimLevHMM, SimLevSensitivity, SimLevWeights,
SimLevWithdrawal. Die Objekte stammen aus den Referenzfällen unter
``golden/modules`` (Python-Code der Fälle), damit Python und Julia dieselben
Eingaben zeichnen.
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
from simlev._r.reftree import decode, load_case

ROOT = os.environ.get("SIMLEV_MODULE_DIR") or os.path.join(
    os.path.dirname(__file__), "..", "..", "golden", "modules")
pytestmark = pytest.mark.skipif(not os.path.isdir(ROOT), reason="Referenzfälle golden/modules fehlen")


def _obj(case, var="result"):
    c = load_case(os.path.join(ROOT, case + ".json.gz"))
    ns = {"simlev": simlev, "np": np, "pd": pd, "math": math}
    for k, v in (c.get("inputs") or {}).items():
        ns[k] = decode(v)
    with warnings.catch_warnings(), contextlib.redirect_stdout(io.StringIO()), \
            contextlib.redirect_stderr(io.StringIO()):
        warnings.simplefilter("ignore")
        exec(c["py"], ns)  # noqa: S102 - Fälle stammen aus dem Repo
    return ns[var]


def _same(a, b):
    """Werte bitgleich (gleiche Länge, NaN-Bitmuster und Vorzeichen der Null eingeschlossen)."""
    a = np.asarray(a, dtype=np.float64).ravel()
    b = np.asarray(b, dtype=np.float64).ravel()
    return a.shape == b.shape and a.view(np.int64).tolist() == b.view(np.int64).tolist()


def _cols(p):
    return {k: list(df.columns) for k, df in p.data.items()}


Q = ["year", "q05", "q25", "q50", "q75", "q95"]

# Klasse, Fall, plot-Argumente, erwartete Panels/Spalten, Texte im SVG
CASES = [
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


@pytest.mark.parametrize("cls,case,kw,cols,texts", CASES, ids=["%s-%s" % (c[0], c[1].split("/")[1]) for c in CASES])
def test_plot_svg_and_data(cls, case, kw, cols, texts):
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
    assert _same(d["weight"], x["risk"]["weight"]) and _same(d["risk_share"], x["risk"]["risk_share"])
    assert "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"800\" height=\"500\"" in x.plot(width=800, height=500).svg
    f = _obj("optimize/ef_default")
    p = f.plot()
    assert _same(p.data["frontier"]["volatility"], f["frontier"]["volatility"])
    assert _same(p.data["assets"]["expected_return"], f["assets"]["expected_return"])
    k = int(np.nanargmax(f["frontier"]["sharpe"].to_numpy(dtype=float)))
    assert _same(p.data["max_sharpe"]["volatility"], [f["frontier"]["volatility"].iloc[k]])


def test_pbo_walk_forward_values():
    x = _obj("overfitting/pbo_sharpe")
    p = x.plot()
    lam = np.asarray(x["lambda"], dtype=float)
    assert _same(p.data["logits"]["lambda"], lam[np.isfinite(lam)])
    assert _same(p.data["degradation"]["is_best"], x["is_best"]) and _same(p.data["degradation"]["oos_best"], x["oos_best"])
    w = _obj("overfitting/wf_basic")
    g = w.plot().data["growth"]
    s = w["series"]
    assert (g["date"].to_numpy().astype("datetime64[D]") == np.asarray(s["date"]).astype("datetime64[D]")).all()
    for c in ("walk_forward", "hindsight", "average"):
        assert _same(g[c], s[c])


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
    assert _same(sc["x"], r["results"]["n"]) and _same(sc["y"], r["results"]["band"])
    assert _same(sc["value"], r["results"]["sharpe"])


def test_goalplan_hmm_values():
    x = _obj("planning/go_ex")
    d = x.plot().data["policy"]
    g = np.asarray(x["grid"], dtype=float)
    keep = (g >= x["goal"] / 20) & (g <= x["goal"] * 3)
    P = np.asarray(x["policy"])[:, keep]
    assert d["choice"].tolist() == P.ravel().tolist()            # Periode außen, Vermögen innen
    assert d["period"].tolist() == np.repeat(np.arange(1, x["horizon"] + 1), keep.sum()).tolist()
    assert _same(d["wealth"], np.tile(g[keep], x["horizon"]))
    assert d["candidate"].tolist() == [list(x["candidates"])[c - 1] for c in d["choice"]]
    assert d["choice"].dtype == np.int64 and d["period"].dtype == np.int64
    h = _obj("regimes/hmm_week")
    f = h.plot().data["filtered"]
    assert _same(f["probability"], np.asarray(h["filtered"], dtype=float)[:, int(h["k"]) - 1])
    assert pd.api.types.is_datetime64_any_dtype(f["date"])


def test_sensitivity_weights_values():
    x = _obj("sensitivity/lvs_basic")
    d = x.plot(metric="sharpe").data["leverage"]
    assert _same(d["leverage"], x["leverage"]) and _same(d["value"], x["sharpe"])      # unskaliert
    assert _same(x.plot().data["leverage"]["value"], x["cagr"])                        # Anteil, nicht ×100
    v = _obj("sensitivity/rs_bands").plot().data["variants"]
    assert any("±" in s for s in v["label"])
    w = _obj("tactical/bl_basic")
    d = w.plot(main="Mein Titel").data["weights"]
    for c in ("A", "C", "B", "CASH"):
        assert _same(d[c], w[c])
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
        assert _same(p.data["spending"][c], q[i])                 # unskaliert (gezeichnet in Tausend)
    p2 = x.plot(probs=[0.1, 0.5, 0.9])
    assert list(p2.data["wealth"].columns) == ["year", "q10", "q50", "q90"]
    assert _same(p2.data["wealth"]["q50"], p.data["wealth"]["q50"])


def test_plot_api_warnings_and_files(tmp_path):
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
    with warnings.catch_warnings(record=True) as wl:              # R kennt data = NULL; Julia nicht
        warnings.simplefilter("always")
        h.plot(data=None)
    assert [str(m.message) for m in wl] == ["plot.SimLevHMM: unbekanntes Argument 'data' wird ignoriert (Tippfehler?)."]
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
