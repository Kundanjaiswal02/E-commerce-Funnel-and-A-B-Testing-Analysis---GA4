-- Explored the dataset

SELECT field_path, data_type
FROM `bigquery-public-data.ga4_obfuscated_sample_ecommerce.INFORMATION_SCHEMA.COLUMN_FIELD_PATHS`
WHERE table_name = 'events_20210131'
ORDER BY field_path;

-- Explore the dataset: 10 raw rows of the key columns to see what one event row looks like.

SELECT
  event_date,
  event_name,
  user_pseudo_id,
  device.category       AS device,
  traffic_source.source AS source,
  geo.country           AS country
FROM `bigquery-public-data.ga4_obfuscated_sample_ecommerce.events_20210131`
LIMIT 10;

-- 01 | Which events exist, and how often? (first week only, to keep the query small)

SELECT
  event_name,
  COUNT(*) AS events
FROM `bigquery-public-data.ga4_obfuscated_sample_ecommerce.events_*`
WHERE _TABLE_SUFFIX BETWEEN '20201101' AND '20201107'
GROUP BY event_name
ORDER BY events DESC;

-- 02 | How big is the dataset and what period does it cover?

SELECT
  COUNT(*)                       AS total_events,
  COUNT(DISTINCT user_pseudo_id) AS total_users,
  MIN(event_date)                AS first_day,
  MAX(event_date)                AS last_day
FROM `bigquery-public-data.ga4_obfuscated_sample_ecommerce.events_*`;


-- 03 | Is each funnel event tracked every day? (event counts per day, full period)

SELECT
  event_date,
  COUNTIF(event_name = 'view_item')      AS view_item,
  COUNTIF(event_name = 'add_to_cart')    AS add_to_cart,
  COUNTIF(event_name = 'begin_checkout') AS begin_checkout,
  COUNTIF(event_name = 'purchase')       AS purchase
FROM `bigquery-public-data.ga4_obfuscated_sample_ecommerce.events_*`
GROUP BY event_date
ORDER BY event_date;


-- 03b, Same check as 03, written as a rule: return ONLY the days that look broken
-- Rule: add_to_cart should never be 0 and should normally be above begin_checkout.

WITH daily AS (
  SELECT
    event_date,
    COUNTIF(event_name = 'add_to_cart')    AS add_to_cart,
    COUNTIF(event_name = 'begin_checkout') AS begin_checkout
  FROM `bigquery-public-data.ga4_obfuscated_sample_ecommerce.events_*`
  GROUP BY event_date
)
SELECT *
FROM daily
WHERE add_to_cart = 0
   OR add_to_cart < begin_checkout
ORDER BY event_date;

-- -- Finding: 26 days flagged. 24 of 25 days from 1-25 Nov (all except 18 Nov) and 22-23 Jan.
-- Confirms 03: tracking broken/unstable until 25 Nov. 18 Nov passes the rule but sits inside
-- the unstable period. 22-23 Jan are isolated days within a working period, so kept.


-- 04 | User-level funnel: how many distinct users reach each step? (26 Nov 2020 - 31 Jan 2021)

WITH user_steps AS (
  SELECT
    user_pseudo_id,
    MAX(IF(event_name = 'view_item',         1, 0)) AS viewed_item,
    MAX(IF(event_name = 'add_to_cart',       1, 0)) AS added_to_cart,
    MAX(IF(event_name = 'begin_checkout',    1, 0)) AS began_checkout,
    MAX(IF(event_name = 'add_shipping_info', 1, 0)) AS added_shipping,
    MAX(IF(event_name = 'add_payment_info',  1, 0)) AS added_payment,
    MAX(IF(event_name = 'purchase',          1, 0)) AS purchased
  FROM `bigquery-public-data.ga4_obfuscated_sample_ecommerce.events_*`
  WHERE _TABLE_SUFFIX BETWEEN '20201126' AND '20210131'
  GROUP BY user_pseudo_id
)
SELECT
  COUNT(*)            AS all_users,
  SUM(viewed_item)    AS viewed_item,
  SUM(added_to_cart)  AS added_to_cart,
  SUM(began_checkout) AS began_checkout,
  SUM(added_shipping) AS added_shipping,
  SUM(added_payment)  AS added_payment,
  SUM(purchased)      AS purchased
