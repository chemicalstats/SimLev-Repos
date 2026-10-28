"""Ergebnisobjekt der Simulation (R-Klasse ``SimLevResult``) mit ``print`` und ``summary``."""
from __future__ import annotations

import math
from typing import Any

import numpy as np

from ._r.rlist import RList
from ._r.rformat import r_round, r_sprintf
from ._r.rnum import NA_REAL, r_sum

__all__ = ["SimLevResult", "SimLevSummary"]

_LINE = "═" * 62
_RULE = "  " + "─" * 21


def _na(x: Any) -> bool:
    return x is None or (isinstance(x, (float, np.floating)) and math.isnan(x))


def _n_tage(n: Any) -> str:
    s = n if isinstance(n, str) else "%d" % int(n)
    return "1 Tag" if s == "1" else s + " Tage"


def _undef_text(um: Any, metric: str) -> str:
    """``.undef_text()``: "nicht definiert (<Ursache>)" aus ``undefined_metrics``."""
    d = None
    try:
        if um is not None and len(um) and metric in list(um["metric"]):
            d = list(um["detail"])[list(um["metric"]).index(metric)]
    except (KeyError, TypeError):
        d = None
    return "nicht definiert" if d is None else "nicht definiert (%s)" % d


class SimLevResult(RList):
    """Ergebnis von :func:`simlev.simulation` (R-Klasse ``SimLevResult``).

    Geordnetes ``dict`` mit Attributzugriff (``res["worth"]`` und ``res.worth``). Elemente in
    der Reihenfolge wie in R: ``dates`` (``datetime64[D]``), ``filled``, ``worth``,
    ``twr_index``, ``invested``, ``external_flows``, ``cagr``, ``ttwror``, ``drawdowns``,
    ``statistics`` (``dict``), ``buys``/``sells`` (``pandas.Series`` je Asset), ``report``
    (``dict`` je Asset mit den Tagesvektoren ``worth``, ``money``, ``flows``, ``total``,
    ``share``), ``tax_report`` (``dict``; ``tariff_years`` als ``pandas.DataFrame``,
    ``next_year`` als ``dict``), ``undefined_metrics`` (``pandas.DataFrame`` mit ``metric``,
    ``reason``, ``detail``), ``open_lots`` (``dict`` je Asset oder ``None``) sowie ggf.
    ``fees_paid`` und ``harvest_days``. Zusätzlich (nur Python) liefert ``trades`` die Lots,
    Verkäufe, Steuer- und Gebührenbuchungen je Asset.
    """

    r_class = ("SimLevResult",)

    @property
    def trades(self) -> dict:
        return getattr(self, "_trades", {})

    # ── Druckausgabe (print.SimLevResult) ────────────────────────────────
    def format(self) -> str:
        s = self["statistics"]
        um = self.get("undefined_metrics")
        ext = bool(self.get("external_flows"))
        out = ["", _LINE, "                 SimLev Simulationsergebnisse                 ", _LINE, ""]
        out += ["  Wertentwicklung", _RULE]

        def pct(v, metric, suffix=""):
            return _undef_text(um, metric) if _na(v) else r_sprintf("%+.2f%%%s", v * 100, suffix)
        if ext:
            out.append("  CAGR:             %s" % pct(self["cagr"], "cagr", " (geldgewichtet, XIRR)"))
            out.append("  TTWROR:           %s" % pct(self["ttwror"], "ttwror", " (zeitgewichtet)"))
        else:
            out.append("  CAGR:             %s" % pct(self["cagr"], "cagr"))
            out.append("  TTWROR:           %s" % pct(self["ttwror"], "ttwror"))
        out.append(r_sprintf("  Endwert:          %.2f EUR", float(self["worth"][-1])))
        if ext:
            out.append(r_sprintf("  Eingezahlt:       %.2f EUR (Start + Sparraten)", float(self["invested"][-1])))
        out.append("")
        out.append("  Risiko (zeitgewichtet, ohne Einzahlungseffekte)" if ext else "  Risiko")
        out.append(_RULE)
        out.append(r_sprintf("  Max. Drawdown:    %.2f%%", s["max_drawdown"] * 100))
        out.append(r_sprintf("  Mittl. Drawdown:  %.2f%%", s["average_drawdown"] * 100))
        out.append(r_sprintf("  Ulcer Index:      %.4f", s["ulcer_index"]))
        out.append("  Längster DD:      %s" % _n_tage(s["longest_drawdown"]))
        out.append("  Mittl. Erholung:  %s" % ("–" if _na(s["avg_recovery_time"]) else
                                              _n_tage(r_sprintf("%.0f", s["avg_recovery_time"]))))
        out.append("")
        out += ["  Kennzahlen", _RULE]

        def fr(v):
            return "–" if _na(v) else r_sprintf("%+.3f", v)
        out.append("  Sharpe:           %s" % fr(s["sharpe"]))
        out.append("  Sortino:          %s" % fr(s["sortino"]))
        out.append("  Calmar:           %s" % fr(s["calmar"]))
        out.append("  Omega:            %s" % fr(s["omega"]))
        out.append("  Gain/Pain:        %s" % fr(s["gain_to_pain"]))
        out.append("  Serenity:         %s" % fr(s["serenity"]))
        out.append("  Martin Ratio:     %s" % fr(s["martin_ratio"]))
        if ext:
            out.append("  (Calmar, Serenity, Martin mit TTWROR)")
        out.append("")
        out += ["  Verteilung", _RULE]
        out.append(r_sprintf("  Mittel je Tag:    %+.4f%%", s["mean"] * 100))
        out.append(r_sprintf("  Std.-Abw. je Tag: %.4f%%", s["sd"] * 100))

        def num3(v, metric):
            return _undef_text(um, metric) if _na(v) else r_sprintf("%.3f", v)
        out.append("  Schiefe:          %s" % num3(s["skewness"], "skewness"))
        out.append("  Wölbung:          %s" % num3(s["kurtosis"], "kurtosis"))
        out.append("")
        tr = self.get("tax_report")
        if tr is not None and tr["total_taxes_paid"] > 0:
            out += ["  Steuern", _RULE]
            out.append(r_sprintf("  Gezahlte Steuern: %.2f EUR", tr["total_taxes_paid"]))
            out.append(r_sprintf("  Verlustvortrag:   %.2f EUR (§ 20) / %.2f EUR (§ 23)",
                                 tr["loss_carryforward_capital"], tr["loss_carryforward_private"]))
            otd = tr.get("open_tax_debt")
            if otd is not None and not _na(otd) and otd > 0:
                out.append(r_sprintf("  Steuerschuld:     %.2f EUR (offen, nicht gedeckt)", otd))
            if tr["sparer_pauschbetrag_annual"] > 0:
                out.append(r_sprintf("  SPB genutzt:      %.2f EUR (Ersparnis: %.2f EUR)",
                                     tr["sparer_pauschbetrag_used"], tr["sparer_pauschbetrag_tax_saved"]))
            out.append("")
        out.append(_LINE)
        return "\n".join(out)

    def print(self) -> "SimLevResult":
        print(self.format())
        return self

    # ── summary.SimLevResult ─────────────────────────────────────────────
    def summary(self, verbose: bool = False) -> "SimLevSummary":
        """Zusammenfassung (R: ``summary()``); druckt nicht selbst (``verbose=True``: zusätzlich drucken)."""
        res = summary(self)
        if verbose:
            print(res.format())
        return res

    # ── Grafik ───────────────────────────────────────────────────────────
    def plot(self, style: str = "full", panels=None, compare: "SimLevResult | None" = None,
             colors: dict | None = None, **kwargs: Any):
        """Dashboard (matplotlib); siehe :func:`simlev.dashboard.plot_dashboard`."""
        from .dashboard import plot_dashboard
        return plot_dashboard(self, style=style, panels=panels, compare=compare, colors=colors, **kwargs)

