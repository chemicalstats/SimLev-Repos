# =============================================================================
# simulation(), Tagesengine im C++-Kern (E17): Aufrufe der Bedingungen je Stelle
# =============================================================================
# Der Kern (core/engine_core_impl.h, enum Site) meldet Warnungen und Abbrueche mit der Stelle, an der sie in
# den bisherigen Phasen von R 1.3.0 entstanden. Die Bedingungen tragen in R deren Aufruf (conditionCall):
# bei Kaeufen und Verkaeufen der Aufruf von .perform_trade_buy bzw. .perform_trade_sell, bei NA in einer
# Bedingung der ganze if-Ausdruck. Stufe 1c: die Aufrufe sind aus den Ruempfen der Phasen von R 1.3.0
# erzeugt (deparse/parse identisch geprueft) und hier festgeschrieben, seit die Phasen entfallen sind.
# Schluessel: Stelle (Site) als Text; 18 und 19: Aufrufe von .perform_asset_split (Abbruch ratio <= 0).
# Nicht von Hand aendern ausser zusammen mit den Stellen im Kern.

.SIM_ENGINE_CALLS <- list(
  "1" = quote(.perform_trade_buy(input = sim_mem, name = name, index = time, reason = reason, spread = spread_rates[[name]], 
        fractions = fractions, details = details)),
  "2" = quote(.perform_trade_buy(input = sim_mem, name = name, index = time, reason = reason, spread = spread_rates[[name]], 
        fractions = fractions, details = details)),
  "3" = quote(.perform_trade_buy(input = sim_mem, name = name, index = time, reason = "Rebalancing/Signal-Einstieg:", 
        spread = spread_rates[[name]], fractions = fractions, details = details)),
  "4" = quote(.perform_trade_buy(input = sim_mem, name = name, index = time, reason = "Rebalancing:", spread = spread_rates[[name]], 
        fractions = fractions, details = details)),
  "5" = quote(.perform_trade_buy(input = input, name = name, index = index, reason = "Freibetrag:", spread = spread, 
        fractions = fractions, details = details)),
  "11" = quote(.perform_trade_sell(input = sim_mem, name = name, index = time, tax_mode = tax_mode, tax_rate = tax_rate, 
        effective_tax_rate = effective_tax_rate, marginal_tax_rate = marginal_tax_rate, private_sale_threshold = private_sale_threshold, 
        use_sparer_pauschbetrag = use_sparer_pauschbetrag, tax_regime = tax_regimes[[name]], reason = "Handelssignal:", 
        spread = spread_rates[[name]], details = details)),
  "12" = quote(.perform_trade_sell(input = sim_mem, name = name, index = time, tax_mode = tax_mode, tax_rate = tax_rate, 
        effective_tax_rate = effective_tax_rate, marginal_tax_rate = marginal_tax_rate, private_sale_threshold = private_sale_threshold, 
        use_sparer_pauschbetrag = use_sparer_pauschbetrag, tax_regime = tax_regimes[[name]], reason = "Rebalancing/Signal-Ausstieg:", 
        spread = spread_rates[[name]], details = details)),
  "13" = quote(.perform_trade_sell(input = sim_mem, name = name, count = sell_result[["sell_count"]], price = sell_result[["fifo_price"]], 
        index = time, tax_mode = tax_mode, tax_rate = tax_rate, effective_tax_rate = effective_tax_rate, 
        marginal_tax_rate = marginal_tax_rate, private_sale_threshold = private_sale_threshold, use_sparer_pauschbetrag = use_sparer_pauschbetrag, 
        tax_regime = tax_regimes[[name]], reason = "Rebalancing:", spread = spread_rates[[name]], details = details)),
  "14" = quote(.perform_trade_sell(input = sim_mem, name = name, index = time, tax_mode = tax_mode, tax_rate = tax_rate, 
        effective_tax_rate = effective_tax_rate, marginal_tax_rate = marginal_tax_rate, private_sale_threshold = private_sale_threshold, 
        use_sparer_pauschbetrag = use_sparer_pauschbetrag, tax_regime = tax_regimes[[name]], reason = "Liquidation:", 
        spread = spread_rates[[name]], details = details)),
  "15" = quote(.perform_trade_sell(input = sim_mem, count = n_sell, price = sell_result[["fifo_price"]], name = name, 
        index = time, tax_mode = tax_mode, tax_rate = tax_rate, effective_tax_rate = effective_tax_rate, 
        marginal_tax_rate = marginal_tax_rate, private_sale_threshold = private_sale_threshold, use_sparer_pauschbetrag = use_sparer_pauschbetrag, 
        tax_regime = tax_regimes[[name]], reason = "Steuerereignis:", spread = spread_rates[[name]], details = details)),
  "16" = quote(.perform_trade_sell(input = sim_mem, count = split_frac, name = name, index = time, tax_mode = tax_mode, 
        tax_rate = tax_rate, effective_tax_rate = effective_tax_rate, marginal_tax_rate = marginal_tax_rate, 
        private_sale_threshold = private_sale_threshold, use_sparer_pauschbetrag = use_sparer_pauschbetrag, 
        tax_regime = tax_regimes[[name]], reason = "Split:", spread = 0, details = details)),
  "17" = quote(.perform_trade_sell(input = input, count = n, name = name, index = index, tax_mode = tax_mode, tax_rate = tax_rate, 
        effective_tax_rate = effective_tax_rate, marginal_tax_rate = marginal_tax_rate, private_sale_threshold = private_sale_threshold, 
        use_sparer_pauschbetrag = use_spb, tax_regime = tax_regime, reason = "Freibetrag:", spread = spread, 
        details = details)),
  "18" = quote(.perform_asset_split(input = sim_mem, name = name, ratio = split_price/100, type = "forward", index = time, 
        fractions = fractions, details = details, current_date = flag_date[time])),
  "19" = quote(.perform_asset_split(input = sim_mem, name = name, ratio = 100/split_price, type = "reverse", index = time, 
        fractions = fractions, details = details, current_date = flag_date[time])),
  "21" = quote(if (input[["assets"]][[name]][["style"]] == "signal" && input[["market"]][[name]][["signal_buy"]][index] && 
        input[["status"]][[name]][["money"]] > 0 && input[["status"]][[name]][["count"]] == 0) {
        signal_buy <- TRUE
    }),
  "22" = quote(if (input[["assets"]][[name]][["style"]] == "signal" && input[["status"]][[name]][["count"]] > 0 && input[["status"]][[name]][["money"]] > 
        0 && !isTRUE(input[["market"]][[name]][["signal_sell"]][index])) {
        signal_buy <- TRUE
    }),
  "23" = quote(if (input[["assets"]][[name]][["style"]] == "bnh" && input[["status"]][[name]][["money"]] > 0) {
        signal_buy <- TRUE
    }),
  "24" = quote(if (input[["assets"]][[name]][["style"]] == "signal" && input[["market"]][[name]][["signal_sell"]][index] && 
        input[["status"]][[name]][["count"]] > 0) {
        signal_sell <- TRUE
    }),
  "25" = quote(if (time == 1L && money - dca_part > 0.005) {
        .fee_env$current <- fee_order
        sim_mem[["status"]][[name]][["money"]] <- money - dca_part
        sim_mem <- .perform_trade_buy(input = sim_mem, name = name, index = time, reason = reason, spread = spread_rates[[name]], 
            fractions = fractions, details = details)
        sim_mem[["status"]][[name]][["money"]] <- sim_mem[["status"]][[name]][["money"]] + dca_part
    }),
  "26" = quote(if (fee < f$min) v <- money - f$min else if (fee > f$max) v <- money - f$max),
  "27" = quote(if (trade_count <= 0) return(input)),
  "28" = quote(if (trade_count <= 0) return(input)),
  "29" = quote(if (count > available) {
        warning(sprintf("perform_trade_sell: angeforderte Verkaufsmenge %.4f \u00fcbersteigt den Bestand %.4f von %s; verkauft wird der gesamte Bestand.", 
            count, available, name))
    }),
  "30" = quote(if (trade_count <= 0) {
        return(input)
    }),
  "31" = quote(if (trade_count * trade_price - fee_paid <= 0) return(input)),
  "32" = quote(if (total_shares <= 0) {
        return(list(sell_count = 0, fifo_price = 0))
    }),
  "33" = quote(if (target <= 0) {
        return(list(sell_count = 0, fifo_price = 0))
    }),
  "34" = quote(if (sum(deficit) > dca_amount) {
        dca_amount * deficit/sum(deficit)
    } else {
        deficit + (dca_amount - sum(deficit)) * strat_w
    }),
  "35" = quote(if (.has_pos && .sig_sell) {
        sim_mem <- .perform_trade_sell(input = sim_mem, name = name, index = time, tax_mode = tax_mode, tax_rate = tax_rate, 
            effective_tax_rate = effective_tax_rate, marginal_tax_rate = marginal_tax_rate, private_sale_threshold = private_sale_threshold, 
            use_sparer_pauschbetrag = use_sparer_pauschbetrag, tax_regime = tax_regimes[[name]], reason = "Rebalancing/Signal-Ausstieg:", 
            spread = spread_rates[[name]], details = details)
        signal_cash_only <- c(signal_cash_only, name)
    } else if (!.has_pos && .sig_buy) {
        sim_mem <- .perform_trade_buy(input = sim_mem, name = name, index = time, reason = "Rebalancing/Signal-Einstieg:", 
            spread = spread_rates[[name]], fractions = fractions, details = details)
    } else if (!.has_pos && !.sig_buy) {
        signal_cash_only <- c(signal_cash_only, name)
    }),
  "36" = quote(if (!.has_pos && .sig_buy) {
        sim_mem <- .perform_trade_buy(input = sim_mem, name = name, index = time, reason = "Rebalancing/Signal-Einstieg:", 
            spread = spread_rates[[name]], fractions = fractions, details = details)
    } else if (!.has_pos && !.sig_buy) {
        signal_cash_only <- c(signal_cash_only, name)
    }),
  "37" = quote(if (!.has_pos && !.sig_buy) {
        signal_cash_only <- c(signal_cash_only, name)
    }),
  "38" = quote(if (sim_mem[["status"]][[name]][["count"]] > 0 && sell_target > 0) {
        sell_result <- .calculate_sell_count(input = sim_mem, name = name, target = sell_target, index = time, 
            spread = spread_rates[[name]], fractions = fractions, tax_mode = tax_mode, tax_rate = effective_tax_rate, 
            marginal_tax_rate = marginal_tax_rate, tax_regime = tax_regimes[[name]])
        sim_mem <- .perform_trade_sell(input = sim_mem, name = name, count = sell_result[["sell_count"]], 
            price = sell_result[["fifo_price"]], index = time, tax_mode = tax_mode, tax_rate = tax_rate, 
            effective_tax_rate = effective_tax_rate, marginal_tax_rate = marginal_tax_rate, private_sale_threshold = private_sale_threshold, 
            use_sparer_pauschbetrag = use_sparer_pauschbetrag, tax_regime = tax_regimes[[name]], reason = "Rebalancing:", 
            spread = spread_rates[[name]], details = details)
    }),
  "39" = quote(if (allocation > 0) {
        sim_mem[["status"]][[name]][["money"]] <- sim_mem[["status"]][[name]][["money"]] + allocation
        transfer_pool <- transfer_pool - allocation
        if (details) {
            cat(sprintf("Rebalancing:\t%.2f EUR aus dem Rebalancing-Topf an %s\n", allocation, name))
        }
        if (name %in% signal_cash_only) {
            if (details) {
                cat(sprintf("\t\t=> %s h\u00e4lt %.2f EUR als Cash-Reserve (Signal inaktiv)\n", name, sim_mem[["status"]][[name]][["money"]]))
            }
        }
        else {
            sim_mem <- .perform_trade_buy(input = sim_mem, name = name, index = time, reason = "Rebalancing:", 
                spread = spread_rates[[name]], fractions = fractions, details = details)
        }
    }),
  "40" = quote(if (transfer_pool > 0.01) {
        if (details) {
            cat(sprintf("\t\tRestverteilung von %.2f EUR aus dem Rebalancing-Topf\n", transfer_pool))
        }
        for (name in active_assets) {
            redistribution <- active_targets[[name]] * transfer_pool
            sim_mem[["status"]][[name]][["money"]] <- sim_mem[["status"]][[name]][["money"]] + redistribution
            if (details) {
                cat(sprintf("\t\t=> %.2f EUR an %s\n", redistribution, name))
            }
        }
    }),
  "41" = quote(if (!(name %in% signal_cash_only) && sim_mem[["status"]][[name]][["money"]] > 0.005 && (sim_mem[["assets"]][[name]][["style"]] != 
        "signal" || sim_mem[["status"]][[name]][["count"]] > 0)) {
        sim_mem <- .buy_with_fee(sim_mem, name, time, "Rebalancing:")
    }),
  "42" = quote(if (sim_mem[["status"]][[name]][["count"]] > 0) {
        sim_mem <- .perform_trade_sell(input = sim_mem, name = name, index = time, tax_mode = tax_mode, tax_rate = tax_rate, 
            effective_tax_rate = effective_tax_rate, marginal_tax_rate = marginal_tax_rate, private_sale_threshold = private_sale_threshold, 
            use_sparer_pauschbetrag = use_sparer_pauschbetrag, tax_regime = tax_regimes[[name]], reason = "Liquidation:", 
            spread = spread_rates[[name]], details = details)
        if (sim_mem[["status"]][[name]][["count"]] > 0) 
            warning(sprintf("simulation: liquidate = TRUE: Position '%s' (Wert %.2f EUR) wurde nicht verkauft, weil die Ordergeb\u00fchr den Erl\u00f6s \u00fcbersteigt.", 
                name, sim_mem[["status"]][[name]][["worth"]]), call. = FALSE)
    }),
  "43" = quote(if (sim_mem[["status"]][[name]][["count"]] > 0) warning(sprintf("simulation: liquidate = TRUE: Position '%s' (Wert %.2f EUR) wurde nicht verkauft, weil die Ordergeb\u00fchr den Erl\u00f6s \u00fcbersteigt.", 
        name, sim_mem[["status"]][[name]][["worth"]]), call. = FALSE)),
  "44" = quote(if (!flag_slow_path[time]) {
        .sim_market_update_cpp(sim_mem, flag_assets, time)
        prev_end <- time
        next
    }),
  "45" = quote(if (net_by != 0) {
        by <- input[["totals"]][["private_sale_net_ytd_by"]]
        input[["totals"]][["private_sale_net_ytd_by"]][name] <- (if (name %in% names(by)) 
            by[[name]]
        else 0) + net_by
    }),
  "46" = quote(if (lot_result$taxable_gain > 0) {
        input[["totals"]][["private_sale_gains_ytd"]] <- input[["totals"]][["private_sale_gains_ytd"]] + 
            lot_result$taxable_gain
        if (details) {
            cat(sprintf("\t\t=> Steuerpflichtiger Gewinn (Haltedauer < 1 Jahr): %.2f EUR (seit Jahresbeginn: %.2f EUR)\n", 
                lot_result$taxable_gain, input[["totals"]][["private_sale_gains_ytd"]]))
        }
    }),
  "47" = quote(if (lot_result$taxable_loss > 0) {
        input[["totals"]][["private_sale_losses_ytd"]] <- input[["totals"]][["private_sale_losses_ytd"]] + 
            lot_result$taxable_loss
        if (details) {
            cat(sprintf("\t\t=> Verrechenbarer Verlust (Haltedauer < 1 Jahr): %.2f EUR (seit Jahresbeginn: %.2f EUR)\n", 
                lot_result$taxable_loss, input[["totals"]][["private_sale_losses_ytd"]]))
        }
    }),
  "48" = quote(if (net_saldo >= private_sale_threshold && net_saldo > 0) {
        carryforward_offset <- min(net_saldo, input[["totals"]][["loss_private_sales"]])
        input[["totals"]][["loss_private_sales"]] <- input[["totals"]][["loss_private_sales"]] - carryforward_offset
        net_gain <- net_saldo - carryforward_offset
        if (details && carryforward_offset > 0) {
            cat(sprintf("  \u00a7 23 EStG: Verlustvortrag verwendet: %.2f EUR\n", carryforward_offset))
            cat(sprintf("             Verbleibender Vortrag: %.2f EUR\n", input[["totals"]][["loss_private_sales"]]))
        }
    }),
  "49" = quote(if (net_gain > 0) {
        if (is.null(tariff_env)) {
            if (is.null(marginal_tax_rate)) {
                warning(sprintf("simulation: Paragraf 23 EStG: Gewinne (%.2f EUR) erreichen die Freigrenze (%.2f EUR), ", 
                    net_saldo, private_sale_threshold), "aber 'marginal_tax_rate' ist nicht gesetzt.\n", 
                    "Verwendet wird 42 % (Spitzensteuersatz); marginal_tax_rate in Prozent angeben (z. B. 42).", 
                    call. = FALSE)
                marginal_tax_rate <- 0.42
            }
            tax_due <- net_gain * marginal_tax_rate * (soli_factor_income + church_factor)
            input[["totals"]][["total_taxes"]] <- input[["totals"]][["total_taxes"]] + tax_due
            input <- .book_tax_due(input, tax_due)
        }
        if (details) {
            cat(sprintf("\n  \u26a0 FREIGRENZE ERREICHT!\n"))
            cat(sprintf("    Jahressaldo %.2f EUR >= Freigrenze %.2f EUR\n", net_saldo, private_sale_threshold))
            cat(sprintf("    \u2192 GESAMTER Gewinn nach Verlustvortrag steuerpflichtig: %.2f EUR (Freigrenze, kein Freibetrag!)\n", 
                net_gain))
            if (!is.null(tariff_env)) {
                cat("    \u2192 Steuer nach dem Einkommensteuertarif (ESt + Soli + KiSt des \u00a7 23-Zuwachses): siehe Jahresveranlagung unten (Zeile \u00a7 23)\n")
            }
            else {
                cat(sprintf("    \u2192 Steuersatz: %.1f%%%s%s\n", marginal_tax_rate * 100, if (soli_factor_income > 
                    1) 
                    sprintf(" + %.1f%%%% Soli", (soli_factor_income - 1) * 100)
                else "", if (church_factor > 0) 
                    sprintf(" + %.1f%% KiSt", church_factor * 100)
                else ""))
                cat(sprintf("    \u2192 Steuerlast: %.2f EUR\n", tax_due))
            }
        }
    } else if (net_ytd_losses > 0) {
        input[["totals"]][["loss_private_sales"]] <- input[["totals"]][["loss_private_sales"]] + net_ytd_losses
        if (details) {
            cat(sprintf("\n  Nettoverlust %.2f EUR \u2192 Vortrag ins n\u00e4chste Jahr\n", net_ytd_losses))
            cat(sprintf("  Gesamter Verlustvortrag: %.2f EUR\n", input[["totals"]][["loss_private_sales"]]))
        }
    } else if (net_saldo > 0 && net_saldo < private_sale_threshold) {
        if (details) {
            cat(sprintf("\n  \u2713 Jahressaldo %.2f EUR < Freigrenze %.2f EUR \u2192 STEUERFREI (Verlustvortrag unver\u00e4ndert)\n", 
                net_saldo, private_sale_threshold))
        }
    } else {
        if (details) {
            cat(sprintf("\n  Keine steuerpflichtigen \u00a7 23 Vorg\u00e4nge in %d\n", stored_year))
        }
    }),
  "50" = quote(if (net_ytd_losses > 0) {
        input[["totals"]][["loss_private_sales"]] <- input[["totals"]][["loss_private_sales"]] + net_ytd_losses
        if (details) {
            cat(sprintf("\n  Nettoverlust %.2f EUR \u2192 Vortrag ins n\u00e4chste Jahr\n", net_ytd_losses))
            cat(sprintf("  Gesamter Verlustvortrag: %.2f EUR\n", input[["totals"]][["loss_private_sales"]]))
        }
    } else if (net_saldo > 0 && net_saldo < private_sale_threshold) {
        if (details) {
            cat(sprintf("\n  \u2713 Jahressaldo %.2f EUR < Freigrenze %.2f EUR \u2192 STEUERFREI (Verlustvortrag unver\u00e4ndert)\n", 
                net_saldo, private_sale_threshold))
        }
    } else {
        if (details) {
            cat(sprintf("\n  Keine steuerpflichtigen \u00a7 23 Vorg\u00e4nge in %d\n", stored_year))
        }
    }),
  "51" = quote(if (net_saldo > 0 && net_saldo < private_sale_threshold) {
        if (details) {
            cat(sprintf("\n  \u2713 Jahressaldo %.2f EUR < Freigrenze %.2f EUR \u2192 STEUERFREI (Verlustvortrag unver\u00e4ndert)\n", 
                net_saldo, private_sale_threshold))
        }
    } else {
        if (details) {
            cat(sprintf("\n  Keine steuerpflichtigen \u00a7 23 Vorg\u00e4nge in %d\n", stored_year))
        }
    }),
  "52" = quote(if (carry_start > 0) {
        spb_used_ytd <- if (use_sparer_pauschbetrag) 
            max(0, input[["totals"]][["sparer_pauschbetrag_annual"]] - input[["totals"]][["sparer_pauschbetrag_remaining"]])
        else 0
        carry_used <- min(carry_start, max(0, cgt_loss_used + spb_used_ytd + cgt_base_taxed - cgt_loss_added))
    }),
  "53" = quote(if (refund_done) {
        refund <- refund_base * effective_tax_rate
        asset_names <- names(input[["status"]])
        w <- vapply(asset_names, function(nm) input[["status"]][[nm]][["actual"]] %||% 0, numeric(1))
        w <- if (sum(w) > 0) 
            w/sum(w)
        else rep(1/length(asset_names), length(asset_names))
        for (nm in asset_names) {
            input[["status"]][[nm]][["money"]] <- input[["status"]][[nm]][["money"]] + refund * w[[nm]]
        }
        input[["totals"]][["total_taxes"]] <- input[["totals"]][["total_taxes"]] - refund
        input[["totals"]][["loss_capital_gains"]] <- input[["totals"]][["loss_capital_gains"]] - refund_base
        if (details) {
            cat(sprintf("  \u00a7 20 EStG: Unterj\u00e4hrige Verlustverrechnung -> Erstattung %.2f EUR in den Geldbestand\n", 
                refund))
        }
    }),
  "54" = quote(if (release > 0) {
        input[["totals"]][["loss_capital_gains"]] <- input[["totals"]][["loss_capital_gains"]] - release
        input[["totals"]][["sparer_pauschbetrag_remaining"]] <- input[["totals"]][["sparer_pauschbetrag_remaining"]] + 
            release
        input[["totals"]][["sparer_pauschbetrag_used_total"]] <- input[["totals"]][["sparer_pauschbetrag_used_total"]] - 
            release
        if (details) {
            cat(sprintf("  \u00a7 20 EStG: Verlust gibt Sparer-Pauschbetrag frei: %.2f EUR (genutzt %d: %.2f EUR, Verlusttopf %.2f EUR)\n", 
                release, stored_year, spb_used_year - release, input[["totals"]][["loss_capital_gains"]]))
        }
    }),
  "55" = quote(if (any_refund && abs(input[["totals"]][["total_taxes"]]) < 1e-09) input[["totals"]][["total_taxes"]] <- 0),
  "56" = quote(if (sum(w) > 0) w/sum(w) else rep(1/length(asset_names), length(asset_names))),
  "57" = quote(if (sum(w) > 0) w/sum(w) else rep(1/length(flag_assets), length(flag_assets))),
  "58" = quote(if (abs(input[["totals"]][["total_taxes"]]) < 1e-09) input[["totals"]][["total_taxes"]] <- 0),
  "59" = quote(if (money >= amount) {
        sim_mem[["status"]][[name]][["money"]] <- money - amount
        if (details) {
            cat(sprintf("Steuerereignis:\tZahlung %s %.2f EUR f\u00fcr %s aus dem Geldbestand am %s\n", label, 
                amount, name, flag_date[time]))
        }
        return(list(sim_mem = sim_mem, unpaid = 0))
    }),
  "60" = quote(if (money > 0) {
        remaining <- amount - money
        sim_mem[["status"]][[name]][["money"]] <- 0
        if (details) {
            cat(sprintf("Steuerereignis:\tTeilzahlung %s %.2f EUR aus dem Geldbestand am %s\n", label, money, 
                flag_date[time]))
        }
    }),
  "61" = quote(if (short <= 0.005 || sim_mem[["status"]][[name]][["count"]] <= 0) break),
  "62" = quote(if (k > 1 || !(n_sell > 0)) n_sell <- max(n_sell, if (fractions) min(sim_mem[["status"]][[name]][["count"]], 
        1e-06) else min(1, sim_mem[["status"]][[name]][["count"]]))),
  "63" = quote(if (raised(sim_mem) <= before) break),
  "64" = quote(if (short <= 0.005) {
        sim_mem[["status"]][[name]][["money"]] <- sim_mem[["status"]][[name]][["money"]] - remaining
    } else {
        sim_mem[["status"]][[name]][["money"]] <- c0
        unpaid <- short
    }),
  "65" = quote(if (round_up && !fractions && res[["sell_count"]] > 0) res <- list(sell_count = min(sim_mem[["status"]][[name]][["count"]], 
        ceiling(res[["sell_count"]] - 1e-09)), fifo_price = NULL)),
  "66" = quote(if (unpaid > 1e-06) {
        others <- setdiff(flag_assets, name)
        val <- vapply(others, function(nm) sim_mem[["status"]][[nm]][["count"]] * sim_mem[["market"]][[nm]][["asset_price"]][time] + 
            max(0, sim_mem[["status"]][[nm]][["money"]]), numeric(1))
        for (nm in others[order(-val)]) {
            if (unpaid <= 1e-06) 
                break
            if (!(val[[nm]] > 0)) 
                next
            r <- .pay_one(sim_mem, nm, unpaid, time, label)
            sim_mem <- r$sim_mem
            unpaid <- r$unpaid
        }
    }),
  "67" = quote(if (unpaid > 1e-06) {
        sim_mem[["status"]][[name]][["money"]] <- sim_mem[["status"]][[name]][["money"]] - unpaid
        tax_unpaid_total <<- tax_unpaid_total + unpaid
        warning(sprintf("simulation: %s von %.2f EUR am %s: das Depot reicht nicht aus; %.2f EUR bleiben als negativer Geldbestand (Steuerschuld) bei '%s'.", 
            label, amount, format(flag_date[time]), unpaid, name), call. = FALSE)
    }),
  "68" = quote(if (unpaid <= 1e-06) break),
  "69" = quote(if (!(val[[nm]] > 0)) next),
  "70" = quote(if (prepaid == 0) {
        sim_mem <- .pay_tax(sim_mem, name, tax_debt, time, "Vorabpauschale")
    } else if (tax_debt - prepaid > 1e-09) {
        sim_mem <- .pay_tax(sim_mem, name, tax_debt - prepaid, time, "Vorabpauschale")
    } else if (tax_debt - prepaid < -1e-09) {
        sim_mem[["status"]][[name]][["money"]] <- sim_mem[["status"]][[name]][["money"]] + (prepaid - tax_debt)
    }),
  "71" = quote(if (tax_debt - prepaid > 1e-09) {
        sim_mem <- .pay_tax(sim_mem, name, tax_debt - prepaid, time, "Vorabpauschale")
    } else if (tax_debt - prepaid < -1e-09) {
        sim_mem[["status"]][[name]][["money"]] <- sim_mem[["status"]][[name]][["money"]] + (prepaid - tax_debt)
    }),
  "72" = quote(if (tax_debt - prepaid < -1e-09) {
        sim_mem[["status"]][[name]][["money"]] <- sim_mem[["status"]][[name]][["money"]] + (prepaid - tax_debt)
    }),
  "73" = quote(if (!(due[[nm]] > 0)) next),
  "74" = quote(if (result$tax > 0 || pre > 0) {
        sim_mem <- .pay_vp(sim_mem, p[["name"]], result$tax, time, list(flat_rate = p[["flat_rate"]], bonus = p[["bonus"]], 
            spb_used = result$spb_used, assessment_date = p[["assessment_date"]]), prepaid = pre)
    }),
  "75" = quote(if (tax_regime == "investment_fund" && sim_mem[["status"]][[name]][["count"]] > 0) {
        vp_result <- .calculate_flat_rate(input = sim_mem, name = name, index = time, dates = flag_date, 
            tax_regime = tax_regime, filled = flag_filled)
        flat_rate <- vp_result$total_vp
        for (vp_k in seq_along(vp_result$lot_indices)) {
            vp_i <- vp_result$lot_indices[vp_k]
            current_vp <- sim_mem[["trades"]][[name]][["buys"]][[vp_i]][["vp"]] %||% 0
            sim_mem[["trades"]][[name]][["buys"]][[vp_i]][["vp"]] <- current_vp + vp_result$lot_vps[vp_k]
        }
        if (flat_rate > 0) {
            pend <- sim_mem[["totals"]][["vp_pending"]]
            if (is.null(pend)) 
                pend <- list()
            pend[[length(pend) + 1L]] <- list(name = name, flat_rate = flat_rate, bonus = sim_mem[["assets"]][[name]][["bonus"]], 
                assessment_date = flag_date[time])
            sim_mem[["totals"]][["vp_pending"]] <- pend
            if (details) {
                cat(sprintf("Steuerereignis:\tVorabpauschale %s: %.2f EUR festgesetzt am %s (Zufluss und Steuer am ersten Handelstag des Folgejahres)\n", 
                    name, flat_rate, flag_date[time]))
            }
        }
    }),
  "76" = quote(if (flat_rate > 0) {
        pend <- sim_mem[["totals"]][["vp_pending"]]
        if (is.null(pend)) 
            pend <- list()
        pend[[length(pend) + 1L]] <- list(name = name, flat_rate = flat_rate, bonus = sim_mem[["assets"]][[name]][["bonus"]], 
            assessment_date = flag_date[time])
        sim_mem[["totals"]][["vp_pending"]] <- pend
        if (details) {
            cat(sprintf("Steuerereignis:\tVorabpauschale %s: %.2f EUR festgesetzt am %s (Zufluss und Steuer am ersten Handelstag des Folgejahres)\n", 
                name, flat_rate, flag_date[time]))
        }
    }),
  "77" = quote(if (base_rate <= 0) {
        return(empty_result)
    }),
  "78" = quote(if (px0 > split_thresh[[2]] || px0 < split_thresh[[1]]) {
        sim_mem[["market"]][[name]][["asset_price"]] <- sim_mem[["market"]][[name]][["asset_price"]]/(px0/100)
        if (details) 
            cat(sprintf("Split-Ereignis:\t%s ohne Bestand: Kursreihe %s %s am %s\n", name, if (px0 > split_thresh[[2]]) 
                "1 :"
            else ": 1", format(if (px0 > split_thresh[[2]]) 
                px0/100
            else 100/px0, digits = 5), flag_date[time]))
    }),
  "79" = quote(if (sim_mem[["status"]][[name]][["count"]] > 0) {
        split_price <- sim_mem[["market"]][[name]][["asset_price"]][time]
        if (split_price > split_thresh[[2]]) {
            sim_mem <- .perform_asset_split(input = sim_mem, name = name, ratio = split_price/100, type = "forward", 
                index = time, fractions = fractions, details = details, current_date = flag_date[time])
        }
        if (split_price < split_thresh[[1]]) {
            sim_mem <- .perform_asset_split(input = sim_mem, name = name, ratio = 100/split_price, type = "reverse", 
                index = time, fractions = fractions, details = details, current_date = flag_date[time])
        }
        split_cnt <- sim_mem[["status"]][[name]][["count"]]
        split_frac <- split_cnt - floor(split_cnt + 1e-09)
        if (!fractions && split_frac > 1e-09) {
            fee_keep <- .fee_env$current
            .fee_env$current <- NULL
            sim_mem <- .perform_trade_sell(input = sim_mem, count = split_frac, name = name, index = time, 
                tax_mode = tax_mode, tax_rate = tax_rate, effective_tax_rate = effective_tax_rate, marginal_tax_rate = marginal_tax_rate, 
                private_sale_threshold = private_sale_threshold, use_sparer_pauschbetrag = use_sparer_pauschbetrag, 
                tax_regime = tax_regimes[[name]], reason = "Split:", spread = 0, details = details)
            .fee_env$current <- fee_keep
        }
    }),
  "80" = quote(if (split_price > split_thresh[[2]]) {
        sim_mem <- .perform_asset_split(input = sim_mem, name = name, ratio = split_price/100, type = "forward", 
            index = time, fractions = fractions, details = details, current_date = flag_date[time])
    }),
  "81" = quote(if (split_price < split_thresh[[1]]) {
        sim_mem <- .perform_asset_split(input = sim_mem, name = name, ratio = 100/split_price, type = "reverse", 
            index = time, fractions = fractions, details = details, current_date = flag_date[time])
    }),
  "82" = quote(if (!fractions && split_frac > 1e-09) {
        fee_keep <- .fee_env$current
        .fee_env$current <- NULL
        sim_mem <- .perform_trade_sell(input = sim_mem, count = split_frac, name = name, index = time, tax_mode = tax_mode, 
            tax_rate = tax_rate, effective_tax_rate = effective_tax_rate, marginal_tax_rate = marginal_tax_rate, 
            private_sale_threshold = private_sale_threshold, use_sparer_pauschbetrag = use_sparer_pauschbetrag, 
            tax_regime = tax_regimes[[name]], reason = "Split:", spread = 0, details = details)
        .fee_env$current <- fee_keep
    }),
  "83" = quote(if (ratio <= 0) {
        stop(sprintf("perform_asset_split: ratio muss > 0 sein (Split-Verh\u00e4ltnis), nicht %s.", format(ratio)))
    }),
  "84" = quote(if (total <= 0) return(input)),
  "85" = quote(if (room <= 0.01) return(input)),
  "86" = quote(if (taxable(first_lot, FALSE) <= 0) return(input)),
  "87" = quote(if (taxable(total) <= room) total else {
        lo <- 0
        hi <- total
        for (i in 1:60) {
            mid <- (lo + hi)/2
            if (taxable(mid) > room) 
                hi <- mid
            else lo <- mid
            if (hi - lo < total * 1e-10) 
                break
        }
        lo
    }),
  "88" = quote(if (taxable(mid) > room) hi <- mid else lo <- mid),
  "89" = quote(if (hi - lo < total * 1e-10) break),
  "90" = quote(if (n <= 0 || taxable(n) <= 0) return(input)),
  "91" = quote(if (n <= 0) return(0)),
  "92" = quote(if (prepaid[j] > 0) sim_mem <- .pay_tax(sim_mem, pend[[j]][["name"]], prepaid[j], n_total_days, "Vorabpauschale")),
  "93" = quote(if (isTRUE(tariff_env$use_gp) && y_last > as.integer(format(stopp_date, "%Y")) && (sim_mem[["totals"]][["cgt_base_taxed_ytd"]] %||% 
        0) > 0) {
        D <- .tariff_close(tariff_env, y_last, 0, sim_mem[["totals"]][["cgt_base_taxed_ytd"]], effective_tax_rate, 
            details)
        sim_mem <- .tariff_book(sim_mem, tariff_env, D)
    }),
  "94" = quote(if (sum(taxable) > 0) taxable/sum(taxable) else rep(1/length(pend), length(pend))),
  "95" = quote(if (vorabpauschale_paid > 0) {
        cat(sprintf("\t\t=> Vorabpauschale-Anrechnung (\u00a7 19 InvStG): %.2f EUR\n", vorabpauschale_paid))
    }),
  "96" = quote(if (result$spb_used > 0) {
        cat(sprintf("\t\t=> Sparerpauschbetrag: %.2f EUR (verbleibend: %.2f EUR)\n", result$spb_used, input[["totals"]][["sparer_pauschbetrag_remaining"]]))
    }),
  "97" = quote(if (lot_result$exempt_gain > 0) {
        cat(sprintf("\t\t=> Steuerfreier Gewinn (Haltedauer > 1 Jahr): %.2f EUR\n", lot_result$exempt_gain))
    }),
  "98" = quote(if (lot_result$exempt_loss > 0) {
        cat(sprintf("\t\t=> Nicht verrechenbarer Verlust (Haltedauer > 1 Jahr): %.2f EUR\n", lot_result$exempt_loss))
    }),
  "99" = quote(if (details && remaining - unpaid > 0) {
        cat(sprintf("\t\t=> Anteile verkauft f\u00fcr den Rest von %.2f EUR (%s)\n", remaining - unpaid, label))
    }),
  "100" = quote(if (details && length(info) && any(due > 0)) {
        for (i in info) {
            rest <- i$D - i$p23 - i$ded
            cat(sprintf("Steuerereignis:\tVeranlagung %d: Nachzahlung %.2f EUR (davon \u00a7 23 %.2f EUR, Kirchensteuer-Sonderausgaben %.2f EUR%s) am %s, aufgeteilt %s\n", 
                i$year, i$D, i$p23, i$ded, if (abs(rest) >= 0.005) 
                    sprintf(", G\u00fcnstigerpr\u00fcfung %.2f EUR", rest)
                else "", flag_date[time], if (i$by_p23) 
                    "nach dem \u00a7 23-Jahressaldo je Asset"
                else "zu gleichen Teilen auf die Assets"))
        }
    }),
  "101" = quote(if (abs(rest) >= 0.005) sprintf(", G\u00fcnstigerpr\u00fcfung %.2f EUR", rest) else ""),
  "102" = quote(if (dev > balance_thresh) {
        cat(sprintf("\t\t=> %s: Ziel=%.1f%%, Ist=%.1f%%, Abweichung=%.2f%%\n", name, active_targets[i] * 
            100, actual_weights[i] * 100, dev * 100))
    }),
  "103" = quote(if (details && carryforward_offset > 0) {
        cat(sprintf("  \u00a7 23 EStG: Verlustvortrag verwendet: %.2f EUR\n", carryforward_offset))
        cat(sprintf("             Verbleibender Vortrag: %.2f EUR\n", input[["totals"]][["loss_private_sales"]]))
    }),
  "104" = quote(if (g23 > 0) cat(sprintf("    \u00a7 23: Gewinn %.2f EUR -> Steuerlast ESt %.2f + Soli %.2f + KiSt %.2f = %.2f EUR\n", 
        g23, p23$est, p23$soli, p23$kist, p23$total)))
)

