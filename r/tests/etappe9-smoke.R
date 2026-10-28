# Rauchprobe der C-Bibliothek slc (Etappe 9.1): laeuft immer, auch ohne SIMLEV_LEGACY_TESTS.
# Gegenstueck zu python/tests/test_etappe9_slc.py und julia/test/etappe9_smoke.jl. Die Gleichheit
# mit Python und Julia prueft tools/gleichlauf/.
library(SimLev)
sl <- asNamespace("SimLev")
err <- function(expr) tryCatch({ expr; NA_character_ }, error = conditionMessage)
warns <- function(expr) {
  w <- character(0)
  withCallingHandlers(expr, warning = function(c) { w <<- c(w, conditionMessage(c)); invokeRestart("muffleWarning") })
  w
}

stopifnot(identical(simlev_seed(1), 1), identical(sl$.sl_version(), "0.1.0"))
simlev_seed(42)
# Zustand = erste vier Ausgaben von SplitMix64(42) (= java.util.SplittableRandom(42))
stopifnot(identical(sl$.sl_state_hex(), c("bdd732262feb6e95", "28efe333b266f103", "47526757130f9f52", "581ce1ff0e4ae394")),
          identical(sl$.sl_u64(2), c("15780b2e0c2ec716", "6104d9866d113a7e")))
for (b in list(1.5, "a", TRUE, 2^53))
  stopifnot(startsWith(err(simlev_seed(b)), "seed: ganze Zahl erwartet (erhalten: "))
stopifnot(identical(err(simlev_seed(1.5)), "seed: ganze Zahl erwartet (erhalten: 1.5)"))

# Reproduzierbarkeit, Stroeme, set.seed() unberuehrt
simlev_seed(7); a <- sl$.sl_runif(5)
simlev_seed(7); stopifnot(identical(sl$.sl_runif(5), a))
s <- sl$.sl_stream(7); stopifnot(identical(sl$.sl_runif(5, stream = s), a))
u <- sl$.sl_streams(sl$.sl_stream(7), 3)
stopifnot(length(unique(lapply(u, sl$.sl_state_hex))) == 3, all(sl$.sl_runif(1000, stream = u[[1]]) > 0))
set.seed(1); r1 <- stats::runif(1); simlev_seed(3); set.seed(1); stopifnot(identical(stats::runif(1), r1))
stopifnot(identical(err(sl$.sl_in_unit(sl$.sl_runif(1))), "interner Fehler: globaler Zufallszustand in paralleler Einheit"))

# Verteilungen und Meldungen
stopifnot(abs(sl$.sl_qnorm(0.975) / 1.959963984540054 - 1) < 1e-15,
          sl$.sl_pnorm(-38) > 0,
          abs(sl$.sl_lgamma(0.5) / 0.5723649429247001 - 1) < 1e-15,
          abs(sl$.sl_pt(2, 5) / 0.9490302605850709 - 1) < 1e-14,
          abs(sl$.sl_qt(0.975, 10) / 2.228138851986274 - 1) < 1e-14,
          abs(sl$.sl_pbeta(0.3, 2, 3) / 0.3483 - 1) < 1e-12)
stopifnot(identical(warns(sl$.sl_qnorm(c(2, 0.5))), "qnorm: NaN erzeugt"),
          identical(err(sl$.sl_sample(3, 5)), "sample: Stichprobe größer als die Grundgesamtheit (replace = FALSE)"))
stopifnot(is.na(sl$.sl_pnorm(NA_real_)) && !is.nan(sl$.sl_pnorm(NA_real_)))   # NA bleibt NA
cat("etappe9-smoke: ok\n")
