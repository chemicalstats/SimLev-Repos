"""Parameterstudien um ``simulation()`` (R: ``sensitivity.R``).

- :func:`sensitivity_grid`         beliebige ``simulation()``-Argumente im Raster
- :func:`sensitivity_rebalancing`  Rebalancing-Frequenz, Versatz und Bänder
- :func:`planning_lumpsum_vs_dca`           Einmalanlage gegen gestreckten Einstieg
- :func:`series_leverage`         Hebelreihe aus einem Index (MSCI-Formel)
- :func:`sensitivity_leverage`     Kennzahlen über den Hebel, optimaler Hebel
"""
from __future__ import annotations

import importlib
import warnings
from collections.abc import Mapping

import numpy as np
import pandas as pd

from ._r import fmt as _fmt
from ._r.rnum import r_cumprod, r_mean, r_mean_int, r_median, r_sum
from ._r.parallel import par_lapply as _par_lapply
from .param_search import (_expand_grid, _isna, _match_arg, _py, _quiet, _seq_by,
                           _cond_msg, _which_max_py)
from .svg import _res_fig, _res_finish, _res_line, _res_panel, _res_points, _res_range, _res_rect, _res_vline

__all__ = ["sensitivity_grid", "sensitivity_rebalancing", "planning_lumpsum_vs_dca", "series_leverage",
           "sensitivity_leverage", "SimLevSensitivity", "SimLevLumpSum"]

_NA = _fmt.NA_REAL
_NAN = _NA          # alle Verwendungen hier sind R's NA


def _numna(e):
    """Zahl oder NA (``None``/``pd.NA`` → NA); ein NaN behält sein Bitmuster (NA bleibt NA, NaN bleibt NaN)."""
    return _NA if (e is None or e is pd.NA or e is pd.NaT) else float(e)
_EPOCH = np.datetime64("1970-01-01", "D")


def _ext(mod, name):
    m = importlib.import_module("simlev." + mod)
    return getattr(m, name)


def _simulation():
    """``simulation(data, strategy, **args)`` mit aufgelösten sim_args (R: ``.sim_call``)."""
    return _ext("engine", "simulation")


def _args_set(args, over, who):
    from ._sim_blocks import _sim_args_set
    return _sim_args_set(args, over, who)


def _metrics_default(metrics):
    return _ext("bootstrap", "bootstrap_study_metrics") if metrics is None else metrics


def _as_series(m):
    if isinstance(m, pd.Series):
        return m
    if isinstance(m, Mapping):
        return pd.Series(dict(m), dtype=np.float64)
    return pd.Series(np.asarray(m, dtype=np.float64))


def _to_date(x, what):
    d = _ext("data_prep", "_to_date")(x, what)
    a = np.asarray(d)
    if not np.issubdtype(a.dtype, np.datetime64):
        a = pd.to_datetime(pd.Series(a)).to_numpy()
    return a.astype("datetime64[D]")


def _days(d):
    return (np.asarray(d).astype("datetime64[D]") - _EPOCH).astype(np.int64)


def _fill_locf(v):
    return np.asarray(_ext("backcast", "_fill_na")(np.asarray(v, dtype=np.float64), "locf"), dtype=np.float64)


def _table_msg(errs):
    """``table(errs)`` als Text ``"<msg> (<n> x); ..."`` (Namen sortiert wie R)."""
    cnt = {}
    for e in errs:
        if e is None:
            continue
        cnt[e] = cnt.get(e, 0) + 1
    from ._r._collate import r_key
    return "; ".join("%s (%d x)" % (k, cnt[k]) for k in sorted(cnt, key=r_key))


def _paste_vec(v):
    """``paste(v, collapse = "/")``."""
    return "/".join(str(s) for s in np.atleast_1d(_fmt.as_character(np.atleast_1d(np.asarray(v)))))


def _is_list_value(v):
    return isinstance(v, (list, tuple, np.ndarray, pd.Series)) and not isinstance(v, str)


def _grid_frame(grid):
    """``expand.grid(grid)`` bzw. data.frame unverändert; Listen-Spalten als object."""
    if isinstance(grid, pd.DataFrame):
        return grid.reset_index(drop=True)
    cols = {}
    for k, v in dict(grid).items():
        vals = list(v) if _is_list_value(v) else [v]
        if any(_is_list_value(e) for e in vals):           # Listen-Spalte
            a = np.empty(len(vals), dtype=object)
            for i, e in enumerate(vals):
                a[i] = e
        elif all(isinstance(e, str) or _isna(e) for e in vals) and any(isinstance(e, str) for e in vals):
            a = np.array([None if _isna(e) else e for e in vals], dtype=object)
        elif all(isinstance(e, (bool, np.bool_)) or _isna(e) for e in vals) and any(isinstance(e, (bool, np.bool_)) for e in vals):
            a = np.array([None if _isna(e) else bool(e) for e in vals], dtype=object)
            if not any(x is None for x in a):
                a = a.astype(bool)
        else:
            a = np.array([_numna(e) for e in vals], dtype=np.float64)
        cols[k] = a
    return _expand_grid(cols)


def _cell(v):
    if isinstance(v, (list, tuple, np.ndarray)):
        return _py(v[0]) if len(v) == 1 else v      # R: Vektor der Länge 1 = Skalar
    return _py(v)


def _is_na_scalar(v):
    if isinstance(v, (list, tuple, np.ndarray, pd.Series, Mapping)):
        a = np.asarray(v, dtype=object) if not isinstance(v, Mapping) else None
        return a is not None and a.size == 1 and _isna(a.ravel()[0])
    return _isna(v)


# ─────────────────────────────────────────────────────────────────────────────
# sensitivity_grid
# ─────────────────────────────────────────────────────────────────────────────

