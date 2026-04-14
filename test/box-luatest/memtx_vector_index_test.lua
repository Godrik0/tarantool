local server = require('luatest.server')
local t = require('luatest')

local g = t.group('memtx_vector_index', {
    {memtx_use_mvcc_engine = true},
    {memtx_use_mvcc_engine = false},
})

g.before_all(function(cg)
    cg.server = server:new({
        box_cfg = {
            memtx_use_mvcc_engine = cg.params.memtx_use_mvcc_engine,
        },
    })
    cg.server:start()
end)

g.after_all(function(cg)
    cg.server:drop()
end)

g.after_each(function(cg)
    cg.server:exec(function()
        if box.space.test ~= nil then
            box.space.test:drop()
        end
    end)
end)

g.test_ddl_and_metadata = function(cg)
    cg.server:exec(function()
        local s = box.schema.space.create('test', {
            format = {
                {name = 'id', type = 'unsigned'},
                {name = 'vec', type = 'array'},
                {name = 'payload', type = 'string', is_nullable = true},
            },
        })
        s:create_index('pk')

        local idx = s:create_index('vec', {
            type = 'vector',
            unique = false,
            parts = {{field = 'vec', type = 'array'}},
            dimension = 2,
            distance = 'cosine',
        })

        t.assert_equals(idx.distance, 'cosine')
        t.assert_equals(idx.algorithm, 'hnsw')
        t.assert_equals(idx.dimension, 2)
        t.assert_equals(idx.m, 16)
        t.assert_equals(idx.ef_construction, 200)
        t.assert_equals(idx.ef_search, 64)

        t.assert_error_covers({
            type = 'ClientError',
            name = 'MODIFY_INDEX',
            message = "Can't create or modify index 'u' in space 'test': " ..
                      "VECTOR index can not be unique",
        }, s.create_index, s, 'u', {
            type = 'vector',
            unique = true,
            parts = {{field = 'vec', type = 'array'}},
            dimension = 2,
            distance = 'l2',
        })

        t.assert_error_covers({
            type = 'ClientError',
            name = 'MODIFY_INDEX',
            message = "Can't create or modify index 'multipart' in space " ..
                      "'test': VECTOR index key can not be multipart",
        }, s.create_index, s, 'multipart', {
            type = 'vector',
            unique = false,
            parts = {
                {field = 'vec', type = 'array'},
                {field = 'id', type = 'unsigned'},
            },
            dimension = 2,
            distance = 'l2',
        })

        t.assert_error_covers({
            type = 'ClientError',
            name = 'MODIFY_INDEX',
            message = "Can't create or modify index 'bad_part' in space " ..
                      "'test': VECTOR index field type must be ARRAY",
        }, s.create_index, s, 'bad_part', {
            type = 'vector',
            unique = false,
            parts = {{field = 'id', type = 'unsigned'}},
            dimension = 2,
            distance = 'l2',
        })

        t.assert_error_covers({
            type = 'ClientError',
            name = 'WRONG_INDEX_OPTIONS',
            message = "Wrong index options: distance must be either " ..
                      "'cosine', 'l2' or 'ip'",
        }, s.create_index, s, 'bad_distance', {
            type = 'vector',
            unique = false,
            parts = {{field = 'vec', type = 'array'}},
            dimension = 2,
            distance = 'euclid',
        })

        t.assert_error_covers({
            type = 'ClientError',
            name = 'WRONG_INDEX_OPTIONS',
            message = "Wrong index options: algorithm must be 'hnsw'",
        }, s.create_index, s, 'bad_algorithm', {
            type = 'vector',
            unique = false,
            parts = {{field = 'vec', type = 'array'}},
            dimension = 2,
            distance = 'l2',
            algorithm = 'flat',
        })

        t.assert_error_covers({
            type = 'ClientError',
            name = 'WRONG_INDEX_OPTIONS',
            message = "Wrong index options: dimension must be greater than 0",
        }, s.create_index, s, 'bad_dimension', {
            type = 'vector',
            unique = false,
            parts = {{field = 'vec', type = 'array'}},
            dimension = 0,
            distance = 'l2',
        })

        t.assert_error_covers({
            type = 'ClientError',
            name = 'WRONG_INDEX_OPTIONS',
            message = "Wrong index options: m must be greater than or equal " ..
                      "to 2",
        }, s.create_index, s, 'bad_m', {
            type = 'vector',
            unique = false,
            parts = {{field = 'vec', type = 'array'}},
            dimension = 2,
            distance = 'l2',
            m = 1,
        })

        t.assert_error_covers({
            type = 'ClientError',
            name = 'WRONG_INDEX_OPTIONS',
            message = "Wrong index options: ef_construction must be " ..
                      "greater than 0",
        }, s.create_index, s, 'bad_ef_construction', {
            type = 'vector',
            unique = false,
            parts = {{field = 'vec', type = 'array'}},
            dimension = 2,
            distance = 'l2',
            ef_construction = 0,
        })

        t.assert_error_covers({
            type = 'ClientError',
            name = 'WRONG_INDEX_OPTIONS',
            message = "Wrong index options: ef_search must be greater " ..
                      "than 0",
        }, s.create_index, s, 'bad_ef_search', {
            type = 'vector',
            unique = false,
            parts = {{field = 'vec', type = 'array'}},
            dimension = 2,
            distance = 'l2',
            ef_search = 0,
        })
    end)
