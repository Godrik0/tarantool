local t = require('luatest')
local fio = require('fio')
local cbuilder = require('luatest.cbuilder')
local cluster = require('luatest.cluster')

local g = t.group('checks')

g.after_each(function(g)
    if g.cluster ~= nil then
        g.cluster:stop()
    end
    if g.temp_dir ~= nil then
        fio.rmtree(g.temp_dir)
    end
end)

-- {{{ Transparent Huge Pages check

-- Create a mock THP sysfs file with the given mode.
local function create_thp_file(temp_dir, mode)
    local thp_file = fio.pathjoin(temp_dir, 'enabled')
    local content
    if mode == 'always' then
        content = '[always] madvise never'
    elseif mode == 'madvise' then
        content = 'always [madvise] never'
    else
        content = 'always madvise [never]'
    end
    local fh = fio.open(thp_file, {'O_CREAT', 'O_WRONLY'}, tonumber('644', 8))
    fh:write(content)
    fh:close()
    return thp_file
end

-- Run test with THP mocked to the given mode.
local function run_with_thp_mock(g, thp_mode, checks_cfg, exp_contains)
    local thp_file
    if thp_mode ~= nil then
        g.temp_dir = fio.tempdir()
        thp_file = create_thp_file(g.temp_dir, thp_mode)
    end

    local builder = cbuilder:new():add_instance('i-001', {})
    if checks_cfg ~= nil then
        builder = builder:set_instance_option('i-001', 'config.checks',
            checks_cfg)
    end
    local config = builder:config()

    g.cluster = cluster:new(config)
    g.cluster:start()

    g.cluster['i-001']:exec(function(thp_file, exp_contains)
        local t = require('luatest')
        local checks = require('internal.config.applier.checks')
        if thp_file ~= nil then
            checks._internal.set_thp_sysfs_path(thp_file)
        end

        local config = require('config')
        checks.apply(config)

        local alerts = box.info.config.alerts
        if exp_contains ~= nil then
            local found = false
            for _, alert in ipairs(alerts) do
                if alert.message ~= nil and
                        string.find(alert.message, exp_contains, 1,
                            true) ~= nil then
                    found = true
                    break
                end
            end
            t.assert(found,
                ('Alert containing "%s" was not found')
                :format(exp_contains))
        end
    end, {thp_file, exp_contains})
end

g.test_thp_alert_enabled_always = function(g)
    run_with_thp_mock(g, 'always', {transparent_huge_pages = true}, 'always')
end

g.test_thp_alert_enabled_madvise = function(g)
    run_with_thp_mock(g, 'madvise', {transparent_huge_pages = true}, 'madvise')
end

g.test_thp_alert_disabled_never = function(g)
    run_with_thp_mock(g, 'never', nil, nil)
end

g.test_thp_alert_no_file = function(g)
    run_with_thp_mock(g, nil, nil, nil)
end

g.test_thp_alert_check_disabled = function(g)
    run_with_thp_mock(g, 'always',
        {transparent_huge_pages = false},
        nil)
end

g.test_thp_alert_check_enabled = function(g)
    run_with_thp_mock(g, 'always',
        {transparent_huge_pages = true},
        'Transparent Huge Pages')
end

g.test_thp_alert_disabled_by_default = function(g)
    run_with_thp_mock(g, 'always', nil, nil)
end

-- }}} Transparent Huge Pages check