def sensitivity_grid(data, strategy, grid, *, sim_args=None, metrics=None, keep_results=False, cores=1):
    """``simulation`` über ein Parameterraster.

    Ruft ``simulation()`` für jede Kombination von ``grid`` auf denselben Daten und derselben Strategie auf und
    sammelt die Kennzahlen in einem DataFrame (eine Zeile je Lauf). Grundlage der speziellen Studien in diesem
    Abschnitt (``sensitivity_rebalancing()``, ``sensitivity_leverage()``).

    Args:
        data, strategy: Wie in ``simulation()``: DataFrame mit Spalte ``date`` und Kursspalten (Niveaus) bzw.
            Strategie aus ``create_strategy()``.
        grid: Benannte Liste von Argumentwerten für ``simulation()``; alle Kombinationen werden gerechnet.
            Parameter der Bausteine werden mit Pfad ``"<Baustein>.<Parameter>"`` angesprochen, z. B.
            ``{"rebalance.unit": ["month", "year"], "rebalance.thresh": [5, 10]}``, ``"dca.value"``,
            ``"tax.rate"``, ``"tax.church_tax"``; Teilbausteine von ``tax_profile()`` mit drei Teilen
            (``"tax.income.marginal_rate"``, ``"tax.income.taxable_income"``, ``"tax.harvest.day"``). Ein Pfad
            baut den Baustein für jeden Lauf neu: Grundwerte aus dem gleichnamigen Baustein in ``sim_args`` (ohne
            ihn die Standardwerte des Konstruktors, z. B. ``dca_plan(value, span)`` braucht dann beide Pfade);
            mehrere Pfade eines Bausteins gelten zusammen. Ohne Punkt sind es Argumente von ``simulation()``
            (``start_value``, ``risk_free``, ``fractions``, ``liquidate``, ``details`` oder ein ganzer Baustein
            als Listen-Spalte). Unbekannte Pfade und die alten Einzelargumente (z. B. ``balance_unit``) ergeben
            einen Fehler mit den möglichen Bausteinen und Parametern. Alternativ ein DataFrame mit einer Zeile je
            Lauf. Listen-Spalten (z. B. ``splits.thresh``) sind erlaubt. ``NA`` lässt das Argument weg
            (Standardwert bzw. Wert aus ``sim_args``).
        sim_args: Benannte Liste gemeinsamer Argumente für alle Läufe (Standard ``{}``); Werte aus ``grid`` haben
            Vorrang. Argumente von ``simulation()`` außer ``data`` und ``strategy``, also auch Bausteine (z. B.
            ``dca = dca_plan(100, 1)``, ``tax = tax_profile()``) und Pfade zu Parametern der Bausteine
            (``"dca.value"``, siehe ``sensitivity_grid``). Alte Einzelargumente (bis 0.8.0, vor den Bausteinen, z.
            B. ``dca_value``) ergeben einen Fehler, der den Baustein nennt.
        metrics: Funktion ``SimLevResult -> benannter numerischer Vektor`` (Standard
            ``bootstrap_study_metrics()``).
        keep_results: Logisch (Standard ``False``): Ergebnisse der Läufe zusätzlich als Attribut ``results``
            zurückgeben.
        cores: Anzahl Prozesse (Standard 1; Fork auf Unix, PSOCK auf Windows).

    Returns:
        DataFrame: Rasterspalten (Listen-Spalten als Text "a/b"), die Kennzahlen aus ``metrics`` (bei
        ``bootstrap_study_metrics()`` z. B. ``cagr`` als Anteil; mit Sparplan geldgewichtet, XIRR) und, falls ein
        Lauf fehlschlug, eine Spalte ``error`` (Fehlermeldung, Kennzahlen dann ``NA``); schlagen alle Läufe fehl,
        ein Fehler mit den Meldungen der Läufe. Bei ``keep_results = True`` Attribut ``results`` (Liste der
        ``SimLevResult``).

    Beispiel::

        import numpy as np, pandas as pd, simlev
        rng = np.random.default_rng(1)
        n = 1500
        d = pd.DataFrame({"date": pd.date_range("2015-01-01", periods=n)})
        d["A"] = 100 * np.cumprod(1 + rng.normal(3e-4, 0.01, n))
        d["B"] = 100 * np.cumprod(1 + rng.normal(1e-4, 0.004, n))
        st = simlev.create_strategy(A=simlev.asset_config(asset_class="etf", share=0.6), B=simlev.asset_config(asset_class="etf", share=0.4))
        g = simlev.sensitivity_grid(d, st, {"rebalance.unit": ["month", "year"]},
                                    sim_args={"rebalance": simlev.rebalance_plan(span=1)})
        print(g[["rebalance.unit", "cagr", "trades"]])
    """
    metrics = _metrics_default(metrics)
    design = _grid_frame(grid)
    if not len(design):
        raise ValueError("Leeres Raster.")
    from ._sim_blocks import _sim_check_names
    _sim_check_names([str(k) for k in design.columns], "sensitivity_grid")   # Argumente bzw. Pfade wie "dca.value"
    sim_args = _args_set({}, sim_args, "sensitivity_grid")
    simulation = _simulation()

    def run(i):
        a = {}
        for k in design.columns:
            a[k] = _cell(design[k].iloc[i])
        a = {k: v for k, v in a.items() if not (not _is_list_value(v) and _isna(v))}
        try:
            args = _args_set(sim_args, a, "sensitivity_grid")
            res = _quiet(lambda: simulation(data, strategy, **args))
        except Exception as e:  # noqa: BLE001
            return {"m": None, "err": _cond_msg(e), "res": None}
        return {"m": _as_series(metrics(res)), "err": None, "res": res if keep_results else None}
    out = list(_par_lapply(list(range(len(design))), run, cores))
    okm = [o["m"] for o in out if o["m"] is not None]
    if not okm:
        raise ValueError("sensitivity_grid: Alle %d Läufe fehlgeschlagen: %s" % (len(out), _table_msg([o["err"] for o in out])))
    mnames = [str(k) for k in okm[0].index]
    M = np.array([[_NAN] * len(mnames) if o["m"] is None else [float(o["m"][k]) if k in o["m"].index else _NAN for k in mnames]
                  for o in out], dtype=np.float64).reshape(len(out), len(mnames))
    cols = {}
    for k in design.columns:
        col = design[k].to_numpy()
        if col.dtype == object and any(_is_list_value(v) for v in col):
            col = np.array([_paste_vec(v) for v in col], dtype=object)
        cols[k] = col
    for j, k in enumerate(mnames):
        cols[k] = M[:, j]
    errs = np.array([o["err"] for o in out], dtype=object)
    cols["error"] = errs
    tab = pd.DataFrame(cols)
    if all(e is None for e in errs):
        tab = tab.drop(columns="error")
    if keep_results:
        tab.attrs["results"] = [o["res"] for o in out]
    return tab


# ─────────────────────────────────────────────────────────────────────────────
# Ergebnisklassen
# ─────────────────────────────────────────────────────────────────────────────

