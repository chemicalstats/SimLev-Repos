# tests/gleichlauf/erzeugen/r_grundfunktionen.R – Referenzfälle des Bereichs r_grundfunktionen: nachgebaute R-Interna: Formatierung, NA/NaN, Statistikfunktionen, Ausdrücke.
# Module: r_fmt, r_nana, r_stats, rexpr (bis 1.4.0 je ein Generator gen_<modul>.R, hier wörtlich hintereinander).
# Aufruf (Repo-Wurzel): LC_ALL=C.UTF-8 R_LIBS=<R-Bibliothek mit SimLev> Rscript tests/gleichlauf/erzeugen/r_grundfunktionen.R
# Ausgabe tests/{gleichlauf,fehler,ausgabe}/faelle/r_grundfunktionen.jsonl.gz (Format und Umgebung: tests/gleichlauf/erzeugen/ref_tools.R).
source("tests/gleichlauf/erzeugen/ref_tools.R")
ref_bereich("r_grundfunktionen")

# ════════════════════════════════════════════════════════════════════════════════════════════════════
# Modul r_fmt
# ════════════════════════════════════════════════════════════════════════════════════════════════════
# Referenzfälle für simlev._r.fmt (Formatierung und Druckausgabe wie R 4.3.3).
# Aufruf aus der Repo-Wurzel:
ref_init("r_fmt")
P <- "from simlev._r import fmt as F\n"
cap <- function(txt) sprintf("paste(capture.output(%s), collapse = '\\n')", txt)
JP <- "const F = SL.RFmt\n"
case <- function(id, r, py, inputs = list(), pre = "", jl = NULL, jlpre = "")
  ref_case(id, r = r, py = paste0(P, pre, "result = ", py), inputs = inputs,
           jl = if (is.null(jl)) NULL else paste0(JP, jlpre, "result = ", jl))
# Python-Argumente -> Julia (Anführungszeichen, True/False)
pj <- function(s) { s <- gsub("True", "true", gsub("False", "false", s)); if (grepl("\"'\"", s, fixed = TRUE)) s else gsub("'", "\"", s) }
jll <- function(x) if (x) "true" else "false"
# NaN-Positionen für Python markieren (Eingaben kennen nur NA)
nanpre <- function(nm, x) {
  i <- which(is.nan(x))
  if (!length(i)) return("")
  sprintf("%s = np.atleast_1d(np.array(%s, dtype=float)).copy(); %s[[%s]] = np.nan\n", nm, nm, nm, paste(i - 1L, collapse = ", "))
}
pyl <- function(x) if (is.null(x)) "None" else if (is.logical(x)) (if (x) "True" else "False") else if (is.character(x)) sprintf("'%s'", x) else format(x)
# Typangaben integer-Spalten (mit NA kommen sie in Python als float an)
dftypes <- function(d) {
  k <- names(d)[vapply(d, function(v) is.integer(v) && !is.factor(v) && anyNA(v), NA)]
  kc <- names(d)[vapply(d, function(v) (is.character(v) || is.factor(v)) && all(is.na(v)), NA)]
  if (!length(k) && !length(kc)) return("None")
  paste0("{", paste(c(sprintf("'%s': 'integer'", k), sprintf("'%s': 'character'", kc)), collapse = ", "), "}")
}
set.seed(20240229)
rnum <- function(n, k = sample(1:7, 1)) {
  switch(k,
    sign(runif(n) - 0.3) * 10^runif(n, -25, 25),
    round(rnorm(n) * 10^sample(-3:8, 1), sample(0:6, 1)),
    sample(-1000:100000, n, TRUE) / 10^sample(0:4, 1),
    (sample(0:2000, n, TRUE) + 0.5) / 10^sample(0:3, 1),
    sign(rnorm(n)) * 10^sample(-10:20, n, TRUE),
    round(runif(n) * 10^sample(1:16, 1)),
    rnorm(n) * 10^runif(1, -5, 10))
}

## ── round / signif ─────────────────────────────────────────────────────────
x_r <- c(0.5, 1.5, 2.5, -0.5, -2.5, 0.15, 0.25, 0.35, 0.285, 1.005, 2.675, 0.1 + 0.2, 123.456, -123.456,
         1e300, -1e-300, 5e-324, 1e15 + 0.5, 2^52 + 0.5, 1234567.891, 0.000123456, NA, Inf, -Inf, 0, -0)
for (d in c(-3, -1, 0, 1, 2, 3, 5, 10, 15, 300, 320))
  case(sprintf("round_d%s", sub("-", "m", d)), sprintf("round(x, %d)", d), sprintf("F.r_round(x, %d)", d), list(x = x_r),
       jl = sprintf("F.r_round(x, %d)", d))
for (d in c(1, 2, 3, 6, 10, 15, 22))
  case(sprintf("signif_d%d", d), sprintf("signif(x, %d)", d), sprintf("F.signif(x, %d)", d), list(x = x_r),
       jl = sprintf("F.signif(x, %d)", d))
x_rr <- unlist(lapply(1:7, function(k) rnum(60, k)))
case("round_rand", "lapply(c(-2, 0, 1, 2, 4, 7), function(d) round(x, d))",
     "[F.r_round(x, d) for d in (-2, 0, 1, 2, 4, 7)]", list(x = x_rr),
     jl = "[F.r_round(x, d) for d in (-2, 0, 1, 2, 4, 7)]")
case("signif_rand", "lapply(c(1, 3, 5, 8, 12), function(d) signif(x, d))",
     "[F.signif(x, d) for d in (1, 3, 5, 8, 12)]", list(x = x_rr),
     jl = "[F.signif(x, d) for d in (1, 3, 5, 8, 12)]")
case("round_vecdig", "round(c(1.2345, 2.3456, 3.4567, -9.8765), c(0, 1, 2, 3))",
     "F.r_round(np.array([1.2345, 2.3456, 3.4567, -9.8765]), [0, 1, 2, 3])",
     jl = "F.r_round([1.2345, 2.3456, 3.4567, -9.8765], [0, 1, 2, 3])")
case("round_int", "round(c(3L, -7L, NA), 2)", "F.r_round(np.array([3.0, -7.0, F.NA_REAL]), 2)",
     jl = "F.r_round(Union{Missing,Int}[3, -7, missing], 2)")
case("round_mat", cap("print(round(m, 3))"), "F.print_matrix(F.r_round(m, 3))", list(m = matrix(rnorm(12), 3, dimnames = list(c("a", "b", "c"), c("W", "X", "Y", "Z")))),
     jl = "F.print_matrix(F.r_round(m, 3))")

## ── as.character / paste ───────────────────────────────────────────────────
x_ac <- c(0.1 + 0.2, 1e5, 1e15, 123456.7, 1/3, 2/3, 1e-20, 123456789012345678, 100000, 1e-5, 1e-4, 1234567.1,
          2^60, -0, NA, Inf, -Inf, 1e300, 5e-324, 0.1, 1e16, 99999999999999999, 1e-300 * 3, 100, 0.07, 1e22, 1e23, 7e-9,
          -7.3639995566896049e-09, 4.1459271333236e-12)
case("aschar_special", "as.character(x)", "F.as_character(x)", list(x = x_ac[-15]), jl = "F.as_character(x)")
case("aschar_rand", "as.character(x)", "F.as_character(x)", list(x = x_rr), jl = "F.as_character(x)")
case("aschar_int_lgl", "c(as.character(c(1L, -5L, 100000L)), as.character(c(TRUE, FALSE)))",
     "np.concatenate([F.as_character(np.array([1, -5, 100000])), F.as_character(np.array([True, False]))])",
     jl = "vcat(F.as_character([1, -5, 100000]), F.as_character([true, false]))")
case("aschar_date", "as.character(as.Date(c('2024-02-29', '1999-12-31')))", "F.as_character(np.array(['2024-02-29', '1999-12-31'], dtype='datetime64[D]'))",
     jl = "F.as_character([Date(2024, 2, 29), Date(1999, 12, 31)])")
case("paste1", "paste('Wert', x, 'EUR')", "F.paste('Wert', x, 'EUR')", list(x = c(1.5, 1e5, 123456.7, NA, 1/3)),
     jl = 'F.paste("Wert", x, "EUR")')
case("paste2", "paste0('a', 1:3, c('x', 'y', 'z'), collapse = '|')", "F.paste0('a', np.arange(1, 4), np.array(['x', 'y', 'z'], dtype=object), collapse='|')",
     jl = 'F.paste0("a", 1:3, ["x", "y", "z"], collapse = "|")')
case("paste3", "c(paste(c('a', NA), TRUE, sep = '-'), paste('x', character(0)), paste(1e-20, 0.1 + 0.2))",
     "np.concatenate([F.paste(np.array(['a', None], dtype=object), True, sep='-'), F.paste('x', np.array([], dtype=object)), [F.paste(1e-20, 0.1 + 0.2)]])",
     jl = 'vcat(F.paste(["a", missing], true, sep = "-"), F.paste("x", String[]), [F.paste(1e-20, 0.1 + 0.2)])')
case("tostring", "toString(c(1.5, 2, 1e6))", "F.to_string(np.array([1.5, 2, 1e6]))", jl = "F.to_string([1.5, 2, 1e6])")

## ── format(): Zahlen ───────────────────────────────────────────────────────
for (i in 1:40) {
  n <- sample(c(1:6, 12, 25), 1); x <- rnum(n)
  if (runif(1) < 0.25) x[sample(n, 1)] <- sample(c(NA, NaN, Inf, -Inf, 0), 1)
  dg <- sample(c(NA, NA, 1:15), 1); ns <- sample(c(0, 0, 0, 1:3), 1)
  r <- sprintf("format(x%s%s)", if (is.na(dg)) "" else sprintf(", digits = %d", dg), if (ns) sprintf(", nsmall = %d", ns) else "")
  py <- sprintf("F.format(x%s%s)", if (is.na(dg)) "" else sprintf(", digits=%d", dg), if (ns) sprintf(", nsmall=%d", ns) else "")
  case(sprintf("fmt_num%02d", i), r, py, list(x = x), nanpre("x", x), jl = py)
}
x_f <- c(1234567.891, 0.5, -42, 1e6, 999.995, NA)
fargs <- list(
  c("big.mark = '.', decimal.mark = ',', nsmall = 2", "big_mark='.', decimal_mark=',', nsmall=2"),
  c("big.mark = ' '", "big_mark=' '"),
  c("big.mark = ' ', scientific = FALSE", "big_mark=' ', scientific=False"),
  c("big.mark = ',', trim = TRUE", "big_mark=',', trim=True"),
  c("scientific = TRUE", "scientific=True"),
  c("scientific = TRUE, digits = 3", "scientific=True, digits=3"),
  c("scientific = 2", "scientific=2"),
  c("scientific = -3", "scientific=-3"),
  c("trim = TRUE", "trim=True"),
  c("width = 15", "width=15"),
  c("nsmall = 3, width = 4", "nsmall=3, width=4"),
  c("drop0trailing = TRUE, nsmall = 3", "drop0trailing=True, nsmall=3"),
  c("zero.print = '-'", "zero_print='-'"),
  c("zero.print = TRUE, nsmall = 2", "zero_print=True, nsmall=2"),
  c("decimal.mark = ','", "decimal_mark=','"),
  c("big.mark = \"'\", big.interval = 2", "big_mark=\"'\", big_interval=2"),
  c("small.mark = ' ', nsmall = 6", "small_mark=' ', nsmall=6"),
  c("digits = 3, nsmall = 1", "digits=3, nsmall=1"))
for (i in seq_along(fargs)) {
  case(sprintf("fmt_arg%02d", i), sprintf("format(x, %s)", fargs[[i]][1]), sprintf("F.format(x, %s)", fargs[[i]][2]), list(x = x_f),
       jl = sprintf("F.format(x, %s)", pj(fargs[[i]][2])))
  case(sprintf("fmt_arg%02db", i), sprintf("format(x, %s)", fargs[[i]][1]), sprintf("F.format(x, %s)", fargs[[i]][2]),
       list(x = c(0, 0.001234, 15, 2.5e-8, 123456789)), jl = sprintf("F.format(x, %s)", pj(fargs[[i]][2])))
}
case("fmt_scalars", "c(format(3.14159), format(1e-15), format(100000), format(123456), format(1e5 + 0.1), format(-0), format(0.1 + 0.2, digits = 17), format(2/3, digits = 3), format(pi, digits = 10))",
     "[F.format(3.14159), F.format(1e-15), F.format(100000.0), F.format(123456.0), F.format(1e5 + 0.1), F.format(-0.0), F.format(0.1 + 0.2, digits=17), F.format(2/3, digits=3), F.format(math.pi, digits=10)]",
     jl = "[F.format(3.14159), F.format(1e-15), F.format(100000.0), F.format(123456.0), F.format(1e5 + 0.1), F.format(-0.0), F.format(0.1 + 0.2, digits=17), F.format(2/3, digits=3), F.format(Float64(pi), digits=10)]")
case("fmt_digits_hi", "lapply(16:22, function(d) format(x, digits = d))", "[F.format(x, digits=d) for d in range(16, 23)]",
     list(x = c(0.1, 1/3, 123456.789, 1e-10 / 3, 2^70)), jl = "[F.format(x, digits=d) for d in 16:22]")
case("fmt_int", "list(format(c(1L, -20L, 300L, NA)), format(100000L), format(c(5L, 12L), width = 6), format(1:3, trim = TRUE), format(123456789L, big.mark = ','))",
     "[F.format(np.array([1, -20, 300, F.NA_REAL]), type='integer'), F.format(100000), F.format(np.array([5, 12]), width=6), F.format(np.arange(1, 4), trim=True), F.format(123456789, big_mark=',')]",
     jl = '[F.format(Union{Missing,Int}[1, -20, 300, missing]), F.format(100000), F.format([5, 12], width=6), F.format(1:3, trim=true), F.format(123456789, big_mark=",")]')
case("fmt_lgl", "list(format(c(TRUE, FALSE, NA)), format(TRUE), format(c(TRUE, NA)), format(NA))",
     "[F.format(np.array([True, False, None], dtype=object)), F.format(True), F.format(np.array([True, None], dtype=object)), F.format(None, type='logical')]",
     jl = "[F.format([true, false, missing]), F.format(true), F.format([true, missing]), F.format(missing)]")
case("fmt_named", "format(c(a = 1.5, bb = 10, ccc = NA))", "F.format(x)", list(x = c(a = 1.5, bb = 10, ccc = NA)), jl = "F.format(x)")
case("fmt_signif", "c(format(signif(b, 3)), format(signif(a, 3)), format(signif(m, 6)), format(signif(adp, 8)))",
     "[F.format(F.signif(b, 3)), F.format(F.signif(a, 3)), F.format(F.signif(m, 6)), F.format(F.signif(adp, 8))]",
     list(b = 0.0123456, a = 1234.5678, m = 98765.4321, adp = 0.123456789123),
     jl = "[F.format(F.signif(b, 3)), F.format(F.signif(a, 3)), F.format(F.signif(m, 6)), F.format(F.signif(adp, 8))]")
case("fmt_pkg1", "c(format(1234.5, big.mark = ' '), format(16956, big.mark = ' ', scientific = FALSE), format(1e7, scientific = FALSE), format(0.05 * 100), format(1/0.85, digits = 5), format(c(0.017, 0.5), digits = 4))",
     "[F.format(1234.5, big_mark=' '), F.format(16956.0, big_mark=' ', scientific=False), F.format(1e7, scientific=False), F.format(0.05 * 100), F.format(1/0.85, digits=5), *F.format(np.array([0.017, 0.5]), digits=4)]",
     jl = '[F.format(1234.5, big_mark=" "), F.format(16956.0, big_mark=" ", scientific=false), F.format(1e7, scientific=false), F.format(0.05 * 100), F.format(1/0.85, digits=5), F.format([0.017, 0.5], digits=4)...]')

## ── format(): Zeichen, Faktoren ────────────────────────────────────────────
s_c <- c("Endvermögen", "PWR", "Max. Konsumrückgang", NA, "", "a\\b", "\"q\"", "日本語", "x")
for (j in c("left", "right", "centre", "none"))
  case(paste0("fmt_chr_", j), sprintf("format(s, justify = '%s')", j), sprintf("F.format(s, justify='%s')", j), list(s = s_c),
       jl = sprintf('F.format(s, justify="%s")', j))
case("fmt_chr_width", "list(format('Endvermögen', width = 28), format(s, width = 26), format(s, width = 3), format(s, na.encode = FALSE))",
     "[F.format('Endvermögen', width=28), F.format(s, width=26), F.format(s, width=3), F.format(s, na_encode=False)]", list(s = s_c[-4]),
     jl = '[F.format("Endvermögen", width=28), F.format(s, width=26), F.format(s, width=3), F.format(s, na_encode=false)]')
case("fmt_chr_na", "format(c('a', NA), na.encode = FALSE)", "F.format(np.array(['a', None], dtype=object), na_encode=False)",
     jl = 'F.format(["a", missing], na_encode=false)')
case("fmt_factor", "format(factor(c('b', 'a', NA, 'ccc')))", "F.format(pd.Categorical(['b', 'a', None, 'ccc']))",
     jl = 'F.format(F.r_factor(["b", "a", missing, "ccc"]))')

## ── Datum ──────────────────────────────────────────────────────────────────
dts <- as.Date(c("2024-02-29", "1999-12-31", "2000-01-01", "2021-01-03", "2020-12-31", "2015-01-01", "2016-01-03",
                 "1970-01-01", "1900-03-01", "2024-12-30", "2008-12-29", "2010-01-03", "2027-01-01", NA))
dfm <- c("%Y-%m-%d", "%d.%m.%Y", "%Y-%m", "%Y", "%m", "%m-%d", "%Y-%m-01", "%Y-01-01", "%G-%V", "%u", "%b %Y", "%B %d, %Y",
         "%a %A %w", "%j %U %W", "%y%m%d %e", "%C %g %h", "%D %F", "%x %X", "%c", "Woche %V/%G (%%)")
for (i in seq_along(dfm))
  case(sprintf("date_%02d", i), sprintf("format(d, '%s')", dfm[i]), sprintf("F.format_date(d, '%s')", dfm[i]), list(d = dts),
       jl = sprintf('F.format_date(d, "%s")', dfm[i]))
set.seed(7); d_iso <- as.Date("1990-12-20") + sort(c(outer(0:14, 365.25 * 0:30, "+")))
case("date_iso_many", "format(d, '%G-%V %u %U %W %j')", "F.format_date(d, '%G-%V %u %U %W %j')", list(d = d_iso),
     jl = 'F.format_date(d, "%G-%V %u %U %W %j")')
case("date_format_generic", "c(format(d), format(d[1], '%d.%m.%Y'))", "[*F.format(d), F.format(d[0], '%d.%m.%Y')]", list(d = dts[1:5]),
     jl = '[F.format(d)..., F.format(d[1], "%d.%m.%Y")]')
case("date_print", cap("print(d)"), "F.print_vector(d)", list(d = dts), jl = "F.print_vector(d)")
case("date_print_long", cap("print(d)"), "F.print_vector(d)", list(d = as.Date("2020-01-01") + 0:29), jl = "F.print_vector(d)")

