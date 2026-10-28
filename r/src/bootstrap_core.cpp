// src/bootstrap_core.cpp
// Bootstrap-Kerne fuer SimLev (portiert und verallgemeinert aus '00 Bootstraps')
//
// Designprinzip: Jeder Kern liefert die QUELLZEILEN (1-basiert) der gezogenen
// Beobachtungen zurueck. Zeilen-Resampling-Verfahren (IID, Block, Stationaer,
// Regime, Tails) erzeugen NUR Indizes; Renditen und Zusatzreihen (Zinsen,
// Inflation, Kalendertage) werden in R ueber denselben Index gezogen. So bleiben
// Querschnitts-Abhaengigkeiten zwischen allen Reihen exakt erhalten.
//
// Parametrische Verfahren (Wild, Reset, EVT, GARCH-Familie) liefern zusaetzlich
// die simulierte Renditematrix. Bei GARCH-Verfahren wird je Simulationstag EIN
// historisches Datum t* gezogen und dessen standardisierte Residuen fuer ALLE
// Reihen verwendet (Filtered Historical Simulation, Barone-Adesi et al. 1999);
// t* ist dann auch die Quellzeile fuer Zusatzreihen.
//
// Zufallszahlen: ausschliesslich Rf_runif / Rf_rgeom / Rf_rnorm (R-RNG), damit
// set.seed() und L'Ecuyer-Streams (parallel::nextRNGStream) reproduzierbar
// greifen; GetRNGstate/PutRNGstate setzt die .Call-Huelle (simlev_capi.h).
// R's RNG ist nicht threadsicher: keine OpenMP-Parallelisierung in diesen Kernen.
//
// Referenzen: Efron (1979); Kuensch (1989); Politis & Romano (1992, 1994);
// Wu (1986), Mammen (1993); Bollerslev (1986); Glosten, Jagannathan & Runkle
// (1993); Barone-Adesi, Giannopoulos & Vosper (1999); Haas, Mittnik &
// Paolella (2004); Diebold, Lee & Weinbach (1994, TVTP).

#include "simlev_capi.h"
#include <vector>
#include <cmath>
#include <algorithm>
using sl::stop;

static inline int draw_int(int n) {            // gleichverteilt in {0, ..., n-1}
  int k = (int) std::floor(Rf_runif(0.0, (double) n));
  return k >= n ? n - 1 : k;
}

// ===========================================================================
// INDEX-KERNE (reines Zeilen-Resampling)
// ===========================================================================

// IID-Bootstrap (Efron 1979): Zeilen gleichverteilt mit Zuruecklegen.
static SEXP boot_idx_iid(int n_src, int n_out) {
  if (n_src < 1) stop("Keine Quellzeilen");
  sl::IntVec idx = sl::new_int(n_out);
  for (int i = 0; i < n_out; i++) idx[i] = draw_int(n_src) + 1;
  return idx.sexp;
}

// Block-Bootstrap mit fester Blocklaenge.
// circular = false: Moving Block Bootstrap (Kuensch 1989), Starts in 0..n-b.
// circular = true : Circular Block Bootstrap (Politis & Romano 1992), Starts in
//                   0..n-1 mit Umlauf; jede Beobachtung gleich wahrscheinlich.
static SEXP boot_idx_block(int n_src, int n_out, int block_length, bool circular) {
  if (n_src < 1) stop("Keine Quellzeilen");
  if (block_length <= 0) stop("block_length muss positiv sein");
  if (block_length > n_src) stop("block_length (%d) ist gr\u00f6\u00dfer als die Historie (%d Zeilen)", block_length, n_src);
  sl::IntVec idx = sl::new_int(n_out);
  int i = 0;
  int n_start = circular ? n_src : (n_src - block_length + 1);
  while (i < n_out) {
    int start = draw_int(n_start);
    int len = std::min(block_length, n_out - i);
    for (int t = 0; t < len; t++) idx[i + t] = ((start + t) % n_src) + 1;
    i += len;
  }
  return idx.sexp;
}

