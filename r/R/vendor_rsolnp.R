# =============================================================================
#  vendor_rsolnp.R  —  uebernommene Teile des R-Pakets Rsolnp
# -----------------------------------------------------------------------------
#  Paket:     Rsolnp 1.16 (CRAN, 2015-12-28), Funktionen solnp, gosolnp und
#             die internen Hilfen .subnp, .checkpars, .checkfun, .checkineq,
#             .checkeq, .safefunx, .safefun, .solnpctrl, .vnorm, .solvecond,
#             .subnpmsg, .report, .ones, .zeros, .emptyfun, .eps, .randpars,
#             .distr1, .distr2, .distr3 (Code aus dem Namensraum des
#             installierten Pakets, deparse)
#  Autoren:   Alexios Ghalanos and Stefan Theussl
#             (Copyright (C) 2009-2013 laut inst/COPYRIGHTS von Rsolnp)
#  Lizenz:    GPL (DESCRIPTION); laut inst/COPYRIGHTS von Rsolnp GPL-3
#  Angepasst fuer SimLev (siehe inst/COPYRIGHTS):
#    * die Funktionen heissen hier .rsolnp_<name> (z. B. .rsolnp_solnp,
#      .rsolnp_subnp, .rsolnp_eps) und rufen sich unter diesen Namen auf;
#      truncnorm::rtruncnorm (in .distr2) ist .truncnorm_rtruncnorm
#      (R/vendor_truncnorm.R)
#    * uebernommen ist der Weg, den rugarch (.rugarch_solnpsolver,
#      .rugarch_gosolnpsolver in R/vendor_rugarch.R) erreicht: solnp
#      vollstaendig, gosolnp ohne parallele Auswertung; cluster und
#      control$eval.type = 2 (.randpars2) brechen mit einem Fehler ab, statt
#      parallel::clusterExport/parLapply bzw. .randpars2 zu nutzen (nicht
#      uebernommen); startpars, benchmark und die Testprobleme sind nicht
#      uebernommen
#    * die Funktionsruempfe sind sonst unveraendert (Formatierung von
#      deparse); Rechnung, Zufallszahlen (set.seed(rseed), bei rseed = NULL
#      der Startwert as.numeric(Sys.time())), Meldungen und Ergebnisse sind
#      die von Rsolnp
#  Genutzt von .rugarch_ugarchfit() (.fit_garch11: bootstrap(), dcc_fit(),
#  dependence_analysis()).
# =============================================================================

#' aus Rsolnp 1.16 (.eps)
#' @keywords internal
#' @noRd
.rsolnp_eps <- .Machine$double.eps