## ── formatC / prettyNum ────────────────────────────────────────────────────
x_c <- c(0, 1.5, -2.25, 123456.789, 1e-5, 0.000123, 99.995, 1e10, -0.5)
fcs <- list(
  c("format = 'f', digits = 2", "format='f', digits=2"), c("format = 'f', digits = 0, big.mark = ' '", "format='f', digits=0, big_mark=' '"),
  c("format = 'e', digits = 3", "format='e', digits=3"), c("format = 'E', digits = 1, width = 12", "format='E', digits=1, width=12"),
  c("format = 'g'", "format='g'"), c("format = 'G', digits = 6", "format='G', digits=6"),
  c("format = 'fg', digits = 3", "format='fg', digits=3"), c("format = 'fg', big.mark = ' '", "format='fg', big_mark=' '"),
  c("format = 'fg', digits = 4, flag = '#'", "format='fg', digits=4, flag='#'"), c("digits = 3, width = 10", "digits=3, width=10"),
  c("format = 'f', digits = 2, flag = '0', width = 10", "format='f', digits=2, flag='0', width=10"),
  c("format = 'f', digits = 1, flag = '-', width = 10", "format='f', digits=1, flag='-', width=10"),
  c("format = 'f', digits = 1, flag = '+'", "format='f', digits=1, flag='+'"),
  c("format = 'f', digits = 3, flag = ' '", "format='f', digits=3, flag=' '"),
  c("format = 'f', digits = 3, drop0trailing = TRUE", "format='f', digits=3, drop0trailing=True"),
  c("format = 'f', digits = 2, width = -12", "format='f', digits=2, width=-12"),
  c("format = 'f', digits = 2, big.mark = '.', decimal.mark = ','", "format='f', digits=2, big_mark='.', decimal_mark=','"),
  c("format = 'g', digits = 3, flag = '#'", "format='g', digits=3, flag='#'"),
  c("format = 'e', digits = 0", "format='e', digits=0"), c("width = 8", "width=8"), c("mode = 'integer'", "mode='integer'"))
for (i in seq_along(fcs))
  case(sprintf("fmtC_%02d", i), sprintf("formatC(x, %s)", fcs[[i]][1]), sprintf("F.formatC(x, %s)", fcs[[i]][2]), list(x = x_c),
       jl = sprintf("F.formatC(x, %s)", pj(fcs[[i]][2])))
case("fmtC_special", "formatC(c(1.5, NA, Inf, -Inf, NaN), format = 'f', digits = 2, width = 7)",
     "F.formatC(x, format='f', digits=2, width=7)", list(x = c(1.5, NA, Inf, -Inf, NaN)), nanpre("x", c(1.5, NA, Inf, -Inf, NaN)),
     jl = 'F.formatC(x, format="f", digits=2, width=7)')
case("fmtC_int", "list(formatC(c(1L, 25L, -300L), width = 5), formatC(c(1L, 25L), width = 5, flag = '0'), formatC(7L, format = 'd', flag = '-', width = 4), formatC(c(1234567, 89), format = 'd', big.mark = ' '))",
     "[F.formatC(np.array([1, 25, -300]), width=5), F.formatC(np.array([1, 25]), width=5, flag='0'), F.formatC(7, format='d', flag='-', width=4), F.formatC(np.array([1234567.0, 89.0]), format='d', big_mark=' ')]",
     jl = '[F.formatC([1, 25, -300], width=5), F.formatC([1, 25], width=5, flag="0"), F.formatC(7, format="d", flag="-", width=4), F.formatC([1234567.0, 89.0], format="d", big_mark=" ")]')
case("fmtC_chr", "list(formatC(c('a', 'Ärger', 'long name'), width = 12), formatC(c('a', 'Ärger'), width = -8), formatC(c('a', 'Öl'), flag = '-', width = 5), formatC('x'))",
     "[F.formatC(np.array(['a', 'Ärger', 'long name'], dtype=object), width=12), F.formatC(np.array(['a', 'Ärger'], dtype=object), width=-8), F.formatC(np.array(['a', 'Öl'], dtype=object), flag='-', width=5), F.formatC('x')]",
     jl = '[F.formatC(["a", "Ärger", "long name"], width=12), F.formatC(["a", "Ärger"], width=-8), F.formatC(["a", "Öl"], flag="-", width=5), F.formatC("x")]')
case("fmtC_pkg", "c(formatC(c(12345.678, 987654321), format = 'f', digits = 0, big.mark = ' '), formatC(round(c(1500.4, 25000.6)), format = 'd', big.mark = ' '), formatC(0.12345, digits = 2, format = 'f'), formatC(c(1, 10, 100, 1000, 25000, 1e6), format = 'fg', big.mark = ' '))",
     "np.concatenate([F.formatC(np.array([12345.678, 987654321]), format='f', digits=0, big_mark=' '), F.formatC(F.r_round(np.array([1500.4, 25000.6])), format='d', big_mark=' '), [F.formatC(0.12345, digits=2, format='f')], F.formatC(np.array([1, 10, 100, 1000, 25000, 1e6], dtype=float), format='fg', big_mark=' ')])",
     jl = 'vcat(F.formatC([12345.678, 987654321], format="f", digits=0, big_mark=" "), F.formatC(F.r_round([1500.4, 25000.6]), format="d", big_mark=" "), [F.formatC(0.12345, digits=2, format="f")], F.formatC([1, 10, 100, 1000, 25000, 1e6], format="fg", big_mark=" "))')
case("fmtC_rand", "lapply(c('f', 'e', 'g', 'fg'), function(f) formatC(x, format = f, digits = 4, width = 10))",
     "[F.formatC(x, format=f, digits=4, width=10) for f in ('f', 'e', 'g', 'fg')]", list(x = rnum(30, 1)),
     jl = '[F.formatC(x, format=f, digits=4, width=10) for f in ("f", "e", "g", "fg")]')
case("prettynum", "list(prettyNum(c(123456, 1234567.5), big.mark = ','), prettyNum(1234567L, big.mark = ' '), prettyNum(c('1234567', '12.5'), big.mark = '.'), prettyNum(c(0, 1.5), zero.print = '.'))",
     "[F.prettyNum(np.array([123456.0, 1234567.5]), big_mark=','), F.prettyNum(1234567, big_mark=' '), F.prettyNum(np.array(['1234567', '12.5'], dtype=object), big_mark='.'), F.prettyNum(np.array([0.0, 1.5]), zero_print='.')]",
     jl = '[F.prettyNum([123456.0, 1234567.5], big_mark=","), F.prettyNum(1234567, big_mark=" "), F.prettyNum(["1234567", "12.5"], big_mark="."), F.prettyNum([0.0, 1.5], zero_print=".")]')

## ── sprintf ────────────────────────────────────────────────────────────────
x_s <- c(0.123456, -1.5, 1234.5678, 0, 1e-10, 2.675, NA, Inf, -Inf, NaN, 1e20)
sfm <- c("%.3f", "%.2f", "%.2f %%", "%.1f %%", "%.0f %%", "%.1f", "%10.0f", "%.4f", "%.0f", "%5.1f", "%+.2f", "%e", "%.2e",
         "%g", "%G", "%10.4g", "%#.3g", "%a", "%A", "%.3a", "%-12.3f|", "% .2f", "%08.2f", "%+.2f%%", "%s", "%10s", "%-10s|", "%.3s")
for (i in seq_along(sfm))
  case(sprintf("spf_%02d", i), sprintf("sprintf('%s', x)", sfm[i]), sprintf("F.sprintf('%s', x)", sfm[i]),
       list(x = x_s), nanpre("x", x_s), jl = sprintf('F.r_sprintf("%s", x)', sfm[i]))
case("spf_int", "c(sprintf('%d', c(1L, -20L, NA)), sprintf('%5d|%-5d|%05d', 42L, 7L, 3L), sprintf('%02d', 1:3), sprintf('%d', 3), sprintf('%x %X %o', 255L, 255L, 8L), sprintf('%i', TRUE), sprintf('%3d', NA))",
     "np.concatenate([F.sprintf('%d', F._as_v(np.array([1, -20, F.NA_REAL]), 'integer')), [F.sprintf('%5d|%-5d|%05d', 42, 7, 3)], F.sprintf('%02d', np.arange(1, 4)), [F.sprintf('%d', 3.0)], [F.sprintf('%x %X %o', 255, 255, 8)], [F.sprintf('%i', True)], [F.sprintf('%3d', F._as_v(None, 'integer'))]])",
     jl = 'vcat(F.r_sprintf("%d", Union{Missing,Int}[1, -20, missing]), [F.r_sprintf("%5d|%-5d|%05d", 42, 7, 3)], F.r_sprintf("%02d", 1:3), [F.r_sprintf("%d", 3.0)], [F.r_sprintf("%x %X %o", 255, 255, 8)], [F.r_sprintf("%i", true)], [F.r_sprintf("%3d", missing)])')
case("spf_str", "c(sprintf('%s = %s', c('a', 'bb'), c(1.5, 1e5)), sprintf('%-26s|', 'Endvermögen'), sprintf('%10s|', 'Öl'), sprintf('%s', NA), sprintf('%s', c(TRUE, NA)), sprintf('%s', 1e-20), sprintf('%s', 123456789012), sprintf('%5s', NA))",
     "np.concatenate([F.sprintf('%s = %s', np.array(['a', 'bb'], dtype=object), np.array([1.5, 1e5])), [F.sprintf('%-26s|', 'Endvermögen'), F.sprintf('%10s|', 'Öl'), F.sprintf('%s', F._as_v(None, 'character'))], F.sprintf('%s', np.array([True, None], dtype=object)), [F.sprintf('%s', 1e-20), F.sprintf('%s', 123456789012.0)], F.sprintf('%5s', np.array([None], dtype=object))])",
     jl = 'vcat(F.r_sprintf("%s = %s", ["a", "bb"], [1.5, 1e5]), [F.r_sprintf("%-26s|", "Endvermögen"), F.r_sprintf("%10s|", "Öl"), F.r_sprintf("%s", missing)], F.r_sprintf("%s", [true, missing]), [F.r_sprintf("%s", 1e-20), F.r_sprintf("%s", 123456789012.0)], F.r_sprintf("%5s", [missing]))')
case("spf_multi", "c(sprintf('%04d-%02d-01', 2024L, 1:3), sprintf('%s (%d x)', c('a', 'b'), 3L), sprintf('%2$s %1$s', 'Welt', 'Hallo'), sprintf('%*d', 5, 42L), sprintf('%-*d|', 4, 7L), sprintf('%+.2f%%%s', 1.234, ' p. a.'), sprintf('%s %g %%', 'Rate', 2.5), sprintf('%g:1', 1/3), sprintf('%%'))",
     "np.concatenate([F.sprintf('%04d-%02d-01', 2024, np.arange(1, 4)), F.sprintf('%s (%d x)', np.array(['a', 'b'], dtype=object), 3), [F.sprintf('%2$s %1$s', 'Welt', 'Hallo'), F.sprintf('%*d', 5.0, 42), F.sprintf('%-*d|', 4, 7), F.sprintf('%+.2f%%%s', 1.234, ' p. a.'), F.sprintf('%s %g %%', 'Rate', 2.5), F.sprintf('%g:1', 1/3), F.sprintf('%%')]])",
     jl = 'vcat(F.r_sprintf("%04d-%02d-01", 2024, 1:3), F.r_sprintf("%s (%d x)", ["a", "b"], 3), [F.r_sprintf("%2\\$s %1\\$s", "Welt", "Hallo"), F.r_sprintf("%*d", 5.0, 42), F.r_sprintf("%-*d|", 4, 7), F.r_sprintf("%+.2f%%%s", 1.234, " p. a."), F.r_sprintf("%s %g %%", "Rate", 2.5), F.r_sprintf("%g:1", 1/3), F.r_sprintf("%%")])')
case("spf_recycle", "sprintf(c('%.1f', '%.3f'), c(1/3, 2/3, 1, 4/3))", "F.sprintf(np.array(['%.1f', '%.3f'], dtype=object), np.array([1/3, 2/3, 1, 4/3]))",
     jl = 'F.r_sprintf(["%.1f", "%.3f"], [1/3, 2/3, 1, 4/3])')
case("spf_pkg", "c(sprintf('%s(1,1) [%s]: mu=%.2e, omega=%.2e, alpha=%.4f', 'GARCH', 'A', 1.5e-4, 2e-6, 0.0812), sprintf('%s\\tKauf %.2fx %s zu %.2f EUR je Anteil am %s\\n', '2024-01-02', 3, 'ETF', 101.255, '2024-01-02'), sprintf('%d von %d Pfaden entfernt\\n', 3L, 100L))",
     "[F.sprintf('%s(1,1) [%s]: mu=%.2e, omega=%.2e, alpha=%.4f', 'GARCH', 'A', 1.5e-4, 2e-6, 0.0812), F.sprintf('%s\\tKauf %.2fx %s zu %.2f EUR je Anteil am %s\\n', '2024-01-02', 3.0, 'ETF', 101.255, '2024-01-02'), F.sprintf('%d von %d Pfaden entfernt\\n', 3, 100)]",
     jl = '[F.r_sprintf("%s(1,1) [%s]: mu=%.2e, omega=%.2e, alpha=%.4f", "GARCH", "A", 1.5e-4, 2e-6, 0.0812), F.r_sprintf("%s\\tKauf %.2fx %s zu %.2f EUR je Anteil am %s\\n", "2024-01-02", 3.0, "ETF", 101.255, "2024-01-02"), F.r_sprintf("%d von %d Pfaden entfernt\\n", 3, 100)]')
case("spf_rand", "lapply(c('%.2f', '%e', '%g', '%s', '%12.5g', '%.0f'), function(f) sprintf(f, x))",
     "[F.sprintf(f, x) for f in ('%.2f', '%e', '%g', '%s', '%12.5g', '%.0f')]", list(x = x_rr),
     jl = '[F.r_sprintf(f, x) for f in ("%.2f", "%e", "%g", "%s", "%12.5g", "%.0f")]')
case("spf_err1", "sprintf('%d', 1.5)", "F.sprintf('%d', 1.5)", jl = 'F.r_sprintf("%d", 1.5)')
case("spf_err2", "sprintf('%f', 'a')", "F.sprintf('%f', 'a')", jl = 'F.r_sprintf("%f", "a")')
case("spf_err3", "sprintf('%s %s', 'a')", "F.sprintf('%s %s', 'a')", jl = 'F.r_sprintf("%s %s", "a")')
case("spf_warn", "sprintf('%s', 'a', 'b')", "F.sprintf('%s', 'a', 'b')", jl = 'F.r_sprintf("%s", "a", "b")')

## ── print: Vektoren ────────────────────────────────────────────────────────
for (i in 1:30) {
  n <- sample(c(1:5, 9, 14, 26, 60, 150), 1); x <- rnum(n)
  if (runif(1) < 0.3) x[sample(n, 1)] <- sample(c(NA, NaN, Inf, -Inf, 0), 1)
  dg <- sample(c(NA, NA, NA, 3, 5, 10, 15), 1)
  r <- if (is.na(dg)) "print(x)" else sprintf("print(x, digits = %d)", dg)
  py <- if (is.na(dg)) "F.print_vector(x)" else sprintf("F.print_vector(x, digits=%d)", dg)
  case(sprintf("pv_num%02d", i), cap(r), py, list(x = x), nanpre("x", x), jl = py)
}
case("pv_int", cap("print(x)"), "F.print_vector(x)", list(x = c(1L, -20L, 300L, 100000L, 7L)), jl = "F.print_vector(x)")
case("pv_int_na", cap("print(x)"), "F.print_vector(x, type='integer')", list(x = c(1L, NA, 100000L, -5L)), jl = "F.print_vector(x)")
case("pv_int_long", cap("print(x)"), "F.print_vector(x)", list(x = 1:120), jl = "F.print_vector(x)")
case("pv_lgl", cap("print(x)"), "F.print_vector(x)", list(x = c(TRUE, NA, FALSE, TRUE)), jl = "F.print_vector(x)")
case("pv_lgl_long", cap("print(x)"), "F.print_vector(x)", list(x = rep(c(TRUE, FALSE, NA), 13)), jl = "F.print_vector(x)")
s_p <- c("Gesamtrendite", "CAGR (TWR)", "Volatilität p. a.", NA, "", "a\\b", "\"q\"", "日本", "tab\there", "Zeile\nneu", "Max. Drawdown", "R²", "M² (Modigliani)", "€", "–")
case("pv_chr", cap("print(s)"), "F.print_vector(s)", list(s = s_p), jl = "F.print_vector(s)")
case("pv_chr_noq", cap("print(s, quote = FALSE)"), "F.print_vector(s, quote=False)", list(s = s_p), jl = "F.print_vector(s, quote_=false)")
case("pv_chr_right", cap("print(s, right = TRUE)"), "F.print_vector(s, right=True)", list(s = s_p), jl = "F.print_vector(s, right=true)")
case("pv_chr_long", cap("print(s)"), "F.print_vector(s)", list(s = rep(s_p, 4)), jl = "F.print_vector(s)")
case("pv_named_num", cap("print(x)"), "F.print_vector(x)", list(x = setNames(rnum(14, 2), paste0("Anlage", 1:14))), jl = "F.print_vector(x)")
case("pv_named_long", cap("print(x)"), "F.print_vector(x)", list(x = setNames(round(rnorm(25), 3), c(month.abb, month.name, "x"))), jl = "F.print_vector(x)")
case("pv_named_chr", cap("print(x)"), "F.print_vector(x)", list(x = c(Typ = "Entnahme", Rate = "4 %", `Längerer Name` = NA)), jl = "F.print_vector(x)")
case("pv_named_chr_noq", cap("print(x, quote = FALSE)"), "F.print_vector(x, quote=False)", list(x = c(Typ = "Entnahme", Rate = "4 %", `Längerer Name` = NA)),
     jl = "F.print_vector(x, quote_=false)")
case("pv_named_lgl", cap("print(x)"), "F.print_vector(x)", list(x = c(a = TRUE, b = FALSE, c = NA)), jl = "F.print_vector(x)")
case("pv_named_int", cap("print(x)"), "F.print_vector(x)", list(x = c(jump = 5L, stale = 10L, revert = 100000L)), jl = "F.print_vector(x)")
case("pv_named_digits", cap("print(x, digits = 3)"), "F.print_vector(x, digits=3)", list(x = c(sharpe = 0.81234, cagr = 0.0712345, vol = 0.1534)),
     jl = "F.print_vector(x, digits=3)")
case("pv_empty", "c(capture.output(print(numeric(0))), capture.output(print(character(0))), capture.output(print(integer(0))), capture.output(print(logical(0))), capture.output(print(NULL)), capture.output(print(c(a = 1)[0])))",
     "[F.print_vector(np.array([], dtype=float)), F.print_vector(np.array([], dtype=object)), F.print_vector(np.array([], dtype=np.int64)), F.print_vector(np.array([], dtype=bool)), F.print_vector(None), F.print_vector(pd.Series(np.array([], dtype=float), index=pd.Index([], dtype=object)))]",
     jl = "[F.print_vector(Float64[]), F.print_vector(String[]), F.print_vector(Int[]), F.print_vector(Bool[]), F.print_vector(nothing), F.print_vector(SL.RVector(Float64[]; names=String[]))]")
case("pv_factor", cap("print(factor(f, levels = lev))"), "F.print_factor(f, levels=lev)", list(f = as.character(c("b", "a", NA, "b", "Öl")), lev = c("Öl", "a", "b", "z")),
     jl = "F.print_factor(f, levels=lev)")
