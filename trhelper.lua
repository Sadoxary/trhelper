--[[
* trhelper - Tataru Helper style dialogue translator for FFXI (Ashita v4).
*
* Captures NPC / cutscene dialogue from the incoming chat stream, sends it to
* Google Translate in a hidden background curl.exe process (the game never
* blocks) and shows the translation in an on-screen box.
*
* Ashita font objects only render Latin glyphs and adding ImGui fonts at runtime
* crashes, so the box is drawn with Windows GDI (any system font, full Unicode)
* into a 32-bit TGA and shown through an Ashita primitive. The texture is only
* rebuilt when the displayed text changes.
*
* NPC selection menus (question + options) never reach the chat; while an event is
* active their text is read (read-only) from the game's dialogue buffer and shown,
* translated, in a second box.
*
* Translations are cached in cache_<lang>.txt next to this file; the cache is a
* plain "original<TAB>translation" text file and can be edited by hand.
*
* The addon never sends packets, never writes game memory and never sends input.
--]]

addon.name      = 'trhelper';
addon.author    = 'Sadoxary';
addon.version   = '1.3';
addon.desc      = 'Translates NPC dialogue with Google Translate (Tataru Helper style).';
addon.link      = '';

require 'common';

local chat          = require 'chat';
local imgui         = require 'imgui';
local primitives    = require 'primitives';
local settings      = require 'settings';
local json          = require 'json';
local ffi           = require 'ffi';

pcall(ffi.cdef, [[
int MultiByteToWideChar(uint32_t CodePage, uint32_t dwFlags, const char* lpMultiByteStr, int cbMultiByte, uint16_t* lpWideCharStr, int cchWideChar);
int WideCharToMultiByte(uint32_t CodePage, uint32_t dwFlags, const uint16_t* lpWideCharStr, int cchWideChar, char* lpMultiByteStr, int cbMultiByte, const char* lpDefaultChar, int* lpUsedDefaultChar);
]]);

pcall(ffi.cdef, [[
typedef struct { int32_t left, top, right, bottom; } trh_rect_t;
typedef struct { int32_t cx, cy; } trh_size_t;
typedef struct {
    uint32_t biSize; int32_t biWidth; int32_t biHeight; uint16_t biPlanes; uint16_t biBitCount;
    uint32_t biCompression; uint32_t biSizeImage; int32_t biXPelsPerMeter; int32_t biYPelsPerMeter;
    uint32_t biClrUsed; uint32_t biClrImportant;
} trh_bmi_t;
void* CreateCompatibleDC(void* hdc);
int DeleteDC(void* hdc);
void* CreateDIBSection(void* hdc, const trh_bmi_t* pbmi, uint32_t usage, void** ppvBits, void* hSection, uint32_t offset);
void* SelectObject(void* hdc, void* h);
int DeleteObject(void* h);
void* CreateFontW(int cHeight, int cWidth, int cEscapement, int cOrientation, int cWeight, uint32_t bItalic, uint32_t bUnderline, uint32_t bStrikeOut, uint32_t iCharSet, uint32_t iOutPrecision, uint32_t iClipPrecision, uint32_t iQuality, uint32_t iPitchAndFamily, const uint16_t* pszFaceName);
int SetBkMode(void* hdc, int mode);
uint32_t SetTextColor(void* hdc, uint32_t color);
int DrawTextW(void* hdc, const uint16_t* lpchText, int cchText, trh_rect_t* lprc, uint32_t format);
int GetTextExtentPoint32W(void* hdc, const uint16_t* lpString, int c, trh_size_t* psizl);
int ExcludeClipRect(void* hdc, int left, int top, int right, int bottom);
int SelectClipRgn(void* hdc, void* hrgn);
int GdiFlush(void);
short GetKeyState(int nVirtKey);
]]);

pcall(ffi.cdef, [[uint32_t GetModuleHandleA(const char* lpModuleName);]]);

local CP_SJIS   = 932;
local CP_UTF8   = 65001;

local MAX_ACTIVE_REQUESTS   = 3;
local REQUEST_TIMEOUT       = 20;   -- seconds
local POLL_INTERVAL         = 0.1;  -- seconds
local DUPLICATE_WINDOW      = 3;    -- seconds

-- GDI constants
local DT_WORDBREAK          = 0x0010;
local DT_SINGLELINE         = 0x0020;
local DT_CALCRECT           = 0x0400;
local DT_NOPREFIX           = 0x0800;
local BK_TRANSPARENT        = 1;
local ANTIALIASED_QUALITY   = 4;    -- grayscale AA; ClearType would break the alpha extraction
local DEFAULT_CHARSET       = 1;
local VK_SHIFT              = 0x10;

-- Text colors (GDI COLORREF: 0x00BBGGRR)
local COLOR_TEXT        = 0x00FFFFFF;
local COLOR_SPEAKER     = 0x0073D1FF;
local COLOR_PENDING     = 0x00A8A8A8;
local COLOR_ERROR       = 0x008080FF;
local COLOR_ORIGINAL    = 0x009A9A9A;
local COLOR_OPTION      = 0x00FFD8A0;

-- NPC menu (question + options) text buffer inside FFXiMain.dll (read-only).
-- Format: question 07 0B option 07 option ... 7F 31 00. The text stays after the menu
-- closes, so it is only used while the event system is active.
local MENU_TEXT_OFFSET  = 0x489109;
local MENU_TEXT_MAX     = 0x800;
local MENU_POLL         = 0.2;      -- seconds
local MENU_MARKER       = '\7\11';  -- 0x07 0x0B: end of question, start of the option list

-- Default Settings
local default_settings = T{
    enabled         = true,
    source_lang     = 'auto',
    target_lang     = 'ru',
    -- Chat modes (low byte) that are translated. 150/151 = NPC conversation / cutscene dialogue.
    modes           = T{ 150, 151 },
    history         = 3,        -- how many dialogue entries are kept on screen
    hide_after      = 20,       -- seconds without new dialogue before the box clears (0 = never)
    show_original   = false,
    newest_on_top   = false,    -- false: new lines at the bottom (old ones scroll up); true: new lines at the top
    debug          = false,    -- logs every incoming line with its mode to debug.log
    menu_enabled    = true,     -- translate NPC menu question + options in a separate box
    menu_window_name = '',      -- game menu name of the selection window (learned automatically)

    ui = T{
        font_family = 'Arial',
        font_size   = 20,       -- pixels
        bold        = false,
        width       = 700,      -- box width in pixels
        padding     = 10,
        bg_alpha    = 0.7,
        pos_x       = 300,
        pos_y       = 900,      -- bottom edge when grow_up is on, top edge otherwise
        grow_up     = true,     -- keep the bottom edge fixed so the box grows upwards
        menu_x      = 1100,     -- NPC menu box, left edge
        menu_anchor_y = 850,    -- NPC menu box: bottom edge when grow_up is on, top edge otherwise
    },
};

