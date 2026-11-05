"""SimLev – Backtesting für ETF-, Hebel- und Multi-Asset-Strategien mit deutscher
Investmentbesteuerung.

Python-Fassung von SimLev, gleichwertig zu den Fassungen in R und Julia: Die Rechenkerne
liegen als gemeinsamer C/C++-Code in ``core/`` (C-Erweiterung ``simlev._ext``), Python bildet
die Schnittstelle darum. Alle drei Fassungen rechnen bitgleich (geprüft unter Linux x86-64).
"""
import importlib as _importlib

from .config import (
    AssetConfig,
    Strategy,
    strategy_add_asset,
    asset_config,
    create_strategy,
    strategy_remove_asset,
    strategy_update_asset,
    strategy_validate,
)
from .engine import simulation
from ._sim_blocks import (
    sim_costs,
    dca_plan,
    rebalance_plan,
    split_rule,
    tax_profile,
    income_rate,
    income_tariff,
    harvest_rule,
    funds_costs,
    SimLevSimCosts,
    SimLevDcaPlan,
    SimLevRebalancePlan,
    SimLevSplitRule,
    SimLevTaxProfile,
    SimLevIncomeRate,
    SimLevIncomeTariff,
    SimLevHarvestRule,
    SimLevFundsCosts,
)
from .wrapper import wrapper_config, wrapper_nav, SimLevWrapperConfig, SimLevWrapperNav
from .result import SimLevResult, SimLevSummary
from .svg import SimLevPlot
from .result import summary as _summary_result
from ._tax_tariff import SimLevTaxTariff, tax_tariff
from .trigger import rebalance_trigger
# Zufallszustand der C-Bibliothek slc (simlev/_lib.py)
from ._lib import simlev_seed


# Erweiterungsmodule (R-Dateien gleichen Namens)
from .data_prep import (  # noqa: E402
    series_align,
    series_check,
    SimLevDataCheck,
    series_align_macro,
    series_convert_currency,
    index_total_return,
    series_deflate,
    series_splice,
    strategy_from_weights,
    portfolio_template,
)
from .backcast import (  # noqa: E402
    backcast_fit,
    backcast,
    SimLevBackcastFit,
    SimLevBackcast,
)
from .bonds import (  # noqa: E402
    index_bond,
    index_money_market,
    index_currency_hedged,
    RVector,
)
from .signals import (  # noqa: E402
    signal_sma,
    signal_ema,
    signal_crossover,
    signal_momentum,
    signal_drawdown,
    signal_volatility,
    signal_combine,
)
from ._r.rnum import NA_REAL as NA  # noqa: E402,F401  R's NA_real_ (NaN mit Nutzlast 1954)

# Analysemodule (Schicht 3) werden erst beim ersten Zugriff auf einen ihrer Namen geladen
# (PEP 562: __getattr__ und __dir__ unten); `from simlev import X`, `simlev.X`, `dir(simlev)`
# und __all__ wirken wie beim sofortigen Laden. Der Name des Moduls selbst (bootstrap,
# param_search) ist das aufrufbare Modul.
_LAZY = {
    "bootstrap": ("bootstrap_config", "BootstrapConfig", "bootstrap_block_length", "bootstrap", "BootstrapResult",
                  "bootstrap_validate", "bootstrap_data", "bootstrap_study_metrics", "bootstrap_study",
                  "SimLevBootstrapStudy", "SummarySimLevBootstrapStudy", "bootstrap_probability"),
    "withdrawal": ("withdrawal_rule", "WithdrawalRule", "withdrawal_cohorts", "WithdrawalPaths",
                   "result_index", "withdrawal_paths", "withdrawal_perfect_rate", "withdrawal_simulation",
                   "SimLevWithdrawal", "SummarySimLevWithdrawal", "withdrawal_max_rate", "withdrawal_horizon",
                   "SimLevHorizon"),
    "dependence": ("copula_fit", "tail_dependence", "dependence_dcc", "dependence_analysis", "quantile_regression",
                   "tail_regression", "tail_covar", "dependence_validate", "regime_subset",
                   "SimLevDependence", "SimLevTailRegression", "SimLevCoVaR"),
    "regimes": ("regime_hmm", "regime_states", "SimLevHMM"),
    "scenarios": ("view_mean", "view_prob", "view_vol", "scenario_entropy_pooling", "scenario_copula",
                  "scenario_risk", "scenario_crisis", "SimLevScenarios"),
    "optimize": ("portfolio_optimize", "portfolio_frontier", "portfolio_rolling", "portfolio_risk_contributions",
                 "portfolio_cpcv", "SimLevOptimization", "SimLevFrontier", "SimLevCPCV",
                 "SimLevBoundsPercent"),
    "tactical": ("SimLevWeights", "signal_state", "momentum_score", "tactical_rules", "tactical_rotation",
                 "tactical_target_volatility", "tactical_conditional_volatility", "tactical_glidepath", "tactical_blend",
                 "tactical_simulation"),
    "deep_analysis": ("result_analysis", "SimLevAnalysis"),
    "planning": ("series_shift_return", "bootstrap_pooled", "portfolio_returns", "planning_goal",
                 "SimLevGoalPlan"),
    "analysis_tests": ("signal_analysis", "sharpe_test", "overfit_reality_check", "sharpe_min_track_record",
                       "result_heatmap", "SimLevSignalAnalysis", "SimLevRealityCheck", "SimLevHeatmap"),
    "overfitting": ("overfit_pbo", "sharpe_probabilistic", "sharpe_deflated", "overfit_walk_forward", "param_bootstrap",
                    "sharpe_haircut", "SimLevPBO", "SimLevDSR", "SimLevWalkForward"),
    "param_search": ("param_search", "param_space", "param_range", "param_plateau", "SimLevParamSpace",
                     "SimLevParamRange", "SimLevParamSearch", "SummarySimLevParamSearch"),
    "sensitivity": ("sensitivity_grid", "sensitivity_rebalancing", "planning_lumpsum_vs_dca", "series_leverage",
                    "sensitivity_leverage", "SimLevSensitivity", "SimLevLumpSum"),
}