def _all_equal_num(t, c):
    """``isTRUE(all.equal(t, c))`` für numerische Vektoren."""
    from ._r.linalg import all_equal_numeric
    return all_equal_numeric(np.asarray(t, dtype=np.float64), np.asarray(c, dtype=np.float64)) is True


class _RFrame(pd.DataFrame):
    """data.frame mit R-Klasse und eigener Druckausgabe."""

    _metadata = []

    @property
    def _constructor(self):
        return pd.DataFrame

    def format(self):  # pragma: no cover - Unterklassen
        return pd.DataFrame.__repr__(self)

    def __repr__(self):
        return self.format()

    def __str__(self):
        return self.format()

    def print(self):
        print(self.format())
        return self


def _fmt_vec(f, v):
    out = _fmt.sprintf(f, np.asarray(v, dtype=np.float64))
    if isinstance(out, str):
        out = np.array([out], dtype=object)
    return np.asarray(out, dtype=object)


class SimLevSensitivity(_RFrame):
    """Ergebnis von :func:`sensitivity_rebalancing` / :func:`sensitivity_leverage` (R-Klasse ``SimLevSensitivity``)."""

    r_class = ("SimLevSensitivity", "data.frame")

    def format(self):
        x = self
        keep = [c for c in ("frequency", "offset", "band", "band_type", "leverage", "cagr", "ttwror", "max_drawdown",
                            "sharpe", "ulcer_index", "taxes", "trades") if c in x.columns]
        y = pd.DataFrame({c: x[c].to_numpy() for c in keep})
        out = []
        if "cagr" in y.columns and "ttwror" in y.columns and _all_equal_num(y["cagr"], y["ttwror"]):
            y = y.drop(columns="ttwror")
        if "band_type" in y.columns:
            band = y["band"].to_numpy(dtype=np.float64) if "band" in y.columns else None
            btv = y["band_type"].to_numpy()
            sel = btv if band is None else btv[~np.isnan(band)]
            bt = list(dict.fromkeys(_py(v) for v in sel))
        else:
            bt = []
        if "band_type" in y.columns and len(bt) <= 1:
            y = y.drop(columns="band_type")
            if len(bt) == 1:
                out.append("Toleranzbänder: %s\n" % ("relativ (% des Zielgewichts)" if bt[0] == "relative"
                                                          else "absolut (Prozentpunkte)"))
        if "band" in y.columns:
            b = y["band"].to_numpy(dtype=np.float64)
            fb = np.atleast_1d(_fmt.format(b))
            y["band"] = np.array(["-" if np.isnan(b[i]) else str(fb[i]) for i in range(b.size)], dtype=object)
        if "offset" in y.columns and np.isnan(y["offset"].to_numpy(dtype=np.float64)).all():
            y["offset"] = np.array([None] * len(y), dtype=object)
        for k in [c for c in ("cagr", "ttwror", "max_drawdown") if c in y.columns]:
            y[k] = _fmt_vec("%.2f %%", 100 * y[k].to_numpy(dtype=np.float64))
        for k in [c for c in ("sharpe", "ulcer_index") if c in y.columns]:
            y[k] = _fmt_vec("%.3f", y[k].to_numpy(dtype=np.float64))
        for k in [c for c in ("taxes", "trades") if c in y.columns]:
            y[k] = _fmt_vec("%.1f", y[k].to_numpy(dtype=np.float64))
        types = {"offset": "logical"} if "offset" in y.columns and y["offset"].dtype == object \
            and all(v is None for v in y["offset"]) else None
        out.append(_fmt.print_data_frame(y, row_names=False, types=types) + "\n")
        if "cagr" in y.columns:
            out.append("cagr: mit Sparplan geldgewichtet (XIRR), sonst CAGR des Depotwerts\n")
        opt = x.attrs.get("optimal")
        if opt is not None:
            o = np.asarray(opt, dtype=np.float64)
            oi = [float(o[i]) if i < o.size else _NA for i in (0, 1)]  # R: x[i] jenseits der Länge = NA
            out.append(_fmt.sprintf("Optimaler Hebel: CAGR %.2f, Sharpe %.2f\n", oi[0], oi[1]))
        return "".join(out)[:-1]

    # ``plot`` (SVG, ``SimLevPlot``) wird am Modulende über ``_plot_method`` gesetzt.


def _plot_sens(x, metric="cagr"):
    """``plot.SimLevSensitivity`` (SVG): Kennzahl nach Hebel (Linie) bzw. je Rebalancing-Variante (Balken).

    Liefert ``(svg, data)``: ``leverage`` (``leverage``, ``value``) bzw. ``variants`` (``label``, ``value``);
    ``value`` ist die Kennzahl unskaliert wie im Ergebnis (Anteile, nicht ×100).
    """
    from . import overfitting as OF
    kind = x.attrs.get("kind", "grid")
    sc = 100 if metric in ("cagr", "ttwror", "max_drawdown", "avg_drawdown") else 1
    raw = np.array([_num1(v) for v in x[metric].tolist()], dtype=np.float64)
    y = sc * raw
    f = _res_fig(720, 460)
    if kind == "leverage":
        lv = np.array([_num1(v) for v in x["leverage"].tolist()], dtype=np.float64)
        p = _res_panel(f, 70, 40, 620, 360, _res_range(lv), _res_range(y), title="%s nach Hebel" % metric,
                       xlab="Hebel", ylab=metric)
        _res_line(f, p, lv, y)
        _res_points(f, p, lv, y)
        j = OF._which_max(raw)
        if j is not None:
            _res_vline(f, p, float(lv[j]), width=1, dash="2,3")
        data = {"leverage": pd.DataFrame({"leverage": lv, "value": raw})}
    else:
        n = len(y)
        lab = []
        for fr, b, o in zip(x["frequency"].tolist(), x["band"].tolist(), x["offset"].tolist()):
            lab.append(" ".join([str(fr), "" if _isna(b) else "±" + _fmt.as_character(_py(b)),
                                 "" if _isna(o) else "-" + _fmt.as_character(_py(o)) + "d"]))
        lo, hi = _res_range(np.concatenate([[0.0], y]))
        p = _res_panel(f, 160, 40, 530, 380, (lo, hi), (0.5, n + 0.5), title="Rebalancing-Varianten: %s" % metric,
                       xlab=metric, yticks=[float(i) for i in range(1, n + 1)], yticklabels=lab[::-1], grid=False)
        for i, v in enumerate(y[::-1].tolist(), start=1):
            if np.isfinite(v):
                _res_rect(f, p, 0.0, i - 0.35, v, i + 0.35)
        data = {"variants": pd.DataFrame({"label": lab, "value": raw})}
    return _res_finish(f), data


