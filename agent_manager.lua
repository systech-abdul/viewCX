-- agent_manager.lua

local Database = require "resources.functions.database"
local dbh = Database.new("system")
assert(dbh:connected())

local M = {}

-- Generate a UUID
local function uuid()
	local result
	dbh:query("SELECT uuid() as uuid", function(row)
		result = row.uuid
	end)
	return result
end

-- Execute a SQL query with logging
local function execute(sql)
	freeswitch.consoleLog("info", "[QueueManager] SQL: " .. sql .. "\n")
	assert(dbh:query(sql))
end

-- ====================
-- QUEUE FUNCTIONS CRUD
-- ====================

-- Insert a new queue
function M.insert_queue(params)
	local queue_uuid = params.call_center_queue_uuid or uuid()

	local sql = string.format([[
		INSERT INTO v_call_center_queues (
			call_center_queue_uuid, domain_uuid, dialplan_uuid,
			queue_name, queue_extension, queue_greeting,
			queue_strategy, queue_moh_sound, queue_record_template,
			queue_time_base_score, queue_time_base_score_sec,
			queue_max_wait_time, queue_max_wait_time_with_no_agent,
			queue_max_wait_time_with_no_agent_time_reached,
			queue_tier_rules_apply, queue_tier_rule_wait_second,
			queue_tier_rule_no_agent_no_wait, queue_timeout_action,
			queue_discard_abandoned_after, queue_abandoned_resume_allowed,
			queue_tier_rule_wait_multiply_level, queue_cid_prefix,
			queue_outbound_caller_id_name, queue_outbound_caller_id_number,
			queue_announce_position, queue_announce_sound,
			queue_announce_frequency, queue_cc_exit_keys,
			queue_email_address, queue_context, queue_description,
			queue_flow_json, agent_log
		) VALUES (
			'%s', '%s', '%s',
			'%s', '%s', '%s',
			'%s', '%s', '%s',
			'%s', %s,
			%s, %s,
			%s, '%s',
			'%s', '%s',
			%s, '%s',
			'%s', '%s',
			'%s', '%s',
			'%s', '%s',
			%s, '%s',
			'%s', '%s', '%s',
			'%s', %s
		)
	]], 
		queue_uuid, params.domain_uuid or "NULL", params.dialplan_uuid or "NULL",
		params.queue_name, params.queue_extension or '', params.queue_greeting or '',
		params.queue_strategy or '', params.queue_moh_sound or '', params.queue_record_template or '',
		params.queue_time_base_score or '', params.queue_time_base_score_sec or "NULL",
		params.queue_max_wait_time or "NULL", params.queue_max_wait_time_with_no_agent or "NULL",
		params.queue_max_wait_time_with_no_agent_time_reached or "NULL",
		params.queue_tier_rules_apply or '', params.queue_tier_rule_wait_second or "NULL",
		params.queue_tier_rule_no_agent_no_wait or '', params.queue_timeout_action or '',
		params.queue_discard_abandoned_after or "NULL", params.queue_abandoned_resume_allowed or '',
		params.queue_tier_rule_wait_multiply_level or '', params.queue_cid_prefix or '',
		params.queue_outbound_caller_id_name or '', params.queue_outbound_caller_id_number or '',
		params.queue_announce_position or '', params.queue_announce_sound or '',
		params.queue_announce_frequency or "NULL", params.queue_cc_exit_keys or '',
		params.queue_email_address or '', params.queue_context or '', params.queue_description or '',
		params.queue_flow_json or '{}', tostring(params.agent_log or true)
	)

	execute(sql)
	freeswitch.api("callcenter_config", "reload")
	return queue_uuid
end

