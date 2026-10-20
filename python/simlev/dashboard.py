"""Dashboard-Grafiken für SimLev-Ergebnisse (Port von plot_dashboard.R, matplotlib).

Prüfungen, Meldungen, Beschriftungen und alle berechneten Werte (``_dashboard_returns``,
Kennzahlentexte, Monatsrenditen, rollierende Renditen und Korrelationen, Vergleichstabelle)
entsprechen SimLev 0.5.0. Nur das Zeichnen selbst (Basisgrafik in R) ist mit matplotlib
nachgebaut; Schriftgrößen und Ränder sind daher angenähert.
"""
from __future__ import annotations

import math
import sys
import warnings
from typing import Any, Sequence

import numpy as np

from ._rnum import NA_REAL, LD, r_cumprod, r_cumsum, r_deparse, r_format, r_mean, r_pow, r_prod, r_round, r_sd, r_sprintf

__all__ = ["plot_dashboard", "export_dashboard", "export_html_dashboard", "r_pretty"]

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
_MONATE_KURZ = ("Jan", "Feb", "Mär", "Apr", "Mai", "Jun", "Jul", "Aug", "Sep", "Okt", "Nov", "Dez")
_R_PALETTE = ("black", "#DF536B", "#61D04F", "#2297E6", "#28E2E5", "#CD0BBC", "#F5C710", "gray62")


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


def r_pretty(lo: float, hi: float, n: int = 5, min_n: int | None = None) -> np.ndarray:
    """Nachbildung von R's ``pretty()`` (``R_pretty`` aus ``src/appl/pretty.c``)."""
    if not (math.isfinite(lo) and math.isfinite(hi)):
        return np.array([0.0])
    if hi < lo:
        lo, hi = hi, lo
    h, h5 = 1.5, 0.5 + 1.5 * 1.5
    eps = 1e-10
    if min_n is None:
        min_n = n // 3
    dx = hi - lo
    if dx == 0 and hi == 0:
        cell, i_small = 1.0, True
    else:
        cell = max(abs(lo), abs(hi))
        u = 1 + (1 / (1 + h) if h5 >= 1.5 * h + 0.5 else 1.5 / (1 + h5))
        u *= max(1, n) * sys.float_info.epsilon
        i_small = dx < cell * u * 3
    if i_small:
        if cell > 10:
            cell = 9 + cell / 10
        cell *= 0.75
        if min_n > 1:
            cell /= min_n
    else:
        cell = dx
        if n > 1:
            cell /= n
    base = 10.0 ** math.floor(math.log10(cell))
    unit = base
    if 2 * base - cell < h * (cell - unit):
        unit = 2 * base
        if 5 * base - cell < h5 * (cell - unit):
            unit = 5 * base
            if 10 * base - cell < h * (cell - unit):
                unit = 10 * base
    ns = math.floor(lo / unit + eps)
    nu = math.ceil(hi / unit - eps)
    while ns * unit > lo + eps * unit:
        ns -= 1
    while nu * unit < hi - eps * unit:
        nu += 1
    k = int(0.5 + nu - ns)
    if k < min_n:
        k = min_n - k
        if ns >= 0:
            nu += k // 2
            ns -= k // 2 + k % 2
        else:
            ns -= k // 2
            nu += k // 2 + k % 2
    return np.arange(ns, nu + 1) * unit


def _dash_custom_layout(n: int) -> np.ndarray:
    """``.dash_custom_layout``: 1-2 Panels in einer Zeile, sonst 2 Spalten mit bis zu 4 Zeilen;
    freie Felder 0 (leer)."""
    nr = (1, 1, 2, 2, 3, 3, 4, 4)[n - 1]
    nc = math.ceil(n / nr)
    return np.array(list(range(1, n + 1)) + [0] * (nr * nc - n), dtype=int).reshape(nr, nc)


# ── Farben (grDevices::col2rgb / adjustcolor) ───────────────────────────────
_COLOR_TABLE: dict[str, str] | None = None