case("pv_factor_many", cap("print(factor(f, levels = lev))"), "F.print_factor(f, levels=lev)", list(f = sample(c(month.name, NA), 40, TRUE), lev = c(month.name, paste("Level", 1:20))),
     jl = "F.print_factor(f, levels=lev)")
case("pv_factor_ord", cap("print(factor(f, levels = lev, ordered = TRUE))"), "F.print_factor(f, levels=lev, ordered=True)", list(f = c("niedrig", "hoch", "mittel"), lev = c("niedrig", "mittel", "hoch")),
     jl = "F.print_factor(f, levels=lev, ordered=true)")
case("pv_width", cap("{ op <- options(width = 40); on.exit(options(op)); print(x) }"), "_r", list(x = rnum(20, 3)),
     pre = "_old = F.set_options(width=40)\ntry:\n    _r = F.print_vector(x)\nfinally:\n    F.set_options(**_old)\n",
     jlpre = "_old = F.set_options(width=40)\n", jl = "try F.print_vector(x) finally F.set_options(; _old...) end")

## ── print: Matrizen ────────────────────────────────────────────────────────
mats <- list(
  m1 = matrix(rnum(12, 2), 3),
  m2 = round(matrix(rnorm(20), 4, dimnames = list(c("SPY", "TLT", "GLD", "Cash"), c("SPY", "TLT", "GLD", "Cash", "Ø"))), 3),
  m3 = round(100 * matrix(rnorm(36) / 10, 3, 12, dimnames = list(c("2021", "2022", "2023"), month.abb)), 2),
  m4 = matrix(c(1.5, NA, -Inf, 0, 1e6, 1e-8), 2, dimnames = list(NULL, c("a", "b", "c"))),
  m5 = matrix(rnum(4, 5), 2, dimnames = list(c("Zeile eins", "z2"), NULL)),
  m6 = round(matrix(rnorm(60) * 1000, 3, 20), 1),
  m7 = round(matrix(runif(16), 4, dimnames = list(paste("Strategie", LETTERS[1:4]), c("Rendite p. a.", "Volatilität", "Sharpe Ratio", "Max. Drawdown"))), 4))
for (k in names(mats)) case(paste0("pm_", k), cap("print(m)"), "F.print_matrix(m)", list(m = mats[[k]]), jl = "F.print_matrix(m)")
case("pm_digits", cap("print(m, digits = 3)"), "F.print_matrix(m, digits=3)", list(m = mats$m2), jl = "F.print_matrix(m, digits=3)")
case("pm_int", cap("print(m)"), "F.print_matrix(m, type='integer')", list(m = matrix(c(1L, NA, 300L, -4L, 100000L, 6L), 2, dimnames = list(c("a", "b"), c("x", "y", "z")))),
     jl = 'F.print_matrix(m, type="integer")')
case("pm_lgl", cap("print(m)"), "F.print_matrix(m)", list(m = matrix(c(TRUE, NA, FALSE, TRUE), 2)), jl = "F.print_matrix(m)")
m_chr <- matrix(c("a", "Ärger", NA, "x y", "\"q\"", "日本"), 2, dimnames = list(c("r1", "Zeile 2"), c("A", "Spalte B", "C")))
case("pm_chr", cap("print(m)"), "F.print_matrix(m)", list(m = m_chr), jl = "F.print_matrix(m)")
case("pm_chr_noq", cap("print(m, quote = FALSE)"), "F.print_matrix(m, quote=False)", list(m = m_chr), jl = "F.print_matrix(m, quote_=false)")
case("pm_chr_right", cap("print(m, quote = FALSE, right = TRUE)"), "F.print_matrix(m, quote=False, right=True)", list(m = m_chr),
     jl = "F.print_matrix(m, quote_=false, right=true)")
case("pm_chr_nodn", cap("print(m)"), "F.print_matrix(m)", list(m = unname(m_chr)), jl = "F.print_matrix(m)")
case("pm_wide_chr", cap("print(m, quote = FALSE)"), "F.print_matrix(m, quote=False)", list(m = matrix(sprintf("%.2f %%", rnorm(48) * 10), 2, 24)),
     jl = "F.print_matrix(m, quote_=false)")
case("pm_empty", "c(paste(capture.output(print(matrix(numeric(0), 0, 0))), collapse = '\\n'), paste(capture.output(print(matrix(numeric(0), 0, 3))), collapse = '\\n'), paste(capture.output(print(matrix(numeric(0), 2, 0))), collapse = '\\n'))",
     "[F.print_matrix(np.zeros((0, 0))), F.print_matrix(np.zeros((0, 3))), F.print_matrix(np.zeros((2, 0)))]",
     jl = "[F.print_matrix(zeros(0, 0)), F.print_matrix(zeros(0, 3)), F.print_matrix(zeros(2, 0))]")
case("pm_dnn", cap("print(table(c('a', 'b', 'a'), c('x', 'y', 'y')))"),
     "F.print_matrix(np.array([[1, 1], [0, 1]]), rownames=['a', 'b'], colnames=['x', 'y'], dimnames_names=('', ''))",
     jl = 'F.print_matrix([1 1; 0 1], rownames=["a", "b"], colnames=["x", "y"], dimnames_names=("", ""))')

## ── print: data.frames ─────────────────────────────────────────────────────
d1 <- data.frame(date = as.Date("2024-01-01") + c(0, 31, 60, 91), Wert = c(100, 101.25, 99.5, NA), n = c(1L, 20L, NA, 4L),
                 Typ = c("Kauf", "Verkauf", NA, "Ärger"), ok = c(TRUE, FALSE, NA, TRUE),
                 f = factor(c("a", "b", NA, "a")), stringsAsFactors = FALSE)
case("pdf_mixed", cap("print(d)"), sprintf("F.print_data_frame(d, types=%s)", dftypes(d1)), list(d = d1), jl = "F.print_data_frame(d)")
case("pdf_mixed_norn", cap("print(d, row.names = FALSE)"), sprintf("F.print_data_frame(d, row_names=False, types=%s)", dftypes(d1)), list(d = d1),
     jl = "F.print_data_frame(d, row_names=false)")
case("pdf_digits", cap("print(d, digits = 3)"), sprintf("F.print_data_frame(d, digits=3, types=%s)", dftypes(d1)), list(d = d1),
     jl = "F.print_data_frame(d, digits=3)")
case("pdf_rn", cap("print(d)"), "F.print_data_frame(d)", list(d = data.frame(Rendite = c(0.0712, -0.031), Vol = c(0.15, 0.2), row.names = c("Strategie A", "Benchmark"))),
     jl = "F.print_data_frame(d)")
case("pdf_head", cap("print(head(d))"), "F.print_data_frame(d.head(6))",
     list(d = data.frame(date = as.Date("2000-01-03") + 0:9, SPY = round(100 * cumprod(1 + rnorm(10, 0, 0.01)), 4), TLT = rnorm(10))),
     jl = "F.print_data_frame(SL.rows(d, 1:6))")
case("pdf_head5", cap("print(utils::head(d, 5), row.names = FALSE)"), "F.print_data_frame(d.head(5), row_names=False)",
     list(d = data.frame(start = as.Date("2008-01-02") + c(0, 300, 900, 1500, 2000, 2500), depth = sprintf("%.2f %%", -runif(6) * 50), days = c(120L, 30L, 400L, 5L, 66L, 7L))),
     jl = "F.print_data_frame(SL.rows(d, 1:5), row_names=false)")
case("pdf_pkg1", cap("print(data.frame(Anlage = a, Gewicht = sprintf('%.1f %%', 100 * w), Beitrag = sprintf('%.2f', b), check.names = FALSE), row.names = FALSE)"),
     "F.print_data_frame(pd.DataFrame({'Anlage': a, 'Gewicht': F.sprintf('%.1f %%', 100 * w), 'Beitrag': F.sprintf('%.2f', b)}), row_names=False)",
     list(a = c("SPY", "TLT", "Gold", "Geldmarkt"), w = c(0.45, 0.3, 0.15, 0.1), b = c(0.0123, -0.002, 0.00451, 0)),
     jl = 'F.print_data_frame(SL.RFrame("Anlage" => a, "Gewicht" => F.r_sprintf("%.1f %%", 100 .* w), "Beitrag" => F.r_sprintf("%.2f", b)), row_names=false)')
case("pdf_pkg2", cap("print(data.frame(Jahre = c(1L, 3L, 5L), Minimum = sprintf('%.1f %%', c(-35.2, -12.1, -3.4)), `Sharpe Mittel` = c(0.81234, 0.7, 1.2), check.names = FALSE), row.names = FALSE)"),
     "F.print_data_frame(pd.DataFrame({'Jahre': np.array([1, 3, 5]), 'Minimum': F.sprintf('%.1f %%', np.array([-35.2, -12.1, -3.4])), 'Sharpe Mittel': np.array([0.81234, 0.7, 1.2])}), row_names=False)",
     jl = 'F.print_data_frame(SL.RFrame("Jahre" => [1, 3, 5], "Minimum" => F.r_sprintf("%.1f %%", [-35.2, -12.1, -3.4]), "Sharpe Mittel" => [0.81234, 0.7, 1.2]), row_names=false)')
case("pdf_wide", cap("print(d)"), "F.print_data_frame(d)", list(d = as.data.frame(setNames(lapply(1:14, function(j) round(rnorm(3) * 10^(j %% 5), 2)), paste0("Spalte_", 1:14)))),
     jl = "F.print_data_frame(d)")
case("pdf_wide_norn", cap("print(d, row.names = FALSE)"), "F.print_data_frame(d, row_names=False)", list(d = as.data.frame(setNames(lapply(1:9, function(j) sprintf("Text %d mit Länge", j * 100 + 1:2)), paste0("Spaltenüberschrift_", 1:9)))),
     jl = "F.print_data_frame(d, row_names=false)")
case("pdf_empty0", cap("print(data.frame())"), "F.print_data_frame(pd.DataFrame())", jl = "F.print_data_frame(SL.RFrame())")
case("pdf_rows0", cap("print(data.frame(a = numeric(0), Typ = character(0)))"), "F.print_data_frame(pd.DataFrame({'a': np.array([], dtype=float), 'Typ': np.array([], dtype=object)}))",
     jl = 'F.print_data_frame(SL.RFrame("a" => Float64[], "Typ" => String[]))')
case("pdf_cols0", cap("print(d[, 0])"), "F.print_data_frame(d.iloc[:, :0])", list(d = data.frame(a = 1:3)),
     jl = "F.print_data_frame(SL.RFrame(String[], Any[]; nrow = SL.nrow(d)))")
case("pdf_cols0_1row", cap("print(d[, 0, drop = FALSE])"), "F.print_data_frame(d.iloc[:, :0])", list(d = data.frame(a = 5)),
     jl = "F.print_data_frame(SL.RFrame(String[], Any[]; nrow = SL.nrow(d)))")
case("pdf_allna", cap("print(d)"), "F.print_data_frame(d, types={'b': 'character'})", list(d = data.frame(a = c(NA_real_, NA), b = c(NA_character_, NA))),
     jl = "F.print_data_frame(d)")
for (i in 1:12) {
  nr <- sample(c(2:5, 8, 15), 1)  # Länge 1 mit NA kann reftree.decode nicht abbilden
  cols <- list(x = rnum(nr), y = round(rnorm(nr), sample(0:3, 1)), z = sample(c("a", "Öl", "längerer Text", NA), nr, TRUE),
               i = sample(c(1:10, NA, 100000L), nr, TRUE), l = sample(c(TRUE, FALSE), nr, TRUE),
               d = as.Date("2019-06-30") + sample(0:3000, nr), f = factor(sample(c("niedrig", "hoch", NA), nr, TRUE)))
  d <- as.data.frame(cols[sample(names(cols), sample(2:6, 1))], stringsAsFactors = FALSE)
  rn <- sample(c(TRUE, TRUE, FALSE), 1)
  case(sprintf("pdf_rand%02d", i), cap(sprintf("print(d, row.names = %s)", rn)),
       sprintf("F.print_data_frame(d, row_names=%s, types=%s)", pyl(rn), dftypes(d)), list(d = d),
       jl = sprintf("F.print_data_frame(d, row_names=%s)", jll(rn)))
}

## ── print: Listen, cat ─────────────────────────────────────────────────────
case("plist1", cap("print(l)"), "F.print_list(l)", list(l = list(a = 1, b = "x", c = list(d = 1:3, 2), `x y` = NULL, z = c(TRUE, NA))), jl = "F.print_list(l)")
case("plist2", cap("print(l)"), "F.print_list(l)", list(l = list(1.5, "a", list(c(1.25, 100)))), jl = "F.print_list(l)")
case("plist3", cap("print(l)"), "F.print_list(l)", list(l = list(settings = c(jump = 0.25, stale = 5, revert = 0.1), n = 3L, m = matrix(1:4, 2), d = data.frame(a = 1:2, b = c("x", "y")))),
     jl = "F.print_list(l)")
case("plist_empty", "c(paste(capture.output(print(list())), collapse = '\\n'), paste(capture.output(print(setNames(list(), character(0)))), collapse = '\\n'))",
     "[F.print_list([]), F.print_list({})]", jl = "[F.print_list(Any[]), F.print_list(SL.RList())]")
case("cat1", "capture.output(cat(1/3, 1e5, 123456.7, 1e-20, NA, NaN, TRUE, 3L, Inf, -0.5, 1e15, 100000.1, 0.1 + 0.2, '\\n'))",
     "F.cat_str(1/3, 1e5, 123456.7, 1e-20, F.NA_REAL, np.nan, True, 3, np.inf, -0.5, 1e15, 100000.1, 0.1 + 0.2, '\\n').rstrip('\\n')",
     jl = 'String(rstrip(F.cat_str(1/3, 1e5, 123456.7, 1e-20, SL.NA, NaN, true, 3, Inf, -0.5, 1e15, 100000.1, 0.1 + 0.2, "\\n"), \'\\n\'))')
case("cat2", "paste(capture.output(cat('a', character(0), 'b', NULL, c(1, 2), c('x', 'y'), sep = c('-', '+'))), collapse = '\\n')",
     "F.cat_str('a', np.array([], dtype=object), 'b', None, np.array([1.0, 2.0]), np.array(['x', 'y'], dtype=object), sep=['-', '+'])",
     jl = 'F.cat_str("a", String[], "b", nothing, [1.0, 2.0], ["x", "y"], sep=["-", "+"])')
case("cat3", "capture.output(cat(x, sep = '\\n'))", "F.cat_str(x, sep='\\n').rstrip('\\n').split('\\n')", list(x = rnum(10, 1)),
     jl = 'String.(split(rstrip(F.cat_str(x, sep="\\n"), \'\\n\'), \'\\n\'))')
case("cat_out", "cat('Wert:', 1/7, '\\n'); cat(sprintf('%.2f\\n', 2.5)); invisible(NULL)",
     "None\nF.r_cat('Wert:', 1/7, '\\n'); F.r_cat(F.sprintf('%.2f\\n', 2.5))",
     jl = 'nothing\nF.r_cat("Wert:", 1/7, "\\n"); F.r_cat(F.r_sprintf("%.2f\\n", 2.5))')

## ── Verteiler ──────────────────────────────────────────────────────────────
case("pdefault", "c(paste(capture.output(print(1:3)), collapse = '\\n'), paste(capture.output(print(data.frame(a = 1:2))), collapse = '\\n'), paste(capture.output(print(matrix(1:4, 2))), collapse = '\\n'), paste(capture.output(print(list(a = 1))), collapse = '\\n'))",
     "[F.print_default(np.arange(1, 4)), F.print_default(pd.DataFrame({'a': np.array([1, 2])})), F.print_default(np.array([[1, 3], [2, 4]])), F.print_default({'a': 1.0})]",
     jl = '[F.print_default(1:3), F.print_default(SL.RFrame("a" => [1, 2])), F.print_default([1 3; 2 4]), F.print_default(SL.RList("a" => 1.0))]')

## ── Ergänzungen ────────────────────────────────────────────────────────────
case("date_wide", "format(d, '%Y-%m-%d|%C|%G|%y|%a|%V|%j|%U|%W')", "F.format_date(d, '%Y-%m-%d|%C|%G|%y|%a|%V|%j|%U|%W')",
     list(d = as.Date(c(3e6, -1e6, -719528, -719529, -719162, 0, 19000, sample(-800000:3000000, 40)))),
     jl = 'F.format_date(d, "%Y-%m-%d|%C|%G|%y|%a|%V|%j|%U|%W")')
case("date_flags", "format(d, '%C|%g|%10Y|%_d|%-m|%^b|%#A|%_3j|%-e|%0e|%6C|%s|%r|%R|%T|%p|%P|%Z|%z|%h|%n|%t|%%|%q|%k|%l|%I|%Ey|%Od|%-V')",
     "F.format_date(d, '%C|%g|%10Y|%_d|%-m|%^b|%#A|%_3j|%-e|%0e|%6C|%s|%r|%R|%T|%p|%P|%Z|%z|%h|%n|%t|%%|%q|%k|%l|%I|%Ey|%Od|%-V')",
     list(d = as.Date(c("2024-03-05", "0999-12-31", "2000-01-09"))),
     jl = 'F.format_date(d, "%C|%g|%10Y|%_d|%-m|%^b|%#A|%_3j|%-e|%0e|%6C|%s|%r|%R|%T|%p|%P|%Z|%z|%h|%n|%t|%%|%q|%k|%l|%I|%Ey|%Od|%-V")')
case("date_numeric", "format(as.Date(c(0, 19000.7, -1)), '%d.%m.%Y')", "F.format_date(np.array([0, 19000.7, -1]), '%d.%m.%Y')",
     jl = 'F.format_date([0, 19000.7, -1], "%d.%m.%Y")')
# Schalter, Breiten und E/O (seit 1.3.0) wie glibc unter Linux; %OS mit options(digits.secs)
case("date_flags_glibc", "format(d, '%-5d|%5q|%Ob|%#p|%^#Z|%08s|%-3C|%5z|%#Eb|%2n|%^P|%_-4Y|%EA|%5')",
     "F.format_date(d, '%-5d|%5q|%Ob|%#p|%^#Z|%08s|%-3C|%5z|%#Eb|%2n|%^P|%_-4Y|%EA|%5')",
     list(d = as.Date(c("2024-03-05", "0999-12-31", "1969-12-31", "0000-01-01"))),
     jl = 'F.format_date(d, "%-5d|%5q|%Ob|%#p|%^#Z|%08s|%-3C|%5z|%#Eb|%2n|%^P|%_-4Y|%EA|%5")')
case("opt_digits_secs", "local({ op <- options(digits.secs = 3); on.exit(options(op)); format(as.Date(c('2020-03-04', '1999-12-31', '2000-01-01', '1970-01-01')), c('%OS', '%H:%M:%OS', '%OS1|%OS', '%%OS')) })",
     "_r", pre = "_old = F.set_options(digits_secs=3)\ntry:\n    _r = F.format_date(np.array(['2020-03-04', '1999-12-31', '2000-01-01', '1970-01-01'], dtype='datetime64[D]'), ['%OS', '%H:%M:%OS', '%OS1|%OS', '%%OS'])\nfinally:\n    F.set_options(**_old)\n",
     jlpre = "_old = F.set_options(digits_secs=3)\n",
     jl = 'try F.format_date([Date(2020, 3, 4), Date(1999, 12, 31), Date(2000, 1, 1), Date(1970, 1, 1)], ["%OS", "%H:%M:%OS", "%OS1|%OS", "%%OS"]) finally F.set_options(; _old...) end')
