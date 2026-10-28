/* core/slc_boot.c – Bootstrap-Kerne mit Zufall aus einem übergebenen Strom (SimLev core, Etappe 9.4)
 * Verfahren:  Die eigenen Bootstrap-Kerne von SimLev (r/src/bootstrap_core_impl.h, C++ über
 *             Host-Sichten) als reines C; Rechnung und Reihenfolge der Ziehungen wie dort, gezogen
 *             wird nur aus dem übergebenen Strom sl_rng * (SPEZ-9 B.17, C.5): ganze Zahl in [0, n)
 *             mit sl_rint (Lemire 2019) statt floor(runif(0, n)), geometrisch mit sl_rgeom
 *             (Inversion), normal mit sl_rnorm (Inversion), gleichverteilt mit sl_unif01.
 *             Indexkerne (Quellzeilen 1-basiert):
 *               iid (Efron 1979); Blöcke fester Länge, fortlaufend (Künsch 1989) bzw. zirkulär
 *               (Politis, Romano 1992); stationär mit geometrischen Blocklängen vom Mittel L
 *               (Politis, Romano 1994); Volatilitätsregime als Markov-Kette über diskretisierte
 *               Regime mit iid-Ziehung im Regime (eigenes Verfahren von SimLev); empirische Ränder
 *               (Mischung linker Rand, Kern, rechter Rand; eigenes Verfahren).
 *             Wertkerne: Wild-Bootstrap mit gemeinsamem Gewicht je Zeile (Wu 1986; Rademacher nach
 *               Liu 1988; Zweipunktverteilung nach Mammen 1993; Standardnormal), Reset/Spiegelung
 *               (eigenes Verfahren), EVT mit GPD-Rändern per Inversion
 *               x = sigma ((1 - u)^(-xi) - 1)/xi über expm1(-xi log u) (u und 1 - u gleich
 *               verteilt; |xi| < 1e-10: -sigma log u), Kopplung der übrigen Reihen über das
 *               historische Verhältnis (McNeil, Frey 2000 für die Ränder), GARCH(1,1)/GJR mit
 *               gefilterter historischer Simulation (Barone-Adesi, Giannopoulos, Vosper 1999;
 *               Bollerslev 1986; Glosten, Jagannathan, Runkle 1993), Markov-Switching-(AR-)GJR-
 *               GARCH(-M) mit zeitvariablen Übergängen (Haas, Mittnik, Paolella 2004; Diebold,
 *               Lee, Weinbach 1994).
 *             Ohne Zufall: rollierende Volatilität, Regime über Schwellen, Übergangsmatrix mit
 *               Laplace-Glättung.
 *             Ungültige Indizes in den Eingaben ergeben einen Fehler (früher nicht geprüft).
 * Quellen:    Efron, B. (1979). Bootstrap methods: Another look at the jackknife. The Annals of
 *               Statistics 7(1), 1–26.
 *             Künsch, H. R. (1989). The jackknife and the bootstrap for general stationary
 *               observations. The Annals of Statistics 17(3), 1217–1241.
 *             Politis, D. N., Romano, J. P. (1992). A circular block-resampling procedure for
 *               stationary data. In: LePage, Billard (Hrsg.), Exploring the Limits of Bootstrap,
 *               Wiley, 263–270.
 *             Politis, D. N., Romano, J. P. (1994). The stationary bootstrap. Journal of the American
 *               Statistical Association 89(428), 1303–1313.
 *             Wu, C. F. J. (1986). Jackknife, bootstrap and other resampling methods in regression
 *               analysis. The Annals of Statistics 14(4), 1261–1295.
 *             Liu, R. Y. (1988). Bootstrap procedures under some non-i.i.d. models. The Annals of
 *               Statistics 16(4), 1696–1708.
 *             Mammen, E. (1993). Bootstrap and wild bootstrap for high dimensional linear models.
 *               The Annals of Statistics 21(1), 255–285.
 *             Barone-Adesi, G., Giannopoulos, K., Vosper, L. (1999). VaR without correlations for
 *               portfolios of derivative securities. Journal of Futures Markets 19(5), 583–602.
 *             McNeil, A. J., Frey, R. (2000). Estimation of tail-related risk measures for
 *               heteroscedastic financial time series: An extreme value approach. Journal of
 *               Empirical Finance 7(3–4), 271–300.
 *             Bollerslev (1986); Glosten, Jagannathan, Runkle (1993); Haas, Mittnik, Paolella
 *               (2004); Diebold, F. X., Lee, J.-H., Weinbach, G. C. (1994). Regime switching with
 *               time-varying transition probabilities. In: Hargreaves (Hrsg.), Nonstationary Time
 *               Series Analysis and Cointegration, Oxford University Press, 283–302.
 *             Lemire, D. (2019); Devroye, L. (1986) (Ziehungen, über slc_sample.c).
 *             Eigener SimLev-Code: r/src/bootstrap_core_impl.h.
 * Konstanten: Mammen-Gewichte (1 - sqrt 5)/2, (1 + sqrt 5)/2 mit P = (sqrt 5 + 1)/(2 sqrt 5),
 *             zur Laufzeit aus sqrt(5) wie im eigenen Kern; Untergrenze der Varianz 1e-14.
 * Reinraum:   geschrieben nur nach den genannten Quellen; kein Code und keine
 *             Koeffizienten aus R, Netlib, ACM- oder RSS-Algorithmen oder Paketen.
 * Prüforakel: die bisherigen eigenen Kerne (statistisch, anderer Generator; scratchpad/e94/).
 */
