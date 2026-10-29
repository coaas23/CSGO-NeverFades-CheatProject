--.name 命中日志
--.author NEVERFADES
--.description 屏幕中央(准星下方)的命中/空枪日志, 无背景; 菜单打开时原地显示预览
--.priority 20

local cfg_enable = ui.new_checkbox( "Lua", "命中日志", "启用命中日志" )
local cfg_pred   = ui.new_checkbox( "Lua", "命中日志", "显示预计伤害" )
local cfg_size   = ui.new_slider( "Lua", "命中日志", "字体大小", 8, 40, 15 )
local cfg_lines  = ui.new_slider( "Lua", "命中日志", "显示行数", 1, 8, 4 )
local cfg_life   = ui.new_slider( "Lua", "命中日志", "停留秒数", 1, 10, 4 )
local cfg_offx   = ui.new_slider( "Lua", "命中日志", "水平偏移", -500, 500, 0 )
local cfg_offy   = ui.new_slider( "Lua", "命中日志", "垂直偏移", -400, 400, 0 )

ui.set( cfg_enable, true )
ui.set( cfg_pred, true )

-- 字体候选: 优先 Windows 的 UI 字形(小字号下笔画最挺), 建不出来就往下退
local FONT_NAMES = { "Microsoft YaHei UI", "微软雅黑", "等线" }
local FF_ANTIALIAS = 8   -- ren::ff_antialias: 灰度抗锯齿, 不用 ClearType(彩边会发虚)

local C_TEXT   = { r = 255, g = 255, b = 255, a = 255 }
local C_GREEN  = { r = 110, g = 235, b = 135, a = 255 }
local C_RED    = { r = 255, g = 90,  b = 90,  a = 255 }
local C_SHADOW = { r = 0,   g = 0,   b = 0,   a = 200 }

local HITGROUP = {
    [ 1 ] = "头部", [ 2 ] = "胸部", [ 3 ] = "腹部",
    [ 4 ] = "左臂", [ 5 ] = "右臂", [ 6 ] = "左腿", [ 7 ] = "右腿",
}

local SOURCE = {
    [ 0 ] = "常规", [ 1 ] = "暴力", [ 2 ] = "穿墙", [ 3 ] = "姿态直读", [ 4 ] = "ML",
}

-- 引擎结算给出的原因(resolver 的 aim_result)
local REASON = {
    [ "spread" ]            = "扩散",
    [ "resolve" ]           = "解析角",
    [ "anti-exploit" ]      = "无回溯",
    [ "extrapolation" ]     = "外推",
    [ "server correction" ] = "服务器修正",
}

local history = {}
local shots = {}

local FONT = render.font_small
local ROW = 16
local cur_size = 0
local font_cache = {}

local function now_ms()
    return utils.get_time_ms and utils.get_time_ms() or 0
end

------------------------------------------------------------------ 字体
-- 按字号缓存: 同一个字号只建一次, 拖动滑条来回改也不会把字体槽位用光(max_fonts=64)
local function build_font( size )
    if font_cache[ size ] ~= nil then return font_cache[ size ] end

    local id = 0
    for _, name in ipairs( FONT_NAMES ) do
        local ok, v = pcall( render.create_font_gdi, name, size, FF_ANTIALIAS, 32, 255 )
        if ok and type( v ) == "number" and v > 0 then
            -- 实测一下能不能出字(建成功但没字形时宽度是 0), 不能就换下一个候选
            local ok_w, w = pcall( render.get_text_size, v, "命中" )
            if ok_w and type( w ) == "number" and w > 0 then
                id = v
                break
            end
        end
    end

    if id == 0 then
        print( string.format( "[命中日志] 字体大小 %d 创建失败, 退回菜单字体", size ) )
    end

    font_cache[ size ] = id
    return id
end

