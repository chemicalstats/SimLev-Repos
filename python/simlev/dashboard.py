"""Dashboard-Visualisierung (Port von plot_dashboard.R, matplotlib).

Panels, Beschriftungen und angezeigte Kennzahlen entsprechen dem R-Paket.
Hinweis: Wie im R-Original rechnet das Statistik-Panel eine vereinfachte
„Sharpe Ratio" ``(CAGR - 2 %) / (sd · √252)`` und die Währungsachse ist
standardmäßig mit ``$`` beschriftet (``currency=`` ändert das Symbol).
"""
from __future__ import annotations

import math
import sys
from typing import Any, Sequence

import numpy as np

from ._rnum import r_mean, r_sd

__all__ = ["plot_dashboard", "export_dashboard", "export_html_dashboard", "r_pretty"]

DEFAULT_COLORS = {
    "primary": "#2E86AB",
    "secondary": "#A23B72",
    "positive": "#06A77D",
    "negative": "#D62246",
    "neutral": "#6C757D",
    "background": "#F8F9FA",
    "grid": "#E9ECEF",
}
_ORDER = ("performance", "drawdown", "distribution", "rolling", "monthly", "stats", "correlation", "comparison")
_MONTHS = ("Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec")


def r_pretty(lo: float, hi: float, n: int = 5) -> np.ndarray:
    """Nachbildung von R's ``pretty()`` (Algorithmus aus R's ``src/appl/pretty.c``)."""
    if not (math.isfinite(lo) and math.isfinite(hi)):
        return np.array([0.0])
    if hi < lo:
        lo, hi = hi, lo
    h, h5 = 1.5, 0.5 + 1.5 * 1.5
    eps = 1e-10
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


def _alpha(color: str, hex_alpha: str) -> tuple:
    from matplotlib.colors import to_rgb
    r, g, b = to_rgb(color)
    return (r, g, b, int(hex_alpha, 16) / 255)


def _fmt_currency(x: float, sym: str) -> str:
    if abs(x) >= 1e6:
        return "%s%.1fM" % (sym, x / 1e6)
    if abs(x) >= 1e3:
        return "%s%.0fK" % (sym, x / 1e3)
    return "%s%.0f" % (sym, x)


def _na_fmt(fmt: str, v: Any) -> str:
    if v is None or (isinstance(v, float) and math.isnan(v)):
        return fmt.replace("%+.2f", "NA").replace("%.2f", "NA").replace("%d", "NA") if "%" in fmt else fmt
    return fmt % v


def _grid_shape(style: str, n: int, compare: bool) -> tuple[int, int]:
    if style == "full":
        return (4, 2) if compare else (3, 2)
    if style == "compact":
        return 2, 2
    if n <= 2:
        return 1, max(n, 1)
    if n <= 4:
        return 2, 2
    if n <= 6:
        return 3, 2
    return 4, 2


