/* core/slc_bootpath.cpp – Pfadaufbau im Bootstrap (SimLev core, seit 1.6.0)
 * Verfahren:  Aus den gezogenen Bruttorenditen eines Pfads (n_out × k) die Kurspfade start * cumprod(c(1, r))
 *             je Index (Produkt in long double wie R's cumprod, sl_r_cumprod), die Hebelprodukte nach der
 *             MSCI-Formel mit Fondskosten
 *               r_L = 1 + L (r - 1) + (1 - L) rate / 100 d / rate_basis - expense / 100 d / ter_basis
 *                     - spread / 100 m d / rate_basis,  m = max(L - 1, 0) + max(-L, 0),
 *             ab der ersten Rendite <= 0 Totalverlust (Rendite 0), die Zusatzreihen der gezogenen Zeilen
 *             (erste Zeile doppelt) und ihre Niveau-Variante cumprod(c(1, aux_ratio[idx, ])) * aux_start.
 *             Ungültig ist ein Pfad mit einer nicht endlichen oder nicht positiven Indexrendite oder einer
 *             nicht endlichen Hebelrendite. Bis 1.5.2 rechnete jede Sprache das je Pfad selbst
 *             (.build_path, _build_path).
 * Quellen:    MSCI Inc. (2020). MSCI Daily Leveraged Indexes Methodology (Hebelformel mit Finanzierung);
 *             IEEE 754-2008, Abschnitt 6.2 (NaN-Weitergabe).
 * Konstanten: keine.
 * Reinraum:   eigener SimLev-Code (Regeln von r/R/bootstrap.R aus SimLev 1.5.2); kein Code aus R oder Paketen.
 * Prüforakel: R 1.5.2 (/home/claude/rlib152; Gleichlauf: prep_fuzz.R).
 */
#include "slc_internal.h"
#include "slc_prep.h"
#include "slc_rbase.h"

#include <stdlib.h>
#include <string.h>

static inline double quiet_(double x)
{
    uint64_t b;
    memcpy(&b, &x, sizeof b);
    b |= UINT64_C(0x0008000000000000);
    memcpy(&x, &b, sizeof b);
    return x;
}
/* linker NaN-Operand gewinnt (wie R auf x86-64) */
static inline double lnan_(double r, double a, double b)
{
    if (r == r) return r;
    if (a != a) return quiet_(a);
    if (b != b) return quiet_(b);
    return r;
}
static inline double add_(double a, double b) { return lnan_(a + b, a, b); }
static inline double sub_(double a, double b) { return lnan_(a - b, a, b); }
static inline double mul_(double a, double b) { return lnan_(a * b, a, b); }
static inline double div_(double a, double b) { return lnan_(a / b, a, b); }

/* out (n + 1) = start * cumprod(c(1, x)) */
static void cp_(int64_t n, const double *x, double start, double *buf, double *out)
{
    int64_t i;
    buf[0] = 1.0;
    memcpy(buf + 1, x, sizeof(double) * (size_t) n);
    sl_r_cumprod(n + 1, buf, out);
    for (i = 0; i <= n; i++) out[i] = mul_(start, out[i]);
}