case("misc_null", "c(format(NULL), as.character(c(a = 1.5)), sprintf('%s', as.Date('2024-01-31')), paste(factor(c('x', 'y')), as.Date('2020-02-02')))",
     "[F.format(None), *F.as_character(pd.Series([1.5], index=['a'])), F.sprintf('%s', np.datetime64('2024-01-31')), *F.paste(pd.Categorical(['x', 'y']), np.datetime64('2020-02-02'))]",
     jl = '[F.format(nothing), F.as_character(SL.RVector([1.5]; names=["a"]))..., F.r_sprintf("%s", Date(2024, 1, 31)), F.paste(F.r_factor(["x", "y"]), Date(2020, 2, 2))...]')
case("misc_bigint", "c(format(3e9), format(c(1, 3e9)), as.character(3e9))", "[F.format(3000000000), *F.format(np.array([1, 3000000000])), F.as_character(3000000000)]",
     jl = "[F.format(3000000000), F.format([1, 3000000000])..., F.as_character(3000000000)]")
case("misc_nchar", "c(nchar(c('Ärger', '日本', 'a\\\\b')), nchar(c('Ärger', '日本'), type = 'bytes'), nchar(c('Ärger', '日本'), type = 'width'))",
     "np.concatenate([F.nchar(np.array(['Ärger', '日本', 'a\\\\b'], dtype=object)), F.nchar(np.array(['Ärger', '日本'], dtype=object), type='bytes'), F.nchar(np.array(['Ärger', '日本'], dtype=object), type='width')])",
     jl = 'vcat(F.nchar(["Ärger", "日本", "a\\\\b"]), F.nchar(["Ärger", "日本"], type="bytes"), F.nchar(["Ärger", "日本"], type="width"))')
case("misc_zeroprint", "format(c(0, 1), zero.print = 'abc')", "F.format(np.array([0.0, 1.0]), zero_print='abc')",
     jl = 'F.format([0.0, 1.0], zero_print="abc")')
case("misc_encode", "c(encodeString(c('a', 'Zeile\nneu', NA), quote = '\"'), encodeString('x', width = 5, justify = 'right'))",
     "[*F.encode_string(np.array(['a', 'Zeile\\nneu', None], dtype=object), quote='\"'), F.encode_string('x', width=5, justify='right')]",
     jl = '[F.encode_string(["a", "Zeile\\nneu", missing], quote_="\\"")..., F.encode_string("x", width=5, justify="right")]')

case("fmt_matrix", "list(format(m), formatC(m, format = 'f', digits = 1), formatC(round(100 * m, 1), digits = 1, format = 'f'), formatC(md, format = 'f', digits = 2, width = 8))",
     "[F.format(m), F.formatC(m, format='f', digits=1), F.formatC(F.r_round(np.array([[100 * v for v in row] for row in m.tolist()]), 1), digits=1, format='f'), F.formatC(md, format='f', digits=2, width=8)]",
     list(m = matrix(c(1.5, 3, 2, 40.25, -0.004, NA), 2), md = matrix(c(0.1234, -5, 12.5, NA), 2, dimnames = list(c("a", "b"), c("x", "y")))),
     jl = '[F.format(m), F.formatC(m, format="f", digits=1), F.formatC(F.r_round(100 .* m, 1), digits=1, format="f"), F.formatC(md, format="f", digits=2, width=8)]')

case("opt_scipen", "local({ op <- options(scipen = 100); on.exit(options(op)); c(as.character(1e5), format(1e10), capture.output(print(c(1e-10, 1))), capture.output(cat(1e5)), sprintf('%s', 1e20)) })",
     "_r", pre = "_old = F.set_options(scipen=100)\ntry:\n    _r = [F.as_character(1e5), F.format(1e10), F.print_vector(np.array([1e-10, 1.0])), F.cat_str(1e5), F.sprintf('%s', 1e20)]\nfinally:\n    F.set_options(**_old)\n",
     jlpre = "_old = F.set_options(scipen=100)\n",
     jl = 'try [F.as_character(1e5), F.format(1e10), F.print_vector([1e-10, 1.0]), F.cat_str(1e5), F.r_sprintf("%s", 1e20)] finally F.set_options(; _old...) end')
case("opt_digits", "local({ op <- options(digits = 3); on.exit(options(op)); c(format(pi), capture.output(print(c(a = 1/3, b = 2/3))), as.character(pi)) })",
     "_r", pre = "_old = F.set_options(digits=3)\ntry:\n    _r = [F.format(math.pi), *F.print_vector(pd.Series([1/3, 2/3], index=['a', 'b'])).split('\\n'), F.as_character(math.pi)]\nfinally:\n    F.set_options(**_old)\n",
     jlpre = "_old = F.set_options(digits=3)\n",
     jl = 'try [F.format(Float64(pi)), split(F.print_vector(SL.RVector([1/3, 2/3]; names=["a", "b"])), \'\\n\')..., F.as_character(Float64(pi))] finally F.set_options(; _old...) end')

## ── Zufallsfälle: Matrizen und data.frames ─────────────────────────────────
set.seed(99)
rchr <- function(n) sample(c("a", "bb", "Ärger", "Öl", "x y", "", "Straße", "日本", "long string here", NA), n, TRUE)
for (i in 1:15) {
  nr <- sample(2:6, 1); nc <- sample(c(1:5, 9, 13), 1)
  t <- sample(c("dbl", "dbl", "int", "lgl", "chr"), 1)
  v <- switch(t, dbl = round(rnum(nr * nc), sample(0:4, 1)), int = sample(c(-50:50, NA, 100000L), nr * nc, TRUE),
              lgl = sample(c(TRUE, FALSE, NA), nr * nc, TRUE), chr = rchr(nr * nc))
  m <- matrix(v, nr, nc)
  if (runif(1) < 0.7) dimnames(m) <- list(if (runif(1) < 0.7) paste0("r", seq_len(nr)) else NULL, if (runif(1) < 0.8) sample(c("SPY", "TLT", "Gold", "Längerer Name", "x"), nc, TRUE) else NULL)
  q <- sample(c(TRUE, FALSE), 1); rt <- sample(c(TRUE, FALSE), 1)
  ty <- if (t == "int") ", type='integer'" else ""
  case(sprintf("pm_rand%02d", i), cap(sprintf("print(m, quote = %s, right = %s)", q, rt)),
       sprintf("F.print_matrix(m, quote=%s, right=%s%s)", pyl(q), pyl(rt), ty), list(m = m), if (t == "dbl") nanpre("m", m) else "",
       jl = sprintf("F.print_matrix(m, quote_=%s, right=%s%s)", jll(q), jll(rt), gsub("'", "\"", ty)))
}
for (i in 1:15) {
  nr <- sample(c(2:6, 12), 1)
  cols <- list(Datum = as.Date("2015-01-01") + sort(sample(0:4000, nr)), Wert = round(rnum(nr), sample(1:4, 1)), Anteil = runif(nr),
               Anzahl = sample(c(0:20, NA, 123456L), nr, TRUE), Name = rchr(nr), Flag = sample(c(TRUE, FALSE, NA), nr, TRUE),
               Klasse = factor(sample(c("hoch", "mittel", "niedrig", NA), nr, TRUE)), Groß = rnorm(nr) * 1e7, Klein = rnorm(nr) * 1e-6)
  d <- as.data.frame(cols[sample(names(cols), sample(2:7, 1))], stringsAsFactors = FALSE)
  if (runif(1) < 0.3) row.names(d) <- paste("Zeile", seq_len(nr))
  rn <- sample(c(TRUE, TRUE, FALSE), 1); dg <- sample(c(NA, NA, 3, 5), 1)
  r <- sprintf("print(d, row.names = %s%s)", rn, if (is.na(dg)) "" else sprintf(", digits = %d", dg))
  py <- sprintf("F.print_data_frame(d, row_names=%s%s, types=%s)", pyl(rn), if (is.na(dg)) "" else sprintf(", digits=%d", dg), dftypes(d))
  case(sprintf("pdf_mix%02d", i), cap(r), py, list(d = d),
       jl = sprintf("F.print_data_frame(d, row_names=%s%s)", jll(rn), if (is.na(dg)) "" else sprintf(", digits=%d", dg)))
}

ref_done()

# ════════════════════════════════════════════════════════════════════════════════════════════════════
# Modul r_nana
# ════════════════════════════════════════════════════════════════════════════════════════════════════
# Referenzfälle: NA/NaN-Kombinationen in den long-double-Kumulationen von R
# (sum, mean, prod, cumsum, cumprod, cummax, cummin, var, sd, colSums, rowSums,
# colMeans, rowMeans – je mit und ohne na.rm). Auf x86-64 entscheidet die
# x87-Regel für zwei NaN (ruhiges NaN schlägt signalisierendes Speicher-NA,
# sonst größere Mantisse), ob NA oder NaN herauskommt; cumsum/cumprod/cummax/
# cummin setzen das Ergebnis über handleNaN (cum.c).
# Python bildet die x87-Regel in simlev._r.rnum._x87_nan bzw. handleNaN nach (NA = NA_REAL).
ref_init("r_nana")

v5 <- c(2, NA_real_, NaN, Inf, -Inf)
v3 <- c(-1.5, NA_real_, NaN)
comb <- function(v, k) {
  g <- as.matrix(expand.grid(rep(list(seq_along(v)), k)))
  lapply(seq_len(nrow(g)), function(i) v[g[i, ]])
}
xs <- c(comb(v5, 1), comb(v5, 2), comb(v5, 3), comb(v3, 4),
        list(c(1, NaN, 3, NA), c(1, NA, 3, NaN), c(0, Inf, NA), c(0, NA, Inf), c(Inf, 0, NaN, NA),
             c(1e308, 1e308, NA), c(1e308, 1e308, NaN), c(-1e308, -1e308, NA, NaN)))
ms <- c(lapply(comb(v3, 4), matrix, nrow = 2),
        lapply(comb(v5, 3), matrix, nrow = 3), lapply(comb(v5, 3), matrix, nrow = 1),
        list(matrix(c(NaN, NA, NA, NaN, 1, NaN), 2), matrix(c(Inf, -Inf, NA, NaN, NA, Inf), 3)))

P <- "import numpy as np\nfrom simlev._r import base as B\nwith np.errstate(all='ignore'):\n    "
J <- "B = SL.RBase\n"
vf <- function(id, rf, pyf, jlf) {
  ref_case(id, sprintf("lapply(xs, %s)", rf),
           paste0(P, sprintf("result = [%s for x in xs]", pyf)),
           inputs = list(xs = xs),
           jl = paste0(J, sprintf("result = Any[%s for x in (vcat(x) for x in xs)]", jlf)))
}
vf("sum", "sum", "B.r_sum(x)", "B.r_sum(x)")
vf("sum_narm", "sum, na.rm = TRUE", "B.r_sum(x, na_rm=True)", "B.r_sum(x; na_rm = true)")
vf("mean", "mean", "B.r_mean(x)", "B.r_mean(x)")
vf("mean_narm", "mean, na.rm = TRUE", "B.r_mean(x, na_rm=True)", "B.r_mean(x; na_rm = true)")
vf("mean_all", "mean", "B.mean(x)", "B.mean(x)")
vf("prod", "prod", "B.r_prod(x)", "B.r_prod(x)")
vf("prod_narm", "prod, na.rm = TRUE", "B.r_prod(x, na_rm=True)", "B.r_prod(x; na_rm = true)")
vf("cumsum", "cumsum", "B.r_cumsum(x)", "B.r_cumsum(x)")
vf("cumprod", "cumprod", "B.cumprod(x)", "B.r_cumprod(x)")
vf("cumprod_engine", "cumprod", "simlev._r.rnum.r_cumprod(x)", "SL.r_cumprod(x)")
vf("cummax", "cummax", "B.cummax(x)", "B.r_cummax(x)")
vf("cummin", "cummin", "B.cummin(x)", "B.r_cummin(x)")
vf("var", "var", "B.r_var(x)", "B.r_var(x)")
vf("var_narm", "var, na.rm = TRUE", "B.r_var(x, na_rm=True)", "B.r_var(x; na_rm = true)")
vf("sd", "sd", "B.r_sd(x)", "B.r_sd(x)")
vf("sd_narm", "sd, na.rm = TRUE", "B.r_sd(x, na_rm=True)", "B.r_sd(x; na_rm = true)")

mf <- function(id, rf, narm) {
  ra <- if (narm) ", na.rm = TRUE" else ""
  pa <- if (narm) ", na_rm=True" else ""
  ja <- if (narm) "; na_rm = true" else ""
  ref_case(id, sprintf("lapply(ms, %s%s)", rf, ra),
           paste0(P, sprintf("result = [B.%s(m%s) for m in ms]", rf, pa)),
           inputs = list(ms = ms),
           jl = paste0(J, sprintf("result = Any[B.%s(m%s) for m in ms]", rf, ja)))
}
for (f in c("colSums", "rowSums", "colMeans", "rowMeans")) {
  mf(f, f, FALSE)
  mf(paste0(f, "_narm"), f, TRUE)
}
ref_case("rowsums_engine", "lapply(ms, function(m) rowSums(m))",
         paste0(P, "result = [simlev._r.rnum.r_rowsums(np.asarray(m, dtype=float)) for m in ms]"),
         inputs = list(ms = ms),
         jl = paste0(J, "result = Any[SL.r_rowsums([m[:, j] for j in 1:size(m, 2)]) for m in ms]"))
ref_done()

# ════════════════════════════════════════════════════════════════════════════════════════════════════
# Modul r_stats
# ════════════════════════════════════════════════════════════════════════════════════════════════════
# Referenzfälle für simlev._r.stats (und Ergänzungen in simlev._r.base).
# Aufruf aus der Repo-Wurzel:
# Die Fälle zu optim/optimHess, lm/lm.fit/poly/glm/summary.lm, smooth.spline, density/bw, fft und
# t.test sind entfallen (seit 1.0.0 keine Nachbildung dieser R-Routinen in Python und Julia; die
# Kerne der C-Bibliothek prüfen die Module slc_opt und slc_linalg). Damit ändern sich die zufälligen
# Eingaben der folgenden Abschnitte (dist/hclust).
ref_init("r_stats")

HDR <- "import math\nimport simlev._r.stats as st\nimport simlev._r.base as rb\n"
JHDR <- "const st = SL.RStats\nconst rb = SL.RBase\n"
cs <- function(id, r, py, inputs = list(), jl = NULL, ...)
  ref_case(id, r = r, py = paste0(HDR, py), inputs = inputs, jl = if (is.null(jl)) NULL else paste0(JHDR, jl), ...)

set.seed(11)
x1 <- rnorm(37); x2 <- round(rnorm(40) * 3)            # x2 mit Bindungen
x3 <- c(4.5, 1.25); x4 <- 2.5; xna <- c(x1[1:9], NA, x1[10:20])
y1 <- 0.4 * x1 + rnorm(37); y2 <- round(x2 + rnorm(40))
M <- matrix(rnorm(60), 20, 3); colnames(M) <- c("a", "b", "c")
Mna <- M; Mna[c(3, 17), 1] <- NA; Mna[5, 3] <- NA
Mu <- unname(matrix(round(rnorm(48) * 2), 12, 4))
pr <- c(0, 0.013, 0.25, 0.5, 2/3, 0.9, 0.999, 1)

## ── quantile / median ───────────────────────────────────────────────────
for (t in 1:9) {
  cs(sprintf("quantile_t%d_a", t), sprintf("quantile(x, pr, type = %d)", t),
     sprintf("result = st.quantile(x, pr, type=%d)", t), list(x = x1, pr = pr),
     jl = sprintf("result = st.quantile(x, pr; type = %d)", t))
  cs(sprintf("quantile_t%d_ties", t), sprintf("quantile(x, pr, type = %d, names = FALSE)", t),
     sprintf("result = st.quantile(x, pr, type=%d, names=False)", t), list(x = x2, pr = pr),
     jl = sprintf("result = st.quantile(x, pr; type = %d, names = false)", t))
  cs(sprintf("quantile_t%d_n2", t), sprintf("quantile(x, c(0.1, 0.5, 0.77), type = %d)", t),
     sprintf("result = st.quantile(x, [0.1, 0.5, 0.77], type=%d)", t), list(x = x3),
     jl = sprintf("result = st.quantile(x, [0.1, 0.5, 0.77]; type = %d)", t))
}
cs("quantile_default", "quantile(x)", "result = st.quantile(x)", list(x = x1), jl = "result = st.quantile(x)")
cs("quantile_n1", "quantile(x, c(0.3, 0.9))", "result = st.quantile(x, [0.3, 0.9])", list(x = x4), jl = "result = st.quantile(x, [0.3, 0.9])")
cs("quantile_probsNA", "quantile(x, c(0.1, NA, 0.8))", "result = st.quantile(x, [0.1, rb.NA_REAL, 0.8])", list(x = x1), jl = "result = st.quantile(x, [0.1, SL.NA, 0.8])")
cs("quantile_narm", "quantile(x, c(0.05, 0.95), na.rm = TRUE)", "result = st.quantile(x, [0.05, 0.95], na_rm=True)", list(x = xna), jl = "result = st.quantile(x, [0.05, 0.95]; na_rm = true)")
cs("quantile_err_na", "quantile(x, 0.5)", "result = st.quantile(x, 0.5)", list(x = xna), jl = "result = st.quantile(x, 0.5)")
cs("quantile_err_probs", "quantile(x, 1.2)", "result = st.quantile(x, 1.2)", list(x = x1), jl = "result = st.quantile(x, 1.2)")
cs("quantile_scalar", "quantile(x, 0.37, names = FALSE)", "result = st.quantile(x, 0.37, names=False)", list(x = x1), jl = "result = st.quantile(x, 0.37; names = false)")
cs("quantile_names_odd", "quantile(x, c(0.001, 0.0125, 1/3, 0.99999))",
   "result = st.quantile(x, [0.001, 0.0125, 1/3, 0.99999])", list(x = x1), jl = "result = st.quantile(x, [0.001, 0.0125, 1/3, 0.99999])")
cs("quantile_empty", "quantile(x, 0.5)", "result = st.quantile(x, 0.5)", list(x = numeric(0)), jl = "result = st.quantile(x, 0.5)")
cs("median_odd", "median(x)", "result = st.median(x)", list(x = x1), jl = "result = st.median(x)")
cs("median_even", "median(x)", "result = st.median(x)", list(x = x1[1:36]), jl = "result = st.median(x)")
cs("median_na", "median(x)", "result = st.median(x)", list(x = xna), jl = "result = st.median(x)")
cs("median_narm", "median(x, na.rm = TRUE)", "result = st.median(x, na_rm=True)", list(x = xna), jl = "result = st.median(x; na_rm = true)")
cs("median_int", "median(c(3L, 1L, 4L, 2L))", "result = st.median(np.array([3, 1, 4, 2]))", jl = "result = st.median([3, 1, 4, 2])")

