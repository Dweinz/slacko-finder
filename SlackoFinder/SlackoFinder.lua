-- Slacko Finder: bevaka spelare via /who och communities, kom ihåg var de senast sågs, larma vid ändringar.

local db, pending, cursor, refresh, debug
local sentAt, autoOff = 0, false
local function p(msg) print("|cff33ff99Slacko|r " .. msg) end
local function dbg(msg) if debug then p("|cffaaaaaa[debug] " .. msg .. "|r") end end
local function key(name) return (name:gsub("%-.*", "")):lower() end

local function ago(t)
  local s = time() - t
  if s < 60 then return "nyss" end
  if s < 3600 then return math.floor(s / 60) .. " min sen" end
  if s < 86400 then return math.floor(s / 3600) .. " h sen" end
  return math.floor(s / 86400) .. " d sen"
end

local function alert(msg)
  p(msg)
  RaidNotice_AddMessage(RaidWarningFrame, msg, ChatTypeInfo.RAID_WARNING)
  PlaySound(SOUNDKIT.RAID_WARNING)
end

local function add(name)
  name = name:gsub("^%s+", ""):gsub("%s+$", "")
  if name ~= "" then db[key(name)] = db[key(name)] or { name = name } end
end

-- Gemensam uppdatering för både /who och community: sparar info och larmar vid ändring.
local function update(k, online, name, zone, level, classFile)
  local e = db[k]
  local wasOnline, wasZone = e.online, e.zone
  if online then
    e.name, e.zone, e.level, e.classFile, e.seen = name or e.name, zone or e.zone, level or e.level, classFile or e.classFile, time()
  end
  e.online = online
  if wasOnline ~= nil and wasOnline ~= online then
    alert(e.name .. (online and " är nu ONLINE" or " gick OFFLINE"))
  end
  if online and e.zone and e.zone == GetRealZoneText() and wasZone ~= e.zone then
    alert(e.name .. " är i din zon: " .. e.zone)
  end
end

---------------------------------------------------------------- communities (ingen /who behövs)
local IN_GAME = {}
for _, s in ipairs({ "Online", "Away", "Busy" }) do -- OnlineMobile = i appen, inte i spelet
  if Enum.ClubMemberPresence then IN_GAME[Enum.ClubMemberPresence[s]] = true end
end

local function eachClubMember(fn)
  if not C_Club then return end
  for _, club in ipairs(C_Club.GetSubscribedClubs() or {}) do
    if club.clubType ~= Enum.ClubType.BattleNet then -- BattleNet-communities har battletags, inte gubbnamn
      for _, id in ipairs(C_Club.GetClubMembers(club.clubId) or {}) do
        local m = C_Club.GetMemberInfo(club.clubId, id)
        if m and m.name and not m.isSelf then fn(m) end
      end
    end
  end
end

local function syncClubs()
  if not db then return end
  eachClubMember(function(m)
    local k = key(m.name)
    -- Community säger bara "online". "Offline" kan vara Appear Offline eller en alt,
    -- så då får /who avgöra (clubOnline=false gör att scan() tar med dem).
    if db[k] then
      db[k].clubOnline = IN_GAME[m.presence] or false
      if db[k].clubOnline then
        local ci = m.classID and C_CreatureInfo.GetClassInfo(m.classID)
        update(k, true, m.name, m.zone, m.level, ci and ci.classFile)
      end
    end
  end)
  refresh()
end

