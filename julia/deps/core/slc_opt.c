/* core/slc_opt.c – Optimierer BFGS, projizierter BFGS, Nelder-Mead; numerischer Gradient
 *                  (SimLev core, Etappe 9.3)
 * Verfahren:  BFGS (SL_OPT_BFGS): Quasi-Newton auf der inversen Hesse-Matrix H, Richtung p = -H g,
 *             H_0 = I und vor der ersten Aufdatierung H = (y's / y'y) I; Aufdatierung nach der
 *             inversen BFGS-Formel, ausgelassen bei y's <= 1e-10 ||s|| ||y||. Liniensuche mit den
 *             starken Wolfe-Bedingungen (c1 = 1e-4, c2 = 0.9): Klammern mit Verdoppeln, dann
 *             Zoomen mit kubischer (beide Ableitungen bekannt) bzw. quadratischer Interpolation
 *             (sonst), auf das innere 80 % des Intervalls beschränkt, bei nicht endlichem Wert
 *             Halbierung. Die Ableitung entlang p wird nur abgefragt, wenn die Abnahmebedingung
 *             gilt. Startschritt 1, in der ersten Iteration min(1, 1/||g||_inf).
 *             Projizierter BFGS (SL_OPT_PBFGS) für l <= x <= u: Start in den Kasten projiziert;
 *             eps-aktive Menge A = {i: x_i - l_i <= eps_k und g_i > 0, oder u_i - x_i <= eps_k und
 *             g_i < 0} mit eps_k = min(1e-3, ||x - P(x - g)||_inf); Richtung d_A = -g_A,
 *             d_F = -(B_FF)^-1 g_F mit der Hesse-Näherung B (BFGS-Formel, Cholesky-Zerlegung des
 *             freien Blocks); Armijo-Suche entlang des projizierten Bogens x(a) = P(x + a d) mit
 *             f(x(a)) <= f(x) - c1 g'(x - x(a)) (g'(x - x(a)) > 0 verlangt), Rückschritt über
 *             quadratische Interpolation auf [0.1 a, 0.5 a]; gilt die Abnahme, aber nicht die
 *             Krümmungsbedingung g(x(a))'(x(a) - x) >= c2 g(x)'(x(a) - x), wird der Schritt
 *             verdoppelt, solange f weiter fällt (eigene Ergänzung nach dem Klammern in N&W
 *             Alg. 3.5; ohne sie bleibt der Schritt bei stark überschätzter Krümmung zu kurz).
 *             Die Hesse-Näherung wird mit dem vollen Schritt s und y aufdatiert.
 *             Nelder-Mead (SL_OPT_NM): Spiegeln, Strecken, äußeres und inneres Zusammenziehen,
 *             Schrumpfen mit rho = 1, chi = 2, gamma = 1/2, sigma = 1/2; Ordnung nach
 *             Funktionswert, bei Gleichstand bleibt die ältere Ecke vorn (die neue Ecke kommt
 *             hinter alle Ecken mit gleichem Wert; beim Schrumpfen bleibt x_1 vorn).
 *             Startsimplex x_0 + delta_i e_i mit delta_i = 0.1 max(|x_0i|, 1) (eigene Wahl).
 *             Numerischer Gradient (B.9): zentrale Differenzen mit h_i = eps^(1/3) max(|x_i|, 1);
 *             reicht der Kasten nicht, einseitig mit h_i = eps^(1/2) max(|x_i|, 1) zur
 *             zulässigen Seite (ist das Intervall noch schmaler: Differenz über seine Enden;
 *             l_i = u_i: 0). Geteilt wird durch die tatsächlich dargestellte Differenz der
 *             Stützstellen. Ist eine Seite nicht endlich, gilt die andere einseitig.
 *             Gemeinsam: Abbruch nach relativer Abnahme, Gradientennorm, Schritt, maxit bzw.
 *             maxfev; Skalierung z = x / parscale, f / fnscale; nicht endliche Werte zählen als
 *             +Inf; Rückfrage an den Host über ein Arbeitsfeld (Zustandsmaschine; jede
 *             Anfrage ist ein Wiederaufsetzpunkt), sl_minimize durchläuft dieselbe Schleife.
 * Quellen:    Nocedal, J., Wright, S. J. (2006). Numerical Optimization, 2. Aufl., Springer,
 *               New York. Kap. 3.1 (Wolfe-Bedingungen, Gl. 3.7), Kap. 3.5 (Algorithmus 3.5
 *               Liniensuche, Algorithmus 3.6 Zoom, Interpolation Gl. 3.58 und 3.59),
 *               Kap. 6.1 (Algorithmus 6.1 BFGS, inverse Aufdatierung Gl. 6.17, Startskalierung
 *               Gl. 6.20, Wahl c1 = 1e-4 und c2 = 0.9), Kap. 8.1 (Differenzenschritte, Gl. 8.6
 *               einseitig mit sqrt(eps), zentral mit eps^(1/3)).
 *             Bertsekas, D. P. (1982). Projected Newton methods for optimization problems with
 *               simple constraints. SIAM Journal on Control and Optimization 20(2), 221–246
 *               (eps-aktive Menge, Abnahme entlang des projizierten Bogens).
 *             Kelley, C. T. (1999). Iterative Methods for Optimization. SIAM.
 *               Kap. 5.4–5.5 (projizierte Newton- und BFGS-Verfahren,
 *               Abbruch über ||x - P(x - g)||).
 *             Nelder, J. A., Mead, R. (1965). A simplex method for function minimization. The
 *               Computer Journal 7(4), 308–313.
 *             Lagarias, J. C., Reeds, J. A., Wright, M. H., Wright, P. E. (1998). Convergence
 *               properties of the Nelder–Mead simplex method in low dimensions. SIAM Journal on
 *               Optimization 9(1), 112–147. Abschnitt 2 (Koeffizienten, Schritte und
 *               Ordnungsregeln bei Gleichstand).
 *             Gill, P. E., Murray, W., Wright, M. H. (1981). Practical Optimization. Academic
 *               Press, London. Abschnitt 8.6 (Wahl der Differenzenschritte; Schritt als
 *               Differenz dargestellter Zahlen).
 * Konstanten: eps = 2^-52; sqrt(eps) = 2^-26 (exakt); eps^(1/3) = 2^(-52/3) =
 *             6.0554544523933395e-06 (selbst gerechnet, Python decimal mit 40 Stellen, auf
 *             double gerundet). Verfahrensparameter aus den Quellen: c1 = 1e-4, c2 = 0.9
 *             (Nocedal/Wright Kap. 3.1, 6.1); rho, chi, gamma, sigma (Lagarias u. a. 1998, Gl. 2.1).
 *             Eigene, dokumentierte Wahl: Verdoppeln beim Klammern, höchstens 40 Versuche je
 *             Liniensuche, Schranke 1e-3 der eps-aktiven Menge, Startsimplex 0.1 max(|x|, 1),
 *             Auslassregel 1e-10 (SPEZ-9 B.8).
 * Reinraum:   geschrieben nur nach den genannten Quellen; kein Code und keine
 *             Koeffizienten aus R, Netlib, ACM- oder RSS-Algorithmen oder Paketen.
 * Prüforakel: R 4.3.3 optim (Nelder-Mead, BFGS, L-BFGS-B) als Black Box; scratchpad/e93/.
 */
#include "slc_internal.h"
#include "slc_opt.h"

#include <float.h>
#include <stdlib.h>
#include <string.h>

/* ── Verfahrensparameter ───────────────────────────────────────────────── */