def isna_strict(x):
    """True nur für R's ``NA`` (nicht für ``NaN``); Skalar oder elementweise für Arrays."""
    import numpy as _np
    from ._r.rnum import r_isna, r_isna_arr
    if _np.ndim(x) == 0:
        return r_isna(x)
    return r_isna_arr(x)



def _callable_module(name):
    """Macht das Untermodul ``simlev.<name>`` aufrufbar wie die gleichnamige Funktion.

    So gilt ``simlev.backcast(...)`` wie in R, und ``simlev.backcast.backcast_fit``
    bzw. ``import simlev.backcast`` erreichen weiter das Modul. Die erst bei Bedarf geladenen
    Module ``bootstrap`` und ``param_search`` machen sich am Ende ihrer
    Datei selbst aufrufbar (``_make_callable``)."""
    import sys
    import types

    mod = sys.modules[__name__ + "." + name]

    class _CallableModule(types.ModuleType):
        def __call__(self, *args, **kwargs):
            return getattr(self, name)(*args, **kwargs)

    mod.__class__ = _CallableModule
    return mod


backcast = _callable_module("backcast")

_LAZY_NAMES = {name: mod for mod, names in _LAZY.items() for name in names}
# Untermodule, die beim sofortigen Laden als Attribute von simlev entstanden (für dir(simlev))
_LAZY_SUBMODULES = tuple(_LAZY) + ("_dependence_core", "_optimize_core", "_withdrawal_core")


def __getattr__(name):
    """Lädt das Analysemodul zu ``name`` beim ersten Zugriff (PEP 562)."""
    mod = _LAZY_NAMES.get(name)
    if mod is None:
        if name in _LAZY_SUBMODULES:
            return _importlib.import_module(__name__ + "." + name)
        raise AttributeError("module %r has no attribute %r" % (__name__, name))
    m = _importlib.import_module(__name__ + "." + mod)
    value = m if name == mod else getattr(m, name)
    globals()[name] = value
    return value


# Hilfsnamen des verzögerten Ladens erscheinen nicht in dir(simlev) (wie vorher)
_LAZY_HIDDEN = frozenset({"_importlib", "_LAZY", "_LAZY_NAMES", "_LAZY_SUBMODULES", "_LAZY_HIDDEN",
                          "__getattr__", "__dir__"})


def __dir__():
    return sorted((set(globals()) - _LAZY_HIDDEN) | set(_LAZY_NAMES) | set(_LAZY_SUBMODULES))

__version__ = "1.6.0"

