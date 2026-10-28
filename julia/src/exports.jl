# Exporte der Erweiterungsmodule: die Funktionen der R-Exporte (r/NAMESPACE)
# stehen nach `using SimLev` direkt zur Verfügung.

const _MODULE_EXPORTS = (
    (:DataPrep, (:align_series, :check_series, :align_macro, :convert_currency, :total_return_index, :deflate,
                 :splice_series, :strategy_from_weights, :portfolio_template)),
    (:Backcast, (:backcast_fit, :backcast)),
    (:Bonds, (:bond_index_from_yields, :money_market_index, :currency_hedged_index)),
    (:Signals, (:signal_sma, :signal_ema, :signal_crossover, :signal_momentum, :signal_drawdown,
                :signal_volatility, :signal_combine)),
    (:Bootstrap, (:bootstrap_config, :block_length, :bootstrap, :validate_bootstrap,
                  :bootstrap_data, :study_metrics, :bootstrap_study, :bootstrap_probability)),
    (:Withdrawal, (:withdrawal_rule, :withdrawal_cohorts, :result_index, :withdrawal_paths,
                   :perfect_withdrawal_rate, :withdrawal_simulation, :withdrawal_max_rate, :horizon_model)),
    (:Dependence, (:fit_copula, :tail_dependence, :dcc_fit, :dependence_analysis, :quantile_reg,
                   :tail_regression, :covar_analysis, :validate_dependence, :regime_subset)),
    (:Regimes, (:regime_hmm, :regime_states)),
    (:Scenarios, (:view_mean, :view_prob, :view_vol, :entropy_pooling, :copula_scenarios, :scenario_risk,
                  :crisis_replay)),
    (:Optimize, (:portfolio_optimize, :efficient_frontier, :rolling_optimization, :risk_contributions,
                 :cpcv_portfolio)),
    (:Tactical, (:signal_state, :momentum_score, :tactical_rules, :tactical_rotation, :target_volatility,
                 :conditional_volatility, :glidepath, :blend_weights, :tactical_simulation)),
    (:DeepAnalysis, (:deep_analysis,)),
    (:Planning, (:set_expected_return, :pooled_bootstrap, :portfolio_returns, :goal_optimize)),
    (:AnalysisTests, (:signal_analysis, :sharpe_test, :reality_check, :min_track_record, :return_heatmap)),
    (:Overfitting, (:pbo, :probabilistic_sharpe, :deflated_sharpe, :walk_forward, :param_bootstrap,
                    :sharpe_haircut)),
    (:ParamSearch, (:param_space, :param_range, :param_search, :plateau)),
    (:Sensitivity, (:sensitivity_grid, :rebalancing_sensitivity, :lumpsum_vs_dca, :leveraged_series,
                    :leverage_sensitivity)),
)

for (m, fs) in _MODULE_EXPORTS
    for f in fs
        @eval const $f = $m.$f
        @eval export $f
    end
end

"`set.seed()` wie in R (globaler Zufallszustand, siehe `RRng`)."
const set_seed = RRng.set_seed
const rng_kind = RRng.rng_kind
export set_seed, rng_kind, read_tax_tariff, SimLevSummary, format_summary
