# Tests Review 7 (Planung/Entnahme): B7-01 bis B7-04, B7-06 bis B7-08

# Referenz zur Entnahmephase (Durchschnittskosten, Entnahme zu Jahresbeginn, Steuer 26,375 %, TFS 30 %):
# Vorabpauschale des Jahres y gilt am ersten Werktag von y + 1 als zugeflossen und wird mit Verlusttopf und
# Pauschbetrag von y + 1 versteuert; die VP des letzten Jahres wird am Pfadende so abgerechnet (Verkauf aus dem Depot)
.r7_ref <- function(R, rate = 0.04, sv = 1e5, basis = sv, tfs = 0.3, tr = 0.26375, spb = 1000, spb1 = spb, br = 0.032) {
  n <- sv; u <- 1; W <- rate * sv; vp_prev <- 0; taxes <- 0; loss <- 0; pot <- 0
  tx <- function(g) { t <- g * (1 - tfs); if (t <= 0) { loss <<- loss - t; return(0) }
    a <- min(loss, t); loss <<- loss - a; t <- t - a; a <- min(pot, t); pot <<- pot - a; (t - a) * tr }
  sell <- function(target) {                  # Brutto G mit G - Steuer = target (Durchschnittskosten)
    V <- n * u; peek <- function(G) max(0, (G - basis * G / V) * (1 - tfs) - loss - pot) * tr
    G <- uniroot(function(G) G - peek(G) - target, c(0, V), tol = 1e-13)$root
    t <- tx(G - basis * G / V); basis <<- basis - basis * G / V; n <<- n - G / u; t
  }
  for (y in seq_along(R)) {
    pot <- if (y == 1) spb1 else spb
    vtax <- if (vp_prev > 0) tx(vp_prev) else 0
    taxes <- taxes + vtax + sell(W + vtax)
    u0 <- u; u <- u * R[y]
    vp_prev <- n * min(u0 * 0.7 * br, u - u0); basis <- basis + vp_prev
  }
  # Pfadende (R8-03, wie simulation()): VP-Steuer mit den Toepfen des Folgejahres, Zwangsverkauf im ablaufenden Jahr
  pot_last <- pot; loss_last <- loss
  pot <- spb; vtax <- tx(vp_prev)
  pot <- pot_last; loss <- loss_last
  taxes <- taxes + vtax + sell(vtax)
  c(taxes = taxes, end = n * u)
}

test_that("B7-01: Vorabpauschale mit den Toepfen des Folgejahres, letzte VP am Pfadende", {
  R <- matrix(1.10, 3, 1)
  ws <- withdrawal_simulation(R, withdrawal_rule("constant", rate = 4), start_value = 1e5, tax_mode = "person",
                              base_rate = 3.2, cost_basis = 100)
  ref <- .r7_ref(R[, 1])
  expect_equal(ws$paths$taxes, ref[["taxes"]], tolerance = 1e-10)               # 636,04 (vorher 342,98)
  expect_equal(ws$paths$terminal_nominal, ref[["end"]], tolerance = 1e-10)
  expect_equal(ws$wealth[4, 1], ref[["end"]], tolerance = 1e-10)                # Endvermoegen nach der VP-Abrechnung
  # Anteil ohne die VP des letzten Jahres = Referenzwert des Befunds (449,43 statt 342,98)
  ws2 <- withdrawal_simulation(matrix(c(1.1, 1.1, 1.1, 1), 4, 1), withdrawal_rule("constant", rate = 4), start_value = 1e5,
                               tax_mode = "person", base_rate = 3.2, cost_basis = 100, years = 3)
  expect_gt(ws2$paths$taxes, 449.4)
  # mit Verlusttopf und Pauschbetrag 0 im Folgejahr; ohne VP unveraendert
  expect_equal(withdrawal_simulation(R, withdrawal_rule("constant", rate = 4), start_value = 1e5, tax_mode = "person", base_rate = 3.2,
                                     cost_basis = 100, sparer_pauschbetrag = 0)$paths$taxes,
               .r7_ref(R[, 1], spb = 0)[["taxes"]], tolerance = 1e-10)
  # Zusammenspiel mit next_year: erstes Planjahr mit Rest-Pauschbetrag, die eigene VP des ersten Jahres mit vollem Pauschbetrag
  d <- data.frame(date = seq.Date(as.Date("2015-01-01"), as.Date("2019-12-31"), by = "day"))
  d$A <- 100 * 1.08^(as.numeric(d$date - d$date[1]) / 365.25)
  r <- simulation(d, create_strategy(A = asset_config("etf", "bnh", asset_spread = 0, asset_bonus = 30)),
                  start_value = 1e5, tax_mode = "person", base_rate = 3.2)
  ny <- r$tax_report$next_year; sv <- tail(r$worth, 1)
  expect_gt(ny$sparer_pauschbetrag_used, 0)
  B <- with(r$open_lots$A, sum(lots$units * lots$price) + sum(lots$vp) + cash)
  w <- suppressMessages(withdrawal_simulation(R, withdrawal_rule("constant", rate = 4), start_value = r, tax_mode = "person", base_rate = 3.2))
  expect_equal(w$paths$taxes, .r7_ref(R[, 1], sv = sv, basis = B, spb1 = ny$sparer_pauschbetrag_remaining)[["taxes"]], tolerance = 1e-9)
})