def _color_table() -> dict[str, str]:
    global _COLOR_TABLE
    if _COLOR_TABLE is None:
        from importlib import resources
        tab = {}
        txt = resources.files("simlev").joinpath("data/r_colors.csv").read_text(encoding="utf-8")
        for line in txt.splitlines()[1:]:
            if line:
                name, hx = line.split(",")
                tab[name] = hx
        _COLOR_TABLE = tab
    return _COLOR_TABLE


def _col2rgba(v: Any) -> tuple[float, float, float, float]:
    """``grDevices::col2rgb(v, alpha = TRUE) / 255`` für einen Wert; Fehler wie in R (ValueError)."""
    if isinstance(v, (bool, np.bool_)):
        raise ValueError("invalid color name '%s'" % ("TRUE" if v else "FALSE"))
    if isinstance(v, (int, float, np.integer, np.floating)):
        f = float(v)
        if math.isnan(f):
            return (1.0, 1.0, 1.0, 0.0)
        if f < 0:
            raise ValueError("numerical color values must be >= 0, found %d" % int(f))
        i = int(f)
        if i == 0:
            raise ValueError("numerical color values must be positive")
        return _col2rgba(_R_PALETTE[(i - 1) % len(_R_PALETTE)])
    if not isinstance(v, str):
        raise ValueError("invalid color specification")
    if v.startswith("#"):
        if len(v) not in (7, 9):
            raise ValueError("invalid RGB specification")
        try:
            vals = [int(v[i:i + 2], 16) for i in range(1, len(v), 2)]
        except ValueError:
            raise ValueError("invalid hex digit in 'color' or 'lty'") from None
        if len(vals) == 3:
            vals.append(255)
        return tuple(c / 255 for c in vals)  # type: ignore[return-value]
    if v in ("NA", "transparent"):
        return (1.0, 1.0, 1.0, 0.0)
    if v[:1].isdigit():
        return _col2rgba(float(int(v)) if v.isdigit() else float("nan"))
    key = v.replace(" ", "").lower()
    hx = _color_table().get(key)
    if hx is None:
        raise ValueError("invalid color name '%s'" % v)
    return _col2rgba(hx)


def _alpha_col(col: Any, a: int) -> tuple[float, float, float, float]:
    """``adjustcolor(col, alpha.f = a / 255)``."""
    r, g, b, al = _col2rgba(col)
    return (r, g, b, al * a / 255)


def _rgba(col: Any) -> tuple[float, float, float, float]:
    return _col2rgba(col)


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
                       np.nan)
    rho = np.minimum(np.maximum(rho, -1), 1)
    dts = _dates_of(x, n_days)
    rho_dates = dts[1:][ok][k - 1:m]
    rho_all = _r_cor(rx, ry) if r_sd(rx) > 0 and r_sd(ry) > 0 else NA_REAL
    return {"k": k, "rho": rho, "dates": rho_dates, "rho_all": rho_all}


# ── Zeichnen ────────────────────────────────────────────────────────────────
def plot_dashboard(x, style: Any = ("full", "compact", "custom"), panels: Any = None, compare=None,
                   colors: Any = None, figsize: tuple[float, float] | None = None, fig=None,
                   show: bool = False, **kwargs):
    """``plot.SimLevResult``: mehrteiliges Dashboard; Rückgabe die ``matplotlib.figure.Figure``.

    ``style``: ``"full"`` (alle Panels), ``"compact"`` (4 Kern-Panels) oder ``"custom"``
    (Panels aus ``panels``; eindeutige Abkürzungen erlaubt). ``compare``: zweites Ergebnis über
    dieselben Tage. ``colors``: ``dict`` mit eigenen Farben (R-Farbname oder Hex-Code),
    nicht genannte aus dem Standard. Weitere Argumente werden wie ``...`` in R ignoriert.
    """
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

    import matplotlib.pyplot as plt
    own_fig = fig is None
    if own_fig:
        if figsize is None:
            figsize = (14, 10) if layout.shape[0] >= 3 else (12, 8)
        fig = plt.figure(figsize=figsize, facecolor=_rgba(col["background"]))
    else:
        fig.set_facecolor(_rgba(col["background"]))
    try:
        with warnings.catch_warnings():
            warnings.simplefilter("ignore")
            _draw(fig, x, compare, selected, layout, col, skipped)
            fig.tight_layout()
    except BaseException:
        if own_fig:
            plt.close(fig)
        raise
    if show:
        plt.show()
    return fig