def plot_dashboard(x, style: str = "full", panels: Sequence[str] | None = None, compare=None,
                   colors: dict | None = None, figsize: tuple[float, float] | None = None,
                   currency: str = "$", fig=None, show: bool = False):
    """Erstellt das mehrteilige Dashboard und gibt die ``matplotlib.figure.Figure`` zurück.

    ``style``: ``"full"`` (alle Standard-Panels), ``"compact"`` (2×2) oder
    ``"custom"`` (Panels aus ``panels``). ``compare`` zeigt ein zweites
    Ergebnis zum Vergleich.
    """
    import matplotlib.pyplot as plt
    from matplotlib.colors import BoundaryNorm, LinearSegmentedColormap
    from ._dates import from_days

    from .config import _match_arg
    style = _match_arg(style, ("full", "compact", "custom"), "style")
    if panels is None:
        panels = ["performance", "drawdown", "distribution", "rolling", "monthly", "stats"]
    col = dict(DEFAULT_COLORS)
    if colors:
        col.update(colors)

    if style == "full":
        selected = (["performance", "drawdown", "distribution", "rolling", "monthly", "correlation", "stats",
                     "comparison"] if compare is not None else
                    ["performance", "drawdown", "distribution", "rolling", "monthly", "stats"])
    elif style == "compact":
        selected = ["performance", "drawdown", "distribution", "stats"]
    else:
        selected = list(panels)
    nrow, ncol = _grid_shape(style, len(selected), compare is not None)

    if fig is None:
        if figsize is None:
            figsize = (14, 10) if nrow >= 3 else (12, 8)
        fig = plt.figure(figsize=figsize, facecolor=col["background"])
    else:
        fig.set_facecolor(col["background"])
    slot = [0]
    max_slots = nrow * ncol

    def next_ax():
        if slot[0] >= max_slots:
            return None
        slot[0] += 1
        ax = fig.add_subplot(nrow, ncol, slot[0])
        ax.set_facecolor(col["background"])
        return ax

    def style_ax(ax, title):
        ax.set_title(title, color=col["primary"], fontsize=13, fontweight="bold")
        ax.grid(True, color=col["grid"], linewidth=0.5)
        ax.set_axisbelow(True)

    worth = np.asarray(x.worth, dtype=float)
    dates = np.asarray(x.dates).astype("datetime64[D]") if getattr(x, "dates", None) is not None \
        else np.arange(worth.size)
    n_days = worth.size

    # 1 Performance
    if "performance" in selected:
        ax = next_ax()
        if ax is not None:
            style_ax(ax, "Portfolio Performance")
            ax.fill_between(dates, worth, np.full(worth.size, worth.min()), color=_alpha(col["primary"], "30"),
                            linewidth=0)
            (l1,) = ax.plot(dates, worth, color=col["primary"], linewidth=2.5)
            if compare is not None:
                (l2,) = ax.plot(dates, np.asarray(compare.worth, dtype=float), color=col["secondary"], linewidth=2.5,
                                linestyle="--")
                ax.legend([l1, l2], ["Strategy 1", "Strategy 2"], loc="upper left", facecolor="white",
                          edgecolor=col["grid"])
            ticks = r_pretty(float(np.nanmin(worth)), float(np.nanmax(worth)))
            ax.set_yticks(ticks)
            ax.set_yticklabels([_fmt_currency(t, currency) for t in ticks])
            ax.set_ylabel("Portfolio Value")
            ax.annotate(_fmt_currency(float(worth[-1]), currency), (dates[-1], worth[-1]),
                        xytext=(4, 0), textcoords="offset points", color=col["primary"], fontweight="bold",
                        fontsize=9, va="center")

    # 2 Drawdown
    if "drawdown" in selected:
        ax = next_ax()
        if ax is not None:
            dd = np.asarray(x.drawdowns, dtype=float) * 100
            style_ax(ax, "Drawdown Analysis")
            ax.fill_between(dates, -dd, 0, color=_alpha(col["negative"], "40"), linewidth=0)
            ax.plot(dates, -dd, color=col["negative"], linewidth=2)
            max_dd = float(np.nanmax(dd)) if dd.size else 0.0
            lo = min(-dd) * 1.1 if dd.size else -1
            ax.set_ylim(lo if lo < 0 else -1e-9, 0)
            ax.axhline(-max_dd, color=col["negative"], linestyle="--", linewidth=1.5)
            ax.annotate("Max: %.1f%%" % max_dd, (dates[0], -max_dd), xytext=(0, 4), textcoords="offset points",
                        color=col["negative"], fontweight="bold")
            ax.set_ylabel("Drawdown (%)")

    # 3 Verteilung
    if "distribution" in selected:
        ax = next_ax()
        if ax is not None:
            with np.errstate(divide="ignore", invalid="ignore"):
                rets = np.diff(np.log(worth)) * 100
            rets = rets[np.isfinite(rets)]
            ax.set_title("Daily Returns Distribution", color=col["primary"], fontsize=13, fontweight="bold")
            if rets.size > 1:
                br = r_pretty(float(rets.min()), float(rets.max()), 50)
                if br.size < 2:
                    br = 50
                ax.hist(rets, bins=br, color=_alpha(col["primary"], "80"), edgecolor=col["primary"])
                xs = np.linspace(rets.min(), rets.max(), 100)
                mu, sd = r_mean(rets), r_sd(rets)
                if sd > 0:
                    yn = np.exp(-0.5 * ((xs - mu) / sd) ** 2) / (sd * math.sqrt(2 * math.pi))
                    ax.plot(xs, yn * rets.size * (rets.max() - rets.min()) / 50, color=col["secondary"],
                            linewidth=2, linestyle="--")
                ax.axvline(mu, color=col["positive"], linewidth=2, linestyle="--")
                s = x.statistics
                txt = "\n".join(["Mean: %.2f%%" % mu, "SD: %.2f%%" % sd,
                                 "Skew: %s" % ("NA" if _isnan(s["skewness"]) else "%.2f" % s["skewness"]),
                                 "Kurt: %s" % ("NA" if _isnan(s["kurtosis"]) else "%.2f" % s["kurtosis"])])
                ax.text(0.98, 0.97, txt, transform=ax.transAxes, ha="right", va="top", color=col["primary"],
                        fontsize=9)
            ax.set_xlabel("Daily Return (%)")
            ax.set_ylabel("Frequency")

    # 4 Rolling Returns
    if "rolling" in selected:
        window = min(30, n_days // 10)
        if n_days > window and window > 0:
            ax = next_ax()
            if ax is not None:
                idx = np.arange(window - 1, n_days)
                start_v = worth[idx - window + 1]
                with np.errstate(divide="ignore", invalid="ignore"):
                    rr = ((worth[idx] / start_v) ** (252 / window) - 1) * 100
                rd = dates[idx]
                style_ax(ax, "%d-Day Rolling Returns (Annualized)" % window)
                ax.axhline(0, color=col["neutral"], linestyle="--")
                pos = rr >= 0
                if pos.any():
                    ax.plot(rd[pos], rr[pos], color=col["positive"], linewidth=1.5)
                if (~pos).any():
                    ax.plot(rd[~pos], rr[~pos], color=col["negative"], linewidth=1.5)
                if not _isnan(x.cagr):
                    c = x.cagr * 100
                    ax.axhline(c, color=col["primary"], linestyle="--", linewidth=1.5)
                    ax.annotate("CAGR: %.1f%%" % c, (rd[0], c), xytext=(0, 4), textcoords="offset points",
                                color=col["primary"], fontweight="bold", fontsize=9)
                ax.set_ylabel("Annualized Return (%)")

    # 5 Monats-Heatmap
    if "monthly" in selected:
        ax = next_ax()
        if ax is not None:
            ym = [(from_days(int(z)).year, from_days(int(z)).month) for z in dates.astype(np.int64)]
            groups: dict[tuple[int, int], list[float]] = {}
            for key, v in zip(ym, worth):
                groups.setdefault(key, []).append(float(v))
            keys = sorted(groups)
            years = sorted({k[0] for k in keys})
            mat = np.full((len(years), 12), np.nan)
            for k in keys:
                vals = groups[k]
                if len(vals) > 1:
                    mat[years.index(k[0]), k[1] - 1] = (vals[-1] / vals[0] - 1) * 100
            cmap = LinearSegmentedColormap.from_list("simlev", [col["negative"], "white", col["positive"]], N=20)
            bounds = np.linspace(-10, 10, 21)
            masked = np.ma.masked_where(~np.isfinite(mat) | (mat < -10) | (mat > 10), mat)
            ax.pcolormesh(np.arange(0.5, 13.5), np.arange(0.5, len(years) + 1.5), masked, cmap=cmap,
                          norm=BoundaryNorm(bounds, cmap.N))
            ax.set_xticks(range(1, 13))
            ax.set_xticklabels(_MONTHS, rotation=90)
            ax.set_yticks(range(1, len(years) + 1))
            ax.set_yticklabels([str(y) for y in years])
            for i in range(len(years)):
                for j in range(12):
                    v = mat[i, j]
                    if np.isfinite(v):
                        ax.text(j + 1, i + 1, "%.1f" % v, ha="center", va="center", fontsize=7,
                                color="white" if abs(v) > 5 else "black")
            ax.set_title("Monthly Returns Heatmap", color=col["primary"], fontsize=13, fontweight="bold")
            ax.set_xlabel("Month")
            ax.set_ylabel("Year")

    # 6 Kennzahlen
    if "stats" in selected:
        ax = next_ax()
        if ax is not None:
            ax.set_axis_off()
            ax.set_xlim(0, 1)
            ax.set_ylim(0, 1)
            ax.set_title("Performance Statistics", color=col["primary"], fontsize=13, fontweight="bold")
            s = x.statistics
            sd252 = s["sd"] * math.sqrt(252)
            sharpe_simple = (x.cagr - 0.02) / sd252 if sd252 != 0 else math.nan
            total_ret = (worth[-1] / worth[0] - 1) * 100
            sections = {
                "Performance Metrics": [
                    "CAGR: %s%%" % _sg(x.cagr * 100 if not _isnan(x.cagr) else math.nan),
                    "TTWROR: %s%%" % _sg(x.ttwror * 100 if not _isnan(x.ttwror) else math.nan),
                    "Total Return: %s%%" % _sg(total_ret),
                ],
                "Risk Metrics": [
                    "Max Drawdown: %.2f%%" % (float(np.nanmax(x.drawdowns)) * 100),
                    "Daily Volatility: %.2f%%" % (s["sd"] * 100),
                    "Ann. Volatility: %.2f%%" % (sd252 * 100),
                ],
                "Return Profile": [
                    "Sharpe Ratio: %s" % _p2(sharpe_simple),
                    "Skewness: %s" % _p2(s["skewness"]),
                    "Kurtosis: %s" % _p2(s["kurtosis"]),
                ],
                "Portfolio Info": [
                    "Start Value: %s" % _fmt_currency(float(worth[0]), currency),
                    "End Value: %s" % _fmt_currency(float(worth[-1]), currency),
                    "Duration: %d days" % n_days,
                ],
            }
            if compare is not None:
                cw = np.asarray(compare.worth, dtype=float)
                sections["Comparison"] = [
                    "CAGR Diff: %s%%" % _sg((x.cagr - compare.cagr) * 100),
                    "Return Diff: %s%%" % _sg((worth[-1] / worth[0] - cw[-1] / cw[0]) * 100),
                    "Vol Diff: %s%%" % _sg((s["sd"] - compare.statistics["sd"]) * math.sqrt(252) * 100),
                ]
            y_start, y_step = 0.95, 0.85 / len(sections)
            for i, (name, rows) in enumerate(sections.items()):
                y = y_start - i * y_step
                ax.text(0.05, y, name, fontweight="bold", fontsize=10, color=col["primary"], ha="left", va="center")
                line_step = min(0.05, y_step / 4.2)
                for j, row in enumerate(rows, start=1):
                    ax.text(0.08, y - j * line_step, row, fontsize=8.5, color=col["neutral"], ha="left", va="center")
            ax.add_patch(_rect(0.02, 0.02, 0.96, 0.96, col["grid"]))

    # 7 Korrelation (Platzhalter wie im R-Paket)
    if "correlation" in selected and getattr(x, "report", None) and len(x.report) > 1:
        ax = next_ax()
        if ax is not None:
            ax.set_axis_off()
            ax.set_title("Asset Correlation Matrix", color=col["primary"], fontsize=13, fontweight="bold")
            ax.text(0.5, 0.5, "Requires asset-level price data", ha="center", va="center", fontsize=12,
                    color=col["neutral"], transform=ax.transAxes)

    # 8 Vergleich
    if "comparison" in selected and compare is not None:
        ax = next_ax()
        if ax is not None:
            ax.set_axis_off()
            ax.set_xlim(0, 1)
            ax.set_ylim(0, 1)
            ax.set_title("Strategy Comparison", color=col["primary"], fontsize=13, fontweight="bold")

            def vals(r):
                sd = r.statistics["sd"] * math.sqrt(252)
                return [r.cagr * 100, float(np.nanmax(r.drawdowns)) * 100, sd * 100,
                        (r.cagr - 0.02) / sd if sd != 0 else math.nan]

            v1, v2 = vals(x), vals(compare)
            ys = np.linspace(0.8, 0.2, 4)
            for name, a, b, y in zip(("CAGR", "Max DD", "Volatility", "Sharpe"), v1, v2, ys):
                ax.text(0.05, y, name, fontweight="bold", fontsize=10, ha="left", va="center")
                ax.text(0.35, y, _p2(a), color=col["primary"], fontsize=9, ha="right", va="center")
                ax.text(0.65, y, _p2(b), color=col["secondary"], fontsize=9, ha="right", va="center")
                dlt = a - b
                ax.text(0.95, y, _sg(dlt), color=col["positive"] if dlt > 0 else col["negative"],
                        fontweight="bold", fontsize=9, ha="right", va="center")
            ax.text(0.35, 0.95, "Strategy 1", color=col["primary"], fontweight="bold", ha="right")
            ax.text(0.65, 0.95, "Strategy 2", color=col["secondary"], fontweight="bold", ha="right")
            ax.text(0.95, 0.95, "Diff", color=col["neutral"], fontweight="bold", ha="right")
            ax.add_patch(_rect(0.02, 0.02, 0.96, 0.96, col["grid"]))

    fig.tight_layout()
    if show:
        plt.show()
    return fig


def _isnan(v: Any) -> bool:
    return v is None or (isinstance(v, float) and math.isnan(v))


def _sg(v: float) -> str:
    return "NA" if _isnan(v) else "%+.2f" % v


def _p2(v: float) -> str:
    return "NA" if _isnan(v) else "%.2f" % v


def _rect(x0, y0, w, h, color):
    from matplotlib.patches import Rectangle
    return Rectangle((x0, y0), w, h, fill=False, edgecolor=color, linewidth=2)


def export_dashboard(x, filename: str = "dashboard.pdf", width: float = 14, height: float = 10, **kwargs):
    """Speichert das Dashboard als Datei (Format aus der Dateiendung, z. B. PDF oder PNG)."""
    import matplotlib.pyplot as plt
    fig = plot_dashboard(x, figsize=(width, height), **kwargs)
    fig.savefig(filename, facecolor=fig.get_facecolor())
    plt.close(fig)
    sys.stderr.write("Dashboard exported to: %s\n" % filename)
    return None


def export_html_dashboard(x, filename: str = "dashboard.html"):
    """Erstellt ein interaktives HTML-Dashboard (über :func:`simlev.plot_interactive`).

    Im R-Paket ist diese Funktion nur ein Platzhalter; die Python-Version
    schreibt das eigenständige HTML-Dashboard von ``plot_interactive``.
    """
    from .interactive import plot_interactive
    return plot_interactive(x, file=filename, open=False, engine="html")
