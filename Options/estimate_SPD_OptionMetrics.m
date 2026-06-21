%% Estimate State-Price Densities
% using Breeden-Litzenberger (1978)
%{ 
NOTES:
   1. Before computing SPD using Breeden-Litzenberger,
      first construct a smooth curve of option prices wrt strikes (moneyness).
   2. How: transform option prices to implied volatilities -- smooth it --
       transform implied volatilities along the specified grid back to
       option price -- take 2nd derivatives to get SPD.
   3. NOT assuming Black–Scholes model to hold, only use the Black–Scholes
      formula only as a tool which provides a one-to-one mapping between
      option prices and implied volatilities.
   4. Likewise, the BS procedure assumes a constant risk-free rate proxied
      by zero-coupon Treasury yield, but this is only used to provide a
      mapping between option prices and implied volatilities.
   5. Targeted maturities may not be available:
      fit the SVI surface at targeted maturities.
%}
clear; close all; clc;
addpath(genpath('utils'));
datapath = '/work/rw196/optionsdata/';
outputpath = '/work/rw196/output/';

%% Preliminaries

% Parameters
params.maturity = [1 3 6 12 24]*30;       % horizon in days to be considered
params.numMat = length(params.maturity);  % number of the term-structure
params.StrikeDelta = 0.1;                 % distance between two grid points along the strike price dimension
params.numKSgrid = 801;
params.KSgrid = ...
    linspace(0.001,2,params.numKSgrid)';  % moneyness grid
params.maxFitTries = 10;                  % maximum tries in fitting SVI for each date
params.Phifun = 'heston_like';            % functional form in SVI surfacing fitting (results robust across "heston_like" and "Power_law")

% Load SP500 option prices
rawOptions = readtable([datapath 'sp500_option_prices.csv'],'ReadVariableNames',true);

% Load SP500 index levels and returns
rawIndexPrice = readtable([datapath 'sp500_index_return.csv'],'ReadVariableNames',true);

% Load zero-coupon yield from OptionMetrics
yields = readtable([datapath 'yields_OptionMetrics.csv'],'ReadVariableNames',true);

clearvars -except params datapath outputpath rawOptions rawIndexPrice yields;

% Options data cleaning
cleanpars.EOMcalcultion = 1;              % 1: calculation only at the end-of-month, 0: daily calculation
cleanpars.thirdFriday = 1;                % 1: Keep options with expiration date on 3rd Friday of month (or following Saturday)
cleanpars.imposeConvexityRestriction = 0; % 1: eliminate options with prices that lead to non-monotonic slopes in K

Options_cleaned = clean_options_data(rawOptions,cleanpars);
Options_cleaned = Options_cleaned(:,{'secid','date','exdate','call_indicator','strike_price','best_bid','best_offer','mid_price','maturity','impl_volatility','dividend_yield','forward_price'});
allDates = unique(Options_cleaned.date);
numDates = length(allDates);

% Interpolate zero-coupon yields and merge into options data
Yinterp = scatteredInterpolant(datenum(yields.date),yields.days,yields.rate,'linear','linear');
Options_cleaned.r = Yinterp([datenum(Options_cleaned.date),Options_cleaned.maturity]);
Options_cleaned.r = Options_cleaned.r/100; % remove percentages

% Realized dividend during the life of each option
% calculated using today and expiration date's index and TR indexs
Sinterp = griddedInterpolant(datenum(rawIndexPrice.date),rawIndexPrice.close,'previous');
Options_cleaned.St = Sinterp(datenum(Options_cleaned.date));
Options_cleaned.ST = Sinterp(datenum(Options_cleaned.exdate));
RIinterp = griddedInterpolant(datenum(rawIndexPrice.date),rawIndexPrice.close_TR,'previous');
RIt = RIinterp(datenum(Options_cleaned.date));
RIT = RIinterp(datenum(Options_cleaned.exdate));
Options_cleaned.div = (RIT./RIt - Options_cleaned.ST./Options_cleaned.St).*Options_cleaned.St;

% Continuously-compounded annualized dividend yields used in the Black-Scholes formula to calculate the implied volatilities
% Note this is very different from the dividend yield provided by OptionMetrics, which is computed using a regression approach
Options_cleaned.divYield = log( ( Options_cleaned.St - Options_cleaned.div.*exp(-Options_cleaned.r.*Options_cleaned.maturity/365) )./Options_cleaned.St )./(-Options_cleaned.maturity/365);


%% SVI Volatility Surface Fitting