def _draw(fig, x, compare, selected, layout, col, skipped):
    from matplotlib.colors import BoundaryNorm, LinearSegmentedColormap
    from matplotlib.patches import Rectangle

    nr, nc = layout.shape
    gs = fig.add_gridspec(nr, nc)
    # Reihenfolge der Layoutfelder: Panels werden in R in fester Folge gezeichnet und füllen die
    # Felder 1, 2, ... nacheinander
    draw_order = [p for p in ("performance", "drawdown", "distribution", "rolling", "monthly", "stats",
                              "correlation", "comparison") if p in selected]
    slot_of = {p: i + 1 for i, p in enumerate(draw_order)}
    bg = _rgba(col["background"])

    def ax_for(slot):
        pos = np.argwhere(layout == slot)
        r0, c0 = pos.min(axis=0)
        r1, c1 = pos.max(axis=0)
        ax = fig.add_subplot(gs[r0:r1 + 1, c0:c1 + 1])
        ax.set_facecolor(bg)
        return ax

    def title(ax, t):
        ax.set_title(t, color=_rgba(col["primary"]), fontsize=13, fontweight="bold")

    def grid(ax):
        ax.grid(True, color=_rgba(col["grid"]), linewidth=0.5)
        ax.set_axisbelow(True)

    def label_bg(ax, xx, yy, lab, colr, ha="left", va="bottom", size=10):
        ax.text(xx, yy, lab, color=_rgba(colr), fontsize=size, fontweight="bold", ha=ha, va=va,
                bbox=dict(facecolor=_alpha_col(col["background"], 0xD9), edgecolor="none", pad=1.5))

    def empty(ax, t):
        ax.set_axis_off()
        title(ax, t)
        ax.text(0.5, 0.5, "Zu wenige Daten", ha="center", va="center", fontsize=11, color=_rgba(col["neutral"]),
                transform=ax.transAxes)

    def r_range(lo, hi):     # yaxs = "r": 4 % Rand
        if lo == hi:
            return (lo - 1, hi + 1) if lo == 0 else (lo - 0.4 * abs(lo), hi + 0.4 * abs(hi))
        d = (hi - lo) * 0.04
        return lo - d, hi + d

    worth = np.asarray(_get(x, "worth"), dtype=float)
    n_days = worth.size
    dates = _dates_of(x, n_days)
    dash = _dashboard_returns(x)
    ext = dash["external_flows"]
    stats = _get(x, "statistics")

    if not selected:
        ax = ax_for(1)
        ax.set_axis_off()
        ax.text(0.5, 0.5, "Keine zeichenbaren Panels:\n%s ohne Vergleichsergebnis (compare)" % ", ".join(skipped),
                ha="center", va="center", fontsize=11, color=_rgba(col["neutral"]), transform=ax.transAxes)
        return

    if "performance" in slot_of:
        ax = ax_for(slot_of["performance"])
        allv = np.concatenate([worth] + ([np.asarray(_get(compare, "worth"), dtype=float)] if compare is not None
                                         else []) + ([dash["invested"]] if ext else []))
        allv = allv[np.isfinite(allv)]
        y_rng = (float(allv.min()), float(allv.max()))
        title(ax, "Wertentwicklung des Depots")
        grid(ax)
        ax.fill_between(dates, worth, np.full(n_days, worth.min()), color=_alpha_col(col["primary"], 0x30),
                        linewidth=0)
        (l1,) = ax.plot(dates, worth, color=_rgba(col["primary"]), linewidth=2.5)
        handles, labels = [l1], ["Depotwert"]
        if ext:
            (li,) = ax.step(dates, dash["invested"], where="post", color=_rgba(col["neutral"]), linewidth=1.5,
                            linestyle=":")
        if compare is not None:
            (l2,) = ax.plot(dates, np.asarray(_get(compare, "worth"), dtype=float), color=_rgba(col["secondary"]),
                            linewidth=2.5, linestyle="--")
            handles, labels = [l1, l2], ["Strategie 1", "Strategie 2"]
            if ext:
                handles.append(li)
                labels.append("Einzahlungen")
            ax.legend(handles, labels, loc="upper left", facecolor="white", edgecolor=_rgba(col["grid"]))
        elif ext:
            ax.legend([l1, li], ["Depotwert", "Einzahlungen"], loc="upper left", facecolor="white",
                      edgecolor=_rgba(col["grid"]))
        lo, hi = r_range(*y_rng)
        ax.set_ylim(lo, hi)
        ticks = r_pretty(*y_rng)
        ticks = ticks[(ticks >= lo) & (ticks <= hi)]
        ax.set_yticks(ticks)
        ax.set_yticklabels(_format_amount(ticks))
        ax.set_ylabel("Depotwert (EUR)")
        ax.annotate(_format_amount(worth[-1], signif3=True)[0], (dates[-1], worth[-1]), xytext=(6, 0),
                    textcoords="offset points", color=_rgba(col["primary"]), fontweight="bold", fontsize=9,
                    va="center", annotation_clip=False,
                    bbox=dict(facecolor=_alpha_col(col["background"], 0xD9), edgecolor="none", pad=1.5))

    if "drawdown" in slot_of:
        ax = ax_for(slot_of["drawdown"])
        dd = np.asarray(_get(x, "drawdowns"), dtype=float) * 100
        title(ax, "Drawdown-Analyse (zeitgewichtet)" if ext else "Drawdown-Analyse")
        grid(ax)
        ax.fill_between(dates, -dd, 0, color=_alpha_col(col["negative"], 0x40), linewidth=0)
        ax.plot(dates, -dd, color=_rgba(col["negative"]), linewidth=2)
        lo = float(np.min(-dd)) * 1.1
        ax.set_ylim(*(r_range(lo, 0.0)))
        max_dd = float(np.max(dd))
        ax.axhline(-max_dd, color=_rgba(col["negative"]), linestyle="--", linewidth=1.5)
        label_bg(ax, dates[0], -max_dd, r_sprintf("Max.: %.1f%%", max_dd), col["negative"])
        ax.set_ylabel("Drawdown (%)")

    if "distribution" in slot_of:
        ax = ax_for(slot_of["distribution"])
        if dash["returns"].size < 3:
            empty(ax, "Verteilung der Tagesrenditen")
        else:
            rets = dash["returns"] * 100
            lo, hi = float(rets.min()), float(rets.max())
            br = r_pretty(lo, hi, 50, min_n=1)
            ax.hist(rets, bins=br if br.size >= 2 else 1, color=_alpha_col(col["primary"], 0x80),
                    edgecolor=_rgba(col["primary"]))
            title(ax, "Verteilung der Tagesrenditen")
            mu, sd = r_mean(rets), r_sd(rets)
            xs = np.linspace(lo, hi, 100)
            if sd > 0:
                yn = np.array([math.exp(-0.5 * ((v - mu) / sd) ** 2) / (sd * math.sqrt(2 * math.pi)) for v in xs])
                ax.plot(xs, yn * rets.size * (hi - lo) / 50, color=_rgba(col["secondary"]), linewidth=2,
                        linestyle="--")
            ax.axvline(mu, color=_rgba(col["positive"]), linewidth=2, linestyle="--")
            txt = "\n".join([r_sprintf("Mittel: %.2f%%", mu), r_sprintf("Std.-Abw.: %.2f%%", sd),
                             r_sprintf("Schiefe: %.2f", stats["skewness"]),
                             r_sprintf("Wölbung: %.2f", stats["kurtosis"])])
            ax.text(0.98, 0.97, txt, transform=ax.transAxes, ha="right", va="top", color=_rgba(col["primary"]),
                    fontsize=9, bbox=dict(facecolor=_alpha_col(col["background"], 0xD9), edgecolor="none"))
            ax.set_xlabel("Tagesrendite (%)")
            ax.set_ylabel("Häufigkeit")

    if "rolling" in slot_of:
        ax = ax_for(slot_of["rolling"])
        rr = _rolling_returns(x)
        if rr["values"] is None:
            empty(ax, "Rollierende Renditen (annualisiert)")
        else:
            vals, rd = rr["values"], dates[rr["idx"]]
            title(ax, "Rollierende %d-Tage-Renditen (annualisiert)" % rr["window"])
            grid(ax)
            ax.axhline(0, color=_rgba(col["neutral"]), linestyle="--")
            pos = vals >= 0
            if pos.any():
                ax.plot(rd[pos], vals[pos], color=_rgba(col["positive"]), linewidth=1.5)
            if (~pos).any():
                ax.plot(rd[~pos], vals[~pos], color=_rgba(col["negative"]), linewidth=1.5)
            cagr_pct = (_get(x, "ttwror") if ext else _get(x, "cagr")) * 100
            if not _isnan(cagr_pct) and math.isfinite(cagr_pct):
                ax.axhline(cagr_pct, color=_rgba(col["primary"]), linestyle="--", linewidth=1.5)
                label_bg(ax, dates[0], cagr_pct, r_sprintf("TTWROR: %.1f%%" if ext else "CAGR: %.1f%%", cagr_pct),
                         col["primary"], size=9)
            ax.set_ylabel("Rendite p. a. (%)")

    if "monthly" in slot_of:
        ax = ax_for(slot_of["monthly"])
        years, mat = _monthly_matrix(x)
        cmap = LinearSegmentedColormap.from_list("simlev", [_rgba(col["negative"]), (1, 1, 1, 1),
                                                            _rgba(col["positive"])], N=20)
        clipped = np.ma.masked_invalid(np.minimum(np.maximum(mat, -10), 10))
        ax.pcolormesh(np.arange(0.5, 13.5), np.arange(0.5, len(years) + 1.5), clipped, cmap=cmap,
                      norm=BoundaryNorm(np.linspace(-10, 10, 21), cmap.N))
        ax.set_xticks(range(1, 13))
        ax.set_xticklabels(_MONATE_KURZ, rotation=90)
        ax.set_yticks(range(1, len(years) + 1))
        ax.set_yticklabels(years)
        for i in range(len(years)):
            for j in range(12):
                v = mat[i, j]
                if not np.isnan(v):
                    ax.text(j + 1, i + 1, r_sprintf("%.1f", v), ha="center", va="center", fontsize=7,
                            color="white" if abs(v) > 5 else "black")
        title(ax, "Monatsrenditen (%)")
        ax.set_xlabel("Monat")
        ax.set_ylabel("Jahr")

    if "stats" in slot_of:
        ax = ax_for(slot_of["stats"])
        ax.set_axis_off()
        ax.set_xlim(0, 1)
        ax.set_ylim(0, 1)
        title(ax, "Kennzahlen")
        secs = _stats_sections(x, compare)
        n_lines = sum(1 + 0.85 * len(v) + 0.5 for v in secs.values())
        two = n_lines > 16
        names = list(secs)
        groups = [names] if not two else [names[:math.ceil(len(names) / 2)], names[math.ceil(len(names) / 2):]]
        lh = 0.88 / max(sum(1 + 0.85 * len(secs[s]) + 0.5 for s in g) for g in groups)
        lh = min(lh, 0.07)
        for k, g in enumerate(groups):
            x0, yy = 0.05 + k * 0.46, 0.95
            for s in g:
                ax.text(x0, yy - 0.5 * lh, s, fontweight="bold", fontsize=10, color=_rgba(col["primary"]),
                        ha="left", va="center")
                yy -= lh
                for v in secs[s]:
                    ax.text(x0 + 0.03, yy - 0.425 * lh, v, fontsize=8.5, color=_rgba(col["neutral"]), ha="left",
                            va="center")
                    yy -= 0.85 * lh
                yy -= 0.5 * lh
        ax.add_patch(Rectangle((0.02, 0.02), 0.96, 0.96, fill=False, edgecolor=_rgba(col["grid"]), linewidth=2))

    if "correlation" in slot_of and compare is not None:
        ax = ax_for(slot_of["correlation"])
        c = _correlation(x, compare)
        if c is None:
            empty(ax, "Rollierende Korrelation")
        else:
            title(ax, "Rollierende Korrelation (%d Tage)" % c["k"])
            grid(ax)
            ax.set_xlim(dates[0], dates[-1])
            ax.set_ylim(*r_range(-1.0, 1.0))
            ax.axhline(0, color=_rgba(col["neutral"]), linestyle="--")
            ax.plot(c["dates"], c["rho"], color=_rgba(col["primary"]), linewidth=1.5)
            ra = c["rho_all"]
            if math.isfinite(ra):
                ax.axhline(ra, color=_rgba(col["secondary"]), linestyle="--", linewidth=1.5)
                label_bg(ax, dates[0], ra, r_sprintf("Gesamt: %.2f", ra), col["secondary"],
                         va="top" if ra > 0.8 else "bottom", size=9)
            ax.set_ylabel("Korrelation")

    if "comparison" in slot_of and compare is not None:
        ax = ax_for(slot_of["comparison"])
        ax.set_axis_off()
        ax.set_xlim(0, 1)
        ax.set_ylim(0, 1)
        title(ax, "Strategievergleich")
        rows = _comparison_rows(x, compare, col)
        ys = np.linspace(0.70, 0.16, len(rows))
        for r, yy in zip(rows, ys):
            ax.text(0.05, yy, r["metric"], fontweight="bold", fontsize=10, ha="left", va="center")
            ax.text(0.35, yy, r["v1"], color=_rgba(col["primary"]), fontsize=9, ha="right", va="center")
            ax.text(0.65, yy, r["v2"], color=_rgba(col["secondary"]), fontsize=9, ha="right", va="center")
            ax.text(0.95, yy, r["diff"], color=_rgba(r["diff_col"]), fontweight="bold", fontsize=9, ha="right",
                    va="center")
        ax.text(0.35, 0.88, "Strategie 1", color=_rgba(col["primary"]), fontweight="bold", ha="right")
        ax.text(0.65, 0.88, "Strategie 2", color=_rgba(col["secondary"]), fontweight="bold", ha="right")
        ax.text(0.95, 0.88, "Differenz", color=_rgba(col["neutral"]), fontweight="bold", ha="right")
        ax.add_patch(Rectangle((0.02, 0.02), 0.96, 0.96, fill=False, edgecolor=_rgba(col["grid"]), linewidth=2))


