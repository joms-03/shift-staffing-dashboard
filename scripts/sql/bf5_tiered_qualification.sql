WITH skill_ladder AS (
    SELECT 'boh-main' AS track, 'event chef' AS skill_key, 6 AS tier
    UNION ALL SELECT 'boh-main', 'banquet cook', 5
    UNION ALL SELECT 'boh-main', 'line cook', 4
    UNION ALL SELECT 'boh-main', 'prep cook', 3
    UNION ALL SELECT 'boh-main', 'food assembler', 2
    UNION ALL SELECT 'boh-main', 'dishwasher', 1
    UNION ALL SELECT 'boh-pastry', 'event chef', 5
    UNION ALL SELECT 'boh-pastry', 'banquet cook', 4
    UNION ALL SELECT 'boh-pastry', 'baker/pastry cook', 3
    UNION ALL SELECT 'boh-pastry', 'food assembler', 2
    UNION ALL SELECT 'boh-pastry', 'dishwasher', 1
    UNION ALL SELECT 'foh-support', 'banquet captain', 6
    UNION ALL SELECT 'foh-support', 'banquet server', 5
    UNION ALL SELECT 'foh-support', 'restaurant server', 4
    UNION ALL SELECT 'foh-support', 'foh support', 3
    UNION ALL SELECT 'foh-support', 'concession worker', 2
    UNION ALL SELECT 'foh-support', 'event help', 1
    UNION ALL SELECT 'foh-assistant', 'banquet captain', 6
    UNION ALL SELECT 'foh-assistant', 'banquet server', 5
    UNION ALL SELECT 'foh-assistant', 'restaurant server', 4
    UNION ALL SELECT 'foh-assistant', 'server assistant', 3
    UNION ALL SELECT 'foh-assistant', 'food runner', 2
    UNION ALL SELECT 'foh-assistant', 'coat check attendant', 1
    UNION ALL SELECT 'bar', 'mixologist', 4
    UNION ALL SELECT 'bar', 'bartender', 3
    UNION ALL SELECT 'bar', 'beer & wine bartender', 2
    UNION ALL SELECT 'bar', 'barback', 1
    UNION ALL SELECT 'facilities-maintenance', 'housekeeping', 3
    UNION ALL SELECT 'facilities-maintenance', 'maintenance', 2
    UNION ALL SELECT 'facilities-maintenance', 'general laborer', 1
    UNION ALL SELECT 'facilities-cleaning', 'housekeeping', 3
    UNION ALL SELECT 'facilities-cleaning', 'general cleaning', 2
    UNION ALL SELECT 'facilities-cleaning', 'banquet setup', 1
    UNION ALL SELECT 'barista', 'barista', 1
    UNION ALL SELECT 'stage', 'stage', 1
),

shift_level AS (
    SELECT
        LOWER(TRIM(m.location_name)) AS business_key,
        m.location_name AS business_name,
        m.location_id,
        m.gig_id AS shift_id,
        MAX(m.gig_creation_time) AS gig_created_at,
        MAX(m.gig_start_time_local) AS shift_date,
        MAX(g.status) AS shift_status
    FROM reporting.mv_core_applications_v3 m
    JOIN db_gigs_gig g
        ON g.id = m.gig_id
    WHERE m.gig_id IS NOT NULL
      AND m.location_id IS NOT NULL
      AND g.status <> 'CANCELLED'
    GROUP BY
        LOWER(TRIM(m.location_name)),
        m.location_name,
        m.location_id,
        m.gig_id
),

ranked_business_shifts AS (
    SELECT
        *,
        ROW_NUMBER() OVER (
            PARTITION BY business_key
            ORDER BY shift_date ASC, gig_created_at ASC, shift_id ASC
        ) AS business_shift_number
    FROM shift_level
),

business_shift_counts AS (
    SELECT
        *,
        COUNT(*) OVER (
            PARTITION BY business_key
        ) AS total_business_postings
    FROM ranked_business_shifts
),

