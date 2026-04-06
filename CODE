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

local localPlayer = Players.LocalPlayer
local currentController = nil
if localPlayer.Character then
	currentController = MovementController.new(localPlayer.Character)
end
localPlayer.CharacterAdded:Connect(function(char)
	if currentController then
		currentController:Destroy()
	end
	currentController = MovementController.new(char)
end)
