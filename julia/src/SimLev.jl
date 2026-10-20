"""
    SimLev

Backtesting für ETF-, Hebel- und Multi-Asset-Strategien mit deutscher
Investmentbesteuerung. Julia-Portierung des gleichnamigen R-Pakets; die
Engine rechnet bitgleich zur R-Version (Linux x86-64).
"""
module SimLev

using Dates
using Printf

export simulation, SimLevResult, format_result,
       asset_config, AssetConfig, create_strategy, Strategy, validate_strategy,
       add_asset, update_asset, remove_asset, migrate_strategy, as_list,
       compute_rebal_trigger, plot_interactive, plot_dashboard, export_dashboard,
       export_html_dashboard, SimLevDashboard, NA, isna_strict,
       RList, RFrame, RVector, NamedMat, named, nrow, ncol, rows, attrs, r_class, inherits,
       r_summary, r_plot

include("r/types.jl")
include("r/suggests.jl")
include("ld80.jl")
include("rnum.jl")
include("rformat.jl")
include("r/libm.jl")
include("r/base.jl")
include("r/rng.jl")
include("r/nmath.jl")
include("r/fmt.jl")
include("r/stats.jl")
include("r/linalg.jl")
include("r/rexpr.jl")
include("r/port.jl")
include("r/evd.jl")
include("r/truncnorm.jl")
include("r/solnp.jl")
include("r/rugarch.jl")
include("r/stinepack.jl")
include("r/imputets.jl")
include("dates.jl")
include("config.jl")
include("trigger.jl")
include("data.jl")
include("core.jl")
include("result.jl")
include("engine.jl")
include("interactive.jl")
include("dashboard.jl")
include("bootstrap_core.jl")
include("signals_core.jl")
include("withdrawal_core.jl")
include("dependence_core.jl")
include("optimize_core.jl")
include("data_prep.jl")
include("backcast.jl")
include("bonds.jl")
include("signals.jl")
include("bootstrap.jl")
include("withdrawal.jl")
include("dependence.jl")
include("regimes.jl")
include("scenarios.jl")
include("optimize.jl")
include("tactical.jl")
include("deep_analysis.jl")
include("planning.jl")
include("analysis_tests.jl")
include("overfitting.jl")
include("param_search.jl")
include("sensitivity.jl")
include("exports.jl")
include("precompile.jl")

end # module
