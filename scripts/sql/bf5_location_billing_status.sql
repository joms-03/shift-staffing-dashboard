-- BF5 Location Payment Status
--
-- An active invoicing customer is valid billing setup even when it uses a
-- custom invoice and therefore has no saved card/bank payment_source. Billing
-- can be attached directly to the location or inherited from its organization.
WITH upcoming_locations AS (
  SELECT DISTINCT location_id
  FROM reporting.mv_core_applications_v3
  WHERE gig_start_time_local >= CURRENT_DATE - INTERVAL '1 day'
    AND gig_start_time_local < CURRENT_DATE + INTERVAL '31 days'
    AND location_id IS NOT NULL
),
location_billing AS (
  SELECT
    metadata.location_id::varchar AS location_id,
    MAX(CASE WHEN active = TRUE THEN 1 ELSE 0 END) AS has_billing,
    MAX(CASE WHEN active = TRUE AND payment_source IS NOT NULL THEN 1 ELSE 0 END) AS has_saved_payment_source
  FROM invoicing.inv_customers
  WHERE metadata.location_id IS NOT NULL
  GROUP BY 1
),
organization_billing AS (
  SELECT
    metadata.org_id::varchar AS organization_id,
    MAX(CASE WHEN active = TRUE THEN 1 ELSE 0 END) AS has_billing,
    MAX(CASE WHEN active = TRUE AND payment_source IS NOT NULL THEN 1 ELSE 0 END) AS has_saved_payment_source
  FROM invoicing.inv_customers
  WHERE metadata.org_id IS NOT NULL
  GROUP BY 1
)
SELECT
  l.location_id,
  l.location_name,
  l.approval_status,
  CASE
    WHEN COALESCE(lb.has_billing, 0) = 1 OR COALESCE(ob.has_billing, 0) = 1 THEN 'Yes'
    ELSE 'No'
  END AS has_payment_information,
  CASE
    WHEN COALESCE(lb.has_billing, 0) = 1 AND COALESCE(ob.has_billing, 0) = 1 THEN
      CASE
        WHEN COALESCE(lb.has_saved_payment_source, 0) = 1
         AND COALESCE(ob.has_saved_payment_source, 0) = 1
          THEN 'Location + Organization payment method'
        WHEN COALESCE(lb.has_saved_payment_source, 0) = 1
          THEN 'Location payment method + Organization invoice'
        WHEN COALESCE(ob.has_saved_payment_source, 0) = 1
          THEN 'Location invoice + Organization payment method'
        ELSE 'Location + Organization invoice'
      END
    WHEN COALESCE(lb.has_billing, 0) = 1 THEN
      CASE
        WHEN COALESCE(lb.has_saved_payment_source, 0) = 1 THEN 'Location payment method'
        ELSE 'Location invoice'
      END
    WHEN COALESCE(ob.has_billing, 0) = 1 THEN
      CASE
        WHEN COALESCE(ob.has_saved_payment_source, 0) = 1 THEN 'Organization payment method'
        ELSE 'Organization invoice'
      END
    ELSE 'None'
  END AS payment_information_scope
FROM upcoming_locations u
JOIN reporting.mv_core_locations_v3 l
  ON l.location_id = u.location_id
LEFT JOIN location_billing lb
  ON lb.location_id = l.location_id::varchar
LEFT JOIN organization_billing ob
  ON ob.organization_id = l.organization_id::varchar
ORDER BY l.location_id
LIMIT 5000;
