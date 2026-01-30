local expression = require('internal.config.utils.expression')

local base_vars = {
    tarantool_version = _TARANTOOL:match('^%d+%.%d+%.%d+'),
}
assert(base_vars.tarantool_version ~= nil)

local function collect_vars_from_ast(node, out)
    if node == nil then return end
    if node.type == 'variable' then out[node.value] = true; return end
    if node.type == 'unary' then return collect_vars_from_ast(node.expr, out) end
    if node.type == 'operation' then
        collect_vars_from_ast(node.left, out)
        collect_vars_from_ast(node.right, out)
    end
end

local function parse_and_collect(expr)
    local ast = expression.parse(expr)
    local names = {}
    collect_vars_from_ast(ast, names)
    return ast, names
end

function eval(expr, configdata)
    opts = opts or {}

    local ast, names = parse_and_collect(expr)

    local vars = table.copy(base_vars)

    for name in pairs(names) do
        if name == 'tarantool_version' then
            -- already in vars
        elseif name:startswith('config.') then
            if configdata == nil then
                error('fail_if uses config.*, but configdata is not provided', 0)
            end

            local path = name:sub(#'config.' + 1)
            local v = configdata:get(path, {use_default = true})

            if v == nil then
                error(('Unknown config option in fail_if: %q'):format(name), 0)
            end

            vars[name] = v
        else
            error(('Unknown variable namespace in fail_if: %q'):format(name), 0)
        end
    end

    expression.validate(ast, vars)
    return expression.evaluate(ast, vars)
end

return {
    eval = eval,
}