test_that("B7-02: lumpsum_vs_dca schreibt das DCA-Depot \u00fcber Stueckzahlen fort (exakt ohne Steuern)", {
  d <- data.frame(date = seq.Date(as.Date("2010-01-01"), as.Date("2016-12-31"), by = "day"))
  t <- seq_len(nrow(d))
  d$A <- 100 * ifelse(t <= 365, exp(t / 365 * log(2)), 2)                      # A steigt im ersten Jahr, dann flach
  d$B <- 100 * ifelse(t <= 365, 1, exp((t - 365) / 365 * log(1.5)))           # B umgekehrt
  st <- create_strategy(A = asset_config("etf", "bnh", asset_share = 0.5, asset_spread = 0),
                        B = asset_config("etf", "bnh", asset_share = 0.5, asset_spread = 0))
  x <- suppressWarnings(lumpsum_vs_dca(d, st, amount = 12000, months = 12, horizon = 5, step = 100))
  expect_true(all(x$exact))
  # Handrechnung: 12 Raten zu 1000 am Monatsersten, je 500 in A und B, danach halten
  ref <- function(s, h, wA = 0.5) { e <- seq.Date(s, by = paste(h, "years"), length.out = 2)[2] - 1
    ia <- match(seq.Date(s, by = "month", length.out = 12), d$date); ie <- match(e, d$date)
    c(dca = sum(1000 * wA / d$A[ia]) * d$A[ie] + sum(1000 * (1 - wA) / d$B[ia]) * d$B[ie],
      ls = 12000 * wA / d$A[ia[1]] * d$A[ie] + 12000 * (1 - wA) / d$B[ia[1]] * d$B[ie]) }
  r1 <- ref(x$start[1], 5)
  expect_equal(x$dca[1], r1[["dca"]], tolerance = 1e-10)                        # vorher 39294 statt 39314 (Index der Einmalanlage)
  expect_equal(x$lump_sum[1], r1[["ls"]], tolerance = 1e-10)
  # Zufallsdaten 60/40: jede Startzeile exakt
  set.seed(5)
  d <- data.frame(date = seq.Date(as.Date("2000-01-01"), as.Date("2009-12-31"), by = "day")); n <- nrow(d)
  d$A <- 100 * exp(cumsum(rnorm(n, 3e-4, 0.012))); d$B <- 100 * exp(cumsum(rnorm(n, 1e-4, 0.004)))
  st <- create_strategy(A = asset_config("etf", "bnh", asset_share = 0.6, asset_spread = 0),
                        B = asset_config("etf", "bnh", asset_share = 0.4, asset_spread = 0))
  x <- suppressWarnings(lumpsum_vs_dca(d, st, amount = 12000, months = 12, horizon = 5, step = 12))
  expect_equal(x$dca, vapply(x$start, function(s) ref(s, 5, 0.6)[["dca"]], 0), tolerance = 1e-10)
  # Strategie mit Rebalancing: Naeherung ueber den Index der Einmalanlage, gekennzeichnet
  xr <- suppressWarnings(lumpsum_vs_dca(d, st, amount = 12000, months = 12, horizon = 5, step = 24,
                                        sim_args = list(balance_mode = TRUE, balance_span = 12)))
  expect_false(any(xr$exact))
  expect_identical(names(x), c("start", "lump_sum", "dca", "advantage", "exact"))
})

