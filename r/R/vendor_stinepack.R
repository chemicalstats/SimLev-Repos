# =============================================================================
#  vendor_stinepack.R  —  uebernommene Teile des R-Pakets stinepack
# -----------------------------------------------------------------------------
#  Paket:     stinepack 1.5 (CRAN, 2024-03-07), Dateien R/stinterp.R,
#             R/stinemanSlopes.R und R/parabolaSlopes.R
#  Autoren:   Tomas Johannesson & Halldor Bjornsson, Icelandic Met. Office;
#             Gabor Grothendieck
#  Lizenz:    GPL (>= 2); in SimLev unter GPL-3 weitergegeben
#  Angepasst fuer SimLev (siehe inst/COPYRIGHTS):
#    * stinterp(), stinemanSlopes() und parabolaSlopes() als interne
#      Funktionen .stinepack_stinterp(), .stinepack_stinemanSlopes() und
#      .stinepack_parabolaSlopes(); die Funktionsruempfe sind unveraendert
#      bis auf die Aufrufe der Steigungen unter ihren neuen Namen
#    * na.stinterp() ist nicht uebernommen
#  Genutzt von .imputets_na_interpolation(option = "stine")
#  (R/vendor_imputets.R) und damit von .fill_na().
# =============================================================================

#' Stineman-Interpolation (aus stinepack 1.5, stinterp)
#' @keywords internal
#' @noRd
".stinepack_stinterp" <-
function (x, y, xout, yp, method = c("scaledstineman", "stineman", 
    "parabola")) 
{
    if (missing(x) || missing(y) || missing(xout)) 
        stop("Wrong number of input arguments, x, y and xout must be specified")
    if (!is.vector(x) || !is.vector(y) || !is.vector(xout) || 
        !is.numeric(x) || !is.numeric(y) || !is.numeric(xout)) 
        stop("x, y and xout must be numeric vectors")
    if (length(x) < 2) 
        stop("x must have 2 or more elements")
    if (length(x) != length(y)) 
        stop("x must have the same number of elements as y")
    if (any(is.na(x)) || any(is.na(x)) || any(is.na(xout))) 
        stop("NAs in x, y or xout are not allowed")
    if (!missing(yp)) {
        if (!is.vector(yp) || !is.numeric(yp)) 
            stop("yp must be a numeric vector")
        if (length(y) != length(yp)) 
            stop("When specified, yp must have the same number of elements as y")
        if (any(is.na(yp)))
           stop("NAs in yp are not allowed")
        if (!missing(method)) 
            stop("Method should not be specified if yp is given")
    }
    dx <- diff(x)
    dy <- diff(y)
    if (any(dx <= 0)) 
        stop("The values of x must strictly increasing")

#calculation of slopes if needed
    if (missing(yp)) {
        yp <- switch(match.arg(method), # this allows for partial argument matching 
               scaledstineman = .stinepack_stinemanSlopes(x,y, scale = TRUE), 
               stineman = .stinepack_stinemanSlopes(x, y, scale = FALSE), 
               parabola = .stinepack_parabolaSlopes(x, y))
    }

# preparations
    m <- length(x)
    m1 <- m - 1
    s <- dy/dx
    k <- length(xout)

    ix <- findInterval(xout, x, rightmost.closed = TRUE)

# For edgepoints allow extrapolation 
# within a tiny range (set by machine precision).

    epx <- 5 * (.Machine$double.eps) * diff(range(x))
    ix[min(x) - epx <= xout & xout <= min(x)] <- 1
    ix[max(x) <= xout & xout <= max(x) + epx] <- m1
    idx <- 1 <= ix & ix <= m1
    ix1 <- ix[idx]
    ix2 <- ix1 + 1

# computation of the interpolant for the three cases dyo1dyo2 ==, > and < 0

    dxo1 <- xout[idx] - x[ix1]
    dxo2 <- xout[idx] - x[ix2]
    y0o <- y[ix1] + s[ix1] * dxo1
    dyo1 <- (yp[ix1] - s[ix1]) * dxo1
    dyo2 <- (yp[ix2] - s[ix1]) * dxo2
    dyo1dyo2 <- dyo1 * dyo2
    yo <- y0o
    if (m > 2 || !missing(yp)) { # linear interpolation is sufficient for m=2 unless slopes are given, then nothing more is done
        id <- dyo1dyo2 > 0
        yo[id] <- y0o[id] + dyo1dyo2[id]/(dyo1[id] + dyo2[id])
        id <- dyo1dyo2 < 0
        yo[id] <- y0o[id] + dyo1dyo2[id] * (dxo1[id] + dxo2[id])/(dyo1[id] - 
            dyo2[id])/((dx[ix1])[id])
    }

# return the results

    yout <- rep(NA, k)
    yout[idx] <- yo
    list(x = xout, y = yout)
}

#' Steigungen nach Stineman (aus stinepack 1.5, stinemanSlopes)
#' @keywords internal
#' @noRd
".stinepack_stinemanSlopes" <-
function (x, y, scale = FALSE) 
{
    m <- length(x)
    m1 <- m - 1
    if (m == 2) {
        yp <- rep(diff(y)/diff(x), 2)
    }
    else {
        if (scale) {
            sx <- diff(range(x))
            sy <- diff(range(y))
            if (sy <= 0) 
                sy <- 1
            x <- x/sx
            y <- y/sy
        }
        dx <- diff(x)
        dy <- diff(y)
        yp <- rep(NA, m)
        dx2dy2p <- dx[-1]^2 + dy[-1]^2
        dx2dy2m <- dx[-m1]^2 + dy[-m1]^2
        yp[2:m1] <- (dy[-m1] * dx2dy2p + dy[-1] * dx2dy2m)/(dx[-m1] * 
            dx2dy2p + dx[-1] * dx2dy2m)
        s <- dy[1]/dx[1]
        if ((s >= 0 && s >= yp[2]) || (s <= 0 && s <= yp[2])) 
            yp[1] <- 2 * s - yp[2]
        else yp[1] <- s + abs(s) * (s - yp[2])/(abs(s) + abs(s - 
            yp[2]))
        s <- dy[m1]/dx[m1]
        if ((s >= 0 && s >= yp[m1]) || (s <= 0 && s <= yp[m1])) 
            yp[m] <- 2 * s - yp[m1]
        else yp[m] <- s + abs(s) * (s - yp[m1])/(abs(s) + abs(s - 
            yp[m1]))
        if (scale) 
            yp <- yp * sy/sx
    }
    yp
}

#' Steigungen ueber Parabeln (aus stinepack 1.5, parabolaSlopes)
#' @keywords internal
#' @noRd
".stinepack_parabolaSlopes" <-
function (x, y) 
{
    m <- length(x)
    m1 <- m - 1
    dx <- diff(x)
    dy <- diff(y)
    dydx = dy/dx
    if (m == 2) {
        yp <- rep(dydx, 2)
    } else {
        yp <- c((dydx[1]*(2*dx[1]+dx[2])-dydx[2]*dx[1])/(dx[1]+dx[2]),
        (dydx[-m1]*dx[-1] + dydx[-1]*dx[-m1])/(dx[-1] + dx[-m1]),
        (dydx[m1]*(2*dx[m1]+dx[m1-1])-dydx[m1-1]*dx[m1])/(dx[m1]+dx[m1-1]))
    }
    yp
}