FROM user_steps;

-- -- Finding: 209,914 users | view_item 45,107 | add_to_cart 12,023 | begin_checkout 6,509 |
-- add_shipping_info 6,510 | add_payment_info 4,253 | purchase 3,351 (1.60% of users).
-- Note: shipping is 1 user above checkout because the open funnel does not enforce order.


-- 05 | Step-to-step conversion: what % of users move on to the next step?

WITH user_steps AS (
  SELECT
    user_pseudo_id,
    MAX(IF(event_name = 'view_item',        1, 0)) AS viewed,
    MAX(IF(event_name = 'add_to_cart',      1, 0)) AS cart,
    MAX(IF(event_name = 'begin_checkout',   1, 0)) AS checkout,
    MAX(IF(event_name = 'add_payment_info', 1, 0)) AS payment,
    MAX(IF(event_name = 'purchase',         1, 0)) AS purchased
  FROM `bigquery-public-data.ga4_obfuscated_sample_ecommerce.events_*`
  WHERE _TABLE_SUFFIX BETWEEN '20201126' AND '20210131'
  GROUP BY user_pseudo_id
)
SELECT
  ROUND(100 * SUM(cart)      / SUM(viewed),   1) AS view_to_cart_pct,
  ROUND(100 * SUM(checkout)  / SUM(cart),     1) AS cart_to_checkout_pct,
  ROUND(100 * SUM(payment)   / SUM(checkout), 1) AS checkout_to_payment_pct,
  ROUND(100 * SUM(purchased) / SUM(payment),  1) AS payment_to_purchase_pct
FROM user_steps;

-- -- Finding: view->cart 26.7% | cart->checkout 54.1% | checkout->payment 65.3% | payment->purchase 78.8%.
-- Biggest drop: product page (view->cart), 33,084 users lost (73.3%). Chosen as the step to fix first.


-- 06 | Data check before the device split: do users appear on more than one device type?

SELECT
  COUNT(*)                                             AS users,
  COUNTIF(device_count > 1)                            AS users_with_multiple_devices,
  ROUND(100 * COUNTIF(device_count > 1) / COUNT(*), 2) AS pct_multiple
FROM (
  SELECT user_pseudo_id, COUNT(DISTINCT device.category) AS device_count
  FROM `bigquery-public-data.ga4_obfuscated_sample_ecommerce.events_*`
  WHERE _TABLE_SUFFIX BETWEEN '20201126' AND '20210131'
  GROUP BY user_pseudo_id
);

-- -- Finding: 2,821 of 209,914 users (1.34%) have more than one device category.


-- 07 | Funnel by device: is the product-page drop worse on one device?

WITH user_steps AS (
  SELECT
    user_pseudo_id,
    ANY_VALUE(device.category) AS device,
    MAX(IF(event_name = 'view_item',      1, 0)) AS viewed_item,
    MAX(IF(event_name = 'add_to_cart',    1, 0)) AS added_to_cart,
    MAX(IF(event_name = 'begin_checkout', 1, 0)) AS began_checkout,
    MAX(IF(event_name = 'purchase',       1, 0)) AS purchased
  FROM `bigquery-public-data.ga4_obfuscated_sample_ecommerce.events_*`
  WHERE _TABLE_SUFFIX BETWEEN '20201126' AND '20210131'
  GROUP BY user_pseudo_id
)
SELECT
  device,
  COUNT(*)            AS users,
  SUM(viewed_item)    AS viewed_item,
  SUM(added_to_cart)  AS added_to_cart,
  SUM(began_checkout) AS began_checkout,
  SUM(purchased)      AS purchased,
  ROUND(100 * SAFE_DIVIDE(SUM(added_to_cart),  SUM(viewed_item)),    1) AS view_to_cart_pct,
  ROUND(100 * SAFE_DIVIDE(SUM(began_checkout), SUM(added_to_cart)),  1) AS cart_to_checkout_pct,
  ROUND(100 * SAFE_DIVIDE(SUM(purchased),      SUM(began_checkout)), 1) AS checkout_to_purchase_pct,
  ROUND(100 * SAFE_DIVIDE(SUM(purchased),      COUNT(*)),            2) AS overall_conversion_pct,
  ROUND(100 * COUNT(*) / SUM(COUNT(*)) OVER (), 1)                       AS share_of_users_pct