test_that("B7-03: goal_optimize meldet die erreichte Erfolgsquote der Politik, DP-Wert getrennt", {
  exact <- function(W, t, H, R, goal, cf) {
    if (t > H) return(as.numeric(W >= goal))
    b <- W + cf[t]; if (b <= 0) return(0)
    max(sapply(seq_len(ncol(R)), function(k) mean(sapply(R[, k], function(r) exact(b * r, t + 1, H, R, goal, cf)))))
  }
  set.seed(3)
  for (case in 1:3) {
    S <- 5; R <- cbind(safe = exp(rnorm(S, 0.02, 0.01)), mid = exp(rnorm(S, 0.04, 0.1)), risky = exp(rnorm(S, 0.06, 0.25)))
    goal <- runif(1, 105, 140)
    if (case == 3) {
      g <- suppressWarnings(goal_optimize(R, 100, goal, 4, n_grid = 301, n_sim = 20000, seed = 1))
      ex <- exact(100, 1, 4, R, goal, rep(0, 4))
      expect_equal(g$probability, mean(g$simulation$success))
      expect_equal(g$probability_se, sqrt(g$probability * (1 - g$probability) / 20000))
      expect_gt(g$probability_dp, ex)                                          # DP 0,9015 > Optimum 0,8768 (Verzerrung)
      expect_lte(g$probability, ex + 2 * g$probability_se)                      # erreichte Quote 0,8571
    }
  }
  out <- capture.output(print(g))
  expect_true(any(grepl("Vorw\u00e4rtssimulation, SE .* DP-Wert 90.1 %", out)))
})

test_that("B7-04: + k Monate auf das Monatsende begrenzt (align_macro, walk_forward, .anniv_ends)", {
  am <- SimLev:::.add_months
  expect_equal(am(as.Date("2024-01-31"), 1), as.Date("2024-02-29"))
  expect_equal(am(as.Date("2023-01-31"), 1), as.Date("2023-02-28"))
  expect_equal(am(as.Date("2024-02-29"), 12), as.Date("2025-02-28"))
  expect_equal(am(as.Date("2024-03-31"), -1), as.Date("2024-02-29"))
  expect_equal(am(as.Date(c("2024-01-15", "2024-12-31")), c(1, 2)), as.Date(c("2024-02-15", "2025-02-28")))
  # align_macro: Monatswert ab Referenzdatum + 1 Monat (vorher 31.01. -> 02.03.)
  m <- data.frame(date = as.Date(c("2023-12-31", "2024-01-31", "2024-02-29", "2024-03-31", "2024-04-30")), cpi = 1:5)
  d <- data.frame(date = seq.Date(as.Date("2024-01-25"), as.Date("2024-06-05"), by = "day"))
  a <- align_macro(d, m, "cpi", lag = 1, lag_unit = "month")
  expect_equal(as.Date(vapply(1:5, function(k) min(a$date[a$cpi %in% k]), 0)),
               as.Date(c("2024-01-31", "2024-02-29", "2024-03-29", "2024-04-30", "2024-05-30")))
  expect_equal(a$cpi[a$date == as.Date("2024-03-01")], 2)
  # Periodenenden ab dem 31.01.: 29.02., 31.03., 30.04. (vorher 02.03., 31.03., 01.05.)
  dts <- seq.Date(as.Date("2000-01-31"), by = "day", length.out = 401)
  expect_equal(dts[SimLev:::.anniv_ends(dts, "month")][1:5], as.Date(c("2000-01-31", "2000-02-29", "2000-03-31", "2000-04-30", "2000-05-31")))
  expect_equal(dts[SimLev:::.anniv_ends(dts, "quarter")][1:3], as.Date(c("2000-01-31", "2000-04-30", "2000-07-31")))
  b <- structure(list(paths = list(matrix(100 * cumprod(c(1, rep(1.001, 400))), ncol = 1, dimnames = list(NULL, "x"))),
                      weights = 1, config = list(), method = "stationary"), class = "bootstrap_result")
  wp <- withdrawal_paths(b, column = "x", frequency = "month", start_date = "2000-01-31")
  expect_equal(round(log(wp$returns[1:4, 1]) / log(1.001)), c(29, 31, 30, 31))   # Tage je Periode
  # unveraendert fuer Starttage <= 28
  d2 <- seq.Date(as.Date("2000-01-15"), by = "day", length.out = 800)
  expect_equal(SimLev:::.anniv_ends(d2, "month"), unique(findInterval(as.numeric(seq.Date(d2[1], d2[800], by = "1 month")), as.numeric(d2))))
  # walk_forward: Fenstergrenzen vom 30.01. an
  set.seed(1); n <- 2 * 365
  dd <- data.frame(date = seq.Date(as.Date("2010-01-30"), by = "day", length.out = n)); dd$A <- 100 * cumprod(1 + rnorm(n, 3e-4, 0.01))
  st <- create_strategy(A = asset_config("etf", "signal", signal_buy = "buy", signal_sell = "sell"))
  ps <- param_search(dd, function(p) list(strategy = st, signal = function(df) signal_sma(df$A, p$n)), param_space(n = c(10, 20)))
  wf <- walk_forward(ps, train = 1 / 12, test = 1 / 12)
  expect_equal(wf$windows$test_start[1], as.Date("2010-02-28"))                # 31.01. + 1 Monat (vorher 03.03.)
})

