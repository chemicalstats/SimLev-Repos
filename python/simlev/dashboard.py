"""Dashboard-Grafiken für SimLev-Ergebnisse (Port von plot_dashboard.R) als abhängigkeitsfreies SVG.

Prüfungen, Meldungen, Beschriftungen und alle berechneten Werte (``_dashboard_returns``,
Kennzahlentexte, Monatsrenditen, rollierende Renditen und Korrelationen, Vergleichstabelle)
entsprechen SimLev 0.5.0. Nur das Zeichnen (Basisgrafik in R) ist wie in der Julia-Fassung
(``julia/src/dashboard.jl``) als SVG nachgebaut; Schriftgrößen und Ränder sind angenähert.
``plot_dashboard`` liefert ein :class:`simlev.svg.SimLevPlot` mit den dargestellten Daten je
Panel in ``data``. Hier stehen die Datenfunktionen und Panels; die Zeichenhilfen kommen aus
``svg.py`` (Abschnitt „Stil Dashboard“).
"""
from __future__ import annotations

import math
import sys
import warnings
from typing import Any

import numpy as np

from ._r.rformat import r_deparse, r_format, r_round, r_sprintf
from ._r.rnum import NA_REAL, LD, r_cumprod, r_cumsum, r_mean, r_pow, r_prod, r_sd
from .svg import (SimLevPlot, _MONATE_KURZ, _Canvas, _Panel, _alpha, _area, _check_svg_file, _col, _col2rgba,
                  _date_ticks, _decimate, _empty_panel, _frame, _line, _polyline, _px, _py, _r_range, _rect,
                  _c, _svg, _svg_close, _svg_open, _svgcol, _svgop, _text, _title, _to_days, _warn_unknown_kw,
                  _write_svg, _yaxis, r_pretty)
from ._r.rformat import r_format1
from ._r.libm import exp as _libm_exp

__all__ = ["plot_dashboard", "export_dashboard", "r_pretty"]

DEFAULT_COLORS = {
    "primary": "#2E86AB",      # Blau
    "secondary": "#A23B72",    # Violett
    "positive": "#06A77D",     # Grün
    "negative": "#D62246",     # Rot
    "neutral": "#6C757D",      # Grau
    "background": "#F8F9FA",   # Hellgrau
    "grid": "#E9ECEF",         # Gitterlinien
}
_ALL_PANELS = ("performance", "drawdown", "distribution", "rolling", "monthly", "stats", "correlation", "comparison")
_DEFAULT_PANELS = ("performance", "drawdown", "distribution", "rolling", "monthly", "stats")


# ── Hilfen ───────────────────────────────────────────────────────────────────
def _stop(msg: str):
    raise ValueError(msg)


def _get(x: Any, name: str) -> Any:
    """``x$name`` (``None``, wenn das Element fehlt)."""
    try:
        return x[name]
    except (KeyError, TypeError, IndexError):
        return getattr(x, name, None)


def _len(v: Any) -> int:
    if v is None:
        return 0
    if np.isscalar(v):
        return 1
    try:
        return len(v)
    except TypeError:
        return 1


def _isnan(v: Any) -> bool:
    return v is None or (isinstance(v, (float, np.floating)) and math.isnan(v))


def _is_true(v: Any) -> bool:
    """``isTRUE(v)``."""
    return isinstance(v, (bool, np.bool_)) and bool(v)


def _dash_custom_layout(n: int) -> np.ndarray:
    """``.dash_custom_layout``: 1-2 Panels in einer Zeile, sonst 2 Spalten mit bis zu 4 Zeilen;
    freie Felder 0 (leer)."""
    nr = (1, 1, 2, 2, 3, 3, 4, 4)[n - 1]
    nc = math.ceil(n / nr)
    return np.array(list(range(1, n + 1)) + [0] * (nr * nc - n), dtype=int).reshape(nr, nc)


# ── Farben ──────────────────────────────────────────────────────────────────
def _deparse_col(v: Any) -> str:
    if v is None:          # None steht für NA (ein NULL-Element gäbe es in einer R-Liste nicht)
        return "NA"
    if isinstance(v, (float, np.floating)) and math.isnan(v):
        return "NA_real_"
    return r_deparse(v)


def _check_colors(colors: Any) -> dict:
    if colors is None:
        return dict(DEFAULT_COLORS)
    names = None
    if isinstance(colors, dict):
        names = list(colors.keys())
        items = list(colors.items())
    else:
        try:
            import pandas as pd
            if isinstance(colors, pd.Series):
                names = [str(k) for k in colors.index]
                items = list(zip(names, colors.tolist()))
        except ImportError:  # pragma: no cover
            pass
    if names is None or any(k == "" for k in names):
        _stop("plot.SimLevResult: colors muss eine benannte Liste (oder ein benannter Zeichenvektor) sein, "
              "z. B. list(primary = \"#003366\"); möglich: %s." % ", ".join(DEFAULT_COLORS))
    unk = [k for k in dict.fromkeys(names) if k not in DEFAULT_COLORS]
    if unk:
        _stop("plot.SimLevResult: unbekannte Farbe(n) %s in colors; möglich: %s."
              % (", ".join("'%s'" % k for k in unk), ", ".join(DEFAULT_COLORS)))

    def ok(v: Any) -> bool:
        if isinstance(v, (list, tuple, np.ndarray)):
            if len(v) != 1:
                return False
            v = v[0]
        if v is None or isinstance(v, (bool, np.bool_)):
            return False
        if isinstance(v, (float, np.floating)) and math.isnan(v):
            return False
        if not isinstance(v, (str, int, float, np.integer, np.floating)):
            return False
        try:
            _col2rgba(v)
        except (ValueError, TypeError):
            return False
        return True

    bad = [(k, v) for k, v in items if not ok(v)]
    if bad:
        _stop("plot.SimLevResult: ungültige Farbe(n) in colors: %s; erwartet je Element ein R-Farbname "
              "(z. B. \"navy\", siehe grDevices::colors()) oder ein Hex-Code \"#RRGGBB\" bzw. \"#RRGGBBAA\"."
              % ", ".join("%s = %s" % (k, _deparse_col(v)) for k, v in bad))
    out = dict(DEFAULT_COLORS)
    for k, v in items:
        out[k] = v[0] if isinstance(v, (list, tuple, np.ndarray)) else v
    return out