def _num1(v):
    v = _py(v)
    return _NA if v is None else float(v)


class SimLevLumpSum(_RFrame):
    """Ergebnis von :func:`planning_lumpsum_vs_dca` (R-Klasse ``SimLevLumpSum``)."""

    r_class = ("SimLevLumpSum", "data.frame")

    def format(self):
        s = self.attrs["summary"]
        st = self.attrs["settings"]
        out = [_fmt.sprintf("Lump Sum vs. DCA: %d Starttermine, %s in %d Monatsraten, Horizont %g Jahre\n",
                            len(self), str(_fmt.formatC(st["amount"], format="f", digits=0, big_mark=" ")),
                            st["months"], st["horizon"])]
        out.append(_fmt.sprintf("  Einmalanlage vorn:          %.1f %% der Starttermine\n", 100 * s["win_rate"]))
        out.append(_fmt.sprintf("  Vorsprung Mittel / Median:  %+.2f %% / %+.2f %%\n", 100 * s["mean_advantage"],
                                100 * s["median_advantage"]))
        out.append(_fmt.sprintf("  MLSA (wenn vorn):           %+.2f %%\n", 100 * s["mlsa"]))
        out.append(_fmt.sprintf("  MLSD (wenn hinten):         %+.2f %%\n", 100 * s["mlsd"]))
        return "".join(out)[:-1]


# ─────────────────────────────────────────────────────────────────────────────
# Rebalancing
# ─────────────────────────────────────────────────────────────────────────────

_FREQ = {"monthly": ("month", 1), "bimonthly": ("month", 2), "quarterly": ("quarter", 1),
         "four_monthly": ("month", 4), "semiannual": ("month", 6), "yearly": ("year", 1)}


def _vec(v):
    if v is None:
        return None
    if isinstance(v, (list, tuple, np.ndarray, pd.Series)):
        return [_py(e) for e in (v.tolist() if hasattr(v, "tolist") else v)]
    return [_py(v)]


def sensitivity_rebalancing(data, strategy, *, frequencies=None, offsets=None, bands=_NAN,
                            band_type=("absolute", "relative"), include_none=True, sim_args=None, metrics=None,
                            cores=1):
    """Rebalancing-Sensitivität.

    Vergleicht Rebalancing-Frequenzen, Versatz vor dem Periodenende und Toleranzbänder (absolut oder relativ) für
    eine Strategie, wie die Rebalancing-Sensitivity von testfol.io. Jede Kombination aus ``frequencies``,
    ``offsets`` und ``bands`` wird mit ``simulation()`` (``rebalance = rebalance_plan(...)``) gerechnet. Bänder
    werden an den Kalenderterminen der jeweiligen Frequenz geprüft. Termine, die nicht als Zeile in ``data``
    vorkommen (bei Handelstagsdaten z. B. Wochenenden), entfallen.

    Args:
        data, strategy: Wie in ``simulation()``: DataFrame mit Spalte ``date`` und Kursspalten (Niveaus) bzw.
            Strategie aus ``create_strategy()``.
        frequencies: Benannte Liste von ``[unit, span]`` mit ``unit`` "month", "quarter" oder "year" und ``span``
            = Anzahl Einheiten zwischen den Terminen (``unit`` und ``span`` von ``rebalance_plan()``). Standard:
            monatlich, zweimonatlich, quartalsweise, viermonatlich, halbjährlich, jährlich (Namen monthly,
            bimonthly, quarterly, four_monthly, semiannual, yearly).
        offsets: Numerischer Vektor: Kalendertage vor dem Ende des Monats, Dreimonatsblocks bzw. Jahres, in dem
            der Termin liegt (0 = letzter Tag; ``rebalance_plan(anchor = "end", days = offset + 1)``). ``None``
            (Standard) rebalanciert am Periodenanfang.
        bands: Toleranzbänder in Prozent (5 = 5 Prozent); ``NA`` (Standard) = an jedem Termin rebalancieren.
            Mehrere Werte, auch gemischt mit ``NA``, sind möglich.
        band_type: "absolute" (Standard; Prozentpunkte Abweichung vom Zielgewicht) oder "relative" (Prozent des
            Zielgewichts), siehe ``thresh_type`` von ``rebalance_plan()``.
        include_none: Logisch (Standard ``True``): zusätzlich einen Lauf ohne Rebalancing (Zeile ``frequency =
            "none"``).
        sim_args: Benannte Liste gemeinsamer Argumente für alle Läufe (Standard ``{}``): Argumente von
            ``simulation()`` außer ``data`` und ``strategy``, also auch Bausteine (z. B. ``dca = dca_plan(100,
            1)``, ``tax = tax_profile()``) und Pfade zu Parametern der Bausteine (``"dca.value"``, siehe
            ``sensitivity_grid``). Alte Einzelargumente (bis 0.8.0, vor den Bausteinen, z. B. ``dca_value``)
            ergeben einen Fehler, der den Baustein nennt. Ein ``rebalance = rebalance_plan(...)`` in ``sim_args``
            liefert die Grundwerte (z. B. ``start``, ``event_col``); Frequenz, Versatz und Band setzt die Funktion
            je Lauf über die Pfade ``"rebalance.unit"``, ``"rebalance.span"``, ``"rebalance.anchor"``,
            ``"rebalance.days"``, ``"rebalance.thresh"`` und ``"rebalance.thresh_type"``; der Lauf ohne
            Rebalancing setzt ``rebalance = None``.
        metrics: Funktion ``SimLevResult -> benannter numerischer Vektor`` (Standard
            ``bootstrap_study_metrics()``).
        cores: Anzahl Prozesse (Standard 1; Fork auf Unix, PSOCK auf Windows).

    Returns:
        DataFrame der Klasse ``SimLevSensitivity`` mit den Spalten ``frequency``, ``offset``, ``band``,
        ``band_type`` und den Kennzahlen aus ``metrics``; fehlgeschlagene Läufe fehlen. Attribut ``kind =
        "rebalancing"``. Ausgabe und Grafik über ``print()`` und ``plot()``. Mit Sparplan (``sim_args``) ist
        ``cagr`` geldgewichtet (XIRR); ``print()`` weist darauf hin.

    Beispiel::

        import numpy as np, pandas as pd, simlev
        rng = np.random.default_rng(1)
        n = 1500
        d = pd.DataFrame({"date": pd.date_range("2015-01-01", periods=n)})
        d["A"] = 100 * np.cumprod(1 + rng.normal(3e-4, 0.01, n))
        d["B"] = 100 * np.cumprod(1 + rng.normal(1e-4, 0.004, n))
        st = simlev.create_strategy(A=simlev.asset_config(asset_class="etf", share=0.6), B=simlev.asset_config(asset_class="etf", share=0.4))
        print(simlev.sensitivity_rebalancing(d, st, frequencies={"monthly": ["month", 1], "yearly": ["year", 1]},
                                             bands=[np.nan, 5]))
    """
    band_type = _match_arg(band_type, ("absolute", "relative"), "band_type")
    frequencies = _FREQ if frequencies is None else frequencies
    sim_args = _args_set({}, sim_args, "sensitivity_rebalancing")
    metrics = _metrics_default(metrics)
    rows = []
    offs = [_NAN] if offsets is None else _vec(offsets)
    bnds = _vec(bands)
    for fn, f in dict(frequencies).items():
        f = list(f)
        for off in offs:
            for b in bnds:
                # Rebalancing über Pfade: weitere Angaben eines rebalance_plan() aus sim_args bleiben erhalten
                a = {"rebalance.unit": str(f[0]), "rebalance.span": float(f[1]), "rebalance.thresh_type": band_type}
                if not _isna(off):
                    a["rebalance.anchor"] = "end"
                    a["rebalance.days"] = off + 1
                if not _isna(b):
                    a["rebalance.thresh"] = b
                rows.append({"label": (fn, _numna(off), _numna(b), band_type),
                             "args": a})
    if include_none:
        rows.append({"label": ("none", _NAN, _NAN, None), "args": {"rebalance": None}})
    simulation = _simulation()

    def run(i):
        try:
            args = _args_set(sim_args, rows[i]["args"], "sensitivity_rebalancing")
            res = _quiet(lambda: simulation(data, strategy, **args))
        except Exception as e:  # noqa: BLE001
            return _cond_msg(e)
        return _as_series(metrics(res))
    out = list(_par_lapply(list(range(len(rows))), run, cores))
    ok = [not isinstance(o, str) for o in out]
    if not any(ok):
        raise ValueError("sensitivity_rebalancing: Alle %d Läufe fehlgeschlagen: %s" % (len(out), _table_msg(out)))
    good = [o for o, k in zip(out, ok) if k]
    mnames = [str(k) for k in good[0].index]
    lab = [r["label"] for r, k in zip(rows, ok) if k]
    cols = {"frequency": np.array([l_[0] for l_ in lab], dtype=object),
            "offset": np.array([l_[1] for l_ in lab], dtype=np.float64),
            "band": np.array([l_[2] for l_ in lab], dtype=np.float64),
            "band_type": np.array([l_[3] for l_ in lab], dtype=object)}
    M = np.array([g.to_numpy(dtype=np.float64) for g in good], dtype=np.float64)
    for j, k in enumerate(mnames):
        cols[k] = M[:, j]
    tab = SimLevSensitivity(cols)
    tab.attrs["kind"] = "rebalancing"
    return tab


