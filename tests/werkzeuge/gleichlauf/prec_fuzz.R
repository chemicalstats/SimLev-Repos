# tests/werkzeuge/gleichlauf/prec_fuzz.R – Fuzz der genaueren Formeln (seit 1.6.2): expm1, log1p, CAGR q^(1/T) - 1 als
# expm1(log(q) / T), (1 + x)^e - 1 als expm1(log1p(x) e), Periodenaggregation prod(1 + x) - 1 als expm1(sum(log1p(x))),
# log(1 - r^2) der Gauss- und t-Copula (r/R/utils.R .cagr_q, .pow1m, .geo_ret, .geo_ann, .log1mr2; Python simlev._util,
# Julia util.jl; Kern evaluate_core_impl.h cagr_q, slc_tcop.cpp log1mr2_).
#
#   LC_ALL=C.UTF-8 R_LIBS=<R-Bibliothek> SIMLEV_FAELLE_DIR=<ordner> Rscript tests/werkzeuge/gleichlauf/prec_fuzz.R <n> <seed>
#
# Erzeugt <n> Fälle im Format der Referenzfälle (tests/gleichlauf/erzeugen/ref_tools.R) als Modul prec_fuzz:
#   70 % Formeln direkt, je Fall ein Vektor von 40 Werten mit kleinen (bis 1e-12), üblichen und großen Renditen
#        (bis 1e6), Rändern (0, -1, < -1, Inf, NA, NaN, T = 0, Inf, negativ): expm1, log1p, .cagr_q, .pow1m,
#        .geo_ret, .geo_ann, .log1mr2 (r bis 1 - 1e-15);
#   30 % Kennzahlen: simulation() (cagr, ttwror; Kern), result_heatmap, copula_fit (Gauss und t, |rho| nahe 1),
#        backcast_fit mit accrual = "geometric" und Diagnose, signal_analysis.
# Warnungen und Fehler mit ihren Aufrufen (r_calls) wie sim_fuzz.R.
#
# Genauigkeit (nur R, Rmpfr mit 256 Bit): für die Formeln je Fall der Fehler in ulp des exakten Werts (an der Stelle
# der double-Eingabe); Zeilen "Genauigkeit <formel>: Median, 99 %, max ulp (neu) | max ulp (Formel bis 1.6.1)". Ende 1,
# wenn die neue Formel schlechter ist als 1 + 3 cond ulp (cond = Kondition der Funktion an der Stelle, für expm1/log1p
# 1 ulp; Fälle mit endlichem, von 0 verschiedenem exaktem Wert).
#
# Prüfung (tests/werkzeuge/gleichlauf/run.py, Schritt 5): abgelegte Referenz (seit 1.6.2 aus R 1.6.2, run.py --ref-erzeugen 162),
# R neu mit tests/werkzeuge/gleichlauf/sim_fuzz_cmp.py, Python und Julia mit vergleich.py/vergleich.jl gegen die Referenz.
source("tests/gleichlauf/erzeugen/ref_tools.R")
suppressMessages(library(Rmpfr))
args <- commandArgs(TRUE)
N <- as.integer(args[1]); seed0 <- as.integer(if (length(args) >= 2) args[2] else 20261123)
ref_bereich("prec_fuzz", alle = TRUE); ref_init("prec_fuzz")
pick <- function(x) x[[sample.int(length(x), 1L)]]
coin <- function(p) runif(1) < p

fuzz_case <- function(id, r, py, jl, inputs) {
  ref_case(id, r = r, py = py, jl = jl, inputs = inputs)
  if (!.ref_in_subset(id)) return(invisible(NULL))
  env <- new.env(parent = globalenv())
  for (k in names(inputs)) assign(k, inputs[[k]], envir = env)
  dp <- function(x) if (is.null(x)) "NULL" else paste(deparse(x), collapse = " ")
  wc <- character(0); ec <- NULL
  invisible(capture.output(tryCatch(withCallingHandlers(eval(parse(text = r), envir = env),
    warning = function(w) { wc <<- c(wc, dp(conditionCall(w))); invokeRestart("muffleWarning") },
    message = function(m) invokeRestart("muffleMessage")),
    error = function(e) ec <<- dp(conditionCall(e)))))
  ref_case_extra(list(r_calls = list(warnings = as.list(wc), error = ec)))
}

