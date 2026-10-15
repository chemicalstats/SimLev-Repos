# Tests fuer Entnahme-Simulationen

make_R <- function(years = 30, paths = 400, seed = 1) {
  set.seed(seed)
  matrix(exp(rnorm(years * paths, 0.05, 0.15)), years)
}

test_that("withdrawal_rule validates and sets rule-specific defaults", {
  expect_s3_class(withdrawal_rule("constant"), "withdrawal_rule")
  v <- withdrawal_rule("vanguard", rate = 5)
  expect_equal(c(v$ceiling, v$floor), c(5, 2.5))
  g <- withdrawal_rule("guyton_klinger", rate = 5.2)
  expect_equal(c(g$ceiling, g$floor, g$cut, g$raise, g$cpr_years), c(20, 20, 10, 10, 15))
  expect_equal(withdrawal_rule("vpw", stock_share = 50)$exp_return, 3.45)
  expect_warning(withdrawal_rule("constant", rate = 0.04), "PROZENT")
  expect_error(withdrawal_rule("constant", rate = 120))
})

test_that("constant rule: success iff rate <= perfect withdrawal rate", {
  R <- make_R()
  ws <- withdrawal_simulation(R, withdrawal_rule("constant", rate = 4), start_value = 1e6, inflation = 2)
  expect_equal((ws$paths$pwr >= 4), ws$paths$success)
  expect_true(all(ws$spending[1, ] == 40000))
})

test_that("PWR closed form matches a brute-force root", {
  r <- c(1.1, 0.8, 1.05, 1.2, 0.95)
  pwr <- perfect_withdrawal_rate(matrix(r)) / 100
  P <- 1; for (x in r) P <- (P - pwr) * x
  expect_equal(P, 0, tolerance = 1e-12)
  pwr_leg <- perfect_withdrawal_rate(matrix(r), legacy = 0.5) / 100
  P <- 1; for (x in r) P <- (P - pwr_leg) * x
  expect_equal(P, 0.5, tolerance = 1e-12)
})

test_that("withdrawal_max_rate equals the PWR quantile for the constant rule", {
  R <- make_R()
  ws <- withdrawal_simulation(R, withdrawal_rule("constant"), inflation = 2)
  mr <- withdrawal_max_rate(R, withdrawal_rule("constant"), success = 0.9, inflation = 2, tol = 1e-4)
  expect_equal(as.numeric(mr), unname(quantile(ws$paths$pwr, 0.1, type = 1)), tolerance = 0.02)
  expect_gte(attr(mr, "success"), 0.9)
})

test_that("Guyton-Klinger matches an independent implementation", {
  R <- make_R(paths = 5)
  gk <- function(r, infl, P = 1e6, rate = 0.05, N = 30) {
    out <- numeric(N); W <- NA; WR0 <- NA; rprev <- 0
    for (t in 1:N) {
      if (t == 1) { W <- rate * P; WR0 <- W / P } else {
        cand <- W * infl; if (!(rprev < 0 && cand / P > WR0)) W <- cand
        wr <- W / P
        if (wr > WR0 * 1.2 && (N - t + 1) > 15) W <- W * 0.9 else if (wr < WR0 * 0.8) W <- W * 1.1
      }
      out[t] <- W; P <- (P - min(W, P)) * r[t]; rprev <- r[t] - 1
    }
    out
  }
  ws <- withdrawal_simulation(R, withdrawal_rule("guyton_klinger", rate = 5), inflation = 2)
  for (k in 1:5) expect_equal(ws$planned[, k] * 1.02^(0:29), gk(R[, k], 1.02), tolerance = 1e-10)
})

test_that("Vanguard dynamic spending respects real ceiling and floor", {
  R <- make_R(paths = 50)
  ws <- withdrawal_simulation(R, withdrawal_rule("vanguard", rate = 5), inflation = 2)
  ch <- ws$planned[-1, ] / ws$planned[-30, ] - 1
  ok <- ws$paths$success
  expect_true(all(ch[, ok] <= 0.05 + 1e-10))
  expect_true(all(ch[, ok] >= -0.025 - 1e-10))
})

test_that("1/N and ABW empty the portfolio without failure", {
  R <- make_R(paths = 100)
  w1 <- withdrawal_simulation(R, withdrawal_rule("one_over_n"), inflation = 2)
  expect_true(all(w1$paths$success)); expect_lt(max(w1$paths$terminal_real), 1e-6)
  wa <- withdrawal_simulation(R, withdrawal_rule("abw", exp_return = 3), inflation = 2)
  expect_true(all(wa$paths$success)); expect_lt(max(wa$paths$terminal_real), 1e-6)
})