# ─────────────────────────────────────────────────────────────────────────────
# Lump Sum vs. DCA
# ─────────────────────────────────────────────────────────────────────────────

def _civil(z):
    from ._dates import ymd
    return ymd(int(z))


def _days_from_civil(y, m, d):
    from ._dates import days_from_civil
    return days_from_civil(y, m, d)


def _seq_date_2nd(s, by):
    """``seq.Date(s, by = "<k> <einheit>", length.out = 2)[2]`` (POSIXlt-Normalisierung)."""
    parts = by.split(" ")
    unit = parts[-1]
    k = int(float(parts[0])) if len(parts) > 1 else 1
    z = int(_days(np.array([s]))[0])
    y, m, d = _civil(z)
    if unit.startswith("year"):
        y2, m2 = y + k, m
    else:
        tot = (m - 1) + k
        y2, m2 = y + tot // 12, tot % 12 + 1
    return np.datetime64(int(_days_from_civil(y2, m2, 1) + d - 1), "D")


def _r_num_str(x):
    return str(_fmt.as_character(np.array([float(x)]))[0])


def _report_get(rep, a, key):
    r = rep[a]
    v = r[key] if isinstance(r, Mapping) or hasattr(r, "__getitem__") else getattr(r, key)
    return np.asarray(v, dtype=np.float64)