local function measure( line )
    local acc = ""
    for _, seg in ipairs( line.segs ) do
        seg.dx = render.get_text_size( FONT, acc )
        acc = acc .. seg.t
    end
    line.w = render.get_text_size( FONT, acc )
end

local function apply_font()
    local size = math.floor( ( ui.get( cfg_size ) or 15 ) + 0.5 )
    if size == cur_size then return end
    cur_size = size

    local id = build_font( size )
    FONT = ( id and id > 0 ) and id or render.font_small

    -- 字号变了, 之前量好的每段宽度全部作废
    for _, line in ipairs( history ) do line.w = nil end

    local ok, w, h = pcall( render.get_text_size, FONT, "Ag" )
    ROW = ( ok and h ) and ( h + 3 ) or 16
end

------------------------------------------------------------------ 数据
local function player_name( index )
    local ok, pinfo = pcall( client.get_player_info, index )
    local name = ok and pinfo and pinfo.name or "?"
    if type( name ) ~= "string" then name = "?" end
    if #name > 14 then name = name:sub( 1, 14 ) .. "..." end
    return name
end

-- 开火瞬间的现场: 解析信息 / 视角 / 下体, 结算事件里目标可能已经死了或换人了
local function snapshot( ev )
    local info, st = nil, nil

    local ent = entities.get_entity( ev.target )
    if ent then
        local ok, v = pcall( resolver.get_info, ent )
        if ok and type( v ) == "table" then info = v end
    end

    local ok2, v2 = pcall( entity.state, ev.target )
    if ok2 and type( v2 ) == "table" then st = v2 end

    return {
        target    = ev.target,
        hitchance = tonumber( ev.hitchance ) or tonumber( ev.hit_chance ) or 0,
        pred      = tonumber( ev.damage ) or 0,
        backtrack = tonumber( ev.backtrack ) or 0,
        info      = info,
        state     = st,
    }
end

local function side_text( info )
    if not info then return "未知" end
    local left, right = info.left_hits or 0, info.right_hits or 0
    if left == right then return "未知" end
    return left > right and "左" or "右"
end

local function reason_text( ev )
    if ev.no_reg then return "服务器未记录" end
    local raw = ev.reason or ev.result or "spread"
    return REASON[ raw ] or tostring( raw )
end

