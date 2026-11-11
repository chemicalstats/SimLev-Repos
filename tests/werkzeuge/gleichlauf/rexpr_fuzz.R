# tests/werkzeuge/gleichlauf/rexpr_fuzz.R – Zufallsausdrücke für die Regeltexte (RExpr; seit 1.6.5, E-T4-6, aus der
# Prüfung K43 T4 Blue): Python simlev._r.rexpr.eval_r und Julia SL.RExpr.eval_r gegen R eval(parse()) in einer Umgebung
# mit Spalten aller Typen (Zahlen mit NA/±0/Unterlauf, ganze Zahlen mit NA und INT_MAX, Wahrheitswerte, Text mit
# Umlaut und Leerraum, Datum, leerer Vektor; ganze Zahlen mit NA nur als Konstante, weil Python sie als Spalte
# double liest); Operatoren, Grundfunktionen (seit 1.6.5 auch rev, which, seq_len, cumprod,
# cummax, cummin, diff, head, tail, E-T4-1), Indizierung, ifelse/if, quantile, as.Date, ":" und Syntaxfehler. Dazu
# (E-T4-5, T4-R2) Potenzen mit (-Inf)^y für y um 2^64 und negative y sowie %% und %/% mit großen Werten, damit die
# Warnungen ("probable complete loss of accuracy in modulus") mitgeprüft werden. Werte, Typen, Fehler und Warnungen.
#
#   LC_ALL=C.UTF-8 R_LIBS=<R-Bibliothek> SIMLEV_FAELLE_DIR=<ordner> Rscript tests/werkzeuge/gleichlauf/rexpr_fuzz.R <n> <seed>
#
# Prüfung wie libm_fuzz.R (run.py, Schritt 5, FUZZ_REF "rexpr"). R rechnet hier mit seinen Basisfunktionen (nicht mit
# SimLev); die Referenz der Vorversion ist daher nur der Stand der Basisfunktionen.
source("tests/gleichlauf/erzeugen/ref_tools.R")
args <- commandArgs(TRUE); N <- as.integer(args[1]); seed0 <- as.integer(args[2])
ref_bereich("rexpr_fuzz", alle = TRUE); ref_init("rexpr_fuzz")
R <- "eval(parse(text = rx_txt), envir = list2env(rx_dat))"
P <- "from simlev._r import rexpr\nresult = rexpr.eval_r(rx_txt, rx_dat)"
J <- "result = SL.RExpr.eval_r(rx_txt, rx_dat)"
D <- list(x = c(10, 20, NA, 40, -5, 0, 2.5), y = c(1.5, -2, 3), i = c(3L, 0L, 1L, -2L), j = c(1L, 5L, 4L),
          l = c(TRUE, NA, FALSE), s = c("b", "a", NA, "B", "a10", "1.5", "Ä", "", " 2 "), big = 2147483647L,
          dt = as.Date(c("2020-02-29", NA, "1969-12-31")), n0 = numeric(0), thr = 15, k = 2L, nm = "a",
          z = c(-0, 1e308, 5e-324, -1e-300), u = 7)
pick <- function(v) v[[sample.int(length(v), 1)]]
coin <- function(p) runif(1) < p
CON <- c("NA", "NaN", "Inf", "-Inf", "0", "-0", "1e308", "5e-324", "2L", "-3L", "NA_integer_", "NA_real_", "NA_character_",
         "TRUE", "FALSE", "\"a\"", "\"10\"", "\"\"", "1.5", "0.1", "3", "1e-10", "2147483647L", "0x10", "1e3L", "100",
         "NULL", "\"2021-03-01\"", "\"x\"", "-2.5", "7")
VARS <- c("x", "y", "i", "j", "l", "s", "big", "dt", "n0", "thr", "k", "nm", "z", "u")
BIN <- c("+", "-", "*", "/", "^", "%%", "%/%", "==", "!=", "<", ">", "<=", ">=", "&", "|", "%in%", "&&", "||")
F1 <- c("abs", "sqrt", "exp", "expm1", "log1p", "log2", "log10", "sin", "cos", "tan", "tanh", "atan", "floor", "ceiling",
        "trunc", "sign", "is.na", "is.nan", "is.finite", "is.infinite", "length", "cumsum", "identity", "as.numeric",
        "as.integer", "as.logical", "as.character", "nchar", "isTRUE", "isFALSE", "any", "all", "sum", "mean", "median",
        "var", "sd", "min", "max", "logical", "integer", "numeric", "character", "double",
        "rev", "which", "seq_len", "cumprod", "cummax", "cummin", "diff", "head", "tail")
