-- Shell, file and LuaLS helpers for the Lua tools (run with yue -e). No Deno (spec §5).
local Lib = {}
Lib.windows = package.config:sub(1, 1) == '\\'

function Lib.quote(text)
    if Lib.windows then return '"' .. text .. '"' end
    return "'" .. text:gsub("'", "'\\''") .. "'"
end

---Converts a path to the platform's separators.
function Lib.native(path)
    if Lib.windows then return (path:gsub('/', '\\')) end
    return path
end

---Forward slashes, for Pkl and URIs.
function Lib.slash(path) return (path:gsub('\\', '/')) end

---Runs a command line, in `cwd` if given. Returns the exit code and the combined output.
function Lib.run(command, cwd)
    local line = command .. ' 2>&1'
    if cwd then line = (Lib.windows and 'cd /d ' or 'cd ') .. Lib.quote(Lib.native(cwd)) .. ' && ' .. line end
    -- cmd.exe strips the outer quotes of a line that starts with a quote; wrap it once more.
    if Lib.windows then line = '"' .. line .. '"' end
    local pipe = assert(io.popen(line, 'r'))
    local output = pipe:read('a')
    local _, _, code = pipe:close()
    return code or 0, output
end

function Lib.must(command, cwd)
    local code, output = Lib.run(command, cwd)
    if code ~= 0 then error(command .. ' (exit ' .. tostring(code) .. ')\n' .. output, 0) end
    return output
end

function Lib.cwd() return (Lib.must(Lib.windows and 'cd' or 'pwd'):gsub('%s+$', '')) end

function Lib.read(path)
    local file = assert(io.open(path, 'rb'))
    local text = file:read('a')
    file:close()
    return text
end

function Lib.write(path, text)
    local file = assert(io.open(path, 'wb'))
    file:write(text)
    file:close()
end

function Lib.copy(from, to) Lib.write(to, Lib.read(from)) end

function Lib.mkdir(path)
    if Lib.windows then
        Lib.must('if not exist ' .. Lib.quote(Lib.native(path)) .. ' mkdir ' .. Lib.quote(Lib.native(path)))
    else
        Lib.must('mkdir -p ' .. Lib.quote(path))
    end
end

function Lib.copyTree(from, to)
    if Lib.windows then
        Lib.must('xcopy /e /i /q /y ' .. Lib.quote(Lib.native(from)) .. ' ' .. Lib.quote(Lib.native(to)))
    else
        Lib.mkdir(to)
        Lib.must('cp -R ' .. Lib.quote(from) .. '/. ' .. Lib.quote(to))
    end
end

function Lib.remove(path) os.remove(path) end