// Stationaerer Bootstrap (Politis & Romano 1994): geometrische Blocklaengen
// mit Erwartungswert L, zirkulaerer Umlauf.
static SEXP boot_idx_stationary(int n_src, int n_out, double L) {
  if (n_src < 1) stop("Keine Quellzeilen");
  if (!(L >= 1.0)) stop("L muss >= 1 sein");
  sl::IntVec idx = sl::new_int(n_out);
  double p = 1.0 / L;
  int i = 0;
  while (i < n_out) {
    int len = (p >= 1.0) ? 1 : (int) Rf_rgeom(p) + 1;
    int start = draw_int(n_src);
    len = std::min(len, n_out - i);
    for (int t = 0; t < len; t++) idx[i + t] = ((start + t) % n_src) + 1;
    i += len;
  }
  return idx.sexp;
}

// Stationaere Verteilung einer Uebergangsmatrix (Potenziteration)
static std::vector<double> stationary_dist(const sl::NumMat& P) {
  int K = P.nrow();
  std::vector<double> pi(K, 1.0 / K), nw(K);
  for (int it = 0; it < 2000; it++) {
    double s = 0.0, diff = 0.0;
    for (int j = 0; j < K; j++) { nw[j] = 0.0; for (int i = 0; i < K; i++) nw[j] += pi[i] * P(i, j); s += nw[j]; }
    for (int j = 0; j < K; j++) { nw[j] /= s; diff += std::fabs(nw[j] - pi[j]); }
    pi = nw;
    if (diff < 1e-12) break;
  }
  return pi;
}

static int draw_from(const double* p, int K) {
  double u = Rf_runif(0.0, 1.0), c = 0.0;
  for (int r = 0; r < K; r++) { c += p[r]; if (u <= c) return r; }
  return K - 1;
}

// Volatilitaets-Regime-Bootstrap: Markov-Kette ueber diskretisierte Regime,
// innerhalb eines Regimes IID-Ziehung aus dessen Beobachtungen.
static SEXP boot_idx_regime(sl::IntVec regimes, sl::NumMat trans, int n_out) {
  int n = regimes.size(), K = trans.nrow();
  std::vector<std::vector<int>> pool(K);
  for (int i = 0; i < n; i++) { int r = regimes[i] - 1; if (r >= 0 && r < K) pool[r].push_back(i); }
  std::vector<double> pi = stationary_dist(trans);
  for (int r = 0; r < K; r++) if (pool[r].empty()) pi[r] = 0.0;
  double s = 0.0; for (int r = 0; r < K; r++) s += pi[r];
  for (int r = 0; r < K; r++) pi[r] = s > 0 ? pi[r] / s : 1.0 / K;
  int cur = draw_from(pi.data(), K);
  sl::IntVec idx = sl::new_int(n_out);
  std::vector<double> row(K);
  for (int t = 0; t < n_out; t++) {
    const std::vector<int>* p = &pool[cur];
    if (p->empty()) for (int r = 0; r < K; r++) if (!pool[r].empty()) { p = &pool[r]; break; }
    idx[t] = (*p)[draw_int((int) p->size())] + 1;
    for (int r = 0; r < K; r++) row[r] = trans(cur, r);
    cur = draw_from(row.data(), K);
  }
  return idx.sexp;
}

// Empirischer Tail-Bootstrap: Mischung aus linkem Rand (Tail), Kernbereich (Bulk) und rechtem Rand
// mit den Wahrscheinlichkeiten p_l, 1 - p_l - p_r, p_r.
static SEXP boot_idx_tails(int n_out, double p_l, double p_r,
                           sl::IntVec bulk_idx, sl::IntVec left_idx, sl::IntVec right_idx) {
  int nb = bulk_idx.size(), nl = left_idx.size(), nr = right_idx.size();
  if (nb == 0) stop("Keine Bulk-Beobachtungen");
  sl::IntVec idx = sl::new_int(n_out);
  for (int t = 0; t < n_out; t++) {
    double u = Rf_runif(0.0, 1.0);
    if (u < p_l && nl > 0)             idx[t] = left_idx[draw_int(nl)];
    else if (u < p_l + p_r && nr > 0)  idx[t] = right_idx[draw_int(nr)];
    else                               idx[t] = bulk_idx[draw_int(nb)];
  }
  return idx.sexp;
}

// ===========================================================================
// MATRIX-KERNE
// ===========================================================================

