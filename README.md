## Prepare Data for Asset Pricing Projects

This repository imports and processes various useful datasets for asset pricing studies.

**import_JKP_stock_charcs.ipynb**

This notebook imports returns and firm characteristics for individual stocks from [Global Factor Data](https://jkpfactors.com/stock-char) organized by Prof. Theis Jensen, Bryan Kelly, and Lasse Heje Pedersen.

**replicate_FF_ports_factors.ipynb**

This notebook replicates the characteristics-sorted portfolios and risk factors from [Fama and French](https://mba.tuck.dartmouth.edu/pages/faculty/ken.french/data_library.html). My replication of the factors MKT, SMB, HML, RMW, CMA, and UMD shows correlations of 0.997, 0.982, 0.981, 0.981, and 0.997, respectively, with the corresponding Fama-French provided factors.

**replicate_JKP_ports_factors.ipynb**

This notebook replicates the characteristics-sorted portfolios and risk factors from [Global Factor Data](https://jkpfactors.com/stock-char) and [Jensen, Kelly, and Pedersen (2023)](https://onlinelibrary.wiley.com/doi/full/10.1111/jofi.13249). My replication of the factors "market_equity" (size), "be_me" (value), "ope_be" (profitability), "at_gr1" (Investment), and "ret_12_1" (momentum) shows correlations of 0.998, 0.997, 0.993, 0.993, and 0.997, respectively, with the corresponding JKP provided factors.

**prepare_data.ipynb**

This notebooks constructs the following datasets that could be used in various asset pricing studies:

- Characteristics univariate-sorted portfolio weights on individual stocks.
- Risk factor weights on individual stocks.
- Individual stock characteristics with (1) missing values filled by industrial cross-sectional median and (2) rank-normalization to the (-1,1) interval.