atom <- function() if (coin(0.5)) pick(VARS) else pick(CON)
ex <- function(d = 0) {
  if (d > 3 || coin(0.25)) return(atom())
  r <- runif(1)
  if (r < 0.30) return(sprintf("%s %s %s", ex(d + 1), pick(BIN), ex(d + 1)))
  if (r < 0.38) return(sprintf("(%s)", ex(d + 1)))
  if (r < 0.45) return(sprintf("%s%s", pick(c("-", "!", "+")), ex(d + 1)))
  if (r < 0.70) { f <- pick(F1); a <- ex(d + 1)
    extra <- if (f %in% c("sum", "mean", "median", "min", "max", "any", "all", "var", "sd") && coin(0.4)) ", na.rm = TRUE" else
             if (f %in% c("sum", "min", "max", "any", "all") && coin(0.3)) paste0(", ", ex(d + 1)) else ""
    return(sprintf("%s(%s%s)", f, a, extra)) }
  if (r < 0.75) return(sprintf("%s(%s, %s)", pick(c("round", "signif", "log", "diff", "head", "tail")), ex(d + 1), pick(c("2", "-1", "0", "NA", "1.7", "\"2\"", "x", "2L"))))
  if (r < 0.80) return(sprintf("%s(%s, %s)", pick(c("pmin", "pmax", "xor", "c", "rep")), ex(d + 1), ex(d + 1)))
  if (r < 0.86) return(sprintf("%s[%s]", pick(VARS), pick(c("1", "-1", "0", "NA", "10", "c(TRUE, FALSE)", "-(1:2)", "\"a\"", "2:3", "i", "l", "x > 5", "c(1, NA)", "2.9", ""))))
  if (r < 0.88) return(sprintf("%s[[%s]]", pick(VARS), pick(c("1", "2", "0", "NA", "-1", "10", "\"a\""))))
  if (r < 0.92) return(sprintf("ifelse(%s, %s, %s)", ex(d + 1), ex(d + 1), ex(d + 1)))
  if (r < 0.95) return(sprintf("if (%s) %s else %s", ex(d + 1), ex(d + 1), ex(d + 1)))
  if (r < 0.97) return(sprintf("quantile(%s, %s%s)", pick(c("x", "y", "i", "z", "c(1, 2, 3, 4)")), pick(c("0.5", "c(0.1, 0.9)", "1.5", "NA", "-0")), pick(c("", ", na.rm = TRUE", ", type = 1", ", type = 9", ", names = FALSE"))))
  if (r < 0.985) return(sprintf("as.Date(%s%s)", pick(c("\"2020-01-31\"", "\"31.12.2020\"", "\"2020/2/3\"", "s", "\"\"", "NA", "18000", "\"2020-13-01\"")), pick(c("", ", format = \"%d.%m.%Y\"", ", \"%Y/%m/%d\"", ", origin = \"1970-01-01\"", ", format = \"%b %d\""))))
  sprintf("%s:%s", pick(c("1", "-2", "0.5", "i", "3L", "NA", "\"2\"")), pick(c("3", "1", "-1.5", "k", "x", "\"4\"", "NA")))
}
# (-Inf)^y und %% bzw. %/% mit großen Werten (E-T4-5, T4-R2)
POT_Y <- c("2^64", "2^64 + 2^12", "2^64 - 2^11", "-2^64", "-(2^64 + 2^12)", "2^63", "-3", "-2", "-0.5", "1e300", "-1e300")
pot <- function() switch(pick(1:3),
  sprintf("(-Inf)^(%s)", pick(POT_Y)),
  sprintf("%s %%%% %s", pick(c("1e300", "-1e300", "2^70", "x", "7")), pick(c("3", "-3", "1e-300", "2^-60", "0.1"))),
  sprintf("%s %%/%% %s", pick(c("1e300", "-1e300", "2^70", "x")), pick(c("3", "-3", "1e-300", "0.1"))))
syntax_bad <- c("(1 + 2", "1 +", "x[1", "\"abc", "1 2", "a b", "if (TRUE) 1 else", "x$", "%%", "1e", "0x", "`x", "x ==== 1", "{1; 2", "1;;2", "x <- ", "5 -> y", "x[[1]", "1 + * 2", "'unbalanced")
nn <- 0
for (kk in seq_len(N)) {
  set.seed(seed0 + kk)
  repeat {
    e <- if (coin(0.04)) pick(syntax_bad) else if (coin(0.05)) pot() else ex()
    if (coin(0.06)) e <- sprintf("{ v <- %s; v %s %s }", ex(2), pick(BIN), ex(3))
    # Speicher- und Längengrenzen von R (RExpr: höchstens 1e8 Werte, eigene Meldung) nicht als Fall
    m <- tryCatch({ suppressWarnings(eval(parse(text = e), envir = list2env(D))); "" }, error = function(err) conditionMessage(err))
    if (!grepl("cannot allocate|too long|long vectors|zu lang", m)) break
  }
  ref_case(sprintf("bx_%04d", kk), R, P, jl = J, inputs = list(rx_txt = e, rx_dat = D))
}
ref_done(); ref_schreiben()
