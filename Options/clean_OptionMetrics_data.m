function Options_cleaned = clean_OptionMetrics_data(rawOptions,pars)
%{
PURPOSE:
    Cleans the raw options data imported from OptionMetrics.
INPUTS:
  rawOptions: raw dataset from OptionMetrics
  pars: parameters struct
        (1) EOMcalculation: 
            1 - calculation only at the end-of-month, 0 - daily calculation
        (2) imposeConvexityRestriction: 
            1 - eliminate options with prices that lead to non-monotonic slopes in K
%}

% Monthly or daily calculation
if pars.EOMcalcultion == 1 % month-end

    % Keep options at month end
    [yr, mo] = ymd(rawOptions.date);
    yrmo = yr * 100 + mo;
    [groups, ~] = findgroups(yrmo);
    monthend = splitapply(@max, rawOptions.date, groups);
    idx = ismember(rawOptions.date, monthend);
    Options_cleaned = rawOptions(idx, :);

elseif pars.EOMcalcultion == 0 % daily

    % Delete particular records that are obvious recording errors:
    % Looks like large transaction of OOM calls that were not present in data
    % on previous date or on next date (5/15 or 5/17). This also caused a put
    % price to be listed that violated arb bound.
    idx_rem = find(and(and(and(rawOptions.date == datetime(2007,5,16), rawOptions.exdate == datetime(2007,6,16)), ismember(rawOptions.cp_flag,'P')), rawOptions.strike_price==1800000));
    idx_rem = [idx_rem; find(and(and(and(rawOptions.date == datetime(2007,5,16), rawOptions.exdate == datetime(2007,6,16)), ismember(rawOptions.cp_flag,'C')), rawOptions.strike_price==1800000))];
    Options_cleaned = rawOptions;
    Options_cleaned(idx_rem,:) = [];

end

% OptionMetrics reports strike prices multiplied by 1000
Options_cleaned.strike_price = Options_cleaned.strike_price/1000;

% Drop options with bid < 0.5$
Options_cleaned(Options_cleaned.best_bid<=0.5,:) = [];

% Drop options with bid higher than ask
Options_cleaned(Options_cleaned.best_bid>Options_cleaned.best_offer,:) = [];

% Time to maturity in days
Options_cleaned.maturity = days(Options_cleaned.exdate - Options_cleaned.date);

% Drop options with expiration within 7 days
% options very close to expiration (e.g., in their final week) can exhibit unusual price behavior
Options_cleaned(Options_cleaned.maturity<=7,:) = [];

% Mid price as an estimate of the option's "true" market price
Options_cleaned.mid_price = (Options_cleaned.best_bid + Options_cleaned.best_offer)/2;

% Call indicator (matching numerics faster than matching strings, cp_flag)
Options_cleaned.call_indicator = zeros(size(Options_cleaned.date));
Options_cleaned.call_indicator(contains(Options_cleaned.cp_flag, 'C')) = 1;

% Drop all ITM options
idx = (Options_cleaned.call_indicator == 1 & Options_cleaned.forward_price > Options_cleaned.strike_price) ...
    | (Options_cleaned.call_indicator == 0 & Options_cleaned.forward_price < Options_cleaned.strike_price);
Options_cleaned(idx,:) = [];

% % Drop deep ITM options
% blendSpan = 0.01;
% idx = (Options_cleaned.call_indicator == 1 & Options_cleaned.St.*(1 - blendSpan) > Options_cleaned.strike_price) ...
%     | (Options_cleaned.call_indicator == 0 & Options_cleaned.St.*(1 + blendSpan) < Options_cleaned.strike_price);
% Options_cleaned(idx,:) = [];

