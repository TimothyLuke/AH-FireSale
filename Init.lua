local addon, options = ...

local Auctionator = Auctionator

local source = {
	ReceiveEvent = function(_, eventName, data)
		print("Starting FireSale")
		local count = 0
		for _, v in ipairs(data) do
			local itemID
			if v and v.auctionInfo and v.auctionInfo[17] then
				itemID = v.auctionInfo[17]
			else
				itemID = v.itemKey.itemID
			end
			local item = Item:CreateFromItemID(itemID)

			item:ContinueOnItemLoad(
				function()
					local ahprice = Auctionator.API.v1.GetAuctionPriceByItemID(addon, itemID)
					local itemname, _, _, _, _, _, _, _, _, _, vendorprice = C_Item.GetItemInfo(itemID)
					if ahprice and vendorprice then
						-- print(itemid, item:GetItemName(), ahprice, vendorprice)
						if ahprice < vendorprice then

							-- print("Added " .. item:GetItemName() .. " to Shopping List")
							local list = Auctionator.Shopping.ListManager:GetIndexForName("FireSale")
							if not list then
								Auctionator.API.v1.CreateShoppingList(addon, "FireSale", {itemname})
							else
								local items = Auctionator.API.v1.GetShoppingListItems(addon, "FireSale")
								local found = false
								for _,v in ipairs(items) do
									if v == itemname then
										found = true
									end
								end
								if not found then
									list = Auctionator.Shopping.ListManager:GetByName("FireSale")
									list:AppendItems({itemname})
									count = count + 1
								end
							end
						end
					end
				end
			)
			
		end
		print("Ending FireSale, " .. tostring(count) .. " items added for purchase.")
	end
}
Auctionator.EventBus:RegisterSource(source, addon)

Auctionator.EventBus:Register(source, {Auctionator.FullScan.Events.ScanComplete})
Auctionator.EventBus:Register(source, {Auctionator.IncrementalScan.Events.ScanComplete})