// Wild Bootstrap (Wu 1986; Liu 1988; Mammen 1993): x*_t = mu + (x_t - mu) w_t
// mit gemeinsamem Gewicht w_t fuer alle Reihen (Querschnitt bleibt erhalten).
// type: 0 = Rademacher, 1 = Mammen, 2 = Standardnormal.
static SEXP boot_wild(sl::NumMat returns, int type) {
  if (type < 0 || type > 2) stop("wild_type muss 0, 1 oder 2 sein (erhalten: %d)", type);
  int n = returns.nrow(), k = returns.ncol();
  sl::NumMat out = sl::new_mat(n, k);
  std::vector<double> mu(k, 0.0);
  for (int j = 0; j < k; j++) { double s = 0; for (int i = 0; i < n; i++) s += returns(i, j); mu[j] = s / n; }
  const double s5 = std::sqrt(5.0);
  const double mp = (s5 + 1.0) / (2.0 * s5), mneg = -(s5 - 1.0) / 2.0, mpos = (s5 + 1.0) / 2.0;
  for (int i = 0; i < n; i++) {
    double w;
    if (type == 0)      w = (Rf_runif(0, 1) < 0.5) ? -1.0 : 1.0;
    else if (type == 1) w = (Rf_runif(0, 1) < mp) ? mneg : mpos;
    else                w = Rf_rnorm(0.0, 1.0);
    for (int j = 0; j < k; j++) out(i, j) = mu[j] + (returns(i, j) - mu[j]) * w;
  }
  return out.sexp;
}

// Reset-/Sign-Flip-Bootstrap: chronologische Reihe, Segmente mit
// Wahrscheinlichkeit p_break umgeschaltet und dann um 1 gespiegelt (2 - R).
static SEXP boot_reset(sl::NumMat returns, double p_break) {
  if (!(p_break >= 0.0 && p_break <= 1.0)) stop("p_break muss in [0, 1] liegen");
  int n = returns.nrow(), k = returns.ncol();
  sl::NumMat out = sl::new_mat(n, k);
  bool flipped = false;
  for (int t = 0; t < n; t++) {
    if (Rf_runif(0, 1) < p_break) flipped = !flipped;
    for (int j = 0; j < k; j++) out(t, j) = flipped ? 2.0 - returns(t, j) : returns(t, j);
  }
  return out.sexp;
}

static inline double rgpd(double scale, double shape) {
  double u = Rf_runif(0.0, 1.0);
  if (u <= 0.0) u = 1e-300;
  if (std::fabs(shape) < 1e-10) return -scale * std::log(u);
  return scale * (std::pow(u, -shape) - 1.0) / shape;
}

// EVT-Bootstrap (semiparametrisch): Kernbereich (Bulk) = empirische Zeilen, Raender (Tails) der
// Basisreihe aus der Generalisierten Pareto-Verteilung. Die uebrigen Reihen
// werden im Tail ueber das historische Verhaeltnis R_c / R_base einer
// gezogenen Tail-Zeile gekoppelt (verallgemeinert den FX-Pool des Originals).
// Rueckgabe: list(ret, idx)
static SEXP boot_evt(sl::NumMat returns, int base, int n_out,
                     double p_l, double thresh_l, double scale_l, double shape_l, sl::IntVec pool_l,
                     double p_r, double thresh_r, double scale_r, double shape_r, sl::IntVec pool_r,
                     sl::IntVec bulk_idx) {
  int k = returns.ncol(), nb = bulk_idx.size(), nl = pool_l.size(), nr = pool_r.size();
  if (nb == 0) stop("Keine Bulk-Beobachtungen");
  sl::NumMat out = sl::new_mat(n_out, k);
  sl::IntVec idx = sl::new_int(n_out);
  for (int t = 0; t < n_out; t++) {
    double u = Rf_runif(0.0, 1.0);
    bool left = (u < p_l), right = (!left && p_r > 0 && u < p_l + p_r);
    if ((left && nl > 0) || (right && nr > 0)) {
      double rb = left ? thresh_l - rgpd(scale_l, shape_l) : thresh_r + rgpd(scale_r, shape_r);
      int j = left ? pool_l[draw_int(nl)] - 1 : pool_r[draw_int(nr)] - 1;
      for (int c = 0; c < k; c++) out(t, c) = (c == base) ? rb : rb * returns(j, c) / returns(j, base);
      idx[t] = j + 1;
    } else {
      int j = bulk_idx[draw_int(nb)] - 1;
      for (int c = 0; c < k; c++) out(t, c) = returns(j, c);
      idx[t] = j + 1;
    }
  }
  return sl::named_list("ret", out, "idx", idx);
}