#include "slc_internal.h"
#include "slc_la_internal.h"

#include <stdlib.h>
#include <string.h>

#define VFLOOR 1e-14

static int draw_int(sl_rng *r, int n) { return (int) sl_rint(r, (int64_t) n); }

static int check_idx(sl_ctx *cx, int n, const int32_t *idx, int lim, const char *what)
{
    int i;
    for (i = 0; i < n; i++)
        if (idx[i] < 1 || idx[i] > lim)
            return sl_fail(cx, SL_EARG, "interner Fehler: %s enthält einen Index außerhalb 1 ... %d", what, lim);
    return SL_OK;
}

/* ── Indexkerne ── */

int sl_boot_idx_iid(sl_ctx *cx, sl_rng *r, int n_src, int n_out, int32_t *idx)
{
    int i;
    if (n_src < 1) return sl_fail(cx, SL_EARG, "Keine Quellzeilen");
    if (n_out < 0) return sl_fail(cx, SL_EARG, "n_out muss >= 0 sein");
    for (i = 0; i < n_out; i++) idx[i] = draw_int(r, n_src) + 1;
    return SL_OK;
}

int sl_boot_idx_block(sl_ctx *cx, sl_rng *r, int n_src, int n_out, int block_length, int circular,
                      int32_t *idx)
{
    int i = 0, n_start, start, len, t;
    if (n_src < 1) return sl_fail(cx, SL_EARG, "Keine Quellzeilen");
    if (block_length <= 0) return sl_fail(cx, SL_EARG, "block_length muss positiv sein");
    if (block_length > n_src)
        return sl_fail(cx, SL_EARG, "block_length (%d) ist größer als die Historie (%d Zeilen)", block_length, n_src);
    if (n_out < 0) return sl_fail(cx, SL_EARG, "n_out muss >= 0 sein");
    n_start = circular ? n_src : (n_src - block_length + 1);
    while (i < n_out) {
        start = draw_int(r, n_start);
        len = block_length < n_out - i ? block_length : n_out - i;
        for (t = 0; t < len; t++) idx[i + t] = ((start + t) % n_src) + 1;
        i += len;
    }
    return SL_OK;
}

int sl_boot_idx_stationary(sl_ctx *cx, sl_rng *r, int n_src, int n_out, double L, int32_t *idx)
{
    double p, g;
    int i = 0, len, start, t, st;
    if (n_src < 1) return sl_fail(cx, SL_EARG, "Keine Quellzeilen");
    if (!(L >= 1.0)) return sl_fail(cx, SL_EARG, "L muss >= 1 sein");
    if (n_out < 0) return sl_fail(cx, SL_EARG, "n_out muss >= 0 sein");
    p = 1.0 / L;
    while (i < n_out) {
        if (p >= 1.0) len = 1;
        else {
            st = sl_rgeom(cx, r, 1, p, &g);
            if (st != SL_OK) return st;
            len = g >= (double) n_out ? n_out : (int) g + 1;
        }
        start = draw_int(r, n_src);
        if (len > n_out - i) len = n_out - i;
        for (t = 0; t < len; t++) idx[i + t] = ((start + t) % n_src) + 1;
        i += len;
    }
    return SL_OK;
}