#define OPT_EPS      2.220446049250313080847e-16   /* 2^-52 */
#define OPT_SQRTEPS  1.4901161193847656e-08        /* 2^-26 */
#define OPT_CBRTEPS  6.0554544523933395e-06        /* 2^(-52/3) */
#define WOLFE_C1     1e-4
#define WOLFE_C2     0.9
#define LS_EXPAND    2.0
#define LS_MAX       40
#define SKIP_TOL     1e-10
#define ACTIVE_EPS0  1e-3
#define NM_RHO       1.0
#define NM_CHI       2.0
#define NM_GAMMA     0.5
#define NM_SIGMA     0.5
#define NM_DELTA     0.1
#define WS_MAGIC     930317.0

/* ── Arbeitsfeld: Kopf (Skalare, ganze Zahlen exakt als double) und Vektoren ─ */

enum {
    H_MAGIC, H_METHOD, H_N, H_HAVEG, H_PC, H_NEED, H_STATUS, H_DONE,
    H_ITER, H_NFEV, H_NGEV, H_NTOT, H_MAXIT, H_MAXFEV, H_RELTOL, H_GTOL, H_XTOL, H_FNSCALE,
    H_CODE, H_REASON, H_HAVEB, H_FB, H_FBRAW,
    H_F, H_LASTF, H_LASTGOK,
    H_GRON, H_GRI, H_GRST, H_GRFZ, H_GRFP, H_GRFM,
    H_A, H_F0, H_D0, H_ALO, H_FLO, H_DLO, H_AHI, H_FHI, H_DHI, H_HDHI,
    H_APREV, H_FPREV, H_DPREV, H_LSN, H_LSI, H_FA, H_DA, H_FIRST, H_ISID, H_RETRY,
    H_NMJ, H_NMFR, H_NMFX, H_EXT, H_FSAV,
    H_SIZE = 64
};

typedef struct {
    double *h;
    int n;
    double *x, *g, *xt, *gt, *p, *lo, *hi, *lou, *hiu, *ps, *xe, *xb, *glo, *gz, *wk, *xc, *xr, *xx;
    double *m, *ch, *sim, *fs;
} W;

#define NVEC 18

static int64_t ws_len(int64_t n)
{
    return (int64_t) H_SIZE + NVEC * n + 2 * n * n + (n + 1) * n + (n + 1);
}

static void bind(W *w, double *ws)
{
    int64_t n = (int64_t) ws[H_N];
    double *q = ws + H_SIZE;
    w->h = ws;
    w->n = (int) n;
    w->x = q; q += n;   w->g = q; q += n;   w->xt = q; q += n;  w->gt = q; q += n;
    w->p = q; q += n;   w->lo = q; q += n;  w->hi = q; q += n;  w->lou = q; q += n;
    w->hiu = q; q += n; w->ps = q; q += n;  w->xe = q; q += n;  w->xb = q; q += n;
    w->glo = q; q += n; w->gz = q; q += n;  w->wk = q; q += n;  w->xc = q; q += n;
    w->xr = q; q += n;  w->xx = q; q += n;
    w->m = q; q += n * n; w->ch = q; q += n * n;
    w->sim = q; q += (n + 1) * n; w->fs = q;
}

#define HI_(k) ((int) w->h[k])

/* ── kleine Hilfen ───────────────────────────────────────────────────────── */

static double clamp(double v, double lo, double hi) { return v < lo ? lo : (v > hi ? hi : v); }

static double norm_inf(int n, const double *v)
{
    double m = 0.0;
    int i;
    for (i = 0; i < n; i++) if (fabs(v[i]) > m) m = fabs(v[i]);
    return m;
}

static double dot(int n, const double *a, const double *b)
{
    double s = 0.0;
    int i;
    for (i = 0; i < n; i++) s += a[i] * b[i];
    return s;
}

static int all_finite(int n, const double *v)
{
    int i;
    for (i = 0; i < n; i++) if (!isfinite(v[i])) return 0;
    return 1;
}

static void set_identity(int n, double *m, double d)
{
    int i;
    for (i = 0; i < n * n; i++) m[i] = 0.0;
    for (i = 0; i < n; i++) m[i + (int64_t) i * n] = d;
}

/* Auswertungspunkt des Hosts aus z: x = z * parscale, in den ungeskalierten Kasten gelegt */
static void eval_point(const W *w, const double *z, double *out)
{
    int i;
    for (i = 0; i < w->n; i++) out[i] = clamp(z[i] * w->ps[i], w->lou[i], w->hiu[i]);
}

const char *sl_opt_method_name(int method)
{
    switch (method) {
    case SL_OPT_BFGS: return "BFGS";
    case SL_OPT_PBFGS: return "PBFGS";
    case SL_OPT_NM: return "Nelder-Mead";
    default: return "Optimierer";
    }
}

const char *sl_opt_message(int reason)
{
    switch (reason) {
    case SL_WHY_NONE: return "läuft";
    case SL_WHY_RELTOL: return "konvergiert: relative Abnahme von f höchstens reltol";
    case SL_WHY_GTOL: return "konvergiert: Norm des projizierten Gradienten höchstens gtol";
    case SL_WHY_XTOL: return "konvergiert: Schritt höchstens xtol";
    case SL_WHY_MAXIT: return "maxit erreicht";
    case SL_WHY_MAXFEV: return "Höchstzahl der Funktionsauswertungen (maxfev) erreicht";
    case SL_WHY_LSFAIL: return "Liniensuche ohne Fortschritt";
    case SL_WHY_DEGEN: return "Simplex entartet";
    case SL_WHY_ERROR: return "Fehler";
    default: return "unbekannt";
    }
}

void sl_opt_ctrl_default(sl_opt_ctrl *c, int method)
{
    c->maxit = (method == SL_OPT_NM) ? 0 : 100;
    c->maxfev = (method == SL_OPT_NM) ? 500 : 0;
    c->reltol = OPT_SQRTEPS;
    c->gtol = 1e-8;
    c->xtol = OPT_EPS;
    c->fnscale = 1.0;
    c->parscale = NULL;
    c->trace = 0;
}

int64_t sl_opt_wsize(int method, int n)
{
    if (method < SL_OPT_BFGS || method > SL_OPT_NM || n < 1 || n > 46340) return -1;
    return ws_len(n);
}

/* ── Ende, Fehler ────────────────────────────────────────────────────────── */

static int finish(W *w, int code, int reason)
{
    w->h[H_DONE] = 1;
    w->h[H_CODE] = code;
    w->h[H_REASON] = reason;
    w->h[H_NEED] = SL_DONE;
    w->h[H_PC] = -1;
    return 0;
}

static int fail(sl_ctx *cx, W *w, int st, const char *what)
{
    sl_fail(cx, st, "%s: %s", sl_opt_method_name(HI_(H_METHOD)), what);
    w->h[H_STATUS] = st;
    finish(w, SL_OPT_MAXIT, SL_WHY_ERROR);
    return 0;
}

static int interrupted(sl_ctx *cx, W *w)
{
    if (sl_interrupted(cx)) {
        w->h[H_STATUS] = SL_EINTR;
        finish(w, SL_OPT_MAXIT, SL_WHY_ERROR);
        return 1;
    }
    return 0;
}

/* ── numerischer Gradient (B.9) ──────────────────────────────────────────── */

enum { FD_ZERO = 0, FD_CENTRAL = 1, FD_FORWARD = 2, FD_BACKWARD = 3, FD_ENDS = 4 };

/* Stützstellen für Komponente mit Wert z im Intervall [lo, hi] (geskaliert) */
static int fd_plan(double z, double lo, double hi, double *zp, double *zm)
{
    double h, h1;
    *zp = z; *zm = z;
    if (!(hi > lo)) return FD_ZERO;
    h = OPT_CBRTEPS * fmax(fabs(z), 1.0);
    if (z + h <= hi && z - h >= lo) { *zp = z + h; *zm = z - h; return FD_CENTRAL; }
    h1 = OPT_SQRTEPS * fmax(fabs(z), 1.0);
    if (z + h1 <= hi) { *zp = z + h1; return FD_FORWARD; }
    if (z - h1 >= lo) { *zm = z - h1; return FD_BACKWARD; }
    *zp = hi; *zm = lo;
    return FD_ENDS;
}

