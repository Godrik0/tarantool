-- System checks applier.
--
-- This applier performs various system checks and generates
-- alerts if issues are detected. New checks can be added
-- by adding functions to the `checks` table.

local fio = require('fio')

-- {{{ THP (Transparent Huge Pages) check

local THP_ALERT_KEY = 'transparent_huge_pages'
local THP_SYSFS_PATH = '/sys/kernel/mm/transparent_hugepage/enabled'

-- For testing purposes.
local thp_sysfs_path = THP_SYSFS_PATH

-- Read current THP mode from sysfs.
-- Returns 'always', 'madvise', 'never' or nil (file doesn't exist).
local function get_thp_mode()
    if not fio.path.exists(thp_sysfs_path) then
        return nil
    end

    local fh = fio.open(thp_sysfs_path, {'O_RDONLY'})
    if fh == nil then
        return nil
    end

    local content = fh:read(256)
    fh:close()
    if content == nil then
        return nil
    end

    -- Format: "always [madvise] never".
    return content:match('%[(%a+)%]')
end

local function check_thp(config, configdata)
    if not configdata:get('config.checks.' ..
        THP_ALERT_KEY, {use_default = true}) then
        config._aboard:drop(THP_ALERT_KEY)
        return
    end

    local mode = get_thp_mode()
    if mode == nil or mode == 'never' then
        config._aboard:drop(THP_ALERT_KEY)
        return
    end

    config._aboard:set({
        type = 'warn',
        message = ('Transparent Huge Pages (THP) are set to "%s". ' ..
            'This may cause latency spikes and memory overhead. ' ..
            'Consider disabling THP: ' ..
            'echo never > /sys/kernel/mm/transparent_hugepage/enabled')
            :format(mode),
    }, {
        key = THP_ALERT_KEY,
    })
end

-- }}} THP (Transparent Huge Pages) check

-- {{{ Mixed sync/async spaces check

local MIXED_SYNC_ALERT_KEY = 'mixed_sync_async_spaces'

-- Detect whether there are spaces with different is_sync flags.
-- Returns true if both sync and async spaces exist, false otherwise.
local function has_mixed_sync_spaces()
    local has_sync = false
    local has_async = false

    for _, sp in pairs(box.space) do
        if sp.is_sync then
            has_sync = true
        else
            has_async = true
        end
        if has_async and has_sync then
            return true
        end
    end
    return false
end

local function check_mixed_sync(config, configdata)
    if not configdata:get('config.checks.' .. MIXED_SYNC_ALERT_KEY,
        {use_default = true}) then
        config._aboard:drop(MIXED_SYNC_ALERT_KEY)
        return
    end

    if not has_mixed_sync_spaces() then
        config._aboard:drop(MIXED_SYNC_ALERT_KEY)
        return
    end

    config._aboard:set({
        type = 'warn',
        message = 'The replicaset has spaces with different is_sync ' ..
            'flags. Mixing synchronous and asynchronous spaces in ' ..
            'the same replicaset may lead to unexpected behavior. ' ..
            'Consider using only synchronous or only asynchronous ' ..
            'spaces within a replicaset.',
    }, {
        key = MIXED_SYNC_ALERT_KEY,
    })
end

-- }}} Mixed sync/async spaces check

-- {{{ System checks registry

-- List of system checks to perform.
--
-- Each check is a function that takes (config, configdata) and
-- may set or drop alerts using config._aboard.
--
-- To add a new check, add a function to this table:
--   checks.my_check_name = function(config, configdata) ... end
local checks = {
    transparent_huge_pages = check_thp,
    mixed_sync_async_spaces = check_mixed_sync,
}

-- }}} System checks registry

local function apply(config)
    local configdata = config._configdata

    local check_keys = {}
    for key in pairs(checks) do
        table.insert(check_keys, key)
    end
    table.sort(check_keys)
    for _, key in ipairs(check_keys) do
        checks[key](config, configdata)
    end
end

return {
    name = 'checks',
    apply = apply,
    _internal = {
        set_thp_sysfs_path = function(path)
            thp_sysfs_path = path
        end,
    },
}
