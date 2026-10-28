// src/simulation_core.cpp
// .Call-Huellen der Engine-Kerne aus src/simulation_core_impl.h (Etappe 7.3a).
//
// Die Kerne (Rechnung und Zugriffe auf sim_mem) stehen seit Etappe 7.3a in
// src/simulation_core_impl.h (gemeinsam mit Python: simlev._ext; kanonisch in core/, F16); diese Datei
// bindet sie mit dem R-Host aus simlev_capi.h ein und enthaelt die .Call-Huellen
// (Umwandlung der Argumente wie frueher).

#include "simlev_capi.h"
#include "simulation_core_impl.h"

// ===========================================================================
// .CALL-HUELLEN (registriert in init.c). Argumente wie die frueheren
// Rcpp-Huellen: input als Liste, name als Rcpp::String (erstes Element eines
// Zeichenvektors), assets als Zeichenvektor; Rueckgabe NULL (R: invisible()).
// ===========================================================================

extern "C" SEXP C_sim_dca_flows(SEXP s_input, SEXP s_name, SEXP s_flows, SEXP s_index) {
  return sl::call([&]() {
    SEXP input = sl::as_list(s_input);
    const char* name = sl::as_rstring(s_name);
    double flows = sl::as_double(s_flows);
    int index = sl::as_int(s_index);
    simlev::dca_flows_allocation(input, name, flows, index);
    return R_NilValue;
  });
}

extern "C" SEXP C_sim_buy_report(SEXP s_input, SEXP s_name, SEXP s_index, SEXP s_trade_count,
                                 SEXP s_trade_price, SEXP s_market_price) {
  return sl::call([&]() {
    SEXP input = sl::as_list(s_input);
    const char* name = sl::as_rstring(s_name);
    int index = sl::as_int(s_index);
    double trade_count = sl::as_double(s_trade_count);
    double trade_price = sl::as_double(s_trade_price);
    double market_price = sl::as_double(s_market_price);
    simlev::calculate_buy_report(input, name, index, trade_count, trade_price, market_price);
    return R_NilValue;
  });
}

extern "C" SEXP C_sim_sell_report(SEXP s_input, SEXP s_name, SEXP s_index, SEXP s_trade_count,
                                  SEXP s_trade_price, SEXP s_market_price, SEXP s_capital_gains_tax) {
  return sl::call([&]() {
    SEXP input = sl::as_list(s_input);
    const char* name = sl::as_rstring(s_name);
    int index = sl::as_int(s_index);
    double trade_count = sl::as_double(s_trade_count);
    double trade_price = sl::as_double(s_trade_price);
    double market_price = sl::as_double(s_market_price);
    double capital_gains_tax = sl::as_double(s_capital_gains_tax);
    simlev::calculate_sell_report(input, name, index, trade_count, trade_price, market_price, capital_gains_tax);
    return R_NilValue;
  });
}

extern "C" SEXP C_sim_total_report(SEXP s_input, SEXP s_assets, SEXP s_index) {
  return sl::call([&]() {
    SEXP input = sl::as_list(s_input);
    SEXP assets = sl::as_character(s_assets);
    int index = sl::as_int(s_index);
    simlev::calculate_total_report(input, assets, index);
    return R_NilValue;
  });
}

extern "C" SEXP C_sim_buy(SEXP s_input, SEXP s_name, SEXP s_index, SEXP s_trade_count,
                          SEXP s_trade_price, SEXP s_market_price) {
  return sl::call([&]() {
    SEXP input = sl::as_list(s_input);
    const char* name = sl::as_rstring(s_name);
    int index = sl::as_int(s_index);
    double trade_count = sl::as_double(s_trade_count);
    double trade_price = sl::as_double(s_trade_price);
    double market_price = sl::as_double(s_market_price);
    simlev::perform_trade_buy_cpp(input, name, index, trade_count, trade_price, market_price);
    return R_NilValue;
  });
}

extern "C" SEXP C_sim_market_update(SEXP s_input, SEXP s_assets, SEXP s_index) {
  return sl::call([&]() {
    SEXP input = sl::as_list(s_input);
    SEXP assets = sl::as_character(s_assets);
    int index = sl::as_int(s_index);
    simlev::perform_market_update(input, assets, index);
    return R_NilValue;
  });
}

extern "C" SEXP C_sim_market_update_batch(SEXP s_input, SEXP s_assets, SEXP s_start_idx, SEXP s_end_idx) {
  return sl::call([&]() {
    SEXP input = sl::as_list(s_input);
    SEXP assets = sl::as_character(s_assets);
    int start_idx = sl::as_int(s_start_idx);
    int end_idx = sl::as_int(s_end_idx);
    simlev::batch_market_update(input, assets, start_idx, end_idx);
    return R_NilValue;
  });
}