#' Nichtlineare Optimierung mit Nebenbedingungen (aus Rsolnp 1.16, solnp)
#' @keywords internal
#' @noRd
.rsolnp_solnp <-
function (pars, fun, eqfun = NULL, eqB = NULL, ineqfun = NULL,
    ineqLB = NULL, ineqUB = NULL, LB = NULL, UB = NULL, control = list(),
    ...)
{
    tic = Sys.time()
    xnames = names(pars)
    .solnpenv <- environment()
    assign("xnames", xnames, envir = .solnpenv)
    assign(".solnp_nfn", 0, envir = .solnpenv)
    assign(".solnp_errors", 0, envir = .solnpenv)
    ind = rep(0, 11)
    np = ind[1] = length(pars)
    check1 = .rsolnp_checkpars(pars, LB, UB, .solnpenv)
    .LB = get(".LB", envir = .solnpenv)
    .UB = get(".UB", envir = .solnpenv)
    if (!is.null(.LB) || !is.null(.UB))
        ind[10] = 1
    funv = .rsolnp_checkfun(pars, fun, .solnpenv, ...)
    .solnp_fun = get(".solnp_fun", envir = .solnpenv)
    ind[2] = 0
    .solnp_hessfun = NULL
    ind[3] = 0
    if (!is.null(ineqfun)) {
        ineqv = .rsolnp_checkineq(pars, ineqfun, ineqLB, ineqUB, .solnpenv,
            ...)
        ind[4] = 1
        nineq = length(ineqLB)
        ind[5] = nineq
        .ineqLBx = .ineqLB
        .ineqUBx = .ineqUB
        .ineqLBx[!is.finite(.ineqLB)] = -1e+10
        .ineqUBx[!is.finite(.ineqUB)] = 1e+10
        ineqx0 = (.ineqLBx + .ineqUBx)/2
        ind[6] = 0
    }
    else {
        .solnp_ineqfun = function(pars, ...) .rsolnp_emptyfun(pars,
            ...)
        ineqv = NULL
        ind[4] = 0
        nineq = 0
        ind[5] = 0
        ind[6] = 0
        ineqx0 = NULL
        .ineqLB = NULL
        .ineqUB = NULL
    }
    .solnp_ineqfun = get(".solnp_ineqfun", envir = .solnpenv)
    .ineqLB = get(".ineqLB", envir = .solnpenv)
    .ineqUB = get(".ineqUB", envir = .solnpenv)
    if (!is.null(eqfun)) {
        eqv = .rsolnp_checkeq(pars, eqfun, eqB, .solnpenv, ...)
        ind[7] = 1
        .eqB = get(".eqB", envir = .solnpenv)
        neq = length(.eqB)
        ind[8] = neq
        ind[9] = 0
    }
    else {
        eqv = NULL
        .solnp_eqfun = function(pars, ...) .rsolnp_emptyfun(pars, ...)
        ind[7] = 0
        neq = 0
        ind[8] = 0
        ind[9] = 0
    }
    .solnp_eqfun = get(".solnp_eqfun", envir = .solnpenv)
    if (ind[10] || ind[4])
        ind[11] = 1
    pb = rbind(cbind(.ineqLB, .ineqUB), cbind(.LB, .UB))
    ctrl = .rsolnp_solnpctrl(control)
    rho = ctrl[[1]]
    maxit = ctrl[[2]]
    minit = ctrl[[3]]
    delta = ctrl[[4]]
    tol = ctrl[[5]]
    trace = ctrl[[6]]
    tc = nineq + neq
    j = jh = funv
    tt = 0 * .rsolnp_ones(3, 1)
    if (tc > 0) {
        lambda = 0 * .rsolnp_ones(tc, 1)
        constraint = c(eqv, ineqv)
        if (ind[4]) {
            tmpv = cbind(constraint[(neq + 1):tc] - .ineqLB,
                .ineqUB - constraint[(neq + 1):tc])
            testmin = apply(tmpv, 1, FUN = function(x) min(x[1],
                x[2]))
            if (all(testmin > 0))
                ineqx0 = constraint[(neq + 1):tc]
            constraint[(neq + 1):tc] = constraint[(neq + 1):tc] -
                ineqx0
        }
        tt[2] = .rsolnp_vnorm(constraint)
        if (max(tt[2] - 10 * tol, nineq, na.rm = TRUE) <= 0)
            rho = 0
    }
    else {
        lambda = 0
    }
    p = c(ineqx0, pars)
    hessv = diag(np + nineq)
    mu = np
    .solnp_iter = 0
    ob = c(funv, eqv, ineqv)
    while (.solnp_iter < maxit) {
        .solnp_iter = .solnp_iter + 1
        .subnp_ctrl = c(rho, minit, delta, tol, trace)
        if (ind[7]) {
            vscale = c(ob[1], rep(1, neq) * max(abs(ob[2:(neq +
                1)])))
        }
        else {
            vscale = 1
        }
        if (!ind[11]) {
            vscale = c(vscale, p)
        }
        else {
            vscale = c(vscale, rep(1, length.out = length(p)))
        }
        vscale = apply(matrix(vscale, ncol = 1), 1, FUN = function(x) min(max(abs(x),
            tol), 1/tol))
        res = .rsolnp_subnp(pars = p, yy = lambda, ob = ob, hessv = hessv,
            lambda = mu, vscale = vscale, ctrl = .subnp_ctrl,
            .env = .solnpenv, ...)
        if (get(".solnp_errors", envir = .solnpenv) == 1) {
            maxit = .solnp_iter
        }
        p = res$p
        lambda = res$y
        hessv = res$hessv
        mu = res$lambda
        temp = p[(nineq + 1):(nineq + np)]
        funv = .rsolnp_safefunx(temp, .solnp_fun, .env = .solnpenv,
            ...)
        ctmp = get(".solnp_nfn", envir = .solnpenv)
        assign(".solnp_nfn", ctmp + 1, envir = .solnpenv)
        tempdf = cbind(temp, funv)
        if (trace) {
            .rsolnp_report(.solnp_iter, funv, temp)
        }
        eqv = .solnp_eqfun(temp, ...)
        ineqv = .solnp_ineqfun(temp, ...)
        ob = c(funv, eqv, ineqv)
        tt[1] = (j - ob[1])/max(abs(ob[1]), 1)
        j = ob[1]
        if (tc > 0) {
            constraint = ob[2:(tc + 1)]
            if (ind[4]) {
                tempv = rbind(constraint[(neq + 1):tc] - pb[1:nineq,
                  1], pb[1:nineq, 2] - constraint[(neq + 1):tc])
                if (min(tempv) > 0) {
                  p[1:nineq] = constraint[(neq + 1):tc]
                }
                constraint[(neq + 1):tc] = constraint[(neq +
                  1):tc] - p[1:nineq]
            }
            tt[3] = .rsolnp_vnorm(constraint)
            if (tt[3] < 10 * tol) {
                rho = 0
                mu = min(mu, tol)
            }
            if (tt[3] < 5 * tt[2]) {
                rho = rho/5
            }
            if (tt[3] > 10 * tt[2]) {
                rho = 5 * max(rho, sqrt(tol))
            }
            if (max(c(tol + tt[1], tt[2] - tt[3])) <= 0) {
                lambda = 0
                hessv = diag(diag(hessv))
            }
            tt[2] = tt[3]
        }
        if (.rsolnp_vnorm(c(tt[1], tt[2])) <= tol) {
            maxit = .solnp_iter
        }
        jh = c(jh, j)
    }
    if (ind[4]) {
        ineqx0 = p[1:nineq]
    }
    p = p[(nineq + 1):(nineq + np)]
    if (get(".solnp_errors", envir = .solnpenv) == 1) {
        convergence = 2
        if (trace)
            cat(paste("\nsolnp--> Solution not reliable....Problem Inverting Hessian.\n",
                sep = ""))
    }
    else {
        if (.rsolnp_vnorm(c(tt[1], tt[2])) <= tol) {
            convergence = 0
            if (trace)
                cat(paste("\nsolnp--> Completed in ", .solnp_iter,
                  " iterations\n", sep = ""))
        }
        else {
            convergence = 1
            if (trace)
                cat(paste("\nsolnp--> Exiting after maximum number of iterations\n",
                  "Tolerance not achieved\n", sep = ""))
        }
    }
    ctmp = get(".solnp_nfn", envir = .solnpenv)
    toc = Sys.time() - tic
    names(p) = xnames
    ans = list(pars = p, convergence = convergence, values = as.numeric(jh),
        lagrange = lambda, hessian = hessv, ineqx0 = ineqx0,
        nfuneval = ctmp, outer.iter = .solnp_iter, elapsed = toc,
        vscale = vscale)
    return(ans)
}