# ── Berechnete Daten ────────────────────────────────────────────────────────
def _dashboard_returns(x: Any) -> dict:
    """``.dashboard_returns``: Tagesrenditen wie in ``simulation()`` (einzahlungsbereinigt, aus
    ``twr_index``), aufgefüllte Tage ausgeschlossen, Beobachtungen je Jahr, Sparplan-Kennung,
    Einzahlungssumme und zeitgewichteter Index (ältere Ergebnisse: aus ``report$flows``)."""
    w = np.asarray(_get(x, "worth"), dtype=float).ravel()
    n = w.size
    report = _get(x, "report") or {}
    if len(report):
        flows = None
        for a in report.values():
            f = np.asarray(_get(a, "flows"), dtype=float).ravel()
            flows = f.copy() if flows is None else flows + f
    else:
        flows = np.zeros(n)
    if flows is None or flows.size != n:
        flows = np.zeros(n)
    twr_x = _get(x, "twr_index")
    has_twr = _len(twr_x) == n
    with np.errstate(divide="ignore", invalid="ignore"):
        if n < 2:
            all_r = np.zeros(0)
        elif has_twr:
            t = np.asarray(twr_x, dtype=float)
            all_r = t[1:] / t[:-1] - 1
        else:
            all_r = (w[1:] - w[:-1] - flows[1:]) / w[:-1]
    all_r = np.where(np.isfinite(all_r), all_r, 0.0)
    fx = _get(x, "filled")
    filled = np.asarray(fx, dtype=bool).ravel() if _len(fx) == n else np.zeros(n, dtype=bool)
    r = all_r[~filled[1:]] if n >= 1 else all_r
    dates = _get(x, "dates")
    if dates is not None and n >= 2:
        dd = np.asarray(dates).astype("datetime64[D]").astype(np.int64)
        years = float(dd[n - 1] - dd[0]) / 365.25
    else:
        years = 0.0
    ef = _get(x, "external_flows")
    if ef is not None:
        ext = _is_true(ef)
    else:
        ext = n >= 2 and bool(np.any(flows[1:][~np.isnan(flows[1:])] != 0))
    inv = _get(x, "invested")
    if _len(inv) == n:
        invested = np.asarray(inv, dtype=float)
    elif n:
        invested = w[0] + r_cumsum(np.concatenate(([0.0], flows[1:])))
    else:
        invested = np.zeros(0)
    if has_twr:
        twr = np.asarray(twr_x, dtype=float)
    elif n:
        twr = r_cumprod(np.concatenate(([1.0], 1 + all_r)))
    else:
        twr = np.zeros(0)
    ppy = r.size / years if years > 0 and r.size else 365.25
    return {"all_returns": all_r, "returns": r, "ppy": ppy, "external_flows": bool(ext),
            "invested": invested, "twr_index": twr}


def _format_amount(x: Any, signif3: bool = False) -> list[str]:
    """``format_amount``: Beträge in Tsd. bzw. Mio. (Achsenwerte exakt, Endwert mit 3 Stellen)."""
    out = []
    for z in np.atleast_1d(np.asarray(x, dtype=float)):
        u = 1e6 if abs(z) >= 1e6 else (1e3 if abs(z) >= 1e3 else 1.0)
        v = z / u
        if signif3:
            d = max(0.0, 2 - math.floor(math.log10(max(abs(v), 1))))
        else:
            d = 3
            for k in range(3):
                if abs(v - r_round(v, k)) < 1e-8 * max(1, abs(v)):
                    d = k
                    break
        out.append(r_sprintf("%.*f", int(d), v) + (" Mio." if u == 1e6 else (" Tsd." if u == 1e3 else "")))
    return out


def _r_cor(x: np.ndarray, y: np.ndarray) -> float:
    """``stats::cor(x, y)`` für zwei vollständige Vektoren (``cov_complete2`` in ``cov.c``)."""
    n = x.size

    def mean(v):
        s = LD(0)
        for a in v:
            s += LD(a)
        t = s / LD(n)
        if math.isfinite(float(t)):
            s = LD(0)
            for a in v:
                s += LD(a) - t
            t = t + s / LD(n)
        return float(t)
    xm, ym = mean(x), mean(y)
    n1 = n - 1
    s = LD(0)
    for a, b in zip(x, y):
        s += LD(a - xm) * LD(b - ym)
    ans = float(s / LD(n1))

    def sdev(v, m):
        s = LD(0)
        for a in v:
            s += LD(a - m) * LD(a - m)
        s /= LD(n1)
        return float(np.sqrt(s))
    sx, sy = sdev(x, xm), sdev(y, ym)
    if sx == 0 or sy == 0:
        return math.nan
    ans /= (sx * sy)
    return min(max(ans, -1.0), 1.0)


def _dates_of(x: Any, n: int) -> np.ndarray:
    d = _get(x, "dates")
    if d is None:
        return np.arange(1, n + 1).astype("datetime64[D]")
    return np.asarray(d).astype("datetime64[D]")


def _tot_ret(r: Any) -> float:
    f = _dashboard_returns(r)
    if f["external_flows"]:
        return float(f["twr_index"][-1]) - 1
    w = np.asarray(_get(r, "worth"), dtype=float)
    return float(w[-1] / w[0] - 1)