## ── var / sd / cov / cor ─────────────────────────────────────────────────
cs("var_vec", "var(x)", "result = st.var(x)", list(x = x1), jl = "result = st.var(x)")
cs("var_na", "var(x)", "result = st.var(x)", list(x = xna), jl = "result = st.var(x)")
cs("var_narm", "var(x, na.rm = TRUE)", "result = st.var(x, na_rm=True)", list(x = xna), jl = "result = st.var(x; na_rm = true)")
cs("var_n1", "var(x)", "result = st.var(x)", list(x = x4), jl = "result = st.var(x)")
cs("var_mat", "var(M)", "result = st.var(M)", list(M = M), jl = "result = st.var(M)")
cs("var_xy", "var(x, y)", "result = st.var(x, y)", list(x = x1, y = y1), jl = "result = st.var(x, y)")
cs("sd_vec", "sd(x)", "result = st.sd(x)", list(x = x1), jl = "result = st.sd(x)")
cs("sd_narm", "sd(x, na.rm = TRUE)", "result = st.sd(x, na_rm=True)", list(x = xna), jl = "result = st.sd(x; na_rm = true)")
cs("sd_big", "sd(x)", "result = st.sd(x)", list(x = 1e8 + x1), jl = "result = st.sd(x)")
for (m in c("pearson", "kendall", "spearman")) {
  for (u in c("everything", "complete.obs", "pairwise.complete.obs", "na.or.complete", "all.obs")) {
    # cor(Mna, use = "everything", method = "kendall") warnt in R 4.3.3 nicht reproduzierbar
    # („the standard deviation is zero“ in 39 von 200 Aufrufen desselben Prozesses; Lesen nicht gesetzten
    # Speichers bei NA in cov.c); der Fall entfällt (nicht im Katalog, zieht keine Zufallszahlen).
    if (m == "kendall" && u == "everything") next
    cs(sprintf("cor_M_%s_%s", m, u), sprintf('cor(M, use = "%s", method = "%s")', u, m),
       sprintf('result = st.cor(M, use="%s", method="%s")', u, m), list(M = Mna),
       jl = sprintf('result = st.cor(M; use = "%s", method = "%s")', u, m))
  }
  cs(sprintf("cor_xy_%s", m), sprintf('cor(x, y, method = "%s")', m), sprintf('result = st.cor(x, y, method="%s")', m),
     list(x = x2, y = y2), jl = sprintf('result = st.cor(x, y; method = "%s")', m))
  cs(sprintf("cor_Mu_%s", m), sprintf('cor(M, method = "%s")', m), sprintf('result = st.cor(M, method="%s")', m), list(M = Mu), jl = sprintf('result = st.cor(M; method = "%s")', m))
  cs(sprintf("cor_My_%s", m), sprintf('cor(M, y, method = "%s", use = "complete.obs")', m),
     sprintf('result = st.cor(M, y, method="%s", use="complete.obs")', m), list(M = Mna, y = rnorm(20)), jl = sprintf('result = st.cor(M, y; method = "%s", use = "complete.obs")', m))
  cs(sprintf("cov_%s", m), sprintf('cov(M, method = "%s")', m), sprintf('result = st.cov(M, method="%s")', m), list(M = M), jl = sprintf('result = st.cov(M; method = "%s")', m))
  cs(sprintf("cov_xy_%s", m), sprintf('cov(x, y, method = "%s")', m), sprintf('result = st.cov(x, y, method="%s")', m),
     list(x = x1, y = y1), jl = sprintf('result = st.cov(x, y; method = "%s")', m))
}
cs("cor_df", "cor(d)", "result = st.cor(d)", list(d = as.data.frame(M)), jl = "result = st.cor(d)")
cs("cor_sd0", "cor(x, rep(1, 37))", "result = st.cor(x, np.ones(37))", list(x = x1), jl = "result = st.cor(x, ones(37))")
cs("cor_sd0_mat", "cor(cbind(x, 1))", "result = st.cor(np.column_stack([x, np.ones(37)]))", list(x = x1), jl = "result = st.cor(hcat(x, ones(37)))")
cs("cor_err_use", 'cor(x, y, use = "foo")', 'result = st.cor(x, y, use="foo")', list(x = x1, y = y1), jl = "result = st.cor(x, y; use = \"foo\")")
cs("cor_err_dims", "cor(x, y)", "result = st.cor(x, y)", list(x = x1, y = y1[1:30]), jl = "result = st.cor(x, y)")
cs("cor_err_supply", "cor(x)", "result = st.cor(x)", list(x = x1), jl = "result = st.cor(x)")
cs("cor_err_allobs", 'cor(x, y, use = "all.obs")', 'result = st.cor(x, y, use="all.obs")', list(x = xna, y = xna + 1), jl = "result = st.cor(x, y; use = \"all.obs\")")
cs("cor_pair1col", 'cor(M[, 1, drop = FALSE], method = "kendall", use = "pairwise.complete.obs")',
   'result = st.cor(M.iloc[:, :1], method="kendall", use="pairwise.complete.obs")', list(M = M), jl = "result = st.cor(M.data[:, 1:1]; method = \"kendall\", use = \"pairwise.complete.obs\")")
cs("cov_err_pair", 'cov(M, method = "spearman", use = "pairwise.complete.obs")',
   'result = st.cov(M, method="spearman", use="pairwise.complete.obs")', list(M = M), jl = "result = st.cov(M; method = \"spearman\", use = \"pairwise.complete.obs\")")
cs("cov2cor_a", "cov2cor(cov(M))", "result = st.cov2cor(st.cov(M))", list(M = M), jl = "result = st.cov2cor(st.cov(M))")
cs("cov2cor_warn", "cov2cor(matrix(c(1, 0.5, 0.5, -1), 2))", "result = st.cov2cor(np.array([[1, 0.5], [0.5, -1.]]))", jl = "result = st.cov2cor([1 0.5; 0.5 -1.0])")
cs("wmean_a", "weighted.mean(x, w)", "result = st.weighted_mean(x, w)", list(x = x1, w = runif(37)), jl = "result = st.weighted_mean(x, w)")
cs("wmean_zero", "weighted.mean(x, w)", "result = st.weighted_mean(x, w)", list(x = c(1, NA, 3), w = c(1, 0, 2)), jl = "result = st.weighted_mean(x, w)")
cs("wmean_isnan", "r <- c(weighted.mean(c(1, 2), c(0, 0)), weighted.mean(c(NA, 2), c(1, 0)), weighted.mean(numeric(0))); c(is.na(r), is.nan(r))",
   "import simlev._r.fmt as fm\nr = [st.weighted_mean([1, 2], [0, 0]), st.weighted_mean([fm.NA_REAL, 2], [1, 0]), st.weighted_mean(np.zeros(0))]\nresult = np.array([x != x for x in r] + [fm._is_rnan(x) for x in r])", jl = "r = [st.weighted_mean([1.0, 2], [0.0, 0]), st.weighted_mean([SL.NA, 2], [1.0, 0]), st.weighted_mean(Float64[])]\nresult = vcat(isnan.(r), [isnan(v) && !SL.isna_strict(v) for v in r])")
cs("cov2cor_isnan", "r <- suppressWarnings(cov2cor(matrix(c(1, 0.5, 0.2, 0.5, -1, 0, 0.2, 0, 0), 3))); r[1, 1] <- NA; c(r, is.nan(r))",
   "import simlev._r.fmt as fm\nimport warnings\nwith warnings.catch_warnings():\n    warnings.simplefilter('ignore')\n    r = st.cov2cor(np.array([[1, 0.5, 0.2], [0.5, -1, 0], [0.2, 0, 0.]]))\nr[0, 0] = fm.NA_REAL\nresult = np.concatenate([r.ravel(order='F'), fm._nan_mask(r.ravel(order='F'))])", jl = "import Logging\nr = Logging.with_logger(Logging.NullLogger()) do\n    st.cov2cor([1 0.5 0.2; 0.5 -1 0; 0.2 0 0.0])\nend\nr[1, 1] = SL.NA\nresult = vcat(vec(r), [Float64(isnan(v) && !SL.isna_strict(v)) for v in vec(r)])")
cs("cov2cor_na", "r <- suppressWarnings(cov2cor(matrix(c(2, NA, 0.2, NA, -1, 0, 0.2, 0, NA), 3))); c(r, is.nan(r))",
   "import simlev._r.fmt as fm\nimport warnings\nwith warnings.catch_warnings():\n    warnings.simplefilter('ignore')\n    r = st.cov2cor(np.array([[2, fm.NA_REAL, 0.2], [fm.NA_REAL, -1, 0], [0.2, 0, fm.NA_REAL]]))\nresult = np.concatenate([r.ravel(order='F'), fm._nan_mask(r.ravel(order='F'))])", jl = "import Logging\nr = Logging.with_logger(Logging.NullLogger()) do\n    st.cov2cor([2 SL.NA 0.2; SL.NA -1 0; 0.2 0 SL.NA])\nend\nresult = vcat(vec(r), [Float64(isnan(v) && !SL.isna_strict(v)) for v in vec(r)])")
cs("wmean_narm", "weighted.mean(x, w, na.rm = TRUE)", "result = st.weighted_mean(x, w, na_rm=True)",
   list(x = xna, w = runif(21)), jl = "result = st.weighted_mean(x, w; na_rm = true)")
cs("wmean_now", "weighted.mean(x)", "result = st.weighted_mean(x)", list(x = x1), jl = "result = st.weighted_mean(x)")
cs("scale_default", "scale(M)", "result = st.scale(M)", list(M = unname(M)), jl = "result = st.scale(M)")
cs("scale_noc", "scale(M, center = FALSE)", "result = st.scale(M, center=False)", list(M = unname(Mna)), jl = "result = st.scale(M; center = false)")
cs("scale_num", "scale(M, center = c(1, 2, 3), scale = c(2, 2, 0.5))",
   "result = st.scale(M, center=[1, 2, 3], scale=[2, 2, 0.5])", list(M = unname(M)), jl = "result = st.scale(M; center = [1, 2, 3], scale = [2, 2, 0.5])")

## ── approx / approxfun / filter ──────────────────────────────────────────
ax <- c(1, 2, 2.5, 4, 7, 8.25); ay <- c(3, -1, 0.5, 2, 2.2, 10)
xo <- c(-1, 1, 1.7, 2.5, 3.99, 7.5, 8.25, 9, NA)
cs("approx_lin", "approx(x, y, xout = xo)", "result = st.approx(x, y, xout=xo)", list(x = ax, y = ay, xo = xo), jl = "result = st.approx(x, y; xout = xo)")
cs("approx_rule2", "approx(x, y, xout = xo, rule = 2)", "result = st.approx(x, y, xout=xo, rule=2)",
   list(x = ax, y = ay, xo = xo), jl = "result = st.approx(x, y; xout = xo, rule = 2)")
cs("approx_rule12", "approx(x, y, xout = xo, rule = c(1, 2))", "result = st.approx(x, y, xout=xo, rule=[1, 2])",
   list(x = ax, y = ay, xo = xo), jl = "result = st.approx(x, y; xout = xo, rule = [1, 2])")
cs("approx_const", 'approx(x, y, xout = xo, method = "constant", f = 0.25, rule = 2)',
   'result = st.approx(x, y, xout=xo, method="constant", f=0.25, rule=2)', list(x = ax, y = ay, xo = xo), jl = "result = st.approx(x, y; xout = xo, method = \"constant\", f = 0.25, rule = 2)")
cs("approx_n", "approx(x, y, n = 11)", "result = st.approx(x, y, n=11)", list(x = ax, y = ay), jl = "result = st.approx(x, y; n = 11)")
cs("approx_unsorted_ties", "approx(x, y, xout = c(0.5, 1.5, 3))", "result = st.approx(x, y, xout=[0.5, 1.5, 3])",
   list(x = c(3, 1, 2, 1, 3), y = c(1, 2, 3, 4, 5)), jl = "result = st.approx(x, y; xout = [0.5, 1.5, 3])")
cs("approx_ties_ordered", 'approx(x, y, xout = c(1.5, 2.5), ties = "ordered")',
   'result = st.approx(x, y, xout=[1.5, 2.5], ties="ordered")', list(x = c(1, 2, 3), y = c(5, 1, 4)), jl = "result = st.approx(x, y; xout = [1.5, 2.5], ties = \"ordered\")")
cs("approx_yleft", "approx(x, y, xout = xo, yleft = -5, yright = 99)", "result = st.approx(x, y, xout=xo, yleft=-5, yright=99)",
   list(x = ax, y = ay, xo = xo), jl = "result = st.approx(x, y; xout = xo, yleft = -5, yright = 99)")
cs("approx_na", "approx(x, y, xout = c(1.5, 3.5))", "result = st.approx(x, y, xout=[1.5, 3.5])",
   list(x = c(1, 2, NA, 4), y = c(1, NA, 3, 8)), jl = "result = st.approx(x, y; xout = [1.5, 3.5])")
cs("approx_err_one", "approx(1, 2, xout = 1)", "result = st.approx([1.0], [2.0], xout=1.0)", jl = "result = st.approx([1.0], [2.0]; xout = 1.0)")
cs("approx_err_f", 'approx(x, y, method = "constant", f = 2)', 'result = st.approx(x, y, method="constant", f=2)',
   list(x = ax, y = ay), jl = "result = st.approx(x, y; method = \"constant\", f = 2)")
cs("approxfun_a", "f <- approxfun(x, y, rule = 2); f(xo)", "f = st.approxfun(x, y, rule=2)\nresult = f(xo)",
   list(x = ax, y = ay, xo = xo), jl = "f = st.approxfun(x, y; rule = 2)\nresult = f(xo)")
fx <- c(1.5, NA, 3, 2, 5, 4, 4.5, 7, 6, 8, 9.5, 9)
cs("filter_conv2", "as.vector(filter(x, rep(1/3, 3)))", "result = st.filter(x, np.full(3, 1/3))", list(x = x1), jl = "result = st.r_filter(x, fill(1/3, 3))")
cs("filter_conv1", "as.vector(filter(x, c(0.5, 0.3, 0.2), sides = 1))", "result = st.filter(x, [0.5, 0.3, 0.2], sides=1)", list(x = x1), jl = "result = st.r_filter(x, [0.5, 0.3, 0.2]; sides = 1)")
cs("filter_conv_even", "as.vector(filter(x, c(0.25, 0.25, 0.25, 0.25)))", "result = st.filter(x, [0.25]*4)", list(x = fx), jl = "result = st.r_filter(x, fill(0.25, 4))")
cs("filter_circ", "as.vector(filter(x, c(1, -2, 1), circular = TRUE))", "result = st.filter(x, [1, -2, 1], circular=True)", list(x = x1), jl = "result = st.r_filter(x, [1, -2, 1]; circular = true)")
cs("filter_rec", 'as.vector(filter(x, 0.7, method = "recursive"))', 'result = st.filter(x, 0.7, method="recursive")', list(x = x1), jl = "result = st.r_filter(x, 0.7; method = \"recursive\")")
cs("filter_rec_init", 'as.vector(filter(x, c(0.5, -0.2), method = "recursive", init = c(1, 2)))',
   'result = st.filter(x, [0.5, -0.2], method="recursive", init=[1, 2])', list(x = x1), jl = "result = st.r_filter(x, [0.5, -0.2]; method = \"recursive\", init = [1, 2])")
cs("filter_rec_na", 'as.vector(filter(x, 0.9, method = "recursive", init = 3))', 'result = st.filter(x, 0.9, method="recursive", init=3)', list(x = fx), jl = "result = st.r_filter(x, 0.9; method = \"recursive\", init = 3)")
cs("filter_mat", "unclass(filter(M, c(0.5, 0.5), sides = 1))[, ]", "result = st.filter(M, [0.5, 0.5], sides=1)", list(M = unname(M)), jl = "result = st.r_filter(M, [0.5, 0.5]; sides = 1)")
cs("filter_err_long", "filter(1:3, rep(1, 4))", "result = st.filter(np.arange(1, 4), np.ones(4))", jl = "result = st.r_filter([1, 2, 3], ones(4))")
cs("filter_err_sides", "filter(x, 1, sides = 3)", "result = st.filter(x, 1, sides=3)", list(x = x1), jl = "result = st.r_filter(x, 1; sides = 3)")
cs("filter_err_init", 'filter(x, c(1, 2), method = "recursive", init = 1)', 'result = st.filter(x, [1, 2], method="recursive", init=1)', list(x = x1), jl = "result = st.r_filter(x, [1, 2]; method = \"recursive\", init = 1)")

## ── optimize / uniroot ──────────────────────────────────────────────────
cs("optimize_a", "optimize(function(x) (x - 0.37)^2 + sin(3 * x), c(-1, 2))",
   "result = st.optimize(lambda x: (x - 0.37)*(x - 0.37) + math.sin(3*x), (-1, 2))", jl = "result = st.optimize(x -> (x - 0.37)*(x - 0.37) + SL.RLibm.sin(3*x), [-1, 2])")
cs("optimize_tol", "optimize(function(x) abs(x - 1/3) + 0.1 * x^2, lower = -5, upper = 5, tol = 1e-10)",
   "result = st.optimize(lambda x: abs(x - 1/3) + 0.1*(x*x), lower=-5, upper=5, tol=1e-10)", jl = "result = st.optimize(x -> abs(x - 1/3) + 0.1*(x*x); lower = -5, upper = 5, tol = 1e-10)")
cs("optimize_max", "optimize(function(x) x * exp(-x), c(0, 4), maximum = TRUE)",
   "result = st.optimize(lambda x: x*math.exp(-x), (0, 4), maximum=True)", jl = "result = st.optimize(x -> x*SL.RLibm.exp(-x), [0, 4]; maximum = true)")
cs("optimize_na", "optimize(function(x) if (x < 0.5) NA else (x - 1)^2, c(0, 3))",
   "result = st.optimize(lambda x: float('nan') if x < 0.5 else (x - 1)*(x - 1), (0, 3))", jl = "result = st.optimize(x -> x < 0.5 ? SL.NA : (x - 1)*(x - 1), [0, 3])")
cs("optimize_err", "optimize(function(x) x^2, c(1, 1))", "result = st.optimize(lambda x: x*x, (1, 1))", jl = "result = st.optimize(x -> x*x, [1, 1])")
cs("uniroot_a", "uniroot(function(x) x^3 - x - 1, c(1, 2))",
   "result = st.uniroot(lambda x: math.pow(x, 3) - x - 1, (1, 2))", jl = "result = st.uniroot(x -> SL.RLibm.pow(x, 3) - x - 1, [1, 2])")
cs("uniroot_tol", "uniroot(function(x) cos(x) - x, c(-pi, pi), tol = 1e-12)",
   "result = st.uniroot(lambda x: math.cos(x) - x, (-math.pi, math.pi), tol=1e-12)", jl = "result = st.uniroot(x -> SL.RLibm.cos(x) - x, [-pi, pi]; tol = 1e-12)")
cs("uniroot_fl", "uniroot(function(x) exp(x) - 3, lower = 0, upper = 2, f.lower = -2, f.upper = exp(2) - 3)",
   "result = st.uniroot(lambda x: math.exp(x) - 3, lower=0, upper=2, f_lower=-2, f_upper=math.exp(2) - 3)", jl = "result = st.uniroot(x -> SL.RLibm.exp(x) - 3; lower = 0, upper = 2, f_lower = -2, f_upper = SL.RLibm.exp(2.0) - 3)")
cs("uniroot_ext_yes", 'uniroot(function(x) exp(x) - 50, c(0, 1), extendInt = "yes")',
   'result = st.uniroot(lambda x: math.exp(x) - 50, (0, 1), extendInt="yes")', jl = "result = st.uniroot(x -> SL.RLibm.exp(x) - 50, [0, 1]; extendInt = \"yes\")")
