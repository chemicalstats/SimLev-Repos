# Referenzfälle für simlev._r.fmt (Formatierung und Druckausgabe wie R 4.3.3).
# Aufruf aus der Repo-Wurzel:
#   LC_ALL=C.UTF-8 R_LIBS=<R-Bibliothek mit SimLev> Rscript golden/modules/gen_r_fmt.R
source("golden/modules/ref_tools.R"); ref_init("r_fmt")
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
