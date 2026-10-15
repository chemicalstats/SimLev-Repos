# Blue Team 3: Statistik, Optimierung, Szenarien (Befunde R3-xx)

.bs_prices <- function(n = 3 * 365, seed = 1, start = "2015-01-01") {
  set.seed(seed)
  d <- data.frame(date = seq.Date(as.Date(start), by = "day", length.out = n))
  d$aktien <- 100 * cumprod(1 + rnorm(n, 3e-4, 0.01)); d$anleihen <- 100 * cumprod(1 + rnorm(n, 1e-4, 0.003))
  d
}
.bs_R <- function() {
  set.seed(1); R <- matrix(rnorm(520 * 3, c(0.002, 0.001, 0.0005), c(0.03, 0.02, 0.01)), 520, byrow = TRUE)
  colnames(R) <- c("aktien", "reits", "anleihen"); R
}

test_that("R3-03 unsortierte Daten werden sortiert (mit Hinweis), Duplikate gemeldet", {
  d <- .bs_prices(5 * 365); ds <- d[sample(nrow(d)), ]; dr <- d[nrow(d):1, ]
  p <- portfolio_optimize(d)
  expect_message(ps <- portfolio_optimize(ds), "nicht nach 'date' sortiert")
  expect_equal(ps$weights, p$weights); expect_equal(ps$n_obs, p$n_obs)
  da <- dependence_analysis(d, c("aktien", "anleihen"), B = 0, dcc = FALSE, copulas = FALSE)
  dar <- suppressMessages(dependence_analysis(dr, c("aktien", "anleihen"), B = 0, dcc = FALSE, copulas = FALSE))
  expect_equal(dar$ppy, da$ppy); expect_equal(dar$correlation$pearson, da$correlation$pearson)
  kr <- data.frame(crisis = "K", start = as.Date("2016-01-01"), end = as.Date("2016-06-30"))
  expect_equal(suppressMessages(crisis_replay(dr, c(aktien = 0.6, anleihen = 0.4), kr)),
               crisis_replay(d, c(aktien = 0.6, anleihen = 0.4), kr))
  expect_error(portfolio_optimize(rbind(d, d[5, ])), "doppelte Daten")
})

test_that("R3-04 cpcv_portfolio: purge = 0 / embargo = 0 entfernen keine Zeilen", {
  set.seed(1); R <- matrix(rnorm(120 * 2, 0.001, 0.02), 120, dimnames = list(NULL, c("a", "b")))
  rec <- new.env(); rec$n <- integer(0)
  suppressMessages(utils::capture.output(trace("portfolio_optimize", bquote(assign("n", c(get("n", envir = .(rec)), nrow(x$R)), envir = .(rec))),
                              where = asNamespace("SimLev"), print = FALSE)))
  on.exit(suppressMessages(utils::capture.output(untrace("portfolio_optimize", where = asNamespace("SimLev")))))
  cnt <- function(p, e) { rec$n <- integer(0)
    invisible(cpcv_portfolio(R, methods = "equal", n_groups = 6, test_groups = 1, purge = p, embargo = e)); rec$n }
  expect_equal(cnt(0, 0), rep(100L, 6))
  expect_equal(cnt(0, 2), c(rep(98L, 5), 100L))
  expect_equal(cnt(2, 2), c(98L, 96L, 96L, 96L, 96L, 98L))
  expect_error(cpcv_portfolio(R, methods = "equal", purge = -1), "purge")
})

