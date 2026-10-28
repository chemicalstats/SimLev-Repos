# Referenzfälle für die aus imputeTS 3.4 und stinepack 1.5 übernommene Fassung von
# na_interpolation (option = "stine" und "linear"), na_locf und stinterp (R: SimLev:::.imputets_na_interpolation,
# .imputets_na_locf in r/R/vendor_imputets.R mit dem C++-Kern locf in r/src/vendor_imputets.cpp,
# SimLev:::.stinepack_stinterp in r/R/vendor_stinepack.R; Python: simlev/_r/imputets.py,
# simlev/_r/stinepack.py; Julia: src/r/imputets.jl, src/r/stinepack.jl) sowie den Stineman-Weg
# in .fill_na / backcast_fit(index_fill = "stine") / backcast(fill = "stine"). imputeTS und
# stinepack selbst werden nicht benötigt; die Fälle waren zuvor mit den echten Paketen erzeugt
# und sind mit der Übernahme bitgleich.
# Aufruf aus der Repo-Wurzel:
#   LC_ALL=C.UTF-8 R_LIBS=<R-Bibliothek mit SimLev> Rscript golden/modules/gen_imputets.R
source("golden/modules/ref_tools.R"); ref_init("imputets")

P <- "import numpy as np\nimport pandas as pd\nfrom simlev._r import imputets as I\nfrom simlev._r import stinepack as S\nfrom simlev import backcast as BC\nNA = simlev.NA\n"
JP <- "const I = SL.RImputeTS\nconst S = SL.RStinepack\nconst BC = SL.Backcast\nconst NA = SL.NA\n"
case <- function(id, r, py, jl, inputs = list(), ...)
  ref_case(id, r = r, py = paste0(P, py), inputs = inputs, jl = paste0(JP, jl), ...)

# Argumentwerte je Sprache formatieren
fv <- function(v, lang) {
  if (is.character(v)) {
    q <- if (lang == "py") "'" else if (lang == "jl") '"' else "'"
    s <- paste0(q, v, q)
    s[is.na(v)] <- if (lang == "r") "NA_character_" else if (lang == "py") "NA" else "missing"
  } else if (is.logical(v)) {
    s <- if (lang == "r") as.character(v) else if (lang == "py") ifelse(v, "True", "False") else ifelse(v, "true", "false")
    s[is.na(v)] <- if (lang == "r") "NA" else if (lang == "py") "None" else "missing"
  } else {
    s <- ifelse(is.na(v), if (lang == "r") "NA" else if (lang == "py") "NA" else "NA",
                ifelse(is.infinite(v), ifelse(v > 0, if (lang == "py") "np.inf" else "Inf", if (lang == "py") "-np.inf" else "-Inf"),
                       sprintf("%.17g", v)))
    if (lang != "r") s <- ifelse(grepl("^-?[0-9]+$", s), paste0(s, ".0"), s)
  }
  if (length(v) == 1) return(s)
  if (lang == "r") paste0("c(", paste(s, collapse = ", "), ")") else paste0("[", paste(s, collapse = ", "), "]")
}
fargs <- function(a, lang) {
  if (!length(a)) return("")
  nm <- names(a)
  if (lang == "py") nm <- gsub(".", "_", nm, fixed = TRUE)
  paste0(", ", paste(sprintf(if (lang == "py") "%s=%s" else "%s = %s", nm, vapply(a, fv, "", lang = lang)), collapse = ", "))
}

