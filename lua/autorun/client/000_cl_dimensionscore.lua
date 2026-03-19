if false then
	print("[DIMCORE] Addon disabled.")
	return
end

--[[
    DimensionsCore by ST2005 & NovaAstral

    Client code
]]

hook.Add("OnEntityCreated", "[DIMCORE] Push entity into DCT on spawn", function(ent)
	if not IsValid(ent) then
		return
	end -- wtf?

	if not (ent and IsValid(ent) and ent.GetTable and ent:GetTable()) then
		return
	end

	for member, body in pairs(ent:GetTable()) do
		if type(body) == "function" then
			do
				local detour = body
				ent:GetTable()[member] = function(...)
					if not IsValid(LocalPlayer()) or not IsValid(ent) then
						return
					end
					if LocalPlayer():GetNW2String("TNMI_Dimension") ~= ent:GetNW2String("TNMI_Dimension") then
						return
					end
					return unpack({ detour(...) })
				end
			end
		end
	end
end)

hook.Add("OnPlayerChat","[DIMCORE] Suppress extradimensional messages",function(ply,strText)
	if ply:GetDimension() ~= LocalPlayer():GetDimension() then return true end
end)