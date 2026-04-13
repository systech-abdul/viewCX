local function check_queue_wait(session, queue, high_wait_threshold)
    local api = freeswitch.API()
    high_wait_threshold = high_wait_threshold or 300  -- default 5 minutes

    -- Allow current session to appear in queue
    --if session then session:sleep(200) end  -- 200 ms

    -- =========================
    -- Get Agent Statistics
    -- =========================
    local agent_result = api:execute("callcenter_config", "queue list agents " .. queue)
    local total_calls, total_talk, available_agents = 0, 0, 0

    for line in string.gmatch(agent_result, "[^\n]+") do
        if line ~= "+OK" and not string.find(line, "name|instance_id") then
            local status = string.match(line, "|(Available)|")
            if status == "Available" then
                available_agents = available_agents + 1
            end

            local no_answer_count, calls_answered, talk_time =
                string.match(line, "|(%d+)|(%d+)|(%d+)|%d+|%d+$")

            calls_answered = tonumber(calls_answered)
            talk_time = tonumber(talk_time)
            
            if calls_answered and talk_time then
                total_calls = total_calls + calls_answered
                total_talk = total_talk + talk_time
            end
        end
    end

    -- Average Handling Time
    local aht = 0
    if total_calls > 0 then
        aht = total_talk / total_calls
    end

    -- =========================
    -- Count waiting callers
    -- =========================
    local member_result = api:execute("callcenter_config", "queue list members " .. queue)
    local waiting_calls = 0

    for line in string.gmatch(member_result, "[^\n]+") do
        if line ~= "+OK" and not string.find(line, "queue|instance_id") then
            local fields = {}
            for f in string.gmatch(line, "([^|]*)") do
                table.insert(fields, f)
            end

            local state = fields[16] or ""         -- state column
            local serving_agent = fields[14] or "" -- agent currently serving
              --freeswitch.consoleLog("INFO",string.format("[CallCenter] Queue state =%s \n",state))
            -- Count waiting calls: Trying or newly joined, not bridged
            if (state == "Trying" or state == "") and serving_agent == "" then
                waiting_calls = waiting_calls + 1
            end
        end
    end

    -- =========================
    -- Estimate wait time
    -- =========================
    local estimated_wait = 0
    if available_agents > 0 then
        estimated_wait = (waiting_calls * aht) / available_agents
    end

    freeswitch.consoleLog("INFO",
        string.format("[CallCenter] Queue=%s AHT=%.2f sec Waiting=%d Agents=%d EstimatedWait=%.2f sec\n",
            queue, aht, waiting_calls, available_agents, estimated_wait)
    )

    -- Return true if estimated wait exceeds threshold
    return estimated_wait > high_wait_threshold
end

-- Return function directly so require() works
return check_queue_wait