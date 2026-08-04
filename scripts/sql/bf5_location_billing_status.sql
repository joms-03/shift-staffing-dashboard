-- BF5 Location Payment Status
--
-- Use the same authoritative billing source selected on the Qwick location
-- Billing page. Location billing is configured when the selected location has
-- a billing customer. Organization billing is configured when the selected
-- organization has a billing customer. This covers both saved payment methods
-- and invoice terms without depending on optional inv_customers metadata.
WITH upcoming_locations AS (
  SELECT DISTINCT location_id
  FROM reporting.mv_core_applications_v3
  WHERE gig_start_time_local >= CURRENT_DATE - INTERVAL '1 day'
    AND gig_start_time_local < CURRENT_DATE + INTERVAL '31 days'
    AND location_id IS NOT NULL
)
SELECT
  r.location_id,
  r.location_name,
  r.approval_status,
  CASE
    WHEN UPPER(COALESCE(loc.billing_source, '')) = 'LOCATION'
     AND loc.billing_customer_id IS NOT NULL THEN 'Yes'
    WHEN UPPER(COALESCE(loc.billing_source, '')) = 'ORGANIZATION'
     AND org.billing_customer_id IS NOT NULL THEN 'Yes'
    ELSE 'No'
  END AS has_payment_information,
  CASE
    WHEN UPPER(COALESCE(loc.billing_source, '')) = 'LOCATION'
     AND loc.billing_customer_id IS NOT NULL THEN 'Location billing account'
    WHEN UPPER(COALESCE(loc.billing_source, '')) = 'ORGANIZATION'
     AND org.billing_customer_id IS NOT NULL THEN 'Organization billing account'
    WHEN UPPER(COALESCE(loc.billing_source, '')) = 'LOCATION' THEN 'Location billing incomplete'
    WHEN UPPER(COALESCE(loc.billing_source, '')) = 'ORGANIZATION' THEN 'Organization billing incomplete'
    ELSE 'No billing source'
  END AS payment_information_scope
FROM upcoming_locations u
JOIN reporting.mv_core_locations_v3 r
  ON r.location_id = u.location_id
JOIN public.db_locations_location loc
  ON loc.id = u.location_id
LEFT JOIN public.db_organizations_organization org
  ON org.id = loc.organization_id
ORDER BY r.location_id
LIMIT 5000;
