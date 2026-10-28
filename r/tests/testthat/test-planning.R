# Tests fuer Gebuehren/Kirchensteuer/Freibetrag, Szenarien, Optimierungs-
# Erweiterungen, Planung und Analyse-Tests

mk_px <- function(n = 365 * 12, seed = 1, mu = 3.5e-4, sd = 0.01) {
  set.seed(seed)
  d <- data.frame(date = seq.Date(as.Date("2010-01-01"), by = "day", length.out = n))
  d$A <- 100 * cumprod(1 + rnorm(n, mu, sd))
  d
}

test_that("order fees, church tax and allowance harvesting in simulation()", {
  d <- mk_px()
  st <- create_strategy(A = asset_config("etf", "bnh", partial_exemption = 30, spread = 0.1))
  a <- list(dca = dca_plan(value = 100, span = 1), tax = tax_profile())
  base <- suppressWarnings(do.call(simulation, c(list(d, st), a)))
  z <- suppressWarnings(do.call(simulation, c(list(d, st), a, list(costs = sim_costs(order_fee = 0)))))
  expect_identical(base$worth, z$worth)
  f1 <- suppressWarnings(do.call(simulation, c(list(d, st), a, list(costs = sim_costs(order_fee = 1)))))
  f0 <- suppressWarnings(do.call(simulation, c(list(d, st), a, list(costs = sim_costs(order_fee = 1, dca_fee = 0)))))
  expect_lt(tail(f1$worth, 1), tail(base$worth, 1))
  # Sparplankaeufe gebuehrenfrei; nur die Anlage des Startkapitals am 1. Tag kostet order_fee (R2-01)
  expect_equal(f0$fees_paid, 1)
  expect_gt(tail(base$worth, 1) - tail(f0$worth, 1), 0); expect_lt(tail(base$worth, 1) - tail(f0$worth, 1), 10)
  n_buys <- sum(vapply(base$report$A$flows, function(v) v > 0, TRUE)) + 1L   # Sparraten plus Starttag
  expect_equal(f1$fees_paid, n_buys * 1, tolerance = 2)
  pct <- suppressWarnings(simulation(d, st, costs = sim_costs(order_fee = list(percent = 0.25, min = 5))))
  expect_equal(pct$fees_paid, max(5, 0.0025 * 10000 / (1 + 0.0025)), tolerance = 1e-6)
  # Kirchensteuer: effektiver Satz 27,99 % bei 9 %
  k <- 0.09; eff <- 0.25 / (1 + 0.25 * k) * (1 + 0.055 + k)
  b0 <- suppressWarnings(simulation(d, st, tax = tax_profile(sparer_pauschbetrag = 0), liquidate = TRUE))
  b9 <- suppressWarnings(simulation(d, st, tax = tax_profile(church_tax = 9, sparer_pauschbetrag = 0), liquidate = TRUE))
  expect_equal(b9$tax_report$total_taxes_paid / b0$tax_report$total_taxes_paid, eff / 0.26375, tolerance = 2e-3)
  # Freibetrag ausschoepfen
  h0 <- suppressWarnings(simulation(d, st, start_value = 50000, tax = tax_profile(), liquidate = TRUE))
  h1 <- suppressWarnings(simulation(d, st, start_value = 50000, tax = tax_profile(harvest = harvest_rule()), liquidate = TRUE))
  expect_lt(h1$tax_report$total_taxes_paid, h0$tax_report$total_taxes_paid)
  expect_gt(tail(h1$worth, 1), tail(h0$worth, 1))
  expect_equal(format(h1$harvest_days[1], "%m-%d"), "12-15")
  expect_error(harvest_rule(day = "12-31"), "harvest_rule: day")
})

