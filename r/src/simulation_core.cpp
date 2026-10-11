// src/simulation_core.cpp
// Core C++ functions for SimLev package
//
// Version: 2.2.1
//
// WICHTIG: Alle Zugriffe auf status/report/market verwenden Named Access,
// um Indizierungsfehler zu vermeiden.
//
// Status-Felder (R-Namen):
//   count, price, worth, money, total, target, actual, differ
//
//   ACHTUNG: Die Feldnamen "actual" und "differ" haben historisch
//   vertauschte Semantik:
//     - "actual" (R[[7]]) enthält das NORMALISIERTE ZIELGEWICHT
//     - "differ" (R[[8]]) enthält das AKTUELLE PORTFOLIO-GEWICHT
//   Dies ist in der R-Initialisierung so angelegt und wird vom gesamten
//   R-Code konsistent so verwendet. Die C++-Funktionen folgen dieser
//   Konvention.
//
// Report-Felder (R-Namen):
//   worth, money, flows, total, share
//
// Market-Felder (R-Namen):
//   asset_day, base_rates, asset_price, signal_buy, signal_sell, spread_rate

#include <Rcpp.h>
#include <vector>
#include <string>
#include <algorithm>
#include <cmath>

using namespace Rcpp;

// ===========================================================================
// HELPER FUNCTIONS
// ===========================================================================

bool leap_year(int year) {
  return (year % 4 == 0 && (year % 100 != 0 || year % 400 == 0));
}

int days_in_month(int year, int month) {
  static const int days[] = {31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31};
  if (month < 1 || month > 12) return 30;
  int d = days[month - 1];
  if (month == 2 && leap_year(year)) d = 29;
  return d;
}

// ===========================================================================
// EXPORTED FUNCTIONS
// ===========================================================================

//' Allocate DCA Flows to an Asset
//'
//' Updates the simulation state with DCA cash flow.
//'
//' @param input Simulation state list
//' @param name Asset name
//' @param flows Amount to add
//' @param index Day index (1-based)
//' @export
// [[Rcpp::export]]
void dca_flows_allocation(List input, String name, double flows, int index) {
  List status = input[1];
  List report = input[4];
  
  List status_name = as<List>(status[name]);
  List report_name = as<List>(report[name]);
  
  // Update flows in report
  NumericVector report_flows = as<NumericVector>(report_name["flows"]);
  report_flows[index - 1] = flows;
  report_name["flows"] = report_flows;
  
  // Update money
  double money = as<double>(status_name["money"]);
  money += flows;
  status_name["money"] = money;
  
  NumericVector report_money = as<NumericVector>(report_name["money"]);
  report_money[index - 1] = money;
  report_name["money"] = report_money;
  
  // Update total
  double worth = as<double>(status_name["worth"]);
  double total = money + worth;
  status_name["total"] = total;
  
  NumericVector report_total = as<NumericVector>(report_name["total"]);
  report_total[index - 1] = total;
  report_name["total"] = report_total;
  
  // Write back
  report[name] = report_name;
  status[name] = status_name;
  input[4] = report;
  input[1] = status;
}


//' Update Report After Buy Transaction
//'
//' @param input Simulation state list
//' @param name Asset name
//' @param index Day index (1-based)
//' @param trade_count Number of shares bought
//' @param trade_price Price paid per share
//' @param market_price Current market price
//' @export
// [[Rcpp::export]]
void calculate_buy_report(List input, String name, int index, 
                          double trade_count, double trade_price, 
                          double market_price) {
  List status = input[1];
  List report = input[4];
  
  List status_name = status[name];
  List report_name = report[name];
  
  double count = as<double>(status_name["count"]);
  double money = as<double>(status_name["money"]);
  
  count += trade_count;
  status_name["count"] = count;
  status_name["price"] = market_price;
  
  double worth = count * market_price;
  status_name["worth"] = worth;
  
  money -= (trade_count * trade_price);
  status_name["money"] = money;
  
  double total = worth + money;
  status_name["total"] = total;
  
  status[name] = status_name;
  input[1] = status;
  
  NumericVector worth_vec = report_name["worth"];
  worth_vec[index - 1] = worth;
  report_name["worth"] = worth_vec;
  
  NumericVector money_vec = report_name["money"];
  money_vec[index - 1] = money;
  report_name["money"] = money_vec;
  
  NumericVector total_vec = report_name["total"];
  total_vec[index - 1] = total;
  report_name["total"] = total_vec;
  
  report[name] = report_name;
  input[4] = report;
}