business_first_five AS (
    SELECT *
    FROM business_shift_counts
    WHERE business_shift_number <= 5
),

confirmed_applications AS (
    SELECT
        a.location_name AS business_name,
        a.location_id,
        a.gig_id AS shift_id,
        a.start_time,
        a.gig_start_time_local AS shift_date,
        a.market,
        a.skill,
        CASE
            WHEN LOWER(TRIM(a.skill)) IN ('food service worker', 'food assembler') THEN 'food assembler'
            WHEN LOWER(TRIM(a.skill)) IN ('event staff', 'event help') THEN 'event help'
            WHEN LOWER(TRIM(a.skill)) IN ('front of house support', 'front of house support staff', 'foh support') THEN 'foh support'
            WHEN LOWER(TRIM(a.skill)) IN ('coat check', 'coat check attendant') THEN 'coat check attendant'
            WHEN LOWER(TRIM(a.skill)) IN ('baker/pastry cook', 'bakery/pastry cook', 'bakery & pastry cook') THEN 'baker/pastry cook'
            WHEN LOWER(TRIM(a.skill)) IN ('full-service bartender', 'full service bartender', 'bartender') THEN 'bartender'
            WHEN LOWER(TRIM(a.skill)) IN ('beer and wine bartender', 'b&w bartender', 'b+w bartender', 'bartender - fixed menu') THEN 'beer & wine bartender'
            WHEN LOWER(TRIM(a.skill)) IN ('general labor', 'general laborer') THEN 'general laborer'
            ELSE LOWER(TRIM(a.skill))
        END AS skill_key,
        a.original_allowed_confirmed_pros AS requested_pros,
        a.current_confirmed_pros_count AS confirmed_pros,
        a.gig_auto_select_enabled,
        a.gig_type AS shift_type,
        a.location_address_latitude,
        a.location_address_longitude,
        a.gigster_id AS pro_id,
        a.confirmation_timestamp,
        a.selection_source,
        a.app_id
    FROM reporting.mv_core_applications_v3_fast a
    INNER JOIN business_first_five bf5
        ON bf5.shift_id = a.gig_id
    WHERE a.start_time >= GETDATE()
      AND a.is_confirmed = TRUE
      AND COALESCE(a.is_canceled, 0) = 0
      AND a.gigster_id IS NOT NULL
    QUALIFY ROW_NUMBER() OVER (
        PARTITION BY a.gig_id, a.gigster_id
        ORDER BY
            a.confirmation_timestamp DESC NULLS LAST,
            a.app_id DESC
    ) = 1
),

historical_paid AS (
    SELECT
        h.gigster_id,
        h.gig_id,
        h.location_id,
        h.start_time,
        h.rating,
        CASE
            WHEN LOWER(TRIM(h.skill)) IN ('food service worker', 'food assembler') THEN 'food assembler'
            WHEN LOWER(TRIM(h.skill)) IN ('event staff', 'event help') THEN 'event help'
            WHEN LOWER(TRIM(h.skill)) IN ('front of house support', 'front of house support staff', 'foh support') THEN 'foh support'
            WHEN LOWER(TRIM(h.skill)) IN ('coat check', 'coat check attendant') THEN 'coat check attendant'
            WHEN LOWER(TRIM(h.skill)) IN ('baker/pastry cook', 'bakery/pastry cook', 'bakery & pastry cook') THEN 'baker/pastry cook'
            WHEN LOWER(TRIM(h.skill)) IN ('full-service bartender', 'full service bartender', 'bartender') THEN 'bartender'
            WHEN LOWER(TRIM(h.skill)) IN ('beer and wine bartender', 'b&w bartender', 'b+w bartender', 'bartender - fixed menu') THEN 'beer & wine bartender'
            WHEN LOWER(TRIM(h.skill)) IN ('general labor', 'general laborer') THEN 'general laborer'
            ELSE LOWER(TRIM(h.skill))
        END AS skill_key
    FROM reporting.mv_core_applications_v3 h
    WHERE h.is_paid = 1
      AND COALESCE(h.is_canceled, 0) = 0
    QUALIFY ROW_NUMBER() OVER (
        PARTITION BY h.gigster_id, h.gig_id
        ORDER BY h.rating_timestamp DESC NULLS LAST, h.app_id DESC
    ) = 1
),

