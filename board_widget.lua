local _dir = debug.getinfo(1, "S").source:sub(2):match("(.*[/\\])") or "./"
local function lrequire(name)
    local key = _dir .. name
    if not package.loaded[key] then
        package.loaded[key] = assert(loadfile(_dir .. name .. ".lua"))()
    end
    return package.loaded[key]
end

local Blitbuffer     = require("ffi/blitbuffer")
local Font           = require("ui/font")
local Geom           = require("ui/geometry")
local GestureRange   = require("ui/gesturerange")
local InputContainer = require("ui/widget/container/inputcontainer")
local RenderText     = require("ui/rendertext")
local UIManager      = require("ui/uimanager")

local gwb      = lrequire("common/grid_widget_base")
local drawLine = gwb.drawLine

local AquariumBoard = lrequire("board")

local C_BG      = Blitbuffer.COLOR_WHITE
local C_FG      = Blitbuffer.COLOR_BLACK
local C_GRID    = Blitbuffer.COLOR_GRAY_9
local C_WATER   = Blitbuffer.COLOR_GRAY_B
local C_SURFACE = Blitbuffer.COLOR_GRAY_4
local C_DONE    = Blitbuffer.COLOR_GRAY_9

-- Largest font size whose ink box for `sample` fits (max_w, max_h). Measured
-- with an unbounded width: sizeUtf8Text truncates at its width argument.
local function bsearchFont(font_name, lo, hi, max_w, max_h, sample)
    local best = lo
    while lo <= hi do
        local mid  = math.floor((lo + hi) / 2)
        local face = Font:getFace(font_name, mid)
        local m    = RenderText:sizeUtf8Text(0, math.huge, face, sample, true, false)
        if m.x <= max_w and (m.y_top + m.y_bottom) <= max_h then
            best, lo = mid, mid + 1
        else
            hi = mid - 1
        end
    end
    return best
end

local function centeredText(bb, text, face, cx, cy, color)
    local m  = RenderText:sizeUtf8Text(0, math.huge, face, text, true, false)
    local tx = cx - math.floor(m.x / 2)
    local ty = cy + math.floor((m.y_top - m.y_bottom) / 2)
    RenderText:renderUtf8Text(bb, tx, ty, face, text, true, false, color)
end

-- ---------------------------------------------------------------------------
-- AquariumBoardWidget: column clues on top, row clues on the left (the usual
-- Aquarium layout), the grid below/right of them. Tanks are outlined by thick
-- black walls; water is a flat grey with a darker surface line.
-- ---------------------------------------------------------------------------

local AquariumBoardWidget = InputContainer:extend{
    board            = nil,
    max_size         = 0,
    cellTapCallback  = nil,
    cellHoldCallback = nil,
}

