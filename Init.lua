local addon = ...

local Auctionator = Auctionator
local GetItemInfo = (C_Item and C_Item.GetItemInfo) or GetItemInfo
local DoesItemExistByID = C_Item and C_Item.DoesItemExistByID

local LIST_NAME = "FireSale"
-- Safety net in case an item never finishes loading.
local SCAN_TIMEOUT = 60

local FireSale = {}
local scanInProgress = false

local function Print(msg)
	print("|cFFFF8000FireSale|r: " .. msg)
end

local function NormaliseName(name)
	return name and strtrim(name):lower()
end

local function IsIgnored(name)
	return FireSale_Data.ignore[NormaliseName(name)] == true
end

local function SearchStringToName(searchString)
	local term = Auctionator.API.v1.ConvertFromSearchString(addon, searchString)
	return term and term.searchString
end

-- Random-suffix gear ("Scalping Tomahawk of the Bear") shares one itemID whose base name
-- never appears on the AH, so those items need a non-exact search to be found.
local function NameToSearchString(name, isExact)
	return Auctionator.API.v1.ConvertToSearchString(addon, {searchString = name, isExact = isExact ~= false})
end

local function ListExists()
	return Auctionator.Shopping.ListManager:GetIndexForName(LIST_NAME) ~= nil
end

local function RemoveFromList(name)
	if not ListExists() then
		return
	end
	local target = NormaliseName(name)
	-- Walk backwards so deletes don't shift the entries still to be checked.
	local items = Auctionator.API.v1.GetShoppingListItems(addon, LIST_NAME)
	for i = #items, 1, -1 do
		if NormaliseName(SearchStringToName(items[i])) == target then
			Auctionator.API.v1.DeleteShoppingListItem(addon, LIST_NAME, items[i])
		end
	end
end

function FireSale.Ignore(name)
	FireSale_Data.ignore[NormaliseName(name)] = true
	RemoveFromList(name)
	Print("Ignoring " .. name)
end

function FireSale.Unignore(name)
	FireSale_Data.ignore[NormaliseName(name)] = nil
	Print("No longer ignoring " .. name)
end

-- Auctionator hands over a different payload depending on the client and scan type.
-- Each entry is one auction (full scans) or one browse result (incremental scan), so
-- the same item shows up many times. Returns itemID, per-unit buyout (or nil), and
-- either the auction's display name (full scans) or whether it carries a suffix.
local function ReadInfo(info)
	local price
	if info[3] and info[3] > 0 and info[10] and info[10] > 0 then
		price = info[10] / info[3]
	end
	return info[17], price, info[1]
end

local function ReadEntry(entry)
	if entry.replicateInfo then
		-- Retail full scan (C_AuctionHouse.GetReplicateItemInfo)
		return ReadInfo(entry.replicateInfo)
	elseif entry.auctionInfo then
		-- Classic full scan (GetAuctionItemInfo)
		return ReadInfo(entry.auctionInfo)
	elseif entry.itemKey then
		-- Retail incremental scan (browse results)
		local suffix = entry.itemKey.itemSuffix
		return entry.itemKey.itemID, entry.minPrice, suffix and suffix > 0
	end
end

-- Collapse the raw scan into one lowest unit price per itemID. Also returns, per itemID,
-- the auction names seen (or true when the scan flagged a suffix directly).
local function MergeScan(data)
	local merged = {}
	local names = {}
	for _, entry in ipairs(data) do
		local itemID, price, name = ReadEntry(entry)
		if itemID and name then
			if name == true then
				names[itemID] = true
			elseif names[itemID] ~= true then
				names[itemID] = names[itemID] or {}
				names[itemID][name] = true
			end
		end
		if itemID then
			local current = merged[itemID]
			if price and price > 0 and (current == nil or current == false or price < current) then
				merged[itemID] = price
			elseif current == nil then
				-- Seen, but no usable buyout (bid-only). Fall back to Auctionator's price later.
				merged[itemID] = false
			end
		end
	end
	return merged, names
end

-- True when auctions for this itemID were listed under a name other than its base name.
local function HasSuffix(seenNames, baseName)
	if seenNames == true then
		return true
	end
	if seenNames then
		for name in pairs(seenNames) do
			if name ~= "" and name ~= baseName then
				return true
			end
		end
	end
	return false
end

local function FinishScan(state)
	if state.finished then
		return
	end
	state.finished = true
	scanInProgress = false

	local existing = {}
	if ListExists() then
		for _, searchString in ipairs(Auctionator.API.v1.GetShoppingListItems(addon, LIST_NAME)) do
			local name = NormaliseName(SearchStringToName(searchString))
			if name then
				existing[name] = searchString
			end
		end
	end

	local toAdd = {}
	for _, bargain in ipairs(state.bargains) do
		local key = NormaliseName(bargain.name)
		local searchString = NameToSearchString(bargain.name, bargain.isExact)
		local current = existing[key]
		if current ~= searchString and not (current and bargain.isExact) then
			if current then
				-- An older exact entry for a suffixed item never matches; swap it for a fuzzy one.
				Auctionator.API.v1.DeleteShoppingListItem(addon, LIST_NAME, current)
			end
			existing[key] = searchString
			table.insert(toAdd, searchString)
		end
	end

	if #toAdd > 0 then
		if ListExists() then
			Auctionator.Shopping.ListManager:GetByName(LIST_NAME):AppendItems(toAdd)
		else
			Auctionator.API.v1.CreateShoppingList(addon, LIST_NAME, toAdd)
		end
	end

	local msg = string.format(
		"%d items below vendor price, %d new added to the %s list",
		#state.bargains, #toAdd, LIST_NAME
	)
	if state.ignored > 0 then
		msg = msg .. string.format(" (%d ignored)", state.ignored)
	end
	if state.pending > 0 then
		msg = msg .. string.format(" (%d items failed to load)", state.pending)
	end
	Print(msg .. ".")
