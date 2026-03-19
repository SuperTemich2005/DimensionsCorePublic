if false then
	print("[DIMCORE] Addon disabled.")
	return
end
print("[DIMCORE] Loading")
--[[
    DimensionsCore by ST2005 & NovaAstral

    Implements dimensions-based instancing to sandbox gamemode of Garry's Mod by detouring various functions to
    respect each entity's new NW2String property 'TNMI_Dimension' and enforce separation between dimensions.

    Designed to make a Spacebuild map where each planet is the size of the entire map, amount of planets and interplanetary
    sectors is unlimited (somewhat) and CAP/CAPE Supergates aren't useless, but generally aims to be as compatible with other addons
    (such as those JPEG NextBots things, the TARDIS addon, weapon packs like M9K and whatnot) and, obviously, every single vanilla feature.
]]

DimCore = DimCore or {}
if not DimCore.ContextStack then
	DimCore.ContextStack = {}
end -- Dimensional Context Table (DCT), a stack of entities that certain functions are detoured to add entities to so that library functions know what entity calls them.
DimCore.NoContext = false
if not DimCore.DEFAULT_DIMENSION then
	DimCore.DEFAULT_DIMENSION = "overworld"
end
DimCore.DimensionsTable = {}
DimCore.DimensionsTable[DimCore.DEFAULT_DIMENSION] = {}

