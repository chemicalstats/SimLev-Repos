# Blue Team 4: Bootstrap, Entnahme, Planung, Parametersuche (Befunde R3-02, R3-07, R4-01 ... R4-19)

bp_study <- function() {
  set.seed(1); n <- 3 * 365
  d <- data.frame(date = seq.Date(as.Date("2015-01-01"), by = "day", length.out = n))
  d$aktien <- 100 * cumprod(1 + rnorm(n, 3e-4, 0.01))
  cfg <- bootstrap_config(c(akt = "aktien"), input = "prices", letfs = list(list(base = "akt", leverage = 2, finance = 2)))
  bootstrap_study(d, cfg, "stationary", n = 20, params = list(L = 30), path_length = 500, seed = 1, progress = FALSE,
    benchmark = "etf", strategies = list(etf = create_strategy(akt = asset_config("etf", "bnh")),
                                         letf = create_strategy(akt_l2 = asset_config("etf", "bnh"))))
}
bp_goal_R <- function() {
  set.seed(1)
  sapply(c(a20 = 0.2, a60 = 0.6, a100 = 1), function(a) exp(rnorm(300, 0.01 + 0.04 * a, 0.02 + 0.16 * a)))
}

test_that("R3-02/R4-15 .with_rng_restore: ohne seed laeuft der Strom weiter, mit seed reproduzierbar und Zustand erhalten", {
  f <- function(seed) SimLev:::.with_rng_restore(stats::runif(3), seed = seed)
  set.seed(42); a <- f(NULL); b <- f(NULL)
  expect_false(identical(a, b))                                    # vorher identisch
  set.seed(42); x <- f(7); y <- stats::runif(1)
  set.seed(42); z <- stats::runif(1)
  expect_identical(x, f(7)); expect_identical(y, z)                 # globaler Zustand unveraendert
  set.seed(42); u <- SimLev:::.with_rng_restore(stats::runif(1)); v <- stats::runif(1)
  expect_identical(u, v)                                            # ohne Argument: immer wiederherstellen (interne Stroeme)
  # pooled_bootstrap und goal_optimize ohne seed: wiederholte Aufrufe verschieden
  set.seed(1)
  land <- function(mu) { d <- data.frame(date = seq.Date(as.Date("1950-12-31"), by = "year", length.out = 70))
    d$aktien <- 100 * cumprod(exp(rnorm(70, mu, 0.18))); d }
  ds <- list(de = land(0.05), us = land(0.07))
  set.seed(42)
  p1 <- pooled_bootstrap(ds, "aktien", n = 50, L = 5); p2 <- pooled_bootstrap(ds, "aktien", n = 50, L = 5)
  expect_false(identical(p1$returns, p2$returns))
  expect_identical(pooled_bootstrap(ds, "aktien", n = 50, L = 5, seed = 3)$returns,
                   pooled_bootstrap(ds, "aktien", n = 50, L = 5, seed = 3)$returns)
  R <- bp_goal_R()[, c(1, 3)]
  g1 <- goal_optimize(R, 1e5, 1.5e5, 10, n_grid = 51, n_sim = 500)
  g2 <- goal_optimize(R, 1e5, 1.5e5, 10, n_grid = 51, n_sim = 500)
  expect_false(identical(g1$simulation, g2$simulation))
})

test_that("R3-07 plateau: unguenstigster Nachbar bei max_drawdown ist das Maximum", {
  x <- structure(list(results = data.frame(id = 1:4, n = c(10, 20, 30, 40), sharpe = c(1, 2, 3, 4),
                                           max_drawdown = c(0.1, 0.5, 0.2, 0.3), cagr = c(0.05, 0.02, 0.04, 0.01)),
                      params = "n", method = "grid", space = param_space(n = c(10, 20, 30, 40)),
                      objective = "sharpe", maximize = TRUE), class = "SimLevParamSearch")
  pl <- plateau(x, metric = "max_drawdown")
  expect_equal(pl$plateau_min, c(0.5, 0.5, 0.5, 0.3))              # vorher Minimum 0.1, 0.1, 0.2, 0.2
  expect_equal(plateau(x, metric = "cagr")$plateau_min, c(0.02, 0.02, 0.01, 0.01))
  expect_equal(plateau(x)$plateau_min, c(1, 1, 2, 3))
  x$maximize <- FALSE; x$objective <- "max_drawdown"
  expect_equal(plateau(x)$plateau_min, c(0.5, 0.5, 0.5, 0.3))
})