test_that("B7-06: withdrawal_max_rate prueft success, lower/upper, tol und rechnet jede Rate einmal", {
  set.seed(1); R <- matrix(exp(rnorm(30 * 100, 0.05, 0.15)), 30)
  expect_error(withdrawal_max_rate(R, success = 95, inflation = 2), "success muss ein Anteil .*gemeint vermutlich 0.95")
  expect_error(withdrawal_max_rate(R, success = 0, inflation = 2), "0 < success <= 1")
  expect_error(withdrawal_max_rate(R, lower = 10, upper = 2, inflation = 2), "0 <= lower < upper <= 100")
  expect_error(withdrawal_max_rate(R, upper = 150, inflation = 2), "lower = 0.5, upper = 150")
  expect_error(withdrawal_max_rate(R, success = 0.9, inflation = 2, tol = 0), "tol muss eine Zahl > 0")
  calls <- 0L; orig <- SimLev::withdrawal_simulation
  local_mocked_bindings(withdrawal_simulation = function(...) { calls <<- calls + 1L; orig(...) }, .package = "SimLev")
  r <- withdrawal_max_rate(R, success = 0.9, inflation = 2, tol = 0.1)
  n_bis <- ceiling(log2((20 - 0.5) / 0.1))
  expect_equal(calls, 2L + n_bis)                                              # lower, upper, je Halbierung einmal (vorher +3)
  expect_gte(attr(r, "success"), 0.9)
})