cs("uniroot_ext_up", 'uniroot(function(x) x - 10.5, c(0, 1), extendInt = "upX")',
   'result = st.uniroot(lambda x: x - 10.5, (0, 1), extendInt="upX")', jl = "result = st.uniroot(x -> x - 10.5, [0, 1]; extendInt = \"upX\")")
cs("uniroot_ext_down", 'uniroot(function(x) 3 - x, c(5, 6), extendInt = "downX")',
   'result = st.uniroot(lambda x: 3 - x, (5, 6), extendInt="downX")', jl = "result = st.uniroot(x -> 3 - x, [5, 6]; extendInt = \"downX\")")
cs("uniroot_maxit", "uniroot(function(x) x^3 - x - 1, c(1, 2), maxiter = 3)",
   "result = st.uniroot(lambda x: math.pow(x, 3) - x - 1, (1, 2), maxiter=3)", jl = "result = st.uniroot(x -> SL.RLibm.pow(x, 3) - x - 1, [1, 2]; maxiter = 3)")
cs("uniroot_endroot", "uniroot(function(x) x - 1, c(1, 2))", "result = st.uniroot(lambda x: x - 1, (1, 2))", jl = "result = st.uniroot(x -> x - 1, [1, 2])")
cs("uniroot_err_sign", "uniroot(function(x) x^2 + 1, c(-1, 2))", "result = st.uniroot(lambda x: x*x + 1, (-1, 2))", jl = "result = st.uniroot(x -> x*x + 1, [-1, 2])")
cs("uniroot_err_lu", "uniroot(function(x) x, lower = 2, upper = 1)", "result = st.uniroot(lambda x: x, lower=2, upper=1)", jl = "result = st.uniroot(x -> x; lower = 2, upper = 1)")
cs("uniroot_inf", "uniroot(function(x) if (x > 1.9) Inf else x - 1, c(0, 2))",
   "result = st.uniroot(lambda x: math.inf if x > 1.9 else x - 1, (0, 2))", jl = "result = st.uniroot(x -> x > 1.9 ? Inf : x - 1, [0, 2])")

## ── dist / hclust ────────────────────────────────────────────────────────
D5 <- matrix(rnorm(40), 8, 5); D5r <- round(D5); D5na <- D5; D5na[2, 3] <- NA
for (m in c("euclidean", "maximum", "manhattan", "canberra", "binary", "minkowski")) {
  cs(paste0("dist_", m), sprintf("as.vector(dist(X, method = '%s', p = 3))", m),
     sprintf("result = np.asarray(st.dist(X, method='%s', p=3))", m), list(X = D5r),
     jl = sprintf("result = st.dist(X; method = \"%s\", p = 3)", m))
  cs(paste0("dist_na_", m), sprintf("as.vector(dist(X, method = '%s'))", m),
     sprintf("result = np.asarray(st.dist(X, method='%s'))", m), list(X = D5na),
     jl = sprintf("result = st.dist(X; method = \"%s\")", m))
}
cs("dist_matrix", "as.matrix(dist(X))", "result = st.dist_as_matrix(st.dist(X))", list(X = D5), jl = "result = st.dist_as_matrix(st.dist(X))")
cs("dist_labels", "as.matrix(dist(X))", "result = st.dist_as_matrix(st.dist(X))",
   list(X = `rownames<-`(D5, letters[1:8])), jl = "result = st.dist_as_matrix(st.dist(X))")
for (m in c("ward.D", "single", "complete", "average", "mcquitty", "median", "centroid", "ward.D2")) {
  cs(paste0("hclust_", m), sprintf("h <- hclust(dist(X), method = '%s'); h[c('merge', 'height', 'order', 'labels', 'method', 'dist.method')]", m),
     sprintf("result = st.hclust(st.dist(X), method='%s')", m), list(X = D5),
     jl = sprintf("result = st.hclust(st.dist(X), \"%s\")", m))
  cs(paste0("hclust_ties_", m), sprintf("h <- hclust(dist(X), method = '%s'); h[c('merge', 'height', 'order')]", m),
     sprintf("result = st.hclust(st.dist(X), method='%s')", m), list(X = D5r),
     jl = sprintf("result = st.hclust(st.dist(X), \"%s\")", m))
}
Cm <- cor(matrix(rnorm(300), 50, 6))
cs("hclust_asdist", "h <- hclust(as.dist(sqrt((1 - C) / 2)), method = 'single'); h[c('merge', 'height', 'order', 'labels')]",
   "result = st.hclust(st.as_dist(np.sqrt((1 - C) / 2)), method='single')", list(C = `dimnames<-`(Cm, list(LETTERS[1:6], LETTERS[1:6]))), jl = "D = NamedMat(sqrt.((1 .- C.data) ./ 2); rownames = C.rownames, colnames = C.colnames)\nresult = st.hclust(st.as_dist(D), \"single\")")
cs("hclust_members", "h <- hclust(dist(X), 'average', members = c(1, 2, 1, 3, 1, 1, 2, 1)); h[c('merge', 'height', 'order')]",
   "result = st.hclust(st.dist(X), 'average', members=[1, 2, 1, 3, 1, 1, 2, 1])", list(X = D5), jl = "result = st.hclust(st.dist(X), \"average\"; members = [1, 2, 1, 3, 1, 1, 2, 1])")
cs("hclust_n2", "h <- hclust(dist(X)); h[c('merge', 'height', 'order')]", "result = st.hclust(st.dist(X))", list(X = D5[1:2, ]), jl = "result = st.hclust(st.dist(X))")
cs("hclust_err_n1", "hclust(dist(X))", "result = st.hclust(st.dist(X))", list(X = D5[1, , drop = FALSE]), jl = "result = st.hclust(st.dist(X))")

## ── p.adjust ─────────────────────────────────────────────────────────────
pv <- c(0.01, 0.04, 0.03, 0.005, 0.2, 0.5, 0.04, NA, 0.9, 0.0001)
for (m in c("holm", "hochberg", "hommel", "bonferroni", "BH", "BY", "fdr", "none")) {
  cs(paste0("padj_", m), sprintf("p.adjust(p, '%s')", m), sprintf("result = st.p_adjust(p, '%s')", m), list(p = pv),
     jl = sprintf("result = st.p_adjust(p, \"%s\")", m))
  cs(paste0("padj_n_", m), sprintf("p.adjust(p, '%s', n = 25)", m), sprintf("result = st.p_adjust(p, '%s', n=25)", m),
     list(p = pv[!is.na(pv)]), jl = sprintf("result = st.p_adjust(p, \"%s\"; n = 25)", m))
}
cs("padj_named", "p.adjust(p, 'BH')", "result = st.p_adjust(p, 'BH')", list(p = c(a = 0.01, b = 0.2, c = 0.03)), jl = "result = st.p_adjust(p, \"BH\")")
cs("padj_hommel2", "p.adjust(c(0.02, 0.03), 'hommel')", "result = st.p_adjust([0.02, 0.03], 'hommel')", jl = "result = st.p_adjust([0.02, 0.03], \"hommel\")")

## ── rank / order / sort / rle / cut / findInterval / tabulate ────────────
rv <- c(3, 1, 4, 1, 5, 9, 2, 6, 5, 3, 5, NA, 8, 9, 7, 9)
for (tm in c("average", "first", "last", "min", "max"))
  cs(paste0("rank_", tm), sprintf("rank(x, ties.method = '%s')", tm), sprintf("result = st.rank(x, ties_method='%s')", tm), list(x = rv),
     jl = sprintf("result = st.r_rank(x; ties_method = \"%s\")", tm))
cs("rank_keep", "rank(x, na.last = 'keep')", "result = st.rank(x, na_last='keep')", list(x = rv), jl = "result = st.r_rank(x; na_last = \"keep\")")
cs("rank_nalastF", "rank(x, na.last = FALSE)", "result = st.rank(x, na_last=False)", list(x = rv), jl = "result = st.r_rank(x; na_last = false)")
cs("rank_naNA", "rank(x, na.last = NA)", "result = st.rank(x, na_last=None)", list(x = rv), jl = "result = st.r_rank(x; na_last = nothing)")
cs("rank_named", "rank(x)", "result = st.rank(x)", list(x = c(b = 2, a = 1, c = 2)), jl = "result = st.r_rank(x)")
cs("order_a", "order(x)", "result = st.order(x)", list(x = rv), jl = "result = st.order(x)")
cs("order_dec", "order(x, decreasing = TRUE)", "result = st.order(x, decreasing=True)", list(x = rv), jl = "result = st.order(x; decreasing = true)")
cs("order_nalast", "order(x, na.last = FALSE)", "result = st.order(x, na_last=False)", list(x = rv), jl = "result = st.order(x; na_last = false)")
cs("order_naNA", "order(x, na.last = NA)", "result = st.order(x, na_last=None)", list(x = rv), jl = "result = st.order(x; na_last = nothing)")
cs("order_two", "order(round(x / 3), -y)", "result = st.order(np.round(x / 3), -y)", list(x = rv[-12], y = 1:15), jl = "result = st.order(round.(x ./ 3), -y)")
cs("order_chr", "order(s)", "result = st.order(s)", list(s = c("b", "a", "ab", "aa", "a", "c")), jl = "result = st.order(s)")
cs("sort_a", "sort(x)", "result = st.sort(x)", list(x = rv), jl = "result = st.r_sort(x)")
cs("sort_dec", "sort(x, decreasing = TRUE)", "result = st.sort(x, decreasing=True)", list(x = rv), jl = "result = st.r_sort(x; decreasing = true)")
cs("sort_named", "sort(x)", "result = st.sort(x)", list(x = c(b = 2, a = 1, c = 0.5)), jl = "result = st.r_sort(x)")
## Zeichenketten: Kollation wie R (ICU "root" unter LC_ALL=C.UTF-8)
chs <- c("b", "A", "a", "B", "ä", "Ä", "Zebra", "zebra", "10", "2", "1", " a", "a b", "a-b", "a_b", "a.b",
         "a,b", "ß", "ss", "é", "e", "E", "x10", "x2", "Ö", "o", "Ü", "u", NA, "", "!", "St", "st", "b", "a")
chd <- c("b", "A", "a", "B", "a", "ä", "B", NA, "a", "Ab", "aB")
cs("chr_sort", "sort(s)", "result = st.sort(s)", list(s = chs), jl = "result = st.r_sort(s)")
cs("chr_sort_dec", "sort(s, decreasing = TRUE)", "result = st.sort(s, decreasing=True)", list(s = chs), jl = "result = st.r_sort(s; decreasing = true)")
cs("chr_sort_nalast", "sort(s, na.last = TRUE)", "result = st.sort(s, na_last=True)", list(s = chs), jl = "result = st.r_sort(s; na_last = true)")
cs("chr_sort_nafirst", "sort(s, decreasing = TRUE, na.last = FALSE)", "result = st.sort(s, decreasing=True, na_last=False)", list(s = chd), jl = "result = st.r_sort(s; decreasing = true, na_last = false)")
cs("chr_sort_named", "sort(s)", "result = st.sort(s)", list(s = c(x = "b", y = "A", z = "a", w = "B", v = "ä")), jl = "result = st.r_sort(s)")
cs("chr_sort_unique", "sort(unique(s))", "result = st.sort(pd.unique(np.asarray(s, dtype=object)))", list(s = chd), jl = "result = st.r_sort(unique(s))")
cs("chr_order", "order(s)", "result = st.order(s)", list(s = chs), jl = "result = st.order(s)")
cs("chr_order_dec", "order(s, decreasing = TRUE)", "result = st.order(s, decreasing=True)", list(s = chs), jl = "result = st.order(s; decreasing = true)")
cs("chr_order_nalastF", "order(s, na.last = FALSE)", "result = st.order(s, na_last=False)", list(s = chs), jl = "result = st.order(s; na_last = false)")
cs("chr_order_naNA", "order(s, na.last = NA)", "result = st.order(s, na_last=None)", list(s = chs), jl = "result = st.order(s; na_last = nothing)")
cs("chr_order_two", "order(s, x)", "result = st.order(s, x)", list(s = chd, x = c(3, 1, 2, 2, 1, 5, 1, 4, 0, 2, 2)), jl = "result = st.order(s, x)")
cs("chr_order_two_dec", "order(x, s, decreasing = TRUE)", "result = st.order(x, s, decreasing=True)", list(s = chd, x = c(3, 1, 2, 2, 1, 5, 1, 4, 0, 2, 2)), jl = "result = st.order(x, s; decreasing = true)")
for (tm in c("average", "min", "max", "first", "last"))
  cs(paste0("chr_rank_", tm), sprintf("rank(s, ties.method = '%s')", tm), sprintf("result = st.rank(s, ties_method='%s')", tm), list(s = chd),
     jl = sprintf("result = st.r_rank(s; ties_method = \"%s\")", tm))
cs("chr_rank_keep", "rank(s, na.last = 'keep')", "result = st.rank(s, na_last='keep')", list(s = chs), jl = "result = st.r_rank(s; na_last = \"keep\")")
cs("chr_factor_levels", "f <- factor(s); list(levels(f), as.integer(f))",
   "import simlev._r.fmt as fm\nlv = list(st.sort(pd.unique(np.asarray([v for v in s if v is not None], dtype=object))))\npos = {v: i + 1 for i, v in enumerate(lv)}\nresult = [lv, np.array([fm.NA_REAL if v is None else pos[v] for v in s])]",
   list(s = chs), jl = "f = SL.RFmt.r_factor(s)\nresult = [f.levels, [c == 0 ? missing : c for c in f.codes]]")
cs("chr_factor_print", "f <- factor(s); paste(capture.output(print(f)), collapse = '\\n')", "import simlev._r.fmt as fm\nresult = fm.print_factor(s)",
   list(s = chd), jl = "result = SL.RFmt.print_factor(s)")
cs("chr_table", "t <- table(s); list(names(t), as.vector(t))",
   "a = st.aggregate(np.ones(len([v for v in s if v is not None])), {'g': [v for v in s if v is not None]}, len)\nresult = [list(a['g']), a['x'].to_numpy(dtype=np.int64)]",
   list(s = chd), jl = "ss = [v for v in s if v !== missing]\na = st.aggregate(ones(length(ss)), [\"g\" => ss], length)\nresult = [a[\"g\"], Int.(a[\"x\"])]")
cs("chr_aggregate", "aggregate(x, list(g = s, h = t), sum)", "result = st.aggregate(x, {'g': s, 'h': t}, st._rsum)",
   list(x = c(1, 2, 3, 4, 5, 6, 7, 8), s = c("b", "A", "a", "B", "a", "ä", "B", "b"), t = c("y", "Y", "y", "Y", "Y", "y", "Y", "y")),
   jl = "result = st.aggregate(x, [\"g\" => s, \"h\" => t], v -> SL.r_sum(v))")
cs("chr_ave_order", "o <- character(0); r <- ave(x, s, FUN = function(v) { o <<- c(o, paste(v, collapse = ',')); v * 0 + length(o) }); list(r, o)",
   "o = []\ndef f(v):\n    o.append(','.join('%d' % t for t in v))\n    return v * 0 + len(o)\nr = st.ave(x, s, FUN=f)\nresult = [r, o]",
   list(x = c(1, 2, 3, 4, 5, 6), s = c("b", "A", "a", "B", "ä", "a")),
   jl = "o = String[]\nf(v) = (push!(o, join([string(Int(t)) for t in v], \",\")); v .* 0 .+ length(o))\nr = st.ave(x, s; FUN = f)\nresult = [r, o]")
chp <- c("a", "A", "b", "B", "ä", "Ä", "a b", "ab", "a-b", "10", "2", "", " ", "ß", "ss", "St", "st", "x10", "x2", "é", "e")
cs("chr_collate_pairs", "outer(s, s, function(a, b) ifelse(a < b, -1L, ifelse(a > b, 1L, 0L)))",
   "result = np.array([[st.str_collate(a, b) for b in s] for a in s], dtype=np.int64)",
   list(s = chp), jl = "result = [st.str_collate(a, b) for a in s, b in s]")
cs("chr_lt", "c(s < 'b', s > 'B', s <= 'a', s >= 'ä')",
   "result = np.array([st.str_collate(v, 'b') < 0 for v in s] + [st.str_collate(v, 'B') > 0 for v in s] + [st.str_collate(v, 'a') <= 0 for v in s] + [st.str_collate(v, 'ä') >= 0 for v in s])",
   list(s = chp), jl = "result = vcat([st.str_collate(v, \"b\") < 0 for v in s], [st.str_collate(v, \"B\") > 0 for v in s], [st.str_collate(v, \"a\") <= 0 for v in s], [st.str_collate(v, \"ä\") >= 0 for v in s])")
cs("rle_a", "unclass(rle(x))", "result = st.rle(x)", list(x = c(1, 1, 2, 2, 2, 3, 1, 1)), jl = "result = st.rle(x)")
cs("rle_lgl", "unclass(rle(x))", "result = st.rle(x)", list(x = c(TRUE, TRUE, FALSE, TRUE)), jl = "result = st.rle(x)")
cs("tabulate_a", "tabulate(x)", "result = st.tabulate(x)", list(x = c(2, 3, 3, 5, NA, 0)), jl = "result = st.tabulate(x)")
cs("tabulate_nb", "tabulate(x, nbins = 3)", "result = st.tabulate(x, nbins=3)", list(x = c(2, 3, 3, 5)), jl = "result = st.tabulate(x; nbins = 3)")
fv <- c(1, 2, 2, 3.5, 7); fq <- c(-1, 1, 2, 2.5, 3.5, 7, 8, NA)
cs("findint_a", "findInterval(x, v)", "result = st.findInterval(x, v)", list(x = fq, v = fv), jl = "result = st.findInterval(x, v)")
cs("findint_rc", "findInterval(x, v, rightmost.closed = TRUE)", "result = st.findInterval(x, v, rightmost_closed=True)", list(x = fq, v = fv), jl = "result = st.findInterval(x, v; rightmost_closed = true)")
cs("findint_ai", "findInterval(x, v, all.inside = TRUE)", "result = st.findInterval(x, v, all_inside=True)", list(x = fq, v = fv), jl = "result = st.findInterval(x, v; all_inside = true)")
cs("findint_lo", "findInterval(x, v, left.open = TRUE)", "result = st.findInterval(x, v, left_open=True)", list(x = fq, v = fv), jl = "result = st.findInterval(x, v; left_open = true)")
cs("findint_err", "findInterval(1, c(2, 1))", "result = st.findInterval(1, [2, 1])", jl = "result = st.findInterval(1, [2, 1])")
cs("cut_codes", "cut(x, 4, labels = FALSE)", "result = st.cut(x, 4, labels=False)", list(x = x1), jl = "result = st.cut(x, 4; labels = false)")
cs("cut_seq", "cut(seq_len(23), 5, labels = FALSE)", "result = st.cut(np.arange(1, 24), 5, labels=False)", jl = "result = st.cut(1:23, 5; labels = false)")
cs("cut_labels", "as.character(cut(x, c(-3, -1, 0, 1, 3)))", "result = np.asarray(st.cut(x, [-3, -1, 0, 1, 3]), dtype=object)", list(x = x1), jl = "result = collect(st.cut(x, [-3, -1, 0, 1, 3]))")
cs("cut_incl", "as.character(cut(x, c(-1, 0, 2, 5), include.lowest = TRUE, right = FALSE))",
   "result = np.asarray(st.cut(x, [-1, 0, 2, 5], include_lowest=True, right=False), dtype=object)", list(x = c(-1, 0, 1.5, 5, 6)), jl = "result = collect(st.cut(x, [-1, 0, 2, 5]; include_lowest = true, right = false))")
