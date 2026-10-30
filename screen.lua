local _dir = debug.getinfo(1, "S").source:sub(2):match("(.*[/\\])") or "./"
local function lrequire(name)
    local key = _dir .. name
    if not package.loaded[key] then
        package.loaded[key] = assert(loadfile(_dir .. name .. ".lua"))()
    end
    return package.loaded[key]
end

local FrameContainer  = require("ui/widget/container/framecontainer")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan  = require("ui/widget/horizontalspan")
local Size            = require("ui/size")
local UIManager       = require("ui/uimanager")
local VerticalGroup   = require("ui/widget/verticalgroup")
local VerticalSpan    = require("ui/widget/verticalspan")
local _               = require("i18n")
local T               = require("ffi/util").template

local ScreenBase          = require("screen_base")
local MenuHelper          = require("menu_helper")
local AquariumBoard       = lrequire("board")
local AquariumBoardWidget = lrequire("board_widget")

local GAME_RULES_EN = [[
Aquarium — Rules

The grid is divided into tanks by thick walls. Fill some cells with water.

• Water obeys gravity: inside a tank, the water surface is level. If a cell is filled, every cell of the same tank on that row and on every row below it is filled too.
• A tank may be full, partly filled or empty.
• The number outside each row and column says how many of its cells hold water. A blank clue gives no information.

Controls:
• Tap a dry cell to fill its tank up to that row.
• Tap a wet cell to drain its tank down below that row.
• Long-press a dry cell to put a dot on it, as a reminder that it stays dry.

A clue turns grey once its line holds exactly that much water, and is shown white on black when the line holds too much.
]]

local GAME_RULES_FR = [[
Aquarium — Règles

La grille est divisée en aquariums par des murs épais. Remplissez certaines cases d'eau.

• L'eau obéit à la gravité : dans un aquarium, la surface de l'eau est horizontale. Si une case est remplie, toutes les cases du même aquarium sur cette ligne et sur toutes les lignes en dessous le sont aussi.
• Un aquarium peut être plein, partiellement rempli ou vide.
• Le nombre au bord de chaque ligne et colonne indique combien de ses cases contiennent de l'eau. Un indice vide ne donne aucune information.

Commandes :
• Appuyez sur une case sèche pour remplir son aquarium jusqu'à cette ligne.
• Appuyez sur une case mouillée pour vider son aquarium sous cette ligne.
• Un appui long sur une case sèche y pose un point, pour se rappeler qu'elle reste sèche.

Un indice devient gris quand sa ligne contient exactement cette quantité d'eau, et blanc sur noir quand elle en contient trop.
]]

local AquariumScreen = ScreenBase:extend{}

function AquariumScreen:init()
    local state = self.plugin:loadState()
    self.board = AquariumBoard:new{ generate = false }
    if not self.board:load(state) then
        self.board:generate(self:_getN(), self:_getDiff())
    end
    ScreenBase.init(self)
end

function AquariumScreen:serializeState()
    return self.board:serialize()
end

function AquariumScreen:_getN()
    return tonumber(self.plugin:getSetting("grid_n", AquariumBoard.DEFAULT_N)) or AquariumBoard.DEFAULT_N
end

function AquariumScreen:_getDiff()
    return self.plugin:getSetting("difficulty", AquariumBoard.DEFAULT_DIFF)
end

function AquariumScreen:_save()
    self.plugin:saveState(self.board:serialize())
end

-- ---------------------------------------------------------------------------
-- Layout
-- ---------------------------------------------------------------------------

function AquariumScreen:buildLayout()
    local is_landscape = self:isLandscape()

    local title_bar = self:buildTitleBar(_("Aquarium"), function()
        return {
            { text = _("New game"), callback = function() self:onNewGame() end },
            self:makeDailyButtonConfig(),
            { text = T(_("Size: %1"), self:_sizeLabel()), callback = function() self:openSizeMenu() end },
            { text = T(_("Difficulty: %1"), self:_diffLabel()), callback = function() self:openDiffMenu() end },
            self:makeRulesButtonConfig(GAME_RULES_EN, GAME_RULES_FR),
        }
    end)

    self.status_text:setMaxWidth(self:getControlsWidth())
    local action_bar = self:buildActionBar({
        { id = "undo_btn", text = _("Undo"), callback = function() self:onUndo() end },
        { text = _("Check"),  callback = function() self:onCheck() end },
        { text = _("Hint"),   callback = function() self:onHint() end },
        { text = _("Reveal"), callback = function() self:onReveal() end },
    })
    self.undo_btn = action_bar:getButtonById("undo_btn")
    local controls = VerticalGroup:new{
        align = "center",
        self.status_text,
        VerticalSpan:new{ width = Size.span.vertical_large },
        action_bar,
    }

    -- The widget draws its own thick border (the clues sit outside it), so
    -- the frame only pads.
    local frame_pad = Size.padding.large
    local budget_w, budget_h = self:getBoardBudget(title_bar, controls)
    local board_max = math.max(math.min(budget_w, budget_h) - 2 * frame_pad, 80)
    self.board_widget = AquariumBoardWidget:new{
        board            = self.board,
        max_size         = board_max,
        cellTapCallback  = function(r, c) self:onCellTap(r, c) end,
        cellHoldCallback = function(r, c) self:onCellHold(r, c) end,
    }
    local board_frame = FrameContainer:new{
        padding    = frame_pad,
        margin     = 0,
        bordersize = 0,
        self.board_widget,
    }
    self:_updateUndoBtn()

    if is_landscape then
        self:buildLandscapeLayout(title_bar, HorizontalGroup:new{
            align = "center",
            board_frame,
            HorizontalSpan:new{ width = self:getGutter() },
            controls,
        })
    else
        self:buildPortraitLayout(title_bar, board_frame,
            VerticalGroup:new{ align = "center", controls, VerticalSpan:new{ width = self:getGutter() } })
    end
    self:updateStatus()
