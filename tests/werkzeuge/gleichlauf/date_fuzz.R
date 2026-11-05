# Zufallsfälle für den Datumskern core/slc_rbase_date.cpp mit R als Orakel.
#   Rscript tests/werkzeuge/gleichlauf/date_fuzz.R <ordner> [fälle] [seed]   # schreibt fmt.tsv, fmt_sys.tsv, fmt_os.tsv, parse.tsv
#   python3 tests/werkzeuge/gleichlauf/date_fuzz_cmp.py <ordner>             # Python (simlev._ext)
#   julia --project=julia tests/werkzeuge/gleichlauf/date_fuzz_cmp.jl <ordner>   # Julia (libslc)
# fmt.tsv: Tag, Format, format(as.Date(Tag), Format) (C-Locale) mit den dokumentierten Umwandlungen;
# fmt_sys.tsv (seit 1.3.0 Prüfziel wie fmt.tsv): Formen, die ?strptime "system-specific" nennt (Schalter - _ 0 ^ #,
# Breiten, E/O vor allen Buchstaben, unbekannte Umwandlungen, unvollständige Angaben, leeres Format);
# fmt_os.tsv (seit 1.3.0): %OS, %OSn und R's Ersetzung im Format mit options(digits.secs) (4. Spalte, "NULL" = nicht
# gesetzt); Ergebnis "<ERR>", wenn R einen Fehler meldet (Ausgabe über 2048 Bytes); parse.tsv: Text, Trenner,
# Tage bzw. NA. Prüfziel überall: textgleich. Texte mit \ \t \n werden als \\ \t \n geschrieben.
args <- commandArgs(TRUE)
d <- args[1]
n <- if (length(args) > 1) as.integer(args[2]) else 10000L
seed <- if (length(args) > 2) as.integer(args[3]) else 20261101L
dir.create(d, showWarnings = FALSE, recursive = TRUE)
invisible(Sys.setlocale("LC_TIME", "C"))
set.seed(seed)
esc <- function(s) gsub("\n", "\\n", gsub("\t", "\\t", gsub("\\", "\\\\", s, fixed = TRUE), fixed = TRUE), fixed = TRUE)
# dokumentierte Umwandlungen (?strptime; ohne das Locale-abhängige %+), dazu %E[cCyYxX], %O[dHImMUVwWy], %OSn
doc <- c(paste0("%", strsplit("aAbBcCdDeFgGhHIjmMnprRStTuUVwWxXyYzZklsp%", "")[[1]]),
         paste0("%E", strsplit("cCyYxX", "")[[1]]), paste0("%O", strsplit("dHImMUVwWy", "")[[1]]), paste0("%OS", 1:6))
# systemabhängig: Schalter, Breiten, E/O vor allen Buchstaben, unbekannte Umwandlungen
conv <- c(strsplit("aAbBcCdDeFgGhHIjklmMnpPrRsStTuUVwWxXyYzZ%qEOJ+fiLNQv1 ", "")[[1]], "ä")
spec_sys <- function() {
  f <- if (runif(1) < 0.5) paste(sample(c("-", "_", "0", "^", "#"), sample(1:3, 1), TRUE), collapse = "") else ""
  w <- if (runif(1) < 0.4) as.character(sample(c(0:12, 15, 20, 25, "00", "05", "012"), 1)) else ""
  e <- if (runif(1) < 0.15) sample(c("E", "O"), 1) else ""
  paste0("%", f, w, e, sample(conv, 1))
}
lit <- c("", "", "-", "/", " ", ":", "x", "ä", "T", "|", "0", "%%")
mkfmt <- function(spec) {
  k <- sample(1:4, 1)
  paste0(vapply(seq_len(k), function(i) paste0(sample(lit, 1), spec()), ""), collapse = "")
}
z <- c(sample(-800000:3000000, n - n %/% 10, TRUE), sample(c(-719528, -719529, 0, -1, 10957, 2932896, 2932897), n %/% 20, TRUE),
       round(runif(n %/% 10 - n %/% 20, -2e10, 2e10)))
