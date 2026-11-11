/* core/slc_opt_fmin.cpp – eindimensionales Minimum nach Brent (fmin) als Frage/Antwort-Verfahren (SimLev core)
 * Verfahren:  Goldener Schnitt mit parabolischer Interpolation nach Brent (1973), Kap. 5, Prozedur localmin;
 *             Abbruch bei |x - xm| <= 2 tol1 - (b - a)/2 mit tol1 = sqrt(eps) |x| + tol/3; Rechenfolge wie
 *             R's Brent_fmin (stats::optimize), damit die Punkte und das Ergebnis bitgleich sind. Als
 *             Zustandsmaschine über ein Arbeitsfeld (sl_fmin_ask/sl_fmin_tell) wie die Optimierer in
 *             slc_opt.cpp; sl_fmin durchläuft dieselbe Schleife mit einem Funktionszeiger. Bis 1.5.2 hatten
 *             Python (_r/_optim.py) und Julia (r/_optim.jl) je eine Übertragung.
 * Quellen:    Brent, R. P. (1973). Algorithms for Minimization without Derivatives. Prentice-Hall,
 *               Englewood Cliffs, Kap. 5.
 * Konstanten: c = (3 - sqrt(5))/2 (goldener Schnitt), eps = DBL_EPSILON (vor sqrt).
 * Herkunft:           übersetzt aus R 4.3.3, src/library/stats/src/optimize.c (Brent_fmin), über die
 *                     Port-Funktionen python/simlev/_r/_optim.py und julia/src/r/_optim.jl (bis 1.5.2);
 *                     Verfahren R. P. Brent (1973) über Netlib go/fmin.f (ohne Urheber- und Lizenzvermerk)
 * Rechte:             The R Core Team, teils Robert Gentleman und Ross Ihaka, The R Foundation (laut Kopf
 *                     der R-Quelle)
 * Lizenz der Vorlage: GPL (>= 2) laut Kopf der R-Quelle; in SimLev unter GPL-3
 * Änderungen:         Zustandsmaschine (Frage/Antwort) statt Rückruf; C++ ohne R-Datenstrukturen.
 * Prüforakel: R 4.3.3 stats::optimize (Gleichlauf: copula_fuzz.R gegen R 1.5.2).
 */
#include "slc_internal.h"
#include "slc_opt.h"

#include <float.h>

/* Arbeitsfeld */
enum { F_PH = 0, F_A, F_B, F_C, F_D, F_E, F_EPS, F_TOL3, F_V, F_W, F_X, F_U, F_FV, F_FW, F_FX };
/* Phasen: 0 f(x) zu Beginn, 1 nächster Schritt, 3 f(u) erwartet, 2 fertig */

void sl_fmin_init(double *ws, double ax, double bx, double tol)
{
    double c = (3. - sqrt(5.)) * .5, eps = DBL_EPSILON;
    int i;
    for (i = 0; i < SL_FMIN_WS; i++) ws[i] = 0.0;
    eps = sqrt(eps);
    ws[F_C] = c; ws[F_EPS] = eps;
    ws[F_A] = ax; ws[F_B] = bx;
    ws[F_V] = ax + c * (bx - ax);
    ws[F_W] = ws[F_V]; ws[F_X] = ws[F_V];
    ws[F_D] = 0.; ws[F_E] = 0.;
    ws[F_TOL3] = tol / 3.;
    ws[F_PH] = 0;
}

int sl_fmin_ask(double *ws, double *x_eval)
{
    double a, b, c, d, e, x, v, w, fx, fv, fw, xm, tol1, t2, p, q, r, u;
    const int ph = (int) ws[F_PH];
    if (ph == 0) { *x_eval = ws[F_X]; return 1; }
    if (ph == 3) { *x_eval = ws[F_U]; return 1; }
    if (ph == 2) { *x_eval = ws[F_X]; return 0; }
    a = ws[F_A]; b = ws[F_B]; c = ws[F_C]; d = ws[F_D]; e = ws[F_E];
    x = ws[F_X]; v = ws[F_V]; w = ws[F_W]; fx = ws[F_FX]; fv = ws[F_FV]; fw = ws[F_FW];
    xm = (a + b) * .5;
    tol1 = ws[F_EPS] * fabs(x) + ws[F_TOL3];
    t2 = tol1 * 2.;
    /* seit 1.6.4 (B-005): auch fertig, wenn der Vergleich NaN ergibt (nicht endliche Grenzen, Intervallbreite Inf oder
     * tol = NaN); bis 1.6.3 lief die Suche dann endlos. Fuer endliche Werte wie R's Brent_fmin. */
    if (!(fabs(x - xm) > t2 - (b - a) * .5)) { ws[F_PH] = 2; *x_eval = x; return 0; }
    p = 0.; q = 0.; r = 0.;
    if (fabs(e) > tol1) {                          /* Parabel durch x, v, w */
        r = (x - w) * (fx - fv);
        q = (x - v) * (fx - fw);
        p = (x - v) * q - (x - w) * r;
        q = (q - r) * 2.;
        if (q > 0.) p = -p; else q = -q;
        r = e;
        e = d;
    }
    if (fabs(p) >= fabs(q * .5 * r) || p <= q * (a - x) || p >= q * (b - x)) {
        if (x < xm) e = b - x; else e = a - x;     /* goldener Schnitt */
        d = c * e;
    } else {
        d = p / q;                                 /* Parabelschritt */
        u = x + d;
        if (u - a < t2 || b - u < t2) {
            d = tol1;
            if (x >= xm) d = -d;
        }
    }
    if (fabs(d) >= tol1) u = x + d;
    else if (d > 0.) u = x + tol1;
    else u = x - tol1;
    ws[F_D] = d; ws[F_E] = e; ws[F_U] = u; ws[F_PH] = 3;
    *x_eval = u;
    return 1;
}

void sl_fmin_tell(double *ws, double f)
{
    const int ph = (int) ws[F_PH];
    double a, b, x, v, w, u, fx, fv, fw, fu;
    if (ph == 0) { ws[F_FX] = f; ws[F_FV] = f; ws[F_FW] = f; ws[F_PH] = 1; return; }
    if (ph != 3) return;
    a = ws[F_A]; b = ws[F_B]; x = ws[F_X]; v = ws[F_V]; w = ws[F_W]; u = ws[F_U];
    fx = ws[F_FX]; fv = ws[F_FV]; fw = ws[F_FW]; fu = f;
    if (fu <= fx) {
        if (u < x) b = x; else a = x;
        v = w; w = x; x = u;
        fv = fw; fw = fx; fx = fu;
    } else {
        if (u < x) a = u; else b = u;
        if (fu <= fw || w == x) {
            v = w; fv = fw;
            w = u; fw = fu;
        } else if (fu <= fv || v == x || v == w) {
            v = u; fv = fu;
        }
    }
    ws[F_A] = a; ws[F_B] = b; ws[F_X] = x; ws[F_V] = v; ws[F_W] = w;
    ws[F_FX] = fx; ws[F_FV] = fv; ws[F_FW] = fw; ws[F_PH] = 1;
}

double sl_fmin(double ax, double bx, sl_fn1 f, void *data, double tol)
{
    double ws[SL_FMIN_WS], x;
    sl_fmin_init(ws, ax, bx, tol);
    while (sl_fmin_ask(ws, &x)) sl_fmin_tell(ws, f(x, data));
    return x;
}
