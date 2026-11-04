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

-- Candidate grids: MAX_ATTEMPTS tank layouts, LEVEL_ROLLS random water
-- levels on each. A new set of levels on the same tanks only changes the
-- clue values, so the solver's work on those tanks carries over: it costs
-- a fraction of a new layout.
-- MAX_SOLVES caps the whole search, counted in solver runs (never in time,
-- so that a seed gives the same puzzle on every device): on 6x6, where
-- line reasoning is rarely needed at all, it is what bounds the time, and
-- the hardest grid found so far is kept.
local MAX_ATTEMPTS = 25
local LEVEL_ROLLS  = 4
local MAX_SOLVES   = 1000

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
-- The generator builds one problem per candidate grid, with every clue,
-- and hides clues by switching their sums off (P.off): `row_sum[r]` and
-- `col_sum[c]` give the sums' indices.
local function buildProblem(n, tanks, row_clues, col_clues)
    local P = { nvars = #tanks, ksize = {}, sums = {}, row_sum = {}, col_sum = {} }
    -- per tank, how many of its cells lie in each row, and in each column
    -- at or below each level
    local in_row, in_col = {}, {}
    for t, tk in ipairs(tanks) do
        P.ksize[t] = #tk.rows + 1
        local rows, cols = {}, {}
        for _, p in ipairs(tk.cells) do
            rows[p[1]] = (rows[p[1]] or 0) + 1
            local col = cols[p[2]]
            if not col then
                col = {}
                for k = 1, #tk.rows + 1 do col[k] = 0 end
                cols[p[2]] = col
            end
            for k = 1, #tk.rows do
                if p[1] >= tk.rows[k] then col[k] = col[k] + 1 end
            end
        end
        in_row[t], in_col[t] = rows, cols
    end

    for r = 1, n do
        if row_clues[r] then
            local s = { clue = row_clues[r], vars = {}, contrib = {} }
            for t, tk in ipairs(tanks) do
                local cnt = in_row[t][r]
                if cnt then
                    local cc = {}
                    for k = 1, #tk.rows do cc[k] = (tk.rows[k] <= r) and cnt or 0 end
                    cc[#tk.rows + 1] = 0
                    s.vars[#s.vars + 1], s.contrib[#s.contrib + 1] = t, cc
                end
            end
            P.sums[#P.sums + 1] = s
            P.row_sum[r] = #P.sums
        end
    end
    for c = 1, n do
        if col_clues[c] then
            local s = { clue = col_clues[c], vars = {}, contrib = {} }
            for t = 1, #tanks do
                local cc = in_col[t][c]
                if cc then
                    s.vars[#s.vars + 1], s.contrib[#s.contrib + 1] = t, cc
                end
            end
            P.sums[#P.sums + 1] = s
            P.col_sum[c] = #P.sums
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
-- `P` is the problem with every clue shown; a try switches the hidden
-- clues' sums off (P.off) instead of building a new problem, and is solved
-- incrementally (Solver.trial) from the clues that stay shown whatever
-- happens next -- those not tried yet, or tried and kept -- with the same
-- result as a solve from scratch.
-- `seek`: first look for the clues whose hiding brings the puzzle up to
-- tier `cap` (see below) instead of hiding in plain random order; used when
-- the plain dig of a grid falls short of the level.
local function digClues(n, P, rc, cc, cap, max_hide, tier, seek, on_try)
    local order = {}
    for i = 1, 2 * n do order[i] = i end
    shuffle(order)
    if max_hide <= 0 then return rc, cc, tier end
    local function sumOf(i)
        if i <= n then return P.row_sum[i] end
        return P.col_sum[i - n]
    end
    -- cand: clues that may still be hidden, in dig order. A clue that
    -- cannot be hidden now never can later (hiding more only takes
    -- information away), so it leaves for good and joins the base.
    local cand = {}
    for t = 1, #order do cand[t] = order[t] end
    local hidden, nhidden = {}, 0
    local function offWith(with_cand, extra)
        local off = {}
        for i in pairs(hidden) do off[sumOf(i)] = true end
        if with_cand then
            for _, i in ipairs(cand) do off[sumOf(i)] = true end
        end
        if extra then off[sumOf(extra)] = true end
        return off
    end
    P.off = offWith(true)
    local base = Solver.newBase(P, cap)
    local function try(i)
        if on_try then on_try() end
        P.off = offWith(false, i)
        return Solver.trial(P, base)
    end
    local function drop(j)   -- cand[j] stays shown for good
        table.remove(cand, j)
        P.off = offWith(true)
        Solver.extendBase(P, base)
    end
    local function hide(j, t2)
        hidden[cand[j]], nhidden, tier = true, nhidden + 1, t2
        table.remove(cand, j)
    end
    -- While the hardest step is below the level's tier, each round tries
    -- every candidate and hides the first one that brings the puzzle to
    -- that tier -- or else the first one that keeps it solvable. Once the
    -- tier is reached, hiding more keeps it there (or makes the puzzle
    -- unsolvable), so the rest is a plain dig in order.
    while seek and nhidden < max_hide and tier < cap and #cand > 0 do
        local first, j = nil, 1
        local found = false
        while j <= #cand do
            local st, t2 = try(cand[j])
            if st ~= "solved" then
                drop(j)
            elseif t2 >= cap then
                hide(j, t2)
                found = true
                break
            else
                first = first or j
                j = j + 1
            end
        end
        if not found then
            if not first then break end
            hide(first, 1)
        end
    end
    local j = 1
    while nhidden < max_hide and j <= #cand do
        local st, t2 = try(cand[j])
        if st == "solved" then hide(j, t2) else drop(j) end
    end
    P.off = nil
    local R, C = {}, {}
    for k = 1, n do
        R[k] = not hidden[k] and rc[k]
        C[k] = not hidden[n + k] and cc[k]
    end
    return R, C, tier
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
        if solves >= MAX_SOLVES then break end
        local region = makeRegions(n, lv.avg_tank)
        local tanks  = buildTanks(n, region)
        local P
        for _ = 1, LEVEL_ROLLS do
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
            if P then
                for r = 1, n do P.sums[P.row_sum[r]].clue = rc[r] end
                for c = 1, n do P.sums[P.col_sum[c]].clue = cc[c] end
            else
                P = buildProblem(n, tanks, rc, cc)
            end
            tick()
            local st, tier = Solver.solve(P, lv.tier)
            if st == "solved" then
                local rc0, cc0, tier0 = rc, cc, tier
                rc, cc, tier = digClues(n, P, rc0, cc0, lv.tier, lv.max_hide(n), tier0, false, tick)
                if tier < lv.tier then
                    -- the plain dig fell short of the level: dig this grid
                    -- again, seeking the clues that need the level's tier
                    rc, cc, tier = digClues(n, P, rc0, cc0, lv.tier, lv.max_hide(n), tier0, true, tick)
                end
                if not best or tier > best.tier then
                    best = { region = region, solution = sol, row_clues = rc, col_clues = cc, tier = tier }
                end
                if tier == lv.tier then return best end
            end
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
    -- A nil would need every candidate to be stuck with all its clues
    -- shown, which has not been observed; loop anyway rather than hand the
    -- screen a nil.
    local p
    repeat p = generatePuzzle(self.n, self.difficulty, on_progress) until p
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