end

g.test_search_update_delete_and_bsize = function(cg)
    cg.server:exec(function()
        local s = box.schema.space.create('test', {
            format = {
                {name = 'id', type = 'unsigned'},
                {name = 'vec', type = 'array'},
                {name = 'payload', type = 'string', is_nullable = true},
            },
        })
        s:create_index('pk')
        local idx = s:create_index('vec', {
            type = 'vector',
            unique = false,
            parts = {{field = 'vec', type = 'array'}},
            dimension = 2,
            distance = 'l2',
            m = 8,
            ef_construction = 32,
            ef_search = 32,
        })

        local bsize_before = idx:bsize()
        s:insert({1, {0, 0}, 'a'})
        s:insert({2, {1, 0}, 'b'})
        s:insert({3, {3, 0}, 'c'})
        s:insert({4, {0, 2}, 'd'})
        t.assert(idx:bsize() > bsize_before)

        local function ids(rows)
            local result = {}
            for _, row in ipairs(rows) do
                table.insert(result, row[1])
            end
            return result
        end

        local function row_by_id(rows, id)
            for _, row in ipairs(rows) do
                if row[1] == id then
                    return row
                end
            end
            return nil
        end

        t.assert_equals(idx:select({{0, 0}}, {
            iterator = 'neighbor',
            limit = 0,
        }), {})

        t.assert_equals(ids(idx:select({{0, 0}}, {
            iterator = 'neighbor',
            limit = 4,
        })), {1, 2, 4, 3})
        t.assert_equals(idx:count(), 4)

        s:update(2, {{'=', 3, 'bb'}})
        local rows = idx:select({{0, 0}}, {
            iterator = 'neighbor',
            limit = 4,
        })
        t.assert_equals(ids(rows), {1, 2, 4, 3})
        t.assert_equals(row_by_id(rows, 2)[3], 'bb')
        t.assert_equals(idx:count(), 4)

        s:update(2, {{'=', 2, {10, 10}}})
        t.assert_equals(ids(idx:select({{0, 0}}, {
            iterator = 'neighbor',
            limit = 4,
        })), {1, 4, 3, 2})
        t.assert_equals(idx:count(), 4)

        s:delete(1)
        t.assert_equals(ids(idx:select({{0, 0}}, {
            iterator = 'neighbor',
            limit = 3,
        })), {4, 3, 2})

        t.assert_error_msg_contains('requested iterator type', function()
            idx:select({{0, 0}}, {iterator = 'eq'})
        end)

        t.assert_error_msg_contains('vector dimension must be 2', function()
            idx:select({{0}}, {iterator = 'neighbor'})
        end)
    end)
end

g.test_recovery_rebuild = function(cg)
    cg.server:exec(function()
        local s = box.schema.space.create('test', {
            format = {
                {name = 'id', type = 'unsigned'},
                {name = 'vec', type = 'array'},
            },
        })
        s:create_index('pk')
        s:create_index('vec', {
            type = 'vector',
            unique = false,
            parts = {{field = 'vec', type = 'array'}},
            dimension = 2,
            distance = 'l2',
            ef_search = 16,
        })
        s:insert({1, {0, 0}})
        s:insert({2, {2, 0}})
        s:insert({3, {0, 3}})
        box.snapshot()
    end)

    cg.server:restart()

    cg.server:exec(function()
        local idx = box.space.test.index.vec
        t.assert_equals(idx.distance, 'l2')
        t.assert_equals(idx.algorithm, 'hnsw')
        t.assert_equals(idx:len(), 3)
        t.assert(idx:bsize() > 0)

        local rows = idx:select({{0, 0}}, {
            iterator = 'neighbor',
            limit = 3,
        })
        t.assert_equals({rows[1][1], rows[2][1], rows[3][1]}, {1, 2, 3})
    end)
end