# na_interpolation(v, ...) mit v als Eingabe
NI <- function(id, v, args = list(option = "stine"), inputs = list(v = v)) {
  ra <- fargs(args, "r"); pa <- fargs(args, "py"); ja <- fargs(args, "jl")
  case(paste0("ni_", id), paste0("SimLev:::.imputets_na_interpolation(v", ra, ")"),
       paste0("result = I.na_interpolation(v", pa, ")"),
       paste0("result = I.na_interpolation(v; ", substring(ja, 3), ")"), inputs)
}
# stinterp(x, y, xout, ...)
ST <- function(id, x, y, xout, args = list()) {
  ra <- fargs(args, "r"); pa <- fargs(args, "py"); ja <- fargs(args, "jl")
  case(paste0("st_", id), paste0("SimLev:::.stinepack_stinterp(x, y, xo", ra, ")"),
       paste0("result = S.stinterp(x, y, xo", pa, ")"),
       paste0("result = S.stinterp(x, y, xo", if (nzchar(ja)) paste0("; ", substring(ja, 3)) else "", ")"),
       list(x = x, y = y, xo = xout))
}

# ── Reihen ──────────────────────────────────────────────────────────────────
set.seed(1); mono <- cumsum(rexp(40))                       # monoton steigend
osc <- sin(seq(0, 6 * pi, length.out = 60)) * 10            # oszillierend
set.seed(2); rw <- 100 * cumprod(1 + rnorm(120, 0, 0.02))  # Kursreihe
stp <- rep(c(1, 1, 1, 5, 5, 5, 2, 2, 2, 2), 3)             # Stufen (Steigung 0)
lin <- 3 + 0.5 * (1:30)                                     # linear (exakt)
quad <- ((1:30) - 12)^2                                     # Parabel mit Minimum
set.seed(3); noisy <- rnorm(80)                             # Rauschen
dec <- rev(mono)                                            # monoton fallend
gaps <- function(x, idx) { x[idx] <- NA; x }