static int fd_need_p(int kind, double z, double zp) { return kind == FD_CENTRAL || kind == FD_FORWARD || (kind == FD_ENDS && zp != z); }
static int fd_need_m(int kind, double z, double zm) { return kind == FD_CENTRAL || kind == FD_BACKWARD || (kind == FD_ENDS && zm != z); }

/* Differenzenquotient; Funktionswerte sind endlich oder +Inf */
static double fd_combine(int kind, double z, double zp, double zm, double fz, double fp, double fm)
{
    switch (kind) {
    case FD_CENTRAL:
        if (isfinite(fp) && isfinite(fm)) return (fp - fm) / (zp - zm);
        if (isfinite(fp)) return (fp - fz) / (zp - z);
        if (isfinite(fm)) return (fz - fm) / (z - zm);
        return NAN;
    case FD_FORWARD:
        return isfinite(fp) ? (fp - fz) / (zp - z) : NAN;
    case FD_BACKWARD:
        return isfinite(fm) ? (fz - fm) / (z - zm) : NAN;
    case FD_ENDS:
        if (zp == z) fp = fz;
        if (zm == z) fm = fz;
        return (isfinite(fp) && isfinite(fm)) ? (fp - fm) / (zp - zm) : NAN;
    default:
        return 0.0;
    }
}

static double fin_or_inf(double v) { return isfinite(v) ? v : INFINITY; }

/* nächste Stützstelle anfragen (1) oder Gradient fertig in gt (0) */
static int gr_next(W *w)
{
    int n = w->n, i, st, kind;
    double zp, zm, z;
    for (;;) {
        i = HI_(H_GRI);
        if (i >= n) {
            w->h[H_GRON] = 0;
            w->h[H_NGEV] += 1;
            w->h[H_LASTGOK] = all_finite(n, w->gt);
            return 0;
        }
        st = HI_(H_GRST);
        z = w->gz[i];
        kind = fd_plan(z, w->lo[i], w->hi[i], &zp, &zm);
        if (st == 0) {
            if (fd_need_p(kind, z, zp)) {
                memcpy(w->xe, w->gz, (size_t) n * sizeof(double));
                w->xe[i] = zp;
                w->h[H_NEED] = SL_NEED_F;
                return 1;
            }
            w->h[H_GRFP] = w->h[H_GRFZ];
            st = 1;
        }
        if (st == 1) {
            if (fd_need_m(kind, z, zm)) {
                memcpy(w->xe, w->gz, (size_t) n * sizeof(double));
                w->xe[i] = zm;
                w->h[H_NEED] = SL_NEED_F;
                w->h[H_GRST] = 1;
                return 1;
            }
            w->h[H_GRFM] = w->h[H_GRFZ];
        }
        w->gt[i] = fd_combine(kind, z, zp, zm, w->h[H_GRFZ], w->h[H_GRFP], w->h[H_GRFM]);
        w->h[H_GRI] = i + 1;
        w->h[H_GRST] = 0;
    }
}

static int gr_feed(W *w, double v)
{
    if (HI_(H_GRST) == 0) { w->h[H_GRFP] = v; w->h[H_GRST] = 1; }
    else { w->h[H_GRFM] = v; w->h[H_GRST] = 2; }
    if (HI_(H_GRST) == 2) {
        /* beide Werte da: zusammensetzen über gr_next (Stufe 2 heißt fertig) */
        int i = HI_(H_GRI), kind;
        double zp, zm, z = w->gz[i];
        kind = fd_plan(z, w->lo[i], w->hi[i], &zp, &zm);
        w->gt[i] = fd_combine(kind, z, zp, zm, w->h[H_GRFZ], w->h[H_GRFP], w->h[H_GRFM]);
        w->h[H_GRI] = i + 1;
        w->h[H_GRST] = 0;
    }
    return gr_next(w);
}

/* ── Anfragen der Verfahren ──────────────────────────────────────────────── */

/* f an z anfragen; -1, wenn maxfev erreicht ist */
static int req_f(W *w, const double *z)
{
    if (HI_(H_MAXFEV) > 0 && HI_(H_NFEV) >= HI_(H_MAXFEV)) return -1;
    if (z != w->xe) memcpy(w->xe, z, (size_t) w->n * sizeof(double));
    w->h[H_NEED] = SL_NEED_F;
    return 1;
}

/* Gradient an z (f(z) = fz bekannt) nach gt; 1 = Anfrage offen, 0 = sofort fertig */
static int req_g(W *w, const double *z, double fz)
{
    if (HI_(H_HAVEG)) {
        memcpy(w->xe, z, (size_t) w->n * sizeof(double));
        w->h[H_NEED] = SL_NEED_G;
        return 1;
    }
    memcpy(w->gz, z, (size_t) w->n * sizeof(double));
    w->h[H_GRFZ] = fz;
    w->h[H_GRI] = 0;
    w->h[H_GRST] = 0;
    w->h[H_GRON] = 1;
    return gr_next(w);
}

/* Protothread-Gerüst: jede Anfrage ist ein Wiederaufsetzpunkt (Nummer k) */
#define PT_BEGIN switch (HI_(H_PC)) { case 0:
#define PT_END default: break; }
#define YIELD(k) do { w->h[H_PC] = (k); return 1; case (k):; } while (0)
#define ASK_F(k, z) do { if (req_f(w, (z)) < 0) goto out_maxfev; YIELD(k); } while (0)
#define ASK_G(k, z, fz) do { if (req_g(w, (z), (fz))) { YIELD(k); } } while (0)

/* ── BFGS (Nocedal/Wright Alg. 6.1 mit Alg. 3.5/3.6) ─────────────────────── */

/* Zoom-Schritt: Interpolation im Intervall (lo, hi), gesichert */
static double zoom_trial(const W *w)
{
    double alo = w->h[H_ALO], flo = w->h[H_FLO], dlo = w->h[H_DLO];
    double ahi = w->h[H_AHI], fhi = w->h[H_FHI], dhi = w->h[H_DHI];
    double del = ahi - alo, a = NAN, d1, d2, rad, den, lb, ub, t;
    if (isfinite(fhi)) {
        if (HI_(H_HDHI)) {                       /* kubisch (N&W Gl. 3.59) */
            d1 = dlo + dhi - 3.0 * (flo - fhi) / (alo - ahi);
            rad = d1 * d1 - dlo * dhi;
            if (rad >= 0.0) {
                d2 = (ahi > alo ? 1.0 : -1.0) * sqrt(rad);
                den = dhi - dlo + 2.0 * d2;
                if (den != 0.0) a = ahi - del * (dhi + d2 - d1) / den;
            }
        } else {                                 /* quadratisch aus f(lo), f'(lo), f(hi) (N&W Gl. 3.58) */
            den = 2.0 * (fhi - flo - dlo * del);
            if (den > 0.0) a = alo - dlo * del * del / den;
        }
    }
    lb = alo + 0.1 * del;
    ub = ahi - 0.1 * del;
    if (lb > ub) { t = lb; lb = ub; ub = t; }
    if (!isfinite(a) || !((a > alo && a < ahi) || (a < alo && a > ahi))) return alo + 0.5 * del;
    return clamp(a, lb, ub);
}

static void bfgs_direction(W *w)
{
    int n = w->n, i, j;
    for (i = 0; i < n; i++) {
        double s = 0.0;
        for (j = 0; j < n; j++) s += w->m[i + (int64_t) j * n] * w->g[j];
        w->p[i] = -s;
    }
}