int sl_boot_path(sl_ctx *cx, int64_t n_out, int k, const double *ret, const int64_t *idx, int64_t n_aux, int na,
                 const double *aux, const double *aux_ratio, const double *aux_start, const int *level, int nL,
                 const sl_letf *letf, double start, double *P, double *lv)
{
    const int64_t N = n_out + 1;
    double *buf = NULL, *r = NULL, *col = NULL;
    int64_t i, ko;
    int j, l, valid = 1;
    if (n_out < 1 || k < 0 || na < 0 || nL < 0 || (na > 0 && (!aux || n_aux < 1)))
        return -sl_fail(cx, SL_EARG, "boot_path: ungültige Größen");
    for (i = 0; i < n_out; i++)
        if (na > 0 && (idx[i] < 1 || idx[i] > n_aux)) return -sl_fail(cx, SL_EARG, "boot_path: Quellzeile außerhalb");
    for (l = 0; l < nL; l++)
        if (letf[l].base < 0 || letf[l].base >= k || letf[l].rate_col >= na || letf[l].days_col >= na)
            return -sl_fail(cx, SL_EARG, "boot_path: Spalte des Hebelprodukts außerhalb");
    for (i = 0; i < n_out * (int64_t) k; i++)
        if (!isfinite(ret[i]) || ret[i] <= 0) return 0;
    buf = (double *) malloc(sizeof(double) * (size_t) (N + 1));
    r = (double *) malloc(sizeof(double) * (size_t) N);
    col = (double *) malloc(sizeof(double) * (size_t) N);
    if (!buf || !r || !col) { free(buf); free(r); free(col); return -sl_fail(cx, SL_ENOMEM, "boot_path: kein Speicher"); }
    for (j = 0; j < k; j++) cp_(n_out, ret + (int64_t) j * n_out, start, buf, P + (int64_t) j * N);
    for (l = 0; l < nL && valid; l++) {
        const sl_letf *q = &letf[l];
        const double *rb = ret + (int64_t) q->base * n_out;
        const double L = q->L, m = (L - 1 > 0 ? L - 1 : 0) + (-L > 0 ? -L : 0);
        for (i = 0; i < n_out; i++) {
            const int64_t a = idx[i] - 1;
            const double rate = q->rate_col >= 0 ? aux[(int64_t) q->rate_col * n_aux + a] : q->rate;
            const double d = q->days_col >= 0 ? aux[(int64_t) q->days_col * n_aux + a] : q->days;
            /* 1 + L * (rb - 1) + (1 - L) * rate / 100 * d / rb_ - expense / 100 * d / tb - spread / 100 * m * d / rb_ */
            double t1 = add_(1.0, mul_(L, sub_(rb[i], 1.0)));
            double t2 = div_(mul_(div_(mul_(1.0 - L, rate), 100.0), d), q->rate_basis);
            double t3 = div_(mul_(q->expense / 100.0, d), q->ter_basis);
            double t4 = div_(mul_(mul_(q->spread / 100.0, m), d), q->rate_basis);
            r[i] = sub_(sub_(add_(t1, t2), t3), t4);
            if (!isfinite(r[i])) { valid = 0; break; }
        }
        if (!valid) break;
        for (ko = 0; ko < n_out && r[ko] > 0; ko++) {}
        for (i = ko; i < n_out; i++) r[i] = 0.0;
        cp_(n_out, r, start, buf, P + (int64_t) (k + l) * N);
    }
    if (valid && na > 0) {
        double *A = P + (int64_t) (k + nL) * N;
        for (j = 0; j < na; j++) {
            const double *s = aux + (int64_t) j * n_aux;
            A[(int64_t) j * N] = s[idx[0] - 1];
            for (i = 0; i < n_out; i++) A[(int64_t) j * N + i + 1] = s[idx[i] - 1];
        }
        if (aux_ratio && lv) {
            for (j = 0; j < na; j++) {
                const double *s = aux_ratio + (int64_t) j * n_aux;
                const double s0 = aux_start ? aux_start[j] : div_(aux[(int64_t) j * n_aux], s[0]);
                for (i = 0; i < n_out; i++) col[i] = s[idx[i] - 1];
                buf[0] = 1.0;
                memcpy(buf + 1, col, sizeof(double) * (size_t) n_out);
                sl_r_cumprod(N, buf, lv + (int64_t) j * N);
                for (i = 0; i < N; i++) lv[(int64_t) j * N + i] = mul_(lv[(int64_t) j * N + i], s0);
                if (level && level[j]) memcpy(A + (int64_t) j * N, lv + (int64_t) j * N, sizeof(double) * (size_t) N);
            }
        }
    }
    free(buf); free(r); free(col);
    return valid;
}