#' aus Rsolnp 1.16 (.subnp)
#' @keywords internal
#' @noRd
.rsolnp_subnp <-
function (pars, yy, ob, hessv, lambda, vscale, ctrl, .env, ...)
{
    .solnp_fun = get(".solnp_fun", envir = .env)
    .solnp_eqfun = get(".solnp_eqfun", envir = .env)
    .solnp_ineqfun = get(".solnp_ineqfun", envir = .env)
    ineqLB = get(".ineqLB", envir = .env)
    ineqUB = get(".ineqUB", envir = .env)
    LB = get(".LB", envir = .env)
    UB = get(".UB", envir = .env)
    ind = get("ind", envir = .env)
    rho = ctrl[1]
    maxit = ctrl[2]
    delta = ctrl[3]
    tol = ctrl[4]
    trace = ctrl[5]
    neq = ind[8]
    nineq = ind[5]
    np = ind[1]
    ch = 1
    alp = c(0, 0, 0)
    nc = neq + nineq
    npic = np + nineq
    p0 = pars
    pb = rbind(cbind(ineqLB, ineqUB), cbind(LB, UB))
    sob = numeric()
    ptt = matrix()
    sc = numeric()
    ob = ob/vscale[1:(nc + 1)]
    p0 = p0/vscale[(neq + 2):(nc + np + 1)]
    if (ind[11]) {
        if (!ind[10]) {
            mm = nineq
        }
        else {
            mm = npic
        }
        pb = pb/cbind(vscale[(neq + 2):(neq + mm + 1)], vscale[(neq +
            2):(neq + mm + 1)])
    }
    if (nc > 0) {
        yy = vscale[2:(nc + 1)] * yy/vscale[1]
    }
    hessv = hessv * (vscale[(neq + 2):(nc + np + 1)] %*% t(vscale[(neq +
        2):(nc + np + 1)]))/vscale[1]
    j = ob[1]
    if (ind[4]) {
        if (!ind[7]) {
            a = cbind(-diag(nineq), matrix(0, ncol = np, nrow = nineq))
        }
        else {
            a = rbind(cbind(0 * .rsolnp_ones(neq, nineq), matrix(0,
                ncol = np, nrow = neq)), cbind(-diag(nineq),
                matrix(0, ncol = np, nrow = nineq)))
        }
    }
    if (ind[7] && !ind[4]) {
        a = .rsolnp_zeros(neq, np)
    }
    if (!ind[7] && !ind[4]) {
        a = .rsolnp_zeros(1, np)
    }
    g = 0 * .rsolnp_ones(npic, 1)
    p = p0[1:npic]
    if (nc > 0) {
        constraint = ob[2:(nc + 1)]
        for (i in 1:np) {
            p0[nineq + i] = p0[nineq + i] + delta
            tmpv = p0[(nineq + 1):npic] * vscale[(nc + 2):(nc +
                np + 1)]
            funv = .rsolnp_safefunx(tmpv, .solnp_fun, .env, ...)
            eqv = .solnp_eqfun(tmpv, ...)
            ineqv = .solnp_ineqfun(tmpv, ...)
            ctmp = get(".solnp_nfn", envir = .env)
            assign(".solnp_nfn", ctmp + 1, envir = .env)
            ob = c(funv, eqv, ineqv)/vscale[1:(nc + 1)]
            g[nineq + i] = (ob[1] - j)/delta
            a[, nineq + i] = (ob[2:(nc + 1)] - constraint)/delta
            p0[nineq + i] = p0[nineq + i] - delta
        }
        if (ind[4]) {
            constraint[(neq + 1):(neq + nineq)] = constraint[(neq +
                1):(neq + nineq)] - p0[1:nineq]
        }
        if (.rsolnp_solvecond(a) > 1/.rsolnp_eps) {
            if (trace)
                .rsolnp_subnpmsg("m1")
        }
        b = a %*% p0 - constraint
        ch = -1
        alp[1] = tol - max(abs(constraint))
        if (alp[1] <= 0) {
            ch = 1
            if (!ind[11]) {
                p0 = p0 - t(a) %*% solve(a %*% t(a), constraint)
                alp[1] = 1
            }
        }
        if (alp[1] <= 0) {
            p0[npic + 1] = 1
            a = cbind(a, -constraint)
            cx = cbind(.rsolnp_zeros(1, npic), 1)
            dx = .rsolnp_ones(npic + 1, 1)
            go = 1
            minit = 0
            while (go >= tol) {
                minit = minit + 1
                gap = cbind(p0[1:mm] - pb[, 1], pb[, 2] - p0[1:mm])
                gap = t(apply(gap, 1, FUN = function(x) sort(x)))
                dx[1:mm] = gap[, 1]
                dx[npic + 1] = p0[npic + 1]
                if (!ind[10]) {
                  dx[(mm + 1):npic] = max(c(dx[1:mm], 100)) *
                    .rsolnp_ones(npic - mm, 1)
                }
                y = try(qr.solve(t(a %*% diag(as.numeric(dx),
                  length(dx), length(dx))), dx * t(cx)), silent = TRUE)
                if (inherits(y, "try-error")) {
                  p = p0 * vscale[(neq + 2):(nc + np + 1)]
                  if (nc > 0) {
                    y = 0
                  }
                  hessv = vscale[1] * hessv/(vscale[(neq + 2):(nc +
                    np + 1)] %*% t(vscale[(neq + 2):(nc + np +
                    1)]))
                  ans = list(p = p, y = y, hessv = hessv, lambda = lambda)
                  assign(".solnp_errors", 1, envir = .env)
                  return(ans)
                }
                v = dx * (dx * (t(cx) - t(a) %*% y))
                if (v[npic + 1] > 0) {
                  z = p0[npic + 1]/v[npic + 1]
                  for (i in 1:mm) {
                    if (v[i] < 0) {
                      z = min(z, -(pb[i, 2] - p0[i])/v[i])
                    }
                    else if (v[i] > 0) {
                      z = min(z, (p0[i] - pb[i, 1])/v[i])
                    }
                  }
                  if (z >= p0[npic + 1]/v[npic + 1]) {
                    p0 = p0 - z * v
                  }
                  else {
                    p0 = p0 - 0.9 * z * v
                  }
                  go = p0[npic + 1]
                  if (minit >= 10) {
                    go = 0
                  }
                }
                else {
                  go = 0
                  minit = 10
                }
            }
            if (minit >= 10) {
                if (trace)
                  .rsolnp_subnpmsg("m2")
            }
            a = matrix(a[, 1:npic], ncol = npic)
            b = a %*% p0[1:npic]
        }
    }
    p = p0[1:npic]
    y = 0
    if (ch > 0) {
        tmpv = p[(nineq + 1):npic] * vscale[(nc + 2):(nc + np +
            1)]
        funv = .rsolnp_safefunx(tmpv, .solnp_fun, .env, ...)
        eqv = .solnp_eqfun(tmpv, ...)
        ineqv = .solnp_ineqfun(tmpv, ...)
        ctmp = get(".solnp_nfn", envir = .env)
        assign(".solnp_nfn", ctmp + 1, envir = .env)
        ob = c(funv, eqv, ineqv)/vscale[1:(nc + 1)]
    }
    j = ob[1]
    if (ind[4]) {
        ob[(neq + 2):(nc + 1)] = ob[(neq + 2):(nc + 1)] - p[1:nineq]
    }
    if (nc > 0) {
        ob[2:(nc + 1)] = ob[2:(nc + 1)] - a %*% p + b
        j = ob[1] - t(yy) %*% matrix(ob[2:(nc + 1)], ncol = 1) +
            rho * .rsolnp_vnorm(ob[2:(nc + 1)])^2
    }
    minit = 0
    while (minit < maxit) {
        minit = minit + 1
        if (ch > 0) {
            for (i in 1:np) {
                p[nineq + i] = p[nineq + i] + delta
                tmpv = p[(nineq + 1):npic] * vscale[(nc + 2):(nc +
                  np + 1)]
                funv = .rsolnp_safefunx(tmpv, .solnp_fun, .env, ...)
                eqv = .solnp_eqfun(tmpv, ...)
                ineqv = .solnp_ineqfun(tmpv, ...)
                ctmp = get(".solnp_nfn", envir = .env)
                assign(".solnp_nfn", ctmp + 1, envir = .env)
                obm = c(funv, eqv, ineqv)/vscale[1:(nc + 1)]
                if (ind[4]) {
                  obm[(neq + 2):(nc + 1)] = obm[(neq + 2):(nc +
                    1)] - p[1:nineq]
                }
                if (nc > 0) {
                  obm[2:(nc + 1)] = obm[2:(nc + 1)] - a %*% p +
                    b
                  obm = obm[1] - t(yy) %*% obm[2:(nc + 1)] +
                    rho * .rsolnp_vnorm(obm[2:(nc + 1)])^2
                }
                g[nineq + i] = (obm - j)/delta
                p[nineq + i] = p[nineq + i] - delta
            }
            if (ind[4]) {
                g[1:nineq] = 0
            }
        }
        if (minit > 1) {
            yg = g - yg
            sx = p - sx
            sc[1] = t(sx) %*% hessv %*% sx
            sc[2] = t(sx) %*% yg
            if ((sc[1] * sc[2]) > 0) {
                sx = hessv %*% sx
                hessv = hessv - (sx %*% t(sx))/sc[1] + (yg %*%
                  t(yg))/sc[2]
            }
        }
        dx = 0.01 * .rsolnp_ones(npic, 1)
        if (ind[11]) {
            gap = cbind(p[1:mm] - pb[, 1], pb[, 2] - p[1:mm])
            gap = t(apply(gap, 1, FUN = function(x) sort(x)))
            gap = gap[, 1] + sqrt(.rsolnp_eps) * .rsolnp_ones(mm, 1)
            dx[1:mm, 1] = .rsolnp_ones(mm, 1)/gap
            if (!ind[10]) {
                dx[(mm + 1):npic, 1] = min(c(dx[1:mm, 1], 0.01)) *
                  .rsolnp_ones(npic - mm, 1)
            }
        }
        go = -1
        lambda = lambda/10
        while (go <= 0) {
            cz = try(chol(hessv + lambda * diag(as.numeric(dx *
                dx), length(dx), length(dx))), silent = TRUE)
            if (inherits(cz, "try-error")) {
                p = p * vscale[(neq + 2):(nc + np + 1)]
                if (nc > 0) {
                  y = 0
                }
                hessv = vscale[1] * hessv/(vscale[(neq + 2):(nc +
                  np + 1)] %*% t(vscale[(neq + 2):(nc + np +
                  1)]))
                ans = list(p = p, y = y, hessv = hessv, lambda = lambda)
                assign(".solnp_errors", 1, envir = .env)
                return(ans)
            }
            cz = try(solve(cz), silent = TRUE)
            if (inherits(cz, "try-error")) {
                p = p * vscale[(neq + 2):(nc + np + 1)]
                if (nc > 0) {
                  y = 0
                }
                hessv = vscale[1] * hessv/(vscale[(neq + 2):(nc +
                  np + 1)] %*% t(vscale[(neq + 2):(nc + np +
                  1)]))
                ans = list(p = p, y = y, hessv = hessv, lambda = lambda)
                assign(".solnp_errors", 1, envir = .env)
                return(ans)
            }
            yg = t(cz) %*% g
            if (nc == 0) {
                u = -cz %*% yg
            }
            else {
                y = try(qr.solve(t(cz) %*% t(a), yg), silent = TRUE)
                if (inherits(y, "try-error")) {
                  p = p * vscale[(neq + 2):(nc + np + 1)]
                  if (nc > 0) {
                    y = 0
                  }
                  hessv = vscale[1] * hessv/(vscale[(neq + 2):(nc +
                    np + 1)] %*% t(vscale[(neq + 2):(nc + np +
                    1)]))
                  ans = list(p = p, y = y, hessv = hessv, lambda = lambda)
                  assign(".solnp_errors", 1, envir = .env)
                  return(ans)
                }
                u = -cz %*% (yg - (t(cz) %*% t(a)) %*% y)
            }
            p0 = u[1:npic] + p
            if (!ind[11]) {
                go = 1
            }
            else {
                go = min(c(p0[1:mm] - pb[, 1], pb[, 2] - p0[1:mm]))
                lambda = 3 * lambda
            }
        }
        alp[1] = 0
        ob1 = ob
        ob2 = ob1
        sob[1] = j
        sob[2] = j
        ptt = cbind(p, p)
        alp[3] = 1
        ptt = cbind(ptt, p0)
        tmpv = ptt[(nineq + 1):npic, 3] * vscale[(nc + 2):(nc +
            np + 1)]
        funv = .rsolnp_safefunx(tmpv, .solnp_fun, .env, ...)
        eqv = .solnp_eqfun(tmpv, ...)
        ineqv = .solnp_ineqfun(tmpv, ...)
        ctmp = get(".solnp_nfn", envir = .env)
        assign(".solnp_nfn", ctmp + 1, envir = .env)
        ob3 = c(funv, eqv, ineqv)/vscale[1:(nc + 1)]
        sob[3] = ob3[1]
        if (ind[4]) {
            ob3[(neq + 2):(nc + 1)] = ob3[(neq + 2):(nc + 1)] -
                ptt[1:nineq, 3]
        }
        if (nc > 0) {
            ob3[2:(nc + 1)] = ob3[2:(nc + 1)] - a %*% ptt[, 3] +
                b
            sob[3] = ob3[1] - t(yy) %*% ob3[2:(nc + 1)] + rho *
                .rsolnp_vnorm(ob3[2:(nc + 1)])^2
        }
        go = 1
        while (go > tol) {
            alp[2] = (alp[1] + alp[3])/2
            ptt[, 2] = (1 - alp[2]) * p + alp[2] * p0
            tmpv = ptt[(nineq + 1):npic, 2] * vscale[(nc + 2):(nc +
                np + 1)]
            funv = .rsolnp_safefunx(tmpv, .solnp_fun, .env, ...)
            eqv = .solnp_eqfun(tmpv, ...)
            ineqv = .solnp_ineqfun(tmpv, ...)
            ctmp = get(".solnp_nfn", envir = .env)
            assign(".solnp_nfn", ctmp + 1, envir = .env)
            ob2 = c(funv, eqv, ineqv)/vscale[1:(nc + 1)]
            sob[2] = ob2[1]
            if (ind[4]) {
                ob2[(neq + 2):(nc + 1)] = ob2[(neq + 2):(nc +
                  1)] - ptt[1:nineq, 2]
            }
            if (nc > 0) {
                ob2[2:(nc + 1)] = ob2[2:(nc + 1)] - a %*% ptt[,
                  2] + b
                sob[2] = ob2[1] - t(yy) %*% ob2[2:(nc + 1)] +
                  rho * .rsolnp_vnorm(ob2[2:(nc + 1)])^2
            }
            obm = max(sob)
            if (obm < j) {
                obn = min(sob)
                go = tol * (obm - obn)/(j - obm)
            }
            condif1 = sob[2] >= sob[1]
            condif2 = sob[1] <= sob[3] && sob[2] < sob[1]
            condif3 = sob[2] < sob[1] && sob[1] > sob[3]
            if (condif1) {
                sob[3] = sob[2]
                ob3 = ob2
                alp[3] = alp[2]
                ptt[, 3] = ptt[, 2]
            }
            if (condif2) {
                sob[3] = sob[2]
                ob3 = ob2
                alp[3] = alp[2]
                ptt[, 3] = ptt[, 2]
            }
            if (condif3) {
                sob[1] = sob[2]
                ob1 = ob2
                alp[1] = alp[2]
                ptt[, 1] = ptt[, 2]
            }
            if (go >= tol) {
                go = alp[3] - alp[1]
            }
        }
        sx = p
        yg = g
        ch = 1
        obn = min(sob)
        if (j <= obn) {
            maxit = minit
        }
        reduce = (j - obn)/(1 + abs(j))
        if (reduce < tol) {
            maxit = minit
        }
        condif1 = sob[1] < sob[2]
        condif2 = sob[3] < sob[2] && sob[1] >= sob[2]
        condif3 = sob[1] >= sob[2] && sob[3] >= sob[2]
        if (condif1) {
            j = sob[1]
            p = ptt[, 1]
            ob = ob1
        }
        if (condif2) {
            j = sob[3]
            p = ptt[, 3]
            ob = ob3
        }
        if (condif3) {
            j = sob[2]
            p = ptt[, 2]
            ob = ob2
        }
    }
    p = p * vscale[(neq + 2):(nc + np + 1)]
    if (nc > 0) {
        y = vscale[1] * y/vscale[2:(nc + 1)]
    }
    hessv = vscale[1] * hessv/(vscale[(neq + 2):(nc + np + 1)] %*%
        t(vscale[(neq + 2):(nc + np + 1)]))
    if (reduce > tol) {
        if (trace)
            .rsolnp_subnpmsg("m3")
    }
    ans = list(p = p, y = y, hessv = hessv, lambda = lambda)
    return(ans)
}

