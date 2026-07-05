-- Shared JSON-RPC handlers for PoB API (transport-agnostic)

-- Debug logging control
local DEBUG = os.getenv('POB_API_DEBUG') == '1'
local function debug_log(msg)
  if DEBUG then io.stderr:write('[Handlers] ' .. msg .. '\n') end
end

-- Resolve BuildOps reliably regardless of CWD
local BuildOps
do
  debug_log('Attempting to require API.BuildOps')
  local ok_ops, mod = pcall(require, 'API.BuildOps')
  debug_log('pcall require result: ok=' .. tostring(ok_ops) .. ', mod=' .. tostring(mod))
  if ok_ops and mod then
    debug_log('Successfully loaded BuildOps via require')
    BuildOps = mod
  else
    debug_log('require failed, trying dofile fallbacks')
    -- Try path relative to this file's directory
    local dir = ''
    local info = debug and debug.getinfo and debug.getinfo(1, 'S')
    local src = info and info.source or ''
    if type(src) == 'string' and src:sub(1,1) == '@' then
      local p = src:sub(2)
      dir = (p:gsub('[^/\\]+$', ''))
    end
    local tried = {}
    local function try(p)
      if p then table.insert(tried, p) end
      if not p then return false end
      debug_log('Trying to load: ' .. tostring(p))
      local ok2, m = pcall(dofile, p)
      if ok2 and m then
        debug_log('Successfully loaded BuildOps from: ' .. tostring(p))
        BuildOps = m
        return true
      end
      debug_log('Failed to load from: ' .. tostring(p) .. ' - error: ' .. tostring(m))
      return false
    end
    if not BuildOps then
      local _ = try(dir .. 'BuildOps.lua')
              or try((rawget(_G,'POB_SCRIPT_DIR') or '.') .. '/API/BuildOps.lua')
              or try('API/BuildOps.lua')
              or try('src/API/BuildOps.lua')
    end
    if not BuildOps then
      io.stderr:write('[Handlers] BuildOps.lua not found. Tried paths: ' .. table.concat(tried, ', ') .. '\n')
      error('API/BuildOps.lua not found. Tried: ' .. table.concat(tried, ', '))
    end
  end
end

local API_VERSION = "1.0.0"

local function version_meta()
  return {
    number      = _G.launch and launch.versionNumber or '?',
    branch      = _G.launch and launch.versionBranch or '?',
    platform    = _G.launch and launch.versionPlatform or '?',
    apiVersion  = API_VERSION,
  }
end

local handlers = {}

handlers.ping = function(params)
  return { ok = true, pong = true }
end

handlers.version = function(params)
  return { ok = true, version = version_meta() }
end

-- Class name → classId mapping (PoE1)
local CLASS_IDS = {
  Scion=0, Marauder=1, Ranger=2, Witch=3, Duelist=4, Templar=5, Shadow=6,
  scion=0, marauder=1, ranger=2, witch=3, duelist=4, templar=5, shadow=6,
}
-- Ascendancy index matches the order in TreeData/3_27/tree.lua ["ascendancies"] array (1-based)
local ASCENDANCY_IDS = {
  [0] = { Ascendant=1 },                               -- Scion
  [1] = { Juggernaut=1, Berserker=2, Chieftain=3 },    -- Marauder
  [2] = { Raider=1, Deadeye=2, Pathfinder=3 },         -- Ranger
  [3] = { Occultist=1, Elementalist=2, Necromancer=3 }, -- Witch
  [4] = { Slayer=1, Gladiator=2, Champion=3 },          -- Duelist
  [5] = { Inquisitor=1, Hierophant=2, Guardian=3 },     -- Templar
  [6] = { Assassin=1, Trickster=2, Saboteur=3 },        -- Shadow
}