/* s = xt - x, y = gt - g (in wk bzw. xc); erste Skalierung und inverse Aufdatierung (Gl. 6.17) */
static void bfgs_update(W *w)
{
    int n = w->n, i, j;
    double *s = w->wk, *y = w->xc, *hy = w->xr, sy, yy, ss, rho, yhy;
    for (i = 0; i < n; i++) { s[i] = w->xt[i] - w->x[i]; y[i] = w->gt[i] - w->g[i]; }
    sy = dot(n, s, y); yy = dot(n, y, y); ss = dot(n, s, s);
    if (HI_(H_FIRST)) {
        if (sy > 0.0 && yy > 0.0) set_identity(n, w->m, sy / yy);   /* Gl. 6.20 */
        w->h[H_FIRST] = 0;
    }
    if (!(sy > SKIP_TOL * sqrt(ss) * sqrt(yy))) return;
    rho = 1.0 / sy;
    for (i = 0; i < n; i++) {
        double t = 0.0;
        for (j = 0; j < n; j++) t += w->m[i + (int64_t) j * n] * y[j];
        hy[i] = t;
    }
    yhy = dot(n, y, hy);
    for (j = 0; j < n; j++)
        for (i = 0; i < n; i++)
            w->m[i + (int64_t) j * n] += -rho * (s[i] * hy[j] + hy[i] * s[j]) + (rho + rho * rho * yhy) * s[i] * s[j];
    w->h[H_ISID] = 0;
}

/* nach angenommenem Schritt: Tests; 1 = weiter */
static int accept_step(W *w)
{
    int n = w->n;
    double fold = w->h[H_F], fnew = w->h[H_FA], sinf, xinf;
    double rt = w->h[H_RELTOL];
    int i;
    sinf = 0.0;
    for (i = 0; i < n; i++) if (fabs(w->xt[i] - w->x[i]) > sinf) sinf = fabs(w->xt[i] - w->x[i]);
    if (HI_(H_METHOD) == SL_OPT_BFGS) bfgs_update(w);
    memcpy(w->x, w->xt, (size_t) n * sizeof(double));
    memcpy(w->g, w->gt, (size_t) n * sizeof(double));
    w->h[H_F] = fnew;
    w->h[H_ITER] += 1;
    xinf = norm_inf(n, w->x);
    if (fabs(fold - fnew) <= rt * (fabs(fold) + rt)) return finish(w, SL_OPT_CONV, SL_WHY_RELTOL);
    if (HI_(H_METHOD) == SL_OPT_BFGS && norm_inf(n, w->g) <= w->h[H_GTOL]) return finish(w, SL_OPT_CONV, SL_WHY_GTOL);
    if (sinf <= w->h[H_XTOL] * (1.0 + xinf)) return finish(w, SL_OPT_CONV, SL_WHY_XTOL);
    return 1;
}

static int run_bfgs(sl_ctx *cx, W *w)
{
    int n = w->n, i;
    double gi;
    PT_BEGIN
    ASK_F(1, w->x);
    if (!isfinite(w->h[H_LASTF])) return fail(cx, w, SL_ENONFINITE, "Zielfunktion am Startwert nicht endlich");
    w->h[H_F] = w->h[H_LASTF];
    ASK_G(2, w->x, w->h[H_F]);
    if (!HI_(H_LASTGOK)) return fail(cx, w, SL_ENONFINITE, "Gradient am Startwert nicht endlich");
    memcpy(w->g, w->gt, (size_t) n * sizeof(double));
    set_identity(n, w->m, 1.0);
    w->h[H_ISID] = 1;
    w->h[H_FIRST] = 1;
    if (norm_inf(n, w->g) <= w->h[H_GTOL]) return finish(w, SL_OPT_CONV, SL_WHY_GTOL);
    w->h[H_RETRY] = 0;

iter_top:
    if (interrupted(cx, w)) return 0;
    if (HI_(H_MAXIT) > 0 && HI_(H_ITER) >= HI_(H_MAXIT)) return finish(w, SL_OPT_MAXIT, SL_WHY_MAXIT);
    bfgs_direction(w);
    w->h[H_D0] = dot(n, w->g, w->p);
    if (!(w->h[H_D0] < 0.0)) {
        set_identity(n, w->m, 1.0);
        w->h[H_ISID] = 1;
        for (i = 0; i < n; i++) w->p[i] = -w->g[i];
        w->h[H_D0] = dot(n, w->g, w->p);
        if (!(w->h[H_D0] < 0.0)) return finish(w, SL_OPT_CONV, SL_WHY_GTOL);
    }
    gi = norm_inf(n, w->g);
    w->h[H_A] = HI_(H_FIRST) ? fmin(1.0, 1.0 / gi) : 1.0;
    w->h[H_F0] = w->h[H_F];
    w->h[H_APREV] = 0.0; w->h[H_FPREV] = w->h[H_F]; w->h[H_DPREV] = w->h[H_D0];
    memcpy(w->glo, w->g, (size_t) n * sizeof(double));
    w->h[H_LSN] = 0; w->h[H_LSI] = 1;

bracket:
    for (i = 0; i < n; i++) w->xt[i] = w->x[i] + w->h[H_A] * w->p[i];
    ASK_F(3, w->xt);
    w->h[H_FA] = w->h[H_LASTF];
    w->h[H_LSN] += 1;
    if (!(w->h[H_FA] <= w->h[H_F0] + WOLFE_C1 * w->h[H_A] * w->h[H_D0]) ||
        (HI_(H_LSI) > 1 && w->h[H_FA] >= w->h[H_FPREV])) {
        w->h[H_ALO] = w->h[H_APREV]; w->h[H_FLO] = w->h[H_FPREV]; w->h[H_DLO] = w->h[H_DPREV];
        w->h[H_AHI] = w->h[H_A]; w->h[H_FHI] = w->h[H_FA]; w->h[H_HDHI] = 0;
        goto zoom;
    }
    ASK_G(4, w->xt, w->h[H_FA]);
    if (!HI_(H_LASTGOK)) {
        w->h[H_ALO] = w->h[H_APREV]; w->h[H_FLO] = w->h[H_FPREV]; w->h[H_DLO] = w->h[H_DPREV];
        w->h[H_AHI] = w->h[H_A]; w->h[H_FHI] = INFINITY; w->h[H_HDHI] = 0;
        goto zoom;
    }
    w->h[H_DA] = dot(n, w->gt, w->p);
    if (fabs(w->h[H_DA]) <= -WOLFE_C2 * w->h[H_D0]) goto accept;
    if (w->h[H_DA] >= 0.0) {
        w->h[H_AHI] = w->h[H_APREV]; w->h[H_FHI] = w->h[H_FPREV]; w->h[H_DHI] = w->h[H_DPREV]; w->h[H_HDHI] = 1;
        w->h[H_ALO] = w->h[H_A]; w->h[H_FLO] = w->h[H_FA]; w->h[H_DLO] = w->h[H_DA];
        memcpy(w->glo, w->gt, (size_t) n * sizeof(double));
        goto zoom;
    }
    w->h[H_APREV] = w->h[H_A]; w->h[H_FPREV] = w->h[H_FA]; w->h[H_DPREV] = w->h[H_DA];
    memcpy(w->glo, w->gt, (size_t) n * sizeof(double));
    if (HI_(H_LSN) >= LS_MAX) {
        w->h[H_ALO] = w->h[H_APREV]; w->h[H_FLO] = w->h[H_FPREV];
        goto accept_lo;
    }
    w->h[H_A] = LS_EXPAND * w->h[H_A];
    w->h[H_LSI] += 1;
    goto bracket;

zoom:
    if (HI_(H_LSN) >= LS_MAX ||
        fabs(w->h[H_AHI] - w->h[H_ALO]) <= OPT_EPS * fmax(fabs(w->h[H_ALO]), fabs(w->h[H_AHI]))) {
        if (w->h[H_ALO] > 0.0) goto accept_lo;
        goto ls_fail;
    }
    w->h[H_A] = zoom_trial(w);
    for (i = 0; i < n; i++) w->xt[i] = w->x[i] + w->h[H_A] * w->p[i];
    ASK_F(5, w->xt);
    w->h[H_FA] = w->h[H_LASTF];
    w->h[H_LSN] += 1;
    if (!(w->h[H_FA] <= w->h[H_F0] + WOLFE_C1 * w->h[H_A] * w->h[H_D0]) || w->h[H_FA] >= w->h[H_FLO]) {
        w->h[H_AHI] = w->h[H_A]; w->h[H_FHI] = w->h[H_FA]; w->h[H_HDHI] = 0;
        goto zoom;
    }
    ASK_G(6, w->xt, w->h[H_FA]);
    if (!HI_(H_LASTGOK)) {
        w->h[H_AHI] = w->h[H_A]; w->h[H_FHI] = INFINITY; w->h[H_HDHI] = 0;
        goto zoom;
    }
    w->h[H_DA] = dot(n, w->gt, w->p);
    if (fabs(w->h[H_DA]) <= -WOLFE_C2 * w->h[H_D0]) goto accept;
    if (w->h[H_DA] * (w->h[H_AHI] - w->h[H_ALO]) >= 0.0) {
        w->h[H_AHI] = w->h[H_ALO]; w->h[H_FHI] = w->h[H_FLO]; w->h[H_DHI] = w->h[H_DLO]; w->h[H_HDHI] = 1;
    }
    w->h[H_ALO] = w->h[H_A]; w->h[H_FLO] = w->h[H_FA]; w->h[H_DLO] = w->h[H_DA];
    memcpy(w->glo, w->gt, (size_t) n * sizeof(double));
    goto zoom;

accept_lo:
    /* bester Punkt mit erfüllter Abnahmebedingung (Gradient in glo) */
    w->h[H_A] = w->h[H_ALO];
    for (i = 0; i < n; i++) w->xt[i] = w->x[i] + w->h[H_A] * w->p[i];
    w->h[H_FA] = w->h[H_FLO];
    memcpy(w->gt, w->glo, (size_t) n * sizeof(double));

accept:
    w->h[H_RETRY] = 0;
    if (!accept_step(w)) return 0;
    goto iter_top;

ls_fail:
    if (!HI_(H_ISID) && !HI_(H_RETRY)) {
        set_identity(n, w->m, 1.0);
        w->h[H_ISID] = 1;
        w->h[H_RETRY] = 1;
        goto iter_top;
    }
    return finish(w, SL_OPT_LSFAIL, SL_WHY_LSFAIL);

out_maxfev:
    return finish(w, SL_OPT_MAXIT, SL_WHY_MAXFEV);
    PT_END
    return 0;
}

