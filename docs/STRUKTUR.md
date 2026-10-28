# Struktur: Zuordnung R / Python / Julia

Diese Datei ist erzeugt; nicht von Hand ändern.

- **Erzeugt** mit `tools/api_snapshot/run.sh` (Auszüge `api_r.R`, `api_py.py`, `api_jl.jl`, Vergleich `compare_api.py`, diese Datei `make_struktur.py`) aus `tools/api_snapshot/api.json`.
- **Stand:** 2026-10-25.
- **Umfang:** R 104 Exporte und 66 S3-Methoden, Python 109 Funktionen und 68 Methoden, Julia 119 Funktionen und 66 Methoden.
- **Zuordnung:** R `a.b` → `a_b`; S3-Methode `<generic>.<Klasse>` → Python `<Klasse>.<generic>` (print über `.print` bzw. `.format`), Julia registrierte Methode (`show`, `r_summary`, `r_plot`). Regeln: `python/DEVELOPING.md`, `julia/DEVELOPING.md`.
- **Abweichungen** der Argumente und Standardwerte meldet `compare_api.py`; bekannte stehen in `tools/api_snapshot/known_differences.tsv`.
- Dateien relativ zu `r/R/`, `python/simlev/` bzw. `julia/src/`.

## Schichten

| Schicht | Inhalt | R | Python | Julia |
|---|---|---|---|---|
| 0 | R-Interna, eingebaute Pakete | (R selbst), `vendor_*` | `simlev/_r/` | `src/r/` |
| 1 | Daten und Strategie | `data_prep.R`, `strategy.R` … | `data_prep.py`, `config.py` | `data_prep.jl`, `config.jl` |
| 2 | Engine | `simulation.R`, `sim_*.R`, Kerne | `engine.py`, `_sim_*.py`, `_core.py`, `result.py` | `engine.jl`, `sim_*.jl` |
| 3 | Analysen | je eine `.R` | je ein Modul | je eine Datei |
| 4 | Ausgabe | `print`-Methoden, `plot_dashboard.R` | `svg.py`, `dashboard.py` | `svg.jl`, `dashboard.jl` |

## Öffentliche Funktionen (R-Exporte) (104)