# ── na_interpolation(…, option = "stine"): Lückenmuster ───────────────────
S1 <- list(mono = mono, osc = osc, rw = rw, stp = stp, lin = lin, quad = quad, noisy = noisy, dec = dec)
for (nm in names(S1)) {
  x <- S1[[nm]]; n <- length(x)
  NI(paste0(nm, "_single"), gaps(x, seq(3, n - 2, by = 5)))
  NI(paste0(nm, "_long"), gaps(x, c(4:12, (n - 9):(n - 3))))
  NI(paste0(nm, "_lead"), gaps(x, c(1:3, 10:11)))
  NI(paste0(nm, "_trail"), gaps(x, c(15, (n - 4):n)))
  NI(paste0(nm, "_both"), gaps(x, c(1:2, 7, 8, n - 1, n)))
  NI(paste0(nm, "_alt"), gaps(x, seq(2, n, by = 2)))
}
for (k in 1:12) {                                           # zufällige Lücken
  set.seed(100 + k); n <- c(15, 50, 200, 800, 2000, 37)[(k - 1) %% 6 + 1]
  x <- cumsum(rnorm(n, 0, c(1, 0.01, 50)[(k - 1) %% 3 + 1]))
  p <- c(0.1, 0.3, 0.6, 0.85)[(k - 1) %% 4 + 1]
  x[runif(n) < p] <- NA
  if (sum(!is.na(x)) < 2) x[c(1, n)] <- c(1, 2)
  NI(sprintf("rand%02d", k), x)
}
# kurze Reihen, wenige Werte
NI("len2_lead", c(NA, 1, 2))
NI("len3_mid", c(1, NA, 3))
NI("len3_trail", c(1, 2, NA))
NI("two_known", c(NA, NA, 2, NA, NA, NA, 7, NA))
NI("two_known_neg", c(5, NA, NA, -3))
NI("three_known", c(1, NA, 4, NA, NA, 2))
NI("three_known_mono", c(NA, 1, NA, 2, NA, NA, 10, NA))
NI("const", c(2, NA, 2, 2, NA, NA, 2))
NI("const_neg0", c(-0, NA, 0, NA, -0))
NI("zero_slope_ends", c(1, 1, NA, 3, 3, NA, 3))
NI("peak", c(0, NA, 10, NA, 0, NA, 10))
NI("nan", c(1, NaN, 3, NA, 5, 2))
NI("int", c(1L, NA, 4L, NA, NA, 10L, 9L))
NI("int_lead", c(NA, NA, 3L, 1L, NA, 7L, NA))
NI("named", c(a = 1, b = NA, c = 3, d = NA, e = 2))
NI("big", c(1e300, NA, 3e300, NA, -1e300, 2e300))
NI("tiny", c(1e-300, NA, 3e-300, NA, 2e-300, 5e-300))
NI("denorm", c(1e-310, NA, 3e-310, NA, 2e-310, 5e-310))
NI("scale_mix", c(1e-8, NA, 1e8, NA, 1, NA, -1e8))
NI("uneq", c(1, NA, NA, NA, NA, NA, NA, 2, 3, NA, 10, 11))
# keine NA / leer
NI("nona", c(1, 2, 3))
NI("nona_int", 1:4)
NI("empty", numeric(0))
# maxgap
x <- c(1, NA, NA, NA, 5, NA, 7, NA, NA, 3, NA)
NI("maxgap2", x, list(option = "stine", maxgap = 2))
NI("maxgap0", x, list(option = "stine", maxgap = 0))
NI("maxgap1", x, list(option = "stine", maxgap = 1))
NI("maxgap_neg", x, list(option = "stine", maxgap = -1))
NI("maxgap_frac", x, list(option = "stine", maxgap = 2.5))
NI("maxgap_na", x, list(option = "stine", maxgap = NA_real_))
NI("maxgap_inf", x, list(option = "stine", maxgap = Inf))
# Argumente für stinterp
x <- gaps(osc[1:30], c(2, 5:7, 13, 20:24, 30))
NI("m_stineman", x, list(option = "stine", method = "stineman"))
NI("m_parabola", x, list(option = "stine", method = "parabola"))
NI("m_scaled", x, list(option = "stine", method = "scaledstineman"))
NI("m_partial", x, list(option = "stine", method = "par"))
NI("m_partial_st", x, list(option = "stine", method = "st"))
NI("m_ambig", x, list(option = "stine", method = "s"))
NI("m_bad", x, list(option = "stine", method = "spline"))
NI("m_two", x, list(option = "stine", method = c("parabola", "stineman")))
NI("m2_parabola", c(NA, 1, NA, 4, NA), list(option = "stine", method = "parabola"))
NI("m3_parabola", c(NA, 1, NA, 4, NA, 2), list(option = "stine", method = "parabola"))
NI("m3_stineman", c(NA, 1, NA, 4, NA, 2), list(option = "stine", method = "stineman"))
NI("yp", c(NA, 1, NA, 4, NA, NA, 2), list(option = "stine", yp = c(0, 0, 0)))
NI("yp_steep", c(1, NA, 4, NA, NA, 2), list(option = "stine", yp = c(5, -1, 2)))
NI("yp_len", c(1, NA, 4, NA, NA, 2), list(option = "stine", yp = c(5, -1)))
NI("yp_na", c(1, NA, 4, NA, NA, 2), list(option = "stine", yp = c(5, NA, 1)))
NI("yp_method", c(1, NA, 4, NA, NA, 2), list(option = "stine", yp = c(5, 1, 1), method = "parabola"))
# option = "linear"
NI("lin_osc", gaps(osc, c(1:3, 10:20, 58:60)), list(option = "linear"))
NI("lin_int", c(NA, 2L, NA, NA, 8L, NA), list())
NI("lin_maxgap", c(1, NA, NA, NA, 5, NA, 7), list(option = "linear", maxgap = 1))
# Fehler und Sonderwerte
NI("err_allna", c(NA_real_, NA_real_, NA_real_))
NI("err_one", c(NA, 1, NA))
NI("err_chr", c("a", NA, "b"))
NI("err_chr_one", c("a", NA))
NI("err_lgl", c(TRUE, NA, FALSE))
NI("err_option", c(1, NA, 3), list(option = "foo"))
NI("err_option2", c(1, NA, 3), list(option = c("stine", "linear")))
NI("err_option_na", c(1, NA, 3), list(option = NA_character_))
NI("err_inf", c(1, NA, Inf, NA, 9))
NI("err_inf2", c(Inf, NA, Inf, NA))
NI("err_inf3", c(Inf, NA, -Inf, NA, 3))
NI("err_inf_big", c(1, 2, 1e308, NA, -1e308, 3))
NI("err_inf_m2", c(1, NA, Inf))
NI("inf_nogap", c(Inf, 1, 2))
# Matrizen
NI("mat2", matrix(c(1, NA, 3, NA, 5, 4, NA, NA, 1, 2), 5))
NI("mat_fail", matrix(c(1, NA, 3, 4, 5, NA, NA, NA, 1, NA), 5))
NI("mat_nona", matrix(c(1, 2, 3, 4, NA, 6), 3))
NI("mat1", matrix(c(1, NA, NA, 7, 2), 5))
NI("mat1_maxgap", matrix(c(1, NA, NA, 7, 2), 5), list(option = "stine", maxgap = 1))
NI("mat_maxgap", matrix(c(1, NA, NA, 7, 2, NA, 1, NA, 3, 4), 5), list(option = "stine", maxgap = 1))
NI("mat_method", matrix(c(1, NA, 4, NA, 2, 5, 1, NA, 3, 4), 5), list(option = "stine", method = "parabola"))
NI("mat_one_err", matrix(c(NA, NA, NA, 1, 2, 3), 3))