test_that("B7-07: Bereichs- und Prozent/Anteil-Pruefungen in withdrawal_simulation, horizon_model, perfect_withdrawal_rate", {
  set.seed(1); R <- matrix(exp(rnorm(10 * 20, 0.05, 0.15)), 10)
  f <- function(...) withdrawal_simulation(R, ...)
  expect_warning(f(tax_mode = "person", tax_rate = 0.26375), "tax_rate = 0.26375 wird als 0.26375 % gelesen")
  expect_error(f(tax_mode = "person", tax_rate = -5), "'tax_rate' muss eine Zahl von 0 bis 100")
  expect_warning(f(tax_mode = "person", asset_bonus = 0.3), "asset_bonus = 0.3 wird als")
  expect_error(f(tax_mode = "person", asset_bonus = 130), "'asset_bonus' muss")
  expect_error(f(tax_mode = "person", cost_basis = -10), "'cost_basis' muss eine Zahl >= 0")
  expect_error(f(tax_mode = "person", sparer_pauschbetrag = -1000), "'sparer_pauschbetrag' muss")
  expect_error(f(tax_mode = "person", sparer_pauschbetrag = c(1000, 2000)), "'sparer_pauschbetrag' muss")
  expect_error(f(loss_carryforward = NA), "'loss_carryforward' muss")
  expect_error(f(gamma = -1), "'gamma' muss")
  expect_error(f(keep_paths = NA), "'keep_paths' muss TRUE oder FALSE")
  expect_warning(f(inflation = 0.02), "inflation = 0.02 wird als 0.02 % p. a. gelesen")
  expect_error(f(inflation = -100), "'inflation' muss")
  expect_warning(f(tax_mode = "person", base_rate = 0.032), "base_rate = 0.032 wird als")
  expect_error(f(horizon = 0), "'horizon' muss NULL, ein Objekt aus horizon_model\\(\\) oder eine Zahl von Jahren > 0")
  expect_error(f(horizon = -5), "'horizon' muss")
  expect_error(horizon_model("fixed", years = 0), "years muss > 0 sein")
  expect_error(horizon_model("uniform", min = 0, max = 30), "min muss > 0 sein")
  expect_error(horizon_model("discrete", years = c(20, -1), prob = c(1, 1)), "years muss > 0 sein")
  expect_silent(f(horizon = 5)); expect_silent(f(tax_mode = "person", tax_rate = 0))
  expect_error(perfect_withdrawal_rate(c(0.05, 0.02, -0.1)), "sieht nicht wie Brutto-Renditen aus")
  expect_error(perfect_withdrawal_rate(c(1.05, NA)), "Brutto-Jahresrenditen")
  expect_error(perfect_withdrawal_rate(c(1.05, 1.1, -0.2)), "m\u00fcssen >= 0 sein")
  expect_error(perfect_withdrawal_rate(c(1.05, 1.02), legacy = -1), "legacy muss ein Anteil >= 0")
  expect_equal(perfect_withdrawal_rate(c(1.05, 1.02, 0.9)), 100 / sum(rev(cumprod(rev(c(1.05, 1.02, 0.9))))) * prod(c(1.05, 1.02, 0.9)))
})

test_that("B7-08: withdrawal_rule prueft alle Parameter (Skalar, NA, Bereich) und warnt bei Anteilen", {
  expect_error(withdrawal_rule("constant", rate = c(4, 5)), "rate muss zwischen 0 und 100 Prozent liegen .*erhalten: 4, 5")
  expect_error(withdrawal_rule("constant", rate = NA), "rate muss zwischen")
  expect_error(withdrawal_rule("endowment", smoothing = NA), "smoothing muss NULL oder eine Zahl von 0 bis 100")
  expect_error(withdrawal_rule("vpw", age = 70, max_age = 65), "age \\(70\\) muss kleiner als max_age \\(65\\)")
  expect_silent(withdrawal_rule("constant", age = 70, max_age = 65))           # ungenutzt bei anderen Regeln
  expect_error(withdrawal_rule("constant", min_real = 5e4, max_real = 1e4), "min_real \\(50000\\) darf nicht gr\u00f6\u00dfer als max_real")
  expect_error(withdrawal_rule("clyatt", floor95 = 150), "floor95 muss eine Zahl von 0 bis 100")
  expect_error(withdrawal_rule("guyton_klinger", cut = 150), "cut muss")
  expect_error(withdrawal_rule("guyton_klinger", inflation_cap = -5), "inflation_cap muss eine Zahl >= 0 in Prozent oder Inf")
  expect_error(withdrawal_rule("guyton_klinger", skip_inflation = "ja"), "skip_inflation muss TRUE oder FALSE")
  expect_error(withdrawal_rule("ratchet", ratchet_gap = -1), "ratchet_gap muss")
  expect_error(withdrawal_rule("vpw", max_rate = 0), "max_rate = 0 erlaubt keine Entnahme")
  expect_error(withdrawal_rule("vanguard", floor = 120), "floor muss NULL oder eine Zahl von 0 bis 100")
  expect_error(withdrawal_rule("abw", fv = -1), "fv muss")
  expect_warning(withdrawal_rule("vanguard", ceiling = 0.05, floor = 0.025),
                 "ceiling = 0.050, floor = 0.025 wirkt wie ein Anteil.*ceiling = 5.0, floor = 2.5")
  expect_silent(withdrawal_rule("guyton_klinger", inflation_cap = Inf))
  expect_silent(withdrawal_rule("vanguard", rate = 5, ceiling = 5, floor = 2.5))
  expect_identical(withdrawal_rule("guyton_klinger", rate = 5.2)$ceiling, 20)
})