test_that("R3-05 scenario_risk: CVaR mit anteiligem Grenzszenario (Rockafellar-Uryasev)", {
  ru <- function(r, q, a) { o <- order(r); r <- r[o]; q <- q[o]; cw <- cumsum(q)
    -sum(pmin(q, pmax(0, a - c(0, cw[-length(cw)]))) * r) / a }
  set.seed(1); X <- data.frame(a = rnorm(30)); ep <- entropy_pooling(X, "a", list())
  for (al in c(0.03, 0.034, 0.05, 0.066))
    expect_equal(unname(scenario_risk(ep, c(a = 1), al)["cvar"]), ru(X$a, rep(1 / 30, 30), al), tolerance = 1e-12)
  X2 <- data.frame(a = c(-10, -1, seq(0, 5, length.out = 98)))
  ep2 <- entropy_pooling(X2, "a", list(view_prob("a == -1", 0.30)))
  sr2 <- scenario_risk(ep2, c(a = 1), 0.05)
  expect_equal(unname(sr2["cvar"]), ru(X2$a, ep2$prob, 0.05), tolerance = 1e-10)
  expect_lt(sr2[["cvar"]], 3)                                   # vorher 10 (nur das schlechteste Szenario)
})

test_that("R3-06 rolling_optimization: Argumentfehler sofort, sonst Warnung und failed_dates", {
  d <- .bs_prices(5 * 365); d$gold <- 100 * cumprod(1 + rnorm(nrow(d), 1e-4, 0.008)); a <- c("aktien", "anleihen", "gold")
  expect_error(rolling_optimization(d, a, method = "min_varianze", window = 2), "unbekanntes Verfahren")
  expect_error(rolling_optimization(d, a, window = 2, upper = 0.2), "nicht erf\u00fcllbar")
  expect_error(rolling_optimization(d, a, window = 2, uper = 0.5), "uper")
  expect_warning(w <- rolling_optimization(d, a, window = 0.5, frequency = "month"), "fehlgeschlagen")
  expect_equal(length(attr(w, "failed_dates")), length(attr(w, "decision_rows")))
  w2 <- rolling_optimization(d, a, window = 2, every = "quarter")
  expect_length(attr(w2, "failed_dates"), 0)
})

test_that("R3-09 walk_forward: keine doppelten Tage, Annualisierung \u00fcber die Testzeit", {
  set.seed(1)
  d <- data.frame(date = seq.Date(as.Date("2010-01-01"), by = "day", length.out = 3000))
  d$A <- 100 * cumprod(1 + rnorm(3000, 3e-4, 0.011))
  st <- create_strategy(A = asset_config("etf", "signal", signal_buy = "buy", signal_sell = "sell"))
  ps <- param_search(d, function(p) list(strategy = st, signal = function(df) signal_sma(df$A, p$n, p$band)),
                     param_space(n = c(50, 100), band = c(0, 2)), burn_in = 250)
  w1 <- walk_forward(ps, train = 3, test = 1, step = 1); w05 <- walk_forward(ps, train = 3, test = 1, step = 0.5)
  expect_false(anyDuplicated(w05$series$date) > 0); expect_false(is.unsorted(w05$series$date))
  expect_equal(w05$series$date, w1$series$date)
  expect_equal(w05$summary[["cagr_average"]], w1$summary[["cagr_average"]], tolerance = 1e-12)
  w2 <- walk_forward(ps, train = 3, test = 1, step = 2); s <- w2$series
  rows <- match(as.numeric(s$date), as.numeric(ps$dates))
  yrs <- sum(as.numeric(ps$dates[rows[-1]] - ps$dates[rows[-1] - 1])) / 365.25
  expect_equal(w2$summary[["cagr_average"]], tail(s$average, 1)^(1 / yrs) - 1, tolerance = 1e-12)
  expect_lt(yrs, as.numeric(diff(range(s$date))) / 365.25 - 1)   # Luecken zaehlen nicht
})