# ── na_locf direkt ──────────────────────────────────────────────────────────
NL <- function(id, v, args = list()) {
  ra <- fargs(args, "r"); pa <- fargs(args, "py"); ja <- fargs(args, "jl")
  case(paste0("nl_", id), paste0("SimLev:::.imputets_na_locf(v", ra, ")"), paste0("result = I.na_locf(v", pa, ")"),
       paste0("result = I.na_locf(v", if (nzchar(ja)) paste0("; ", substring(ja, 3)) else "", ")"), list(v = v))
}
NL("basic", c(NA, 1, NA, NA, 3, NA))
NL("nocb", c(NA, 1, NA, NA, 3, NA), list(option = "nocb"))
NL("keep", c(NA, 1, NA, NA, 3, NA), list(na_remaining = "keep"))
NL("nocb_keep", c(NA, 1, NA, NA, 3, NA), list(option = "nocb", na_remaining = "keep"))
NL("inf", c(NA, 1, Inf, NA, NaN, 2, NA))
NL("inf_nocb", c(NA, -Inf, 1, NA, Inf, NA), list(option = "nocb"))
NL("maxgap", c(NA, 1, NA, NA, 3, NA), list(maxgap = 1))
NL("int", c(NA, 2L, NA, 5L))
NL("err_allna", c(NA_real_, NA_real_))
NL("err_chr", c("a", NA))
NL("err_option", c(1, NA), list(option = "x"))
NL("err_rem", c(NA, 1, NA), list(na_remaining = "x"))
NL("nona", c(1, 2))