z <- sample(z)
fmt1 <- function(z, f) tryCatch({r <- format(as.Date(z), f); if (is.na(r)) "<NA>" else esc(r)}, error = function(e) "<ERR>")
wr <- function(fm, file, ds = NULL) {
  out <- if (is.null(ds)) {
    vapply(seq_along(fm), function(i) fmt1(z[i], fm[i]), "")
  } else {
    vapply(seq_along(fm), function(i) {
      options(digits.secs = if (is.na(ds[i])) NULL else ds[i])
      on.exit(options(digits.secs = NULL))
      fmt1(z[i], fm[i])
    }, "")
  }
  cols <- list(sprintf("%.0f", z[seq_along(fm)]), esc(fm), out)
  if (!is.null(ds)) cols[[4]] <- ifelse(is.na(ds), "NULL", format(ds))
  writeLines(do.call(paste, c(cols, sep = "\t")), file.path(d, file), useBytes = TRUE)
}
fm <- vapply(seq_len(n), function(i) mkfmt(function() sample(doc, 1)), "")
fm[seq(1, n, 7)] <- sample(c("%Y-%m-%d", "%G-%V", "%Y-%m", "%Y", "%m-%d", "%d.%m.%Y", "%b %Y", "%u"), length(seq(1, n, 7)), TRUE)
wr(fm, "fmt.tsv")
fs <- vapply(seq_len(n), function(i) mkfmt(spec_sys), "")
k <- seq(1, n, 20)
fs[k] <- paste0(fs[k], sample(c("%", "%-", "%5", "%_0", "%E", "%^", "%12", "%05E"), length(k), TRUE))
fs[seq(3, n, 97)] <- ""
fs[seq(5, n, 211)] <- sample(c("%2048d", "%2049d", "%3000q", paste0(strrep("x", 2040), "%9Y")), length(seq(5, n, 211)), TRUE)
wr(fs, "fmt_sys.tsv")
# %OS: R ersetzt das erste "%OS" (mit Ziffer) im Format; digits.secs für %OS ohne Ziffer
os <- c("%OS", "%OS", "%OS0", "%OS1", "%OS3", "%OS6", "%OS7", "%OS9", "%%OS", "%%OS2", "%-OS", "%5OS", "%E%OS", "%5%OS3")
spec_os <- function() if (runif(1) < 0.45) sample(os, 1) else if (runif(1) < 0.5) spec_sys() else sample(doc, 1)
no <- max(1L, n %/% 2L)
fo <- vapply(seq_len(no), function(i) mkfmt(spec_os), "")
dso <- sample(c(NA, 0:7, 2.5, -1, 10), no, TRUE)
wr(fo, "fmt_os.tsv", dso)
# Lesen: as.Date(x, format = "%Y-%m-%d") bzw. "%Y/%m/%d"
piece <- function() {
  u <- runif(1)
  if (u < 0.75) as.character(sample(c(0:40, 0:40, 99:101, 999:1001, 1969:2030, 9998:10001), 1))
  else if (u < 0.85) sprintf("%02d", sample(0:40, 1))
  else if (u < 0.92) paste0(" ", sample(1:31, 1))
  else sample(c("", "x", "+1", "-1", "001", "0012", "1.5", "\t1", " "), 1)
}
sep <- sample(c("-", "/"), n, TRUE)
other <- ifelse(sep == "-", "/", "-")
tx <- vapply(seq_len(n), function(i) {
  s1 <- if (runif(1) < 0.93) sep[i] else other[i]
  s2 <- if (runif(1) < 0.93) sep[i] else sample(c(other[i], " ", ""), 1)
  tail <- if (runif(1) < 0.15) sample(c("abc", " ", "1", "-", "T12:00"), 1) else ""
  paste0(if (runif(1) < 0.05) " " else "", piece(), s1, piece(), s2, piece(), tail)
}, "")
pz <- as.numeric(mapply(function(x, s) as.Date(x, format = paste0("%Y", s, "%m", s, "%d")), tx, sep))
writeLines(paste(esc(tx), sep, ifelse(is.na(pz), "NA", sprintf("%.0f", pz)), sep = "\t"), file.path(d, "parse.tsv"),
           useBytes = TRUE)
cat("R:", 2 * n + no, "Format- und", n, "Lesefälle in", d, "\n")
