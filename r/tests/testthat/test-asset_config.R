test_that("asset_config creates valid ETF configuration", {
  cfg <- asset_config(
    asset_class = "etf",
    asset_share = 0.7,
    asset_bonus = 30
  )
  
  expect_s3_class(cfg, "asset_config")
  expect_equal(cfg$asset_class, "etf")
  expect_equal(cfg$asset_share, 0.7)
  expect_equal(cfg$asset_bonus, 30)
  expect_equal(cfg$tax_regime, "investment_fund")
  expect_false(cfg$deliverable)
})


test_that("deliverable TRUE sets private_sale regime for ETC", {
 cfg <- asset_config(
    asset_class = "etc",
    deliverable = TRUE
  )
  
  expect_true(cfg$deliverable)
  expect_equal(cfg$tax_regime, "private_sale")
})


test_that("deliverable FALSE sets capital_gains regime for ETN", {
  cfg <- asset_config(
    asset_class = "etn",
    deliverable = FALSE
  )
  
  expect_false(cfg$deliverable)
  expect_equal(cfg$tax_regime, "capital_gains")
})


test_that("backward compatibility for etn_deliverable", {
  expect_warning({
    cfg <- asset_config(asset_class = "etn_deliverable")
  }, "deprecated")
  
  expect_equal(cfg$asset_class, "etn")
  expect_true(cfg$deliverable)
  expect_equal(cfg$tax_regime, "private_sale")
})


test_that("backward compatibility for etn_standard", {
  expect_warning({
    cfg <- asset_config(asset_class = "etn_standard")
  }, "deprecated")
  
  expect_equal(cfg$asset_class, "etn")
  expect_false(cfg$deliverable)
  expect_equal(cfg$tax_regime, "capital_gains")
})


test_that("asset_share validation", {
  expect_error(
    asset_config(asset_share = 0),
    "between 0"
  )
  
  expect_error(
    asset_config(asset_share = 1.5),
    "between 0"
  )
  
  expect_error(
    asset_config(asset_share = -0.1),
    "between 0"
  )
})


test_that("signal requires buy and sell columns", {
  expect_error(
    asset_config(action_type = "signal"),
    "signal_buy and signal_sell"
  )
  
  cfg <- asset_config(
    action_type = "signal",
    signal_buy = "buy_col",
    signal_sell = "sell_col"
  )
  
  expect_equal(cfg$signal_buy, "buy_col")
  expect_equal(cfg$signal_sell, "sell_col")
})


test_that("invalid tax_regime is rejected", {
  expect_error(
    asset_config(tax_regime = "invalid"),
    "Invalid tax_regime"
  )
})


test_that("print.asset_config works", {
  cfg <- asset_config(asset_class = "etf", asset_bonus = 30)
  expect_output(print(cfg), "Asset Configuration")
  expect_output(print(cfg), "etf")
  expect_output(print(cfg), "investment_fund")
})