FROM user_steps
GROUP BY device
ORDER BY users DESC;

-- -- Finding: view->cart desktop 26.4% | mobile 27.1% | tablet 25.3% (within ~2 pts).
-- The drop is not device-specific.


-- 08 | Funnel by acquisition channel (traffic_source.medium = channel that FIRST brought the user)

WITH user_steps AS (
  SELECT
    user_pseudo_id,
    ANY_VALUE(traffic_source.medium) AS medium,
    MAX(IF(event_name = 'view_item',      1, 0)) AS viewed_item,
    MAX(IF(event_name = 'add_to_cart',    1, 0)) AS added_to_cart,
    MAX(IF(event_name = 'begin_checkout', 1, 0)) AS began_checkout,
    MAX(IF(event_name = 'purchase',       1, 0)) AS purchased
  FROM `bigquery-public-data.ga4_obfuscated_sample_ecommerce.events_*`
  WHERE _TABLE_SUFFIX BETWEEN '20201126' AND '20210131'
  GROUP BY user_pseudo_id
)
SELECT
  medium,
  COUNT(*)           AS users,
  SUM(viewed_item)   AS viewed_item,
  SUM(added_to_cart) AS added_to_cart,
  ROUND(100 * SAFE_DIVIDE(SUM(added_to_cart),  SUM(viewed_item)),   1) AS view_to_cart_pct,
  ROUND(100 * SAFE_DIVIDE(SUM(began_checkout), SUM(added_to_cart)), 1) AS cart_to_checkout_pct,
  ROUND(100 * SAFE_DIVIDE(SUM(purchased),      COUNT(*)),           2) AS overall_conversion_pct,
  ROUND(100 * COUNT(*) / SUM(COUNT(*)) OVER (), 1)                      AS share_of_users_pct
FROM user_steps
GROUP BY medium
ORDER BY users DESC;

-- -- Finding: largest channels organic 24.6% and (none) 26.7% view->cart, close to overall 26.7%.
-- Referral highest (29.1%), cpc lowest (23.0%, 5% of users).
-- (data deleted) 41.6% is only 2.7% of users and cannot be interpreted.
-- Conclusion: channel is not the main cause of the product-page drop.



-- 09 | Funnel by new vs returning users

WITH user_steps AS (
  SELECT
    user_pseudo_id,
    MAX(IF(event_name = 'first_visit',    1, 0)) AS is_new,
    MAX(IF(event_name = 'view_item',      1, 0)) AS viewed_item,
    MAX(IF(event_name = 'add_to_cart',    1, 0)) AS added_to_cart,
    MAX(IF(event_name = 'begin_checkout', 1, 0)) AS began_checkout,
    MAX(IF(event_name = 'purchase',       1, 0)) AS purchased
  FROM `bigquery-public-data.ga4_obfuscated_sample_ecommerce.events_*`
  WHERE _TABLE_SUFFIX BETWEEN '20201126' AND '20210131'
  GROUP BY user_pseudo_id
)
SELECT
  IF(is_new = 1, 'new', 'returning') AS user_type,
  COUNT(*)         AS users,
  SUM(viewed_item) AS viewed_item,
  ROUND(100 * SAFE_DIVIDE(SUM(added_to_cart),  SUM(viewed_item)),   1) AS view_to_cart_pct,
  ROUND(100 * SAFE_DIVIDE(SUM(began_checkout), SUM(added_to_cart)), 1) AS cart_to_checkout_pct,
  ROUND(100 * SAFE_DIVIDE(SUM(purchased),      COUNT(*)),           2) AS overall_conversion_pct,
  ROUND(100 * COUNT(*) / SUM(COUNT(*)) OVER (), 1)                      AS share_of_users_pct
