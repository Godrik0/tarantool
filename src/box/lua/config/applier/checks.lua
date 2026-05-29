-- System checks applier.
--
-- This applier performs various system checks and generates
-- alerts if issues are detected. New checks can be added
-- by adding functions to the `checks` table.
--
-- The checks run on every config apply/reload and also periodically
-- via a background fiber, so that runtime changes are
-- detected automatically without requiring config:reload().

local fio = require('fio')
local fiber = require('fiber')
local log = require('internal.config.utils.log')

-- Interval between periodic check runs (seconds).
-- Set by apply() from config.checks.interval.
local check_interval = nil

-- Alerts namespace for checks.
local alert_ns = nil

-- Set an alert in the checks namespace, but only if the alert
-- with the given key doesn't already exist with the same message.
-- This avoids re-logging and timestamp updates on every
-- periodic check run when nothing has changed.
-- Returns true if the alert was set, false if unchanged.
local function set_alert_if_changed(key, alert)
    local existing = alert_ns._aboard:get(
        ('checks:%s'):format(key))
    if existing ~= nil and existing.message == alert.message then
        return false
    end
    alert_ns:set(key, alert)
    return true
end

-- Drop an alert from the checks namespace if it exists.
-- Returns true if the alert was dropped, false if it didn't exist.
local function drop_alert_if_exists(key)
    local full_key = ('checks:%s'):format(key)
    if alert_ns._aboard:get(full_key) == nil then
        return false
    end
    alert_ns:unset(key)
    return true
end

-- {{{ System checks registry

-- List of system checks to perform.
--
-- Each element is a {key = <str>, fn = <func>} table where:
--   key is a config.checks.* option that enables/disables the check
--   fn  is a function(configdata) that performs the check and
--       returns true if an alert was set or dropped, false otherwise
--
-- To add a new check, add an element to this array:
--   {key = MY_ALERT_KEY, fn = my_check_function},
local checks = {}

-- }}} System checks registry

-- {{{ Run all checks

local function run_checks(config)
    local configdata = config._configdata
    local changed = false

    for _, check in ipairs(checks) do
        local ok, result = pcall(check.fn, configdata)
        if not ok then
            log.error(('checks: check %s failed: %s'):format(check.key, result))
        else
            changed = changed or result
        end
    end
    return changed
end

-- }}} Run all checks

-- {{{ Check if any check is enabled

local function any_check_enabled(configdata)
    for _, check in ipairs(checks) do
        if configdata:get('config.checks.' .. check.key,
            {use_default = true}) then
            return true
        end
    end
    return false
end

-- }}} Check if any check is enabled

-- {{{ Background fiber

-- Fiber that periodically re-runs all checks.
local check_fiber = nil
local check_cond = fiber.cond()

local function checks_fiber_f(config)
    fiber.self():name('config.checks')
    while true do
        check_cond:wait(check_interval)
        local status = config._status
        if status ~= 'startup_in_progress' and
           status ~= 'reload_in_progress' then
            local changed = run_checks(config)
            if changed then
                config:_set_status_based_on_alerts()
            end
        end
    end
end

local function start_fiber(config)
    if check_fiber ~= nil and check_fiber:status() ~= 'dead' then
        return
    end
    check_fiber = fiber.new(checks_fiber_f, config)
end

local function stop_fiber()
    if check_fiber ~= nil and check_fiber:status() ~= 'dead' then
        check_fiber:cancel()
        check_fiber = nil
    end
end

-- }}} Background fiber

local function apply(config)
    if alert_ns == nil then
        alert_ns = config:new_alerts_namespace('checks')
    end

    local configdata = config._configdata
    local interval = configdata:get('config.checks.interval',
        {use_default = true})
    if interval ~= check_interval then
        check_interval = interval
        check_cond:signal()
    end

    run_checks(config)
    if any_check_enabled(configdata) then
        start_fiber(config)
    else
        stop_fiber()
    end
end

return {
    name = 'checks',
    apply = apply,
}