handlers.new_build = function(params)
  if not _G.newBuild then
    return { ok = false, error = 'headless wrapper not initialized' }
  end
  _G.newBuild()
  if params and (params.className or params.ascendancy) then
    local classId = 0
    local ascendId = 0
    if params.className then
      classId = CLASS_IDS[params.className] or CLASS_IDS[params.className:lower()] or 0
    end
    if params.ascendancy and ASCENDANCY_IDS[classId] then
      ascendId = ASCENDANCY_IDS[classId][params.ascendancy] or 0
    end
    if build and build.spec then
      build.spec:ImportFromNodeList(classId, ascendId, 0, {}, {}, {})
    end
  end
  return { ok = true }
end

handlers.load_build_xml = function(params)
  if not params or type(params.xml) ~= 'string' then
    return { ok = false, error = 'missing xml' }
  end
  local name = (params.name and tostring(params.name)) or 'API Build'
  if not _G.loadBuildFromXML then
    return { ok = false, error = 'headless wrapper not initialized' }
  end
  _G.loadBuildFromXML(params.xml, name)
  return { ok = true, build_id = 1 }
end

-- 走 PoB 原生 GGG-JSON 匯入（正確處理天賦樹珠寶）。params: { items=<get-items JSON>, passives=<get-passive-skills JSON> }
handlers.load_build_json = function(params)
  if not params or type(params.items) ~= 'string' or type(params.passives) ~= 'string' then
    return { ok = false, error = 'missing items/passives JSON' }
  end
  if not _G.loadBuildFromJSON then
    return { ok = false, error = 'headless wrapper not initialized' }
  end
  _G.loadBuildFromJSON(params.items, params.passives)
  return { ok = true, build_id = 1 }
end

-- 測一批英文詞綴能否被 PoB ModParser 解析（= 是否會被計算）。params: { lines=[string] }
-- 回傳每條 { line, parsed=bool, extra=string|nil }。parsed=true 表 PoB 認得並會套用效果。
handlers.parse_mods = function(params)
  local lines = params and params.lines
  if type(lines) ~= 'table' then return { ok = false, error = 'missing lines' } end
  local modLib = _G.modLib
  if not modLib or not modLib.parseMod then return { ok = false, error = 'modLib.parseMod unavailable' } end
  local out = {}
  for _, line in ipairs(lines) do
    local ok2, modList, extra = pcall(modLib.parseMod, tostring(line))
    -- 三態：nonempty modList=parsed（會計算）；空表 {} + extra=unsupported（PoB 認得但不支援計算）；
    -- modList=nil=unrecognised（沒認出，可能誤譯或非 stat）。
    local status
    if not ok2 or modList == nil then
      status = 'unrecognised'
    elseif type(modList) == 'table' and #modList == 0 then
      status = 'unsupported'
    else
      status = 'parsed'
    end
    table.insert(out, {
      line = line,
      parsed = status == 'parsed',
      status = status,
      extra = (type(extra) == 'string' and extra) or nil,
    })
  end
  return { ok = true, results = out }
end

handlers.get_stats = function(params)
  local fields = params and params.fields or nil
  local stats, err = BuildOps.export_stats(fields)
  if not stats then
    return { ok = false, error = err }
  end
  return { ok = true, stats = stats }
end

handlers.get_items = function(params)
  local list, err = BuildOps.get_items()
  if not list then return { ok = false, error = err } end
  return { ok = true, items = list }
end

handlers.get_skills = function(params)
  local info, err = BuildOps.get_skills()
  if not info then return { ok = false, error = err } end
  return { ok = true, skills = info }
end

handlers.get_tree = function(params)
  local tree, err = BuildOps.get_tree()
  if not tree then
    return { ok = false, error = err }
  end
  return { ok = true, tree = tree }
end

handlers.set_main_selection = function(params)
  local ok2, err = BuildOps.set_main_selection(params or {})
  if not ok2 then return { ok = false, error = err } end
  local skills = BuildOps.get_skills()
  return { ok = true, skills = skills }
end

handlers.set_tree = function(params)
  local ok2, err = BuildOps.set_tree(params or {})
  if not ok2 then
    return { ok = false, error = err }
  end
  local tree = BuildOps.get_tree()
  return { ok = true, tree = tree }