FROM user_steps
GROUP BY user_type
ORDER BY users DESC;

-- -- Finding: new 25.2% vs returning 39.2% view->cart. New users = 94.9% of users and
-- 89.7% of product viewers, so the product-page problem is mainly a first-time-visitor problem.
-- Caveat: correlation, not cause (returning users chose to come back). "New" = new browser cookie.


-- 10 | Baseline for the A/B test: product viewers only (the test population)

WITH user_steps AS (
  SELECT
    user_pseudo_id,
    MAX(IF(event_name = 'view_item',   1, 0)) AS viewed_item,
    MAX(IF(event_name = 'add_to_cart', 1, 0)) AS added_to_cart,
    MAX(IF(event_name = 'purchase',    1, 0)) AS purchased
  FROM `bigquery-public-data.ga4_obfuscated_sample_ecommerce.events_*`
  WHERE _TABLE_SUFFIX BETWEEN '20201126' AND '20210131'
  GROUP BY user_pseudo_id
)
SELECT
  SUM(viewed_item)                 AS viewers,
  SUM(viewed_item * added_to_cart) AS viewers_added_to_cart,
  SUM(viewed_item * purchased)     AS viewers_purchased
FROM user_steps;

-- -- Finding: 45,107 viewers | 12,017 viewers added to cart (26.64% baseline) |
-- 3,328 viewers purchased (7.38% guardrail baseline).
-- Used in the Colab notebook (ab_test_simulation.ipynb) to calculate sample size.


-- ===============================================================================

-- Data Preparation for Dashboard

-- 11 | DASHBOARD TABLE: funnel_steps
-- WHAT: Saves the funnel as a table with ONE ROW PER STEP, plus users lost
-- and step-to-step conversion %.


CREATE SCHEMA IF NOT EXISTS `funnel-portfolio-514915.funnel_dashboard`
OPTIONS (location = 'US');

CREATE OR REPLACE TABLE `funnel-portfolio-514915.funnel_dashboard.funnel_steps` AS

-- 1: one row per user with a 1/0 flag per step (same idea as query 04)
WITH user_steps AS (
  SELECT
    user_pseudo_id,
    MAX(IF(event_name = 'view_item',        1, 0)) AS viewed_item,
    MAX(IF(event_name = 'add_to_cart',      1, 0)) AS added_to_cart,
    MAX(IF(event_name = 'begin_checkout',   1, 0)) AS began_checkout,
    MAX(IF(event_name = 'add_payment_info', 1, 0)) AS added_payment,
    MAX(IF(event_name = 'purchase',         1, 0)) AS purchased
  FROM `bigquery-public-data.ga4_obfuscated_sample_ecommerce.events_*`
  WHERE _TABLE_SUFFIX BETWEEN '20201126' AND '20210131'
  GROUP BY user_pseudo_id
),

-- 2: add up the flags = users per step (one row, many columns)
totals AS (
  SELECT
    COUNT(*)            AS all_users,
    SUM(viewed_item)    AS viewed_item,
    SUM(added_to_cart)  AS added_to_cart,
    SUM(began_checkout) AS began_checkout,
    SUM(added_payment)  AS added_payment,
    SUM(purchased)      AS purchased
  FROM user_steps
),

-- 3: turn the columns into rows (one row per step)
funnel AS (
  SELECT s.step_order, s.step, s.users
  FROM totals,
  UNNEST([
    STRUCT(1 AS step_order, '1. All users' AS step, all_users AS users),
    STRUCT(2, '2. View item',      viewed_item),
    STRUCT(3, '3. Add to cart',    added_to_cart),
    STRUCT(4, '4. Begin checkout', began_checkout),
    STRUCT(5, '5. Add payment',    added_payment),
    STRUCT(6, '6. Purchase',       purchased)
  ]) AS s
)