test_that("R4-01 Niveau-Zusatzreihen: Inflation aus kumulierten Zeilenverhaeltnissen statt Spruengen", {
  set.seed(1); n <- 6 * 365
  d <- data.frame(us = 1 + rnorm(n, 3e-4, 0.01))
  d$cpi <- 100 * 1.02^(seq_len(n) / 365); d$zins <- 2
  cfg <- bootstrap_config(c(us = "us"), aux = c(cpi = "cpi", zins = "zins"))
  b <- bootstrap(d, cfg, "stationary", n = 5, params = list(L = 100), path_length = 3 * 365 + 1, seed = 1, progress = FALSE)
  wp <- withdrawal_paths(b, column = "us", inflation = "cpi", inflation_type = "level")
  expect_true(all(abs(wp$inflation - 1.02) < 1e-3))                # vorher 0,6 bis 1,7
  expect_equal(b$paths[[1]][, "zins"], rep(2, 3 * 365 + 2))       # Raten bleiben Originalwerte
  wr <- withdrawal_paths(b, column = "us", inflation = "zins", inflation_type = "rate_pa")
  expect_true(all(abs(wr$inflation - 1.02) < 1e-3))
  # ohne Niveau-Variante: klarer Fehler bei nicht chronologischen Verfahren
  b0 <- b; b0$paths <- lapply(b0$paths, function(p) { attr(p, "aux_level") <- NULL; p })
  expect_error(withdrawal_paths(b0, column = "us", inflation = "cpi"), "Blockgrenzen")
  # chronologisches Verfahren: Niveau-Variante = Originalwerte
  bw <- bootstrap(d, cfg, "wild", n = 2, seed = 1, progress = FALSE)
  expect_equal(unname(attr(bw$paths[[1]], "aux_level")[-1, "cpi"]), unname(bw$paths[[1]][-1, "cpi"]), tolerance = 1e-12)
  # bootstrap_study(keep_aux) auf Kursniveaus
  dd <- data.frame(date = seq.Date(as.Date("1990-01-01"), by = "day", length.out = n), us = 100 * cumprod(d$us), cpi = d$cpi)
  st <- bootstrap_study(dd, bootstrap_config(c(us = "us"), aux = c(cpi = "cpi"), input = "prices"), "stationary",
    n = 4, params = list(L = 100), path_length = 3 * 365 + 1, seed = 1, progress = FALSE,
    keep_returns = "year", keep_aux = "cpi", strategies = list(bnh = create_strategy(us = asset_config("etf", "bnh"))))
  expect_true(all(abs(st$aux_returns$cpi - 1.02) < 1e-3))
  expect_true(all(abs(withdrawal_paths(st, inflation = "cpi")$inflation - 1.02) < 1e-3))
})

test_that("R4-02 withdrawal_cohorts prueft das Monatsraster", {
  d <- data.frame(date = seq.Date(as.Date("1900-12-31"), by = "year", length.out = 120))
  d$depot <- 100 * 1.05^(0:119)
  expect_error(withdrawal_cohorts(d, price = "depot", years = 5, step = "year"), "Jahresdaten")
  m <- data.frame(date = seq.Date(as.Date("1990-02-01"), by = "month", length.out = 241) - 1)
  m$depot <- 100 * 1.05^((0:240) / 12)
  ok <- withdrawal_cohorts(m, price = "depot", years = 10, step = "year")
  expect_equal(range(ok$returns), c(1.05, 1.05), tolerance = 1e-12)
  expect_error(withdrawal_cohorts(m[-50, ], price = "depot", years = 10, step = "year"), "l\u00fcckenlose Monatsdaten")
})

test_that("R4-03/R4-13 horizon_model: Einzelwerte und triangular-Grenzfaelle", {
  expect_equal(unique(SimLev:::.draw_horizon(horizon_model("uniform", min = 30, max = 30), 500)), 30L)
  expect_equal(unique(SimLev:::.draw_horizon(horizon_model("sample", years = 25), 500)), 25L)
  expect_equal(unique(SimLev:::.draw_horizon(horizon_model("discrete", years = 30, prob = 1), 500)), 30L)
  expect_output(print(horizon_model("discrete", years = 30, prob = 1)), "Bereich 30 bis 30")
  expect_equal(unique(SimLev:::.draw_horizon(horizon_model("triangular", min = 30, mode = 30, max = 30), 100)), 30L)
  expect_error(horizon_model("triangular", min = 20, mode = 50, max = 30), "mode")
  # gueltige Eingaben unveraendert (gleiche Ziehung wie sample())
  h <- horizon_model("uniform", min = 20, max = 30)
  set.seed(h$seed); ref <- sample(20:30, 100, replace = TRUE)
  expect_identical(SimLev:::.draw_horizon(h, 100), as.integer(ref))
  set.seed(1); R <- matrix(exp(rnorm(40 * 50, 0.04, 0.15)), 40)
  ws <- withdrawal_simulation(R, withdrawal_rule("constant"), inflation = 2, horizon = horizon_model("uniform", min = 30, max = 30))
  expect_equal(unique(ws$paths$horizon), 30L)
})

