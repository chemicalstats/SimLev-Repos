# tests/werkzeuge/gleichlauf/tariff_fuzz.R – Zufallsvergleich des Tarifkerns core/tariff_core_impl.h (seit 1.3.0) mit den
# R-Funktionen, die simulation() im Tarifweg nutzt: .tariff_income_tax, .tariff_soli und .tariff_close.
# Bitgleich (identical, NA an denselben Stellen). Der Kern rechnet in R, Python und Julia aus derselben Quelle;
# geprueft wird er hier ueber den R-Zugang .wd_tariff_check.
#
#   Rscript tests/werkzeuge/gleichlauf/tariff_fuzz.R [n] [seed]     (Standard n = 10000 je Teil, seed = 20261101)
#
# Ende 1 bei einer Abweichung. Teile: ESt und Soli je n Werte, Jahresabschluss n Faelle; jeweils mit dem
# mitgelieferten Tarif und einem abgewandelten Tarif (andere Zonen, Soli-Saetze).
suppressPackageStartupMessages(library(SimLev))
args <- commandArgs(trailingOnly = TRUE)
n <- if (length(args) >= 1) as.integer(args[1]) else 10000L
seed <- if (length(args) >= 2) as.integer(args[2]) else 20261101L
ns <- asNamespace("SimLev")
it <- get(".tariff_income_tax", ns); so <- get(".tariff_soli", ns); tc <- get(".tariff_close", ns)
chk <- get(".wd_tariff_check", ns); par_of <- get(".wd_tariff_par", ns)
set.seed(seed)

tt0 <- tax_tariff()
# abgewandelter Tarif: Zonen verschoben, andere Saetze und Soli (Plausibilitaet wie tax_tariff())
f <- tempfile(fileext = ".csv")
writeLines(c("art,ab,bezug,teiler,a,b,c",
             "zone,0,0,1,0,0,0",
             "zone,11001,11000,10000,1000.5,1400,0",
             "zone,20000,19999,10000,180.25,2500,1222.37",
             "zone,70000,0,1,0,0.43,-11700.1",
             "zone,300000,0,1,0,0.47,-26700.9",
             "soli,18000,,,5.5,12.3,"), f)
tt1 <- suppressWarnings(tax_tariff(f))

rx <- function(k) {   # Betraege ueber alle Groessenordnungen, Zonengrenzen, ganze und gebrochene Euro
  u <- runif(k)
  x <- ifelse(u < 0.15, sample(c(0, 1, 11000:11002, 12348:12350, 17799:17801, 19998:20001, 69878:69880,
                                 277825:277827, 299999:300001), k, replace = TRUE) + sample(c(0, 1e-10, -1e-10, 0.5, 0.999999), k, TRUE),
       ifelse(u < 0.3, -runif(k, 0, 5e4),
       ifelse(u < 0.85, runif(k, 0, 4e5), exp(runif(k, log(4e5), log(5e9))))))
  x
}
bad <- 0L
rep_diff <- function(what, i, a, b) {
  if (bad < 10) cat(sprintf("ABWEICHUNG %s Fall %d: R %s, Kern %s\n", what, i, format(a, digits = 17), format(b, digits = 17)))
  bad <<- bad + 1L
}
for (tt in list(tt0, tt1)) {
  nm <- if (identical(tt, tt0)) "mitgeliefert" else "abgewandelt"
  # 1. ESt
  x <- rx(n)
  a <- vapply(x, function(v) it(tt, v), 0); b <- chk(par_of(tt, 0, FALSE), x, 1L)
  for (i in which(!mapply(identical, a, b))) rep_diff("ESt", i, a[i], b[i])
  cat(sprintf("ESt (%s): %d Werte, %d gleich\n", nm, n, sum(mapply(identical, a, b))))
  # 2. Soli (auch gebrochene ESt-Betraege)
  e <- c(vapply(x[seq_len(n %/% 2)], function(v) it(tt, v), 0), rx(n - n %/% 2) / 3)
  a <- vapply(e, function(v) so(tt, v), 0); b <- chk(par_of(tt, 0, FALSE), e, 2L)
  for (i in which(!mapply(identical, a, b))) rep_diff("Soli", i, a[i], b[i])
  cat(sprintf("Soli (%s): %d Werte, %d gleich\n", nm, n, sum(mapply(identical, a, b))))
  # 3. Jahresabschluss
  same <- 0L
  for (i in seq_len(n)) {
    ck <- sample(c(0, 0.08, 0.09, runif(1, 0, 0.1)), 1)
    gp <- runif(1) < 0.6
    zve <- if (runif(1) < 0.03) NA_real_ else abs(rx(1))
    ksp <- sample(c(0, runif(1, -3000, 3000), runif(1, -50, 50)), 1)
    g23 <- if (runif(1) < 0.7) 0 else runif(1, 0, 1e5)
    kb <- sample(c(0, -runif(1, 0, 1e3), runif(1, 0, 2e4), exp(runif(1, 0, log(5e6)))), 1)
    kap <- 0.25 / (1 + 0.25 * ck)
    abg <- sample(c(0.26375, 0.25 / (1 + 0.25 * ck) * (1 + 0.055 + ck), runif(1, 0, 0.5)), 1)
    env <- new.env(parent = emptyenv())
    env$tariff <- tt; env$zve_all <- zve; env$zve <- NULL
    env$ks <- stats::setNames(ksp, "2030"); env$church_k <- ck; env$kapest_rate <- kap; env$use_gp <- gp
    env$rows <- list(); env$refund_due <- 0
    D <- tc(env, 2030L, g23, kb, abg)
    rr <- if (length(env$rows)) {
      rw <- env$rows[[1]]; rw$guenstiger <- as.numeric(rw$guenstiger); v <- unlist(rw[1, ], use.names = FALSE)
      v[1] <- NA_real_; v
    } else rep(NA_real_, 25)
    p <- par_of(tt, ck, gp)
    cc <- chk(p, matrix(c(zve, ksp, g23, kb, abg), 1), 3L)[1, ]
    ok <- identical(rr, cc) && (if (is.na(D)) is.na(cc[23]) else identical(D, cc[23])) &&
          (is.na(zve) || identical(unname(env$ks["2031"]), cc[25]))
    if (ok) same <- same + 1L else rep_diff("Jahresabschluss", i, rr, cc)
  }
  cat(sprintf("Jahresabschluss (%s): %d Fälle, %d gleich\n", nm, n, same))
}
cat(sprintf("GESAMT %s (%d Abweichungen)\n", if (bad) "ABWEICHUNG" else "gleich", bad))
quit(status = if (bad) 1L else 0L)