# ── Zufallswerte ──
ret_small <- function(n) sample(c(-1, 1), n, TRUE) * 10^runif(n, -12, -1)
ret_any <- function(n) { k <- sample(1:4, n, TRUE)
  ifelse(k == 1, ret_small(n), ifelse(k == 2, rnorm(n, 0, 0.05), ifelse(k == 3, runif(n, -0.99, 3), 10^runif(n, 0, 6)))) }
edges <- function(x, p, vals) { m <- runif(length(x)) < p; if (any(m)) x[m] <- sample(vals, sum(m), TRUE); x }
EDGE_X <- c(0, -0, -1, -1.5, Inf, -Inf, NA, NaN, 1e-300, -1e-300)
EDGE_T <- c(0, Inf, -Inf, NA, -2, 1e-3)

# ── Genauigkeit gegen Rmpfr ──
B <- 256L
ulp_err <- function(x, ex) {                       # |x - ex| in ulp(ex); nur endliche, von 0 verschiedene ex
  e <- asNumeric(ex); ok <- is.finite(e) & e != 0 & is.finite(x)
  u <- rep(NA_real_, length(x))
  if (any(ok)) u[ok] <- asNumeric(abs(mpfr(x[ok], B) - ex[ok])) / 2^(floor(log2(abs(e[ok]))) - 52)
  u
}
expm1_m <- function(z) { z <- mpfr(z, B); exp(z) - 1 }
cond_expm1 <- function(z) ifelse(abs(z) < 1e-300, 1, abs(z * exp(z) / expm1(z)))
GEN <- new.env(); GEN$acc <- list()
acc_add <- function(name, new, old, ex, cond) {
  u <- ulp_err(new, ex); uo <- ulp_err(old, ex)
  ok <- !is.na(u) & is.finite(cond)
  bad <- ok & u > 1 + 3 * cond
  GEN$acc[[name]] <- rbind(GEN$acc[[name]], data.frame(u = u[ok], uo = uo[ok], bad = bad[ok]))
}

