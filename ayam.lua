-- Kaitun Ayam: jalankan seluruh file ini. Sumber disertakan agar bisa dilanjutkan setelah teleport.
local source = [========[
-- Turkey Auto Grab + cari farmer dinamis (tanpa koordinat)
-- Auto Grab   : teleport ke ayam kecil yang prompt Grab-nya aktif, lalu grab
-- Auto Kirim  : kalau lagi pegang ayam, teleport ke NPC farmer (dicari lewat teks "Bring turkeys here" / Highlight, tanpa nama)
-- Kaitun      : Auto Grab + Auto Kirim ON; pindah server setelah semua ayam kecil habis dikirim.
-- Pindah Server: otomatis saat kosong, atau lewat tombol untuk pindah manual.
-- Auto Masuk : Continue -> cek ayam (kosong = langsung pindah server) -> I agree -> lompat & farming.
--              Pop-up acara tidak ditunggu; kalau muncul sesudah agree, ditutup di background.
-- Butuh executor dengan fireproximityprompt (fallback: InputHoldBegin).

local SCRIPT_SOURCE = ...
local SCRIPT_VERSION = "5.0-kaitun"
print("[TurkeyAuto " .. SCRIPT_VERSION .. "/BOOT] skrip mulai")

local Players = game:GetService("Players")
local UIS = game:GetService("UserInputService")
local HttpService = game:GetService("HttpService")
local TeleportService = game:GetService("TeleportService")
local GuiService = game:GetService("GuiService")

if _G.__TurkeyAuto then pcall(_G.__TurkeyAuto) end

local running = true
local gui
local connections = {}
local navigationWorkers = {}
local hopGeneration = 0

-- Cleanup tersedia juga ketika autoexec masih menunggu pemain atau PlayerGui.
_G.__TurkeyAuto = function()
	if not running then return end
	running = false
	hopGeneration += 1
	for _, connection in ipairs(connections) do connection:Disconnect() end
	for worker in pairs(navigationWorkers) do pcall(task.cancel, worker) end
	if gui then gui:Destroy() end
end

local lp = Players.LocalPlayer
local function refreshPlayer()
	lp = Players.LocalPlayer
	return lp
end

local enabled, sendEnabled = true, true
local grabCount, snapCount = 0, 0
local hopBusy, hopAttempt = false, nil
local hopNoticeUntil = 0
local autoJoinEnabled, joinBusy = true, true
local grabPendingUntil, autoHopRetryAt = 0, 0
local emptyScans = 0

local function connect(signal, callback)
	local connection = signal:Connect(callback)
	table.insert(connections, connection)
	return connection
end

---------------------------------------------------------------- helper
local function getHRP()
	local c = lp and lp.Character
	return c and c:FindFirstChild("HumanoidRootPart")
end

local function farmCharacter()
	local character = lp and lp.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	local root = getHRP()
	if root and humanoid and humanoid.Health > 0 then return root, humanoid end
end

-- true kalau ada TurkeyHold weld yang nempel ke karakter kita
local function isHolding()
	local c = lp and lp.Character
	if not c then return false end
	for _, m in ipairs(workspace:GetChildren()) do
		if m.Name == "Turkey" then
			local root = m:FindFirstChild("HumanoidRootPart")
			local w = root and root:FindFirstChild("TurkeyHold")
			if w and ((w.Part0 and w.Part0:IsDescendantOf(c)) or (w.Part1 and w.Part1:IsDescendantOf(c))) then
				return true
			end
		end
	end
	return false
end

-- ayam kecil terdekat yang prompt Grab-nya aktif (boss otomatis ke-skip)
local function nearestTurkey()
	local me = getHRP()
	if not me then return end
	local bestRoot, bestPrompt, bestDist
	for _, m in ipairs(workspace:GetChildren()) do
		if m.Name == "Turkey" and m:IsA("Model") and not m:GetAttribute("Ungrabbable") then
			local root = m:FindFirstChild("HumanoidRootPart")
			local p = root and root:FindFirstChildOfClass("ProximityPrompt")
			if p and p.Enabled then
				local d = (root.Position - me.Position).Magnitude
				if not bestDist or d < bestDist then
					bestRoot, bestPrompt, bestDist = root, p, d
				end
			end
		end
	end
	return bestRoot, bestPrompt, bestDist
end

local function press(prompt)
	if fireproximityprompt then
		pcall(fireproximityprompt, prompt)
	else
		pcall(function()
			prompt:InputHoldBegin()
			task.wait(0.05)
			prompt:InputHoldEnd()
		end)
	end
end

local function npcRoot(m)
	return m:FindFirstChild("HumanoidRootPart") or m.PrimaryPart or m:FindFirstChildWhichIsA("BasePart", true)
end

-- Cari farmer TANPA nama (nama NPC diacak tiap round). Urutan:
-- 1) teks "Bring turkeys here" di dalam model NPC
-- 2) teks itu di BillboardGui PlayerGui yang Adornee-nya NPC
-- 3) Highlight (outline emas) yang aktif di model NPC
-- 4) fallback atribut Invulnerable/CanFight, HANYA kalau kandidatnya tepat satu
local farmerCache
local farmerLastSearch = 0

local function isBringLabel(o)
	return (o:IsA("TextLabel") or o:IsA("TextButton"))
		and o.Text:lower():find("bring turkeys", 1, true) ~= nil
end

local function findFarmer()
	if farmerCache and farmerCache.Parent and npcRoot(farmerCache) then
		return farmerCache
	end
	farmerCache = nil

	-- jangan scan berat tiap 0.15 detik kalau belum ketemu
	if os.clock() - farmerLastSearch < 1 then return nil end
	farmerLastSearch = os.clock()

	local folder = workspace:FindFirstChild("NPCs")

	if folder then
		for _, m in ipairs(folder:GetChildren()) do
			if m:IsA("Model") and npcRoot(m) then
				for _, d in ipairs(m:GetDescendants()) do
					if isBringLabel(d) then
						farmerCache = m
						return m
					end
				end
			end
		end
	end

	local pg = lp and lp:FindFirstChild("PlayerGui")
	if pg then
		for _, d in ipairs(pg:GetDescendants()) do
			if isBringLabel(d) then
				local bb = d:FindFirstAncestorOfClass("BillboardGui")
				local a = bb and bb.Adornee
				local model = a and (a:IsA("Model") and a or a:FindFirstAncestorOfClass("Model"))
				if model and model:IsDescendantOf(workspace) and npcRoot(model) then
					farmerCache = model
					return model
				end
			end
		end
	end

	if folder then
		for _, m in ipairs(folder:GetChildren()) do
			if m:IsA("Model") and npcRoot(m) then
				for _, d in ipairs(m:GetDescendants()) do
					if d:IsA("Highlight") and d.Enabled then
						farmerCache = m
						return m
					end
				end
			end
		end
	end

	if folder then
		local only, n = nil, 0
		for _, m in ipairs(folder:GetChildren()) do
			if m:IsA("Model") and m:GetAttribute("Invulnerable") == true
				and m:GetAttribute("CanFight") == false and npcRoot(m) then
				only, n = m, n + 1
			end
		end
		if n == 1 then
			farmerCache = only
			return only
		end
	end

	return nil
end

local function toClipboard(text)
	print(text)
	if setclipboard then pcall(setclipboard, text) end
end

-- daftar semua NPC + posisi + SEMUA atribut + nama child, buat mastiin siapa farmer-nya
local function dumpNPCs()
	local folder = workspace:FindFirstChild("NPCs")
	local lines = { "=== dump Workspace.NPCs ===" }
	if folder then
		local f = findFarmer()
		for _, m in ipairs(folder:GetChildren()) do
			local r = m:IsA("Model") and npcRoot(m)
			local pos = r and string.format("(%.0f, %.0f, %.0f)", r.Position.X, r.Position.Y, r.Position.Z) or "-"
			local attrs = {}
			for k, v in pairs(m:GetAttributes()) do table.insert(attrs, k .. "=" .. tostring(v)) end
			table.sort(attrs)
			local kids = {}
			for i, c in ipairs(m:GetChildren()) do
				if i > 14 then break end
				table.insert(kids, c.Name)
			end
			table.insert(lines, string.format("%s%s | pos=%s\n    attr: %s\n    child: %s",
				m == f and "[FARMER?] " or "", m.Name, pos, table.concat(attrs, ", "), table.concat(kids, ", ")))
		end
	else
		table.insert(lines, "Workspace.NPCs tidak ada")
	end
	toClipboard(table.concat(lines, "\n"))
end