-- {{{ Mixed sync/async spaces check

-- Space setup types:
--   mix  — one async space + one sync space
--   async — one async space only
--   sync  — one sync space only
--   nil     — no user spaces
local function run_mixed_sync_test(g, checks_cfg, space_setup, exp_contains)
    local builder = cbuilder:new():add_instance('i-001', {})
    if checks_cfg ~= nil then
        builder = builder:set_instance_option('i-001', 'config.checks',
            checks_cfg)
    end
    local config = builder:config()

    g.cluster = cluster:new(config)
    g.cluster:start()

    g.cluster['i-001']:exec(function(space_setup, exp_contains)
        local t = require('luatest')
        local checks = require('internal.config.applier.checks')

        -- Create spaces according to the setup type.
        if space_setup == 'mix' then
            box.schema.create_space('async_space')
            box.schema.create_space('sync_space', {is_sync = true})
        elseif space_setup == 'async' then
            box.schema.create_space('async_space')
        elseif space_setup == 'sync' then
            box.schema.create_space('sync_space', {is_sync = true})
        end

        local config = require('config')
        checks.apply(config)

        local alerts = box.info.config.alerts
        if exp_contains ~= nil then
            local found = false
            for _, alert in ipairs(alerts) do
                if alert.message ~= nil and
                        string.find(alert.message, exp_contains, 1,
                            true) ~= nil then
                    found = true
                    break
                end
            end
            t.assert(found, ('Alert containing "%s" was not found'):format(
                exp_contains))
        else
            t.assert_equals(alerts, {})
        end
    end, {space_setup, exp_contains})
end

g.test_mixed_sync_alert_mix_sync_and_async = function(g)
    run_mixed_sync_test(g,
        {mixed_sync_async_spaces = true},
        'mix',
        'different is_sync')
end

g.test_mixed_sync_alert_only_async = function(g)
    run_mixed_sync_test(g,
        {mixed_sync_async_spaces = true},
        'async',
        nil)
end

g.test_mixed_sync_alert_only_sync = function(g)
    -- A sync user space + async system spaces = mixed, alert fires.
    run_mixed_sync_test(g,
        {mixed_sync_async_spaces = true},
        'sync',
        'different is_sync')
end

g.test_mixed_sync_alert_check_disabled = function(g)
    run_mixed_sync_test(g,
        {mixed_sync_async_spaces = false},
        'mix',
        nil)
end

g.test_mixed_sync_alert_disabled_by_default = function(g)
    run_mixed_sync_test(g,
        nil,
        'mix',
        nil)
end

-- }}} Mixed sync/async spaces check

