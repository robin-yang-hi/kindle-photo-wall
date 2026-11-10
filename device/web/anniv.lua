-- ============================================================
-- 纪念日登记网页（Kindle 端，由 tcpsvd 每连接拉起一次）
--   地址:  http://<Kindle IP>:8080/
--   数据:  device/anniversaries.conf（paint2.sh 每帧重读）
--   保存后写一条 cmd=paint，5 秒内重绘屏幕
-- 运行环境: BusyBox tcpsvd + Lua 5.1（设备无 httpd，故用此方案）
-- ============================================================

local DIR   = os.getenv("KPW_DIR") or "/mnt/us/kindle-photo-wall"
local CONF  = DIR .. "/device/anniversaries.conf"
local CMDF  = DIR .. "/device/cmd"
local MAXB  = 40          -- 名称最多字节数（约 13 个汉字）

-- ---------------- 小工具 ----------------
local function url_decode(s)
    if not s then return "" end
    s = s:gsub("+", " ")
    s = s:gsub("%%(%x%x)", function(h) return string.char(tonumber(h, 16)) end)
    return s
end

local function url_encode(s)
    if not s then return "" end
    return (s:gsub("[^%w%-%._~ ]", function(c)
        return string.format("%%%02X", string.byte(c))
    end):gsub(" ", "+"))
end

local function parse_qs(s)
    local t = {}
    if not s or s == "" then return t end
    for pair in s:gmatch("[^&]+") do
        local k, v = pair:match("^([^=]+)=(.*)$")
        if k then
            t[url_decode(k)] = url_decode(v)
        else
            t[url_decode(pair)] = ""
        end
    end
    return t
end

local function esc(s)
    if not s then return "" end
    s = s:gsub("&", "&amp;"):gsub("<", "&lt;"):gsub(">", "&gt;")
    s = s:gsub('"', "&quot;"):gsub("'", "&#39;")
    return s
end

-- 距某天还有几天（负数=已过去）。"MM-DD" 自动跳到今年/明年，
-- 这样每年的生日永远算"下一次"。
local function days_to(dstr)
    local y, m, d
    local y0, m0, d0 = dstr:match("^(%d%d%d%d)%-(%d%d)%-(%d%d)$")
    if y0 then
        y, m, d = tonumber(y0), tonumber(m0), tonumber(d0)
    else
        local mm, dd = dstr:match("^(%d%d)%-(%d%d)$")
        if not mm then return nil end
        m, d = tonumber(mm), tonumber(dd)
        local t = os.date("*t")
        y = t.year
        local cand = os.time({ year = y, month = m, day = d, hour = 12 })
        local now = os.time({ year = t.year, month = t.month, day = t.day, hour = 12 })
        if cand and now and cand < now then y = y + 1 end
    end
    local a = os.time({ year = y, month = m, day = d, hour = 12 })
    local t2 = os.date("*t")
    local b = os.time({ year = t2.year, month = t2.month, day = t2.day, hour = 12 })
    if not a or not b then return nil end
    return math.floor((a - b) / 86400 + 0.5)
end

local function ulen(s)          -- UTF-8 字符数（约等于汉字个数）
    local n = 0
    for _ in s:gmatch("[^\128-\191]") do n = n + 1 end
    return n
end

