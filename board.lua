local _dir = debug.getinfo(1, "S").source:sub(2):match("(.*[/\\])") or "./"
local function lrequire(name)
    local key = _dir .. name
    if not package.loaded[key] then
        package.loaded[key] = assert(loadfile(_dir .. name .. ".lua"))()
    end
    return package.loaded[key]
end

local UndoStack  = require("undo_stack")
local Timer      = require("timer")
local Hint       = require("hint")
local grid_utils = require("grid_utils")

local Solver = lrequire("solver")

local shuffle   = grid_utils.shuffle
local emptyGrid = grid_utils.emptyGrid

-- Player cell states. Water is the only state that decides the puzzle; a dot
-- is the player's own "this stays dry" note.
local EMPTY = 0
local WATER = 1
local DOT   = 2

local SIZES        = { 6, 8, 10 }
local DEFAULT_N    = 8
local DEFAULT_DIFF = "medium"

local DIR4 = { { -1, 0 }, { 1, 0 }, { 0, -1 }, { 0, 1 } }

-- Per difficulty:
--   avg_tank  average tank size the region generator aims for (smaller tanks
--             make more, tighter interactions between lines);
--   tier      the solver tier the puzzle must need (see solver.lua): 1 = bound
--             reasoning on single lines, 2 = exact line reasoning. Tier 3
--             (trial: assume a level, look for a contradiction) is never
--             asked for: on paper it plays as guessing, so hard is harder
--             through more hidden clues and smaller tanks instead;
--   max_hide  how many row/column clues may be hidden (function of n). Easy
--             shows every clue.
local LEVELS = {
    easy   = { avg_tank = 4.5, tier = 1, max_hide = function()  return 0 end },
    medium = { avg_tank = 3.5, tier = 2, max_hide = function(n) return math.floor(n / 3) end },
    hard   = { avg_tank = 3.0, tier = 2, max_hide = function(n) return 2 * n end },
}

local MAX_ATTEMPTS = 50

-- ---------------------------------------------------------------------------
-- Generator
-- ---------------------------------------------------------------------------

-- Tanks: start from one tank per cell and merge random neighbouring pairs
-- (never past a size cap) until the target count is reached, then fold any
-- leftover single cells into a neighbour. Returns region[r][c] = 1..T.
local function makeRegions(n, avg)
    local reg, size = {}, {}
    for r = 1, n do
        reg[r] = {}
        for c = 1, n do
            local id = (r - 1) * n + c
            reg[r][c], size[id] = id, 1
        end
    end
    local count  = n * n
    local target = math.floor(n * n / avg + 0.5)
    local cap    = math.floor(avg * 1.8 + 0.5)

    local function merge(a, b)   -- b into a
        for r = 1, n do
            for c = 1, n do
                if reg[r][c] == b then reg[r][c] = a end
            end
        end
        size[a], size[b] = size[a] + size[b], nil
        count = count - 1
    end

    local tries = 0
    while count > target and tries < 20000 do
        tries = tries + 1
        local r, c = math.random(n), math.random(n)
        local d = DIR4[math.random(4)]
        local r2, c2 = r + d[1], c + d[2]
        if r2 >= 1 and r2 <= n and c2 >= 1 and c2 <= n then
            local a, b = reg[r][c], reg[r2][c2]
            if a ~= b and size[a] + size[b] <= cap then merge(a, b) end
        end
    end
    for r = 1, n do
        for c = 1, n do
            local a = reg[r][c]
            if size[a] == 1 then
                for _, d in ipairs(DIR4) do
                    local r2, c2 = r + d[1], c + d[2]
                    if r2 >= 1 and r2 <= n and c2 >= 1 and c2 <= n and reg[r2][c2] ~= a then
                        merge(reg[r2][c2], a)
                        break
                    end
                end
            end
        end
    end

    -- Renumber 1..T in reading order.
    local map, next_id = {}, 0
    for r = 1, n do
        for c = 1, n do
            local a = reg[r][c]
            if not map[a] then next_id = next_id + 1; map[a] = next_id end
            reg[r][c] = map[a]
        end
    end
    return reg, next_id
end

