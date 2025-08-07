## Prepare Data for Asset Pricing Projects

This repository imports and processes several datasets commonly used in empirical asset pricing research.

### import_JKP_stock_charcs.ipynb

This notebook imports individual stock returns and firm characteristics from [Global Factor Data](https://jkpfactors.com/stock-char), compiled by Professors Theis Jensen, Bryan Kelly, and Lasse Heje Pedersen.

### replicate_FF_ports_factors.ipynb

This notebook replicates the characteristics-sorted portfolios and risk factors provided by [Fama and French](https://mba.tuck.dartmouth.edu/pages/faculty/ken.french/data_library.html).  
The replicated factors—MKT, SMB, HML, RMW, CMA, and UMD—exhibit correlations of 0.997, 0.982, 0.981, 0.981, and 0.997, respectively, with the official Fama-French factors.

### replicate_JKP_ports_factors.ipynb

This notebook replicates the characteristics-sorted portfolios and risk factors from both [Global Factor Data](https://jkpfactors.com/stock-char) and [Jensen, Kelly, and Pedersen (2023)](https://onlinelibrary.wiley.com/doi/full/10.1111/jofi.13249).  
The replicated factors—_market_equity_ (size), _be_me_ (value), _ope_be_ (profitability), _at_gr1_ (investment), and _ret_12_1_ (momentum)—exhibit correlations of 0.998, 0.997, 0.993, 0.993, and 0.997, respectively, with the corresponding JKP-provided factors.

### prepare_data.ipynb

This notebook constructs processed datasets for use in asset pricing applications, including:

- Portfolio weights for univariate-sorted portfolios on individual stocks. 
- Risk factor weights on individual stocks. 
- Firm-level characteristics datasets that:
  - Fill missing values by the cross-sectional median within each industry.
  - Apply rank-transformation and normalization to the \(-1, 1\) interval.