#' aus Rsolnp 1.16 (.checkpars)
#' @keywords internal
#' @noRd
.rsolnp_checkpars <-
function (pars, LB, UB, .env)
{
    if (is.null(pars))
        stop("\nsolnp-->error: must supply starting parameters\n",
            call. = FALSE)
    if (!is.null(LB)) {
        if (length(pars) != length(LB))
            stop("\nsolnp-->error: LB length not equal to parameter length\n",
                call. = FALSE)
        if (is.null(UB))
            UB = rep(.Machine$double.xmax/2, length(LB))
    }
    else {
        LB = NULL
    }
    if (!is.null(UB)) {
        if (length(pars) != length(UB))
            stop("\nsolnp-->error: UB length not equal to parameter length\n",
                call. = FALSE)
        if (is.null(LB))
            LB = rep(-.Machine$double.xmax/2, length(UB))
    }
    else {
        UB = NULL
    }
    if (!is.null(UB) && any(LB > UB))
        stop("\nsolnp-->error: UB must be greater than LB\n",
            call. = FALSE)
    if (!is.null(UB) && any(LB == UB))
        warning("\nsolnp-->warning: Equal Lower/Upper Bounds Found. Consider\n\n\t\t\t\t\t\texcluding fixed parameters.\n",
            call. = FALSE)
    if (!is.null(LB) && !any(is.finite(LB))) {
        idx = which(!is.finite(LB))
        LB[idx] = sign(LB[idx]) * .Machine$double.xmax/2
    }
    if (!is.null(UB) && !any(is.finite(UB))) {
        idx = which(!is.finite(UB))
        UB[idx] = sign(UB[idx]) * .Machine$double.xmax/2
    }
    assign(".LB", LB, envir = .env)
    assign(".UB", UB, envir = .env)
    return(1)
}