test_that("entropy pooling meets views and keeps probabilities valid", {
  set.seed(1); X <- data.frame(a = rnorm(2000, 0.2, 2), b = rnorm(2000, 0.05, 0.5))
  X$b <- X$b + 0.1 * X$a
  ep <- scenario_entropy_pooling(X, c("a", "b"), list(view_mean("a", -0.3), view_prob("a < -2", 0.2), view_vol("b", 0.5, "<=")))
  expect_equal(sum(ep$prob), 1); expect_true(all(ep$prob >= 0))
  expect_equal(sum(ep$prob * X$a), -0.3, tolerance = 1e-5)
  expect_equal(sum(ep$prob * (X$a < -2)), 0.2, tolerance = 1e-5)
  mb <- sum(ep$prob * X$b); expect_lte(sqrt(sum(ep$prob * (X$b - sum(X$b) / 2000)^2)), 0.5 + 1e-4)
  expect_lt(ep$effective_n, 2000)
  sr <- scenario_risk(ep, c(a = 0.5, b = 0.5)); expect_true(sr[["cvar"]] >= sr[["var"]])
  expect_output(print(ep), "entropy_pooling")
})

test_that("copula scenarios and crisis replay", {
  set.seed(2); n <- 365 * 12
  d <- data.frame(date = seq.Date(as.Date("2005-01-01"), by = "day", length.out = n))
  z <- matrix(rnorm(2 * n), n) %*% chol(matrix(c(1, 0.6, 0.6, 1), 2)); w <- sqrt(rchisq(n, 4) / 4)
  d$a <- 100 * exp(cumsum(0.01 * z[, 1] / w)); d$b <- 100 * exp(cumsum(0.005 * z[, 2] / w))
  cs <- scenario_copula(d, c("a", "b"), n = 20000, frequency = "day", seed = 1)
  expect_equal(cs$copula$correlation[1, 2], 0.6, tolerance = 0.05)
  expect_lt(cs$copula$df, 15)
  ss <- scenario_copula(d, c("a", "b"), n = 20000, frequency = "day", stress = list(a = c(0, 0.05)), seed = 1)
  qa <- quantile(cs$scenarios$a, 0.05)
  expect_true(all(ss$scenarios$a <= qa + 1e-9))
  expect_lt(mean(ss$scenarios$b), mean(cs$scenarios$b) - 0.3)
  cr <- scenario_crisis(d, c(a = 0.6, b = 0.4))
  expect_true(all(cr$crisis %in% c("Finanzkrise 2007-09", "Eurokrise 2011")))
  i <- which(d$date == as.Date("2007-10-09")); j <- which(d$date == as.Date("2009-03-09"))
  expect_equal(cr$portfolio[1], 100 * (0.6 * d$a[j] / d$a[i] + 0.4 * d$b[j] / d$b[i] - 1))
})

test_that("covariance estimators, min CDaR, CPCV and Sharpe haircuts", {
  set.seed(1)
  S0 <- matrix(c(0.04, 0.006, 0.002, 0.006, 0.0225, 0.001, 0.002, 0.001, 0.0025), 3) / 52
  R <- matrix(rnorm(780 * 3), 780) %*% chol(S0) + matrix(c(0.08, 0.06, 0.02) / 52, 780, 3, byrow = TRUE)
  colnames(R) <- c("a", "b", "c")
  for (cv in c("ewma", "denoise", "gerber")) {
    S <- SimLev:::.opt_cov(R, cv); expect_true(isSymmetric(S)); expect_true(all(eigen(S)$values > 0))
    expect_equal(sum(portfolio_optimize(R, method = "min_variance", cov = cv)$weights), 1)
  }
  R2 <- R[, 1:2]; g <- seq(0, 1, by = 0.002)
  cd <- sapply(g, function(a) SimLev:::.cdar_hist(R2 %*% c(a, 1 - a), 0.05))
  oc <- portfolio_optimize(R2, method = "min_cdar")
  expect_lt(oc$stats[["cdar"]], min(cd) + 1e-4)
  cp <- portfolio_cpcv(R, methods = c("equal", "min_variance"), n_groups = 5, test_groups = 2)
  expect_equal(cp$n_splits, choose(5, 2)); expect_equal(nrow(cp$splits), 2 * choose(5, 2))
  expect_output(print(cp), "CPCV")
  hc <- sharpe_haircut(c(1, 0.5), n_obs = 520, n_tests = 50)
  p1 <- 2 * pnorm(-1 / sqrt(52) * sqrt(520))
  expect_equal(hc$p_bonferroni[1], min(1, 50 * p1))
  expect_equal(hc$sharpe_bonferroni[1], qnorm(1 - min(1, 50 * p1) / 2) / sqrt(520) * sqrt(52))
  expect_true(all(hc$haircut_bhy >= hc$haircut_bonferroni - 1e-12 | is.na(hc$haircut_bhy)))
})