| Name R | Datei R | Name Python | Datei Python | Name Julia | Datei Julia |
|---|---|---|---|---|---|
| `min_track_record` | `analysis_tests.R` | `min_track_record` | `analysis_tests.py` | `min_track_record` | `analysis_tests.jl` |
| `reality_check` | `analysis_tests.R` | `reality_check` | `analysis_tests.py` | `reality_check` | `analysis_tests.jl` |
| `return_heatmap` | `analysis_tests.R` | `return_heatmap` | `analysis_tests.py` | `return_heatmap` | `analysis_tests.jl` |
| `sharpe_test` | `analysis_tests.R` | `sharpe_test` | `analysis_tests.py` | `sharpe_test` | `analysis_tests.jl` |
| `signal_analysis` | `analysis_tests.R` | `signal_analysis` | `analysis_tests.py` | `signal_analysis` | `analysis_tests.jl` |
| `asset_config` | `asset_config.R` | `asset_config` | `config.py` | `asset_config` | `config.jl` |
| `backcast` | `backcast.R` | `backcast` | `backcast.py` | `backcast` | `backcast.jl` |
| `backcast_fit` | `backcast.R` | `backcast_fit` | `backcast.py` | `backcast_fit` | `backcast.jl` |
| `bond_index_from_yields` | `bonds.R` | `bond_index_from_yields` | `bonds.py` | `bond_index_from_yields` | `bonds.jl` |
| `currency_hedged_index` | `bonds.R` | `currency_hedged_index` | `bonds.py` | `currency_hedged_index` | `bonds.jl` |
| `money_market_index` | `bonds.R` | `money_market_index` | `bonds.py` | `money_market_index` | `bonds.jl` |
| `block_length` | `bootstrap.R` | `block_length` | `bootstrap.py` | `block_length` | `bootstrap.jl` |
| `bootstrap` | `bootstrap.R` | `bootstrap` | `bootstrap.py` | `bootstrap` | `bootstrap.jl` |
| `bootstrap_config` | `bootstrap.R` | `bootstrap_config` | `bootstrap.py` | `bootstrap_config` | `bootstrap.jl` |
| `bootstrap_data` | `bootstrap.R` | `bootstrap_data` | `bootstrap.py` | `bootstrap_data` | `bootstrap.jl` |
| `bootstrap_probability` | `bootstrap.R` | `bootstrap_probability` | `bootstrap.py` | `bootstrap_probability` | `bootstrap.jl` |
| `bootstrap_study` | `bootstrap.R` | `bootstrap_study` | `bootstrap.py` | `bootstrap_study` | `bootstrap.jl` |
| `study_metrics` | `bootstrap.R` | `study_metrics` | `bootstrap.py` | `study_metrics` | `bootstrap.jl` |
| `validate_bootstrap` | `bootstrap.R` | `validate_bootstrap` | `bootstrap.py` | `validate_bootstrap` | `bootstrap.jl` |
| `compute_rebal_trigger` | `compute_rebal_trigger.R` | `compute_rebal_trigger` | `trigger.py` | `compute_rebal_trigger` | `trigger.jl` |
| `align_macro` | `data_prep.R` | `align_macro` | `data_prep.py` | `align_macro` | `data_prep.jl` |
| `align_series` | `data_prep.R` | `align_series` | `data_prep.py` | `align_series` | `data_prep.jl` |
| `check_series` | `data_prep.R` | `check_series` | `data_prep.py` | `check_series` | `data_prep.jl` |
| `convert_currency` | `data_prep.R` | `convert_currency` | `data_prep.py` | `convert_currency` | `data_prep.jl` |
| `deflate` | `data_prep.R` | `deflate` | `data_prep.py` | `deflate` | `data_prep.jl` |
| `portfolio_template` | `data_prep.R` | `portfolio_template` | `data_prep.py` | `portfolio_template` | `data_prep.jl` |
| `splice_series` | `data_prep.R` | `splice_series` | `data_prep.py` | `splice_series` | `data_prep.jl` |
| `strategy_from_weights` | `data_prep.R` | `strategy_from_weights` | `data_prep.py` | `strategy_from_weights` | `data_prep.jl` |
| `total_return_index` | `data_prep.R` | `total_return_index` | `data_prep.py` | `total_return_index` | `data_prep.jl` |
| `deep_analysis` | `deep_analysis.R` | `deep_analysis` | `deep_analysis.py` | `deep_analysis` | `deep_analysis.jl` |
| `covar_analysis` | `dependence.R` | `covar_analysis` | `dependence.py` | `covar_analysis` | `dependence.jl` |
| `dcc_fit` | `dependence.R` | `dcc_fit` | `dependence.py` | `dcc_fit` | `dependence.jl` |
| `dependence_analysis` | `dependence.R` | `dependence_analysis` | `dependence.py` | `dependence_analysis` | `dependence.jl` |
| `fit_copula` | `dependence.R` | `fit_copula` | `dependence.py` | `fit_copula` | `dependence.jl` |
| `quantile_reg` | `dependence.R` | `quantile_reg` | `dependence.py` | `quantile_reg` | `dependence.jl` |
| `regime_subset` | `dependence.R` | `regime_subset` | `dependence.py` | `regime_subset` | `dependence.jl` |
| `tail_dependence` | `dependence.R` | `tail_dependence` | `dependence.py` | `tail_dependence` | `dependence.jl` |
| `tail_regression` | `dependence.R` | `tail_regression` | `dependence.py` | `tail_regression` | `dependence.jl` |
| `validate_dependence` | `dependence.R` | `validate_dependence` | `dependence.py` | `validate_dependence` | `dependence.jl` |
| `cpcv_portfolio` | `optimize.R` | `cpcv_portfolio` | `optimize.py` | `cpcv_portfolio` | `optimize.jl` |
| `efficient_frontier` | `optimize.R` | `efficient_frontier` | `optimize.py` | `efficient_frontier` | `optimize.jl` |
| `portfolio_optimize` | `optimize.R` | `portfolio_optimize` | `optimize.py` | `portfolio_optimize` | `optimize.jl` |
| `risk_contributions` | `optimize.R` | `risk_contributions` | `optimize.py` | `risk_contributions` | `optimize.jl` |
| `rolling_optimization` | `optimize.R` | `rolling_optimization` | `optimize.py` | `rolling_optimization` | `optimize.jl` |
| `deflated_sharpe` | `overfitting.R` | `deflated_sharpe` | `overfitting.py` | `deflated_sharpe` | `overfitting.jl` |
| `param_bootstrap` | `overfitting.R` | `param_bootstrap` | `overfitting.py` | `param_bootstrap` | `overfitting.jl` |
| `pbo` | `overfitting.R` | `pbo` | `overfitting.py` | `pbo` | `overfitting.jl` |
| `probabilistic_sharpe` | `overfitting.R` | `probabilistic_sharpe` | `overfitting.py` | `probabilistic_sharpe` | `overfitting.jl` |
| `sharpe_haircut` | `overfitting.R` | `sharpe_haircut` | `overfitting.py` | `sharpe_haircut` | `overfitting.jl` |
| `walk_forward` | `overfitting.R` | `walk_forward` | `overfitting.py` | `walk_forward` | `overfitting.jl` |
| `param_range` | `param_search.R` | `param_range` | `param_search.py` | `param_range` | `param_search.jl` |
| `param_search` | `param_search.R` | `param_search` | `param_search.py` | `param_search` | `param_search.jl` |
| `param_space` | `param_search.R` | `param_space` | `param_search.py` | `param_space` | `param_search.jl` |
| `plateau` | `param_search.R` | `plateau` | `param_search.py` | `plateau` | `param_search.jl` |
| `goal_optimize` | `planning.R` | `goal_optimize` | `planning.py` | `goal_optimize` | `planning.jl` |
| `pooled_bootstrap` | `planning.R` | `pooled_bootstrap` | `planning.py` | `pooled_bootstrap` | `planning.jl` |
| `portfolio_returns` | `planning.R` | `portfolio_returns` | `planning.py` | `portfolio_returns` | `planning.jl` |
| `set_expected_return` | `planning.R` | `set_expected_return` | `planning.py` | `set_expected_return` | `planning.jl` |
| `export_dashboard` | `plot_dashboard.R` | `export_dashboard` | `__init__.py` | `export_dashboard` | `dashboard.jl` |
| `regime_hmm` | `regimes.R` | `regime_hmm` | `regimes.py` | `regime_hmm` | `regimes.jl` |
| `regime_states` | `regimes.R` | `regime_states` | `regimes.py` | `regime_states` | `regimes.jl` |
| `copula_scenarios` | `scenarios.R` | `copula_scenarios` | `scenarios.py` | `copula_scenarios` | `scenarios.jl` |
| `crisis_replay` | `scenarios.R` | `crisis_replay` | `scenarios.py` | `crisis_replay` | `scenarios.jl` |
| `entropy_pooling` | `scenarios.R` | `entropy_pooling` | `scenarios.py` | `entropy_pooling` | `scenarios.jl` |
| `scenario_risk` | `scenarios.R` | `scenario_risk` | `scenarios.py` | `scenario_risk` | `scenarios.jl` |
| `view_mean` | `scenarios.R` | `view_mean` | `scenarios.py` | `view_mean` | `scenarios.jl` |
| `view_prob` | `scenarios.R` | `view_prob` | `scenarios.py` | `view_prob` | `scenarios.jl` |
| `view_vol` | `scenarios.R` | `view_vol` | `scenarios.py` | `view_vol` | `scenarios.jl` |
| `leverage_sensitivity` | `sensitivity.R` | `leverage_sensitivity` | `sensitivity.py` | `leverage_sensitivity` | `sensitivity.jl` |
| `leveraged_series` | `sensitivity.R` | `leveraged_series` | `sensitivity.py` | `leveraged_series` | `sensitivity.jl` |
| `lumpsum_vs_dca` | `sensitivity.R` | `lumpsum_vs_dca` | `sensitivity.py` | `lumpsum_vs_dca` | `sensitivity.jl` |
| `rebalancing_sensitivity` | `sensitivity.R` | `rebalancing_sensitivity` | `sensitivity.py` | `rebalancing_sensitivity` | `sensitivity.jl` |
| `sensitivity_grid` | `sensitivity.R` | `sensitivity_grid` | `sensitivity.py` | `sensitivity_grid` | `sensitivity.jl` |
| `signal_combine` | `signals.R` | `signal_combine` | `signals.py` | `signal_combine` | `signals.jl` |
| `signal_crossover` | `signals.R` | `signal_crossover` | `signals.py` | `signal_crossover` | `signals.jl` |
| `signal_drawdown` | `signals.R` | `signal_drawdown` | `signals.py` | `signal_drawdown` | `signals.jl` |
| `signal_ema` | `signals.R` | `signal_ema` | `signals.py` | `signal_ema` | `signals.jl` |
| `signal_momentum` | `signals.R` | `signal_momentum` | `signals.py` | `signal_momentum` | `signals.jl` |
| `signal_sma` | `signals.R` | `signal_sma` | `signals.py` | `signal_sma` | `signals.jl` |
| `signal_volatility` | `signals.R` | `signal_volatility` | `signals.py` | `signal_volatility` | `signals.jl` |
| `simulation` | `simulation.R` | `simulation` | `engine.py` | `simulation` | `sim_evaluate.jl` |
| `add_asset` | `strategy.R` | `add_asset` | `config.py` | `add_asset` | `config.jl` |
| `create_strategy` | `strategy.R` | `create_strategy` | `config.py` | `create_strategy` | `config.jl` |
| `remove_asset` | `strategy.R` | `remove_asset` | `config.py` | `remove_asset` | `config.jl` |
| `update_asset` | `strategy.R` | `update_asset` | `config.py` | `update_asset` | `config.jl` |
| `validate_strategy` | `strategy.R` | `validate_strategy` | `config.py` | `validate_strategy` | `config.jl` |
| `blend_weights` | `tactical.R` | `blend_weights` | `tactical.py` | `blend_weights` | `tactical.jl` |
| `conditional_volatility` | `tactical.R` | `conditional_volatility` | `tactical.py` | `conditional_volatility` | `tactical.jl` |
| `glidepath` | `tactical.R` | `glidepath` | `tactical.py` | `glidepath` | `tactical.jl` |
| `momentum_score` | `tactical.R` | `momentum_score` | `tactical.py` | `momentum_score` | `tactical.jl` |
| `signal_state` | `tactical.R` | `signal_state` | `tactical.py` | `signal_state` | `tactical.jl` |
| `tactical_rotation` | `tactical.R` | `tactical_rotation` | `tactical.py` | `tactical_rotation` | `tactical.jl` |
| `tactical_rules` | `tactical.R` | `tactical_rules` | `tactical.py` | `tactical_rules` | `tactical.jl` |
| `tactical_simulation` | `tactical.R` | `tactical_simulation` | `tactical.py` | `tactical_simulation` | `tactical.jl` |
| `target_volatility` | `tactical.R` | `target_volatility` | `tactical.py` | `target_volatility` | `tactical.jl` |
| `read_tax_tariff` | `tax_tariff.R` | `read_tax_tariff` | `tax_tariff.py` | `read_tax_tariff` | `tax_tariff.jl` |
| `horizon_model` | `withdrawal.R` | `horizon_model` | `withdrawal.py` | `horizon_model` | `withdrawal.jl` |
| `perfect_withdrawal_rate` | `withdrawal.R` | `perfect_withdrawal_rate` | `withdrawal.py` | `perfect_withdrawal_rate` | `withdrawal.jl` |
| `result_index` | `withdrawal.R` | `result_index` | `withdrawal.py` | `result_index` | `withdrawal.jl` |
| `withdrawal_cohorts` | `withdrawal.R` | `withdrawal_cohorts` | `withdrawal.py` | `withdrawal_cohorts` | `withdrawal.jl` |
| `withdrawal_max_rate` | `withdrawal.R` | `withdrawal_max_rate` | `withdrawal.py` | `withdrawal_max_rate` | `withdrawal.jl` |
| `withdrawal_paths` | `withdrawal.R` | `withdrawal_paths` | `withdrawal.py` | `withdrawal_paths` | `withdrawal.jl` |
| `withdrawal_rule` | `withdrawal.R` | `withdrawal_rule` | `withdrawal.py` | `withdrawal_rule` | `withdrawal.jl` |
| `withdrawal_simulation` | `withdrawal.R` | `withdrawal_simulation` | `withdrawal.py` | `withdrawal_simulation` | `withdrawal.jl` |