//' Update Report After Sell Transaction
//'
//' @param input Simulation state list
//' @param name Asset name
//' @param index Day index (1-based)
//' @param trade_count Number of shares sold
//' @param trade_price Price received per share
//' @param market_price Current market price
//' @param capital_gains_tax Tax paid on gains
//' @export
// [[Rcpp::export]]
void calculate_sell_report(List input, String name, int index,
                           double trade_count, double trade_price,
                           double market_price, double capital_gains_tax) {
  List status = input[1];
  List report = input[4];
  
  List status_name = status[name];
  List report_name = report[name];
  
  double count = as<double>(status_name["count"]);
  double money = as<double>(status_name["money"]);
  
  count -= trade_count;
  status_name["count"] = count;
  status_name["price"] = market_price;
  
  double worth = count * market_price;
  status_name["worth"] = worth;
  
  money += (trade_count * trade_price) - capital_gains_tax;
  status_name["money"] = money;
  
  double total = worth + money;
  status_name["total"] = total;
  
  status[name] = status_name;
  input[1] = status;
  
  NumericVector worth_vec = report_name["worth"];
  worth_vec[index - 1] = worth;
  report_name["worth"] = worth_vec;
  
  NumericVector money_vec = report_name["money"];
  money_vec[index - 1] = money;
  report_name["money"] = money_vec;
  
  NumericVector total_vec = report_name["total"];
  total_vec[index - 1] = total;
  report_name["total"] = total_vec;
  
  report[name] = report_name;
  input[4] = report;
}


//' Calculate Total Report for All Assets
//'
//' Updates status and report for all assets at a given day.
//' Recalculates portfolio weights (stored in status "differ" field)
//' based on current market values.
//'
//' @param input Simulation state list
//' @param assets Character vector of asset names
//' @param index Day index (1-based)
//' @export
// [[Rcpp::export]]
void calculate_total_report(List input, CharacterVector assets, int index) {
  List status = input[1];
  List market = input[2];
  List report = input[4];
  
  // First pass: update prices and calculate totals
  for (int i = 0; i < assets.size(); i++) {
    String name = assets[i];
    
    List status_name = as<List>(status[name]);
    List market_name = as<List>(market[name]);
    List report_name = as<List>(report[name]);
    
    NumericVector asset_price = as<NumericVector>(market_name["asset_price"]);
    double price = asset_price[index - 1];
    status_name["price"] = price;
    
    double count = as<double>(status_name["count"]);
    double worth = price * count;
    status_name["worth"] = worth;
    
    NumericVector report_worth = as<NumericVector>(report_name["worth"]);
    report_worth[index - 1] = worth;
    report_name["worth"] = report_worth;
    
    double money = as<double>(status_name["money"]);
    NumericVector report_money = as<NumericVector>(report_name["money"]);
    report_money[index - 1] = money;
    report_name["money"] = report_money;
    
    double total = money + worth;
    status_name["total"] = total;
    NumericVector report_total = as<NumericVector>(report_name["total"]);
    report_total[index - 1] = total;
    report_name["total"] = report_total;
    
    status[name] = status_name;
    report[name] = report_name;
  }
  
  // Calculate total portfolio worth
  double total_worth = 0.0;
  for (int i = 0; i < assets.size(); i++) {
    String name = assets[i];
    List status_name = as<List>(status[name]);
    total_worth += as<double>(status_name["total"]);
  }
  
  // Second pass: calculate and store portfolio weights
  //
  // Feldkonvention (historisch bedingt):
  //   status["actual"] = normalisiertes Zielgewicht (wird hier NICHT ueberschrieben)
  //   status["differ"] = aktuelles Portfolio-Gewicht (wird hier aktualisiert)
  //
  for (int i = 0; i < assets.size(); i++) {
    String name = assets[i];
    
    List status_name = as<List>(status[name]);
    List report_name = as<List>(report[name]);
    
    double total = as<double>(status_name["total"]);
    double current_weight = (total_worth > 0) ? total / total_worth : 0.0;
    
    // Aktuelles Portfolio-Gewicht in "differ" speichern
    // (R-Code liest dies als sim_mem[[2]][[name]][[8]] fuer DCA/Rebalancing)
    status_name["differ"] = current_weight;
    
    // Report: share-Vektor aktualisieren
    NumericVector report_share = as<NumericVector>(report_name["share"]);
    report_share[index - 1] = current_weight;
    report_name["share"] = report_share;
    
    status[name] = status_name;
    report[name] = report_name;
  }
  
  input[1] = status;
  input[4] = report;
}