#' aus Rsolnp 1.16 (.checkfun)
#' @keywords internal
#' @noRd
.rsolnp_checkfun <-
function (pars, fun, .env, ...)
{
    if (!is.function(fun))
        stop("\nsolnp-->error: fun does not appear to be a function\n",
            call. = FALSE)
    val = fun(pars, ...)
    if (length(val) != 1)
        stop("\nsolnp-->error: objective function returns value of length greater than 1!\n",
            call. = FALSE)
    assign(".solnp_fun", fun, envir = .env)
    ctmp = get(".solnp_nfn", envir = .env)
    assign(".solnp_nfn", ctmp + 1, envir = .env)
    return(val)
}

#' aus Rsolnp 1.16 (.checkineq)
#' @keywords internal
#' @noRd
.rsolnp_checkineq <-
function (pars, fun, ineqLB, ineqUB, .env, ...)
{
    xnames = get("xnames", envir = .env)
    val = fun(pars, ...)
    n = length(val)
    if (!is.null(ineqLB)) {
        if (length(ineqLB) != n)
            stop("\nsolnp-->error: inequality function returns vector of different length to\n\t\t\t\t\t\t\tinequality lower bounds\n",
                call. = FALSE)
    }
    else {
        stop("\nsolnp-->error: inequality function given without lower bounds\n",
            call. = FALSE)
    }
    if (!is.null(ineqUB)) {
        if (length(ineqUB) != n)
            stop("\nsolnp-->error: inequality function returns vector of different length to\n\t\t\t\t\t\t\tinequality upper bounds\n",
                call. = FALSE)
    }
    else {
        stop("\nsolnp-->error: inequality function given without upper bounds\n",
            call. = FALSE)
    }
    if (any(ineqLB > ineqUB))
        stop("\nsolnp-->error: ineqUB must be greater than ineqLB\n",
            call. = FALSE)
    assign(".ineqLB", ineqLB, envir = .env)
    assign(".ineqUB", ineqUB, envir = .env)
    .solnp_ineqfun = function(x, ...) {
        names(x) = xnames
        fun(x, ...)
    }
    assign(".solnp_ineqfun", .solnp_ineqfun, envir = .env)
    return(val)
}

