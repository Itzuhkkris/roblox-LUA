-- written by Kris
-- this script combines a placement system + basic movement abilities

local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local Players = game:GetService("Players")
local Workspace = game:GetService("Workspace")
local TweenService = game:GetService("TweenService")

-- maid is used to track connections/instances so we can clean them up properly
-- this avoids memory leaks when systems get turned on/off
local Maid = {}
Maid.__index = Maid

function Maid.new()
	return setmetatable({_tasks = {}}, Maid)
end

function Maid:GiveTask(task)
	table.insert(self._tasks, task)
end

function Maid:DoCleaning()
	for _, task in pairs(self._tasks) do
		if typeof(task) == "RBXScriptConnection" then
			task:Disconnect()
		elseif typeof(task) == "Instance" then
			task:Destroy()
		elseif type(task) == "function" then
			task()
		end
	end
	table.clear(self._tasks)
end

-- spring is used for smooth camera movement instead of instant snapping
-- this feels better for the player and simulates real physics (damping + stiffness)
local Spring = {}
Spring.__index = Spring

function Spring.new()
	return setmetatable({
		Position = Vector3.new(),
		Velocity = Vector3.new(),
		Target = Vector3.new()
	}, Spring)
end

function Spring:Update(dt)
	local displacement = self.Position - self.Target
	
	-- force pulls position back toward target (like a spring)
	local force = (-200 * displacement) - (30 * self.Velocity)
	local accel = force / 5
	
	self.Velocity += accel * dt
	self.Position += self.Velocity * dt
	
	return self.Position
end

-- command system lets us undo/redo placement
-- instead of deleting objects, we store actions so they can be reversed
local HistoryManager = {}
HistoryManager.__index = HistoryManager

function HistoryManager.new()
	return setmetatable({History = {}, Redo = {}}, HistoryManager)
end

function HistoryManager:Execute(cmd)
	cmd:Execute()
	table.insert(self.History, cmd)
	self.Redo = {}
end

function HistoryManager:Undo()
	local cmd = table.remove(self.History)
	if cmd then
		cmd:Undo()
		table.insert(self.Redo, cmd)
	end
end

function HistoryManager:Redo()
	local cmd = table.remove(self.Redo)
	if cmd then
		cmd:Execute()
		table.insert(self.History, cmd)
	end
end

-- each placement is stored as a command so it can be undone
local PlaceCommand = {}
PlaceCommand.__index = PlaceCommand

function PlaceCommand.new(prefab, cf)
	return setmetatable({
		Prefab = prefab,
		CF = cf,
		Instance = nil
	}, PlaceCommand)
end

function PlaceCommand:Execute()
	if not self.Instance then
		self.Instance = self.Prefab:Clone()
	end
	self.Instance:PivotTo(self.CF)
	self.Instance.Parent = Workspace
end

function PlaceCommand:Undo()
	if self.Instance then
		self.Instance.Parent = nil
	end
end

-- helper math for snapping placement to a grid
-- this makes building feel consistent instead of random placement
local PlacementMath = {}

function PlacementMath.Snap(n, step)
	return math.round(n / step) * step
end

function PlacementMath.SnapVec(v, step)
	return Vector3.new(
		PlacementMath.Snap(v.X, step),
		PlacementMath.Snap(v.Y, step),
		PlacementMath.Snap(v.Z, step)
	)
end

function PlacementMath.GetSize(model)
	local _, size = model:GetBoundingBox()
	return size
end

-- main placement system
local PlacementSystem = {}
PlacementSystem.__index = PlacementSystem

function PlacementSystem.new()
	local self = setmetatable({}, PlacementSystem)

	self.Maid = Maid.new()
	self.History = HistoryManager.new()

	self.Grid = 4
	self.Active = false
	self.Ghost = nil
	self.Valid = false
	self.TargetCF = CFrame.new()

	self.Camera = Workspace.CurrentCamera

	-- raycast ignores the ghost so we don’t hit our own preview
	self.RaycastParams = RaycastParams.new()
	self.RaycastParams.FilterType = Enum.RaycastFilterType.Exclude

	-- overlap is used to check collisions before placing
	self.OverlapParams = OverlapParams.new()
	self.OverlapParams.FilterType = Enum.RaycastFilterType.Exclude

	return self
end

function PlacementSystem:Equip(prefab)
	self:Unequip()

	self.Active = true
	self.Prefab = prefab
	self.Ghost = prefab:Clone()

	-- ghost is semi-transparent so player knows it's not placed yet
	for _, v in pairs(self.Ghost:GetDescendants()) do
		if v:IsA("BasePart") then
			v.Transparency = 0.5
			v.CanCollide = false
		end
	end

	self.Ghost.Parent = Workspace

	self.Maid:GiveTask(RunService.RenderStepped:Connect(function()
		self:_update()
	end))

	self.Maid:GiveTask(UserInputService.InputBegan:Connect(function(i,g)
		if not g then self:_input(i) end
	end))
end

function PlacementSystem:Unequip()
	self.Active = false
	self.Maid:DoCleaning()

	if self.Ghost then
		self.Ghost:Destroy()
	end
end