//' Perform Trade Buy (C++ Core)
//'
//' Executes the core buy logic: calls calculate_buy_report (report + status update),
//' creates a FIFO lot entry, and increments buy_count. All by-reference.
//'
//' The R wrapper handles: trade_count calculation (spread, fractions), details output.
//'
//' @param input Simulation state list (modified in place)
//' @param name Asset name
//' @param index Day index (1-based)
//' @param trade_count Number of units to buy
//' @param trade_price Price per unit (after spread)
//' @param market_price Raw market price (before spread)
//' @export
// [[Rcpp::export]]
void perform_trade_buy_cpp(List input, String name, int index,
                           double trade_count, double trade_price,
                           double market_price) {
  
  // 1. Report + Status Update (via existing C++ function)
  calculate_buy_report(input, name, index, trade_count, trade_price, market_price);
  
  // 2. FIFO-Lot erstellen
  List trades = input[3];  // trades
  List trades_name = as<List>(trades[name]);
  
  // Kaufdatum aus market[[name]][["asset_day"]]
  List market = input[2];
  List market_name = as<List>(market[name]);
  DateVector asset_days = as<DateVector>(market_name["asset_day"]);
  Date event_date = asset_days[index - 1];
  
  // Lot-Felder: Named Access, konsistent mit R-Code
  // buy[["date"]], buy[["type"]], buy[["count"]], buy[["price"]],
  // buy[["remaining"]], buy[["original"]], (buy[["vp"]] wird später am 31.12. ergänzt)
  List lot = List::create(
    Named("date") = Date(event_date),
    Named("type") = "Buy",
    Named("count") = trade_count,
    Named("price") = trade_price,
    Named("remaining") = trade_count,
    Named("original") = trade_count
  );
  
  // 3. Lot an buys-Liste anhängen
  int buy_count = as<int>(trades_name["buy_count"]) + 1;
  trades_name["buy_count"] = buy_count;
  
  List buys = as<List>(trades_name["buys"]);
  buys[buy_count - 1] = lot;  // 0-basierter Index
  trades_name["buys"] = buys;
  
  trades[name] = trades_name;
  input[3] = trades;
}


//' Single-Day Market Update (Fast Path)
//'
//' Updates prices, worth, total, and portfolio weights for all assets
//' on a single day. Replaces the R-level perform_market_update.
//'
//' @param input Simulation state list (modified in place)
//' @param assets Character vector of asset names
//' @param index Day index (1-based)
//' @export
// [[Rcpp::export]]
void perform_market_update(List input, CharacterVector assets, int index) {
  List status = input[1];
  List market = input[2];
  List report = input[4];
  
  int n_assets = assets.size();
  double total_portfolio = 0.0;
  std::vector<double> asset_totals(n_assets);
  
  for (int i = 0; i < n_assets; i++) {
    String name = assets[i];
    List status_name = as<List>(status[name]);
    List market_name = as<List>(market[name]);
    List report_name = as<List>(report[name]);
    
    NumericVector prices = as<NumericVector>(market_name["asset_price"]);
    double count = as<double>(status_name["count"]);
    double money = as<double>(status_name["money"]);
    double worth = count * prices[index - 1];
    double total = worth + money;
    
    asset_totals[i] = total;
    total_portfolio += total;
    
    // Report-Vektoren in-place aktualisieren
    NumericVector rw = as<NumericVector>(report_name["worth"]);
    NumericVector rm = as<NumericVector>(report_name["money"]);
    NumericVector rf = as<NumericVector>(report_name["flows"]);
    NumericVector rt = as<NumericVector>(report_name["total"]);
    rw[index - 1] = worth;
    rm[index - 1] = money;
    rf[index - 1] = 0.0;
    rt[index - 1] = total;
    
    // Status aktualisieren
    status_name["price"] = prices[index - 1];
    status_name["worth"] = worth;
    status_name["total"] = total;
    
    status[name] = status_name;
  }
  
  // Gewichte berechnen und schreiben
  for (int i = 0; i < n_assets; i++) {
    String name = assets[i];
    List status_name = as<List>(status[name]);
    List report_name = as<List>(report[name]);
    
    double weight = (total_portfolio > 0) ? asset_totals[i] / total_portfolio : 0.0;
    NumericVector rs = as<NumericVector>(report_name["share"]);
    rs[index - 1] = weight;
    status_name["differ"] = weight;
    
    status[name] = status_name;
  }
  
  input[1] = status;
  input[4] = report;
}