/* ── projizierter BFGS (Bertsekas 1982; Kelley 1999, Kap. 5.5) ───────────── */

/* Cholesky-Zerlegung (untere Dreiecksmatrix) der k x k-Matrix a an Ort und Stelle; 0 = nicht pd */
static int chol_small(int k, double *a)
{
    int i, j, l;
    for (j = 0; j < k; j++) {
        double d = a[j + (int64_t) j * k];
        for (l = 0; l < j; l++) d -= a[j + (int64_t) l * k] * a[j + (int64_t) l * k];
        if (!(d > 0.0) || !isfinite(d)) return 0;
        d = sqrt(d);
        a[j + (int64_t) j * k] = d;
        for (i = j + 1; i < k; i++) {
            double s = a[i + (int64_t) j * k];
            for (l = 0; l < j; l++) s -= a[i + (int64_t) l * k] * a[j + (int64_t) l * k];
            a[i + (int64_t) j * k] = s / d;
        }
    }
    return 1;
}

/* projizierte Gradientennorm ||x - P(x - g)||_inf */
static double proj_grad_norm(const W *w)
{
    int i;
    double m = 0.0, t;
    for (i = 0; i < w->n; i++) {
        t = fabs(clamp(w->x[i] - w->g[i], w->lo[i], w->hi[i]) - w->x[i]);
        if (t > m) m = t;
    }
    return m;
}

/* Richtung p: aktive Komponenten -g, freie -(B_FF)^-1 g_F; wk[i] = 1 für frei */
static void pbfgs_direction(W *w, double epsk)
{
    int n = w->n, i, j, k, nf = 0, ii, jj;
    double *fr = w->wk, *a = w->ch, *b = w->xc;
    for (i = 0; i < n; i++) {
        int act = !(w->hi[i] > w->lo[i]) ||
                  (w->x[i] - w->lo[i] <= epsk && w->g[i] > 0.0) ||
                  (w->hi[i] - w->x[i] <= epsk && w->g[i] < 0.0);
        fr[i] = act ? 0.0 : 1.0;
        if (!act) nf++;
    }
    for (i = 0; i < n; i++) w->p[i] = -w->g[i];
    if (nf == 0) return;
    for (k = 0; k < 2; k++) {
        jj = 0;
        for (j = 0; j < n; j++) {
            if (fr[j] == 0.0) continue;
            ii = 0;
            for (i = 0; i < n; i++) {
                if (fr[i] == 0.0) continue;
                a[ii + (int64_t) jj * nf] = w->m[i + (int64_t) j * n];
                ii++;
            }
            jj++;
        }
        if (chol_small(nf, a)) break;
        set_identity(n, w->m, 1.0);              /* nicht positiv definit: neu mit B = I */
        w->h[H_ISID] = 1;
    }
    ii = 0;                                       /* L c = -g_F, L' d = c */
    for (i = 0; i < n; i++) if (fr[i] != 0.0) b[ii++] = -w->g[i];
    for (i = 0; i < nf; i++) {
        double s = b[i];
        for (k = 0; k < i; k++) s -= a[i + (int64_t) k * nf] * b[k];
        b[i] = s / a[i + (int64_t) i * nf];
    }
    for (i = nf - 1; i >= 0; i--) {
        double s = b[i];
        for (k = i + 1; k < nf; k++) s -= a[k + (int64_t) i * nf] * b[k];
        b[i] = s / a[i + (int64_t) i * nf];
    }
    ii = 0;
    for (i = 0; i < n; i++) if (fr[i] != 0.0) w->p[i] = b[ii++];
}

/* Aufdatierung der Hesse-Näherung B: B - (Bs)(Bs)'/(s'Bs) + yy'/(y's) */
static void pbfgs_update(W *w)
{
    int n = w->n, i, j;
    double *s = w->wk, *y = w->xc, *bs = w->xr, sy, yy, ss, sbs;
    for (i = 0; i < n; i++) { s[i] = w->xt[i] - w->x[i]; y[i] = w->gt[i] - w->g[i]; }
    sy = dot(n, s, y); yy = dot(n, y, y); ss = dot(n, s, s);
    if (HI_(H_FIRST)) {
        if (sy > 0.0 && yy > 0.0) set_identity(n, w->m, yy / sy);   /* Kehrwert von Gl. 6.20 */
        w->h[H_FIRST] = 0;
    }
    if (!(sy > SKIP_TOL * sqrt(ss) * sqrt(yy))) return;
    for (i = 0; i < n; i++) {
        double t = 0.0;
        for (j = 0; j < n; j++) t += w->m[i + (int64_t) j * n] * s[j];
        bs[i] = t;
    }
    sbs = dot(n, s, bs);
    if (!(sbs > 0.0)) return;
    for (j = 0; j < n; j++)
        for (i = 0; i < n; i++)
            w->m[i + (int64_t) j * n] += -bs[i] * bs[j] / sbs + y[i] * y[j] / sy;
    w->h[H_ISID] = 0;
}