-- tanks[t] = { cells = { {r,c}, ... }, rows = { distinct rows, top first } }
local function buildTanks(n, region)
    local tanks = {}
    for r = 1, n do
        for c = 1, n do
            local t = region[r][c]
            tanks[t] = tanks[t] or { cells = {}, rows = {} }
            local tk = tanks[t]
            tk.cells[#tk.cells + 1] = { r, c }
            if tk.rows[#tk.rows] ~= r then tk.rows[#tk.rows + 1] = r end
        end
    end
    return tanks
end

-- The solver's view: one variable per tank, option k (1..#rows) = water up to
-- rows[k] (every tank cell at that row or below is filled), option #rows+1 =
-- dry. Each row/column clue is a sum over the tanks crossing that line.
-- `cache` (optional, one per set of tanks) keeps the sum tables between the
-- many problems a dig builds: a sum only depends on the tanks and its clue,
-- and the solver never writes to one (it memoises on it, which is why
-- sharing it pays).
local function buildProblem(n, tanks, row_clues, col_clues, cache)
    local P = { nvars = #tanks, ksize = {}, sums = {} }
    for t, tk in ipairs(tanks) do P.ksize[t] = #tk.rows + 1 end

    for r = 1, n do
        local key = cache and row_clues[r] and ("r" .. r .. ":" .. row_clues[r])
        if key and cache[key] then
            P.sums[#P.sums + 1] = cache[key]
        elseif row_clues[r] then
            local s = { clue = row_clues[r], vars = {}, contrib = {} }
            for t, tk in ipairs(tanks) do
                local cnt = 0
                for _, p in ipairs(tk.cells) do
                    if p[1] == r then cnt = cnt + 1 end
                end
                if cnt > 0 then
                    local cc = {}
                    for k = 1, #tk.rows do cc[k] = (tk.rows[k] <= r) and cnt or 0 end
                    cc[#tk.rows + 1] = 0
                    s.vars[#s.vars + 1], s.contrib[#s.contrib + 1] = t, cc
                end
            end
            P.sums[#P.sums + 1] = s
            if key then cache[key] = s end
        end
    end
    for c = 1, n do
        local key = cache and col_clues[c] and ("c" .. c .. ":" .. col_clues[c])
        if key and cache[key] then
            P.sums[#P.sums + 1] = cache[key]
        elseif col_clues[c] then
            local s = { clue = col_clues[c], vars = {}, contrib = {} }
            for t, tk in ipairs(tanks) do
                local in_col = false
                local cc = {}
                for k = 1, #tk.rows + 1 do
                    local level, cnt = tk.rows[k], 0
                    for _, p in ipairs(tk.cells) do
                        if p[2] == c then
                            in_col = true
                            if level and p[1] >= level then cnt = cnt + 1 end
                        end
                    end
                    cc[k] = cnt
                end
                if in_col then
                    s.vars[#s.vars + 1], s.contrib[#s.contrib + 1] = t, cc
                end
            end
            P.sums[#P.sums + 1] = s
            if key then cache[key] = s end
        end
    end
    return P
end

local function countLines(n, sol)
    local rc, cc = {}, {}
    for i = 1, n do rc[i], cc[i] = 0, 0 end
    for r = 1, n do
        for c = 1, n do
            if sol[r][c] then rc[r], cc[c] = rc[r] + 1, cc[c] + 1 end
        end
    end
    return rc, cc
end

-- Hides clues one by one (random order) while the puzzle stays solvable
-- within `cap`. Returns the final clues and the tier the last solve needed.
local function digClues(n, tanks, rc, cc, cap, max_hide, tier, cache, on_try)
    local order = {}
    for i = 1, 2 * n do order[i] = i end
    shuffle(order)
    local hidden = 0
    for _, i in ipairs(order) do
        if hidden >= max_hide then break end
        local R, C = {}, {}
        for k = 1, n do R[k], C[k] = rc[k], cc[k] end
        if i <= n then R[i] = false else C[i - n] = false end
        if on_try then on_try() end
        local st, t2 = Solver.solve(buildProblem(n, tanks, R, C, cache), cap)
        if st == "solved" then
            rc, cc, tier, hidden = R, C, t2, hidden + 1
        end
    end
    return rc, cc, tier
end

-- One complete puzzle for (n, difficulty). Every candidate is proven unique by
-- the solver (it deduces every tank's level); the first one whose hardest
-- step equals the level's tier wins, otherwise the hardest seen is kept.
-- Returns { region, solution, row_clues, col_clues, tier }.
-- `on_progress(fraction)`, optional, is called before every solve. The work
-- has no fixed size (a level may take one candidate or all MAX_ATTEMPTS),
-- so the fraction approaches 1 as solves pile up, against a typical run of
-- a few candidates dug through every clue.
local function generatePuzzle(n, difficulty, on_progress)
    local lv = LEVELS[difficulty] or LEVELS[DEFAULT_DIFF]
    local solves, typical = 0, 3 * (1 + 2 * n)
    local function tick()
        solves = solves + 1
        if on_progress then on_progress(solves / (solves + typical)) end
    end
    local best
    for _ = 1, MAX_ATTEMPTS do
        local region = makeRegions(n, lv.avg_tank)
        local tanks  = buildTanks(n, region)
        local sol    = emptyGrid(n, n, false)
        for _, tk in ipairs(tanks) do
            local level = tk.rows[math.random(#tk.rows + 1)]   -- nil = dry
            if level then
                for _, p in ipairs(tk.cells) do
                    if p[1] >= level then sol[p[1]][p[2]] = true end
                end
            end
        end
        local rc, cc = countLines(n, sol)
        local cache = {}
        tick()
        local st, tier = Solver.solve(buildProblem(n, tanks, rc, cc, cache), lv.tier)
        if st == "solved" then
            rc, cc, tier = digClues(n, tanks, rc, cc, lv.tier, lv.max_hide(n), tier, cache, tick)
            if not best or tier > best.tier then
                best = { region = region, solution = sol, row_clues = rc, col_clues = cc, tier = tier }
            end
            if tier == lv.tier then break end
        end
    end
    return best
end

-- ---------------------------------------------------------------------------
-- AquariumBoard
-- ---------------------------------------------------------------------------

local AquariumBoard = {}
AquariumBoard.__index = AquariumBoard

function AquariumBoard:new(opts)
    opts = opts or {}
    local obj = setmetatable({
        n          = opts.n or DEFAULT_N,
        difficulty = opts.difficulty or DEFAULT_DIFF,
        undo       = UndoStack:new{ max_size = 500 },
        timer      = Timer:new(),
        hints_used = 0,
    }, self)
    if opts.generate ~= false then obj:generate() end
    return obj
end

-- `on_progress(fraction)`: optional, for the screen's progress bar.
function AquariumBoard:generate(n, difficulty, on_progress)
    self.n          = n or self.n
    self.difficulty = difficulty or self.difficulty
    local p = generatePuzzle(self.n, self.difficulty, on_progress)
    self.region    = p.region
    self.solution  = p.solution
    self.row_clues = p.row_clues
    self.col_clues = p.col_clues
    self.tier      = p.tier
    self:_reset()
end

function AquariumBoard:_reset()
    local n = self.n
    self.tanks      = buildTanks(n, self.region)
    self.cells      = emptyGrid(n, n, EMPTY)
    self.wrong      = emptyGrid(n, n, false)
    self.won        = false
    self.revealed   = false
    self.hints_used = 0
    self.undo:clear()
    self.timer:reset()
    self.timer:start()
end

-- The solver's problem for the clues on show (tests use it).
function AquariumBoard:getProblem()
    return buildProblem(self.n, self.tanks, self.row_clues, self.col_clues)
end

-- ---------------------------------------------------------------------------
-- Moves. Water obeys gravity inside a tank, so every move changes a whole
-- band of the tank at once and the grid can never show floating water:
--   * flooding (r, c) fills every cell of its tank on row r and below;
--   * draining (r, c) empties every cell of its tank on row r and above.
-- One move = one undo entry holding every cell it touched.
-- ---------------------------------------------------------------------------

function AquariumBoard:_apply(changes)
    if #changes == 0 then return false end
    self.undo:push(changes)
    self:_checkWin()
    return true
end

function AquariumBoard:flood(r, c)
    if self.won then return false end
    local changes = {}
    for _, p in ipairs(self.tanks[self.region[r][c]].cells) do
        local pr, pc = p[1], p[2]
        if pr >= r and self.cells[pr][pc] ~= WATER then
            changes[#changes + 1] = { r = pr, c = pc, old = self.cells[pr][pc] }
            self.cells[pr][pc] = WATER
            self.wrong[pr][pc] = false
        end
    end
    return self:_apply(changes)
end

function AquariumBoard:drain(r, c)
    if self.won then return false end
    local changes = {}
    for _, p in ipairs(self.tanks[self.region[r][c]].cells) do
        local pr, pc = p[1], p[2]
        if pr <= r and self.cells[pr][pc] == WATER then
            changes[#changes + 1] = { r = pr, c = pc, old = WATER }
            self.cells[pr][pc] = EMPTY
            self.wrong[pr][pc] = false
        end
    end
    return self:_apply(changes)
end

-- Tap: a dry cell floods up to its row; a wet one drains down past it.
function AquariumBoard:tap(r, c)
    if self.cells[r][c] == WATER then return self:drain(r, c) end
    return self:flood(r, c)
end

-- Long-press: toggle the "stays dry" dot on a dry cell.
function AquariumBoard:toggleDot(r, c)
    if self.won then return false end
    local old = self.cells[r][c]
    if old == WATER then return false end
    self.cells[r][c] = (old == DOT) and EMPTY or DOT
    self.wrong[r][c] = false
    self.undo:push({ { r = r, c = c, old = old } })
    return true
end

-- Hint writes go through the same gravity moves.
function AquariumBoard:setCell(r, c, v)
    if v == WATER then return self:flood(r, c) end
    if self.cells[r][c] == WATER then return self:drain(r, c) end
    return false
end

function AquariumBoard:undoMove()
    if self.won then return false end
    local changes = self.undo:pop()
    if not changes then return false end
    for _, ch in ipairs(changes) do
        self.cells[ch.r][ch.c] = ch.old
        self.wrong[ch.r][ch.c] = false
    end
    return true
end

function AquariumBoard:canUndo()
    return not self.won and self.undo:canUndo()
end

-- ---------------------------------------------------------------------------
-- State queries
-- ---------------------------------------------------------------------------

-- Number of row/column clues kept out of view.
function AquariumBoard:hiddenCount()
    local k = 0
    for i = 1, self.n do
        if not self.row_clues[i] then k = k + 1 end
        if not self.col_clues[i] then k = k + 1 end
    end
    return k
end

function AquariumBoard:isWater(r, c)
    return self.cells[r][c] == WATER
end

-- Water counted on a line: what the clue next to it is compared against.
function AquariumBoard:rowCount(r)
    local k = 0
    for c = 1, self.n do if self.cells[r][c] == WATER then k = k + 1 end end
    return k
end

function AquariumBoard:colCount(c)
    local k = 0
    for r = 1, self.n do if self.cells[r][c] == WATER then k = k + 1 end end
    return k
end

function AquariumBoard:waterCount()
    local k = 0
    for r = 1, self.n do k = k + self:rowCount(r) end
    return k
end

function AquariumBoard:solutionCount()
    local k = 0
    for r = 1, self.n do
        for c = 1, self.n do if self.solution[r][c] then k = k + 1 end end
    end
    return k
end

-- The solution is unique (the generator proved it), so matching it is the
-- same as satisfying every clue.
function AquariumBoard:_checkWin()
    for r = 1, self.n do
        for c = 1, self.n do
            if (self.cells[r][c] == WATER) ~= self.solution[r][c] then
                self.won = false
                return false
            end
        end
    end
    self.won = true
    self.timer:stop()
    return true
end

-- Marks water where the solution is dry and dots where it is wet.
-- Returns the number of cells marked.
function AquariumBoard:check()
    local n, count = self.n, 0
    for r = 1, n do
        for c = 1, n do
            local v, s = self.cells[r][c], self.solution[r][c]
            local bad = (v == WATER and not s) or (v == DOT and s)
            self.wrong[r][c] = bad
            if bad then count = count + 1 end
        end
    end
    return count
end

function AquariumBoard:reveal()
    for r = 1, self.n do
        for c = 1, self.n do
            self.cells[r][c] = self.solution[r][c] and WATER or EMPTY
            self.wrong[r][c] = false
        end
    end
    self.revealed = true
    self.won      = true
    self.timer:stop()
end

-- ---------------------------------------------------------------------------
-- Hint: only water decides the puzzle, so a dot is "empty" and dry solution
-- cells are never offered. A wet cell that should be dry is a mistake, and
-- clearing it drains the tank down past that row -- every cell that drains
-- is dry in the solution too, since the solution obeys the same gravity.
-- ---------------------------------------------------------------------------

Hint.install(AquariumBoard, {
    getUser     = function(b, r, c) return b.cells[r][c] end,
    getSolution = function(b, r, c) return b.solution[r][c] and WATER or EMPTY end,
    isEmpty     = function(v) return v ~= WATER end,
    setCell     = function(b, r, c, v) return b:setCell(r, c, v) end,
    blank       = EMPTY,
})

-- ---------------------------------------------------------------------------
-- Persistence
-- ---------------------------------------------------------------------------

local function clueOut(t, n)
    local out = {}
    for i = 1, n do out[i] = t[i] or -1 end
    return out
end

local function clueIn(t, n)
    local out = {}
    for i = 1, n do
        local v = t[i]
        out[i] = (type(v) == "number" and v >= 0) and v or false
    end
    return out
end

function AquariumBoard:serialize()
    local n = self.n
    -- Timer:serialize() stops the clock; a save mid-game must not.
    local running = self.timer:isRunning()
    local timer   = self.timer:serialize()
    if running then self.timer:start() end
    local region, sol, cells = {}, {}, {}
    for r = 1, n do
        for c = 1, n do
            region[#region + 1] = self.region[r][c]
            sol[#sol + 1]       = self.solution[r][c] and 1 or 0
            cells[#cells + 1]   = self.cells[r][c]
        end
    end
    return {
        n          = n,
        difficulty = self.difficulty,
        region     = region,
        solution   = sol,
        cells      = cells,
        row_clues  = clueOut(self.row_clues, n),
        col_clues  = clueOut(self.col_clues, n),
        tier       = self.tier,
        won        = self.won,
        revealed   = self.revealed,
        hints_used = self.hints_used,
        timer      = timer,
    }
end

function AquariumBoard:load(data)
    if type(data) ~= "table" or type(data.region) ~= "table" then return false end
    local n = tonumber(data.n)
    if not n or #data.region ~= n * n or type(data.solution) ~= "table"
        or type(data.cells) ~= "table" then
        return false
    end
    self.n          = n
    self.difficulty = data.difficulty or DEFAULT_DIFF
    self.region     = emptyGrid(n, n, 1)
    self.solution   = emptyGrid(n, n, false)
    local idx = 1
    for r = 1, n do
        for c = 1, n do
            self.region[r][c]   = data.region[idx]
            self.solution[r][c] = data.solution[idx] == 1
            idx = idx + 1
        end
    end
    self.row_clues = clueIn(data.row_clues or {}, n)
    self.col_clues = clueIn(data.col_clues or {}, n)
    self.tier      = data.tier
    self:_reset()
    idx = 1
    for r = 1, n do
        for c = 1, n do
            self.cells[r][c] = data.cells[idx] or EMPTY
            idx = idx + 1
        end
    end
    self.won        = data.won and true or false
    self.revealed   = data.revealed and true or false
    self.hints_used = data.hints_used or 0
    self.timer:load(data.timer)
    if self.won then self.timer:stop() else self.timer:start() end
    return true
end

AquariumBoard.EMPTY        = EMPTY
AquariumBoard.WATER        = WATER
AquariumBoard.DOT          = DOT
AquariumBoard.SIZES        = SIZES
AquariumBoard.DEFAULT_N    = DEFAULT_N
AquariumBoard.DEFAULT_DIFF = DEFAULT_DIFF
AquariumBoard.LEVELS       = LEVELS
AquariumBoard._buildProblem = buildProblem
AquariumBoard._buildTanks   = buildTanks

return AquariumBoard