// Gemeinsamer Teil fuer Nicht-Basisreihen ("cross"-Modelle): GARCH(1,1) je
// Reihe, gekoppelt an die Basisreihe (ratio) oder eigenstaendig (joint).
struct CrossState {
  int m;
  std::vector<int> col;
  std::vector<double> mu, om, al, be, s2, eps;
  std::vector<bool> ratio;
};

static CrossState init_cross(sl::IntVec cols, sl::NumVec mu, sl::NumVec om, sl::NumVec al,
                             sl::NumVec be, sl::LglVec ratio, sl::NumVec s2_init) {
  CrossState cs; cs.m = cols.size();
  for (int c = 0; c < cs.m; c++) {
    cs.col.push_back(cols[c]); cs.mu.push_back(mu[c]); cs.om.push_back(om[c]);
    cs.al.push_back(al[c]); cs.be.push_back(be[c]); cs.ratio.push_back(ratio[c]);
    cs.s2.push_back(s2_init[c]); cs.eps.push_back(0.0);
  }
  return cs;
}

static inline void step_cross(CrossState& cs, sl::NumMat& out, int t, double base_ret,
                              const sl::NumMat& z_cross, int tstar) {
  for (int c = 0; c < cs.m; c++) {
    double s2 = cs.om[c] + cs.al[c] * cs.eps[c] * cs.eps[c] + cs.be[c] * cs.s2[c];
    if (s2 < 1e-14) s2 = 1e-14;
    cs.s2[c] = s2;
    double e = std::sqrt(s2) * z_cross(tstar, c);
    cs.eps[c] = e;
    double g = 1.0 + cs.mu[c] + e;
    out(t, cs.col[c]) = cs.ratio[c] ? base_ret * g : g;
  }
}

// GARCH(1,1) bzw. GJR-GARCH(1,1) mit Filtered Historical Simulation.
// Basisreihe: sigma2_t = omega + (alpha + gamma * I[eps<0]) eps^2 + beta sigma2.
// Je Tag wird ein historisches Datum t* aus 'valid' gezogen; z_base[t*] und
// z_cross[t*, ] treiben alle Reihen gemeinsam.
static SEXP boot_garch(int n_out, int base, int k,
                       double mu, double omega, double alpha, double beta, double gamma,
                       double s2_init, sl::NumVec z_base, sl::IntVec valid,
                       sl::IntVec cross_cols, sl::NumVec cmu, sl::NumVec com,
                       sl::NumVec cal, sl::NumVec cbe, sl::LglVec cratio,
                       sl::NumVec cs2, sl::NumMat z_cross) {
  if (omega <= 0) stop("omega muss > 0 sein");
  int nv = valid.size();
  if (nv == 0) stop("Keine g\u00fcltigen Residuen");
  sl::NumMat out = sl::new_mat(n_out, k);
  sl::IntVec idx = sl::new_int(n_out);
  CrossState cs = init_cross(cross_cols, cmu, com, cal, cbe, cratio, cs2);
  double s2 = s2_init, eps = 0.0;
  for (int t = 0; t < n_out; t++) {
    double ind = (eps < 0.0) ? 1.0 : 0.0;
    s2 = omega + (alpha + gamma * ind) * eps * eps + beta * s2;
    if (s2 < 1e-14) s2 = 1e-14;
    int ts = valid[draw_int(nv)] - 1;
    eps = std::sqrt(s2) * z_base[ts];
    double rb = 1.0 + mu + eps;
    out(t, base) = rb;
    step_cross(cs, out, t, rb, z_cross, ts);
    idx[t] = ts + 1;
  }
  return sl::named_list("ret", out, "idx", idx);
}

