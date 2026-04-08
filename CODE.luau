local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local Players = game:GetService("Players")
local Workspace = game:GetService("Workspace")
local TweenService = game:GetService("TweenService")
local Debris = game:GetService("Debris")

local Signal = {}
Signal.__index = Signal
function Signal.new()
	local self = setmetatable({}, Signal)
	self._bindable = Instance.new("BindableEvent")
	return self
end
function Signal:Connect(handler)
	return self._bindable.Event:Connect(handler)
end
function Signal:Fire(...)
	self._bindable:Fire(...)
end
function Signal:Destroy()
	self._bindable:Destroy()
end

local Maid = {}
Maid.__index = Maid
function Maid.new()
	return setmetatable({_tasks = {}}, Maid)
end
function Maid:GiveTask(task)
	local taskId = #self._tasks + 1
	self._tasks[taskId] = task
	return taskId
end
function Maid:DoCleaning()
	for index, task in pairs(self._tasks) do
		if typeof(task) == "RBXScriptConnection" then
			task:Disconnect()
		elseif type(task) == "function" then
			task()
		elseif typeof(task) == "Instance" then
			task:Destroy()
		elseif type(task) == "table" and type(task.Destroy) == "function" then
			task:Destroy()
		end
		self._tasks[index] = nil
	end
end
function Maid:Destroy()
	self:DoCleaning()
end

local Spring = {}
Spring.__index = Spring
function Spring.new(mass: number, damping: number, constant: number)
	local self = setmetatable({}, Spring)
	self.Mass = mass or 5
	self.Damping = damping or 50
	self.Constant = constant or 250
	self.Target = Vector3.new()
	self.Position = Vector3.new()
	self.Velocity = Vector3.new()
	return self
end
function Spring:Shove(force: Vector3)
	self.Velocity += (force / self.Mass)
end
function Spring:Update(dt: number)
	local displacement = self.Position - self.Target
	local springForce = -self.Constant * displacement
	local dampingForce = -self.Damping * self.Velocity
	local acceleration = (springForce + dampingForce) / self.Mass
	self.Velocity += (acceleration * dt)
	self.Position += (self.Velocity * dt)
	return self.Position
end

local HistoryManager = {}
HistoryManager.__index = HistoryManager
function HistoryManager.new(maxHistory)
	local self = setmetatable({}, HistoryManager)
	self.History = {}
	self.RedoStack = {}
	self.MaxHistory = maxHistory or 50
	return self
end
function HistoryManager:Execute(command)
	command:Execute()
	table.insert(self.History, command)
	self.RedoStack = {}
	if #self.History > self.MaxHistory then
		table.remove(self.History, 1)
	end