function PlacementSystem:_update()
	if not self.Active then return end

	local mouse = UserInputService:GetMouseLocation()
	local ray = self.Camera:ViewportPointToRay(mouse.X, mouse.Y)

	local result = Workspace:Raycast(ray.Origin, ray.Direction * 50, self.RaycastParams)

	if result then
		local size = PlacementMath.GetSize(self.Ghost)

		-- align object to surface using normal
		-- this allows placing on walls, not just ground
		local cf = CFrame.lookAt(result.Position, result.Position + result.Normal)

		local offset = result.Position + result.Normal * (size.Y/2)
		local snapped = PlacementMath.SnapVec(offset, self.Grid)

		self.TargetCF = CFrame.new(snapped) * (cf - cf.Position)

		-- smooth movement so preview doesn’t jitter
		local current = self.Ghost:GetPivot()
		self.Ghost:PivotTo(current:Lerp(self.TargetCF, 0.5))

		self.Valid = true
	else
		self.Valid = false
	end
end

function PlacementSystem:Place()
	if not self.Valid then return end

	local cmd = PlaceCommand.new(self.Prefab, self.TargetCF)
	self.History:Execute(cmd)

	-- visual feedback so placement feels responsive
	local fx = Instance.new("Part")
	fx.Anchored = true
	fx.Size = Vector3.new(4,4,4)
	fx.CFrame = self.TargetCF
	fx.Material = Enum.Material.Neon
	fx.Transparency = 0.5
	fx.Parent = Workspace

	TweenService:Create(fx, TweenInfo.new(0.4), {
		Transparency = 1
	}):Play()

	task.delay(0.4, function()
		fx:Destroy()
	end)
end

function PlacementSystem:_input(i)
	if i.UserInputType == Enum.UserInputType.MouseButton1 then
		self:Place()
	elseif i.KeyCode == Enum.KeyCode.Z and UserInputService:IsKeyDown(Enum.KeyCode.LeftControl) then
		self.History:Undo()
	elseif i.KeyCode == Enum.KeyCode.Y and UserInputService:IsKeyDown(Enum.KeyCode.LeftControl) then
		self.History:Redo()
	elseif i.KeyCode == Enum.KeyCode.X then
		self:Unequip()
	end
end

-- movement controller handles dash
-- uses physics instead of teleporting so it feels natural
local MovementController = {}
MovementController.__index = MovementController

function MovementController.new(char)
	local self = setmetatable({}, MovementController)

	self.Root = char:WaitForChild("HumanoidRootPart")
	self.Spring = Spring.new()
	self.CanDash = true

	-- reuse one attachment instead of creating new every dash (more efficient)
	self.Attachment = Instance.new("Attachment")
	self.Attachment.Parent = self.Root

	RunService.RenderStepped:Connect(function(dt)
		self:_update(dt)
	end)

	UserInputService.InputBegan:Connect(function(i,g)
		if not g then self:_input(i) end
	end)

	return self
end

function MovementController:_input(i)
	if i.KeyCode == Enum.KeyCode.Q and self.CanDash then
		self.CanDash = false

		local vel = Instance.new("LinearVelocity")
		vel.Attachment0 = self.Attachment
		vel.VectorVelocity = self.Root.CFrame.LookVector * 100
		vel.MaxForce = 100000
		vel.Parent = self.Root

		-- short duration so it feels like a burst
		task.delay(0.2, function()
			vel:Destroy()
			self.CanDash = true
		end)
	end
end

function MovementController:_update(dt)
	local offset = self.Spring:Update(dt)

	-- small tilt effect based on spring
	Workspace.CurrentCamera.CFrame *= CFrame.Angles(0,0,math.rad(offset.X))
end

-- simple test prefab (just a block)
local function CreatePrefab()
	local m = Instance.new("Model")
	local p = Instance.new("Part")
	p.Size = Vector3.new(4,4,4)
	p.Anchored = true
	p.Parent = m
	m.PrimaryPart = p
	return m
end

-- UI so the person marking knows controls instantly
local function CreateUI()
	local gui = Instance.new("ScreenGui")
	gui.Parent = Players.LocalPlayer:WaitForChild("PlayerGui")

	local txt = Instance.new("TextLabel")
	txt.Size = UDim2.new(0,400,0,140)
	txt.Position = UDim2.new(0,10,0,10)
	txt.BackgroundTransparency = 0.3
	txt.TextColor3 = Color3.new(1,1,1)
	txt.TextXAlignment = Enum.TextXAlignment.Left
	txt.TextYAlignment = Enum.TextYAlignment.Top
	txt.Font = Enum.Font.Code
	txt.TextSize = 14
	txt.Text = [[
P - build mode
Click - place
Ctrl Z/Y - undo redo
X - exit

Q - dash
]]
	txt.Parent = gui
end

-- init
local player = Players.LocalPlayer
local placement = PlacementSystem.new()
local prefab = CreatePrefab()

CreateUI()

UserInputService.InputBegan:Connect(function(i,g)
	if not g and i.KeyCode == Enum.KeyCode.P then
		placement:Equip(prefab)
	end
end)

player.CharacterAdded:Connect(function(char)
	MovementController.new(char)
end)

if player.Character then
	MovementController.new(player.Character)
end