/* stationäre Verteilung (Potenziteration wie stationary_dist im eigenen Kern) */
static void stationary_dist(int K, const double *P, double *pi, double *nw)
{
    int it, i, j;
    for (j = 0; j < K; j++) pi[j] = 1.0 / K;
    for (it = 0; it < 2000; it++) {
        double s = 0.0, diff = 0.0;
        for (j = 0; j < K; j++) { nw[j] = 0.0; for (i = 0; i < K; i++) nw[j] += pi[i] * P[i + K * j]; s += nw[j]; }
        for (j = 0; j < K; j++) { nw[j] /= s; diff += fabs(nw[j] - pi[j]); }
        memcpy(pi, nw, (size_t) K * sizeof(double));
        if (diff < 1e-12) break;
    }
}

static int draw_from(sl_rng *r, const double *p, int K)
{
    double u = sl_unif01(r), c = 0.0;
    int k;
    for (k = 0; k < K; k++) { c += p[k]; if (u <= c) return k; }
    return K - 1;
}

int sl_boot_idx_regime(sl_ctx *cx, sl_rng *r, int n, const int32_t *regimes, int K,
                       const double *trans, int n_out, int32_t *idx)
{
    int *cnt, *off, *pool, i, k, t, cur;
    double *pi, *nw, *row, s = 0.0;
    if (K < 1) return sl_fail(cx, SL_EARG, "Übergangsmatrix ist leer");
    if (n_out < 0 || n < 0) return sl_fail(cx, SL_EARG, "n_out muss >= 0 sein");
    if (!slc_all_finite((int64_t) K * K, trans)) return sl_fail(cx, SL_ENONFINITE, "Übergangsmatrix enthält nicht endliche Werte");
    cnt = (int *) calloc((size_t) (2 * (K + 1) + n + 1), sizeof(int));
    pi = (double *) malloc(3 * (size_t) K * sizeof(double));
    if (cnt == NULL || pi == NULL) { free(cnt); free(pi); return sl_fail(cx, SL_ENOMEM, "Bootstrap: kein Speicher"); }
    off = cnt + (K + 1); pool = off + (K + 1);
    nw = pi + K; row = nw + K;
    for (i = 0; i < n; i++) { int g = regimes[i] - 1; if (g >= 0 && g < K) cnt[g]++; }
    off[0] = 0;
    for (k = 0; k < K; k++) off[k + 1] = off[k] + cnt[k];
    for (k = 0; k < K; k++) cnt[k] = 0;
    for (i = 0; i < n; i++) { int g = regimes[i] - 1; if (g >= 0 && g < K) pool[off[g] + cnt[g]++] = i; }
    if (off[K] == 0) { free(cnt); free(pi); return sl_fail(cx, SL_EARG, "Keine Beobachtungen in den Regimen"); }
    stationary_dist(K, trans, pi, nw);
    for (k = 0; k < K; k++) if (off[k + 1] == off[k]) pi[k] = 0.0;
    for (k = 0; k < K; k++) s += pi[k];
    for (k = 0; k < K; k++) pi[k] = s > 0 ? pi[k] / s : 1.0 / K;
    cur = draw_from(r, pi, K);
    for (t = 0; t < n_out; t++) {
        int g = cur;
        if (off[g + 1] == off[g]) for (k = 0; k < K; k++) if (off[k + 1] > off[k]) { g = k; break; }
        idx[t] = pool[off[g] + draw_int(r, off[g + 1] - off[g])] + 1;
        for (k = 0; k < K; k++) row[k] = trans[cur + K * k];
        cur = draw_from(r, row, K);
    }
    free(cnt); free(pi);
    return SL_OK;
}