end
function HistoryManager:Undo()
	if #self.History == 0 then return end
	local command = table.remove(self.History, #self.History)
	command:Undo()
	table.insert(self.RedoStack, command)
end
function HistoryManager:Redo()
	if #self.RedoStack == 0 then return end
	local command = table.remove(self.RedoStack, #self.RedoStack)
	command:Execute()
	table.insert(self.History, command)
end

local PlaceCommand = {}
PlaceCommand.__index = PlaceCommand
function PlaceCommand.new(modelPrefab, cframe, parent)
	local self = setmetatable({}, PlaceCommand)
	self.ModelPrefab = modelPrefab
	self.TargetCFrame = cframe
	self.TargetParent = parent
	self.PlacedInstance = nil
	return self
end
function PlaceCommand:Execute()
	if not self.PlacedInstance then
		self.PlacedInstance = self.ModelPrefab:Clone()
	end
	self.PlacedInstance:PivotTo(self.TargetCFrame)
	self.PlacedInstance.Parent = self.TargetParent
end
function PlaceCommand:Undo()
	if self.PlacedInstance then
		self.PlacedInstance.Parent = nil
	end
end

local PlacementMath = {}
function PlacementMath.SnapNumber(value, step)
	return math.round(value / step) * step
end
function PlacementMath.SnapVector(vector, step)
	return Vector3.new(
		PlacementMath.SnapNumber(vector.X, step),
		PlacementMath.SnapNumber(vector.Y, step),
		PlacementMath.SnapNumber(vector.Z, step)
	)
end
function PlacementMath.CalculateBoundingBox(model)
	local orientation, size = model:GetBoundingBox()
	return size
end

local PlacementSystem = {}
PlacementSystem.__index = PlacementSystem
function PlacementSystem.new(gridSize)
	local self = setmetatable({}, PlacementSystem)
	self.Maid = Maid.new()
	self.History = HistoryManager.new(20)
	self.GridSize = gridSize or 2
	self.RotationOffset = CFrame.new()
	self.MaxRange = 50
	self.IsActive = false
	self.CurrentPrefab = nil
	self.GhostModel = nil
	self.PlacementValid = false
	self.RaycastParams = RaycastParams.new()
	self.RaycastParams.FilterType = Enum.RaycastFilterType.Exclude
	self.RaycastParams.IgnoreWater = true
	self.OverlapParams = OverlapParams.new()
	self.OverlapParams.FilterType = Enum.RaycastFilterType.Exclude
	self.Camera = Workspace.CurrentCamera
	self.Highlight = Instance.new("Highlight")
	self.Highlight.FillTransparency = 0.5
	self.Highlight.OutlineTransparency = 0
	self.TargetCFrame = CFrame.new()
	return self
end
function PlacementSystem:Equip(modelPrefab)
	self:Unequip()
	self.CurrentPrefab = modelPrefab
	self.GhostModel = modelPrefab:Clone()
	for _, desc in pairs(self.GhostModel:GetDescendants()) do
		if desc:IsA("BasePart") then
			desc.CanCollide = false
			desc.CanQuery = false
			desc.CastShadow = false
			desc.Transparency = 0.5
		end
	end
	self.Highlight.Parent = self.GhostModel
	self.GhostModel.Parent = Workspace
	self.IsActive = true
	self.RotationOffset = CFrame.new()
	local filter = {self.GhostModel}
	if Players.LocalPlayer.Character then
		table.insert(filter, Players.LocalPlayer.Character)
	end
	self.RaycastParams.FilterDescendantsInstances = filter
	self.OverlapParams.FilterDescendantsInstances = filter
	self.Maid:GiveTask(RunService.RenderStepped:Connect(function()
		self:_onRenderStep()
	end))
	self.Maid:GiveTask(UserInputService.InputBegan:Connect(function(input, gpe)
		if gpe then return end
		self:_handleInput(input)
	end))
end
function PlacementSystem:Unequip()
	self.IsActive = false
	self.Maid:DoCleaning()
	if self.GhostModel then
		self.GhostModel:Destroy()
		self.GhostModel = nil
	end
	self.CurrentPrefab = nil
end
function PlacementSystem:Rotate(axis, degrees)
	local rad = math.rad(degrees)
	if axis == "X" then
		self.RotationOffset *= CFrame.Angles(rad, 0, 0)
	elseif axis == "Y" then
		self.RotationOffset *= CFrame.Angles(0, rad, 0)
	elseif axis == "Z" then
		self.RotationOffset *= CFrame.Angles(0, 0, rad)
	end
end
function PlacementSystem:_getMouseTarget()
	local mousePos = UserInputService:GetMouseLocation()
	local ray = self.Camera:ViewportPointToRay(mousePos.X, mousePos.Y)
	return Workspace:Raycast(ray.Origin, ray.Direction * self.MaxRange, self.RaycastParams)
end
function PlacementSystem:_calculatePlacement(rayResult)
	if not rayResult then return nil end
	local modelSize = PlacementMath.CalculateBoundingBox(self.GhostModel)
	local basePosition = rayResult.Position
	local normal = rayResult.Normal
	local upVector = Vector3.new(0, 1, 0)
	local dot = normal:Dot(upVector)
	local baseRotation = CFrame.lookAt(basePosition, basePosition + normal, math.abs(dot) > 0.99 and Vector3.new(0, 0, 1) or upVector)
	local offsetPosition = basePosition + (normal * (modelSize.Y / 2))
	local snappedPosition = PlacementMath.SnapVector(offsetPosition, self.GridSize)
	local yOffset = (modelSize.Y / 2) - PlacementMath.SnapNumber(modelSize.Y / 2, self.GridSize)
	snappedPosition = Vector3.new(snappedPosition.X, offsetPosition.Y + yOffset, snappedPosition.Z)
	local finalCFrame = CFrame.new(snappedPosition) * (baseRotation - baseRotation.Position) * self.RotationOffset
	return finalCFrame
end
function PlacementSystem:_checkCollisions(targetCFrame)
	local size = PlacementMath.CalculateBoundingBox(self.GhostModel)
	local parts = Workspace:GetPartBoundsInBox(targetCFrame, size, self.OverlapParams)
	for _, part in pairs(parts) do
		if part.CanCollide then
			return false
		end
	end
	return true
end
function PlacementSystem:_updateVisuals()
	if self.PlacementValid then
		self.Highlight.FillColor = Color3.fromRGB(0, 255, 0)
		self.Highlight.OutlineColor = Color3.fromRGB(0, 200, 0)
	else
		self.Highlight.FillColor = Color3.fromRGB(255, 0, 0)
		self.Highlight.OutlineColor = Color3.fromRGB(200, 0, 0)
	end
end
function PlacementSystem:_onRenderStep()
	if not self.IsActive or not self.GhostModel then return end
	local rayResult = self:_getMouseTarget()
	if rayResult then
		self.TargetCFrame = self:_calculatePlacement(rayResult)
		self.GhostModel:PivotTo(self.TargetCFrame:Lerp(self.GhostModel:GetPivot(), 0.5))
		self.PlacementValid = self:_checkCollisions(self.TargetCFrame)
		self.GhostModel.Parent = Workspace
	else
		self.PlacementValid = false
		self.GhostModel.Parent = nil
	end
	self:_updateVisuals()
end
function PlacementSystem:_handleInput(input)
	if input.UserInputType == Enum.UserInputType.MouseButton1 then
		self:Place()
	elseif input.KeyCode == Enum.KeyCode.R then
		self:Rotate("Y", 90)
	elseif input.KeyCode == Enum.KeyCode.T then
		self:Rotate("X", 90)
	elseif input.KeyCode == Enum.KeyCode.Z and UserInputService:IsKeyDown(Enum.KeyCode.LeftControl) then
		self.History:Undo()
	elseif input.KeyCode == Enum.KeyCode.Y and UserInputService:IsKeyDown(Enum.KeyCode.LeftControl) then
		self.History:Redo()
	elseif input.KeyCode == Enum.KeyCode.X then
		self:Unequip()
	end
end
function PlacementSystem:Place()
	if not self.PlacementValid or not self.IsActive then return end
	local command = PlaceCommand.new(self.CurrentPrefab, self.TargetCFrame, Workspace)
	self.History:Execute(command)
	local fxPart = Instance.new("Part")
	fxPart.Size = PlacementMath.CalculateBoundingBox(self.GhostModel)
	fxPart.CFrame = self.TargetCFrame
	fxPart.Anchored = true
	fxPart.CanCollide = false
	fxPart.Material = Enum.Material.Neon
	fxPart.Color = Color3.fromRGB(255, 255, 255)
	fxPart.Transparency = 0.5
	fxPart.Parent = Workspace
	local tweenInfo = TweenInfo.new(0.5, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
	local tween = TweenService:Create(fxPart, tweenInfo, {Size = fxPart.Size * 1.5, Transparency = 1})
	tween:Play()
	tween.Completed:Connect(function()
		fxPart:Destroy()
	end)
end
function PlacementSystem:Destroy()
	self:Unequip()
end

local MovementController = {}
MovementController.__index = MovementController
function MovementController.new(character: Model)
	local self = setmetatable({}, MovementController)
	self.Character = character
	self.Humanoid = character:WaitForChild("Humanoid")
	self.RootPart = character:WaitForChild("HumanoidRootPart")
	self.Maid = Maid.new()
	self.CameraSpring = Spring.new(5, 40, 300)
	self.FovSpring = Spring.new(2, 20, 150)
	self.FovSpring.Target = Vector3.new(70, 0, 0)
	self.FovSpring.Position = Vector3.new(70, 0, 0)
	self.State = "Idle"
	self.GrapplePoint = nil
	self.Rope = nil
	self.Attachment0 = nil
	self.Attachment1 = nil
	self.Camera = Workspace.CurrentCamera
	self.RaycastParams = RaycastParams.new()
	self.RaycastParams.FilterDescendantsInstances = {self.Character}
	self.RaycastParams.FilterType = Enum.RaycastFilterType.Exclude
	self.RaycastParams.IgnoreWater = true
	self.CanDash = true
	self.IsWallRunning = false
	self:_init()
	return self
end
function MovementController:_init()
	local attachment = Instance.new("Attachment")
	attachment.Parent = self.RootPart
	self.Attachment0 = attachment
	self.Maid:GiveTask(attachment)
	self.Maid:GiveTask(RunService.RenderStepped:Connect(function(dt)
		self:_onRenderStep(dt)
	end))
	self.Maid:GiveTask(UserInputService.InputBegan:Connect(function(input, gpe)
		if gpe then return end
		self:_handleInput(input, true)
	end))
	self.Maid:GiveTask(UserInputService.InputEnded:Connect(function(input, gpe)
		if gpe then return end
		self:_handleInput(input, false)
	end))
	self.Maid:GiveTask(self.Humanoid.StateChanged:Connect(function(oldState, newState)
		if newState == Enum.HumanoidStateType.Landed then
			self.CanDash = true
			self.IsWallRunning = false
		end
	end))
end
function MovementController:_handleInput(input: InputObject, isBegan: boolean)
	if input.KeyCode == Enum.KeyCode.E then
		if isBegan then
			self:_attemptGrapple()
		else
			self:_releaseGrapple()
		end
	elseif input.KeyCode == Enum.KeyCode.LeftShift then
		if isBegan then
			self.Humanoid.WalkSpeed = 26
			self.FovSpring.Target = Vector3.new(90, 0, 0)
		else
			self.Humanoid.WalkSpeed = 16
			self.FovSpring.Target = Vector3.new(70, 0, 0)
		end
	elseif input.KeyCode == Enum.KeyCode.Q and isBegan then
		self:_performDash()
	end
end
function MovementController:_attemptGrapple()
	local mousePos = UserInputService:GetMouseLocation()
	local ray = self.Camera:ViewportPointToRay(mousePos.X, mousePos.Y)
	local result = Workspace:Raycast(ray.Origin, ray.Direction * 250, self.RaycastParams)
	if result then
		self.GrapplePoint = result.Position
		self.State = "Grappling"
		self:_createRope(result.Instance, result.Position)
		self.Humanoid.PlatformStand = true
		local currentVel = self.RootPart.AssemblyLinearVelocity
		self.RootPart.AssemblyLinearVelocity = Vector3.new(currentVel.X, math.max(currentVel.Y, 50), currentVel.Z)
	end
end
function MovementController:_createRope(hitInstance: Instance, position: Vector3)
	if self.Rope then self.Rope:Destroy() end
	if self.Attachment1 then self.Attachment1:Destroy() end
	local att1 = Instance.new("Attachment")
	att1.WorldPosition = position
	att1.Parent = hitInstance
	self.Attachment1 = att1
	local rope = Instance.new("RopeConstraint")
	rope.Attachment0 = self.Attachment0
	rope.Attachment1 = self.Attachment1
	rope.Visible = true
	rope.Color = BrickColor.new("White")
	rope.Thickness = 0.1
	rope.Length = (self.RootPart.Position - position).Magnitude
	rope.Parent = self.RootPart
	self.Rope = rope
end
function MovementController:_releaseGrapple()
	self.State = "Idle"
	self.GrapplePoint = nil
	self.Humanoid.PlatformStand = false
	if self.Rope then
		self.Rope:Destroy()
		self.Rope = nil
	end
	if self.Attachment1 then
		self.Attachment1:Destroy()
		self.Attachment1 = nil
	end
end
function MovementController:_performDash()
	if not self.CanDash or self.State == "Grappling" then return end
	self.CanDash = false
	local moveDir = self.Humanoid.MoveDirection
	if moveDir.Magnitude < 0.1 then
		moveDir = self.RootPart.CFrame.LookVector
	end
	local dashForce = Instance.new("LinearVelocity")
	dashForce.Attachment0 = self.Attachment0
	dashForce.VectorVelocity = moveDir * 100
	dashForce.MaxForce = 100000
	dashForce.RelativeTo = Enum.ActuatorRelativeTo.World
	dashForce.Parent = self.RootPart
	self.FovSpring:Shove(Vector3.new(50, 0, 0))
	task.delay(0.2, function()
		dashForce:Destroy()
	end)
end
function MovementController:_updateWallRun(dt: number)
	if self.State == "Grappling" then return end
	local rightRay = Workspace:Raycast(self.RootPart.Position, self.RootPart.CFrame.RightVector * 3, self.RaycastParams)
	local leftRay = Workspace:Raycast(self.RootPart.Position, -self.RootPart.CFrame.RightVector * 3, self.RaycastParams)
	if (rightRay or leftRay) and self.Humanoid:GetState() == Enum.HumanoidStateType.Freefall then
		self.IsWallRunning = true
		self.CanDash = true
		local wallNormal = rightRay and rightRay.Normal or leftRay.Normal
		local cross = wallNormal:Cross(Vector3.new(0, 1, 0))
		if self.Humanoid.MoveDirection.Magnitude > 0 then
			local forceDir = cross * math.sign(self.Humanoid.MoveDirection:Dot(cross))
			self.RootPart.AssemblyLinearVelocity = Vector3.new(forceDir.X * 45, 2, forceDir.Z * 45)
			self.CameraSpring.Target = Vector3.new(rightRay and 15 or -15, 0, 0)
		end
	else
		self.IsWallRunning = false
	end
end
function MovementController:_onRenderStep(dt: number)
	local velocity = self.RootPart.AssemblyLinearVelocity
	local tiltTarget = 0
	if self.State == "Grappling" and self.GrapplePoint then
		local dir = (self.GrapplePoint - self.RootPart.Position).Unit
		local right = self.Camera.CFrame.RightVector
		tiltTarget = right:Dot(dir) * 20
		if self.Rope then
			self.Rope.Length = math.max(10, self.Rope.Length - (dt * 25))
		end
	elseif not self.IsWallRunning then
		local localVel = self.RootPart.CFrame:VectorToObjectSpace(velocity)
		tiltTarget = math.clamp(-localVel.X * 0.3, -12, 12)
	end
	if not self.IsWallRunning then
		self.CameraSpring.Target = Vector3.new(tiltTarget, 0, 0)
	end
	local camOffset = self.CameraSpring:Update(dt)
	self.Camera.CFrame *= CFrame.Angles(0, 0, math.rad(camOffset.X))
	local fovUpdate = self.FovSpring:Update(dt)
	self.Camera.FieldOfView = fovUpdate.X
	self:_updateWallRun(dt)
end
function MovementController:Destroy()
	self.Maid:Destroy()
	self:_releaseGrapple()
end

local function CreateDemoPrefab()
	local model = Instance.new("Model")
	local root = Instance.new("Part")
	root.Size = Vector3.new(4, 4, 4)
	root.Color = Color3.fromRGB(100, 150, 255)
	root.Material = Enum.Material.SmoothPlastic
	root.Anchored = true
	root.Name = "Root"
	root.Parent = model
	local top = Instance.new("Part")
	top.Size = Vector3.new(2, 2, 2)
	top.Color = Color3.fromRGB(255, 100, 100)
	top.Material = Enum.Material.Neon
	top.Anchored = true
	top.CFrame = root.CFrame * CFrame.new(0, 3, 0)
	top.Parent = model
	model.PrimaryPart = root
	return model
end

local localPlayer = Players.LocalPlayer
local currentController = nil
local placementSystem = PlacementSystem.new(4)
local demoPrefab = CreateDemoPrefab()

if localPlayer.Character then
	currentController = MovementController.new(localPlayer.Character)
end

localPlayer.CharacterAdded:Connect(function(char)
	if currentController then
		currentController:Destroy()
	end
	currentController = MovementController.new(char)
end)

UserInputService.InputBegan:Connect(function(input, gpe)
	if gpe then return end
	if input.KeyCode == Enum.KeyCode.P and not placementSystem.IsActive then
		placementSystem:Equip(demoPrefab)
	end
end)