end

handlers.add_item_text = function(params)
  local res, err = BuildOps.add_item_text(params or {})
  if not res then return { ok = false, error = err } end
  return { ok = true, item = res }
end

handlers.export_build_xml = function(params)
  local xml, err = BuildOps.export_build_xml()
  if not xml then return { ok = false, error = err } end
  return { ok = true, xml = xml }
end

handlers.set_level = function(params)
  if not params or params.level == nil then
    return { ok = false, error = 'missing level' }
  end
  local ok2, err = BuildOps.set_level(params.level)
  if not ok2 then return { ok = false, error = err } end
  return { ok = true }
end

handlers.set_flask_active = function(params)
  local ok2, err = BuildOps.set_flask_active(params or {})
  if not ok2 then return { ok = false, error = err } end
  return { ok = true }
end

-- 批次啟用所有有裝備的藥劑欄位（JSON 原生匯入路徑用；預設 active=true）。
handlers.set_all_flasks_active = function(params)
  local ok2, count = BuildOps.set_all_flasks_active(params or {})
  if not ok2 then return { ok = false, error = count } end
  return { ok = true, count = count }
end

handlers.get_build_info = function(params)
  local info, err = BuildOps.get_build_info()
  if not info then return { ok = false, error = err } end
  return { ok = true, info = info }
end

handlers.update_tree_delta = function(params)
  local ok2, err = BuildOps.update_tree_delta(params or {})
  if not ok2 then return { ok = false, error = err } end
  local tree = BuildOps.get_tree()
  return { ok = true, tree = tree }
end

handlers.calc_with = function(params)
  local out, base = BuildOps.calc_with(params or {})
  if not out then return { ok = false, error = base } end
  return { ok = true, output = out }
end

handlers.get_config = function(params)
  local cfg, err = BuildOps.get_config()
  if not cfg then return { ok = false, error = err } end
  return { ok = true, config = cfg }
end

handlers.set_config = function(params)
  local ok2, err = BuildOps.set_config(params or {})
  if not ok2 then return { ok = false, error = err } end
  local cfg = BuildOps.get_config()
  return { ok = true, config = cfg }
end

handlers.create_socket_group = function(params)
  local res, err = BuildOps.create_socket_group(params or {})
  if not res then return { ok = false, error = err or 'failed to create socket group' } end
  return { ok = true, socketGroup = res }
end

handlers.add_gem = function(params)
  local res, err = BuildOps.add_gem(params or {})
  if not res then return { ok = false, error = err or 'failed to add gem' } end
  return { ok = true, gem = res }
end

handlers.set_gem_level = function(params)
  local ok2, err = BuildOps.set_gem_level(params or {})
  if not ok2 then return { ok = false, error = err or 'failed to set gem level' } end
  return { ok = true }
end

handlers.set_gem_quality = function(params)
  local ok2, err = BuildOps.set_gem_quality(params or {})
  if not ok2 then return { ok = false, error = err or 'failed to set gem quality' } end
  return { ok = true }
end

handlers.remove_skill = function(params)
  local ok2, err = BuildOps.remove_skill(params or {})
  if not ok2 then return { ok = false, error = err or 'failed to remove skill' } end
  return { ok = true }
end

handlers.remove_gem = function(params)
  local ok2, err = BuildOps.remove_gem(params or {})
  if not ok2 then return { ok = false, error = err or 'failed to remove gem' } end
  return { ok = true }
end

handlers.search_nodes = function(params)
  local res, err = BuildOps.search_nodes(params or {})
  if not res then return { ok = false, error = err or 'failed to search nodes' } end
  return { ok = true, results = res }
end

handlers.save_build = function(params)
  local res, err = BuildOps.save_build(params or {})
  if not res then return { ok = false, error = err or 'failed to save build' } end
  return { ok = true, result = res }
end

