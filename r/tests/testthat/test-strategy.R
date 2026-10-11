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
    ETF = list(asset_class = "etf", asset_share = 0.7),
    Bond = list(asset_class = "etf", asset_share = 0.3, asset_bonus = 0)
  ))
  
  expect_s3_class(strat, "strategy")
  expect_s3_class(strat$ETF, "asset_config")
  expect_s3_class(strat$Bond, "asset_config")
})


test_that("create_strategy rejects empty input", {
  expect_error(create_strategy(), "At least one asset")
})


test_that("create_strategy rejects unnamed assets", {
  expect_error(
    create_strategy(asset_config()),
    "must be named"
  )
})


test_that("validate_strategy checks data columns", {
  strat <- create_strategy(
    ETF = asset_config(asset_class = "etf")
  )
  
  good_data <- data.frame(
    date = as.Date("2024-01-01"),
    ETF = 100
  )
  
  expect_true(validate_strategy(strat, good_data))
  
  bad_data <- data.frame(
    date = as.Date("2024-01-01"),
    Other = 100
  )
  
  expect_error(
    validate_strategy(strat, bad_data),
    "not found"
  )
})


test_that("validate_strategy checks signal columns", {
  strat <- create_strategy(
    ETF = asset_config(
      action_type = "signal",
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
  
  expect_true(validate_strategy(strat, good_data))
  
  bad_data <- data.frame(
    date = as.Date("2024-01-01"),
    ETF = 100
  )
  
  expect_error(
    validate_strategy(strat, bad_data),
    "Signal column"
  )
})


test_that("add_asset adds to strategy", {
  strat <- create_strategy(
    ETF = asset_config()
  )
  
  strat <- add_asset(strat, "Gold", asset_config(asset_class = "etc"))
  
  expect_length(strat, 2)
  expect_true("Gold" %in% names(strat))
})


test_that("remove_asset removes from strategy", {
  strat <- create_strategy(
    ETF = asset_config(),
    Gold = asset_config(asset_class = "etc")
  )
  
  strat <- remove_asset(strat, "Gold")
  
  expect_length(strat, 1)
  expect_false("Gold" %in% names(strat))
})


test_that("remove_asset warns on empty strategy", {
  strat <- create_strategy(ETF = asset_config())
  
  expect_warning(
    remove_asset(strat, "ETF"),
    "empty"
  )
})


test_that("update_asset modifies existing", {
  strat <- create_strategy(
    ETF = asset_config(asset_share = 0.5)
  )
  
  strat <- update_asset(strat, "ETF", asset_share = 0.8)
  
  expect_equal(strat$ETF$asset_share, 0.8)
})


test_that("update_asset rejects unknown asset", {
  strat <- create_strategy(ETF = asset_config())
  
  expect_error(
    update_asset(strat, "Unknown", asset_share = 0.5),
    "not found"
  )
})


test_that("migrate_strategy converts old format", {
  old <- list(
    Gold = list(
      asset_class = "etn_deliverable",
      action_type = "bnh",
      asset_share = 1.0,
      asset_spread = 0.1,
      asset_bonus = 0
    )
  )
  
  new <- migrate_strategy(old, verbose = FALSE)
  
  expect_equal(new$Gold$asset_class, "etn")
  expect_true(new$Gold$deliverable)
  expect_equal(new$Gold$tax_regime, "private_sale")
})


test_that("print.strategy works", {
  strat <- create_strategy(
    ETF = asset_config(asset_class = "etf"),
    Gold = asset_config(asset_class = "etc")
  )
  
  expect_output(print(strat), "Investment Strategy")
  expect_output(print(strat), "2 assets")
})


test_that("summary.strategy shows allocation", {
  strat <- create_strategy(
    ETF = asset_config(asset_share = 0.7),
    Gold = asset_config(asset_share = 0.3, asset_class = "etc")
  )
  
  expect_output(summary(strat), "Total allocation: 100")
})