test_that("R4-04/R4-11 withdrawal_simulation: Dimensionen von base_rate/inflation, inflation = NULL", {
  R <- matrix(1.06, 30, 3)
  expect_error(withdrawal_simulation(R, withdrawal_rule("constant", rate = 4), tax_mode = "person", base_rate = matrix(2.5, 1, 1)),
               "base_rate als Matrix")
  ref <- withdrawal_simulation(R, withdrawal_rule("constant", rate = 4), tax_mode = "person", base_rate = 2.5)
  full <- withdrawal_simulation(R, withdrawal_rule("constant", rate = 4), tax_mode = "person", base_rate = matrix(2.5, 30, 3))
  expect_equal(full$paths, ref$paths)
  expect_error(withdrawal_simulation(matrix(1.04, 30, 3), withdrawal_rule("constant"), inflation = matrix(1.02, 30, 1)),
               "dieselbe Dimension")
  expect_error(SimLev:::.wd_simulate(R, matrix(1, 30, 1), matrix(0, 30, 0), matrix(2.5, 30, 3), 1L, 1L,
                                     SimLev:::.wd_param_vector(withdrawal_rule("constant")), TRUE, 1e6, rep(0, 30),
                                     FALSE, 0.26375, 0.3, 1000, TRUE, 0, 1, 0, TRUE), "Inflationsmatrix")
  a <- withdrawal_simulation(matrix(1.04, 30, 5), withdrawal_rule("constant"), inflation = NULL)
  b <- withdrawal_simulation(matrix(1.04, 30, 5), withdrawal_rule("constant"), inflation = 0)
  expect_equal(a$paths, b$paths)
})

test_that("R4-05 income: Jahre nach Pfadende ohne Wirkung, end < start Fehler, Einzeleinkommen", {
  R <- matrix(1.00, 10, 1)
  w <- function(inc) withdrawal_simulation(R, withdrawal_rule("constant", rate = 4), start_value = 1e6, income = inc)$wealth[, 1]
  expect_equal(w(list(list(start = 12, amount = 10000))), w(NULL))  # vorher Rente in Jahr 10
  expect_error(w(list(list(start = 5, end = 3, amount = 10000))), "start <= end")
  expect_equal(w(list(start = 3, end = 5, amount = 1000)), w(list(list(start = 3, end = 5, amount = 1000))))
  expect_equal(w(list(list(start = 3, end = 5, amount = 10000)))[7], 1e6 - 6 * 40000 + 3 * 10000)
})

test_that("R4-06/R4-09 summary p_better bei dd_q50/dd_q90 und bootstrap_probability-Umgebung", {
  st <- bp_study()
  pr <- summary(st, metrics = c("max_drawdown", "dd_q50", "dd_q90"))$paired
  tab <- st$results; l <- tab[tab$strategy == "letf", ]; e <- tab[tab$strategy == "etf", ]
  expect_equal(pr$p_better[pr$metric == "dd_q50"], mean(l$dd_q50 < e$dd_q50))
  expect_equal(pr$p_better[pr$metric == "dd_q90"], mean(l$dd_q90 < e$dd_q90))
  thr <- 0.5; X <- 0.5
  ref <- bootstrap_probability(st, cagr > thr)$probability
  expect_equal(bootstrap_probability(st, cagr > X)$probability, ref)          # vorher 0 (lapply-Variable X)
  f <- function(s) { lim <- 0.5; bootstrap_probability(s, cagr > lim) }
  expect_equal(f(st)$probability, ref)                                        # vorher Fehler
})