# ── stinterp direkt ─────────────────────────────────────────────────────────
xs <- c(1, 2, 4, 5, 7.5, 8, 11)
ys <- c(1, 3, 3, 4, 0, 2, 2.5)
xo <- c(0, 0.5, 1, 1.5, 2.5, 3.5, 4, 5, 6, 7.5, 7.9, 9.5, 11, 11 + 1e-15, 11 + 1e-13, 12, 1 - 1e-15, 1 - 1e-13)
ST("basic", xs, ys, xo)
ST("stineman", xs, ys, xo, list(method = "stineman"))
ST("parabola", xs, ys, xo, list(method = "parabola"))
ST("yp", xs, ys, xo, list(yp = c(1, 0, 0, -1, 0, 1, 0)))
ST("m2", c(1, 3), c(2, 5), c(0, 1, 2, 3, 4))
ST("m2_yp", c(1, 3), c(2, 5), c(1, 1.5, 2, 2.5, 3), list(yp = c(0, 0)))
ST("m2_parabola", c(1, 3), c(2, 5), c(1, 2, 3), list(method = "parabola"))
ST("m3", c(0, 1, 3), c(0, 1, 0), seq(0, 3, by = 0.25))
ST("int", 1:6, c(1L, 4L, 2L, 2L, 8L, 3L), c(1.5, 2.5, 5.5, 6))
ST("neg0", c(-1, 0, 1), c(1, 0, 1), c(-0, 0, -0.5))
set.seed(4); ST("dense", sort(c(0, cumsum(rexp(50)))), sin(seq(0, 10, length.out = 51)), seq(0, 40, by = 0.37))
ST("const_y", 1:5, rep(3, 5), c(1.5, 4.5))
ST("ymono", 1:8, cumsum(1:8)^2, seq(1, 8, by = 0.5))
ST("y_na_par", c(1, 2, 3, 4), c(1, NA, 3, 4), c(2.5), list(method = "parabola"))
ST("y_na_par3", c(1, 2, 3, 4), c(1, NA, 3, 4), c(1.5, 2.5, 3.5), list(method = "parabola"))
ST("y_na", c(1, 2, 3, 4), c(1, NA, 3, 4), c(1.5))
ST("err_short", 1, 1, 1.5)
ST("err_len", c(1, 2), 1, 1.5)
ST("err_xna", c(1, NA, 3), c(1, 2, 3), 1.5)
ST("err_xona", c(1, 2, 3), c(1, 2, 3), c(1.5, NA))
ST("err_dup", c(1, 1, 3), c(1, 2, 3), 1.5)
ST("err_dec", c(1, 3, 2), c(1, 2, 3), 1.5)
ST("err_chr", c(1, 2), c("a", "b"), 1.5)
ST("err_yp_len", c(1, 2), c(1, 2), 1.5, list(yp = 1))
ST("err_yp_na", c(1, 2), c(1, 2), 1.5, list(yp = c(1, NA)))
ST("err_yp_chr", c(1, 2), c(1, 2), 1.5, list(yp = "a"))
ST("err_yp_method", c(1, 2), c(1, 2), 1.5, list(yp = c(0, 0), method = "stineman"))
ST("err_method", c(1, 2, 3), c(1, 2, 5), 1.5, list(method = "foo"))
ST("err_inf_x", c(-Inf, 2, 3), c(1, 2, 5), 1.5)
ST("err_inf_x2", c(Inf, Inf), c(1, 2), 1.5)
case("st_err_mat", "SimLev:::.stinepack_stinterp(matrix(1:2), c(1, 2), 1.5)", "result = S.stinterp(np.array([[1.0], [2.0]]), [1.0, 2.0], 1.5)",
     "result = S.stinterp([1.0; 2.0;;], [1.0, 2.0], 1.5)")
case("st_err_missing", "SimLev:::.stinepack_stinterp(c(1, 2), c(1, 2))", "result = S.stinterp([1.0, 2.0], [1.0, 2.0])",
     "result = S.stinterp([1.0, 2.0], [1.0, 2.0])")
SL <- function(id, r, py, jl, inputs = list(x = xs, y = ys)) case(paste0("slope_", id), r, py, jl, inputs)
SL("stine", "SimLev:::.stinepack_stinemanSlopes(x, y)", "result = S.stinemanSlopes(x, y)", "result = S.stinemanSlopes(x, y)")
SL("stine_scaled", "SimLev:::.stinepack_stinemanSlopes(x, y, scale = TRUE)", "result = S.stinemanSlopes(x, y, scale=True)",
   "result = S.stinemanSlopes(x, y; scale = true)")
SL("parabola", "SimLev:::.stinepack_parabolaSlopes(x, y)", "result = S.parabolaSlopes(x, y)", "result = S.parabolaSlopes(x, y)")
SL("stine_const", "SimLev:::.stinepack_stinemanSlopes(x, y, scale = TRUE)", "result = S.stinemanSlopes(x, y, scale=True)",
   "result = S.stinemanSlopes(x, y; scale = true)", list(x = 1:4, y = rep(2, 4)))
