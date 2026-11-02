# N10: Zufallsfälle für den Datumskern core/slc_rbase_date.c mit R als Orakel.
#   Rscript tools/gleichlauf/date_fuzz.R <ordner> [fälle]          # schreibt fmt.tsv und parse.tsv
#   python3 tools/gleichlauf/date_fuzz_cmp.py <ordner>             # Python (simlev._ext)
#   julia --project=julia tools/gleichlauf/date_fuzz_cmp.jl <ordner>   # Julia (libslc)
# fmt.tsv: Tag, Format, format(as.Date(Tag), Format) (C-Locale) mit den dokumentierten Umwandlungen (Prüfziel:
# textgleich); fmt_sys.tsv: dasselbe mit systemabhängigen Formen (Schalter, Breiten, unbekannte Umwandlungen; nur
# Bericht); parse.tsv: Text, Trenner, Tage bzw. NA.
# Texte mit \ \t \n werden als \\ \t \n geschrieben.
args <- commandArgs(TRUE)
d <- args[1]
n <- if (length(args) > 1) as.integer(args[2]) else 10000L
dir.create(d, showWarnings = FALSE, recursive = TRUE)
invisible(Sys.setlocale("LC_TIME", "C"))
set.seed(20261101)
esc <- function(s) gsub("\n", "\\n", gsub("\t", "\\t", gsub("\\", "\\\\", s, fixed = TRUE), fixed = TRUE), fixed = TRUE)
# dokumentierte Umwandlungen (?strptime; ohne das Locale-abhängige %+), dazu %E[cCyYxX], %O[dHImMUVwWy], %OSn
doc <- c(paste0("%", strsplit("aAbBcCdDeFgGhHIjmMnprRStTuUVwWxXyYzZklsp%", "")[[1]]),
         paste0("%E", strsplit("cCyYxX", "")[[1]]), paste0("%O", strsplit("dHImMUVwWy", "")[[1]]), paste0("%OS", 1:6))
# systemabhängig: Schalter, Breiten, E/O vor anderen Buchstaben, unbekannte Umwandlungen
conv <- strsplit("aAbBcCdDeFgGhHIjklmMnpPrRsStTuUVwWxXyYzZ%qEOJ", "")[[1]]
spec_sys <- function() {
  f <- if (runif(1) < 0.4) paste(sample(c("-", "_", "0", "^", "#"), sample(1:2, 1), TRUE), collapse = "") else ""
  w <- if (runif(1) < 0.3) as.character(sample(c(0:12, 20), 1)) else ""
  e <- if (runif(1) < 0.08) sample(c("E", "O"), 1) else ""
  paste0("%", f, w, e, sample(conv, 1))
}
lit <- c("", "", "-", "/", " ", ":", "x", "\u00e4", "T", "|", "0")
mkfmt <- function(spec) {
  k <- sample(1:4, 1)
  paste0(vapply(seq_len(k), function(i) paste0(sample(lit, 1), spec()), ""), collapse = "")
}
z <- c(sample(-800000:3000000, n - n %/% 10, TRUE), sample(c(-719528, -719529, 0, -1, 10957, 2932896, 2932897), n %/% 20, TRUE),
       round(runif(n %/% 10 - n %/% 20, -2e10, 2e10)))
fm <- vapply(seq_len(n), function(i) mkfmt(function() sample(doc, 1)), "")
fm[seq(1, n, 7)] <- sample(c("%Y-%m-%d", "%G-%V", "%Y-%m", "%Y", "%m-%d", "%d.%m.%Y", "%b %Y", "%u"), length(seq(1, n, 7)), TRUE)
wr <- function(fm, file) {
  out <- format(as.Date(z), fm)
  writeLines(paste(sprintf("%.0f", z), esc(fm), ifelse(is.na(out), "<NA>", esc(out)), sep = "\t"), file.path(d, file),
             useBytes = TRUE)
}
wr(fm, "fmt.tsv")
fs <- vapply(seq_len(n), function(i) mkfmt(spec_sys), "")
fs[seq(1, n, 20)] <- paste0(fs[seq(1, n, 20)], sample(c("%", "%-", "%5", "%_0", "%E"), length(seq(1, n, 20)), TRUE))
wr(fs, "fmt_sys.tsv")
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
cat("R:", 2 * n, "Format- und", n, "Lesefälle in", d, "\n")