#' aus Rsolnp 1.16 (.checkeq)
#' @keywords internal
#' @noRd
.rsolnp_checkeq <-
function (pars, fun, eqB, .env, ...)
{
    xnames = get("xnames", envir = .env)
    n = length(eqB)
    val = fun(pars, ...) - eqB
    if (length(val) != n)
        stop("\nsolnp-->error: equality function returns vector of different length\n\t\t\t\t\t\tto equality value\n",
            call. = FALSE)
    .eqB = eqB
    assign(".eqB", .eqB, envir = .env)
    .solnp_eqfun = function(x, ...) {
        names(x) = xnames
        fun(x, ...) - .eqB
    }
    assign(".solnp_eqfun", .solnp_eqfun, envir = .env)
    return(val)
}

#' aus Rsolnp 1.16 (.safefunx)
#' @keywords internal
#' @noRd
.rsolnp_safefunx <-
function (pars, fun, .env, ...)
{
    xnames = get("xnames", envir = .env)
    names(pars) = xnames
    v = fun(pars, ...)
    if (is.na(v) | !is.finite(v) | is.nan(v)) {
        warning(paste("\nsolnp-->warning: ", v, " detected in function call...check your function\n",
            sep = ""), immediate. = FALSE)
        v = 1e+24
    }
    v
}

#' aus Rsolnp 1.16 (.solnpctrl)
#' @keywords internal
#' @noRd
.rsolnp_solnpctrl <-
function (control)
{
    ans = list()
    params = unlist(control)
    if (is.null(params)) {
        ans$rho = 1
        ans$outer.iter = 400
        ans$inner.iter = 800
        ans$delta = 1e-07
        ans$tol = 1e-08
        ans$trace = 1
    }
    else {
        npar = tolower(names(unlist(control)))
        names(params) = npar
        if (any(substr(npar, 1, 3) == "rho"))
            ans$rho = as.numeric(params["rho"])
        else ans$rho = 1
        if (any(substr(npar, 1, 10) == "outer.iter"))
            ans$outer.iter = as.numeric(params["outer.iter"])
        else ans$outer.iter = 400
        if (any(substr(npar, 1, 10) == "inner.iter"))
            ans$inner.iter = as.numeric(params["inner.iter"])
        else ans$inner.iter = 800
        if (any(substr(npar, 1, 5) == "delta"))
            ans$delta = as.numeric(params["delta"])
        else ans$delta = 1e-07
        if (any(substr(npar, 1, 3) == "tol"))
            ans$tol = as.numeric(params["tol"])
        else ans$tol = 1e-08
        if (any(substr(npar, 1, 5) == "trace"))
            ans$trace = as.numeric(params["trace"])
        else ans$trace = 1
    }
    return(ans)
}

#' aus Rsolnp 1.16 (.vnorm)
#' @keywords internal
#' @noRd
.rsolnp_vnorm <-
function (x)
{
    sum((x)^2)^(1/2)
}

#' aus Rsolnp 1.16 (.solvecond)
#' @keywords internal
#' @noRd
.rsolnp_solvecond <-
function (x)
{
    z = svd(x)$d
    if (any(z == 0))
        ret = Inf
    else ret = max(z)/min(z)
    return(ret)
}

#' aus Rsolnp 1.16 (.subnpmsg)
#' @keywords internal
#' @noRd
.rsolnp_subnpmsg <-
function (m)
{
    g1 = c("solnp-->")
    m1 = paste("\n", g1, "Redundant constraints were found. Poor\n",
        g1, "intermediate results may result.Suggest that you\n",
        g1, "remove redundant constraints and re-OPTIMIZE\n",
        sep = "")
    m2 = paste("\n", g1, "The linearized problem has no feasible\n",
        g1, "solution.  The problem may not be feasible.\n",
        sep = "")
    m3 = paste("\n", g1, "Minor optimization routine did not converge in the \n",
        g1, "specified number of minor iterations.  You may need\n",
        g1, "to increase the number of minor iterations.        \n",
        sep = "")
    ans = switch(m, m1 = m1, m2 = m2, m3 = m3)
    cat(ans)
}

#' aus Rsolnp 1.16 (.report)
#' @keywords internal
#' @noRd
.rsolnp_report <-
function (iter, funv, pars)
{
    cat(paste("\nIter: ", iter, " fn: ", format(funv, digits = 4,
        scientific = 5, nsmall = 4, zero.print = TRUE), "\t Pars: ",
        sep = ""), format(pars, digits = 4, scientific = 6, nsmall = 5,
        zero.print = TRUE))
}