static int run_pbfgs(sl_ctx *cx, W *w)
{
    int n = w->n, i;
    double wn, dec, a, fa, fx, t;
    PT_BEGIN
    ASK_F(1, w->x);
    if (!isfinite(w->h[H_LASTF])) return fail(cx, w, SL_ENONFINITE, "Zielfunktion am Startwert nicht endlich");
    w->h[H_F] = w->h[H_LASTF];
    ASK_G(2, w->x, w->h[H_F]);
    if (!HI_(H_LASTGOK)) return fail(cx, w, SL_ENONFINITE, "Gradient am Startwert nicht endlich");
    memcpy(w->g, w->gt, (size_t) n * sizeof(double));
    set_identity(n, w->m, 1.0);
    w->h[H_ISID] = 1;
    w->h[H_FIRST] = 1;
    w->h[H_RETRY] = 0;

iter_top:
    if (interrupted(cx, w)) return 0;
    wn = proj_grad_norm(w);
    if (wn <= w->h[H_GTOL]) return finish(w, SL_OPT_CONV, SL_WHY_GTOL);
    if (HI_(H_MAXIT) > 0 && HI_(H_ITER) >= HI_(H_MAXIT)) return finish(w, SL_OPT_MAXIT, SL_WHY_MAXIT);
    pbfgs_direction(w, fmin(ACTIVE_EPS0, wn));
    w->h[H_A] = HI_(H_FIRST) ? fmin(1.0, 1.0 / norm_inf(n, w->g)) : 1.0;
    w->h[H_LSN] = 0;
    w->h[H_EXT] = 0;

trial:
    if (HI_(H_LSN) >= LS_MAX) {
        if (HI_(H_EXT)) goto revert;
        goto ls_fail;
    }
    a = w->h[H_A];
    for (i = 0; i < n; i++) w->xt[i] = clamp(w->x[i] + a * w->p[i], w->lo[i], w->hi[i]);
    if (HI_(H_EXT) && memcmp(w->xt, w->xx, (size_t) n * sizeof(double)) == 0) goto revert;
    dec = 0.0;
    for (i = 0; i < n; i++) dec += w->g[i] * (w->x[i] - w->xt[i]);
    w->h[H_DA] = dec;
    if (!(dec > 0.0)) {
        if (HI_(H_EXT)) goto revert;
        w->h[H_LSN] += 1;
        w->h[H_A] = 0.5 * a;
        goto trial;
    }
    ASK_F(3, w->xt);
    w->h[H_FA] = w->h[H_LASTF];
    w->h[H_LSN] += 1;
    fa = w->h[H_FA]; fx = w->h[H_F]; dec = w->h[H_DA]; a = w->h[H_A];
    if (!(fa <= fx - WOLFE_C1 * dec) || (HI_(H_EXT) && !(fa < w->h[H_FSAV]))) {
        if (HI_(H_EXT)) goto revert;
        if (!isfinite(fa)) w->h[H_A] = 0.5 * a;
        else {
            /* Rückschritt: Minimum der Parabel durch f(0), Steigung -dec/a und f(a) */
            t = 2.0 * (fa - fx + dec);
            t = (t > 0.0) ? dec * a / t : 0.5 * a;
            w->h[H_A] = clamp(t, 0.1 * a, 0.5 * a);
        }
        goto trial;
    }
    ASK_G(4, w->xt, w->h[H_FA]);
    if (!HI_(H_LASTGOK)) {
        if (HI_(H_EXT)) goto revert;
        w->h[H_A] = 0.5 * w->h[H_A];
        goto trial;
    }
    /* Ausweiten entlang des Bogens, solange die Krümmungsbedingung verletzt ist:
     * g(x(a))'(x(a) - x) < c2 g(x)'(x(a) - x) (wie das Klammern in N&W Alg. 3.5) */
    t = 0.0;
    for (i = 0; i < n; i++) t += w->gt[i] * (w->xt[i] - w->x[i]);
    if (t < -WOLFE_C2 * w->h[H_DA] && HI_(H_LSN) < LS_MAX) {
        memcpy(w->xx, w->xt, (size_t) n * sizeof(double));
        memcpy(w->glo, w->gt, (size_t) n * sizeof(double));
        w->h[H_FSAV] = w->h[H_FA];
        w->h[H_EXT] = 1;
        w->h[H_A] = LS_EXPAND * w->h[H_A];
        goto trial;
    }
    goto accept;

revert:
    /* letzter Punkt der Ausweitung mit erfüllter Abnahmebedingung */
    memcpy(w->xt, w->xx, (size_t) n * sizeof(double));
    memcpy(w->gt, w->glo, (size_t) n * sizeof(double));
    w->h[H_FA] = w->h[H_FSAV];

accept:
    w->h[H_EXT] = 0;
    w->h[H_RETRY] = 0;
    pbfgs_update(w);
    if (!accept_step(w)) return 0;
    goto iter_top;

ls_fail:
    if (!HI_(H_ISID) && !HI_(H_RETRY)) {
        set_identity(n, w->m, 1.0);
        w->h[H_ISID] = 1;
        w->h[H_RETRY] = 1;
        goto iter_top;
    }
    return finish(w, SL_OPT_LSFAIL, SL_WHY_LSFAIL);

out_maxfev:
    return finish(w, SL_OPT_MAXIT, SL_WHY_MAXFEV);
    PT_END
    return 0;
}

/* ── Nelder-Mead (Lagarias u. a. 1998) ───────────────────────────────────── */

#define VTX(w, k) ((w)->sim + (int64_t) (k) * (w)->n)

/* stabile Ordnung nach Funktionswert (Einfügen; bei Gleichstand bleibt die Reihenfolge) */
static void nm_sort(W *w)
{
    int n = w->n, i, k;
    double fv, *tmp = w->wk;
    for (i = 1; i <= n; i++) {
        fv = w->fs[i];
        memcpy(tmp, VTX(w, i), (size_t) n * sizeof(double));
        k = i - 1;
        while (k >= 0 && w->fs[k] > fv) {
            w->fs[k + 1] = w->fs[k];
            memcpy(VTX(w, k + 1), VTX(w, k), (size_t) n * sizeof(double));
            k--;
        }
        w->fs[k + 1] = fv;
        memcpy(VTX(w, k + 1), tmp, (size_t) n * sizeof(double));
    }
}

/* schlechteste Ecke durch v (Wert fv) ersetzen: hinter alle Ecken mit Wert <= fv */
static void nm_accept(W *w, const double *v, double fv)
{
    int n = w->n, j = 0, k;
    while (j < n && w->fs[j] <= fv) j++;
    for (k = n; k > j; k--) {
        w->fs[k] = w->fs[k - 1];
        memcpy(VTX(w, k), VTX(w, k - 1), (size_t) n * sizeof(double));
    }
    w->fs[j] = fv;
    memcpy(VTX(w, j), v, (size_t) n * sizeof(double));
}