test_that("expected-return shift, pooled bootstrap, random horizon and goal planning", {
  d <- mk_px(3650)
  d$r <- c(1, d$A[-1] / d$A[-nrow(d)])
  d2 <- series_shift_return(d, "r", 4)
  yrs <- as.numeric(max(d$date) - min(d$date)) / 365.25
  expect_equal(prod(d2$r)^(1 / yrs) - 1, 0.04, tolerance = 1e-10)
  expect_equal(sd(log(d2$r)), sd(log(d$r)))
  mk <- function(mu, seed) { set.seed(seed); n <- 60
    data.frame(date = seq.Date(as.Date("1960-12-31"), by = "year", length.out = n),
               s = 100 * cumprod(c(1, exp(rnorm(n - 1, mu, 0.18)))), cpi = 100 * cumprod(c(1, rep(1.02, n - 1)))) }
  ds <- list(x = mk(0.07, 1), y = mk(0.01, 2))
  pb <- bootstrap_pooled(ds, "s", inflation = "cpi", n = 300, years = 30, seed = 1)
  expect_s3_class(pb, "withdrawal_paths"); expect_equal(dim(pb$returns), c(30L, 300L))
  expect_true(all(abs(pb$inflation - 1.02) < 1e-12))
  expect_lt(abs(mean(pb$countries == "x") - 0.5), 0.1)
  pt <- bootstrap_pooled(ds, "s", n = 300, years = 30, seed = 1, target = c(s = 5))
  expect_lt(abs(exp(mean(log(pt$assets$s))) - 1.05), 0.01)                  # Ziehungsrauschen um 5 %
  h <- withdrawal_horizon("discrete", years = c(20, 30), prob = c(0.5, 0.5))
  hh <- SimLev:::.draw_horizon(h, 1000); expect_setequal(unique(hh), c(20, 30))
  expect_identical(hh, SimLev:::.draw_horizon(h, 1000))
  w30 <- withdrawal_simulation(pb, withdrawal_rule("constant", rate = 4), years = 30)
  wf <- withdrawal_simulation(pb, withdrawal_rule("constant", rate = 4), horizon = 30)
  expect_equal(wf$paths$success, w30$paths$success)
  w20 <- withdrawal_simulation(pb, withdrawal_rule("constant", rate = 4), years = 20)
  wr <- withdrawal_simulation(pb, withdrawal_rule("constant", rate = 4), horizon = h)
  H <- wr$paths$horizon
  expect_equal(wr$paths$success, ifelse(H == 20, w20$paths$success, w30$paths$success))
  expect_equal(wr$paths$terminal_real[H == 20], w20$paths$terminal_real[H == 20], tolerance = 1e-8)
  expect_error(withdrawal_horizon("uniform", min = 30), "max")
  cand <- lapply(c(0, 0.5, 1), function(a) c(s = a, cpi = 1 - a)); names(cand) <- c("A0", "A50", "A100")
  Rc <- do.call(rbind, lapply(ds, function(x) portfolio_returns(x, cand, "year")))
  gp <- planning_goal(Rc, start_value = 100, goal = 200, horizon = 15, n_sim = 4000, seed = 1)
  expect_gte(gp$probability, max(gp$static) - 1e-9)
  expect_equal(mean(gp$simulation$success), gp$probability, tolerance = 0.03)
  expect_output(print(gp), "Zielplanung")
  pdf(NULL); on.exit(dev.off(), add = TRUE); expect_silent(plot(gp))
})