def _ann_vol(r: Any) -> float:
    sd = _get(r, "statistics")["sd"]
    if _isnan(sd):
        return math.nan
    return sd * math.sqrt(_dashboard_returns(r)["ppy"])


def _stats_sections(x: Any, compare: Any = None) -> dict[str, list[str]]:
    """Texte des Kennzahlen-Panels (Abschnitt → Zeilen) wie in R."""
    dash = _dashboard_returns(x)
    ext = dash["external_flows"]
    st = _get(x, "statistics")
    worth = np.asarray(_get(x, "worth"), dtype=float)
    n_days = worth.size
    dd = np.asarray(_get(x, "drawdowns"), dtype=float)
    inv = _get(x, "invested")
    if _len(inv) == n_days:
        s0 = 0.0
        for a in (_get(x, "report") or {}).values():
            f = _get(a, "flows")
            s0 += float(np.asarray(f, dtype=float)[0]) if _len(f) == n_days else 0.0
        start = r_sprintf("Startkapital: %.2f EUR", float(np.asarray(inv, dtype=float)[0]) - s0)
    else:
        start = r_sprintf("Depotwert Starttag: %.2f EUR", float(worth[0]))
    depot = [start, r_sprintf("Endwert: %.2f EUR", float(worth[-1]))]
    if ext:
        depot.append(r_sprintf("Eingezahlt: %.2f EUR", float(dash["invested"][-1])))
    depot.append("Dauer: %d Tage" % n_days)
    stats = {
        "Rendite": [
            r_sprintf("CAGR (geldgew.): %+.2f%%" if ext else "CAGR: %+.2f%%", _get(x, "cagr") * 100),
            r_sprintf("TTWROR: %+.2f%%", _get(x, "ttwror") * 100),
            r_sprintf("Gesamtrendite (TWR): %+.2f%%" if ext else "Gesamtrendite: %+.2f%%", _tot_ret(x) * 100),
        ],
        "Risiko": [
            r_sprintf("Max. Drawdown (TWR): %.2f%%" if ext else "Max. Drawdown: %.2f%%", float(np.max(dd)) * 100),
            r_sprintf("Volatilität je Tag: %.2f%%", st["sd"] * 100),
            r_sprintf("Volatilität p. a.: %.2f%%", _ann_vol(x) * 100),
        ],
        "Renditeprofil": [
            r_sprintf("Sharpe Ratio: %.2f", st["sharpe"]),
            r_sprintf("Schiefe: %.2f", st["skewness"]),
            r_sprintf("Wölbung: %.2f", st["kurtosis"]),
        ],
        "Depot": depot,
    }
    if compare is not None:
        stats["Vergleich"] = [
            r_sprintf("Diff. CAGR: %+.2f%%", (_get(x, "cagr") - _get(compare, "cagr")) * 100),
            r_sprintf("Diff. Gesamtrendite: %+.2f%%", (_tot_ret(x) - _tot_ret(compare)) * 100),
            r_sprintf("Diff. Volatilität: %+.2f%%", (_ann_vol(x) - _ann_vol(compare)) * 100),
        ]
    return stats


def _comparison_rows(x: Any, compare: Any, colors: dict | None = None) -> list[dict]:
    """Zeilen des Panels „Strategievergleich“: Kennzahl, Werte, Differenz und deren Farbe."""
    col = colors or DEFAULT_COLORS
    ext_any = _dashboard_returns(x)["external_flows"] or _dashboard_returns(compare)["external_flows"]
    metrics = ["CAGR (MWR)" if ext_any else "CAGR", "Max. DD (TWR)" if ext_any else "Max. DD", "Volatilität", "Sharpe"]
    lower_better = (False, True, True, False)

    def vals(r):
        return [_get(r, "cagr") * 100, float(np.max(np.asarray(_get(r, "drawdowns"), dtype=float))) * 100,
                _ann_vol(r) * 100, _get(r, "statistics")["sharpe"]]
    a, b = vals(x), vals(compare)
    rows = []
    for i, m in enumerate(metrics):
        d = a[i] - b[i]
        better = d < 0 if lower_better[i] else d > 0
        if not math.isfinite(d) or r_round(d, 2) == 0:
            dc = col["neutral"]
        else:
            dc = col["positive"] if better else col["negative"]
        rows.append({"metric": m, "v1": r_sprintf("%.2f", a[i]), "v2": r_sprintf("%.2f", b[i]),
                     "diff": r_sprintf("%+.2f", d), "diff_col": dc})
    return rows


