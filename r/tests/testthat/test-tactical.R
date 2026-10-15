# Tests fuer taktische Allokation, Optimierer, Risikozerlegung und Anleihereihen

make_mkt <- function(n = 365 * 8, seed = 1) {
  set.seed(seed)
  d <- data.frame(date = seq.Date(as.Date("2012-01-01"), by = "day", length.out = n))
  d$A <- 100 * cumprod(1 + rnorm(n, 3e-4, 0.012)); d$B <- 100 * cumprod(1 + rnorm(n, 2e-4, 0.009))
  d$C <- 100 * cumprod(1 + rnorm(n, 1e-4, 0.004)); d$CASH <- 100 * cumprod(rep(1 + 0.02 / 365, n))
  d
}

test_that("signal_state, momentum_score and weight builders", {
  st <- signal_state(list(buy = c(F, T, F, F, F, T), sell = c(F, F, F, T, F, F)))
  expect_equal(st, c(FALSE, TRUE, TRUE, FALSE, FALSE, TRUE))
  d <- make_mkt()
  S <- momentum_score(d, c("A", "B"), lookbacks = c(1, 12))
  i <- which(d$date == as.Date("2016-06-15"))
  j1 <- which(d$date == as.Date("2016-05-15")); j12 <- which(d$date == as.Date("2015-06-15"))
  expect_equal(unname(S[i, "A"]), mean(c(d$A[i] / d$A[j1] - 1, d$A[i] / d$A[j12] - 1)))
  expect_true(all(is.na(S[1:300, "A"])))
  w <- tactical_rules(d, list(list(when = "A > B", weights = c(A = 1)),
                              list(when = rep(TRUE, nrow(d)), weights = c(B = 0.5, C = 0.5))), default = c(C = 1))
  expect_s3_class(w, "SimLevWeights")
  expect_equal(unname(rowSums(as.matrix(w[, -1]))), rep(1, nrow(d)))
  expect_equal(attr(w, "regime"), ifelse(d$A > d$B, 1L, 2L))
  ro <- tactical_rotation(d, c("A", "B"), top = 1, safe = c("C", "CASH"))
  dr <- attr(ro, "decision_rows"); sc <- attr(ro, "scores")
  k <- dr[10]; best <- c("A", "B")[which.max(sc[k, c("A", "B")])]
  if (sc[k, best] >= 0) expect_equal(ro[[best]][k], 1) else expect_equal(sum(ro[k, c("C", "CASH")]), 1)
  expect_true(all(ro$A[(k + 1):(dr[11])] == ro$A[k]))                         # gehalten bis zur naechsten Entscheidung
  can <- tactical_rotation(d, c("A", "B"), top = 2, safe = "CASH", canary = c("A", "B"), absolute = FALSE)
  sc2 <- attr(can, "scores"); k2 <- attr(can, "decision_rows")[20]
  expect_equal(can$CASH[k2], min(1, sum(sc2[k2, c("A", "B")] < 0) / 2))
  gp <- glidepath(d, from = c(A = 0.9, C = 0.1), to = c(A = 0.3, C = 0.7))
  expect_equal(gp$A[1], 0.9); expect_equal(gp$A[nrow(d)], 0.3, tolerance = 1e-12)
  expect_true(all(diff(gp$A) <= 1e-12))
  bl <- blend_weights(x = gp, y = ro, shares = c(0.5, 0.5))
  expect_equal(bl$A, 0.5 * gp$A + 0.5 * ro$A)
  tv <- target_volatility(d, c(A = 1), safe = "CASH", target = 5)
  ex <- attr(tv, "exposure"); expect_true(all(ex >= 0 & ex <= 1))
  expect_equal(tv$A + tv$CASH, rep(1, nrow(d)))
  expect_error(target_volatility(d, c(A = 1), safe = "CASH", max_exposure = 2), "Kredit")
  cv <- conditional_volatility(d, c(A = 1), safe = "CASH", base = 0.8, min_history = 1)
  st <- attr(cv, "state"); ex <- attr(cv, "exposure")
  expect_equal(cv$A + cv$CASH, rep(1, nrow(d)))
  expect_true(all(ex[st == 0L] == 0.8)); expect_true(all(ex[st == 1L] <= 0.8)); expect_true(all(ex[st == -1L] >= 0.8 & ex[st == -1L] <= 1))
  expect_true(all(st[seq_len(365)] == 0L))                                   # vor min_history
  d2 <- d; cut <- 365 * 3; d2$A[(cut + 1):nrow(d)] <- d2$A[(cut + 1):nrow(d)] * 1.5^(seq_len(nrow(d) - cut) %% 2)
  cv2 <- conditional_volatility(d2, c(A = 1), safe = "CASH", base = 0.8, min_history = 1)
  expect_identical(cv$A[seq_len(cut)], cv2$A[seq_len(cut)])                  # kein Blick in die Zukunft
  fx <- conditional_volatility(d, c(A = 1), safe = "CASH", base = 0.7, min_history = 1,
                               scaling = "fixed", high_exposure = 0.3, low_exposure = 0.9)
  expect_true(all(round(fx$A, 10) %in% c(0.3, 0.7, 0.9)))
  expect_message(conditional_volatility(d, c(A = 1), safe = "CASH", min_history = 1), "hochskaliert")
  expect_silent(conditional_volatility(d, c(A = 1), safe = "CASH", lower = NULL, min_history = 1))
  expect_error(conditional_volatility(d, c(A = 1), safe = "CASH", max_exposure = 1.5), "Kredit")
  expect_output(print(cv), "Volatilit\u00e4tsphasen")
  expect_output(print(ro), "Zielgewichte")
  pdf(NULL); on.exit(dev.off(), add = TRUE); expect_silent(plot(bl))
})

