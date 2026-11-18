--!strict
--[[
	Drafts on a game table (Shared.Plants.Furniture gameTable): an 8x8 board
	with 12 pieces a side, played like a real board. Nothing is enforced but
	whose pieces you touch: from your stool you move your own pieces about
	the board, put one of yours back on from your side of the table, take
	any piece off the board (to its owner's side), and crown or uncrown your
	own (tap it twice).

	The board is a 64-character string, square (i, j) at index j * 8 + i + 1
	(i across, j from side "a" at the table's -Z edge to side "b" at +Z):
	  "." empty, "a"/"b" a piece, "A"/"B" a crowned piece.
	Pieces not on the board wait at their side of the table.

	Server.Furniture.FurnitureService keeps each table's board in the world
	store (field "g:<room>/<index>" of the building's furniture entity), so
	every server shows the same game, and mirrors it to clients on the
	building's anchor (GAMES_ATTRIBUTE, "<key>=<board>;...").
]]

local Drafts = {}

Drafts.SIZE = 8
Drafts.PER_SIDE = 12
-- Layout in the piece's own normal studs (Furniture scales it).
Drafts.SQ = 0.32 -- a square
Drafts.BOARD = 8 * 0.32 + 0.12 -- the board, edge to edge
Drafts.TOP = 3.6 -- the table top, edge to edge
Drafts.PIECE_D = 0.26
Drafts.PIECE_H = 0.09
Drafts.GAMES_ATTRIBUTE = "FurnitureGames"
Drafts.FIELD_PREFIX = "g:"

function Drafts.index(i: number, j: number): number
	return j * 8 + i + 1
end

function Drafts.square(index: number): (number, number)
	return (index - 1) % 8, (index - 1) // 8
end

-- Dark squares hold the pieces.
function Drafts.dark(i: number, j: number): boolean
	return (i + j) % 2 == 1
end

function Drafts.start(): string
	local t = table.create(64, ".")
	for j = 0, 7 do
		for i = 0, 7 do
			if Drafts.dark(i, j) then
				if j <= 2 then
					t[Drafts.index(i, j)] = "a"
				elseif j >= 5 then
					t[Drafts.index(i, j)] = "b"
				end
			end
		end
	end
	return table.concat(t)
end

function Drafts.valid(board: any): boolean
	if type(board) ~= "string" or #board ~= 64 or string.find(board, "[^%.abAB]") then
		return false
	end
	local _, na = string.gsub(board, "[aA]", "")
	local _, nb = string.gsub(board, "[bB]", "")
	return na <= Drafts.PER_SIDE and nb <= Drafts.PER_SIDE
end

-- How many of a side's pieces are on the board.
function Drafts.onBoard(board: string, side: string): number
	local _, n = string.gsub(board, if side == "a" then "[aA]" else "[bB]", "")
	return n
end

-- How many of a side's pieces wait at its side of the table.
function Drafts.waiting(board: string, side: string): number
	return Drafts.PER_SIDE - Drafts.onBoard(board, side)
end

local function sideOf(c: string): string?
	if c == "a" or c == "A" then
		return "a"
	elseif c == "b" or c == "B" then
		return "b"
	end
	return nil
end
Drafts.sideOf = sideOf

local function set(board: string, index: number, c: string): string
	return string.sub(board, 1, index - 1) .. c .. string.sub(board, index + 1)
end

-- The board after `side` moves `from` -> `to` (squares 1..64; 0 is the
-- side of the table), or nil if that isn't allowed:
--   square -> other empty square : move your own piece
--   square -> same square        : crown / uncrown your own piece
--   square -> 0                  : take any piece off the board
--   0 -> empty square            : put one of your waiting pieces on
function Drafts.apply(board: string, side: string, from: number, to: number): string?
	if side ~= "a" and side ~= "b" or not Drafts.valid(board) then
		return nil
	end
	if from ~= math.floor(from) or to ~= math.floor(to) or from < 0 or from > 64 or to < 0 or to > 64 then
		return nil
	end
	if from == 0 then
		if to == 0 or string.sub(board, to, to) ~= "." or Drafts.waiting(board, side) <= 0 then
			return nil
		end
		return set(board, to, side)
	end
	local c = string.sub(board, from, from)
	local owner = sideOf(c)
	if not owner then
		return nil
	end
	if to == 0 then
		return set(board, from, ".")
	end
	if owner ~= side then
		return nil
	end
	if to == from then
		return set(board, from, if c == string.lower(c) then string.upper(c) else string.lower(c))
	end
	if string.sub(board, to, to) ~= "." then
		return nil
	end
	return set(set(board, from, "."), to, c)
end

-- "<key>=<board>;..." <-> { [key] = board }
function Drafts.parse(s: any): { [string]: string }
	local out = {}
	if type(s) == "string" then
		for key, board in string.gmatch(s, "([^=;]+)=([%.abAB]+)") do
			if #board == 64 then
				out[key] = board
			end
		end
	end
	return out
end

function Drafts.encode(map: { [string]: string }): string
	local parts = {}
	for key, board in map do
		table.insert(parts, `{key}={board}`)
	end
	table.sort(parts)
	return table.concat(parts, ";")
end

return Drafts