prior_experience AS (
    SELECT
        c.shift_id,
        c.pro_id,
        COUNT(DISTINCT CASE
            WHEN (target.skill_key IS NULL AND h.skill_key = c.skill_key)
              OR matched.skill_key IS NOT NULL
            THEN h.gig_id
        END) AS prior_paid_qualifying_skill_shifts,
        COUNT(DISTINCT CASE
            WHEN h.location_id = c.location_id
             AND (
                 (target.skill_key IS NULL AND h.skill_key = c.skill_key)
                 OR matched.skill_key IS NOT NULL
             )
            THEN h.gig_id
        END) AS prior_paid_qualifying_skill_shifts_same_business
    FROM confirmed_applications c
    LEFT JOIN historical_paid h
        ON h.gigster_id = c.pro_id
       AND h.start_time < c.start_time
    LEFT JOIN skill_ladder target
        ON target.skill_key = c.skill_key
    LEFT JOIN skill_ladder matched
        ON matched.track = target.track
       AND matched.skill_key = h.skill_key
       AND matched.tier >= target.tier
    GROUP BY c.shift_id, c.pro_id
),

position_ratings AS (
    SELECT
        c.shift_id,
        c.pro_id,
        ROUND(AVG(CASE WHEN h.rating BETWEEN 1 AND 5 THEN h.rating END)::numeric, 2) AS position_avg_rating,
        COUNT(DISTINCT CASE WHEN h.rating BETWEEN 1 AND 5 THEN h.gig_id END) AS position_ratings_count
    FROM confirmed_applications c
    LEFT JOIN historical_paid h
        ON h.gigster_id = c.pro_id
       AND h.start_time < c.start_time
       AND h.skill_key = c.skill_key
    GROUP BY c.shift_id, c.pro_id
),

latest_profiles AS (
    SELECT
        user_id,
        bio,
        ROW_NUMBER() OVER (
            PARTITION BY user_id
            ORDER BY last_updated_ts DESC NULLS LAST, id DESC
        ) AS rn
    FROM public.db_gigster_profiles_gigsterprofile
    WHERE COALESCE(__hevo__marked_deleted, FALSE) = FALSE
),

pro_profiles AS (
    SELECT
        p.*,
        LOWER(COALESCE(p.experience, '') || ' ' || COALESCE(lp.bio, '')) AS profile_text
    FROM reporting.mv_pro_snapshot_v3 p
    LEFT JOIN latest_profiles lp
        ON lp.user_id = p.pro_id
       AND lp.rn = 1
),

