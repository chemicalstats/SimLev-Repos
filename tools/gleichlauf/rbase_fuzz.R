# N8: Zufallsprüfung der Kerne core/slc_rbase*.c gegen R (Orakel). Schreibt je Kern eine Binärdatei
# mit Datensätzen aus Doubles: Felder als (Länge, Werte ...); Fehler als Länge -1.
#   Rscript tools/gleichlauf/rbase_fuzz.R <ordner> [fälle je kern]
args <- commandArgs(TRUE)
out <- args[1]; N <- if (length(args) > 1) as.integer(args[2]) else 10000L
dir.create(out, showWarnings = FALSE, recursive = TRUE)
set.seed(20261101)
specials <- c(NA, NaN, Inf, -Inf, 0, -0, 1, -1, .Machine$double.xmax, -.Machine$double.xmax,
              .Machine$double.xmin, 5e-324, 1e308, -1e308, 2, 0.5)
rx <- function(n, na = TRUE, ties = runif(1) < 0.4, spec = runif(1) < 0.3) {
  if (n == 0) return(numeric(0))
  x <- switch(sample(4, 1),
              rnorm(n, sample(c(0, 1e3, -5, 1e15), 1), sample(c(1, 1e-8, 1e10), 1)),
              runif(n), rexp(n) * 10^sample(-3:3, 1), round(rnorm(n) * 3))
  if (ties) x <- round(x, sample(0:1, 1))
  if (spec) { k <- sample(n, max(1, n %/% 4), TRUE); x[k] <- sample(specials, length(k), TRUE) }
  if (!na) x[is.na(x)] <- 0
  if (na && runif(1) < 0.15) x[sample(n, 1)] <- sample(c(NA, NaN), 1)
  x
}
rn <- function() sample(c(0:12, 0:40, sample(41:300, 3)), 1)
con <- NULL
rec <- function(...) for (v in list(...)) { v <- as.double(v); writeBin(c(length(v), v), con) }
err <- function() writeBin(-1, con)
open_k <- function(k) { if (!is.null(con)) close(con); con <<- file(file.path(out, paste0(k, ".bin")), "wb") }
try_rec <- function(expr) { r <- tryCatch(expr, error = function(e) NULL); if (is.null(r)) err() else rec(r) }