test_that("R3-11 copula_scenarios: Stress-Pruefung und gemeinsame bedingte Ziehung", {
  set.seed(1); z <- matrix(rnorm(3000), ncol = 3) %*% chol(matrix(c(1, .9, .5, .9, 1, .5, .5, .5, 1), 3))
  X <- data.frame(a = z[, 1], b = z[, 2], c = z[, 3])
  expect_error(copula_scenarios(X, c("a", "b", "c"), n = 100, stress = list(c(0, 0.05))), "benannte Liste")
  expect_error(copula_scenarios(X, c("a", "b", "c"), n = 100, stress = list(a = c(0.05, 0))), "0 <= von < bis <= 1")
  expect_error(copula_scenarios(X, c("a", "b", "c"), n = 100, stress = list(a = c(0, 5))), "keine Prozent")
  cs <- copula_scenarios(X, c("a", "b", "c"), n = 20000, family = "gaussian", stress = list(a = c(0, 0.1), b = c(0, 0.1)), seed = 1)
  # Referenz: Verwerfung aus derselben Gauss-Copula
  Rm <- cs$copula$correlation; set.seed(2); U <- pnorm(matrix(rnorm(3e6), ncol = 3) %*% chol(Rm))
  U <- U[U[, 1] <= 0.1 & U[, 2] <= 0.1, ]
  qm <- function(j, u) approx((seq_len(1000) - 0.5) / 1000, sort(X[[j]]), u, rule = 2)$y   # empirische Raender wie im Paket
  expect_equal(cor(cs$scenarios$a, cs$scenarios$b), cor(qm("a", U[, 1]), qm("b", U[, 2])), tolerance = 0.06)
  expect_equal(mean(cs$scenarios$c), mean(qm("c", U[, 3])), tolerance = 0.03)
  expect_gt(cor(cs$scenarios$a, cs$scenarios$b), 0.4)              # vorher ~0 (unabhaengig gezogen)
  expect_true(all(cs$scenarios$a <= quantile(X$a, 0.1) + 1e-12))
})

test_that("R3-12 quantile_reg erreicht das exakte Optimum auch bei extremen tau", {
  obj <- function(b, y, X, tau) { r <- y - X %*% b; sum(r * (tau - (r < 0))) }
  corner <- function(y, X, tau) { cmb <- combn(nrow(X), ncol(X)); best <- Inf
    for (j in seq_len(ncol(cmb))) { A <- X[cmb[, j], , drop = FALSE]; if (abs(det(A)) < 1e-12) next
      best <- min(best, obj(solve(A, y[cmb[, j]]), y, X, tau)) }; best }
  set.seed(1); n <- 120; x <- rnorm(n); y <- 1 + 2 * x + rnorm(n); X1 <- cbind(1, x)
  for (tau in c(1e-4, 1e-6, 1 - 1e-6, 0.95))
    expect_equal(obj(quantile_reg(y, x, tau), y, X1, tau), corner(y, X1, tau), tolerance = 1e-10)
  # Fall aus dem Zufallsscan (n = 500, tau = 0.95, Inflation/Zins)
  set.seed(5)
  for (it in 1:271) {
    n <- sample(c(150, 500, 1500), 1); tau <- sample(c(0.01, 0.05, 0.1, 0.25, 0.5, 0.75, 0.9, 0.95, 0.99), 1)
    infl <- 2 + cumsum(rnorm(n, 0, 0.1)); rate <- 1 + cumsum(rnorm(n, 0, 0.05))
    y <- 0.1 - 0.05 * infl + rt(n, 4) * (1 + 0.2 * abs(infl)); if (runif(1) < 0.5) y <- round(y, 2)
    X <- cbind(infl = infl, rate = rate)[, seq_len(sample(1:2, 1)), drop = FALSE]
  }
  b <- quantile_reg(y, X, tau)
  expect_equal(unname(b), c(2.3992, 0.0487, -0.0679), tolerance = 1e-3)   # quantreg::rq(method = "br")
  expect_equal(sum(abs(y - cbind(1, X) %*% b) < 1e-9), 3L)               # Ecke: 3 Residuen exakt 0
  # entartete Ecken (diskreter Regressor, gerundete Werte, doppelte Zeilen): Nachweis ohne Warnung
  set.seed(7)
  for (it in 1:20) {
    g <- sample(0:2, 30, TRUE); y <- round(g + rnorm(30), 1); idx <- sample(30, 30, TRUE); tau <- c(0.1, 0.5, 0.9)[it %% 3 + 1]
    expect_silent(b <- quantile_reg(y[idx], g[idx], tau))
    expect_equal(obj(b, y[idx], cbind(1, g[idx]), tau), corner(y[idx], cbind(1, g[idx]), tau), tolerance = 1e-10)
  }
})