test_that("R4-07/R4-17 goal_optimize: stufentreue Wahrscheinlichkeiten, Gleichstand, Pruefungen", {
  R <- bp_goal_R()
  mc <- function(k, sv, goal, h, cf = 0, N = 100000) { set.seed(11); W <- rep(sv, N); alive <- rep(TRUE, N)
    for (t in 1:h) { b <- W + cf; alive <- alive & b > 0; W <- ifelse(alive, b * R[sample.int(nrow(R), N, TRUE), k], 0) }
    mean(alive & W >= goal) }
  g <- goal_optimize(R, 1e5, 1.5e5, 10, n_sim = 20000, seed = 1)
  expect_lt(max(abs(unname(g$static) - sapply(1:3, mc, 1e5, 1.5e5, 10))), 0.006)   # vorher 0.115 statt 0.094
  expect_lt(max(abs(g$probability - mean(g$simulation$success))), 0.015)
  g2 <- goal_optimize(R, 1e5, 0, 20, contributions = -8000, n_sim = 20000, seed = 1)
  expect_lt(max(abs(unname(g2$static[1]) - mc(1, 1e5, 0, 20, -8000))), 0.003)      # vorher 0.026 statt 0.005
  expect_lt(max(abs(g2$probability - mean(g2$simulation$success))), 0.015)        # vorher 0.450 vs 0.424
  # Gleichstand: Kandidat mit geringster Streuung
  g3 <- goal_optimize(R, 2e5, 1e5, 10, n_grid = 101, n_sim = 2000, seed = 1)
  expect_equal(g3$candidates[g3$policy[10, which(g3$grid > 1e6)[1]]], "a20")
  expect_equal(g3$candidates[g3$policy[1, which(g3$grid < 200)[1]]], "a20")
  expect_error(goal_optimize(R, 0, 1e5, 10), "start_value")
  expect_error(goal_optimize(R, 1e5, 1.5e5, 0), "horizon muss eine ganze Zahl")
})

test_that("R4-08/R4-19 set_expected_return: unsortierte Kurse, fehlende Zielspalte", {
  set.seed(1)
  p <- data.frame(date = seq.Date(as.Date("2000-01-01"), by = "day", length.out = 3650))
  p$us <- 100 * cumprod(exp(rnorm(3650, 3e-4, 0.01)))
  o <- sample(nrow(p)); ps <- p[o, ]
  y <- set_expected_return(ps, "us", 4, type = "prices")
  ys <- set_expected_return(p, "us", 4, type = "prices")
  expect_equal(y$us, ys$us[o])                                     # gleiche Zeilenreihenfolge wie Eingabe
  expect_equal((ys$us[3650] / ys$us[1])^(365.25 / 3649) - 1, 0.04, tolerance = 1e-10)
  expect_error(set_expected_return(data.frame(us = rep(1.001, 10), eu = 1.001), c("us", "eu"), c(us = 4)), "fehlt f\u00fcr: eu")
})

test_that("R4-10 pooled_bootstrap: unbenannte und falsch benannte Gewichte", {
  set.seed(1)
  land <- function(mu) { d <- data.frame(date = seq.Date(as.Date("1950-12-31"), by = "year", length.out = 70))
    d$aktien <- 100 * cumprod(exp(rnorm(70, mu, 0.18))); d$anleihen <- 100 * cumprod(exp(rnorm(70, 0.02, 0.06))); d }
  ds <- list(de = land(0.05), us = land(0.07))
  p <- pooled_bootstrap(ds, c("aktien", "anleihen"), weights = c(0.6, 0.4), n = 5, L = 5, seed = 1)
  q <- pooled_bootstrap(ds, c("aktien", "anleihen"), weights = c(aktien = 0.6, anleihen = 0.4), n = 5, L = 5, seed = 1)
  expect_equal(p$returns, q$returns); expect_equal(dim(p$returns), c(30L, 5L))
  expect_error(pooled_bootstrap(ds, c("aktien", "anleihen"), weights = c(aktien = 0.6, bonds = 0.4), n = 5, L = 5, seed = 1), "weights")
  expect_error(pooled_bootstrap(ds, c("aktien", "anleihen"), weights = 1, n = 5, L = 5, seed = 1), "weights")
})

test_that("R4-12 withdrawal_paths prueft dates", {
  set.seed(2)
  b <- bootstrap(data.frame(us = 1 + rnorm(2600, 3e-4, 0.01)), bootstrap_config(c(us = "us")), "stationary",
                 n = 3, params = list(L = 50), path_length = 2520, seed = 1, progress = FALSE)
  td <- seq.Date(as.Date("2000-01-03"), by = "day", length.out = 4000); td <- td[!format(td, "%u") %in% c("6", "7")][1:2521]
  ok <- withdrawal_paths(b, column = "us", dates = td)
  expect_equal(nrow(ok$returns), 9L)
  expect_error(withdrawal_paths(b, column = "us", dates = td[1:1000]), "L\u00e4nge 1000")
  expect_error(withdrawal_paths(b, column = "us", dates = c(td, td + 4000)), "L\u00e4nge 5042")
  expect_equal(withdrawal_paths(b, column = "us", dates = as.character(td))$returns, ok$returns)
  expect_error(withdrawal_paths(b, column = "us", dates = rev(td)), "aufsteigend")
})

