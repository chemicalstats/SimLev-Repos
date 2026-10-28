# Struktur: Zuordnung R / Python / Julia

Diese Datei ist erzeugt; nicht von Hand ändern.

- **Erzeugt** mit `tools/api_snapshot/run.sh` (Auszüge `api_r.R`, `api_py.py`, `api_jl.jl`, Vergleich `compare_api.py`, diese Datei `make_struktur.py`) aus `tools/api_snapshot/api.json`.
- **Stand:** 2026-10-27.
- **Umfang:** R 115 Exporte und 78 S3-Methoden, Python 120 Funktionen und 79 Methoden, Julia 130 Funktionen und 77 Methoden.
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

## Öffentliche Funktionen (R-Exporte) (115)

| Name R | Datei R | Name Python | Datei Python | Name Julia | Datei Julia |
|---|---|---|---|---|---|
| `overfit_reality_check` | `analysis_tests.R` | `overfit_reality_check` | `analysis_tests.py` | `overfit_reality_check` | `analysis_tests.jl` |
| `result_heatmap` | `analysis_tests.R` | `result_heatmap` | `analysis_tests.py` | `result_heatmap` | `analysis_tests.jl` |
| `sharpe_min_track_record` | `analysis_tests.R` | `sharpe_min_track_record` | `analysis_tests.py` | `sharpe_min_track_record` | `analysis_tests.jl` |
| `sharpe_test` | `analysis_tests.R` | `sharpe_test` | `analysis_tests.py` | `sharpe_test` | `analysis_tests.jl` |
| `signal_analysis` | `analysis_tests.R` | `signal_analysis` | `analysis_tests.py` | `signal_analysis` | `analysis_tests.jl` |
| `asset_config` | `asset_config.R` | `asset_config` | `config.py` | `asset_config` | `config.jl` |
| `backcast` | `backcast.R` | `backcast` | `backcast.py` | `backcast` | `backcast.jl` |
| `backcast_fit` | `backcast.R` | `backcast_fit` | `backcast.py` | `backcast_fit` | `backcast.jl` |
| `index_bond` | `bonds.R` | `index_bond` | `bonds.py` | `index_bond` | `bonds.jl` |
| `index_currency_hedged` | `bonds.R` | `index_currency_hedged` | `bonds.py` | `index_currency_hedged` | `bonds.jl` |
| `index_money_market` | `bonds.R` | `index_money_market` | `bonds.py` | `index_money_market` | `bonds.jl` |
| `bootstrap` | `bootstrap.R` | `bootstrap` | `bootstrap.py` | `bootstrap` | `bootstrap.jl` |
| `bootstrap_block_length` | `bootstrap.R` | `bootstrap_block_length` | `bootstrap.py` | `bootstrap_block_length` | `bootstrap.jl` |
| `bootstrap_config` | `bootstrap.R` | `bootstrap_config` | `bootstrap.py` | `bootstrap_config` | `bootstrap.jl` |
| `bootstrap_data` | `bootstrap.R` | `bootstrap_data` | `bootstrap.py` | `bootstrap_data` | `bootstrap.jl` |
| `bootstrap_probability` | `bootstrap.R` | `bootstrap_probability` | `bootstrap.py` | `bootstrap_probability` | `bootstrap.jl` |
| `bootstrap_study` | `bootstrap.R` | `bootstrap_study` | `bootstrap.py` | `bootstrap_study` | `bootstrap.jl` |
| `bootstrap_study_metrics` | `bootstrap.R` | `bootstrap_study_metrics` | `bootstrap.py` | `bootstrap_study_metrics` | `bootstrap.jl` |
| `bootstrap_validate` | `bootstrap.R` | `bootstrap_validate` | `bootstrap.py` | `bootstrap_validate` | `bootstrap.jl` |
| `rebalance_trigger` | `compute_rebal_trigger.R` | `rebalance_trigger` | `trigger.py` | `rebalance_trigger` | `trigger.jl` |
| `index_total_return` | `data_prep.R` | `index_total_return` | `data_prep.py` | `index_total_return` | `data_prep.jl` |
| `portfolio_template` | `data_prep.R` | `portfolio_template` | `data_prep.py` | `portfolio_template` | `data_prep.jl` |
| `series_align` | `data_prep.R` | `series_align` | `data_prep.py` | `series_align` | `data_prep.jl` |
| `series_align_macro` | `data_prep.R` | `series_align_macro` | `data_prep.py` | `series_align_macro` | `data_prep.jl` |
| `series_check` | `data_prep.R` | `series_check` | `data_prep.py` | `series_check` | `data_prep.jl` |
| `series_convert_currency` | `data_prep.R` | `series_convert_currency` | `data_prep.py` | `series_convert_currency` | `data_prep.jl` |
| `series_deflate` | `data_prep.R` | `series_deflate` | `data_prep.py` | `series_deflate` | `data_prep.jl` |
| `series_splice` | `data_prep.R` | `series_splice` | `data_prep.py` | `series_splice` | `data_prep.jl` |
| `strategy_from_weights` | `data_prep.R` | `strategy_from_weights` | `data_prep.py` | `strategy_from_weights` | `data_prep.jl` |
| `result_analysis` | `deep_analysis.R` | `result_analysis` | `deep_analysis.py` | `result_analysis` | `deep_analysis.jl` |
| `copula_fit` | `dependence.R` | `copula_fit` | `dependence.py` | `copula_fit` | `dependence.jl` |
| `dependence_analysis` | `dependence.R` | `dependence_analysis` | `dependence.py` | `dependence_analysis` | `dependence.jl` |
| `dependence_dcc` | `dependence.R` | `dependence_dcc` | `dependence.py` | `dependence_dcc` | `dependence.jl` |
| `dependence_validate` | `dependence.R` | `dependence_validate` | `dependence.py` | `dependence_validate` | `dependence.jl` |
| `quantile_regression` | `dependence.R` | `quantile_regression` | `dependence.py` | `quantile_regression` | `dependence.jl` |
| `regime_subset` | `dependence.R` | `regime_subset` | `dependence.py` | `regime_subset` | `dependence.jl` |
| `tail_covar` | `dependence.R` | `tail_covar` | `dependence.py` | `tail_covar` | `dependence.jl` |
| `tail_dependence` | `dependence.R` | `tail_dependence` | `dependence.py` | `tail_dependence` | `dependence.jl` |
| `tail_regression` | `dependence.R` | `tail_regression` | `dependence.py` | `tail_regression` | `dependence.jl` |
| `portfolio_cpcv` | `optimize.R` | `portfolio_cpcv` | `optimize.py` | `portfolio_cpcv` | `optimize.jl` |
| `portfolio_frontier` | `optimize.R` | `portfolio_frontier` | `optimize.py` | `portfolio_frontier` | `optimize.jl` |
| `portfolio_optimize` | `optimize.R` | `portfolio_optimize` | `optimize.py` | `portfolio_optimize` | `optimize.jl` |
| `portfolio_risk_contributions` | `optimize.R` | `portfolio_risk_contributions` | `optimize.py` | `portfolio_risk_contributions` | `optimize.jl` |
| `portfolio_rolling` | `optimize.R` | `portfolio_rolling` | `optimize.py` | `portfolio_rolling` | `optimize.jl` |
| `overfit_pbo` | `overfitting.R` | `overfit_pbo` | `overfitting.py` | `overfit_pbo` | `overfitting.jl` |
| `overfit_walk_forward` | `overfitting.R` | `overfit_walk_forward` | `overfitting.py` | `overfit_walk_forward` | `overfitting.jl` |
| `param_bootstrap` | `overfitting.R` | `param_bootstrap` | `overfitting.py` | `param_bootstrap` | `overfitting.jl` |
| `sharpe_deflated` | `overfitting.R` | `sharpe_deflated` | `overfitting.py` | `sharpe_deflated` | `overfitting.jl` |
| `sharpe_haircut` | `overfitting.R` | `sharpe_haircut` | `overfitting.py` | `sharpe_haircut` | `overfitting.jl` |
| `sharpe_probabilistic` | `overfitting.R` | `sharpe_probabilistic` | `overfitting.py` | `sharpe_probabilistic` | `overfitting.jl` |
| `param_plateau` | `param_search.R` | `param_plateau` | `param_search.py` | `param_plateau` | `param_search.jl` |
| `param_range` | `param_search.R` | `param_range` | `param_search.py` | `param_range` | `param_search.jl` |
| `param_search` | `param_search.R` | `param_search` | `param_search.py` | `param_search` | `param_search.jl` |
| `param_space` | `param_search.R` | `param_space` | `param_search.py` | `param_space` | `param_search.jl` |
| `bootstrap_pooled` | `planning.R` | `bootstrap_pooled` | `planning.py` | `bootstrap_pooled` | `planning.jl` |
| `planning_goal` | `planning.R` | `planning_goal` | `planning.py` | `planning_goal` | `planning.jl` |
| `portfolio_returns` | `planning.R` | `portfolio_returns` | `planning.py` | `portfolio_returns` | `planning.jl` |
| `series_shift_return` | `planning.R` | `series_shift_return` | `planning.py` | `series_shift_return` | `planning.jl` |
| `export_dashboard` | `plot_dashboard.R` | `export_dashboard` | `__init__.py` | `export_dashboard` | `dashboard.jl` |
| `regime_hmm` | `regimes.R` | `regime_hmm` | `regimes.py` | `regime_hmm` | `regimes.jl` |
| `regime_states` | `regimes.R` | `regime_states` | `regimes.py` | `regime_states` | `regimes.jl` |
| `scenario_copula` | `scenarios.R` | `scenario_copula` | `scenarios.py` | `scenario_copula` | `scenarios.jl` |
| `scenario_crisis` | `scenarios.R` | `scenario_crisis` | `scenarios.py` | `scenario_crisis` | `scenarios.jl` |
| `scenario_entropy_pooling` | `scenarios.R` | `scenario_entropy_pooling` | `scenarios.py` | `scenario_entropy_pooling` | `scenarios.jl` |
| `scenario_risk` | `scenarios.R` | `scenario_risk` | `scenarios.py` | `scenario_risk` | `scenarios.jl` |
| `view_mean` | `scenarios.R` | `view_mean` | `scenarios.py` | `view_mean` | `scenarios.jl` |
| `view_prob` | `scenarios.R` | `view_prob` | `scenarios.py` | `view_prob` | `scenarios.jl` |
| `view_vol` | `scenarios.R` | `view_vol` | `scenarios.py` | `view_vol` | `scenarios.jl` |
| `planning_lumpsum_vs_dca` | `sensitivity.R` | `planning_lumpsum_vs_dca` | `sensitivity.py` | `planning_lumpsum_vs_dca` | `sensitivity.jl` |
| `sensitivity_grid` | `sensitivity.R` | `sensitivity_grid` | `sensitivity.py` | `sensitivity_grid` | `sensitivity.jl` |
| `sensitivity_leverage` | `sensitivity.R` | `sensitivity_leverage` | `sensitivity.py` | `sensitivity_leverage` | `sensitivity.jl` |
| `sensitivity_rebalancing` | `sensitivity.R` | `sensitivity_rebalancing` | `sensitivity.py` | `sensitivity_rebalancing` | `sensitivity.jl` |
| `series_leverage` | `sensitivity.R` | `series_leverage` | `sensitivity.py` | `series_leverage` | `sensitivity.jl` |
| `signal_combine` | `signals.R` | `signal_combine` | `signals.py` | `signal_combine` | `signals.jl` |
| `signal_crossover` | `signals.R` | `signal_crossover` | `signals.py` | `signal_crossover` | `signals.jl` |
| `signal_drawdown` | `signals.R` | `signal_drawdown` | `signals.py` | `signal_drawdown` | `signals.jl` |
| `signal_ema` | `signals.R` | `signal_ema` | `signals.py` | `signal_ema` | `signals.jl` |
| `signal_momentum` | `signals.R` | `signal_momentum` | `signals.py` | `signal_momentum` | `signals.jl` |
| `signal_sma` | `signals.R` | `signal_sma` | `signals.py` | `signal_sma` | `signals.jl` |
| `signal_volatility` | `signals.R` | `signal_volatility` | `signals.py` | `signal_volatility` | `signals.jl` |
| `dca_plan` | `sim_blocks.R` | `dca_plan` | `_sim_blocks.py` | `dca_plan` | `sim_blocks.jl` |
| `funds_costs` | `sim_blocks.R` | `funds_costs` | `_sim_blocks.py` | `funds_costs` | `sim_blocks.jl` |
| `harvest_rule` | `sim_blocks.R` | `harvest_rule` | `_sim_blocks.py` | `harvest_rule` | `sim_blocks.jl` |
| `income_rate` | `sim_blocks.R` | `income_rate` | `_sim_blocks.py` | `income_rate` | `sim_blocks.jl` |
| `income_tariff` | `sim_blocks.R` | `income_tariff` | `_sim_blocks.py` | `income_tariff` | `sim_blocks.jl` |
| `rebalance_plan` | `sim_blocks.R` | `rebalance_plan` | `_sim_blocks.py` | `rebalance_plan` | `sim_blocks.jl` |
| `sim_costs` | `sim_blocks.R` | `sim_costs` | `_sim_blocks.py` | `sim_costs` | `sim_blocks.jl` |
| `split_rule` | `sim_blocks.R` | `split_rule` | `_sim_blocks.py` | `split_rule` | `sim_blocks.jl` |
| `tax_profile` | `sim_blocks.R` | `tax_profile` | `_sim_blocks.py` | `tax_profile` | `sim_blocks.jl` |
| `simulation` | `simulation.R` | `simulation` | `engine.py` | `simulation` | `sim_evaluate.jl` |
| `create_strategy` | `strategy.R` | `create_strategy` | `config.py` | `create_strategy` | `config.jl` |
| `strategy_add_asset` | `strategy.R` | `strategy_add_asset` | `config.py` | `strategy_add_asset` | `config.jl` |
| `strategy_remove_asset` | `strategy.R` | `strategy_remove_asset` | `config.py` | `strategy_remove_asset` | `config.jl` |
| `strategy_update_asset` | `strategy.R` | `strategy_update_asset` | `config.py` | `strategy_update_asset` | `config.jl` |
| `strategy_validate` | `strategy.R` | `strategy_validate` | `config.py` | `strategy_validate` | `config.jl` |
| `momentum_score` | `tactical.R` | `momentum_score` | `tactical.py` | `momentum_score` | `tactical.jl` |
| `signal_state` | `tactical.R` | `signal_state` | `tactical.py` | `signal_state` | `tactical.jl` |
| `tactical_blend` | `tactical.R` | `tactical_blend` | `tactical.py` | `tactical_blend` | `tactical.jl` |
| `tactical_conditional_volatility` | `tactical.R` | `tactical_conditional_volatility` | `tactical.py` | `tactical_conditional_volatility` | `tactical.jl` |
| `tactical_glidepath` | `tactical.R` | `tactical_glidepath` | `tactical.py` | `tactical_glidepath` | `tactical.jl` |
| `tactical_rotation` | `tactical.R` | `tactical_rotation` | `tactical.py` | `tactical_rotation` | `tactical.jl` |
| `tactical_rules` | `tactical.R` | `tactical_rules` | `tactical.py` | `tactical_rules` | `tactical.jl` |
| `tactical_simulation` | `tactical.R` | `tactical_simulation` | `tactical.py` | `tactical_simulation` | `tactical.jl` |
| `tactical_target_volatility` | `tactical.R` | `tactical_target_volatility` | `tactical.py` | `tactical_target_volatility` | `tactical.jl` |
| `tax_tariff` | `tax_tariff.R` | `tax_tariff` | `_tax_tariff.py` | `tax_tariff` | `tax_tariff.jl` |
| `result_index` | `withdrawal.R` | `result_index` | `withdrawal.py` | `result_index` | `withdrawal.jl` |
| `withdrawal_cohorts` | `withdrawal.R` | `withdrawal_cohorts` | `withdrawal.py` | `withdrawal_cohorts` | `withdrawal.jl` |
| `withdrawal_horizon` | `withdrawal.R` | `withdrawal_horizon` | `withdrawal.py` | `withdrawal_horizon` | `withdrawal.jl` |
| `withdrawal_max_rate` | `withdrawal.R` | `withdrawal_max_rate` | `withdrawal.py` | `withdrawal_max_rate` | `withdrawal.jl` |
| `withdrawal_paths` | `withdrawal.R` | `withdrawal_paths` | `withdrawal.py` | `withdrawal_paths` | `withdrawal.jl` |
| `withdrawal_perfect_rate` | `withdrawal.R` | `withdrawal_perfect_rate` | `withdrawal.py` | `withdrawal_perfect_rate` | `withdrawal.jl` |
| `withdrawal_rule` | `withdrawal.R` | `withdrawal_rule` | `withdrawal.py` | `withdrawal_rule` | `withdrawal.jl` |
| `withdrawal_simulation` | `withdrawal.R` | `withdrawal_simulation` | `withdrawal.py` | `withdrawal_simulation` | `withdrawal.jl` |
| `wrapper_config` | `wrapper.R` | `wrapper_config` | `wrapper.py` | `wrapper_config` | `wrapper.jl` |
| `wrapper_nav` | `wrapper.R` | `wrapper_nav` | `wrapper.py` | `wrapper_nav` | `wrapper.jl` |