---Every file under `dir` whose name ends with `suffix`, as paths relative to the current directory, sorted.
function Lib.files(dir, suffix)
    local prefix = Lib.slash(Lib.cwd()) .. '/'
    local output = Lib.windows
        and Lib.must('dir /s /b ' .. Lib.quote(Lib.native(dir) .. '\\*' .. suffix))
        or Lib.must('find ' .. Lib.quote(dir) .. ' -type f -name ' .. Lib.quote('*' .. suffix))
    local files = {}
    for line in output:gmatch('[^\r\n]+') do
        local path = Lib.slash(line)
        if path:sub(1, #prefix) == prefix then path = path:sub(#prefix + 1) end
        files[#files + 1] = path
    end
    table.sort(files)
    return files
end

---A small JSON decoder for LuaLS reports: objects, arrays, strings, numbers, true, false and null (as nil).
function Lib.decodeJson(text)
    local position = 1
    local value
    local function skip() position = text:find('[^ \t\r\n]', position) or #text + 1 end
    local function fail(what) error('invalid JSON at ' .. position .. ': ' .. what, 0) end
    local escapes = {['"'] = '"', ['\\'] = '\\', ['/'] = '/', b = '\b', f = '\f', n = '\n', r = '\r', t = '\t'}
    local function str()
        local parts = {}
        position = position + 1
        while true do
            local char = text:sub(position, position)
            if char == '' then fail('unterminated string') end
            if char == '"' then position = position + 1; return table.concat(parts) end
            if char == '\\' then
                local kind = text:sub(position + 1, position + 1)
                if kind == 'u' then
                    parts[#parts + 1] = utf8.char(tonumber(text:sub(position + 2, position + 5), 16))
                    position = position + 6
                else
                    parts[#parts + 1] = escapes[kind] or fail('bad escape')
                    position = position + 2
                end
            else
                parts[#parts + 1] = char
                position = position + 1
            end
        end
    end
    function value()
        skip()
        local char = text:sub(position, position)
        if char == '{' then
            local object = {}
            position = position + 1; skip()
            if text:sub(position, position) == '}' then position = position + 1; return object end
            while true do
                skip()
                local key = str()
                skip()
                if text:sub(position, position) ~= ':' then fail('expected :') end
                position = position + 1
                object[key] = value()
                skip()
                local following = text:sub(position, position)
                position = position + 1
                if following == '}' then return object end
                if following ~= ',' then fail('expected , or }') end
            end
        elseif char == '[' then
            local array = {}
            position = position + 1; skip()
            if text:sub(position, position) == ']' then position = position + 1; return array end
            while true do
                array[#array + 1] = value()
                skip()
                local following = text:sub(position, position)
                position = position + 1
                if following == ']' then return array end
                if following ~= ',' then fail('expected , or ]') end
            end
        elseif char == '"' then
            return str()
        elseif text:sub(position, position + 3) == 'true' then
            position = position + 4; return true
        elseif text:sub(position, position + 4) == 'false' then
            position = position + 5; return false
        elseif text:sub(position, position + 3) == 'null' then
            position = position + 4; return nil
        else
            local number = text:match('^-?%d+%.?%d*[eE]?[-+]?%d*', position)
            if not number or number == '' then fail('unexpected ' .. char) end
            position = position + #number
            return tonumber(number)
        end
    end
    local result = value()
    skip()
    if position <= #text then fail('trailing text') end
    return result
end

---Runs LuaLS over `project` and returns its report: a table from file URI to a list of diagnostics.
function Lib.diagnose(luals, project, name)
    local version = Lib.must(Lib.quote(luals) .. ' --version')
    if not version:find('3.19.1', 1, true) then error('LuaLS 3.19.1 is required, found: ' .. version, 0) end
    local parent = project:match('^(.*)/[^/]+$')
    local report = parent .. '/' .. name .. '.json'
    Lib.remove(report)
    local _, output = Lib.run(Lib.quote(luals) .. ' ' .. table.concat({
        '--check=' .. Lib.quote(Lib.native(project)),
        '--checklevel=Hint',
        '--check_format=json',
        '--check_out_path=' .. Lib.quote(Lib.native(report)),
        '--logpath=' .. Lib.quote(Lib.native(parent .. '/' .. name .. '-logs')),
        '--metapath=' .. Lib.quote(Lib.native(parent .. '/luals-meta')),
    }, ' '))
    Lib.write(parent .. '/' .. name .. '.log', output)
    local ok, text = pcall(Lib.read, report)
    if not ok then error('LuaLS wrote no report for ' .. project .. ':\n' .. output, 0) end
    return Lib.decodeJson(text) or {}
end

---Compares a report with the `-- EXPECT <code>` markers of `fixture`, reported as a file named `reportedName`. A
---diagnostic in any other file fails. Returns the number of expected diagnostics.
function Lib.expectMarked(fixture, report, reportedName, label)
    local expected, actual = {}, {}
    local line = 0
    for text in (Lib.read(fixture):gsub('\r', '') .. '\n'):gmatch('(.-)\n') do
        local code = text:match('%-%- EXPECT ([%w%-]+)')
        if code then expected[#expected + 1] = line .. ':' .. code end
        line = line + 1
    end
    for file, diagnostics in pairs(report) do
        for _, diagnostic in ipairs(diagnostics) do
            if file:sub(-#reportedName - 1) ~= '/' .. reportedName then
                error(label .. ': unexpected diagnostic in ' .. file .. ': ' .. diagnostic.code .. ' ' ..
                    diagnostic.message, 0)
            end
            actual[#actual + 1] = diagnostic.range.start.line .. ':' .. diagnostic.code
        end
    end
    table.sort(expected); table.sort(actual)
    if table.concat(expected, ' ') ~= table.concat(actual, ' ') then
        error(label .. ': expected ' .. table.concat(expected, ' ') .. '; got ' .. table.concat(actual, ' '), 0)
    end
    return #actual
end

return Lib
