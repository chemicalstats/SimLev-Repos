# Direktvergleich der eigenstaendig geschriebenen Richardson-Ableitungen
# (SimLev:::.sl_richardson_hessian, .sl_richardson_jacobian in r/R/richardson.R) mit
# numDeriv::hessian und numDeriv::jacobian als Blackbox-Orakel: zufaellige Funktionen und
# Punkte, die Einstellungen von rugarch (.makefitmodel: Hesse-Matrix eps = 1e-4, d = 0.1,
# Jacobi-Matrix eps = 1e-4, d = 1e-4, beide zero.tol = sqrt(.Machine$double.eps/7e-7),
# r = 4, v = 2) und zusaetzlich r = 2, 3, 5, 6. Verglichen werden mit identical() das
# Ergebnis und die Folge der Auswertungspunkte; dazu Funktionen mit Gedaechtnis wie die
# Likelihood von rugarch (nicht endliche Werte werden mit dem letzten endlichen Wert
# bestraft). numDeriv wird nur hier gebraucht, nicht von SimLev.
# Aufruf aus der Repo-Wurzel:
#   LC_ALL=C.UTF-8 R_LIBS=<R-Bibliothek mit SimLev> Rscript golden/modules/check_richardson.R [n]
args <- commandArgs(TRUE)
N <- if (length(args)) as.integer(args[1]) else 500L
stopifnot(requireNamespace("numDeriv", quietly = TRUE))
ZT <- sqrt(.Machine$double.eps / 7e-07)

# zufaellige glatte Funktion R^p -> R^q (q = 1 fuer die Hesse-Matrix)
rand_fun <- function(p, q) {
  K <- sample(1:4, 1)
  A <- lapply(1:K, function(k) matrix(rnorm(q * p, sd = 10^runif(1, -1, 1)), q, p))
  b <- lapply(1:K, function(k) rnorm(q))
  cf <- lapply(1:K, function(k) rnorm(q, sd = 10^runif(1, -2, 2)))
  g <- sample(list(sin, exp, tanh, function(z) log1p(z^2), function(z) z^3, cos,
                   function(z) 1 / (1 + z^2), function(z) sqrt(1 + z^2)), K, replace = TRUE)
  Q <- crossprod(matrix(rnorm(p * p), p, p)) * 10^runif(1, -2, 2)
  function(x) {
    out <- rep(sum(x * (Q %*% x)), q)
    for (k in 1:K) out <- out + cf[[k]] * g[[k]](as.vector(A[[k]] %*% x) + b[[k]])
    out
  }
}
# zufaelliger Punkt mit gemischten Groessenordnungen, Nullen und Werten unter zero.tol
rand_point <- function(p) {
  x <- rnorm(p) * 10^runif(p, -5, 2)
  x[runif(p) < 0.15] <- 0
  tiny <- runif(p) < 0.1
  x[tiny] <- runif(sum(tiny), -ZT, ZT)
  x
}
# Funktion mit Gedaechtnis wie die Likelihood von rugarch: ausserhalb eines Bereichs
# (hier |x_1 - c| < w) NaN, dann letzter endlicher Wert + 10 % Strafe; Protokoll der Punkte
with_memory <- function(f, c, w) {
  env <- new.env(); env$last <- 1; env$log <- list(); env$pen <- 0L
  list(f = function(x) {
    env$log[[length(env$log) + 1L]] <- x
    v <- if (abs(x[1] - c) < w) f(x) else NaN
    bad <- !is.finite(v)
    if (any(bad)) { v[bad] <- env$last + 0.1 * abs(env$last); env$pen <- env$pen + 1L } else env$last <- v[1]
    v
  }, env = env)
}

nh <- nj <- nm <- npen <- 0L; fails <- character()
check <- function(tag, a, b) if (!identical(a, b)) fails <<- c(fails, tag)
set.seed(20261021)
for (it in seq_len(N)) {
  p <- sample(1:6, 1); x <- rand_point(p)
  r <- if (it %% 4 == 0) sample(c(2, 3, 5, 6), 1) else 4
  # Hesse-Matrix
  f <- rand_fun(p, 1)
  check(sprintf("hessian %d", it),
        numDeriv::hessian(f, x, method.args = list(eps = 1e-4, d = 0.1, zero.tol = ZT, r = r, v = 2,
                                                    show.details = FALSE)),
        SimLev:::.sl_richardson_hessian(f, x, eps = 1e-4, d = 0.1, zero.tol = ZT, r = r, v = 2))
  nh <- nh + 1L
  # Jacobi-Matrix
  q <- sample(c(1:5, 50, 300), 1); g <- rand_fun(p, q)
  check(sprintf("jacobian %d", it),
        numDeriv::jacobian(g, x, method.args = list(eps = 1e-4, d = 1e-4, zero.tol = ZT, r = r, v = 2,
                                                     show.details = FALSE)),
        SimLev:::.sl_richardson_jacobian(g, x, eps = 1e-4, d = 1e-4, zero.tol = ZT, r = r, v = 2))
  nj <- nj + 1L
  # mit Gedaechtnis: Ergebnis und Folge der Auswertungspunkte
  if (it %% 2 == 0) {
    w <- abs(x[1]) * runif(1, 0.05, 0.4) + 1e-6
    m1 <- with_memory(f, x[1], w); m2 <- with_memory(f, x[1], w)
    check(sprintf("hessian/memory %d", it),
          numDeriv::hessian(m1$f, x, method.args = list(eps = 1e-4, d = 0.1, zero.tol = ZT, r = r, v = 2)),
          SimLev:::.sl_richardson_hessian(m2$f, x, eps = 1e-4, d = 0.1, zero.tol = ZT, r = r, v = 2))
    check(sprintf("hessian/log %d", it), m1$env$log, m2$env$log)
    npen <- npen + m2$env$pen
    w <- abs(x[1]) * runif(1, 1e-5, 2e-4) + 1e-9
    m1 <- with_memory(g, x[1], w); m2 <- with_memory(g, x[1], w)
    check(sprintf("jacobian/memory %d", it),
          numDeriv::jacobian(m1$f, x, method.args = list(eps = 1e-4, d = 1e-4, zero.tol = ZT, r = r, v = 2)),
          SimLev:::.sl_richardson_jacobian(m2$f, x, eps = 1e-4, d = 1e-4, zero.tol = ZT, r = r, v = 2))
    check(sprintf("jacobian/log %d", it), m1$env$log, m2$env$log)
    npen <- npen + m2$env$pen
    nm <- nm + 1L
  }
}
cat(sprintf("Hesse-Matrix %d, Jacobi-Matrix %d, mit Gedaechtnis und Auswertungsfolge je %d (%d bestrafte Auswertungen): %s\n",
            nh, nj, nm, npen, if (length(fails)) paste("ABWEICHUNG:", paste(fails, collapse = ", ")) else "alle identisch"))
if (length(fails)) quit(status = 1)