def planning_lumpsum_vs_dca(data, strategy, *, amount=10000, months=12, horizon=10, step=1, sim_args=None, cores=1):
    """Einmalanlage gegen gestreckten Einstieg (Lump Sum vs. DCA).

    Vergleicht für rollierende Starttermine (jeweils am Monatsersten) die sofortige Anlage eines Betrags mit einem
    Einstieg in ``months`` gleichen Monatsraten. Verglichen wird das Vermögen nach ``horizon`` Jahren.

    Args:
        data, strategy: Wie in ``simulation()``: DataFrame mit Spalte ``date`` und Kursspalten (Niveaus) bzw.
            Strategie aus ``create_strategy()``.
        amount: Anlagebetrag in Währungseinheiten (Standard 10000); bei DCA in ``months`` Raten von ``amount /
            months`` aufgeteilt.
        months: Anzahl Monatsraten des gestreckten Einstiegs (Standard 12).
        horizon: Vergleichshorizont in Jahren ab Start (Standard 10).
        step: Jeder wievielte mögliche Starttermin verwendet wird (Standard 1 = jeder Monat; 12 = jährlich).
        sim_args: Benannte Liste weiterer Argumente für ``simulation()`` (z. B. ``tax = tax_profile()``):
            Argumente von ``simulation()`` außer ``data`` und ``strategy``, also auch Bausteine (z. B. ``dca =
            dca_plan(100, 1)``, ``tax = tax_profile()``) und Pfade zu Parametern der Bausteine (``"dca.value"``,
            siehe ``sensitivity_grid``). Alte Einzelargumente (bis 0.8.0, vor den Bausteinen, z. B. ``dca_value``)
            ergeben einen Fehler, der den Baustein nennt. ``start_value`` und ``dca`` (auch Pfade ``"dca.*"`` und
            die alten ``dca_*``) setzt die Funktion selbst (in ``sim_args`` ein Fehler).
        cores: Anzahl Prozesse (Standard 1; Fork auf Unix, PSOCK auf Windows).

    Returns:
        DataFrame der Klasse ``SimLevLumpSum`` mit einer Zeile je Start: ``start`` (Datum), ``lump_sum`` und
        ``dca`` (Endvermögen nach ``horizon`` Jahren in Währungseinheiten), ``advantage`` (Lump Sum / DCA - 1, als
        Anteil) und ``exact`` (logisch: DCA-Depot exakt über Stückzahlen fortgeschrieben, siehe oben). Attribut
        ``summary``: ``win_rate`` (Anteil der Starttermine mit Vorsprung der Einmalanlage), ``mean_advantage``,
        ``median_advantage``, ``mlsa`` (mittlerer Vorsprung bei Gewinn) und ``mlsd`` (mittlerer Rückstand bei
        Verlust), alle als Anteil; Attribut ``settings``.

    Details:
        Die Einmalanlage wird über den ganzen Horizont mit ``simulation()`` gerechnet, der gestreckte Einstieg
        über die ``months`` Monate der Einstiegsphase (Sparplan). Danach wird das DCA-Depot fortgeschrieben:

        - exakt: Handelt die Strategie nach der Einstiegsphase nicht mehr (in der Einmalanlage bleibt die
          Stückzahl jedes Assets bis zum Horizont gleich, z. B. Buy-and-Hold ohne Rebalancing, ohne Steuern), hält
          auch das DCA-Depot seine Stückzahlen: Endwert = Summe der Stückzahlen am Ende der Einstiegsphase x Kurs
          am Horizont plus Cash. Jedes Asset behält so seine eigenen Gewichte.
        - Näherung: Sonst (Rebalancing, Signale, Steuern mit Vorabpauschale oder Kosten, die Stück verkaufen)
          wächst das DCA-Depot mit dem zeitgewichteten Index der Einmalanlage (``result_index()``), als hätte es
          ab dem Ende der Einstiegsphase deren Gewichte; mit Steuern (``tax = tax_profile()``) erscheint dazu eine
          Warnung.

        Welche Variante verwendet wurde, steht je Start in der Spalte ``exact``. Für Fonds-Wrapper
        (``asset_config(wrapper = )``) ist der Kurs der Anteilswert aus ``wrapper_nav()`` im Fenster der
        Einmalanlage, wie ihn ``simulation()`` rechnet.

        Als Starttermine dienen nur Monatserste, die als Zeile in ``data`` vorkommen (bei Handelstagsdaten
        entfallen Monate, deren Erster kein Handelstag ist), und nur solche, nach denen noch ``horizon`` Jahre
        Daten folgen.

    Beispiel::

        import numpy as np, pandas as pd, simlev
        rng = np.random.default_rng(1)
        n = 2190
        d = pd.DataFrame({"date": pd.date_range("2010-01-01", periods=n)})
        d["ETF"] = 100 * np.cumprod(1 + rng.normal(3e-4, 0.01, n))
        ld = simlev.planning_lumpsum_vs_dca(d, simlev.create_strategy(ETF=simlev.asset_config(asset_class="etf")),
                                            amount=12000, months=12, horizon=3, step=6)
        print(ld.head())
    """
    sim_args = {} if sim_args is None else dict(sim_args)
    own = [k for k in sim_args if k in ("start_value", "dca", "dca_mode", "dca_value", "dca_span", "dca_unit", "dca_skip")
           or str(k).startswith("dca.")]
    if own:
        raise ValueError("planning_lumpsum_vs_dca setzt %s selbst; aus sim_args entfernen (Betrag über amount, Raten über months)."
                         % ", ".join(own))
    sim_args = _args_set({}, sim_args, "planning_lumpsum_vs_dca")
    data = data.copy()
    data["date"] = _to_date(data["date"], "planning_lumpsum_vs_dca: data$date")
    data = data.iloc[np.argsort(_days(data["date"].to_numpy()), kind="stable")].reset_index(drop=True)
    d = data["date"].to_numpy().astype("datetime64[D]")
    dn = _days(d)
    if sim_args.get("tax") is not None:
        warnings.warn("Mit Steuern ist die Fortschreibung des DCA-Depots nach der Einstiegsphase eine Näherung "
                      "(Index der Einmalanlage).", UserWarning, stacklevel=2)
    dd = np.array([_civil(z)[2] for z in dn])
    firsts = d[dd == 1]
    last_ok = _seq_date_2nd(d.max(), "-" + _r_num_str(horizon) + " years")
    starts = firsts[firsts <= last_ok]
    sel = _seq_by(1, len(starts), step)
    starts = starts[sel.astype(np.int64) - 1]
    if not len(starts):
        raise ValueError("Historie zu kurz für den Horizont.")
    simulation = _simulation()
    result_index = _ext("withdrawal", "result_index")
    wmod = importlib.import_module("simlev.wrapper")
    cmod = importlib.import_module("simlev.config")
    wraps = cmod._strategy_wrappers(strategy)   # Fonds-Wrapper: Asset-Name ist keine Kursspalte (_strategy_columns)
    to_frame = _ext("_sim_base", "_to_frame")
    hz = _r_num_str(horizon) + " years"
    mo = _r_num_str(months) + " months"
    cache = {}

    def px(a, dates, navs=None):
        if a in wraps:
            nd, nv = navs[a]
            i = np.searchsorted(nd, _days(np.atleast_1d(dates)), side="right")
            i[i == 0] = 1
            return nv[i - 1]
        if a not in cache:
            cache[a] = _fill_locf(data[a].to_numpy(dtype=np.float64))
        k = np.searchsorted(dn, _days(np.atleast_1d(dates)), side="right")
        return cache[a][k - 1]

    def run(s):
        e = _seq_date_2nd(s, hz) - np.timedelta64(1, "D")
        e_dca = _seq_date_2nd(s, mo) - np.timedelta64(1, "D")
        w = data[(d >= s) & (d <= e)].reset_index(drop=True)
        ls = _quiet(lambda: simulation(w, strategy, start_value=amount, **sim_args))
        wd = data[(d >= s) & (d <= e_dca)].reset_index(drop=True)
        from ._sim_blocks import dca_plan
        dp = dca_plan(value=amount / months, span=1, unit="month", skip=True)
        dca = _quiet(lambda: simulation(wd, strategy, start_value=amount / months, dca=dp, **sim_args))
        ix = result_index(ls)
        # Fonds-Wrapper: Kurs = Anteilswert im Fenster der Einmalanlage (wie in simulation() aus den inneren Spalten)
        navs = {}
        if wraps:
            wf = to_frame(w.copy())
            wf.filled_attr = None
            for a in wraps:
                nv = _quiet(lambda a=a: wmod._wrapper_nav_calc(wf, strategy[a]["wrapper"], sim_args.get("splits"),
                                                               tag="Wrapper '%s'" % a,
                                                               who="planning_lumpsum_vs_dca: Wrapper '%s'" % a))
                navs[a] = wmod._nav_raw(nv)
        ixd = np.asarray(ix["date"]).astype("datetime64[D]")
        ixv = ix["value"].to_numpy(dtype=np.float64)
        wmax = np.asarray(wd["date"]).astype("datetime64[D]").max()
        k = int(np.nonzero(ixd == wmax)[0][0])
        assets = list(dca["report"].keys())
        rows = np.arange(k, len(ix))
        const = True
        for a in assets:
            p = px(a, ixd[rows], navs)
            u = _report_get(ls["report"], a, "worth")[rows] / p
            okc = bool(np.isfinite(u).all()) and bool((np.abs(u - u[0]) <= 1e-9 * max(1.0, abs(u[0]))).all())
            if not okc:
                const = False
                break
        if const:
            dw = np.asarray(dca["worth"], dtype=np.float64)
            nd = dw.size
            ddates = np.asarray(dca["dates"])
            vals = [_report_get(dca["report"], a, "worth")[nd - 1] / px(a, ddates[nd - 1:nd], navs)[0]
                    * px(a, ixd[-1:], navs)[0] + _report_get(dca["report"], a, "money")[nd - 1] for a in assets]
            dca_end = r_sum(np.array(vals, dtype=np.float64))
        else:
            dca_end = float(np.asarray(dca["worth"], dtype=np.float64)[-1]) * ixv[-1] / ixv[k]
        return (float(np.asarray(ls["worth"], dtype=np.float64)[-1]), float(dca_end), bool(const))
    res = list(_par_lapply(list(starts), run, cores))
    lump = np.array([r[0] for r in res], dtype=np.float64)
    dcav = np.array([r[1] for r in res], dtype=np.float64)
    exact = np.array([r[2] for r in res], dtype=bool)
    adv = lump / dcav - 1
    tab = SimLevLumpSum({"start": starts, "lump_sum": lump, "dca": dcav, "advantage": adv, "exact": exact})
    win = adv > 0
    tab.attrs["summary"] = pd.Series({"win_rate": r_mean_int(win.astype(np.int64)), "mean_advantage": r_mean(adv),
                                      "median_advantage": r_median(adv),
                                      "mlsa": r_mean(adv[win]) if win.any() else _NAN,
                                      "mlsd": r_mean(adv[~win]) if (~win).any() else _NAN}, dtype=np.float64)
    tab.attrs["settings"] = {"amount": amount, "months": months, "horizon": horizon}
    return tab


