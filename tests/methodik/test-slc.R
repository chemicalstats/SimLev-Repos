# test-slc.R
# C-Bibliothek slc (gemeinsamer Kern von R, Python und Julia) gegen unabhängige Werte: Testvektoren,
# bekannte Konstanten, R's eigene Routinen und analytische Lösungen. Die Gleichheit der Sprachen prüfen die
# Referenzfälle tests/<gruppe>/faelle/slc (Module slc, slc_linalg, slc_opt und slc_models). Inhalt wörtlich aus den vier Rauchproben
# der C-Bibliothek (bis 1.4.0 eigene Skripte in tests/: Zufall und Verteilungen, lineare Algebra, Optimierer,
# Modelle); deren stopifnot()-Prüfungen bleiben, je Rauchprobe ein Block.
# Prüfungen je Paragraph bzw. Thema als Tabellen tabelle("<Thema>", wert(ist, soll, quelle =), ident(…), bed(…), pruef(…))
# (helper-tabelle.R); Quelle je Zeile aus dem Kommentar an der Prüfung, sonst "Handrechnung (Herleitung im Test)". Erwartete
# Werte unverändert (Liste der geprüften Werte vor und nach der Umstellung auf Tabellen in 1.4.2 je Datei verglichen).
testthat::local_edition(3)   # Edition 3 wie bisher (Config/testthat/edition in r/DESCRIPTION entfällt)

sl <- asNamespace("SimLev")

