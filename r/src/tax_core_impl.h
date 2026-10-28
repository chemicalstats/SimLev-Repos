// ═══════════════════════════════════════════════════════════════════════════
// tax_core_impl.cpp — C++-Ports der Steuer-Kerne (Vollmigration Rechen-Engine)
// (Dateiname aus der Rcpp-Zeit; seit 0.5.0 ueber R's C-Schnittstelle angebunden, simlev_capi.h)
// 1:1-Semantik zu den R-Originalen:
//   calculate_flat_rate (VP je Lot nach § 18 Abs. 1-2 InvStG: Jahresanfangskurs als
//   Bezug, Deckel = Wertzuwachs im Jahr, Zwoelftelung nach dem Deckel, M4),
//   calculate_paragraph_20_tax (TFS -> Verlusttopf -> SPB -> Tracker),
//   calculate_vorabpauschale_tax (R-2: Verlusttopf vor SPB),
//   calculate_sell_count (kum. FIFO + Bisektion + Rundung auf ganze Stueck; Steuerschaetzung
//   mit § 19-Anrechnung der Lot-VP, Verlusttopf + freiem Sparer-Pauschbetrag, R3a-04).
// totals-Listen werden direkt (IN PLACE) veraendert (bewaehrtes Muster per Referenz).
// .sim_p20_tax_cpp/.sim_vp_tax_cpp erhalten sim_mem$totals (Zugriff ueber Namen, nur vorhandene Felder;
// R legt alle Felder in .sim_build_state an) und aendern die Zahlen in dieser Liste: Jedes
// R-Objekt, das dieselbe totals-Liste teilt, sieht die Aenderung. Probelaeufe auf einer Kopie
// brauchen daher eine tiefe Kopie (unserialize(serialize(...))), keine einfache Zuweisung.
// sim_mem selbst (Position der Felder) wird hier nicht verwendet.
// ═══════════════════════════════════════════════════════════════════════════
//
// GEMEINSAME QUELLE FUER R UND PYTHON (Etappe 7.3a): Die Kerne arbeiten auf dem
// Simulationszustand des Hosts (R: die Listen von sim_mem; Python: die dict/list-
// Struktur sim aus simlev/_sim_phases.py) ueber die Zugriffe simlev_host::as_list,
// get, set, put, at, has, as_double, as_int, num_vec, named_list und die Makros
// SIMLEV_XLENGTH, SIMLEV_LENGTH, SIMLEV_IS_NULL, SIMLEV_STRING_AT (Schnittstelle in
// simlev_core.h). Fuer R sind das genau die frueheren Aufrufe aus simlev_capi.h
// (simlev_host nimmt den Namensraum sl auf), der Compiler erzeugt daher denselben
// Maschinencode wie vor der Teilung (geprueft per Disassemblierung); Python stellt
// dieselben Zugriffe auf seine Objekte (python/src/_ext_common.h, _ext_engine.cpp).
// R ruft die Kerne ueber die .Call-Huellen in r/src/tax_core.cpp auf, Python ueber
// simlev._ext. Kanonisch in core/ (seit Etappe 9.6c, F16); R und Python bauen aus
// Byte-fuer-Byte-Kopien in r/src/ bzw. python/src/core/ (tools/core_sync.py
// --write/--check); Aenderungen nur in core/ vornehmen und danach kopieren.
// Die Python-Huellen (simlev/_core.py) rufen nur noch diese Kerne; die reinen
// Python-Kerne als Rueckfall sind seit 9.6c entfallen.

#ifndef SIMLEV_TAX_CORE_IMPL_H
#define SIMLEV_TAX_CORE_IMPL_H

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
#if !defined(SIMLEV_XLENGTH) || !defined(SIMLEV_STRING_AT)
#error "Vor diesem Kern den Host einbinden: R simlev_capi.h, Python _ext_common.h (siehe simlev_core.h)."
#endif

#include <algorithm>
#include <cmath>
#include <vector>

