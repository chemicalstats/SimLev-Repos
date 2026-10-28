# Exporte der Erweiterungsmodule: die Funktionen der R-Exporte (r/NAMESPACE)
# stehen nach `using SimLev` direkt zur Verfügung.

const _MODULE_EXPORTS = (
    (:DataPrep, (:series_align, :series_check, :series_align_macro, :series_convert_currency, :index_total_return, :series_deflate,
                 :series_splice, :strategy_from_weights, :portfolio_template)),
    (:Backcast, (:backcast_fit, :backcast)),
    (:Bonds, (:index_bond, :index_money_market, :index_currency_hedged)),
    (:Signals, (:signal_sma, :signal_ema, :signal_crossover, :signal_momentum, :signal_drawdown,
                :signal_volatility, :signal_combine)),
    (:Bootstrap, (:bootstrap_config, :bootstrap_block_length, :bootstrap, :bootstrap_validate,
                  :bootstrap_data, :bootstrap_study_metrics, :bootstrap_study, :bootstrap_probability)),
    (:Withdrawal, (:withdrawal_rule, :withdrawal_cohorts, :result_index, :withdrawal_paths,
                   :withdrawal_perfect_rate, :withdrawal_simulation, :withdrawal_max_rate, :withdrawal_horizon)),
    (:Dependence, (:copula_fit, :tail_dependence, :dependence_dcc, :dependence_analysis, :quantile_regression,
                   :tail_regression, :tail_covar, :dependence_validate, :regime_subset)),
    (:Regimes, (:regime_hmm, :regime_states)),
    (:Scenarios, (:view_mean, :view_prob, :view_vol, :scenario_entropy_pooling, :scenario_copula, :scenario_risk,
                  :scenario_crisis)),
    (:Optimize, (:portfolio_optimize, :portfolio_frontier, :portfolio_rolling, :portfolio_risk_contributions,
                 :portfolio_cpcv)),
    (:Tactical, (:signal_state, :momentum_score, :tactical_rules, :tactical_rotation, :tactical_target_volatility,
                 :tactical_conditional_volatility, :tactical_glidepath, :tactical_blend, :tactical_simulation)),
    (:DeepAnalysis, (:result_analysis,)),
    (:Planning, (:series_shift_return, :bootstrap_pooled, :portfolio_returns, :planning_goal)),
    (:AnalysisTests, (:signal_analysis, :sharpe_test, :overfit_reality_check, :sharpe_min_track_record, :result_heatmap)),
    (:Overfitting, (:overfit_pbo, :sharpe_probabilistic, :sharpe_deflated, :overfit_walk_forward, :param_bootstrap,
                    :sharpe_haircut)),
    (:ParamSearch, (:param_space, :param_range, :param_search, :param_plateau)),
    (:Sensitivity, (:sensitivity_grid, :sensitivity_rebalancing, :planning_lumpsum_vs_dca, :series_leverage,
                    :sensitivity_leverage)),
)

for (m, fs) in _MODULE_EXPORTS
    for f in fs
        @eval const $f = $m.$f
        @eval export $f
    end
end

# Zufallszustand der C-Bibliothek slc (Etappe 9.1, src/slib.jl)
const simlev_seed = SLib.simlev_seed
export simlev_seed

# set_seed/rng_kind (Nachbildung von R's Zufall, RRng) sind mit Etappe 9.6c entfallen (Entwurf C.6)
export tax_tariff, SimLevSummary, format_summary
# Bausteine für simulation() (Etappe 6.3, sim_blocks.jl)
export sim_costs, dca_plan, rebalance_plan, split_rule, tax_profile, income_rate, income_tariff, harvest_rule,
       funds_costs
# Fonds-Wrapper (Etappe 6.5c, wrapper.jl)
export wrapper_config, wrapper_nav