test_that("R8-01: walk_forward-Fenster von t0 aus, lueckenlos ohne Ueberlappung (Start 31.08.)", {
  set.seed(1); n <- 1500
  d <- data.frame(date = seq.Date(as.Date("2010-08-30"), by = "day", length.out = n))
  d$A <- 100 * cumprod(1 + rnorm(n, 3e-4, 0.011))
  st <- create_strategy(A = asset_config("etf", "signal", signal_buy = "buy", signal_sell = "sell"))
  ps <- suppressMessages(suppressWarnings(param_search(d, function(p) list(strategy = st, signal = function(df) signal_sma(df$A, p$n, 0)),
                                                       param_space(n = c(20, 50)), burn_in = 0)))
  dd <- SimLev:::.of_returns(ps, "day")$dates
  expect_equal(dd[1], as.Date("2010-08-31"))
  wf <- walk_forward(ps, train = 0.5, test = 0.5)
  W <- wf$windows
  # Teststart k = t0 + 6 (k + 1) Monate, Testende = Tag vor t0 + 6 (k + 2) Monate (auf Monatsende begrenzt)
  expect_equal(W$test_start[1:4], as.Date(c("2011-02-28", "2011-08-31", "2012-02-29", "2012-08-31")))
  expect_equal(W$test_end[1:3], as.Date(c("2011-08-30", "2012-02-28", "2012-08-30")))   # vorher 27.08. (3 Tage Luecke)
  nW <- nrow(W)
  expect_true(all(W$test_end[-nW] + 1 == W$test_start[-1]))                    # lueckenlos, keine Ueberlappung
  s <- wf$series$date
  expect_length(setdiff(dd[dd >= min(s) & dd <= max(s)], s), 0L)
  expect_false(anyDuplicated(s) > 0)
})

test_that("R8-02: Horizont H auf laengeren Pfaden = Pfade mit H Jahren (Endvermoegen und Steuern mit VP-Abrechnung)", {
  set.seed(2); R <- matrix(exp(rnorm(20 * 3, 0.06, 0.12)), 20)
  f <- function(RR, ...) suppressWarnings(withdrawal_simulation(RR, withdrawal_rule("constant", rate = 4), start_value = 1e5,
                                                                tax_mode = "person", base_rate = 2.5, cost_basis = 60, ...))
  a <- f(R[1:10, ]); b <- f(R, horizon = 10)
  expect_equal(b$paths$terminal_real, a$paths$terminal_real, tolerance = 1e-12)   # vorher 156328 statt 156078
  expect_equal(b$paths$taxes, a$paths$taxes, tolerance = 1e-12)
  expect_equal(b$paths$success, a$paths$success)
  # zufaellige Horizonte, monatliche Perioden und FIFO-Lots ebenso
  h <- horizon_model("discrete", years = c(5, 12), prob = c(1, 1))
  Hm <- SimLev:::.draw_horizon(h, 3)
  Rm <- matrix(exp(rnorm(240 * 3, 0.005, 0.03)), 240)
  bm <- suppressWarnings(withdrawal_simulation(Rm, withdrawal_rule("percent", rate = 5), frequency = "month", tax_mode = "person",
                                               base_rate = 2.5, cost_basis = 60, horizon = h))
  for (i in 1:3) {
    am <- suppressWarnings(withdrawal_simulation(Rm[seq_len(12 * Hm[i]), i, drop = FALSE], withdrawal_rule("percent", rate = 5),
                                                 frequency = "month", tax_mode = "person", base_rate = 2.5, cost_basis = 60))
    expect_equal(bm$paths$terminal_real[i], am$paths$terminal_real, tolerance = 1e-12)
    expect_equal(bm$paths$taxes[i], am$paths$taxes, tolerance = 1e-12)
  }
  # ohne horizon unveraendert: volle Pfadlaenge
  expect_equal(f(R)$paths$terminal_real, f(R, horizon = 20)$paths$terminal_real, tolerance = 1e-12)
})