## S3-Methoden (80)

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
| `print.SimLevDcaPlan` | `sim_blocks.R` | `SimLevDcaPlan.format` | `_sim_blocks.py` | `show(SimLevDcaPlan)` | `sim_blocks.jl` |
| `print.SimLevFundsCosts` | `sim_blocks.R` | `SimLevFundsCosts.format` | `_sim_blocks.py` | `show(SimLevFundsCosts)` | `sim_blocks.jl` |
| `print.SimLevHarvestRule` | `sim_blocks.R` | `SimLevHarvestRule.format` | `_sim_blocks.py` | `show(SimLevHarvestRule)` | `sim_blocks.jl` |
| `print.SimLevIncomeRate` | `sim_blocks.R` | `SimLevIncomeRate.format` | `_sim_blocks.py` | `show(SimLevIncomeRate)` | `sim_blocks.jl` |
| `print.SimLevIncomeTariff` | `sim_blocks.R` | `SimLevIncomeTariff.format` | `_sim_blocks.py` | `show(SimLevIncomeTariff)` | `sim_blocks.jl` |
| `print.SimLevRebalancePlan` | `sim_blocks.R` | `SimLevRebalancePlan.format` | `_sim_blocks.py` | `show(SimLevRebalancePlan)` | `sim_blocks.jl` |
| `print.SimLevSimCosts` | `sim_blocks.R` | `SimLevSimCosts.format` | `_sim_blocks.py` | `show(SimLevSimCosts)` | `sim_blocks.jl` |
| `print.SimLevSplitRule` | `sim_blocks.R` | `SimLevSplitRule.format` | `_sim_blocks.py` | `show(SimLevSplitRule)` | `sim_blocks.jl` |
| `print.SimLevTaxProfile` | `sim_blocks.R` | `SimLevTaxProfile.format` | `_sim_blocks.py` | `show(SimLevTaxProfile)` | `sim_blocks.jl` |
| `print.SimLevResult` | `simulation.R` | `SimLevResult.print` | `result.py` | `show(SimLevResult)` | `result.jl` |
| `print.summary.SimLevResult` | `simulation.R` | `SimLevSummary.print` | `result.py` | `show(summary.SimLevResult)` | `result.jl` |
| `summary.SimLevResult` | `simulation.R` | `SimLevResult.summary` | `result.py` | `r_summary(SimLevResult)` | `result.jl` |
| `print.strategy` | `strategy.R` | `Strategy.print` | `config.py` | `show(strategy)` | `config.jl` |
| `summary.strategy` | `strategy.R` | `Strategy.summary` | `config.py` | `r_summary(strategy)` | `config.jl` |
| `plot.SimLevWeights` | `tactical.R` | `SimLevWeights.plot` | `tactical.py` | `r_plot(SimLevWeights)` | `tactical.jl` |
| `print.SimLevWeights` | `tactical.R` | `SimLevWeights.format` | `tactical.py` | `show(SimLevWeights)` | `tactical.jl` |
| `print.SimLevTaxTariff` | `tax_tariff.R` | `SimLevTaxTariff.print` | `_tax_tariff.py` | `show(SimLevTaxTariff)` | `tax_tariff.jl` |
| `plot.SimLevWithdrawal` | `withdrawal.R` | `SimLevWithdrawal.plot` | `withdrawal.py` | `r_plot(SimLevWithdrawal)` | `withdrawal.jl` |
| `print.SimLevHorizon` | `withdrawal.R` | `SimLevHorizon.format` | `withdrawal.py` | `show(SimLevHorizon)` | `withdrawal.jl` |
| `print.SimLevWithdrawal` | `withdrawal.R` | `SimLevWithdrawal.print` | `withdrawal.py` | `show(SimLevWithdrawal)` | `withdrawal.jl` |
| `print.summary.SimLevWithdrawal` | `withdrawal.R` | `SummarySimLevWithdrawal.format` | `withdrawal.py` | `show(summary.SimLevWithdrawal)` | `withdrawal.jl` |
| `print.withdrawal_rule` | `withdrawal.R` | `WithdrawalRule.format` | `withdrawal.py` | `show(withdrawal_rule)` | `withdrawal.jl` |
| `summary.SimLevWithdrawal` | `withdrawal.R` | `SimLevWithdrawal.summary` | `withdrawal.py` | `r_summary(SimLevWithdrawal)` | `withdrawal.jl` |
| `[.SimLevWrapperNav` | `wrapper.R` | – | – | – | – |
| `print.SimLevWrapperConfig` | `wrapper.R` | `SimLevWrapperConfig.print` | `wrapper.py` | `show(SimLevWrapperConfig)` | `wrapper.jl` |
| `print.SimLevWrapperNav` | `wrapper.R` | `SimLevWrapperNav.format` | `wrapper.py` | `show(SimLevWrapperNav)` | `wrapper.jl` |
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