test_that("slc: Zufall (SplitMix64-Testvektoren, Ströme, Meldungen) und Verteilungen gegen bekannte Werte (Rauchprobe Zufall und Verteilungen)", {
err <- function(expr) tryCatch({ expr; NA_character_ }, error = conditionMessage)
warns <- function(expr) {
  w <- character(0)
  withCallingHandlers(expr, warning = function(c) { w <<- c(w, conditionMessage(c)); invokeRestart("muffleWarning") })
  w
}
tabelle("slc: Zufall (SplitMix64-Testvektoren, Ströme, Meldungen) und Verteilungen gegen bekannte Werte (Rauchprobe Zufall und Verteilungen)",
  bed(identical(simlev_seed(1), 1),
      quelle = "Handrechnung (Herleitung im Test)"),
  bed(identical(sl$.sl_version(), "0.1.0"),
      quelle = "Handrechnung (Herleitung im Test)"))
simlev_seed(42)
tabelle("slc: Zufall (SplitMix64-Testvektoren, Ströme, Meldungen) und Verteilungen gegen bekannte Werte (Rauchprobe Zufall und Verteilungen)",
  bed(identical(sl$.sl_state_hex(), c("bdd732262feb6e95", "28efe333b266f103", "47526757130f9f52", "581ce1ff0e4ae394")),
      quelle = "Zustand = erste vier Ausgaben von SplitMix64(42) (= java.util.SplittableRandom(42))"),
  bed(identical(sl$.sl_u64(2), c("15780b2e0c2ec716", "6104d9866d113a7e")),
      quelle = "Zustand = erste vier Ausgaben von SplitMix64(42) (= java.util.SplittableRandom(42))"))
for (b in list(1.5, "a", TRUE, 2^53))
  stopifnot(identical(err(simlev_seed(b)), "simlev_seed: seed muss eine ganze Zahl mit |seed| < 2^53 sein."))   # seit 1.6.4 ohne Wert (Entscheidung 8), seit K43 T1-R5 mit Funktionsnamen
tabelle("slc: Zufall (SplitMix64-Testvektoren, Ströme, Meldungen) und Verteilungen gegen bekannte Werte (Rauchprobe Zufall und Verteilungen)",
  bed(identical(err(simlev_seed(1.5)), "simlev_seed: seed muss eine ganze Zahl mit |seed| < 2^53 sein."),
      quelle = "Handrechnung (Herleitung im Test)"))

# Reproduzierbarkeit, Stroeme, set.seed() unberuehrt
simlev_seed(7); a <- sl$.sl_runif(5)
simlev_seed(7)
tabelle("slc: Zufall (SplitMix64-Testvektoren, Ströme, Meldungen) und Verteilungen gegen bekannte Werte (Rauchprobe Zufall und Verteilungen)",
  bed(identical(sl$.sl_runif(5), a),
      quelle = "Handrechnung (Herleitung im Test)"))
s <- sl$.sl_stream(7)
tabelle("slc: Zufall (SplitMix64-Testvektoren, Ströme, Meldungen) und Verteilungen gegen bekannte Werte (Rauchprobe Zufall und Verteilungen)",
  bed(identical(sl$.sl_runif(5, stream = s), a),
      quelle = "Handrechnung (Herleitung im Test)"))
u <- sl$.sl_streams(sl$.sl_stream(7), 3)
tabelle("slc: Zufall (SplitMix64-Testvektoren, Ströme, Meldungen) und Verteilungen gegen bekannte Werte (Rauchprobe Zufall und Verteilungen)",
  bed(length(unique(lapply(u, sl$.sl_state_hex))) == 3,
      quelle = "Handrechnung (Herleitung im Test)"),
  bed(all(sl$.sl_runif(1000, stream = u[[1]]) > 0),
      quelle = "Handrechnung (Herleitung im Test)"))
set.seed(1); r1 <- stats::runif(1); simlev_seed(3); set.seed(1)
tabelle("slc: Zufall (SplitMix64-Testvektoren, Ströme, Meldungen) und Verteilungen gegen bekannte Werte (Rauchprobe Zufall und Verteilungen)",
  bed(identical(stats::runif(1), r1),
      quelle = "Handrechnung (Herleitung im Test)"),
  bed(identical(err(sl$.sl_in_unit(sl$.sl_runif(1))), "interner Fehler: globaler Zufallszustand in paralleler Einheit"),
      quelle = "Handrechnung (Herleitung im Test)"),
  bed(abs(sl$.sl_qnorm(0.975) / 1.959963984540054 - 1) < 1e-15,
      quelle = "Verteilungen und Meldungen"),
  bed(sl$.sl_pnorm(-38) > 0,
      quelle = "Verteilungen und Meldungen"),
  bed(abs(sl$.sl_lgamma(0.5) / 0.5723649429247001 - 1) < 1e-15,
      quelle = "Verteilungen und Meldungen"),
  bed(abs(sl$.sl_pt(2, 5) / 0.9490302605850709 - 1) < 1e-14,
      quelle = "Verteilungen und Meldungen"),
  bed(abs(sl$.sl_qt(0.975, 10) / 2.228138851986274 - 1) < 1e-14,
      quelle = "Verteilungen und Meldungen"),
  bed(abs(sl$.sl_pbeta(0.3, 2, 3) / 0.3483 - 1) < 1e-12,
      quelle = "Verteilungen und Meldungen"),
  bed(identical(warns(sl$.sl_qnorm(c(2, 0.5))), "qnorm: NaN erzeugt"),
      quelle = "Handrechnung (Herleitung im Test)"),
  bed(identical(err(sl$.sl_sample(3, 5)), "sample: Stichprobe größer als die Grundgesamtheit (replace = FALSE)"),
      quelle = "Handrechnung (Herleitung im Test)"),
  bed(is.na(sl$.sl_pnorm(NA_real_)) && !is.nan(sl$.sl_pnorm(NA_real_)),
      quelle = "NA bleibt NA"))
  succeed()
})

