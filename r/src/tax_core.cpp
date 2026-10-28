// src/tax_core.cpp
// .Call-Huellen der Engine-Kerne aus src/tax_core_impl.h (Etappe 7.3a).
//
// Die Kerne (Rechnung und Zugriffe auf sim_mem) stehen seit Etappe 7.3a in
// src/tax_core_impl.h (gemeinsam mit Python: simlev._ext; kanonisch in core/, F16); diese Datei
// bindet sie mit dem R-Host aus simlev_capi.h ein und enthaelt die .Call-Huellen
// (Umwandlung der Argumente wie frueher).

#include "simlev_capi.h"
#include "tax_core_impl.h"

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
    return simlev::flat_rate(buys, front_index, base_rate, year_start_price, market_price, soy_days, eoy_days);
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
    return simlev::p20_tax(trade_gain, bonus, totals, tax_rate, use_spb);
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
    return simlev::vp_tax(flat_rate, bonus, totals, tax_rate, use_spb);
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
    return simlev::sell_count(buys, front_index, target, trade_price, total_shares, fractions, regime,
                      bonus, loss_pool, tax_rate);
  });
}
