# Rauchprobe der Optimierer der C-Bibliothek slc (Etappe 9.3): laeuft immer, auch ohne
# SIMLEV_LEGACY_TESTS. Gegenstueck zu python/tests/test_etappe9_opt.py und
# julia/test/etappe93_opt.jl; die Gleichheit mit Python und Julia prueft tools/gleichlauf/.
library(SimLev)
sl <- asNamespace("SimLev")
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
stopifnot(o$convergence == 0L, o$value < 1e-15, o$evaluations == o$counts[[1]])
# Schranken mit aktiven Grenzen
o <- sl$.sl_optim(rep(0, 4), function(x) sl$.sl_opt_testfn(8, x), method = "L-BFGS-B", lower = -1, upper = 1)
stopifnot(o$convergence == 0L, identical(o$par, c(1, -1, 1, -1)), abs(o$value - 2.5) < 1e-14)
# Nelder-Mead: maxit begrenzt wie bei optim die Funktionsauswertungen
o <- sl$.sl_optim(c(-1.2, 1), fr, control = list(maxit = 10))
stopifnot(o$convergence == 1L, o$counts[[1]] == 10L)
# Maximum ueber fnscale
o <- sl$.sl_optim(c(1, 1), function(x) 3 - (x[1] - 2)^2 - (x[2] + 1)^2, method = "BFGS", control = list(fnscale = -1))
stopifnot(abs(o$value - 3) < 1e-12, max(abs(o$par - c(2, -1))) < 1e-6)
# NaN/Inf
o <- sl$.sl_optim(c(3, 3, 3), function(x) sl$.sl_opt_testfn(7, x), method = "BFGS")
stopifnot(o$convergence == 0L, abs(o$value - sum(1 + log(1:3))) < 1e-10)
stopifnot(identical(err(sl$.sl_optim(c(1, 1), function(x) NaN, method = "BFGS")), "BFGS: Zielfunktion am Startwert nicht endlich"),
          identical(err(sl$.sl_optim(c(1, 1), fr, method = "BFGS", lower = 0)), "optim: Schranken nur mit L-BFGS-B bzw. PBFGS (nicht BFGS)"),
          identical(err(sl$.sl_optim(c(1, 1), fr, control = list(abstol = 1))), "optim: unbekannte Steuerwerte 'abstol'"))
# numerischer Gradient (B.9)
x <- c(0.3, -0.7, 1.1)
stopifnot(max(abs(sl$.sl_numgrad_test(1, x) - sl$.sl_opt_testfn(1, x, TRUE)[[2]])) < 1e-6,
          identical(sl$.sl_numgrad_test(8, c(1, 2), c(1, -Inf), c(1, Inf))[1], 0))
cat("etappe93-opt: ok\n")