test_that("all rules run, monthly frequency and taxes reduce outcomes", {
  R <- make_R(paths = 100)
  for (ty in setdiff(names(SimLev:::.wd_rules), "cape")) {
    ws <- withdrawal_simulation(R, withdrawal_rule(ty, rate = 4), inflation = 2)
    expect_true(all(is.finite(ws$paths$terminal_real)), info = ty)
  }
  expect_error(withdrawal_simulation(R, withdrawal_rule("cape")), "CAPE")
  w0 <- withdrawal_simulation(R, withdrawal_rule("constant"), inflation = 2)
  wt <- withdrawal_simulation(R, withdrawal_rule("constant"), inflation = 2, tax_mode = "person")
  expect_true(all(wt$paths$terminal_real <= w0$paths$terminal_real + 1e-6))
  expect_gt(sum(wt$paths$taxes), 0)
  set.seed(2)
  Rm <- matrix(exp(rnorm(360 * 20, 0.05 / 12, 0.15 / sqrt(12))), 360)
  wm <- withdrawal_simulation(Rm, withdrawal_rule("constant"), frequency = "month", inflation = 2)
  expect_equal(wm$years, 30)
})

test_that("income offsets portfolio withdrawals", {
  R <- make_R(paths = 50)
  a <- withdrawal_simulation(R, withdrawal_rule("constant"), inflation = 2)
  b <- withdrawal_simulation(R, withdrawal_rule("constant"), inflation = 2,
                             income = list(list(start = 11, amount = 20000)))
  expect_true(all(b$paths$terminal_real >= a$paths$terminal_real))
  expect_true(all(abs(b$spending[15, b$paths$success] - 40000) < 1e-6))
})

test_that("historical cohorts are built from a daily price series", {
  set.seed(4)
  d <- seq.Date(as.Date("1970-01-01"), as.Date("2019-12-31"), by = "day")
  df <- data.frame(date = d, px = 100 * cumprod(1 + rnorm(length(d), 2.5e-4, 0.01)),
                   cpi = 100 * 1.02^(as.numeric(d - d[1]) / 365.25))
  co <- withdrawal_cohorts(df, "px", inflation = "cpi", years = 30, step = "year")
  expect_s3_class(co, "withdrawal_paths")
  expect_equal(ncol(co$returns), 20L)
  expect_equal(nrow(co$returns), 30L)
  expect_equal(co$inflation[1, 1], 1.02, tolerance = 1e-3)
  ws <- withdrawal_simulation(co, withdrawal_rule("constant", rate = 4))
  s <- summary(ws)
  expect_equal(s$swr, min(ws$paths$pwr))
  expect_true(ws$historical)
})

test_that("bootstrap paths can be converted for withdrawals", {
  set.seed(5); n <- 3000
  d <- data.frame(eq = 1 + rnorm(n, 3e-4, 0.01), cpi = 100 * 1.0001^(0:(n - 1)))
  b <- bootstrap(d, bootstrap_config(c(eq = "eq"), aux = c(cpi = "cpi")), "stationary", n = 5,
                 params = list(L = 30), path_length = 7310, seed = 1, progress = FALSE)
  wp <- withdrawal_paths(b, "eq", inflation = 2, start_date = "2000-01-01")
  expect_equal(nrow(wp$returns), 20L)
  ws <- withdrawal_simulation(wp, withdrawal_rule("percent", rate = 4))
  expect_true(all(ws$paths$success))
})

test_that("result_index removes cash flows (TWR index)", {
  set.seed(4)
  d <- data.frame(date = seq.Date(as.Date("2010-01-01"), by = "day", length.out = 800),
                  ETF = 100 * cumprod(1 + rnorm(800, 3e-4, 0.01)))
  st <- create_strategy(ETF = asset_config("etf", "bnh", asset_spread = 0))
  r1 <- simulation(d, st, start_value = 1000)
  r2 <- simulation(d, st, start_value = 1000, dca_mode = TRUE, dca_value = 500, dca_span = 1)
  i1 <- result_index(r1); i2 <- result_index(r2)
  expect_equal(i1$value, 100 * d$ETF / d$ETF[1], tolerance = 1e-10)
  expect_equal(i2$value, i1$value, tolerance = 1e-10)        # Sparplan aendert die TWR nicht
  expect_gt(sum(i2$flows), 0)
  expect_error(result_index(list()), "SimLevResult")
})