test_that("R3-13 quantile_reg: klare Fehler bei ung\u00fcltigen Eingaben", {
  set.seed(1); n <- 200; x <- rnorm(n); y <- 1 + 2 * x + rnorm(n)
  expect_error(quantile_reg(y, cbind(x, x2 = 2 * x)), "linear abh\u00e4ngig \\('x2'\\)")
  expect_error(quantile_reg(y, cbind(x, k = 1)), "linear abh\u00e4ngig \\('k'\\)")
  expect_error(quantile_reg(y, data.frame(x = x, g = factor(sample(letters[1:3], n, TRUE)))), "nicht numerisch")
  expect_error(quantile_reg(y, x[1:100]), "100 Zeilen")
  expect_error(quantile_reg(y, x, tau = c(0.1, 0.9)), "tau")
  expect_error(quantile_reg(y, x, tau = NA), "tau")
})

test_that("R3-14 pbo: Lesart nennt den Zufallswert bei ungerader Punktezahl", {
  set.seed(1); R <- matrix(rnorm(400 * 3, 0, 0.01), 400)
  expect_output(print(pbo(R, S = 8, frequency = "day")), "67 % = Zufall \\(ungerade")
  expect_output(print(pbo(cbind(R, R[, 1]), S = 8, frequency = "day")), "50 % = Zufall,")
})

test_that("R3-15 dcc_fit: (fast) perfekt korrelierte Reihen -> klarer Fehler statt Korrelation 0", {
  set.seed(1); x <- rnorm(500, 0, 0.01)
  expect_error(dcc_fit(cbind(a = x, b = x)), "singul\u00e4r")
  expect_error(dcc_fit(cbind(a = x, b = -x + 1e-9 * rnorm(500))), "singul\u00e4r")
  fl <- SimLev:::.dcc_filter(cbind(x, x) / 0.01, 0.03, 0.95, matrix(1, 2, 2), TRUE)
  expect_false(fl$ok); expect_true(all(is.na(fl$R)))                 # keine vorbelegten Nullen
})

test_that("R3-16 tail_regression: singul\u00e4re Bootstrap-Stichproben werden NA und gemeldet", {
  set.seed(1); n <- 3 * 365
  d <- data.frame(date = seq.Date(as.Date("2015-01-01"), by = "day", length.out = n))
  d$zins <- ifelse(seq_len(n) > n - 20, 1, 0); d$aktien <- 100 * cumprod(1 + rnorm(n, 3e-4, 0.01))
  expect_warning(tr <- tail_regression(d, "aktien", "zins", quantiles = c(0.05, 0.5), B = 50, seed = 1), "nicht sch\u00e4tzbar")
  expect_gt(tr$B_failed, 0); expect_lt(tr$B_failed, 50)
  expect_true(all(is.finite(tr$coefficients$se)))
})

test_that("R3-17 efficient_frontier prueft die Grenzen", {
  R <- .bs_R()
  expect_error(efficient_frontier(R, upper = 0.2, n = 5), "nicht erf\u00fcllbar")
  expect_error(efficient_frontier(R, lower = 0.5, n = 5), "nicht erf\u00fcllbar")
  ef <- efficient_frontier(R, upper = 0.5, n = 5)
  expect_equal(unname(rowSums(ef$frontier[, 4:6])), rep(1, nrow(ef$frontier)), tolerance = 1e-9)
})

