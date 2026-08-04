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

elevated_shifts AS (
    SELECT
        app.*,
        CASE
            WHEN LOWER(TRIM(app.skill)) IN ('food service worker', 'food assembler') THEN 'food assembler'
            WHEN LOWER(TRIM(app.skill)) IN ('event staff', 'event help') THEN 'event help'
            WHEN LOWER(TRIM(app.skill)) IN ('front of house support', 'front of house support staff', 'foh support') THEN 'foh support'
            WHEN LOWER(TRIM(app.skill)) IN ('coat check', 'coat check attendant') THEN 'coat check attendant'
            WHEN LOWER(TRIM(app.skill)) IN ('baker/pastry cook', 'bakery/pastry cook', 'bakery & pastry cook') THEN 'baker/pastry cook'
            WHEN LOWER(TRIM(app.skill)) IN ('full-service bartender', 'full service bartender', 'bartender') THEN 'bartender'
            WHEN LOWER(TRIM(app.skill)) IN ('beer and wine bartender', 'b&w bartender', 'b+w bartender', 'bartender - fixed menu') THEN 'beer & wine bartender'
            WHEN LOWER(TRIM(app.skill)) IN ('general labor', 'general laborer') THEN 'general laborer'
            ELSE LOWER(TRIM(app.skill))
        END AS skill_key,
        ROW_NUMBER() OVER (
            PARTITION BY app.gigster_id, app.gig_id
            ORDER BY app.confirmation_timestamp DESC NULLS LAST, app.app_id DESC
        ) AS rn
    FROM reporting.mv_core_applications_v3 app
    LEFT JOIN reporting.mv_core_locations_v3 loc
        ON app.location_id = loc.location_id
    WHERE app.is_confirmed = TRUE
      AND loc.currently_elevated_status = 'VIP'
      AND app.gig_start_time_local >= GETDATE()
      AND app.gig_start_time_local < DATEADD(day, 3, GETDATE())
      AND COALESCE(app.is_canceled, 0) = 0
      AND app.gigster_id IS NOT NULL
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

historical_ranked AS (
    SELECT
        gigster_id,
        gig_id,
        rating,
        CASE
            WHEN LOWER(TRIM(skill)) IN ('food service worker', 'food assembler') THEN 'food assembler'
            WHEN LOWER(TRIM(skill)) IN ('event staff', 'event help') THEN 'event help'
            WHEN LOWER(TRIM(skill)) IN ('front of house support', 'front of house support staff', 'foh support') THEN 'foh support'
            WHEN LOWER(TRIM(skill)) IN ('coat check', 'coat check attendant') THEN 'coat check attendant'
            WHEN LOWER(TRIM(skill)) IN ('baker/pastry cook', 'bakery/pastry cook', 'bakery & pastry cook') THEN 'baker/pastry cook'
            WHEN LOWER(TRIM(skill)) IN ('full-service bartender', 'full service bartender', 'bartender') THEN 'bartender'
            WHEN LOWER(TRIM(skill)) IN ('beer and wine bartender', 'b&w bartender', 'b+w bartender', 'bartender - fixed menu') THEN 'beer & wine bartender'
            WHEN LOWER(TRIM(skill)) IN ('general labor', 'general laborer') THEN 'general laborer'
            ELSE LOWER(TRIM(skill))
        END AS skill_key,
        ROW_NUMBER() OVER (
            PARTITION BY gigster_id, gig_id
            ORDER BY rating_timestamp DESC NULLS LAST, app_id DESC
        ) AS hist_rn
    FROM reporting.mv_core_applications_v3
    WHERE is_paid = 1
      AND COALESCE(is_canceled, 0) = 0
      AND gig_start_time_local < GETDATE()
),

prior_position AS (
    SELECT
        gigster_id,
        skill_key,
        COUNT(DISTINCT gig_id) AS prior_paid_same_position_shifts,
        ROUND(AVG(CASE WHEN rating BETWEEN 1 AND 5 THEN rating END)::numeric, 2) AS position_avg_rating,
        COUNT(DISTINCT CASE WHEN rating BETWEEN 1 AND 5 THEN gig_id END) AS position_ratings_count
    FROM historical_ranked
    WHERE hist_rn = 1
    GROUP BY gigster_id, skill_key
),

prior_qualifying AS (
    SELECT
        es.gigster_id,
        es.gig_id,
        COUNT(DISTINCT h.gig_id) AS prior_paid_qualifying_skill_shifts
    FROM elevated_shifts es
    JOIN skill_ladder target
        ON target.skill_key = es.skill_key
    JOIN skill_ladder matched
        ON matched.track = target.track
       AND matched.tier >= target.tier
    LEFT JOIN historical_ranked h
        ON h.gigster_id = es.gigster_id
       AND h.hist_rn = 1
       AND h.skill_key = matched.skill_key
    WHERE es.rn = 1
    GROUP BY es.gigster_id, es.gig_id
),

profile_signals AS (
    SELECT
        es.*,
        pro.full_name,
        pro.phone_number,
        pro.verified_pro,
        pro.avg_rating AS overall_avg_rating,
        pro.ratings AS overall_ratings_count,
        LOWER(COALESCE(pro.experience, '') || ' ' || COALESCE(lp.bio, '')) AS profile_text,
        COALESCE(
            pq.prior_paid_qualifying_skill_shifts,
            pp.prior_paid_same_position_shifts,
            0
        ) AS prior_paid_qualifying_skill_shifts,
        pp.position_avg_rating,
        COALESCE(pp.position_ratings_count, 0) AS position_ratings_count,
        CASE
            WHEN LOWER(COALESCE(pro.experience, '') || ' ' || COALESCE(lp.bio, '')) = '' THEN 0
            WHEN es.skill_key = 'event chef'
             AND LOWER(COALESCE(pro.experience, '') || ' ' || COALESCE(lp.bio, '')) LIKE '%event chef%' THEN 1
            WHEN es.skill_key = 'banquet cook'
             AND (
                 LOWER(COALESCE(pro.experience, '') || ' ' || COALESCE(lp.bio, '')) LIKE '%event chef%'
                 OR LOWER(COALESCE(pro.experience, '') || ' ' || COALESCE(lp.bio, '')) LIKE '%banquet cook%'
                 OR LOWER(COALESCE(pro.experience, '') || ' ' || COALESCE(lp.bio, '')) LIKE '%event cook%'
                 OR LOWER(COALESCE(pro.experience, '') || ' ' || COALESCE(lp.bio, '')) LIKE '%banquet chef%'
             ) THEN 1
            WHEN es.skill_key = 'line cook'
             AND (
                 LOWER(COALESCE(pro.experience, '') || ' ' || COALESCE(lp.bio, '')) LIKE '%event chef%'
                 OR LOWER(COALESCE(pro.experience, '') || ' ' || COALESCE(lp.bio, '')) LIKE '%banquet cook%'
                 OR LOWER(COALESCE(pro.experience, '') || ' ' || COALESCE(lp.bio, '')) LIKE '%event cook%'
                 OR LOWER(COALESCE(pro.experience, '') || ' ' || COALESCE(lp.bio, '')) LIKE '%banquet chef%'
                 OR LOWER(COALESCE(pro.experience, '') || ' ' || COALESCE(lp.bio, '')) LIKE '%line cook%'
             ) THEN 1
            WHEN es.skill_key = 'prep cook'
             AND (
                 LOWER(COALESCE(pro.experience, '') || ' ' || COALESCE(lp.bio, '')) LIKE '%event chef%'
                 OR LOWER(COALESCE(pro.experience, '') || ' ' || COALESCE(lp.bio, '')) LIKE '%banquet cook%'
                 OR LOWER(COALESCE(pro.experience, '') || ' ' || COALESCE(lp.bio, '')) LIKE '%event cook%'
                 OR LOWER(COALESCE(pro.experience, '') || ' ' || COALESCE(lp.bio, '')) LIKE '%banquet chef%'
                 OR LOWER(COALESCE(pro.experience, '') || ' ' || COALESCE(lp.bio, '')) LIKE '%line cook%'
                 OR LOWER(COALESCE(pro.experience, '') || ' ' || COALESCE(lp.bio, '')) LIKE '%prep cook%'
                 OR LOWER(COALESCE(pro.experience, '') || ' ' || COALESCE(lp.bio, '')) LIKE '%food prep%'
             ) THEN 1
            WHEN es.skill_key = 'baker/pastry cook'
             AND (
                 LOWER(COALESCE(pro.experience, '') || ' ' || COALESCE(lp.bio, '')) LIKE '%event chef%'
                 OR LOWER(COALESCE(pro.experience, '') || ' ' || COALESCE(lp.bio, '')) LIKE '%banquet cook%'
                 OR LOWER(COALESCE(pro.experience, '') || ' ' || COALESCE(lp.bio, '')) LIKE '%event cook%'
                 OR LOWER(COALESCE(pro.experience, '') || ' ' || COALESCE(lp.bio, '')) LIKE '%banquet chef%'
                 OR LOWER(COALESCE(pro.experience, '') || ' ' || COALESCE(lp.bio, '')) LIKE '%baker%'
                 OR LOWER(COALESCE(pro.experience, '') || ' ' || COALESCE(lp.bio, '')) LIKE '%bakery%'
                 OR LOWER(COALESCE(pro.experience, '') || ' ' || COALESCE(lp.bio, '')) LIKE '%pastry%'
             ) THEN 1
            WHEN es.skill_key = 'food assembler'
             AND (
                 LOWER(COALESCE(pro.experience, '') || ' ' || COALESCE(lp.bio, '')) LIKE '%event chef%'
                 OR LOWER(COALESCE(pro.experience, '') || ' ' || COALESCE(lp.bio, '')) LIKE '%banquet cook%'
                 OR LOWER(COALESCE(pro.experience, '') || ' ' || COALESCE(lp.bio, '')) LIKE '%event cook%'
                 OR LOWER(COALESCE(pro.experience, '') || ' ' || COALESCE(lp.bio, '')) LIKE '%banquet chef%'
                 OR LOWER(COALESCE(pro.experience, '') || ' ' || COALESCE(lp.bio, '')) LIKE '%line cook%'
                 OR LOWER(COALESCE(pro.experience, '') || ' ' || COALESCE(lp.bio, '')) LIKE '%prep cook%'
                 OR LOWER(COALESCE(pro.experience, '') || ' ' || COALESCE(lp.bio, '')) LIKE '%food prep%'
                 OR LOWER(COALESCE(pro.experience, '') || ' ' || COALESCE(lp.bio, '')) LIKE '%baker%'
                 OR LOWER(COALESCE(pro.experience, '') || ' ' || COALESCE(lp.bio, '')) LIKE '%bakery%'
                 OR LOWER(COALESCE(pro.experience, '') || ' ' || COALESCE(lp.bio, '')) LIKE '%pastry%'
                 OR LOWER(COALESCE(pro.experience, '') || ' ' || COALESCE(lp.bio, '')) LIKE '%food assembler%'
                 OR LOWER(COALESCE(pro.experience, '') || ' ' || COALESCE(lp.bio, '')) LIKE '%food service%'
                 OR LOWER(COALESCE(pro.experience, '') || ' ' || COALESCE(lp.bio, '')) LIKE '%cafeteria%'
             ) THEN 1
            WHEN es.skill_key = 'dishwasher'
             AND (
                 LOWER(COALESCE(pro.experience, '') || ' ' || COALESCE(lp.bio, '')) LIKE '%event chef%'
                 OR LOWER(COALESCE(pro.experience, '') || ' ' || COALESCE(lp.bio, '')) LIKE '%banquet cook%'
                 OR LOWER(COALESCE(pro.experience, '') || ' ' || COALESCE(lp.bio, '')) LIKE '%event cook%'
                 OR LOWER(COALESCE(pro.experience, '') || ' ' || COALESCE(lp.bio, '')) LIKE '%banquet chef%'
                 OR LOWER(COALESCE(pro.experience, '') || ' ' || COALESCE(lp.bio, '')) LIKE '%line cook%'
                 OR LOWER(COALESCE(pro.experience, '') || ' ' || COALESCE(lp.bio, '')) LIKE '%prep cook%'
                 OR LOWER(COALESCE(pro.experience, '') || ' ' || COALESCE(lp.bio, '')) LIKE '%food prep%'
                 OR LOWER(COALESCE(pro.experience, '') || ' ' || COALESCE(lp.bio, '')) LIKE '%baker%'
                 OR LOWER(COALESCE(pro.experience, '') || ' ' || COALESCE(lp.bio, '')) LIKE '%bakery%'
                 OR LOWER(COALESCE(pro.experience, '') || ' ' || COALESCE(lp.bio, '')) LIKE '%pastry%'
                 OR LOWER(COALESCE(pro.experience, '') || ' ' || COALESCE(lp.bio, '')) LIKE '%food assembler%'
                 OR LOWER(COALESCE(pro.experience, '') || ' ' || COALESCE(lp.bio, '')) LIKE '%food service%'
                 OR LOWER(COALESCE(pro.experience, '') || ' ' || COALESCE(lp.bio, '')) LIKE '%cafeteria%'
                 OR LOWER(COALESCE(pro.experience, '') || ' ' || COALESCE(lp.bio, '')) LIKE '%dishwasher%'
                 OR LOWER(COALESCE(pro.experience, '') || ' ' || COALESCE(lp.bio, '')) LIKE '%dish washer%'
                 OR LOWER(COALESCE(pro.experience, '') || ' ' || COALESCE(lp.bio, '')) LIKE '%dishwashing%'
             ) THEN 1
            WHEN es.skill_key = 'banquet captain'
             AND LOWER(COALESCE(pro.experience, '') || ' ' || COALESCE(lp.bio, '')) LIKE '%banquet captain%' THEN 1
            WHEN es.skill_key = 'banquet server'
             AND (
                 LOWER(COALESCE(pro.experience, '') || ' ' || COALESCE(lp.bio, '')) LIKE '%banquet captain%'
                 OR LOWER(COALESCE(pro.experience, '') || ' ' || COALESCE(lp.bio, '')) LIKE '%banquet server%'
                 OR LOWER(COALESCE(pro.experience, '') || ' ' || COALESCE(lp.bio, '')) LIKE '%event server%'
             ) THEN 1
            WHEN es.skill_key = 'restaurant server'
             AND (
                 LOWER(COALESCE(pro.experience, '') || ' ' || COALESCE(lp.bio, '')) LIKE '%banquet captain%'
                 OR LOWER(COALESCE(pro.experience, '') || ' ' || COALESCE(lp.bio, '')) LIKE '%banquet server%'
                 OR LOWER(COALESCE(pro.experience, '') || ' ' || COALESCE(lp.bio, '')) LIKE '%event server%'
                 OR LOWER(COALESCE(pro.experience, '') || ' ' || COALESCE(lp.bio, '')) LIKE '%restaurant server%'
             ) THEN 1
            WHEN es.skill_key = 'foh support'
             AND (
                 LOWER(COALESCE(pro.experience, '') || ' ' || COALESCE(lp.bio, '')) LIKE '%banquet captain%'
                 OR LOWER(COALESCE(pro.experience, '') || ' ' || COALESCE(lp.bio, '')) LIKE '%banquet server%'
                 OR LOWER(COALESCE(pro.experience, '') || ' ' || COALESCE(lp.bio, '')) LIKE '%event server%'
                 OR LOWER(COALESCE(pro.experience, '') || ' ' || COALESCE(lp.bio, '')) LIKE '%restaurant server%'
                 OR LOWER(COALESCE(pro.experience, '') || ' ' || COALESCE(lp.bio, '')) LIKE '%foh support%'
                 OR LOWER(COALESCE(pro.experience, '') || ' ' || COALESCE(lp.bio, '')) LIKE '%front of house%'
             ) THEN 1
            WHEN es.skill_key = 'concession worker'
             AND (
                 LOWER(COALESCE(pro.experience, '') || ' ' || COALESCE(lp.bio, '')) LIKE '%banquet captain%'
                 OR LOWER(COALESCE(pro.experience, '') || ' ' || COALESCE(lp.bio, '')) LIKE '%banquet server%'
                 OR LOWER(COALESCE(pro.experience, '') || ' ' || COALESCE(lp.bio, '')) LIKE '%event server%'
                 OR LOWER(COALESCE(pro.experience, '') || ' ' || COALESCE(lp.bio, '')) LIKE '%restaurant server%'
                 OR LOWER(COALESCE(pro.experience, '') || ' ' || COALESCE(lp.bio, '')) LIKE '%foh support%'
                 OR LOWER(COALESCE(pro.experience, '') || ' ' || COALESCE(lp.bio, '')) LIKE '%front of house%'
                 OR LOWER(COALESCE(pro.experience, '') || ' ' || COALESCE(lp.bio, '')) LIKE '%concession%'
             ) THEN 1
            WHEN es.skill_key = 'event help'
             AND (
                 LOWER(COALESCE(pro.experience, '') || ' ' || COALESCE(lp.bio, '')) LIKE '%banquet captain%'
                 OR LOWER(COALESCE(pro.experience, '') || ' ' || COALESCE(lp.bio, '')) LIKE '%banquet server%'
                 OR LOWER(COALESCE(pro.experience, '') || ' ' || COALESCE(lp.bio, '')) LIKE '%event server%'
                 OR LOWER(COALESCE(pro.experience, '') || ' ' || COALESCE(lp.bio, '')) LIKE '%restaurant server%'
                 OR LOWER(COALESCE(pro.experience, '') || ' ' || COALESCE(lp.bio, '')) LIKE '%foh support%'
                 OR LOWER(COALESCE(pro.experience, '') || ' ' || COALESCE(lp.bio, '')) LIKE '%front of house%'
                 OR LOWER(COALESCE(pro.experience, '') || ' ' || COALESCE(lp.bio, '')) LIKE '%concession%'
                 OR LOWER(COALESCE(pro.experience, '') || ' ' || COALESCE(lp.bio, '')) LIKE '%event help%'
                 OR LOWER(COALESCE(pro.experience, '') || ' ' || COALESCE(lp.bio, '')) LIKE '%event staff%'
             ) THEN 1
            WHEN es.skill_key = 'server assistant'
             AND (
                 LOWER(COALESCE(pro.experience, '') || ' ' || COALESCE(lp.bio, '')) LIKE '%banquet captain%'
                 OR LOWER(COALESCE(pro.experience, '') || ' ' || COALESCE(lp.bio, '')) LIKE '%banquet server%'
                 OR LOWER(COALESCE(pro.experience, '') || ' ' || COALESCE(lp.bio, '')) LIKE '%event server%'
                 OR LOWER(COALESCE(pro.experience, '') || ' ' || COALESCE(lp.bio, '')) LIKE '%restaurant server%'
                 OR LOWER(COALESCE(pro.experience, '') || ' ' || COALESCE(lp.bio, '')) LIKE '%server assistant%'
             ) THEN 1
            WHEN es.skill_key = 'food runner'
             AND (
                 LOWER(COALESCE(pro.experience, '') || ' ' || COALESCE(lp.bio, '')) LIKE '%banquet captain%'
                 OR LOWER(COALESCE(pro.experience, '') || ' ' || COALESCE(lp.bio, '')) LIKE '%banquet server%'
                 OR LOWER(COALESCE(pro.experience, '') || ' ' || COALESCE(lp.bio, '')) LIKE '%event server%'
                 OR LOWER(COALESCE(pro.experience, '') || ' ' || COALESCE(lp.bio, '')) LIKE '%restaurant server%'
                 OR LOWER(COALESCE(pro.experience, '') || ' ' || COALESCE(lp.bio, '')) LIKE '%server assistant%'
                 OR LOWER(COALESCE(pro.experience, '') || ' ' || COALESCE(lp.bio, '')) LIKE '%food runner%'
             ) THEN 1
            WHEN es.skill_key = 'coat check attendant'
             AND (
                 LOWER(COALESCE(pro.experience, '') || ' ' || COALESCE(lp.bio, '')) LIKE '%banquet captain%'
                 OR LOWER(COALESCE(pro.experience, '') || ' ' || COALESCE(lp.bio, '')) LIKE '%banquet server%'
                 OR LOWER(COALESCE(pro.experience, '') || ' ' || COALESCE(lp.bio, '')) LIKE '%event server%'
                 OR LOWER(COALESCE(pro.experience, '') || ' ' || COALESCE(lp.bio, '')) LIKE '%restaurant server%'
                 OR LOWER(COALESCE(pro.experience, '') || ' ' || COALESCE(lp.bio, '')) LIKE '%server assistant%'
                 OR LOWER(COALESCE(pro.experience, '') || ' ' || COALESCE(lp.bio, '')) LIKE '%food runner%'
                 OR LOWER(COALESCE(pro.experience, '') || ' ' || COALESCE(lp.bio, '')) LIKE '%coat check%'
             ) THEN 1
            WHEN es.skill_key = 'mixologist'
             AND LOWER(COALESCE(pro.experience, '') || ' ' || COALESCE(lp.bio, '')) LIKE '%mixologist%' THEN 1
            WHEN es.skill_key = 'bartender'
             AND (
                 LOWER(COALESCE(pro.experience, '') || ' ' || COALESCE(lp.bio, '')) LIKE '%mixologist%'
                 OR LOWER(COALESCE(pro.experience, '') || ' ' || COALESCE(lp.bio, '')) LIKE '%full-service bartender%'
                 OR LOWER(COALESCE(pro.experience, '') || ' ' || COALESCE(lp.bio, '')) LIKE '%full service bartender%'
                 OR (
                     LOWER(COALESCE(pro.experience, '') || ' ' || COALESCE(lp.bio, '')) LIKE '%bartender%'
                     AND LOWER(COALESCE(pro.experience, '') || ' ' || COALESCE(lp.bio, '')) NOT LIKE '%beer & wine bartender%'
                     AND LOWER(COALESCE(pro.experience, '') || ' ' || COALESCE(lp.bio, '')) NOT LIKE '%beer and wine bartender%'
                     AND LOWER(COALESCE(pro.experience, '') || ' ' || COALESCE(lp.bio, '')) NOT LIKE '%bartender - fixed menu%'
                 )
             ) THEN 1
            WHEN es.skill_key = 'beer & wine bartender'
             AND (
                 LOWER(COALESCE(pro.experience, '') || ' ' || COALESCE(lp.bio, '')) LIKE '%mixologist%'
                 OR LOWER(COALESCE(pro.experience, '') || ' ' || COALESCE(lp.bio, '')) LIKE '%bartender%'
             ) THEN 1
            WHEN es.skill_key = 'barback'
             AND (
                 LOWER(COALESCE(pro.experience, '') || ' ' || COALESCE(lp.bio, '')) LIKE '%mixologist%'
                 OR LOWER(COALESCE(pro.experience, '') || ' ' || COALESCE(lp.bio, '')) LIKE '%bartender%'
                 OR LOWER(COALESCE(pro.experience, '') || ' ' || COALESCE(lp.bio, '')) LIKE '%barback%'
             ) THEN 1
            WHEN es.skill_key = 'housekeeping'
             AND (
                 LOWER(COALESCE(pro.experience, '') || ' ' || COALESCE(lp.bio, '')) LIKE '%housekeeping%'
                 OR LOWER(COALESCE(pro.experience, '') || ' ' || COALESCE(lp.bio, '')) LIKE '%housekeeper%'
             ) THEN 1
            WHEN es.skill_key = 'maintenance'
             AND (
                 LOWER(COALESCE(pro.experience, '') || ' ' || COALESCE(lp.bio, '')) LIKE '%housekeeping%'
                 OR LOWER(COALESCE(pro.experience, '') || ' ' || COALESCE(lp.bio, '')) LIKE '%housekeeper%'
                 OR LOWER(COALESCE(pro.experience, '') || ' ' || COALESCE(lp.bio, '')) LIKE '%maintenance%'
             ) THEN 1
            WHEN es.skill_key = 'general laborer'
             AND (
                 LOWER(COALESCE(pro.experience, '') || ' ' || COALESCE(lp.bio, '')) LIKE '%housekeeping%'
                 OR LOWER(COALESCE(pro.experience, '') || ' ' || COALESCE(lp.bio, '')) LIKE '%housekeeper%'
                 OR LOWER(COALESCE(pro.experience, '') || ' ' || COALESCE(lp.bio, '')) LIKE '%maintenance%'
                 OR LOWER(COALESCE(pro.experience, '') || ' ' || COALESCE(lp.bio, '')) LIKE '%general labor%'
                 OR LOWER(COALESCE(pro.experience, '') || ' ' || COALESCE(lp.bio, '')) LIKE '%laborer%'
             ) THEN 1
            WHEN es.skill_key = 'general cleaning'
             AND (
                 LOWER(COALESCE(pro.experience, '') || ' ' || COALESCE(lp.bio, '')) LIKE '%housekeeping%'
                 OR LOWER(COALESCE(pro.experience, '') || ' ' || COALESCE(lp.bio, '')) LIKE '%housekeeper%'
                 OR LOWER(COALESCE(pro.experience, '') || ' ' || COALESCE(lp.bio, '')) LIKE '%general cleaning%'
                 OR LOWER(COALESCE(pro.experience, '') || ' ' || COALESCE(lp.bio, '')) LIKE '%cleaner%'
                 OR LOWER(COALESCE(pro.experience, '') || ' ' || COALESCE(lp.bio, '')) LIKE '%cleaning%'
             ) THEN 1
            WHEN es.skill_key = 'banquet setup'
             AND (
                 LOWER(COALESCE(pro.experience, '') || ' ' || COALESCE(lp.bio, '')) LIKE '%housekeeping%'
                 OR LOWER(COALESCE(pro.experience, '') || ' ' || COALESCE(lp.bio, '')) LIKE '%housekeeper%'
                 OR LOWER(COALESCE(pro.experience, '') || ' ' || COALESCE(lp.bio, '')) LIKE '%general cleaning%'
                 OR LOWER(COALESCE(pro.experience, '') || ' ' || COALESCE(lp.bio, '')) LIKE '%cleaner%'
                 OR LOWER(COALESCE(pro.experience, '') || ' ' || COALESCE(lp.bio, '')) LIKE '%cleaning%'
                 OR LOWER(COALESCE(pro.experience, '') || ' ' || COALESCE(lp.bio, '')) LIKE '%banquet setup%'
                 OR LOWER(COALESCE(pro.experience, '') || ' ' || COALESCE(lp.bio, '')) LIKE '%event setup%'
             ) THEN 1
            WHEN es.skill_key = 'barista'
             AND LOWER(COALESCE(pro.experience, '') || ' ' || COALESCE(lp.bio, '')) LIKE '%barista%' THEN 1
            WHEN es.skill_key = 'stage'
             AND LOWER(COALESCE(pro.experience, '') || ' ' || COALESCE(lp.bio, '')) LIKE '%stage%' THEN 1
            WHEN LOWER(COALESCE(pro.experience, '') || ' ' || COALESCE(lp.bio, '')) LIKE '%' || LOWER(TRIM(es.skill)) || '%' THEN 1
            ELSE 0
        END AS profile_experience_qualifying_flag,
        CASE es.skill_key
            WHEN 'event chef' THEN COALESCE(pro.cert_event_chef, 0)
            WHEN 'banquet cook' THEN GREATEST(COALESCE(pro.cert_event_chef, 0), COALESCE(pro.cert_event_cook, 0))
            WHEN 'line cook' THEN GREATEST(COALESCE(pro.cert_event_chef, 0), COALESCE(pro.cert_event_cook, 0), COALESCE(pro.cert_line_cook, 0))
            WHEN 'prep cook' THEN GREATEST(COALESCE(pro.cert_event_chef, 0), COALESCE(pro.cert_event_cook, 0), COALESCE(pro.cert_line_cook, 0), COALESCE(pro.cert_prep_cook, 0))
            WHEN 'baker/pastry cook' THEN GREATEST(COALESCE(pro.cert_event_chef, 0), COALESCE(pro.cert_event_cook, 0), COALESCE(pro.cert_baker_pastry, 0))
            WHEN 'food assembler' THEN GREATEST(COALESCE(pro.cert_event_chef, 0), COALESCE(pro.cert_event_cook, 0), COALESCE(pro.cert_line_cook, 0), COALESCE(pro.cert_prep_cook, 0), COALESCE(pro.cert_baker_pastry, 0), COALESCE(pro.cert_food_assembler, 0))
            WHEN 'dishwasher' THEN GREATEST(COALESCE(pro.cert_event_chef, 0), COALESCE(pro.cert_event_cook, 0), COALESCE(pro.cert_line_cook, 0), COALESCE(pro.cert_prep_cook, 0), COALESCE(pro.cert_baker_pastry, 0), COALESCE(pro.cert_food_assembler, 0), COALESCE(pro.cert_dishwasher, 0))
            WHEN 'banquet captain' THEN COALESCE(pro.cert_banquet_captain, 0)
            WHEN 'banquet server' THEN GREATEST(COALESCE(pro.cert_banquet_captain, 0), COALESCE(pro.cert_event_server, 0))
            WHEN 'restaurant server' THEN GREATEST(COALESCE(pro.cert_banquet_captain, 0), COALESCE(pro.cert_event_server, 0), COALESCE(pro.cert_restaurant_server, 0))
            WHEN 'foh support' THEN GREATEST(COALESCE(pro.cert_banquet_captain, 0), COALESCE(pro.cert_event_server, 0), COALESCE(pro.cert_restaurant_server, 0), COALESCE(pro.cert_foh_support, 0))
            WHEN 'concession worker' THEN GREATEST(COALESCE(pro.cert_banquet_captain, 0), COALESCE(pro.cert_event_server, 0), COALESCE(pro.cert_restaurant_server, 0), COALESCE(pro.cert_foh_support, 0), COALESCE(pro.cert_concession_worker, 0))
            WHEN 'event help' THEN GREATEST(COALESCE(pro.cert_banquet_captain, 0), COALESCE(pro.cert_event_server, 0), COALESCE(pro.cert_restaurant_server, 0), COALESCE(pro.cert_foh_support, 0), COALESCE(pro.cert_concession_worker, 0), COALESCE(pro.cert_event_help, 0))
            WHEN 'server assistant' THEN GREATEST(COALESCE(pro.cert_banquet_captain, 0), COALESCE(pro.cert_event_server, 0), COALESCE(pro.cert_restaurant_server, 0), COALESCE(pro.cert_server_assistant, 0))
            WHEN 'food runner' THEN GREATEST(COALESCE(pro.cert_banquet_captain, 0), COALESCE(pro.cert_event_server, 0), COALESCE(pro.cert_restaurant_server, 0), COALESCE(pro.cert_server_assistant, 0), COALESCE(pro.cert_food_runner, 0))
            WHEN 'coat check attendant' THEN GREATEST(COALESCE(pro.cert_banquet_captain, 0), COALESCE(pro.cert_event_server, 0), COALESCE(pro.cert_restaurant_server, 0), COALESCE(pro.cert_server_assistant, 0), COALESCE(pro.cert_food_runner, 0), COALESCE(pro.cert_coat_check_attendant, 0))
            WHEN 'mixologist' THEN COALESCE(pro.cert_mixologist, 0)
            WHEN 'bartender' THEN GREATEST(COALESCE(pro.cert_mixologist, 0), COALESCE(pro.cert_bartender_full_service, 0))
            WHEN 'beer & wine bartender' THEN GREATEST(COALESCE(pro.cert_mixologist, 0), COALESCE(pro.cert_bartender_full_service, 0), COALESCE(pro.cert_beer_wine, 0), COALESCE(pro.cert_fixed_menu, 0))
            WHEN 'barback' THEN GREATEST(COALESCE(pro.cert_mixologist, 0), COALESCE(pro.cert_bartender_full_service, 0), COALESCE(pro.cert_beer_wine, 0), COALESCE(pro.cert_fixed_menu, 0), COALESCE(pro.cert_barback, 0))
            WHEN 'housekeeping' THEN COALESCE(pro.cert_housekeeping, 0)
            WHEN 'maintenance' THEN GREATEST(COALESCE(pro.cert_housekeeping, 0), COALESCE(pro.cert_maintenance, 0))
            WHEN 'general laborer' THEN GREATEST(COALESCE(pro.cert_housekeeping, 0), COALESCE(pro.cert_maintenance, 0), COALESCE(pro.cert_general_labor, 0))
            WHEN 'general cleaning' THEN GREATEST(COALESCE(pro.cert_housekeeping, 0), COALESCE(pro.cert_general_cleaning, 0))
            WHEN 'banquet setup' THEN GREATEST(COALESCE(pro.cert_housekeeping, 0), COALESCE(pro.cert_general_cleaning, 0), COALESCE(pro.cert_event_setup, 0))
            WHEN 'barista' THEN COALESCE(pro.cert_barista, 0)
            WHEN 'stage' THEN COALESCE(pro.cert_stage, 0)
            ELSE NULL
        END AS cert_qualifying_flag
    FROM elevated_shifts es
    LEFT JOIN reporting.mv_pro_snapshot_v3 pro
        ON es.gigster_id = pro.pro_id
    LEFT JOIN latest_profiles lp
        ON es.gigster_id = lp.user_id
       AND lp.rn = 1
    LEFT JOIN prior_position pp
        ON es.gigster_id = pp.gigster_id
       AND es.skill_key = pp.skill_key
    LEFT JOIN prior_qualifying pq
        ON es.gigster_id = pq.gigster_id
       AND es.gig_id = pq.gig_id
    WHERE es.rn = 1
),

evaluated AS (
    SELECT
        ps.*,
        CASE
            WHEN profile_experience_qualifying_flag = 1 THEN 'Profile experience (same or higher tier)'
            WHEN cert_qualifying_flag = 1 THEN 'Profile skill/certification (same or higher tier)'
            ELSE 'No match'
        END AS profile_match_source
    FROM profile_signals ps
)

SELECT
    gig_id || '-' || gigster_id AS row_key,
    full_name AS pro_name,
    phone_number AS pro_phone_number,
    CASE
        WHEN COALESCE(outreached, 0) = 0 THEN 'Not outreached'
        WHEN outreach_pro_response = 1 THEN 'Pro responded'
        ELSE 'No pro response'
    END AS outreach_status,
    CASE WHEN verified_pro = TRUE THEN 'Verified' ELSE 'Unverified' END AS verified_status,
    ROUND(EXTRACT(EPOCH FROM (gig_start_time_local - GETDATE())) / 3600.0, 2) AS hours_to_start,
    gig_start_time_local AS start_time,
    location_name,
    market,
    skill AS skillset_type,
    '=HYPERLINK("https://biz.qwick.com/locations/' || location_id || '/gigs/' || gig_id || '/applicants", "Shift Link")' AS shift_url,
    gigster_id AS pro_id,
    gig_id,
    CASE WHEN profile_match_source = 'No match' THEN 'No' ELSE 'Yes' END AS has_matching_profile_skill,
    profile_match_source,
    prior_paid_qualifying_skill_shifts AS prior_paid_same_skill_shifts,
    position_avg_rating,
    position_ratings_count,
    overall_avg_rating,
    overall_ratings_count,
    CASE
        WHEN position_ratings_count > 0 AND position_avg_rating < 4.0 THEN 'Yes'
        ELSE 'No'
    END AS poor_position_rating,
    CASE
        WHEN profile_match_source = 'No match' AND prior_paid_qualifying_skill_shifts = 0
        THEN 'No same- or higher-tier profile experience/certification and no prior paid qualifying shifts'
        WHEN position_ratings_count > 0 AND position_avg_rating < 4.0
        THEN 'Poor prior ' || skill || ' rating: ' || position_avg_rating || ' across ' || position_ratings_count || ' rated shifts'
        ELSE 'Qualified - no outreach'
    END AS qualification_gap
FROM evaluated
ORDER BY gig_start_time_local ASC, location_name, gig_id, full_name;