-- Push entity to the context stack. If dbg is not nil, print a debug message in console (used to trace where this function was called from)
function DimCore.PushContext(ent, dbg)
	DimCore.ContextStack[#DimCore.ContextStack + 1] = ent
end

-- Return the entity at the top of the stack
function DimCore.LookupContext()
	if DimCore.NoContext then
		return nil
	end
	return DimCore.ContextStack[#DimCore.ContextStack]
end

-- Pop an entity from the stack and return it
function DimCore.PopContext()
	local a = DimCore.ContextStack[#DimCore.ContextStack]
	DimCore.ContextStack[#DimCore.ContextStack] = nil
	return a
end

-- Make LookupContext return nil. Call if you want ents.GetAll to return actually all entities.
function DimCore.DumpDCT()
	DimCore.NoContext = true
end

-- Make LookupContext return stack top.
function DimCore.RestoreDCT()
	DimCore.NoContext = false
end

-- Debug command to get dimension of an entity the player is looking at.
concommand.Add("dim_get", function(ply, cmd, args)
	print("[DIMCORE] dim_get executed by ", ply, " in ", ply:GetDimension())
	if not IsValid(ply:GetEyeTrace().Entity) then
		return
	end
	print("> ", ply:GetEyeTrace().Entity, " dimension: ", ply:GetEyeTrace().Entity:GetDimension())
	print("> Children dimensions:")
	for k, v in pairs(ply:GetEyeTrace().Entity:GetChildren()) do
		print("> > ", k, v, ": ", v:GetDimension())
		if v:GetDimension() ~= ply:GetEyeTrace().Entity:GetDimension() then
			print("WARNING: DIMENSION MISMATCH")
		end
	end
end)

-- Debug command to teleport to another dimension
concommand.Add("dim_goto", function(ply, cmd, args)
	print("[DIMCORE] dim_goto executed by ", ply, " in ", ply:GetDimension(), ". Warping to ", args[1])
	ply:SetDimension(args[1])
end)

-- Function from GMod Wiki.
function RecursiveSetPreventTransmit(ent, ply, stopTransmitting)
	if ent ~= ply and IsValid(ent) and IsValid(ply) then
		ent:SetPreventTransmit(ply, stopTransmitting)
		local tab = ent:GetChildren()
		for i = 1, #tab do
			RecursiveSetPreventTransmit(tab[i], ply, stopTransmitting)
		end
	end
end

-- Detour or add functions of SENTs
hook.Add("InitPostEntity", "[DIMCORE] Detour Entity table functions", function() -- Wait for the game to be ready
	timer.Simple(0, function() -- Wait a frame to be sure
		-- Note: I am using do-end blocks to prevent shadowing of local variables.
		do -- Define SetDimension and GetDimension in Entity
			local meta = FindMetaTable("Entity")

			-- Detour emitSound
			do
				local ent = meta
				local detour = ent.EmitSound
				ent.EmitSound = function(
					self,
					soundName,
					soundLevel,
					pitchPercent,
					volume,
					channel,
					soundFlags,
					dsp,
					filter
				)
					callerDim = self:GetDimension()

					if not filter or type(filter) == type(true) then
						filter = RecipientFilter()
						filter:AddAllPlayers()
					end

					for i, ply in ipairs(player.GetAll()) do
						if ply:GetDimension() ~= callerDim then
							filter:RemovePlayer(ply)
						end
					end

					return detour(self, soundName, soundLevel, pitchPercent, volume, channel, soundFlags, dsp, filter)
				end
			end

			meta.SetDimension = function(self, targetDim)
				if not IsValid(self) then
					return
				end
				if IsValid(self:GetParent()) then
					return
				end -- Prevent a child from getting pulled in a dimension away from its parent
				if not targetDim then
					targetDim = DimCore.DEFAULT_DIMENSION
				end

				if
					DimCore.DimensionsTable[self:GetNW2String("TNMI_Dimension", "overworld")]
					and DimCore.DimensionsTable[self:GetNW2String("TNMI_Dimension", "overworld")][self]
				then
					DimCore.DimensionsTable[self:GetNW2String("TNMI_Dimension", "overworld")][self] = nil
				end

				-- Set dimension property
				self:SetNW2String("TNMI_Dimension", targetDim)

				if not DimCore.DimensionsTable[targetDim] then
					DimCore.DimensionsTable[targetDim] = {}
				end
				DimCore.DimensionsTable[targetDim][self] = true

				timer.Simple(0, function() -- Wait a tick before applying changes.
					if not IsValid(self) then
						return
					end
					-- Check if this entity is physical and make it enter the custom collision check loop if it's outside of default dimension
					if IsValid(self:GetPhysicsObject()) and self:GetPhysicsObject():IsValid() then
						self:SetCustomCollisionCheck(targetDim ~= DimCore.DEFAULT_DIMENSION)
						self:CollisionRulesChanged()
					end

					-- Pull the player with the seat
					if self:IsVehicle() then
						if self:GetDriver() then
							self:GetDriver():SetDimension(targetDim)
						end
					end

					-- Propagate shift on children
					for k, v in pairs(self:GetChildren()) do
						v:SetDimension(targetDim)
					end

					-- Update net visibility of this entity to ALL players
					DimCore.DumpDCT()
					for _, ply in pairs(player.GetAll()) do
						RecursiveSetPreventTransmit(self, ply, ply:GetDimension() ~= self:GetDimension())
					end
					DimCore.RestoreDCT()
				end)
			end

			meta.GetDimension = function(self)
				return self:GetNW2String("TNMI_Dimension", DimCore.DEFAULT_DIMENSION)
			end
		end

		do -- Define SetDimension and GetDimension in Player
			local meta = FindMetaTable("Player")

			meta.SetDimension = function(self, targetDim)
				if not IsValid(self) then
					return
				end
				if self:InVehicle() then
					return
				end -- Prevent a player from getting pulled out of the vehicle
				if not targetDim then
					targetDim = DimCore.DEFAULT_DIMENSION
				end

				if
					DimCore.DimensionsTable[self:GetNW2String("TNMI_Dimension", "overworld")]
					and DimCore.DimensionsTable[self:GetNW2String("TNMI_Dimension", "overworld")][self]
				then
					DimCore.DimensionsTable[self:GetNW2String("TNMI_Dimension", "overworld")][self] = nil
				end

				-- Set dimension property
				self:SetNW2String("TNMI_Dimension", targetDim)

				if not DimCore.DimensionsTable[targetDim] then
					DimCore.DimensionsTable[targetDim] = {}
				end
				DimCore.DimensionsTable[targetDim][self] = true

				timer.Simple(0, function() -- Sync
					-- Check if this entity is physical and make it enter the custom collision check loop if it's outside of default dimension
					if IsValid(self:GetPhysicsObject()) and self:GetPhysicsObject():IsValid() then
						self:SetCustomCollisionCheck(targetDim ~= DimCore.DEFAULT_DIMENSION)
						self:CollisionRulesChanged()
					end

					-- Handle player's entities (weapons and viewmodels and viewentities)
					for _, wep in ipairs(self:GetWeapons()) do
						wep:SetDimension(targetDim)
					end

					-- Also update visibility on ALL entities for this player
					for _, ent in pairs(ents.GetAll()) do
						if IsValid(ent:GetOwner()) and ent:IsWeapon() and ent:GetOwner() == self then
							continue
						end
						if
							(ent == self:GetViewModel(0))
							or (ent == self:GetViewModel(1))
							or (ent == self:GetViewModel(2))
						then
							continue
						end
						if ent == self:GetViewEntity() then
							continue
						end
						if ent == self:GetHands() then
							continue
						end
						if ent:GetClass() == "physgun_beam" and ent:GetOwner() == self then
							continue
						end

						RecursiveSetPreventTransmit(ent, self, self:GetDimension() ~= ent:GetDimension())
					end

					-- Update net visibility of this entity to ALL players
					DimCore.DumpDCT()
					for _, ply in pairs(player.GetAll()) do
						RecursiveSetPreventTransmit(self, ply, ply:GetDimension() ~= self:GetDimension())
					end
					DimCore.RestoreDCT()
				end)
			end

			meta.GetDimension = function(self)
				return self:GetNW2String("TNMI_Dimension", DimCore.DEFAULT_DIMENSION)
			end
		end

		do -- Define SetDimension and GetDimension in Weapon
			local meta = FindMetaTable("Weapon")

			meta.SetDimension = function(self, targetDim)
				if not targetDim then
					targetDim = DimCore.DEFAULT_DIMENSION
				end
				if not IsValid(self) then
					return
				end

				-- Set dimension property
				self:SetNW2String("TNMI_Dimension", targetDim)

				timer.Simple(0, function() -- Wait a tick before applying changes.
					if not IsValid(self) then
						return
					end

					-- Update net visibility of this entity to ALL players
					DimCore.DumpDCT()
					for _, ply in pairs(player.GetAll()) do
						RecursiveSetPreventTransmit(self, ply, ply:GetDimension() ~= self:GetDimension())
					end
					DimCore.RestoreDCT()
				end)
			end

			meta.GetDimension = function(self)
				if
					self
					and self.GetOwner
					and IsValid(self:GetOwner())
					and self:GetOwner().GetDimension
					and self:GetOwner():GetDimension()
				then
					return self:GetOwner():GetDimension()
				else
					return DimCore.DEFAULT_DIMENSION
				end
			end
		end

		DimCore.DumpDCT()
		for _, v in pairs(ents.GetAll()) do
			v:SetDimension(DimCore.DEFAULT_DIMENSION)
		end
		DimCore.RestoreDCT()

		-- Detour ents.GetAll to deal with all Find functions and more
		do
			print("[DIMCORE] Detoured ents.GetAll")
			local detour = ents.GetAll
			ents.GetAll = function()
				local caller = DimCore.LookupContext()
				if not IsValid(caller) or not caller.GetDimension then
					return detour()
				end

				local callerDim = caller:GetDimension()
				local ret = detour()
				local returnedTable = {}
				for k, v in ipairs(ret) do
					if IsValid(v) and v.GetDimension then
						if v:GetDimension() == callerDim then
							returnedTable[#returnedTable + 1] = v
						end
					end
				end

				return returnedTable
			end
		end

		-- Detour ents.FindInSphere
		do
			print("[DIMCORE] Detoured ents.FindInSphere")
			local detour = ents.FindInSphere
			ents.FindInSphere = function(origin, radius)
				local caller = DimCore.LookupContext()
				if not IsValid(caller) or not caller.GetDimension then
					return detour(origin, radius)
				end

				local callerDim = caller:GetDimension()
				local ret = detour(origin, radius)
				local returnedTable = {}
				for k, v in pairs(ret) do
					if IsValid(v) and v.GetDimension then
						if v:GetDimension() == callerDim then
							returnedTable[#returnedTable + 1] = v
						end
					end
				end

				return returnedTable
			end
		end

		-- Detour ents.FindInBox
		do
			print("[DIMCORE] Detoured ents.FindInBox")
			local detour = ents.FindInBox
			ents.FindInBox = function(...)
				local caller = DimCore.LookupContext()
				if not IsValid(caller) or not caller.GetDimension then
					return detour(...)
				end

				local callerDim = caller:GetDimension()
				local ret = detour(...)
				local returnedTable = {}
				for k, v in pairs(ret) do
					if IsValid(v) and v.GetDimension then
						if v:GetDimension() == callerDim then
							returnedTable[#returnedTable + 1] = v
						end
					end
				end

				return returnedTable
			end
		end

		-- Detour ents.FindInCone
		do
			print("[DIMCORE] Detoured ents.FindInCone")
			local detour = ents.FindInCone
			ents.FindInCone = function(...)
				local caller = DimCore.LookupContext()
				if not IsValid(caller) or not caller.GetDimension then
					return detour(...)
				end

				local callerDim = caller:GetDimension()
				local ret = detour(...)
				local returnedTable = {}
				for k, v in pairs(ret) do
					if IsValid(v) and v.GetDimension then
						if v:GetDimension() == callerDim then
							returnedTable[#returnedTable + 1] = v
						end
					end
				end

				return returnedTable
			end
		end
		-- More find functions...

		-- Detour ents.Create
		do
			print("[DIMCORE] Detoured ents.Create")
			local detour = ents.Create
			ents.Create = function(class)
				local creator = DimCore.LookupContext()
				local r = detour(class)

				DimCore.PushContext(r)
				if (not r.SetDimension) or not r.GetDimension then
					return r
				end

				if IsValid(creator) then
					r:SetDimension(creator:GetDimension())
				end

				return r
			end
		end
		--
		-- Detour util.TraceLine
		do
			print("[DIMCORE] Detoured util.TraceLine")
			local detour = util.TraceLine
			local recursiveDetour
			recursiveDetour = function(traceConfig, callerDim)
				local testResult = detour(traceConfig)
				
				if
					(
						testResult.Entity
						and IsValid(testResult.Entity)
						and testResult.Entity.GetDimension
						and testResult.Entity:GetDimension() == callerDim
					)
					or testResult.HitWorld
					or (testResult.Fraction == 1)
				then
					return testResult
				end

				traceConfig.filter[#traceConfig.filter + 1] = testResult.Entity

				return recursiveDetour(traceConfig, callerDim)
			end
			util.TraceLine = function(traceConfig)
				local caller = DimCore.LookupContext()
				if caller and IsValid(caller) and caller.GetDimension then
					local callerDim = caller:GetDimension()

					if not traceConfig.filter then
						traceConfig.filter = {}
					end

					DimCore.DumpDCT()
					if isentity(traceConfig.filter) then
						traceConfig.filter = { traceConfig.filter }
					elseif istable(traceConfig.filter) then
						if isstring(traceConfig.filter[1]) then
							local newFilter = {}
							for _, blacklistedClass in ipairs(traceConfig.filter) do
								for _, ent in ipairs(ents.FindByClass(blacklistedClass)) do
									newFilter[#newFilter + 1] = ent
								end
							end
							traceConfig.filter = newFilter
						elseif isentity(traceConfig.filter[1]) then
							-- /shrug
						end
					end
					DimCore.RestoreDCT()

					if isfunction(traceConfig.filter) then
						local filterDetour = traceConfig.filter
						traceConfig.filter = function(e)
							if e.GetDimension and e:GetDimension() ~= callerDim then
								return false
							end
							return filterDetour(e)
						end
						return detour(traceConfig)
					else
						return recursiveDetour(traceConfig, callerDim)
					end
				else
					return detour(traceConfig)
				end
			end
		end

		do -- Detour net.Broadcast
			print("[DIMCORE] Detoured net.Broadcast")
			local detour = net.Broadcast
			net.Broadcast = function()
				local targets = {}
				local caller = DimCore.LookupContext()
				if not (caller and isentity(caller) and IsValid(caller) and caller.GetDimension) then
					detour()
					return
				end
				local callerDim = caller:GetDimension()

				for i, ply in ipairs(player.GetAll()) do
					if ply:GetDimension() == callerDim then
						targets[#targets + 1] = ply
					end
				end
				return net.Send(targets)
			end
		end

		do -- Detour util.Effect
			print("[DIMCORE] Detoured util.Effect")
			local detour = util.Effect
			util.Effect = function(effectName, effectData, allowOverride, ignorePredictionOrRecipientFilter)
				local caller = DimCore.LookupContext()

				if not (caller and isentity(caller) and IsValid(caller) and caller.GetDimension) then
					detour(effectName, effectData, allowOverride, ignorePredictionOrRecipientFilter)
					return
				end

				local callerDim = caller:GetDimension()

				local allowOverride = allowOverride or true
				local ignorePredictionOrRecipientFilter = ignorePredictionOrRecipientFilter or nil

				if not ignorePredictionOrRecipientFilter or type(ignorePredictionOrRecipientFilter) == type(true) then
					ignorePredictionOrRecipientFilter = RecipientFilter()
					ignorePredictionOrRecipientFilter:AddAllPlayers()
				end

				for i, ply in ipairs(player.GetAll()) do
					if ply:GetDimension() ~= callerDim then
						ignorePredictionOrRecipientFilter:RemovePlayer(ply)
					end
				end

				return detour(effectName, effectData, allowOverride, ignorePredictionOrRecipientFilter)
			end
		end

		-- Detour timer.Create
		do
			print("[DIMCORE] Detoured timer.Create")
			local detour = timer.Create
			timer.Create = function(identifier, delay, repetitions, func)
				local caller = DimCore.LookupContext()
				local r = detour(identifier, delay, repetitions, function()
					if caller then
						DimCore.PushContext(caller)
					end

					func()

					if caller then
						DimCore.PopContext()
					end
				end)

				return r
			end
		end

		-- Detour timer.Simple
		do
			print("[DIMCORE] Detoured timer.Simple")
			local detour = timer.Simple
			timer.Simple = function(delay, func)
				local caller = DimCore.LookupContext()
				local r = detour(delay, function()
					if caller then
						DimCore.PushContext(caller)
					end

					func()

					if caller then
						DimCore.PopContext()
					end
				end)

				return r
			end
		end

		-- Detour hook.Add
		do
			print("[DIMCORE] Detoured hook.Add")
			local detour = hook.Add
			hook.Add = function(eventName, identifier, func)
				local caller = DimCore.LookupContext()
				local r = detour(eventName, identifier, function(...)
					if caller then
						DimCore.PushContext(caller)
					end
					local ret = func(...)
					if caller then
						DimCore.PopContext()
					end

					return ret
				end)
				return r
			end
		end

		-- Detour hook.Run
		do
			print("[DIMCORE] Detoured hook.Run")
			local detour = hook.Run
			hook.Run = function(eventName, ...)
				local caller = DimCore.LookupContext()
				if caller then
					DimCore.PushContext(caller)
				end
				local r = detour(eventName, ...)
				if caller then
					DimCore.PopContext()
				end

				return r
			end
		end
	end)
end) -- Note: Nothing in this hook will hot-reload.

hook.Add("OnEntityCreated", "[DIMCORE] Push entity into DCT on spawn", function(ent)
	if not IsValid(ent) then
		return
	end -- wtf?
	if
		IsValid(DimCore:LookupContext())
		and DimCore.LookupContext().GetDimension
		and ent.SetDimension
		and ent.GetDimension
	then
		ent:SetDimension(DimCore.LookupContext():GetDimension())
	end

	timer.Simple(0, function()
		DimCore.PopContext()

		if not (ent and IsValid(ent) and ent.GetTable and ent:GetTable()) then
			return
		end

		for member, body in pairs(ent:GetTable()) do
			if type(body) == "function" then
				if member == "StartTouch" or member == "EndTouch" or member == "Touch" then
					local detour = body
					ent:GetTable()[member] = function(self, other)
						if self and other and self:GetDimension() == other:GetDimension() then
							DimCore.PushContext(self)
							local r = { detour(self, other) }
							DimCore.PopContext()
							return unpack(r)
						else
							return
						end
					end
				else
					local detour = body
					ent:GetTable()[member] = function(...)
						DimCore.PushContext(ent)
						local r = { detour(...) }
						DimCore.PopContext()
						return unpack(r)
					end
				end
			end
		end
	end)
end)

-- Push player onto the context stack when they create an entity using Spawn Menu
local hookSuffixes = { "Effect", "NPC", "Prop", "Ragdoll", "SENT", "SWEP", "Vehicle" }
for _, hookname in pairs(hookSuffixes) do
	hook.Add("PlayerSpawn" .. hookname, "[DIMCORE] Push player onto DCT on spawnmenu use", function(ply)
		DimCore.PushContext(ply)
	end)
	hook.Add("PlayerSpawned" .. hookname, "[DIMCORE] Pop player from DCT on spawnmenu use", function()
		DimCore.PopContext()
	end)
end

-- Hooks for putting players in dimensions
local playerRespawnHooks = { "PlayerSpawn", "PlayerInitialSpawn" }
for _, hookName in pairs(playerRespawnHooks) do
	hook.Add(hookName, "[DIMCORE] Assign Dimension Values to Players", function(ply)
		ply:SetDimension(DimCore.DEFAULT_DIMENSION)
	end)
end

hook.Add("CreateEntityRagdoll", "[DIMCORE] Assign Dimension Values to Ragdolls", function(owner, doll)
	timer.Simple(0, function()
		if not IsValid(owner) then
			return
		end
		if not IsValid(doll) then
			return
		end

		doll:SetDimension(owner:GetDimension())
	end)
end)

-- Hook for handling physical colisions between entities
hook.Add("ShouldCollide", "[DIMCORE] Prevent Entities from Colliding Across Dimensions", function(ent1, ent2)
	return (ent1:GetDimension() == ent2:GetDimension()) or (ent1:IsWorld() or ent2:IsWorld())
end)

-- Hook for preventing miscellaneous interactions between player and entities (credit Nova Astral)
local interactionHook = {
	"PlayerUse",
	"PhysgunPickup",
	"AllowPlayerPickup",
	"GravGunPickupAllowed",
	"PlayerCanPickupItem",
	"PlayerCanHearPlayersVoice",
	"CanPlayerUnfreeze",
	"CanPlayerEnterVehicle",
	"GravGunPunt",
}
for k, hookName in ipairs(interactionHook) do
	hook.Add(hookName, "[DIMCORE] Prevent Player Interactions with Extradimensional Entities", function(ply, ent)
		if ply:GetDimension() ~= ent:GetDimension() then
			return false
		end

		DimCore.PushContext(ply)
		timer.Simple(0, function()
			DimCore.PopContext()
		end)
	end)
end

-- Edge case, if a player is somehow in a vehicle that isnt in the same dimension
hook.Add("PlayerLeaveVehicle", "[DIMCORE] LeaveVehicle", function(ply, veh)
	if ply:GetDimension() ~= veh:GetDimension() then
		ply:SetDimension(veh:GetDimension())
	end
end)

-- Return all players to the default dimension if an admin ran map cleanup
--make sure this can check if a player is stuck in something and just respawn them later
hook.Add("PostCleanupMap", "[DIMCORE] MapCleanup", function()
	for k, v in ipairs(player.GetAll()) do
		v:SetDimension(DimCore.DEFAULT_DIMENSION)
	end
end)

hook.Add("EntityFireBullets", "[DIMCORE] Update DCT when entity fires a bullet", function(ent, data)
	DimCore.PushContext(ent)
end)

hook.Add("PostEntityFireBullets", "[DIMCORE] Update DCT when entity fires a bullet", function(ent)
	timer.Simple(0, function()
		DimCore.PopContext()
	end)
end)

hook.Add(
	"EntityTakeDamage",
	"[DIMCORE] Prevent entities from harming other entities across dimensions",
	function(target, dmg)
		xpcall(function()
			if
				not (
					target:GetDimension() == dmg:GetInflictor():GetDimension()
					or target:GetDimension() == dmg:GetAttacker():GetDimension()
				)
			then
				dmg:ScaleDamage(0)
				dmg:SetDamageForce(Vector())
			end
		end, function() end)
	end
)

hook.Add("CanTool", "[DIMCORE] Update DCT when player uses Toolgun", function(ply)
	DimCore.PushContext(ply)

	timer.Simple(0, function()
		DimCore.PopContext()
	end)
end)

hook.Add("EntityRemoved", "[DIMCORE] Keep DimensionsTable clean", function(ent)
	if not ent or not IsValid(ent) or not ent.GetDimension then
		return
	end
	xpcall(function()
		table.RemoveByValue(DimCore.DimensionsTable[ent:GetDimension()], ent)
	end, function() end)
end)
print("[DIMCORE] Loading complete.")