cs("cut_userlab", "as.character(cut(x, c(-5, 0, 5), labels = c('neg', 'pos'), right = FALSE))",
   "result = np.asarray(st.cut(x, [-5, 0, 5], labels=['neg', 'pos'], right=False), dtype=object)", list(x = x1), jl = "result = collect(st.cut(x, [-5, 0, 5]; labels = [\"neg\", \"pos\"], right = false))")
cs("cut_err_breaks", "cut(1:3, c(1, 1, 2))", "result = st.cut(np.arange(1, 4), [1, 1, 2])", jl = "result = st.cut(1:3, [1, 1, 2])")

## ── complete.cases / ecdf / ave / aggregate ─────────────────────────────
cs("cc_df", "complete.cases(d)", "result = st.complete_cases(d)",
   list(d = data.frame(a = c(1, NA, 3, 4), b = c("x", "y", NA, "z"), stringsAsFactors = FALSE)), jl = "result = st.complete_cases(d)")
cs("cc_mat_vec", "complete.cases(M, v)", "result = st.complete_cases(M, v)", list(M = unname(Mna), v = c(NA, rep(1, 19))), jl = "result = st.complete_cases(M, v)")
cs("ecdf_a", "F <- ecdf(x); F(c(-5, x[1:5], 0, 5))", "F = st.ecdf(x)\nresult = F(np.concatenate([[-5], x[:5], [0, 5]]))", list(x = x2), jl = "F = st.ecdf(x)\nresult = F(vcat(-5, x[1:5], 0, 5))")
cs("ave_mean", "ave(x, g)", "result = st.ave(x, g)", list(x = x1, g = rep(1:4, length.out = 37)), jl = "result = st.ave(x, g)")
cs("ave_sum2", "ave(x, g, h, FUN = sum)", "result = st.ave(x, g, h, FUN=lambda v: st._rsum(v))",
   list(x = x1, g = rep(1:3, length.out = 37), h = rep(c(0, 1), each = 19)[1:37]), jl = "result = st.ave(x, g, h; FUN = v -> SL.r_sum(v))")
cs("ave_nog", "ave(x)", "result = st.ave(x)", list(x = x1), jl = "result = st.ave(x)")
cs("aggregate_1", "aggregate(x, list(p = g), mean)", "result = st.aggregate(x, {'p': g}, st._rmean)", list(x = x1, g = rep(c(3, 1, 2), length.out = 37)), jl = "result = st.aggregate(x, [\"p\" => g], v -> SL.RStats._rmean(v))")
cs("aggregate_2", "aggregate(x, list(p1 = g, p2 = h), median)", "result = st.aggregate(x, {'p1': g, 'p2': h}, st.median)",
   list(x = x1, g = rep(1:3, length.out = 37), h = rep(c(0.5, 0.1), length.out = 37)), jl = "result = st.aggregate(x, [\"p1\" => g, \"p2\" => h], st.median)")

## ── base: colSums & Co. ─────────────────────────────────────────────────
cs("base_colSums", "colSums(M)", "result = rb.colSums(M)", list(M = M), jl = "result = rb.colSums(M)")
cs("base_colSums_na", "colSums(M, na.rm = TRUE)", "result = rb.colSums(M, na_rm=True)", list(M = Mna), jl = "result = rb.colSums(M; na_rm = true)")
cs("base_colMeans", "colMeans(M)", "result = rb.colMeans(M)", list(M = Mna), jl = "result = rb.colMeans(M)")
cs("base_colMeans_na", "colMeans(M, na.rm = TRUE)", "result = rb.colMeans(M, na_rm=True)", list(M = Mna), jl = "result = rb.colMeans(M; na_rm = true)")
cs("base_rowSums", "rowSums(M)", "result = rb.rowSums(M)", list(M = Mna), jl = "result = rb.rowSums(M)")
cs("base_rowSums_na", "rowSums(M, na.rm = TRUE)", "result = rb.rowSums(M, na_rm=True)", list(M = Mna), jl = "result = rb.rowSums(M; na_rm = true)")
cs("base_rowMeans", "rowMeans(M)", "result = rb.rowMeans(M)", list(M = M), jl = "result = rb.rowMeans(M)")
cs("base_rowMeans_na", "rowMeans(M, na.rm = TRUE)", "result = rb.rowMeans(M, na_rm=True)", list(M = Mna), jl = "result = rb.rowMeans(M; na_rm = true)")
cs("base_rowMeans_df", "rowMeans(d)", "result = rb.rowMeans(d)", list(d = as.data.frame(M)), jl = "result = rb.rowMeans(d)")
cs("base_cumprod", "cumprod(1 + x / 100)", "result = rb.cumprod(1 + x / 100)", list(x = x1), jl = "result = rb.r_cumprod(1 .+ x ./ 100)")
cs("base_cumprod_na", "cumprod(x)", "result = rb.cumprod(x)", list(x = c(1.1, 2, NA, 3)), jl = "result = rb.r_cumprod(x)")
cs("base_cummax", "cummax(x)", "result = rb.cummax(x)", list(x = xna), jl = "result = rb.r_cummax(x)")
cs("base_cummin", "cummin(x)", "result = rb.cummin(x)", list(x = x1), jl = "result = rb.r_cummin(x)")
cs("base_mean_mat", "mean(M)", "result = rb.mean(M)", list(M = M), jl = "result = rb.mean(M)")
cs("base_diff", "diff(x)", "result = rb.diff(x)", list(x = x1), jl = "result = rb.r_diff(x)")
cs("base_diff_lag", "diff(x, lag = 2, differences = 2)", "result = rb.diff(x, lag=2, differences=2)", list(x = x1), jl = "result = rb.r_diff(x; lag = 2, differences = 2)")
cs("base_diff_mat", "diff(M)", "result = rb.diff(M)", list(M = unname(M)), jl = "result = rb.r_diff(M)")
cs("base_pmax", "pmax(x, 0.2)", "result = rb.pmax(x, 0.2)", list(x = xna), jl = "result = rb.pmax(x, 0.2)")
cs("base_pmin_narm", "pmin(x, rev(x), na.rm = TRUE)", "result = rb.pmin(x, x[::-1], na_rm=True)", list(x = xna), jl = "result = rb.pmin(x, reverse(x); na_rm = true)")
cs("base_range", "range(x)", "result = rb.range(x)", list(x = x1), jl = "result = rb.r_range(x)")
cs("base_range_na", "range(x, na.rm = TRUE)", "result = rb.range(x, na_rm=True)", list(x = xna), jl = "result = rb.r_range(x; na_rm = true)")

ref_done()

# ════════════════════════════════════════════════════════════════════════════════════════════════════
# Modul rexpr
# ════════════════════════════════════════════════════════════════════════════════════════════════════
# Referenzfälle für den gemeinsamen Auswerter von Ausdrücken in R-Syntax
# (Python simlev._r.rexpr, Julia SimLev.RExpr): Bedingungen als Text in
# tactical_rules(), bootstrap_probability(), regime_subset() und view_prob().
# Jeder Fall wertet einen Text wie R aus:
#   R       eval(parse(text = rx_txt), envir = list2env(rx_dat))
#   Python  simlev._r.rexpr.eval_r(rx_txt, rx_dat)
#   Julia   SL.RExpr.eval_r(rx_txt, rx_dat)
# Aufruf aus der Repo-Wurzel:
ref_init("rexpr")