---------------------------------------------------------------- /who (för de som inte är i en community)
local function scan()
  local keys = {}
  for k, e in pairs(db) do if not e.clubOnline then keys[#keys + 1] = k end end
  if #keys == 0 then return end
  table.sort(keys)
  cursor = (cursor or 0) % #keys + 1
  pending, sentAt = keys[cursor], GetTime()
  -- false = svar till chatten (vi läser och döljer dem), inte till LFG-/who-fönstret
  if C_FriendList.SetWhoToUi then C_FriendList.SetWhoToUi(false) end
  dbg("/who skickad: " .. db[pending].name)
  C_FriendList.SendWho('n-"' .. db[pending].name .. '"')
end

-- Små /who-svar kommer som chattrader i stället för WHO_LIST_UPDATE (Forever/classic).
local function pat(fmt)
  if type(fmt) ~= "string" then return nil end
  local out = fmt:gsub("([%^%$%(%)%.%[%]%*%+%-%?])", "%%%1")
  out = out:gsub("%%d", "(%%d+)"):gsub("%%s", "(.-)")
  return "^" .. out .. "$"
end
local whoPats
local function whoLine(msg) -- returnerar namn, nivå, zon om raden är ett /who-resultat
  whoPats = whoPats or { pat(WHO_LIST_GUILD_FORMAT), pat(WHO_LIST_FORMAT) }
  for _, pt in ipairs(whoPats) do
    local c = { msg:match(pt) }
    if #c >= 6 then return c[1], tonumber(c[3]), c[#c] end
  end
end
-- ponytail: "0 ..." = "0 players total" på engelska klient; byt mot WHO_NUM_RESULTS-mönster om det slår fel.
local function zeroLine(msg) return msg:match("^0 ") ~= nil end

ChatFrame_AddMessageEventFilter("CHAT_MSG_SYSTEM", function(_, _, msg) -- dölj våra automatiska /who i chatten
  if debug or GetTime() - sentAt > 3 then return false end
  local ok, hide = pcall(function() return whoLine(msg) ~= nil or zeroLine(msg) or msg:match("^%d+ ") ~= nil end)
  return ok and hide
end)

-- Automatik: SendWho kräver ett tangent-/klicktryck, så vi hakar på spelarens vanliga input
-- (gå, svänga kameran, casta...) och kör nästa /who max var INTERVAL:e sekund.
-- ponytail: en person per intervall, N personer = uppdatering var N*INTERVAL s.
-- Bara musklick i spelvärlden (svänga kameran, klicka på saker), aldrig tangentbord:
-- /who i samma knapptryck som ett chattmeddelande gav disconnect i Forever.
local INTERVAL, lastScan = 15, 0
local function chatOpen()
  local ok, active = pcall(function() return ChatEdit_GetActiveWindow and ChatEdit_GetActiveWindow() end)
  return ok and active
end
local function autoScan()
  if db and not autoOff and not chatOpen() and GetTime() - lastScan > INTERVAL then -- inget svar = gå vidare
    lastScan = GetTime()
    scan()
  end
end
WorldFrame:HookScript("OnMouseDown", autoScan)

---------------------------------------------------------------- fönster
local ICON = "Interface\\AddOns\\SlackoFinder\\icon"
local VIP = { ["slacko taow"] = true } -- det är ju Slacko Finder
local ROW_H, W = 26, 480
local CW = W - 52 -- innehållsbredd
local settings = {}

local win = CreateFrame("Frame", "SlackoFinderFrame", UIParent, "BasicFrameTemplateWithInset")
win:SetSize(W, 440)
win:SetPoint("CENTER")
win:SetMovable(true)
win:SetClampedToScreen(true)
win:EnableMouse(true)
win:RegisterForDrag("LeftButton")
win:SetScript("OnDragStart", win.StartMoving)
win:SetScript("OnDragStop", win.StopMovingOrSizing)
win:Hide()
tinsert(UISpecialFrames, "SlackoFinderFrame") -- Esc stänger
win.TitleText:SetText("Slacko Finder")
local logo = win:CreateTexture(nil, "OVERLAY")
logo:SetSize(16, 16)
logo:SetPoint("RIGHT", win.TitleText, "LEFT", -4, 0)
logo:SetTexture(ICON)
logo:SetTexCoord(0.08, 0.92, 0.08, 0.92)

local box = CreateFrame("EditBox", nil, win, "InputBoxTemplate")
box:SetSize(210, 22)
box:SetPoint("TOPLEFT", 22, -32)
box:SetAutoFocus(false)
local hint = box:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
hint:SetPoint("LEFT", 2, 0)
hint:SetText("Spelarnamn...")
box:SetScript("OnTextChanged", function(self) hint:SetShown(self:GetText() == "") end)
local function addFromBox() add(box:GetText()); box:SetText(""); box:ClearFocus(); refresh() end
box:SetScript("OnEnterPressed", addFromBox)
box:SetScript("OnEscapePressed", box.ClearFocus)

local addBtn = CreateFrame("Button", nil, win, "UIPanelButtonTemplate")
addBtn:SetSize(90, 22)
addBtn:SetPoint("LEFT", box, "RIGHT", 6, 0)
addBtn:SetText("Lägg till")
addBtn:SetScript("OnClick", addFromBox)

local clubBtn = CreateFrame("Button", nil, win, "UIPanelButtonTemplate")
clubBtn:SetSize(130, 22)
clubBtn:SetPoint("LEFT", addBtn, "RIGHT", 6, 0)
clubBtn:SetText("Hämta community")
clubBtn:SetScript("OnClick", function()
  local n = 0
  eachClubMember(function(m) if not db[key(m.name)] then n = n + 1 end; add(m.name) end)
  p(n .. " nya från dina communities")
  syncClubs()
end)

-- kolumnrubriker
local COL_NAME, COL_LVL, COL_ZONE = 44, 200, 232
local function header(text, x, point)
  local h = win:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
  if point then h:SetPoint("TOPRIGHT", -48, -66) else h:SetPoint("TOPLEFT", 14 + x, -66) end
  h:SetText(text)
end
header("Namn", COL_NAME)
header("Lv", COL_LVL)
header("Zon", COL_ZONE)
header("Senast", 0, true)
local line = win:CreateTexture(nil, "ARTWORK")
line:SetColorTexture(1, 0.82, 0, 0.3)
line:SetHeight(1)
line:SetPoint("TOPLEFT", 14, -80)
line:SetPoint("TOPRIGHT", -14, -80)

local scroll = CreateFrame("ScrollFrame", nil, win, "UIPanelScrollFrameTemplate")
scroll:SetPoint("TOPLEFT", 14, -84)
scroll:SetPoint("BOTTOMRIGHT", -34, 34)
local content = CreateFrame("Frame", nil, scroll)
content:SetSize(CW, 1)
scroll:SetScrollChild(content)

local footer = win:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
footer:SetPoint("BOTTOMLEFT", 18, 14)
local scanBtn = CreateFrame("Button", nil, win, "UIPanelButtonTemplate")
scanBtn:SetSize(70, 20)
scanBtn:SetPoint("BOTTOMRIGHT", -14, 9)
scanBtn:SetText("Sök")
scanBtn:SetScript("OnClick", function() scan() end) -- knappklick = alltid giltigt för /who
local help = win:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
help:SetPoint("RIGHT", scanBtn, "LEFT", -10, 0)
help:SetText("Vänsterklick: viska  ·  Högerklick: bjud in")

local function tell(name) (ChatFrame_SendTell or ChatFrameUtil.SendTell)(name) end
local function invite(name) (C_PartyInfo and C_PartyInfo.InviteUnit or InviteUnit)(name) end

local function tooltip(r)
  local e = db[r.key]
  if not e then return end
  GameTooltip:SetOwner(r, "ANCHOR_RIGHT")
  local c = e.classFile and RAID_CLASS_COLORS[e.classFile]
  GameTooltip:AddLine(e.name, c and c.r or 1, c and c.g or 0.82, c and c.b or 0)
  if e.level then GameTooltip:AddLine("Level " .. e.level, 1, 1, 1) end
  if e.zone then GameTooltip:AddLine(e.zone, 1, 1, 1) end
  if e.online then GameTooltip:AddLine("Online", 0, 1, 0)
  elseif e.seen then GameTooltip:AddLine("Offline, sågs " .. ago(e.seen), 0.6, 0.6, 0.6)
  else GameTooltip:AddLine("Inte sedd än", 0.6, 0.6, 0.6) end
  if e.clubOnline ~= nil then GameTooltip:AddLine("Community-medlem", 0.4, 0.7, 1) end
  GameTooltip:Show()
end

local rows = {}
local function row(i)
  if rows[i] then return rows[i] end
  local r = CreateFrame("Button", nil, content)
  r:SetSize(CW, ROW_H)
  r:SetPoint("TOPLEFT", 0, -(i - 1) * ROW_H)
  r:RegisterForClicks("LeftButtonUp", "RightButtonUp")
  r.bg = r:CreateTexture(nil, "BACKGROUND")
  r.bg:SetAllPoints()
  r.bg:SetColorTexture(1, 1, 1, i % 2 == 0 and 0.03 or 0)
  r.glow = r:CreateTexture(nil, "BORDER") -- svag grön ton på online-rader
  r.glow:SetAllPoints()
  r.glow:SetColorTexture(0.1, 1, 0.2, 0.07)
  r.vip = r:CreateTexture(nil, "BORDER") -- guldtoning för Slacko
  r.vip:SetAllPoints()
  r.vip:SetColorTexture(1, 0.82, 0, 0.18)
  r.vipEdge = r:CreateTexture(nil, "ARTWORK")
  r.vipEdge:SetSize(3, ROW_H)
  r.vipEdge:SetPoint("LEFT")
  r.vipEdge:SetColorTexture(1, 0.82, 0, 1)
  r.star = r:CreateTexture(nil, "OVERLAY")
  r.star:SetSize(14, 14)
  r.star:SetTexture("Interface\\TargetingFrame\\UI-RaidTargetingIcon_1")
  r:SetHighlightTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight", "ADD")
  r.dot = r:CreateTexture(nil, "ARTWORK")
  r.dot:SetSize(10, 10)
  r.dot:SetPoint("LEFT", 4, 0)
  r.cls = r:CreateTexture(nil, "ARTWORK")
  r.cls:SetSize(20, 20)
  r.cls:SetPoint("LEFT", 18, 0)
  r.name = r:CreateFontString(nil, "OVERLAY", "GameFontNormal")
  r.name:SetPoint("LEFT", COL_NAME, 0)
  r.name:SetWidth(COL_LVL - COL_NAME - 4)
  r.name:SetJustifyH("LEFT")
  r.name:SetWordWrap(false)
  r.lvl = r:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  r.lvl:SetPoint("LEFT", COL_LVL, 0)
  r.zone = r:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  r.zone:SetPoint("LEFT", COL_ZONE, 0)
  r.zone:SetWidth(110)
  r.zone:SetJustifyH("LEFT")
  r.zone:SetWordWrap(false)
  r.seen = r:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
  r.seen:SetPoint("RIGHT", -22, 0)
  r.del = CreateFrame("Button", nil, r, "UIPanelCloseButton")
  r.del:SetSize(18, 18)
  r.del:SetPoint("RIGHT", 0, 0)
  r.del:SetAlpha(0) -- syns bara när musen är över raden
  r.del:SetScript("OnClick", function() db[r.key] = nil; GameTooltip:Hide(); refresh() end)
  r.del:SetScript("OnEnter", function() r.del:SetAlpha(1) end)
  r.del:SetScript("OnLeave", function() if not r:IsMouseOver() then r.del:SetAlpha(0) end end)
  r:SetScript("OnEnter", function() r.del:SetAlpha(1); tooltip(r) end)
  r:SetScript("OnLeave", function() if not r.del:IsMouseOver() then r.del:SetAlpha(0) end; GameTooltip:Hide() end)
  r:SetScript("OnClick", function(_, btn)
    local e = db[r.key]
    if e then if btn == "RightButton" then invite(e.name) else tell(e.name) end end
  end)
  rows[i] = r
  return r
end

local empty = win:CreateFontString(nil, "OVERLAY", "GameFontDisable")
empty:SetPoint("CENTER", 0, -10)
empty:SetText("Skriv ett namn ovan, eller hämta din community")

---------------------------------------------------------------- minimapknapp
local mm = CreateFrame("Button", "SlackoFinderMinimapButton", Minimap)
mm:SetSize(32, 32)
mm:SetFrameStrata("MEDIUM")
mm:SetFrameLevel(8)
mm:RegisterForClicks("LeftButtonUp", "RightButtonUp")
mm:RegisterForDrag("LeftButton")
mm:SetHighlightTexture("Interface\\Minimap\\UI-Minimap-ZoomButton-Highlight")
local mmBg = mm:CreateTexture(nil, "BACKGROUND")
mmBg:SetSize(24, 24)
mmBg:SetPoint("CENTER")
mmBg:SetTexture("Interface\\Minimap\\UI-Minimap-Background")
local mmIcon = mm:CreateTexture(nil, "ARTWORK")
mmIcon:SetSize(20, 20)
mmIcon:SetPoint("CENTER")
mmIcon:SetTexture(ICON)
pcall(mmIcon.SetMask, mmIcon, "Interface\\CharacterFrame\\TempPortraitAlphaMask") -- rund ikon
local mmBorder = mm:CreateTexture(nil, "OVERLAY")
mmBorder:SetSize(54, 54)
mmBorder:SetPoint("TOPLEFT")
mmBorder:SetTexture("Interface\\Minimap\\MiniMap-TrackingBorder")
local badge = mm:CreateFontString(nil, "OVERLAY", "NumberFontNormalSmall")
badge:SetPoint("BOTTOMRIGHT", 2, 0)
badge:SetTextColor(0.2, 1, 0.2)

local function placeMinimap()
  local a, rad = math.rad(settings.mmAngle or 200), Minimap:GetWidth() / 2 + 5
  mm:ClearAllPoints()
  mm:SetPoint("CENTER", Minimap, "CENTER", math.cos(a) * rad, math.sin(a) * rad)
end
mm:SetScript("OnDragStart", function()
  mm:SetScript("OnUpdate", function()
    local mx, my = Minimap:GetCenter()
    local px, py = GetCursorPosition()
    local s = Minimap:GetEffectiveScale()
    settings.mmAngle = math.deg(math.atan2(py / s - my, px / s - mx))
    placeMinimap()
  end)
end)
mm:SetScript("OnDragStop", function() mm:SetScript("OnUpdate", nil) end)
mm:SetScript("OnClick", function() win:SetShown(not win:IsShown()) end)
mm:SetScript("OnEnter", function()
  GameTooltip:SetOwner(mm, "ANCHOR_LEFT")
  GameTooltip:AddLine("Slacko Finder")
  GameTooltip:AddLine(footer:GetText() or "", 1, 1, 1)
  GameTooltip:AddLine("Klicka: öppna  ·  Dra: flytta", 0.6, 0.6, 0.6)
  GameTooltip:Show()
end)
mm:SetScript("OnLeave", function() GameTooltip:Hide() end)

local function onLoaded()
  SlackoFinderSettings = SlackoFinderSettings or {}
  settings = SlackoFinderSettings
  placeMinimap()
  refresh()
end

function refresh()
  if not db then return end
  local list, online = {}, 0
  for k, e in pairs(db) do
    list[#list + 1] = { k = k, e = e }
    if e.online then online = online + 1 end
  end
  footer:SetText(online .. " av " .. #list .. " online")
  badge:SetText(online > 0 and online or "")
  if not win:IsShown() then return end
  table.sort(list, function(a, b)
    if (VIP[a.k] or false) ~= (VIP[b.k] or false) then return VIP[a.k] end
    if (a.e.online or false) ~= (b.e.online or false) then return a.e.online end
    return a.k < b.k
  end)
  empty:SetShown(#list == 0)
  content:SetHeight(math.max(1, #list * ROW_H))
  if scroll.ScrollBar then scroll.ScrollBar:SetShown(#list * ROW_H > scroll:GetHeight()) end
  for i = 1, math.max(#list, #rows) do
    local it, r = list[i], row(i)
    r:SetShown(it ~= nil)
    if it then
      local e = it.e
      r.key = it.k
      r.glow:SetShown(e.online == true)
      r.dot:SetTexture(e.online and "Interface\\COMMON\\Indicator-Green"
        or e.online == nil and "Interface\\COMMON\\Indicator-Yellow" -- inte kollad än
        or "Interface\\COMMON\\Indicator-Gray")
      local tc = e.classFile and CLASS_ICON_TCOORDS and CLASS_ICON_TCOORDS[e.classFile]
      if tc then
        r.cls:SetTexture("Interface\\WorldStateFrame\\Icons-Classes")
        r.cls:SetTexCoord(unpack(tc))
      else
        r.cls:SetTexture("Interface\\Icons\\INV_Misc_QuestionMark")
        r.cls:SetTexCoord(0.08, 0.92, 0.08, 0.92)
      end
      r.cls:SetDesaturated(not e.online)
      local c = e.classFile and RAID_CLASS_COLORS[e.classFile]
      r.name:SetText(c and c:WrapTextInColorCode(e.name) or e.name)
      r.name:SetAlpha(e.online and 1 or 0.6)
      local vip = VIP[it.k] or false
      r.vip:SetShown(vip)
      r.vipEdge:SetShown(vip)
      r.star:SetShown(vip)
      r.star:ClearAllPoints()
      r.star:SetPoint("LEFT", r.name, "LEFT", r.name:GetStringWidth() + 4, 0)
      r.lvl:SetText(e.level or "")
      r.zone:SetText(e.zone or "|cff666666–|r")
      r.zone:SetAlpha(e.online and 1 or 0.6)
      r.seen:SetText(e.online and "|cff33ff33online|r"
        or e.online == nil and "|cffffd100kollar...|r"
        or e.seen and ago(e.seen) or "aldrig sedd")
    end
  end
end
win:SetScript("OnShow", refresh)
C_Timer.NewTicker(15, syncClubs) -- community-status + håller "x min sen" färskt

---------------------------------------------------------------- events
local f = CreateFrame("Frame")
f:RegisterEvent("ADDON_LOADED")
f:RegisterEvent("WHO_LIST_UPDATE")
f:RegisterEvent("NAME_PLATE_UNIT_ADDED")
f:RegisterEvent("CLUB_MEMBER_PRESENCE_UPDATED")
f:RegisterEvent("CHAT_MSG_SYSTEM")
f:RegisterEvent("ADDON_ACTION_BLOCKED")
f:RegisterEvent("ADDON_ACTION_FORBIDDEN")
local nearAt = {}
f:SetScript("OnEvent", function(_, event, arg, func)
  if (event == "ADDON_ACTION_BLOCKED" or event == "ADDON_ACTION_FORBIDDEN") and arg == "SlackoFinder" then
    -- WoW godtog inte vårt anrop: stäng av automatiken så vi inte stör andra addons
    if not autoOff then
      autoOff = true
      p("WoW blockerade " .. tostring(func) .. ". Automatisk /who avstängd, använd Sök-knappen.")
    end
    return
  end
  if event == "ADDON_LOADED" then
    if arg == "SlackoFinder" then SlackoFinderDB = SlackoFinderDB or {}; db = SlackoFinderDB; onLoaded() end
  elseif event == "CLUB_MEMBER_PRESENCE_UPDATED" then
    syncClubs()
  elseif event == "NAME_PLATE_UNIT_ADDED" then -- namnplåt syns = inom ~40 m
    -- pcall: namn kan vara "secret values" i strid (Midnight)
    local ok, k = pcall(function() local k = key(UnitName(arg)); return db[k] and k end)
    if ok and k and time() - (nearAt[k] or 0) > 60 then
      nearAt[k] = time()
      alert(db[k].name .. " är NÄRA dig!")
    end
  elseif event == "CHAT_MSG_SYSTEM" and pending and db[pending] then
    local ok, name, level, zone = pcall(whoLine, arg) -- pcall: meddelandet kan vara "secret"
    if ok and name and key(name) == pending then
      dbg("svar i chatten: " .. name .. " i " .. zone)
      update(pending, true, name, zone, level)
      pending = nil
      refresh()
    elseif ok and not name and zeroLine(arg) then
      dbg("svar i chatten: 0 träffar -> offline")
      update(pending, false)
      pending = nil
      refresh()
    end
  elseif event == "WHO_LIST_UPDATE" and pending and db[pending] then
    local k, found = pending, false
    dbg("WHO_LIST_UPDATE med " .. C_FriendList.GetNumWhoResults() .. " träffar")
    if C_FriendList.GetNumWhoResults() == 0 then
      -- svaret kan vara på väg som chattrad; vänta 1 s innan vi säger offline
      C_Timer.After(1, function() if pending == k then update(k, false); pending = nil; refresh() end end)
      return
    end
    pending = nil
    for i = 1, C_FriendList.GetNumWhoResults() do
      local w = C_FriendList.GetWhoInfo(i)
      if w and key(w.fullName) == k then -- n-"X" matchar delsträngar, kräv exakt namn
        found = true
        update(k, true, w.fullName, w.area, w.level, w.filename)
      end
    end
    if not found then update(k, false) end
    refresh()
  end
end)

SLASH_SLACKOFINDER1 = "/sf"
SlashCmdList.SLACKOFINDER = function(msg)
  local cmd, name = msg:match("^(%S*)%s*(.-)%s*$")
  if cmd == "add" then add(name); refresh()
  elseif cmd == "del" then db[key(name)] = nil; refresh()
  elseif cmd == "scan" then scan()
  elseif cmd == "debug" then debug = not debug; p("debug " .. (debug and "PÅ" or "av"))
  else win:SetShown(not win:IsShown()) end
end