// Markov-Switching-(AR-)GJR-GARCH(-M) mit optional zeitvariablen
// Uebergangswahrscheinlichkeiten (TVTP). Deckt ms_garch (phi = lambda = 0,
// delta = 0), ms_ar_garch_m (delta = 0) und tvtp_ms_garch ab.
//   sigma2_t = omega_r + (alpha_r + gamma_r I[eps<0]) eps^2 + beta_r sigma2
//   mean_t   = mu_r + phi_r * r_{t-1} + lambda_r * sigma_t
//   logit P_ij(t) = log P_ij + delta_ij * (sigma2_t / unc_var_i - 1)
// Residuen: t* wird aus den historischen Tagen des aktuellen Regimes gezogen.
static SEXP boot_ms_garch(int n_out, int base, int k, int K,
                          sl::NumVec mu, sl::NumVec omega, sl::NumVec alpha,
                          sl::NumVec beta, sl::NumVec gamma,
                          sl::NumVec phi, sl::NumVec lambda,
                          sl::NumMat trans, sl::NumMat delta, sl::NumVec unc_var,
                          sl::NumVec stat_prob, SEXP pools, sl::NumVec z_base,
                          sl::IntVec cross_cols, sl::NumVec cmu, sl::NumVec com,
                          sl::NumVec cal, sl::NumVec cbe, sl::LglVec cratio,
                          sl::NumVec cs2, sl::NumMat z_cross) {
  for (int i = 0; i < K; i++) {
    double rs = 0; for (int j = 0; j < K; j++) rs += trans(i, j);
    if (std::fabs(rs - 1.0) > 1e-6) stop("Zeile %d der Uebergangsmatrix summiert nicht auf 1", i + 1);
    if (unc_var[i] <= 0) stop("unc_var[%d] <= 0", i + 1);
  }
  std::vector<std::vector<int>> pl(K);
  for (int r = 0; r < K; r++) { sl::IntVec p = sl::int_vec(sl::at(pools, r)); for (int j = 0; j < p.size(); j++) pl[r].push_back(p[j] - 1); }
  bool tvtp = false;
  for (int i = 0; i < K; i++) for (int j = 0; j < K; j++) if (std::fabs(delta(i, j)) > 1e-12) tvtp = true;

  sl::NumMat out = sl::new_mat(n_out, k);
  sl::IntVec idx = sl::new_int(n_out), reg = sl::new_int(n_out);
  CrossState cs = init_cross(cross_cols, cmu, com, cal, cbe, cratio, cs2);
  std::vector<double> sp(stat_prob.begin(), stat_prob.end()), pr(K);
  int r = draw_from(sp.data(), K);
  double s2 = unc_var[r], eps = 0.0, prev = 0.0;
  for (int t = 0; t < n_out; t++) {
    if (t > 0) {
      int old = r;
      if (tvtp) {
        double x = s2 / unc_var[old] - 1.0;
        x = std::min(10.0, std::max(-0.99, x));
        double mx = -1e300;
        for (int j = 0; j < K; j++) { double b = std::max(trans(old, j), 1e-10); pr[j] = std::log(b) + delta(old, j) * x; mx = std::max(mx, pr[j]); }
        double se = 0.0; for (int j = 0; j < K; j++) { pr[j] = std::exp(pr[j] - mx); se += pr[j]; }
        for (int j = 0; j < K; j++) pr[j] /= se;
      } else {
        for (int j = 0; j < K; j++) pr[j] = trans(old, j);
      }
      r = draw_from(pr.data(), K);
      if (r != old) s2 = 0.5 * s2 + 0.5 * unc_var[r];     // Varianz-Glaettung beim Regimewechsel
    }
    double ind = (eps < 0.0) ? 1.0 : 0.0;
    s2 = omega[r] + (alpha[r] + gamma[r] * ind) * eps * eps + beta[r] * s2;
    if (s2 < 1e-14) s2 = 1e-14;
    double sig = std::sqrt(s2);
    const std::vector<int>* p = &pl[r];
    if (p->empty()) for (int q = 0; q < K; q++) if (!pl[q].empty()) { p = &pl[q]; break; }
    int ts = (*p)[draw_int((int) p->size())];
    eps = sig * z_base[ts];
    double m = mu[r] + phi[r] * prev + lambda[r] * sig;
    double ex = m + eps;
    double rb = 1.0 + ex;
    out(t, base) = rb;
    prev = ex;
    step_cross(cs, out, t, rb, z_cross, ts);
    idx[t] = ts + 1; reg[t] = r + 1;
  }
  return sl::named_list("ret", out, "idx", idx, "regime", reg);
}