local({
  R <- "eval(parse(text = rx_txt), envir = list2env(rx_dat))"
  P <- "from simlev._r import rexpr\nresult = rexpr.eval_r(rx_txt, rx_dat)"
  J <- "result = SL.RExpr.eval_r(rx_txt, rx_dat)"
  # Daten: NA in Zahlen nur als NA (Python unterscheidet NA und NaN in Eingaben nicht)
  D <- list(x = c(10, 20, NA, 40, -5, 0), y = c(1.5, -2, 3), i = c(3L, 0L, 1L, -2L), j = c(1L, NA, 4L),
            l = c(TRUE, NA, FALSE), s = c("b", "a", NA, "B", "a10", "a9", "\u00c4", "z", ""),
            big = 2147483647L, dt = as.Date(c("2020-01-01", NA, "2021-06-30")), n0 = numeric(0),
            thr = 15, k = 2L, nm = "a")
  grp <- function(prefix, exprs, d = D) {
    for (k in seq_along(exprs))
      ref_case(sprintf("%s_%03d", prefix, k), R, P, jl = J, inputs = list(rx_txt = exprs[[k]], rx_dat = d))
  }

  # ── Vorrang ──────────────────────────────────────────────────────────────
  grp("prec", c("-2^2", "-1:3", "2^-1", "2^3^2", "-2:2 * 2", "1:3^2", "5 %% 3 ^ 2", "-5 %/% 2",
                "5 %in% 1:5 + 1", "!TRUE & FALSE", "!x > 15", "!x + 1 > 15", "1 + 2 * 3 - 4 / 2", "2 * 3 %% 4",
                "(1 + 2) * 3", "TRUE | FALSE & FALSE", "FALSE & TRUE | TRUE", "1 < 2 & 2 < 3", "!!TRUE", "- -3",
                "+-3", "-(1:3)", "2^1:3", "1:3 + 1", "1:2:3", "x > 15 | x < 0", "x[2] ^ 2", "-x[1]", "!l",
                "l & !l", "1 == 1 & 2 != 3", "thr * 2 > x", "!x", "-i", "-l", "+l", "2 - -2", "2^-1^2",
                "-2^-2", "!x == 10", "x == !l", "1:3 * 2:4", "10 - 2 - 3", "2^2^3", "100 / 10 / 2",
                "7 %/% 2 %% 2", "!1 + 1", "-1^0.5", "(-1)^0.5", "1:3 %in% 2:5", "-i %% 3L"))

  # ── NA-Logik ─────────────────────────────────────────────────────────────
  grp("na", c("NA & FALSE", "NA & TRUE", "NA | TRUE", "NA | FALSE", "!NA", "NA > 1", "NA == NA", "NA + 1",
              "NA_integer_ + 1L", "NA_real_ * 0", "NaN + 1", "NA^0", "1^NA", "NA_integer_^0L", "1L^NA_integer_",
              "NaN == NaN", "NA & NaN", "x > 15 & l", "l | NA", "is.na(x)", "is.na(NA_character_)",
              "is.nan(c(1, NA, NaN))", "is.na(c(1, NA, NaN))", "NA && FALSE", "FALSE && NA", "NA || TRUE",
              "TRUE || NA", "NA && TRUE", "xor(TRUE, NA)", "any(l)", "all(l)", "any(l, na.rm = TRUE)",
              "all(c(TRUE, NA), na.rm = TRUE)", "sum(l)", "sum(l, na.rm = TRUE)", "mean(l, na.rm = TRUE)",
              "max(x)", "max(x, na.rm = TRUE)", "min(c(NaN, NA))", "min(c(NA, NaN))", "max(NaN, 1)",
              "NA_character_ == \"a\"", "ifelse(l, 1, 0)", "ifelse(x > 15, \"hoch\", \"tief\")", "isTRUE(NA)",
              "isFALSE(FALSE)", "NA %in% c(1, NA)", "NaN %in% c(NA, NaN)", "NA %in% NaN", "NA_real_ %in% NA",
              "x %in% c(10, NA)", "NA * NaN", "NaN * NA", "NA_real_ + NaN", "NaN - NA_real_", "c(NA, NaN) > 0",
              "!is.na(x) & x > 15", "is.na(x) | x > 15", "NA^1", "NA_integer_ * 0L", "sum(NA, NaN)",
              "sum(NaN, NA)", "max(NA, NaN, na.rm = TRUE)", "mean(c(NA, NaN))", "mean(c(NaN, NA))"))

  # ── %in% ─────────────────────────────────────────────────────────────────
  grp("in", c("5 %in% 1:5", "\"a\" %in% s", "s %in% c(\"a\", \"b\")", "1 %in% \"1\"", "TRUE %in% 1", "0 %in% -0",
              "c(1.5, 2) %in% y", "i %in% c(1, 3)", "dt %in% as.Date(\"2020-01-01\")", "NULL %in% 1", "1 %in% NULL",
              "x %in% x", "NA_character_ %in% s", "\"\" %in% s", "1L %in% c(1, 2)", "s[1:3] %in% NA"))

  # ── %% und %/% ───────────────────────────────────────────────────────────
  grp("mod", c("7 %% 3", "-7 %% 3", "7 %% -3", "-7 %% -3", "7.5 %% 2", "5 %% 0", "-5 %% 0", "0 %% 0", "5 %/% 0",
               "-5 %/% 0", "0 %/% 0", "7 %/% 3", "-7 %/% 3", "7L %% 3L", "-7L %% 3L", "7L %% -3L", "7L %/% 0L",
               "7L %% 0L", "-7L %/% 2L", "5.5 %/% 1.1", "1 %% 0.1", "1e20 %% 3", "x %% 3", "i %% 2L", "i %/% 2L",
               "NA %% 2", "2 %% NA", "NA_integer_ %/% 2L", "Inf %% 3", "3 %% Inf", "-3 %% Inf", "TRUE %% 2L",
               "1e17 %% 3", "0.3 %% 0.1", "-0.5 %/% 0.25", "2.5 %/% -1", "x %/% 7", "y %% 1", "1e300 %/% 1e-10"))

  # ── ^ ───────────────────────────────────────────────────────────────────
  grp("pow", c("2^10", "2^0.5", "(-8)^(1/3)", "0^0", "0^-1", "NA^0", "Inf^0", "(-2)^2", "(-2)^3", "(-Inf)^3",
               "(-Inf)^2", "2^Inf", "0.5^Inf", "(-1)^Inf", "1^Inf", "x^2", "i^2L", "2L^31L", "y^y", "10^-2",
               "2**3", "NaN^0", "1^NaN", "1.1^1000", "x^0.5", "(-0)^-1", "0^-0.5"))

  # ── Ganzzahlen ──────────────────────────────────────────────────────────
  grp("int", c("1L + 2L", "big + 1L", "big + 1", "-big - 1L", "-big - 2L", "big * 2L", "46341L * 46341L",
               "46340L * 46340L", "big - (-1L)", "1L / 2L", "5L / 0L", "-5L / 0L", "0L / 0L", "TRUE + TRUE",
               "TRUE * 3L", "sum(c(big, 1L))", "sum(big, 1L)", "sum(i)", "sum(1:100)", "cumsum(c(big, 1L))",
               "cumsum(i)", "abs(-3L)", "abs(i)", "big:(big - 2L)", "1:3 + 0.5", "1:3 * 2L", "length(x) * 2L",
               "nchar(s) + 1L", "as.integer(3.9)", "as.integer(-3.9)", "as.integer(3e9)", "as.integer(\"12\")",
               "as.integer(c(\"1\", \"3e9\", \"x\"))", "as.integer(TRUE)", "1e5L", "0x10L", "1.5L", "1.L",
               "100000000000L", "1e-3L", "i * big", "c(big, 1L) + c(1L, NA)", "max(i)", "min(i, 10L)",
               "max(i, 2.5)", "-big", "big - big", "k * k * k", "i - big", "sum(big, big, -big)",
               "cumsum(c(TRUE, TRUE, NA))", "2147483647:2147483649", "-2147483647:-2147483649", "1.5:4",
               "3:1", "k:5", "0L - big - 1L", "abs(-big)", "i %/% 0L", "big %/% 2L", "-big %% 7L"))

  # ── Indizierung ─────────────────────────────────────────────────────────
  grp("idx", c("x[2]", "x[-1]", "x[c(1, 2)]", "x[c(-1, -2)]", "x[0]", "x[c(0, 1)]", "x[c(-1, 0)]", "x[7]",
               "x[-7]", "x[c(1, -1)]", "x[NA]", "x[c(1, NA)]", "x[NA_integer_]", "x[TRUE]", "x[c(TRUE, FALSE)]",
               "x[c(TRUE, NA)]", "x[rep(TRUE, 8)]", "x[x > 15]", "x[!is.na(x)]", "x[1.9]", "x[-1.9]", "x[0.5]",
               "x[-0.5]", "x[]", "x[\"a\"]", "s[2]", "s[c(TRUE, NA)]", "l[5]", "i[-2]", "i[i > 0]", "x[[2]]",
               "x[[7]]", "x[[NA]]", "x[[-1]]", "x[[c(1, 2)]]", "x[[0]]", "y[[-1]]", "c(5, 6)[[-1]]",
               "c(5, 6)[[-2]]", "c(5, 6)[[-3]]", "(1:2)[[-1L]]", "(1:3)[[-1L]]", "x[2][1]", "x[c(1, 1, 2)]",
               "x[c(-1, NA)]", "x[Inf]", "x[-Inf]", "x[NaN]", "x[1e10]", "x[1, 2]", "x[i]", "x[j]", "(1:5)[2:3]",
               "c(1, 2)[2]", "x[s]", "x[l]", "x[NULL]", "x[integer(0)]", "x[c(TRUE, FALSE)][2]",
               "s[nchar(s) > 1]", "dt[2]", "dt[-1]", "x[length(x)]", "x[x > thr & !is.na(x)]", "x[[1]] > 5",
               "LETTERS[c(-1:-24)]", "month.abb[12]", "x[-(1:3)]", "x[c(-1, -1)]", "l[l]", "x[dt]",
               "letters[1:3]", "x[[TRUE]]", "x[[2.7]]", "x[[\"a\"]]", "x[[integer(0)]]", "c(5, 6)[[-0.5]]",
               "c(5, 6)[[-1.5]]", "x[c(-2, -2, 0, -100)]", "y[c(3, 3, 3)]", "s[0]", "dt[c(TRUE, FALSE)]",
               "x[[]]", "x[k]", "x[-k]", "i[c(-1L, 0L)]"))

  # ── if / else ───────────────────────────────────────────────────────────
  grp("if", c("if (TRUE) 1 else 2", "if (FALSE) 1", "if (NA) 1", "if (c(TRUE, FALSE)) 1", "if (logical(0)) 1",
              "if (\"TRUE\") 1", "if (\"yes\") 1", "if (\"T\") 1 else 2", "if (2) \"a\" else \"b\"",
              "if (0) \"a\" else \"b\"", "if (NaN) 1", "if (NA_real_) 1", "if (NA_integer_) 1", "if (5L) 1",
              "if (x[1] > 5) x else -x", "if (NULL) 1", "if (NA_character_) 1",
              "x > 15 & if (TRUE) TRUE else FALSE", "if (TRUE) 1 else 2 + 10", "if (FALSE) 1 else 2 + 10",
              "if (thr > 10) x > thr else x < thr", "if (any(x > 30, na.rm = TRUE)) \"ja\" else \"nein\"",
              "if (TRUE) if (FALSE) 1 else 2", "if (FALSE) 1 else if (TRUE) 2 else 3", "(if (TRUE) 1) + 1",
              "if (is.na(x[3])) 0 else x[3]", "if (dt[1] > as.Date(\"2019-12-31\")) 1 else 0",
              "y <- if (TRUE) 3; y * 2", "if (TRUE) NULL", "if (FALSE) 1 else NULL", "{if (TRUE) 1\nelse 2}",
              "(if (FALSE) 1\n else 2)", "if (TRUE)\n 1", "if (x[2] > 15) x[2] else 0", "if (\"F\") 1 else 2",
              "if (dt[1]) 1", "if (-0.5) 1 else 2", "if (l[1] & l[3]) 1 else 2", "if (TRUE) 1 else 2 > 1",
              "if (FALSE) 1 else 2 > 1", "-if (TRUE) 1 else 2", "if (TRUE) x[x > 15] else x",
              "if (length(n0)) 1 else 2", "if (y) 1", "if (FALSE) 1 else if (FALSE) 2"))

  # ── Funktionen ──────────────────────────────────────────────────────────
  grp("c", c("c(1, \"a\", TRUE)", "c(1L, 2.5)", "c(TRUE, 1L)", "c(NA, 1L)", "c()", "c(NULL, 1)", "c(x, y)",
             "c(l, i)", "c(s, 1)", "c(dt, as.Date(\"2022-01-01\"))", "c(1, dt)", "c(x[1], NA)",
             "length(c(x, y))", "c(1/3, \"a\")", "c(TRUE, NA, \"x\")", "c(i, 0.5)", "c(NA)", "c(NA_character_, 1)"))
  grp("mean", c("mean(x)", "mean(x, na.rm = TRUE)", "mean(y)", "mean(i)", "mean(l, na.rm = TRUE)", "mean(s)",
                "mean(n0)", "mean(c(1e308, 1e308))", "mean(x, trim = 0.2, na.rm = TRUE)",
                "mean(c(1, 5, 2, 9, 3), trim = 0.2)", "mean(1:10, trim = 0.1)", "mean(x, trim = 0.6)",
                "mean(y, trim = 0.5)", "mean()", "mean(dt, na.rm = TRUE)", "mean(x, na = TRUE)",
                "mean(c(0.1, 0.2, 0.3, 0.4))", "mean(x, foo = 1)", "mean(c(1, 2, 3, 100), 0.25)",
                "mean(x, trim = 0.1)", "mean(c(TRUE, FALSE))", "mean(j)", "mean(j, na.rm = TRUE)",
                "mean(y, trim = \"a\")", "mean(c(-1e308, 1e308, 1e308))"))
  grp("median", c("median(x)", "median(x, na.rm = TRUE)", "median(y)", "median(i)", "median(c(1L, 3L, 2L))",
                  "median(c(1L, NA))", "median(c(TRUE, FALSE, TRUE))", "median(c(\"b\", \"a\", \"c\"))",
                  "median(c(\"b\", \"a\"))", "median(n0)", "median(1:4)", "median(c(0.1, 0.2, 0.3, 0.4))",
                  "median(dt, na.rm = TRUE)", "median()", "median(l)", "median(j, na.rm = TRUE)",
                  "median(c(TRUE, FALSE))"))
  grp("var", c("sd(y)", "var(y)", "sd(x, na.rm = TRUE)", "var(x)", "var(1)", "sd(i)", "var(l, na.rm = TRUE)",
               "sd(c(TRUE, FALSE))", "var(\"a\")", "sd()", "var(c(1e10, 1e10 + 1, 1e10 + 2))", "sd(n0)",
               "var(c(0.1, 0.2, 0.4))", "sd(x)", "var(j, na.rm = TRUE)", "sd(y, TRUE)"))
  grp("minmax", c("max(x)", "max(x, na.rm = TRUE)", "min(y)", "max(i)", "min(i, -5L)", "max(i, 2.5)", "max(l)",
                  "max(TRUE, FALSE)", "min(s)", "min(s, na.rm = TRUE)", "max(s, na.rm = TRUE)", "max(\"b\", \"a\")",
                  "max(\"a\", 1)", "min(numeric(0))", "max(integer(0))", "max(character(0))", "max(NA, NaN)",
                  "max(NaN, NA)", "max(NA_integer_, 1L)", "max(dt, na.rm = TRUE)", "min(1, 2, 3, NA, na.rm = TRUE)",
                  "max(n0, 1)", "min(c(\"B\", \"b\", \"a\", \"A\"))", "max(c(\"a10\", \"a9\", \"a1\"))", "min(j)",
                  "max(j, na.rm = TRUE)", "min(1L, 2.5, \"10\")", "max(-Inf, Inf)", "min(y, 0)", "max()", "min(dt)",
                  "max(i, NA)", "min(NaN, 1)", "max(c(1, NaN), 5)", "min(\"\", \"a\")"))
  grp("sum", c("sum(x)", "sum(x, na.rm = TRUE)", "sum(1:10)", "sum(i, y)", "sum(1L, 2.5)", "sum(TRUE, FALSE, NA)",
               "sum()", "sum(s)", "sum(n0)", "sum(c(1e308, 1e308))", "sum(0.1, 0.2, 0.3)", "sum(c(0.1, 0.2, 0.3))",
               "sum(y, 1L, i)", "sum(j)", "sum(j, na.rm = TRUE)", "sum(dt)", "sum(x > 15, na.rm = TRUE)",
               "sum(c(big, big), 0.5)", "sum(1e308, 1e308)", "sum(l, i)"))
  grp("len", c("length(x)", "length(NULL)", "length(\"abc\")", "length(x[x > 15])", "length()", "length(1, 2)",
               "length(n0)", "length(dt)"))
  grp("quant", c("quantile(y, 0.5)", "quantile(x, 0.9, na.rm = TRUE)", "quantile(x, c(0.1, 0.5), na.rm = TRUE)",
                 "quantile(x)", "quantile(1:10, 0.33, type = 1)", "quantile(y, probs = c(0, 1))", "quantile(i)",
                 "quantile(y, 1.5)", "x > quantile(x, 0.5, na.rm = TRUE)", "quantile(y, 0.25, type = 6)",
                 "quantile(y, NA)", "quantile(numeric(0), 0.5)", "quantile(c(1.1, 2.2, 3.3, 4.4), 0.1)",
                 "quantile(1:9)", "quantile(y, 0.3, type = 2)", "quantile(y, 0.3, type = 3)",
                 "quantile(y, 0.3, type = 4)", "quantile(y, 0.3, type = 5)", "quantile(y, 0.3, type = 8)",
                 "quantile(y, 0.3, type = 9)", "quantile(s, na.rm = TRUE)", "quantile(l, na.rm = TRUE)"))
  grp("nchar", c("nchar(s)", "nchar(s, keepNA = FALSE)", "nchar(s, \"bytes\")", "nchar(s, type = \"w\")",
                 "nchar(s, type = \"x\")", "nchar(x)", "nchar(123.5)", "nchar(TRUE)", "nchar(1e6)", "nchar(i)",
                 "nchar(NA)", "nchar(NULL)", "nchar(\"\u4e2d\", \"width\")", "nchar(dt)", "nchar(s) > 1",
                 "nchar(s, keepNA = TRUE, type = \"bytes\")", "nchar(\"\u00e4\u00f6\", \"bytes\")", "nchar(1/3)",
                 "nchar(c(\"abc\", NA), \"c\")"))
  grp("asnum", c("as.numeric(s)", "as.numeric(\"NA\")", "as.numeric(\" 12 \")", "as.numeric(\"1e\")",
                 "as.numeric(\"0x1p3\")", "as.numeric(\"-inf\")", "as.numeric(\"NaN\")", "as.numeric(\"\")",
                 "as.numeric(c(\"1\", \"x\", \"y\"))", "as.numeric(l)", "as.numeric(dt)", "as.numeric(\"1.5e-3\")",
                 "as.numeric(\"  3.25  \")", "as.numeric(\"1e400\")", "as.numeric(\"0x1A\")", "as.numeric(\"1d\")",
                 "as.double(\"2\")", "as.numeric(i)", "as.numeric(\"1,5\")", "as.numeric(\".5\")",
                 "as.numeric(\"5.\")", "as.numeric(\"+.5e+2\")", "as.numeric(\"Inf\")", "as.numeric(\"infinity\")",
                 "as.numeric(\"-0\")", "as.numeric(\"1e-400\")", "as.numeric(\"0.1\") == 0.1", "as.numeric()",
                 "as.numeric(\"1\", \"2\")", "as.numeric(\"123456789.123456789\")", "as.numeric(\"0x\")",
                 "as.numeric(\"1 2\")", "as.numeric(\"\u00e4\")", "as.numeric(\"1e5\") + 1L"))
  grp("fun", c("as.logical(c(\"T\", \"yes\", \"false\", NA))", "as.logical(0:2)",
               "as.character(c(1.5, 1/3, 1e6, 1e15, 1e16, 123456.7))", "as.character(i)", "as.character(l)",
               "abs(y)", "sqrt(y)", "sqrt(-1)", "log(y)", "log(8, 2)", "log(8, base = 2)", "log()", "log(1, 2, 3)",
               "abs(1, 2)", "exp(1)", "log10(1000)", "log2(8)", "log1p(1e-10)", "expm1(1e-10)", "floor(-2.5)",
               "ceiling(2.1)", "trunc(-2.7)", "sign(y)", "round(2.5)", "round(-1.5)", "round(1.005, 2)",
               "round(123.456, -1)", "signif(123456, 2)", "round(\"a\")", "pmin(x, 15)", "pmax(x, 15, na.rm = TRUE)",
               "pmax(i, 1L)", "cumsum(y)", "identity(x)", "is.finite(x)", "is.infinite(c(Inf, -Inf, 1))", "tan(1)",
               "atan(1)", "tanh(0.5)", "sin(pi)", "cos(pi)", "unknownfun(1)", "x %foo% 1", "any(x > 15)",
               "all(x > 5, na.rm = TRUE)", "any(\"a\")", "any(1)", "xor(TRUE, FALSE)", "ifelse(NA, 1, 2)",
               "ifelse(c(TRUE, FALSE), 1L, 2.5)", "ifelse(TRUE, \"a\", 1)", "sqrt(x = 4)", "abs(x = -1)",
               "log(x = 1, y = 2)", "sd(x, 1, 2)", "round(i)", "round(x / 3, 2)", "signif(y / 7)", "exp(x)",
               "log(0)", "log(-1)", "log(x, 10)", "sqrt(i)", "abs(l)", "floor(i)", "is.na(i)", "is.na(s)",
               "is.na(dt)", "cumsum(x)", "cumsum(l)", "pmin(i, 0L)", "pmax(l, FALSE)", "pmin(y, x[1:3])",
               "as.logical(\"abc\")", "as.logical(y)", "as.character(dt)", "as.Date(\"2021-03-04\") > dt",
               "as.character(c(0.1 + 0.2, 1e-20, 100000, 1e5 + 0.1))", "isTRUE(TRUE)", "isTRUE(c(TRUE, TRUE))",
               "any()", "all()", "any(logical(0))", "is.finite(\"a\")", "is.nan(x)", "round(-0.4)",
               "signif(-0.000123456, 3)", "log(c(1, 10, 100), base = 10)", "exp(-Inf)", "ifelse(l, \"a\", NA)",
               "ifelse(x > 15, x, NA)", "ifelse(i > 0, i, 0L)", "abs()", "xor(l, TRUE)"))

  # ── Zeichenketten (Vergleiche nach Kollation wie R/ICU) ─────────────────
  grp("str", c("s == \"a\"", "s != \"a\"", "s < \"b\"", "s > \"a\"", "s <= \"a10\"", "\"a\" < \"B\"", "\"B\" < \"a\"",
               "\"a10\" < \"a9\"", "1 < \"2\"", "10 < \"9\"", "TRUE == \"TRUE\"", "\"abc\" == \"abc\"",
               "\"\u00c4\" < \"B\"", "\"\u00e4\" < \"b\"", "\"a\" < \"A\"", "s >= \"\"", "nm == s", "x == \"10\"",
               "1.5 == \"1.5\"", "1/3 == \"0.333333333333333\"", "\"Z\" > \"a\"", "\"a b\" < \"a_b\"",
               "\"_a\" < \"a\"", "s > \"\u00e4\"", "\"a\" == \"a \"", "\"10\" < 9", "\"x\" + 1",
               "'single' == \"single\"", "\"a\\tb\" == 'a\tb'", "nchar(\"\\u00e4\")", "\"\\x41\" == \"A\"",
               "\"\\101\" == \"A\"", "nchar(\"a\\\\b\")", "r\"(a\\b)\" == \"a\\\\b\"", "R\"[x]\" == 'x'",
               "r\"-{a}-\"", "`x` > 15", "\"\\\"\" == '\"'", "'\\'' == \"'\"", "\"\u00df\" < \"t\"",
               "\"e\" < \"\u00e9\"", "\"\u00e9\" < \"f\""))

  # ── Datum ───────────────────────────────────────────────────────────────
  grp("date", c("dt > as.Date(\"2020-06-01\")", "dt > \"2020-06-01\"", "dt + 1", "dt - dt[1]", "dt[3] - dt[1]",
                "dt == dt", "as.Date(\"2021-01-01\") - 1", "dt * 2", "-dt", "is.na(dt)", "as.numeric(dt)",
                "dt %in% dt[1]", "dt >= dt[1] & dt <= dt[3]", "1 + dt", "dt - 1", "!dt", "dt & TRUE"))

  # ── Zuweisungen, Blöcke, mehrere Ausdrücke ───────────────────────────────
  grp("assign", c("a <- 5; a * 2", "a = 3; b <- a + 1; b", "x <- 1; x", "1 -> z; z + 1", "(a <- 2) + 1",
                  "a <- b <- 3; a + b", "{a <- 1; a + 1}", "\"q\" <- 4; q", "x > 15; y < 0",
                  "\n\nx > 15\n", "", "  ", "# nur Kommentar", "x > 15 # Kommentar", "x >\n 15", "x[\n2\n]",
                  "sum(x\n, na.rm = TRUE)", "(x\n> 15)", "{}", "{x > 15}", "{1\n2}", 
                  "x$a", "x@a", "a := 1", "y = 1; y + 1", "1 = 2"))

  # ── Pipe ────────────────────────────────────────────────────────────────
  grp("pipe", c("x |> sum(na.rm = TRUE)", "x |> is.na() |> sum()", "y |> quantile(probs = 0.5)", "x |> f()",
                "x |> 1", "x |> sum", "x |> `+`(1)", "y |> mean(x = _)", "x |> sum(_)", "_ > 1", "y |> c(1, x = _)", "x > 15 |> sum()"))

  # ── Laufzeitfehler ──────────────────────────────────────────────────────
  grp("err", c("zz", "x + \"a\"", "!s", "-s", "s & TRUE", "TRUE && c(TRUE, FALSE)", "NULL && TRUE",
               "\"a\" || TRUE", "x[[1]][[2]]", "NA:3", "1:NA", "n0:1", "\"f\"(1)", "1(2)", "logical(0) && TRUE",
               "TRUE && logical(0)", "FALSE || \"a\"", "1:3 || TRUE", "x | \"a\"", "l && TRUE", "mean(NULL)", "-NULL", "is.na(NULL)", "NULL + 1L", "!NULL", "NULL == NULL", "logical(0) || FALSE"))

  # ── Warnungen ───────────────────────────────────────────────────────────
  grp("warn", c("1:3 + 1:2", "x + 1:4", "1:3 == 1:2", "l & c(TRUE, FALSE)", "1:2:3", "sqrt(-1)", "as.numeric(\"a\")",
                "big + 1L", "mean(\"a\")", "max(numeric(0))", "1e17 %% 3", "c(1, 2)[1] + as.numeric(\"x\")",
                "1:3 %% 1:2", "c(1.5L, 2.5L)", "i + big + 1L", "y > c(1, 2)", "as.integer(c(\"x\", \"1e10\"))",
                "s < c(\"a\", \"b\")", "sqrt(c(-1, -4))", "1:3 + 1:2 + 1:4"))

  # ── Zahlen und Konstanten ───────────────────────────────────────────────
  grp("num", c("0x10", "1e3", "1E-2", ".5", "5.", "1e+2", "0x1p-2", "1e5L", "0x10L", "TRUE + T", "F", "pi", "Inf - Inf",
               "-Inf", "1/0", "-1/0", "0/0", "NA_real_", "NA_integer_", "NA_character_", "NULL", "1e-400", "1e400",
               "123456789012345678901234567890", "0.1 + 0.2", "1 - 0.9", "0xFFp1", "0x.8p1", "1e-310 * 1e10",
               "2.2250738585072014e-308", "4.9406564584124654e-324", "1.7976931348623157e308", "0.30000000000000004",
               "3.14159265358979323846", "1e22", "1e23", "9007199254740993", "0.1e1", "100e-2", "TRUE", "letters[26]",
               "month.name[1]", "-0", "1 / -0", "0x7fffffffL", "0x80000000L"))

  # ── Syntaxfehler (Meldung wie parse(text = )) ────────────────────────────
  grp("syn", c("eq > ", "a > > b", "a b", "(a", "a)", "a +", "f(a,", "f(a b)", "a == b == c", "a < b < c", "1 +* 2",
               "x[1", "x]", "a & | b", "'abc", "\"abc", "a ,b", "if (a) b else", "if a", "a %in%", "a %foo", "5x",
               "a ! b", "!", "a(", ")", "1 2", "a 'x'", "a >\n\n", "a > 1 &\n b <", "TRUE FALSE", "NA NA", "a > 1e",
               "0x", "1.2.3", "`a", "a\\b", "a > 2 \n & b", "  \n eq >", "abc def ghi", "a && && b", "a > b else c",
               "else", "a\tb", "_a", ".1a", "'a\\qb'", "x == 'a\\qb'", "'\\x'", "'\\0'", "a <<< b", "x[[1]",
               "x[[1]]]", "if (a) 1\nelse 2", "function(x", "a::b::c", "a$1", "1 ->", "\\x", "a\u20acb",
               "f(a = b = c)", "if (a = 1) 2", "a NULL", "a function", "a ;; b", ";", "a,", "a]", "a}", "{", "}",
               "a[[", "a=>b", "a\n\n\nb c", "x > 1 +", "x >= ", "x > 15 & (y < 3", "x > 15 &&", "x %in% c(1, 2",
               "{if (a) 1 else 2\n else 3}", "a\n== b", "a # x\n > 2", "x[1,,2", "f(,", "'\\u{zz}'", "\"multi\nline",
               "r\"(raw", "r\"x\"", "1 + 2 3", "{x\n> 15}", "x > 15)", "x > 15 & y < 3 | ", "x > (15", "x[[2]",
               "mean(x, na.rm = TRUE", "sum(x))", "x >\t", "\u00e4 > 1 >", "x > 15 &\n\n", "if (x > 1) 2 else",
               "x > 15 && y < ", "x | | y", "x > 'abc", "c(1, 2,)", "x[]]", "x <= = 1", "x => 1", "x ! = 1",
               "1 %% %% 2", "x > 15 y < 2", "TRUE & NA FALSE", "x > -", "(x > 15", "x > 15 \u00e4",
               "x\n\n\n\n\n > ", "{\n\n}}", "x <- ", "x -> ", "f(x = )", "(if (TRUE) 1\n\n else 2", "1e", "0xg",
               "1.5e+", "x\u00a0> 1", "'\\U{110000}'", "'\\777'", "x > 1 ;; x", "x > 1\n;"))
})

ref_done()

ref_schreiben()