test_that("R3-18 cpcv_portfolio: Training mit rr$ppy, Tippfehler und Grenzfaelle", {
  d <- .bs_prices(4 * 365)
  rec <- new.env(); rec$ppy <- NA_real_
  suppressMessages(utils::capture.output(trace(".opt_core", bquote(assign("ppy", ppy, envir = .(rec))), where = asNamespace("SimLev"), print = FALSE)))
  on.exit(suppressMessages(utils::capture.output(untrace(".opt_core", where = asNamespace("SimLev")))))
  invisible(cpcv_portfolio(d, methods = "min_variance", frequency = "day", n_groups = 4, test_groups = 1))
  expect_equal(rec$ppy, SimLev:::.opt_returns(d, NULL, "day")$ppy)      # nicht 252
  expect_error(cpcv_portfolio(d, methods = c("equal", "min_varianze"), frequency = "day"), "unbekanntes Verfahren")
  expect_error(cpcv_portfolio(d, n_groups = 3, test_groups = 3), "kleiner als n_groups")
  expect_error(cpcv_portfolio(d, methods = list(a = list(method = "min_variance", upper = 0.2))), "keine Optimierung erfolgreich")
})

test_that("R3-19 entropy_pooling: prior und Views werden geprueft", {
  set.seed(1); X <- data.frame(aktien = rnorm(1000, 0.15, 2), anleihen = rnorm(1000, 0.05, 0.6))
  expect_error(entropy_pooling(X, c("aktien", "anleihen"), list(), prior = rep(1, 10)), "1000")
  expect_error(entropy_pooling(X, c("aktien", "anleihen"), list(), prior = c(-1, rep(1, 999))), "negative")
  expect_error(view_vol("aktien", -1), ">= 0"); expect_error(view_prob("aktien < 0", 1.5), "zwischen 0 und 1")
  expect_equal(entropy_pooling(X, c("aktien", "anleihen"), list(), prior = rep(3, 1000))$summary$mean_prior, unname(colMeans(X)))
})

test_that("R3-20 Anlagen ohne Schwankung und N = 1", {
  R <- .bs_R(); Rc <- cbind(R, cash = 0.0005)
  for (m in c("risk_parity", "hrp", "inverse_vol")) expect_error(portfolio_optimize(Rc, method = m), "ohne Schwankung")
  expect_warning(p <- portfolio_optimize(Rc), "ohne Schwankung")
  expect_true(is.na(p$stats[["sharpe"]])); expect_equal(p$stats[["volatility"]], 0)
  pd <- suppressWarnings(portfolio_optimize(Rc, cov = "denoise")); expect_equal(sum(pd$weights), 1)
  R1 <- R[, 1, drop = FALSE]
  expect_equal(unname(efficient_frontier(R1)$frontier$aktien), 1)
  expect_equal(unname(portfolio_optimize(R1, resample = 5, seed = 1)$weights), 1)
  d <- .bs_prices(1500); expect_equal(range(rolling_optimization(d, "aktien", window = 2)$aktien), c(1, 1))
})

test_that("R3-21 Grenzen und Budgets: positionsweise, Tippfehler, NA, Leerverkauf", {
  R <- .bs_R()
  p <- portfolio_optimize(R, upper = c(0.2, 0.2, 0.6))
  expect_true(all(p$weights <= c(0.2, 0.2, 0.6) + 1e-9)); expect_equal(unname(p$bounds["upper", ]), c(0.2, 0.2, 0.6))
  expect_error(portfolio_optimize(R, upper = c(anleihe = 0.5)), "unbekannte Anlage")
  expect_error(portfolio_optimize(R, upper = c(0.5, 0.5)), "L\u00e4nge 2")
  expect_equal(portfolio_optimize(R, method = "risk_parity", budget = c(0.5, 0.3, 0.2))$weights,
               portfolio_optimize(R, method = "risk_parity", budget = c(aktien = 0.5, reits = 0.3, anleihen = 0.2))$weights)
  expect_warning(portfolio_optimize(R, method = "inverse_vol", upper = 0.4), "ignoriert")
  expect_error(portfolio_optimize(R, upper = c(aktien = NA)), "ohne NA")
  expect_error(portfolio_optimize(R, method = "mean_variance", lower = -0.5), "Long-only")
})