// ===========================================================================
// HILFSFUNKTIONEN
// ===========================================================================

// Rollierende Volatilitaet (Bessel-korrigiert) der Ueberschussrendite x - 1.
static SEXP rolling_vol(sl::NumVec x, int window) {
  int n = x.size();
  if (window <= 0) stop("window muss positiv sein");
  if (window > n) window = n;
  sl::NumVec vol = sl::new_num(n);
  double sum = 0.0, sq = 0.0;
  for (int i = 0; i < n; i++) {
    double v = x[i] - 1.0; sum += v; sq += v * v;
    if (i >= window) { double o = x[i - window] - 1.0; sum -= o; sq -= o * o; }
    int cnt = std::min(i + 1, window);
    if (cnt <= 1) vol[i] = 0.0;
    else { double m = sum / cnt; vol[i] = std::sqrt(std::max(0.0, (sq - cnt * m * m) / (cnt - 1))); }
  }
  return vol.sexp;
}

// Regime-Zuordnung ueber Schwellen [tau_r, tau_{r+1})
static SEXP assign_regimes(sl::NumVec vol, sl::NumVec thresh) {
  int n = vol.size(), K = thresh.size() - 1;
  sl::IntVec reg = sl::new_int(n);
  for (int i = 0; i < n; i++) {
    reg[i] = K;
    for (int r = 0; r < K; r++) if (vol[i] >= thresh[r] && vol[i] < thresh[r + 1]) { reg[i] = r + 1; break; }
  }
  return reg.sexp;
}

// Uebergangsmatrix mit Laplace-/Dirichlet-Glaettung alpha
static SEXP estimate_trans_mat(sl::IntVec regimes, int K, double alpha) {
  sl::NumMat P = sl::new_mat(K, K);
  int n = regimes.size();
  for (int t = 1; t < n; t++) {
    int a = regimes[t - 1] - 1, b = regimes[t] - 1;
    if (a >= 0 && a < K && b >= 0 && b < K) P(a, b) += 1.0;
  }
  for (int r = 0; r < K; r++) {
    double s = 0.0;
    for (int c = 0; c < K; c++) { P(r, c) += alpha; s += P(r, c); }
    for (int c = 0; c < K; c++) P(r, c) /= s;
  }
  return P.sexp;
}

// ===========================================================================
// .CALL-HUELLEN (registriert in init.c; R-Seite in R/cores.R)
// ===========================================================================

extern "C" SEXP C_boot_idx_iid(SEXP s_n_src, SEXP s_n_out) {
  return sl::call([&]() {
    int n_src = sl::as_int(s_n_src);
    int n_out = sl::as_int(s_n_out);
    return boot_idx_iid(n_src, n_out);
  });
}

extern "C" SEXP C_boot_idx_block(SEXP s_n_src, SEXP s_n_out, SEXP s_block_length, SEXP s_circular) {
  return sl::call([&]() {
    int n_src = sl::as_int(s_n_src);
    int n_out = sl::as_int(s_n_out);
    int block_length = sl::as_int(s_block_length);
    bool circular = sl::as_bool(s_circular);
    return boot_idx_block(n_src, n_out, block_length, circular);
  });
}

extern "C" SEXP C_boot_idx_stationary(SEXP s_n_src, SEXP s_n_out, SEXP s_L) {
  return sl::call([&]() {
    int n_src = sl::as_int(s_n_src);
    int n_out = sl::as_int(s_n_out);
    double L = sl::as_double(s_L);
    return boot_idx_stationary(n_src, n_out, L);
  });
}

extern "C" SEXP C_boot_idx_regime(SEXP s_regimes, SEXP s_trans, SEXP s_n_out) {
  return sl::call([&]() {
    sl::IntVec regimes = sl::int_vec(s_regimes);
    sl::NumMat trans = sl::num_mat(s_trans);
    int n_out = sl::as_int(s_n_out);
    return boot_idx_regime(regimes, trans, n_out);
  });
}