test_that("slc: lineare Algebra, kleinste Quadrate, Logit, Stineman, Glättungsspline, Kerndichte gegen R bzw. analytische Werte (Rauchprobe lineare Algebra)", {
err <- function(expr) tryCatch({ expr; NA_character_ }, error = conditionMessage)
near <- function(a, b, tol = 1e-12) isTRUE(all(abs(a - b) <= tol * max(1, abs(b))))

A <- matrix(c(4, 2, 2, 3), 2)
R <- sl$.sl_chol(A)
tabelle("slc: lineare Algebra, kleinste Quadrate, Logit, Stineman, Glättungsspline, Kerndichte gegen R bzw. analytische Werte (Rauchprobe lineare Algebra)",
  bed(identical(R, matrix(c(2, 0, 1, sqrt(2)), 2)),
      quelle = "Handrechnung (Herleitung im Test)"),
  bed(near(crossprod(R), A),
      quelle = "Handrechnung (Herleitung im Test)"),
  bed(near(sl$.sl_solve_spd(A, c(1, 2)), c(-0.125, 0.75)),
      quelle = "Handrechnung (Herleitung im Test)"),
  bed(near(sl$.sl_solve_spd(A) %*% A, diag(2)),
      quelle = "Handrechnung (Herleitung im Test)"),
  bed(near(sl$.sl_logdet_spd(A), log(8)),
      quelle = "Handrechnung (Herleitung im Test)"),
  bed(near(sl$.sl_backsolve(R, c(2, 1)), c(1 - 1 / (2 * sqrt(2)), 1 / sqrt(2))),
      quelle = "Handrechnung (Herleitung im Test)"),
  bed(identical(err(sl$.sl_chol(matrix(c(1, 2, 2, 1), 2))), "chol: Matrix nicht positiv definit (führende Minore der Ordnung 2)"),
      quelle = "Handrechnung (Herleitung im Test)"),
  bed(identical(err(sl$.sl_chol(matrix(c(1, NA, NA, 1), 2))), "chol: NA/NaN/Inf in der Matrix"),
      quelle = "Handrechnung (Herleitung im Test)"),
  bed(identical(err(sl$.sl_solve_spd(diag(c(1e20, 1)), 1:2)), "solve: Matrix numerisch singulär"),
      quelle = "Handrechnung (Herleitung im Test)"))
e <- sl$.sl_eigen_sym(A)
tabelle("slc: lineare Algebra, kleinste Quadrate, Logit, Stineman, Glättungsspline, Kerndichte gegen R bzw. analytische Werte (Rauchprobe lineare Algebra)",
  bed(near(e$values, c(7 + sqrt(17), 7 - sqrt(17)) / 2),
      quelle = "Handrechnung (Herleitung im Test)"),
  bed(near(abs(e$vectors), abs(eigen(A)$vectors)),
      quelle = "Handrechnung (Herleitung im Test)"),
  bed(all(e$vectors[1, ] > 0 | e$vectors[2, ] > 0),
      quelle = "Handrechnung (Herleitung im Test)"))
X <- matrix(as.double(1:6), 2)
tabelle("slc: lineare Algebra, kleinste Quadrate, Logit, Stineman, Glättungsspline, Kerndichte gegen R bzw. analytische Werte (Rauchprobe lineare Algebra)",
  bed(identical(sl$.sl_matmul(X, t(X)), X %*% t(X)),
      quelle = "Handrechnung (Herleitung im Test)"),
  bed(identical(sl$.sl_crossprod(X), crossprod(X)),
      quelle = "Handrechnung (Herleitung im Test)"),
  bed(identical(sl$.sl_tcrossprod(X), tcrossprod(X)),
      quelle = "Handrechnung (Herleitung im Test)"),
  bed(identical(sl$.sl_matmul(1:3, 1:3), matrix(14, 1)),
      quelle = "Handrechnung (Herleitung im Test)"),
  bed(identical(err(sl$.sl_matmul(X, X)), "%m%: nicht passende Argumente"),
      quelle = "Handrechnung (Herleitung im Test)"))
f <- sl$.sl_lsfit(cbind(1, 1:5, 2 * (1:5)), c(1, 3, 2, 5, 4))
tabelle("slc: lineare Algebra, kleinste Quadrate, Logit, Stineman, Glättungsspline, Kerndichte gegen R bzw. analytische Werte (Rauchprobe lineare Algebra)",
  bed(f$rank == 2L,
      quelle = "Handrechnung (Herleitung im Test)"),
  bed(identical(f$pivot, c(1L, 2L, 3L)),
      quelle = "Handrechnung (Herleitung im Test)"),
  bed(is.na(f$coefficients[3]),
      quelle = "Handrechnung (Herleitung im Test)"),
  bed(near(f$coefficients[1:2], c(0.6, 0.8)),
      quelle = "Handrechnung (Herleitung im Test)"),
  bed(identical(err(sl$.sl_lsfit(cbind(1, 1:3), c(1, NA, 3))), "lm: NA/NaN/Inf in y"),
      quelle = "Handrechnung (Herleitung im Test)"))
g <- sl$.sl_logit_irls(cbind(1, 1:6), c(0, 0, 1, 0, 1, 1))
tabelle("slc: lineare Algebra, kleinste Quadrate, Logit, Stineman, Glättungsspline, Kerndichte gegen R bzw. analytische Werte (Rauchprobe lineare Algebra)",
  bed(g$converged,
      quelle = "Handrechnung (Herleitung im Test)"),
  bed(near(g$coefficients, coef(glm(c(0, 0, 1, 0, 1, 1) ~ I(1:6), family = binomial())), 1e-7),
      quelle = "Handrechnung (Herleitung im Test)"))
s <- sl$.sl_stineman(c(1, 2, 4), c(1, 3, 2), c(1, 1.5, 4, 5))
tabelle("slc: lineare Algebra, kleinste Quadrate, Logit, Stineman, Glättungsspline, Kerndichte gegen R bzw. analytische Werte (Rauchprobe lineare Algebra)",
  bed(identical(s[c(1, 3)], c(1, 2)),
      quelle = "Handrechnung (Herleitung im Test)"),
  bed(is.na(s[4]),
      quelle = "Handrechnung (Herleitung im Test)"),
  bed(s[2] > 1 && s[2] < 3,
      quelle = "Handrechnung (Herleitung im Test)"))
sp <- sl$.sl_smspline_fit(1:10, sin(1:10))
tabelle("slc: lineare Algebra, kleinste Quadrate, Logit, Stineman, Glättungsspline, Kerndichte gegen R bzw. analytische Werte (Rauchprobe lineare Algebra)",
  bed(length(sp$x) == 10L,
      quelle = "Handrechnung (Herleitung im Test)"),
  bed(sp$df > 2,
      quelle = "Handrechnung (Herleitung im Test)"),
  bed(sp$df < 10,
      quelle = "Handrechnung (Herleitung im Test)"),
  bed(identical(sp$gam[c(1, 10)], c(0, 0)),
      quelle = "Handrechnung (Herleitung im Test)"),
  bed(near(sl$.sl_smspline_predict(sp, c(1, 10)), sp$y[c(1, 10)], 1e-12),
      quelle = "Handrechnung (Herleitung im Test)"),
  bed(identical(err(sl$.sl_smspline_fit(c(1, 2, 3, 3), 1:4)), "smooth.spline: mindestens 4 verschiedene x-Werte"),
      quelle = "Handrechnung (Herleitung im Test)"))
k <- sl$.sl_kde(c(-1, 0, 2, 3, 3.5))
tabelle("slc: lineare Algebra, kleinste Quadrate, Logit, Stineman, Glättungsspline, Kerndichte gegen R bzw. analytische Werte (Rauchprobe lineare Algebra)",
  bed(length(k$x) == 512L,
      quelle = "Handrechnung (Herleitung im Test)"),
  bed(identical(k$bw, bw.nrd0(c(-1, 0, 2, 3, 3.5))),
      quelle = "Handrechnung (Herleitung im Test)"),
  bed(abs(sum(k$y) * diff(k$x[1:2]) - 1) < 1e-3,
      quelle = "Handrechnung (Herleitung im Test)"))
  succeed()
})