test_that("R3-22 regime_hmm: k pr\u00fcfen, konstante Kurse, loglik zu den gelieferten Parametern", {
  set.seed(1); n <- 8 * 365
  d <- data.frame(date = seq.Date(as.Date("2010-01-01"), by = "day", length.out = n))
  d$a <- 100 * exp(cumsum(rnorm(n, 2e-4, 0.01))); d$const <- 100
  expect_error(regime_hmm(d, "a", k = 1), "ganze Zahl >= 2"); expect_error(regime_hmm(d, "a", k = 2.5), "ganze Zahl >= 2")
  expect_error(regime_hmm(d, "const", k = 2), "ohne Schwankung")
  h <- regime_hmm(d, "a", k = 2, max_iter = 1)
  X <- SimLev:::.dep_returns(d, "a", NULL, "week")$a
  mu <- h$means[, 1] / 100 / h$ppy; sd <- h$volatility[, 1] / 100 / sqrt(h$ppy)
  B <- sapply(1:2, function(j) dnorm(X, mu[j], sd[j])); a <- h$initial * B[1, ]; ll <- log(sum(a)); a <- a / sum(a)
  for (t in 2:length(X)) { a <- drop(a %*% h$transition) * B[t, ]; ll <- ll + log(sum(a)); a <- a / sum(a) }
  expect_equal(h$loglik, ll, tolerance = 1e-8)
})

test_that("R3-23 dependence_analysis: diskrete Zustandsvariable ohne leeres Regime", {
  set.seed(1); n <- 3000
  d <- data.frame(date = seq.Date(as.Date("2010-01-01"), by = "day", length.out = n))
  infl <- 2 + cumsum(rnorm(n, 0, 0.05)); e1 <- rnorm(n); e2 <- rnorm(n); rho <- ifelse(infl > 2, 0.5, -0.3)
  d$stocks <- 100 * exp(cumsum(0.01 * e1)); d$bonds <- 100 * exp(cumsum(0.005 * (rho * e1 + sqrt(1 - rho^2) * e2)))
  d$regime <- ifelse(infl > 2, 2, 1)
  da <- dependence_analysis(d, c("stocks", "bonds"), conditions = "regime", B = 0, dcc = FALSE, copulas = FALSE)
  ref <- dependence_analysis(d, c("stocks", "bonds"), conditions = "regime", breaks = list(regime = c(-Inf, 1.5, Inf)),
                             B = 0, dcc = FALSE, copulas = FALSE)
  expect_equal(da$conditional$regime$n, ref$conditional$regime$n)
  expect_equal(da$conditional$regime$pearson, ref$conditional$regime$pearson)
  # stetige Zustaende: unveraenderte Quantilsgrenzen
  cv <- rnorm(500); rg <- SimLev:::.dep_regimes(cv)
  expect_equal(rg$breaks, c(-Inf, quantile(cv, c(1, 2) / 3, names = FALSE), Inf))
})

test_that("R3-25 fit_copula / tail_dependence: Eingabepruefung", {
  set.seed(1); x <- rnorm(200); y <- x + rnorm(200)
  expect_error(fit_copula(x, rep(1, 200)), "konstant")
  expect_error(fit_copula(x, y, families = "clayton_45"), "unbekannte Familie")
  expect_error(fit_copula(x, y, families = "gaussian_180"), "unbekannte Familie")
  expect_error(fit_copula(x, y[1:100]), "gleich lang")
  expect_error(tail_dependence(x, y[1:100]), "gleich lang")
  expect_error(tail_dependence(x, y, q = 0), "echt zwischen 0 und 1")
})