-- 來源查詢：回傳指定 mod 名的各來源貢獻（物品/天賦/技能）。唯讀。
handlers.get_mod_sources = function(params)
  local res, err = BuildOps.get_mod_sources(params and params.mods or {})
  if not res then return { ok = false, error = err } end
  return { ok = true, sources = res }
end

-- 資訊探索：列出 modDB 的 mod 名（可 pattern 過濾）。
handlers.list_mods = function(params)
  local res, err = BuildOps.list_mods(params or {})
  if not res then return { ok = false, error = err } end
  return { ok = true, mods = res }
end

-- 完整輸出：吐 mainOutput 全部可序列化純量欄位。
handlers.get_full_output = function(params)
  local res, err = BuildOps.get_full_output()
  if not res then return { ok = false, error = err } end
  return { ok = true, output = res }
end

-- 推導查詢：回傳指定 stat 的 CALCS breakdown。
handlers.get_breakdown = function(params)
  local res, err = BuildOps.get_breakdown(params and params.stats or {})
  if not res then return { ok = false, error = err } end
  return { ok = true, breakdown = res }
end

-- 匯出 PoB 紋身表（name→sd/targetType），供我方以 sd 比對反查台服紋身的有效英文名。純唯讀、一次性。
-- 需先載入任一 build（tree.tattoo 隨 spec.tree 初始化）。
handlers.get_tattoo_table = function(params)
  if not build or not build.spec or not build.spec.tree or not build.spec.tree.tattoo then
    return { ok = false, error = 'tattoo table unavailable (load a build first)' }
  end
  local out = {}
  for name, node in pairs(build.spec.tree.tattoo.nodes) do
    if type(node) == 'table' and node.sd then
      local sd = {}
      for _, s in ipairs(node.sd) do if type(s) == 'string' then table.insert(sd, s) end end
      table.insert(out, { name = name, sd = sd, targetType = node.targetType, overrideType = node.overrideType })
    end
  end
  return { ok = true, tattoos = out }
end

-- 星團珠寶子圖幾何：匯出 PoB 動態生成的星團節點（座標＋名稱＋stat＋連線＋是否配置），供前端在
-- 天賦樹上疊畫。這些節點 id 在靜態 passive-tree.json 不存在（動態生成，見 hashes_ex），其 x/y 由
-- PoB ProcessNode 以與前端 nodePos 相同的軌道公式算好、同座標空間，故可直接疊在基礎樹上對齊。
handlers.get_cluster_tree = function(params)
  if not build or not build.spec then return { ok = false, error = 'build/spec not initialized' } end
  local spec = build.spec
  local nodes, edges = {}, {}
  local seenEdge = {}
  local function edgeKey(a, b) return a < b and (a .. '_' .. b) or (b .. '_' .. a) end
  if spec.subGraphs then
    for _, sg in pairs(spec.subGraphs) do
      for _, node in ipairs(sg.nodes or {}) do
        if node.id and node.x and node.y then
          -- stat 描述：node.sd 為字串陣列（顯示用）。
          local stats = {}
          if type(node.sd) == 'table' then
            for _, s in ipairs(node.sd) do if type(s) == 'string' then table.insert(stats, s) end end
          end
          table.insert(nodes, {
            id = node.id,
            x = node.x,
            y = node.y,
            name = node.dn,
            stats = stats,
            kind = node.type, -- Notable / Socket / Mastery / Keystone / nil(小天賦)
            alloc = spec.allocNodes[node.id] ~= nil,
          })
          -- 連線：node.linked 為相連節點物件（可能連到基座 socket 這類基礎樹節點）。
          for _, lk in ipairs(node.linked or {}) do
            if lk.id then
              local k = edgeKey(node.id, lk.id)
              if not seenEdge[k] then
                seenEdge[k] = true
                table.insert(edges, { a = node.id, b = lk.id })
              end
            end
          end
        end
      end
    end
  end
  return { ok = true, nodes = nodes, edges = edges }
end

return {
  handlers = handlers,
  version_meta = version_meta,
}