static int run_nm(sl_ctx *cx, W *w)
{
    int n = w->n, i, k;
    double *x1, *xw, rt, span, dia, t;
    PT_BEGIN
    ASK_F(1, w->x);
    if (!isfinite(w->h[H_LASTF])) return fail(cx, w, SL_ENONFINITE, "Zielfunktion am Startwert nicht endlich");
    memcpy(VTX(w, 0), w->x, (size_t) n * sizeof(double));
    w->fs[0] = w->h[H_LASTF];
    for (w->h[H_NMJ] = 1; HI_(H_NMJ) <= n; w->h[H_NMJ] += 1) {
        k = HI_(H_NMJ);
        memcpy(VTX(w, k), w->x, (size_t) n * sizeof(double));
        VTX(w, k)[k - 1] = w->x[k - 1] + NM_DELTA * fmax(fabs(w->x[k - 1]), 1.0);
        ASK_F(2, VTX(w, HI_(H_NMJ)));
        w->fs[HI_(H_NMJ)] = w->h[H_LASTF];
    }
    nm_sort(w);

iter_top:
    if (interrupted(cx, w)) return 0;
    rt = w->h[H_RELTOL];
    span = w->fs[n] - w->fs[0];
    if (span <= rt * (fabs(w->fs[0]) + rt)) return finish(w, SL_OPT_CONV, SL_WHY_RELTOL);
    x1 = VTX(w, 0);
    dia = 0.0;
    for (k = 1; k <= n; k++)
        for (i = 0; i < n; i++) if (fabs(VTX(w, k)[i] - x1[i]) > dia) dia = fabs(VTX(w, k)[i] - x1[i]);
    if (dia <= w->h[H_XTOL] * (1.0 + norm_inf(n, x1))) return finish(w, SL_OPT_DEGEN, SL_WHY_DEGEN);
    if (HI_(H_MAXIT) > 0 && HI_(H_ITER) >= HI_(H_MAXIT)) return finish(w, SL_OPT_MAXIT, SL_WHY_MAXIT);
    /* Schwerpunkt der besten n Ecken, Spiegelpunkt */
    for (i = 0; i < n; i++) {
        t = 0.0;
        for (k = 0; k < n; k++) t += VTX(w, k)[i];
        w->xc[i] = t / n;
    }
    xw = VTX(w, n);
    for (i = 0; i < n; i++) w->xr[i] = w->xc[i] + NM_RHO * (w->xc[i] - xw[i]);
    ASK_F(3, w->xr);
    w->h[H_NMFR] = w->h[H_LASTF];
    w->h[H_ITER] += 1;
    if (w->h[H_NMFR] < w->fs[0]) {                                   /* strecken */
        for (i = 0; i < n; i++) w->xx[i] = w->xc[i] + NM_CHI * (w->xr[i] - w->xc[i]);
        ASK_F(4, w->xx);
        w->h[H_NMFX] = w->h[H_LASTF];
        if (w->h[H_NMFX] < w->h[H_NMFR]) nm_accept(w, w->xx, w->h[H_NMFX]);
        else nm_accept(w, w->xr, w->h[H_NMFR]);
        goto iter_top;
    }
    if (w->h[H_NMFR] < w->fs[n - 1]) {                               /* spiegeln */
        nm_accept(w, w->xr, w->h[H_NMFR]);
        goto iter_top;
    }
    if (w->h[H_NMFR] < w->fs[n]) {                                   /* außen zusammenziehen */
        for (i = 0; i < n; i++) w->xx[i] = w->xc[i] + NM_GAMMA * (w->xr[i] - w->xc[i]);
        ASK_F(5, w->xx);
        w->h[H_NMFX] = w->h[H_LASTF];
        if (w->h[H_NMFX] <= w->h[H_NMFR]) { nm_accept(w, w->xx, w->h[H_NMFX]); goto iter_top; }
    } else {                                                         /* innen zusammenziehen */
        xw = VTX(w, n);
        for (i = 0; i < n; i++) w->xx[i] = w->xc[i] + NM_GAMMA * (xw[i] - w->xc[i]);
        ASK_F(6, w->xx);
        w->h[H_NMFX] = w->h[H_LASTF];
        if (w->h[H_NMFX] < w->fs[n]) { nm_accept(w, w->xx, w->h[H_NMFX]); goto iter_top; }
    }
    /* schrumpfen auf x_1 */
    for (w->h[H_NMJ] = 1; HI_(H_NMJ) <= n; w->h[H_NMJ] += 1) {
        k = HI_(H_NMJ);
        x1 = VTX(w, 0);
        for (i = 0; i < n; i++) VTX(w, k)[i] = x1[i] + NM_SIGMA * (VTX(w, k)[i] - x1[i]);
        ASK_F(7, VTX(w, HI_(H_NMJ)));
        w->fs[HI_(H_NMJ)] = w->h[H_LASTF];
    }
    nm_sort(w);
    goto iter_top;

out_maxfev:
    return finish(w, SL_OPT_MAXIT, SL_WHY_MAXFEV);
    PT_END
    return 0;
}

static int run(sl_ctx *cx, W *w)
{
    switch (HI_(H_METHOD)) {
    case SL_OPT_BFGS: return run_bfgs(cx, w);
    case SL_OPT_PBFGS: return run_pbfgs(cx, w);
    default: return run_nm(cx, w);
    }
}

/* ── öffentliche Schnittstelle ───────────────────────────────────────────── */

int sl_opt_init(sl_ctx *cx, int method, int n, const double *x0, const double *lo, const double *hi,
                const sl_opt_ctrl *ctrl, int have_grad, double *ws)
{
    sl_opt_ctrl c;
    W w;
    int i;
    const char *nm = sl_opt_method_name(method);
    if (method < SL_OPT_BFGS || method > SL_OPT_NM) return sl_fail(cx, SL_EARG, "Optimierer: unbekanntes Verfahren %d", method);
    if (n < 1 || n > 46340) return sl_fail(cx, SL_EARG, "%s: Zahl der Parameter muss zwischen 1 und 46340 liegen (erhalten: %d)", nm, n);
    if (ws == NULL || x0 == NULL) return sl_fail(cx, SL_EARG, "%s: interner Fehler (Felder fehlen)", nm);
    if (ctrl) c = *ctrl; else sl_opt_ctrl_default(&c, method);
    if (c.maxit < 0) return sl_fail(cx, SL_EARG, "%s: maxit muss >= 0 sein", nm);
    if (c.maxfev < 0) return sl_fail(cx, SL_EARG, "%s: maxfev muss >= 0 sein", nm);
    if (!(c.reltol >= 0.0) || !isfinite(c.reltol)) return sl_fail(cx, SL_EARG, "%s: reltol muss endlich und >= 0 sein", nm);
    if (!(c.gtol >= 0.0) || !isfinite(c.gtol)) return sl_fail(cx, SL_EARG, "%s: gtol muss endlich und >= 0 sein", nm);
    if (!(c.xtol >= 0.0) || !isfinite(c.xtol)) return sl_fail(cx, SL_EARG, "%s: xtol muss endlich und >= 0 sein", nm);
    if (!isfinite(c.fnscale) || c.fnscale == 0.0) return sl_fail(cx, SL_EARG, "%s: fnscale muss endlich und ungleich 0 sein", nm);
    if (method != SL_OPT_PBFGS && (lo != NULL || hi != NULL))
        return sl_fail(cx, SL_EARG, "%s: Schranken nur mit PBFGS", nm);
    for (i = 0; i < n; i++) {
        if (!isfinite(x0[i])) return sl_fail(cx, SL_ENONFINITE, "%s: Startwert nicht endlich (Komponente %d)", nm, i + 1);
        if (c.parscale && (!(c.parscale[i] > 0.0) || !isfinite(c.parscale[i])))
            return sl_fail(cx, SL_EARG, "%s: parscale muss endlich und > 0 sein (Komponente %d)", nm, i + 1);
        if ((lo && isnan(lo[i])) || (hi && isnan(hi[i])))
            return sl_fail(cx, SL_EARG, "%s: Schranke ist NaN (Komponente %d)", nm, i + 1);
        if (lo && hi && lo[i] > hi[i])
            return sl_fail(cx, SL_EARG, "%s: untere Schranke größer als obere (Komponente %d)", nm, i + 1);
        if ((lo && lo[i] == INFINITY) || (hi && hi[i] == -INFINITY))
            return sl_fail(cx, SL_EARG, "%s: Schranke ohne zulässigen Punkt (Komponente %d)", nm, i + 1);
    }
    memset(ws, 0, (size_t) ws_len(n) * sizeof(double));
    ws[H_MAGIC] = WS_MAGIC;
    ws[H_METHOD] = method;
    ws[H_N] = n;
    bind(&w, ws);
    w.h[H_HAVEG] = have_grad ? 1 : 0;
    w.h[H_MAXIT] = c.maxit;
    w.h[H_MAXFEV] = c.maxfev;
    w.h[H_RELTOL] = c.reltol;
    w.h[H_GTOL] = c.gtol;
    w.h[H_XTOL] = c.xtol;
    w.h[H_FNSCALE] = c.fnscale;
    w.h[H_FB] = INFINITY;
    w.h[H_FBRAW] = NAN;
    for (i = 0; i < n; i++) {
        double s = c.parscale ? c.parscale[i] : 1.0;
        w.ps[i] = s;
        w.lou[i] = lo ? lo[i] : -INFINITY;
        w.hiu[i] = hi ? hi[i] : INFINITY;
        w.lo[i] = w.lou[i] / s;
        w.hi[i] = w.hiu[i] / s;
        w.x[i] = clamp(x0[i] / s, w.lo[i], w.hi[i]);
        w.xb[i] = x0[i];
    }
    w.h[H_PC] = 0;
    run(cx, &w);
    return (int) w.h[H_STATUS];
}