test_that("slc: Optimierer gegen bekannte Minima und Meldungen (Rauchprobe Optimierer)", {
err <- function(expr) tryCatch({ expr; NA_character_ }, error = conditionMessage)
fr <- function(x) sl$.sl_opt_testfn(1, x)
gr <- function(x) sl$.sl_opt_testfn(1, x, TRUE)[[2]]

for (m in c("Nelder-Mead", "BFGS", "L-BFGS-B")) {
  o <- sl$.sl_optim(c(a = -1.2, b = 1), fr, method = m)
  stopifnot(o$convergence == 0L, o$value < 1e-12, max(abs(o$par - 1)) < 1e-5, identical(names(o$par), c("a", "b")),
            identical(names(o$counts), c("function", "gradient")), is.na(o$counts[[2]]) == (m == "Nelder-Mead"))
  c0 <- sl$.sl_minimize_test(1, c(-1.2, 1), m)
  stopifnot(identical(c0$par, unname(o$par)), identical(c0$value, o$value), c0$evaluations == o$evaluations)
}
o <- sl$.sl_optim(c(-1.2, 1), fr, gr, method = "BFGS")
tabelle("slc: Optimierer gegen bekannte Minima und Meldungen (Rauchprobe Optimierer)",
  bed(o$convergence == 0L,
      quelle = "Handrechnung (Herleitung im Test)"),
  bed(o$value < 1e-15,
      quelle = "Handrechnung (Herleitung im Test)"),
  bed(o$evaluations == o$counts[[1]],
      quelle = "Handrechnung (Herleitung im Test)"))
# Schranken mit aktiven Grenzen
o <- sl$.sl_optim(rep(0, 4), function(x) sl$.sl_opt_testfn(8, x), method = "L-BFGS-B", lower = -1, upper = 1)
tabelle("slc: Optimierer gegen bekannte Minima und Meldungen (Rauchprobe Optimierer)",
  bed(o$convergence == 0L,
      quelle = "Handrechnung (Herleitung im Test)"),
  bed(identical(o$par, c(1, -1, 1, -1)),
      quelle = "Handrechnung (Herleitung im Test)"),
  bed(abs(o$value - 2.5) < 1e-14,
      quelle = "Handrechnung (Herleitung im Test)"))
# Nelder-Mead: maxit begrenzt wie bei optim die Funktionsauswertungen
o <- sl$.sl_optim(c(-1.2, 1), fr, control = list(maxit = 10))
tabelle("slc: Optimierer gegen bekannte Minima und Meldungen (Rauchprobe Optimierer)",
  bed(o$convergence == 1L,
      quelle = "Handrechnung (Herleitung im Test)"),
  bed(o$counts[[1]] == 10L,
      quelle = "Handrechnung (Herleitung im Test)"))
# Maximum ueber fnscale
o <- sl$.sl_optim(c(1, 1), function(x) 3 - (x[1] - 2)^2 - (x[2] + 1)^2, method = "BFGS", control = list(fnscale = -1))
tabelle("slc: Optimierer gegen bekannte Minima und Meldungen (Rauchprobe Optimierer)",
  bed(abs(o$value - 3) < 1e-12,
      quelle = "Handrechnung (Herleitung im Test)"),
  bed(max(abs(o$par - c(2, -1))) < 1e-6,
      quelle = "Handrechnung (Herleitung im Test)"))
# NaN/Inf
o <- sl$.sl_optim(c(3, 3, 3), function(x) sl$.sl_opt_testfn(7, x), method = "BFGS")
tabelle("slc: Optimierer gegen bekannte Minima und Meldungen (Rauchprobe Optimierer)",
  bed(o$convergence == 0L,
      quelle = "Handrechnung (Herleitung im Test)"),
  bed(abs(o$value - sum(1 + log(1:3))) < 1e-10,
      quelle = "Handrechnung (Herleitung im Test)"),
  bed(identical(err(sl$.sl_optim(c(1, 1), function(x) NaN, method = "BFGS")), "BFGS: Zielfunktion am Startwert nicht endlich"),
      quelle = "Handrechnung (Herleitung im Test)"),
  bed(identical(err(sl$.sl_optim(c(1, 1), fr, method = "BFGS", lower = 0)), "optim: Schranken nur mit L-BFGS-B bzw. PBFGS (nicht BFGS)"),
      quelle = "Handrechnung (Herleitung im Test)"),
  bed(identical(err(sl$.sl_optim(c(1, 1), fr, control = list(abstol = 1))), "optim: unbekannte Steuerwerte 'abstol'"),
      quelle = "Handrechnung (Herleitung im Test)"))
# numerischer Gradient (B.9)
x <- c(0.3, -0.7, 1.1)
tabelle("slc: Optimierer gegen bekannte Minima und Meldungen (Rauchprobe Optimierer)",
  bed(max(abs(sl$.sl_numgrad_test(1, x) - sl$.sl_opt_testfn(1, x, TRUE)[[2]])) < 1e-6,
      quelle = "Handrechnung (Herleitung im Test)"),
  bed(identical(sl$.sl_numgrad_test(8, c(1, 2), c(1, -Inf), c(1, Inf))[1], 0),
      quelle = "Handrechnung (Herleitung im Test)"))
  succeed()
})