--[[
* Fills keys missing from a loaded settings file (the settings lib does not merge defaults).
--]]
local function apply_defaults(s)
    for k, v in pairs(default_settings) do
        if (s[k] == nil) then
            s[k] = type(v) == 'table' and v:copy(true) or v;
        end
    end
    for k, v in pairs(default_settings.ui) do
        if (s.ui[k] == nil) then
            s.ui[k] = v;
        end
    end
    return s;
end

-- Addon State
local tr = T{
    settings    = apply_defaults(settings.load(default_settings)),
    prim        = nil,      -- primitive showing the rendered texture
    texture     = nil,      -- current texture file
    tex_id      = 0,
    box_h       = 0,        -- visible box height (for dragging)
    shown       = true,
    dirty       = true,

    base_dir    = nil,
    tmp_dir     = nil,

    cache       = T{ },     -- original -> translation
    waiting     = T{ },     -- original -> list of entries awaiting that translation
    queue       = T{ },     -- originals waiting for a free request slot
    active      = T{ },     -- id -> request job
    next_id     = 0,
    last_poll   = 0,

    entries     = T{ },     -- on-screen dialogue entries

    last_text   = nil,
    last_time   = 0,
    activity    = 0,        -- os.clock() of the last new line / finished translation
    last_render = 0,
    drag        = nil,      -- active mouse drag (move or width)
    config_open = { false }, -- settings window visibility (ImGui p_open)
    config_bufs = { },
    config_changed = false,

    -- NPC menu box
    menu_box    = { prim = nil, texture = nil, box_h = 0 },
    menu        = nil,      -- { question = entry, options = { entry, ... } } while a menu is open
    menu_raw    = nil,      -- raw buffer text of the current menu
    menu_addr   = 0,
    menu_poll   = 0,
    menu_hidden = false,    -- menu text still in the buffer but the menu is no longer on screen
    menu_name   = nil,      -- last seen game menu name
    menu_stale  = nil,      -- buffer text left over from an earlier conversation
    menu_line_hidden = false, -- hidden by the next NPC line (used until the menu name is learned)
    was_active  = false,
    learn_until = nil,
    learn_name  = nil,
    learn_valid = false,
    menu_name_changed_at = -10,
    menu_visible_since = 0,
};