def export_dashboard(x, filename: str = "dashboard.pdf", width: float = 14, height: float = 10, **kwargs):
    """Dashboard als Datei speichern (Format aus der Dateiendung, Standard PDF, Größe in Zoll).

    Weitere Argumente gehen an :func:`plot_dashboard`. Meldung wie in R nach ``stderr``.
    """
    import matplotlib.pyplot as plt
    fig = plot_dashboard(x, figsize=(width, height), **kwargs)
    try:
        fig.savefig(filename, facecolor=fig.get_facecolor())
    finally:
        plt.close(fig)
    sys.stderr.write("export_dashboard: Dashboard gespeichert in %s\n" % filename)
    return None


def export_html_dashboard(x, filename: str = "dashboard.html"):
    """Platzhalter wie in R: ohne ``plotly`` ein Fehler, mit ``plotly`` nur eine Meldung (es wird keine
    Datei geschrieben). Für ein interaktives Dashboard siehe :func:`simlev.plot_interactive`."""
    try:
        import plotly  # noqa: F401
    except ImportError:
        _stop("export_html_dashboard: Das Paket 'plotly' wird für HTML-Dashboards benötigt; "
              "installieren mit install.packages(\"plotly\").")
    sys.stderr.write("export_html_dashboard: Der Export als interaktives HTML-Dashboard ist noch nicht umgesetzt; "
                     "es wird keine Datei geschrieben (siehe plot_interactive()).\n")
    return None
