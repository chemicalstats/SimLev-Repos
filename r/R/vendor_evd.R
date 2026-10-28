# =============================================================================
#  vendor_evd.R  —  uebernommene Teile des R-Pakets evd
# -----------------------------------------------------------------------------
#  Paket:     evd 2.3-7.1 (CRAN, 2024-09-21), Datei R/uvfit.R
#  Autoren:   Alec Stephenson. Function fbvpot by Chris Ferro.
#  Lizenz:    GPL-3
#  Angepasst fuer SimLev (siehe inst/COPYRIGHTS):
#    * fpot() und fpot.norm() als interne Funktionen .evd_fpot() und
#      .evd_fpot_norm(); uebernommen ist nur der Weg, den SimLev erreicht:
#      model = "gpd" mit cmax = FALSE und mper = NULL (die Argumente und
#      ihre Pruefungen bleiben; model = "pp", cmax = TRUE und mper brechen
#      mit einem Fehler ab, statt nlpp/clusters/fpot.quantile zu nutzen)
#    * die negative Log-Likelihood nlgpd ist C-Code aus evd src/pot.c,
#      mit unveraendertem Rumpf in src/vendor_evd.c; statt ueber .C wird sie
#      ueber die .Call-Huelle C_evd_nlgpd gerufen, die die Argumente wie .C
#      prueft und kopiert (src/init.c registriert nur .Call-Routinen)
#    * Rechnung, Startwerte, optim-Aufruf, Meldungen und Ergebnis (Klasse
#      c("pot", "uvevd", "evd")) wie im Original
#  Genutzt von .fit_tail() (bootstrap(), Verfahren "evt").
# =============================================================================

#' GPD-Anpassung ueber einer Schwelle (aus evd 2.3-7.1, fpot)
#' @keywords internal
#' @noRd
.evd_fpot <-
function(x, threshold, model = c("gpd", "pp"), start, npp = length(x), cmax = FALSE, r = 1, ulow = -Inf, rlow = 1, mper = NULL, ..., std.err = TRUE, corr = FALSE, method = "BFGS", warn.inf = TRUE)
{
  call <- match.call()
  model <- match.arg(model)
  if(missing(x) || length(x) == 0 || mode(x) != "numeric")
    stop("`x' must be a non-empty numeric vector")
  if(missing(threshold) || length(threshold) != 1 ||
     mode(threshold) != "numeric")
    stop("`threshold' must be a numeric value")
  threshold <- as.double(threshold)
  if(is.null(mper)) {
    ft <- .evd_fpot_norm(x = x, threshold = threshold, model = model, start = start,
      npp = npp, cmax = cmax, r = r, ulow = ulow, rlow = rlow, ...,
      std.err = std.err, corr = corr, method = method, warn.inf = warn.inf)
  }
  else {
    if(model == "pp")
      stop("`mper' cannot be specified in point process models")
    # SimLev: fpot.quantile nicht uebernommen
    stop("evd-Uebernahme: fpot mit mper (fpot.quantile) nicht uebernommen")
  }
  structure(c(ft, call = call), class = c("pot", "uvevd", "evd"))
}

#' @keywords internal
#' @noRd
.evd_fpot_norm <-
function(x, threshold, model, start, npp = length(x), cmax = FALSE, r = 1, ulow = -Inf, rlow = 1, ..., std.err = TRUE, corr = FALSE, method = "BFGS", warn.inf = TRUE)
{
    if(model == "gpd") {
      nlpot <- function(loc, scale, shape) {
        # SimLev: statt .C(C_nlgpd, ..., dns = double(1))$dns die .Call-Huelle
        # aus src/vendor_evd.c (prueft und rechnet wie .C)
        .Call(C_evd_nlgpd,
            exceed, nhigh, threshold, scale, shape)
      }
      # Avoids note produced by R CMD check
      formals(nlpot) <- formals(nlpot)[2:3]
    }
    # SimLev: model = "pp" (nlpp) nicht uebernommen
    if(model == "pp")
      stop("evd-Uebernahme: fpot mit model = \"pp\" nicht uebernommen")
    nn <- length(x)
    nop <- as.double(nn/npp)
    if(cmax) {
      # SimLev: clusters() nicht uebernommen
      stop("evd-Uebernahme: fpot mit cmax = TRUE (clusters) nicht uebernommen")
    }
    else {
      extind <- r <- NULL
      high <- (x > threshold) & !is.na(x)
      exceed <- as.double(x[high])
      nhigh <- nat <- length(exceed)
    }
    if(!nhigh) stop("no data above threshold")
    pat <- nat/nn
    param <- c("scale", "shape")
    if(missing(start)) {
        if(model == "gpd") {
          start <- list(scale = 0, shape = 0)
          start$scale <- mean(exceed) - threshold
        }
        start <- start[!(param %in% names(list(...)))]
    }
    if(!is.list(start))
        stop("`start' must be a named list")
    if(!length(start))
        stop("there are no parameters left to maximize over")
    nm <- names(start)
    l <- length(nm)
    f <- formals(nlpot)
    names(f) <- param
    m <- match(nm, param)
    if(any(is.na(m)))
        stop("`start' specifies unknown arguments")
    formals(nlpot) <- c(f[m], f[-m])
    nllh <- function(p, ...) nlpot(p, ...)
    if(l > 1)
        body(nllh) <- parse(text = paste("nlpot(", paste("p[",1:l,
            "]", collapse = ", "), ", ...)"))
    fixed.param <- list(...)[names(list(...)) %in% param]
    if(any(!(param %in% c(nm,names(fixed.param)))))
        stop("unspecified parameters")
    start.arg <- c(list(p = unlist(start)), fixed.param)
    if(warn.inf && do.call("nllh", start.arg) == 1e6)
        warning("negative log-likelihood is infinite at starting values")
    opt <- optim(start, nllh, hessian = TRUE, ..., method = method)
	if(is.null(names(opt$par))) names(opt$par) <- nm
    if (opt$convergence != 0) {
        warning("optimization may not have succeeded")
        if(opt$convergence == 1) opt$convergence <- "iteration limit reached"
    }
    else opt$convergence <- "successful"
    if(std.err) {
        tol <- .Machine$double.eps^0.5
        var.cov <- qr(opt$hessian, tol = tol)
        if(var.cov$rank != ncol(var.cov$qr))
            stop("observed information matrix is singular; use std.err = FALSE")
        var.cov <- solve(var.cov, tol = tol)
        std.err <- diag(var.cov)
        if(any(std.err <= 0))
            stop("observed information matrix is singular; use std.err = FALSE")
        std.err <- sqrt(std.err)
        names(std.err) <- nm
        if(corr) {
            .mat <- diag(1/std.err, nrow = length(std.err))
            corr <- structure(.mat %*% var.cov %*% .mat, dimnames = list(nm,nm))
            diag(corr) <- rep(1, length(std.err))
        }
        else corr <- NULL
    }
    else std.err <- var.cov <- corr <- NULL
    param <- c(opt$par, unlist(fixed.param))
   if(model == "gpd") scale <- param["scale"]

    list(estimate = opt$par, std.err = std.err, fixed = unlist(fixed.param),
        param = param, deviance = 2*opt$value, corr = corr, var.cov = var.cov,
        convergence = opt$convergence, counts = opt$counts, message = opt$message,
        threshold = threshold, cmax = cmax, r = r, ulow = ulow, rlow = rlow, npp = npp,
        nhigh = nhigh, nat = nat, pat = pat, extind = extind,
        data = x, exceedances = exceed, mper = NULL, scale = scale)
}