SL("stine2", "SimLev:::.stinepack_stinemanSlopes(x, y)", "result = S.stinemanSlopes(x, y)", "result = S.stinemanSlopes(x, y)",
   list(x = c(1, 4), y = c(2, -1)))

# ── .fill_na(…, "stine") ────────────────────────────────────────────────────
FN <- function(id, v) for (kl in c(FALSE, TRUE))
  case(sprintf("fill_%s_%d", id, kl), sprintf("SimLev:::.fill_na(v, 'stine', keep_leading = %s)", kl),
       sprintf("result = BC._fill_na(v, 'stine', keep_leading=%s)", if (kl) "True" else "False"),
       sprintf('result = BC._fill_na(v, "stine"; keep_leading = %s)', tolower(kl)), list(v = v))
FN("vna", c(NA, NA, 1, NA, NA, 4, 5, NA, 2, NA))
FN("rw", gaps(rw, c(1:5, 20:30, 50, 52, 54, 110:120)))
FN("one", c(NA, 3, NA))
FN("two", c(NA, 3, NA, NA, 1, NA))
FN("nan", c(NaN, 1, NaN, 2, NA))
FN("osc", gaps(osc, c(3:9, 25:40)))
set.seed(9); vb <- cumsum(rnorm(1500)); vb[sample(1500, 700)] <- NA
FN("big", vb)
case("fill_def_stine", "list(SimLev:::.fill_na(c(1, 2, 3), 'stine'), SimLev:::.fill_na(c(NA, NA), 'stine'), SimLev:::.fill_na(c(1, NA, 3), 'st'))",
     "result = [BC._fill_na([1.0, 2.0, 3.0], 'stine'), BC._fill_na(np.array([NA, NA]), 'stine'), BC._fill_na(np.array([1.0, NA, 3.0]), 'st')]",
     'result = [BC._fill_na([1.0, 2.0, 3.0], "stine"), BC._fill_na([NA, NA], "stine"), BC._fill_na([1.0, NA, 3.0], "st")]')

# ── öffentliche API: backcast_fit / backcast mit "stine" ───────────────────
make_bc_data <- function(n = 1200, drag = 0.4, lev = 2, seed = 1, weekends = TRUE, from = "2005-01-01") {
  set.seed(seed)
  d <- seq.Date(as.Date(from), by = "day", length.out = n)
  idx <- 100 * cumprod(1 + c(0, rnorm(n - 1, 3e-4, 0.01)))
  rate <- 2 + sin(seq_len(n) / 400)
  ter <- ifelse(d >= as.Date("2006-06-01"), 0.6, 0.35)
  x <- c(0, diff(idx) / head(idx, -1))
  r <- lev * x + (1 - lev) * rate / 100 / 360 - ter / 100 / 365 - drag / 100 / 365
  r[1] <- 0
  truth <- 50 * cumprod(1 + r)
  etf <- truth
  etf[seq_len(n / 2)] <- NA
  if (weekends) etf[as.POSIXlt(d)$wday %in% c(0, 6)] <- NA
  data.frame(date = d, etf = etf, idx = idx, rate = rate)
}
s2 <- make_bc_data()
set.seed(5); sp <- make_bc_data(lev = 1, drag = 0, weekends = TRUE, seed = 5)
sp$etf <- sp$etf * exp(c(0, cumsum(rnorm(nrow(sp) - 1, 0, 0.002))))
sp$idx[c(3, 4, 700, 701, 702)] <- NA
sp$fx <- 1 + 0.1 * sin(seq_len(nrow(sp)) / 100)
s3 <- make_bc_data(n = 600, seed = 7)
s3$idx[c(1:4, 50:60, 200, 202, 204, 300:340)] <- NA
s3$etf[c(310:330, 400:420)] <- NA
TER <- "c('2005-01-01' = 0.35, '2006-06-01' = 0.6)"
TERP <- "pd.Series([0.35, 0.6], index=['2005-01-01', '2006-06-01'])"
TERJ <- 'SL.named("2005-01-01" => 0.35, "2006-06-01" => 0.6)'
IB <- list(s2 = s2, sp = sp, s3 = s3)
case("bf_stine", "backcast_fit(sp, 'etf', 'idx', index_fill = 'stine', validate = FALSE)",
     "result = BC.backcast_fit(sp, 'etf', 'idx', index_fill='stine', validate=False)",
     'result = BC.backcast_fit(sp, "etf", "idx"; index_fill = "stine", validate = false)', IB)