end

local function CheckItem(state, itemID, scanPrice, auctionNames)
	local itemname, _, _, _, _, _, _, _, _, _, vendorprice = GetItemInfo(itemID)
	local ahprice = scanPrice or Auctionator.API.v1.GetAuctionPriceByItemID(addon, itemID)
	if itemname and ahprice and vendorprice and vendorprice > 0 and ahprice < vendorprice then
		local isExact = not HasSuffix(auctionNames, itemname)
		if IsIgnored(itemname) then
			state.ignored = state.ignored + 1
		elseif not state.seenNames[itemname] then
			state.seenNames[itemname] = {name = itemname, isExact = isExact}
			table.insert(state.bargains, state.seenNames[itemname])
		elseif not isExact then
			state.seenNames[itemname].isExact = false
		end
	end
end

local function ProcessScan(data)
	if scanInProgress then
		return
	end
	scanInProgress = true

	local merged, auctionNames = MergeScan(data)
	local state = {pending = 0, ignored = 0, bargains = {}, seenNames = {}, finished = false}

	for itemID in pairs(merged) do
		if not DoesItemExistByID or DoesItemExistByID(itemID) then
			state.pending = state.pending + 1
		end
	end

	Print(string.format("Checking %d unique items from %d scan entries...", state.pending, #data))

	if state.pending == 0 then
		FinishScan(state)
		return
	end

	for itemID, price in pairs(merged) do
		if not DoesItemExistByID or DoesItemExistByID(itemID) then
			Item:CreateFromItemID(itemID):ContinueOnItemLoad(function()
				if state.finished then
					return
				end
				CheckItem(state, itemID, price or nil, auctionNames[itemID])
				state.pending = state.pending - 1
				if state.pending == 0 then
					FinishScan(state)
				end
			end)
		end
	end

	C_Timer.After(SCAN_TIMEOUT, function()
		FinishScan(state)
	end)
end

-- Adds an "Ignore" button to rows of the FireSale list in Auctionator's Shopping tab.
-- Search term rows only use the first two option slots, so the third is free.
local function FindListsContainer(frame)
	while frame do
		if frame.expandedList ~= nil then
			return frame
		end
		frame = frame:GetParent()
	end
end

local function OnIgnoreClicked(option)
	local row = option:GetParent()
	local name = row.elementData and SearchStringToName(row.elementData.searchTerm)
	if name then
		FireSale.Ignore(name)
	end
end

local function DecorateRow(row)
	local data = row.elementData
	if not (data and RowType and data.type == RowType.SearchTerm and row.options3) then
		return
	end
	local container = FindListsContainer(row)
	if not (container and container.expandedList and container.expandedList:GetName() == LIST_NAME) then
		return
	end
	row.options3.Icon:SetTexture("Interface\\Buttons\\UI-GroupLoot-Pass-Up")
	row.options3:SetScript("OnClick", OnIgnoreClicked)
	row.options3.TooltipText = "Ignore this item in future FireSale scans"
	row.options3:Show()
end

local function HookShoppingRows()
	if not (Auctionator.Shopping and Auctionator.Shopping.Tab and Auctionator.Shopping.Tab.SetupContainerRow) then
		return
	end
	-- Rows are recycled; Text:SetText runs on every acquire after elementData is set.
	hooksecurefunc(Auctionator.Shopping.Tab, "SetupContainerRow", function(row)
		hooksecurefunc(row.Text, "SetText", function()
			DecorateRow(row)
		end)
	end)
end

-- /firesale ignore <item link or name>, /firesale unignore <...>, /firesale list
local function ItemNameFromArg(arg)
	if not arg or arg == "" then
		return nil
	end
	return arg:match("|h%[(.-)%]|h") or GetItemInfo(arg) or arg
end

SLASH_FIRESALE1 = "/firesale"
SlashCmdList.FIRESALE = function(msg)
	local cmd, rest = strtrim(msg or ""):match("^(%S*)%s*(.-)$")
	cmd = cmd:lower()
	local name = ItemNameFromArg(rest)
	if cmd == "ignore" and name then
		FireSale.Ignore(name)
	elseif cmd == "unignore" and name then
		FireSale.Unignore(name)
	elseif cmd == "list" then
		local names = {}
		for key in pairs(FireSale_Data.ignore) do
			table.insert(names, key)
		end
		table.sort(names)
		Print(#names == 0 and "Ignore list is empty." or ("Ignored: " .. table.concat(names, ", ")))
	else
		Print("/firesale ignore <item>, /firesale unignore <item>, /firesale list")
	end
end

local source = {
	ReceiveEvent = function(_, _, data)
		ProcessScan(data or {})
	end
}

local loader = CreateFrame("Frame")
loader:RegisterEvent("ADDON_LOADED")
loader:SetScript("OnEvent", function(self, _, loaded)
	if loaded ~= addon then
		return
	end
	self:UnregisterEvent("ADDON_LOADED")

	FireSale_Data = FireSale_Data or {}
	FireSale_Data.ignore = FireSale_Data.ignore or {}

	Auctionator.EventBus:RegisterSource(source, addon)
	if Auctionator.FullScan and Auctionator.FullScan.Events then
		Auctionator.EventBus:Register(source, {Auctionator.FullScan.Events.ScanComplete})
	end
	if Auctionator.IncrementalScan and Auctionator.IncrementalScan.Events then
		Auctionator.EventBus:Register(source, {Auctionator.IncrementalScan.Events.ScanComplete})
	end

	HookShoppingRows()
end)