end

-- ---------------------------------------------------------------------------
-- Interaction
-- ---------------------------------------------------------------------------

function AquariumScreen:_afterMove()
    self.hint_cell = nil
    self.board_widget:refresh()
    self:_updateUndoBtn()
    self:updateStatus()
    self:_save()
end

function AquariumScreen:onCellTap(r, c)
    if self.board.won then return end
    if self.board:tap(r, c) then self:_afterMove() end
end

function AquariumScreen:onCellHold(r, c)
    if self.board.won then return end
    if self.board:toggleDot(r, c) then self:_afterMove() end
end

function AquariumScreen:onUndo()
    if self.board:undoMove() then self:_afterMove() end
end

function AquariumScreen:onCheck()
    if self.board.won then return end
    local count = self.board:check()
    self.board_widget:refresh()
    if count == 0 then
        self:updateStatus(_("No errors found!"))
    else
        self:updateStatus(T(_("%1 error(s) highlighted."), count))
    end
end

function AquariumScreen:onReveal()
    self.board:reveal()
    self.board_widget:refresh()
    self:_updateUndoBtn()
    self:_save()
    self:updateStatus(_("Solution revealed."))
end

-- A hint can fill the last tank, so the round may end here.
function AquariumScreen:onHint()
    ScreenBase.onHint(self)
    self:_updateUndoBtn()
    self:refreshActionBar()
end

function AquariumScreen:onNewGame()
    math.randomseed(os.time())
    self.board:generate(self:_getN(), self:_getDiff())
    self.hint_cell = nil
    self:_save()
    self:buildLayout()
    self:updateStatus(_("New game started."))
    UIManager:setDirty(self, function() return "ui", self.dimen end)
end

function AquariumScreen:openSizeMenu()
    local items = {}
    for _, n in ipairs(AquariumBoard.SIZES) do
        items[#items + 1] = { id = n, text = string.format("%d\xC3\x97%d", n, n) }
    end
    MenuHelper.openPickerMenu{
        title      = _("Select size"),
        items      = items,
        current_id = self:_getN(),
        parent     = self,
        on_select  = function(n)
            self.plugin:saveSetting("grid_n", n)
            self:onNewGame()
        end,
    }
end

function AquariumScreen:openDiffMenu()
    MenuHelper.openDifficultyMenu{
        current   = self:_getDiff(),
        parent    = self,
        on_select = function(diff)
            self.plugin:saveSetting("difficulty", diff)
            self:onNewGame()
        end,
    }
end

-- ---------------------------------------------------------------------------
-- Status
-- ---------------------------------------------------------------------------

function AquariumScreen:updateStatus(msg)
    local status
    if msg then
        status = msg
    elseif self.board.won and not self.board.revealed then
        status = T(_("Solved! Time: %1"), self.board.timer:format())
    elseif self.board.revealed then
        status = _("Solution revealed.")
    else
        local n = self.board.n
        status = self:joinStatus(
            T("%1×%1", n),
            MenuHelper.DIFFICULTY_LABELS[self.board.difficulty] or self.board.difficulty,
            self:_waterLabel())
    end
    ScreenBase.updateStatus(self, status)
    -- Every move, hint, undo and reveal ends here, so the bar follows the board.
    self:refreshActionBar()
end

-- Reveal marks the board won, so it ends the round too.
function AquariumScreen:isRoundOver()
    return self.board.won
end

-- The total is only shown when the clues already give it away (every row or
-- every column clue on show), so hidden clues stay hidden.
function AquariumScreen:_waterLabel()
    local b = self.board
    local function sum(clues)
        local s = 0
        for i = 1, b.n do
            if not clues[i] then return nil end
            s = s + clues[i]
        end
        return s
    end
    local total = sum(b.row_clues) or sum(b.col_clues)
    if total then
        return T(_("Water: %1/%2"), b:waterCount(), total)
    end
    return T(_("Water: %1"), b:waterCount())
end

function AquariumScreen:_sizeLabel()
    local n = self:_getN()
    return string.format("%d\xC3\x97%d", n, n)
end

function AquariumScreen:_diffLabel()
    local d = self:_getDiff()
    return MenuHelper.DIFFICULTY_LABELS[d] or d
end

function AquariumScreen:_updateUndoBtn()
    if self.undo_btn then
        self.undo_btn:enableDisable(self.board:canUndo())
    end
end

return AquariumScreen
