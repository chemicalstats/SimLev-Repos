# Referenzfälle für den gemeinsamen Auswerter von Ausdrücken in R-Syntax
# (Python simlev._r.rexpr, Julia SimLev.RExpr): Bedingungen als Text in
# tactical_rules(), bootstrap_probability(), regime_subset() und view_prob().
# Jeder Fall wertet einen Text wie R aus:
#   R       eval(parse(text = rx_txt), envir = list2env(rx_dat))
#   Python  simlev._r.rexpr.eval_r(rx_txt, rx_dat)
#   Julia   SL.RExpr.eval_r(rx_txt, rx_dat)
# Aufruf aus der Repo-Wurzel:
#   LC_ALL=C.UTF-8 R_LIBS=<R-Bibliothek mit SimLev> Rscript golden/modules/gen_rexpr.R
source("golden/modules/ref_tools.R"); ref_init("rexpr")

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
