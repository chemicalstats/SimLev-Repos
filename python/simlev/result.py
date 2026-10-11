"""Ergebnisobjekt der Simulation (R-Klasse ``SimLevResult``)."""
from __future__ import annotations

import math
from dataclasses import dataclass, field
from typing import Any

import numpy as np

__all__ = ["SimLevResult"]

_LINE = "══════════════════════════════════════════════════════════════"


def _na(x: Any) -> bool:
    return x is None or (isinstance(x, float) and math.isnan(x))


def _f(fmt: str, x: Any) -> str:
    """``sprintf`` mit R-Verhalten für NA."""
    if _na(x):
        return "NA"
    return fmt % x


@dataclass
class SimLevResult:
    """Ergebnis von :func:`simlev.simulation`.

    Attribute entsprechen den Listenelementen des R-Ergebnisses:

    ``dates``, ``filled``, ``worth``, ``cagr``, ``ttwror``, ``drawdowns``,
    ``statistics``, ``buys``, ``sells``, ``report`` und ``tax_report``.
    Zusätzlich (nur Python) enthält ``trades`` die Lots, Verkäufe, Steuer- und
    Gebührenbuchungen je Asset.
    """

    dates: np.ndarray
    filled: np.ndarray
    worth: np.ndarray
    cagr: float
    ttwror: float
    drawdowns: np.ndarray
    statistics: dict
    buys: dict
    sells: dict
    report: dict
    tax_report: dict
    trades: dict = field(default_factory=dict, repr=False)

    # ── Darstellung ──────────────────────────────────────────────────────
    def __repr__(self) -> str:
        return self.format()

    def __getitem__(self, key: str) -> Any:
        return getattr(self, key)

    def keys(self) -> list[str]:
        return ["dates", "filled", "worth", "cagr", "ttwror", "drawdowns", "statistics",
                "buys", "sells", "report", "tax_report"]

    def format(self) -> str:
        s = self.statistics
        out = ["", _LINE, "                    SimLev Simulation Results                  ", _LINE, ""]
        out += ["  Performance", "  ─────────────────────"]
        out.append("  CAGR:             %s%%" % _f("%+.2f", self.cagr * 100 if not _na(self.cagr) else None))
        out.append("  TTWROR:           %s%%" % _f("%+.2f", self.ttwror * 100 if not _na(self.ttwror) else None))
        out.append("  Final Value:      %s EUR" % _f("%.2f", float(self.worth[-1])))
        out.append("")
        out += ["  Risk", "  ─────────────────────"]
        out.append("  Max Drawdown:     %s%%" % _f("%.2f", s["max_drawdown"] * 100))
        out.append("  Avg Drawdown:     %s%%" % _f("%.2f", s["average_drawdown"] * 100))
        out.append("  Ulcer Index:      %s" % _f("%.4f", s["ulcer_index"]))
        out.append("  Longest DD:       %d Tage" % s["longest_drawdown"])
        rec = "–" if _na(s["avg_recovery_time"]) else "%.0f" % s["avg_recovery_time"]
        out.append("  Avg Recovery:     %s Tage" % rec)
        out.append("")

        def ratio(v: Any) -> str:
            return "–" if _na(v) else "%+.3f" % v

        out += ["  Ratios", "  ─────────────────────"]
        out.append("  Sharpe:           %s" % ratio(s["sharpe"]))
        out.append("  Sortino:          %s" % ratio(s["sortino"]))
        out.append("  Calmar:           %s" % ratio(s["calmar"]))
        out.append("  Omega:            %s" % ratio(s["omega"]))
        out.append("  Gain/Pain:        %s" % ratio(s["gain_to_pain"]))
        out.append("  Serenity:         %s" % ratio(s["serenity"]))
        out.append("  Martin Ratio:              %s" % ratio(s["martin_ratio"]))
        out.append("")
        out += ["  Distribution", "  ─────────────────────"]
        out.append("  Daily Mean:       %s%%" % _f("%+.4f", s["mean"] * 100))
        out.append("  Daily Std Dev:    %s%%" % _f("%.4f", s["sd"] * 100))
        out.append("  Skewness:         %s" % _f("%.3f", s["skewness"]))
        out.append("  Kurtosis:         %s" % _f("%.3f", s["kurtosis"]))
        out.append("")
        tr = self.tax_report
        if tr is not None and tr["total_taxes_paid"] > 0:
            out += ["  Steuern", "  ─────────────────────"]
            out.append("  Gezahlte Steuern: %.2f EUR" % tr["total_taxes_paid"])
            out.append("  Verlustvortrag:   %.2f EUR (§ 20) / %.2f EUR (§ 23)"
                       % (tr["loss_carryforward_capital"], tr["loss_carryforward_private"]))
            if tr["sparer_pauschbetrag_annual"] > 0:
                out.append("  SPB genutzt:      %.2f EUR (Ersparnis: %.2f EUR)"
                           % (tr["sparer_pauschbetrag_used"], tr["sparer_pauschbetrag_tax_saved"]))
            out.append("")
        out.append(_LINE)
        return "\n".join(out)

    def print(self) -> "SimLevResult":
        print(self.format())
        return self

    def summary(self, verbose: bool = True) -> dict:
        """Kompakte Kennzahlenübersicht; gibt die Werte als ``dict`` zurück."""
        n_days = int(self.worth.size)
        s = self.statistics
        start, end = float(self.worth[0]), float(self.worth[-1])
        res = {
            "n_days": n_days,
            "n_years": round(n_days / 365.25, 2),
            "start_value": start,
            "end_value": end,
            "total_return": (end / start) - 1 if start != 0 else math.nan,
            "cagr": self.cagr,
            "ttwror": self.ttwror,
            "sharpe": s["sharpe"],
            "sortino": s["sortino"],
            "calmar": s["calmar"],
            "omega": s["omega"],
            "gain_to_pain": s["gain_to_pain"],
            "serenity": s["serenity"],
            "martin_ratio": s["martin_ratio"],
            "max_drawdown": s["max_drawdown"],
            "average_drawdown": s["average_drawdown"],
            "ulcer_index": s["ulcer_index"],
            "longest_drawdown": s["longest_drawdown"],
            "avg_recovery_time": s["avg_recovery_time"],
            "statistics": s,
            "tax_report": self.tax_report,
        }
        if verbose:
            def fmt(v: Any, pct: bool = False) -> str:
                if _na(v):
                    return "–"
                return "%.2f%%" % (v * 100) if pct else "%.3f" % v

            out = ["", _LINE, "                    SimLev Summary                             ", _LINE, ""]
            out.append("  Zeitraum:         %d Tage (%.1f Jahre)" % (n_days, res["n_years"]))
            out.append("  Start:            %.2f EUR" % start)
            out.append("  Ende:             %.2f EUR" % end)
            out.append("  Gesamtrendite:    %s%%" % _f("%+.2f", res["total_return"] * 100))
            out.append("  CAGR:             %s%%" % _f("%+.2f", self.cagr * 100 if not _na(self.cagr) else None))
            out.append("  TTWROR:           %s%%" % _f("%+.2f", self.ttwror * 100 if not _na(self.ttwror) else None))
            out.append("")
            rows = [
                ("Sharpe", fmt(s["sharpe"])), ("Sortino", fmt(s["sortino"])), ("Calmar", fmt(s["calmar"])),
                ("Omega", fmt(s["omega"])), ("Gain/Pain", fmt(s["gain_to_pain"])),
                ("Serenity", fmt(s["serenity"])), ("Martin", fmt(s["martin_ratio"])),
                ("Max DD", fmt(s["max_drawdown"], True)), ("Avg DD", fmt(s["average_drawdown"], True)),
                ("Ulcer", fmt(s["ulcer_index"])), ("Longest DD", "%d d" % s["longest_drawdown"]),
                ("Avg Recovery", "–" if _na(s["avg_recovery_time"]) else "%.0f d" % s["avg_recovery_time"]),
            ]
            for k, v in rows:
                out.append("  %-16s %s" % (k, v))
            out.append("")
            out.append(_LINE)
            print("\n".join(out))
        return res

    # ── Grafik ───────────────────────────────────────────────────────────
    def plot(self, style: str = "full", panels=None, compare: "SimLevResult | None" = None,
             colors: dict | None = None, **kwargs: Any):
        """Dashboard (matplotlib); siehe :func:`simlev.dashboard.plot_dashboard`."""
        from .dashboard import plot_dashboard
        return plot_dashboard(self, style=style, panels=panels, compare=compare, colors=colors, **kwargs)

    def plot_interactive(self, file: str | None = None, panels=("performance", "drawdown", "weights"),
                         max_points: int = 6000, open: bool | None = None, engine: str = "auto"):
        """Interaktives HTML-Dashboard; siehe :func:`simlev.interactive.plot_interactive`."""
        from .interactive import plot_interactive
        return plot_interactive(self, file=file, panels=panels, max_points=max_points, open=open, engine=engine)