case("bf_stine_s3", "backcast_fit(s3, 'etf', 'idx', ter = 0.5, leverage = 2, rate = 'rate', index_fill = 'stine')",
     "result = BC.backcast_fit(s3, 'etf', 'idx', ter=0.5, leverage=2, rate='rate', index_fill='stine')",
     'result = BC.backcast_fit(s3, "etf", "idx"; ter = 0.5, leverage = 2, rate = "rate", index_fill = "stine")', IB)
case("bf_stine_fx", "backcast_fit(sp, 'etf', 'idx', model = 'linear', fx = 'fx', index_fill = 'stine', fit = c('drag', 'beta'))",
     "result = BC.backcast_fit(sp, 'etf', 'idx', model='linear', fx='fx', index_fill='stine', fit=['drag', 'beta'])",
     'result = BC.backcast_fit(sp, "etf", "idx"; model = "linear", fx = "fx", index_fill = "stine", fit = ["drag", "beta"])', IB)
F2 <- sprintf("f <- backcast_fit(s2, 'etf', 'idx', ter = %s, leverage = 2, rate = 'rate')", TER)
F2P <- sprintf("f = BC.backcast_fit(s2, 'etf', 'idx', ter=%s, leverage=2, rate='rate')", TERP)
F2J <- sprintf('f = BC.backcast_fit(s2, "etf", "idx"; ter = %s, leverage = 2, rate = "rate")\n', TERJ)
case("bc_stine", paste0(F2, "; backcast(f, fill = 'stine', splice = '2006-08-15')"),
     paste0(F2P, "; result = BC.backcast(fit=f, fill='stine', splice='2006-08-15')"),
     paste0(F2J, 'result = BC.backcast(f; fill = "stine", splice = "2006-08-15")'), IB)
case("bc_stine_attr", paste0(F2, "; bc <- backcast(f, fill = 'stine', rebase = 100); list(bc = bc, params = attr(bc, 'params'), splice = attr(bc, 'splice_date'))"),
     paste0(F2P, "; bc = BC.backcast(fit=f, fill='stine', rebase=100)\nresult = dict(bc=bc, params=bc.attrs['params'], splice=bc.attrs['splice_date'])"),
     paste0(F2J, 'bc = BC.backcast(f; fill = "stine", rebase = 100)\nresult = SL.RList("bc" => bc, "params" => SL.attrs(bc)["params"], "splice" => SL.attrs(bc)["splice_date"])'), IB)
case("bc_nofit_stine", "backcast(data = s3, product = 'etf', index = 'idx', leverage = 2, rate = 'rate', ter = 0.5, fill = 'stine', index_fill = 'stine')",
     "result = BC.backcast(data=s3, product='etf', index='idx', leverage=2, rate='rate', ter=0.5, fill='stine', index_fill='stine')",
     'result = BC.backcast(; data = s3, product = "etf", index = "idx", leverage = 2, rate = "rate", ter = 0.5, fill = "stine", index_fill = "stine")', IB)
case("bc_fit_stine", "f <- backcast_fit(s3, 'etf', 'idx', leverage = 2, rate = 'rate', index_fill = 'stine'); backcast(f, fill = 'stine')",
     "f = BC.backcast_fit(s3, 'etf', 'idx', leverage=2, rate='rate', index_fill='stine'); result = BC.backcast(fit=f, fill='stine')",
     'f = BC.backcast_fit(s3, "etf", "idx"; leverage = 2, rate = "rate", index_fill = "stine")\nresult = BC.backcast(f; fill = "stine")', IB)
ref_done()