class SimLevSummary(RList):
    """Ergebnis von ``summary(<SimLevResult>)`` (R-Klasse ``summary.SimLevResult``)."""

    r_class = ("summary.SimLevResult",)

    def format(self) -> str:
        x = self
        s = x["statistics"]
        n_days = x["n_days"]
        ext = bool(x.get("external_flows"))
        um = x.get("undefined_metrics")
        out = ["", _LINE, "                    SimLev Zusammenfassung                    ", _LINE, ""]
        out.append(r_sprintf("  Zeitraum:         %s (%.1f Jahre)", _n_tage(n_days), x["n_years"]))
        if x.get("start_capital") is not None and not _na(x["start_capital"]):
            out.append(r_sprintf("  Startkapital:     %.2f EUR", x["start_capital"]))
        out.append(r_sprintf("  Depotwert Starttag: %.2f EUR", x["start_value"]))
        out.append(r_sprintf("  Ende:             %.2f EUR", x["end_value"]))

        def pct(v, metric, suffix=""):
            return _undef_text(um, metric) if _na(v) else r_sprintf("%+.2f%%%s", v * 100, suffix)
        if ext:
            out.append(r_sprintf("  Eingezahlt:       %.2f EUR (Start + Sparraten)", x["invested"]))
            out.append(r_sprintf("  Gesamtrendite (zeitgewichtet): %+.2f %%", x["total_return_twr"] * 100))
            out.append(r_sprintf("  Gewinn je eingezahltem EUR:    %+.2f %% (Endwert %.2f EUR / Eingezahlt %.2f EUR - 1)",
                                 x["return_on_invested"] * 100, x["end_value"], x["invested"]))
            out.append("  CAGR:             %s" % pct(x["cagr"], "cagr", " (geldgewichtet, XIRR)"))
            out.append("  TTWROR:           %s" % pct(x["ttwror"], "ttwror", " (zeitgewichtet)"))
        else:
            out.append(r_sprintf("  Gesamtrendite:    %+.2f%%", x["total_return"] * 100))
            out.append("  CAGR:             %s" % pct(x["cagr"], "cagr"))
            out.append("  TTWROR:           %s" % pct(x["ttwror"], "ttwror"))
        out.append("")

        def fmt(val, p=False):
            if _na(val):
                return "–"
            return r_sprintf("%.2f%%", val * 100) if p else r_sprintf("%.3f", val)
        rows = [("Sharpe", fmt(s["sharpe"])), ("Sortino", fmt(s["sortino"])), ("Calmar", fmt(s["calmar"])),
                ("Omega", fmt(s["omega"])), ("Gain/Pain", fmt(s["gain_to_pain"])), ("Serenity", fmt(s["serenity"])),
                ("Martin", fmt(s["martin_ratio"])), ("Max. DD", fmt(s["max_drawdown"], True)),
                ("Mittl. DD", fmt(s["average_drawdown"], True)), ("Ulcer", fmt(s["ulcer_index"])),
                ("Längster DD", "%d d" % s["longest_drawdown"]),
                ("Mittl. Erholung", "–" if _na(s["avg_recovery_time"]) else
                 r_sprintf("%.0f d", s["avg_recovery_time"]))]
        for k, v in rows:
            out.append("  %s %s" % (k.ljust(16), v))
        if ext:
            out.append("  (Drawdowns zeitgewichtet; Calmar, Serenity, Martin mit TTWROR)")
        out.append("")
        out.append(_LINE)
        return "\n".join(out)

    def print(self) -> "SimLevSummary":
        print(self.format())
        return self