#' aus Rsolnp 1.16 (.ones)
#' @keywords internal
#' @noRd
.rsolnp_ones <-
function (n = 1, m = 1)
{
    if (missing(m))
        m = n
    sol = matrix(1, nrow = n, ncol = m)
    return(sol)
}

#' aus Rsolnp 1.16 (.zeros)
#' @keywords internal
#' @noRd
.rsolnp_zeros <-
function (n = 1, m = 1)
{
    if (missing(m))
        m = n
    sol = matrix(0, nrow = n, ncol = m)
    return(sol)
}

#' aus Rsolnp 1.16 (.emptyfun)
#' @keywords internal
#' @noRd
.rsolnp_emptyfun <-
function (pars, ...)
{
    NULL
}

#' solnp mit zufaelligen Startwerten (aus Rsolnp 1.16, gosolnp)
#' @keywords internal
#' @noRd
.rsolnp_gosolnp <-
function (pars = NULL, fixed = NULL, fun, eqfun = NULL, eqB = NULL,
    ineqfun = NULL, ineqLB = NULL, ineqUB = NULL, LB = NULL,
    UB = NULL, control = list(), distr = rep(1, length(LB)),
    distr.opt = list(), n.restarts = 1, n.sim = 20000, cluster = NULL,
    rseed = NULL, ...)
{
    if (!is.null(pars))
        gosolnp_parnames = names(pars)
    else gosolnp_parnames = NULL
    if (is.null(control$trace))
        trace = FALSE
    else trace = as.logical(control$trace)
    if (is.null(control$eval.type))
        parmethod = 1
    else parmethod = as.integer(min(abs(control$eval.type), 2))
    if (parmethod == 0)
        parmethod = 1
    control$eval.type = NULL
    if (is.null(rseed))
        rseed = as.numeric(Sys.time())
    else rseed = as.integer(rseed)
    if (is.null(LB))
        stop("\ngosolnp-->error: the function requires lower parameter bounds\n",
            call. = FALSE)
    if (is.null(UB))
        stop("\ngosolnp-->error: the function requires upper parameter bounds\n",
            call. = FALSE)
    if (!is.null(fixed) && is.null(pars))
        stop("\ngosolnp-->error: you need to provide a pars vector if using the fixed option\n",
            call. = FALSE)
    if (!is.null(pars))
        n = length(pars)
    else n = length(LB)
    np = 1:n
    if (!is.null(fixed)) {
        fixed = unique(fixed)
        if (any(is.na(match(fixed, np))))
            stop("\ngosolnp-->error: fixed indices out of bounds\n",
                call. = FALSE)
    }
    if (any(distr == 2)) {
        d2 = which(distr == 2)
        for (i in 1:length(d2)) {
            if (is.null(distr.opt[[d2[i]]]$mean))
                stop(paste("\ngosolnp-->error: distr.opt[[,",
                  d2[i], "]] missing mean\n", sep = ""), call. = FALSE)
            if (is.null(distr.opt[[d2[i]]]$sd))
                stop(paste("\ngosolnp-->error: distr.opt[[,",
                  d2[i], "]] missing sd\n", sep = ""), call. = FALSE)
        }
    }
    if (any(distr == 3)) {
        d3 = which(distr == 3)
        for (i in 1:length(d3)) {
            if (is.null(distr.opt[[d3[i]]]$mean))
                stop(paste("\ngosolnp-->error: distr.opt[[,",
                  d3[i], "]] missing mean\n", sep = ""), call. = FALSE)
            if (is.null(distr.opt[[d3[i]]]$sd))
                stop(paste("\ngosolnp-->error: distr.opt[[,",
                  d3[i], "]] missing sd\n", sep = ""), call. = FALSE)
        }
    }
    if (!is.null(cluster)) {
        # SimLev: parallele Auswertung (clusterExport, clusterEvalQ,
        # parLapply) nicht uebernommen
        stop("Rsolnp-Uebernahme: gosolnp mit cluster nicht uebernommen")
    }
    gosolnp_rndpars = switch(parmethod, .rsolnp_randpars(pars = pars,
        fixed = fixed, fun = fun, eqfun = eqfun, eqB = eqB, ineqfun = ineqfun,
        ineqLB = ineqLB, ineqUB = ineqUB, LB = LB, UB = UB, distr = distr,
        distr.opt = distr.opt, n.restarts = n.restarts, n.sim = n.sim,
        trace = trace, rseed = rseed, gosolnp_parnames = gosolnp_parnames,
        cluster = cluster, ...), stop("Rsolnp-Uebernahme: gosolnp mit control$eval.type = 2 (.randpars2) nicht uebernommen"))
    gosolnp_rndpars = gosolnp_rndpars[, 1:n, drop = FALSE]
    if (trace)
        cat("\ngosolnp-->Starting Solver\n")
    solution = vector(mode = "list", length = n.restarts)
    # SimLev: Zweig mit cluster (parLapply) nicht uebernommen
    {
        solution = lapply(as.list(1:n.restarts), FUN = function(i) {
            xx = gosolnp_rndpars[i, ]
            names(xx) = gosolnp_parnames
            ans = try(.rsolnp_solnp(pars = xx, fun = fun, eqfun = eqfun,
                eqB = eqB, ineqfun = ineqfun, ineqLB = ineqLB,
                ineqUB = ineqUB, LB = LB, UB = UB, control = control,
                ...), silent = TRUE)
            if (inherits(ans, "try-error")) {
                ans = list()
                ans$values = 1e+10
                ans$convergence = 0
                ans$pars = rep(NA, length(xx))
            }
            return(ans)
        })
    }
    if (n.restarts > 1) {
        best = sapply(solution, FUN = function(x) if (x$convergence !=
            0)
            NA
        else x$values[length(x$values)])
        if (all(is.na(best)))
            stop("\ngosolnp-->Could not find a feasible starting point...exiting\n",
                call. = FALSE)
        nb = which(best == min(best, na.rm = TRUE))[1]
        solution = solution[[nb]]
        if (trace)
            cat("\ngosolnp-->Done!\n")
        solution$start.pars = gosolnp_rndpars[nb, ]
        names(solution$start.pars) = gosolnp_parnames
        solution$rseed = rseed
    }
    else {
        solution = solution[[1]]
        solution$start.pars = gosolnp_rndpars[1, ]
        names(solution$start.pars) = gosolnp_parnames
        solution$rseed = rseed
    }
    return(solution)
}