test_that("signal analysis, Sharpe tests, reality check, MinTRL, heatmap, HMM and real deep analysis", {
  set.seed(3); n <- 365 * 16
  d <- data.frame(date = seq.Date(as.Date("2000-01-01"), by = "day", length.out = n))
  st <- rep(rep(1:2, c(700, 300)), length.out = n)
  d$A <- 100 * exp(cumsum(ifelse(st == 1, rnorm(n, 4e-4, 0.006), rnorm(n, -3e-4, 0.02))))
  d$B <- 100 * exp(cumsum(rnorm(n, 1e-4, 0.004)))
  d$sig <- c(NA, diff(log(d$A)))
  sa <- signal_analysis(d, "sig", "A", horizon = 10, bins = 4, splits = 2)
  expect_equal(sum(sa$bins$n), nrow(sa$data)); expect_equal(dim(sa$splits), c(4L, 2L))
  t0 <- sharpe_test(d$A[-1] / d$A[-n] - 1, d$A[-1] / d$A[-n] - 1, ppy = 365)
  expect_equal(unname(t0["difference"]), 0)
  tt <- sharpe_test(data.frame(date = d$date, value = d$A), data.frame(date = d$date, value = d$B))
  expect_true(tt["p_value"] > 0 && tt["p_value"] <= 1)
  set.seed(4); R <- matrix(rnorm(800 * 10, 0, 0.01), 800); R[, 2] <- R[, 2] + 0.003
  rc <- overfit_reality_check(R, B = 200, frequency = "day", seed = 1)
  expect_lt(rc$p_spa, 0.05); expect_equal(rc$best, "p2")
  r <- d$B[-1] / d$B[-n] - 1; mt <- sharpe_min_track_record(r, ppy = 365)
  sr <- mean(r) / sd(r); zz <- (r - mean(r)) / sd(r)
  expect_equal(unname(mt["needed_periods"]), 1 + (1 - mean(zz^3) * sr + (mean(zz^4) - 1) / 4 * sr^2) * (qnorm(0.95) / sr)^2)
  hm <- result_heatmap(data.frame(date = d$date, value = d$A), max_years = 5)
  ye <- tapply(d$A, format(d$date, "%Y"), function(v) tail(v, 1))
  expect_equal(unname(hm$matrix["2001", "1"]), unname(ye["2001"] / ye["2000"] - 1))
  expect_equal(unname(hm$matrix["2001", "3"]), unname((ye["2003"] / ye["2000"])^(1 / 3) - 1))
  hmm <- regime_hmm(d, "A", k = 2)
  expect_gt(hmm$volatility[2, 1], 2 * hmm$volatility[1, 1])
  s_day <- regime_states(hmm, d$date)
  expect_gt(mean(s_day == st, na.rm = TRUE), 0.85)
  e <- hmm$dates[100]; expect_true(is.na(regime_states(hmm, e)) || regime_states(hmm, e) == max.col(hmm$filtered)[99])
  da <- result_analysis(data.frame(date = d$date, value = d$B), inflation = 2)
  dn <- result_analysis(data.frame(date = d$date, value = d$B))
  expect_equal((1 + da$metrics["cagr", 1]) * 1.02, 1 + dn$metrics["cagr", 1], tolerance = 1e-6)
  pdf(NULL); on.exit(dev.off(), add = TRUE)
  expect_silent(plot(sa)); expect_silent(plot(hm)); expect_silent(plot(hmm))
})
