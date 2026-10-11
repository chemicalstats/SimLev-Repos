// ═══════════════════════════════════════════════════════════════════════════
// tax_core_RCpp.cpp — Rcpp-Ports der Steuer-Kerne (Vollmigration Rechen-Engine)
// 1:1-Semantik zu den R-Originalen:
//   calculate_flat_rate (VP je Lot: Zwoelftelung T-1, Growth-Cap, M4),
//   calculate_paragraph_20_tax (TFS -> Verlusttopf -> SPB -> Tracker),
//   calculate_vorabpauschale_tax (R-2: Verlusttopf vor SPB),
//   calculate_sell_count (kum. FIFO + Bisektion + Integer-Rounding).
// totals-Listen werden IN PLACE mutiert (etabliertes by-reference-Muster).
// ═══════════════════════════════════════════════════════════════════════════
#include <Rcpp.h>
using namespace Rcpp;

static inline bool lot_is_null2(SEXP b) {
  return Rf_isNull(b) || Rf_length(b) == 0;
}
static inline double tget(List& t, const char* fld) {          // %||% 0
  if (!t.containsElementNamed(fld)) return 0.0;
  SEXP v = t[fld];
  return Rf_isNull(v) ? 0.0 : as<double>(v);
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

//' Vorabpauschale je Lot (Port des Kerns von calculate_flat_rate)
//' base_rate bereits dezimal (>0), Datums-Args als Tage seit Epoch.
// [[Rcpp::export]]
List flat_rate_rcpp(List buys, int front_index, double base_rate,
                    double year_start_price, double market_price,
                    int soy_days, int eoy_days) {
  const int n = buys.size();
  List empty = List::create(Named("total_vp") = 0.0,
                            Named("lot_indices") = IntegerVector(0),
                            Named("lot_vps") = NumericVector(0));
  if (front_index > n) return empty;

  // M4: aktive Lots (remaining > 0) sammeln; NULL-Lot = Ende der Liste
  std::vector<int>    idx;
  std::vector<double> vps;
  idx.reserve(n - front_index + 1);
  vps.reserve(n - front_index + 1);

  for (int i = front_index; i <= n; ++i) {
    SEXP bs = buys[i - 1];
    if (lot_is_null2(bs)) break;                 // Sentinel wie R (first_null)
    List b(bs);
    double rem = as<double>(b["remaining"]);
    if (rem <= 0) continue;                      // nur aktive Lots

    int buy_days = static_cast<int>(as<double>(b["date"]));
    double vp = 0.0;
    if (buy_days <= eoy_days) {
      double months_factor, reference_value;
      if (buy_days < soy_days) {                 // ganzjaehrig gehalten
        months_factor   = 1.0;
        reference_value = rem * year_start_price;
      } else {                                   // T-1: Zwoelftelung
        int y, m, d; civil_from_days2(buy_days, y, m, d);
        months_factor   = (12.0 - (m - 1)) / 12.0;
        reference_value = rem * as<double>(b["price"]);
      }
      double base_worth   = reference_value * base_rate * 0.7 * months_factor;
      double market_worth = rem * market_price;
      double growth       = std::max(0.0, market_worth - reference_value);
      vp = std::max(0.0, std::min(base_worth, growth));
    }
    idx.push_back(i);
    vps.push_back(vp);
  }

  long double total_ld = 0.0L;              // wie R sum(): long-double-Akkumulator
  for (double v : vps) total_ld += v;
  double total = static_cast<double>(total_ld);
  return List::create(Named("total_vp") = total,
                      Named("lot_indices") = wrap(idx),
                      Named("lot_vps") = wrap(vps));
}

//' § 20-Steuerkern (Port von calculate_paragraph_20_tax); mutiert totals in place
// [[Rcpp::export]]
List p20_tax_rcpp(double trade_gain, double bonus, List totals,
                  double tax_rate, bool use_spb) {
  double adjusted_gain = trade_gain * (1.0 - bonus);

  if (adjusted_gain < 0) {
    totals["loss_capital_gains"] = as<double>(totals["loss_capital_gains"]) - adjusted_gain;
    totals["cgt_loss_added_ytd"] = tget(totals, "cgt_loss_added_ytd") - adjusted_gain;
    return List::create(Named("tax") = 0.0, Named("spb_used") = 0.0);
  }

  double pool = as<double>(totals["loss_capital_gains"]);
  double loss_offset = std::min(adjusted_gain, pool);
  totals["loss_capital_gains"] = pool - loss_offset;
  totals["cgt_loss_used_ytd"]  = tget(totals, "cgt_loss_used_ytd") + loss_offset;
  double gain_after_loss = adjusted_gain - loss_offset;

  double spb_offset = 0.0;
  double spb_rem = as<double>(totals["sparer_pauschbetrag_remaining"]);
  if (use_spb && spb_rem > 0) {
    spb_offset = std::min(gain_after_loss, spb_rem);
    totals["sparer_pauschbetrag_remaining"]  = spb_rem - spb_offset;
    totals["sparer_pauschbetrag_used_total"] =
      as<double>(totals["sparer_pauschbetrag_used_total"]) + spb_offset;
  }

  double taxable_gain = gain_after_loss - spb_offset;
  totals["cgt_base_taxed_ytd"] = tget(totals, "cgt_base_taxed_ytd") + taxable_gain;
  double tax = taxable_gain * tax_rate;
  totals["total_taxes"] = as<double>(totals["total_taxes"]) + tax;

  return List::create(Named("tax") = tax, Named("spb_used") = spb_offset);
}

//' VP-Steuerkern (Port von calculate_vorabpauschale_tax, R-2); mutiert totals
// [[Rcpp::export]]
List vp_tax_rcpp(double flat_rate, double bonus, List totals,
                 double tax_rate, bool use_spb) {
  double taxable_flat_rate = flat_rate * (1.0 - bonus);

  double pool = as<double>(totals["loss_capital_gains"]);
  double loss_offset = std::min(taxable_flat_rate, pool);
  totals["loss_capital_gains"] = pool - loss_offset;
  totals["cgt_loss_used_ytd"]  = tget(totals, "cgt_loss_used_ytd") + loss_offset;
  double vp_after_loss = taxable_flat_rate - loss_offset;

  double spb_offset = 0.0;
  double spb_rem = as<double>(totals["sparer_pauschbetrag_remaining"]);
  if (use_spb && spb_rem > 0) {
    spb_offset = std::min(vp_after_loss, spb_rem);
    totals["sparer_pauschbetrag_remaining"]  = spb_rem - spb_offset;
    totals["sparer_pauschbetrag_used_total"] =
      as<double>(totals["sparer_pauschbetrag_used_total"]) + spb_offset;
  }

  double taxable_gain = vp_after_loss - spb_offset;
  totals["cgt_base_taxed_ytd"] = tget(totals, "cgt_base_taxed_ytd") +
                                 std::max(0.0, taxable_gain);
  double tax = std::max(0.0, taxable_gain * tax_rate);

  return List::create(Named("tax") = tax,
                      Named("spb_used") = spb_offset,
                      Named("taxable_amount") = taxable_flat_rate);
}

// ── interner FIFO-Fast-Preis auf kumulierten Vektoren (wie R) ──
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

//' Verkaufsstueckzahl fuer Ziel-Nettoerloes (Port von calculate_sell_count)
//' regime: 0=none, 1=investment_fund, 2=capital_gains, 3=private_sale
// [[Rcpp::export]]
List sell_count_rcpp(List buys, int front_index, double target,
                     double trade_price, double total_shares, bool fractions,
                     int regime, double bonus, double loss_pool, double tax_rate) {
  List zero = List::create(Named("sell_count") = 0.0, Named("fifo_price") = 0.0);
  const int n = buys.size();
  if (front_index > n) return zero;

  std::vector<double> units, prices;
  units.reserve(n - front_index + 1);
  prices.reserve(n - front_index + 1);
  for (int i = front_index; i <= n; ++i) {
    SEXP bs = buys[i - 1];
    if (lot_is_null2(bs)) break;                 // Abbruch bei NULL-Lots
    List b(bs);
    double rem = as<double>(b["remaining"]);
    if (rem > 0) {
      units.push_back(rem);
      prices.push_back(as<double>(b["price"]));
    }
  }
  if (units.empty()) return zero;

  const int nl = static_cast<int>(units.size());
  std::vector<double> cu(nl), cc(nl);
  long double su = 0.0L, sc = 0.0L;         // wie R cumsum(): long-double-Akkumulator
  for (int i = 0; i < nl; ++i) {
    su += units[i];              cu[i] = static_cast<double>(su);
    sc += units[i] * prices[i];  cc[i] = static_cast<double>(sc);
  }

  auto objective = [&](double sell) -> double {
    if (sell <= 0) return -target;
    if (sell > total_shares) sell = total_shares;
    double fp = fifo_fast(sell, cu, cc, prices);
    double gain = (trade_price - fp) * sell;
    double tax = 0.0;
    if (regime == 1) {                                    // investment_fund
      double adj = gain * (1.0 - bonus);
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
    // Bisektion (exakt wie calculate_bisection_search, max 30)
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

  if (!fractions) {
    double tl = std::floor(sell), tu = std::ceil(sell);
    if (tl < 1) tl = 1;
    if (tu > total_shares) tu = total_shares;
    sell = (std::fabs(objective(tl)) <= std::fabs(objective(tu))) ? tl : tu;
  }

  double final_fp = fifo_fast(sell, cu, cc, prices);
  double out = std::max(0.0, std::min(sell, total_shares));
  return List::create(Named("sell_count") = out, Named("fifo_price") = final_fp);
}