def _rolling_returns(x: Any) -> dict | None:
    """Rollierende Renditen (bis 30 Tage, kalendergenau annualisiert); ``None`` bei zu wenigen Daten."""
    worth = np.asarray(_get(x, "worth"), dtype=float)
    n_days = worth.size
    dates = _dates_of(x, n_days).astype(np.int64)
    window = max(2, min(30, n_days // 10))
    if n_days <= window:
        return {"window": window, "values": None}
    growth = r_cumprod(1 + np.concatenate(([0.0], _dashboard_returns(x)["all_returns"])))
    vals = np.empty(n_days - window + 1)
    for j, i in enumerate(range(window, n_days + 1)):
        days = float(dates[i - 1] - dates[i - window])
        vals[j] = (r_pow(growth[i - 1] / growth[i - window], 365.25 / days) - 1) * 100
    return {"window": window, "values": vals, "idx": np.arange(window - 1, n_days)}


def _monthly_matrix(x: Any) -> tuple[list[str], np.ndarray]:
    """Monatsrenditen in Prozent (Jahre × 12), verkettete einzahlungsbereinigte Tagesrenditen."""
    worth = np.asarray(_get(x, "worth"), dtype=float)
    dts = _dates_of(x, worth.size)
    ym = [str(d)[:7] for d in dts]
    month_ret = np.concatenate(([0.0], _dashboard_returns(x)["all_returns"]))
    groups: dict[str, list[float]] = {}
    for k, v in zip(ym, month_ret):
        groups.setdefault(k, []).append(float(v))
    keys = sorted(groups)
    years = list(dict.fromkeys(k[:4] for k in keys))
    mat = np.full((len(years), 12), np.nan)
    for k in keys:
        mat[years.index(k[:4]), int(k[5:7]) - 1] = (r_prod(1 + np.asarray(groups[k])) - 1) * 100
    return years, mat


def _correlation(x: Any, compare: Any) -> dict | None:
    """Rollierende Korrelation der bereinigten Tagesrenditen; ``None`` bei zu wenigen Daten."""
    n_days = np.asarray(_get(x, "worth")).size
    rc_x = _dashboard_returns(x)["all_returns"]
    rc_c = _dashboard_returns(compare)["all_returns"]

    def fill_of(r):
        f = _get(r, "filled")
        return np.asarray(f, dtype=bool)[1:] if _len(f) == n_days else np.zeros(max(0, n_days - 1), dtype=bool)
    ok = ~(fill_of(x) | fill_of(compare))
    rx, ry = rc_x[ok], rc_c[ok]
    m = rx.size
    k = min(252, m // 4)
    if not (m >= 40 and k >= 10):
        return None

    def win(v):
        cs = np.concatenate(([0.0], r_cumsum(v)))
        return cs[k:m + 1] - cs[0:m - k + 1]
    sx, sy, sxx, syy, sxy = win(rx), win(ry), win(rx * rx), win(ry * ry), win(rx * ry)
    vx = k * sxx - sx * sx
    vy = k * syy - sy * sy
    with np.errstate(divide="ignore", invalid="ignore"):
        rho = np.where((vx > 0) & (vy > 0), (k * sxy - sx * sy) / np.sqrt(np.maximum(vx, 0) * np.maximum(vy, 0)),
                       NA_REAL)                                    # R: NA_real_
    rho = np.minimum(np.maximum(rho, -1), 1)
    dts = _dates_of(x, n_days)
    rho_dates = dts[1:][ok][k - 1:m]
    rho_all = _r_cor(rx, ry) if r_sd(rx) > 0 and r_sd(ry) > 0 else NA_REAL
    return {"k": k, "rho": rho, "dates": rho_dates, "rho_all": rho_all}


# ── Panels (wie julia/src/dashboard.jl) ─────────────────────────────────────
# Jede Panel-Funktion zeichnet in den Canvas und liefert die dargestellten Werte als
# DataFrame (nicht ausgedünnt, unskaliert wie im Ergebnisobjekt bzw. wie berechnet).

def _frame_of(**cols):
    import pandas as pd
    return pd.DataFrame(cols)


def _no_dates():
    return np.array([], dtype="datetime64[D]")


def _panel_performance(c, cell, x, compare, dash):
    col = c.col
    worth = np.asarray(_get(x, "worth"), dtype=float)
    ext = dash["external_flows"]
    dates = _dates_of(x, worth.size)
    xs = _to_days(dates)
    cw = np.asarray(_get(compare, "worth"), dtype=float) if compare is not None else None
    allv = np.concatenate([worth] + ([cw] if cw is not None else []) + ([dash["invested"]] if ext else []))
    allv = allv[np.isfinite(allv)]
    y_rng = (float(allv.min()), float(allv.max()))
    lo, hi = _r_range(*y_rng)
    p = _Panel(*cell, xs[0], xs[-1], lo, hi)
    ticks = [float(t) for t in r_pretty(*y_rng) if lo <= t <= hi]
    _frame(c, p, title="Wertentwicklung des Depots", ylabel="Depotwert (EUR)", yticks=ticks,
           ylabels=_format_amount(ticks), xticks=_date_ticks(xs[0], xs[-1]))
    dx, dy = _decimate(xs, worth)
    _area(c, p, dx, dy, float(np.min(worth)), _alpha(col["primary"], 0x30))
    _polyline(c, p, dx, dy, color=_col(col["primary"]), width=2.5)
    if ext:
        _polyline(c, p, *_decimate(xs, dash["invested"]), color=_col(col["neutral"]), width=1.5, dash="2,3",
                  step=True)
    legend = []
    if cw is not None:
        _polyline(c, p, *_decimate(xs, cw), color=_col(col["secondary"]), width=2.5, dash="8,5")
        legend = [("Strategie 1", _col(col["primary"]), ""), ("Strategie 2", _col(col["secondary"]), "8,5")]
        if ext:
            legend.append(("Einzahlungen", _col(col["neutral"]), "2,3"))
    elif ext:
        legend = [("Depotwert", _col(col["primary"]), ""), ("Einzahlungen", _col(col["neutral"]), "2,3")]
    if legend:
        _rect(c, p.x0 + 6, p.y0 + 6, 130, 8 + 16 * len(legend), fill="white", stroke=_col(col["grid"]))
        for i, (lab, lc, ld) in enumerate(legend):
            yy = p.y0 + 14 + 16 * i
            _line(c, p.x0 + 12, yy, p.x0 + 36, yy, color=lc, width=2, dash=ld)
            _text(c, p.x0 + 42, yy, lab, size=10)
    _text(c, p.x0 + p.w + 4, _py(p, worth[-1]), _format_amount(worth[-1], signif3=True)[0], size=9,
          color=_col(col["primary"]), weight="bold", bg=_alpha(col["background"], 0xD9))
    cols = {"date": dates, "strategy": worth}
    if cw is not None:
        cols["compare"] = cw
    if ext:
        cols["invested"] = np.asarray(dash["invested"], dtype=float)
    return _frame_of(**cols)


def _panel_drawdown(c, cell, x, dash):
    col = c.col
    ddx = np.asarray(_get(x, "drawdowns"), dtype=float)
    dates = _dates_of(x, ddx.size)
    xs = _to_days(dates)
    dd = ddx * 100
    lo, hi = _r_range(float(np.min(-dd)) * 1.1, 0.0)
    p = _Panel(*cell, xs[0], xs[-1], lo, hi)
    yt, yl = _yaxis(lo, hi)
    _frame(c, p, title="Drawdown-Analyse (zeitgewichtet)" if dash["external_flows"] else "Drawdown-Analyse",
           ylabel="Drawdown (%)", yticks=yt, ylabels=yl, xticks=_date_ticks(xs[0], xs[-1]))
    dx, dy = _decimate(xs, -dd)
    _area(c, p, dx, dy, 0.0, _alpha(col["negative"], 0x40))
    _polyline(c, p, dx, dy, color=_col(col["negative"]), width=2)
    max_dd = float(np.max(dd))
    _line(c, p.x0, _py(p, -max_dd), p.x0 + p.w, _py(p, -max_dd), color=_col(col["negative"]), width=1.5, dash="6,4")
    _text(c, p.x0 + 4, _py(p, -max_dd) - 9, r_sprintf("Max.: %.1f%%", max_dd), color=_col(col["negative"]),
          weight="bold", bg=_alpha(col["background"], 0xD9))
    return _frame_of(date=dates, drawdown=ddx)


def _panel_distribution(c, cell, x, dash):
    col = c.col
    if dash["returns"].size < 3:
        _empty_panel(c, _Panel(*cell, 0, 1, 0, 1), "Verteilung der Tagesrenditen")
        return _frame_of(**{"return": np.zeros(0)})
    rets = dash["returns"] * 100
    lo, hi = float(rets.min()), float(rets.max())
    br = [float(v) for v in r_pretty(lo, hi, 50, min_n=1)]
    if len(br) < 2:
        br = [lo, lo + 1 if hi == lo else hi]
    counts = [0] * (len(br) - 1)
    bra = np.asarray(br)
    for v in rets.tolist():
        j = int(np.searchsorted(bra, v, side="left")) - 1      # rechts geschlossene Klassen (wie hist())
        j = min(max(j, 0), len(counts) - 1)
        counts[j] += 1
    ymax = max(counts) * 1.04
    p = _Panel(*cell, br[0], br[-1], 0.0, ymax)
    yt, yl = _yaxis(0.0, max(counts))
    xt = r_pretty(br[0], br[-1])
    _frame(c, p, title="Verteilung der Tagesrenditen", xlabel="Tagesrendite (%)", ylabel="Häufigkeit",
           yticks=yt, ylabels=yl, xticks=[(float(t), r_format1(float(t))) for t in xt if br[0] <= t <= br[-1]],
           grid=False)
    f = _alpha(col["primary"], 0x80)
    for j, cnt in enumerate(counts):
        if cnt == 0:
            continue
        x0 = _px(p, br[j])
        x1 = _px(p, br[j + 1])
        _svg(c, "<rect x=\"%s\" y=\"%s\" width=\"%s\" height=\"%s\" fill=\"%s\" fill-opacity=\"%s\" stroke=\"%s\" "
                "stroke-width=\"0.6\"/>" % (_c(x0), _c(_py(p, cnt)), _c(x1 - x0), _c(_py(p, 0) - _py(p, cnt)),
                                            _svgcol(f), _svgop(f), _col(col["primary"])))
    mu, sd = r_mean(rets), r_sd(rets)
    if sd > 0:
        n = rets.size
        xsq = [lo + (hi - lo) * i / 99 for i in range(100)]
        yn = []
        for v in xsq:
            z = (v - mu) / sd
            yn.append(_libm_exp(-0.5 * (z * z)) / (sd * math.sqrt(2 * math.pi)) * n * (hi - lo) / 50)
        _polyline(c, p, xsq, yn, color=_col(col["secondary"]), width=2, dash="6,4")
    _line(c, _px(p, mu), p.y0, _px(p, mu), p.y0 + p.h, color=_col(col["positive"]), width=2, dash="6,4")
    st = _get(x, "statistics")
    lines_ = [r_sprintf("Mittel: %.2f%%", mu), r_sprintf("Std.-Abw.: %.2f%%", sd),
              r_sprintf("Schiefe: %.2f", st["skewness"]), r_sprintf("Wölbung: %.2f", st["kurtosis"])]
    for i, t in enumerate(lines_):
        _text(c, p.x0 + p.w - 6, p.y0 + 12 + 14 * i, t, size=10, color=_col(col["primary"]), anchor="end",
              bg=_alpha(col["background"], 0xD9))
    return _frame_of(**{"return": np.asarray(dash["returns"], dtype=float)})


def _panel_rolling(c, cell, x, dash):
    col = c.col
    rr = _rolling_returns(x)
    if rr["values"] is None:
        _empty_panel(c, _Panel(*cell, 0, 1, 0, 1), "Rollierende Renditen (annualisiert)")
        return _frame_of(date=_no_dates(), return_pct=np.zeros(0))
    worth = np.asarray(_get(x, "worth"), dtype=float)
    dates = _dates_of(x, worth.size)
    xs = _to_days(dates)
    rd = xs[rr["idx"]]
    vals = np.asarray(rr["values"], dtype=float)
    ext = dash["external_flows"]
    cagr_pct = (_get(x, "ttwror") if ext else _get(x, "cagr")) * 100
    fin = math.isfinite(cagr_pct)
    fv = np.concatenate([vals, [cagr_pct] if fin else [], [0.0]])
    fv = fv[np.isfinite(fv)]
    lo, hi = _r_range(float(fv.min()), float(fv.max()))
    p = _Panel(*cell, xs[0], xs[-1], lo, hi)
    yt, yl = _yaxis(lo, hi)
    _frame(c, p, title="Rollierende %d-Tage-Renditen (annualisiert)" % rr["window"], ylabel="Rendite p. a. (%)",
           yticks=yt, ylabels=yl, xticks=_date_ticks(xs[0], xs[-1]))
    _line(c, p.x0, _py(p, 0), p.x0 + p.w, _py(p, 0), color=_col(col["neutral"]), dash="6,4")
    with np.errstate(invalid="ignore"):
        pos = np.where(vals >= 0, vals, np.nan)
        neg = np.where(vals < 0, vals, np.nan)
    _polyline(c, p, *_decimate(rd, pos), color=_col(col["positive"]), width=1.5)
    _polyline(c, p, *_decimate(rd, neg), color=_col(col["negative"]), width=1.5)
    if fin:
        _line(c, p.x0, _py(p, cagr_pct), p.x0 + p.w, _py(p, cagr_pct), color=_col(col["primary"]), width=1.5,
              dash="6,4")
        _text(c, p.x0 + 4, _py(p, cagr_pct) - 9, r_sprintf("TTWROR: %.1f%%" if ext else "CAGR: %.1f%%", cagr_pct),
              size=10, color=_col(col["primary"]), weight="bold", bg=_alpha(col["background"], 0xD9))
    return _frame_of(date=dates[rr["idx"]], return_pct=vals)


def _panel_monthly(c, cell, x):
    col = c.col
    years, mat = _monthly_matrix(x)
    ny = len(years)
    p = _Panel(*cell, 0.5, 12.5, 0.5, ny + 0.5)
    _title(c, p, "Monatsrenditen (%)")
    neg = _col2rgba(col["negative"])
    pos = _col2rgba(col["positive"])
    white = (1.0, 1.0, 1.0)

    def heat(v):
        t = (min(max(v, -10.0), 10.0) + 10) / 20
        k = min(max(math.floor(t * 20), 0), 19) / 19       # 20 Farbstufen
        a, b, u = (neg, white, k * 2) if k < 0.5 else (white, pos, (k - 0.5) * 2)
        return _svgcol((a[0] + (b[0] - a[0]) * u, a[1] + (b[1] - a[1]) * u, a[2] + (b[2] - a[2]) * u, 1.0))
    cw = p.w / 12
    ch = p.h / max(ny, 1)
    ry, rm, rv = [], [], []
    for i in range(ny):
        for j in range(12):
            v = float(mat[i, j])
            if math.isnan(v):
                continue
            ry.append(int(years[i]))
            rm.append(j + 1)
            rv.append(v)
            x0 = p.x0 + j * cw
            y0 = p.y0 + p.h - (i + 1) * ch
            _rect(c, x0, y0, cw, ch, fill=heat(v))
            if ch >= 9:
                _text(c, x0 + cw / 2, y0 + ch / 2, r_sprintf("%.1f", v), size=min(9.0, ch * 0.7), anchor="middle",
                      color="white" if abs(v) > 5 else "black")
    _rect(c, p.x0, p.y0, p.w, p.h, stroke="#CED4DA", sw=0.8)
    for j in range(12):
        _text(c, p.x0 + (j + 0.5) * cw, p.y0 + p.h + 8, _MONATE_KURZ[j], size=9, color="#495057", anchor="end",
              rot=-90)
    step = max(1, -(-ny // 12))
    for i in range(0, ny, step):
        _text(c, p.x0 - 6, p.y0 + p.h - (i + 0.5) * ch, years[i], size=9, color="#495057", anchor="end")
    _text(c, p.x0 + p.w / 2, p.y0 + p.h + 40, "Monat", size=11, color="#495057", anchor="middle")
    _text(c, p.x0 - 44, p.y0 + p.h / 2, "Jahr", size=11, color="#495057", anchor="middle", rot=-90)
    return _frame_of(year=np.asarray(ry, dtype=np.int64), month=np.asarray(rm, dtype=np.int64),
                     return_pct=np.asarray(rv, dtype=float))


def _panel_stats(c, cell, x, compare):
    col = c.col
    p = _Panel(*cell, 0, 1, 0, 1)
    _title(c, p, "Kennzahlen")
    secs = list(_stats_sections(x, compare).items())

    def nl(g):
        return sum(1 + 0.85 * len(ls) + 0.5 for _, ls in g)
    two = nl(secs) > 16
    h = math.ceil(len(secs) / 2)
    groups = [secs[:h], secs[h:]] if two else [secs]
    lh = min(0.88 / max(nl(g) for g in groups), 0.07) * p.h
    for k, g in enumerate(groups):
        x0 = p.x0 + (0.05 + k * 0.46) * p.w
        yy = p.y0 + 0.05 * p.h
        for s, ls in g:
            _text(c, x0, yy + 0.5 * lh, s, size=12, color=_col(col["primary"]), weight="bold")
            yy += lh
            for v in ls:
                _text(c, x0 + 0.03 * p.w, yy + 0.425 * lh, v, size=10.5, color=_col(col["neutral"]))
                yy += 0.85 * lh
            yy += 0.5 * lh
    _rect(c, p.x0 + 0.02 * p.w, p.y0 + 0.02 * p.h, 0.96 * p.w, 0.96 * p.h, stroke=_col(col["grid"]), sw=2)
    sec, lab, val = [], [], []
    for s, ls in secs:
        for v in ls:
            a, _, b = v.partition(": ")
            sec.append(s)
            lab.append(a)
            val.append(b)
    return _frame_of(section=sec, label=lab, value=val)


def _panel_correlation(c, cell, x, compare):
    col = c.col
    r = _correlation(x, compare)
    if r is None:
        _empty_panel(c, _Panel(*cell, 0, 1, 0, 1), "Rollierende Korrelation")
        return _frame_of(date=_no_dates(), correlation=np.zeros(0))
    worth = np.asarray(_get(x, "worth"), dtype=float)
    xs = _to_days(_dates_of(x, worth.size))
    lo, hi = _r_range(-1.0, 1.0)
    p = _Panel(*cell, xs[0], xs[-1], lo, hi)
    yt, yl = _yaxis(-1.0, 1.0)
    _frame(c, p, title="Rollierende Korrelation (%d Tage)" % r["k"], ylabel="Korrelation", yticks=yt, ylabels=yl,
           xticks=_date_ticks(xs[0], xs[-1]))
    _line(c, p.x0, _py(p, 0), p.x0 + p.w, _py(p, 0), color=_col(col["neutral"]), dash="6,4")
    _polyline(c, p, *_decimate(_to_days(r["dates"]), r["rho"]), color=_col(col["primary"]), width=1.5)
    ra = float(r["rho_all"])
    if math.isfinite(ra):
        _line(c, p.x0, _py(p, ra), p.x0 + p.w, _py(p, ra), color=_col(col["secondary"]), width=1.5, dash="6,4")
        _text(c, p.x0 + 4, _py(p, ra) + (9 if ra > 0.8 else -9), r_sprintf("Gesamt: %.2f", ra), size=10,
              color=_col(col["secondary"]), weight="bold", bg=_alpha(col["background"], 0xD9))
    return _frame_of(date=np.asarray(r["dates"]).astype("datetime64[D]"), correlation=np.asarray(r["rho"], dtype=float))


def _panel_comparison(c, cell, x, compare):
    col = c.col
    p = _Panel(*cell, 0, 1, 0, 1)
    _title(c, p, "Strategievergleich")
    rows = _comparison_rows(x, compare, col)

    def X(f):  # noqa: N802
        return p.x0 + f * p.w

    def Y(f):  # noqa: N802
        return p.y0 + (1 - f) * p.h
    _text(c, X(0.35), Y(0.88), "Strategie 1", color=_col(col["primary"]), weight="bold", anchor="end")
    _text(c, X(0.65), Y(0.88), "Strategie 2", color=_col(col["secondary"]), weight="bold", anchor="end")
    _text(c, X(0.95), Y(0.88), "Differenz", color=_col(col["neutral"]), weight="bold", anchor="end")
    for i, r in enumerate(rows):
        yy = 0.70 - (0.70 - 0.16) * i / max(len(rows) - 1, 1)
        _text(c, X(0.05), Y(yy), r["metric"], weight="bold")
        _text(c, X(0.35), Y(yy), r["v1"], color=_col(col["primary"]), anchor="end")
        _text(c, X(0.65), Y(yy), r["v2"], color=_col(col["secondary"]), anchor="end")
        _text(c, X(0.95), Y(yy), r["diff"], color=_col(r["diff_col"]), weight="bold", anchor="end")
    _rect(c, X(0.02), Y(0.98), 0.96 * p.w, 0.96 * p.h, stroke=_col(col["grid"]), sw=2)
    return _frame_of(label=[r["metric"] for r in rows], value=[r["v1"] for r in rows],
                     compare=[r["v2"] for r in rows], diff=[r["diff"] for r in rows])


# ── Zeichnen ────────────────────────────────────────────────────────────────
def plot_dashboard(x, style: Any = ("full", "compact", "custom"), panels: Any = None, compare=None,
                   colors: Any = None, width: float = 1400, height: float | None = None, file: Any = None,
                   **kwargs) -> SimLevPlot:
    """``plot.SimLevResult``: mehrteiliges Dashboard als SVG (:class:`simlev.svg.SimLevPlot`).

    ``style``: ``"full"`` (alle Panels), ``"compact"`` (4 Kern-Panels) oder ``"custom"``
    (Panels aus ``panels``; eindeutige Abkürzungen erlaubt). ``compare``: zweites Ergebnis über
    dieselben Tage. ``colors``: ``dict`` mit eigenen Farben (R-Farbname oder Hex-Code),
    nicht genannte aus dem Standard. ``width``, ``height``: Größe in Pixeln (Standard 1400 und
    10/14 bzw. 8/12 der Breite). ``file``: zusätzlich als SVG-Datei speichern (nur Endung
    ``.svg``); ohne ``file`` wird nichts geschrieben. Unbekannte Schlüsselwörter ergeben eine
    Warnung. Auch über ``res.plot(...)`` bzw. ``simlev.plot(res, ...)``.

    ``data`` des Ergebnisses enthält je gezeichnetem Panel (Zeichenreihenfolge) eine Tabelle:
    ``performance`` (``date``, ``strategy``, ggf. ``compare``, ``invested``), ``drawdown``
    (``date``, ``drawdown``), ``distribution`` (``return``), ``rolling`` (``date``,
    ``return_pct``), ``monthly`` (``year``, ``month``, ``return_pct``), ``stats``
    (``section``, ``label``, ``value``), ``correlation`` (``date``, ``correlation``),
    ``comparison`` (``label``, ``value``, ``compare``, ``diff``).
    """
    _warn_unknown_kw("plot_dashboard", list(kwargs))
    if file is not None:
        _check_svg_file(file, "plot_dashboard")
    from .config import _match_arg, _pmatch
    style = _match_arg(style, ("full", "compact", "custom"), "style")
    panels_given = panels is not None
    if panels is None:
        panels = list(_DEFAULT_PANELS)
    pv = [panels] if isinstance(panels, str) else panels
    if not isinstance(pv, (list, tuple, np.ndarray)) or not len(pv) or not all(isinstance(p, str) for p in pv):
        shown = "" if pv is None else ", ".join(r_format(list(pv) if isinstance(pv, (list, tuple, np.ndarray))
                                                          else [pv]))
        _stop("plot.SimLevResult: panels muss ein Zeichenvektor sein (erhalten: %s); möglich: %s."
              % (shown, ", ".join('"%s"' % p for p in _ALL_PANELS)))
    pm = [_pmatch(p, _ALL_PANELS) for p in pv]
    if any(i is None for i in pm):
        _stop("plot.SimLevResult: unbekannte(s) Panel(s) %s in panels; möglich: %s."
              % (", ".join('"%s"' % p for p, i in zip(pv, pm) if i is None),
                 ", ".join('"%s"' % p for p in _ALL_PANELS)))
    panels = list(dict.fromkeys(_ALL_PANELS[i] for i in pm))
    if panels_given and style != "custom":
        warnings.warn("plot.SimLevResult: panels wirkt nur mit style = \"custom\" und wird bei style = \"%s\" ignoriert."
                      % style, stacklevel=2)
    col = _check_colors(colors)

    from .result import SimLevResult
    xw = _get(x, "worth")
    if compare is not None and (not isinstance(compare, SimLevResult) or _len(_get(compare, "worth")) != _len(xw)):
        if not isinstance(compare, SimLevResult):
            from .engine import _r_class_name
            why = "erhalten: Objekt der Klasse '%s'" % _r_class_name(compare)
        else:
            why = "%d statt %d Tage" % (_len(_get(compare, "worth")), _len(xw))
        _stop("plot.SimLevResult: compare muss ein SimLevResult über dieselben Tage wie x sein (%s); "
              "NULL = kein Vergleich." % why)
    skipped: list[str] = []
    if style == "custom" and compare is None and any(p in ("correlation", "comparison") for p in panels):
        skipped = [p for p in panels if p in ("correlation", "comparison")]
        warnings.warn("plot.SimLevResult: Panel(s) %s nicht gezeichnet: %s ein Vergleichsergebnis (compare)."
                      % (", ".join('"%s"' % p for p in skipped), "benötigen" if len(skipped) > 1 else "benötigt"),
                      stacklevel=2)
        panels = [p for p in panels if p not in skipped]

    if style == "full":
        selected = (["performance", "drawdown", "distribution", "rolling", "monthly", "correlation", "stats",
                     "comparison"] if compare is not None else list(_DEFAULT_PANELS))
        layout = np.arange(1, len(selected) + 1).reshape(-1, 2)
    elif style == "compact":
        selected = ["performance", "drawdown", "distribution", "stats"]
        layout = np.array([[1, 2], [3, 4]])
    else:
        selected = panels
        layout = _dash_custom_layout(len(panels)) if panels else np.array([[1]])

    nr, nc = layout.shape
    W = float(width)
    H = (W * 10 / 14 if nr >= 3 else W * 8 / 12) if height is None else float(height)
    c = _Canvas(col)
    bg = _col2rgba(col["background"])
    _svg_open(c, W, H)
    _rect(c, 0, 0, W, H, fill=_svgcol(bg))
    cw = W / nc
    chh = H / nr

    def cell_of(slot):
        pos = np.argwhere(layout == slot)
        r0, c0 = (int(v) for v in pos.min(axis=0))
        r1, c1 = (int(v) for v in pos.max(axis=0))
        return (c0 * cw + 80, r0 * chh + 40, (c1 - c0 + 1) * cw - 130, (r1 - r0 + 1) * chh - 95)

    data: dict = {}
    if not selected:
        _text(c, W / 2, H / 2 - 8, "Keine zeichenbaren Panels:", size=13, color=_col(col["neutral"]), anchor="middle")
        _text(c, W / 2, H / 2 + 10, "%s ohne Vergleichsergebnis (compare)" % ", ".join(skipped), size=13,
              color=_col(col["neutral"]), anchor="middle")
    else:
        with np.errstate(all="ignore"):
            dash = _dashboard_returns(x)
            order = [p for p in ("performance", "drawdown", "distribution", "rolling", "monthly", "stats",
                                 "correlation", "comparison") if p in selected]
            for slot, pn in enumerate(order, start=1):
                cell = cell_of(slot)
                if pn == "performance":
                    data[pn] = _panel_performance(c, cell, x, compare, dash)
                elif pn == "drawdown":
                    data[pn] = _panel_drawdown(c, cell, x, dash)
                elif pn == "distribution":
                    data[pn] = _panel_distribution(c, cell, x, dash)
                elif pn == "rolling":
                    data[pn] = _panel_rolling(c, cell, x, dash)
                elif pn == "monthly":
                    data[pn] = _panel_monthly(c, cell, x)
                elif pn == "stats":
                    data[pn] = _panel_stats(c, cell, x, compare)
                elif pn == "correlation" and compare is not None:
                    data[pn] = _panel_correlation(c, cell, x, compare)
                elif pn == "comparison" and compare is not None:
                    data[pn] = _panel_comparison(c, cell, x, compare)
    d = SimLevPlot(_svg_close(c), data, x, "SimLevResult")
    if file is not None:
        _write_svg(file, d, "plot_dashboard")
    return d


def export_dashboard(x, filename: str = "dashboard.svg", width: float = 14, height: float = 10, **kwargs):
    """Dashboard als SVG-Datei speichern (Größe in Zoll wie in R, 100 px je Zoll).

    Weitere Argumente gehen an :func:`plot_dashboard` (unbekannte → Warnung). Es gibt nur SVG:
    Eine andere Dateiendung bricht vor dem Zeichnen mit einer Meldung ab. Meldung wie in R nach
    ``stderr``.
    """
    _check_svg_file(filename, "export_dashboard")
    d = plot_dashboard(x, width=width * 100, height=height * 100, **kwargs)
    _write_svg(filename, d, "export_dashboard")
    sys.stderr.write("export_dashboard: Dashboard gespeichert in %s\n" % filename)
    return None