# 1 Summen: x, narm; Ergebnisse sum, prod, mean, var (ohne NA), cumsum, cumprod, cummax, cummin
open_k("sums")
for (i in 1:N) {
  x <- rx(rn()); narm <- runif(1) < 0.5
  xn <- x[!is.na(x)]
  rec(x, narm, sum(x, na.rm = narm), prod(x, na.rm = narm), mean(if (narm) xn else x),
      if (length(xn) > 1) var(xn) else NA_real_, cumsum(x), cumprod(x), cummax(x), cummin(x))
}
# 2 ganze Zahlen: mean
open_k("meanint")
for (i in 1:N) { x <- sample(-1e6:1e6, rn(), TRUE); rec(x, mean(x)) }
# 3 Matrizen: nr, nc, x, narm; colSums, colMeans, rowSums, rowMeans
open_k("margins")
for (i in 1:N) {
  nr <- sample(0:8, 1); nc <- sample(0:6, 1); x <- rx(nr * nc); narm <- runif(1) < 0.5
  m <- matrix(x, nr, nc)
  rec(nr, nc, x, narm, colSums(m, na.rm = narm), colMeans(m, na.rm = narm), rowSums(m, na.rm = narm),
      rowMeans(m, na.rm = narm))
}
# 4 Potenz
open_k("pow")
ys <- c(2, 0, 0.5, -1, 3, -2, 1.5, -0.5, 1/3, 10, 400, -400, NA, NaN, Inf, -Inf, 1, -0, 1e-300)
for (i in 1:N) { x <- rx(rn()); y <- if (runif(1) < 0.7) sample(ys, 1) else rnorm(1) * 3; rec(x, y, x^y) }
# 5 order: nkey, x (nkey Spalten), dec, nalast (1, 0, -1); Ergebnis
open_k("order")
for (i in 1:N) {
  n <- rn(); nk <- sample(c(1, 1, 2, 3), 1); keys <- lapply(1:nk, function(k) rx(n, ties = TRUE))
  dec <- runif(nk) < 0.5; nl <- sample(c(1, 0, -1), 1)
  r <- do.call(order, c(keys, list(na.last = if (nl == 1) TRUE else if (nl == 0) FALSE else NA,
                                   decreasing = dec, method = "radix")))
  rec(nk, unlist(keys), dec, nl, r)
}
# 6 rank (x ohne NA), ties 0..4
open_k("rank")
tm <- c("average", "first", "last", "min", "max")
for (i in 1:N) { x <- rx(rn(), na = FALSE, ties = TRUE); t <- sample(0:4, 1); rec(x, t, rank(x, ties.method = tm[t + 1])) }
# 7 partielle Sortierung (x ohne NA)
open_k("psort")
for (i in 1:N) {
  x <- rx(sample(c(2:60, 100:200), 1), na = FALSE, ties = TRUE, spec = runif(1) < 0.5)
  if (runif(1) < 0.5) x[sample(length(x), length(x) %/% 3)] <- sample(c(0, -0), 1)
  k <- sample(length(x), min(length(x), sample(c(1:12, 1:3), 1)))
  rec(x, k, sort(x, partial = k))
}
# 8 Quantile (x ohne NA), Typ 1..9; p begrenzt, NA erlaubt
open_k("quantile")
for (i in 1:N) {
  x <- rx(rn(), na = FALSE, ties = TRUE)
  if (runif(1) < 0.3 && length(x)) x[sample(length(x), max(1, length(x) %/% 2))] <- sample(c(0, -0), 1)
  p <- c(runif(sample(1:6, 1)), sample(c(0, 1, 0.5, 0.25, 0.75, 1/3, 0.1, 0.9, NA), sample(0:4, 1), TRUE))
  p <- pmax(0, pmin(1, p)); tp <- sample(1:9, 1)
  rec(x, p, tp, quantile(x, p, type = tp, names = FALSE))
}
# 9 tabulate
open_k("tabulate")
for (i in 1:N) {
  b <- sample(c(-3:25, NA), rn(), TRUE) + if (runif(1) < 0.3) runif(1) else 0; nb <- sample(0:20, 1)
  rec(b, nb, suppressWarnings(tabulate(b, nb)))
}
# 10 findInterval
open_k("findint")
for (i in 1:N) {
  v <- sort(rx(sample(0:12, 1), na = FALSE, ties = TRUE, spec = FALSE)); x <- rx(rn(), ties = TRUE)
  if (runif(1) < 0.5 && length(v)) x <- c(x, sample(v, 3, TRUE))
  fl <- runif(3) < 0.5
  rec(v, x, fl, findInterval(x, v, rightmost.closed = fl[1], all.inside = fl[2], left.open = fl[3]))
}
# 11 cov/cor (interner Kern von R über stats:::C_cor/C_cov)
open_k("cov")
for (i in 1:N) {
  n <- sample(0:14, 1); ncx <- sample(1:4, 1); x <- matrix(rx(n * ncx, ties = TRUE), n, ncx)
  hasy <- runif(1) < 0.4; ncy <- if (hasy) sample(1:3, 1) else 0
  y <- if (hasy) matrix(rx(n * ncy, ties = TRUE), n, ncy) else NULL
  use <- sample(1:5, 1); kend <- runif(1) < 0.3; cr <- runif(1) < 0.6
  r <- tryCatch(suppressWarnings(if (cr) .Call(stats:::C_cor, x, y, use, kend) else .Call(stats:::C_cov, x, y, use, kend)),
                error = function(e) NULL)
  rec(n, ncx, x, ncy, if (hasy) y else numeric(0), use, kend, cr)
  if (is.null(r)) err() else rec(r)
}
close(con)
cat("fertig", N, "Fälle je Kern\n")