pro_skill_evidence AS (
    SELECT
        c.shift_id,
        c.pro_id,
        CASE
            WHEN p.profile_text IS NULL OR TRIM(p.profile_text) = '' THEN 0
            WHEN c.skill_key = 'event chef'
             AND p.profile_text LIKE '%event chef%' THEN 1
            WHEN c.skill_key = 'banquet cook'
             AND (
                 p.profile_text LIKE '%event chef%'
                 OR p.profile_text LIKE '%banquet cook%'
                 OR p.profile_text LIKE '%event cook%'
                 OR p.profile_text LIKE '%banquet chef%'
             ) THEN 1
            WHEN c.skill_key = 'line cook'
             AND (
                 p.profile_text LIKE '%event chef%'
                 OR p.profile_text LIKE '%banquet cook%'
                 OR p.profile_text LIKE '%event cook%'
                 OR p.profile_text LIKE '%banquet chef%'
                 OR p.profile_text LIKE '%line cook%'
             ) THEN 1
            WHEN c.skill_key = 'prep cook'
             AND (
                 p.profile_text LIKE '%event chef%'
                 OR p.profile_text LIKE '%banquet cook%'
                 OR p.profile_text LIKE '%event cook%'
                 OR p.profile_text LIKE '%banquet chef%'
                 OR p.profile_text LIKE '%line cook%'
                 OR p.profile_text LIKE '%prep cook%'
                 OR p.profile_text LIKE '%food prep%'
             ) THEN 1
            WHEN c.skill_key = 'baker/pastry cook'
             AND (
                 p.profile_text LIKE '%event chef%'
                 OR p.profile_text LIKE '%banquet cook%'
                 OR p.profile_text LIKE '%event cook%'
                 OR p.profile_text LIKE '%banquet chef%'
                 OR p.profile_text LIKE '%baker%'
                 OR p.profile_text LIKE '%bakery%'
                 OR p.profile_text LIKE '%pastry%'
             ) THEN 1
            WHEN c.skill_key = 'food assembler'
             AND (
                 p.profile_text LIKE '%event chef%'
                 OR p.profile_text LIKE '%banquet cook%'
                 OR p.profile_text LIKE '%event cook%'
                 OR p.profile_text LIKE '%banquet chef%'
                 OR p.profile_text LIKE '%line cook%'
                 OR p.profile_text LIKE '%prep cook%'
                 OR p.profile_text LIKE '%food prep%'
                 OR p.profile_text LIKE '%baker%'
                 OR p.profile_text LIKE '%bakery%'
                 OR p.profile_text LIKE '%pastry%'
                 OR p.profile_text LIKE '%food assembler%'
                 OR p.profile_text LIKE '%food service%'
                 OR p.profile_text LIKE '%cafeteria%'
             ) THEN 1
            WHEN c.skill_key = 'dishwasher'
             AND (
                 p.profile_text LIKE '%event chef%'
                 OR p.profile_text LIKE '%banquet cook%'
                 OR p.profile_text LIKE '%event cook%'
                 OR p.profile_text LIKE '%banquet chef%'
                 OR p.profile_text LIKE '%line cook%'
                 OR p.profile_text LIKE '%prep cook%'
                 OR p.profile_text LIKE '%food prep%'
                 OR p.profile_text LIKE '%baker%'
                 OR p.profile_text LIKE '%bakery%'
                 OR p.profile_text LIKE '%pastry%'
                 OR p.profile_text LIKE '%food assembler%'
                 OR p.profile_text LIKE '%food service%'
                 OR p.profile_text LIKE '%cafeteria%'
                 OR p.profile_text LIKE '%dishwasher%'
                 OR p.profile_text LIKE '%dish washer%'
                 OR p.profile_text LIKE '%dishwashing%'
             ) THEN 1
            WHEN c.skill_key = 'banquet captain'
             AND p.profile_text LIKE '%banquet captain%' THEN 1
            WHEN c.skill_key = 'banquet server'
             AND (
                 p.profile_text LIKE '%banquet captain%'
                 OR p.profile_text LIKE '%banquet server%'
                 OR p.profile_text LIKE '%event server%'
             ) THEN 1
            WHEN c.skill_key = 'restaurant server'
             AND (
                 p.profile_text LIKE '%banquet captain%'
                 OR p.profile_text LIKE '%banquet server%'
                 OR p.profile_text LIKE '%event server%'
                 OR p.profile_text LIKE '%restaurant server%'
             ) THEN 1
            WHEN c.skill_key = 'foh support'
             AND (
                 p.profile_text LIKE '%banquet captain%'
                 OR p.profile_text LIKE '%banquet server%'
                 OR p.profile_text LIKE '%event server%'
                 OR p.profile_text LIKE '%restaurant server%'
                 OR p.profile_text LIKE '%foh support%'
                 OR p.profile_text LIKE '%front of house%'
             ) THEN 1
            WHEN c.skill_key = 'concession worker'
             AND (
                 p.profile_text LIKE '%banquet captain%'
                 OR p.profile_text LIKE '%banquet server%'
                 OR p.profile_text LIKE '%event server%'
                 OR p.profile_text LIKE '%restaurant server%'
                 OR p.profile_text LIKE '%foh support%'
                 OR p.profile_text LIKE '%front of house%'
                 OR p.profile_text LIKE '%concession%'
             ) THEN 1
            WHEN c.skill_key = 'event help'
             AND (
                 p.profile_text LIKE '%banquet captain%'
                 OR p.profile_text LIKE '%banquet server%'
                 OR p.profile_text LIKE '%event server%'
                 OR p.profile_text LIKE '%restaurant server%'
                 OR p.profile_text LIKE '%foh support%'
                 OR p.profile_text LIKE '%front of house%'
                 OR p.profile_text LIKE '%concession%'
                 OR p.profile_text LIKE '%event help%'
                 OR p.profile_text LIKE '%event staff%'
             ) THEN 1
            WHEN c.skill_key = 'server assistant'
             AND (
                 p.profile_text LIKE '%banquet captain%'
                 OR p.profile_text LIKE '%banquet server%'
                 OR p.profile_text LIKE '%event server%'
                 OR p.profile_text LIKE '%restaurant server%'
                 OR p.profile_text LIKE '%server assistant%'
             ) THEN 1
            WHEN c.skill_key = 'food runner'
             AND (
                 p.profile_text LIKE '%banquet captain%'
                 OR p.profile_text LIKE '%banquet server%'
                 OR p.profile_text LIKE '%event server%'
                 OR p.profile_text LIKE '%restaurant server%'
                 OR p.profile_text LIKE '%server assistant%'
                 OR p.profile_text LIKE '%food runner%'
             ) THEN 1
            WHEN c.skill_key = 'coat check attendant'
             AND (
                 p.profile_text LIKE '%banquet captain%'
                 OR p.profile_text LIKE '%banquet server%'
                 OR p.profile_text LIKE '%event server%'
                 OR p.profile_text LIKE '%restaurant server%'
                 OR p.profile_text LIKE '%server assistant%'
                 OR p.profile_text LIKE '%food runner%'
                 OR p.profile_text LIKE '%coat check%'
             ) THEN 1
            WHEN c.skill_key = 'mixologist'
             AND p.profile_text LIKE '%mixologist%' THEN 1
            WHEN c.skill_key = 'bartender'
             AND (
                 p.profile_text LIKE '%mixologist%'
                 OR p.profile_text LIKE '%full-service bartender%'
                 OR p.profile_text LIKE '%full service bartender%'
                 OR (
                     p.profile_text LIKE '%bartender%'
                     AND p.profile_text NOT LIKE '%beer & wine bartender%'
                     AND p.profile_text NOT LIKE '%beer and wine bartender%'
                     AND p.profile_text NOT LIKE '%bartender - fixed menu%'
                 )
             ) THEN 1
            WHEN c.skill_key = 'beer & wine bartender'
             AND (
                 p.profile_text LIKE '%mixologist%'
                 OR p.profile_text LIKE '%bartender%'
             ) THEN 1
            WHEN c.skill_key = 'barback'
             AND (
                 p.profile_text LIKE '%mixologist%'
                 OR p.profile_text LIKE '%bartender%'
                 OR p.profile_text LIKE '%barback%'
             ) THEN 1
            WHEN c.skill_key = 'housekeeping'
             AND (p.profile_text LIKE '%housekeeping%' OR p.profile_text LIKE '%housekeeper%') THEN 1
            WHEN c.skill_key = 'maintenance'
             AND (
                 p.profile_text LIKE '%housekeeping%'
                 OR p.profile_text LIKE '%housekeeper%'
                 OR p.profile_text LIKE '%maintenance%'
             ) THEN 1
            WHEN c.skill_key = 'general laborer'
             AND (
                 p.profile_text LIKE '%housekeeping%'
                 OR p.profile_text LIKE '%housekeeper%'
                 OR p.profile_text LIKE '%maintenance%'
                 OR p.profile_text LIKE '%general labor%'
                 OR p.profile_text LIKE '%laborer%'
             ) THEN 1
            WHEN c.skill_key = 'general cleaning'
             AND (
                 p.profile_text LIKE '%housekeeping%'
                 OR p.profile_text LIKE '%housekeeper%'
                 OR p.profile_text LIKE '%general cleaning%'
                 OR p.profile_text LIKE '%cleaner%'
                 OR p.profile_text LIKE '%cleaning%'
             ) THEN 1
            WHEN c.skill_key = 'banquet setup'
             AND (
                 p.profile_text LIKE '%housekeeping%'
                 OR p.profile_text LIKE '%housekeeper%'
                 OR p.profile_text LIKE '%general cleaning%'
                 OR p.profile_text LIKE '%cleaner%'
                 OR p.profile_text LIKE '%cleaning%'
                 OR p.profile_text LIKE '%banquet setup%'
                 OR p.profile_text LIKE '%event setup%'
             ) THEN 1
            WHEN c.skill_key = 'barista' AND p.profile_text LIKE '%barista%' THEN 1
            WHEN c.skill_key = 'stage' AND p.profile_text LIKE '%stage%' THEN 1
            WHEN p.profile_text LIKE '%' || LOWER(TRIM(c.skill)) || '%' THEN 1
            ELSE 0
        END AS profile_experience_qualifying_flag,
        CASE c.skill_key
            WHEN 'event chef' THEN COALESCE(p.cert_event_chef, 0)
            WHEN 'banquet cook' THEN GREATEST(COALESCE(p.cert_event_chef, 0), COALESCE(p.cert_event_cook, 0))
            WHEN 'line cook' THEN GREATEST(COALESCE(p.cert_event_chef, 0), COALESCE(p.cert_event_cook, 0), COALESCE(p.cert_line_cook, 0))
            WHEN 'prep cook' THEN GREATEST(COALESCE(p.cert_event_chef, 0), COALESCE(p.cert_event_cook, 0), COALESCE(p.cert_line_cook, 0), COALESCE(p.cert_prep_cook, 0))
            WHEN 'baker/pastry cook' THEN GREATEST(COALESCE(p.cert_event_chef, 0), COALESCE(p.cert_event_cook, 0), COALESCE(p.cert_baker_pastry, 0))
            WHEN 'food assembler' THEN GREATEST(COALESCE(p.cert_event_chef, 0), COALESCE(p.cert_event_cook, 0), COALESCE(p.cert_line_cook, 0), COALESCE(p.cert_prep_cook, 0), COALESCE(p.cert_baker_pastry, 0), COALESCE(p.cert_food_assembler, 0))
            WHEN 'dishwasher' THEN GREATEST(COALESCE(p.cert_event_chef, 0), COALESCE(p.cert_event_cook, 0), COALESCE(p.cert_line_cook, 0), COALESCE(p.cert_prep_cook, 0), COALESCE(p.cert_baker_pastry, 0), COALESCE(p.cert_food_assembler, 0), COALESCE(p.cert_dishwasher, 0))
            WHEN 'banquet captain' THEN COALESCE(p.cert_banquet_captain, 0)
            WHEN 'banquet server' THEN GREATEST(COALESCE(p.cert_banquet_captain, 0), COALESCE(p.cert_event_server, 0))
            WHEN 'restaurant server' THEN GREATEST(COALESCE(p.cert_banquet_captain, 0), COALESCE(p.cert_event_server, 0), COALESCE(p.cert_restaurant_server, 0))
            WHEN 'foh support' THEN GREATEST(COALESCE(p.cert_banquet_captain, 0), COALESCE(p.cert_event_server, 0), COALESCE(p.cert_restaurant_server, 0), COALESCE(p.cert_foh_support, 0))
            WHEN 'concession worker' THEN GREATEST(COALESCE(p.cert_banquet_captain, 0), COALESCE(p.cert_event_server, 0), COALESCE(p.cert_restaurant_server, 0), COALESCE(p.cert_foh_support, 0), COALESCE(p.cert_concession_worker, 0))
            WHEN 'event help' THEN GREATEST(COALESCE(p.cert_banquet_captain, 0), COALESCE(p.cert_event_server, 0), COALESCE(p.cert_restaurant_server, 0), COALESCE(p.cert_foh_support, 0), COALESCE(p.cert_concession_worker, 0), COALESCE(p.cert_event_help, 0))
            WHEN 'server assistant' THEN GREATEST(COALESCE(p.cert_banquet_captain, 0), COALESCE(p.cert_event_server, 0), COALESCE(p.cert_restaurant_server, 0), COALESCE(p.cert_server_assistant, 0))
            WHEN 'food runner' THEN GREATEST(COALESCE(p.cert_banquet_captain, 0), COALESCE(p.cert_event_server, 0), COALESCE(p.cert_restaurant_server, 0), COALESCE(p.cert_server_assistant, 0), COALESCE(p.cert_food_runner, 0))
            WHEN 'coat check attendant' THEN GREATEST(COALESCE(p.cert_banquet_captain, 0), COALESCE(p.cert_event_server, 0), COALESCE(p.cert_restaurant_server, 0), COALESCE(p.cert_server_assistant, 0), COALESCE(p.cert_food_runner, 0), COALESCE(p.cert_coat_check_attendant, 0))
            WHEN 'mixologist' THEN COALESCE(p.cert_mixologist, 0)
            WHEN 'bartender' THEN GREATEST(COALESCE(p.cert_mixologist, 0), COALESCE(p.cert_bartender_full_service, 0))
            WHEN 'beer & wine bartender' THEN GREATEST(COALESCE(p.cert_mixologist, 0), COALESCE(p.cert_bartender_full_service, 0), COALESCE(p.cert_beer_wine, 0), COALESCE(p.cert_fixed_menu, 0))
            WHEN 'barback' THEN GREATEST(COALESCE(p.cert_mixologist, 0), COALESCE(p.cert_bartender_full_service, 0), COALESCE(p.cert_beer_wine, 0), COALESCE(p.cert_fixed_menu, 0), COALESCE(p.cert_barback, 0))
            WHEN 'housekeeping' THEN COALESCE(p.cert_housekeeping, 0)
            WHEN 'maintenance' THEN GREATEST(COALESCE(p.cert_housekeeping, 0), COALESCE(p.cert_maintenance, 0))
            WHEN 'general laborer' THEN GREATEST(COALESCE(p.cert_housekeeping, 0), COALESCE(p.cert_maintenance, 0), COALESCE(p.cert_general_labor, 0))
            WHEN 'general cleaning' THEN GREATEST(COALESCE(p.cert_housekeeping, 0), COALESCE(p.cert_general_cleaning, 0))
            WHEN 'banquet setup' THEN GREATEST(COALESCE(p.cert_housekeeping, 0), COALESCE(p.cert_general_cleaning, 0), COALESCE(p.cert_event_setup, 0))
            WHEN 'barista' THEN COALESCE(p.cert_barista, 0)
            WHEN 'stage' THEN COALESCE(p.cert_stage, 0)
            ELSE NULL
        END AS confirmed_skill_badged_flag
    FROM confirmed_applications c
    LEFT JOIN pro_profiles p
        ON p.pro_id = c.pro_id
)