int sl_boot_idx_tails(sl_ctx *cx, sl_rng *r, int n_out, double p_l, double p_r, int nb,
                      const int32_t *bulk_idx, int nl, const int32_t *left_idx, int nr,
                      const int32_t *right_idx, int32_t *idx)
{
    int t;
    if (nb == 0) return sl_fail(cx, SL_EARG, "Keine Bulk-Beobachtungen");
    if (n_out < 0) return sl_fail(cx, SL_EARG, "n_out muss >= 0 sein");
    for (t = 0; t < n_out; t++) {
        double u = sl_unif01(r);
        if (u < p_l && nl > 0) idx[t] = left_idx[draw_int(r, nl)];
        else if (u < p_l + p_r && nr > 0) idx[t] = right_idx[draw_int(r, nr)];
        else idx[t] = bulk_idx[draw_int(r, nb)];
    }
    return SL_OK;
}

/* ── Wertkerne ── */

int sl_boot_wild(sl_ctx *cx, sl_rng *r, int n, int k, const double *ret, int type, double *out)
{
    const double s5 = sqrt(5.0);
    const double mp = (s5 + 1.0) / (2.0 * s5), mneg = -(s5 - 1.0) / 2.0, mpos = (s5 + 1.0) / 2.0;
    double *mu;
    int i, j, st;
    if (type < 0 || type > 2) return sl_fail(cx, SL_EARG, "wild_type muss 0, 1 oder 2 sein (erhalten: %d)", type);
    if (n < 1 || k < 0) return sl_fail(cx, SL_ESMALL, "Keine Quellzeilen");
    mu = (double *) malloc(((size_t) k + 1) * sizeof(double));
    if (mu == NULL) return sl_fail(cx, SL_ENOMEM, "Bootstrap: kein Speicher");
    for (j = 0; j < k; j++) { double s = 0; for (i = 0; i < n; i++) s += ret[i + (size_t) n * j]; mu[j] = s / n; }
    for (i = 0; i < n; i++) {
        double w;
        if (type == 0) w = (sl_unif01(r) < 0.5) ? -1.0 : 1.0;
        else if (type == 1) w = (sl_unif01(r) < mp) ? mneg : mpos;
        else {
            st = sl_rnorm(cx, r, 1, 0.0, 1.0, &w);
            if (st != SL_OK) { free(mu); return st; }
        }
        for (j = 0; j < k; j++) out[i + (size_t) n * j] = mu[j] + (ret[i + (size_t) n * j] - mu[j]) * w;
    }
    free(mu);
    return SL_OK;
}

int sl_boot_reset(sl_ctx *cx, sl_rng *r, int n, int k, const double *ret, double p_break, double *out)
{
    int t, j, flipped = 0;
    if (!(p_break >= 0.0 && p_break <= 1.0)) return sl_fail(cx, SL_EARG, "p_break muss in [0, 1] liegen");
    for (t = 0; t < n; t++) {
        if (sl_unif01(r) < p_break) flipped = !flipped;
        for (j = 0; j < k; j++) {
            const double v = ret[t + (size_t) n * j];
            out[t + (size_t) n * j] = flipped ? 2.0 - v : v;
        }
    }
    return SL_OK;
}

/* GPD-Ziehung per Inversion */
static double rgpd(sl_rng *r, double scale, double shape)
{
    const double u = sl_unif01(r);
    if (fabs(shape) < 1e-10) return -scale * log(u);
    return scale * expm1(-shape * log(u)) / shape;
}

