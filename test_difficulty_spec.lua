-- Difficulty guarantees for Aquarium (see docs/dev/TESTING.md, "Difficulty
-- specs"). Levels: easy = every clue shown, tier 1 (bounds on single lines);
-- medium/hard = tier 2 (exact line reasoning), more hidden clues and smaller
-- tanks. Tier 3 (trial) is never allowed.
local DIR = debug.getinfo(1, "S").source:sub(2):match("(.*[/\\])") or "./"

package.preload["gettext"] = function()
    return setmetatable({}, { __call = function(_, s) return s end })
end
package.path = DIR .. "common/?.lua;" .. DIR .. "?.lua;" .. package.path

describe("Aquarium difficulty", function()
    local Board, Solver
    local LEVELS = { "easy", "medium", "hard" }

    setup(function()
        Board  = require("board")
        Solver = require("solver")
    end)

    local function newBoard(n, diff, seed)
        math.randomseed(seed or 42)
        return Board:new({ n = n or 6, difficulty = diff or "easy" })
    end

    -- the serialized puzzle without the timer (which reads the clock)
    local function strip(b)
        local d = b:serialize()
        d.timer = nil
        return d
    end

    local function hidden(b)
        local h = 0
        for k = 1, b.n do
            if b.row_clues[k] == false then h = h + 1 end
            if b.col_clues[k] == false then h = h + 1 end
        end
        return h
    end

    it("the level table is ordered: smaller tanks, more hidden clues, tier never 3", function()
        local L = Board.LEVELS
        assert.is_true(L.easy.avg_tank > L.medium.avg_tank)
        assert.is_true(L.medium.avg_tank > L.hard.avg_tank)
        for _, n in ipairs(Board.SIZES) do
            assert.are.equal(0, L.easy.max_hide(n))
            assert.is_true(L.medium.max_hide(n) < L.hard.max_hide(n))
        end
        assert.are.equal(1, L.easy.tier)
        for _, d in ipairs(LEVELS) do assert.is_true(L[d].tier <= 2) end
    end)

    it("easy shows every clue and needs only tier-1 logic", function()
        for seed = 1, 10 do
            local b = newBoard(8, "easy", seed)
            for i = 1, b.n do
                assert.is_truthy(b.row_clues[i])
                assert.is_truthy(b.col_clues[i])
            end
            local st, tier = Solver.solve(b:getProblem(), 1)
            assert.are.equal("solved", st)
            assert.are.equal(1, tier)
        end
    end)

    -- 1.1.0: the progress bar's callback must not change the puzzle a
    -- seed gives (the timer is left out: it reads the clock), and a
    -- generation stays far below the old worst cases (238 ms on 10x10
    -- hard on a desktop; the bound is generous for slow test runs).
    it("reports progress without changing the puzzle, within a time bound", function()
        for _, n in ipairs(Board.SIZES) do
            for _, diff in ipairs({ "medium", "hard" }) do
                for seed = 1, 2 do
                    local plain = newBoard(n, diff, seed * 7 + n)
                    local fractions = {}
                    math.randomseed(seed * 7 + n)
                    local b = Board:new({ n = n, difficulty = diff, generate = false })
                    local t0 = os.clock()
                    b:generate(n, diff, function(f) fractions[#fractions + 1] = f end)
                    assert.is_true(os.clock() - t0 < 10)
                    assert.are.same(strip(plain), strip(b))
                    assert.is_true(#fractions > 0)
                    for i, f in ipairs(fractions) do
                        assert.is_true(f >= 0 and f <= 1)
                        if i > 1 then assert.is_true(f >= fractions[i - 1]) end
                    end
                end
            end
        end
    end)

    it("every puzzle has exactly one solution (independent count) and the solver finds it", function()
        local cases = { { 6, 12 }, { 8, 8 }, { 10, 4 } }
        for _, case in ipairs(cases) do
            local n, seeds = case[1], case[2]
            for _, diff in ipairs(LEVELS) do
                for seed = 1, seeds do
                    local b = newBoard(n, diff, seed * 31 + n)
                    local P = b:getProblem()
                    local count, exhausted = Solver.count(P, 2, 500000)
                    assert.is_false(exhausted)
                    assert.are.equal(1, count)
                    local st, tier, S = Solver.solve(P, 3)
                    assert.are.equal("solved", st)
                    assert.is_true(tier <= Board.LEVELS[diff].tier)
                    -- the deduced levels reproduce the stored solution
                    local opt = Solver.assignment(S)
                    for t, tk in ipairs(b.tanks) do
                        local level = tk.rows[opt[t]]
                        for _, p in ipairs(tk.cells) do
                            local wet = level ~= nil and p[1] >= level
                            assert.are.equal(b.solution[p[1]][p[2]], wet)
                        end
                    end
                end
            end
        end
    end)

    -- 1.2.0: a grid whose plain dig falls short of the level is dug
    -- again, seeking the clues that need line reasoning (tier 2), and a
    -- layout gets several sets of water levels. Hard on 8x8 and 10x10
    -- and medium on 10x10 then always reach tier 2 (8x8 medium: 99%,
    -- 1.1.0: 84%), and 6x6 does more often than before.
    it("medium and hard reach line reasoning", function()
        for _, n in ipairs({ 8, 10 }) do
            for seed = 1, 4 do
                assert.are.equal(2, newBoard(n, "hard", seed).tier)
                if n == 10 then assert.are.equal(2, newBoard(n, "medium", seed).tier) end
            end
        end
        local reached = 0
        for seed = 1, 10 do
            if newBoard(6, "hard", seed).tier == 2 then reached = reached + 1 end
        end
        assert.is_true(reached >= 5)
    end)

    -- Trial reasoning (tier 3) plays as guessing on paper: no level may
    -- need it. Hard is harder through more hidden clues instead.
    it("never needs trial reasoning; hard hides more clues than medium", function()
        local med, hard = 0, 0
        for seed = 1, 8 do
            for _, diff in ipairs(LEVELS) do
                local b = newBoard(8, diff, seed)
                local st = Solver.solve(b:getProblem(), 2)
                assert.are.equal("solved", st)
                if diff == "medium" then med = med + hidden(b) end
                if diff == "hard" then hard = hard + hidden(b) end
            end
        end
        assert.is_true(hard > med)
    end)

    -- On averages over seeds, per size: tier, hidden clues and tank count
    -- all go up from easy to hard (tier and hidden clues may tie between
    -- neighbours on one measure, never on all of them).
    it("levels are distinct and ordered on averages over seeds", function()
        local SEEDS = 6
        for _, n in ipairs({ 6, 8 }) do
            local avg = {}
            for _, diff in ipairs(LEVELS) do
                local t, h, k = 0, 0, 0
                for seed = 1, SEEDS do
                    local b = newBoard(n, diff, 100 + seed)
                    t, h, k = t + b.tier, h + hidden(b), k + #b.tanks
                end
                avg[diff] = { tier = t / SEEDS, hidden = h / SEEDS, tanks = k / SEEDS }
            end
            local e, m, h = avg.easy, avg.medium, avg.hard
            assert.is_true(e.tier <= m.tier and m.tier <= h.tier)
            assert.is_true(e.hidden < m.hidden and m.hidden < h.hidden)
            assert.is_true(e.tanks < m.tanks and m.tanks < h.tanks)
        end
    end)

    -- Generation is capped by solver runs, never by time: with a clock that
    -- jumps 1000 s at every read, a seed still gives the same puzzle.
    it("the same seed gives the same puzzle, and generation never reads the clock", function()
        local oc, ot = os.clock, os.time
        for _, n in ipairs({ 6, 8 }) do
            for _, diff in ipairs(LEVELS) do
                local a = strip(newBoard(n, diff, 9 + n))
                local b = strip(newBoard(n, diff, 9 + n))
                assert.are.same(a, b)
                local t = 0
                os.clock = function() t = t + 1000; return t end
                os.time = function(x) if x then return ot(x) end; t = t + 1000; return t end
                local ok, c = pcall(function() return strip(newBoard(n, diff, 9 + n)) end)
                os.clock, os.time = oc, ot
                assert.is_true(ok, tostring(c))
                assert.are.same(a, c)
            end
        end
        for _, f in ipairs({ "board.lua", "solver.lua" }) do
            local src = assert(io.open(DIR .. f)):read("*a")
            assert.is_nil(src:find("os%.clock"), f)
            assert.is_nil(src:find("os%.time"), f)
        end
    end)
end)