SELECT
    c.business_name,
    c.location_id,
    c.shift_id,
    c.shift_date,
    c.market,
    c.skill,
    c.requested_pros,
    c.confirmed_pros,
    CASE
        WHEN c.gig_auto_select_enabled = TRUE THEN 'On'
        WHEN c.gig_auto_select_enabled = FALSE THEN 'Off'
        ELSE 'Unknown'
    END AS auto_select_status,
    c.shift_type,
    c.pro_id,
    p.full_name AS pro_name,
    p.phone_number AS pro_phone_number,
    CASE
        WHEN e.profile_experience_qualifying_flag = 1 AND e.confirmed_skill_badged_flag = 1 THEN 'Profile + Badge'
        WHEN e.profile_experience_qualifying_flag = 1 AND e.confirmed_skill_badged_flag = 0 THEN 'Profile Only'
        WHEN e.profile_experience_qualifying_flag = 1 AND e.confirmed_skill_badged_flag IS NULL THEN 'Profile (Badge N/A)'
        WHEN e.profile_experience_qualifying_flag = 0 AND e.confirmed_skill_badged_flag = 1 THEN 'Badge Only'
        WHEN e.profile_experience_qualifying_flag = 0 AND e.confirmed_skill_badged_flag = 0 THEN 'Neither'
        ELSE 'No Profile Match (Badge N/A)'
    END AS confirmed_skill_profile_badge_status,
    COALESCE(x.prior_paid_qualifying_skill_shifts, 0) AS prior_paid_same_skill_shifts,
    CASE WHEN COALESCE(x.prior_paid_qualifying_skill_shifts, 0) > 0 THEN 'Yes' ELSE 'No' END AS has_worked_same_skill_before,
    COALESCE(x.prior_paid_qualifying_skill_shifts_same_business, 0) AS prior_paid_same_skill_shifts_same_business,
    CASE WHEN COALESCE(x.prior_paid_qualifying_skill_shifts_same_business, 0) > 0 THEN 'Yes' ELSE 'No' END AS repeat_same_skill_at_same_business,
    CASE
        WHEN e.profile_experience_qualifying_flag = 1
          OR e.confirmed_skill_badged_flag = 1
          OR COALESCE(x.prior_paid_qualifying_skill_shifts, 0) > 0
        THEN 'Yes'
        ELSE 'No'
    END AS has_relevant_same_skill_experience,
    p.avg_rating,
    p.ratings AS ratings_count,
    ROUND((100.0 * p.completion_percentage)::numeric, 1) AS completion_rate_lifetime_pct,
    ROUND((100.0 * p.completion_percentage_30)::numeric, 1) AS completion_rate_last_30_days_pct,
    p.paid_gigs AS completed_shifts_lifetime,
    p.pro_cancelled_gigs_30 AS pro_cancellations_last_30_days,
    ROUND((100.0 * p.pro_cancel_percentage_30)::numeric, 1) AS pro_cancel_rate_last_30_days_pct,
    p.no_show_gigs_last_30 AS no_shows_last_30_days,
    CASE
        WHEN p.pro_last_lat IS NULL
          OR p.pro_last_long IS NULL
          OR c.location_address_latitude IS NULL
          OR c.location_address_longitude IS NULL
        THEN NULL
        ELSE ROUND((3959.0 * ACOS(LEAST(1.0, GREATEST(-1.0,
            COS(RADIANS(p.pro_last_lat))
            * COS(RADIANS(c.location_address_latitude))
            * COS(RADIANS(c.location_address_longitude) - RADIANS(p.pro_last_long))
            + SIN(RADIANS(p.pro_last_lat))
            * SIN(RADIANS(c.location_address_latitude))
        ))))::numeric, 1)
    END AS distance_from_pro_last_seen_to_business_miles,
    p.pro_last_on AS pro_last_seen_at,
    c.confirmation_timestamp,
    c.selection_source,
    pr.position_avg_rating,
    COALESCE(pr.position_ratings_count, 0) AS position_ratings_count
FROM confirmed_applications c
LEFT JOIN prior_experience x
    ON x.shift_id = c.shift_id
   AND x.pro_id = c.pro_id
LEFT JOIN position_ratings pr
    ON pr.shift_id = c.shift_id
   AND pr.pro_id = c.pro_id
LEFT JOIN pro_skill_evidence e
    ON e.shift_id = c.shift_id
   AND e.pro_id = c.pro_id
LEFT JOIN pro_profiles p
    ON p.pro_id = c.pro_id
ORDER BY
    c.shift_date,
    c.business_name,
    c.shift_id,
    p.full_name;