--[[
* Encoding helpers
--]]
local function convert(str, from_cp, to_cp)
    if (str == nil or #str == 0) then
        return '';
    end

    local wlen = ffi.C.MultiByteToWideChar(from_cp, 0, str, #str, nil, 0);
    if (wlen <= 0) then
        return str;
    end
    local wbuf = ffi.new('uint16_t[?]', wlen);
    ffi.C.MultiByteToWideChar(from_cp, 0, str, #str, wbuf, wlen);

    local len = ffi.C.WideCharToMultiByte(to_cp, 0, wbuf, wlen, nil, 0, nil, nil);
    if (len <= 0) then
        return str;
    end
    local buf = ffi.new('char[?]', len);
    ffi.C.WideCharToMultiByte(to_cp, 0, wbuf, wlen, buf, len, nil, nil);
    return ffi.string(buf, len);
end

local function to_wide(s)
    local n = ffi.C.MultiByteToWideChar(CP_UTF8, 0, s, #s, nil, 0);
    local buf = ffi.new('uint16_t[?]', n + 1);
    if (n > 0) then
        ffi.C.MultiByteToWideChar(CP_UTF8, 0, s, #s, buf, n);
    end
    return buf, n;
end

local function utf8_len(s)
    local _, n = s:gsub('[^\128-\191]', '');
    return n;
end

--[[
* Converts a raw FFXI chat line into clean UTF-8 text.
--]]
local function clean_message(raw)
    local msg = AshitaCore:GetChatManager():ParseAutoTranslate(raw, true);
    msg = msg:gsub('[\30\31\127].', '');        -- color codes and the dialogue prompt marker
    msg = msg:gsub('\239[\39\40]', '');         -- leftover auto-translate braces
    msg = msg:gsub('[%z\1-\31]', ' ');          -- line breaks (0x07, \n) and other control bytes
    msg = convert(msg, CP_SJIS, CP_UTF8);
    msg = msg:gsub('%s+', ' '):gsub('^%s+', ''):gsub('%s+$', '');
    return msg;
end

--[[
* Files / paths
--]]
local function cache_path()
    return ('%s\\cache_%s.txt'):fmt(tr.base_dir, tr.settings.target_lang);
end

local function debug_log(line)
    local f = io.open(tr.base_dir .. '\\debug.log', 'ab');
    if (f ~= nil) then
        f:write(os.date('[%H:%M:%S] ') .. line .. '\n');
        f:close();
    end
end

local function load_cache()
    tr.cache = T{ };
    local f = io.open(cache_path(), 'rb');
    if (f == nil) then
        return;
    end
    for line in f:lines() do
        local k, v = line:gsub('\r$', ''):match('^(.-)\t(.*)$');
        if (k ~= nil and #k > 0 and #v > 0) then
            tr.cache[k] = v;
        end
    end
    f:close();
end

local function save_cache_entry(orig, text)
    local f = io.open(cache_path(), 'ab');
    if (f ~= nil) then
        f:write(orig:gsub('[\t\r\n]', ' ') .. '\t' .. text:gsub('[\t\r\n]', ' ') .. '\n');
        f:close();
    end
end

local function remove_file(path)
    if (path ~= nil and ashita.fs.exists(path)) then
        pcall(ashita.fs.remove, path);
    end
end

local function clean_tmp_dir()
    if (not ashita.fs.exists(tr.tmp_dir)) then
        ashita.fs.create_directory(tr.tmp_dir);
        return;
    end
    local ok, files = pcall(ashita.fs.get_directory, tr.tmp_dir, '.*', false);
    if (ok and type(files) == 'table') then
        for _, name in pairs(files) do
            remove_file(tr.tmp_dir .. '\\' .. name);
        end
    end
end

--[[
* Rendering (GDI -> TGA -> primitive)
--]]
-- With grow_up the stored pos_y is the bottom edge, so the box grows upwards as lines are added.
local function box_top()
    local ui = tr.settings.ui;
    return math.max(0, ui.grow_up and (ui.pos_y - tr.box_h) or ui.pos_y);
end

-- Same for the NPC menu box (menu_anchor_y).
local function menu_top()
    local ui = tr.settings.ui;
    return math.max(0, ui.grow_up and (ui.menu_anchor_y - tr.menu_box.box_h) or ui.menu_anchor_y);
end

-- Switches the anchor edge without moving the boxes on screen.
local function set_grow_up(on)
    local ui = tr.settings.ui;
    if ((ui.grow_up == true) == on) then
        return;
    end
    local sign = on and 1 or -1;
    ui.pos_y         = ui.pos_y + sign * tr.box_h;
    ui.menu_anchor_y = ui.menu_anchor_y + sign * tr.menu_box.box_h;
    ui.grow_up       = on;
    tr.dirty         = true;
end

local function next_pow2(n)
    local p = 1;
    while (p < n) do
        p = p * 2;
    end
    return p;
end

-- Shown while the settings window is open and nothing else is on screen.
local PREVIEW_ENTRIES = {
    { speaker = 'Apururu', orig = 'Hee-hee.', text = 'Хи-хи. Мы, Тарутару, очень гордимся своими головными уборами.', state = 'done' },
    { speaker = 'Pojimo-Rojimo', orig = 'Welcome to the magical city of Windurst!', text = 'Добро пожаловать в волшебный город Виндерст!', state = 'done' },
    { speaker = 'Maat', orig = 'You are not ready yet.', state = 'pending' },
};

local function display_entries()
    if (#tr.entries == 0 and tr.config_open[1]) then
        return PREVIEW_ENTRIES;
    end
    return tr.entries;
end

local function build_blocks()
    local blocks  = T{ };
    local entries = display_entries();
    local n = #entries;
    for i = 1, n do
        local e   = entries[tr.settings.newest_on_top and (n - i + 1) or i];
        local gap = i > 1 and 6 or 0;
        local body, color;
        if (e.state == 'pending') then
            body, color = '... ' .. e.orig, COLOR_PENDING;
        elseif (e.state == 'error') then
            body, color = '[!] ' .. e.orig, COLOR_ERROR;
        else
            body, color = e.text, COLOR_TEXT;
        end

        local speaker = e.speaker ~= nil and (e.speaker .. ':') or nil;
        blocks:append(T{
            speaker = speaker,
            full    = speaker ~= nil and (speaker .. ' ' .. body) or body,
            color   = color,
            gap     = gap,
        });

        if (tr.settings.show_original and e.state == 'done') then
            blocks:append(T{ full = e.orig, color = COLOR_ORIGINAL, gap = 0 });
        end
    end
    return blocks;
end

-- Builds the 32-bit BGRA image; returns the pixel string (bottom-up rows), width, height and box height.
local function draw_image(blocks)
    local ui     = tr.settings.ui;
    local pad    = ui.padding;
    local box_w  = math.max(100, ui.width);
    local text_w = box_w - pad * 2;
    local C      = ffi.C;

    local hdc = C.CreateCompatibleDC(nil);
    if (hdc == nil) then
        return nil;
    end
    local hfont = C.CreateFontW(-ui.font_size, 0, 0, 0, ui.bold and 700 or 400, 0, 0, 0,
        DEFAULT_CHARSET, 0, 0, ANTIALIASED_QUALITY, 0, (to_wide(ui.font_family)));
    local old_font = C.SelectObject(hdc, hfont);
    C.SetBkMode(hdc, BK_TRANSPARENT);

    -- Measure every block with word wrapping..
    local rc = ffi.new('trh_rect_t');
    local y  = pad;
    for _, b in ipairs(blocks) do
        b.wtext, b.wlen = to_wide(b.full);
        rc.left, rc.top, rc.right, rc.bottom = 0, 0, text_w, 0;
        C.DrawTextW(hdc, b.wtext, b.wlen, rc, DT_CALCRECT + DT_WORDBREAK + DT_NOPREFIX);
        b.y = y + b.gap;
        b.h = rc.bottom;
        y   = b.y + b.h;
    end
    local box_h = y + pad;
    local W, H  = next_pow2(box_w), next_pow2(box_h);

    local bmi = ffi.new('trh_bmi_t');
    bmi.biSize      = ffi.sizeof('trh_bmi_t');
    bmi.biWidth     = W;
    bmi.biHeight    = H;    -- positive = bottom-up rows, same as a default TGA
    bmi.biPlanes    = 1;
    bmi.biBitCount  = 32;
    local bits = ffi.new('void*[1]');
    local hbmp = C.CreateDIBSection(hdc, bmi, 0, bits, nil, 0);
    if (hbmp == nil or bits[0] == nil) then
        C.SelectObject(hdc, old_font);
        C.DeleteObject(hfont);
        C.DeleteDC(hdc);
        return nil;
    end
    local old_bmp = C.SelectObject(hdc, hbmp);

    -- Draw the text on black; the speaker name is drawn first and clipped out of the body pass..
    local size = ffi.new('trh_size_t');
    for _, b in ipairs(blocks) do
        rc.left, rc.top, rc.right, rc.bottom = pad, b.y, pad + text_w, b.y + b.h;
        if (b.speaker ~= nil) then
            local sw, sl = to_wide(b.speaker);
            C.SetTextColor(hdc, COLOR_SPEAKER);
            C.DrawTextW(hdc, sw, sl, rc, DT_SINGLELINE + DT_NOPREFIX);
            C.GetTextExtentPoint32W(hdc, sw, sl, size);
            C.ExcludeClipRect(hdc, pad, b.y, pad + size.cx, b.y + size.cy);
        end
        C.SetTextColor(hdc, b.color);
        C.DrawTextW(hdc, b.wtext, b.wlen, rc, DT_WORDBREAK + DT_NOPREFIX);
        if (b.speaker ~= nil) then
            C.SelectClipRgn(hdc, nil);
        end
    end
    C.GdiFlush();

    -- Turn "text on black" into text over a translucent background with real alpha..
    local px   = ffi.cast('uint8_t*', bits[0]);
    local bg_a = math.floor(math.max(0, math.min(1, ui.bg_alpha)) * 255);
    local max, min, floor = math.max, math.min, math.floor;
    for row = 0, H - 1 do
        local inside_y = (H - 1 - row) < box_h;
        local base = row * W * 4;
        for x = 0, W - 1 do
            local i = base + x * 4;
            if (inside_y and x < box_w) then
                local b_, g_, r_ = px[i], px[i + 1], px[i + 2];
                local t = max(r_, g_, b_);
                if (t == 0) then
                    px[i + 3] = bg_a;
                else
                    local out_a = t + bg_a * (255 - t) / 255;
                    local k = 255 / out_a;
                    px[i]     = min(255, floor(b_ * k));
                    px[i + 1] = min(255, floor(g_ * k));
                    px[i + 2] = min(255, floor(r_ * k));
                    px[i + 3] = floor(out_a);
                end
            else
                px[i], px[i + 1], px[i + 2], px[i + 3] = 0, 0, 0, 0;
            end
        end
    end
    local data = ffi.string(px, W * H * 4);

    C.SelectObject(hdc, old_bmp);
    C.DeleteObject(hbmp);
    C.SelectObject(hdc, old_font);
    C.DeleteObject(hfont);
    C.DeleteDC(hdc);

    return data, W, H, box_h;
end

-- Shown in the menu box while the settings window is open and no menu is active.
local MENU_PREVIEW = {
    question = { orig = 'What is your business?', text = 'Чем могу помочь?', state = 'done' },
    options  = {
        { orig = 'Would you cast Signet on me?', text = 'Не могли бы вы наложить на меня Signet?', state = 'done' },
        { orig = 'Nothing, sorry to bother you.', state = 'pending' },
    },
};

local function entry_body(e)
    if (e.state == 'pending') then
        return '... ' .. e.orig, COLOR_PENDING;
    elseif (e.state == 'error') then
        return '[!] ' .. e.orig, COLOR_ERROR;
    end
    return e.text, nil;
end

local function build_menu_blocks()
    local m = (not tr.menu_hidden) and tr.menu or nil;
    if (m == nil and tr.config_open[1]) then
        m = MENU_PREVIEW;
    end
    if (m == nil) then
        return nil;
    end

    local blocks = T{ };
    if (m.question ~= nil) then
        local body, color = entry_body(m.question);
        blocks:append(T{ full = body, color = color or COLOR_TEXT, gap = 0 });
    end
    for i, o in ipairs(m.options) do
        local body, color = entry_body(o);
        blocks:append(T{ full = ('%d. %s'):fmt(i, body), color = color or COLOR_OPTION, gap = (i == 1 and #blocks > 0) and 6 or 2 });
    end
    return blocks;
end

-- Draws blocks into a new TGA texture on prim. Returns the visible box height, or nil on failure.
local function paint(prim, state, blocks, place)
    local ok, data, W, H, box_h = pcall(draw_image, blocks);
    if (not ok or data == nil) then
        if (not ok) then
            print(chat.header(addon.name):append(chat.error('Render failed: ' .. tostring(data))));
        end
        prim.visible = false;
        return nil;
    end

    -- Uncompressed 32-bit TGA, bottom-left origin, 8 alpha bits.
    tr.tex_id = tr.tex_id + 1;
    local path = ('%s\\box_%d.tga'):fmt(tr.tmp_dir, tr.tex_id);
    local f = io.open(path, 'wb');
    if (f == nil) then
        return nil;
    end
    f:write(string.char(0, 0, 2, 0, 0, 0, 0, 0, 0, 0, 0, 0,
        W % 256, math.floor(W / 256), H % 256, math.floor(H / 256), 32, 8));
    f:write(data);
    f:close();

    state.box_h     = box_h;
    prim.texture    = path;
    prim.width      = W;
    prim.height     = H;
    prim.position_x, prim.position_y = place();
    prim.visible    = true;

    remove_file(state.texture);
    state.texture = path;
    return box_h;
end

local function render()
    tr.dirty = false;
    local ui = tr.settings.ui;

    if (tr.prim ~= nil) then
        if (not tr.shown or #display_entries() == 0) then
            tr.prim.visible = false;
        else
            paint(tr.prim, tr, build_blocks(), function () return ui.pos_x, box_top(); end);
        end
    end

    local mb = tr.menu_box;
    if (mb.prim ~= nil) then
        local blocks = (tr.shown and tr.settings.menu_enabled) and build_menu_blocks() or nil;
        if (blocks == nil) then
            mb.prim.visible = false;
        else
            paint(mb.prim, mb, blocks, function () return ui.menu_x, menu_top(); end);
        end
    end
end

local function add_entry(entry)
    tr.entries:append(entry);
    while (#tr.entries > math.max(1, tr.settings.history)) do
        tr.entries:remove(1);
    end
    tr.activity = os.clock();
    tr.dirty = true;
end

--[[
* Translation requests
*
* Each request runs "cmd /c curl ... && move" hidden via ShellExecute. The result
* file only appears after curl has fully finished, so polling for it is safe.
--]]
local function start_request(orig)
    tr.next_id = tr.next_id + 1;
    local id   = tr.next_id;
    local job  = T{
        orig    = orig,
        started = os.time(),
        req     = ('%s\\req_%d.txt'):fmt(tr.tmp_dir, id),
        part    = ('%s\\res_%d.part'):fmt(tr.tmp_dir, id),
        done    = ('%s\\res_%d.json'):fmt(tr.tmp_dir, id),
        err     = ('%s\\res_%d.err'):fmt(tr.tmp_dir, id),
    };

    local f = io.open(job.req, 'wb');
    if (f == nil) then
        return false;
    end
    f:write(orig);
    f:close();

    -- The Chrome extension endpoint; translate.googleapis.com (client=gtx) answers 429 for many IPs.
    local cmd = ('curl.exe -s -f -G --max-time 15 -A "Mozilla/5.0" "https://clients5.google.com/translate_a/t"'
        .. ' -d client=dict-chrome-ex -d sl=%s -d tl=%s --data-urlencode "q@%s" -o "%s"'
        .. ' && move /y "%s" "%s" >nul || echo fail>"%s"'):fmt(
            tr.settings.source_lang, tr.settings.target_lang, job.req, job.part, job.part, job.done, job.err);

    ashita.misc.execute(os.getenv('ComSpec') or 'cmd.exe', '/s /c "' .. cmd .. '"', 0);
    tr.active[id] = job;
    return true;
end

local function parse_response(data)
    -- Response is ["text"] for a fixed source language or [["text","en"]] for sl=auto.
    local ok, res = pcall(json.decode, data);
    if (not ok or type(res) ~= 'table') then
        return nil;
    end
    local text = res[1];
    if (type(text) == 'table') then
        text = text[1];
    end
    if (type(text) ~= 'string' or #text == 0) then
        return nil;
    end
    text = text:gsub('%s+', ' '):gsub('^%s+', ''):gsub('%s+$', '');
    return text;
end

local function finish_translation(orig, text)
    if (text ~= nil) then
        tr.cache[orig] = text;
        save_cache_entry(orig, text);
    end
    local list = tr.waiting[orig];
    tr.waiting[orig] = nil;
    if (list ~= nil) then
        for _, e in ipairs(list) do
            e.text  = text;
            e.state = text ~= nil and 'done' or 'error';
        end
    end
    tr.activity = os.clock();
    tr.dirty = true;
end

local function request_translation(entry)
    local cached = tr.cache[entry.orig];
    if (cached ~= nil) then
        entry.text  = cached;
        entry.state = 'done';
        return;
    end

    entry.state = 'pending';
    local list = tr.waiting[entry.orig];
    if (list ~= nil) then
        list:append(entry);
        return;
    end
    tr.waiting[entry.orig] = T{ entry };
    tr.queue:append(entry.orig);
end

local function poll_requests()
    local now = os.time();
    for id, job in pairs(tr.active) do
        if (ashita.fs.exists(job.done)) then
            local data = nil;
            local f = io.open(job.done, 'rb');
            if (f ~= nil) then
                data = f:read('*a');
                f:close();
            end
            tr.active[id] = nil;
            remove_file(job.req);
            remove_file(job.done);
            finish_translation(job.orig, data and parse_response(data));
        elseif (ashita.fs.exists(job.err) or now - job.started > REQUEST_TIMEOUT) then
            tr.active[id] = nil;
            remove_file(job.req);
            remove_file(job.part);
            remove_file(job.err);
            finish_translation(job.orig, nil);
        end
    end

    local count = 0;
    for _ in pairs(tr.active) do
        count = count + 1;
    end
    while (count < MAX_ACTIVE_REQUESTS and #tr.queue > 0) do
        local orig = tr.queue:remove(1);
        if (start_request(orig)) then
            count = count + 1;
        else
            finish_translation(orig, nil);
        end
    end
end

--[[
* Handles a clean UTF-8 dialogue line.
--]]
local function has_mode(mode)
    for _, v in pairs(tr.settings.modes) do
        if (tonumber(v) == mode) then
            return true;
        end
    end
    return false;
end

local function modes_string()
    local out = { };
    for _, v in pairs(tr.settings.modes) do
        out[#out + 1] = tostring(v);
    end
    return table.concat(out, ', ');
end

local function handle_line(text)
    if (text == nil or not text:find('%a')) then
        return;
    end

    -- A new NPC line after a menu means an option was picked: hide the menu box.
    if (tr.menu ~= nil and not tr.menu_hidden and os.clock() - tr.menu_visible_since > 0.5) then
        tr.menu_line_hidden = true;
        tr.menu_hidden = true;
        tr.dirty = true;
    end

    local now = os.time();
    if (text == tr.last_text and now - tr.last_time <= DUPLICATE_WINDOW) then
        return;
    end
    tr.last_text = text;
    tr.last_time = now;

    -- NPC lines look like "Name : text"; keep the name untranslated.
    local speaker, body = text:match('^([^:]+) : (.+)$');
    if (speaker == nil or utf8_len(speaker) > 40) then
        speaker, body = nil, text;
    end

    -- A repeated line moves to the bottom instead of showing twice; older lines scroll up.
    for i = #tr.entries, 1, -1 do
        local e = tr.entries[i];
        if (e.orig == body and e.speaker == speaker) then
            tr.entries:remove(i);
        end
    end

    local entry = T{ speaker = speaker, orig = body, text = nil, state = 'pending' };
    request_translation(entry);
    add_entry(entry);
end

--[[
* NPC menu (question + options)
*
* The menu text never reaches the chat, so it is read from the game's dialogue buffer
* while the event system is active (signature from XIUI's gamestate.lua).
--]]
local pEventSystem = ashita.memory.find('FFXiMain.dll', 0, 'A0????????84C0741AA1????????85C0741166A1????????663B05????????0F94C0C3', 0, 0);

local function event_active()
    if (pEventSystem == nil or pEventSystem == 0) then
        return false;
    end
    local ptr = ashita.memory.read_uint32(pEventSystem + 1);
    if (ptr == 0) then
        return false;
    end
    return ashita.memory.read_uint8(ptr) == 1;
end

local function read_menu_raw()
    if (tr.menu_addr == 0 or not event_active()) then
        return nil;
    end
    local raw = ffi.string(ffi.cast('const char*', tr.menu_addr), MENU_TEXT_MAX);
    raw = raw:match('^([^%z]*)');
    if (raw == nil or not raw:find(MENU_MARKER, 1, true)) then
        return nil;
    end
    return raw;
end

local function menu_entry(raw_part)
    local text = clean_message(raw_part);
    if (text == '') then
        return nil;
    end
    local e = T{ orig = text, text = nil, state = 'pending' };
    request_translation(e);
    return e;
end

-- Current game menu name (signature from XIUI's gamestate.lua). Changes when a selection menu opens / closes.
local pGameMenu = ashita.memory.find('FFXiMain.dll', 0, '8B480C85C974??8B510885D274??3B05', 16, 0);

local function get_menu_name()
    if (pGameMenu == nil or pGameMenu == 0) then
        return '';
    end
    local sub = ashita.memory.read_uint32(pGameMenu);
    if (sub == 0) then
        return '';
    end
    local value = ashita.memory.read_uint32(sub);
    if (value == 0) then
        return '';
    end
    local header = ashita.memory.read_uint32(value + 4);
    if (header == 0) then
        return '';
    end
    return (ashita.memory.read_string(header + 0x46, 16):gsub('%z', ''));
end

--[[
* Menu box visibility. The buffer keeps its text after the menu closes, even into later
* conversations, so:
*  - text already in the buffer when a conversation starts is stale and ignored;
*  - when a fresh menu appears, the game menu name that opens with it is learned and
*    saved (settings.menu_window_name); from then on the box is shown exactly while that
*    game menu is open (this also covers reopening an identical menu);
*  - until a name is learned, the next NPC line hides the box (handle_line).
--]]
local function build_menu(raw)
    local pos  = raw:find(MENU_MARKER, 1, true);
    local menu = { question = menu_entry(raw:sub(1, pos - 1)), options = { } };
    for part in (raw:sub(pos + #MENU_MARKER) .. '\7'):gmatch('(.-)\7') do
        local e = menu_entry(part);
        if (e ~= nil) then
            menu.options[#menu.options + 1] = e;
        end
    end
    return menu;
end

local function poll_menu()
    local s      = tr.settings;
    local now    = os.clock();
    local active = event_active();
    local raw    = (s.menu_enabled and active) and read_menu_raw() or nil;
    local name   = get_menu_name();

    if (name ~= tr.menu_name) then
        if (s.debug) then
            debug_log(('[menu name] "%s" -> "%s"'):fmt(tostring(tr.menu_name), name));
        end
        tr.menu_name = name;
        tr.menu_name_changed_at = now;
        if (tr.learn_until ~= nil and now < tr.learn_until) then
            tr.learn_name  = name;
            tr.learn_valid = true;
        end
    end

    -- New conversation: whatever menu text is in the buffer now belongs to an earlier one.
    if (active and not tr.was_active) then
        tr.menu_stale = raw;
    end
    tr.was_active = active;

    if (raw ~= tr.menu_raw) then
        tr.menu_raw = raw;
        tr.menu     = raw ~= nil and build_menu(raw) or nil;
        tr.dirty    = true;
        if (raw ~= nil and raw ~= tr.menu_stale) then
            tr.menu_stale         = nil;
            tr.menu_line_hidden   = false;
            tr.menu_visible_since = now;
            -- Learn the game menu name if it changed around the moment the text appeared.
            tr.learn_until = now + 1.0;
            tr.learn_name  = name;
            tr.learn_valid = (now - (tr.menu_name_changed_at or -10)) < 1.0;
            if (s.debug) then
                debug_log('[menu] ' .. clean_message((raw:gsub('\7', ' | '))));
            end
        end
    end

    if (tr.learn_until ~= nil and now >= tr.learn_until) then
        if (tr.learn_valid and tr.learn_name ~= nil and tr.learn_name ~= '' and s.menu_window_name ~= tr.learn_name) then
            s.menu_window_name = tr.learn_name;
            settings.save();
            if (s.debug) then
                debug_log(('[menu name] learned "%s"'):fmt(tr.learn_name));
            end
        end
        tr.learn_until = nil;
    end

    local learned = s.menu_window_name or '';
    local visible;
    if (raw == nil) then
        visible = false;
    elseif (learned ~= '') then
        visible = (name == learned);
    else
        visible = (raw ~= tr.menu_stale) and not tr.menu_line_hidden;
    end

    if (visible and tr.menu_hidden) then
        tr.menu_visible_since = now;
    end
    if (tr.menu_hidden == visible) then
        tr.menu_hidden = not visible;
        tr.dirty = true;
    end
end

--[[
* Settings
--]]
local function update_settings(s)
    if (s ~= nil) then
        tr.settings = apply_defaults(s);
    end
    if (tr.base_dir ~= nil) then
        load_cache();
    end
    tr.dirty = true;
    settings.save();
end

settings.register('settings', 'settings_update', update_settings);

--[[
* Help
--]]
local function msg(text)
    print(chat.header(addon.name):append(chat.message(text)));
end

local function print_help(isError)
    if (isError) then
        print(chat.header(addon.name):append(chat.error('Invalid command syntax for command: ')):append(chat.success('/tr')));
    else
        print(chat.header(addon.name):append(chat.message('Available commands:')));
    end

    local cmds = T{
        { '/tr', 'Opens / closes the settings window.' },
        { '/tr box', 'Shows / hides the translation box.' },
        { '/tr top', 'Toggles new lines at the top / bottom of the box.' },
        { '/tr grow', 'Toggles growing upward (fixed bottom edge) / downward.' },
        { '/tr menu', 'Toggles translation of NPC menu options (separate box).' },
        { '/tr menu relearn', 'Forgets the learned NPC menu window name.' },
        { '/tr (on | off)', 'Enables / disables translation.' },
        { '/tr lang <code>', 'Target language (ru, uk, de, ...).' },
        { '/tr src <code>', 'Source language (auto, en, ja).' },
        { '/tr orig', 'Toggles showing the original text under the translation.' },
        { '/tr lines <n>', 'How many dialogue entries stay on screen.' },
        { '/tr hide <sec>', 'Clears the box after <sec> seconds without dialogue (0 = never).' },
        { '/tr width <px>', 'Box width in pixels.' },
        { '/tr size <px>', 'Font size in pixels.' },
        { '/tr alpha <0-100>', 'Background opacity.' },
        { '/tr font <family>', 'Font family (Arial, Tahoma, Segoe UI, ...).' },
        { '/tr bold', 'Toggles bold text.' },
        { '/tr pos <x> <y>', 'Box position. Mouse: drag = move, Shift+drag = width, Shift+wheel = font size.' },
        { '/tr modes', 'Lists translated chat modes.' },
        { '/tr mode (add | del) <id>', 'Adds / removes a chat mode.' },
        { '/tr debug', 'Toggles logging of every chat line and its mode to debug.log.' },
        { '/tr test <text>', 'Translates the given text (pipeline check).' },
        { '/tr clear', 'Clears the translation box.' },
        { '/tr (reload | reset)', 'Reloads / resets settings.' },
    };
    cmds:ieach(function (v)
        print(chat.header(addon.name):append(chat.error('Usage: ')):append(chat.message(v[1]):append(' - ')):append(chat.color1(6, v[2])));
    end);
end

--[[
* event: load
--]]
ashita.events.register('load', 'load_cb', function ()
    tr.base_dir = addon.path:gsub('[\\/]+$', '');
    tr.tmp_dir  = tr.base_dir .. '\\tmp';
    clean_tmp_dir();
    load_cache();
    tr.prim = primitives.new({
        visible     = false,
        locked      = true,     -- dragging is handled by the mouse event below
        can_focus   = false,
        color       = 0xFFFFFFFF,
        position_x  = tr.settings.ui.pos_x,
        position_y  = tr.settings.ui.pos_y,
    });
    tr.menu_box.prim = primitives.new({
        visible     = false,
        locked      = true,
        can_focus   = false,
        color       = 0xFFFFFFFF,
        position_x  = tr.settings.ui.menu_x,
        position_y  = tr.settings.ui.menu_anchor_y,
    });

    local mod = ffi.C.GetModuleHandleA('FFXiMain.dll');
    tr.menu_addr = (mod ~= 0) and (mod + MENU_TEXT_OFFSET) or 0;
    if (pEventSystem == nil or pEventSystem == 0) then
        msg('Event system signature not found; NPC menu translation is disabled.');
        tr.menu_addr = 0;
    end
    tr.dirty = true;
end);

--[[
* event: unload
--]]
ashita.events.register('unload', 'unload_cb', function ()
    if (tr.prim ~= nil) then
        tr.prim:destroy();
        tr.prim = nil;
    end
    if (tr.menu_box.prim ~= nil) then
        tr.menu_box.prim:destroy();
        tr.menu_box.prim = nil;
    end
    remove_file(tr.texture);
    remove_file(tr.menu_box.texture);
    settings.save();
end);

--[[
* event: text_in
--]]
ashita.events.register('text_in', 'text_in_cb', function (e)
    local mode = bit.band(e.mode, 0xFF);

    if (tr.settings.debug) then
        debug_log(('[%d] %s'):fmt(mode, clean_message(e.message)));
    end

    if (not tr.settings.enabled or not has_mode(mode)) then
        return;
    end

    handle_line(clean_message(e.message));
end);

--[[
* Settings window (ImGui, default font; labels stay Latin since that font has no Cyrillic)
--]]
local function parse_modes(str)
    local modes = T{ };
    for v in str:gmatch('%d+') do
        local id = tonumber(v);
        if (id >= 0 and id <= 255) then
            modes:append(id);
        end
    end
    return modes;
end

local function ui_checkbox(label, tbl, key)
    local v = { tbl[key] == true };
    if (imgui.Checkbox(label, v)) then
        tbl[key] = v[1];
        tr.dirty = true;
        tr.config_changed = true;
    end
end

local function ui_slider_int(label, tbl, key, min, max)
    local v = { math.floor(tonumber(tbl[key]) or min) };
    if (imgui.SliderInt(label, v, min, max)) then
        tbl[key] = v[1];
        tr.dirty = true;
        tr.config_changed = true;
    end
end

local function ui_text(label, buf_key, size, on_apply)
    if (imgui.InputText(label, tr.config_bufs[buf_key], size, ImGuiInputTextFlags_EnterReturnsTrue)) then
        on_apply(tr.config_bufs[buf_key][1]);
        tr.dirty = true;
        tr.config_changed = true;
    end
end

local function open_config()
    local s = tr.settings;
    tr.config_bufs = {
        target  = { s.target_lang },
        source  = { s.source_lang },
        font    = { s.ui.font_family },
        modes   = { modes_string() },
        test    = { 'Welcome to Windurst, adventurer!' },
    };
    tr.config_open[1] = true;
end

local function render_config()
    if (not tr.config_open[1]) then
        if (tr.config_was_open) then
            tr.config_was_open = false;
            tr.dirty = true;    -- drop the preview text
        end
        if (tr.config_changed) then
            tr.config_changed = false;
            settings.save();
        end
        return;
    end
    if (not tr.config_was_open) then
        tr.config_was_open = true;
        tr.dirty = true;        -- show the preview text
    end

    local s  = tr.settings;
    local ui = s.ui;

    imgui.SetNextWindowSize({ 460, 0 }, ImGuiCond_FirstUseEver);
    if (imgui.Begin('trhelper - Translation Settings', tr.config_open, ImGuiWindowFlags_AlwaysAutoResize)) then
        imgui.PushItemWidth(220);

        imgui.TextColored({ 1.0, 0.82, 0.45, 1.0 }, 'Translation');
        ui_checkbox('Translation enabled', s, 'enabled');
        ui_checkbox('Show translation box', tr, 'shown');
        ui_checkbox('Show original text under the translation', s, 'show_original');
        ui_checkbox('Translate NPC menu options (separate box)', s, 'menu_enabled');
        ui_text('Target language (Enter)', 'target', 16, function (v)
            s.target_lang = v:lower():gsub('%s+', '');
            load_cache();
        end);
        ui_text('Source language (Enter)', 'source', 16, function (v)
            s.source_lang = v:lower():gsub('%s+', '');
        end);

        imgui.Spacing();
        imgui.Separator();
        imgui.TextColored({ 1.0, 0.82, 0.45, 1.0 }, 'Layout');
        local order = { s.newest_on_top and 1 or 0 };
        local r1 = imgui.RadioButton('New lines at the bottom (old scroll up)', order, 0);
        local r2 = imgui.RadioButton('New lines at the top (old scroll down)', order, 1);
        if (r1 or r2) then
            s.newest_on_top = order[1] == 1;
            tr.dirty = true;
            tr.config_changed = true;
        end
        ui_slider_int('Lines on screen', s, 'history', 1, 10);
        local grow = { ui.grow_up == true };
        if (imgui.Checkbox('Grow upward (bottom edge stays in place)', grow)) then
            set_grow_up(grow[1]);
            tr.config_changed = true;
        end
        ui_slider_int('Hide after, sec (0 = never)', s, 'hide_after', 0, 120);

        imgui.Spacing();
        imgui.Separator();
        imgui.TextColored({ 1.0, 0.82, 0.45, 1.0 }, 'Appearance');
        ui_text('Font family (Enter)', 'font', 64, function (v)
            ui.font_family = v;
        end);
        ui_slider_int('Font size', ui, 'font_size', 10, 48);
        ui_checkbox('Bold', ui, 'bold');
        ui_slider_int('Box width', ui, 'width', 200, 1600);
        ui_slider_int('Padding', ui, 'padding', 0, 40);
        local alpha = { math.floor((tonumber(ui.bg_alpha) or 0) * 100 + 0.5) };
        if (imgui.SliderInt('Background opacity, %', alpha, 0, 100)) then
            ui.bg_alpha = alpha[1] / 100;
            tr.dirty = true;
            tr.config_changed = true;
        end
        imgui.TextDisabled('Drag the box to move it, Shift+drag to resize, Shift+wheel for font size.');

        imgui.Spacing();
        imgui.Separator();
        imgui.TextColored({ 1.0, 0.82, 0.45, 1.0 }, 'Advanced');
        ui_text('Chat modes (Enter)', 'modes', 128, function (v)
            s.modes = parse_modes(v);
            tr.config_bufs.modes[1] = modes_string();
        end);
        imgui.Text(('Menu window name: %s'):fmt(s.menu_window_name ~= '' and s.menu_window_name or '(not learned yet)'));
        imgui.SameLine();
        if (imgui.Button('Relearn')) then
            s.menu_window_name = '';
            tr.config_changed = true;
        end
        ui_checkbox('Debug log (debug.log)', s, 'debug');
        imgui.InputText('##test', tr.config_bufs.test, 256);
        imgui.SameLine();
        if (imgui.Button('Test')) then
            tr.last_text = nil;
            handle_line(tr.config_bufs.test[1]);
        end

        imgui.PopItemWidth();
        imgui.Spacing();
        if (imgui.Button('Clear box')) then
            tr.entries = T{ };
            tr.dirty = true;
        end
        imgui.SameLine();
        if (imgui.Button('Reset to defaults')) then
            settings.reset();
            open_config();
        end
        imgui.SameLine();
        if (imgui.Button('Close')) then
            tr.config_open[1] = false;
        end
    end
    imgui.End();
end

--[[
* event: d3d_present
--]]
ashita.events.register('d3d_present', 'present_cb', function ()
    local now = os.clock();
    if (now - tr.last_poll >= POLL_INTERVAL) then
        tr.last_poll = now;
        poll_requests();
    end

    -- Clear the box after a quiet period (not while the settings window is open)..
    local hide_after = tonumber(tr.settings.hide_after) or 0;
    if (tr.config_open[1]) then
        tr.activity = now;
    elseif (hide_after > 0 and #tr.entries > 0 and next(tr.waiting) == nil and now - tr.activity > hide_after) then
        tr.entries = T{ };
        tr.dirty = true;
    end
    while (#tr.entries > math.max(1, tonumber(tr.settings.history) or 1)) do
        tr.entries:remove(1);
        tr.dirty = true;
    end

    -- Rebuilding the texture is not free; limit it to ~10 times a second (sliders, resizing)..
    if (tr.dirty and now - tr.last_render >= 0.1) then
        tr.last_render = now;
        render();
    end

    render_config();

    if (now - tr.menu_poll >= MENU_POLL) then
        tr.menu_poll = now;
        poll_menu();
    end
end);

--[[
* event: mouse
* desc : Drag moves the box, Shift + drag changes its width, Shift + wheel changes the font size.
--]]
-- Returns 'menu' or 'dialog' for the box under the cursor, or nil.
local function box_at(x, y)
    local ui = tr.settings.ui;
    local mb = tr.menu_box;
    if (mb.prim ~= nil and mb.prim.visible
        and x >= ui.menu_x and x < ui.menu_x + ui.width and y >= menu_top() and y < menu_top() + mb.box_h) then
        return 'menu';
    end
    if (tr.prim ~= nil and tr.prim.visible) then
        local top = box_top();
        if (x >= ui.pos_x and x < ui.pos_x + ui.width and y >= top and y < top + tr.box_h) then
            return 'dialog';
        end
    end
    return nil;
end

ashita.events.register('mouse', 'mouse_cb', function (e)
    local ui = tr.settings.ui;

    -- Active drag: follow the mouse until the button is released..
    if (tr.drag ~= nil) then
        local d = tr.drag;
        if (d.mode == 'move') then
            local nx, ny = d.px + (e.x - d.x), d.py + (e.y - d.y);
            if (d.box == 'menu') then
                ui.menu_x, ui.menu_anchor_y = nx, ny;
                if (tr.menu_box.prim ~= nil) then
                    tr.menu_box.prim.position_x = nx;
                    tr.menu_box.prim.position_y = menu_top();
                end
            else
                ui.pos_x, ui.pos_y = nx, ny;
                if (tr.prim ~= nil) then
                    tr.prim.position_x = nx;
                    tr.prim.position_y = box_top();
                end
            end
        else
            local w = math.max(200, math.min(2048, d.w + (e.x - d.x)));
            if (w ~= ui.width) then
                ui.width = w;
                tr.dirty = true;
            end
        end
        tr.activity = os.clock();
        if (e.message == 0x202) then
            tr.drag = nil;
            settings.save();
        end
        e.blocked = true;
        return;
    end

    local box = box_at(e.x, e.y);
    if (box == nil) then
        return;
    end

    local shift = bit.band(ffi.C.GetKeyState(VK_SHIFT), 0x8000) ~= 0;

    if (e.message == 0x201) then
        tr.drag = {
            box     = box,
            mode    = shift and 'width' or 'move',
            x       = e.x,
            y       = e.y,
            px      = box == 'menu' and ui.menu_x or ui.pos_x,
            py      = box == 'menu' and ui.menu_anchor_y or ui.pos_y,
            w       = ui.width,
        };
        e.blocked = true;
    elseif (e.message == 0x20A and shift) then
        local d = tonumber(e.delta) or 0;
        if (d ~= 0) then
            ui.font_size = math.max(10, math.min(48, ui.font_size + (d > 0 and 1 or -1)));
            tr.activity = os.clock();
            tr.dirty = true;
            settings.save();
        end
        e.blocked = true;
    end
end);


--[[
* event: command
--]]
ashita.events.register('command', 'command_cb', function (e)
    local args = e.command:args();
    if (#args == 0 or not args[1]:any('/tr')) then
        return;
    end

    e.blocked = true;
    local s = tr.settings;

    if (#args == 1) then
        if (tr.config_open[1]) then
            tr.config_open[1] = false;
        else
            open_config();
        end
        tr.dirty = true;
        return;
    end

    local sub = args[2]:lower();

    if (#args == 2 and sub == 'box') then
        tr.shown = not tr.shown;
        tr.dirty = true;
        return;
    end

    if (#args == 3 and sub == 'menu' and args[3]:lower() == 'relearn') then
        s.menu_window_name = '';
        settings.save();
        msg('The NPC menu window name will be learned again on the next menu.');
        return;
    end

    if (#args == 2 and sub == 'menu') then
        s.menu_enabled = not s.menu_enabled;
        tr.dirty = true;
        settings.save();
        msg('NPC menu translation ' .. (s.menu_enabled and 'enabled.' or 'disabled.'));
        return;
    end

    if (#args == 2 and sub == 'grow') then
        set_grow_up(not s.ui.grow_up);
        settings.save();
        msg('Box grows ' .. (s.ui.grow_up and 'upward.' or 'downward.'));
        return;
    end

    if (#args == 2 and sub == 'top') then
        s.newest_on_top = not s.newest_on_top;
        tr.dirty = true;
        settings.save();
        msg('New lines appear at the ' .. (s.newest_on_top and 'top.' or 'bottom.'));
        return;
    end

    if (sub == 'help') then
        print_help(false);
        return;
    end

    if (#args == 2 and sub:any('on', 'off')) then
        s.enabled = sub == 'on';
        settings.save();
        msg('Translation ' .. (s.enabled and 'enabled.' or 'disabled.'));
        return;
    end

    if (#args == 3 and sub == 'lang') then
        s.target_lang = args[3]:lower();
        load_cache();
        settings.save();
        msg('Target language: ' .. s.target_lang);
        return;
    end

    if (#args == 3 and sub == 'src') then
        s.source_lang = args[3]:lower();
        settings.save();
        msg('Source language: ' .. s.source_lang);
        return;
    end

    if (#args == 2 and sub == 'orig') then
        s.show_original = not s.show_original;
        tr.dirty = true;
        settings.save();
        return;
    end

    if (#args == 2 and sub == 'bold') then
        s.ui.bold = not s.ui.bold;
        tr.dirty = true;
        settings.save();
        return;
    end

    if (#args == 3 and sub:any('lines', 'width', 'size', 'alpha', 'hide')) then
        local n = args[3]:number_or(-1);
        if (n < 0 or (n == 0 and not sub:any('alpha', 'hide'))) then
            print_help(true);
            return;
        end
        if (sub == 'lines') then
            s.history = n;
            while (#tr.entries > n) do
                tr.entries:remove(1);
            end
        elseif (sub == 'width') then
            s.ui.width = math.min(n, 2048);
        elseif (sub == 'hide') then
            s.hide_after = n;
        elseif (sub == 'size') then
            s.ui.font_size = n;
        else
            s.ui.bg_alpha = math.min(n, 100) / 100;
        end
        tr.dirty = true;
        settings.save();
        return;
    end

    if (#args >= 3 and sub == 'font') then
        s.ui.font_family = args:slice(3, #args):concat(' ');
        tr.dirty = true;
        settings.save();
        return;
    end

    if (#args == 4 and sub == 'pos') then
        s.ui.pos_x = args[3]:number_or(s.ui.pos_x);
        s.ui.pos_y = args[4]:number_or(s.ui.pos_y);
        tr.dirty = true;
        settings.save();
        return;
    end

    if (#args == 2 and sub == 'modes') then
        msg('Translated modes: ' .. modes_string());
        return;
    end

    if (#args == 4 and sub == 'mode' and args[3]:any('add', 'del')) then
        local id = args[4]:number_or(-1);
        if (id < 0 or id > 255) then
            print_help(true);
            return;
        end
        local modes = T{ };
        for _, v in pairs(s.modes) do
            if (tonumber(v) ~= id) then
                modes:append(v);
            end
        end
        if (args[3] == 'add') then
            modes:append(id);
        end
        s.modes = modes;
        settings.save();
        msg('Translated modes: ' .. modes_string());
        return;
    end

    if (#args == 2 and sub == 'debug') then
        s.debug = not s.debug;
        settings.save();
        msg('Debug logging ' .. (s.debug and ('enabled: ' .. tr.base_dir .. '\\debug.log') or 'disabled.'));
        return;
    end

    if (#args >= 3 and sub == 'test') then
        tr.last_text = nil;
        handle_line(convert(args:slice(3, #args):concat(' '), CP_SJIS, CP_UTF8));
        return;
    end

    if (#args == 2 and sub == 'clear') then
        tr.entries = T{ };
        tr.dirty = true;
        return;
    end

    if (#args == 2 and sub:any('reload', 'rl')) then
        settings.reload();
        msg('Settings reloaded from disk.');
        return;
    end

    if (#args == 2 and sub == 'reset') then
        settings.reset();
        msg('Settings reset to defaults.');
        return;
    end

    print_help(true);
end);