int sl_boot_evt(sl_ctx *cx, sl_rng *r, int n, int k, const double *ret, int base, int n_out,
                double p_l, double thresh_l, double scale_l, double shape_l, int nl, const int32_t *pool_l,
                double p_r, double thresh_r, double scale_r, double shape_r, int nr, const int32_t *pool_r,
                int nb, const int32_t *bulk_idx, double *out, int32_t *idx)
{
    int t, c, st;
    if (nb == 0) return sl_fail(cx, SL_EARG, "Keine Bulk-Beobachtungen");
    if (base < 0 || base >= k) return sl_fail(cx, SL_EARG, "interner Fehler: Basisreihe außerhalb 0 ... %d", k - 1);
    if ((st = check_idx(cx, nl, pool_l, n, "pool_l")) != SL_OK) return st;
    if ((st = check_idx(cx, nr, pool_r, n, "pool_r")) != SL_OK) return st;
    if ((st = check_idx(cx, nb, bulk_idx, n, "bulk_idx")) != SL_OK) return st;
    for (t = 0; t < n_out; t++) {
        const double u = sl_unif01(r);
        const int left = (u < p_l), right = (!left && p_r > 0 && u < p_l + p_r);
        if ((left && nl > 0) || (right && nr > 0)) {
            const double rb = left ? thresh_l - rgpd(r, scale_l, shape_l) : thresh_r + rgpd(r, scale_r, shape_r);
            const int j = left ? pool_l[draw_int(r, nl)] - 1 : pool_r[draw_int(r, nr)] - 1;
            for (c = 0; c < k; c++)
                out[t + (size_t) n_out * c] = (c == base) ? rb : rb * ret[j + (size_t) n * c] / ret[j + (size_t) n * base];
            idx[t] = j + 1;
        } else {
            const int j = bulk_idx[draw_int(r, nb)] - 1;
            for (c = 0; c < k; c++) out[t + (size_t) n_out * c] = ret[j + (size_t) n * c];
            idx[t] = j + 1;
        }
    }
    return SL_OK;
}

/* Nicht-Basisreihen (GARCH(1,1) je Reihe, gekoppelt über ratio oder eigenständig) */
typedef struct {
    int m, n_src;
    const int32_t *col, *ratio;
    const double *mu, *om, *al, *be, *z;
    double *s2, *eps;
} cross_state;

static int cross_init(sl_ctx *cx, cross_state *cs, int m, int n_src, int k, int base, const int32_t *cols,
                      const double *mu, const double *om, const double *al, const double *be,
                      const int32_t *ratio, const double *s2_init, const double *z)
{
    int c;
    cs->m = m; cs->n_src = n_src; cs->col = cols; cs->ratio = ratio;
    cs->mu = mu; cs->om = om; cs->al = al; cs->be = be; cs->z = z;
    cs->s2 = (double *) malloc(2 * ((size_t) m + 1) * sizeof(double));
    if (cs->s2 == NULL) return sl_fail(cx, SL_ENOMEM, "Bootstrap: kein Speicher");
    cs->eps = cs->s2 + m + 1;
    for (c = 0; c < m; c++) {
        if (cols[c] < 0 || cols[c] >= k || cols[c] == base) {
            free(cs->s2);
            return sl_fail(cx, SL_EARG, "interner Fehler: Spalte der Kopplung außerhalb 0 ... %d", k - 1);
        }
        cs->s2[c] = s2_init[c];
        cs->eps[c] = 0.0;
    }
    return SL_OK;
}

static void cross_step(cross_state *cs, double *out, int n_out, int t, double base_ret, int tstar)
{
    int c;
    for (c = 0; c < cs->m; c++) {
        double s2 = cs->om[c] + cs->al[c] * cs->eps[c] * cs->eps[c] + cs->be[c] * cs->s2[c], e, g;
        if (s2 < VFLOOR) s2 = VFLOOR;
        cs->s2[c] = s2;
        e = sqrt(s2) * cs->z[tstar + (size_t) cs->n_src * c];
        cs->eps[c] = e;
        g = 1.0 + cs->mu[c] + e;
        out[t + (size_t) n_out * cs->col[c]] = cs->ratio[c] ? base_ret * g : g;
    }
}