test_that("R8-03: Pfadende-VP wie simulation() (Steuer mit Folgejahr-Toepfen, Zwangsverkauf im ablaufenden Jahr)", {
  Ry <- c(1.10, 0.8, 1.30); u <- cumprod(c(1, Ry)); cal <- seq(as.Date("2021-01-01"), as.Date("2023-12-31"), by = "day")
  yr <- as.integer(format(cal, "%Y")) - 2020; px <- 100 * u[yr]; l <- format(cal, "%m-%d") == "12-31"; px[l] <- 100 * u[yr[l] + 1]
  st <- create_strategy(A = asset_config("etf", "bnh", asset_share = 1, asset_spread = 0, asset_bonus = 30))
  r <- suppressMessages(simulation(data.frame(date = cal, A = px), st, start_value = 1e5, tax_mode = "person", base_rate = 3.2))
  w <- withdrawal_simulation(matrix(Ry, ncol = 1), withdrawal_rule("constant", rate = 0), start_value = 1e5,
                             tax_mode = "person", base_rate = 3.2, cost_basis = 100, asset_bonus = 30)
  expect_equal(w$paths$taxes, r$tax_report$total_taxes_paid, tolerance = 1e-9)    # 251,47 (vorher 253,13)
  expect_equal(w$paths$terminal_nominal, tail(r$worth, 1), tolerance = 1e-9)
})

test_that("R8-08: planmaessige vollst\u00e4ndige Entnahme (one_over_n, abw, hebeler, vpw) mit Steuern kein Fehlschlag", {
  set.seed(1); R <- matrix(exp(rnorm(30 * 200, 0.05, 0.15)), 30)
  for (ty in c("one_over_n", "abw", "vpw")) {
    w <- withdrawal_simulation(R, withdrawal_rule(ty), tax_mode = "person", cost_basis = 60)
    expect_true(all(w$paths$success), info = ty)                                # vorher one_over_n 5,5 %, abw 6 % Erfolg
    if (ty != "vpw") expect_true(all(w$paths$terminal_real == 0), info = ty)   # Depot planmaessig geleert (vpw: bis max_age 100)
  }
  # one_over_n ohne Steuern und mit Steuern: beide leeren das Depot; Konsum im letzten Jahr mit Steuern kleiner
  a <- withdrawal_simulation(R[, 1:5], withdrawal_rule("one_over_n"), tax_mode = "person", cost_basis = 60)
  expect_true(all(a$paths$success) && all(is.na(a$paths$depletion_year)))
  # echter Fehlschlag bleibt einer: konstante Entnahme, die das Depot vor dem Ende aufbraucht
  b <- withdrawal_simulation(matrix(0.9, 30, 1), withdrawal_rule("constant", rate = 10), tax_mode = "person", cost_basis = 60)
  expect_false(b$paths$success)
  # one_over_n monatlich: Leerung im letzten Jahr ebenfalls planmaessig
  Rm <- matrix(exp(rnorm(120 * 4, 0.004, 0.04)), 120)
  wm <- withdrawal_simulation(Rm, withdrawal_rule("one_over_n"), frequency = "month", tax_mode = "person", cost_basis = 60)
  expect_true(all(wm$paths$success))
})