## S3-Methoden (68)

| Name R | Datei R | Name Python | Datei Python | Name Julia | Datei Julia |
|---|---|---|---|---|---|
| `plot.SimLevHeatmap` | `analysis_tests.R` | `SimLevHeatmap.plot` | `analysis_tests.py` | `r_plot(SimLevHeatmap)` | `analysis_tests.jl` |
| `plot.SimLevSignalAnalysis` | `analysis_tests.R` | `SimLevSignalAnalysis.plot` | `analysis_tests.py` | `r_plot(SimLevSignalAnalysis)` | `analysis_tests.jl` |
| `print.SimLevHeatmap` | `analysis_tests.R` | `SimLevHeatmap.format` | `analysis_tests.py` | `show(SimLevHeatmap)` | `analysis_tests.jl` |
| `print.SimLevRealityCheck` | `analysis_tests.R` | `SimLevRealityCheck.format` | `analysis_tests.py` | `show(SimLevRealityCheck)` | `analysis_tests.jl` |
| `print.SimLevSignalAnalysis` | `analysis_tests.R` | `SimLevSignalAnalysis.format` | `analysis_tests.py` | `show(SimLevSignalAnalysis)` | `analysis_tests.jl` |
| `print.asset_config` | `asset_config.R` | `AssetConfig.print` | `config.py` | `show(asset_config)` | `config.jl` |
| `summary.asset_config` | `asset_config.R` | `AssetConfig.summary` | `config.py` | `r_summary(asset_config)` | `config.jl` |
| `plot.SimLevBackcast` | `backcast.R` | `SimLevBackcast.plot` | `backcast.py` | `r_plot(SimLevBackcast)` | `backcast.jl` |
| `plot.SimLevBackcastFit` | `backcast.R` | `SimLevBackcastFit.plot` | `backcast.py` | `r_plot(SimLevBackcastFit)` | `backcast.jl` |
| `print.SimLevBackcast` | `backcast.R` | `SimLevBackcast.format` | `backcast.py` | `show(SimLevBackcast)` | `backcast.jl` |
| `print.SimLevBackcastFit` | `backcast.R` | `SimLevBackcastFit.format` | `backcast.py` | `show(SimLevBackcastFit)` | `backcast.jl` |
| `summary.SimLevBackcastFit` | `backcast.R` | `SimLevBackcastFit.summary` | `backcast.py` | `r_summary(SimLevBackcastFit)` | `backcast.jl` |
| `plot.SimLevBootstrapStudy` | `bootstrap.R` | `SimLevBootstrapStudy.plot` | `bootstrap.py` | `r_plot(SimLevBootstrapStudy)` | `bootstrap.jl` |
| `print.SimLevBootstrapStudy` | `bootstrap.R` | `SimLevBootstrapStudy.format` | `bootstrap.py` | `show(SimLevBootstrapStudy)` | `bootstrap.jl` |
| `print.bootstrap_config` | `bootstrap.R` | `BootstrapConfig.format` | `bootstrap.py` | `show(bootstrap_config)` | `bootstrap.jl` |
| `print.bootstrap_result` | `bootstrap.R` | `BootstrapResult.format` | `bootstrap.py` | `show(bootstrap_result)` | `bootstrap.jl` |
| `print.summary.SimLevBootstrapStudy` | `bootstrap.R` | `SummarySimLevBootstrapStudy.format` | `bootstrap.py` | `show(summary.SimLevBootstrapStudy)` | `bootstrap.jl` |
| `summary.SimLevBootstrapStudy` | `bootstrap.R` | `SimLevBootstrapStudy.summary` | `bootstrap.py` | `r_summary(SimLevBootstrapStudy)` | `bootstrap.jl` |
| `print.SimLevDataCheck` | `data_prep.R` | `SimLevDataCheck.print` | `data_prep.py` | `show(SimLevDataCheck)` | `data_prep.jl` |
| `plot.SimLevAnalysis` | `deep_analysis.R` | `SimLevAnalysis.plot` | `deep_analysis.py` | `r_plot(SimLevAnalysis)` | `deep_analysis.jl` |
| `print.SimLevAnalysis` | `deep_analysis.R` | `SimLevAnalysis.format` | `deep_analysis.py` | `show(SimLevAnalysis)` | `deep_analysis.jl` |
| `summary.SimLevAnalysis` | `deep_analysis.R` | `SimLevAnalysis.summary` | `deep_analysis.py` | `r_summary(SimLevAnalysis)` | `deep_analysis.jl` |
| `plot.SimLevCoVaR` | `dependence.R` | `SimLevCoVaR.plot` | `dependence.py` | `r_plot(SimLevCoVaR)` | `dependence.jl` |
| `plot.SimLevDependence` | `dependence.R` | `SimLevDependence.plot` | `dependence.py` | `r_plot(SimLevDependence)` | `dependence.jl` |
| `plot.SimLevTailRegression` | `dependence.R` | `SimLevTailRegression.plot` | `dependence.py` | `r_plot(SimLevTailRegression)` | `dependence.jl` |
| `print.SimLevCoVaR` | `dependence.R` | `SimLevCoVaR.format` | `dependence.py` | `show(SimLevCoVaR)` | `dependence.jl` |
| `print.SimLevDependence` | `dependence.R` | `SimLevDependence.format` | `dependence.py` | `show(SimLevDependence)` | `dependence.jl` |
| `print.SimLevTailRegression` | `dependence.R` | `SimLevTailRegression.format` | `dependence.py` | `show(SimLevTailRegression)` | `dependence.jl` |
| `plot.SimLevFrontier` | `optimize.R` | `SimLevFrontier.plot` | `optimize.py` | `r_plot(SimLevFrontier)` | `optimize.jl` |
| `plot.SimLevOptimization` | `optimize.R` | `SimLevOptimization.plot` | `optimize.py` | `r_plot(SimLevOptimization)` | `optimize.jl` |
| `print.SimLevCPCV` | `optimize.R` | `SimLevCPCV.format` | `optimize.py` | `show(SimLevCPCV)` | `optimize.jl` |
| `print.SimLevFrontier` | `optimize.R` | `SimLevFrontier.format` | `optimize.py` | `show(SimLevFrontier)` | `optimize.jl` |
| `print.SimLevOptimization` | `optimize.R` | `SimLevOptimization.format` | `optimize.py` | `show(SimLevOptimization)` | `optimize.jl` |
| `plot.SimLevPBO` | `overfitting.R` | `SimLevPBO.plot` | `overfitting.py` | `r_plot(SimLevPBO)` | `overfitting.jl` |
| `plot.SimLevWalkForward` | `overfitting.R` | `SimLevWalkForward.plot` | `overfitting.py` | `r_plot(SimLevWalkForward)` | `overfitting.jl` |
| `print.SimLevDSR` | `overfitting.R` | `SimLevDSR.print` | `overfitting.py` | `show(SimLevDSR)` | `overfitting.jl` |
| `print.SimLevPBO` | `overfitting.R` | `SimLevPBO.print` | `overfitting.py` | `show(SimLevPBO)` | `overfitting.jl` |
| `print.SimLevWalkForward` | `overfitting.R` | `SimLevWalkForward.print` | `overfitting.py` | `show(SimLevWalkForward)` | `overfitting.jl` |
| `plot.SimLevParamSearch` | `param_search.R` | `SimLevParamSearch.plot` | `param_search.py` | `r_plot(SimLevParamSearch)` | `param_search.jl` |
| `print.SimLevParamSearch` | `param_search.R` | `SimLevParamSearch.print` | `param_search.py` | `show(SimLevParamSearch)` | `param_search.jl` |
| `print.SimLevParamSpace` | `param_search.R` | `SimLevParamSpace.print` | `param_search.py` | `show(SimLevParamSpace)` | `param_search.jl` |
| `print.summary.SimLevParamSearch` | `param_search.R` | `SummarySimLevParamSearch.print` | `param_search.py` | `show(summary.SimLevParamSearch)` | `param_search.jl` |
| `summary.SimLevParamSearch` | `param_search.R` | `SimLevParamSearch.summary` | `param_search.py` | `r_summary(SimLevParamSearch)` | `param_search.jl` |
| `plot.SimLevGoalPlan` | `planning.R` | `SimLevGoalPlan.plot` | `planning.py` | `r_plot(SimLevGoalPlan)` | `planning.jl` |
| `print.SimLevGoalPlan` | `planning.R` | `SimLevGoalPlan.format` | `planning.py` | `show(SimLevGoalPlan)` | `planning.jl` |
| `plot.SimLevResult` | `plot_dashboard.R` | `SimLevResult.plot` | `dashboard.py` | `r_plot(SimLevResult)` | `dashboard.jl` |
| `plot.SimLevHMM` | `regimes.R` | `SimLevHMM.plot` | `regimes.py` | `r_plot(SimLevHMM)` | `regimes.jl` |
| `print.SimLevHMM` | `regimes.R` | `SimLevHMM.format` | `regimes.py` | `show(SimLevHMM)` | `regimes.jl` |
| `print.SimLevScenarios` | `scenarios.R` | `SimLevScenarios.format` | `scenarios.py` | `show(SimLevScenarios)` | `scenarios.jl` |
| `plot.SimLevSensitivity` | `sensitivity.R` | `SimLevSensitivity.plot` | `sensitivity.py` | `r_plot(SimLevSensitivity)` | `sensitivity.jl` |
| `print.SimLevLumpSum` | `sensitivity.R` | `SimLevLumpSum.print` | `sensitivity.py` | `show(SimLevLumpSum)` | `sensitivity.jl` |
| `print.SimLevSensitivity` | `sensitivity.R` | `SimLevSensitivity.print` | `sensitivity.py` | `show(SimLevSensitivity)` | `sensitivity.jl` |
| `print.SimLevResult` | `simulation.R` | `SimLevResult.print` | `result.py` | `show(SimLevResult)` | `result.jl` |
| `print.summary.SimLevResult` | `simulation.R` | `SimLevSummary.print` | `result.py` | `show(summary.SimLevResult)` | `result.jl` |
| `summary.SimLevResult` | `simulation.R` | `SimLevResult.summary` | `result.py` | `r_summary(SimLevResult)` | `result.jl` |
| `print.strategy` | `strategy.R` | `Strategy.print` | `config.py` | `show(strategy)` | `config.jl` |
| `summary.strategy` | `strategy.R` | `Strategy.summary` | `config.py` | `r_summary(strategy)` | `config.jl` |
| `plot.SimLevWeights` | `tactical.R` | `SimLevWeights.plot` | `tactical.py` | `r_plot(SimLevWeights)` | `tactical.jl` |
| `print.SimLevWeights` | `tactical.R` | `SimLevWeights.format` | `tactical.py` | `show(SimLevWeights)` | `tactical.jl` |
| `print.SimLevTaxTariff` | `tax_tariff.R` | `SimLevTaxTariff.print` | `tax_tariff.py` | `show(SimLevTaxTariff)` | `tax_tariff.jl` |
| `plot.SimLevWithdrawal` | `withdrawal.R` | `SimLevWithdrawal.plot` | `withdrawal.py` | `r_plot(SimLevWithdrawal)` | `withdrawal.jl` |
| `print.SimLevHorizon` | `withdrawal.R` | `SimLevHorizon.format` | `withdrawal.py` | `show(SimLevHorizon)` | `withdrawal.jl` |
| `print.SimLevWithdrawal` | `withdrawal.R` | `SimLevWithdrawal.format` | `withdrawal.py` | `show(SimLevWithdrawal)` | `withdrawal.jl` |
| `print.summary.SimLevWithdrawal` | `withdrawal.R` | `SummarySimLevWithdrawal.format` | `withdrawal.py` | `show(summary.SimLevWithdrawal)` | `withdrawal.jl` |
| `print.withdrawal_rule` | `withdrawal.R` | `WithdrawalRule.format` | `withdrawal.py` | `show(withdrawal_rule)` | `withdrawal.jl` |
| `summary.SimLevWithdrawal` | `withdrawal.R` | `SimLevWithdrawal.summary` | `withdrawal.py` | `r_summary(SimLevWithdrawal)` | `withdrawal.jl` |
| – | – | `SimLevParamRange.format` | `param_search.py` | – | – |
| – | – | `WithdrawalPathsPB.format` | `planning.py` | – | – |

## Nur in den Ports (15)

| Name R | Datei R | Name Python | Datei Python | Name Julia | Datei Julia |
|---|---|---|---|---|---|
| – | – | – | – | `attrs` | `r/stats_smooth.jl` |
| – | – | – | – | `format_result` | `result.jl` |
| – | – | – | – | `format_summary` | `result.jl` |
| – | – | – | – | `inherits` | `r/types.jl` |
| – | – | `isna_strict` | `__init__.py` | `isna_strict` | `r/rnum.jl` |
| – | – | – | – | `named` | `r/types.jl` |
| – | – | – | – | `ncol` | `r/types.jl` |
| – | – | – | – | `nrow` | `r/types.jl` |
| – | – | `plot` | `__init__.py` | `r_plot` | `r/types.jl` |
| – | – | – | – | `plot_dashboard` | `dashboard.jl` |
| – | – | – | – | `r_class` | `config.jl` |
| – | – | `rng_kind` | `_r/rng.py` | `rng_kind` | `r/rng.jl` |
| – | – | – | – | `rows` | `r/types.jl` |
| – | – | `set_seed` | `_r/rng.py` | `set_seed` | `r/rng.jl` |
| – | – | `summary` | `__init__.py` | `r_summary` | `r/types.jl` |
