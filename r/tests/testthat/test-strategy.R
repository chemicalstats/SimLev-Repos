test_that("create_strategy creates valid strategy", {
  strat <- create_strategy(
    ETF = asset_config(asset_class = "etf"),
    Gold = asset_config(asset_class = "etc")
  )
  
  expect_s3_class(strat, "strategy")
  expect_length(strat, 2)
  expect_named(strat, c("ETF", "Gold"))
})


test_that("create_strategy works with assets parameter", {
  strat <- create_strategy(assets = list(
    ETF = asset_config(asset_class = "etf"),
    Gold = asset_config(asset_class = "etc")
  ))
  
  expect_s3_class(strat, "strategy")
  expect_length(strat, 2)
})


test_that("create_strategy converts plain lists", {
  strat <- create_strategy(assets = list(
    ETF = list(asset_class = "etf", share = 0.7),
    Bond = list(asset_class = "etf", share = 0.3, partial_exemption = 0)
  ))
  
  expect_s3_class(strat, "strategy")
  expect_s3_class(strat$ETF, "asset_config")
  expect_s3_class(strat$Bond, "asset_config")
})


test_that("create_strategy rejects empty input", {
  expect_error(create_strategy(), "mindestens eine Asset-Konfiguration")
})


test_that("create_strategy rejects unnamed assets", {
  expect_error(
    create_strategy(asset_config()),
    "alle Assets m\u00fcssen benannt sein"
  )
})


test_that("strategy_validate checks data columns", {
  strat <- create_strategy(
    ETF = asset_config(asset_class = "etf")
  )
  
  good_data <- data.frame(
    date = as.Date("2024-01-01"),
    ETF = 100
  )
  
  expect_true(strategy_validate(strat, good_data))
  
  bad_data <- data.frame(
    date = as.Date("2024-01-01"),
    Other = 100
  )
  
  expect_error(
    strategy_validate(strat, bad_data),
    "Kursspalte\\(n\\) 'ETF' fehlen in data"
  )
})


test_that("strategy_validate checks signal columns", {
  strat <- create_strategy(
    ETF = asset_config(
      trading = "signal",
      signal_buy = "buy_signal",
      signal_sell = "sell_signal"
    )
  )
  
  good_data <- data.frame(
    date = as.Date("2024-01-01"),
    ETF = 100,
    buy_signal = TRUE,
    sell_signal = FALSE
  )
  
  expect_true(strategy_validate(strat, good_data))
  
  bad_data <- data.frame(
    date = as.Date("2024-01-01"),
    ETF = 100
  )
  
  expect_error(
    strategy_validate(strat, bad_data),
    "signal_buy-Spalte 'buy_signal' fehlt in data"
  )
})


test_that("strategy_add_asset adds to strategy", {
  strat <- create_strategy(
    ETF = asset_config()
  )
  
  strat <- strategy_add_asset(strat, "Gold", asset_config(asset_class = "etc"))
  
  expect_length(strat, 2)
  expect_true("Gold" %in% names(strat))
})


test_that("strategy_remove_asset removes from strategy", {
  strat <- create_strategy(
    ETF = asset_config(),
    Gold = asset_config(asset_class = "etc")
  )
  
  strat <- strategy_remove_asset(strat, "Gold")
  
  expect_length(strat, 1)
  expect_false("Gold" %in% names(strat))
})


test_that("strategy_remove_asset warns on empty strategy", {
  strat <- create_strategy(ETF = asset_config())
  
  expect_warning(
    strategy_remove_asset(strat, "ETF"),
    "keine Assets mehr"
  )
})


test_that("strategy_update_asset modifies existing", {
  strat <- create_strategy(
    ETF = asset_config(share = 0.5)
  )
  
  strat <- strategy_update_asset(strat, "ETF", share = 0.8)
  
  expect_equal(strat$ETF$share, 0.8)
})


test_that("strategy_update_asset rejects unknown asset", {
  strat <- create_strategy(ETF = asset_config())
  
  expect_error(
    strategy_update_asset(strat, "Unknown", share = 0.5),
    "Asset 'Unknown' ist nicht in der Strategie"
  )
})


test_that("print.strategy works", {
  strat <- create_strategy(
    ETF = asset_config(asset_class = "etf"),
    Gold = asset_config(asset_class = "etc")
  )
  
  expect_output(print(strat), "Anlagestrategie")
  expect_output(print(strat), "2 Assets")
})


test_that("summary.strategy shows allocation", {
  strat <- create_strategy(
    ETF = asset_config(share = 0.7),
    Gold = asset_config(share = 0.3, asset_class = "etc")
  )
  
  expect_output(summary(strat), "Gesamtgewicht: 100")
})