#' aus Rsolnp 1.16 (.randpars)
#' @keywords internal
#' @noRd
.rsolnp_randpars <-
function (pars, fixed, fun, eqfun, eqB, ineqfun, ineqLB, ineqUB,
    LB, UB, distr, distr.opt, n.restarts, n.sim, trace = TRUE,
    rseed, gosolnp_parnames, cluster, ...)
{
    if (trace)
        cat("\nCalculating Random Initialization Parameters...")
    N = length(LB)
    gosolnp_rndpars = matrix(NA, ncol = N, nrow = n.sim * n.restarts)
    if (!is.null(fixed))
        for (i in 1:length(fixed)) gosolnp_rndpars[, fixed[i]] = pars[fixed[i]]
    nf = 1:N
    if (!is.null(fixed))
        nf = nf[-c(fixed)]
    m = length(nf)
    set.seed(rseed)
    for (i in 1:m) {
        j = nf[i]
        gosolnp_rndpars[, j] = switch(distr[j], .rsolnp_distr1(LB[j],
            UB[j], n.restarts * n.sim), .rsolnp_distr2(LB[j], UB[j],
            n.restarts * n.sim, mean = distr.opt[[j]]$mean, sd = distr.opt[[j]]$sd),
            .rsolnp_distr3(n.restarts * n.sim, mean = distr.opt[[j]]$mean,
                sd = distr.opt[[j]]$sd))
    }
    if (trace)
        cat("ok!\n")
    if (!is.null(ineqfun)) {
        if (trace)
            cat("\nExcluding Inequality Violations...\n")
        ineqv = matrix(NA, ncol = length(ineqLB), nrow = n.restarts *
            n.sim)
        if (length(ineqLB) == 1) {
            ineqv = apply(gosolnp_rndpars, 1, FUN = function(x) {
                names(x) = gosolnp_parnames
                ineqfun(x, ...)
            })
            lbviol = sum(ineqv < ineqLB)
            ubviol = sum(ineqv > ineqUB)
            if (lbviol > 0 | ubviol > 0) {
                vidx = c(which(ineqv < ineqLB), which(ineqv >
                  ineqUB))
                vidx = unique(vidx)
                gosolnp_rndpars = gosolnp_rndpars[-c(vidx), ,
                  drop = FALSE]
                lvx = length(vidx)
            }
            else {
                vidx = 0
                lvx = 0
            }
        }
        else {
            ineqv = t(apply(gosolnp_rndpars, 1, FUN = function(x) {
                names(x) = gosolnp_parnames
                ineqfun(x, ...)
            }))
            lbviol = apply(ineqv, 1, FUN = function(x) sum(any(x <
                ineqLB)))
            ubviol = apply(ineqv, 1, FUN = function(x) sum(any(x >
                ineqUB)))
            if (any(lbviol > 0) | any(ubviol > 0)) {
                vidx = c(which(lbviol > 0), which(ubviol > 0))
                vidx = unique(vidx)
                gosolnp_rndpars = gosolnp_rndpars[-c(vidx), ,
                  drop = FALSE]
                lvx = length(vidx)
            }
            else {
                vidx = 0
                lvx = 0
            }
        }
        if (trace)
            cat(paste("\n...Excluded ", lvx, "/", n.restarts *
                n.sim, " Random Sequences\n", sep = ""))
    }
    if (trace)
        cat("\nEvaluating Objective Function with Random Sampled Parameters...")
    if (!is.null(cluster)) {
        # SimLev: parallele Auswertung nicht uebernommen
        stop("Rsolnp-Uebernahme: gosolnp mit cluster nicht uebernommen")
    }
    else {
        evfun = apply(gosolnp_rndpars, 1, FUN = function(x) .rsolnp_safefun(x,
            fun, gosolnp_parnames, ...))
    }
    if (trace)
        cat("ok!\n")
    if (trace)
        cat("\nSorting and Choosing Best Candidates for starting Solver...")
    z = sort.int(evfun, index.return = T)
    ans = gosolnp_rndpars[z$ix[1:n.restarts], , drop = FALSE]
    prtable = cbind(ans, z$x[1:n.restarts])
    if (trace)
        cat("ok!\n")
    colnames(prtable) = c(paste("par", 1:N, sep = ""), "objf")
    if (trace) {
        cat("\nStarting Parameters and Starting Objective Function:\n")
        if (n.restarts == 1)
            print(t(prtable), digits = 4)
        else print(prtable, digits = 4)
    }
    return(prtable)
}

#' aus Rsolnp 1.16 (.safefun)
#' @keywords internal
#' @noRd
.rsolnp_safefun <-
function (pars, fun, gosolnp_parnames, ...)
{
    names(pars) = gosolnp_parnames
    v = fun(pars, ...)
    if (is.na(v) | !is.finite(v) | is.nan(v)) {
        warning(paste("\ngosolnp-->warning: ", v, " detected in function call...check your function\n",
            sep = ""), immediate. = FALSE)
        v = 1e+24
    }
    v
}

#' aus Rsolnp 1.16 (.distr1)
#' @keywords internal
#' @noRd
.rsolnp_distr1 <-
function (LB, UB, n)
{
    runif(n, min = LB, max = UB)
}

#' aus Rsolnp 1.16 (.distr2)
#' @keywords internal
#' @noRd
.rsolnp_distr2 <-
function (LB, UB, n, mean, sd)
{
    .truncnorm_rtruncnorm(n, a = as.double(LB), b = as.double(UB), mean = as.double(mean),
        sd = as.double(sd))
}

#' aus Rsolnp 1.16 (.distr3)
#' @keywords internal
#' @noRd
.rsolnp_distr3 <-
function (n, mean, sd)
{
    rnorm(n, mean = mean, sd = sd)
}