test_that("tactical_simulation trades to the target weights", {
  d <- make_mkt(365 * 6)
  wr <- tactical_rules(d, list(list(when = signal_sma(d$A, 100), weights = c(A = 1))), default = c(C = 1))
  r <- suppressMessages(tactical_simulation(d, wr, lag = 1, asset_args = list(asset_spread = 0)))
  expect_s3_class(r, "SimLevResult")
  st <- as.matrix(r$tactical$weights[, -1])
  # an jedem Ereignistag liegt der Wert nach dem Handel in der Zielanlage
  # (Reste aus der Engine-Logik mit Ist-Gewichten des Vortags bleiben klein)
  ev <- match(as.numeric(r$tactical$events), as.numeric(d$date))
  wA <- r$report$A$worth[ev] / r$worth[ev]
  move <- abs(d$A[ev] / d$A[ev - 1] - 1) + abs(d$C[ev] / d$C[ev - 1] - 1)
  expect_true(all(abs(wA - st[ev, "A"]) <= move + 0.005))
  expect_lt(mean(abs(wA - st[ev, "A"])), 0.005)
  # Verzoegerung: Zielgewicht von Tag t gilt ab t + 1
  expect_equal(unname(st[-1, "A"]), wr$A[-nrow(wr)])
  # statische Gewichte entsprechen jaehrlichem Rebalancing auf dieselben Gewichte
  ws <- tactical_rules(d, list(), default = c(A = 0.6, C = 0.4))
  r1 <- suppressMessages(tactical_simulation(d, ws, rebalance = "year", lag = 0, asset_args = list(asset_spread = 0)))
  expect_equal(r1$tactical$switches, 0L)
  expect_equal(length(r1$tactical$events), 6L)                                # Jahresenden 2012-2017
  # Toleranzband: weniger Handel
  rb <- suppressMessages(tactical_simulation(d, ws, rebalance = "month", tolerance = 50, asset_args = list(asset_spread = 0)))
  ra <- suppressMessages(simulation(d, strategy_from_weights(c(A = 0.6, C = 0.4), asset_spread = 0)))
  expect_equal(tail(rb$worth, 1), tail(ra$worth, 1), tolerance = 1e-10)
  expect_error(tactical_simulation(d, ws, balance_mode = TRUE), "steuert")
})

test_that("portfolio_optimize matches closed forms and brute force", {
  set.seed(1)
  S0 <- matrix(c(0.04, 0.006, 0.002, 0.006, 0.0225, 0.001, 0.002, 0.001, 0.0025), 3) / 52
  R <- matrix(rnorm(780 * 3), 780) %*% chol(S0) + matrix(c(0.08, 0.06, 0.02) / 52, 780, 3, byrow = TRUE)
  colnames(R) <- c("a", "b", "c")
  S <- cov(R)
  w <- solve(S, rep(1, 3)); w <- w / sum(w)
  expect_equal(unname(portfolio_optimize(R, method = "min_variance")$weights), unname(w), tolerance = 1e-6)
  ws <- solve(S, colMeans(R)); ws <- ws / sum(ws)
  expect_equal(unname(portfolio_optimize(R, method = "max_sharpe")$weights), unname(ws), tolerance = 1e-4)
  rp <- portfolio_optimize(R, method = "risk_parity")
  expect_equal(rp$risk$risk_share, rep(1 / 3, 3), tolerance = 1e-8)
  rpb <- portfolio_optimize(R, method = "risk_parity", budget = c(a = 0.5, b = 0.25, c = 0.25))
  expect_equal(rpb$risk$risk_share, c(0.5, 0.25, 0.25), tolerance = 1e-8)
  ub <- portfolio_optimize(R, method = "min_variance", upper = c(c = 0.5))
  expect_equal(unname(ub$weights["c"]), 0.5, tolerance = 1e-8); expect_equal(sum(ub$weights), 1)
  R2 <- R[, 1:2]; g <- seq(0, 1, by = 0.001)
  cv <- sapply(g, function(a) SimLev:::.cvar_hist(R2 %*% c(a, 1 - a), 0.05))
  oc <- portfolio_optimize(R2, method = "min_cvar")
  expect_lt(oc$stats[["cvar"]], min(cv) + 1e-5)
  h <- portfolio_optimize(R, method = "hrp"); expect_equal(sum(h$weights), 1); expect_true(all(h$weights > 0))
  iv <- portfolio_optimize(R, method = "inverse_vol")$weights
  expect_equal(unname(iv), unname((1 / sqrt(diag(S))) / sum(1 / sqrt(diag(S)))))
  lw <- SimLev:::.opt_cov(R, "ledoit_wolf"); expect_true(all(eigen(lw)$values > 0))
  expect_true(isSymmetric(lw))
  rs <- portfolio_optimize(R, method = "min_variance", resample = 10, seed = 1)
  expect_equal(dim(rs$resampled), c(10L, 3L)); expect_equal(sum(rs$weights), 1)
  expect_error(portfolio_optimize(R, upper = 0.2), "Grenzen")
  ef <- efficient_frontier(R, n = 20)
  expect_true(all(diff(ef$frontier$volatility) >= -1e-10))
  expect_output(print(rp), "risk_parity"); expect_output(print(ef), "Effizienzgrenze")
  pdf(NULL); on.exit(dev.off(), add = TRUE); expect_silent(plot(rp)); expect_silent(plot(ef))
})

