# Data for Asset Pricing

This repository collects code for importing, cleaning, and constructing datasets commonly used in empirical asset pricing research. The repository is organized by data source and research topic, with each folder containing code for downloading, processing, and replicating widely used financial datasets.

## Repository Structure

### Chars_Ports_Factors

This folder contains notebooks for importing stock characteristics and replicating characteristic-sorted portfolios and risk factors.

Files include:

- **JKP_portfolios_factors_weights.ipynb** – Imports and constructs stock characteristics, characteristic-sorted portfolios, portfolio weights, risk factors, and factor weights.
- **replicate_JKP_ports_factors.ipynb** – Replicates the characteristic-sorted portfolios and risk factors from both the [Global Factor Data](https://jkpfactors.com/stock-char) library and Jensen, Kelly, and Pedersen (2023).
- **replicate_FF_ports_factors.ipynb** – Replicates the characteristic-sorted portfolios and risk factors from the [Fama–French Data Library](https://mba.tuck.dartmouth.edu/pages/faculty/ken.french/data_library.html).

### Institutional_Holdings

This folder contains code for processing institutional ownership data from SEC Form 13F filings.

Files include:

- **LSEG_13f_holdings.ipynb** – Processes institutional holdings from the LSEG 13F database.
- **WRDS_SEC_13f_holdings.sas** – Downloads and cleans SEC Form 13F filings from the WRDS SEC Analytics Suite.
- **Institutional_holdings.ipynb** – Combines the processed datasets from the LSEG and WRDS sources.

### Liquidity_TradingCosts

This folder contains code for constructing commonly used liquidity and transaction cost measures from CRSP daily data.

Files include:

- **liquidity_tradingcosts.ipynb** – Computes multiple liquidity and transaction cost measures.
- **Hasbrouck_gibbs.py** – Python implementation of the Hasbrouck–Gibbs estimation procedure used by the notebook.

### Options

This folder contains MATLAB code for cleaning OptionMetrics data and constructing option-implied measures.

Files include:

- **clean_OptionMetrics_data.m** – Cleans and prepares OptionMetrics data.
- **estimate_SPD_OptionMetrics.m** – Estimates the state price density (SPD) from OptionMetrics option data.