__all__ = [
    "AssetConfig",
    "SimLevResult",
    "SimLevPlot",
    "SimLevSummary",
    "SimLevTaxTariff",
    "Strategy",
    "strategy_add_asset",
    "asset_config",
    "rebalance_trigger",
    "create_strategy",
    "export_dashboard",
    "tax_tariff",
    "strategy_remove_asset",
    "simulation",
    "sim_costs",
    "dca_plan",
    "rebalance_plan",
    "split_rule",
    "tax_profile",
    "income_rate",
    "income_tariff",
    "harvest_rule",
    "funds_costs",
    "SimLevSimCosts",
    "SimLevDcaPlan",
    "SimLevRebalancePlan",
    "SimLevSplitRule",
    "SimLevTaxProfile",
    "SimLevIncomeRate",
    "SimLevIncomeTariff",
    "SimLevHarvestRule",
    "SimLevFundsCosts",
    "wrapper_config",
    "wrapper_nav",
    "SimLevWrapperConfig",
    "SimLevWrapperNav",
    "summary",
    "plot",
    "NA",
    "isna_strict",
    "series_align",
    "series_check",
    "SimLevDataCheck",
    "series_align_macro",
    "series_convert_currency",
    "index_total_return",
    "series_deflate",
    "series_splice",
    "strategy_from_weights",
    "portfolio_template",
    "backcast_fit",
    "backcast",
    "SimLevBackcastFit",
    "SimLevBackcast",
    "index_bond",
    "index_money_market",
    "index_currency_hedged",
    "RVector",
    "signal_sma",
    "signal_ema",
    "signal_crossover",
    "signal_momentum",
    "signal_drawdown",
    "signal_volatility",
    "signal_combine",
    "bootstrap_config",
    "BootstrapConfig",
    "bootstrap_block_length",
    "bootstrap",
    "BootstrapResult",
    "bootstrap_validate",
    "bootstrap_data",
    "bootstrap_study_metrics",
    "bootstrap_study",
    "SimLevBootstrapStudy",
    "SummarySimLevBootstrapStudy",
    "bootstrap_probability",
    "withdrawal_rule",
    "WithdrawalRule",
    "withdrawal_cohorts",
    "WithdrawalPaths",
    "result_index",
    "withdrawal_paths",
    "withdrawal_perfect_rate",
    "withdrawal_simulation",
    "SimLevWithdrawal",
    "SummarySimLevWithdrawal",
    "withdrawal_max_rate",
    "withdrawal_horizon",
    "SimLevHorizon",
    "copula_fit",
    "tail_dependence",
    "dependence_dcc",
    "dependence_analysis",
    "quantile_regression",
    "tail_regression",
    "tail_covar",
    "dependence_validate",
    "regime_subset",
    "SimLevDependence",
    "SimLevTailRegression",
    "SimLevCoVaR",
    "regime_hmm",
    "regime_states",
    "SimLevHMM",
    "view_mean",
    "view_prob",
    "view_vol",
    "scenario_entropy_pooling",
    "scenario_copula",
    "scenario_risk",
    "scenario_crisis",
    "SimLevScenarios",
    "portfolio_optimize",
    "portfolio_frontier",
    "portfolio_rolling",
    "portfolio_risk_contributions",
    "portfolio_cpcv",
    "SimLevOptimization",
    "SimLevFrontier",
    "SimLevCPCV",
    "SimLevBoundsPercent",
    "SimLevWeights",
    "signal_state",
    "momentum_score",
    "tactical_rules",
    "tactical_rotation",
    "tactical_target_volatility",
    "tactical_conditional_volatility",
    "tactical_glidepath",
    "tactical_blend",
    "tactical_simulation",
    "result_analysis",
    "SimLevAnalysis",
    "series_shift_return",
    "bootstrap_pooled",
    "portfolio_returns",
    "planning_goal",
    "SimLevGoalPlan",
    "signal_analysis",
    "sharpe_test",
    "overfit_reality_check",
    "sharpe_min_track_record",
    "result_heatmap",
    "SimLevSignalAnalysis",
    "SimLevRealityCheck",
    "SimLevHeatmap",
    "overfit_pbo",
    "sharpe_probabilistic",
    "sharpe_deflated",
    "overfit_walk_forward",
    "param_bootstrap",
    "sharpe_haircut",
    "SimLevPBO",
    "SimLevDSR",
    "SimLevWalkForward",
    "param_space",
    "param_range",
    "param_search",
    "param_plateau",
    "SimLevParamSpace",
    "SimLevParamRange",
    "SimLevParamSearch",
    "SummarySimLevParamSearch",
    "sensitivity_grid",
    "sensitivity_rebalancing",
    "planning_lumpsum_vs_dca",
    "series_leverage",
    "sensitivity_leverage",
    "SimLevSensitivity",
    "SimLevLumpSum",
    "strategy_update_asset",
    "strategy_validate",
    "simlev_seed",
]


