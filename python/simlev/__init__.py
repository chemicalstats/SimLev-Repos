"""SimLev – Backtesting für ETF-, Hebel- und Multi-Asset-Strategien mit deutscher
Investmentbesteuerung.

Python-Portierung des gleichnamigen R-Pakets. Die Engine ``simulation()`` rechnet
bitgleich zur R-Version 0.5.0 (getestet unter Linux x86-64).
"""
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
from .bootstrap import (  # noqa: E402
    bootstrap_config,
    BootstrapConfig,
    block_length,
    bootstrap,
    BootstrapResult,
    validate_bootstrap,
    bootstrap_data,
    study_metrics,
    bootstrap_study,
    SimLevBootstrapStudy,
    SummarySimLevBootstrapStudy,
    bootstrap_probability,
)
from .withdrawal import (  # noqa: E402
    withdrawal_rule,
    WithdrawalRule,
    withdrawal_cohorts,
    WithdrawalPaths,
    result_index,
    withdrawal_paths,
    perfect_withdrawal_rate,
    withdrawal_simulation,
    SimLevWithdrawal,
    SummarySimLevWithdrawal,
    withdrawal_max_rate,
    horizon_model,
    SimLevHorizon,
)
from .dependence import (  # noqa: E402
    fit_copula,
    tail_dependence,
    dcc_fit,
    dependence_analysis,
    quantile_reg,
    tail_regression,
    covar_analysis,
    validate_dependence,
    regime_subset,
    SimLevDependence,
    SimLevTailRegression,
    SimLevCoVaR,
)
from .regimes import (  # noqa: E402
    regime_hmm,
    regime_states,
    SimLevHMM,
)
from .scenarios import (  # noqa: E402
    view_mean,
    view_prob,
    view_vol,
    entropy_pooling,
    copula_scenarios,
    scenario_risk,
    crisis_replay,
    SimLevScenarios,
)
from .optimize import (  # noqa: E402
    portfolio_optimize,
    efficient_frontier,
    rolling_optimization,
    risk_contributions,
    cpcv_portfolio,
    SimLevOptimization,
    SimLevFrontier,
    SimLevCPCV,
    SimLevBoundsPercent,
)
from .tactical import (  # noqa: E402
    SimLevWeights,
    signal_state,
    momentum_score,
    tactical_rules,
    tactical_rotation,
    target_volatility,
    conditional_volatility,
    glidepath,
    blend_weights,
    tactical_simulation,
)
from .deep_analysis import (  # noqa: E402
    SimLevAnalysis,
)
from .planning import (  # noqa: E402
    set_expected_return,
    pooled_bootstrap,
    portfolio_returns,
    goal_optimize,
    SimLevGoalPlan,
)
from .analysis_tests import (  # noqa: E402
    signal_analysis,
    sharpe_test,
    reality_check,
    min_track_record,
    return_heatmap,
    SimLevSignalAnalysis,
    SimLevRealityCheck,
    SimLevHeatmap,
)
from .overfitting import (  # noqa: E402
    pbo,
    probabilistic_sharpe,
    deflated_sharpe,
    walk_forward,
    param_bootstrap,
    sharpe_haircut,
    SimLevPBO,
    SimLevDSR,
    SimLevWalkForward,
)
from .param_search import (  # noqa: E402
    param_space,
    param_range,
    plateau,
    SimLevParamSpace,
    SimLevParamRange,
    SimLevParamSearch,
    SummarySimLevParamSearch,
)
from .sensitivity import (  # noqa: E402
    sensitivity_grid,
    rebalancing_sensitivity,
    lumpsum_vs_dca,
    leveraged_series,
    leverage_sensitivity,
    SimLevSensitivity,
    SimLevLumpSum,
)
from ._r.rng import rng_kind, set_seed  # noqa: E402
from ._r.rnum import NA_REAL as NA  # noqa: E402,F401  R's NA_real_ (NaN mit Nutzlast 1954)


def isna_strict(x):
    """True nur für R's ``NA`` (nicht für ``NaN``); Skalar oder elementweise für Arrays."""
    import numpy as _np
    from ._r.rnum import r_isna, r_isna_arr
    if _np.ndim(x) == 0:
        return r_isna(x)
    return r_isna_arr(x)



def _callable_module(name):
    """Macht das Untermodul ``simlev.<name>`` aufrufbar wie die gleichnamige Funktion.

    So gilt ``simlev.bootstrap(...)`` wie in R, und ``simlev.bootstrap.bootstrap_config``
    bzw. ``import simlev.bootstrap`` erreichen weiter das Modul."""
    import sys
    import types

    mod = sys.modules[__name__ + "." + name]

    class _CallableModule(types.ModuleType):
        def __call__(self, *args, **kwargs):
            return getattr(self, name)(*args, **kwargs)

    mod.__class__ = _CallableModule
    return mod


backcast = _callable_module("backcast")
bootstrap = _callable_module("bootstrap")
deep_analysis = _callable_module("deep_analysis")
param_search = _callable_module("param_search")

__version__ = "0.5.1"

__all__ = [
    "AssetConfig",
    "SimLevResult",
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


def export_dashboard(x, filename: str = "dashboard.pdf", width: float = 14, height: float = 10, **kwargs):
    """Speichert das Dashboard als PDF (oder anderes von matplotlib unterstütztes Format)."""
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
    """Generisches ``plot()`` wie in R: ruft die Methode ``x.plot()`` auf (matplotlib)."""
    meth = getattr(type(x), "plot", None)
    if callable(meth):
        return meth(x, *args, **kwargs)
    raise TypeError("plot(): keine Methode f\u00fcr %s" % type(x).__name__)