-- {{{ Fiber-based checks

g.test_fiber_detects_thp_enabled = function(g)
    g.temp_dir = fio.tempdir()
    local thp_file = create_thp_file(g.temp_dir, 'never')

    local builder = cbuilder:new():add_instance('i-001', {})
    builder = builder:set_instance_option('i-001', 'config.checks', {
        transparent_huge_pages = true,
    })
    local config = builder:config()

    g.cluster = cluster:new(config)
    g.cluster:start()

    g.cluster['i-001']:exec(function(thp_file)
        local t = require('luatest')
        local fiber = require('fiber')
        local fio = require('fio')
        local checks = require('internal.config.applier.checks')

        checks._internal.set_thp_sysfs_path(thp_file)
        checks._internal.set_check_interval(1)

        t.assert_equals(require('config'):info().status, 'ready')

        local fh = fio.open(thp_file, {'O_WRONLY', 'O_TRUNC'})
        fh:write('[always] madvise never')
        fh:close()

        local cond = fiber.cond()
        local watcher = box.watch('config.info', function(_, info)
            if info.status == 'check_warnings' then
                cond:signal()
            end
        end)
        local ok = cond:wait(5)
        watcher:unregister()
        t.assert(ok, 'Timed out waiting for check_warnings status')

        local alerts = box.info.config.alerts
        local found = false
        for _, alert in ipairs(alerts) do
            if alert.message ~= nil and
                    string.find(alert.message, 'Transparent Huge Pages', 1,
                        true) ~= nil then
                found = true
                break
            end
        end
        t.assert(found, 'THP alert not found after fiber detected change')

        checks._internal.stop_fiber()
    end, {thp_file})
end

g.test_fiber_drops_thp_alert_after_disabled = function(g)
    g.temp_dir = fio.tempdir()
    local thp_file = create_thp_file(g.temp_dir, 'always')

    local builder = cbuilder:new():add_instance('i-001', {})
    builder = builder:set_instance_option('i-001', 'config.checks', {
        transparent_huge_pages = true,
    })
    local config = builder:config()

    g.cluster = cluster:new(config)
    g.cluster:start()

    g.cluster['i-001']:exec(function(thp_file)
        local t = require('luatest')
        local fiber = require('fiber')
        local fio = require('fio')
        local checks = require('internal.config.applier.checks')

        checks._internal.set_thp_sysfs_path(thp_file)
        checks.apply(require('config'))

        checks._internal.set_check_interval(1)

        local cond = fiber.cond()
        local watcher = box.watch('config.info', function(_, info)
            if info.status == 'check_warnings' then
                cond:signal()
            end
        end)
        local ok = cond:wait(5)
        t.assert(ok, 'Timed out waiting for check_warnings status')

        local fh = fio.open(thp_file, {'O_WRONLY', 'O_TRUNC'})
        fh:write('always madvise [never]')
        fh:close()

        local cond2 = fiber.cond()
        local watcher2 = box.watch('config.info', function(_, info)
            if info.status == 'ready' then
                cond2:signal()
            end
        end)
        ok = cond2:wait(5)
        watcher:unregister()
        watcher2:unregister()
        t.assert(ok, 'Timed out waiting for ready status')

        t.assert_equals(box.info.config.alerts, {})

        checks._internal.stop_fiber()
    end, {thp_file})
end

g.test_fiber_detects_new_sync_space = function(g)
    local builder = cbuilder:new():add_instance('i-001', {})
    builder = builder:set_instance_option('i-001', 'config.checks', {
        mixed_sync_async_spaces = true,
    })
    local config = builder:config()

    g.cluster = cluster:new(config)
    g.cluster:start()

    g.cluster['i-001']:exec(function()
        local t = require('luatest')
        local fiber = require('fiber')
        local checks = require('internal.config.applier.checks')

        checks._internal.set_check_interval(1)

        t.assert_equals(require('config'):info().status, 'ready')

        box.schema.create_space('sync_space', {is_sync = true})

        local cond = fiber.cond()
        local watcher = box.watch('config.info', function(_, info)
            if info.status == 'check_warnings' then
                cond:signal()
            end
        end)
        local ok = cond:wait(5)
        watcher:unregister()
        t.assert(ok, 'Timed out waiting for check_warnings status')

        local alerts = box.info.config.alerts
        local found = false
        for _, alert in ipairs(alerts) do
            if alert.message ~= nil and
                    string.find(alert.message, 'different is_sync', 1,
                        true) ~= nil then
                found = true
                break
            end
        end
        t.assert(found, 'Alert not found after fiber detected sync space')

        checks._internal.stop_fiber()
    end)
end

g.test_fiber_drops_alert_after_space_drop = function(g)
    local builder = cbuilder:new():add_instance('i-001', {})
    builder = builder:set_instance_option('i-001', 'config.checks', {
        mixed_sync_async_spaces = true,
    })
    local config = builder:config()

    g.cluster = cluster:new(config)
    g.cluster:start()

    g.cluster['i-001']:exec(function()
        local t = require('luatest')
        local fiber = require('fiber')
        local checks = require('internal.config.applier.checks')

        checks._internal.set_check_interval(1)

        box.schema.create_space('sync_space', {is_sync = true})

        local cond = fiber.cond()
        local watcher = box.watch('config.info', function(_, info)
            if info.status == 'check_warnings' then
                cond:signal()
            end
        end)
        local ok = cond:wait(5)
        t.assert(ok, 'Timed out waiting for check_warnings status')

        box.space.sync_space:drop()

        local cond2 = fiber.cond()
        local watcher2 = box.watch('config.info', function(_, info)
            if info.status == 'ready' then
                cond2:signal()
            end
        end)
        ok = cond2:wait(5)
        watcher:unregister()
        watcher2:unregister()
        t.assert(ok, 'Timed out waiting for ready status')

        t.assert_equals(box.info.config.alerts, {})

        checks._internal.stop_fiber()
    end)
end

-- }}} Fiber-based checks
