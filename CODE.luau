local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local Players = game:GetService("Players")
local Workspace = game:GetService("Workspace")
local TweenService = game:GetService("TweenService")

-- simple signal system so different parts of the code can talk to each other
local Signal = {}
Signal.__index = Signal

function Signal.new()
	local self = setmetatable({}, Signal)
	self._bindable = Instance.new("BindableEvent")
	return self
end

function Signal:Connect(fn)
	return self._bindable.Event:Connect(fn)
end

function Signal:Fire(...)
	self._bindable:Fire(...)
end

function Signal:Destroy()
	self._bindable:Destroy()
end

-- maid is just used to clean up stuff like connections so we don’t leak memory
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

function Maid:Destroy()
	self:DoCleaning()
end

-- spring system for smooth movement (used for camera stuff)
local Spring = {}
Spring.__index = Spring

function Spring.new(mass, damping, constant)
	local self = setmetatable({}, Spring)
	self.Mass = mass or 5
	self.Damping = damping or 50
	self.Constant = constant or 250
	self.Position = Vector3.new()
	self.Velocity = Vector3.new()
	self.Target = Vector3.new()
	return self
end

function Spring:Shove(force)
	self.Velocity += force / self.Mass
end

function Spring:Update(dt)
	local displacement = self.Position - self.Target
	local force = (-self.Constant * displacement) - (self.Damping * self.Velocity)
	local accel = force / self.Mass

	self.Velocity += accel * dt
	self.Position += self.Velocity * dt

	return self.Position
end

-- handles undo / redo using a command system
local HistoryManager = {}
HistoryManager.__index = HistoryManager

function HistoryManager.new(max)
	return setmetatable({
		History = {},
		RedoStack = {},
		Max = max or 50
	}, HistoryManager)
end

function HistoryManager:Execute(cmd)
	cmd:Execute()
	table.insert(self.History, cmd)
	self.RedoStack = {}

	if #self.History > self.Max then
		table.remove(self.History, 1)
	end
end

function HistoryManager:Undo()
	if #self.History == 0 then return end
	local cmd = table.remove(self.History)
	cmd:Undo()
	table.insert(self.RedoStack, cmd)
end

function HistoryManager:Redo()
	if #self.RedoStack == 0 then return end
	local cmd = table.remove(self.RedoStack)
	cmd:Execute()
	table.insert(self.History, cmd)
end

-- command object for placing parts
local PlaceCommand = {}
PlaceCommand.__index = PlaceCommand

function PlaceCommand.new(prefab, cf, parent)
	return setmetatable({
		Prefab = prefab,
		CF = cf,
		Parent = parent,
		Instance = nil
	}, PlaceCommand)
end

function PlaceCommand:Execute()
	if not self.Instance then
		self.Instance = self.Prefab:Clone()
	end
	self.Instance:PivotTo(self.CF)
	self.Instance.Parent = self.Parent
end

function PlaceCommand:Undo()
	if self.Instance then
		self.Instance.Parent = nil
	end
end

-- helper math for snapping to grid
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

-- main building system
local PlacementSystem = {}
PlacementSystem.__index = PlacementSystem

function PlacementSystem.new(grid)
	local self = setmetatable({}, PlacementSystem)

	self.Maid = Maid.new()
	self.History = HistoryManager.new(20)

	self.Grid = grid or 2
	self.IsActive = false
	self.CurrentPrefab = nil
	self.Ghost = nil
	self.Valid = false
	self.TargetCF = CFrame.new()
	self.Rotation = CFrame.new()

	self.Camera = Workspace.CurrentCamera

	self.RaycastParams = RaycastParams.new()
	self.RaycastParams.FilterType = Enum.RaycastFilterType.Exclude

	self.OverlapParams = OverlapParams.new()
	self.OverlapParams.FilterType = Enum.RaycastFilterType.Exclude

	self.Highlight = Instance.new("Highlight")
	self.Highlight.FillTransparency = 0.5

	return self
end

function PlacementSystem:Equip(prefab)
	self:Unequip()

	self.CurrentPrefab = prefab
	self.Ghost = prefab:Clone()

	-- make ghost transparent so player knows it's a preview
	for _, v in pairs(self.Ghost:GetDescendants()) do
		if v:IsA("BasePart") then
			v.Transparency = 0.5
			v.CanCollide = false
		end
	end

	self.Highlight.Parent = self.Ghost
	self.Ghost.Parent = Workspace

	self.IsActive = true

	self.Maid:GiveTask(RunService.RenderStepped:Connect(function()
		self:_update()
	end))

	self.Maid:GiveTask(UserInputService.InputBegan:Connect(function(i, g)
		if not g then self:_input(i) end
	end))
end

function PlacementSystem:Unequip()
	self.IsActive = false
	self.Maid:DoCleaning()

	if self.Ghost then
		self.Ghost:Destroy()
	end
end