def summary(object: SimLevResult) -> SimLevSummary:
    """``summary.SimLevResult``: Kennzahlen als :class:`SimLevSummary` (druckt nicht selbst)."""
    worth = np.asarray(object["worth"], dtype=np.float64)
    n_days = int(worth.size)
    s = object["statistics"]
    ext = bool(object.get("external_flows"))
    invested = object.get("invested")
    twr = object.get("twr_index")
    res = SimLevSummary()
    res["n_days"] = n_days
    res["n_years"] = r_round(n_days / 365.25, 2)
    res["start_value"] = float(worth[0])
    if invested is not None:
        flows1 = [float(r["flows"][0]) for r in object["report"].values()]
        res["start_capital"] = float(invested[0]) - r_sum(flows1, na_rm=True)
    else:
        res["start_capital"] = NA_REAL
    res["end_value"] = float(worth[-1])
    res["total_return_twr"] = (float(twr[-1]) / float(twr[0]) - 1) if ext else (float(worth[-1]) / float(worth[0])) - 1
    res["return_on_invested"] = NA_REAL
    res["total_return"] = NA_REAL
    res["invested"] = float(invested[-1]) if invested is not None else float(worth[0])
    res["cagr"] = object["cagr"]
    res["ttwror"] = object["ttwror"]
    for k in ("sharpe", "sortino", "calmar", "omega", "gain_to_pain", "serenity", "martin_ratio", "max_drawdown",
              "average_drawdown", "ulcer_index", "longest_drawdown", "avg_recovery_time"):
        res[k] = s[k]
    res["statistics"] = s
    res["tax_report"] = object.get("tax_report")
    res["undefined_metrics"] = object.get("undefined_metrics")
    res["external_flows"] = ext
    res["total_return"] = res["total_return_twr"]
    res["return_on_invested"] = (res["end_value"] - res["invested"]) / res["invested"]
    return res
