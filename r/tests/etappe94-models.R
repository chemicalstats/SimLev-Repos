# Rauchprobe der Modelle der C-Bibliothek slc (Etappe 9.4): laeuft immer, auch ohne
# SIMLEV_LEGACY_TESTS. Gegenstueck zu python/tests/test_etappe9_models.py und
# julia/test/etappe94_models.jl; die Gleichheit mit Python und Julia prueft tools/gleichlauf/.
library(SimLev)
sl <- asNamespace("SimLev")
err <- function(expr) tryCatch({ expr; NA_character_ }, error = conditionMessage)
s <- sl$.sl_stream(7)
z <- sl$.sl_rnorm(1500, stream = s)
e <- numeric(1500); v <- 1e-4; ep <- 0
for (t in seq_along(e)) { if (t > 1) v <- 2e-6 + 0.08 * ep^2 + 0.9 * v; ep <- sqrt(v) * z[t]; e[t] <- 3e-4 + ep }
f <- sl$.sl_garch11_fit(e)
stopifnot(f$convergence == 0L, abs(f$alpha - 0.08) < 0.05, abs(f$beta - 0.9) < 0.05, f$method == "ml",
          abs(f$loglik + sl$.sl_garch11_nll(e, c(f$mu, f$omega, f$alpha, f$beta, 0))) < 1e-8)
g <- sl$.sl_fit_garch11(e, gjr = TRUE)
stopifnot(g$method == "ml", g$alpha + g$gamma >= 0, length(g$z) == 1500,  # N1: gamma < 0 zulaessig
          abs(stats::sd(g$z) - 1) < 1e-12)
stopifnot(sl$.sl_fit_garch11(rep(1e-3, 30))$method == "konstant")
w <- tryCatch(sl$.sl_fit_garch11(e[1:6]), warning = conditionMessage)
stopifnot(grepl("ML-Sch", w))
stopifnot(grepl("zu wenige", err(sl$.sl_garch11_fit(e[1:9]))))
x <- 0.01 * expm1(-0.2 * log(sl$.sl_runif(400, stream = s))) / 0.2
p <- sl$.sl_gpd_fit(x)
stopifnot(p$convergence == 0L, abs(p$shape - 0.2) < 0.15, abs(p$scale / 0.01 - 1) < 0.2)
stopifnot(grepl("zu wenige", err(sl$.sl_gpd_fit(x[1:5]))))
Z <- matrix(sl$.sl_rnorm(600, stream = s), 300); Q <- stats::cor(Z)
d <- sl$.sl_dcc_fit(Z, Q)
stopifnot(d$a >= 0, d$b >= 0, d$a + d$b < 0.999, isTRUE(sl$.sl_dcc_filter(Z, d$a, d$b, Q, TRUE)$ok))
f1 <- sl$.sl_dcc_filter(Z, 0.03, 0.95, Q, TRUE); f0 <- sl$.sl_dcc_filter(Z, 0.03, 0.95, Q, FALSE)
stopifnot(identical(f1$nll, f0$nll), isTRUE(f1$ok))   # 9.6c: frueherer Vergleich mit .dcc_filter (entfallen)
m <- sl$.sl_ms_garch_fit(e[1:600], 2, "sGARCH")
stopifnot(is.finite(m$loglik), all(m$regimes %in% 1:2), abs(rowSums(m$P) - 1) < 1e-12)
stopifnot(grepl("Anzahl Regime", err(sl$.sl_ms_garch_fit(e, 1, "sGARCH"))))
# N1: analytischer Gradient gegen zentrale Differenzen (Schritt 1e-5 max(|x|, 1))
th <- sl$.sl_ms_garch_starts(e[1:600], 2, "gjrGARCH", all = TRUE)[, 3]
gr <- sl$.sl_ms_garch_grad(th, e[1:600], 2, "gjrGARCH")
gn <- vapply(seq_along(th), function(i) { h <- 1e-5 * max(abs(th[i]), 1); a <- b <- th; a[i] <- a[i] + h; b[i] <- b[i] - h
  (sl$.sl_ms_garch_nll(a, e[1:600], 2, "gjrGARCH") - sl$.sl_ms_garch_nll(b, e[1:600], 2, "gjrGARCH")) / (2 * h) }, 0)
stopifnot(identical(gr$value, sl$.sl_ms_garch_nll(th, e[1:600], 2, "gjrGARCH")), max(abs(gr$gradient - gn)) < 1e-5 * max(abs(gn), 1))
i1 <- sl$.sl_boot_idx_stationary(300, 50, 10, stream = sl$.sl_stream(1))
i2 <- sl$.sl_boot_idx_stationary(300, 50, 10, stream = sl$.sl_stream(1))
stopifnot(identical(i1, i2), all(i1 >= 1 & i1 <= 300))
stopifnot(grepl("block_length", err(sl$.sl_boot_idx_block(10, 5, 20, FALSE, stream = s))))
cat("etappe94-models: ok\n")