-- ---------------- 读写 conf ----------------
local function read_lines()
    local f = io.open(CONF, "r")
    if not f then return {} end
    local lines = {}
    for ln in f:lines() do
        ln = ln:gsub("\r$", "")
        lines[#lines + 1] = ln
    end
    f:close()
    return lines
end

local function write_lines(lines)
    local tmp = CONF .. ".new"
    local f = io.open(tmp, "w")
    if not f then return false end
    for _, ln in ipairs(lines) do f:write(ln, "\n") end
    f:close()
    os.remove(CONF)
    return os.rename(tmp, CONF) ~= nil
end

-- ---------------- 农历（农历生日用） ----------------
-- 设备字模只有固定的农历月名/日名，这里与 render/make_v2.py 的 LUNAR_MONTH / LUNAR_DAY 对齐
local LUNAR_M = {"正月", "二月", "三月", "四月", "五月", "六月",
                 "七月", "八月", "九月", "十月", "冬月", "腊月"}
local LUNAR_D = {"初一", "初二", "初三", "初四", "初五", "初六", "初七", "初八", "初九", "初十",
                 "十一", "十二", "十三", "十四", "十五", "十六", "十七", "十八", "十九", "二十",
                 "廿一", "廿二", "廿三", "廿四", "廿五", "廿六", "廿七", "廿八", "廿九", "三十"}

-- "1116" → "冬月十六"
local function lunar_label(key)
    local m, d = tonumber(key:sub(1, 2)), tonumber(key:sub(3, 4))
    if not m or not d or m < 1 or m > 12 or d < 1 or d > 30 then return nil end
    return LUNAR_M[m] .. LUNAR_D[d]
end

-- 农历 key → 下一次公历 "YYYY-MM-DD"（今天及以后，最多往后看三年）
local function lunar_next(key)
    local t = os.date("*t")
    local today = os.time({ year = t.year, month = t.month, day = t.day, hour = 12 })
    local best, bestn
    for off = 0, 2 do
        local fy = t.year + off
        local f = io.open(DIR .. "/assets/lunar/" .. fy .. ".txt", "r")
        if f then
            for line in f:lines() do
                local md, k = line:match("^(%d%d%d%d)|.-|.-|.-|(%S+)$")
                if k == key then
                    local m2, d2 = tonumber(md:sub(1, 2)), tonumber(md:sub(3, 4))
                    local ct = os.time({ year = fy, month = m2, day = d2, hour = 12 })
                    if ct and ct >= today and (not bestn or ct < bestn) then
                        best = string.format("%04d-%02d-%02d", fy, m2, d2)
                        bestn = ct
                    end
                end
            end
            f:close()
        end
    end
    return best
end

-- 解析出「有效条目」：{line=原行号, d=日期串, n=名称, yearly=bool}
local function entries()
    local out = {}
    for i, ln in ipairs(read_lines()) do
        if ln ~= "" and not ln:match("^%s*#") then
            local d, n = ln:match("^%s*(%S+)%s+(.+)$")
            if d then
                out[#out + 1] = { line = i, d = d, n = n:gsub("%s+$", ""),
                                  yearly = (d:match("^%d%d%-%d%d$") ~= nil),
                                  lunar = (d:match("^[Ll]%d%d%-%d%d$") ~= nil) }
            end
        end
    end
    return out
end

-- 保存后让设备立刻重画一帧
local function trigger_repaint()
    local f = io.open(CMDF, "w")
    if f then f:write("paint\n") f:close() end
end

-- ---------------- HTTP ----------------
local function respond(status, body, extra)
    io.write("HTTP/1.1 ", status, "\r\n")
    io.write("Content-Type: text/html; charset=utf-8\r\n")
    io.write("Content-Length: ", #body, "\r\n")
    io.write("Cache-Control: no-store\r\n")
    io.write("Connection: close\r\n")
    if extra then io.write(extra) end
    io.write("\r\n")
    io.write(body)
    io.flush()
end

local function redirect(loc)
    io.write("HTTP/1.1 302 Found\r\nLocation: ", loc, "\r\n")
    io.write("Content-Length: 0\r\nConnection: close\r\n\r\n")
    io.flush()
end

-- ---------------- 页面 ----------------
local CSS = [[
:root{color-scheme:light}
*{box-sizing:border-box}
body{margin:0;padding:18px 16px 44px;background:#f5f5f2;color:#141414;
 font:16px/1.6 -apple-system,BlinkMacSystemFont,"PingFang SC","Microsoft YaHei",sans-serif}
h1{font-size:20px;margin:0 0 4px;letter-spacing:.5px}
.sub{color:#7a7a74;font-size:13px;margin:0 0 16px}
.card{background:#fff;border-radius:14px;padding:16px 16px 18px;margin-bottom:14px;
 box-shadow:0 1px 2px rgba(0,0,0,.06)}
label{display:block;font-size:13px;color:#6b6b66;margin:12px 0 6px}
input[type=text],input[type=date]{width:100%;padding:13px 12px;font-size:16px;color:#141414;
 border:1px solid #dedeD8;border-radius:11px;background:#fbfbf9;-webkit-appearance:none}
input[type=text]:focus,input[type=date]:focus{outline:none;border-color:#141414;background:#fff}
.chk{display:flex;align-items:center;gap:10px;margin:16px 2px 4px;font-size:15px;color:#333}
.chk input{width:20px;height:20px;accent-color:#141414}
button{width:100%;margin-top:18px;padding:15px;font-size:17px;font-weight:600;border:0;
 border-radius:12px;background:#141414;color:#fff}
button:active{opacity:.82}
ul{list-style:none;margin:0;padding:0}
li{display:flex;align-items:center;gap:10px;padding:13px 0;border-bottom:1px solid #efefea}
li:last-child{border-bottom:0}
.dt{font-size:15px;font-weight:600;font-variant-numeric:tabular-nums;color:#141414;min-width:74px}
.nm{flex:1;font-size:16px;word-break:break-all}
.tag{font-size:11px;color:#8a8a84;border:1px solid #e2e2dc;border-radius:6px;padding:1px 5px}
.del{font-size:14px;color:#c0392b;text-decoration:none;padding:6px 4px}
.empty{color:#9a9a94;font-size:14px;padding:6px 0}
.ok{background:#e9f5ea;color:#22592b;padding:11px 13px;border-radius:11px;font-size:14px;margin-bottom:12px}
.hint{color:#8a8a84;font-size:12.5px;line-height:1.7;margin:10px 2px 0}
h2{font-size:14px;color:#6b6b66;font-weight:600;margin:4px 0 2px;letter-spacing:.5px}
]]

local function page(opts)
    opts = opts or {}
    local h = {}
    h[#h + 1] = '<!doctype html><html lang="zh-CN"><head><meta charset="utf-8">'
    h[#h + 1] = '<meta name="viewport" content="width=device-width,initial-scale=1,maximum-scale=1">'
    h[#h + 1] = '<title>Kindle 特殊日子</title><style>' .. CSS .. '</style></head><body>'
    h[#h + 1] = '<h1>特殊日子</h1>'
    h[#h + 1] = '<p class="sub">生日 / 考试 / 答辩 / 考公…保存后 5 秒内上屏，月历上会画出方框</p>'

    if opts.ok then h[#h + 1] = '<div class="ok">' .. esc(opts.ok) .. '</div>' end
    if opts.err then
        h[#h + 1] = '<div class="ok" style="background:#fdecea;color:#8c2b20">' ..
                    esc(opts.err) .. '</div>'
    end

    -- 表单
    h[#h + 1] = '<form class="card" method="post" action="/add">'
    h[#h + 1] = '<label for="n">名称（最多 13 个字）</label>'
    h[#h + 1] = '<input id="n" name="n" type="text" placeholder="答辩 / 考公 / 生日 / 结婚纪念"'
    h[#h + 1] = ' maxlength="13" autocomplete="off" required>'
    h[#h + 1] = '<label for="d">日期</label>'
    h[#h + 1] = '<input id="d" name="d" type="date" required value="' ..
                os.date("%Y-%m-%d") .. '">'
    h[#h + 1] = '<label class="chk"><input type="checkbox" name="y" value="1" checked>'
    h[#h + 1] = '每年重复（生日、结婚纪念这类每年都有的；考试、答辩等一次性日子请取消勾选）</label>'
    h[#h + 1] = '<button type="submit">保存到 Kindle</button>'
    h[#h + 1] = '</form>'

    -- 列表
    local es = entries()
    h[#h + 1] = '<div class="card"><h2>已登记（' .. #es .. ' 条）</h2>'
    if #es == 0 then
        h[#h + 1] = '<p class="empty">还没有，上面填一条试试</p>'
    else
        h[#h + 1] = '<ul>'
        for _, e in ipairs(es) do
            local show = e.d
            local nd = days_to(e.d)
            if e.lunar then
                local key = e.d:sub(2):gsub("-", "")
                local lb = lunar_label(key) or key
                local g = lunar_next(key)
                if g then
                    nd = days_to(g)
                    show = "农历" .. lb .. " 公历" .. g:sub(6)
                else
                    show = "农历" .. lb
                end
            end
            local left = ""
            if nd then
                if nd == 0 then left = "今天"
                elseif nd > 0 then left = nd .. " 天后"
                else left = "已过 " .. (-nd) .. " 天" end
            end
            h[#h + 1] = '<li><span class="dt">' .. esc(show) .. '</span>'
            h[#h + 1] = '<span class="nm">' .. esc(e.n) .. '</span>'
            h[#h + 1] = '<span class="tag">' .. esc(left) .. '</span>'
            h[#h + 1] = '<a class="del" href="/del?ln=' .. e.line ..
                        '" onclick="return confirm(\'删除「' .. esc(e.n) .. '」？\')">删除</a></li>'
        end
        h[#h + 1] = '</ul>'
    end
    h[#h + 1] = '</div>'

    h[#h + 1] = '<p class="hint">同一局域网内打开本页即可，无需密码。' ..
                '名称最多 13 个字，设备字库含 3755 个常用汉字。<br>' ..
                '勾了「每年重复」只存月和日，跨年自动推算下一次；' ..
                '一次性日子（考试、答辩、报名截止）取消勾选，存完整年月日。<br>' ..
                '农历生日这类每年都在变的，直接在 device/anniversaries.conf 里写 L11-16 名称（L=农历，' ..
                '11-16 即冬月十六），勾选框里加不了。<br>' ..
                '月历上的方框：细框=节日，粗底框=你登记的日子。' ..
                '右栏只显示最近的一条，其余的按月会在月历上标出。</p>'
    h[#h + 1] = '</body></html>'
    return table.concat(h)
end

-- ---------------- 动作 ----------------
local function do_add(q)
    local name = (q.n or ""):gsub("^%s+", ""):gsub("%s+$", "")
    local date = q.d or ""
    if name == "" then return redirect("/?err=" .. url_encode("名称不能为空")) end
    if ulen(name) > 13 or #name > MAXB then
        return redirect("/?err=" .. url_encode("名称太长（最多 13 个字）"))
    end
    local y, m, d = date:match("^(%d%d%d%d)%-(%d%d)%-(%d%d)$")
    if not y then return redirect("/?err=" .. url_encode("日期格式不对")) end
    local stamp
    if q.y == "1" then
        stamp = m .. "-" .. d                      -- 每年重复：只存 MM-DD
    else
        stamp = y .. "-" .. m .. "-" .. d
    end
    local f = io.open(CONF, "a")
    if not f then return redirect("/?err=" .. url_encode("写入失败，检查设备存储")) end
    f:write(stamp, " ", name, "\n")
    f:close()
    trigger_repaint()
    redirect("/?ok=" .. url_encode("已保存：" .. stamp .. " " .. name))
end

local function do_del(q)
    local ln = tonumber(q.ln or "")
    if not ln then return redirect("/?err=" .. url_encode("参数错误")) end
    local lines = read_lines()
    if not lines[ln] then return redirect("/?err=" .. url_encode("这条已经不在了")) end
    table.remove(lines, ln)
    if write_lines(lines) then
        trigger_repaint()
        redirect("/?ok=" .. url_encode("已删除"))
    else
        redirect("/?err=" .. url_encode("删除失败"))
    end
end

-- ---------------- 主流程 ----------------
local req = io.read("*l")
if not req then return end
local method, target = req:match("^(%u+)%s+(%S+)")
if not method then return end

local clen = 0
while true do
    local h = io.read("*l")
    if not h or h:gsub("\r", "") == "" then break end
    local k, v = h:match("^([^:]+):%s*(.-)\r?$")
    if k and k:lower() == "content-length" then clen = tonumber(v) or 0 end
end

local body = ""
if clen > 0 then
    while #body < clen do
        local chunk = io.read(clen - #body)
        if not chunk or chunk == "" then break end
        body = body .. chunk
    end
end

local path, qs = target:match("^([^?]*)%??(.*)$")
local q = parse_qs(qs)
if method == "POST" then
    for k, v in pairs(parse_qs(body)) do q[k] = v end
end

if path == "/add" then
    do_add(q)
elseif path == "/del" then
    do_del(q)
else
    respond("200 OK", page({ ok = q.ok, err = q.err }))
end