% Loop over each trading date
% Use while loop with try-catch to handle errors
tic;
t = 1;
while t <= numDates
    success = false;
    while ~success
        try
            % Keeping track
            disp(['SVI: ', num2str(t),' out of ',num2str(numDates)])

            % Current date
            currentDate = allDates(t);
            Optionst = Options_cleaned(currentDate == Options_cleaned.date,:);
            
            % Filter out options with less than 5 obs at a given maturity
            [u,~,idx] = unique(Optionst.maturity);
            counts = accumarray(idx,1);
            keepMat = u(counts >= 5);
            Optionst = Optionst(ismember(Optionst.maturity, keepMat),:);       

            % Step 1: Fitting the SVI surface
            % -------------------------------------------------------

            % % Keep the call if duplicate strikes appear for a pair of call and put
            % Optionst = sortrows(Optionst,{'exdate','strike_price','call_indicator'},{'ascend','ascend','descend'});
            % [~,idx] = unique(Optionst(:,{'exdate','strike_price'}));
            % Optionst = Optionst(idx,:);

            % % Drop ITM options
            % idx = (Optionst.call_indicator == 1 & Optionst.strike_price < Optionst.forward_price) ...
            %     | (Optionst.call_indicator == 0 & Optionst.strike_price >= Optionst.forward_price) ;
            % Optionst(idx,:) = [];

            % Unpack variables
            St = Optionst.St(1);
            Mat = Optionst.maturity/360; % in years
            rt = Optionst.r;
            Striket  = Optionst.strike_price;
            Callt = Optionst.call_indicator;
            Bidt = Optionst.best_bid;
            Askt = Optionst.best_offer;
            Ft = Optionst.forward_price;
            Dt = Optionst.div;
            %IVt = Optionst.impl_volatility;

            % Log moneyness
            LMt = log(Striket./Ft);

            % Convert put prices to call prices using put-call parity
            % Bidt(Callt==0) = Bidt(Callt==0) + exp(-rt(Callt==0).*Mat(Callt==0)).*(Ft(Callt==0)-Striket(Callt==0));
            % Askt(Callt==0) = Askt(Callt==0) + exp(-rt(Callt==0).*Mat(Callt==0)).*(Ft(Callt==0)-Striket(Callt==0));
            % Midt = (Bidt+Askt)/2;
            Midt = (Bidt+Askt)/2;
            Midt(Callt==0) = Midt(Callt==0) + exp(-rt(Callt==0).*Mat(Callt==0)).*(Ft(Callt==0)-Striket(Callt==0));

            % Implied volatility
            IVt = blsimpv(Ft.*exp(-rt.*Mat), Striket, rt, Mat, Midt);
            %IVt = blsimpv(St, Striket, rt, Mat, Midt, 'Yield', Optionst.divYield);

            % Fit SVI: handling warnings and crazy coefficient estimates
            for attempt = 1:params.maxFitTries
                lastwarn('');
                [coef, theta, mat_unique] = fit_svi_surface(IVt, Mat, LMt, params.Phifun);
                [wmsg, wid] = lastwarn;

                if contains(wmsg, 'singular')
                    fprintf("  Attempt %d: Singular matrix warning detected. Retrying...\n", attempt);
                elseif max(abs(coef(:))) >=10
                    fprintf("  Attempt %d: Extreme estimates detected. Retrying...\n", attempt);
                else
                    break;
                end
            end

            % Interpolation
            [~,idx] = ismember(mat_unique,Mat);
            Ft_unique = Ft(idx);
            Dt_unique = Dt(idx);
            rt_unique = rt(idx);
            Finterp = griddedInterpolant(mat_unique,Ft_unique,'linear','linear');
            Dinterp = griddedInterpolant(mat_unique,Dt_unique,'linear','linear');
            rinterp = griddedInterpolant(mat_unique,rt_unique,'pchip','pchip');

            % Strike grids
            Striket_grid = St.*params.KSgrid;

            % Loop through maturities to recover Em at each maturity
            for j = 1:params.numMat

                % Interpolated data for the targeted maturity
                tau_interp = params.maturity(j)/360; % in years
                Ft_interp = Finterp(tau_interp)';
                Dt_interp = Dinterp(tau_interp)';
                rt_interp = rinterp(tau_interp)';
                LMgrid = log(Striket_grid/Ft_interp);
                [Pricet_interp, IVt_interp, ~] = svi_interpolation(LMgrid, tau_interp, ...
                    Ft_interp, rt_interp, coef, theta, mat_unique, Ft_unique, rt_unique);

                % Step 2: State-price densities
                % -------------------------------------------------------

                % K grid point(s) - DELTA
                LMgrid_m = log((Striket_grid - params.StrikeDelta)./Ft_interp);
                [Pricet_interp_m, ~, ~] = svi_interpolation(LMgrid_m, tau_interp, ...
                    Ft_interp, rt_interp, coef, theta, mat_unique, Ft_unique, rt_unique);

                % K grid point(s) + DELTA
                LMgrid_p = log((Striket_grid + params.StrikeDelta)./Ft_interp);
                [Pricet_interp_p, ~, ~] = svi_interpolation(LMgrid_p, tau_interp, ...
                    Ft_interp, rt_interp, coef, theta, mat_unique, Ft_unique, rt_unique);

                % State-price densities using Breeden-Litzenberger
                fQ = (Pricet_interp_m+Pricet_interp_p-2*Pricet_interp)/params.StrikeDelta^2;

                % Storing
                expireDate = currentDate+days(params.maturity(j)*30);
                ST_interp = Sinterp(datenum(expireDate));
                SPD.("mat"+num2str(params.maturity(j)))(t,:) = table(currentDate,expireDate,params.maturity(j),St,ST_interp,rt_interp,Dt_interp,{IVt_interp},{Pricet_interp},{Striket_grid},{fQ});
                % Column names
                if t == 1
                    SPD.("mat"+num2str(params.maturity(j))).Properties.VariableNames = {'date','exdate','maturity','St','ST','r','div','IV','Price','Strike','fQ'};
                end

            end

            % No errors occur
            success = true;
            t = t + 1;  % only move forward if success
        
        catch ME
            fprintf('Error at t = %d: %s\n', t, ME.message);
        end
    end
end
toc;

% Save raw estimations (without any modifications)
SPD.params = params;
SPD.dates = allDates;
save([outputpath 'state_price_densities.mat'],'SPD','-v7.3');