function PlacementSystem:_calc(ray)
	if not ray then return end

	local size = PlacementMath.GetSize(self.Ghost)
	local pos = ray.Position
	local normal = ray.Normal

	-- this rotates the object so it matches the surface (walls, floor, etc)
	local cf = CFrame.lookAt(pos, pos + normal)

	local offset = pos + normal * (size.Y/2)
	local snapped = PlacementMath.SnapVec(offset, self.Grid)

	return CFrame.new(snapped) * (cf - cf.Position) * self.Rotation
end

function PlacementSystem:_check(cf)
	local size = PlacementMath.GetSize(self.Ghost)
	local parts = Workspace:GetPartBoundsInBox(cf, size, self.OverlapParams)

	for _, p in pairs(parts) do
		if p.CanCollide then
			return false
		end
	end
	return true
end

function PlacementSystem:_update()
	if not self.IsActive or not self.CurrentPrefab then return end

	local mouse = UserInputService:GetMouseLocation()
	local ray = self.Camera:ViewportPointToRay(mouse.X, mouse.Y)
	local result = Workspace:Raycast(ray.Origin, ray.Direction * 50, self.RaycastParams)

	if result then
		self.TargetCF = self:_calc(result)

		-- smooth movement instead of snapping instantly
		local current = self.Ghost:GetPivot()
		self.Ghost:PivotTo(current:Lerp(self.TargetCF, 0.5))

		self.Valid = self:_check(self.TargetCF)
	else
		self.Valid = false
	end

	-- green = valid, red = blocked
	self.Highlight.FillColor = self.Valid and Color3.new(0,1,0) or Color3.new(1,0,0)
end

function PlacementSystem:Place()
	if not self.Valid or not self.CurrentPrefab then return end

	local cmd = PlaceCommand.new(self.CurrentPrefab, self.TargetCF, Workspace)
	self.History:Execute(cmd)

	-- little effect when placing
	local fx = Instance.new("Part")
	fx.Anchored = true
	fx.Size = PlacementMath.GetSize(self.Ghost)
	fx.CFrame = self.TargetCF
	fx.Material = Enum.Material.Neon
	fx.Transparency = 0.5
	fx.Parent = Workspace

	TweenService:Create(fx, TweenInfo.new(0.5), {
		Size = fx.Size * 1.5,
		Transparency = 1
	}):Play()

	task.delay(0.5, function() fx:Destroy() end)

	-- small camera bump for feedback
	Workspace.CurrentCamera.FieldOfView += 2
	task.delay(0.1, function()
		Workspace.CurrentCamera.FieldOfView -= 2
	end)
end

function PlacementSystem:_input(i)
	if i.UserInputType == Enum.UserInputType.MouseButton1 then
		self:Place()
	elseif i.KeyCode == Enum.KeyCode.R then
		self.Rotation *= CFrame.Angles(0, math.rad(90), 0)
	elseif i.KeyCode == Enum.KeyCode.Z and UserInputService:IsKeyDown(Enum.KeyCode.LeftControl) then
		self.History:Undo()
	elseif i.KeyCode == Enum.KeyCode.Y and UserInputService:IsKeyDown(Enum.KeyCode.LeftControl) then
		self.History:Redo()
	elseif i.KeyCode == Enum.KeyCode.X then
		self:Unequip()
	end
end

-- movement system (simplified dash)
local MovementController = {}
MovementController.__index = MovementController

function MovementController.new(char)
	local self = setmetatable({}, MovementController)

	self.Root = char:WaitForChild("HumanoidRootPart")
	self.Camera = Workspace.CurrentCamera
	self.Spring = Spring.new()
	self.CanDash = true

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
		vel.Attachment0 = Instance.new("Attachment", self.Root)
		vel.VectorVelocity = self.Root.CFrame.LookVector * 100
		vel.MaxForce = 100000
		vel.Parent = self.Root

		task.delay(0.2, function() vel:Destroy() end)
	end
end

function MovementController:_update(dt)
	local offset = self.Spring:Update(dt)
	self.Camera.CFrame *= CFrame.Angles(0,0,math.rad(offset.X))
end

-- simple test block
local function CreatePrefab()
	local m = Instance.new("Model")
	local p = Instance.new("Part")
	p.Size = Vector3.new(4,4,4)
	p.Anchored = true
	p.Parent = m
	m.PrimaryPart = p
	return m
end

-- basic UI so marker knows controls
local function CreateUI()
	local gui = Instance.new("ScreenGui")
	gui.Parent = Players.LocalPlayer:WaitForChild("PlayerGui")

	local txt = Instance.new("TextLabel")
	txt.Size = UDim2.new(0,400,0,150)
	txt.Position = UDim2.new(0,10,0,10)
	txt.BackgroundTransparency = 0.3
	txt.TextColor3 = Color3.new(1,1,1)
	txt.TextXAlignment = Enum.TextXAlignment.Left
	txt.TextYAlignment = Enum.TextYAlignment.Top
	txt.Font = Enum.Font.Code
	txt.TextSize = 14
	txt.Text = [[
P - placement mode
Click - place
R - rotate
Ctrl Z/Y - undo redo
X - exit

Q - dash
]]
	txt.Parent = gui
end

local player = Players.LocalPlayer
local placement = PlacementSystem.new(4)
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