# ─────────────────────────────────────────────────────────────────────────────
# Hebel
# ─────────────────────────────────────────────────────────────────────────────

def series_leverage(data, index, *, leverage=2, rate=0, expense=0, spread=0, start=100):
    """Gehebelte Reihe aus einem Index erzeugen (täglich zurückgesetzt, MSCI-Formel plus Kosten).

    Bildet eine täglich zurückgesetzte Hebelreihe (Niveau) nach der MSCI-Formel plus Fondskosten (wie die
    Ticker-Parameter L, E, SP und FR bei testfol.io): r = L x + (1 - L) i T/360 - TER· T/365 - s· m(L) T/360 mit
    Indexrendite x, Kalendertagen T seit der Vorzeile, m(L) = max(L-1, 0) + max(-L, 0) und i, TER, s als Anteil
    (Prozentangabe / 100); der Zins gilt für den Tag der Rendite. Das Ergebnis kann als Kursspalte in
    ``simulation()`` dienen; für die Anpassung an ein echtes Produkt siehe ``backcast_fit()``.

    Args:
        data: DataFrame mit Spalte ``date`` und der Indexspalte.
        index: Spaltenname des Index (Niveau, nicht Rendite; Lücken werden mit dem letzten Wert gefüllt).
        leverage: Hebel L als Zahl (Standard 2; negativ für Short).
        rate: Finanzierungszins in Prozent p. a. (Standard 0): Skalar, Spaltenname, Vektor der Länge
            ``nrow(data)``, ``data.frame(date, value)`` oder benannter Vektor mit Datumsnamen.
        expense: TER in Prozent p. a. (Standard 0).
        spread: Spread auf den finanzierten bzw. leerverkauften Anteil m(L) in Prozent p. a. (Standard 0).
        start: Startwert der Reihe in der ersten Zeile (Standard 100).

    Returns:
        Numerischer Vektor (Niveau, Länge ``nrow(data)``); fällt eine Tagesrendite auf -100 Prozent oder darunter,
        bleibt die Reihe ab dort bei 0.

    Beispiel::

        import numpy as np, pandas as pd, simlev
        rng = np.random.default_rng(1)
        n = 1500
        d = pd.DataFrame({"date": pd.date_range("2015-01-01", periods=n)})
        d["idx"] = 100 * np.cumprod(1 + rng.normal(3e-4, 0.01, n))
        d["zins"] = 2.0
        d["l2"] = simlev.series_leverage(d, "idx", leverage=2, rate="zins", expense=0.6, spread=0.3)
        print(d.tail(2))
    """
    idx = _fill_locf(np.asarray(data[index], dtype=np.float64))
    dts = _days(_to_date(data["date"], "data$date")).astype(np.float64)
    dd = np.concatenate([[1.0], np.diff(dts)])
    x = np.concatenate([[0.0], idx[1:] / idx[:-1] - 1])
    rt = np.asarray(_ext("backcast", "_resolve_series")(rate, data, "rate"), dtype=np.float64)
    L = float(leverage)
    m = max(L - 1, 0.0) + max(-L, 0.0)
    r = L * x + (1 - L) * rt / 100 * dd / 360 - expense / 100 * dd / 365 - spread / 100 * m * dd / 360
    r = np.array(r, dtype=np.float64)
    r[0] = 0.0
    ko = np.nonzero(r <= -1)[0]
    if ko.size:
        r[ko[0]:] = -1.0
    v = start * r_cumprod(1 + r)
    v[v < 0] = 0.0
    return v


