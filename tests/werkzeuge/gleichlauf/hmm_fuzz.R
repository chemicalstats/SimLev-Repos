# tests/werkzeuge/gleichlauf/hmm_fuzz.R – Fuzz von regime_hmm (seit 1.5.0: Baum-Welch-EM im Kern hmm_em,
# core/research_core_impl.h)
#
#   LC_ALL=C.UTF-8 R_LIBS=<R-Bibliothek> SIMLEV_FAELLE_DIR=<ordner> Rscript tests/werkzeuge/gleichlauf/hmm_fuzz.R <n> <seed>
#
# Erzeugt <n> Fälle im Format der Referenzfälle (tests/gleichlauf/erzeugen/ref_tools.R) als Modul hmm_fuzz:
# regime_hmm() mit k = 2 bis 4, 1 bis 4 Spalten, Tages- (1 bis 2 Jahre), Wochen- und Monatsdaten (2 bis 12 Jahre), Regimewechseln
# in Volatilität und Mittel, korrelierten Spalten, fast kollinearen Spalten (Startwerte scheitern an der
# Cholesky-Zerlegung), Ausreißern, NA-Kursen, n_start 1 bis 6, max_iter 0, 1, 2, 5, 40, 300, tol 0, 1e-3, 1e-7, NA,
# seed (auch NULL nach simlev_seed), dazu Eingabefehler (zu wenige Perioden, konstante Spalte); mit print()-Ausgabe.
# Warnungen und Fehler mit ihren Aufrufen (r_calls) wie sim_fuzz.R.
#
# Prüfung (tests/werkzeuge/gleichlauf/run.py, Schritt 5): abgelegte Referenz (seit 1.6.2 aus R 1.6.2, run.py --ref-erzeugen 162), R neu mit
# tests/werkzeuge/gleichlauf/sim_fuzz_cmp.py, Python und Julia mit vergleich.py/vergleich.jl gegen die Referenz.
source("tests/gleichlauf/erzeugen/ref_tools.R")
args <- commandArgs(TRUE)
N <- as.integer(args[1]); seed0 <- as.integer(if (length(args) >= 2) args[2] else 20261106)
ref_bereich("hmm_fuzz", alle = TRUE); ref_init("hmm_fuzz")

num <- function(v) sprintf("%.17g", v)
PH <- "import simlev\nimport simlev._r.fmt\nfrom simlev import regimes as RG\n"
JH <- "RG = SL.Regimes\n"
cols_all <- c("a", "b", "c", "e")

for (kk in seq_len(N)) {
  set.seed(seed0 + kk)
  freq <- pick(c("week", "week", "day", "month"))
  yrs <- if (freq == "day") pick(c(1, 1.5, 2)) else pick(c(2, 3, 5, 8, 12))
  n <- round(yrs * 365)
  d <- data.frame(date = seq.Date(as.Date("1995-01-01") + sample.int(4000, 1), by = "day", length.out = n))
  nc <- pick(c(1, 1, 2, 3, 4))
  seglen <- pick(c(60, 150, 400))
  vols <- pick(list(c(0.006, 0.02), c(0.01, 0.011), c(0.005, 0.015, 0.04), c(0.01)))
  vol <- rep(rep(vols, each = seglen), length.out = n)
  mu <- rep(rep(pick(list(c(2e-4, -5e-4), c(0, 0), c(1e-3, 0))), each = seglen), length.out = n)
  z <- matrix(rnorm(n * nc), n, nc)
  if (nc > 1 && coin(0.5)) z[, 2] <- pick(c(0.5, 0.9, 0.999999)) * z[, 1] + sqrt(1 - pick(c(0.25, 0.81))) * z[, 2]
  if (nc > 1 && coin(0.08)) z[, nc] <- z[, 1] + 1e-9 * z[, nc]                          # fast kollinear
  for (j in seq_len(nc)) {
    r <- mu + vol * z[, j] * pick(c(1, 0.3, 2))
    if (coin(0.1)) r[sample.int(n, 3)] <- pick(c(-0.3, 0.25))
    p <- 100 * exp(cumsum(r))
    if (coin(0.15)) p[sample.int(n, pick(c(1, 5)))] <- NA
    d[[cols_all[j]]] <- p
  }
  if (coin(0.03)) d[[cols_all[1]]] <- 100                                                # konstante Spalte
  cols <- cols_all[seq_len(nc)]
  k <- pick(c(2, 2, 2, 3, 3, 4))
  if (coin(0.04)) k <- pick(c(1, 2.5))
  a <- list(k = num(k))
  if (freq != "week") a$frequency <- sprintf("'%s'", freq)
  if (coin(0.6)) a$n_start <- num(pick(c(1, 2, 3, 6)))
  if (coin(0.5)) a$max_iter <- num(pick(c(1, 2, 5, 40, 300, 0)))
  if (coin(0.4)) a$tol <- pick(c("0", "1e-3", "1e-7", "NA"))
  sd <- if (coin(0.15)) "NULL" else num(sample.int(9999, 1))
  if (sd != "1") a$seed <- sd
  rv <- function(v, lang) switch(lang, r = v,
    py = if (v == "NA") "simlev._r.fmt.NA_REAL" else if (v == "NULL") "None" else v,
    jl = if (v == "NA") "SL.NA" else if (v == "NULL") "nothing" else gsub("'", "\"", v))
  ra <- paste(sprintf("%s = %s", names(a), vapply(a, rv, "", lang = "r")), collapse = ", ")
  pa <- paste(sprintf("%s=%s", names(a), vapply(a, rv, "", lang = "py")), collapse = ", ")
  ja <- paste(sprintf("%s = %s", names(a), vapply(a, rv, "", lang = "jl")), collapse = ", ")
  cr <- sprintf("c(%s)", paste(sprintf("'%s'", cols), collapse = ", "))
  cp <- sprintf("[%s]", paste(sprintf("'%s'", cols), collapse = ", "))
  cj <- sprintf("[%s]", paste(sprintf("\"%s\"", cols), collapse = ", "))
  pre <- if (sd == "NULL") c("simlev_seed(3); ", "simlev.simlev_seed(3); ", "SL.simlev_seed(3); ") else c("", "", "")
  fuzz_case(sprintf("h%05d", kk),
            r = sprintf("%sregime_hmm(d, %s, %s)", pre[1], cr, ra),
            py = sprintf("%s%sresult = RG.regime_hmm(d, %s, %s)", PH, pre[2], cp, pa),
            jl = sprintf("%s%sresult = RG.regime_hmm(d, %s; %s)", JH, pre[3], cj, ja),
            inputs = list(d = d))
}
ref_done(); ref_schreiben()