extern "C" SEXP C_boot_idx_tails(SEXP s_n_out, SEXP s_p_l, SEXP s_p_r, SEXP s_bulk_idx,
                                 SEXP s_left_idx, SEXP s_right_idx) {
  return sl::call([&]() {
    int n_out = sl::as_int(s_n_out);
    double p_l = sl::as_double(s_p_l);
    double p_r = sl::as_double(s_p_r);
    sl::IntVec bulk_idx = sl::int_vec(s_bulk_idx);
    sl::IntVec left_idx = sl::int_vec(s_left_idx);
    sl::IntVec right_idx = sl::int_vec(s_right_idx);
    return boot_idx_tails(n_out, p_l, p_r, bulk_idx, left_idx, right_idx);
  });
}

extern "C" SEXP C_boot_wild(SEXP s_returns, SEXP s_type) {
  return sl::call([&]() {
    sl::NumMat returns = sl::num_mat(s_returns);
    int type = sl::as_int(s_type);
    return boot_wild(returns, type);
  });
}

extern "C" SEXP C_boot_reset(SEXP s_returns, SEXP s_p_break) {
  return sl::call([&]() {
    sl::NumMat returns = sl::num_mat(s_returns);
    double p_break = sl::as_double(s_p_break);
    return boot_reset(returns, p_break);
  });
}

extern "C" SEXP C_boot_evt(SEXP s_returns, SEXP s_base, SEXP s_n_out, SEXP s_p_l, SEXP s_thresh_l,
                           SEXP s_scale_l, SEXP s_shape_l, SEXP s_pool_l, SEXP s_p_r, SEXP s_thresh_r,
                           SEXP s_scale_r, SEXP s_shape_r, SEXP s_pool_r, SEXP s_bulk_idx) {
  return sl::call([&]() {
    sl::NumMat returns = sl::num_mat(s_returns);
    int base = sl::as_int(s_base);
    int n_out = sl::as_int(s_n_out);
    double p_l = sl::as_double(s_p_l);
    double thresh_l = sl::as_double(s_thresh_l);
    double scale_l = sl::as_double(s_scale_l);
    double shape_l = sl::as_double(s_shape_l);
    sl::IntVec pool_l = sl::int_vec(s_pool_l);
    double p_r = sl::as_double(s_p_r);
    double thresh_r = sl::as_double(s_thresh_r);
    double scale_r = sl::as_double(s_scale_r);
    double shape_r = sl::as_double(s_shape_r);
    sl::IntVec pool_r = sl::int_vec(s_pool_r);
    sl::IntVec bulk_idx = sl::int_vec(s_bulk_idx);
    return boot_evt(returns, base, n_out, p_l, thresh_l, scale_l, shape_l, pool_l,
                    p_r, thresh_r, scale_r, shape_r, pool_r, bulk_idx);
  });
}

extern "C" SEXP C_boot_garch(SEXP s_n_out, SEXP s_base, SEXP s_k, SEXP s_mu, SEXP s_omega, SEXP s_alpha,
                             SEXP s_beta, SEXP s_gamma, SEXP s_s2_init, SEXP s_z_base, SEXP s_valid,
                             SEXP s_cross_cols, SEXP s_cmu, SEXP s_com, SEXP s_cal, SEXP s_cbe,
                             SEXP s_cratio, SEXP s_cs2, SEXP s_z_cross) {
  return sl::call([&]() {
    int n_out = sl::as_int(s_n_out);
    int base = sl::as_int(s_base);
    int k = sl::as_int(s_k);
    double mu = sl::as_double(s_mu);
    double omega = sl::as_double(s_omega);
    double alpha = sl::as_double(s_alpha);
    double beta = sl::as_double(s_beta);
    double gamma = sl::as_double(s_gamma);
    double s2_init = sl::as_double(s_s2_init);
    sl::NumVec z_base = sl::num_vec(s_z_base);
    sl::IntVec valid = sl::int_vec(s_valid);
    sl::IntVec cross_cols = sl::int_vec(s_cross_cols);
    sl::NumVec cmu = sl::num_vec(s_cmu);
    sl::NumVec com = sl::num_vec(s_com);
    sl::NumVec cal = sl::num_vec(s_cal);
    sl::NumVec cbe = sl::num_vec(s_cbe);
    sl::LglVec cratio = sl::lgl_vec(s_cratio);
    sl::NumVec cs2 = sl::num_vec(s_cs2);
    sl::NumMat z_cross = sl::num_mat(s_z_cross);
    return boot_garch(n_out, base, k, mu, omega, alpha, beta, gamma, s2_init, z_base, valid,
                      cross_cols, cmu, com, cal, cbe, cratio, cs2, z_cross);
  });
}