int sl_boot_garch(sl_ctx *cx, sl_rng *r, int n_out, int base, int k, double mu, double omega,
                  double alpha, double beta, double gamma, double s2_init, int n_src,
                  const double *z_base, int nv, const int32_t *valid, int m, const int32_t *cross_cols,
                  const double *cmu, const double *com, const double *cal, const double *cbe,
                  const int32_t *cratio, const double *cs2, const double *z_cross, double *out,
                  int32_t *idx)
{
    cross_state cs;
    double s2 = s2_init, eps = 0.0;
    int t, st;
    if (omega <= 0) return sl_fail(cx, SL_EARG, "omega muss > 0 sein");
    if (nv == 0) return sl_fail(cx, SL_EARG, "Keine gültigen Residuen");
    if (base < 0 || base >= k) return sl_fail(cx, SL_EARG, "interner Fehler: Basisreihe außerhalb 0 ... %d", k - 1);
    if ((st = check_idx(cx, nv, valid, n_src, "valid")) != SL_OK) return st;
    if ((st = cross_init(cx, &cs, m, n_src, k, base, cross_cols, cmu, com, cal, cbe, cratio, cs2, z_cross)) != SL_OK) return st;
    for (t = 0; t < n_out; t++) {
        const double ind = (eps < 0.0) ? 1.0 : 0.0;
        double rb;
        int ts;
        s2 = omega + (alpha + gamma * ind) * eps * eps + beta * s2;
        if (s2 < VFLOOR) s2 = VFLOOR;
        ts = valid[draw_int(r, nv)] - 1;
        eps = sqrt(s2) * z_base[ts];
        rb = 1.0 + mu + eps;
        out[t + (size_t) n_out * base] = rb;
        cross_step(&cs, out, n_out, t, rb, ts);
        idx[t] = ts + 1;
    }
    free(cs.s2);
    return SL_OK;
}

int sl_boot_ms_garch(sl_ctx *cx, sl_rng *r, int n_out, int base, int k, int K, const double *mu,
                     const double *omega, const double *alpha, const double *beta,
                     const double *gamma, const double *phi, const double *lambda,
                     const double *trans, const double *delta, const double *unc_var,
                     const double *stat_prob, const int32_t *pool_off, const int32_t *pool_idx,
                     int n_src, const double *z_base, int m, const int32_t *cross_cols,
                     const double *cmu, const double *com, const double *cal, const double *cbe,
                     const int32_t *cratio, const double *cs2, const double *z_cross, double *out,
                     int32_t *idx, int32_t *regime)
{
    cross_state cs;
    double *pr, s2, eps = 0.0, prev = 0.0;
    int i, j, t, st, rg, tvtp = 0;
    if (K < 1) return sl_fail(cx, SL_EARG, "Anzahl Regime muss >= 1 sein");
    if (base < 0 || base >= k) return sl_fail(cx, SL_EARG, "interner Fehler: Basisreihe außerhalb 0 ... %d", k - 1);
    for (i = 0; i < K; i++) {
        double rs = 0;
        for (j = 0; j < K; j++) rs += trans[i + K * j];
        if (fabs(rs - 1.0) > 1e-6) return sl_fail(cx, SL_EARG, "Zeile %d der Uebergangsmatrix summiert nicht auf 1", i + 1);
        if (unc_var[i] <= 0) return sl_fail(cx, SL_EARG, "unc_var[%d] <= 0", i + 1);
    }
    if (pool_off[0] != 0) return sl_fail(cx, SL_EARG, "interner Fehler: Grenzen der Regime-Pools");
    for (i = 0; i < K; i++) if (pool_off[i + 1] < pool_off[i]) return sl_fail(cx, SL_EARG, "interner Fehler: Grenzen der Regime-Pools");
    if ((st = check_idx(cx, pool_off[K], pool_idx, n_src, "pools")) != SL_OK) return st;
    if (pool_off[K] == 0) return sl_fail(cx, SL_EARG, "Keine Beobachtungen in den Regime-Pools");
    for (i = 0; i < K; i++) for (j = 0; j < K; j++) if (fabs(delta[i + K * j]) > 1e-12) tvtp = 1;
    pr = (double *) malloc((size_t) K * sizeof(double));
    if (pr == NULL) return sl_fail(cx, SL_ENOMEM, "Bootstrap: kein Speicher");
    if ((st = cross_init(cx, &cs, m, n_src, k, base, cross_cols, cmu, com, cal, cbe, cratio, cs2, z_cross)) != SL_OK) {
        free(pr);
        return st;
    }
    rg = draw_from(r, stat_prob, K);
    s2 = unc_var[rg];
    for (t = 0; t < n_out; t++) {
        double ind, sig, mm, ex, rb;
        int g, ts;
        if (t > 0) {
            const int old = rg;
            if (tvtp) {
                double x = s2 / unc_var[old] - 1.0, mx = -1e300, se = 0.0;
                if (x > 10.0) x = 10.0;
                if (x < -0.99) x = -0.99;
                for (j = 0; j < K; j++) {
                    const double b = trans[old + K * j] > 1e-10 ? trans[old + K * j] : 1e-10;
                    pr[j] = log(b) + delta[old + K * j] * x;
                    if (pr[j] > mx) mx = pr[j];
                }
                for (j = 0; j < K; j++) { pr[j] = exp(pr[j] - mx); se += pr[j]; }
                for (j = 0; j < K; j++) pr[j] /= se;
            } else {
                for (j = 0; j < K; j++) pr[j] = trans[old + K * j];
            }
            rg = draw_from(r, pr, K);
            if (rg != old) s2 = 0.5 * s2 + 0.5 * unc_var[rg];     /* Varianz-Glättung beim Regimewechsel */
        }
        ind = (eps < 0.0) ? 1.0 : 0.0;
        s2 = omega[rg] + (alpha[rg] + gamma[rg] * ind) * eps * eps + beta[rg] * s2;
        if (s2 < VFLOOR) s2 = VFLOOR;
        sig = sqrt(s2);
        g = rg;
        if (pool_off[g + 1] == pool_off[g]) for (i = 0; i < K; i++) if (pool_off[i + 1] > pool_off[i]) { g = i; break; }
        ts = pool_idx[pool_off[g] + draw_int(r, pool_off[g + 1] - pool_off[g])] - 1;
        eps = sig * z_base[ts];
        mm = mu[rg] + phi[rg] * prev + lambda[rg] * sig;
        ex = mm + eps;
        rb = 1.0 + ex;
        out[t + (size_t) n_out * base] = rb;
        prev = ex;
        cross_step(&cs, out, n_out, t, rb, ts);
        idx[t] = ts + 1;
        regime[t] = rg + 1;
    }
    free(pr); free(cs.s2);
    return SL_OK;
}