test_that("R4-14 withdrawal_max_rate bricht bei Regeln ohne rate ab", {
  set.seed(1); R <- matrix(exp(rnorm(30 * 50, 0.04, 0.15)), 30)
  for (ty in c("vpw", "abw", "one_over_n", "hebeler", "cape"))
    expect_error(withdrawal_max_rate(R, withdrawal_rule(ty), success = 0.9, inflation = 2), "nutzt rate nicht")
  expect_true(is.finite(withdrawal_max_rate(R, withdrawal_rule("constant"), success = 0.9, inflation = 2)))
})

test_that("R4-16 bootstrap: Parameter vorab geprueft, Knockout-Rate konsistent", {
  set.seed(5); d <- data.frame(us = 1 + rnorm(1000, 3e-4, 0.01)); cfg <- bootstrap_config(c(us = "us"))
  expect_error(bootstrap(d, cfg, "stationary", n = 2, params = list(L = 0.5), seed = 1, progress = FALSE), "params\\$L")
  expect_error(bootstrap(d, cfg, "reset", n = 2, params = list(p_break = 2), seed = 1, progress = FALSE), "p_break")
  expect_error(bootstrap(d[1:50, , drop = FALSE], cfg, "block", n = 5, params = list(block_length = 500), seed = 1, progress = FALSE),
               "block_length")
  expect_error(bootstrap(d, cfg, "wild", n = 1, params = list(wild_type = 7), seed = 1, progress = FALSE), "wild_type")
  expect_error(bootstrap(d, cfg, "stationary", n = 1, path_length = 0, seed = 1, progress = FALSE), "path_length")
  d2 <- d; d2$us[c(5, 500)] <- Inf
  expect_error(bootstrap(d2, cfg, "raw", n = 2, seed = 1, progress = FALSE), "nicht endliche")
  expect_error(SimLev:::.boot_idx_block(50L, 100L, 500L, FALSE), "gr\u00f6\u00dfer als die Historie")   # Meldung aus C++ (bootstrap_core.cpp)
  # Knockout: Wild-Bootstrap mit einem Ausreisser (2 * mu - 3 < 0) -> etwa die Haelfte der Versuche ungueltig
  dk <- data.frame(us = c(rep(1, 199), 3))
  b <- bootstrap(dk, cfg, "wild", n = 40, seed = 1, max_tries = 1, progress = FALSE)
  expect_lt(length(b$paths), 40)
  expect_equal(b$knockout_rate, 100 * b$stats$knockout_rate)      # vorher 0 % gegenueber stats 0.6
  expect_equal(b$stats$knockout_rate, (40 - length(b$paths)) / 40)
})

test_that("R4-18 summary.SimLevWithdrawal: kein Konsum nach dem Horizont, Rumpfjahr nicht als volles Jahr", {
  set.seed(1); R <- matrix(exp(rnorm(30 * 100, 0.03, 0.1)), 30)
  s <- summary(withdrawal_simulation(R, withdrawal_rule("constant"), horizon = 10))
  expect_true(all(is.na(s$spending_by_year[c("Jahr 20", "Jahr 30"), ])))
  expect_false(anyNA(s$spending_by_year[c("Jahr 1", "Jahr 10"), ]))
  w <- suppressWarnings(withdrawal_simulation(matrix(1.01, 5, 1), frequency = "quarter"))
  expect_equal(w$full_years, 1L)
  expect_equal(unlist(w$paths[, c("mean_spending", "min_spending", "spending_drawdown")]),
               c(mean_spending = 40000, min_spending = 40000, spending_drawdown = 0))
  expect_equal(w$paths$total_spending, 50000)                       # Rumpfjahr zaehlt in der Summe
})

test_that("R4-19 klare Meldungen bei ung\u00fcltigen Eingaben", {
  expect_error(withdrawal_simulation(matrix(1.03, 10, 2), years = 0), "years muss eine positive Zahl")
  expect_error(param_range(1, 2, n = 0), "n \\(Anzahl Rasterpunkte\\)")
  d <- data.frame(date = seq.Date(as.Date("1990-02-01"), by = "month", length.out = 360) - 1); d$p <- 100 * 1.004^(0:359)
  expect_error(withdrawal_cohorts(d, price = "p", years = 2.5, frequency = "year"), "ganze Jahre")
  expect_equal(dim(withdrawal_cohorts(d, price = "p", years = 2.5, frequency = "quarter")$returns), c(10L, 330L))
})