test_that("R9-01: Pfadende-VP mit Verlusttopf nach dem Zwangsverkauf (Differenz wie simulation())", {
  t <- 0.26375
  # Gewinnverkauf: Verlusttopf 2000 deckt den Verkaufsgewinn im ablaufenden Jahr, die VP-Steuer steigt
  w <- withdrawal_simulation(matrix(1.10, 1, 1), withdrawal_rule("constant", rate = 0), start_value = 1e6, tax_mode = "person",
                             base_rate = 2.5, asset_bonus = 30, cost_basis = 100, loss_carryforward = 2000)
  V <- 1.1e6; basis <- 1e6 + 17500; gq <- 1 - basis / V                       # Gewinnanteil je EUR Verkauf
  vtax0 <- (17500 * 0.7 - 2000 - 1000) * t                                   # 2439,69: Toepfe 2025 vor dem Verkauf
  loss1 <- 2000 - vtax0 * gq * 0.7                                            # Verkauf 2024: Gewinn n. TFS aus dem Topf
  vtax1 <- (17500 * 0.7 - loss1 - 1000) * t                                   # 2473,47 endgueltig
  G2 <- (vtax1 - vtax0) / (1 - gq * 0.7 * t)                                  # Nachzahlung: Verkauf 2025 (Topf und SPB leer)
  expect_equal(w$paths$taxes, vtax1 + G2 * gq * 0.7 * t, tolerance = 1e-10)  # vorher 2439,69
  expect_equal(w$paths$terminal_nominal, V - vtax0 - G2, tolerance = 1e-10)
  # dasselbe Muster wie simulation(): Fonds A 990000 (+10 %), Verlusttopf 2000 aus einem Verlustverkauf, Ende 31.12.
  dd <- seq.Date(as.Date("2024-01-01"), as.Date("2024-12-31"), by = "day"); n <- length(dd)
  d <- data.frame(date = dd, A = seq(100, 110, length.out = n), B = ifelse(dd < as.Date("2024-06-01"), 100, 80))
  d$buy <- seq_len(n) == 1; d$sell <- dd == as.Date("2024-06-01")
  s <- create_strategy(A = asset_config("etf", asset_share = 0.99, asset_spread = 0, asset_bonus = 30),
                       B = asset_config("etf", "signal", asset_share = 0.01, asset_spread = 0, asset_bonus = 0, signal_buy = "buy", signal_sell = "sell"))
  r <- suppressMessages(simulation(d, s, start_value = 1e6, tax_mode = "person", base_rate = 2.5))
  we <- withdrawal_simulation(matrix(1.10, 1, 1), withdrawal_rule("constant", rate = 0), start_value = 990000, tax_mode = "person",
                              base_rate = 2.5, asset_bonus = 30, cost_basis = 100, loss_carryforward = 2000)
  expect_equal(we$paths$taxes, r$tax_report$total_taxes_paid, tolerance = 1e-9)  # 2441,18 = VP 2440,71 + Nachverkauf 0,47
  # Verlustverkauf (Basis ueber dem Wert): Verkauf im ablaufenden Jahr erhoeht den Topf, Erstattung ins Depot
  wl <- withdrawal_simulation(matrix(1.10, 1, 1), withdrawal_rule("constant", rate = 0), start_value = 1e6, tax_mode = "person",
                              base_rate = 2.5, asset_bonus = 30, cost_basis = 120)
  basis <- 1.2e6 + 17500; gl <- 1 - basis / V                                 # negativ
  vtax0 <- (17500 * 0.7 - 1000) * t
  loss1 <- -vtax0 * gl * 0.7
  vtax1 <- (17500 * 0.7 - loss1 - 1000) * t
  expect_lt(vtax1, vtax0)
  expect_equal(wl$paths$taxes, vtax1, tolerance = 1e-10)
  expect_equal(wl$paths$terminal_nominal, V - vtax0 + (vtax0 - vtax1), tolerance = 1e-10)
  # Horizont-Weg: Horizont 1 auf 3-Jahres-Pfaden = 1-Jahres-Pfad
  wh <- withdrawal_simulation(matrix(1.10, 3, 1), withdrawal_rule("constant", rate = 0), start_value = 1e6, tax_mode = "person",
                              base_rate = 2.5, asset_bonus = 30, cost_basis = 100, loss_carryforward = 2000, horizon = 1)
  expect_equal(wh$paths$taxes, w$paths$taxes, tolerance = 1e-12)
  expect_equal(wh$paths$terminal_real, w$paths$terminal_real, tolerance = 1e-12)
})
