--!nonstrict
-- Scans declarations without evaluating Lua. Callers drive step(); asynchronous
-- reads only store results and wake the caller. Limits retain partial results.
local parser = {}
local FILE_CAP, TOKEN_CAP, LITERAL_CAP, IDENT_CAP = 131072, 32768, 8192, 128
local FILES_CAP, DEPTH_CAP, TOTAL_CAP, READ_CAP = 64, 16, 1048576, 160

local function diagnostic(list, file, line, code, message)
    list[#list + 1] = {file = file, line = line, code = code, message = message, severity = "warning"}
end

local function space(c)
    return c == " " or c == "\t" or c == "\n" or c == "\r" or c == "\v" or c == "\f"
end

local function letter(c)
    local b = string.byte(c)
    return b ~= nil and (b >= 65 and b <= 90 or b >= 97 and b <= 122 or b == 95)
end

local function digit(c)
    local b = string.byte(c)
    return b ~= nil and b >= 48 and b <= 57
end

local function hex(c)
    local b = string.byte(c)
    if not b then return nil end
    if b >= 48 and b <= 57 then return b - 48 end
    if b >= 65 and b <= 70 then return b - 55 end
    if b >= 97 and b <= 102 then return b - 87 end
    return nil
end

local function utf8char(n)
    if n < 128 then return string.char(n) end
    if n < 2048 then return string.char(192 + math.floor(n / 64), 128 + n % 64) end
    if n < 65536 then
        return string.char(224 + math.floor(n / 4096), 128 + math.floor(n / 64) % 64, 128 + n % 64)
    end
    return string.char(240 + math.floor(n / 262144), 128 + math.floor(n / 4096) % 64,
        128 + math.floor(n / 64) % 64, 128 + n % 64)
end

local function trim(s)
    local first, last = 1, #s
    while first <= last and space(string.sub(s, first, first)) do first = first + 1 end
    while last >= first and space(string.sub(s, last, last)) do last = last - 1 end
    return string.sub(s, first, last)
end

local Scanner = {}
Scanner.__index = Scanner

function Scanner:warn(line, code, message)
    if #self.diagnostics < 64 then diagnostic(self.diagnostics, self.path, line, code, message) end
end

function Scanner:append(s)
    if self.length + #s > LITERAL_CAP then
        if not self.invalid then self:warn(self.startLine, "literal-limit", "Literal exceeds the decoded byte limit") end
        self.invalid = true
    elseif not self.invalid then
        self.buffer[#self.buffer + 1] = s
    end
    self.length = math.min(LITERAL_CAP + 1, self.length + #s)
end

function Scanner:badString(message)
    if not self.invalid then self:warn(self.startLine, "string", message) end
    self.invalid = true
end

function Scanner:emit(kind, value)
    if #self.tokens >= TOKEN_CAP then
        self:warn(self.line, "token-limit", "Token limit reached; remaining source skipped")
        self.phase = "finish"
        return
    end
    local token = {kind = kind, value = value, line = self.startLine}
    if kind == "id" and value == "hl" then token.header = self.header end
    local index = #self.tokens + 1
    self.tokens[index] = token
    if kind == "symbol" then
        if value == "(" or value == "{" or value == "[" then
            token.separators = {}
            self.stack[#self.stack + 1] = index
        elseif value == ")" or value == "}" or value == "]" then
            local opening = self.tokens[self.stack[#self.stack]]
            local expected = value == ")" and "(" or value == "}" and "{" or "["
            if opening and opening.value == expected then
                opening.close = index

                self.stack[#self.stack] = nil
            else
                self:warn(token.line, "delimiter", "Unmatched closing delimiter")
            end
        elseif value == "," or value == ";" then
            local opening = self.tokens[self.stack[#self.stack]]
            if opening and (value == "," or opening.value == "{") then
                opening.separators[#opening.separators + 1] = index
            end
        end
    end
    self.work = self.work + 1
end

function Scanner:finishIdentifier()
    if self.length > IDENT_CAP then self:warn(self.startLine, "identifier-limit", "Identifier exceeds the byte limit") end
    self:emit("id", self.length <= IDENT_CAP and table.concat(self.buffer) or nil)
    self.buffer, self.mode = nil, "normal"
end

function Scanner:finishString()
    self:emit(self.invalid and "invalid-string" or "string", not self.invalid and table.concat(self.buffer) or nil)
    self.buffer = nil
    self.mode = "normal"
end

function Scanner:finishComment()
    -- Only bounded comment text is inspected, never a whole-source pattern.
    if not self.invalid then
        local body = trim(table.concat(self.buffer))
        if #body >= 6 and string.sub(body, 1, 3) == "===" and string.sub(body, -3) == "==="
            and string.sub(body, 4, 4) ~= "=" and string.sub(body, -4, -4) ~= "=" then
            local name = trim(string.sub(body, 4, -4))
            if name ~= "" then self.header = name end
        end
    end
    self.buffer = nil
    self.mode = "normal"
end

local escapes = {a = "\a", b = "\b", f = "\f", n = "\n", r = "\r", t = "\t", v = "\v",
    ["\\"] = "\\", ["\""] = "\"", ["'"] = "'"}

function Scanner:lex()
    local c = string.sub(self.text, self.pos, self.pos)
    local mode = self.mode
    local consume = true
    if mode == "normal" then
        self.startLine = self.line
        if space(c) then

        elseif letter(c) then
            self.mode, self.buffer, self.length = "id", {c}, 1
        elseif digit(c) then
            self.mode, self.numberPrevious = "number", c
        elseif c == "'" or c == '"' then
            self.mode, self.quote, self.buffer, self.length, self.invalid = "quote", c, {}, 0, false
            self.escape = nil
        elseif c == "." then
            self.mode, self.dots = "dot", 1
        elseif c == "-" then
            self.mode = "dash"
        elseif c == "[" then
            self.mode, self.probeStart, self.equals, self.commentProbe = "probe", self.pos, 0, false
        else
            self:emit("symbol", c)
        end
    elseif mode == "id" then
        if letter(c) or digit(c) then
            self.length = self.length + 1
            if self.length <= IDENT_CAP then self.buffer[#self.buffer + 1] = c end
        else
            self:finishIdentifier()
            consume = false
        end
    elseif mode == "number" then
        if letter(c) or digit(c) or c == "." or ((c == "+" or c == "-") and string.find("eEpP", self.numberPrevious, 1, true)) then
            self.numberPrevious = c
        else
            self:emit("number", nil)
            self.mode, consume = "normal", false
        end
    elseif mode == "dot" then
        if c == "." then
            self.dots = self.dots + 1
            if self.dots == 3 then self:emit("symbol", "..."); self.mode = "normal" end
        else
            self:emit("symbol", self.dots == 1 and "." or "..")
            self.mode, consume = "normal", false
        end
    elseif mode == "dash" then
        if c == "-" then
            self.mode = "comment-start"
        else
            self:emit("symbol", "-")
            self.mode, consume = "normal", false
        end
    elseif mode == "comment-start" then
        self.buffer, self.length, self.invalid = {}, 0, false
        if c == "[" then
            self.mode, self.equals, self.commentProbe = "probe", 0, true
        else
            self.mode, consume = "comment", false
        end
    elseif mode == "probe" then
        if c == "=" then
            self.equals = self.equals + 1
        elseif c == "[" then
            self.mode, self.closing, self.closeEquals = "long", false, 0
            self.longComment, self.initialNewline, self.longNewline = self.commentProbe, true, nil
            self.buffer, self.length, self.invalid = {}, 0, false
        elseif self.commentProbe then
            self.mode, self.invalid, consume = "comment", true, false
        else
            self:emit("symbol", "[")
            -- Replay only the equals signs, which cannot contain newlines.
            self.pos = self.probeStart + 1
            self.mode, consume = "normal", false
        end
    elseif mode == "comment" then
        if c == "\n" or c == "\r" then
            self:finishComment()
        elseif not self.invalid then
            if self.length < LITERAL_CAP then
                self.buffer[#self.buffer + 1], self.length = c, self.length + 1
            else
                self.invalid = true
            end
        end
    elseif mode == "long" then
        if self.initialNewline == true and (c == "\n" or c == "\r") then
            self.initialNewline = c
        elseif (self.initialNewline == "\r" and c == "\n") or (self.initialNewline == "\n" and c == "\r") then
            self.initialNewline = false
        else
            self.initialNewline = false
            if self.closing and c == "=" then
                self.closeEquals = self.closeEquals + 1
            elseif self.closing and c == "]" and self.closeEquals == self.equals then
                if self.longComment then self.mode, self.buffer = "normal", nil else self:finishString() end
            else
                if self.closing and not self.longComment then
                    self:append("]")
                    self:append(string.rep("=", math.min(self.closeEquals, LITERAL_CAP + 1)))
                end
                self.closing, self.closeEquals = c == "]", 0
                if not self.longComment then
                    if c == "\r" or c == "\n" then
                        if self.longNewline and self.longNewline ~= c then
                            self.longNewline = nil
                        else
                            self:append("\n")
                            self.longNewline = c
                        end
                    else
                        self.longNewline = nil
                        if c ~= "]" then self:append(c) end
                    end
                end
            end
        end
    elseif mode == "quote" then
        local escape = self.escape
        if escape == "z" then
            if not space(c) then self.escape, consume = nil, false end
        elseif escape == "decimal" then
            if digit(c) and self.escapeDigits < 3 then
                self.escapeValue = self.escapeValue * 10 + tonumber(c)
                self.escapeDigits = self.escapeDigits + 1
            else
                if self.escapeValue > 255 then self:badString("Decimal escape is out of range") else self:append(string.char(self.escapeValue)) end
                self.escape, consume = nil, false
            end
        elseif escape == "hex" then
            local n = hex(c)
            if n then
                self.escapeValue = self.escapeValue * 16 + n
                self.escapeDigits = self.escapeDigits + 1
                if self.escapeDigits == 2 then self:append(string.char(self.escapeValue)); self.escape = nil end
            else
                self:badString("Invalid hexadecimal escape")
                self.escape, consume = nil, false
            end
        elseif escape == "unicode-start" then
            if c == "{" then self.escape = "unicode" else self:badString("Invalid Unicode escape"); self.escape, consume = nil, false end
        elseif escape == "unicode" then
            local n = hex(c)
            if n then
                self.escapeDigits = self.escapeDigits + 1
                self.escapeValue = math.min(1114112, self.escapeValue * 16 + n)
            elseif c == "}" then
                local value = self.escapeValue
                if self.escapeDigits == 0 or value > 1114111 or (value >= 55296 and value <= 57343) then
                    self:badString("Invalid Unicode code point")
                else
                    self:append(utf8char(value))
                end
                self.escape = nil
            else
                self:badString("Invalid Unicode escape")
                self.escape, consume = nil, false
            end
        elseif escape == "after-cr" then
            self.escape = nil
            if c ~= "\n" then consume = false end
        elseif escape == "start" then
            self.escape = nil
            if escapes[c] then self:append(escapes[c])
            elseif digit(c) then self.escape, self.escapeValue, self.escapeDigits = "decimal", tonumber(c), 1
            elseif c == "x" or c == "u" then
                self.escape, self.escapeValue, self.escapeDigits = c == "x" and "hex" or "unicode-start", 0, 0
            elseif c == "z" then self.escape = "z"
            elseif c == "\n" or c == "\r" then
                self:append("\n")
                if c == "\r" then self.escape = "after-cr" end
            else self:badString("Unknown quoted-string escape") end
        elseif c == "\\" then self.escape = "start"
        elseif c == self.quote then self:finishString()
        else
            if c == "\n" or c == "\r" then self:badString("Unescaped newline in quoted string") end
            self:append(c)
        end
    end
    if consume then
        if c == "\r" or c == "\n" and not self.previousCR then self.line = self.line + 1 end
        self.previousCR = c == "\r"
        self.pos, self.bytes = self.pos + 1, self.bytes + 1
    end
end

function Scanner:endLex()
    local mode = self.mode
    if mode == "id" then
        self:finishIdentifier()
    elseif mode == "number" then self:emit("number", nil)
    elseif mode == "dash" then self:emit("symbol", "-")
    elseif mode == "dot" then self:emit("symbol", self.dots == 1 and "." or "..")
    elseif mode == "probe" and not self.commentProbe then
        self:emit("symbol", "[")
        self.pos, self.mode = self.probeStart + 1, "normal"
        return
    elseif mode == "quote" or mode == "long" then
        self:warn(self.startLine, "unterminated", "Unterminated string or long comment")
        if mode == "quote" or not self.longComment then self.invalid = true; self:finishString() end
    elseif mode == "comment" then self:finishComment() end
    self.phase, self.buffer = "finish", nil
end

local function is(token, value)
    return token ~= nil and (token.kind == "symbol" or token.kind == "id") and token.value == value
end

local function literal(tokens, first, last)
    local token = tokens[first]
    if first == last and token and token.kind == "string" then return token.value end
    return nil
end

local function argument(tokens, opening, n)
    local token = tokens[opening]
    local separators = token.separators
    local first = n == 1 and opening + 1 or (separators[n - 1] and separators[n - 1] + 1)
    if not first then return nil, nil end
    return first, (separators[n] or token.close or (#tokens + 1)) - 1
end

function Scanner:finishBinding(pending)
    local row = pending.row
    local description = pending.desc
    if pending.hasDescription then description = pending.description end
    if description == nil or description == "" then
        row.description, row.descriptionMissing = "No description", true
    else
        row.description = description
    end
    self.events[#self.events + 1] = {kind = "binding", binding = row}
    self.pending = nil
end

function Scanner:parseOne()
    local tokens, pending = self.tokens, self.pending
    if pending then
        local opening = tokens[pending.tableIndex]
        local first, last = argument(tokens, pending.tableIndex, pending.field)
        if first and first <= last then
            local key, valueStart
            if tokens[first].kind == "id" and is(tokens[first + 1], "=") then
                key, valueStart = tokens[first].value, first + 2
            elseif is(tokens[first], "[") and tokens[first].close == first + 2
                and tokens[first + 1].kind == "string" and is(tokens[first + 3], "=") then
                key, valueStart = tokens[first + 1].value, first + 4
            end
            if key == "description" then
                pending.hasDescription, pending.description = true, literal(tokens, valueStart, last)
            elseif key == "desc" then
                pending.desc = literal(tokens, valueStart, last)
            end
        end
        pending.field = pending.field + 1
        if pending.field > #opening.separators + 1 then self:finishBinding(pending) end
        return
    end
    local index = self.cursor
    local token = tokens[index]
    if not token then self.done = true; self.text, self.tokens, self.stack = nil, nil, nil; return end
    self.cursor = index + 1
    local previous = tokens[index - 1]
    if is(previous, ".") or is(previous, ":") or is(previous, "function") then return end
    if token.kind == "id" and token.value == "hl" and is(tokens[index + 1], ".")
        and is(tokens[index + 2], "bind") and is(tokens[index + 3], "(") then
        local first, last = argument(tokens, index + 3, 1)
        local shortcut = literal(tokens, first, last)
        local row = {shortcut = shortcut or "Computed shortcut", file = self.path, line = token.line, header = token.header}
        if shortcut == nil then
            row.computed = true
            self:warn(token.line, "computed-shortcut", "Computed shortcut cannot be resolved from source")
        end
        local p = {row = row, field = 1}
        first, last = argument(tokens, index + 3, 3)
        if first and is(tokens[first], "{") and tokens[first].close == last then
            p.tableIndex = first
            self.pending = p
        else
            self:finishBinding(p)
        end
    elseif token.kind == "id" and token.value == "require" then
        local nextToken, name = tokens[index + 1], nil
        if is(nextToken, "(") then
            local first, last = argument(tokens, index + 1, 1)
            if #nextToken.separators == 0 then name = literal(tokens, first, last) end
        elseif nextToken and nextToken.kind == "string" then
            name = nextToken.value
        else
            -- A bare reference to require is not an import call.
            if not is(nextToken, "{") then return end
        end
        if name then
            self.events[#self.events + 1] = {kind = "import", name = name, file = self.path, line = token.line}
        else
            self:warn(token.line, "computed-import", "Nonliteral import skipped")
        end
    end
end

function Scanner:step(byteBudget, tokenBudget)
    if self.done then return true end
    byteBudget, tokenBudget = math.max(1, byteBudget or 1536), math.max(1, tokenBudget or 96)
    self.bytes, self.work = 0, 0
    while self.bytes < byteBudget and self.work < tokenBudget and not self.done do
        if self.phase == "lex" then
            if self.pos <= #self.text then self:lex() else self:endLex(); self.work = self.work + 1 end
        elseif self.phase == "finish" then
            local opening = self.stack[#self.stack]
            if opening then
                self:warn(self.tokens[opening].line, "delimiter", "Unclosed opening delimiter")
                self.stack[#self.stack] = nil
            else
                self.phase = "parse"
            end
            self.work = self.work + 1
        else
            self:parseOne()
            self.work = self.work + 1
        end
    end
    return self.done
end

function parser.scan(text, path)
    local job = setmetatable({text = text, path = path or "", events = {}, diagnostics = {}, done = false,
        tokens = {}, stack = {}, pos = 1, line = 1, startLine = 1, cursor = 1, mode = "normal", phase = "lex"}, Scanner)
    if #text > FILE_CAP then
        job.text = string.sub(text, 1, FILE_CAP)
        job:warn(1, "file-limit", "Source exceeds 128 KiB; scanning prefix only")
    end
    return job
end


local function normalize(path)
    local absolute = string.sub(path, 1, 1) == "/"
    local parts = {}
    for part in string.gmatch(path, "[^/]+") do
        if part == ".." then
            if #parts > 0 and parts[#parts] ~= ".." and parts[#parts] ~= "~" then
                parts[#parts] = nil
            elseif not absolute and parts[1] ~= "~" then parts[#parts + 1] = part end
        elseif part ~= "." then parts[#parts + 1] = part end
    end
    return (absolute and "/" or "") .. table.concat(parts, "/")
end

local function expand(path, home)
    if home and (path == "~" or string.sub(path, 1, 2) == "~/") then return home .. string.sub(path, 2) end
    return path
end

local Loader = {}
Loader.__index = Loader

function Loader:warn(file, line, code, message)
    diagnostic(self.diagnostics, file, line, code, message)
end

function Loader:cancel()
    self.cancelled, self.done, self.waiting, self.result = true, true, nil, nil
    self.stack, self.request = {}, nil
end

function Loader:candidates(name)
    local path = expand(name, self.host.home)
    if string.sub(path, 1, 1) ~= "/" and path ~= "~" and string.sub(path, 1, 2) ~= "~/" then
        if not string.find(path, "/", 1, true) and string.sub(path, -4) ~= ".lua" then
            path = string.gsub(path, "%.", "/")
        end
        path = self.root .. "/" .. path
    end
    path = normalize(path)
    local base = string.sub(path, -4) == ".lua" and string.sub(path, 1, -5) or path
    return {base .. ".lua", base .. "/init.lua"}
end

function Loader:startRead(request)
    local path = request.paths[request.index]
    if self.reads >= READ_CAP then
        self:warn(request.file, request.line, "read-limit", "Read attempt limit reached")
        self.request = nil
        return
    end
    self.reads = self.reads + 1
    local ticket = {}
    self.waiting = ticket
    local function receive(text)
        if self.cancelled or self.waiting ~= ticket or self.result then return end
        self.result = {text = text, failed = type(text) ~= "string"}
        if self.wake then self.wake() end
    end
    local ok, accepted = pcall(self.host.readFileAsync, path, receive)
    if (not ok or accepted == false) and not self.result then
        -- Exceptions are deliberately not echoed: they may contain source data.
        receive(nil)
    end
end

function Loader:step()
    if self.done then return false end
    if self.waiting then
        if not self.result then return false end
        local result, request = self.result, self.request
        self.result, self.waiting = nil, nil
        local path = request.paths[request.index]
        if result.failed then
            self.visited[path] = "failed"
            request.index = request.index + 1
        else
            self.visited[path] = "loaded"
            self.request = nil
            self.files = self.files + 1
            local text = result.text
            local accepted = math.min(#text, FILE_CAP, TOTAL_CAP - self.total)
            if accepted < math.min(#text, FILE_CAP) then
                self:warn(path, 1, "total-limit", "Total source limit reached; scanning prefix only")
            end
            self.total = self.total + accepted
            if #text > FILE_CAP then self:warn(path, 1, "file-limit", "Source exceeds 128 KiB; scanning prefix only") end
            text = string.sub(text, 1, accepted)
            -- Neither supported declaration nor import can exist without these
            -- literal identifier bytes. Avoid lexing unrelated theme/rule modules.
            if not string.find(text, "bind", 1, true) and not string.find(text, "require", 1, true) then text = "" end
            local scanner = parser.scan(text, path)
            self.stack[#self.stack + 1] = {scanner = scanner, event = 1, diagnostic = 1, depth = request.depth}
        end
        return true
    end
    if self.request then
        local request = self.request
        local path = request.paths[request.index]
        if not path then
            self:warn(request.file, request.line, "read-failed", "Unable to read source import or main file")
            self.request = nil
        elseif self.visited[path] == "failed" then
            request.index = request.index + 1
        elseif self.visited[path] then
            self.request = nil -- Already loaded, including ancestors: break cycles.
        elseif self.files >= FILES_CAP or self.total >= TOTAL_CAP then
            self:warn(request.file, request.line, "load-limit", "File or total source limit reached; import skipped")
            self.request = nil
        else
            self:startRead(request)
        end
        return not self.waiting or self.result ~= nil
    end
    local frame = self.stack[#self.stack]
    if not frame then self.done = true; return false end
    local scanner = frame.scanner
    -- Small, fixed batch; imports suspend their parent before its next event.
    for _ = 1, 32 do
        local d = scanner.diagnostics[frame.diagnostic]
        if d then
            self.diagnostics[#self.diagnostics + 1] = d
            frame.diagnostic = frame.diagnostic + 1
        else break end
    end
    for _ = 1, 32 do
        local event = scanner.events[frame.event]
        if not event then break end
        frame.event = frame.event + 1
        if event.kind == "binding" then
            self.bindings[#self.bindings + 1] = event.binding
        elseif frame.depth >= DEPTH_CAP then
            self:warn(event.file, event.line, "depth-limit", "Import depth limit reached; import skipped")
        elseif event.name == "" or #event.name > 4096 or string.find(event.name, "\0", 1, true) then
            self:warn(event.file, event.line, "import-path", "Invalid or oversized import path skipped")
        else
            self.request = {paths = self:candidates(event.name), index = 1, depth = frame.depth + 1,
                file = event.file, line = event.line}
            return true
        end
    end
    if frame.event <= #scanner.events or frame.diagnostic <= #scanner.diagnostics then return true end
    if scanner.done then self.stack[#self.stack] = nil else scanner:step() end
    return true
end

function parser.new(host, mainPath, wake)
    local path = normalize(expand(mainPath, host.home))
    local root = string.match(path, "^(.*)/[^/]*$") or "."
    if root == "" then root = "/" end
    return setmetatable({host = host, wake = wake, root = root, bindings = {}, diagnostics = {},
        done = false, files = 0, reads = 0, total = 0, visited = {}, stack = {},
        request = {paths = {path}, index = 1, depth = 0, file = path, line = 1}}, Loader)
end

return parser