-- 4: compare each step with the step before it
SELECT
  step_order,
  step,
  users,
  LAG(users) OVER (ORDER BY step_order) - users                             AS users_lost,
  ROUND(100 * SAFE_DIVIDE(users, LAG(users) OVER (ORDER BY step_order)), 1) AS step_conversion_pct
FROM funnel;


-- 12 | DASHBOARD TABLE: funnel_segments
-- WHAT: Saves funnel rates for 3 kinds of segment (Device, Channel,
-- User type) in ONE table, with a column saying which kind each row is.

CREATE OR REPLACE TABLE `funnel-portfolio-514915.funnel_dashboard.funnel_segments` AS

-- PART 1: one row per user, with their device, channel, new/returning, and step flags
WITH user_steps AS (
  SELECT
    user_pseudo_id,
    ANY_VALUE(device.category)       AS device,
    ANY_VALUE(traffic_source.medium) AS medium,
    MAX(IF(event_name = 'first_visit',    1, 0)) AS is_new,
    MAX(IF(event_name = 'view_item',      1, 0)) AS viewed_item,
    MAX(IF(event_name = 'add_to_cart',    1, 0)) AS added_to_cart,
    MAX(IF(event_name = 'begin_checkout', 1, 0)) AS began_checkout,
    MAX(IF(event_name = 'purchase',       1, 0)) AS purchased
  FROM `bigquery-public-data.ga4_obfuscated_sample_ecommerce.events_*`
  WHERE _TABLE_SUFFIX BETWEEN '20201126' AND '20210131'
  GROUP BY user_pseudo_id
),

-- PART 2: stack the same users 3 times, each time labelled by a different segment
stacked AS (
  SELECT 'Device' AS segment_type, device AS segment,
         viewed_item, added_to_cart, began_checkout, purchased
  FROM user_steps
  UNION ALL
  SELECT 'Channel', medium,
         viewed_item, added_to_cart, began_checkout, purchased
  FROM user_steps
  UNION ALL
  SELECT 'User type', IF(is_new = 1, 'new', 'returning'),
         viewed_item, added_to_cart, began_checkout, purchased
  FROM user_steps
)

-- PART 3: count per segment and calculate the rates
SELECT
  segment_type,
  segment,
  COUNT(*)           AS users,
  SUM(viewed_item)   AS viewed_item,
  SUM(added_to_cart) AS added_to_cart,
  ROUND(100 * SAFE_DIVIDE(SUM(added_to_cart),  SUM(viewed_item)),   1) AS view_to_cart_pct,
  ROUND(100 * SAFE_DIVIDE(SUM(began_checkout), SUM(added_to_cart)), 1) AS cart_to_checkout_pct,
  ROUND(100 * SAFE_DIVIDE(SUM(purchased),      COUNT(*)),           2) AS overall_conversion_pct,
  ROUND(100 * COUNT(*) / SUM(COUNT(*)) OVER (PARTITION BY segment_type), 1) AS share_of_users_pct
FROM stacked
GROUP BY segment_type, segment;


-- 13 | DASHBOARD TABLE: daily_events
-- WHAT: Saves daily counts of the main funnel events for ALL 92 days,
-- with a real DATE column.

CREATE OR REPLACE TABLE `funnel-portfolio-514915.funnel_dashboard.daily_events` AS
SELECT
  PARSE_DATE('%Y%m%d', event_date)       AS date,
  COUNTIF(event_name = 'view_item')      AS view_item,
  COUNTIF(event_name = 'add_to_cart')    AS add_to_cart,
  COUNTIF(event_name = 'begin_checkout') AS begin_checkout,
  COUNTIF(event_name = 'purchase')       AS purchase
FROM `bigquery-public-data.ga4_obfuscated_sample_ecommerce.events_*`
GROUP BY date
ORDER BY date;