test_that("a saved simulation() result drives the withdrawal phase", {
  set.seed(4)
  d <- data.frame(date = seq.Date(as.Date("1980-01-01"), as.Date("2019-12-31"), by = "day"))
  d$ETF <- 100 * cumprod(1 + rnorm(nrow(d), 3e-4, 0.01))
  res <- simulation(d, create_strategy(ETF = asset_config("etf", "bnh", asset_spread = 0)), start_value = 1e5)
  f <- tempfile(fileext = ".rds"); saveRDS(res, f); res <- readRDS(f)
  co <- withdrawal_cohorts(res, years = 25, step = "year", inflation = 2)
  expect_equal(nrow(co$returns), 25L)
  expect_equal(ncol(co$returns), 15L)
  idx <- result_index(res)
  ends <- SimLev:::.period_ends(idx$date, "month")
  expect_equal(co$returns[1, 1], idx$value[ends[13]] / idx$value[ends[1]], tolerance = 1e-12)
  w1 <- withdrawal_simulation(withdrawal_cohorts(res, years = 25, inflation = 2), withdrawal_rule("constant", rate = 4))
  w2 <- withdrawal_simulation(res, withdrawal_rule("constant", rate = 4), years = 25, inflation = 2)
  expect_equal(w1$paths$terminal_real, w2$paths$terminal_real)
  # Startvermoegen und Kostenbasis aus der Ansparphase
  acc <- simulation(d[1:3650, ], create_strategy(ETF = asset_config("etf", "bnh", asset_spread = 0)),
                    start_value = 1e4, dca_mode = TRUE, dca_value = 500, dca_span = 1)
  # Ansparphase ohne tax_mode = "person": keine offenen Lots, daher Naeherung mit Warnung
  expect_warning(withdrawal_simulation(res, withdrawal_rule("percent", rate = 4), years = 25, inflation = 2,
                                       start_value = acc, tax_mode = "person"), "cost_basis: N\u00e4herung")
  w3 <- suppressWarnings(withdrawal_simulation(res, withdrawal_rule("percent", rate = 4), years = 25, inflation = 2,
                                               start_value = acc, tax_mode = "person"))
  expect_equal(w3$start_value, tail(acc$worth, 1))
  expect_true(all(w3$paths$taxes > 0))
})

test_that("a list of simulation() results is used path by path", {
  set.seed(9)
  st <- create_strategy(ETF = asset_config("etf", "bnh", asset_spread = 0))
  dd <- seq.Date(as.Date("2000-01-01"), by = "day", length.out = 3660)
  runs <- lapply(1:4, function(k) simulation(data.frame(date = dd, ETF = 100 * cumprod(1 + rnorm(length(dd), 3e-4, 0.01))), st))
  wp <- withdrawal_paths(runs, inflation = 2)
  expect_equal(dim(wp$returns), c(10L, 4L))
  ws <- withdrawal_simulation(runs, withdrawal_rule("guyton_klinger", rate = 5), inflation = 2)
  expect_equal(nrow(ws$paths), 4L)
})

test_that("bootstrap_study with keep_returns feeds withdrawal_simulation", {
  set.seed(5); n <- 2000
  d <- data.frame(eq = 1 + rnorm(n, 3e-4, 0.01), cpi = 100 * 1.00006^(0:(n - 1)))
  cfg <- bootstrap_config(c(eq = "eq"), aux = c(cpi = "cpi"),
                          letfs = list(list(base = "eq", leverage = 2, finance = 2, expense = 0.5)))
  strats <- list(bnh = create_strategy(eq = asset_config("etf", "bnh")),
                 lev = create_strategy(eq_l2 = asset_config("etf", "bnh")))
  st <- bootstrap_study(d, cfg, "stationary", n = 6, strategies = strats, params = list(L = 50),
                        path_length = 365 * 12, burn_in = 30, seed = 3, keep_returns = "year",
                        keep_aux = "cpi", progress = FALSE)
  expect_equal(dim(st$returns$lev), c(11L, 6L))
  wp <- withdrawal_paths(st, strategy = "lev", inflation = "cpi")
  expect_equal(dim(wp$inflation), c(11L, 6L))
  ws <- withdrawal_simulation(st, withdrawal_rule("constant", rate = 4), strategy = "bnh", inflation = 2)
  expect_equal(nrow(ws$paths), 6L)
  # gespeicherte Rendite == Index der direkt gerechneten Simulation
  b <- bootstrap(d, cfg, "stationary", n = 6, params = list(L = 50), path_length = 365 * 12, seed = 3, progress = FALSE)
  df <- bootstrap_data(b, 2); df <- df[31:nrow(df), ]
  r <- simulation(df, strats$bnh)
  ix <- result_index(r)$value[SimLev:::.anniv_ends(df$date, "year")]
  expect_equal(st$returns$bnh[, 2], ix[-1] / ix[-length(ix)], tolerance = 1e-12)
  expect_error(withdrawal_paths(bootstrap_study(d, cfg, "raw", n = 2, strategies = strats[1], path_length = 400,
                                                seed = 1, progress = FALSE)), "keep_returns")
})
