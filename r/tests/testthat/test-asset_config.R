test_that("asset_config creates valid ETF configuration", {
  cfg <- asset_config(
    asset_class = "etf",
    share = 0.7,
    partial_exemption = 30
  )
  
  expect_s3_class(cfg, "asset_config")
  expect_equal(cfg$asset_class, "etf")
  expect_equal(cfg$share, 0.7)
  expect_equal(cfg$partial_exemption, 30)
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
  }, "asset_class = \"etn_deliverable\" ist veraltet")
  
  expect_equal(cfg$asset_class, "etn")
  expect_true(cfg$deliverable)
  expect_equal(cfg$tax_regime, "private_sale")
})


test_that("backward compatibility for etn_standard", {
  expect_warning({
    cfg <- asset_config(asset_class = "etn_standard")
  }, "asset_class = \"etn_standard\" ist veraltet")
  
  expect_equal(cfg$asset_class, "etn")
  expect_false(cfg$deliverable)
  expect_equal(cfg$tax_regime, "capital_gains")
})


test_that("share validation", {
  expect_error(
    asset_config(share = 0),
    "share muss ein Anteil gr\u00f6\u00dfer 0 und h\u00f6chstens 1 sein .*nicht 0\\."
  )
  
  expect_error(
    asset_config(share = 1.5),
    "share muss ein Anteil gr\u00f6\u00dfer 0 und h\u00f6chstens 1 sein .*nicht 1.5; f\u00fcr 1.5 % share = 0.015 angeben"
  )
  
  expect_error(
    asset_config(share = -0.1),
    "share muss ein Anteil gr\u00f6\u00dfer 0 und h\u00f6chstens 1 sein .*nicht -0.1\\."
  )
})


test_that("signal requires buy and sell columns", {
  expect_error(
    asset_config(trading = "signal"),
    "m\u00fcssen signal_buy und signal_sell angegeben werden"
  )
  
  cfg <- asset_config(
    trading = "signal",
    signal_buy = "buy_col",
    signal_sell = "sell_col"
  )
  
  expect_equal(cfg$signal_buy, "buy_col")
  expect_equal(cfg$signal_sell, "sell_col")
})


test_that("invalid tax_regime is rejected", {
  expect_error(
    asset_config(tax_regime = "invalid"),
    "tax_regime = \"invalid\" ist ung\u00fcltig"
  )
})


test_that("print.asset_config works", {
  cfg <- asset_config(asset_class = "etf", partial_exemption = 30)
  expect_output(print(cfg), "Asset-Konfiguration")
  expect_output(print(cfg), "etf")
  expect_output(print(cfg), "investment_fund")
})
