local DIR = debug.getinfo(1, "S").source:sub(2):match("(.*[/\\])") or "./"

package.preload["gettext"] = function()
    return setmetatable({}, { __call = function(_, s) return s end })
end
package.path = DIR .. "common/?.lua;" .. DIR .. "?.lua;" .. package.path

describe("AquariumBoard", function()
    local Board, Solver

    setup(function()
        Board  = require("board")
        Solver = require("solver")
    end)

    local function newBoard(n, diff, seed)
        math.randomseed(seed or 42)
        return Board:new({ n = n or 6, difficulty = diff or "easy" })
    end

    -- Every tank's water must sit at one level: wet cells exactly the tank's
    -- cells at or below some row.
    local function obeysGravity(b, grid_is_wet)
        for _, tk in ipairs(b.tanks) do
            local top
            for _, p in ipairs(tk.cells) do
                if grid_is_wet(p[1], p[2]) and (not top or p[1] < top) then top = p[1] end
            end
            for _, p in ipairs(tk.cells) do
                local should = top ~= nil and p[1] >= top
                if grid_is_wet(p[1], p[2]) ~= should then return false end
            end
        end
        return true
    end

    -- Plays the solution through the public moves: flood each tank at its
    -- highest wet cell.
    local function playSolution(b)
        for _, tk in ipairs(b.tanks) do
            local best
            for _, p in ipairs(tk.cells) do
                if b.solution[p[1]][p[2]] and (not best or p[1] < best[1]) then best = p end
            end
            if best then b:flood(best[1], best[2]) end
        end
    end

    describe("generator", function()
        it("builds connected tanks covering the grid", function()
            local b = newBoard(8, "medium")
            local n = b.n
            for t, tk in ipairs(b.tanks) do
                assert.is_true(#tk.cells >= 2)
                -- flood fill from the first cell reaches every cell of the tank
                local seen, stack, reached = {}, { tk.cells[1] }, 0
                seen[tk.cells[1][1] * 100 + tk.cells[1][2]] = true
                while #stack > 0 do
                    local p = table.remove(stack)
                    reached = reached + 1
                    for _, d in ipairs({ { 1, 0 }, { -1, 0 }, { 0, 1 }, { 0, -1 } }) do
                        local r, c = p[1] + d[1], p[2] + d[2]
                        if r >= 1 and r <= n and c >= 1 and c <= n and b.region[r][c] == t
                            and not seen[r * 100 + c] then
                            seen[r * 100 + c] = true
                            stack[#stack + 1] = { r, c }
                        end
                    end
                end
                assert.are.equal(#tk.cells, reached)
            end
        end)

        it("solution obeys gravity and matches every shown clue", function()
            for _, diff in ipairs({ "easy", "medium", "hard" }) do
                local b = newBoard(8, diff, 7)
                assert.is_true(obeysGravity(b, function(r, c) return b.solution[r][c] end))
                for i = 1, b.n do
                    local rc, cc = 0, 0
                    for j = 1, b.n do
                        if b.solution[i][j] then rc = rc + 1 end
                        if b.solution[j][i] then cc = cc + 1 end
                    end
                    if b.row_clues[i] then assert.are.equal(rc, b.row_clues[i]) end
                    if b.col_clues[i] then assert.are.equal(cc, b.col_clues[i]) end
                end
            end
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

        it("every puzzle has exactly one solution (independent count) and the solver finds it", function()
            local cases = { { 6, 12 }, { 8, 8 }, { 10, 4 } }
            for _, case in ipairs(cases) do
                local n, seeds = case[1], case[2]
                for _, diff in ipairs({ "easy", "medium", "hard" }) do
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

        it("hard puzzles at 8x8 mostly need trial reasoning (tier 3)", function()
            local hard = 0
            for seed = 1, 8 do
                if newBoard(8, "hard", seed).tier == 3 then hard = hard + 1 end
            end
            assert.is_true(hard >= 6)
        end)
    end)

    describe("moves", function()
        it("tapping a dry cell floods its tank from that row down", function()
            local b = newBoard(6, "easy")
            local tk = b.tanks[1]
            local p  = tk.cells[1]   -- top-left-most cell of tank 1
            b:tap(p[1], p[2])
            for _, q in ipairs(tk.cells) do
                assert.are.equal(q[1] >= p[1], b:isWater(q[1], q[2]))
            end
            assert.is_true(obeysGravity(b, function(r, c) return b:isWater(r, c) end))
        end)

        it("tapping a wet cell drains its tank from that row up", function()
            local b = newBoard(6, "easy")
            local tk
            for _, t in ipairs(b.tanks) do if #t.rows >= 2 then tk = t; break end end
            local top = tk.cells[1]
            b:tap(top[1], top[2])
            b:tap(top[1], top[2])
            for _, q in ipairs(tk.cells) do
                assert.are.equal(q[1] > top[1], b:isWater(q[1], q[2]))
            end
            assert.is_true(obeysGravity(b, function(r, c) return b:isWater(r, c) end))
        end)

        it("long-press toggles a dot on dry cells only, water overwrites it", function()
            local b = newBoard(6, "easy")
            local p = b.tanks[1].cells[1]
            assert.is_true(b:toggleDot(p[1], p[2]))
            assert.are.equal(Board.DOT, b.cells[p[1]][p[2]])
            b:flood(p[1], p[2])
            assert.are.equal(Board.WATER, b.cells[p[1]][p[2]])
            assert.is_false(b:toggleDot(p[1], p[2]))
            -- undo brings the dot back
            assert.is_true(b:undoMove())
            assert.are.equal(Board.DOT, b.cells[p[1]][p[2]])
        end)

        it("undo reverts a whole flood in one step", function()
            local b = newBoard(6, "easy")
            local p = b.tanks[1].cells[1]
            b:flood(p[1], p[2])
            assert.is_true(b:undoMove())
            assert.are.equal(0, b:waterCount())
            assert.is_false(b:undoMove())
        end)

        it("counts water per line", function()
            local b = newBoard(6, "easy")
            playSolution(b)
            for i = 1, b.n do
                if b.row_clues[i] then assert.are.equal(b.row_clues[i], b:rowCount(i)) end
                if b.col_clues[i] then assert.are.equal(b.col_clues[i], b:colCount(i)) end
            end
        end)
    end)

    describe("win, check, reveal", function()
        it("playing the solution wins and freezes the board", function()
            local b = newBoard(8, "medium")
            assert.is_false(b.won)
            playSolution(b)
            assert.is_true(b.won)
            assert.is_false(b:tap(1, 1))
            assert.is_false(b:canUndo())
        end)

        it("check flags wet cells that should be dry and dots that should be wet", function()
            local b = newBoard(6, "easy")
            local dry, wet
            for r = 1, b.n do
                for c = 1, b.n do
                    if not b.solution[r][c] then dry = dry or { r, c } else wet = wet or { r, c } end
                end
            end
            assert.are.equal(0, b:check())
            b:toggleDot(wet[1], wet[2])
            assert.are.equal(1, b:check())
            assert.is_true(b.wrong[wet[1]][wet[2]])
            b:undoMove()
            b:flood(dry[1], dry[2])
            assert.is_true(b:check() >= 1)
            assert.is_true(b.wrong[dry[1]][dry[2]])
        end)

        it("reveal shows the solution and ends the round", function()
            local b = newBoard(6, "easy")
            b:reveal()
            assert.is_true(b.won)
            assert.is_true(b.revealed)
            for r = 1, b.n do
                for c = 1, b.n do assert.are.equal(b.solution[r][c], b:isWater(r, c)) end
            end
        end)
    end)

    describe("hint", function()
        it("successive hints solve the puzzle", function()
            local b = newBoard(8, "hard")
            for _ = 1, 200 do
                local step = b:findHint()
                if not step then break end
                assert.are.equal("fill", step.kind)
                assert.is_true(b.solution[step.r][step.c])
                assert.is_true(b:applyHint(step))
            end
            assert.is_true(b.won)
        end)

        it("reports a wrong water cell first and clearing it drains only dry cells", function()
            local b = newBoard(6, "easy")
            local dry
            for r = b.n, 1, -1 do
                for c = 1, b.n do
                    if not b.solution[r][c] then dry = { r, c }; break end
                end
                if dry then break end
            end
            b:flood(dry[1], dry[2])
            local step = b:findHint()
            assert.are.equal("mistake", step.kind)
            assert.is_true(b:applyHint(step))
            assert.is_false(b:isWater(step.r, step.c))
            -- nothing wet that the solution wants dry is left behind
            for r = 1, b.n do
                for c = 1, b.n do
                    if b:isWater(r, c) then assert.is_true(b.solution[r][c]) end
                end
            end
        end)

        it("a dot is not a mistake on a dry cell", function()
            local b = newBoard(6, "easy")
            for r = 1, b.n do
                for c = 1, b.n do
                    if not b.solution[r][c] then b:toggleDot(r, c) end
                end
            end
            local step = b:findHint()
            assert.are.equal("fill", step.kind)
        end)
    end)

    describe("serialize / load", function()
        it("round-trips tanks, clues (hidden ones too), cells and flags", function()
            local b = newBoard(8, "hard", 5)
            local p = b.tanks[2].cells[1]
            b:flood(p[1], p[2])
            local q = b.tanks[3].cells[1]
            b:toggleDot(q[1], q[2])
            local data = b:serialize()

            local b2 = Board:new({ generate = false })
            assert.is_true(b2:load(data))
            assert.are.equal(b.n, b2.n)
            assert.are.equal(b.difficulty, b2.difficulty)
            for i = 1, b.n do
                assert.are.equal(b.row_clues[i], b2.row_clues[i])
                assert.are.equal(b.col_clues[i], b2.col_clues[i])
            end
            for r = 1, b.n do
                for c = 1, b.n do
                    assert.are.equal(b.region[r][c], b2.region[r][c])
                    assert.are.equal(b.solution[r][c], b2.solution[r][c])
                    assert.are.equal(b.cells[r][c], b2.cells[r][c])
                end
            end
            assert.are.equal(#b.tanks, #b2.tanks)
        end)

        it("saving does not stop the clock", function()
            local b = newBoard(6, "easy")
            b:serialize()
            assert.is_true(b.timer:isRunning())
        end)

        it("rejects invalid data", function()
            local b = Board:new({ generate = false })
            assert.is_false(b:load(nil))
            assert.is_false(b:load({}))
            assert.is_false(b:load({ n = 6, region = { 1, 2 } }))
        end)
    end)
end)