# Auswertung im C++-Kern (E17 Stufe 3, core/evaluate_core_impl.h, enum Site): Aufrufe der Abbrueche (NA in
# einer Bedingung) aus .sim_returns (1-4) und .sim_risk_stats (5, 6) von R 1.3.0, dazu der Aufruf von
# stats::uniroot in .xirr_rate (Warnungen von uniroot) und von max() ohne Werte; erzeugt wie oben.

.SIM_EVAL_CALLS <- list(
  "1" = quote(if (start_worth > 0 && ann_factor > 0) {
        (stopp_worth/start_worth)^(1/ann_factor) - 1
    } else {
        NA_real_
    }),
  "2" = quote(if (tax_unpaid_total > 0) sum(vapply(flag_assets, function(nm) max(0, -sim_mem[["status"]][[nm]][["money"]]), 
        numeric(1))) else 0),
  "3" = quote(if (!(has_ext_flows && any(twr_index <= 0))) warning("simulation: zeitgewichteter Wertindex wird negativ (Tagesrendite unter -100 %); ttwror ist nicht definiert (NA).", 
        call. = FALSE)),
  "4" = quote(if (has_ext_flows && any(twr_index <= 0)) {
        i0 <- which(twr_index <= 0)[1]
        warning(sprintf("simulation: zeitgewichteter Wertindex am %s nicht positiv (Tagesrendite %.2f %% bei Depotwert %.2f EUR am Vortag und Einzahlung %.2f EUR); TTWROR und die zeitgewichteten Drawdowns sind nicht aussagekr\u00e4ftig (Drawdowns auf 100 %% begrenzt).", 
            format(flag_date[i0]), 100 * period_return[i0], total_worth[i0 - 1], total_flows[i0]), call. = FALSE)
        drawdowns <- pmin(drawdowns, 1)
    }),
  "5" = quote(if (downside_sd_excess > 0) {
        (mean_excess * days_per_year)/(downside_sd_excess * sqrt(days_per_year))
    } else {
        NA_real_
    }),
  "6" = quote(if (dd_series[i] < running_max[i]) {
        current_dd <- current_dd + 1L
        if (current_dd > longest_dd) 
            longest_dd <- current_dd
    } else {
        current_dd <- 0L
    }),
  "uniroot" = quote(stats::uniroot(g, br, f.lower = fb[1], f.upper = fb[2], tol = 1e-14, maxiter = 1000)),
  "max" = quote(max(drawdowns, na.rm = TRUE))
)