test_that("risk_contributions add up; rolling optimization feeds tactical_simulation", {
  set.seed(2); R <- matrix(rnorm(500 * 3, 0, c(0.03, 0.02, 0.01)), 500, byrow = TRUE); colnames(R) <- c("a", "b", "c")
  w <- c(a = 0.5, b = 0.3, c = 0.2)
  rv <- risk_contributions(R, w)
  expect_equal(sum(rv$contribution), attr(rv, "total"))
  expect_equal(attr(rv, "total"), sqrt(drop(t(w) %*% cov(R) %*% w) * 52))
  rc <- risk_contributions(R, w, "cvar")
  expect_equal(sum(rc$contribution), SimLev:::.cvar_hist(R %*% w, 0.05), tolerance = 1e-12)
  d <- make_mkt(365 * 5)
  ro <- rolling_optimization(d, c("A", "B", "C"), "inverse_vol", window = 2, every = "quarter")
  dr <- attr(ro, "decision_rows")
  expect_true(all(ro$A[1:(dr[1] - 1)] == 1 / 3))
  sub <- d[d$date > d$date[dr[2]] - round(2 * 365.25) & d$date <= d$date[dr[2]], ]
  expect_equal(unname(unlist(ro[dr[2], c("A", "B", "C")])),
               unname(portfolio_optimize(sub, c("A", "B", "C"), "inverse_vol")$weights))
  r <- suppressMessages(tactical_simulation(d, ro, rebalance = "quarter"))
  expect_true(tail(r$worth, 1) > 0)
})

test_that("bond, money market and hedged series", {
  d <- data.frame(date = seq.Date(as.Date("2020-01-01"), by = "day", length.out = 3), y = c(2, 2, 3))
  b <- bond_index_from_yields(d, "y", maturity = 10, coupon_frequency = 1)
  P <- 0.02 * (1 - 1.03^-10) / 0.03 + 1.03^-10
  expect_equal(b[2], 100 * (1 + 0.02 / 365.25))
  expect_equal(b[3] / b[2], P + 0.02 / 365.25)
  bd <- bond_index_from_yields(d, "y", maturity = 10, method = "duration")
  expect_equal(bd[3] / b[3], 1, tolerance = 2e-4)                        # Konvexitaetsnaeherung nah an exakt
  expect_equal(attr(b, "duration")[1], -(SimLev:::.bond_price(0.0201, 0.02, 10, 1) - SimLev:::.bond_price(0.0199, 0.02, 10, 1)) / 0.0002,
               tolerance = 1e-6)
  dc <- data.frame(date = seq.Date(as.Date("2021-01-01"), by = "day", length.out = 366), y = 3, x = 100)
  expect_equal(tail(money_market_index(dc, "y"), 1), 100 * (1 + 0.03 / 360)^365)
  expect_equal(tail(money_market_index(dc, 3, spread = 1), 1), 100 * (1 + 0.02 / 360)^365)
  expect_equal(tail(currency_hedged_index(dc, "x", 3, 1), 1), 100 * (1 + 0.02 / 360)^365)
  m <- data.frame(date = as.Date(c("2020-12-01", "2021-06-01")), value = c(1, 2))
  expect_equal(money_market_index(dc, m)[3] / money_market_index(dc, m)[2], 1 + 0.01 / 360)
  z <- data.frame(date = dc$date, y = 0)
  expect_equal(tail(bond_index_from_yields(z, "y"), 1), 100)
})
