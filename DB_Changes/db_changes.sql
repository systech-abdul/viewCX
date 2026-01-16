--22/22/2025

CREATE OR REPLACE FUNCTION public.fn_did_routing(p_did_num text, p_src_regex_pattern text, p_caller_ip text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE
AS $function$
DECLARE
    v_result JSONB;
    v_row    RECORD;
BEGIN
    -- Find the best matching DID route
    FOR v_row IN
        SELECT 
            r.did_route_uuid,
            r.tenant_id,
            r.process_id,
            r.domain_uuid,
            d.domain_name,
            COALESCE(r.time_zone, 'UTC') AS time_zone,
            r.routing_logic,
            r.failover_destination,
            r.failover_type,
            r.src_regex_pattern,
            r.ip_check,
            r.days
        FROM v_did_routes r
        JOIN v_domains d ON d.domain_uuid = r.domain_uuid
        WHERE r.did_num = p_did_num
          AND r.enabled = true

          -- SRC pattern matching: *, exact, or comma list
          AND (
                r.src_regex_pattern = '*'
             OR r.src_regex_pattern = p_src_regex_pattern
             OR string_to_array(REPLACE(r.src_regex_pattern, '+', ''), ',') 
                && ARRAY[REPLACE(p_src_regex_pattern, '+', '')]
          )

          -- IP partial match (safe for INET/CIDR → TEXT)
          AND (
                r.ip_check IS NULL
             OR p_caller_ip IS NULL
             OR host(r.ip_check)::TEXT LIKE '%' || p_caller_ip || '%'
          )

        ORDER BY
            CASE 
                WHEN r.src_regex_pattern = p_src_regex_pattern THEN 1
                WHEN string_to_array(REPLACE(r.src_regex_pattern, '+', ''), ',') 
                     && ARRAY[REPLACE(p_src_regex_pattern, '+', '')] THEN 2
                WHEN r.src_regex_pattern = '*' THEN 3
                ELSE 4
            END ASC,
            r.created_at DESC
        LIMIT 1
    LOOP

        -- Use the route's own time_zone
        DECLARE
            v_tz               TEXT := COALESCE(v_row.time_zone, 'UTC');

            -- *** KEY CHANGE: compute "now" in that time zone ***
            v_now_local        TIMESTAMP := (now() AT TIME ZONE v_tz);
            v_current_day_abbr TEXT      := lower(to_char(v_now_local, 'Dy'));
            v_current_time     TIME      := v_now_local::TIME;

            v_match_type       TEXT;
            v_active_today     BOOLEAN := false;
            v_matched_logic    JSONB  := NULL;
            v_destination      TEXT;
            v_destination_type TEXT;
            v_route_type       TEXT  := 'failover';
        BEGIN

            -- 1. Match type
            v_match_type := CASE
                WHEN v_row.src_regex_pattern = '*' THEN 'matched_star'
                WHEN string_to_array(REPLACE(v_row.src_regex_pattern, '+', ''), ',') 
                     && ARRAY[REPLACE(p_src_regex_pattern, '+', '')]
                     AND (v_row.ip_check IS NULL OR p_caller_ip IS NULL 
                          OR host(v_row.ip_check)::TEXT LIKE '%' || p_caller_ip || '%')
                     THEN 'match_both_src_and_caler_ip'
                WHEN string_to_array(REPLACE(v_row.src_regex_pattern, '+', ''), ',') 
                     && ARRAY[REPLACE(p_src_regex_pattern, '+', '')]
                     THEN 'matched_src'
                ELSE 'no_match'
            END;

            -- 2. Active today? (day check in route's timezone)
            v_active_today := COALESCE(
                v_row.days IS NULL 
                OR v_row.days = 'null'::jsonb 
                OR (jsonb_typeof(v_row.days) = 'array' AND jsonb_array_length(v_row.days) = 0)
                OR EXISTS (
                    SELECT 1 FROM jsonb_array_elements_text(v_row.days) d
                    WHERE left(lower(d.value), 3) = v_current_day_abbr
                ),
                false
            );

            -- 3. Try to match routing_logic (with overnight support!)
            IF v_row.routing_logic IS NOT NULL 
               AND jsonb_typeof(v_row.routing_logic) = 'array' 
               AND jsonb_array_length(v_row.routing_logic) > 0 THEN

                SELECT jsonb_build_object(
                    'destination_type', el->>'destination_type',
                    'destination',      el->>'destination'
                )
                INTO v_matched_logic
                FROM jsonb_array_elements(v_row.routing_logic) el
                WHERE (
                    NOT (el ? 'days')
                    OR jsonb_typeof(el->'days') != 'array'
                    OR jsonb_array_length(el->'days') = 0
                    OR EXISTS (
                        SELECT 1 FROM jsonb_array_elements_text(el->'days') d
                        WHERE left(lower(d.value), 3) = v_current_day_abbr
                    )
                )
                AND (
                    el->>'start_time' IS NULL OR el->>'start_time' = ''
                    OR el->>'end_time' IS NULL   OR el->>'end_time'   = ''
                    OR (
                        (el->>'start_time')::TIME <= (el->>'end_time')::TIME
                        AND v_current_time >= (el->>'start_time')::TIME
                        AND v_current_time <= (el->>'end_time')::TIME
                    )
                    OR (
                        (el->>'start_time')::TIME > (el->>'end_time')::TIME
                        AND (
                            v_current_time >= (el->>'start_time')::TIME
                            OR v_current_time <= (el->>'end_time')::TIME
                        )
                    )
                )
                ORDER BY COALESCE((el->>'order')::INT, 999) ASC
                LIMIT 1;

                IF v_matched_logic IS NOT NULL THEN
                    v_route_type       := 'routing';
                    v_destination      := v_matched_logic->>'destination';
                    v_destination_type := v_matched_logic->>'destination_type';
                END IF;
            END IF;

            -- 4. Fallback to failover
            IF v_route_type = 'failover' THEN
                v_destination      := v_row.failover_destination;
                v_destination_type := v_row.failover_type;
            END IF;

            -- 5. Final response
            v_result := jsonb_build_object(
                'match_type',            v_match_type,
                'active_today',          v_active_today,
                'route_type',            v_route_type,
                'destination_type',      v_destination_type,
                'destination',           v_destination,
                'did_route_uuid',        v_row.did_route_uuid,
                'tenant_id',             v_row.tenant_id,
                'process_id',            v_row.process_id,
                'domain_uuid',           v_row.domain_uuid,
                'domain_name',           v_row.domain_name,
                'time_zone',             v_tz,
                'matched_routing_logic', v_matched_logic,
                'failover_destination',  CASE 
                    WHEN v_route_type = 'failover' 
                    THEN jsonb_build_object(
                        'destination', v_row.failover_destination,
                        'destination_type', v_row.failover_type
                    )
                    ELSE NULL 
                END
            );

            RETURN v_result;
        END;
    END LOOP;

    -- No route found
    RETURN jsonb_build_object(
        'match_type',            'no_match',
        'active_today',          false,
        'route_type',            NULL,
        'destination_type',      NULL,
        'destination',           NULL,
        'did_route_uuid',        NULL,
        'tenant_id',             NULL,
        'process_id',            NULL,
        'domain_uuid',           NULL,
        'domain_name',           NULL,
        'time_zone',             NULL,
        'matched_routing_logic', NULL,
        'failover_destination',  NULL
    );

END;
$function$