local function build( ev, hit, snap, name )
    if not snap then
        snap = shots[ ev.id ] or snapshot( ev )
        shots[ ev.id ] = nil
    end

    local col = hit and C_GREEN or C_RED
    local segs = {}
    local function add( t, c ) segs[ #segs + 1 ] = { t = t, c = c } end

    local damage = 0
    if hit then
        damage = math.floor( ( tonumber( ev.damage ) or snap.pred or 0 ) + 0.5 )
    end

    add( hit and "命中 " or "空枪 ", C_TEXT )
    add( name or player_name( snap.target or ev.target ), col )
    add( " 造成 ", C_TEXT )
    add( tostring( damage ), col )
    add( " 伤害", C_TEXT )

    if hit then
        add( " 部位 " .. ( HITGROUP[ ev.hitgroup ] or tostring( ev.hitgroup or "?" ) ), C_TEXT )
    else
        add( " 原因 ", C_TEXT )
        add( reason_text( ev ), col )
    end

    add( " -", C_TEXT )
    add( string.format( " 命中率 %d", math.floor( ( snap.hitchance or 0 ) + 0.5 ) ), C_TEXT )

    if ui.get( cfg_pred ) then
        add( string.format( " 预计伤害 %d", math.floor( ( snap.pred or 0 ) + 0.5 ) ), C_TEXT )
    end

    local info = snap.info or {}
    local st = snap.state or {}

    add( string.format( " 回溯 %d", snap.backtrack or 0 ), C_TEXT )
    add( " 侧向 " .. side_text( snap.info ), C_TEXT )
    add( " 来源 " .. ( SOURCE[ info.source or 0 ] or "常规" ), C_TEXT )
    add( string.format( " 视角 %.0f", st.yaw or 0 ), C_TEXT )
    add( string.format( " 下体 %.0f", st.lby or 0 ), C_TEXT )
    add( string.format( " 解析 %d", info.shots or 0 ), C_TEXT )

    return segs
end

local function emit( segs )
    if not ui.get( cfg_enable ) then return end

    for _, line in ipairs( history ) do line.w = nil end   -- 新行可能改变最大宽度, 统一重算

    history[ #history + 1 ] = { segs = segs, expire = now_ms() + ( ui.get( cfg_life ) or 4 ) * 1000 }

    local max_lines = ui.get( cfg_lines ) or 4
    while #history > max_lines do
        table.remove( history, 1 )
    end
end

------------------------------------------------------------------ 绘制
local function anchor()
    local sw, sh = render.get_screen_size()
    if not sw or not sh then return nil end
    return sw * 0.5 + ( ui.get( cfg_offx ) or 0 ), sh * 0.54 + ( ui.get( cfg_offy ) or 0 )
end

local function draw_segs( segs, y, cx, dim )
    local line = { segs = segs }
    measure( line )

    local x = cx - line.w * 0.5

    -- 全程不透明, 到点直接消失: 不做淡出, 字始终是实的
    for _, seg in ipairs( line.segs ) do
        local sx = x + seg.dx
        if dim then
            render.text( FONT, sx, y, seg.t, { r = seg.c.r, g = seg.c.g, b = seg.c.b, a = 140 }, 0, 0 )
        else
            render.text( FONT, sx + 1, y + 1, seg.t, C_SHADOW, 0, 0 )
            render.text( FONT, sx, y, seg.t, seg.c, 0, 0 )
        end
    end
end

client.set_event_callback( "aim_fire", function( ev )
    if not ui.get( cfg_enable ) or not ev or not ev.id then return end
    shots[ ev.id ] = snapshot( ev )
end )

client.set_event_callback( "aim_hit", function( ev )
    if not ui.get( cfg_enable ) or not ev then return end
    apply_font()
    emit( build( ev, true ) )
end )

client.set_event_callback( "aim_miss", function( ev )
    if not ui.get( cfg_enable ) or not ev then return end
    apply_font()
    emit( build( ev, false ) )
end )

client.set_event_callback( "level_init", function()
    shots = {}
    history = {}
end )

client.set_event_callback( "paint", function()
    if not ui.get( cfg_enable ) then return end

    apply_font()

    local now = now_ms()
    for i = #history, 1, -1 do
        if history[ i ].expire <= now then table.remove( history, i ) end
    end

    if #history == 0 then return end

    local cx, top = anchor()
    if not cx then return end

    for i, line in ipairs( history ) do
        if not line.w then measure( line ) end

        local y = top + ( i - 1 ) * ROW
        local x = cx - line.w * 0.5

        for _, seg in ipairs( line.segs ) do
            local sx = x + seg.dx
            render.text( FONT, sx + 1, y + 1, seg.t, C_SHADOW, 0, 0 )
            render.text( FONT, sx, y, seg.t, seg.c, 0, 0 )
        end
    end
end )

-- 菜单打开时原地画一条示例(半透明), 不用开枪就能对齐位置 —— 和原生按键列表一个思路
ui.preview( function()
    if not ui.get( cfg_enable ) then return end
    if #history > 0 then return end           -- 有真实日志时它自己就在那个位置

    apply_font()

    local cx, top = anchor()
    if not cx then return end

    local sample_snap = {
        target = 0,
        hitchance = 88,
        pred = 470,
        backtrack = 0,
        info = { left_hits = 3, right_hits = 1, source = 3, shots = 342 },
        state = { yaw = -54, lby = -54 },
    }

    draw_segs( build( { hitgroup = 2 }, true, sample_snap, "示例玩家" ), top, cx, true )
end )