% Keep options with expiration date on 3rd Friday of month,
% or on Saturday that follows the third Friday
% This also drops weeklies, quarterlies, and EOM options
% (irregular trading patterns, lower liquidity, etc.)
if pars.thirdFriday == 1

    % step 1: unique expiration dates
    exdate_unique = unique(Options_cleaned.exdate);
    % step 2: third Fridays
    thirdFridays = datetime(nweekdate(3,6,year(exdate_unique),month(exdate_unique)), 'ConvertFrom','datenum');
    % step 3: include Saturdays that follows the third Friday (one day after)
    thirdFridaySaturdays = thirdFridays + caldays(1);
    % step 4: combine third Fridays and those Saturdays
    validExpDates = [thirdFridays; thirdFridaySaturdays];
    % step 5: keep options with valid expiration dates
    idx_keep = ismember(Options_cleaned.exdate, validExpDates);
    Options_cleaned = Options_cleaned(idx_keep,:);

end

% Adjust the AM-settled expiration date to the previous day (if an option
% expires at the market opening, this corresponds to a horizon of one day less)
Options_cleaned.exdate(Options_cleaned.am_settlement == 1) = ...
    Options_cleaned.exdate(Options_cleaned.am_settlement == 1) - caldays(1);
Options_cleaned.maturity(Options_cleaned.am_settlement == 1) = ...
    Options_cleaned.maturity(Options_cleaned.am_settlement == 1) - 1;

% % Keep PM-settled options if both AM and PM settlement co-exist
% % PM-settled reflects closing prices and is more common now
% Options_cleaned=sortrows(Options_cleaned,{'date','exdate','call_indicator','strike_price','am_settlement'},{'ascend','ascend','ascend','ascend','descend'});
% [~,idx,~] = unique(Options_cleaned(:,{'date','exdate','call_indicator','strike_price'}),'rows');
% Options_cleaned = Options_cleaned(idx,:);

% Drop options with prices that lead to non-monotonic slopes in strikes
% this step takes a long time
if pars.imposeConvexityRestriction == 1

    % Create an option ID: date-exdate-type-settled
    % (date-exdate-call_indicator-am_settlement)
    optionID = mod(year(Options_cleaned.date),100)*10^11 + ...
        month(Options_cleaned.date)*10^9 + ...
        day(Options_cleaned.date)*10^7 + ...
        mod(year(Options_cleaned.exdate),100)*10^5 + ...
        month(Options_cleaned.exdate)*10^3 + ...
        day(Options_cleaned.exdate)*10 + ...
        Options_cleaned.call_indicator;

    % Sorted on ascending strike prices
    Options_cleaned=sortrows(Options_cleaned,{'date','exdate','call_indicator','am_settlement','strike_price'},{'ascend','ascend','ascend','ascend','ascend'});

    % Loop over each unique option set and store indices to remove
    optionID_unique = unique(optionID);
    idx_rem = [];
    for i = 1:length(optionID_unique)

        if mod(i,1000)==0
            disp(['Convexity violation filter: ', num2str(i),' out of ',num2str(length(optionID_unique))])
        end

        [idx,~] = ismember(optionID, optionID_unique(i));
        idx = find(idx);

        % Different treatment for calls and puts
        if Options_cleaned.call_indicator(idx(1)) == 1

            idx_rem_temp = [];
            numCalls = length(idx);
            idx_recentMax = 1;  % Lowest strike call should have the highest price

            for j = 2:numCalls

                if Options_cleaned.mid_price(idx(j))>Options_cleaned.mid_price(idx(idx_recentMax))
                    idx_rem_temp = [idx_rem_temp; idx(j)];
                else
                    idx_recentMax = j;
                end

            end

        else

            idx_rem_temp = [];
            numPuts = length(idx);
            idx_recentMax = numPuts;    % Highest strike put should have the higest price

            for j = 1:numPuts-1

                if Options_cleaned.mid_price(idx(numPuts-j))>Options_cleaned.mid_price(idx(idx_recentMax))
                    idx_rem_temp = [idx_rem_temp; idx(numPuts-j)];
                else
                    idx_recentMax = numPuts-j;
                end

            end

        end

        idx_rem = [idx_rem; idx_rem_temp];

    end

    disp(['Num options removed = ', num2str(length(idx_rem)), ' out of ', num2str(length(Options_cleaned.date)), ' original options'])

    Options_cleaned(idx_rem,:) = [];

end

% Sort rows
Options_cleaned = sortrows(Options_cleaned,{'date','exdate','strike_price','call_indicator'});