-- Update existing queue by UUID
function M.update_queue(params)
	assert(params.call_center_queue_uuid, "call_center_queue_uuid required")

	local sql = string.format([[
		UPDATE v_call_center_queues SET
			domain_uuid = '%s',
			dialplan_uuid = '%s',
			queue_name = '%s',
			queue_extension = '%s',
			queue_greeting = '%s',
			queue_strategy = '%s',
			queue_moh_sound = '%s',
			queue_record_template = '%s',
			queue_time_base_score = '%s',
			queue_time_base_score_sec = %s,
			queue_max_wait_time = %s,
			queue_max_wait_time_with_no_agent = %s,
			queue_max_wait_time_with_no_agent_time_reached = %s,
			queue_tier_rules_apply = '%s',
			queue_tier_rule_wait_second = %s,
			queue_tier_rule_no_agent_no_wait = '%s',
			queue_timeout_action = '%s',
			queue_discard_abandoned_after = %s,
			queue_abandoned_resume_allowed = '%s',
			queue_tier_rule_wait_multiply_level = '%s',
			queue_cid_prefix = '%s',
			queue_outbound_caller_id_name = '%s',
			queue_outbound_caller_id_number = '%s',
			queue_announce_position = '%s',
			queue_announce_sound = '%s',
			queue_announce_frequency = %s,
			queue_cc_exit_keys = '%s',
			queue_email_address = '%s',
			queue_context = '%s',
			queue_description = '%s',
			queue_flow_json = '%s',
			agent_log = %s
		WHERE call_center_queue_uuid = '%s';
	]], 
		params.domain_uuid or "NULL", params.dialplan_uuid or "NULL",
		params.queue_name, params.queue_extension or '', params.queue_greeting or '',
		params.queue_strategy or '', params.queue_moh_sound or '', params.queue_record_template or '',
		params.queue_time_base_score or '', params.queue_time_base_score_sec or "NULL",
		params.queue_max_wait_time or "NULL", params.queue_max_wait_time_with_no_agent or "NULL",
		params.queue_max_wait_time_with_no_agent_time_reached or "NULL",
		params.queue_tier_rules_apply or '', params.queue_tier_rule_wait_second or "NULL",
		params.queue_tier_rule_no_agent_no_wait or '', params.queue_timeout_action or '',
		params.queue_discard_abandoned_after or "NULL", params.queue_abandoned_resume_allowed or '',
		params.queue_tier_rule_wait_multiply_level or '', params.queue_cid_prefix or '',
		params.queue_outbound_caller_id_name or '', params.queue_outbound_caller_id_number or '',
		params.queue_announce_position or '', params.queue_announce_sound or '',
		params.queue_announce_frequency or "NULL", params.queue_cc_exit_keys or '',
		params.queue_email_address or '', params.queue_context or '', params.queue_description or '',
		params.queue_flow_json or '{}', tostring(params.agent_log or true),
		params.call_center_queue_uuid
	)

	execute(sql)
	freeswitch.api("callcenter_config", "reload")
end

-- Delete queue by UUID
function M.delete_queue(queue_uuid)
	assert(queue_uuid, "queue_uuid required")
	execute("DELETE FROM v_call_center_queues WHERE call_center_queue_uuid = '" .. queue_uuid .. "';")
	freeswitch.api("callcenter_config", "reload")
end

-- ====================
-- AGENT FUNCTIONS CRUD
-- ====================

-- Insert new agent
function M.insert_agent(params)
	local agent_uuid = params.call_center_agent_uuid or uuid()

	local sql_v = string.format([[
		INSERT INTO v_call_center_agents (
			call_center_agent_uuid, domain_uuid, user_uuid,
			agent_name, agent_type, agent_call_timeout,
			agent_id, agent_password, agent_contact, agent_status,
			agent_logout, agent_max_no_answer, agent_wrap_up_time,
			agent_reject_delay_time, agent_busy_delay_time,
			agent_no_answer_delay_time, agent_record
		) VALUES (
			'%s', '%s', %s,
			'%s', '%s', %s,
			'%s', '%s', '%s', '%s',
			'%s', %s, %s,
			%s, %s,
			'%s', '%s'
		)
	]], 
		agent_uuid, params.domain_uuid or "", params.user_uuid and ("'" .. params.user_uuid .. "'") or "NULL",
		params.agent_name, params.agent_type, params.agent_call_timeout or "NULL",
		params.agent_id or params.agent_name, params.agent_password or '',
		params.agent_contact, params.agent_status,
		params.agent_logout or '',
		params.agent_max_no_answer or "NULL", params.agent_wrap_up_time or "NULL",
		params.agent_reject_delay_time or "NULL", params.agent_busy_delay_time or "NULL",
		params.agent_no_answer_delay_time or '', params.agent_record or ''
	)
	execute(sql_v)

	local sql_cc = string.format([[
		INSERT INTO agents (
			name, uuid, type, contact, status,
			max_no_answer, wrap_up_time, reject_delay_time,
			busy_delay_time, no_answer_delay_time
		) VALUES (
			'%s', '%s', '%s', '%s', '%s',
			%d, %d, %d,
			%d, %d
		)
	]], 
		params.agent_name, agent_uuid, params.agent_type, params.agent_contact, params.agent_status,
		tonumber(params.agent_max_no_answer) or 0,
		tonumber(params.agent_wrap_up_time) or 0,
		tonumber(params.agent_reject_delay_time) or 0,
		tonumber(params.agent_busy_delay_time) or 0,
		tonumber(params.agent_no_answer_delay_time) or 0
	)
	execute(sql_cc)

	freeswitch.api("callcenter_config", "reload")
	return agent_uuid