function AquariumBoardWidget:init()
    local n    = self.board.n
    local cell = math.max(10, math.floor(self.max_size / (n + 1)))
    self.cell  = cell
    -- The grid's offset inside the widget: one clue band on the left and top.
    self.grid_x, self.grid_y = cell, cell
    self.w     = cell * (n + 1)
    self.h     = cell * (n + 1)
    self.dimen = Geom:new{ w = self.w, h = self.h }

    local pad = math.max(1, math.floor(cell / 10))
    local num_size = bsearchFont("cfont", 7, math.max(10, cell), cell - 4 * pad,
        math.floor(cell * 0.45), string.rep("8", #tostring(n)))
    self.num_face = Font:getFace("cfont", math.max(7, num_size))

    self.paint_rect = nil
    self.ges_events = {
        CellTap  = { GestureRange:new{ ges = "tap",          range = function() return self.paint_rect end } },
        CellHold = { GestureRange:new{ ges = "hold_release", range = function() return self.paint_rect end } },
    }
end

-- Screen position -> (r, c), or nil outside the grid (clue bands included).
function AquariumBoardWidget:_cellAt(ges)
    if not self.paint_rect then return nil end
    local lx = ges.pos.x - self.paint_rect.x - self.grid_x
    local ly = ges.pos.y - self.paint_rect.y - self.grid_y
    if lx < 0 or ly < 0 then return nil end
    local c = math.floor(lx / self.cell) + 1
    local r = math.floor(ly / self.cell) + 1
    local n = self.board.n
    if r > n or c > n then return nil end
    return r, c
end

function AquariumBoardWidget:onCellTap(_, ges)
    local r, c = self:_cellAt(ges)
    if r and self.cellTapCallback then self.cellTapCallback(r, c) end
    return true
end

function AquariumBoardWidget:onCellHold(_, ges)
    local r, c = self:_cellAt(ges)
    if r and self.cellHoldCallback then self.cellHoldCallback(r, c) end
    return true
end

function AquariumBoardWidget:refresh()
    UIManager:setDirty(self, function()
        return "ui", self.paint_rect or self.dimen
    end)
end

-- A clue reads plain while the line is short, grey once it holds exactly the
-- clued amount, and white on black when it holds too much.
function AquariumBoardWidget:_paintClue(bb, clue, have, cx, cy)
    if not clue then return end
    local text = tostring(clue)
    if have > clue then
        local s = math.floor(self.cell * 0.78)
        bb:paintRoundedRect(cx - math.floor(s / 2), cy - math.floor(s / 2), s, s, C_FG,
            math.floor(s / 5))
        centeredText(bb, text, self.num_face, cx, cy, C_BG)
    elseif have == clue then
        centeredText(bb, text, self.num_face, cx, cy, C_DONE)
    else
        centeredText(bb, text, self.num_face, cx, cy, C_FG)
    end
end

function AquariumBoardWidget:paintTo(bb, x, y)
    self.paint_rect = Geom:new{ x = x, y = y, w = self.w, h = self.h }
    local board = self.board
    local n, cell = board.n, self.cell
    local gx, gy = x + self.grid_x, y + self.grid_y
    local gw = cell * n
    local region = board.region

    bb:paintRect(x, y, self.w, self.h, C_BG)

    -- Cells
    local surf = math.max(2, math.floor(cell / 12))
    for r = 1, n do
        for c = 1, n do
            local cx, cy = gx + (c - 1) * cell, gy + (r - 1) * cell
            local v = board.cells[r][c]
            if v == AquariumBoard.WATER then
                bb:paintRect(cx, cy, cell, cell, C_WATER)
                -- Surface line where the cell above (same tank) is dry.
                local above_dry = r == 1 or region[r - 1][c] ~= region[r][c]
                    or board.cells[r - 1][c] ~= AquariumBoard.WATER
                if above_dry then
                    bb:paintRect(cx, cy + math.floor(cell * 0.12), cell, surf, C_SURFACE)
                end
            elseif v == AquariumBoard.DOT then
                bb:paintCircle(cx + math.floor(cell / 2), cy + math.floor(cell / 2),
                    math.max(2, math.floor(cell / 10)), C_FG)
            end
            if board.wrong[r][c] then
                -- A heavy X: readable on water and on white alike.
                local m  = math.floor(cell * 0.22)
                local lw = math.max(2, math.floor(cell / 14))
                local len = cell - 2 * m
                for i = 0, len - 1 do
                    bb:paintRect(cx + m + i, cy + m + i, lw, lw, C_FG)
                    bb:paintRect(cx + cell - m - i - lw, cy + m + i, lw, lw, C_FG)
                end
            end
        end
    end

    -- Thin grid lines
    for i = 0, n do
        drawLine(bb, gx + i * cell, gy, 1, gw, C_GRID)
        drawLine(bb, gx, gy + i * cell, gw, 1, C_GRID)
    end

    -- Tank walls
    local wall = math.max(3, math.floor(cell * 0.09))
    local half = math.floor(wall / 2)
    -- Wall segments overlap by a wall's width so corners close; clip them to
    -- the grid so none pokes out past the border.
    local function wallRect(wx, wy, ww, wh)
        local x0, y0 = math.max(wx, gx), math.max(wy, gy)
        local x1, y1 = math.min(wx + ww, gx + gw), math.min(wy + wh, gy + gw)
        if x1 > x0 and y1 > y0 then drawLine(bb, x0, y0, x1 - x0, y1 - y0, C_FG) end
    end
    for r = 1, n do
        for c = 1, n do
            if c < n and region[r][c] ~= region[r][c + 1] then
                wallRect(gx + c * cell - half, gy + (r - 1) * cell - half, wall, cell + wall)
            end
            if r < n and region[r][c] ~= region[r + 1][c] then
                wallRect(gx + (c - 1) * cell - half, gy + r * cell - half, cell + wall, wall)
            end
        end
    end
    -- Outer border, drawn inside the grid box.
    drawLine(bb, gx, gy, gw, wall, C_FG)
    drawLine(bb, gx, gy + gw - wall, gw, wall, C_FG)
    drawLine(bb, gx, gy, wall, gw, C_FG)
    drawLine(bb, gx + gw - wall, gy, wall, gw, C_FG)

    -- Clues: rows on the left, columns on top.
    local mid = math.floor(cell / 2)
    for r = 1, n do
        self:_paintClue(bb, board.row_clues[r], board:rowCount(r), x + mid, gy + (r - 1) * cell + mid)
    end
    for c = 1, n do
        self:_paintClue(bb, board.col_clues[c], board:colCount(c), gx + (c - 1) * cell + mid, y + mid)
    end
end

return AquariumBoardWidget