//' Batch Market Update for Contiguous Fast-Path Days
//'
//' Vectorized update for a range of days where no trades, DCA, rebalancing,
//' year-change, or staking events occur. During these days, count and money
//' are constant per asset, so worth and total are simple price-scaled vectors.
//'
//' This replaces hundreds of individual perform_market_update() calls with
//' a single tight C++ loop over the price vectors.
//'
//' @param input Simulation state list (modified in place)
//' @param assets Character vector of asset names
//' @param start_idx First day index (1-based, inclusive)
//' @param end_idx Last day index (1-based, inclusive)
//' @export
// [[Rcpp::export]]
void batch_market_update(List input, CharacterVector assets, 
                         int start_idx, int end_idx) {
  List status = input[1];
  List market = input[2];
  List report = input[4];
  
  int n_assets = assets.size();
  int n_days = end_idx - start_idx + 1;
  if (n_days <= 0) return;
  
  // Portfolio-Tagessummen fuer Gewichtsberechnung
  std::vector<double> portfolio_totals(n_days, 0.0);
  
  // === PASS 1: Preise, Worth, Total berechnen und Report schreiben ===
  // Pro Asset: Ein Durchlauf ueber den Preisvektor (cache-freundlich)
  for (int a = 0; a < n_assets; a++) {
    String name = assets[a];
    List status_name = as<List>(status[name]);
    List market_name = as<List>(market[name]);
    List report_name = as<List>(report[name]);
    
    double count = as<double>(status_name["count"]);
    double money = as<double>(status_name["money"]);
    
    NumericVector prices = as<NumericVector>(market_name["asset_price"]);
    NumericVector rw = as<NumericVector>(report_name["worth"]);
    NumericVector rm = as<NumericVector>(report_name["money"]);
    NumericVector rf = as<NumericVector>(report_name["flows"]);
    NumericVector rt = as<NumericVector>(report_name["total"]);
    
    double last_worth = 0.0, last_total = 0.0, last_price = 0.0;
    
    for (int d = 0; d < n_days; d++) {
      int idx = start_idx - 1 + d;  // 0-basierter Index
      double price = prices[idx];
      double worth = count * price;
      double total = worth + money;
      
      rw[idx] = worth;
      rm[idx] = money;
      rf[idx] = 0.0;
      rt[idx] = total;
      
      portfolio_totals[d] += total;
      last_price = price;
      last_worth = worth;
      last_total = total;
    }
    
    // Status auf letzten Tag des Blocks setzen
    status_name["price"] = last_price;
    status_name["worth"] = last_worth;
    status_name["total"] = last_total;
    
    status[name] = status_name;
  }
  
  // === PASS 2: Portfolio-Gewichte berechnen ===
  for (int a = 0; a < n_assets; a++) {
    String name = assets[a];
    List status_name = as<List>(status[name]);
    List report_name = as<List>(report[name]);
    
    NumericVector rs = as<NumericVector>(report_name["share"]);
    NumericVector rt = as<NumericVector>(report_name["total"]);
    
    double last_weight = 0.0;
    for (int d = 0; d < n_days; d++) {
      int idx = start_idx - 1 + d;
      double weight = (portfolio_totals[d] > 0.0) 
                        ? rt[idx] / portfolio_totals[d] 
                        : 0.0;
      rs[idx] = weight;
      last_weight = weight;
    }
    
    // Status-Gewicht auf letzten Tag des Blocks setzen
    status_name["differ"] = last_weight;
    status[name] = status_name;
  }
  
  input[1] = status;
  input[4] = report;
}
