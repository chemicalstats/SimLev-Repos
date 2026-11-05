# SimLev – Literatur

SimLev setzt die folgenden Verfahren selbst um. Zu jedem Eintrag steht, in
welcher Funktion SimLev das Verfahren nutzt. Alle Angaben sind geprüft:
beim Verlag, über Crossref bzw. die DOI-Auflösung, bei arXiv, auf den
Seiten der Autoren oder in Bibliothekskatalogen. Wo eine Quelle keinen DOI
hat, fehlt er auch hier.

## Bootstrap und Resampling

- Efron, B. (1979). Bootstrap methods: Another look at the jackknife.
  *The Annals of Statistics* 7(1), 1–26.
  [doi:10.1214/aos/1176344552](https://doi.org/10.1214/aos/1176344552)
  – `bootstrap()`, Verfahren `"raw"` (Ziehen einzelner Zeilen mit
  Zurücklegen).
- Künsch, H. R. (1989). The jackknife and the bootstrap for general
  stationary observations. *The Annals of Statistics* 17(3), 1217–1241.
  [doi:10.1214/aos/1176347265](https://doi.org/10.1214/aos/1176347265)
  – Verfahren `"block"` (Blöcke fester Länge).
- Politis, D. N., Romano, J. P. (1992). A circular block-resampling
  procedure for stationary data. In: R. LePage, L. Billard (Hrsg.),
  *Exploring the Limits of Bootstrap*. Wiley, 263–270. – Verfahren
  `"circular"`.
- Politis, D. N., Romano, J. P. (1994). The stationary bootstrap. *Journal
  of the American Statistical Association* 89(428), 1303–1313.
  [doi:10.1080/01621459.1994.10476870](https://doi.org/10.1080/01621459.1994.10476870)
  – Verfahren `"stationary"`, `bootstrap_pooled()`, die
  Block-Bootstraps in `sharpe_test(method = "bootstrap")`,
  `dependence_analysis()` und `tail_regression()`.
- Politis, D. N., White, H. (2004). Automatic block-length selection for
  the dependent bootstrap. *Econometric Reviews* 23(1), 53–70.
  [doi:10.1081/ETC-120028836](https://doi.org/10.1081/ETC-120028836)
  – `bootstrap_block_length()`.
- Patton, A., Politis, D. N., White, H. (2009). Correction to "Automatic
  block-length selection for the dependent bootstrap" by D. Politis and
  H. White. *Econometric Reviews* 28(4), 372–375.
  [doi:10.1080/07474930802459016](https://doi.org/10.1080/07474930802459016)
  – Korrektur in `bootstrap_block_length()`.
- Wu, C. F. J. (1986). Jackknife, bootstrap and other resampling methods
  in regression analysis. *The Annals of Statistics* 14(4), 1261–1295.
  [doi:10.1214/aos/1176350142](https://doi.org/10.1214/aos/1176350142)
  – Verfahren `"wild"`.
- Liu, R. Y. (1988). Bootstrap procedures under some non-i.i.d. models.
  *The Annals of Statistics* 16(4), 1696–1708.
  [doi:10.1214/aos/1176351062](https://doi.org/10.1214/aos/1176351062)
  – `"wild"` mit Rademacher-Gewichten (`wild_type = 0`).
- Mammen, E. (1993). Bootstrap and wild bootstrap for high dimensional
  linear models. *The Annals of Statistics* 21(1), 255–285.
  [doi:10.1214/aos/1176349025](https://doi.org/10.1214/aos/1176349025)
  – `"wild"` mit der Zweipunktverteilung nach Mammen (`wild_type = 1`).
- Barone-Adesi, G., Giannopoulos, K., Vosper, L. (1999). VaR without
  correlations for portfolios of derivative securities. *Journal of Futures
  Markets* 19(5), 583–602.
  [doi:10.1002/(SICI)1096-9934(199908)19:5<583::AID-FUT5>3.0.CO;2-S](https://doi.org/10.1002/%28SICI%291096-9934%28199908%2919:5%3C583::AID-FUT5%3E3.0.CO;2-S)
  – gefilterte historische Simulation in den Verfahren `"garch"` und
  `"gjr_garch"`.
- Anarkulova, A., Cederburg, S., O'Doherty, M. S. (2022). Stocks for the
  long run? Evidence from a broad sample of developed markets. *Journal of
  Financial Economics* 143(1), 409–433.
  [doi:10.1016/j.jfineco.2021.06.040](https://doi.org/10.1016/j.jfineco.2021.06.040)
  – Länder-Bootstrap `bootstrap_pooled()`.
- Hyndman, R. J., Fan, Y. (1996). Sample quantiles in statistical
  packages. *The American Statistician* 50(4), 361–365.
  [doi:10.1080/00031305.1996.10473566](https://doi.org/10.1080/00031305.1996.10473566)
  – Quantile Typ 7: gewichtete Quantile in `summary()` von
  `bootstrap_study()` und `withdrawal_simulation()`, Quartile der
  Bandbreite der Kerndichte, Rangeinteilung der MS-GARCH-Startwerte.
- Akinshin, A. (2023). Weighted quantile estimators. arXiv:2304.07265.
  [arxiv.org/abs/2304.07265](https://arxiv.org/abs/2304.07265) –
  gewichtete Quantile (Typ 7) bei ESS-gewichteten Studien.
- Kish, L. (1965). *Survey Sampling*. John Wiley, New York. – effektive
  Stichprobengröße (Σw)²/Σw² der gewichteten Quantile.

Ohne Literaturquelle, eigene Verfahren von SimLev: die Bootstrap-Verfahren
`"regime"` (Volatilitätsregime als Markov-Kette), `"tails"` (empirische
Ränder) und `"reset"` sowie die ESS-gewichtete Gittersuche über
Hyperparameter.

## Volatilitäts- und Regimemodelle

- Bollerslev, T. (1986). Generalized autoregressive conditional
  heteroskedasticity. *Journal of Econometrics* 31(3), 307–327.
  [doi:10.1016/0304-4076(86)90063-1](https://doi.org/10.1016/0304-4076%2886%2990063-1)
  – GARCH(1,1) per Maximum Likelihood: Verfahren `"garch"`, erste Stufe von
  `dependence_dcc()`, Regime der MS-GARCH-Verfahren.
- Glosten, L. R., Jagannathan, R., Runkle, D. E. (1993). On the relation
  between the expected value and the volatility of the nominal excess
  return on stocks. *The Journal of Finance* 48(5), 1779–1801.
  [doi:10.1111/j.1540-6261.1993.tb05128.x](https://doi.org/10.1111/j.1540-6261.1993.tb05128.x)
  – GJR-GARCH(1,1): Verfahren `"gjr_garch"`, Varianzmodell `"gjrGARCH"`
  der MS-GARCH-Verfahren.
- Engle, R. F., Lilien, D. M., Robins, R. P. (1987). Estimating time
  varying risk premia in the term structure: The ARCH-M model.
  *Econometrica* 55(2), 391–407.
  [doi:10.2307/1913242](https://doi.org/10.2307/1913242) –
  GARCH-in-Mean-Term im Verfahren `"ms_ar_garch_m"`.
- Haas, M., Mittnik, S., Paolella, M. S. (2004). A new approach to
  Markov-switching GARCH models. *Journal of Financial Econometrics* 2(4),
  493–530. [doi:10.1093/jjfinec/nbh020](https://doi.org/10.1093/jjfinec/nbh020)
  – eigene MS-GARCH-Schätzung der Verfahren `"ms_garch"`,
  `"ms_ar_garch_m"` und `"tvtp_ms_garch"`.
- Hamilton, J. D. (1989). A new approach to the economic analysis of
  nonstationary time series and the business cycle. *Econometrica* 57(2),
  357–384. [doi:10.2307/1912559](https://doi.org/10.2307/1912559) –
  Filter der MS-GARCH-Likelihood, `regime_hmm()`, `regime_states()`.
- Diebold, F. X., Lee, J.-H., Weinbach, G. C. (1994). Regime switching
  with time-varying transition probabilities. In: C. P. Hargreaves (Hrsg.),
  *Nonstationary Time Series Analysis and Cointegration*. Oxford University
  Press, 283–302.
  [doi:10.1093/oso/9780198773917.003.0010](https://doi.org/10.1093/oso/9780198773917.003.0010)
  – Verfahren `"tvtp_ms_garch"` (zeitvariable Übergänge).
- Baum, L. E., Petrie, T., Soules, G., Weiss, N. (1970). A maximization
  technique occurring in the statistical analysis of probabilistic
  functions of Markov chains. *The Annals of Mathematical Statistics*
  41(1), 164–171.
  [doi:10.1214/aoms/1177697196](https://doi.org/10.1214/aoms/1177697196)
  – EM-Schätzung in `regime_hmm()`, Startwerte der MS-GARCH-Schätzung.
- Viterbi, A. J. (1967). Error bounds for convolutional codes and an
  asymptotically optimum decoding algorithm. *IEEE Transactions on
  Information Theory* 13(2), 260–269.
  [doi:10.1109/TIT.1967.1054010](https://doi.org/10.1109/TIT.1967.1054010)
  – wahrscheinlichste Regimefolge in `regime_hmm()` und den
  MS-GARCH-Verfahren.
- Rabiner, L. R. (1989). A tutorial on hidden Markov models and selected
  applications in speech recognition. *Proceedings of the IEEE* 77(2),
  257–286. [doi:10.1109/5.18626](https://doi.org/10.1109/5.18626) –
  skalierte Vorwärts-Rückwärts-Rekursion, Neuschätzung der
  Startverteilung und Viterbi-Pfad in `regime_hmm()`.
- Schwarz, G. (1978). Estimating the dimension of a model. *The Annals of
  Statistics* 6(2), 461–464.
  [doi:10.1214/aos/1176344136](https://doi.org/10.1214/aos/1176344136) –
  BIC in `regime_hmm()`.
- Nystrup, P., Hansen, B. W., Madsen, H., Lindström, E. (2015).
  Regime-based versus static asset allocation: Letting the data speak.
  *The Journal of Portfolio Management* 42(1), 103–109.
  [doi:10.3905/jpm.2015.42.1.103](https://doi.org/10.3905/jpm.2015.42.1.103)
  – Regime-Allokation mit einem Hidden-Markov-Modell als Vorbild für
  `regime_hmm()` und `regime_states()`; dort adaptiv geschätzt, in SimLev
  einmal auf der ganzen Historie (Gauß-HMM ohne autoregressiven Teil, EM
  statt der numerischen Likelihood-Maximierung bei Hamilton 1989).

## Extremwerte

- Pickands, J. (1975). Statistical inference using extreme order
  statistics. *The Annals of Statistics* 3(1), 119–131.
  [doi:10.1214/aos/1176343003](https://doi.org/10.1214/aos/1176343003)
  – verallgemeinerte Pareto-Verteilung (GPD) der Überschreitungen im
  Verfahren `"evt"`.
- Davison, A. C., Smith, R. L. (1990). Models for exceedances over high
  thresholds. *Journal of the Royal Statistical Society, Series B* 52(3),
  393–425.
  [doi:10.1111/j.2517-6161.1990.tb01796.x](https://doi.org/10.1111/j.2517-6161.1990.tb01796.x)
  – GPD-Schätzung per Maximum Likelihood in `"evt"`.
- Hosking, J. R. M., Wallis, J. R. (1987). Parameter and quantile
  estimation for the generalized Pareto distribution. *Technometrics*
  29(3), 339–349.
  [doi:10.1080/00401706.1987.10488243](https://doi.org/10.1080/00401706.1987.10488243)
  – Startwerte der GPD-Schätzung (wahrscheinlichkeitsgewichtete Momente).
- McNeil, A. J., Frey, R. (2000). Estimation of tail-related risk measures
  for heteroscedastic financial time series: An extreme value approach.
  *Journal of Empirical Finance* 7(3–4), 271–300.
  [doi:10.1016/S0927-5398(00)00012-8](https://doi.org/10.1016/S0927-5398%2800%2900012-8)
  – GPD-Ränder mit empirischer Mitte im Verfahren `"evt"`.

## Abhängigkeit, Copulas, Regression

- Engle, R. (2002). Dynamic conditional correlation: A simple class of
  multivariate generalized autoregressive conditional heteroskedasticity
  models. *Journal of Business & Economic Statistics* 20(3), 339–350.
  [doi:10.1198/073500102288618487](https://doi.org/10.1198/073500102288618487)
  – `dependence_dcc()`, DCC in `dependence_analysis()`.
- Genest, C., Ghoudi, K., Rivest, L.-P. (1995). A semiparametric
  estimation procedure of dependence parameters in multivariate families
  of distributions. *Biometrika* 82(3), 543–552.
  [doi:10.1093/biomet/82.3.543](https://doi.org/10.1093/biomet/82.3.543)
  – Pseudo-Maximum-Likelihood auf Rängen in `copula_fit()`.
- Joe, H. (2014). *Dependence Modeling with Copulas*. Chapman & Hall/CRC,
  Boca Raton (Monographs on Statistics and Applied Probability 134). –
  Copula-Familien und implizite Tail-Abhängigkeit in `copula_fit()`.
- Longin, F., Solnik, B. (2001). Extreme correlation of international
  equity markets. *The Journal of Finance* 56(2), 649–676.
  [doi:10.1111/0022-1082.00340](https://doi.org/10.1111/0022-1082.00340)
  – Exceedance-Korrelationen in `tail_dependence()`.
- Knight, W. R. (1966). A computer method for calculating Kendall's tau
  with ungrouped data. *Journal of the American Statistical Association*
  61(314), 436–439.
  [doi:10.1080/01621459.1966.10480879](https://doi.org/10.1080/01621459.1966.10480879)
  – Kendalls τ in O(n log n) (`tail_dependence()`, `copula_fit()`,
  `dependence_analysis()`, `scenario_copula()`).
- Koenker, R., Bassett, G. (1978). Regression quantiles. *Econometrica*
  46(1), 33–50. [doi:10.2307/1913643](https://doi.org/10.2307/1913643) –
  `quantile_regression()`, `tail_regression()`, `tail_covar()`.
- Hunter, D. R., Lange, K. (2000). Quantile regression via an MM
  algorithm. *Journal of Computational and Graphical Statistics* 9(1),
  60–77.
  [doi:10.1080/10618600.2000.10474866](https://doi.org/10.1080/10618600.2000.10474866)
  – Lösungsverfahren in `quantile_regression()`.
- Barrodale, I., Roberts, F. D. K. (1974). Algorithm 478: Solution of an
  overdetermined system of equations in the l1 norm. *Communications of the
  ACM* 17(6), 319–320.
  [doi:10.1145/355616.361024](https://doi.org/10.1145/355616.361024) –
  Nachschärfen der Lösung auf eine Ecke in `quantile_regression()` (nach
  dem Verfahren, ohne Code des Algorithmus).
- Adrian, T., Brunnermeier, M. K. (2016). CoVaR. *American Economic
  Review* 106(7), 1705–1741.
  [doi:10.1257/aer.20120555](https://doi.org/10.1257/aer.20120555) –
  `tail_covar()`.

## Portfolio, Szenarien, Risiko

- Ledoit, O., Wolf, M. (2004). A well-conditioned estimator for
  large-dimensional covariance matrices. *Journal of Multivariate Analysis*
  88(2), 365–411.
  [doi:10.1016/S0047-259X(03)00096-4](https://doi.org/10.1016/S0047-259X%2803%2900096-4)
  – `portfolio_optimize(cov = "ledoit_wolf")`.
- Laloux, L., Cizeau, P., Bouchaud, J.-P., Potters, M. (1999). Noise
  dressing of financial correlation matrices. *Physical Review Letters*
  83(7), 1467–1470.
  [doi:10.1103/PhysRevLett.83.1467](https://doi.org/10.1103/PhysRevLett.83.1467)
  – Rauschfilter `cov = "denoise"`.
- López de Prado, M. (2020). *Machine Learning for Asset Managers*.
  Cambridge University Press (Elements in Quantitative Finance).
  [doi:10.1017/9781108883658](https://doi.org/10.1017/9781108883658) –
  `cov = "denoise"`.
- Gerber, S., Markowitz, H. M., Ernst, P. A., Miao, Y., Javid, B.,
  Sargen, P. (2022). The Gerber statistic: A robust co-movement measure for
  portfolio optimization. *The Journal of Portfolio Management* 48(3),
  87–102. [doi:10.3905/jpm.2021.1.316](https://doi.org/10.3905/jpm.2021.1.316)
  – `cov = "gerber"`.
- Choueifaty, Y., Coignard, Y. (2008). Toward maximum diversification.
  *The Journal of Portfolio Management* 35(1), 40–51.
  [doi:10.3905/jpm.2008.35.1.40](https://doi.org/10.3905/jpm.2008.35.1.40)
  – `method = "max_diversification"`.
- Spinu, F. (2013). An algorithm for computing risk parity weights. SSRN
  2297383. [doi:10.2139/ssrn.2297383](https://doi.org/10.2139/ssrn.2297383)
  – `method = "risk_parity"` mit Risikobudgets.
- López de Prado, M. (2016). Building diversified portfolios that
  outperform out of sample. *The Journal of Portfolio Management* 42(4),
  59–69. [doi:10.3905/jpm.2016.42.4.059](https://doi.org/10.3905/jpm.2016.42.4.059)
  – `method = "hrp"`.
- Rockafellar, R. T., Uryasev, S. (2000). Optimization of conditional
  value-at-risk. *Journal of Risk* 2(3), 21–41.
  [doi:10.21314/JOR.2000.038](https://doi.org/10.21314/JOR.2000.038) –
  `method = "min_cvar"`.
- Rockafellar, R. T., Uryasev, S. (2002). Conditional value-at-risk for
  general loss distributions. *Journal of Banking & Finance* 26(7),
  1443–1471.
  [doi:10.1016/S0378-4266(02)00271-6](https://doi.org/10.1016/S0378-4266%2802%2900271-6)
  – CVaR mit anteiligem Grenzszenario in `scenario_risk()`.
- Chekhlov, A., Uryasev, S., Zabarankin, M. (2005). Drawdown measure in
  portfolio optimization. *International Journal of Theoretical and Applied
  Finance* 8(1), 13–58.
  [doi:10.1142/S0219024905002767](https://doi.org/10.1142/S0219024905002767)
  – `method = "min_cdar"`.
- Michaud, R. O. (1998). *Efficient Asset Management: A Practical Guide to
  Stock Portfolio Optimization and Asset Allocation*. Harvard Business
  School Press, Boston. – Resampling `portfolio_optimize(resample = …)`.
- Meucci, A. (2008). Fully flexible views: Theory and practice. *Risk*
  21(10), 97–102. – `scenario_entropy_pooling()`.

## Überanpassung und Tests

- Bailey, D. H., Borwein, J., López de Prado, M., Zhu, Q. J. (2017). The
  probability of backtest overfitting. *Journal of Computational Finance*
  20(4), 39–69.
  [doi:10.21314/JCF.2016.322](https://doi.org/10.21314/JCF.2016.322) –
  `overfit_pbo()`.
- Bailey, D. H., López de Prado, M. (2012). The Sharpe ratio efficient
  frontier. *Journal of Risk* 15(2), 3–44.
  [doi:10.21314/JOR.2012.255](https://doi.org/10.21314/JOR.2012.255) –
  `sharpe_probabilistic()`, `sharpe_min_track_record()`.
- Bailey, D. H., López de Prado, M. (2014). The deflated Sharpe ratio:
  Correcting for selection bias, backtest overfitting, and non-normality.
  *The Journal of Portfolio Management* 40(5), 94–107.
  [doi:10.3905/jpm.2014.40.5.094](https://doi.org/10.3905/jpm.2014.40.5.094)
  – `sharpe_deflated()`.
- Harvey, C. R., Liu, Y. (2015). Backtesting. *The Journal of Portfolio
  Management* 42(1), 13–28.
  [doi:10.3905/jpm.2015.42.1.013](https://doi.org/10.3905/jpm.2015.42.1.013)
  – `sharpe_haircut()`.
- Holm, S. (1979). A simple sequentially rejective multiple test
  procedure. *Scandinavian Journal of Statistics* 6(2), 65–70. –
  Korrektur `holm` in `sharpe_haircut()`.
- Benjamini, Y., Yekutieli, D. (2001). The control of the false discovery
  rate in multiple testing under dependency. *The Annals of Statistics*
  29(4), 1165–1188.
  [doi:10.1214/aos/1013699998](https://doi.org/10.1214/aos/1013699998) –
  Korrektur `bhy` in `sharpe_haircut()`.
- White, H. (2000). A reality check for data snooping. *Econometrica*
  68(5), 1097–1126.
  [doi:10.1111/1468-0262.00152](https://doi.org/10.1111/1468-0262.00152)
  – `overfit_reality_check()`.
- Hansen, P. R. (2005). A test for superior predictive ability. *Journal
  of Business & Economic Statistics* 23(4), 365–380.
  [doi:10.1198/073500105000000063](https://doi.org/10.1198/073500105000000063)
  – SPA-Test in `overfit_reality_check()`.
- Ledoit, O., Wolf, M. (2008). Robust performance hypothesis testing with
  the Sharpe ratio. *Journal of Empirical Finance* 15(5), 850–859.
  [doi:10.1016/j.jempfin.2008.03.002](https://doi.org/10.1016/j.jempfin.2008.03.002)
  – `sharpe_test()`.
- Newey, W. K., West, K. D. (1987). A simple, positive semi-definite,
  heteroskedasticity and autocorrelation consistent covariance matrix.
  *Econometrica* 55(3), 703–708. – Kovarianz in
  `sharpe_test(method = "hac")`.
- Welch, B. L. (1947). The generalization of "Student's" problem when
  several different population variances are involved. *Biometrika*
  34(1–2), 28–35.
  [doi:10.1093/biomet/34.1-2.28](https://doi.org/10.1093/biomet/34.1-2.28)
  – Welch-Test in `signal_analysis()`.
- Satterthwaite, F. E. (1946). An approximate distribution of estimates
  of variance components. *Biometrics Bulletin* 2(6), 110–114.
  [doi:10.2307/3002019](https://doi.org/10.2307/3002019) – Freiheitsgrade
  des Welch-Tests in `signal_analysis()`.
- López de Prado, M. (2018). *Advances in Financial Machine Learning*.
  John Wiley & Sons, Kap. 7 und 12. – `portfolio_cpcv()`.

## Entnahme, Planung, Taktik, Anleihen, Backcast

- Bengen, W. P. (1994). Determining withdrawal rates using historical
  data. *Journal of Financial Planning* 7(4), 171–180. –
  `withdrawal_rule("constant")`.
- Cooley, P. L., Hubbard, C. M., Walz, D. T. (1998). Retirement savings:
  Choosing a withdrawal rate that is sustainable. *AAII Journal* 20(2),
  16–21. – `withdrawal_rule("constant")` (Trinity-Studie).
- Bengen, W. P. (2001). Conserving client portfolios during retirement,
  part IV. *Journal of Financial Planning*, Mai 2001. –
  `withdrawal_rule("floor_ceiling")`.
- Guyton, J. T., Klinger, W. J. (2006). Decision rules and maximum initial
  withdrawal rates. *Journal of Financial Planning* 19(3), 49–59. –
  `withdrawal_rule("guyton_klinger")`.
- Daga, A., Clarke, A. S., Pakula, D., Bupp, J. (2021). *Sustainable
  spending rates in turbulent markets*. Vanguard Research Note, März 2021. –
  `withdrawal_rule("vanguard")`.
- Bogleheads Wiki: Variable percentage withdrawal.
  [bogleheads.org/wiki/Variable_percentage_withdrawal](https://www.bogleheads.org/wiki/Variable_percentage_withdrawal)
  – `withdrawal_rule("vpw")`.
- Kitces, M. (2015). The ratcheting safe withdrawal rate – a more dominant
  version of the 4% rule? *Nerd's Eye View*, kitces.com, 3. Juni 2015.
  [kitces.com](https://www.kitces.com/blog/the-ratcheting-safe-withdrawal-rate-a-more-dominant-version-of-the-4-rule/)
  – `withdrawal_rule("ratchet")`.
- Clyatt, B. (2005). *Work Less, Live More: The New Way to Retire Early*.
  Nolo, Berkeley. – `withdrawal_rule("clyatt")` (95-%-Regel: Rate × Depot,
  mindestens 95 % der Vorjahresentnahme, nominal).
- Swensen, D. F. (2009). *Pioneering Portfolio Management: An
  Unconventional Approach to Institutional Investment*, Fully Revised and
  Updated. Free Press, Kap. 3. – Yale-Regel als Vorbild für
  `withdrawal_rule("endowment")`; abweichend nimmt SimLev das Depot zu
  Beginn des Planjahres statt des Werts zum Ende des vorigen
  Geschäftsjahres und inflationiert nur die Vorjahresentnahme.
- Tobin, J. (1974). What is permanent endowment income? *American
  Economic Review* 64(2), 427–432.
  [ideas.repec.org](https://ideas.repec.org/a/aea/aecrev/v64y1974i2p427-32.html)
  – von Swensen (2009) zitierte Grundlage der Yale-Regel,
  `withdrawal_rule("endowment")`.
- Bogleheads Wiki: Withdrawal methods, Abschnitt 1/N.
  [bogleheads.org/wiki/Withdrawal_methods](https://www.bogleheads.org/wiki/Withdrawal_methods)
  – `withdrawal_rule("one_over_n")`.
- Waring, M. B., Siegel, L. B. (2015). The only spending rule article you
  will ever need. *Financial Analysts Journal* 71(1), 91–107.
  [doi:10.2469/faj.v71.n1.2](https://doi.org/10.2469/faj.v71.n1.2) –
  jährlich neu berechnete virtuelle Annuität als Vorbild für
  `withdrawal_rule("abw")`; abweichend mit fester erwarteter Realrendite
  statt aktueller Marktzinsen und mit optionalem Zielvermögen.
- Jeske, K. (2017). The ultimate guide to safe withdrawal rates – Part 18:
  Flexibility and the mechanics of CAPE-based rules. *Early Retirement
  Now*, earlyretirementnow.com, 30. August 2017.
  [earlyretirementnow.com](https://earlyretirementnow.com/2017/08/30/the-ultimate-guide-to-safe-withdrawal-rates-part-18-flexibility-cape-based-rules/)
  – `withdrawal_rule("cape")` (Rate = a + b / CAPE, Standard 1,75 % und
  0,5; dort monatlich, in SimLev jährlich).
- Ponzo, P. (o. J.). Sensible withdrawals. *Gummy-stuff*.
  [financialwisdomforum.org](https://www.financialwisdomforum.org/gummy-stuff/sensible_withdrawals.htm)
  – Vorbild für `withdrawal_rule("sensible")`; Bemessung von Grundentnahme
  und Zuwachs in SimLev eigene Festlegung.
- Hebeler, H. K. (2001). *J.K. Lasser's Your Winning Retirement Plan*.
  Wiley. – Retirement Autopilot als Vorbild für
  `withdrawal_rule("hebeler")`.
- Steiner, K. (2015). Bud Hebeler's Autopilot withdrawal rule. *How much
  can I afford to spend in retirement?* (Blog), 22. Januar 2015.
  [howmuchcaniaffordtospendinretirement.blogspot.com](https://howmuchcaniaffordtospendinretirement.blogspot.com/2015/01/bud-hebelers-autopilot-withdrawal-rule.html)
  – Gewichtung 75 % inflationierte Vorjahresentnahme und 25 % Annuität in
  `withdrawal_rule("hebeler")`; abweichend rechnet SimLev die Annuität
  über die Restjahre statt über die Lebenserwartung.
- Suarez, E. D., Suarez, A., Walz, D. T. (2015). The perfect withdrawal
  amount: A methodology for creating retirement account distribution
  strategies. *Financial Services Review* 24(4), 331–357. –
  `withdrawal_perfect_rate()`.
- Das, S. R., Ostrov, D., Radhakrishnan, A., Srivastav, D. (2020). Dynamic
  portfolio allocation in goals-based wealth management. *Computational
  Management Science* 17(4), 613–640.
  [doi:10.1007/s10287-019-00351-7](https://doi.org/10.1007/s10287-019-00351-7)
  – `planning_goal()`.
- Antonacci, G. (2014). *Dual Momentum Investing: An Innovative Strategy
  for Higher Returns with Lower Risk*. McGraw-Hill. – Dual Momentum in
  `tactical_rotation()`.
- Keller, W. J., Keuning, J. W. (2018). Breadth momentum and the canary
  universe: Defensive asset allocation (DAA). SSRN 3212862.
  [doi:10.2139/ssrn.3212862](https://doi.org/10.2139/ssrn.3212862) –
  Canary-Schutz und Gewichtung `"13612w"` in `tactical_rotation()`.
- Moreira, A., Muir, T. (2017). Volatility-managed portfolios. *The
  Journal of Finance* 72(4), 1611–1644.
  [doi:10.1111/jofi.12513](https://doi.org/10.1111/jofi.12513) –
  `tactical_target_volatility()`.
- Bongaerts, D., Kang, X., van Dijk, M. (2020). Conditional volatility
  targeting. *Financial Analysts Journal* 76(4), 54–71.
  [doi:10.1080/0015198X.2020.1790853](https://doi.org/10.1080/0015198X.2020.1790853)
  – `tactical_conditional_volatility()`.
- Swinkels, L. (2019). Treasury bond return data starting in 1962. *Data*
  4(3), 91. [doi:10.3390/data4030091](https://doi.org/10.3390/data4030091)
  – `index_bond()`.
- MSCI (2021). *MSCI Short and Leveraged Daily Indexes Methodology*,
  August 2021.
  [msci.com](https://www.msci.com/eqb/methodology/meth_docs/MSCI_Short_and_Leveraged_Daily_Indexes_Methodology_Aug2021.pdf)
  – Hebelformel im Strukturmodell von `backcast_fit()`, in
  `series_leverage()` und für die Hebelprodukte in `bootstrap_config()`.
- Stambaugh, R. F. (1997). Analyzing investments whose histories differ in
  length. *Journal of Financial Economics* 45(3), 285–331.
  [doi:10.1016/S0304-405X(97)00020-2](https://doi.org/10.1016/S0304-405X%2897%2900020-2)
  – Regressions-Rückrechnung `backcast_fit(model = "linear")`.

## Numerische Grundlagen der eigenen Kerne

Die C-Bibliothek in [`core/`](core/) ist nach diesen Quellen geschrieben;
der Kopf jeder Datei nennt, welche Abschnitte sie nutzt.

**Zufall** (`simlev_seed()` und alle zufälligen Funktionen):

- Blackman, D., Vigna, S. (2021). Scrambled linear pseudorandom number
  generators. *ACM Transactions on Mathematical Software* 47(4), Art. 36.
  [doi:10.1145/3460772](https://doi.org/10.1145/3460772); frei als
  [arXiv:1805.01407](https://arxiv.org/abs/1805.01407) – Generator
  xoshiro256** und Sprünge um 2^128 für unabhängige Ströme.
- Steele, G. L., Lea, D., Flood, C. H. (2014). Fast splittable
  pseudorandom number generators. In: *Proceedings of the 2014 ACM
  International Conference on Object Oriented Programming Systems Languages
  & Applications (OOPSLA)*, 453–472.
  [doi:10.1145/2660193.2660195](https://doi.org/10.1145/2660193.2660195)
  – SplitMix64 zum Setzen des Zustands.
- Stafford, D. (2011). Better bit mixing – improving on MurmurHash3's
  64-bit finalizer. Blog, September 2011.
  [zimbry.blogspot.com](https://zimbry.blogspot.com/2011/09/better-bit-mixing-improving-on.html)
  – Mischfunktion von SplitMix64 (Variante 13).
- Lemire, D. (2019). Fast random integer generation in an interval. *ACM
  Transactions on Modeling and Computer Simulation* 29(1), 1–12.
  [doi:10.1145/3230636](https://doi.org/10.1145/3230636); frei als
  [arXiv:1805.10941](https://arxiv.org/abs/1805.10941) – ganze Zahlen in
  [0, n) für Stichproben und Bootstrap-Indizes.
- Knuth, D. E. (1997). *The Art of Computer Programming*, Bd. 2:
  *Seminumerical Algorithms*, 3. Aufl. Addison-Wesley, §3.4.2. – Stichproben
  ohne Zurücklegen (Fisher-Yates).
- Devroye, L. (1986). *Non-Uniform Random Variate Generation*.
  Springer, New York; frei auf der
  [Seite des Autors](https://luc.devroye.org/rnbookindex.html) –
  Inversion, diskrete Verteilungen, geometrische und Chi-Quadrat-Ziehungen.
- Marsaglia, G., Tsang, W. W. (2000). A simple method for generating gamma
  variables. *ACM Transactions on Mathematical Software* 26(3), 363–372.
  [doi:10.1145/358407.358414](https://doi.org/10.1145/358407.358414) –
  Gamma- und Chi-Quadrat-Ziehungen (`scenario_copula()`).

**Verteilungen** (Normal-, t-, Beta-, logistische Verteilung, `lgamma`):

- Olver, F. W. J., Olde Daalhuis, A. B., Lozier, D. W., Schneider, B. I.,
  Boisvert, R. F., Clark, C. W., Miller, B. R., Saunders, B. V., Cohl,
  H. S., McClain, M. A. (Hrsg.). *NIST Digital Library of Mathematical
  Functions*. [dlmf.nist.gov](https://dlmf.nist.gov/) – Reihen,
  Kettenbrüche und Asymptotik (Kap. 3, 4, 5, 7, 8, 24; Gleichungsnummern in
  den Dateiköpfen).
- Abramowitz, M., Stegun, I. A. (Hrsg.) (1964). *Handbook of Mathematical
  Functions with Formulas, Graphs, and Mathematical Tables*. National Bureau
  of Standards, Washington, DC (Applied Mathematics Series 55),
  Gl. 26.5.27, 26.7.1, 26.7.5. – t-Verteilung.
- Lentz, W. J. (1976). Generating Bessel functions in Mie scattering
  calculations using continued fractions. *Applied Optics* 15(3), 668–671.
  [doi:10.1364/AO.15.000668](https://doi.org/10.1364/AO.15.000668) –
  Auswertung der Kettenbrüche.
- Thompson, I. J., Barnett, A. R. (1986). Coulomb and Bessel functions of
  complex arguments and order. *Journal of Computational Physics* 64(2),
  490–509.
  [doi:10.1016/0021-9991(86)90046-X](https://doi.org/10.1016/0021-9991%2886%2990046-X)
  – modifiziertes Lentz-Verfahren.
- Dekker, T. J. (1971). A floating-point technique for extending the
  available precision. *Numerische Mathematik* 18(3), 224–242.
  [doi:10.1007/BF01397083](https://doi.org/10.1007/BF01397083) – exakte
  Produkte (Teilung nach Veltkamp).
- Householder, A. S. (1970). *The Numerical Treatment of a Single
  Nonlinear Equation*. McGraw-Hill, New York. – Halley-Schritte der
  Quantilfunktionen.

**Lineare Algebra und kleinste Quadrate** (Cholesky, Löser, Eigenwerte,
QR, Logit-IRLS, Matrixprodukt):

- Golub, G. H., Van Loan, C. F. (2013). *Matrix Computations*, 4. Aufl.
  Johns Hopkins University Press, Baltimore.
- Jacobi, C. G. J. (1846). Über ein leichtes Verfahren, die in der Theorie
  der Säcularstörungen vorkommenden Gleichungen numerisch aufzulösen.
  *Journal für die reine und angewandte Mathematik* 30, 51–94.
  [doi:10.1515/crll.1846.30.51](https://doi.org/10.1515/crll.1846.30.51)
  – Eigenwerte symmetrischer Matrizen (bis 1.6.1; heute nur die kleinen
  Zerlegungen der GARCH-Kerne).
- Demmel, J., Veselić, K. (1992). Jacobi's method is more accurate than
  QR. *SIAM Journal on Matrix Analysis and Applications* 13(4), 1204–1245.
  [doi:10.1137/0613074](https://doi.org/10.1137/0613074) – Grenzen der
  Wahl (bis 1.6.1 Jacobi-Verfahren; seit 1.6.2 Householder + QL).
- Bowdler, H., Martin, R. S., Reinsch, C., Wilkinson, J. H. (1968). The QR
  and QL algorithms for symmetric matrices. *Numerische Mathematik* 11,
  293–306; auch in Wilkinson, J. H., Reinsch, C. (1971). *Handbook for
  Automatic Computation II: Linear Algebra*, Springer, Beitrag II/3 –
  implizites QL der symmetrischen Eigenzerlegung (seit 1.6.2).
- Businger, P., Golub, G. H. (1965). Linear least squares solutions by
  Householder transformations. *Numerische Mathematik* 7(3), 269–276.
  [doi:10.1007/BF01436084](https://doi.org/10.1007/BF01436084) – QR mit
  Spaltenpivotisierung.
- Higham, N. J. (2002). *Accuracy and Stability of Numerical Algorithms*,
  2. Aufl. SIAM.
  [doi:10.1137/1.9780898718027](https://doi.org/10.1137/1.9780898718027)
- Neumaier, A. (1974). Rundungsfehleranalyse einiger Verfahren zur
  Summation endlicher Summen. *ZAMM* 54(1), 39–51.
  [doi:10.1002/zamm.19740540106](https://doi.org/10.1002/zamm.19740540106)
  – kompensierte Summen.
- McCullagh, P., Nelder, J. A. (1989). *Generalized Linear Models*,
  2. Aufl. Chapman and Hall, London. – Logit-IRLS in den MS-GARCH-Verfahren
  mit zeitvariablen Übergängen.

**Optimierer** (BFGS, projizierter BFGS, Nelder-Mead, numerischer
Gradient; u. a. in `backcast_fit()`, `copula_fit()`,
`scenario_entropy_pooling()` und den GARCH-, GPD-, DCC- und
MS-GARCH-Schätzungen):

- Nocedal, J., Wright, S. J. (2006). *Numerical Optimization*, 2. Aufl.
  Springer, New York.
  [doi:10.1007/978-0-387-40065-5](https://doi.org/10.1007/978-0-387-40065-5)
- Bertsekas, D. P. (1982). Projected Newton methods for optimization
  problems with simple constraints. *SIAM Journal on Control and
  Optimization* 20(2), 221–246.
  [doi:10.1137/0320018](https://doi.org/10.1137/0320018)
- Kelley, C. T. (1999). *Iterative Methods for Optimization*. SIAM.
  [doi:10.1137/1.9781611970920](https://doi.org/10.1137/1.9781611970920)
- Nelder, J. A., Mead, R. (1965). A simplex method for function
  minimization. *The Computer Journal* 7(4), 308–313.
  [doi:10.1093/comjnl/7.4.308](https://doi.org/10.1093/comjnl/7.4.308)
- Lagarias, J. C., Reeds, J. A., Wright, M. H., Wright, P. E. (1998).
  Convergence properties of the Nelder–Mead simplex method in low
  dimensions. *SIAM Journal on Optimization* 9(1), 112–147.
  [doi:10.1137/S1052623496303470](https://doi.org/10.1137/S1052623496303470)
- Gill, P. E., Murray, W., Wright, M. H. (1981). *Practical Optimization*.
  Academic Press, London. – Schrittweiten des numerischen Gradienten.

**Glättungsspline, Interpolation, Kerndichte** (`backcast_fit()`,
`backcast()`, Dichten in `plot()` von Bootstrap-Studien):

- Stineman, R. W. (1980). A consistently well-behaved method of
  interpolation. *Creative Computing* 6(7), 54–57. – Lücken füllen mit
  `fill = "stine"` bzw. `index_fill = "stine"`.
- Reinsch, C. H. (1967). Smoothing by spline functions. *Numerische
  Mathematik* 10(3), 177–183.
  [doi:10.1007/BF02162161](https://doi.org/10.1007/BF02162161) –
  `backcast_fit(model = "spline")`.
- Green, P. J., Silverman, B. W. (1994). *Nonparametric Regression and
  Generalized Linear Models: A Roughness Penalty Approach*. Chapman & Hall
  (Monographs on Statistics and Applied Probability 58).
- Craven, P., Wahba, G. (1979). Smoothing noisy data with spline
  functions: Estimating the correct degree of smoothing by the method of
  generalized cross-validation. *Numerische Mathematik* 31(4), 377–403.
  [doi:10.1007/BF01404567](https://doi.org/10.1007/BF01404567) – Wahl der
  Glättung (GCV).
- Hutchinson, M. F., de Hoog, F. R. (1985). Smoothing noisy data with
  spline functions. *Numerische Mathematik* 47(1), 99–106.
  [doi:10.1007/BF01389878](https://doi.org/10.1007/BF01389878) – Spur der
  Glättungsmatrix.
- Kiefer, J. (1953). Sequential minimax search for a maximum. *Proceedings
  of the American Mathematical Society* 4(3), 502–506.
  [doi:10.1090/S0002-9939-1953-0055639-3](https://doi.org/10.1090/S0002-9939-1953-0055639-3)
  – Goldener Schnitt bei der Suche des Glättungsparameters.
- Knuth, D. E. (1998). *The Art of Computer Programming*, Bd. 3: *Sorting
  and Searching*, 2. Aufl. Addison-Wesley, §5.2.4. – Sortieren der Knoten.
- Silverman, B. W. (1986). *Density Estimation for Statistics and Data
  Analysis*. Chapman & Hall, London (Monographs on Statistics and Applied
  Probability 26). – Gauß-Kerndichte und Bandbreite.
- Scott, D. W. (1992). *Multivariate Density Estimation: Theory, Practice,
  and Visualization*. John Wiley & Sons, New York. – Gauß-Kern.
- Wand, M. P., Jones, M. C. (1995). *Kernel Smoothing*. Chapman & Hall,
  London (Monographs on Statistics and Applied Probability 60). –
  lineares Binning bei großen Stichproben.
- Hinnant, H. (o. J.). chrono-Compatible Low-Level Date Algorithms.
  Webseite, gemeinfrei („Consider these donated to the public domain.“).
  [howardhinnant.github.io](https://howardhinnant.github.io/date_algorithms.html)
  – Umrechnung Tage ↔ Kalenderdatum (`days_from_civil`, `civil_from_days`)
  in den Engine-Kernen, `slc_rbase_date.cpp` und den Ports; siehe COPYRIGHTS.
- Brent, R. P. (1973). *Algorithms for Minimization without Derivatives*.
  Prentice-Hall. – Verfahren von `optimize` (Netlib `fmin`), das Python und Julia
  aus R nachbilden, und von `zeroin` (XIRR im Kern, `sl_r_zeroin2`); siehe COPYRIGHTS.
- Singleton, R. C. (1969). Algorithm 347: An efficient algorithm for sorting
  with minimal storage. *Communications of the ACM* 12(3), 185–186.
  [doi:10.1145/362875.362901](https://doi.org/10.1145/362875.362901) –
  Quicksort in `qsort-body.c` von R, übersetzt in `slc_rbase_sort.cpp`;
  siehe COPYRIGHTS.
- Hoare, C. A. R. (1961). Algorithm 63: Partition; Algorithm 64:
  Quicksort; Algorithm 65: Find. *Communications of the ACM* 4(7),
  321–322. – Auswahl für die partielle Sortierung in `slc_rbase_sort.cpp`.

## Pakete als Vorbild bzw. Prüforakel

**SimLev enthält keinen Code aus diesen Paketen.** In den Versionen 0.5.1
bis 0.10.0 waren Teile von evd, imputeTS, stinepack, rugarch, Rsolnp und
truncnorm ins R-Paket übernommen und in Python und Julia nachgebildet; seit
Version 1.0.0 rechnet SimLev diese Aufgaben mit eigenen Kernen (siehe [`r/NEWS.md`](r/NEWS.md)).
Die Pakete dienten bei der Entwicklung nur als Vorbild für das Verhalten
und als Prüforakel (Vergleich von Ein- und Ausgaben); keines ist eine
Abhängigkeit. Angaben aus den DESCRIPTION-Dateien der genannten Fassungen:

| Paket | Fassung | Autorinnen und Autoren | Lizenz | Rolle |
|---|---|---|---|---|
| evd | 2.3-7.1 (2024-09-21) | Alec Stephenson; Funktion `fbvpot` von Chris Ferro | GPL-3 | Prüforakel der GPD-Schätzung (`fpot`) |
| imputeTS | 3.4 (2025-08-25) | Steffen Moritz, Sebastian Gatscha, Earo Wang, Ron Hause | GPL-3 | Vorbild und Prüforakel der Stineman-Interpolation (`na_interpolation`) |
| stinepack | 1.5 (2024-03-07) | Tomas Johannesson, Halldor Bjornsson (Icelandic Met. Office), Gabor Grothendieck | GPL (≥ 2) | Vorbild und Prüforakel der Stineman-Interpolation (`stinterp`) |
| rugarch | 1.5-6 (2026-07-18) | Alexios Galanos, Tobias Kley | GPL-3 | Prüforakel der GARCH- und GJR-Schätzung (`ugarchfit`) |
| MSGARCH | 2.51 (2022-12-05) | David Ardia, Keven Bluteau, Kris Boudt, Leopoldo Catania, Alexios Ghalanos, Brian Peterson, Denis-Alexandre Trottier | GPL (≥ 2) | Prüforakel der MS-GARCH-Schätzung |
| Rsolnp | 1.16 (2015-12-28) | Alexios Ghalanos, Stefan Theussl | GPL | früher über den rugarch-Weg genutzt, heute ohne Rolle |
| truncnorm | 1.0-9 (2023-03-20) | Olaf Mersmann, Heike Trautmann, Detlef Steuer, Björn Bornkamp | GPL (≥ 2) | früher über den rugarch-Weg genutzt, heute ohne Rolle |
| numDeriv | 2016.8-1.1 (2019-06-06) | Paul Gilbert, Ravi Varadhan | GPL-2 | früher Prüforakel der numerischen Ableitungen, heute ohne Rolle |

R selbst: R Core Team (2024). *R: A Language and Environment for
Statistical Computing*. R Foundation for Statistical Computing, Wien.
[www.R-project.org](https://www.R-project.org/) (Fassung 4.3.3). R ist
Prüforakel der eigenen Kerne. Die Python- und die Julia-Fassung bilden
außerdem einige Grundfunktionen von R nach (Sortierung, Quantile,
Formatierung und Druck u. a.), damit sie zeichengleich zu R rechnen und
ausgeben; welche das sind und unter welcher Lizenz, steht in
[`python/COPYRIGHTS.md`](python/COPYRIGHTS.md) und
[`julia/COPYRIGHTS.md`](julia/COPYRIGHTS.md).