def export_dashboard(x, *, filename: str = "dashboard.svg", width: float = 14, height: float = 10, **kwargs):
    """Speichert das Dashboard als SVG-Datei (Größe in Zoll, 100 px je Zoll; nur Endung ``.svg``).

    Methoden und Export-Funktionen für ``"SimLevResult"``-Objekte, die von ``simulation`` zurückgegeben werden.

    ``plot`` erstellt ein mehrteiliges Dashboard-Layout mit wählbaren Panels (Wertentwicklung, Drawdown,
    Renditeverteilung, rollierende Renditen, Monatsrenditen-Heatmap, Kennzahlen, Korrelation, Strategievergleich).
    Korrelation und Strategievergleich gibt es nur mit ``compare``.

    ``export_dashboard`` speichert das Dashboard als PDF.

    ``print`` gibt die wichtigsten Kennzahlen und ggf. die Steuerzusammenfassung auf der Konsole aus. ``summary``
    liefert eine Liste der Klasse ``"summary.SimLevResult"`` und druckt nicht selbst; ihre Methode ``print`` zeigt
    die kompakte Kennzahlentabelle (in der Konsole erscheint sie bei ``summary(x)`` wie bisher, bei ``s <-
    summary(x)`` erst mit ``print(s)`` bzw. ``s``).

    Args:
        x: Ein ``"SimLevResult"``-Objekt (bei ``print.summary.SimLevResult``: das Ergebnis von ``summary``).
        filename: Character. Pfad der Ausgabedatei. Standard: ``"dashboard.pdf"``.
        width: Numerisch. Breite in Zoll. Standard: ``14``.
        height: Numerisch. Höhe in Zoll. Standard: ``10``.
        **kwargs: Für ``plot``, ``print``, ``summary``: wird ignoriert. Für ``export_dashboard``: wird an
            ``plot.SimLevResult`` weitergeleitet.

    Returns:
        - ``plot.SimLevResult``: Unsichtbar ``None`` (Seiteneffekt: Plot).

        - ``print.SimLevResult``: Unsichtbar ``x``.

        - ``summary.SimLevResult``: Sichtbar eine Liste der Klasse ``"summary.SimLevResult"`` mit ``n_days``,
          ``n_years``, ``start_value`` (Depotwert am Starttag in EUR, nach Kaufkosten und mit der Sparrate des
          Starttags; Ausgabe „Depotwert Starttag“), ``start_capital`` (Startkapital in EUR: Argument
          ``start_value`` von ``simulation``, berechnet als ``invested[1]`` minus Einzahlungen des Starttags;
          ``NA`` ohne ``invested``), ``end_value``, ``invested`` (EUR; Startwert plus Einzahlungen, brutto),
          ``total_return_twr`` (zeitgewichtete Gesamtrendite: mit Sparplan letzter Wert von ``twr_index`` minus 1,
          sonst Endwert / Depotwert am Starttag - 1), ``return_on_invested`` ((Endwert - Eingezahlt) /
          Eingezahlt), ``total_return`` (gleichwertiger Alias für ``total_return_twr``), ``cagr``, ``ttwror``
          (Anteile; mit Sparplan ist ``cagr`` geldgewichtet), den Kennzahlen aus ``statistics`` (``sharpe``,
          ``sortino``, ``calmar``, ``omega``, ``gain_to_pain``, ``serenity``, ``martin_ratio``, ``max_drawdown``,
          ``average_drawdown``, ``ulcer_index``, ``longest_drawdown``, ``avg_recovery_time``) sowie
          ``statistics``, ``tax_report`` (einschließlich ``open_tax_debt``, bei ``tax_mode = "person"``
          ``next_year``, mit ``taxable_income`` ``tariff_years``), ``undefined_metrics`` (Ursachen nicht
          definierter Kennzahlen, siehe ``simulation``) und ``external_flows``.

        - ``print.summary.SimLevResult``: Unsichtbar ``x``; gibt die kompakte Zusammenfassung aus (nicht
          definierte Kennzahlen als „nicht definiert (Ursache)“).

        - ``export_dashboard``: Unsichtbar ``None`` (PDF-Datei wird geschrieben; das PDF-Gerät wird auch bei einem
          Fehler wieder geschlossen).

    Details:
        Die Kennzahlen des Dashboards entsprechen ``x["statistics"]``: Die Sharpe Ratio ist
        ``statistics["sharpe"]`` (mit dem in ``simulation`` gewählten ``risk_free``), die annualisierte
        Volatilität ``statistics["sd"]`` mal Wurzel der tatsächlichen Beobachtungen je Jahr (ohne aufgefüllte
        Tage, also rund 252 bei Handelstagsdaten und 365 bei Kalenderdaten). Alle Renditen sind um Einzahlungen
        (Sparplan) bereinigt: Die Verteilungsgrafik zeigt einfache Tagesrenditen in Prozent ohne aufgefüllte
        (LOCF-)Tage, die rollierenden Renditen werden kalendergenau annualisiert (Exponent 365,25 / Kalendertage
        des Fensters), die Monats-Heatmap zeigt Monatsrenditen von Monatsende zu Monatsende (erster Monat ab dem
        Starttag) in Prozent; die Farbskala reicht von -10 bis +10 Prozent, stärkere Monate erhalten die Randfarbe
        (der Wert steht im Feld). Beträge werden in EUR beschriftet (Wertachse in Tsd. bzw. Mio., Einheit im
        Achsentitel; Endwert-Label mit drei gültigen Stellen, Kennzahlentabelle mit vollen Beträgen auf zwei
        Nachkommastellen). Die Ränder richten sich nach der Breite der Beschriftungen; Kennzahlentabelle und
        Strategievergleich verkleinern bei wenig Platz die Schrift (die Kennzahlen ggf. in zwei Spalten). Im
        Strategievergleich ist die Differenz Strategie 1 minus Strategie 2 grün, wenn Strategie 1 besser ist (bei
        Max. DD und Volatilität also kleiner), rot, wenn sie schlechter ist, und grau bei Gleichstand (auf zwei
        Nachkommastellen). Bei sehr kurzen Ergebnissen zeigen Panels ohne ausreichende Daten den Hinweis „Zu
        wenige Daten".

        **Sparplan (Einzahlungen, ``x["external_flows"] = True``).** Die Wertgrafik zeigt weiterhin den Depotwert
        ``x["worth"]`` und zusätzlich die Summe der Einzahlungen (Startwert plus Sparraten, ``x["invested"]``) als
        gepunktete Linie. Drawdown-Grafik und Drawdown-Kennzahlen beruhen auf dem zeitgewichteten Wertindex
        ``x["twr_index"]`` (wie ``x["drawdowns"]``), die CAGR ist geldgewichtet (interner Zinsfuß) und so
        beschriftet; die Gesamtrendite im Kennzahlen-Panel und im Vergleich ist zeitgewichtet, die Referenzlinie
        der rollierenden Renditen zeigt die TTWROR. ``print`` und ``summary`` kennzeichnen die CAGR als
        geldgewichtet, TTWROR, Gesamtrendite und Drawdowns als zeitgewichtet, nennen die eingezahlte Summe und
        weisen darauf hin, dass Calmar, Serenity und Martin Ratio dann mit der TTWROR rechnen. Ohne Einzahlungen
        bleiben Grafik und Ausgabe unverändert.

    Hinweise (Python):
        Weitere Argumente gehen an :func:`simlev.dashboard.plot_dashboard`.

    Beispiel::

        import numpy as np, pandas as pd, simlev
        rng = np.random.default_rng(1)
        n = 500
        d = pd.DataFrame({"date": pd.date_range("2021-01-01", periods=n)})
        d["ETF"] = 100 * np.cumprod(1 + rng.normal(4e-4, 0.012, n))
        import os, tempfile
        res = simlev.simulation(d, simlev.create_strategy(ETF=simlev.asset_config(asset_class="etf")))
        f = simlev.export_dashboard(res, filename=os.path.join(tempfile.mkdtemp(), "bericht.svg"))
    """
    from .dashboard import export_dashboard as _impl
    return _impl(x, filename=filename, width=width, height=height, **kwargs)


def summary(object, *args, **kwargs):  # noqa: A002 - R-Name
    """Generisches ``summary()`` wie in R: ruft die Methode ``object.summary()`` auf."""
    meth = getattr(type(object), "summary", None)
    if callable(meth):
        return meth(object, *args, **kwargs)
    if isinstance(object, SimLevResult):
        return _summary_result(object)
    raise TypeError("summary(): keine Methode f\u00fcr %s" % type(object).__name__)


def plot(x, *args, **kwargs):
    """Generisches ``plot()`` wie in R: ruft die Methode ``x.plot()`` auf.

    Ergebnis ist ein :class:`simlev.SimLevPlot` (SVG in ``svg``, dargestellte Werte je Panel in
    ``data``); geschrieben wird nur mit ``file="….svg"``."""
    meth = getattr(type(x), "plot", None)
    if callable(meth):
        return meth(x, *args, **kwargs)
    raise TypeError("plot(): keine Methode f\u00fcr %s" % type(x).__name__)