static int check_ws(sl_ctx *cx, const double *ws)
{
    if (ws == NULL || ws[H_MAGIC] != WS_MAGIC)
        return sl_fail(cx, SL_EARG, "Optimierer: interner Fehler (Arbeitsfeld nicht initialisiert)");
    return SL_OK;
}

int sl_opt_ask(sl_ctx *cx, const double *ws, double *x_eval, int *need)
{
    W w;
    if (check_ws(cx, ws) != SL_OK) { *need = SL_DONE; return SL_EARG; }
    bind(&w, (double *) ws);
    *need = (int) w.h[H_NEED];
    if (*need != SL_DONE && x_eval) eval_point(&w, w.xe, x_eval);
    return SL_OK;
}

int sl_opt_tell(sl_ctx *cx, double *ws, double f, const double *g)
{
    W w;
    int need, i, n;
    double v;
    if (check_ws(cx, ws) != SL_OK) return SL_EARG;
    bind(&w, ws);
    n = w.n;
    if (w.h[H_DONE] != 0.0) return sl_fail(cx, SL_EARG, "%s: interner Fehler (Optimierer ist beendet)", sl_opt_method_name((int) w.h[H_METHOD]));
    need = (int) w.h[H_NEED];
    if (need == SL_NEED_F) {
        w.h[H_NTOT] += 1;
        v = fin_or_inf(f / w.h[H_FNSCALE]);
        if (w.h[H_GRON] != 0.0) {
            if (gr_feed(&w, v)) return SL_OK;
        } else {
            w.h[H_LASTF] = v;
            w.h[H_NFEV] += 1;
            if (v < w.h[H_FB]) {
                w.h[H_FB] = v;
                w.h[H_FBRAW] = f;
                w.h[H_HAVEB] = 1;
                eval_point(&w, w.xe, w.xb);
            }
        }
    } else if (need == SL_NEED_G) {
        if (g == NULL) return sl_fail(cx, SL_EARG, "%s: interner Fehler (Gradient fehlt)", sl_opt_method_name((int) w.h[H_METHOD]));
        for (i = 0; i < n; i++) w.gt[i] = g[i] * w.ps[i] / w.h[H_FNSCALE];
        w.h[H_NGEV] += 1;
        w.h[H_LASTGOK] = all_finite(n, w.gt);
    } else {
        return sl_fail(cx, SL_EARG, "Optimierer: interner Fehler (keine Anfrage offen)");
    }
    run(cx, &w);
    return (int) w.h[H_STATUS];
}

int sl_opt_result(const double *ws, double *x, double *f, int *code, int *iter, int *nfev, int *ngev)
{
    W w;
    if (ws == NULL || ws[H_MAGIC] != WS_MAGIC) return SL_EARG;
    bind(&w, (double *) ws);
    if (x) memcpy(x, w.xb, (size_t) w.n * sizeof(double));
    if (f) *f = w.h[H_FBRAW];
    if (code) *code = (int) w.h[H_CODE];
    if (iter) *iter = (int) w.h[H_ITER];
    if (nfev) *nfev = (int) w.h[H_NFEV];
    if (ngev) *ngev = (int) w.h[H_NGEV];
    return (int) w.h[H_STATUS];
}

int sl_opt_info(const double *ws, int *reason, int *ntot)
{
    if (ws == NULL || ws[H_MAGIC] != WS_MAGIC) return SL_EARG;
    if (reason) *reason = (int) ws[H_REASON];
    if (ntot) *ntot = (int) ws[H_NTOT];
    return SL_OK;
}

int sl_opt_dim(const double *ws)
{
    if (ws == NULL || ws[H_MAGIC] != WS_MAGIC) return -1;
    return (int) ws[H_N];
}

int sl_minimize(sl_ctx *cx, int method, int n, double *x, const double *lo, const double *hi,
                const sl_opt_ctrl *ctrl, sl_fn f, sl_gr g, void *data,
                double *fmin, int *code, int *iter, int *nfev)
{
    int64_t len = sl_opt_wsize(method, n);
    double *ws, *xe, *ge, fv = 0.0;
    int st, need;
    if (len < 0) return sl_fail(cx, SL_EARG, "%s: Verfahren oder Zahl der Parameter ungültig", sl_opt_method_name(method));
    if (f == NULL) return sl_fail(cx, SL_EARG, "%s: Zielfunktion fehlt", sl_opt_method_name(method));
    ws = (double *) malloc((size_t) (len + 2 * (int64_t) n) * sizeof(double));
    if (ws == NULL) return sl_fail(cx, SL_ENOMEM, "%s: kein Speicher", sl_opt_method_name(method));
    xe = ws + len;
    ge = xe + n;
    ws[H_MAGIC] = 0.0;
    st = sl_opt_init(cx, method, n, x, lo, hi, ctrl, g != NULL, ws);
    while (st == SL_OK) {
        sl_opt_ask(cx, ws, xe, &need);
        if (need == SL_DONE) break;
        if (need == SL_NEED_F) st = sl_opt_tell(cx, ws, f(xe, data), NULL);
        else { g(xe, ge, data); st = sl_opt_tell(cx, ws, fv, ge); }
    }
    if (ws[H_MAGIC] == WS_MAGIC) {
        int s2 = sl_opt_result(ws, x, fmin, code, iter, nfev, NULL);
        if (st == SL_OK) st = s2;
    }
    free(ws);
    return st;
}

int sl_numgrad(sl_ctx *cx, int n, const double *x, const double *lo, const double *hi, double fx,
               sl_fn f, void *data, double *g, int *nfev)
{
    double *z, zp, zm, fp, fm, fz = fin_or_inf(fx), l, u, keep;
    int i, kind, cnt = 0;
    if (n < 1 || x == NULL || g == NULL || f == NULL) return sl_fail(cx, SL_EARG, "sl_numgrad: interner Fehler (Argumente)");
    z = (double *) malloc((size_t) n * sizeof(double));
    if (z == NULL) return sl_fail(cx, SL_ENOMEM, "sl_numgrad: kein Speicher");
    memcpy(z, x, (size_t) n * sizeof(double));
    for (i = 0; i < n; i++) {
        l = lo ? lo[i] : -INFINITY;
        u = hi ? hi[i] : INFINITY;
        kind = fd_plan(z[i], l, u, &zp, &zm);
        keep = z[i];
        fp = fz; fm = fz;
        if (fd_need_p(kind, keep, zp)) { z[i] = zp; fp = fin_or_inf(f(z, data)); cnt++; }
        if (fd_need_m(kind, keep, zm)) { z[i] = zm; fm = fin_or_inf(f(z, data)); cnt++; }
        z[i] = keep;
        g[i] = fd_combine(kind, keep, zp, zm, fz, fp, fm);
    }
    free(z);
    if (nfev) *nfev = cnt;
    return SL_OK;
}