namespace simlev {

static inline bool lot_is_null2(simlev_host::Obj b) {
  return SIMLEV_IS_NULL(b) || SIMLEV_LENGTH(b) == 0;
}
static inline double tget(simlev_host::Obj t, const char* fld) {           // %||% 0
  if (!simlev_host::has(t, fld)) return 0.0;
  simlev_host::Obj v = simlev_host::get(t, fld);
  return SIMLEV_IS_NULL(v) ? 0.0 : simlev_host::as_double(v);
}
static inline void civil_from_days2(long z, int& y, int& m, int& d) {
  z += 719468L;
  const long era = (z >= 0 ? z : z - 146096L) / 146097L;
  const unsigned doe = static_cast<unsigned>(z - era * 146097L);
  const unsigned yoe = (doe - doe / 1460u + doe / 36524u - doe / 146096u) / 365u;
  const long yy = static_cast<long>(yoe) + era * 400L;
  const unsigned doy = doe - (365u * yoe + yoe / 4u - yoe / 100u);
  const unsigned mp = (5u * doy + 2u) / 153u;
  d = static_cast<int>(doy - (153u * mp + 2u) / 5u + 1u);
  m = static_cast<int>(mp + (mp < 10 ? 3 : -9));
  y = static_cast<int>(yy + (m <= 2));
}

// Vorabpauschale je Lot (Port des Kerns von calculate_flat_rate; .sim_flat_rate_cpp)
// base_rate bereits dezimal (>0), Datums-Args als Tage seit Epoch.
static simlev_host::Obj flat_rate(simlev_host::Obj buys, int front_index, double base_rate,
                      double year_start_price, double market_price,
                      int soy_days, int eoy_days) {
  const int n = SIMLEV_XLENGTH(buys);
  simlev_host::Obj empty = simlev_host::named_list("total_vp", 0.0,
                              "lot_indices", simlev_host::new_int(0),
                              "lot_vps", simlev_host::new_num(0));
  if (front_index > n) return empty;

  // M4: aktive Lots (remaining > 0) sammeln; NULL-Lot = Ende der Liste
  std::vector<int>    idx;
  std::vector<double> vps;
  idx.reserve(n - front_index + 1);
  vps.reserve(n - front_index + 1);

  for (int i = front_index; i <= n; ++i) {
    simlev_host::Obj bs = simlev_host::at(buys, i - 1);
    if (lot_is_null2(bs)) break;                 // Endmarke wie in R (first_null)
    simlev_host::Obj b = simlev_host::as_list(bs);
    double rem = simlev_host::as_double(simlev_host::get(b, "remaining"));
    if (rem <= 0) continue;                      // nur aktive Lots

    int buy_days = static_cast<int>(simlev_host::as_double(simlev_host::get(b, "date")));
    double vp = 0.0;
    if (buy_days <= eoy_days) {
      // § 18 Abs. 1-2 InvStG: Basisertrag und Deckel (Wertzuwachs im Kalenderjahr)
      // beziehen sich fuer jedes Lot auf den Ruecknahmepreis zu Jahresbeginn;
      // bei Erwerb im laufenden Jahr mindert sich die VP danach um je ein
      // Zwoelftel fuer jeden vollen Monat vor dem Erwerbsmonat (Abs. 2).
      double months_factor = 1.0;                // vor dem Jahr erworben
      if (buy_days >= soy_days) {                // Erwerb im laufenden Jahr
        int y, m, d; civil_from_days2(buy_days, y, m, d);
        months_factor = (12.0 - (m - 1)) / 12.0;
      }
      double reference_value = rem * year_start_price;
      double base_worth   = reference_value * base_rate * 0.7;
      double market_worth = rem * market_price;
      double growth       = std::max(0.0, market_worth - reference_value);
      vp = std::max(0.0, std::min(base_worth, growth)) * months_factor;
    }
    idx.push_back(i);
    vps.push_back(vp);
  }

  long double total_ld = 0.0L;              // wie R sum(): long-double-Akkumulator
  for (double v : vps) total_ld += v;
  double total = static_cast<double>(total_ld);
  return simlev_host::named_list("total_vp", total,
                        "lot_indices", idx,
                        "lot_vps", vps);
}

// § 20-Steuerkern (Port von calculate_paragraph_20_tax; .sim_p20_tax_cpp); mutiert totals in place
static simlev_host::Obj p20_tax(double trade_gain, double bonus, simlev_host::Obj totals,
                    double tax_rate, bool use_spb) {
  double adjusted_gain = trade_gain * (1.0 - bonus);

  if (adjusted_gain < 0) {
    simlev_host::set(totals, "loss_capital_gains", simlev_host::as_double(simlev_host::get(totals, "loss_capital_gains")) - adjusted_gain);
    simlev_host::set(totals, "cgt_loss_added_ytd", tget(totals, "cgt_loss_added_ytd") - adjusted_gain);
    return simlev_host::named_list("tax", 0.0, "spb_used", 0.0);
  }

  double pool = simlev_host::as_double(simlev_host::get(totals, "loss_capital_gains"));
  double loss_offset = std::min(adjusted_gain, pool);
  simlev_host::set(totals, "loss_capital_gains", pool - loss_offset);
  simlev_host::set(totals, "cgt_loss_used_ytd",  tget(totals, "cgt_loss_used_ytd") + loss_offset);
  double gain_after_loss = adjusted_gain - loss_offset;

  double spb_offset = 0.0;
  double spb_rem = simlev_host::as_double(simlev_host::get(totals, "sparer_pauschbetrag_remaining"));
  if (use_spb && spb_rem > 0) {
    spb_offset = std::min(gain_after_loss, spb_rem);
    simlev_host::set(totals, "sparer_pauschbetrag_remaining",  spb_rem - spb_offset);
    simlev_host::set(totals, "sparer_pauschbetrag_used_total",
            simlev_host::as_double(simlev_host::get(totals, "sparer_pauschbetrag_used_total")) + spb_offset);
  }

  double taxable_gain = gain_after_loss - spb_offset;
  simlev_host::set(totals, "cgt_base_taxed_ytd", tget(totals, "cgt_base_taxed_ytd") + taxable_gain);
  double tax = taxable_gain * tax_rate;
  simlev_host::set(totals, "total_taxes", simlev_host::as_double(simlev_host::get(totals, "total_taxes")) + tax);

  return simlev_host::named_list("tax", tax, "spb_used", spb_offset);
}

// VP-Steuerkern (Port von calculate_vorabpauschale_tax, R-2; .sim_vp_tax_cpp); mutiert totals
static simlev_host::Obj vp_tax(double flat_rate, double bonus, simlev_host::Obj totals,
                   double tax_rate, bool use_spb) {
  double taxable_flat_rate = flat_rate * (1.0 - bonus);

  double pool = simlev_host::as_double(simlev_host::get(totals, "loss_capital_gains"));
  double loss_offset = std::min(taxable_flat_rate, pool);
  simlev_host::set(totals, "loss_capital_gains", pool - loss_offset);
  simlev_host::set(totals, "cgt_loss_used_ytd",  tget(totals, "cgt_loss_used_ytd") + loss_offset);
  double vp_after_loss = taxable_flat_rate - loss_offset;

  double spb_offset = 0.0;
  double spb_rem = simlev_host::as_double(simlev_host::get(totals, "sparer_pauschbetrag_remaining"));
  if (use_spb && spb_rem > 0) {
    spb_offset = std::min(vp_after_loss, spb_rem);
    simlev_host::set(totals, "sparer_pauschbetrag_remaining",  spb_rem - spb_offset);
    simlev_host::set(totals, "sparer_pauschbetrag_used_total",
            simlev_host::as_double(simlev_host::get(totals, "sparer_pauschbetrag_used_total")) + spb_offset);
  }

  double taxable_gain = vp_after_loss - spb_offset;
  simlev_host::set(totals, "cgt_base_taxed_ytd", tget(totals, "cgt_base_taxed_ytd") +
                                        std::max(0.0, taxable_gain));
  double tax = std::max(0.0, taxable_gain * tax_rate);

  return simlev_host::named_list("tax", tax,
                        "spb_used", spb_offset,
                        "taxable_amount", taxable_flat_rate);
}

// ── interner schneller FIFO-Preis auf kumulierten Vektoren (wie R) ──
static inline double fifo_fast(double units, const std::vector<double>& cu,
                               const std::vector<double>& cc,
                               const std::vector<double>& prices) {
  const int n = static_cast<int>(cu.size());
  if (units <= 0) return 0.0;
  if (units >= cu[n - 1]) return cc[n - 1] / cu[n - 1];
  // findInterval(units, c(0, cum)): erstes Lot mit cum >= units
  int lot = 0;
  while (lot < n && cu[lot] < units) ++lot;      // 0-basiert
  int lot_idx = std::min(lot + 1, n);            // 1-basiert wie R
  if (lot_idx == 1) return prices[0];
  double prev_cost  = cc[lot_idx - 2];
  double prev_units = cu[lot_idx - 2];
  double rem = units - prev_units;
  return (prev_cost + rem * prices[lot_idx - 1]) / units;
}

// Verkaufsstueckzahl fuer Ziel-Nettoerloes (Port von calculate_sell_count; .sim_sell_count_cpp)
// regime: 0=none, 1=investment_fund, 2=capital_gains, 3=private_sale
static simlev_host::Obj sell_count(simlev_host::Obj buys, int front_index, double target,
                       double trade_price, double total_shares, bool fractions,
                       int regime, double bonus, double loss_pool, double tax_rate) {
  simlev_host::Obj zero = simlev_host::named_list("sell_count", 0.0, "fifo_price", 0.0);
  const int n = SIMLEV_XLENGTH(buys);
  if (front_index > n) return zero;

  std::vector<double> units, prices, vpu;
  units.reserve(n - front_index + 1);
  prices.reserve(n - front_index + 1);
  vpu.reserve(n - front_index + 1);
  bool any_vp = false;
  for (int i = front_index; i <= n; ++i) {
    simlev_host::Obj bs = simlev_host::at(buys, i - 1);
    if (lot_is_null2(bs)) break;                 // Abbruch bei NULL-Lots
    simlev_host::Obj b = simlev_host::as_list(bs);
    double rem = simlev_host::as_double(simlev_host::get(b, "remaining"));
    if (rem > 0) {
      units.push_back(rem);
      prices.push_back(simlev_host::as_double(simlev_host::get(b, "price")));
      // § 19 InvStG: bereits versteuerte Vorabpauschale je Stueck (F9: Basis = remaining)
      double lot_vp = simlev_host::has(b, "vp") ? simlev_host::as_double(simlev_host::get(b, "vp")) : 0.0;
      double v = (regime == 1 && lot_vp > 0) ? lot_vp / rem : 0.0;
      if (v > 0) any_vp = true;
      vpu.push_back(v);
    }
  }
  if (units.empty()) return zero;

  const int nl = static_cast<int>(units.size());
  std::vector<double> cu(nl), cc(nl), cv(nl);
  long double su = 0.0L, sc = 0.0L, sv = 0.0L;   // wie R cumsum(): long-double-Akkumulator
  for (int i = 0; i < nl; ++i) {
    su += units[i];              cu[i] = static_cast<double>(su);
    sc += units[i] * prices[i];  cc[i] = static_cast<double>(sc);
    sv += units[i] * vpu[i];     cv[i] = static_cast<double>(sv);
  }
  // VP-Anrechnung der ersten 'sell' Stueck (FIFO), wie .sim_fifo_vp_cpp
  auto fifo_vp = [&](double sell) -> double {
    if (!any_vp || sell <= 0) return 0.0;
    if (sell >= cu[nl - 1]) return cv[nl - 1];
    int lot = 0;
    while (lot < nl && cu[lot] < sell) ++lot;
    if (lot >= nl) lot = nl - 1;
    double prev_u = lot > 0 ? cu[lot - 1] : 0.0, prev_v = lot > 0 ? cv[lot - 1] : 0.0;
    return prev_v + (sell - prev_u) * vpu[lot];
  };

  // R3a-04: loss_pool = freier Verlusttopf + freier Sparer-Pauschbetrag (Aufrufer), damit die
  // geschaetzte Steuer der tatsaechlichen entspricht (kein Ueberverkauf mit Rueckkauf)
  auto objective = [&](double sell) -> double {
    if (sell <= 0) return -target;
    if (sell > total_shares) sell = total_shares;
    double fp = fifo_fast(sell, cu, cc, prices);
    double gain = (trade_price - fp) * sell;
    double tax = 0.0;
    if (regime == 1) {                                    // investment_fund
      double adj = (gain - fifo_vp(sell)) * (1.0 - bonus);  // § 19 InvStG vor Teilfreistellung
      tax = std::max(adj - loss_pool, 0.0) * tax_rate;
    } else if (regime == 2) {                             // capital_gains
      tax = std::max(gain - loss_pool, 0.0) * tax_rate;
    }                                                     // 3/private_sale: 0
    return sell * trade_price - tax - target;
  };

  double initial = target / trade_price;
  double lower = std::max(1e-6, initial * 0.1);
  double upper = std::min(initial * 3.0, total_shares);
  double f_lower = objective(lower);
  double f_upper = objective(upper);
  double tol = fractions ? 1e-6 : 0.5;

  double sell;
  if (f_lower >= 0) {
    sell = lower;
  } else if (f_upper <= 0) {
    sell = upper;
  } else if (std::fabs(f_lower) < tol) {
    sell = lower;
  } else if (std::fabs(f_upper) < tol) {
    sell = upper;
  } else {
    // Bisektion (Intervallhalbierung mit Abbruch bei |f| < tol oder Intervall < tol, max 30)
    sell = (lower + upper) * 0.5;
    for (int it = 0; it < 30; ++it) {
      double mid = (lower + upper) * 0.5;
      double fm = objective(mid);
      if (std::fabs(fm) < tol || (upper - lower) < tol) { sell = mid; break; }
      if (fm * f_lower < 0) { upper = mid; f_upper = fm; }
      else                  { lower = mid; f_lower = fm; }
      sell = (lower + upper) * 0.5;
    }
  }

  // Ganze Stuecke: naechstliegende Stueckzahl (Umschichtung). Zwangsverkaeufe fuer Zahlungen
  // (Steuer, Kosten) rufen mit fractions = TRUE auf und runden in R auf (R3a-03).
  if (!fractions) {
    double tl = std::floor(sell), tu = std::ceil(sell);
    if (tl < 1) tl = 1;
    if (tu > total_shares) tu = total_shares;
    sell = (std::fabs(objective(tl)) <= std::fabs(objective(tu))) ? tl : tu;
  }

  double final_fp = fifo_fast(sell, cu, cc, prices);
  double out = std::max(0.0, std::min(sell, total_shares));
  return simlev_host::named_list("sell_count", out, "fifo_price", final_fp);
}

}  // namespace simlev

#endif