def sensitivity_leverage(data, index, *, leverages=None, rate=0, expense=0, spread=0, strategy=None, sim_args=None,
                         metrics=None, cores=1):
    """Kennzahlen über den Hebel.

    Erzeugt für jeden Hebel eine Reihe mit ``series_leverage()``, simuliert sie als Buy-and-Hold (oder mit einer
    eigenen Strategie für das Asset ``"LEV"``) und bestimmt den Hebel mit der höchsten CAGR bzw. Sharpe Ratio, wie
    die LETF-Analyse von testfol.io. An ``simulation()`` wird ein DataFrame mit den Spalten ``date`` und ``LEV``
    übergeben.

    Args:
        data: DataFrame mit Spalte ``date`` und der Indexspalte.
        index: Spaltenname des Index (Niveau, nicht Rendite; Lücken werden mit dem letzten Wert gefüllt).
        leverages: Numerischer Vektor der zu prüfenden Hebel (Standard ``seq(0.5, 4, by = 0.25)``).
        rate: Finanzierungszins in Prozent p. a. (Standard 0): Skalar, Spaltenname, Vektor der Länge
            ``nrow(data)``, ``data.frame(date, value)`` oder benannter Vektor mit Datumsnamen.
        expense: TER in Prozent p. a. (Standard 0).
        spread: Spread auf den finanzierten bzw. leerverkauften Anteil m(L) in Prozent p. a. (Standard 0).
        strategy: Optional Strategie mit dem Asset ``"LEV"``; ``None`` (Standard) = Buy-and-Hold-ETF mit 30
            Prozent Teilfreistellung (``asset_config("etf", "bnh", partial_exemption = 30)``).
        sim_args: Benannte Liste gemeinsamer Argumente für alle Läufe (Standard ``{}``): Argumente von
            ``simulation()`` außer ``data`` und ``strategy``, also auch Bausteine (z. B. ``dca = dca_plan(100,
            1)``, ``tax = tax_profile()``) und Pfade zu Parametern der Bausteine (``"dca.value"``, siehe
            ``sensitivity_grid``). Alte Einzelargumente (bis 0.8.0, vor den Bausteinen, z. B. ``dca_value``)
            ergeben einen Fehler, der den Baustein nennt.
        metrics: Funktion ``SimLevResult -> benannter numerischer Vektor`` (Standard
            ``bootstrap_study_metrics()``).
        cores: Anzahl Prozesse (Standard 1; Fork auf Unix, PSOCK auf Windows).

    Returns:
        DataFrame der Klasse ``SimLevSensitivity`` mit ``leverage`` und den Kennzahlen aus ``metrics``
        (fehlgeschlagene Läufe fehlen); Attribut ``optimal`` (benannter Vektor ``cagr``, ``sharpe``: Hebel mit
        maximaler CAGR bzw. Sharpe Ratio) und ``kind = "leverage"``. Mit Sparplan (``sim_args``) ist ``cagr``
        geldgewichtet (XIRR). Ausgabe und Grafik über ``print()`` und ``plot()``.

    Beispiel::

        import numpy as np, pandas as pd, simlev
        rng = np.random.default_rng(1)
        n = 1500
        d = pd.DataFrame({"date": pd.date_range("2015-01-01", periods=n)})
        d["idx"] = 100 * np.cumprod(1 + rng.normal(3e-4, 0.01, n))
        lv = simlev.sensitivity_leverage(d, "idx", leverages=[1, 1.5, 2, 3], rate=2, expense=0.5)
        print(lv)
    """
    leverages = _seq_by(0.5, 4, 0.25) if leverages is None else np.atleast_1d(np.asarray(leverages, dtype=np.float64))
    sim_args = _args_set({}, sim_args, "sensitivity_leverage")
    metrics = _metrics_default(metrics)
    if strategy is None:
        from .config import asset_config, create_strategy
        strategy = create_strategy(LEV=asset_config(asset_class="etf", trading="bnh", partial_exemption=30))
    simulation = _simulation()
    dts = _to_date(data["date"], "data$date")

    def run(L):
        lev = series_leverage(data, index, leverage=L, rate=rate, expense=expense, spread=spread)
        lev = np.where(lev <= 0, 1e-8, lev)
        df = pd.DataFrame({"date": dts, "LEV": lev})
        try:
            res = _quiet(lambda: simulation(df, strategy, **sim_args))
        except Exception:  # noqa: BLE001
            return None
        return _as_series(metrics(res))
    out = list(_par_lapply(list(leverages), run, cores))
    ok = np.array([o is not None for o in out], dtype=bool)
    good = [o for o in out if o is not None]
    cols = {"leverage": leverages[ok]}
    if good:
        mnames = [str(k) for k in good[0].index]
        M = np.array([g.to_numpy(dtype=np.float64) for g in good], dtype=np.float64)
        for j, k in enumerate(mnames):
            cols[k] = M[:, j]
    tab = SimLevSensitivity(cols)
    tab.attrs["kind"] = "leverage"
    jc = _which_max_py(tab["cagr"].to_numpy(dtype=np.float64)) if "cagr" in tab.columns else None
    js = _which_max_py(tab["sharpe"].to_numpy(dtype=np.float64)) if "sharpe" in tab.columns else None
    lv = tab["leverage"].to_numpy(dtype=np.float64)
    # R: c(cagr = lev[which.max(cagr)], sharpe = ...): ein leeres which.max lässt das Element weg
    opt = {}
    if jc is not None:
        opt["cagr"] = lv[jc]
    if "sharpe" in tab.columns:
        if js is not None:
            opt["sharpe"] = lv[js]
    else:
        opt["sharpe"] = _NA
    tab.attrs["optimal"] = pd.Series(opt, dtype=np.float64)
    return tab


# plot.SimLevSensitivity (SVG, ``SimLevPlot``) wie Julias ``_plot_method(_plot_sens, "SimLevSensitivity")``
from .svg import _plot_method  # noqa: E402

SimLevSensitivity.plot = _plot_method(_plot_sens, "SimLevSensitivity")

# Rechnen mit NA (signalisierendes NaN) ohne numpy-Warnung "invalid value" wie in R (gemeinsamer Helfer)
from ._r.base import quiet_fp  # noqa: E402

quiet_fp(globals(), list(__all__))