extern "C" SEXP C_boot_ms_garch(SEXP s_n_out, SEXP s_base, SEXP s_k, SEXP s_K, SEXP s_mu, SEXP s_omega,
                                SEXP s_alpha, SEXP s_beta, SEXP s_gamma, SEXP s_phi, SEXP s_lambda,
                                SEXP s_trans, SEXP s_delta, SEXP s_unc_var, SEXP s_stat_prob,
                                SEXP s_pools, SEXP s_z_base, SEXP s_cross_cols, SEXP s_cmu, SEXP s_com,
                                SEXP s_cal, SEXP s_cbe, SEXP s_cratio, SEXP s_cs2, SEXP s_z_cross) {
  return sl::call([&]() {
    int n_out = sl::as_int(s_n_out);
    int base = sl::as_int(s_base);
    int k = sl::as_int(s_k);
    int K = sl::as_int(s_K);
    sl::NumVec mu = sl::num_vec(s_mu);
    sl::NumVec omega = sl::num_vec(s_omega);
    sl::NumVec alpha = sl::num_vec(s_alpha);
    sl::NumVec beta = sl::num_vec(s_beta);
    sl::NumVec gamma = sl::num_vec(s_gamma);
    sl::NumVec phi = sl::num_vec(s_phi);
    sl::NumVec lambda = sl::num_vec(s_lambda);
    sl::NumMat trans = sl::num_mat(s_trans);
    sl::NumMat delta = sl::num_mat(s_delta);
    sl::NumVec unc_var = sl::num_vec(s_unc_var);
    sl::NumVec stat_prob = sl::num_vec(s_stat_prob);
    SEXP pools = sl::as_list(s_pools);
    sl::NumVec z_base = sl::num_vec(s_z_base);
    sl::IntVec cross_cols = sl::int_vec(s_cross_cols);
    sl::NumVec cmu = sl::num_vec(s_cmu);
    sl::NumVec com = sl::num_vec(s_com);
    sl::NumVec cal = sl::num_vec(s_cal);
    sl::NumVec cbe = sl::num_vec(s_cbe);
    sl::LglVec cratio = sl::lgl_vec(s_cratio);
    sl::NumVec cs2 = sl::num_vec(s_cs2);
    sl::NumMat z_cross = sl::num_mat(s_z_cross);
    return boot_ms_garch(n_out, base, k, K, mu, omega, alpha, beta, gamma, phi, lambda, trans, delta,
                         unc_var, stat_prob, pools, z_base, cross_cols, cmu, com, cal, cbe, cratio,
                         cs2, z_cross);
  });
}

extern "C" SEXP C_rolling_vol(SEXP s_x, SEXP s_window) {
  return sl::call([&]() {
    sl::NumVec x = sl::num_vec(s_x);
    int window = sl::as_int(s_window);
    return rolling_vol(x, window);
  });
}

extern "C" SEXP C_assign_regimes(SEXP s_vol, SEXP s_thresh) {
  return sl::call([&]() {
    sl::NumVec vol = sl::num_vec(s_vol);
    sl::NumVec thresh = sl::num_vec(s_thresh);
    return assign_regimes(vol, thresh);
  });
}

extern "C" SEXP C_estimate_trans_mat(SEXP s_regimes, SEXP s_K, SEXP s_alpha) {
  return sl::call([&]() {
    sl::IntVec regimes = sl::int_vec(s_regimes);
    int K = sl::as_int(s_K);
    double alpha = sl::as_double(s_alpha);
    return estimate_trans_mat(regimes, K, alpha);
  });
}
