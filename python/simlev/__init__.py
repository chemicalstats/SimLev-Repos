"""SimLev – Backtesting für ETF-, Hebel- und Multi-Asset-Strategien mit deutscher
Investmentbesteuerung.

Python-Portierung des gleichnamigen R-Pakets. Die Engine ``simulation()`` rechnet
bitgleich zur R-Version 0.5.0 (getestet unter Linux x86-64).
"""
import importlib as _importlib

from .config import (
    AssetConfig,
    Strategy,
    add_asset,
    asset_config,
    create_strategy,
    remove_asset,
    update_asset,
    validate_strategy,
)
from .engine import simulation
from .result import SimLevResult, SimLevSummary
from .svg import SimLevPlot
from .result import summary as _summary_result
from .tax_tariff import SimLevTaxTariff, read_tax_tariff
from .trigger import compute_rebal_trigger


# Erweiterungsmodule (R-Dateien gleichen Namens)
from .data_prep import (  # noqa: E402
    align_series,
    check_series,
    SimLevDataCheck,
    align_macro,
    convert_currency,
    total_return_index,
    deflate,
    splice_series,
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
    bond_index_from_yields,
    money_market_index,
    currency_hedged_index,
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
from ._r.rng import rng_kind, set_seed  # noqa: E402
from ._r.rnum import NA_REAL as NA  # noqa: E402,F401  R's NA_real_ (NaN mit Nutzlast 1954)

# Analysemodule (Schicht 3) werden erst beim ersten Zugriff auf einen ihrer Namen geladen
# (PEP 562: __getattr__ und __dir__ unten); `from simlev import X`, `simlev.X`, `dir(simlev)`
# und __all__ wirken wie beim sofortigen Laden. Der Name des Moduls selbst (bootstrap,
# deep_analysis, param_search) ist das aufrufbare Modul.
_LAZY = {
    "bootstrap": ("bootstrap_config", "BootstrapConfig", "block_length", "bootstrap", "BootstrapResult",
                  "validate_bootstrap", "bootstrap_data", "study_metrics", "bootstrap_study",
                  "SimLevBootstrapStudy", "SummarySimLevBootstrapStudy", "bootstrap_probability"),
    "withdrawal": ("withdrawal_rule", "WithdrawalRule", "withdrawal_cohorts", "WithdrawalPaths",
                   "result_index", "withdrawal_paths", "perfect_withdrawal_rate", "withdrawal_simulation",
                   "SimLevWithdrawal", "SummarySimLevWithdrawal", "withdrawal_max_rate", "horizon_model",
                   "SimLevHorizon"),
    "dependence": ("fit_copula", "tail_dependence", "dcc_fit", "dependence_analysis", "quantile_reg",
                   "tail_regression", "covar_analysis", "validate_dependence", "regime_subset",
                   "SimLevDependence", "SimLevTailRegression", "SimLevCoVaR"),
    "regimes": ("regime_hmm", "regime_states", "SimLevHMM"),
    "scenarios": ("view_mean", "view_prob", "view_vol", "entropy_pooling", "copula_scenarios",
                  "scenario_risk", "crisis_replay", "SimLevScenarios"),
    "optimize": ("portfolio_optimize", "efficient_frontier", "rolling_optimization", "risk_contributions",
                 "cpcv_portfolio", "SimLevOptimization", "SimLevFrontier", "SimLevCPCV",
                 "SimLevBoundsPercent"),
    "tactical": ("SimLevWeights", "signal_state", "momentum_score", "tactical_rules", "tactical_rotation",
                 "target_volatility", "conditional_volatility", "glidepath", "blend_weights",
                 "tactical_simulation"),
    "deep_analysis": ("deep_analysis", "SimLevAnalysis"),
    "planning": ("set_expected_return", "pooled_bootstrap", "portfolio_returns", "goal_optimize",
                 "SimLevGoalPlan"),
    "analysis_tests": ("signal_analysis", "sharpe_test", "reality_check", "min_track_record",
                       "return_heatmap", "SimLevSignalAnalysis", "SimLevRealityCheck", "SimLevHeatmap"),
    "overfitting": ("pbo", "probabilistic_sharpe", "deflated_sharpe", "walk_forward", "param_bootstrap",
                    "sharpe_haircut", "SimLevPBO", "SimLevDSR", "SimLevWalkForward"),
    "param_search": ("param_search", "param_space", "param_range", "plateau", "SimLevParamSpace",
                     "SimLevParamRange", "SimLevParamSearch", "SummarySimLevParamSearch"),
    "sensitivity": ("sensitivity_grid", "rebalancing_sensitivity", "lumpsum_vs_dca", "leveraged_series",
                    "leverage_sensitivity", "SimLevSensitivity", "SimLevLumpSum"),
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
    Module ``bootstrap``, ``deep_analysis`` und ``param_search`` machen sich am Ende ihrer
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
_LAZY_SUBMODULES = tuple(_LAZY) + ("_bootstrap_core", "_dependence_core", "_optimize_core", "_withdrawal_core")


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

__version__ = "0.8.0"

__all__ = [
    "AssetConfig",
    "SimLevResult",
    "SimLevPlot",
    "SimLevSummary",
    "SimLevTaxTariff",
    "Strategy",
    "add_asset",
    "asset_config",
    "compute_rebal_trigger",
    "create_strategy",
    "export_dashboard",
    "read_tax_tariff",
    "remove_asset",
    "simulation",
    "summary",
    "plot",
    "set_seed",
    "rng_kind",
    "NA",
    "isna_strict",
    "align_series",
    "check_series",
    "SimLevDataCheck",
    "align_macro",
    "convert_currency",
    "total_return_index",
    "deflate",
    "splice_series",
    "strategy_from_weights",
    "portfolio_template",
    "backcast_fit",
    "backcast",
    "SimLevBackcastFit",
    "SimLevBackcast",
    "bond_index_from_yields",
    "money_market_index",
    "currency_hedged_index",
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
    "block_length",
    "bootstrap",
    "BootstrapResult",
    "validate_bootstrap",
    "bootstrap_data",
    "study_metrics",
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
    "perfect_withdrawal_rate",
    "withdrawal_simulation",
    "SimLevWithdrawal",
    "SummarySimLevWithdrawal",
    "withdrawal_max_rate",
    "horizon_model",
    "SimLevHorizon",
    "fit_copula",
    "tail_dependence",
    "dcc_fit",
    "dependence_analysis",
    "quantile_reg",
    "tail_regression",
    "covar_analysis",
    "validate_dependence",
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
    "entropy_pooling",
    "copula_scenarios",
    "scenario_risk",
    "crisis_replay",
    "SimLevScenarios",
    "portfolio_optimize",
    "efficient_frontier",
    "rolling_optimization",
    "risk_contributions",
    "cpcv_portfolio",
    "SimLevOptimization",
    "SimLevFrontier",
    "SimLevCPCV",
    "SimLevBoundsPercent",
    "SimLevWeights",
    "signal_state",
    "momentum_score",
    "tactical_rules",
    "tactical_rotation",
    "target_volatility",
    "conditional_volatility",
    "glidepath",
    "blend_weights",
    "tactical_simulation",
    "deep_analysis",
    "SimLevAnalysis",
    "set_expected_return",
    "pooled_bootstrap",
    "portfolio_returns",
    "goal_optimize",
    "SimLevGoalPlan",
    "signal_analysis",
    "sharpe_test",
    "reality_check",
    "min_track_record",
    "return_heatmap",
    "SimLevSignalAnalysis",
    "SimLevRealityCheck",
    "SimLevHeatmap",
    "pbo",
    "probabilistic_sharpe",
    "deflated_sharpe",
    "walk_forward",
    "param_bootstrap",
    "sharpe_haircut",
    "SimLevPBO",
    "SimLevDSR",
    "SimLevWalkForward",
    "param_space",
    "param_range",
    "param_search",
    "plateau",
    "SimLevParamSpace",
    "SimLevParamRange",
    "SimLevParamSearch",
    "SummarySimLevParamSearch",
    "sensitivity_grid",
    "rebalancing_sensitivity",
    "lumpsum_vs_dca",
    "leveraged_series",
    "leverage_sensitivity",
    "SimLevSensitivity",
    "SimLevLumpSum",
    "update_asset",
    "validate_strategy",
]


def export_dashboard(x, filename: str = "dashboard.svg", width: float = 14, height: float = 10, **kwargs):
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