end

-- Update existing agent by UUID
function M.update_agent(params)
	assert(params.call_center_agent_uuid, "call_center_agent_uuid required")

	local sql_v = string.format([[
		UPDATE v_call_center_agents SET
			domain_uuid = '%s',
			user_uuid = %s,
			agent_name = '%s',
			agent_type = '%s',
			agent_call_timeout = %s,
			agent_id = '%s',
			agent_password = '%s',
			agent_contact = '%s',
			agent_status = '%s',
			agent_logout = '%s',
			agent_max_no_answer = %s,
			agent_wrap_up_time = %s,
			agent_reject_delay_time = %s,
			agent_busy_delay_time = %s,
			agent_no_answer_delay_time = '%s',
			agent_record = '%s'
		WHERE call_center_agent_uuid = '%s';
	]], 
		params.domain_uuid or "", 
		params.user_uuid and ("'" .. params.user_uuid .. "'") or "NULL",
		params.agent_name, params.agent_type, params.agent_call_timeout or "NULL",
		params.agent_id or params.agent_name, params.agent_password or '',
		params.agent_contact, params.agent_status,
		params.agent_logout or '',
		params.agent_max_no_answer or "NULL", params.agent_wrap_up_time or "NULL",
		params.agent_reject_delay_time or "NULL", params.agent_busy_delay_time or "NULL",
		params.agent_no_answer_delay_time or '', params.agent_record or '',
		params.call_center_agent_uuid
	)
	execute(sql_v)

	local sql_cc = string.format([[
		UPDATE agents SET
			uuid = '%s',
			type = '%s',
			contact = '%s',
			status = '%s',
			max_no_answer = %d,
			wrap_up_time = %d,
			reject_delay_time = %d,
			busy_delay_time = %d,
			no_answer_delay_time = %d
		WHERE name = '%s';
	]], 
		params.call_center_agent_uuid,
		params.agent_type,
		params.agent_contact,
		params.agent_status,
		tonumber(params.agent_max_no_answer) or 0,
		tonumber(params.agent_wrap_up_time) or 0,
		tonumber(params.agent_reject_delay_time) or 0,
		tonumber(params.agent_busy_delay_time) or 0,
		tonumber(params.agent_no_answer_delay_time) or 0,
		params.agent_name
	)
	execute(sql_cc)

	freeswitch.api("callcenter_config", "reload")
end

-- Delete agent by agent name
function M.delete_agent(agent_name)
	assert(agent_name, "agent_name required")
	execute("DELETE FROM v_call_center_agents WHERE call_center_agent_uuid = '" .. agent_name .. "';")
	execute("DELETE FROM agents WHERE name = '" .. agent_name .. "';")
	freeswitch.api("callcenter_config", "reload")
end

-- ====================
-- TIER FUNCTIONS CRUD
-- ====================

-- Insert new tier
function M.insert_tier(params)
	local tier_uuid = params.call_center_tier_uuid or uuid()

	local sql_v = string.format([[
		INSERT INTO v_call_center_tiers (
			call_center_tier_uuid, domain_uuid, call_center_queue_uuid,
			call_center_agent_uuid, agent_name, queue_name,
			tier_level, tier_position, flag
		) VALUES (
			'%s', '%s', '%s',
			'%s', '%s', '%s',
			%d, %d, %d
		)
	]], 
		tier_uuid,
		params.domain_uuid or '',
		params.call_center_queue_uuid or '',
		params.call_center_agent_uuid or '',
		params.agent_name or '',
		params.queue_name or '',
		tonumber(params.tier_level) or 1,
		tonumber(params.tier_position) or 1,
		tonumber(params.flag) or 1
	)
	execute(sql_v)

	local sql_mod = string.format([[
		INSERT INTO tiers (queue, agent, level, position)
		VALUES ('%s', '%s', %d, %d)
	]], 
		params.queue_name,
		params.agent_name,
		tonumber(params.tier_level) or 1,
		tonumber(params.tier_position) or 1
	)
	execute(sql_mod)

	freeswitch.api("callcenter_config", "reload")
	return tier_uuid