test_that("R3-26 crisis_replay: Eingabepruefung", {
  d <- data.frame(date = as.Date("2020-01-01") + 0:9, a = c(100, 110, 90, 80, 85, 120, 130, 100, 95, 140), b = 100 + 0:9)
  kr <- data.frame(crisis = "K", start = as.Date("2020-01-02"), end = as.Date("2020-01-05"))
  expect_error(crisis_replay(d, c(a = 0.5, gold = 0.5), kr), "'gold'")
  expect_error(crisis_replay(d, c(0.5, 0.5), kr), "benannter")
  expect_error(crisis_replay(d, c(a = 1, b = -1), kr), "positiv")
  d0 <- d; d0$a[2] <- 0; expect_error(crisis_replay(d0, c(a = 0.5, b = 0.5), kr), "positiv und endlich")
})

test_that("R3-27 risk_contributions: CVaR-Grenzbeitrag bei Gewicht 0, Namenspruefung", {
  R <- .bs_R(); w <- c(aktien = 0.5, reits = 0, anleihen = 0.5)
  rc <- risk_contributions(R, w, measure = "cvar")
  L <- -drop(R %*% w); tl <- L >= quantile(L, 0.95)
  expect_equal(rc$marginal, unname(colMeans(-R[tl, ])))
  expect_equal(sum(rc$contribution), attr(rc, "total"))
  expect_error(risk_contributions(R, c(0.5, 0.2, 0.3)), "benannter")
  expect_error(risk_contributions(R, c(aktien = 0.5, gold = 0.5)), "'gold'")
})

test_that("R3-28 Kurse <= 0 oder nicht endlich werden mit Spalte und Datum abgewiesen", {
  d <- .bs_prices()
  d0 <- d; d0$aktien[100:106] <- 0
  expect_error(portfolio_optimize(d0), "Kursspalte 'aktien'.*2015-04-10")
  expect_error(dependence_analysis(d0, c("aktien", "anleihen"), B = 0, dcc = FALSE, copulas = FALSE), "positiv und endlich")
  dn <- d; dn$aktien[100] <- -5; expect_error(entropy_pooling(dn, c("aktien", "anleihen"), list()), "-5")
  di <- d; di$aktien[100] <- Inf; expect_error(regime_hmm(di, "aktien"), "Inf")
  dna <- d; dna$aktien[100:106] <- NA; expect_equal(portfolio_optimize(dna)$n_obs, portfolio_optimize(d)$n_obs)
})

test_that("R3-29 Sharpe-Kennzahlen: zentriert gerechnet, Spalten ohne Schwankung ausgeschlossen", {
  set.seed(1); R <- matrix(rnorm(1000 * 3, 4e-4, 0.01), 1000)
  cash <- 100 * cumprod(rep(1 + 0.02 / 365, 1001)); cash <- cash[-1] / cash[-1001] - 1
  ohne <- deflated_sharpe(R, frequency = "day", id = 1)
  expect_warning(mit <- deflated_sharpe(cbind(R, cash), frequency = "day", id = 1), "ohne Schwankung")
  expect_equal(mit$sr0, ohne$sr0); expect_equal(mit$dsr, ohne$dsr)
  expect_warning(h <- sharpe_haircut(cbind(R, cash), frequency = "day"), "ohne Schwankung")
  expect_equal(nrow(h), 3L)
  expect_warning(pb <- pbo(cbind(R, cash), S = 4, frequency = "day"), "ohne Schwankung")
  expect_equal(pb$lambda, pbo(R, S = 4, frequency = "day")$lambda)
  # zentrierte Varianz: grosses Mittel, kleine Streuung
  x <- 1e-3 + 1e-9 * rnorm(500); M <- cbind(x, rnorm(500, 0, 0.01))
  expect_equal(unname(SimLev:::.of_col_metric(M, "sharpe")), unname(apply(M, 2, function(r) mean(r) / sd(r))), tolerance = 1e-10)
})