/* ── ohne Zufall ── */

int sl_rolling_vol(sl_ctx *cx, int n, const double *x, int window, double *vol)
{
    double sum = 0.0, sq = 0.0;
    int i;
    if (window <= 0) return sl_fail(cx, SL_EARG, "window muss positiv sein");
    if (window > n) window = n;
    for (i = 0; i < n; i++) {
        const double v = x[i] - 1.0;
        int cnt;
        sum += v; sq += v * v;
        if (i >= window) { const double o = x[i - window] - 1.0; sum -= o; sq -= o * o; }
        cnt = (i + 1) < window ? (i + 1) : window;
        if (cnt <= 1) vol[i] = 0.0;
        else {
            const double m = sum / cnt, q = (sq - cnt * m * m) / (cnt - 1);
            vol[i] = sqrt(q > 0.0 ? q : 0.0);
        }
    }
    return SL_OK;
}

int sl_assign_regimes(sl_ctx *cx, int n, const double *vol, int nth, const double *thresh, int32_t *reg)
{
    const int K = nth - 1;
    int i, k;
    if (K < 1) return sl_fail(cx, SL_EARG, "mindestens zwei Schwellen");
    for (i = 0; i < n; i++) {
        reg[i] = K;
        for (k = 0; k < K; k++) if (vol[i] >= thresh[k] && vol[i] < thresh[k + 1]) { reg[i] = k + 1; break; }
    }
    return SL_OK;
}

int sl_estimate_trans_mat(sl_ctx *cx, int n, const int32_t *regimes, int K, double alpha, double *P)
{
    int t, i, j;
    if (K < 1) return sl_fail(cx, SL_EARG, "K muss >= 1 sein");
    for (i = 0; i < K * K; i++) P[i] = 0.0;
    for (t = 1; t < n; t++) {
        const int a = regimes[t - 1] - 1, b = regimes[t] - 1;
        if (a >= 0 && a < K && b >= 0 && b < K) P[a + K * b] += 1.0;
    }
    for (i = 0; i < K; i++) {
        double s = 0.0;
        for (j = 0; j < K; j++) { P[i + K * j] += alpha; s += P[i + K * j]; }
        for (j = 0; j < K; j++) P[i + K * j] /= s;
    }
    return SL_OK;
}
