// src/bootstrap_core_impl.h
// Bootstrap-Kerne fuer SimLev (portiert und verallgemeinert aus '00 Bootstraps'),
// reine Rechnung ohne R und Python.
//
// GEMEINSAME QUELLE FUER R UND PYTHON (Etappe 7.3b): R ruft die Kerne ueber die
// .Call-Huellen in src/bootstrap_core.cpp auf (sie wandeln nur die R-Objekte um),
// Python ueber das Erweiterungsmodul simlev._ext (python/src/_ext_bootstrap.cpp).
// Python baut aus einer Byte-fuer-Byte-Kopie in python/src/
// (python/tests/test_shared_c.py); Aenderungen nur hier vornehmen und danach
// kopieren. Der reine Python-Kern (simlev/_bootstrap_core.py) rechnet dasselbe und
// bleibt der Rueckfall.
//
// Aufbau wie alle C++-Kerne (simlev_core.h): statische Funktionen ueber den Sichten
// simlev_host::NumVec/IntVec/LglVec/NumMat/IntList und den Host-Makros SIMLEV_*
// (Fehler, Anlegen der Ergebnisse), die die einbindende Huelle festlegt (R:
// simlev_capi.h, Python: _ext_common.h). Die Rechnung ist Zeile fuer Zeile die
// fruehere aus bootstrap_core.cpp; fuer R setzen die Namen genau die frueheren
// Aufrufe ein, der Compiler erzeugt daher denselben Maschinencode wie vor der
// Teilung (geprueft per Disassemblierung).
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
// Zufallszahlen: ausschliesslich ueber den Host, simlev_host::runif, rgeom und rnorm
// (die Funktionen runif, rgeom, rnorm aus R's nmath). R: genau Rf_runif, Rf_rgeom,
// Rf_rnorm, damit set.seed() und L'Ecuyer-Streams (parallel::nextRNGStream)
// reproduzierbar greifen; GetRNGstate/PutRNGstate setzt die .Call-Huelle
// (simlev_capi.h). Python: die C-Nachbildung von R's Zufallszahlen
// (python/src/_rng_r.c) auf dem Zustand von simlev._r.rng, den die Huelle uebergibt
// und danach zurueckschreibt. R's RNG ist nicht threadsicher: keine
// OpenMP-Parallelisierung in diesen Kernen.
//
// Referenzen: Efron (1979); Kuensch (1989); Politis & Romano (1992, 1994);
// Wu (1986), Mammen (1993); Bollerslev (1986); Glosten, Jagannathan & Runkle
// (1993); Barone-Adesi, Giannopoulos & Vosper (1999); Haas, Mittnik &
// Paolella (2004); Diebold, Lee & Weinbach (1994, TVTP).
#ifndef SIMLEV_BOOTSTRAP_CORE_IMPL_H
#define SIMLEV_BOOTSTRAP_CORE_IMPL_H

// Gleitkomma wie im Pilot (simlev_core.h): Abbruch bei -ffast-math; kein
// Zusammenziehen von a * b + c zu fma. Das Pragma steht nur dort, wo der Compiler
// fma ueberhaupt erzeugen kann (__FP_FAST_FMA, etwa aarch64 oder -mfma): auf
// x86-64 ohne FMA ist -ffp-contract=off wirkungslos, das GCC-Pragma optimize
// veraendert dort aber die Codeerzeugung der ganzen Datei (geprueft), und R soll
// denselben Maschinencode wie vor der Teilung ausfuehren. Python baut immer mit
// -ffp-contract=off (setup.py) und setzt SIMLEV_FP_CONTRACT_BY_FLAG.
#if defined(__FAST_MATH__)
#error "Gemeinsame Kerne duerfen nicht mit -ffast-math uebersetzt werden (Bitgleichheit)."
#endif
#if defined(__clang__)
#pragma STDC FP_CONTRACT OFF
#elif defined(_MSC_VER)
#pragma fp_contract (off)
#elif defined(__GNUC__) && (defined(__FP_FAST_FMA) || defined(__FP_FAST_FMAF)) && !defined(SIMLEV_FP_CONTRACT_BY_FLAG)
#pragma GCC optimize ("fp-contract=off")
#endif

