{{ config(materialized = 'semantic_view') }}

-- Added for the ADE repair agent demo; not part of the guide.
--
-- The semantic view is the business context at the end of the pipeline. It's what
-- Cortex Analyst answers questions from, and it's what the repair agent reads to
-- understand what a broken model is for: which columns people rely on, how they
-- join and what each metric means. A fix that compiles but changes a metric's
-- meaning is a wrong fix, and this is where the agent can tell.

TABLES (
    customers AS {{ ref('customers') }}
        PRIMARY KEY (customer_key)
        COMMENT = 'One row per TPC-H customer, with nation and region',
    orders AS {{ ref('orders_summary') }}
        PRIMARY KEY (order_key)
        WITH SYNONYMS = ('sales', 'order lines summary')
        COMMENT = 'One row per order, with line item totals'
)

RELATIONSHIPS (
    orders_to_customers AS orders(customer_key) REFERENCES customers(customer_key)
)

FACTS (
    orders.order_total_price AS orders.order_total_price
        COMMENT = 'Order total as recorded on the order',
    orders.total_net_price AS orders.total_net_price
        COMMENT = 'Sum of extended price after discount',
    orders.total_charged_price AS orders.total_charged_price
        COMMENT = 'Sum of extended price after discount and tax',
    orders.total_quantity AS orders.total_quantity
        COMMENT = 'Sum of line item quantities'
)

DIMENSIONS (
    customers.customer_name AS customers.customer_name
        WITH SYNONYMS = ('customer')
        COMMENT = 'Customer name',
    customers.market_segment AS customers.market_segment
        WITH SYNONYMS = ('segment')
        COMMENT = 'Customer market segment',
    customers.nation AS customers.nation
        WITH SYNONYMS = ('country')
        COMMENT = 'Customer nation',
    customers.region AS customers.region
        COMMENT = 'Customer region',
    orders.order_date AS orders.order_date
        COMMENT = 'Date the order was placed',
    orders.order_status AS orders.order_status
        COMMENT = 'Order status code: F fulfilled, O open, P partial',
    orders.order_priority AS orders.order_priority
        COMMENT = 'Order priority'
)

METRICS (
    orders.order_count AS COUNT(orders.order_key)
        WITH SYNONYMS = ('number of orders')
        COMMENT = 'Number of orders',
    orders.revenue AS SUM(orders.total_charged_price)
        WITH SYNONYMS = ('sales', 'total revenue')
        COMMENT = 'Revenue: extended price after discount and tax, summed',
    orders.net_revenue AS SUM(orders.total_net_price)
        COMMENT = 'Revenue after discount, before tax',
    orders.avg_order_value AS AVG(orders.total_charged_price)
        COMMENT = 'Average charged price per order',
    customers.customer_count AS COUNT(DISTINCT customers.customer_key)
        COMMENT = 'Number of customers'
)

COMMENT = 'TPC-H orders and customers from the Data engineering with CoCo guide pipeline'

AI_SQL_GENERATION 'Revenue means total_charged_price (after discount and tax) unless the question says net. Order status F is fulfilled, O open, P partially fulfilled.'

AI_VERIFIED_QUERIES (
    revenue_by_segment AS (
        QUESTION 'What is revenue by market segment?'
        ONBOARDING_QUESTION TRUE
        SQL 'SELECT * FROM SEMANTIC_VIEW({{ this }} DIMENSIONS customers.market_segment METRICS orders.revenue) ORDER BY revenue DESC'
    )
)