test_that("slc: Modelle (GARCH/GJR, GPD, DCC, MS-GARCH/HMM, Bootstrap-Kerne) auf Plausibilität und Meldungen (Rauchprobe Modelle)", {
err <- function(expr) tryCatch({ expr; NA_character_ }, error = conditionMessage)
s <- sl$.sl_stream(7)
z <- sl$.sl_rnorm(1500, stream = s)
e <- numeric(1500); v <- 1e-4; ep <- 0
for (t in seq_along(e)) { if (t > 1) v <- 2e-6 + 0.08 * ep^2 + 0.9 * v; ep <- sqrt(v) * z[t]; e[t] <- 3e-4 + ep }
f <- sl$.sl_garch11_fit(e)
tabelle("slc: Modelle (GARCH/GJR, GPD, DCC, MS-GARCH/HMM, Bootstrap-Kerne) auf Plausibilität und Meldungen (Rauchprobe Modelle)",
  bed(f$convergence == 0L,
      quelle = "Handrechnung (Herleitung im Test)"),
  bed(abs(f$alpha - 0.08) < 0.05,
      quelle = "Handrechnung (Herleitung im Test)"),
  bed(abs(f$beta - 0.9) < 0.05,
      quelle = "Handrechnung (Herleitung im Test)"),
  bed(f$method == "ml",
      quelle = "Handrechnung (Herleitung im Test)"),
  bed(abs(f$loglik + sl$.sl_garch11_nll(e, c(f$mu, f$omega, f$alpha, f$beta, 0))) < 1e-8,
      quelle = "Handrechnung (Herleitung im Test)"))
g <- sl$.sl_fit_garch11(e, gjr = TRUE)
tabelle("slc: Modelle (GARCH/GJR, GPD, DCC, MS-GARCH/HMM, Bootstrap-Kerne) auf Plausibilität und Meldungen (Rauchprobe Modelle)",
  bed(g$method == "ml",
      quelle = "Handrechnung (Herleitung im Test)"),
  bed(g$alpha + g$gamma >= 0,
      quelle = "Handrechnung (Herleitung im Test)"),
  bed(length(g$z) == 1500,
      quelle = "Handrechnung (Herleitung im Test)"),
  bed(abs(stats::sd(g$z) - 1) < 1e-12,
      quelle = "Handrechnung (Herleitung im Test)"),
  bed(sl$.sl_fit_garch11(rep(1e-3, 30))$method == "konstant",
      quelle = "Handrechnung (Herleitung im Test)"))
w <- tryCatch(sl$.sl_fit_garch11(e[1:6]), warning = conditionMessage)
tabelle("slc: Modelle (GARCH/GJR, GPD, DCC, MS-GARCH/HMM, Bootstrap-Kerne) auf Plausibilität und Meldungen (Rauchprobe Modelle)",
  bed(grepl("ML-Sch", w),
      quelle = "Handrechnung (Herleitung im Test)"),
  bed(grepl("zu wenige", err(sl$.sl_garch11_fit(e[1:9]))),
      quelle = "Handrechnung (Herleitung im Test)"))
x <- 0.01 * expm1(-0.2 * log(sl$.sl_runif(400, stream = s))) / 0.2
p <- sl$.sl_gpd_fit(x)
tabelle("slc: Modelle (GARCH/GJR, GPD, DCC, MS-GARCH/HMM, Bootstrap-Kerne) auf Plausibilität und Meldungen (Rauchprobe Modelle)",
  bed(p$convergence == 0L,
      quelle = "Handrechnung (Herleitung im Test)"),
  bed(abs(p$shape - 0.2) < 0.15,
      quelle = "Handrechnung (Herleitung im Test)"),
  bed(abs(p$scale / 0.01 - 1) < 0.2,
      quelle = "Handrechnung (Herleitung im Test)"),
  bed(grepl("zu wenige", err(sl$.sl_gpd_fit(x[1:5]))),
      quelle = "Handrechnung (Herleitung im Test)"))
Z <- matrix(sl$.sl_rnorm(600, stream = s), 300); Q <- stats::cor(Z)
d <- sl$.sl_dcc_fit(Z, Q)
tabelle("slc: Modelle (GARCH/GJR, GPD, DCC, MS-GARCH/HMM, Bootstrap-Kerne) auf Plausibilität und Meldungen (Rauchprobe Modelle)",
  bed(d$a >= 0,
      quelle = "Handrechnung (Herleitung im Test)"),
  bed(d$b >= 0,
      quelle = "Handrechnung (Herleitung im Test)"),
  bed(d$a + d$b < 0.999,
      quelle = "Handrechnung (Herleitung im Test)"),
  bed(isTRUE(sl$.sl_dcc_filter(Z, d$a, d$b, Q, TRUE)$ok),
      quelle = "Handrechnung (Herleitung im Test)"))
f1 <- sl$.sl_dcc_filter(Z, 0.03, 0.95, Q, TRUE); f0 <- sl$.sl_dcc_filter(Z, 0.03, 0.95, Q, FALSE)
tabelle("slc: Modelle (GARCH/GJR, GPD, DCC, MS-GARCH/HMM, Bootstrap-Kerne) auf Plausibilität und Meldungen (Rauchprobe Modelle)",
  bed(identical(f1$nll, f0$nll),
      quelle = "9.6c: frueherer Vergleich mit .dcc_filter (entfallen)"),
  bed(isTRUE(f1$ok),
      quelle = "9.6c: frueherer Vergleich mit .dcc_filter (entfallen)"))
m <- sl$.sl_ms_garch_fit(e[1:600], 2, "sGARCH")
tabelle("slc: Modelle (GARCH/GJR, GPD, DCC, MS-GARCH/HMM, Bootstrap-Kerne) auf Plausibilität und Meldungen (Rauchprobe Modelle)",
  bed(is.finite(m$loglik),
      quelle = "Handrechnung (Herleitung im Test)"),
  bed(all(m$regimes %in% 1:2),
      quelle = "Handrechnung (Herleitung im Test)"),
  bed(abs(rowSums(m$P) - 1) < 1e-12,
      quelle = "Handrechnung (Herleitung im Test)"),
  bed(identical(sl$.sl_ms_garch_fit(e[1:600], 2, "sGARCH", cores = 3), m),
      quelle = "Threads, Ergebnis gleich (seit 1.2.0)"),
  bed(grepl("Anzahl Regime", err(sl$.sl_ms_garch_fit(e, 1, "sGARCH"))),
      quelle = "Handrechnung (Herleitung im Test)"))
# analytischer Gradient (seit 1.0.0) gegen zentrale Differenzen (Schritt 1e-5 max(|x|, 1))
th <- sl$.sl_ms_garch_starts(e[1:600], 2, "gjrGARCH", all = TRUE)[, 3]
gr <- sl$.sl_ms_garch_grad(th, e[1:600], 2, "gjrGARCH")
gn <- vapply(seq_along(th), function(i) { h <- 1e-5 * max(abs(th[i]), 1); a <- b <- th; a[i] <- a[i] + h; b[i] <- b[i] - h
  (sl$.sl_ms_garch_nll(a, e[1:600], 2, "gjrGARCH") - sl$.sl_ms_garch_nll(b, e[1:600], 2, "gjrGARCH")) / (2 * h) }, 0)
tabelle("slc: Modelle (GARCH/GJR, GPD, DCC, MS-GARCH/HMM, Bootstrap-Kerne) auf Plausibilität und Meldungen (Rauchprobe Modelle)",
  bed(identical(gr$value, sl$.sl_ms_garch_nll(th, e[1:600], 2, "gjrGARCH")),
      quelle = "Handrechnung (Herleitung im Test)"),
  bed(max(abs(gr$gradient - gn)) < 1e-5 * max(abs(gn), 1),
      quelle = "Handrechnung (Herleitung im Test)"))
# analytischer GJR-Gradient (seit 1.1.0) gegen zentrale Differenzen (Schritt 1e-5 max(|x|, 1), mu in Einheiten von sd(e))
tg <- c(3e-4, -13.1, -3.2, -4.5, 2); sc <- c(stats::sd(e), 1, 1, 1, 1)
gg <- sl$.sl_garch11_grad(tg, e)
gq <- vapply(1:5, function(i) { h <- 1e-5 * max(abs(tg[i] / sc[i]), 1) * sc[i]; a <- b <- tg; a[i] <- a[i] + h; b[i] <- b[i] - h
  (sl$.sl_garch11_grad(a, e)$value - sl$.sl_garch11_grad(b, e)$value) / (2 * h) }, 0)
tabelle("slc: Modelle (GARCH/GJR, GPD, DCC, MS-GARCH/HMM, Bootstrap-Kerne) auf Plausibilität und Meldungen (Rauchprobe Modelle)",
  bed(max(abs(gg$gradient - gq) * sc) < 1e-5 * max(abs(gq * sc), 1),
      quelle = "Handrechnung (Herleitung im Test)"))
# dasselbe fuer sGARCH (seit 1.1.0) (theta = c(mu, log omega, a, b)); theta mit 5 Werten ist dort falsch
ts <- c(3e-4, -13.1, -2.6, 2.3); ss <- sc[1:4]
gs <- sl$.sl_garch11_grad(ts, e, FALSE)
gq <- vapply(1:4, function(i) { h <- 1e-5 * max(abs(ts[i] / ss[i]), 1) * ss[i]; a <- b <- ts; a[i] <- a[i] + h; b[i] <- b[i] - h
  (sl$.sl_garch11_grad(a, e, FALSE)$value - sl$.sl_garch11_grad(b, e, FALSE)$value) / (2 * h) }, 0)
tabelle("slc: Modelle (GARCH/GJR, GPD, DCC, MS-GARCH/HMM, Bootstrap-Kerne) auf Plausibilität und Meldungen (Rauchprobe Modelle)",
  bed(length(gs$gradient) == 4L,
      quelle = "Handrechnung (Herleitung im Test)"),
  bed(max(abs(gs$gradient - gq) * ss) < 1e-5 * max(abs(gq * ss), 1),
      quelle = "Handrechnung (Herleitung im Test)"),
  bed(abs(gs$value - sl$.sl_garch11_nll(e, c(ts[1], exp(ts[2]), exp(ts[3:4]) / (1 + sum(exp(ts[3:4]))), 0))) < 1e-12 * abs(gs$value),
      quelle = "Handrechnung (Herleitung im Test)"),
  bed(grepl("Laenge", err(sl$.sl_garch11_grad(tg, e, FALSE))),
      quelle = "Handrechnung (Herleitung im Test)"))
i1 <- sl$.sl_boot_idx_stationary(300, 50, 10, stream = sl$.sl_stream(1))
i2 <- sl$.sl_boot_idx_stationary(300, 50, 10, stream = sl$.sl_stream(1))
tabelle("slc: Modelle (GARCH/GJR, GPD, DCC, MS-GARCH/HMM, Bootstrap-Kerne) auf Plausibilität und Meldungen (Rauchprobe Modelle)",
  bed(identical(i1, i2),
      quelle = "Handrechnung (Herleitung im Test)"),
  bed(all(i1 >= 1 & i1 <= 300),
      quelle = "Handrechnung (Herleitung im Test)"),
  bed(grepl("block_length", err(sl$.sl_boot_idx_block(10, 5, 20, FALSE, stream = s))),
      quelle = "Handrechnung (Herleitung im Test)"))
# Backcast-Zielfunktion in C (seit 1.1.0) mit analytischem Gradienten (gegen zentrale Differenzen), Fit, Kendall
set.seed(3); bx <- rnorm(300, 3e-4, 0.01); bpos <- sort(sample(300, 250)); bpos[1] <- 1L
bl <- (log(50) + cumsum(log1p(2.01 * bx - 4e-5 + rnorm(300, 0, 2e-4))))[bpos]
pr <- list(bx, rep(-1 / 36000, 300), rep(0.5 / 36500, 300), 2, rep(1 / 36000, 300), rep(1 / 36500, 300), bpos, bl, c(3L, 1L, 2L), 0.3)
th <- c(0.7, 0.3, 1.01); gb <- sl$.sl_backcast_obj(pr, th, 1:3, TRUE)
gq <- vapply(1:3, function(i) { h <- 1e-6 * max(abs(th[i]), 1); a <- b <- th; a[i] <- a[i] + h; b[i] <- b[i] - h
  (sl$.sl_backcast_obj(pr, a, 1:3)$value - sl$.sl_backcast_obj(pr, b, 1:3)$value) / (2 * h) }, 0)
fb <- sl$.sl_backcast_fit(pr, c(0, 0, 1), 1:3, c(-10, -5, 0.5), c(10, 10, 1.5))
tabelle("slc: Modelle (GARCH/GJR, GPD, DCC, MS-GARCH/HMM, Bootstrap-Kerne) auf Plausibilität und Meldungen (Rauchprobe Modelle)",
  bed(max(abs(gb$gradient - gq)) < 1e-6 * max(abs(gq)),
      quelle = "4 / sqrt(5 * 5), korrekt gerundet"),
  bed(fb$convergence == 0L,
      quelle = "4 / sqrt(5 * 5), korrekt gerundet"),
  bed(fb$value <= gb$value,
      quelle = "4 / sqrt(5 * 5), korrekt gerundet"),
  bed(sl$.kendall_tau_core(c(1, 2, 2, 3), c(1, 3, 2, 3)) == 0.8,
      quelle = "4 / sqrt(5 * 5), korrekt gerundet"))
  succeed()
})