#include "simlev_core.h"
#if !defined(SIMLEV_FAIL) || !defined(SIMLEV_INT) || !defined(SIMLEV_MATRIX) || !defined(SIMLEV_LIST_INT) || !defined(SIMLEV_RNG)
#error "Vor diesem Kern den Host einbinden: R simlev_capi.h, Python _ext_common.h (siehe simlev_core.h)."
#endif

#include <vector>
#include <cmath>
#include <algorithm>

namespace simlev {


static inline int draw_int(int n) {            // gleichverteilt in {0, ..., n-1}
  int k = (int) std::floor(simlev_host::runif(0.0, (double) n));
  return k >= n ? n - 1 : k;
}

// ===========================================================================
// INDEX-KERNE (reines Zeilen-Resampling)
// ===========================================================================

// IID-Bootstrap (Efron 1979): Zeilen gleichverteilt mit Zuruecklegen.
static auto boot_idx_iid(int n_src, int n_out) {
  if (n_src < 1) SIMLEV_FAIL("Keine Quellzeilen");
  simlev_host::IntVec idx = SIMLEV_INT(n_out);
  for (int i = 0; i < n_out; i++) idx[i] = draw_int(n_src) + 1;
  return SIMLEV_DONE(idx);
}

// Block-Bootstrap mit fester Blocklaenge.
// circular = false: Moving Block Bootstrap (Kuensch 1989), Starts in 0..n-b.
// circular = true : Circular Block Bootstrap (Politis & Romano 1992), Starts in
//                   0..n-1 mit Umlauf; jede Beobachtung gleich wahrscheinlich.
static auto boot_idx_block(int n_src, int n_out, int block_length, bool circular) {
  if (n_src < 1) SIMLEV_FAIL("Keine Quellzeilen");
  if (block_length <= 0) SIMLEV_FAIL("block_length muss positiv sein");
  if (block_length > n_src) SIMLEV_FAIL("block_length (%d) ist gr\u00f6\u00dfer als die Historie (%d Zeilen)", block_length, n_src);
  simlev_host::IntVec idx = SIMLEV_INT(n_out);
  int i = 0;
  int n_start = circular ? n_src : (n_src - block_length + 1);
  while (i < n_out) {
    int start = draw_int(n_start);
    int len = std::min(block_length, n_out - i);
    for (int t = 0; t < len; t++) idx[i + t] = ((start + t) % n_src) + 1;
    i += len;
  }
  return SIMLEV_DONE(idx);
}

// Stationaerer Bootstrap (Politis & Romano 1994): geometrische Blocklaengen
// mit Erwartungswert L, zirkulaerer Umlauf.
static auto boot_idx_stationary(int n_src, int n_out, double L) {
  if (n_src < 1) SIMLEV_FAIL("Keine Quellzeilen");
  if (!(L >= 1.0)) SIMLEV_FAIL("L muss >= 1 sein");
  simlev_host::IntVec idx = SIMLEV_INT(n_out);
  double p = 1.0 / L;
  int i = 0;
  while (i < n_out) {
    int len = (p >= 1.0) ? 1 : (int) simlev_host::rgeom(p) + 1;
    int start = draw_int(n_src);
    len = std::min(len, n_out - i);
    for (int t = 0; t < len; t++) idx[i + t] = ((start + t) % n_src) + 1;
    i += len;
  }
  return SIMLEV_DONE(idx);
}

// Stationaere Verteilung einer Uebergangsmatrix (Potenziteration)
static std::vector<double> stationary_dist(const simlev_host::NumMat& P) {
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
  double u = simlev_host::runif(0.0, 1.0), c = 0.0;
  for (int r = 0; r < K; r++) { c += p[r]; if (u <= c) return r; }
  return K - 1;
}

// Volatilitaets-Regime-Bootstrap: Markov-Kette ueber diskretisierte Regime,
// innerhalb eines Regimes IID-Ziehung aus dessen Beobachtungen.
static auto boot_idx_regime(simlev_host::IntVec regimes, simlev_host::NumMat trans, int n_out) {
  int n = regimes.size(), K = trans.nrow();
  std::vector<std::vector<int>> pool(K);
  for (int i = 0; i < n; i++) { int r = regimes[i] - 1; if (r >= 0 && r < K) pool[r].push_back(i); }
  std::vector<double> pi = stationary_dist(trans);
  for (int r = 0; r < K; r++) if (pool[r].empty()) pi[r] = 0.0;
  double s = 0.0; for (int r = 0; r < K; r++) s += pi[r];
  for (int r = 0; r < K; r++) pi[r] = s > 0 ? pi[r] / s : 1.0 / K;
  int cur = draw_from(pi.data(), K);
  simlev_host::IntVec idx = SIMLEV_INT(n_out);
  std::vector<double> row(K);
  for (int t = 0; t < n_out; t++) {
    const std::vector<int>* p = &pool[cur];
    if (p->empty()) for (int r = 0; r < K; r++) if (!pool[r].empty()) { p = &pool[r]; break; }
    idx[t] = (*p)[draw_int((int) p->size())] + 1;
    for (int r = 0; r < K; r++) row[r] = trans(cur, r);
    cur = draw_from(row.data(), K);
  }
  return SIMLEV_DONE(idx);
}

// Empirischer Tail-Bootstrap: Mischung aus linkem Rand (Tail), Kernbereich (Bulk) und rechtem Rand
// mit den Wahrscheinlichkeiten p_l, 1 - p_l - p_r, p_r.
static auto boot_idx_tails(int n_out, double p_l, double p_r,
                           simlev_host::IntVec bulk_idx, simlev_host::IntVec left_idx, simlev_host::IntVec right_idx) {
  int nb = bulk_idx.size(), nl = left_idx.size(), nr = right_idx.size();
  if (nb == 0) SIMLEV_FAIL("Keine Bulk-Beobachtungen");
  simlev_host::IntVec idx = SIMLEV_INT(n_out);
  for (int t = 0; t < n_out; t++) {
    double u = simlev_host::runif(0.0, 1.0);
    if (u < p_l && nl > 0)             idx[t] = left_idx[draw_int(nl)];
    else if (u < p_l + p_r && nr > 0)  idx[t] = right_idx[draw_int(nr)];
    else                               idx[t] = bulk_idx[draw_int(nb)];
  }
  return SIMLEV_DONE(idx);
}

// ===========================================================================
// MATRIX-KERNE
// ===========================================================================

// Wild Bootstrap (Wu 1986; Liu 1988; Mammen 1993): x*_t = mu + (x_t - mu) w_t
// mit gemeinsamem Gewicht w_t fuer alle Reihen (Querschnitt bleibt erhalten).
// type: 0 = Rademacher, 1 = Mammen, 2 = Standardnormal.
static auto boot_wild(simlev_host::NumMat returns, int type) {
  if (type < 0 || type > 2) SIMLEV_FAIL("wild_type muss 0, 1 oder 2 sein (erhalten: %d)", type);
  int n = returns.nrow(), k = returns.ncol();
  simlev_host::NumMat out = SIMLEV_MATRIX(n, k);
  std::vector<double> mu(k, 0.0);
  for (int j = 0; j < k; j++) { double s = 0; for (int i = 0; i < n; i++) s += returns(i, j); mu[j] = s / n; }
  const double s5 = std::sqrt(5.0);
  const double mp = (s5 + 1.0) / (2.0 * s5), mneg = -(s5 - 1.0) / 2.0, mpos = (s5 + 1.0) / 2.0;
  for (int i = 0; i < n; i++) {
    double w;
    if (type == 0)      w = (simlev_host::runif(0, 1) < 0.5) ? -1.0 : 1.0;
    else if (type == 1) w = (simlev_host::runif(0, 1) < mp) ? mneg : mpos;
    else                w = simlev_host::rnorm(0.0, 1.0);
    for (int j = 0; j < k; j++) out(i, j) = mu[j] + (returns(i, j) - mu[j]) * w;
  }
  return SIMLEV_DONE(out);
}

// Reset-/Sign-Flip-Bootstrap: chronologische Reihe, Segmente mit
// Wahrscheinlichkeit p_break umgeschaltet und dann um 1 gespiegelt (2 - R).
static auto boot_reset(simlev_host::NumMat returns, double p_break) {
  if (!(p_break >= 0.0 && p_break <= 1.0)) SIMLEV_FAIL("p_break muss in [0, 1] liegen");
  int n = returns.nrow(), k = returns.ncol();
  simlev_host::NumMat out = SIMLEV_MATRIX(n, k);
  bool flipped = false;
  for (int t = 0; t < n; t++) {
    if (simlev_host::runif(0, 1) < p_break) flipped = !flipped;
    for (int j = 0; j < k; j++) out(t, j) = flipped ? 2.0 - returns(t, j) : returns(t, j);
  }
  return SIMLEV_DONE(out);
}

static inline double rgpd(double scale, double shape) {
  double u = simlev_host::runif(0.0, 1.0);
  if (u <= 0.0) u = 1e-300;
  if (std::fabs(shape) < 1e-10) return -scale * std::log(u);
  return scale * (std::pow(u, -shape) - 1.0) / shape;
}

// EVT-Bootstrap (semiparametrisch): Kernbereich (Bulk) = empirische Zeilen, Raender (Tails) der
// Basisreihe aus der Generalisierten Pareto-Verteilung. Die uebrigen Reihen
// werden im Tail ueber das historische Verhaeltnis R_c / R_base einer
// gezogenen Tail-Zeile gekoppelt (verallgemeinert den FX-Pool des Originals).
// Rueckgabe: list(ret, idx)
static auto boot_evt(simlev_host::NumMat returns, int base, int n_out,
                     double p_l, double thresh_l, double scale_l, double shape_l, simlev_host::IntVec pool_l,
                     double p_r, double thresh_r, double scale_r, double shape_r, simlev_host::IntVec pool_r,
                     simlev_host::IntVec bulk_idx) {
  int k = returns.ncol(), nb = bulk_idx.size(), nl = pool_l.size(), nr = pool_r.size();
  if (nb == 0) SIMLEV_FAIL("Keine Bulk-Beobachtungen");
  simlev_host::NumMat out = SIMLEV_MATRIX(n_out, k);
  simlev_host::IntVec idx = SIMLEV_INT(n_out);
  for (int t = 0; t < n_out; t++) {
    double u = simlev_host::runif(0.0, 1.0);
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
  return SIMLEV_LIST("ret", out, "idx", idx);
}

// Gemeinsamer Teil fuer Nicht-Basisreihen ("cross"-Modelle): GARCH(1,1) je
// Reihe, gekoppelt an die Basisreihe (ratio) oder eigenstaendig (joint).
struct CrossState {
  int m;
  std::vector<int> col;
  std::vector<double> mu, om, al, be, s2, eps;
  std::vector<bool> ratio;
};

static CrossState init_cross(simlev_host::IntVec cols, simlev_host::NumVec mu, simlev_host::NumVec om, simlev_host::NumVec al,
                             simlev_host::NumVec be, simlev_host::LglVec ratio, simlev_host::NumVec s2_init) {
  CrossState cs; cs.m = cols.size();
  for (int c = 0; c < cs.m; c++) {
    cs.col.push_back(cols[c]); cs.mu.push_back(mu[c]); cs.om.push_back(om[c]);
    cs.al.push_back(al[c]); cs.be.push_back(be[c]); cs.ratio.push_back(ratio[c]);
    cs.s2.push_back(s2_init[c]); cs.eps.push_back(0.0);
  }
  return cs;
}

static inline void step_cross(CrossState& cs, simlev_host::NumMat& out, int t, double base_ret,
                              const simlev_host::NumMat& z_cross, int tstar) {
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
static auto boot_garch(int n_out, int base, int k,
                       double mu, double omega, double alpha, double beta, double gamma,
                       double s2_init, simlev_host::NumVec z_base, simlev_host::IntVec valid,
                       simlev_host::IntVec cross_cols, simlev_host::NumVec cmu, simlev_host::NumVec com,
                       simlev_host::NumVec cal, simlev_host::NumVec cbe, simlev_host::LglVec cratio,
                       simlev_host::NumVec cs2, simlev_host::NumMat z_cross) {
  if (omega <= 0) SIMLEV_FAIL("omega muss > 0 sein");
  int nv = valid.size();
  if (nv == 0) SIMLEV_FAIL("Keine g\u00fcltigen Residuen");
  simlev_host::NumMat out = SIMLEV_MATRIX(n_out, k);
  simlev_host::IntVec idx = SIMLEV_INT(n_out);
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
  return SIMLEV_LIST("ret", out, "idx", idx);
}

// Markov-Switching-(AR-)GJR-GARCH(-M) mit optional zeitvariablen
// Uebergangswahrscheinlichkeiten (TVTP). Deckt ms_garch (phi = lambda = 0,
// delta = 0), ms_ar_garch_m (delta = 0) und tvtp_ms_garch ab.
//   sigma2_t = omega_r + (alpha_r + gamma_r I[eps<0]) eps^2 + beta_r sigma2
//   mean_t   = mu_r + phi_r * r_{t-1} + lambda_r * sigma_t
//   logit P_ij(t) = log P_ij + delta_ij * (sigma2_t / unc_var_i - 1)
// Residuen: t* wird aus den historischen Tagen des aktuellen Regimes gezogen.
static auto boot_ms_garch(int n_out, int base, int k, int K,
                          simlev_host::NumVec mu, simlev_host::NumVec omega, simlev_host::NumVec alpha,
                          simlev_host::NumVec beta, simlev_host::NumVec gamma,
                          simlev_host::NumVec phi, simlev_host::NumVec lambda,
                          simlev_host::NumMat trans, simlev_host::NumMat delta, simlev_host::NumVec unc_var,
                          simlev_host::NumVec stat_prob, simlev_host::IntList pools, simlev_host::NumVec z_base,
                          simlev_host::IntVec cross_cols, simlev_host::NumVec cmu, simlev_host::NumVec com,
                          simlev_host::NumVec cal, simlev_host::NumVec cbe, simlev_host::LglVec cratio,
                          simlev_host::NumVec cs2, simlev_host::NumMat z_cross) {
  for (int i = 0; i < K; i++) {
    double rs = 0; for (int j = 0; j < K; j++) rs += trans(i, j);
    if (std::fabs(rs - 1.0) > 1e-6) SIMLEV_FAIL("Zeile %d der Uebergangsmatrix summiert nicht auf 1", i + 1);
    if (unc_var[i] <= 0) SIMLEV_FAIL("unc_var[%d] <= 0", i + 1);
  }
  std::vector<std::vector<int>> pl(K);
  for (int r = 0; r < K; r++) { simlev_host::IntVec p = SIMLEV_LIST_INT(pools, r); for (int j = 0; j < p.size(); j++) pl[r].push_back(p[j] - 1); }
  bool tvtp = false;
  for (int i = 0; i < K; i++) for (int j = 0; j < K; j++) if (std::fabs(delta(i, j)) > 1e-12) tvtp = true;

  simlev_host::NumMat out = SIMLEV_MATRIX(n_out, k);
  simlev_host::IntVec idx = SIMLEV_INT(n_out), reg = SIMLEV_INT(n_out);
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
  return SIMLEV_LIST("ret", out, "idx", idx, "regime", reg);
}

// ===========================================================================
// HILFSFUNKTIONEN
// ===========================================================================

// Rollierende Volatilitaet (Bessel-korrigiert) der Ueberschussrendite x - 1.
static auto rolling_vol(simlev_host::NumVec x, int window) {
  int n = x.size();
  if (window <= 0) SIMLEV_FAIL("window muss positiv sein");
  if (window > n) window = n;
  simlev_host::NumVec vol = SIMLEV_NUM(n);
  double sum = 0.0, sq = 0.0;
  for (int i = 0; i < n; i++) {
    double v = x[i] - 1.0; sum += v; sq += v * v;
    if (i >= window) { double o = x[i - window] - 1.0; sum -= o; sq -= o * o; }
    int cnt = std::min(i + 1, window);
    if (cnt <= 1) vol[i] = 0.0;
    else { double m = sum / cnt; vol[i] = std::sqrt(std::max(0.0, (sq - cnt * m * m) / (cnt - 1))); }
  }
  return SIMLEV_DONE(vol);
}

// Regime-Zuordnung ueber Schwellen [tau_r, tau_{r+1})
static auto assign_regimes(simlev_host::NumVec vol, simlev_host::NumVec thresh) {
  int n = vol.size(), K = thresh.size() - 1;
  simlev_host::IntVec reg = SIMLEV_INT(n);
  for (int i = 0; i < n; i++) {
    reg[i] = K;
    for (int r = 0; r < K; r++) if (vol[i] >= thresh[r] && vol[i] < thresh[r + 1]) { reg[i] = r + 1; break; }
  }
  return SIMLEV_DONE(reg);
}

// Uebergangsmatrix mit Laplace-/Dirichlet-Glaettung alpha
static auto estimate_trans_mat(simlev_host::IntVec regimes, int K, double alpha) {
  simlev_host::NumMat P = SIMLEV_MATRIX(K, K);
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
  return SIMLEV_DONE(P);
}

}  // namespace simlev

#endif