end

-- Update existing tier by UUID
function M.update_tier(params)
	assert(params.call_center_tier_uuid, "call_center_tier_uuid required")

	local sql_v = string.format([[
		UPDATE v_call_center_tiers SET
			domain_uuid = '%s',
			call_center_queue_uuid = '%s',
			call_center_agent_uuid = '%s',
			agent_name = '%s',
			queue_name = '%s',
			tier_level = %d,
			tier_position = %d,
			flag = %d
		WHERE call_center_tier_uuid = '%s';
	]], 
		params.domain_uuid or '',
		params.call_center_queue_uuid or '',
		params.call_center_agent_uuid or '',
		params.agent_name or '',
		params.queue_name or '',
		tonumber(params.tier_level) or 1,
		tonumber(params.tier_position) or 1,
		tonumber(params.flag) or 1,
		params.call_center_tier_uuid
	)
	execute(sql_v)

	local sql_mod = string.format([[
		UPDATE tiers SET
			level = %d,
			position = %d
		WHERE queue = '%s' AND agent = '%s';
	]], 
		tonumber(params.tier_level) or 1,
		tonumber(params.tier_position) or 1,
		params.queue_name,
		params.agent_name
	)
	execute(sql_mod)

	freeswitch.api("callcenter_config", "reload")
end

-- Delete tier by agent name and queue name
function M.delete_tier(agent_name, queue_name)
	assert(agent_name and queue_name, "agent_name and queue_name are required")

	execute(string.format("DELETE FROM tiers WHERE agent = '%s' AND queue = '%s';", agent_name, queue_name))
	execute(string.format("DELETE FROM v_call_center_tiers WHERE call_center_agent_uuid = '%s' AND queue_name = '%s';", agent_name, queue_name))

	freeswitch.api("callcenter_config", "reload")
end

return M


--[[ Usage examples:

local cc = require "agent_manager"

-- Insert queue
local queue_uuid = cc.insert_queue{
	domain_uuid = "domain-uuid",
	queue_name = "support",
	queue_extension = "9001",
	queue_strategy = "longest-idle-agent",
	queue_moh_sound = "local_stream://default",
	queue_context = "default",
	agent_log = true
}

-- Update queue
cc.update_queue{
	call_center_queue_uuid = queue_uuid,
	queue_name = "support_updated",
	queue_extension = "9002",
	-- other params...
}

-- Delete queue
cc.delete_queue(queue_uuid)

-- Insert agent
local agent_uuid = cc.insert_agent{
	domain_uuid = "domain-uuid",
	agent_name = "1005",
	agent_type = "callback",
	agent_contact = "user/1005@yourdomain.com",
	agent_status = "Available"
}


""

-- Update agent
cc.update_agent{
	call_center_agent_uuid = agent_uuid,
	agent_name = "1005",
	agent_type = "callback",
	agent_contact = "user/1005@yourdomain.com",
	agent_status = "Available"
}

-- Delete agent
cc.delete_agent("1005")

-- Insert tier
local tier_uuid = cc.insert_tier{
	domain_uuid = "domain-uuid",
	agent_name = "1005",
	queue_name = "support",
	call_center_agent_uuid = agent_uuid,
	call_center_queue_uuid = queue_uuid,
	tier_level = 1,
	tier_position = 1
}

-- Update tier
cc.update_tier{
	call_center_tier_uuid = tier_uuid,
	agent_name = "1005",
	queue_name = "support",
	tier_level = 2,
	tier_position = 1
}

"
UPDATE tiers
SET state = 'Ready',
    LEVEL = 1,
    POSITION = 1
WHERE queue = '4000@cc.systech.ae'
  AND agent = '9c490bb2-2680-443d-920e-8db06df22d61';

"

-- Delete tier
cc.delete_tier("1005", "support")

]]