-- catat objek di sekitar lu (NPC diprioritaskan)
local function snapshotNearby(radius, reason)
	local me = getHRP()
	if not me then return end
	snapCount += 1
	local exclude = {}
	for _, pl in ipairs(Players:GetPlayers()) do
		if pl.Character then table.insert(exclude, pl.Character) end
	end
	local params = OverlapParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.FilterDescendantsInstances = exclude

	local found = {}
	for _, part in ipairs(workspace:GetPartBoundsInRadius(me.Position, radius, params)) do
		local obj = part:FindFirstAncestorOfClass("Model") or part
		local path = obj:GetFullName()
		if not path:find("%.Traffic") then
			local d = (part.Position - me.Position).Magnitude
			if not found[obj] or d < found[obj].dist then
				found[obj] = { obj = obj, path = path, dist = d, npc = path:find("^Workspace%.NPCs") ~= nil }
			end
		end
	end
	local list = {}
	for _, e in pairs(found) do table.insert(list, e) end
	table.sort(list, function(a, b)
		if a.npc ~= b.npc then return a.npc end
		return a.dist < b.dist
	end)

	local pos = me.Position
	local lines = { string.format("=== snapshot #%d | %s | pos lu (%.0f, %.0f, %.0f) | radius %d ===",
		snapCount, reason, pos.X, pos.Y, pos.Z, radius) }
	for i = 1, math.min(#list, 40) do
		local e = list[i]
		local extra = {}
		for k, v in pairs(e.obj:GetAttributes()) do
			if #extra < 6 then table.insert(extra, k .. "=" .. tostring(v)) end
		end
		local n = 0
		for _, d in ipairs(e.obj:GetDescendants()) do
			n += 1
			if n > 300 then break end
			if d:IsA("ProximityPrompt") then
				table.insert(extra, string.format("prompt[%s/%s]", d.ActionText, d.ObjectText))
			end
		end
		table.insert(lines, string.format("%2d. %s | %s | jarak=%d%s", i, e.obj.ClassName, e.path,
			math.floor(e.dist), #extra > 0 and (" | " .. table.concat(extra, ", ")) or ""))
	end
	toClipboard(table.concat(lines, "\n"))
end

---------------------------------------------------------------- GUI
gui = Instance.new("ScreenGui")
gui.Name = "TurkeyAutoGui"
gui.ResetOnSpawn = false
gui.DisplayOrder = 100000
local function attachGui()
	if not running then return false end
	local player = refreshPlayer()
	local playerGui = player and player:FindFirstChildOfClass("PlayerGui")
	if gui.Parent and gui.Parent:IsA("PlayerGui") and gui.Parent ~= playerGui then gui.Parent = nil end
	if gui.Parent then return true end
	local hiddenRoot, core
	if type(gethui) == "function" then pcall(function() hiddenRoot = gethui() end) end
	pcall(function() core = game:GetService("CoreGui") end)
	for _, root in ipairs({ hiddenRoot or false, core or false, playerGui or false }) do
		if root then
			local ok = pcall(function() gui.Parent = root end)
			if not running then return false end
			if ok and gui.Parent then return true end
		end
	end
	return false
end
attachGui()

local frame = Instance.new("Frame")
frame.Size = UDim2.fromOffset(240, 366)
frame.Position = UDim2.new(0.02, 0, 0.2, 0)
frame.BackgroundColor3 = Color3.fromRGB(30, 30, 36)
frame.BorderSizePixel = 0
frame.Parent = gui
Instance.new("UICorner", frame).CornerRadius = UDim.new(0, 8)

local function makeLabel(text, y, h)
	local l = Instance.new("TextLabel")
	l.BackgroundTransparency = 1
	l.Position = UDim2.fromOffset(8, y)
	l.Size = UDim2.new(1, -16, 0, h)
	l.Font = Enum.Font.Gotham
	l.TextSize = 13
	l.TextColor3 = Color3.new(1, 1, 1)
	l.TextXAlignment = Enum.TextXAlignment.Left
	l.TextYAlignment = Enum.TextYAlignment.Top
	l.TextWrapped = true
	l.Text = text
	l.Parent = frame
	return l
end

local function makeButton(text, y, color)
	local b = Instance.new("TextButton")
	b.Position = UDim2.fromOffset(8, y)
	b.Size = UDim2.new(1, -16, 0, 26)
	b.BackgroundColor3 = color
	b.BorderSizePixel = 0
	b.Font = Enum.Font.GothamBold
	b.TextSize = 13
	b.TextColor3 = Color3.new(1, 1, 1)
	b.Text = text
	b.Parent = frame
	Instance.new("UICorner", b).CornerRadius = UDim.new(0, 6)
	return b
end

local RED, GREEN = Color3.fromRGB(170, 50, 50), Color3.fromRGB(50, 150, 70)
local BLUE, GOLD = Color3.fromRGB(50, 90, 160), Color3.fromRGB(150, 110, 30)

local title = makeLabel("Turkey Auto " .. SCRIPT_VERSION, 4, 20)
title.Font = Enum.Font.GothamBold
local grabBtn = makeButton("Auto Grab: ON", 28, GREEN)
local sendBtn = makeButton("Auto Kirim ke Farmer: ON", 58, GREEN)
local tpBtn = makeButton("TP ke farmer sekarang", 88, BLUE)
local dumpBtn = makeButton("Dump NPC (cek farmer)", 118, GOLD)
local scanBtn = makeButton("Scan sekitar", 148, GOLD)
local posBtn = makeButton("Catat posisi sekarang", 178, BLUE)
local joinBtn = makeButton("Auto Masuk: ON", 208, GREEN)
local joinDumpBtn = makeButton("Dump UI Masuk", 238, GOLD)
local hopBtn = makeButton("Pindah Server", 268, BLUE)
local status = makeLabel("Status: menyiapkan masuk...", 300, 40)
local counter = makeLabel("Grab: 0 | snapshot: 0", 344, 18)

local function setStatus(t, background)
	if not running or hopBusy then return end
	if background and (joinBusy or os.clock() < hopNoticeUntil) then return end
	local text = "Status: " .. t
	if status.Text ~= text then status.Text = text end
end
local function updateCounter() counter.Text = string.format("Grab: %d | snapshot: %d", grabCount, snapCount) end

---------------------------------------------------------------- urutan masuk
local joinAwaitingRules, joinAwaitingEvent, joinEventSeen = false, false, false
local joinConfirmation, coreGuiConfirmed = nil, false
local lastJoinMessage, lastClickTarget, lastClickAt = "", nil, 0
local lastClickReason
local lastJoinError
local joinIntroHandled = false
-- masuk dianggap selesai begitu "I agree" beres + karakter berdiri; pop-up acara TIDAK ditunggu
-- (kalau muncul belakangan, ditutup sambil farming jalan).
local joinDone, joinDoneAt = false, 0
local SETTLE_AFTER_JOIN = 1 -- detik, cuma dipakai kalau ayam sudah ada saat agree
local PRECHECK_SETTLE = 1.2 -- detik setelah Continue sebelum cek ayam
local joinContinued, joinContinuedAt, joinAgreed, rulesSeen, eventOpen = false, 0, false, false, false
local agreeMissing = 0 -- hitungan scan berturut-turut tanpa tombol agree (anti salah deteksi sesaat)
-- true selama sudah lewat Continue tapi belum klik I agree
local function joinPrecheck()
	return joinBusy and joinContinued and not joinAgreed and not joinDone and autoJoinEnabled
end
local bootstrapStarted = os.clock()
local lastBootstrapClick, bootstrapClicks = -math.huge, 0
local virtualInput, virtualInputManager
local mouseInput
pcall(function() virtualInputManager = game:GetService("VirtualInputManager") end)
task.spawn(function()
	local ok, input = pcall(function() return UIS:CreateVirtualInput() end)
	if running and ok then virtualInput = input end
end)
pcall(function()
	connect(UIS.InputBegan, function(input)
		if input.UserInputType == Enum.UserInputType.MouseButton1 then mouseInput = input end
	end)
end)

local function uiText(object)
	if not (object:IsA("TextLabel") or object:IsA("TextButton")) then return "" end
	local text = object.ContentText
	if type(text) ~= "string" or text == "" then text = object.Text end
	local normalized = text:lower():gsub("<.->", ""):gsub("%s+", " ")
	return normalized
end

local function compactUIKey(text)
	local key = text:lower():gsub("<.->", ""):gsub("[^%w]", "")
	return key
end

local function uiScreenPosition(object)
	local position = object.AbsolutePosition + object.AbsoluteSize / 2
	-- Konversi input memakai GuiInset seperti pada skrip referensi.
	local ok, inset = pcall(function() return GuiService:GetGuiInset() end)
	if ok then position += inset end
	return position
end

local function uiVisible(object, scanning)
	if not object:IsA("GuiObject") or not object.Parent then return false, "bukan GuiObject aktif" end
	local size = object.AbsoluteSize
	if size.X <= 0 or size.Y <= 0 then return false, "ukuran nol" end
	local center = object.AbsolutePosition + size / 2
	local parent = object
	while parent do
		if scanning and (parent == gui or parent.Name == "ExperienceChat"
			or parent.Name == "Chat" or parent.Name == "BubbleChat") then return false, "panel sendiri/chat" end
		if parent:IsA("GuiObject") then
			if not parent.Visible then return false, "Visible=false pada " .. parent:GetFullName() end
			if parent:IsA("CanvasGroup") and parent.GroupTransparency >= 1 then return false, "CanvasGroup transparan" end
			if parent.ClipsDescendants then
				local position, bounds = parent.AbsolutePosition, parent.AbsoluteSize
				if center.X < position.X or center.Y < position.Y
					or center.X >= position.X + bounds.X or center.Y >= position.Y + bounds.Y then return false, "terpotong ClipsDescendants" end
			end
		elseif parent:IsA("ScreenGui") and not parent.Enabled then
			return false, "ScreenGui.Enabled=false"
		end
		parent = parent.Parent
	end
	local camera = workspace.CurrentCamera
	if camera then
		local position = uiScreenPosition(object)
		if position.X < 0 or position.Y < 0 or position.X >= camera.ViewportSize.X
			or position.Y >= camera.ViewportSize.Y then return false, "pusat di luar viewport" end
	end
	return true
end

local function uiButton(object)
	local current = object
	while current and current:IsA("GuiObject") do
		if current:IsA("GuiButton") then return current end
		current = current.Parent
	end
	-- Sebagian UI menaruh label dan tombol transparan sebagai saudara.
	local parent = object.Parent
	if not parent or not parent:IsA("GuiObject") then return end
	local center = object.AbsolutePosition + object.AbsoluteSize / 2
	local candidate, bestArea
	for _, child in ipairs(parent:GetDescendants()) do
		if child:IsA("GuiButton") and uiVisible(child) then
			local position, size = child.AbsolutePosition, child.AbsoluteSize
			if center.X >= position.X and center.Y >= position.Y
				and center.X < position.X + size.X and center.Y < position.Y + size.Y then
				local area = size.X * size.Y
				if not bestArea or area < bestArea then
					candidate, bestArea = child, area
				elseif area == bestArea then
					candidate = nil
				end
			end
		end
	end
	return candidate
end

local function startupScreen(object)
	local parent = object
	while parent do
		local name = compactUIKey(parent.Name)
		if name:find("loading", 1, true) or name:find("intro", 1, true)
			or name == "titlescreen" or name == "startscreen" or name == "splashscreen" then return parent end
		parent = parent.Parent
	end
end

local function uiDrawn(object)
	local objects = object:GetDescendants()
	table.insert(objects, object)
	for _, child in ipairs(objects) do
		if child:IsA("GuiObject") and uiVisible(child, true) then
			if child.BackgroundTransparency < 0.99 then return true end
			if (child:IsA("TextLabel") or child:IsA("TextButton")) and child.TextTransparency < 0.99
				and child.MaxVisibleGraphemes ~= 0 and uiText(child) ~= "" then return true end
			if (child:IsA("ImageLabel") or child:IsA("ImageButton")) and type(child.Image) == "string"
				and child.Image ~= "" and child.ImageTransparency < 0.99 then return true end
		end
	end
	return false
end

local function buttonReady(button)
	if not button or not uiVisible(button) or button.Interactable == false then return false end
	if button.GuiState == Enum.GuiState.NonInteractable then return false end
	return true
end

local function countdownVisible(button)
	local parent = button.Parent
	local objects = parent and parent:GetDescendants() or button:GetDescendants()
	table.insert(objects, button)
	for _, object in ipairs(objects) do
		if (object:IsA("TextLabel") or object:IsA("TextButton")) and object.TextTransparency < 1
			and object.MaxVisibleGraphemes ~= 0 and uiVisible(object) and uiText(object):find("%d") then
			local center = object.AbsolutePosition + object.AbsoluteSize / 2
			local position, size = button.AbsolutePosition, button.AbsoluteSize
			local overButton = center.X >= position.X and center.Y >= position.Y
				and center.X < position.X + size.X and center.Y < position.Y + size.Y
			if object == button or object:IsDescendantOf(button) or overButton then return true end
		end
	end
	return false
end

local function nativeEventPrompt(object)
	local prompt
	local parent = object
	while parent do
		if parent.Name == "Prompt" and parent:IsA("GuiObject") then prompt = parent end
		if parent.Name == "EventsInExperienceRoot" and parent:FindFirstAncestorWhichIsA("CoreGui") then return prompt end
		parent = parent.Parent
	end
end

local function visibleNativeEvent(core)
	if not core then return end
	local robloxGui = core:FindFirstChild("RobloxGui")
	local events = robloxGui and robloxGui:FindFirstChild("EventsInExperienceRoot")
	local prompt = events and events:FindFirstChild("Prompt", true)
	if prompt and uiVisible(prompt) and uiDrawn(prompt) then return prompt end
end

local function closeButton(marker)
	local prompt = nativeEventPrompt(marker)
	if prompt then
		local header = prompt:FindFirstChild("TitleContainer", true)
		local named, headerButtons = {}, {}
		for _, object in ipairs(prompt:GetDescendants()) do
			if object:IsA("GuiButton") and uiVisible(object) then
				local name = compactUIKey(object.Name)
				local text = uiText(object):match("^%s*(.-)%s*$")
				if name:find("close", 1, true) or name == "dismiss" or name == "xbutton"
					or text == "x" or text == "×" or text == "✕" or text == "close" or text == "tutup" then
					table.insert(named, object)
				end
				local size = object.AbsoluteSize
				if header and object:IsDescendantOf(header) and size.X <= prompt.AbsoluteSize.X * 0.3
					and size.Y <= math.max(marker.AbsoluteSize.Y * 2, 40) then
					table.insert(headerButtons, object)
				end
			end
		end
		if #named == 1 then return named[1] end
		if #named == 0 and #headerButtons == 1 then return headerButtons[1] end
		return
	end
	local container = marker.Parent
	while container and container:IsA("GuiObject") do
		local camera = workspace.CurrentCamera
		if camera and container.AbsoluteSize.X >= camera.ViewportSize.X * 0.95
			and container.AbsoluteSize.Y >= camera.ViewportSize.Y * 0.95 then return end
		local matches = {}
		for _, object in ipairs(container:GetDescendants()) do
			if object:IsA("GuiButton") and uiVisible(object) then
				local name = object.Name:lower():gsub("[%s_%-]", "")
				local text = uiText(object):match("^%s*(.-)%s*$")
				if name == "close" or name == "closebutton" or name == "dismiss"
					or text == "x" or text == "×" or text == "✕" or text == "close" or text == "tutup" then
					table.insert(matches, object)
				end
			end
		end
		if #matches == 1 then return matches[1] end
		if #matches > 1 then return end
		if container.BackgroundTransparency < 1 then return end
		container = container.Parent
	end
end

local eventSnapshot, eventHistory = {}, {}
local observedEvent, snapshotEvent, snapshotTarget, snapshotReady
local eventStarted = 0

local function traceEvent(prompt, message)
	if not prompt or prompt ~= snapshotEvent then return end
	table.insert(eventHistory, string.format("[%.2fs] %s", os.clock() - eventStarted, tostring(message)))
	if #eventHistory > 40 then table.remove(eventHistory, 1) end
end

local function eventDetails(marker, close)
	local prompt = nativeEventPrompt(marker)
	local lines = {
		"=== Pop-up acara Roblox ===",
		"root=" .. prompt:GetFullName(),
		"target X=" .. (close and close:GetFullName() or "belum teridentifikasi"),
	}
	for _, object in ipairs(prompt:GetDescendants()) do
		if object:IsA("GuiButton") then
			table.insert(lines, string.format("event button=%s [%s] | text=%q | visible=%s | ready=%s | pos=%s | size=%s",
				object:GetFullName(), object.ClassName, uiText(object), tostring(uiVisible(object)),
				tostring(buttonReady(object)), tostring(object.AbsolutePosition), tostring(object.AbsoluteSize)))
		end
	end
	return lines
end

local function observeEvent(marker, close)
	local prompt = marker and nativeEventPrompt(marker)
	if not prompt then
		if observedEvent then
			local ok, visible = pcall(uiVisible, observedEvent)
			if not ok or not visible then
				traceEvent(observedEvent, "panel acara sudah hilang dari layar")
				observedEvent = nil
			end
		end
		return
	end
	local ready = buttonReady(close)
	local opened = prompt ~= observedEvent
	if opened then
		observedEvent, snapshotEvent = prompt, prompt
		eventHistory, eventStarted = {}, os.clock()
		traceEvent(prompt, "panel acara terdeteksi saat masih terbuka")
	end
	if opened or close ~= snapshotTarget or ready ~= snapshotReady then
		snapshotTarget, snapshotReady = close, ready
		local ok, details = pcall(eventDetails, marker, close)
		eventSnapshot = ok and details or { "snapshot acara gagal: " .. tostring(details) }
		traceEvent(prompt, "target X=" .. (close and close:GetFullName() or "nil") .. " | ready=" .. tostring(ready))
	end
end

local function joinMessage(message)
	setStatus(message)
	if lastJoinMessage ~= message then
		lastJoinMessage = message
		traceEvent(observedEvent, message)
		print("[TurkeyAuto " .. SCRIPT_VERSION .. "/Masuk] " .. message)
	end
end

local pointerAttempts = setmetatable({}, { __mode = "k" })
local callbackButtons = setmetatable({}, { __mode = "k" })

local function sendJoinCallback(button, eventName, checkCountdown)
	local prompt = nativeEventPrompt(button)
	if callbackButtons[button] then return true end
	local ok, handlers = pcall(function() return getconnections(button[eventName]) end)
	if not ok or type(handlers) ~= "table" then
		traceEvent(prompt, eventName .. " getconnections gagal: " .. tostring(handlers))
		return false
	end
	traceEvent(prompt, eventName .. " koneksi terbaca=" .. #handlers)
	local pending = 0
	local workers = {}
	for _, connection in ipairs(handlers) do
		local readable, ready = pcall(function()
			return connection.Enabled ~= false and connection.Connected ~= false and type(connection.Fire) == "function"
		end)
		if readable and ready then
			local worker
			worker = coroutine.create(function()
				local called = false
				local fired, err = pcall(function()
					if running and autoJoinEnabled and not hopBusy and button.Parent and buttonReady(button)
						and not (checkCountdown and countdownVisible(button)) then
						called = true
						if eventName == "Activated" then connection:Fire(mouseInput, 1)
						else connection:Fire() end
					end
				end)
				traceEvent(prompt, eventName .. " callback dipanggil=" .. tostring(called) .. " | API berhasil=" .. tostring(fired)
					.. (fired and "" or (" | " .. tostring(err))))
				if not fired then print("[TurkeyAuto " .. SCRIPT_VERSION .. "/Input] callback gagal: " .. tostring(err)) end
				navigationWorkers[worker] = nil
				pending -= 1
				if pending == 0 then callbackButtons[button] = nil end
			end)
			pending += 1
			navigationWorkers[worker] = true
			table.insert(workers, worker)
		end
	end
	if pending == 0 then
		traceEvent(prompt, eventName .. " tidak memiliki callback yang dapat dijalankan")
		return false
	end
	callbackButtons[button] = true
	for _, worker in ipairs(workers) do task.spawn(worker) end
	return true
end

local function sendJoinPointer(object, point, checkCountdown, introClick)
	if not running or hopBusy or not autoJoinEnabled then return false end
	local inputEvent = object and nativeEventPrompt(object)
	local wasEnabled = gui.Enabled
	local panelPosition = uiScreenPosition(frame) - frame.AbsoluteSize / 2
	local hidePanel = wasEnabled and frame.Visible and point.X >= panelPosition.X and point.Y >= panelPosition.Y
		and point.X < panelPosition.X + frame.AbsoluteSize.X and point.Y < panelPosition.Y + frame.AbsoluteSize.Y
	if hidePanel then gui.Enabled = false end
	local ok, sent, reason = xpcall(function()
		task.wait(0.04)
		if not running or hopBusy or not autoJoinEnabled then return false end
		if GuiService.MenuIsOpen then return false, "tutup menu Roblox dulu" end
		local button = object and uiButton(object)
		local introLayer = introClick and object and object:FindFirstAncestorWhichIsA("ScreenGui")
		local eventPrompt = inputEvent
		local function introReceiver(hit)
			if not introClick then return false end
			if introLayer and hit:IsDescendantOf(introLayer) then return true end
			local camera = workspace.CurrentCamera
			return camera and hit.BackgroundTransparency >= 0.99
				and hit.AbsoluteSize.X * hit.AbsoluteSize.Y >= camera.ViewportSize.X * camera.ViewportSize.Y * 0.8
				and not uiDrawn(hit)
		end
		if object then
			if not object.Parent or not uiVisible(object) then return false end
			if not introClick and button and not buttonReady(button) then return false end
			if button and checkCountdown and countdownVisible(button) then return false end
			point = uiScreenPosition(object)
			local root = object:FindFirstAncestorWhichIsA("PlayerGui") or object:FindFirstAncestorWhichIsA("CoreGui")
			if root then
				local center = object.AbsolutePosition + object.AbsoluteSize / 2
				local readable, hits = pcall(function() return root:GetGuiObjectsAtPosition(center.X, center.Y) end)
				if readable then
					local targetHit = introClick == true or eventPrompt ~= nil
					for _, hit in ipairs(hits) do
						if eventPrompt and (hit == eventPrompt or hit:IsDescendantOf(eventPrompt)) then
							targetHit = true
							continue
						end
						if introClick and hit:IsA("GuiButton") then
							if not introReceiver(hit) then
								return false, "intro tertutup tombol " .. hit:GetFullName()
							end
							if not buttonReady(hit) then return false, "hitbox Continue belum bisa diklik" end
							button = hit
							targetHit = true
							break
						end
						if hit == object or hit:IsDescendantOf(object) or hit == button then
							targetHit = true
							if not introClick then break end
						end
						local caption = hit:IsA("TextLabel") or hit:IsA("ImageLabel")
						if not object:IsDescendantOf(hit) and (hit:IsA("GuiButton") or (hit.Active and not caption)) then
							if not introReceiver(hit) then
								return false, "target tertutup " .. hit:GetFullName()
							end
						end
					end
					if not targetHit then return false, "hit-test belum menunjuk target" end
				end
			end
		end
		local coreOK, coreHits = pcall(function()
			return game:GetService("CoreGui"):GetGuiObjectsAtPosition(point.X, point.Y)
		end)
		if coreOK then
			for _, hit in ipairs(coreHits) do
				local related = object and (hit == object or hit:IsDescendantOf(object) or object:IsDescendantOf(hit))
				if eventPrompt and (hit == eventPrompt or hit:IsDescendantOf(eventPrompt)) then related = true end
				if (hit:IsA("GuiButton") or hit.Active) and introReceiver(hit) then related = true end
				if not related and uiVisible(hit) and (hit:IsA("GuiButton") or hit.Active) then
					return false, "titik klik tertutup pop-up Roblox"
				end
			end
		end
		local camera = workspace.CurrentCamera
		if not camera or point.X < 0 or point.Y < 0 or point.X >= camera.ViewportSize.X
			or point.Y >= camera.ViewportSize.Y then return false end
		local methods = {}
		local coreTarget = object and object:FindFirstAncestorWhichIsA("CoreGui")
		if virtualInput and not coreTarget then table.insert(methods, "VirtualInput") end
		if virtualInputManager then table.insert(methods, "VirtualInputManager") end
		if button and type(getconnections) == "function" then
			table.insert(methods, "MouseButton1Click")
			table.insert(methods, "Activated")
		end
		if #methods == 0 then return false, "metode klik belum tersedia" end
		local key = object or gui
		local attempt = (pointerAttempts[key] or 0) + 1
		pointerAttempts[key] = attempt
		local method = methods[(attempt - 1) % #methods + 1]
		traceEvent(eventPrompt, "percobaan " .. attempt .. " | metode=" .. method .. " | titik=" .. tostring(point))
		if method == "MouseButton1Click" or method == "Activated" then
			print("[TurkeyAuto " .. SCRIPT_VERSION .. "/Input] " .. method .. " | " .. button:GetFullName() .. " | percobaan " .. attempt)
			return sendJoinCallback(button, method, checkCountdown)
		end
		local function release()
			if method == "VirtualInput" then
				virtualInput:SendMouseButton(point, Enum.UserInputType.MouseButton1, false, 0)
			else
				virtualInputManager:SendMouseButtonEvent(point.X, point.Y, 0, false, game, 0)
			end
		end
		local checked, held = pcall(function() return UIS:IsMouseButtonPressed(Enum.UserInputType.MouseButton1) end)
		if checked and held then
			local targetPoint = point
			point = Vector2.new(0, 0)
			local released = pcall(release)
			point = targetPoint
			if not released then return false, "tombol mouse lama belum terlepas" end
			task.wait(0.04)
			if not running or hopBusy or not autoJoinEnabled then return false end
			if object then
				if not object.Parent or not uiVisible(object) then return false end
				if not introClick then button = uiButton(object) end
				if button and (not buttonReady(button) or (checkCountdown and countdownVisible(button))) then return false end
				point = uiScreenPosition(object)
			end
		end
		local downAttempted, released = false, false
		local delivered, inputError = pcall(function()
			if method == "VirtualInput" then virtualInput:SendMousePosition(point)
			else virtualInputManager:SendMouseMoveEvent(point.X, point.Y, game) end
			downAttempted = true
			if method == "VirtualInput" then
				virtualInput:SendMouseButton(point, Enum.UserInputType.MouseButton1, true, 0)
			else
				virtualInputManager:SendMouseButtonEvent(point.X, point.Y, 0, true, game, 0)
			end
			task.wait(0.08)
			release()
			released = true
		end)
		if downAttempted and not released then pcall(release) end
		if not running or hopBusy or not autoJoinEnabled then return false end
		local description = object and object:GetFullName() or "bootstrap layar awal"
		print("[TurkeyAuto " .. SCRIPT_VERSION .. "/Input] " .. method .. " | " .. description .. " | percobaan " .. attempt)
		if not delivered then
			traceEvent(eventPrompt, method .. " gagal: " .. tostring(inputError) .. " | down dicoba=" .. tostring(downAttempted))
			print("[TurkeyAuto " .. SCRIPT_VERSION .. "/Input] " .. tostring(inputError))
			return downAttempted, "input belum terkonfirmasi, menunggu perubahan UI"
		end
		return true
	end, function(err) return debug.traceback(tostring(err), 2) end)
	if running and hidePanel then pcall(function() gui.Enabled = wasEnabled end) end
	local detail = reason
	if not ok then detail = sent end
	traceEvent(inputEvent, "hasil percobaan | API berhasil=" .. tostring(ok) .. " | dikirim=" .. tostring(sent)
		.. " | detail=" .. tostring(detail))
	if not ok then return false, "input gagal: " .. tostring(sent) end
	return sent, reason
end

local function clickJoinTarget(object, checkCountdown, introClick)
	if not running or hopBusy or not autoJoinEnabled or not uiVisible(object) then return false end
	local button = uiButton(object)
	if not introClick and button and not buttonReady(button) then return false end
	if lastClickTarget == object and os.clock() - lastClickAt < 1 then return false, lastClickReason end
	lastClickTarget, lastClickAt = object, os.clock()
	local sent, reason = sendJoinPointer(object, uiScreenPosition(object), checkCountdown, introClick)
	lastClickReason = reason
	return sent, reason
end

local function joinUIRoots()
	local roots = {}
	local player = refreshPlayer()
	local playerGui = player and player:FindFirstChildOfClass("PlayerGui")
	if playerGui then table.insert(roots, playerGui) end
	local coreOK, core = pcall(function() return game:GetService("CoreGui") end)
	if coreOK and core then table.insert(roots, core) end
	if type(gethui) == "function" then
		local ok, hiddenRoot = pcall(gethui)
		if ok and hiddenRoot and hiddenRoot ~= core and hiddenRoot ~= playerGui then table.insert(roots, hiddenRoot) end
	end
	return roots, playerGui, coreOK and core or nil
end

local function joinedTextKey(container)
	local labels = {}
	for _, child in ipairs(container:GetChildren()) do
		if (child:IsA("TextLabel") or child:IsA("TextButton")) and child.TextTransparency < 1
			and child.MaxVisibleGraphemes ~= 0 and uiVisible(child, true) and compactUIKey(uiText(child)) ~= "" then
			table.insert(labels, child)
		end
	end
	if #labels < 2 then return "" end
	table.sort(labels, function(a, b)
		if a.LayoutOrder ~= b.LayoutOrder then return a.LayoutOrder < b.LayoutOrder end
		if a.AbsolutePosition.Y ~= b.AbsolutePosition.Y then return a.AbsolutePosition.Y < b.AbsolutePosition.Y end
		return a.AbsolutePosition.X < b.AbsolutePosition.X
	end)
	local text = {}
	for _, label in ipairs(labels) do table.insert(text, uiText(label)) end
	return compactUIKey(table.concat(text, " "))
end

local joinIndexes = setmetatable({}, { __mode = "k" })

local function joinUINodes(root, playerGui)
	local entry = joinIndexes[root]
	if not entry then
		entry = { expires = 0 }
		joinIndexes[root] = entry
		pcall(function()
			connect(root.DescendantAdded, function() entry.expires = 0 end)
			connect(root.DescendantRemoving, function() entry.expires = 0 end)
		end)
	end
	if entry.nodes and os.clock() < entry.expires then return entry.nodes end
	local nodes = {}
	for _, object in ipairs(root:GetDescendants()) do
		local text = object:IsA("TextLabel") or object:IsA("TextButton")
		local button = object:IsA("GuiButton")
		local rules = object:IsA("ScreenGui") and object.Name == "RulesScreenGui"
		local name = compactUIKey(object.Name)
		local named = name == "clicktocontinue" or name == "taptocontinue" or name == "clickanywhere"
			or name == "continueprompt" or name == "continue" or name == "continuelabel" or name == "continuebutton"
			or name == "play" or name == "playbutton" or name == "startbutton"
			or name == "overlay" or name == "mainframe" or name == "background"
		if text or rules or named or (button and root == playerGui) then
			table.insert(nodes, {
				object = object, text = text, button = button, rules = rules,
				name = name, intro = startupScreen(object),
			})
		end
	end
	entry.nodes = nodes
	entry.expires = os.clock() + 1
	return nodes
end

local function scanJoinUI()
	local roots, playerGui, core = joinUIRoots()
	local found = { playerReadable = playerGui ~= nil, coreReadable = core ~= nil }
	local agreements, seen, groups, rulesScreens = {}, {}, {}, {}
	local function recognize(object, key)
		if key == "clicktocontinue" or key == "taptocontinue" or key == "clickanywhere"
			or key == "klikuntukmelanjutkan" or key == "klikdimanasaja" or key == "sentuhuntukmelanjutkan" then
			found.continueTarget = object
		end
		if key:match("^iagree%d*s?$") or key:match("^sayasetuju%d*s?$") then table.insert(agreements, object) end
		if key == "schoolrules" or key == "peraturansekolah" or key == "readthesebeforeyouplay" then found.rules = object end
		if key == "bergabungkeacara" or key == "joinevent" or key == "jointheevent" then found.event = object end
		if key:match("^loading") or key:match("^memuat") then found.loading = object end
	end
	for _, root in ipairs(roots) do
		local ok, nodes = pcall(joinUINodes, root, playerGui)
		if not ok then
			if root == core then found.coreReadable = false end
			if root == playerGui then found.playerReadable = false end
			continue
		end
		for _, node in ipairs(nodes) do
			local object = node.object
			if seen[object] then continue end
			seen[object] = true
			local readable = pcall(function()
				if node.rules and object.Enabled then
					table.insert(rulesScreens, object)
				end
				if not uiVisible(object, true) then return end
				local name, intro = node.name, node.intro
				local namedContinue = name == "clicktocontinue" or name == "taptocontinue"
					or name == "clickanywhere" or name == "continueprompt"
				local introControl = intro and (name == "continue" or name == "continuelabel" or name == "continuebutton"
					or (node.button and (name == "play" or name == "playbutton" or name == "startbutton")))
				if (namedContinue or introControl) and uiDrawn(object) then found.continueTarget = object end
				local camera = workspace.CurrentCamera
				if intro and camera and object.AbsoluteSize.X * object.AbsoluteSize.Y >= camera.ViewportSize.X * camera.ViewportSize.Y * 0.4
					and (name == "overlay" or name == "mainframe" or name == "background") and uiDrawn(object) then
					found.intro = object
				end
				if node.button and not intro and root == playerGui and camera
					and object.AbsoluteSize.X * object.AbsoluteSize.Y < camera.ViewportSize.X * camera.ViewportSize.Y * 0.4 then
					found.gameplay = true
				end
				if not node.text or object.TextTransparency >= 1
					or object.MaxVisibleGraphemes == 0 then return end
				local text = uiText(object)
				for _, property in ipairs({ "Text", "ContentText", "LocalizedText" }) do
					local ok, value = pcall(function() return object[property] end)
					if ok and type(value) == "string" and value ~= "" then recognize(object, compactUIKey(value)) end
				end
				if text == "校則" or text == "学校のルール" then found.rules = object end
				local parent = object.Parent
				if #compactUIKey(text) <= 8 and parent and parent:IsA("GuiObject") and not groups[parent] then
					groups[parent] = true
					recognize(parent, joinedTextKey(parent))
				end
			end)
			if not readable then
				if root == core then found.coreReadable = false end
				if root == playerGui then found.playerReadable = false end
			end
		end
	end
	for _, screen in ipairs(rulesScreens) do
		local button = screen:FindFirstChild("AgreeButton", true)
		if button and button:IsA("GuiButton") and uiVisible(button) and uiDrawn(button) then
			found.rules = found.rules or button
			found.agreeTarget = button
		end
	end
	local eventOK, nativePrompt = pcall(visibleNativeEvent, core)
	if eventOK and nativePrompt and (not found.event or nativeEventPrompt(found.event) ~= nativePrompt) then
		found.event = nativePrompt
	end
	if found.rules and not found.agreeTarget then
		for _, agreement in ipairs(agreements) do
			local parent = found.rules
			while parent and parent:IsA("GuiObject") do
				if agreement:IsDescendantOf(parent) then found.agreeTarget = agreement break end
				parent = parent.Parent
			end
		end
	end
	return found
end

local function dumpJoinUI()
	local roots, playerGui, core = joinUIRoots()
	local camera = workspace.CurrentCamera
	local character = lp and lp.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	local lines = {
		"=== TurkeyAuto " .. SCRIPT_VERSION .. "/Masuk UI dump ===",
		string.format("place=%s | job=%s | loaded=%s | camera=%s | viewport=%s",
			tostring(game.PlaceId), tostring(game.JobId), tostring(game:IsLoaded()),
			camera and tostring(camera.CameraType) or "nil", camera and tostring(camera.ViewportSize) or "nil"),
		string.format("character=%s | humanoid=%s | Sit=%s | SeatPart=%s | nativeInput=%s | legacyInput=%s",
			character and character:GetFullName() or "nil", humanoid and humanoid:GetFullName() or "nil",
			humanoid and tostring(humanoid.Sit) or "nil", humanoid and tostring(humanoid.SeatPart) or "nil",
			tostring(virtualInput ~= nil), tostring(virtualInputManager ~= nil)),
		string.format("state: continued=%s | agreed=%s | rulesSeen=%s | done=%s | eventOpen=%s",
			tostring(joinContinued), tostring(joinAgreed), tostring(rulesSeen), tostring(joinDone), tostring(eventOpen)),
	}
	local engineOK, engineVersion = pcall(function() return version() end)
	if engineOK then table.insert(lines, "engine=" .. tostring(engineVersion)) end
	local event = scanJoinUI().event
	observeEvent(event, event and closeButton(event))
	if #eventSnapshot > 0 then
		table.insert(lines, "=== Rekaman saat pop-up terakhir masih terbuka ===")
		for _, line in ipairs(eventSnapshot) do table.insert(lines, line) end
		table.insert(lines, "=== Riwayat percobaan X ===")
		for _, line in ipairs(eventHistory) do table.insert(lines, line) end
	else
		table.insert(lines, "Rekaman pop-up acara belum tersedia pada run ini.")
	end
	local relevantKeys = {
		clicktocontinue = true, taptocontinue = true, klikuntukmelanjutkan = true,
		schoolrules = true, readthesebeforeyouplay = true, bergabungkeacara = true, joinevent = true, jointheevent = true,
	}
	local candidates = {}
	local unreadable = 0
	for _, root in ipairs(roots) do
		local ok, objects = pcall(function() return root:GetDescendants() end)
		if not ok then
			table.insert(lines, "root tidak terbaca: " .. tostring(root) .. " | " .. tostring(objects))
			continue
		end
		for _, object in ipairs(objects) do
			local readable = pcall(function()
				local isText = object:IsA("TextLabel") or object:IsA("TextButton") or object:IsA("TextBox")
				local raw = isText and object.Text or ""
				local contentOK, content = pcall(function() return object.ContentText end)
				if not contentOK or type(content) ~= "string" then content = raw end
				local key = compactUIKey(raw)
				local contentKey = compactUIKey(content)
				local name = compactUIKey(object.Name)
				local relevant = relevantKeys[key] == true or relevantKeys[contentKey] == true
					or key:match("^iagree%d*s?$") ~= nil or contentKey:match("^iagree%d*s?$") ~= nil
					or contentKey:find("schoolrules", 1, true) ~= nil
					or contentKey == "bergabungkeacara" or contentKey == "joinevent"
					or name:find("continue", 1, true) ~= nil or name:find("agree", 1, true) ~= nil
					or name:find("rules", 1, true) ~= nil or name:find("rsvp", 1, true) ~= nil
					or name:find("loading", 1, true) ~= nil
				local visible, reason = uiVisible(object, true)
				if not relevant and not (isText and visible and raw ~= "") then return end
				table.insert(candidates, {
					object = object, root = root, path = object:GetFullName(), relevant = relevant,
					visible = visible, reason = reason, raw = raw, content = content, key = key, contentKey = contentKey,
				})
			end)
			if not readable then unreadable += 1 end
		end
	end
	table.sort(candidates, function(a, b)
		if a.relevant ~= b.relevant then return a.relevant end
		if (a.root == playerGui) ~= (b.root == playerGui) then return a.root == playerGui end
		return a.path < b.path
	end)
	table.insert(lines, string.format("kandidat=%d | ditampilkan=%d | objek tidak terbaca=%d",
		#candidates, math.min(#candidates, 80), unreadable))
	for index = 1, math.min(#candidates, 80) do
		local entry = candidates[index]
		local ok, err = pcall(function()
			local object = entry.object
			table.insert(lines, string.format("%d. %s [%s] | visible=%s | alasan=%s",
				index, entry.path, object.ClassName, tostring(entry.visible), tostring(entry.reason or "-")))
			table.insert(lines, string.format("   Text=%q | ContentText=%q | key=%q | contentKey=%q",
				entry.raw, entry.content, entry.key, entry.contentKey))
			if object:IsA("GuiObject") then
				table.insert(lines, string.format("   Visible=%s | Active=%s | Interactable=%s | GuiState=%s | pos=%s | size=%s",
					tostring(object.Visible), tostring(object.Active), tostring(object.Interactable), tostring(object.GuiState),
					tostring(object.AbsolutePosition), tostring(object.AbsoluteSize)))
				local button = uiButton(object)
				table.insert(lines, "   tombol=" .. (button and button:GetFullName() or "nil")
					.. " | siap=" .. tostring(buttonReady(button)))
			end
			local ancestors = {}
			local ancestor = object.Parent
			for _ = 1, 5 do
				if not ancestor then break end
				local description = ancestor.Name .. " [" .. ancestor.ClassName .. "]"
				if ancestor:IsA("GuiObject") then description ..= " Visible=" .. tostring(ancestor.Visible) end
				if ancestor:IsA("LayerCollector") then description ..= " Enabled=" .. tostring(ancestor.Enabled) end
				table.insert(ancestors, description)
				ancestor = ancestor.Parent
			end
			table.insert(lines, "   ancestor=" .. table.concat(ancestors, " <- "))
			local layer = object:FindFirstAncestorWhichIsA("LayerCollector")
			if layer then
				local description = layer:GetFullName() .. " [" .. layer.ClassName .. "] Enabled=" .. tostring(layer.Enabled)
				if layer:IsA("ScreenGui") then description ..= " IgnoreGuiInset=" .. tostring(layer.IgnoreGuiInset) end
				table.insert(lines, "   layer=" .. description)
			end
			if not object:IsA("GuiObject") then return end
			local center = object.AbsolutePosition + object.AbsoluteSize / 2
			local position = uiScreenPosition(object)
			local hitRoots = { entry.root }
			if entry.root == playerGui and core then table.insert(hitRoots, core) end
			for _, root in ipairs(hitRoots) do
				local point = root == core and position or center
				local hitOK, hits = pcall(function() return root:GetGuiObjectsAtPosition(point.X, point.Y) end)
				local descriptions = {}
				if hitOK then
					for hitIndex = 1, math.min(#hits, 5) do
						local hit = hits[hitIndex]
						table.insert(descriptions, hit:GetFullName() .. " [" .. hit.ClassName .. "] Active=" .. tostring(hit.Active))
					end
					if #hits == 0 then table.insert(descriptions, "kosong") end
				else
					table.insert(descriptions, "tidak terbaca: " .. tostring(hits))
				end
				table.insert(lines, "   hits " .. root.ClassName .. " @ " .. tostring(point) .. " = " .. table.concat(descriptions, " | "))
			end
		end)
		if not ok then table.insert(lines, "   detail tidak terbaca: " .. tostring(err)) end
	end
	toClipboard(table.concat(lines, "\n"))
	joinMessage("dump UI dicatat di console")
end

joinDumpBtn.MouseButton1Click:Connect(function()
	local ok, err = xpcall(dumpJoinUI, function(message) return debug.traceback(tostring(message), 2) end)
	if not ok then
		local report = "[TurkeyAuto " .. SCRIPT_VERSION .. "/ERROR] dump UI gagal\n" .. tostring(err)
		print(report)
		if type(setclipboard) == "function" then pcall(setclipboard, report) end
		joinMessage("dump UI gagal, detail ada di console/clipboard")
	end
end)

local function processJoin()
	if not autoJoinEnabled or hopBusy then return end
	attachGui()
	local ui = scanJoinUI()
	eventOpen = ui.event ~= nil

	-- Tombol agree hilang setelah pernah terlihat = sudah diklik. Butuh 2 scan berturut-turut
	-- supaya hilang sesaat (UI redraw) tidak dianggap selesai.
	if rulesSeen and not joinAgreed then
		if not ui.agreeTarget and not ui.rules then
			agreeMissing += 1
			if agreeMissing >= 2 then joinAgreed = true end
		else
			agreeMissing = 0
		end
	end

	if ui.event then
		-- sebelum agree: pop-up menghalangi klik, jadi tutup dulu. Sesudah agree: background saja.
		if not joinAgreed and not joinDone then joinBusy = true end
		joinIntroHandled = true
		joinEventSeen, joinAwaitingEvent, joinConfirmation = true, false, nil
		joinBtn.Text = "Auto Masuk: ON"
		local close = closeButton(ui.event)
		observeEvent(ui.event, close)
		if close and buttonReady(close) then
			local clicked, reason = clickJoinTarget(close)
			joinMessage(reason or (clicked and "menutup pop-up acara..." or "tutup pop-up acara lewat tombol X jika belum tertutup"))
		else
			joinMessage("tombol X acara belum siap, cek Dump UI Masuk atau tutup manual")
		end
		if not (joinAgreed or joinDone) then return end
	else
		observeEvent(nil)
	end

	if ui.continueTarget then
		joinBusy = true
		joinAwaitingRules = true
		joinConfirmation = nil
		joinBtn.Text = "Auto Masuk: ON"
		local _, reason = clickJoinTarget(ui.continueTarget, false, true)
		joinMessage(reason or "Click to Continue terdeteksi, menunggu UI siap...")
		return
	end

	if ui.agreeTarget or ui.rules then
		joinBusy, joinAwaitingRules = true, false
		rulesSeen, joinAgreed, agreeMissing = true, false, 0
		-- Continue sudah lewat: mulai jam precheck ayam (loop farming yang mengecek)
		if not joinContinued then joinContinued, joinContinuedAt = true, os.clock() end
		joinIntroHandled = true
		joinAwaitingEvent = false -- nggak nunggu pop-up acara; ditutup belakangan kalau muncul
		joinConfirmation = nil
		joinBtn.Text = "Auto Masuk: ON"
		local button = ui.agreeTarget and uiButton(ui.agreeTarget)
		if buttonReady(button) and not countdownVisible(button) then
			local _, reason = clickJoinTarget(button, true)
			joinMessage(reason or "I agree aktif, menunggu panel ditutup...")
		else
			joinMessage("menunggu tombol I agree bisa diklik...")
		end
		return
	end

	-- Layar Continue sudah hilang tapi rules belum muncul: precheck ayam sudah boleh jalan
	if joinAwaitingRules and not joinContinued then joinContinued, joinContinuedAt = true, os.clock() end

	-- Agree selesai: langsung lompat & farming, pop-up acara diurus di background
	if joinAgreed and not joinDone then
		local character = lp and lp.Character
		local humanoid = character and character:FindFirstChildOfClass("Humanoid")
		if humanoid and humanoid.Health > 0 and getHRP() then
			if humanoid.Sit or humanoid.SeatPart then
				humanoid.Sit = false
				humanoid.Jump = true
				pcall(function() humanoid:ChangeState(Enum.HumanoidStateType.Jumping) end)
			end
			joinBusy = false
			joinDone, joinDoneAt = true, os.clock()
			joinMessage("agree selesai, langsung farming")
			return
		end
	end

	if ui.loading then
		joinBusy = true
		joinMessage("menunggu loading UI selesai...")
		return
	end
	if ui.intro then
		joinBusy = true
		if game:IsLoaded() then
			local _, reason = clickJoinTarget(ui.intro, false, true)
			joinMessage(reason or "layar intro terdeteksi, menunggu perubahan UI...")
		else
			joinMessage("menunggu game selesai dimuat...")
		end
		return
	end
	local camera = workspace.CurrentCamera
	local bootstrapNeeded = not lp or not ui.playerReadable
		or (not joinIntroHandled and not ui.gameplay and camera and camera.CameraType == Enum.CameraType.Scriptable)
	if bootstrapNeeded and not joinAwaitingRules and not joinAwaitingEvent then
		joinBusy = true
		if os.clock() - bootstrapStarted >= 60 then
			joinMessage("bootstrap belum siap, klik Dump UI Masuk atau ulangi Auto Masuk")
			return
		end
		if camera and camera.ViewportSize.X > 0 and camera.ViewportSize.Y > 0 and os.clock() - lastBootstrapClick >= 1 then
			lastBootstrapClick = os.clock()
			bootstrapClicks += 1
			local _, reason = sendJoinPointer(nil, Vector2.new(camera.ViewportSize.X * 0.5, camera.ViewportSize.Y * 0.65))
			joinMessage(reason or ("bootstrap layar awal, percobaan " .. bootstrapClicks))
		end
		return
	end
	if not game:IsLoaded() then
		joinBusy = true
		joinMessage("menunggu game selesai dimuat...")
		return
	end
	if not joinBusy then return end
	if not ui.playerReadable then
		joinMessage("menunggu UI pemain siap...")
		return
	end
	if joinAwaitingRules then
		joinConfirmation = "rules"
		joinBtn.Text = "Lanjut jika Rules tak muncul"
		joinMessage("menunggu School Rules muncul...")
		return
	end
	if not ui.coreReadable and not coreGuiConfirmed then
		joinConfirmation = "core"
		joinBtn.Text = "Lanjut (pop-up ditutup)"
		joinMessage("tutup pop-up Roblox manual, lalu klik Lanjut")
		return
	end
	if joinAwaitingEvent and not joinEventSeen then
		joinConfirmation = "event"
		joinBtn.Text = "Lanjut jika acara tak muncul"
		joinMessage("menunggu pop-up acara muncul...")
		return
	end
	local character = lp and lp.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	if not humanoid or humanoid.Health <= 0 or not getHRP() then
		joinMessage("menunggu karakter siap...")
		return
	end
	camera = workspace.CurrentCamera
	if not camera then
		joinMessage("menunggu kamera tersedia...")
		return
	end
	if camera.CameraType == Enum.CameraType.Scriptable and not joinIntroHandled and not ui.gameplay then
		joinConfirmation = "clear"
		joinBtn.Text = "Lanjut (UI sudah bersih)"
		joinMessage("UI masuk belum dikenali, klik Dump UI Masuk")
		return
	end
	if humanoid.Sit or humanoid.SeatPart then
		joinMessage("melompat untuk keluar dari kursi...")
		humanoid.Sit = false
		humanoid.Jump = true
		humanoid:ChangeState(Enum.HumanoidStateType.Jumping)
		return
	end
	joinBusy = false
	joinDone, joinDoneAt = true, os.clock()
	joinMessage("masuk selesai, karakter siap")
end

joinBtn.MouseButton1Click:Connect(function()
	if joinConfirmation then
		joinIntroHandled = true
		if joinConfirmation == "core" then
			coreGuiConfirmed = true
			joinAwaitingEvent = false
		elseif joinConfirmation == "rules" then
			joinAwaitingRules = false
		elseif joinConfirmation == "event" then
			joinAwaitingEvent = false
		end
		joinConfirmation = nil
		joinBtn.Text = "Auto Masuk: ON"
		return
	end
	autoJoinEnabled = not autoJoinEnabled
	joinBusy = autoJoinEnabled
	bootstrapStarted, lastBootstrapClick, bootstrapClicks = os.clock(), -math.huge, 0
	joinAwaitingRules, joinAwaitingEvent, joinEventSeen = false, false, false
	joinContinued, joinAgreed, rulesSeen, joinDone, agreeMissing = false, false, false, false, 0
	lastClickTarget, lastClickAt = nil, 0
	joinBtn.Text = "Auto Masuk: " .. (autoJoinEnabled and "ON" or "OFF")
	joinBtn.BackgroundColor3 = autoJoinEnabled and GREEN or RED
	setStatus(autoJoinEnabled and "menyiapkan masuk..." or "Auto Masuk dimatikan")
end)

task.spawn(function()
	while running do
		task.wait((joinBusy or eventOpen) and 0.2 or 1)
		if not running then break end
		local ok, err = xpcall(processJoin, function(message) return debug.traceback(tostring(message), 2) end)
		if not ok then
			joinBusy = autoJoinEnabled
			joinMessage("Auto Masuk tertahan, cek console atau matikan tombolnya")
			if lastJoinError ~= tostring(err) then
				lastJoinError = tostring(err)
				print("[TurkeyAuto " .. SCRIPT_VERSION .. "/ERROR] " .. tostring(err))
			end
		else
			lastJoinError = nil
		end
	end
end)

---------------------------------------------------------------- pindah server
local HISTORY_FILE = "NotSameServers.json"
local serverHistory = { placeId = game.PlaceId, hour = math.floor(os.time() / 3600), ids = {} }
local historyLoaded = false
local historyWritable = type(writefile) == "function"

local function refreshServerHistory()
	local hour = math.floor(os.time() / 3600)
	if serverHistory.hour ~= hour then
		serverHistory.hour = hour
		serverHistory.ids = {}
	end
	if game.JobId ~= "" then serverHistory.ids[game.JobId] = true end
end

local function loadServerHistory()
	if historyLoaded then return end
	historyLoaded = true
	if type(readfile) == "function" then
		local ok, saved = pcall(function()
			return HttpService:JSONDecode(readfile(HISTORY_FILE))
		end)
		if ok and type(saved) == "table" then
			if saved.placeId == game.PlaceId and saved.hour == serverHistory.hour and type(saved.ids) == "table" then
				for id, visited in pairs(saved.ids) do
					if type(id) == "string" and visited == true then serverHistory.ids[id] = true end
				end
			elseif saved[1] == os.date("!*t").hour then
				-- Kompatibel dengan format lama [jam, ID, ID, ...].
				for index, id in ipairs(saved) do
					if index > 1 and type(id) == "string" then serverHistory.ids[id] = true end
				end
			end
		end
	end
	refreshServerHistory()
end

local function rememberServer(id)
	refreshServerHistory()
	serverHistory.ids[id] = true
	if not historyWritable then return end
	local ok, err = pcall(function()
		writefile(HISTORY_FILE, HttpService:JSONEncode(serverHistory))
	end)
	if not ok then
		historyWritable = false
		warn("[TurkeyAuto] riwayat server disimpan di memori sesi: " .. tostring(err))
	end
end

local function hopActive(generation)
	return running and hopBusy and hopGeneration == generation
end

local function setHopStatus(text)
	if running and hopBusy then status.Text = "Status: " .. text end
end

-- Pemeriksaan terakhir juga dilakukan sesudah HTTP, karena ayam bisa muncul
-- atau baru menempel ke karakter selama pencarian server berlangsung.
-- Selama precheck (sudah Continue, belum agree) hop tetap diizinkan walau joinBusy.
local function canAutoHop()
	if not enabled or (joinBusy and not joinPrecheck()) or not refreshPlayer() or not farmCharacter() then return false end
	if isHolding() or os.clock() < grabPendingUntil then return false end
	return nearestTurkey() == nil
end

local continuationQueued = false
local function queueContinuation()
	if continuationQueued or type(SCRIPT_SOURCE) ~= "string" then return end
	local queue = queue_on_teleport or queueonteleport
	if type(queue) ~= "function" and type(syn) == "table" then queue = syn.queue_on_teleport end
	if type(queue) ~= "function" and type(fluxus) == "table" then queue = fluxus.queue_on_teleport end
	if type(queue) ~= "function" then
		print("[KaitunAyam] queue teleport tidak tersedia; gunakan autoexec agar lanjut di server berikutnya")
		return
	end
	local loader = "local source = " .. string.format("%q", SCRIPT_SOURCE)
		.. "\nlocal run, err = loadstring(source, '@kaitunayam')"
		.. "\nif not run then error(err, 0) end"
		.. "\nif type(setfenv) == 'function' then setfenv(run, getfenv()) end"
		.. "\nrun(source)"
	local ok, err = pcall(queue, loader)
	if ok then
		continuationQueued = true
	else
		warn("[KaitunAyam] antrean teleport gagal; gunakan autoexec: " .. tostring(err))
	end
end

connect(TeleportService.TeleportInitFailed, function(player, result, message, placeId, options)
	local attempt = hopAttempt
	if not (hopBusy and attempt and attempt.requested and player == lp and placeId == game.PlaceId) then return end
	if options and options.ServerInstanceId ~= "" and options.ServerInstanceId ~= attempt.id then return end
	attempt.failure = tostring(result) .. " | " .. tostring(message)
	attempt.retryDelay = result == Enum.TeleportResult.Flooded and 15 or 2
end)

local function searchServers(generation, automatic)
	loadServerHistory()
	local cursor = ""
	local seenCursors = {}
	local attempts = 0
	local pageNo, skipped = 0, 0
	while hopActive(generation) do
		pageNo += 1
		if automatic and not canAutoHop() then return "lanjut mengambil atau mengirim ayam" end
		local url = "https://games.roblox.com/v1/games/" .. game.PlaceId .. "/servers/Public?sortOrder=Asc&limit=100"
		if cursor ~= "" then url ..= "&cursor=" .. HttpService:UrlEncode(cursor) end
		local page
		for retry = 1, 3 do
			if not hopActive(generation) then return end
			if automatic and not canAutoHop() then return "lanjut mengambil atau mengirim ayam" end
			setHopStatus(string.format("cari server: halaman %d, dilewati %d...", pageNo, skipped))
			-- HttpGet kadang nggak pernah balas (nggak ada timeout bawaan), jadi dijalankan di thread
			-- terpisah dan ditunggu maksimal 15 detik.
			local result = { done = false }
			task.spawn(function()
				local okCall, response = pcall(function()
					local decoded = HttpService:JSONDecode(game:HttpGet(url))
					if type(decoded) ~= "table" or type(decoded.data) ~= "table" then
						error("respons daftar server tidak valid")
					end
					return decoded
				end)
				result.ok, result.data, result.done = okCall, response, true
			end)
			local waited = os.clock()
			while not result.done and hopActive(generation) and os.clock() - waited < 15 do task.wait(0.2) end
			if not hopActive(generation) then return end
			local ok, data
			if result.done then
				ok, data = result.ok, result.data
			else
				ok, data = false, "timeout 15 detik, HttpGet tidak membalas"
			end
			if ok then
				page = data
				break
			end
			warn("[TurkeyAuto] gagal mengambil daftar server: " .. tostring(data))
			if retry < 3 then
				-- 429 = kena rate limit Roblox, kasih jeda lebih lama
				local limited = tostring(data):find("429", 1, true) ~= nil
				setHopStatus(limited and "kena rate limit Roblox, nunggu sebentar..." or "koneksi gagal, mencoba lagi...")
				task.wait(limited and 10 * retry or 2 ^ retry)
			end
		end
		if not page then return "gagal mengambil server, cek console" end

		for _, server in ipairs(page.data) do
			if not hopActive(generation) then return end
			if automatic and not canAutoHop() then return "lanjut mengambil atau mengirim ayam" end
			refreshServerHistory()
			if type(server) ~= "table" then continue end
			local id = server.id
			local playing, maxPlayers = tonumber(server.playing), tonumber(server.maxPlayers)
			if type(id) ~= "string" or id == "" or id == game.JobId or serverHistory.ids[id]
				or not playing or not maxPlayers or playing < 0 or playing >= maxPlayers then
				skipped += 1
				continue
			end

			attempts += 1
			local attempt = { id = id }
			hopAttempt = attempt
			rememberServer(id)
			if not hopActive(generation) then return end
			if automatic and not canAutoHop() then return "lanjut mengambil atau mengirim ayam" end
			queueContinuation()
			if not hopActive(generation) then return end
			if automatic and not canAutoHop() then return "lanjut mengambil atau mengirim ayam" end
			hopBtn.Text = "Menghubungkan..."
			setHopStatus("pindah server, percobaan " .. attempts)
			attempt.requested = true
			local ok, err = pcall(function()
				TeleportService:TeleportToPlaceInstance(game.PlaceId, id, lp)
			end)
			if not ok then attempt.failure = tostring(err) end
			local started = os.clock()
			-- Tunggu kegagalan atau perpindahan. Jangan antrekan teleport lain saat Roblox masih memproses.
			while hopActive(generation) and not attempt.failure do
				if os.clock() - started > 30 then setHopStatus("masih menunggu teleport Roblox...") end
				task.wait(0.2)
			end
			if not hopActive(generation) then return end
			hopAttempt = nil
			warn("[TurkeyAuto] teleport ke " .. id .. " gagal: " .. attempt.failure)
			if attempts >= 5 then return "5 percobaan teleport gagal, coba lagi nanti" end
			hopBtn.Text = "Batalkan Pencarian"
			setHopStatus("teleport gagal, mencoba server lain...")
			task.wait(attempt.retryDelay or 2)
		end

		local nextCursor = page.nextPageCursor
		if nextCursor == nil or nextCursor == "" or nextCursor == "null" then
			return "belum ada server baru yang tersedia"
		end
		if type(nextCursor) ~= "string" or seenCursors[nextCursor] then
			return "cursor daftar server berulang atau tidak valid"
		end
		seenCursors[nextCursor] = true
		cursor = nextCursor
		task.wait(1)
	end
end

local function startServerHop(automatic)
	if hopBusy then return end
	if not refreshPlayer() then setStatus("menunggu pemain tersedia sebelum pindah server") return end
	if automatic and (os.clock() < autoHopRetryAt or not canAutoHop()) then return end
	if game.PlaceId <= 0 then
		setStatus("PlaceId belum tersedia")
		return
	end
	hopGeneration += 1
	local generation = hopGeneration
	hopBusy = true
	hopBtn.Text = "Batalkan Pencarian"
	setHopStatus("mencari server dengan slot kosong...")
	task.spawn(function()
		local ok, message = pcall(searchServers, generation, automatic)
		if not hopActive(generation) then return end
		hopAttempt = nil
		hopBusy = false
		hopBtn.Text = "Pindah Server"
		hopNoticeUntil = os.clock() + 5
		-- Gagal/daftar kosong: beri jeda agar HTTP tidak diulang tiap frame.
		autoHopRetryAt = os.clock() + ((automatic and canAutoHop()) and 10 or 0)
		if not ok then
			warn("[TurkeyAuto] pindah server gagal: " .. tostring(message))
			message = "pindah server gagal, cek console"
		end
		setStatus(message or "pencarian server selesai")
	end)
end

hopBtn.MouseButton1Click:Connect(function()
	if hopBusy then
		if hopAttempt then
			setHopStatus("teleport sudah diminta, tunggu Roblox...")
			return
		end
		hopGeneration += 1
		hopBusy = false
		hopBtn.Text = "Pindah Server"
		autoHopRetryAt = os.clock() + 10
		hopNoticeUntil = os.clock() + 5
		setStatus("pencarian dibatalkan; auto coba lagi dalam 10 detik")
		return
	end
	startServerHop(false)
end)

local function bindToggle(btn, label, initial, onChange)
	local on = initial
	btn.MouseButton1Click:Connect(function()
		if hopBusy then return end
		on = not on
		btn.Text = label .. ": " .. (on and "ON" or "OFF")
		btn.BackgroundColor3 = on and GREEN or RED
		onChange(on)
	end)
end
bindToggle(grabBtn, "Auto Grab", enabled, function(v)
	enabled = v
	emptyScans = 0
	if not v then setStatus("OFF") end
end)
bindToggle(sendBtn, "Auto Kirim ke Farmer", sendEnabled, function(v) sendEnabled = v end)

local function toFarmer()
	local f = findFarmer()
	local fr = f and npcRoot(f)
	local me = getHRP()
	if not (fr and me) then return false end
	me.AssemblyLinearVelocity = Vector3.zero
	me.CFrame = CFrame.new(fr.Position + Vector3.new(2, 0, 2))
	return true, f.Name
end

tpBtn.MouseButton1Click:Connect(function()
	if hopBusy or joinBusy then return end
	farmerLastSearch = 0 -- paksa scan ulang pas klik manual
	local ok, name = toFarmer()
	setStatus(ok and ("TP ke " .. name) or "farmer nggak ketemu, klik Dump NPC")
end)

dumpBtn.MouseButton1Click:Connect(function()
	dumpNPCs()
	setStatus("dump NPC dicatat (console + clipboard)")
end)

scanBtn.MouseButton1Click:Connect(function()
	snapshotNearby(60, "scan manual")
	updateCounter()
	setStatus("snapshot dicatat (console + clipboard)")
end)

posBtn.MouseButton1Click:Connect(function()
	local r = getHRP()
	if not r then return end
	local p = r.Position
	local s = string.format("Vector3.new(%.1f, %.1f, %.1f)", p.X, p.Y, p.Z)
	print("[TurkeyAuto] posisi: " .. s)
	if setclipboard then pcall(setclipboard, s) end
	setStatus("posisi dicatat: " .. s)
end)

-- drag lewat judul
do
	local dragging, startPos, startFrame
	title.InputBegan:Connect(function(i)
		if i.UserInputType == Enum.UserInputType.MouseButton1 or i.UserInputType == Enum.UserInputType.Touch then
			dragging, startPos, startFrame = true, i.Position, frame.Position
		end
	end)
	connect(UIS.InputChanged, function(i)
		if dragging and (i.UserInputType == Enum.UserInputType.MouseMovement or i.UserInputType == Enum.UserInputType.Touch) then
			local d = i.Position - startPos
			frame.Position = UDim2.new(startFrame.X.Scale, startFrame.X.Offset + d.X, startFrame.Y.Scale, startFrame.Y.Offset + d.Y)
		end
	end)
	connect(UIS.InputEnded, function(i)
		if i.UserInputType == Enum.UserInputType.MouseButton1 or i.UserInputType == Enum.UserInputType.Touch then
			dragging = false
		end
	end)
end

---------------------------------------------------------------- loop utama
local holdingNow = false

-- log prompt non-Sit yang muncul pas lagi pegang ayam
pcall(function()
	connect(game:GetService("ProximityPromptService").PromptShown, function(prompt)
		if holdingNow and prompt.ActionText ~= "Grab" and prompt.ActionText ~= "Sit" then
			print(string.format("[TurkeyAuto] prompt muncul pas pegang ayam: %s | %s | %s",
				prompt.ActionText, prompt.ObjectText, prompt:GetFullName()))
		end
	end)
end)

task.spawn(function()
	while running do
		task.wait(0.15)
		if not running then break end
		refreshPlayer()
		if hopBusy then continue end
		if joinBusy then
			-- Sudah lewat Continue tapi belum agree: cek ayam, kalau kosong langsung pindah server
			if joinPrecheck() and enabled and farmCharacter()
				and os.clock() - joinContinuedAt >= PRECHECK_SETTLE then
				if nearestTurkey() == nil and not isHolding() then
					emptyScans += 1
					if emptyScans >= 2 then
						joinMessage("tidak ada ayam setelah Continue, pindah server...")
						startServerHop(true)
					end
				else
					emptyScans = 0
				end
			end
			continue
		end
		local me, hum = farmCharacter()
		if not me then
			emptyScans = 0
			setStatus("menunggu karakter siap...", true)
			continue
		end
		-- lagi duduk (kursi/seat)? lompat dulu sampai berdiri, nggak bisa grab kalau masih duduk
		if (enabled or sendEnabled) and hum and hum.Sit then
			setStatus("lagi duduk, lompat dulu biar berdiri...", true)
			hum.Sit = false
			hum.Jump = true
			pcall(function() hum:ChangeState(Enum.HumanoidStateType.Jumping) end)
			task.wait(0.35)
			continue
		end
		local holding = isHolding()

		if holding and not holdingNow then
			grabCount += 1
			updateCounter()
		elseif holdingNow and not holding then
			snapshotNearby(60, "ayam lepas (kemungkinan diserahin ke farmer)")
			updateCounter()
		end
		holdingNow = holding
		if holding then
			grabPendingUntil = 0
			emptyScans = 0
		end

		if holding and sendEnabled then
			local f = findFarmer()
			local fr = f and npcRoot(f)
			local me = getHRP()
			if not fr then
				setStatus("farmer nggak ketemu (klik Dump NPC)", true)
			elseif me then
				if (me.Position - fr.Position).Magnitude > 6 then toFarmer() end
				setStatus("di dekat " .. f.Name .. ", nunggu ayam ilang", true)
			end
		elseif enabled and holding then
			setStatus("lagi pegang ayam, bawa ke farmer manual", true)
		elseif enabled then
			local root, prompt, dist = nearestTurkey()
			if not root then
				if os.clock() < grabPendingUntil then
					emptyScans = 0
					setStatus("menunggu hasil grab terakhir...", true)
				elseif os.clock() < autoHopRetryAt then
					emptyScans = 0
					setStatus("ayam kecil habis, menunggu percobaan pindah server...", true)
				else
					if os.clock() - joinDoneAt < SETTLE_AFTER_JOIN then
						-- baru masuk: kasih sebentar biar ayam di sekitar ke-load dulu
						emptyScans = 0
						setStatus("memeriksa ayam di sekitar...", true)
					else
						-- Konfirmasi dua pemindaian singkat untuk perubahan replika sesaat.
						emptyScans += 1
						if emptyScans >= 2 then startServerHop(true) end
					end
				end
			else
				emptyScans = 0
				setStatus(string.format("ngejar ayam (jarak %d)", math.floor(dist)), true)
				me.AssemblyLinearVelocity = Vector3.zero
				me.CFrame = root.CFrame + Vector3.new(0, 3, 0)
				-- Prompt dapat nonaktif lebih dulu sebelum TurkeyHold direplikasi.
				grabPendingUntil = os.clock() + 5
				press(prompt)
			end
		end
	end
end)

]========]
local run, err = loadstring(source, '@kaitunayam')
if not run then error(err, 0) end
if type(setfenv) == 'function' then setfenv(run, getfenv()) end
run(source)
