// ═══════════════════════════════════════════════════════════════════════════
// tax_core.cpp — C++-Ports der Steuer-Kerne (Vollmigration Rechen-Engine)
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
#include "simlev_capi.h"
#include <algorithm>
#include <cmath>
#include <vector>

static inline bool lot_is_null2(SEXP b) {
  return Rf_isNull(b) || Rf_length(b) == 0;
}
static inline double tget(SEXP t, const char* fld) {           // %||% 0
  if (!sl::has(t, fld)) return 0.0;
  SEXP v = sl::get(t, fld);
  return Rf_isNull(v) ? 0.0 : sl::as_double(v);
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
static SEXP flat_rate(SEXP buys, int front_index, double base_rate,
                      double year_start_price, double market_price,
                      int soy_days, int eoy_days) {
  const int n = Rf_xlength(buys);
  SEXP empty = sl::named_list("total_vp", 0.0,
                              "lot_indices", sl::new_int(0),
                              "lot_vps", sl::new_num(0));
  if (front_index > n) return empty;

  // M4: aktive Lots (remaining > 0) sammeln; NULL-Lot = Ende der Liste
  std::vector<int>    idx;
  std::vector<double> vps;
  idx.reserve(n - front_index + 1);
  vps.reserve(n - front_index + 1);

  for (int i = front_index; i <= n; ++i) {
    SEXP bs = sl::at(buys, i - 1);
    if (lot_is_null2(bs)) break;                 // Endmarke wie in R (first_null)
    SEXP b = sl::as_list(bs);
    double rem = sl::as_double(sl::get(b, "remaining"));
    if (rem <= 0) continue;                      // nur aktive Lots

    int buy_days = static_cast<int>(sl::as_double(sl::get(b, "date")));
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
  return sl::named_list("total_vp", total,
                        "lot_indices", idx,
                        "lot_vps", vps);
}

// § 20-Steuerkern (Port von calculate_paragraph_20_tax; .sim_p20_tax_cpp); mutiert totals in place
static SEXP p20_tax(double trade_gain, double bonus, SEXP totals,
                    double tax_rate, bool use_spb) {
  double adjusted_gain = trade_gain * (1.0 - bonus);

  if (adjusted_gain < 0) {
    sl::set(totals, "loss_capital_gains", sl::as_double(sl::get(totals, "loss_capital_gains")) - adjusted_gain);
    sl::set(totals, "cgt_loss_added_ytd", tget(totals, "cgt_loss_added_ytd") - adjusted_gain);
    return sl::named_list("tax", 0.0, "spb_used", 0.0);
  }

  double pool = sl::as_double(sl::get(totals, "loss_capital_gains"));
  double loss_offset = std::min(adjusted_gain, pool);
  sl::set(totals, "loss_capital_gains", pool - loss_offset);
  sl::set(totals, "cgt_loss_used_ytd",  tget(totals, "cgt_loss_used_ytd") + loss_offset);
  double gain_after_loss = adjusted_gain - loss_offset;

  double spb_offset = 0.0;
  double spb_rem = sl::as_double(sl::get(totals, "sparer_pauschbetrag_remaining"));
  if (use_spb && spb_rem > 0) {
    spb_offset = std::min(gain_after_loss, spb_rem);
    sl::set(totals, "sparer_pauschbetrag_remaining",  spb_rem - spb_offset);
    sl::set(totals, "sparer_pauschbetrag_used_total",
            sl::as_double(sl::get(totals, "sparer_pauschbetrag_used_total")) + spb_offset);
  }

  double taxable_gain = gain_after_loss - spb_offset;
  sl::set(totals, "cgt_base_taxed_ytd", tget(totals, "cgt_base_taxed_ytd") + taxable_gain);
  double tax = taxable_gain * tax_rate;
  sl::set(totals, "total_taxes", sl::as_double(sl::get(totals, "total_taxes")) + tax);

  return sl::named_list("tax", tax, "spb_used", spb_offset);
}

// VP-Steuerkern (Port von calculate_vorabpauschale_tax, R-2; .sim_vp_tax_cpp); mutiert totals
static SEXP vp_tax(double flat_rate, double bonus, SEXP totals,
                   double tax_rate, bool use_spb) {
  double taxable_flat_rate = flat_rate * (1.0 - bonus);

  double pool = sl::as_double(sl::get(totals, "loss_capital_gains"));
  double loss_offset = std::min(taxable_flat_rate, pool);
  sl::set(totals, "loss_capital_gains", pool - loss_offset);
  sl::set(totals, "cgt_loss_used_ytd",  tget(totals, "cgt_loss_used_ytd") + loss_offset);
  double vp_after_loss = taxable_flat_rate - loss_offset;

  double spb_offset = 0.0;
  double spb_rem = sl::as_double(sl::get(totals, "sparer_pauschbetrag_remaining"));
  if (use_spb && spb_rem > 0) {
    spb_offset = std::min(vp_after_loss, spb_rem);
    sl::set(totals, "sparer_pauschbetrag_remaining",  spb_rem - spb_offset);
    sl::set(totals, "sparer_pauschbetrag_used_total",
            sl::as_double(sl::get(totals, "sparer_pauschbetrag_used_total")) + spb_offset);
  }

  double taxable_gain = vp_after_loss - spb_offset;
  sl::set(totals, "cgt_base_taxed_ytd", tget(totals, "cgt_base_taxed_ytd") +
                                        std::max(0.0, taxable_gain));
  double tax = std::max(0.0, taxable_gain * tax_rate);

  return sl::named_list("tax", tax,
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
static SEXP sell_count(SEXP buys, int front_index, double target,
                       double trade_price, double total_shares, bool fractions,
                       int regime, double bonus, double loss_pool, double tax_rate) {
  SEXP zero = sl::named_list("sell_count", 0.0, "fifo_price", 0.0);
  const int n = Rf_xlength(buys);
  if (front_index > n) return zero;

  std::vector<double> units, prices, vpu;
  units.reserve(n - front_index + 1);
  prices.reserve(n - front_index + 1);
  vpu.reserve(n - front_index + 1);
  bool any_vp = false;
  for (int i = front_index; i <= n; ++i) {
    SEXP bs = sl::at(buys, i - 1);
    if (lot_is_null2(bs)) break;                 // Abbruch bei NULL-Lots
    SEXP b = sl::as_list(bs);
    double rem = sl::as_double(sl::get(b, "remaining"));
    if (rem > 0) {
      units.push_back(rem);
      prices.push_back(sl::as_double(sl::get(b, "price")));
      // § 19 InvStG: bereits versteuerte Vorabpauschale je Stueck (F9: Basis = remaining)
      double lot_vp = sl::has(b, "vp") ? sl::as_double(sl::get(b, "vp")) : 0.0;
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
  return sl::named_list("sell_count", out, "fifo_price", final_fp);
}

// ═══════════════════════════════════════════════════════════════════════════
// .Call-Huellen (registriert in init.c; R-Seite in R/cores.R)
// ═══════════════════════════════════════════════════════════════════════════

extern "C" SEXP C_sim_flat_rate(SEXP s_buys, SEXP s_front_index, SEXP s_base_rate, SEXP s_year_start_price,
                                SEXP s_market_price, SEXP s_soy_days, SEXP s_eoy_days) {
  return sl::call([&]() {
    SEXP buys = sl::as_list(s_buys);
    int front_index = sl::as_int(s_front_index);
    double base_rate = sl::as_double(s_base_rate);
    double year_start_price = sl::as_double(s_year_start_price);
    double market_price = sl::as_double(s_market_price);
    int soy_days = sl::as_int(s_soy_days);
    int eoy_days = sl::as_int(s_eoy_days);
    return flat_rate(buys, front_index, base_rate, year_start_price, market_price, soy_days, eoy_days);
  });
}

extern "C" SEXP C_sim_p20_tax(SEXP s_trade_gain, SEXP s_bonus, SEXP s_totals, SEXP s_tax_rate,
                              SEXP s_use_spb) {
  return sl::call([&]() {
    double trade_gain = sl::as_double(s_trade_gain);
    double bonus = sl::as_double(s_bonus);
    SEXP totals = sl::as_list(s_totals);
    double tax_rate = sl::as_double(s_tax_rate);
    bool use_spb = sl::as_bool(s_use_spb);
    return p20_tax(trade_gain, bonus, totals, tax_rate, use_spb);
  });
}

extern "C" SEXP C_sim_vp_tax(SEXP s_flat_rate, SEXP s_bonus, SEXP s_totals, SEXP s_tax_rate,
                             SEXP s_use_spb) {
  return sl::call([&]() {
    double flat_rate = sl::as_double(s_flat_rate);
    double bonus = sl::as_double(s_bonus);
    SEXP totals = sl::as_list(s_totals);
    double tax_rate = sl::as_double(s_tax_rate);
    bool use_spb = sl::as_bool(s_use_spb);
    return vp_tax(flat_rate, bonus, totals, tax_rate, use_spb);
  });
}

extern "C" SEXP C_sim_sell_count(SEXP s_buys, SEXP s_front_index, SEXP s_target, SEXP s_trade_price,
                                 SEXP s_total_shares, SEXP s_fractions, SEXP s_regime, SEXP s_bonus,
                                 SEXP s_loss_pool, SEXP s_tax_rate) {
  return sl::call([&]() {
    SEXP buys = sl::as_list(s_buys);
    int front_index = sl::as_int(s_front_index);
    double target = sl::as_double(s_target);
    double trade_price = sl::as_double(s_trade_price);
    double total_shares = sl::as_double(s_total_shares);
    bool fractions = sl::as_bool(s_fractions);
    int regime = sl::as_int(s_regime);
    double bonus = sl::as_double(s_bonus);
    double loss_pool = sl::as_double(s_loss_pool);
    double tax_rate = sl::as_double(s_tax_rate);
    return sell_count(buys, front_index, target, trade_price, total_shares, fractions, regime,
                      bonus, loss_pool, tax_rate);
  });
}