q_r <- function(v) paste(deparse(v), collapse = "")
for (kk in seq_len(N)) suppressWarnings({
  set.seed(seed0 + kk)
  if (kk %% 10 < 7) {
    typ <- pick(c("expm1", "log1p", "cagr", "pow1m", "geo_ret", "geo_ann", "log1mr2"))
    m <- 40L
    if (typ %in% c("expm1", "log1p")) {
      x <- if (typ == "expm1") c(ret_small(20), rnorm(10, 0, 3), runif(10, -700, 700)) else c(ret_small(20), runif(10, -1, 3), 10^runif(10, 0, 300))
      x <- edges(x, 0.05, if (typ == "log1p") setdiff(EDGE_X, c(-1.5, -Inf)) else EDGE_X)   # log1p(< -1): R warnt
      fuzz_case(sprintf("%s%05d", substr(typ, 1, 2), kk), r = sprintf("%s(x)", typ),
                py = sprintf("result = simlev._r.libm.%s(x)", typ), jl = sprintf("result = SL.RLibm.%s(x)", typ),
                inputs = list(x = x))
      if (typ == "expm1") acc_add("expm1", expm1(x), exp(x) - 1, expm1_m(x), rep(1, m))
      else { ex <- log1p(mpfr(x, B)); acc_add("log1p", log1p(x), log(1 + x), ex, rep(1, m)) }
    } else if (typ %in% c("cagr", "pow1m")) {
      x <- if (typ == "cagr") 1 + ret_any(m) else ret_any(m)
      x[x <= 0 & typ == "cagr"] <- abs(x[x <= 0 & typ == "cagr"])
      t <- pick(list(runif(m, 0.01, 60), 10^runif(m, -2, 2), sample(c(1, 2, 5, 10, 20, 30), m, TRUE), 252 / sample(1:5000, m, TRUE)))
      x <- edges(x, 0.04, EDGE_X); t <- edges(t, 0.04, EDGE_T)
      f <- if (typ == "cagr") ".cagr_q" else ".pow1m"; fp <- if (typ == "cagr") "_cagr_q" else "_pow1m"
      fuzz_case(sprintf("%s%05d", substr(typ, 1, 2), kk),
                r = sprintf("vapply(seq_along(x), function(i) SimLev:::%s(x[i], t[i]), 0)", f),
                py = sprintf("result = np.array([simlev._util.%s(a, b) for a, b in zip(x, t)])", fp),
                jl = sprintf("result = [SL.%s(a, b) for (a, b) in zip(x, t)]", fp),
                inputs = list(x = x, t = t))
      new <- vapply(seq_along(x), function(i) get(f, asNamespace("SimLev"))(x[i], t[i]), 0)
      if (typ == "cagr") { old <- x^(1 / t) - 1; z <- log(mpfr(x, B)) / mpfr(t, B) }
      else { old <- (1 + x)^t - 1; z <- log1p(mpfr(x, B)) * mpfr(t, B) }
      ok <- is.finite(x) & is.finite(t) & t != 0 & x >= ifelse(typ == "cagr", 0, -1) & x != ifelse(typ == "cagr", 0, -1)
      zz <- asNumeric(z); cnd <- ifelse(ok, cond_expm1(zz), NA)
      # Eingabe exakt (double); log bzw. log1p und Produkt/Quotient stören z relativ um etwa 1 ulp: Kondition von expm1 in z
      ex <- expm1(z); ex[!ok] <- mpfr(NA, B)
      acc_add(typ, new, old, ex, cnd)
    } else if (typ %in% c("geo_ret", "geo_ann")) {
      x <- pick(list(ret_small(m), rnorm(m, 0, 0.01), rnorm(m, 0, 0.1), runif(m, -0.5, 0.5)))
      if (coin(0.05)) x[sample.int(m, 1)] <- pick(c(-1, -1.2, NA, NaN, Inf))
      t <- pick(c(1, 0.25, 3.7, 10, 40, 0, Inf))
      if (typ == "geo_ret") {
        fuzz_case(sprintf("gr%05d", kk), r = "SimLev:::.geo_ret(x)", py = "result = simlev._util._geo_ret(x)",
                  jl = "result = SL._geo_ret(x)", inputs = list(x = x))
        new <- SimLev:::.geo_ret(x); old <- prod(1 + x) - 1; z <- sum(log1p(mpfr(x, B)))
      } else {
        fuzz_case(sprintf("ga%05d", kk), r = sprintf("SimLev:::.geo_ann(x, %s)", q_r(t)),
                  py = sprintf("result = simlev._util._geo_ann(x, %s)", if (is.infinite(t)) "math.inf" else format(t)),
                  jl = sprintf("result = SL._geo_ann(x, %s)", if (is.infinite(t)) "Inf" else format(t)), inputs = list(x = x))
        new <- SimLev:::.geo_ann(x, t); old <- prod(1 + x)^(1 / t) - 1; z <- sum(log1p(mpfr(x, B))) / t
      }
      ok <- all(is.finite(x)) && all(x > -1) && is.finite(t) && t != 0
      if (ok) {
        # Kondition der Summe der Logarithmen: sum |log1p(x_i)| / |sum log1p(x_i)| (Auslöschung der Summe)
        lx <- asNumeric(log1p(mpfr(x, B))); cs <- sum(abs(lx)) / max(abs(sum(lx)), 1e-300)
        acc_add(typ, new, old, expm1(z), cond_expm1(asNumeric(z)) * cs)
      }
    } else {
      r <- pick(list(runif(m, -1, 1), sample(c(-1, 1), m, TRUE) * (1 - 10^runif(m, -15, -1)), ret_small(m), tanh(runif(m, -20, 20))))
      r <- edges(r, 0.03, c(0, 1, -1, NA, NaN, 0.5^0.5))
      fuzz_case(sprintf("lr%05d", kk), r = "vapply(r, SimLev:::.log1mr2, 0)",
                py = "result = np.array([simlev._util._log1mr2(v) for v in r])", jl = "result = [SL._log1mr2(v) for v in r]",
                inputs = list(r = r))
      ok <- is.finite(r) & abs(r) < 1
      rm <- mpfr(r, B); ex <- log(1 - rm * rm); ex[!ok] <- mpfr(NA, B)
      acc_add("log1mr2", vapply(r, SimLev:::.log1mr2, 0), log(1 - r^2), ex, ifelse(ok, 1, NA))
    }
  } else {
    typ <- pick(c("sim", "heatmap", "copula", "backcast", "signal"))
    if (typ == "sim") {
      n <- pick(c(300, 800, 3000)); d <- data.frame(date = seq.Date(as.Date("2001-01-01") + sample(0:2000, 1), by = "day", length.out = n))
      mu <- pick(c(0, 1e-6, 2e-4, -3e-4)); d$A <- round(100 * cumprod(1 + rnorm(n, mu, pick(c(1e-5, 0.01, 0.03)))), pick(c(2, 6, 10)))
      dca <- coin(0.5)
      fuzz_case(sprintf("si%05d", kk),
        r = sprintf("r <- simulation(d, create_strategy(A = asset_config('etf', 'bnh')), start_value = 1000%s); c(r$cagr, r$ttwror)",
                    if (dca) ", dca = dca_plan(value = 50, span = 1)" else ""),
        py = sprintf("r = simlev.simulation(d, simlev.create_strategy(A=simlev.asset_config(asset_class='etf', trading='bnh')), start_value=1000%s)\nresult = np.array([r['cagr'], r['ttwror']])",
                     if (dca) ", dca=simlev.dca_plan(value=50, span=1)" else ""),
        jl = sprintf("r = SL.simulation(d, SL.create_strategy(\"A\" => SL.asset_config(\"etf\", \"bnh\")); start_value = 1000%s)\nresult = [r[\"cagr\"], r[\"ttwror\"]]",
                     if (dca) ", dca = SL.dca_plan(value = 50, span = 1)" else ""),
        inputs = list(d = d))
    } else if (typ == "heatmap") {
      by <- pick(c("week", "day", "month")); n <- switch(by, week = 52 * pick(c(3, 8, 15)) + 7, day = 365 * pick(c(3, 6)) + 9, month = 12 * pick(c(4, 20)) + 1)
      wk <- data.frame(date = seq.Date(as.Date("2005-01-01"), by = by, length.out = n))
      wk$value <- 100 * cumprod(1 + rnorm(n, pick(c(0, 1e-7, 1.5e-3)), pick(c(1e-6, 0.02))))
      fuzz_case(sprintf("hm%05d", kk), r = "result_heatmap(wk)", py = "result = simlev.result_heatmap(wk)",
                jl = "result = SL.result_heatmap(wk)", inputs = list(wk = wk))
    } else if (typ == "copula") {
      n <- pick(c(30, 200, 800)); rho <- pick(c(0.999, -0.9999, 0.99999, 0.3, 1 - 1e-9))
      z1 <- rnorm(n); z2 <- rho * z1 + sqrt(1 - rho^2) * rnorm(n)
      if (coin(0.5)) { w <- sqrt(pick(c(3, 6)) / rchisq(n, pick(c(3, 6)))); z1 <- z1 * w; z2 <- z2 * w }
      fam <- pick(c("gaussian", "t"))
      fuzz_case(sprintf("co%05d", kk), r = sprintf("copula_fit(x, y, families = '%s')", fam),
                py = sprintf("result = simlev.copula_fit(x, y, families=['%s'])", fam),
                jl = sprintf("result = SL.copula_fit(x, y; families = [\"%s\"])", fam), inputs = list(x = z1, y = z2))
    } else if (typ == "backcast") {
      n <- pick(c(400, 1200)); dt <- seq.Date(as.Date("2010-01-04"), by = "day", length.out = n)
      ri <- rnorm(n, 3e-4, 0.01); ter <- pick(c(0.07, 0.5, 2)); lev <- pick(c(1, 2, -1))
      s <- data.frame(date = dt, idx = 100 * cumprod(1 + ri), rate = pick(c(0, 1.5)))
      s$etf <- 50 * cumprod(1 + lev * ri - ter / 100 / 365 + rnorm(n, 0, 1e-4))
      fuzz_case(sprintf("bc%05d", kk),
        r = sprintf("f <- backcast_fit(s, 'etf', 'idx', ter = %s, leverage = %s, rate = 'rate', accrual = 'geometric'); f[c('fitted', 'diagnostics')]", ter, lev),
        py = sprintf("f = simlev.backcast_fit(s, 'etf', 'idx', ter=%s, leverage=%s, rate='rate', accrual='geometric')\nresult = {k: f[k] for k in ('fitted', 'diagnostics')}", ter, lev),
        jl = sprintf("f = SL.backcast_fit(s, \"etf\", \"idx\"; ter = %s, leverage = %s, rate = \"rate\", accrual = \"geometric\")\nresult = SL.RList(\"fitted\" => f[\"fitted\"], \"diagnostics\" => f[\"diagnostics\"])", ter, lev),
        inputs = list(s = s))
    } else {
      n <- pick(c(600, 1500)); d <- data.frame(date = seq.Date(as.Date("2003-01-01"), by = "day", length.out = n))
      d$aktien <- 100 * cumprod(1 + rnorm(n, pick(c(1e-6, 3e-4)), pick(c(1e-4, 0.01))))
      d$mom <- c(rep(NA, 20), diff(log(d$aktien), lag = 20)); h <- pick(c(5, 21, 63))
      fuzz_case(sprintf("sa%05d", kk), r = sprintf("signal_analysis(d, 'mom', 'aktien', horizon = %d, bins = 4)", h),
                py = sprintf("result = simlev.signal_analysis(d, 'mom', 'aktien', horizon=%d, bins=4)", h),
                jl = sprintf("result = SL.signal_analysis(d, \"mom\", \"aktien\"; horizon = %d, bins = 4)", h),
                inputs = list(d = d))
    }
  }
})
ref_done(); ref_schreiben()
# Genauigkeit
schlecht <- 0L
for (nm in names(GEN$acc)) {
  a <- GEN$acc[[nm]]
  q <- function(v) if (length(v)) stats::quantile(v, c(0.5, 0.99, 1), names = FALSE, na.rm = TRUE) else rep(NA, 3)
  qn <- q(a$u); qo <- q(a$uo[is.finite(a$uo)])
  cat(sprintf("Genauigkeit %-8s %6d Werte: neu Median %.2f, 99 %% %.2f, max %.3g ulp | bis 1.6.1 Median %.3g, 99 %% %.3g, max %.3g ulp%s\n",
              nm, nrow(a), qn[1], qn[2], qn[3], qo[1], qo[2], qo[3], if (any(a$bad)) sprintf("  SCHLECHTER als 1 + 3 cond: %d", sum(a$bad)) else ""))
  schlecht <- schlecht + sum(a$bad)
}
if (schlecht) quit(status = 1)
