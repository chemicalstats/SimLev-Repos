"""SimLev – Backtesting für ETF-, Hebel- und Multi-Asset-Strategien mit deutscher
Investmentbesteuerung.

Python-Portierung des gleichnamigen R-Pakets. Die Engine ``simulation()`` rechnet
bitgleich zur R-Version 0.5.0 (getestet unter Linux x86-64).
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
# Zufallszustand der C-Bibliothek slc (Etappe 9.1, simlev/_lib.py)
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

__version__ = "1.0.0"

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

    Weitere Argumente gehen an :func:`simlev.dashboard.plot_dashboard`."""
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
