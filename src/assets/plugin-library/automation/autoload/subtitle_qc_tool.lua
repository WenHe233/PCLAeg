local tr = aegisub.gettext
script_name = tr("～字幕质检工具～")
script_description = tr("检查字幕中的闪轴、叠轴、关键帧、时长、字数、标签、错字等问题；可自动校正闪轴、叠轴、关键帧，替换特定字符等")
script_author = "https://bbs.acgrip.com/thread-13325-1-1.html"
script_version = "1.0"

local re = require("re")
local ffi = require("ffi")

ffi.cdef([[
    int MultiByteToWideChar(unsigned int, unsigned long, const char*, int, wchar_t*, int);
    int WideCharToMultiByte(unsigned int, unsigned long, const wchar_t*, int, char*, int, const char*, int*);
]])

-- 提示内容输出的列，可选effect、actor
local TIPS_OUTPUT_COLUMN = "effect"

-- 通用工具模块
local Utils = {
    IS_LUA51 = _VERSION == "Lua 5.1",
    -- codepage
    CODEPAGE = {
        UTF8 = 65001,
        GBK = 936,
        BIG5 = 950,
    },
    SPACE_CHARS = {
        [" "] = true,
        ["\t"] = true,
        ["　"] = true,
    },
    array_to_set = function(array)
        local s = {};
        for _, v in ipairs(array) do
            s[v] = true
        end
        return s
    end,
}

-- 配置管理模块
local Config = {
    CONFIG_FILE_PATH = aegisub.decode_path("?user/subtitle_qc_tool.cfg"),
    TYPO_DICT_FILE_PATH = aegisub.decode_path("?user/subtitle_qc_tool_typo_dict.cfg"),
    DEFAULT = {
        version = script_version,

        time_check_selected_styles = {},
        time_check_clear_tips_before_execute = true,
        time_check_save_config_on_execute = false,
        time_check_selected_only = false,
        ignore_no_text = false,
        sort_by_time = false,
        flash_threshold = 120,
        flash_prev_ratio = 80,
        flash_keyframe_prioritize = true,
        overlap_keyframe_prioritize = true,
        overlap_prev_ratio = 100,
        start_time_before_keyframe = 120,
        start_time_after_keyframe = 120,
        end_time_before_keyframe = 160,
        end_time_after_keyframe = 160,
        min_duration = 500,
        max_duration = 15000,
        max_chars = 22,

        char_replace_selected_styles = {},
        char_replace_clear_tips_before_execute = true,
        char_replace_save_config_on_execute = false,
        char_replace_selected_only = false,
        split_overlapping_dialogue = false,
        clear_cn_period = false,
        clear_en_comma = false,
        clear_cn_comma = false,
        clear_cn_caesura_point = false,
        clear_ass_line_break = false,
        clear_space = false,
        clear_full_width_space = false,
        clear_right_arrow = false,
        full_width_space_choice_idx = 1,
        space_choice_idx = 1,
        english_word_spaces = false,
        exclamation_point_choice_idx = 1,
        question_mark_choice_idx = 1,
        interrobang_choice_idx = 1,
        replace_ellipsis_radical = false,
        replace_ellipsis = false,
        replace_multi_ellipsis = false,
        en_double_quotation_mark = false,
        cn_double_quotation_mark = false,
        jp_double_quotation_mark = false,
        double_quotation_mark_choice_idx = false,
        en_single_quotation_mark = false,
        cn_single_quotation_mark = false,
        jp_single_quotation_mark = false,
        single_quotation_mark_choice_idx = 1,
        middle_dot_choice_idx = 1,

        content_sweep_save_config_on_execute = false,
        sweep_fanhuaji = false,
        sweep_useless_style = false,
        sweep_actor_ntp = false,
        sweep_last_notext_line = false,
        sweep_aegisub_motion_plugin_info = false,
        sweep_nonstandard_section = false,
    }
}

-- 关键帧处理模块
local Keyframe = {}

-- 统计数据模块
local Stats = {}

-- 时轴检查与校正模块
local TimingCheck = {}

-- 文本替换模块
local CharReplace = {}

-- 内容清理模块
local ContentSweep = {}

-- 标签检查模块
local TagCheck = {
    -- 标准 ASS 标签
    STANDARD_TAGS = Utils.array_to_set({
        -- 格式开关
        "b", "i", "u", "s",
        -- 字体
        "fn", "fs", "fsp", "fscx", "fscy", "fe",
        -- 旋转/倾斜
        "fr", "frx", "fry", "frz", "fax", "fay",
        -- 颜色
        "c", "1c", "2c", "3c", "4c",
        -- 透明度
        "alpha", "1a", "2a", "3a", "4a",
        -- 边框/阴影
        "bord", "xbord", "ybord", "shad", "xshad", "yshad",
        -- 模糊
        "be", "blur",
        -- 位置/对齐
        "pos", "move", "org", "an", "a",
        -- 渐变/动画
        "fad", "fade", "t",
        -- 裁剪
        "clip", "iclip",
        -- 卡拉OK (k和K效果不同，大小写敏感)
        "k", "K", "kf", "ko",
        -- 其他
        "q", "r", "p", "pbo",
    }),
    -- VSFilterMod 扩展标签
    VSFILTERMOD_TAGS = Utils.array_to_set({
        "z", "fsc", "frs", "fsvp", "fshp",
        "rnd", "rndx", "rndy", "rndz",
        "1vc", "2vc", "3vc", "4vc",
        "1va", "2va", "3va", "4va",
        "1img", "2img", "3img", "4img",
        "mover", "moves3", "moves4", "movevc",
        "xblur", "yblur",
        "jitter", "distort", "ortho",
    }),
    -- 需要括号的标签
    PAREN_TAGS = Utils.array_to_set({
        "pos", "move", "org",
        "fad", "fade", "t",
        "clip", "iclip",
        "1vc", "2vc", "3vc", "4vc",
        "1va", "2va", "3va", "4va",
        "1img", "2img", "3img", "4img",
        "mover", "moves3", "moves4", "movevc",
        "jitter", "distort",
    }),
    -- 颜色标签
    COLOR_TAGS = Utils.array_to_set({
        "c", "1c", "2c", "3c", "4c",
    }),
    -- 透明度标签
    ALPHA_TAGS = Utils.array_to_set({
        "alpha", "1a", "2a", "3a", "4a",
    }),
    VALID_FONT_CODE = Utils.array_to_set({
        0, 1, 128, 129, 134, 136, 162, 163, 177, 178,
    }),
}

-- 错字检查模块
local TypoCheck = {}

-- GUI模块
local GUI = {
    EXCLAMATION_POINT_CHOICE = {
        "不替换",
        "替换为 \"！\"（U+FF01，中文感叹号，全角）",
        "替换为 \"!\"（U+0021，英文感叹号，半角）",
    },
    QUESTION_MARK_CHOICE = {
        "不替换",
        "替换为 \"？\" （U+FF1F，中文问号，全角）",
        "替换为 \"?\" （U+003F，英文问号，半角）",
    },
    INTERROBANG_CHOICE = {
        "不替换",
        "替换为 中文形式的\"？！\"（U+FF1FU+FF01，中文问号感叹号，全角字符）",
        "替换为 中文形式的\"?!\"（U+0021U+003F，英文问号感叹号，半角字符）",
        "替换为 日文形式的\"！？\"（U+003FU+0021，中文感叹号问号，全角字符）",
        "替换为 日文形式的\"!?\"（U+0021U+003F，英文感叹号问号，半角字符）",
    },
    FULL_WIDTH_SPACE_CHOICE = {
        "不替换",
        "替换为 \" \"（U+0020，半角空格）",
        "替换为 \"  \"（U+0020U+0020，两个半角空格）",
        "替换为 \"　\"（U+3000，全角空格）【日文形式】",
    },
    SPACE_CHOICE = {
        "不替换",
        "替换为 \" \"（U+0020，半角空格）",
        "替换为 \"  \"（U+0020U+0020，两个半角空格）",
        "替换为 \"　\"（U+3000，全角空格）【日文形式】",
    },
    DOUBLE_QUOTATION_MARK_CHOICE = {
        "不替换",
        "替换为 \"\"（U+0022U+0022，英文双引号，半角）",
        "替换为 “”（U+201CU+201D，中文双引号，全角）",
        "替换为 「」（U+300CU+300D，二角括号【日文形式】）",
        "替换为 ﹁﹂（U+FE41U+FE42，竖排二角括号【日文形式】）",
    },
    SINGLE_QUOTATION_MARK_CHOICE = {
        "不替换",
        "替换为 \'\'（U+0027U+0027，英文单引号，半角）",
        "替换为 ‘’（U+2018U+2019，中文单引号，全角）",
        "替换为 『』（U+300EU+300F，双重引号【日文形式】）",
        "替换为 ﹃﹄（U+FE43U+FE44，竖排双重引号【日文形式】）",
    },
    MIDDLE_DOT_CHOICE = {
        "不替换",
        "替换为 \"·\"（U+00B7，间隔号，中文常用）",
        "替换为 \"．\"（U+FF0E，音界号，Big5标准中文常用）",
        "替换为 \"・\"（U+30FB，全角片假名中点【日文形式】）",
        "替换为 \"･\"（U+FF65，半角片假名中点【日文形式】）",
    },
}


--========================= Util =========================--
function Utils.log(msg)
    aegisub.log(msg .. "\n")
end

-- 显示警告框
function Utils.alert(msg)
    aegisub.dialog.display(
        {
            {class="label", label="   ", x=0, y=0, height=2},
            {class="label", label=msg, x=1, y=0, height=2},
            {class="label", label="   ", x=2, y=0, height=2}
        }, 
        {"确定"}
    )
end

-- 深度复制
function Utils.deep_copy(obj)
    local seen = {}
    local function copy(_obj)
        if type(_obj) ~= "table" then
            return _obj
        end
        if seen[_obj] then
            return seen[_obj]
        end
        local _table = {}
        seen[_obj] = _table
        for k, v in pairs(_obj) do
            _table[k] = copy(v)
        end
        return _table
    end
    return copy(obj)
end

-- 表格比较
function Utils.table_equal(t1, t2)
    if t1 == t2 then
        return true
    end
    if type(t1) ~= "table" or type(t2) ~= "table" then
        return false
    end

    local queue = {{t1, t2},}
    local visited = {}

    while next(queue) do
        local pair = table.remove(queue, 1)
        local a, b = pair[1], pair[2]

        if not visited[a] then
            visited[a] = {}
        end

        if not visited[a][b] then
            visited[a][b] = true

            -- 比较键值对
            for k, v in pairs(a) do
                local v2 = b[k]
                if v2 == nil then
                    return false
                end
                if type(v) == "table" and type(v2) == "table" then
                    if v ~= v2 then
                        table.insert(queue, {v, v2})
                    end
                elseif v ~= v2 then
                    return false
                end
            end

            -- 检查b是否有额外键
            for k in pairs(b) do
                if a[k] == nil then
                    return false
                end
            end
        end
    end
    return true
end

-- 下拉框所选择的选项的索引
function Utils.which_choice(choice_array, choice_value)
    for i, value in ipairs(choice_array) do
        if value == choice_value then
            return i
        end
    end
    return nil
end

-- 字符计数（移除绘图、标签、换行）
function Utils.count_stripped_text(text)
    -- 移除文本中的绘图、标签、换行
    local stripped = {}
    for _, segment in ipairs(Utils.parse_line(text)) do
        if segment.type == "text" then
            table.insert(stripped, segment.content)
        end
    end

    stripped = re.sub(table.concat(stripped, ""), "\\\\[hnN]", function(x) return x == "\\h" and " " or "" end)

    -- 使用re库计数UTF-8字符，re.find空字符串会返回nil
    local matches = re.find(stripped, ".") or {}
    return #matches
end

-- 毫秒转时间字符串
function Utils.ms_to_time_str(ms)
    local centiseconds = math.floor(ms / 10 + 0.5) % 100
    local seconds = math.floor(ms / 1000) % 60
    local minutes = math.floor(ms / 60000) % 60
    local hours = math.floor(ms / 3600000)
    -- Aegisub 显示格式：H:MM:SS.CS (厘秒是两位)
    return string.format("%d:%02d:%02d.%02d", hours, minutes, seconds, centiseconds)
end

-- 字符串转为整数
function Utils.str_to_int(text)
    local match = re.find(text, "^\\s*-?\\d+\\s*$")
    if match then
        -- tonumber会自动去除前后空格
        return tonumber(match[1].str)
    end
    return nil
end

-- 字符串转为小数
function Utils.str_to_decimal(text)
    local match = re.find(text, "^\\s*-?\\d+(?:\\.\\d+)?\\s*$")
    if match then
        return tonumber(match[1].str)
    end
    return nil
end

-- 解析字幕文本，分离标签tag、绘图指令drawing和纯文本text
function Utils.parse_line(text)
    local segments = {}
    local pos = 1
    local len = #text
    local drawing_or_text = "text"

    while pos <= len do
        if text:sub(pos, pos) == "{" then
            local end_pos = text:find("}", pos)
            if end_pos then
                local tag_content = text:sub(pos, end_pos)
                table.insert(segments, {type="tag", content=tag_content})
                -- 检查 \p 标签
                for p in tag_content:gmatch("\\p(%d+)") do
                    drawing_or_text = tonumber(p) == 0 and "text" or "drawing"
                end
                pos = end_pos + 1
            else
                table.insert(segments, {type=drawing_or_text, content="{"})
                pos = pos + 1
            end
        else
            local text_end = (text:find("{", pos) or len + 1) - 1
            local content = text:sub(pos, text_end)
            table.insert(segments, {type=drawing_or_text, content=content})
            pos = text_end + 1
        end
    end

    return segments
end

-- 多字节编码 转 UTF-8
function Utils.multibyte_to_utf8(str, from_codepage)
    if str == "" then
        return ""
    end

    local wlen = ffi.C.MultiByteToWideChar(from_codepage, 0, str, #str, nil, 0)
    if wlen == 0 then
        return nil
    end

    local wstr = ffi.new("wchar_t[?]", wlen)
    ffi.C.MultiByteToWideChar(from_codepage, 0, str, #str, wstr, wlen)
    local ulen = ffi.C.WideCharToMultiByte(Utils.CODEPAGE.UTF8, 0, wstr, wlen, nil, 0, nil, nil)
    local ustr = ffi.new("char[?]", ulen + 1)
    ffi.C.WideCharToMultiByte(Utils.CODEPAGE.UTF8, 0, wstr, wlen, ustr, ulen, nil, nil)
    return ffi.string(ustr, ulen)
end

-- 码点 转 UTF-8字符
function Utils.codepoint_to_utf8(codepoint)
    if codepoint < 0 or codepoint > 0x10FFFF then
        return nil
    end

    if codepoint < 0x80 then
        return string.char(codepoint)
    elseif codepoint < 0x800 then
        return string.char(
            0xC0 + math.floor(codepoint / 64),
            0x80 + codepoint % 64
        )
    elseif codepoint < 0x10000 then
        return string.char(
            0xE0 + math.floor(codepoint / 4096),
            0x80 + math.floor(codepoint / 64) % 64,
            0x80 + codepoint % 64
        )
    else
        return string.char(
            0xF0 + math.floor(codepoint / 262144),
            0x80 + math.floor(codepoint / 4096) % 64,
            0x80 + math.floor(codepoint / 64) % 64,
            0x80 + codepoint % 64
        )
    end
end

-- UTF-16 转 UTF-8
function Utils.utf16_to_utf8(str, is_utf16be)
    if #str < 2 then
        return nil
    end

    local start = 1
    -- if is_utf16be then
    --     -- 跳过 utf16be BOM (FE FF)
    --     if str:byte(1) == 0xFE and str:byte(2) == 0xFF then
    --         start = 3
    --     end
    -- elseif str:byte(1) == 0xFF and str:byte(2) == 0xFE then
    --     -- 跳过 utf16le BOM (FF FE)
    --     start = 3
    -- end

    local result = {}
    local i = start
    local lo_hi_bytes
    if is_utf16be then
        lo_hi_bytes = function(idx) return str:byte(idx + 1), str:byte(idx) end
    else
        lo_hi_bytes = function(idx) return str:byte(idx), str:byte(idx + 1) end
    end

    while i <= #str - 1 do
        local lo, hi = lo_hi_bytes(i)
        local code = lo + hi * 256

        -- 代理对处理 (Surrogate Pair)
        if code >= 0xD800 and code <= 0xDBFF and i + 3 <= #str then
            local lo2, hi2 = lo_hi_bytes(i + 2)
            local code2 = lo2 + hi2 * 256
            if code2 >= 0xDC00 and code2 <= 0xDFFF then
                code = 0x10000 + (code - 0xD800) * 1024 + (code2 - 0xDC00)
                i = i + 2
            end
        end

        local utf8_char = Utils.codepoint_to_utf8(code)
        if utf8_char then
            result[#result + 1] = utf8_char
        end
        i = i + 2
    end

    return table.concat(result)
end

-- 检测BOM
function Utils.detect_bom(str)
    local len = #str
    if len >= 3 then
        local b1, b2, b3 = str:byte(1, 3)
        -- UTF-8 BOM: EF BB BF
        if b1 == 0xEF and b2 == 0xBB and b3 == 0xBF then
            return "UTF-8", 3
        end
    end
    if len >= 2 then
        local b1, b2 = str:byte(1, 2)
        -- UTF-16 LE: FF FE
        if b1 == 0xFF and b2 == 0xFE then
            return "UTF-16LE", 2
        end
        -- UTF-16 BE: FE FF
        if b1 == 0xFE and b2 == 0xFF then
            return "UTF-16BE", 2
        end
    end
    return nil, 0
end

-- UTF-8 有效性检测
function Utils.check_utf8(str)
    local i = 1
    local len = #str
    local multibyte_cnt = 0

    while i <= len do
        local b = str:byte(i)
        local width = 0
        -- 英文/数字/半角符号(0x00~0x7F)。续字节(0x80~0xBF)、保留位(0xF8+)无效
        if b < 0x80 then
            -- 英文/数字/半角符号
            width = 1
        elseif b >= 0xC2 then
            if b < 0xE0 then
                -- 部分欧洲/中东字符
                width = 2
            elseif b < 0xF0 then
                -- 中日韩文字/常用符号（如全角空格、中文标点）
                width = 3
            elseif b < 0xF5 then
                -- Emoji/特殊符号
                width = 4
            end
        end

        if width == 0 then
            return false, 0
        end

        -- 最后的几个字节如果不是完整的一个字则不检测
        local multibyte_last_idx = i + width - 1
        if multibyte_last_idx <= len then
            for j = i + 1, multibyte_last_idx do
                b = str:byte(j)
                if b < 0x80 or b >= 0xC0 then
                    return false, 0
                end
            end
        end

        if width > 1 then
            multibyte_cnt = multibyte_cnt + 1
        end
        i = i + width
    end

    return true, multibyte_cnt
end

-- UTF-16 检测（无BOM）
function Utils.detect_utf16(str)
    local len = #str
    if len < 2 then
        return nil, 0
    end

    local null_odd, null_even = 0, 0
    local ascii_le, ascii_be = 0, 0

    -- 如果字符串的字节数非偶数个，则忽略最后一个字节的判断
    for i = 1, len, 2 do
        local b1, b2 = str:byte(i), str:byte(i + 1)

        if b1 == 0x00 then
            null_odd = null_odd + 1
        end
        if b2 == 0x00 then
            null_even = null_even + 1
        end

        -- ASCII 字符检测
        if b1 >= 0x20 and b1 < 0x7F and b2 == 0x00 then
            ascii_le = ascii_le + 1
        end
        if b2 >= 0x20 and b2 < 0x7F and b1 == 0x00 then
            ascii_be = ascii_be + 1
        end
    end

    local pairs = len / 2
    local threshold = pairs * 0.3

    -- UTF-16 LE: 大量 xx 00 模式
    if null_even > threshold and ascii_le > threshold / 2 then
        return "UTF-16LE", ascii_le / pairs
    end

    -- UTF-16 BE: 大量 00 xx 模式
    if null_odd > threshold and ascii_be > threshold / 2 then
        return "UTF-16BE", ascii_be / pairs
    end

    return nil, 0
end

-- GBK 得分
function Utils.detect_score_gbk(str)
    local i, len = 1, #str
    local valid, total = 0, 0

    while i <= len do
        local b = str:byte(i)
        if b < 0x80 then
            i = i + 1
        elseif b >= 0x81 and b <= 0xFE and i + 1 <= len then
            local b2 = str:byte(i + 1)
            total = total + 1
            if (b2 >= 0x40 and b2 <= 0x7E) or (b2 >= 0x80 and b2 <= 0xFE) then
                valid = valid + 1
                if b >= 0xB0 and b <= 0xF7 and b2 >= 0xA1 then
                    valid = valid + 0.5
                end
            end
            i = i + 2
        else
            return 0
        end
    end

    return total > 0 and valid / total or 0
end

-- Big5 得分
function Utils.detect_score_big5(str)
    local i, len = 1, #str
    local valid, total = 0, 0

    while i <= len do
        local b = str:byte(i)
        if b < 0x80 then
            i = i + 1
        elseif b >= 0x81 and b <= 0xFE and i + 1 <= len then
            local b2 = str:byte(i + 1)
            total = total + 1
            if (b2 >= 0x40 and b2 <= 0x7E) or (b2 >= 0xA1 and b2 <= 0xFE) then
                valid = valid + 1
                if b >= 0xA4 and b <= 0xC6 then
                    valid = valid + 0.5
                end
            end
            i = i + 2
        else
            return 0
        end
    end

    return total > 0 and valid / total or 0
end

-- 检测字符串的编码
function Utils.detect_encoding(str)
    local len = #str
    if len == 0 then
        return nil, 0
    end

    -- BOM 检测（最高优先级）
    local bom_encoding, bom_width = Utils.detect_bom(str)
    if bom_encoding then
        return bom_encoding, bom_width
    end

    -- 检测是否纯 ASCII
    local has_highbyte = false
    local has_null = false
    for i = 1, len do
        local b = str:byte(i)
        if b >= 0x80 then
            has_highbyte = true
        end
        if b == 0x00 then
            has_null = true
        end
    end

    if not has_highbyte and not has_null then
        return "ASCII", 0
    end

    -- 如果有 NULL 字节，优先检测 UTF-16
    if has_null then
        -- UTF-16 检测
        local utf16, score16 = Utils.detect_utf16(str)
        if utf16 and score16 > 0.3 then
            return utf16, 0
        end
    end

    -- UTF-8 检测
    local is_utf8, multibyte_cnt = Utils.check_utf8(str)
    if is_utf8 and multibyte_cnt > 0 then
        return "UTF-8", 0
    end

    -- 其他多字节编码
    local scores = {
        {name = "GBK", score = Utils.detect_score_gbk(str)},
        {name = "Big5", score = Utils.detect_score_big5(str)},
    }

    table.sort(scores, function(a, b) return a.score > b.score end)

    if scores[1].score > 0.9 then
        return scores[1].name, 0
    end

    return nil, 0
end

-- 字符串转成UTF-8编码
function Utils.convert_to_utf8(str, encoding)
    if encoding == "UTF-8" or encoding == "ASCII" then
        return str
    elseif encoding == "UTF-16LE" then
        return Utils.utf16_to_utf8(str, false)
    elseif encoding == "UTF-16BE" then
        return Utils.utf16_to_utf8(str, true)
    elseif encoding == "GBK" then
        return Utils.multibyte_to_utf8(str, Utils.CODEPAGE.GBK)
    elseif encoding == "Big5" then
        return Utils.multibyte_to_utf8(str, Utils.CODEPAGE.BIG5)
    end
    error("Unknown encoding: " .. encoding)
end

--========================= Config =========================--
-- 加载配置
function Config.load()
    local file, err = io.open(Config.CONFIG_FILE_PATH, "r")
    if not file then
        if not err:find("No such file") then
            Utils.alert("打开配置文件出错：" .. err .. "\n将使用默认配置")
        end
        return Utils.deep_copy(Config.DEFAULT)
    end

    local content = file:read("*a")
    file:close()

    local func, parse_err = Utils.IS_LUA51 and loadstring(content) or load(content)
    if not func then
        Utils.alert("解析配置文件出错：" .. parse_err .. "\n将使用默认配置")
        return Utils.deep_copy(Config.DEFAULT)
    end

    local ok, config = pcall(func)
    if not ok or type(config) ~= "table" then
        Utils.alert("加载配置数据出错：" .. config .. "\n将使用默认配置")
        return Utils.deep_copy(Config.DEFAULT)
    end

    -- 合并默认配置（补全缺失项）
    for k, v in pairs(Config.DEFAULT) do
        if config[k] == nil then
            config[k] = v
        end
    end
    return config
end

-- 保存配置
function Config.save(config)
    local file, err = io.open(Config.CONFIG_FILE_PATH, "w")
    if not file then
        Utils.alert("无法创建配置文件：" .. err)
        return false
    end

    -- 序列化配置
    local function serialize(t, level)
        level = level or 0
        local indent = string.rep("  ", level)
        local s = "{\n"
        for k, v in pairs(t) do
            local key = type(k) == "string" and string.format('["%s"]', (k:gsub('["\\]', "\\%1"))) or "[" .. k .. "]"
            local val = type(v) == "table" and serialize(v, level + 1)
                            or (type(v) == "string" and string.format('"%s"', (v:gsub('["\\]', "\\%1"))) or tostring(v))
            s = s .. indent .. "  " .. key .. " = " .. val .. ",\n"
        end
        return s .. indent .. "}"
    end

    local ok, write_err = file:write("return " .. serialize(config))
    if not ok then
        Utils.alert("配置文件写入失败：" .. write_err)
        return false
    end

    if not file:close() then
        Utils.alert("配置文件保存失败：关闭文件出错")
        return false
    end
    return true
end

-- 验证配置参数有效性
function Config.validate(config)
    -- 时间参数取整到厘秒
    config.start_time_before_keyframe = math.floor(config.start_time_before_keyframe / 10) * 10
    config.start_time_after_keyframe = math.floor(config.start_time_after_keyframe / 10) * 10
    config.end_time_before_keyframe = math.floor(config.end_time_before_keyframe / 10) * 10
    config.end_time_after_keyframe = math.floor(config.end_time_after_keyframe / 10) * 10
    config.flash_threshold = math.floor(config.flash_threshold / 10) * 10

    -- 比例参数限制在0-100
    config.flash_prev_ratio = math.max(0, math.min(100, config.flash_prev_ratio))
    config.overlap_prev_ratio = math.max(0, math.min(100, config.overlap_prev_ratio))

    -- 时长参数最小值限制
    config.min_duration = math.max(10, config.min_duration)
    config.max_duration = math.max(config.min_duration, config.max_duration)
    return config
end

-- 设置为仅检查
function Config.set_check_only(config)
    config.check_only = true
    return config
end


--========================= Keyframe =========================--
-- 获取关键帧时间（毫秒，精确到厘秒）
function Keyframe.get_all()
    local keyframes = aegisub.keyframes()
    if not keyframes or #keyframes == 0 then
        return {}
    end

    -- 检查是否有视频
    if not aegisub.video_size() then
        return {}
    end

    local fps = aegisub.frame_from_ms(1000)
    if not fps or fps <= 0 then
        return {}
    end

    local kf_times = {}
    for _, frame in ipairs(keyframes) do
        -- 关键帧精确到厘秒
        table.insert(kf_times, math.floor((aegisub.ms_from_frame(frame) + 5) / 10) * 10)
    end
    table.sort(kf_times)
    return kf_times
end

-- 查找范围内的关键帧
function Keyframe.find_in_range(keyframes, start_time, end_time)
    if #keyframes == 0 then
        return {}
    end

    -- 二分查找起始索引(找到第一个大于等于start_time的关键帧索引start_idx)
    local left, right = 1, #keyframes
    local start_idx = right + 1
    while left <= right do
        -- 防止math.floor((left + right) / 2)加法溢出
        local mid = math.floor(left + (right - left) / 2)
        if keyframes[mid] >= start_time then
            start_idx = mid
            right = mid - 1
        else
            left = mid + 1
        end
    end

    -- 收集范围内关键帧
    local result = {}
    for i = start_idx, #keyframes do
        if keyframes[i] <= end_time then
            table.insert(result, keyframes[i])
        else
            break
        end
    end
    return result
end

-- 查找最接近的关键帧
function Keyframe.find_nearest(keyframes, time, max_distance, direction)
    -- direction: "before"(<=time且最接近) 或 "after"(>=time且最接近) 或 "any"(最接近time)
    if #keyframes == 0 then
        return nil
    end

    -- 二分查找插入位置(找到第一个大于等于time的关键帧索引pos)
    local left, right = 1, #keyframes
    local pos = right + 1
    while left <= right do
        local mid = math.floor((left + right) / 2)
        if keyframes[mid] >= time then
            pos = mid
            right = mid - 1
        else
            left = mid + 1
        end
    end

    local best_kf_idx = nil

    -- 检查前向关键帧(<=time)
    if direction == "before" or direction == "any" then
        if direction == "before" and pos <= #keyframes and keyframes[pos] == time then
            best_kf_idx = pos
        elseif pos > 1 and time - keyframes[pos - 1] <= max_distance then
            best_kf_idx = pos - 1
        end
    end

    -- 检查后向关键帧(>=time)
    if (direction == "after" or direction == "any") and pos <= #keyframes then
        local distance = keyframes[pos] - time
        if distance <= max_distance then
            if not best_kf_idx or distance < (time - keyframes[best_kf_idx]) then
                best_kf_idx = pos
            end
        end
    end

    return best_kf_idx and keyframes[best_kf_idx] or nil
end


--========================= Stats =========================--
-- 创建空统计对象
function Stats.create(styles)
    local stats = {
        total = {
            flash_issue = 0,
            overlap_issue = 0,
            full_coverage_issue = 0,
            start_time_keyframe_issue = 0,
            end_time_keyframe_issue = 0,
            short_duration_issue = 0,
            long_duration_issue = 0,
            long_text_issue = 0,
        },
        by_style = {}
    }

    -- 初始化样式统计
    for style in pairs(styles) do
        stats.by_style[style] = Utils.deep_copy(stats.total)
    end
    return stats
end

-- 更新统计数据
function Stats.update(stats, style, issue_type, not_update_total)
    if not not_update_total then
        stats.total[issue_type] = stats.total[issue_type] + 1
    end
    stats.by_style[style][issue_type] = stats.by_style[style][issue_type] + 1
end

-- 格式化统计结果为字符串
function Stats.format(stats)
    local text = "━━━━━━ 各样式情况 ━━━━━━\n"
    for style, data in pairs(stats.by_style) do
        text = text .. string.format(
            "[ %s ]：\n闪轴【%d】┋ 叠轴【%d】┋ 覆盖轴【%d】┋ 始&末贴K帧【%d+%d】┋ 过短&过长轴【%d+%d】┋ 字数多【%d】\n\n",
            style,
            data.flash_issue,
            data.overlap_issue,
            data.full_coverage_issue,
            data.start_time_keyframe_issue, data.end_time_keyframe_issue,
            data.short_duration_issue, data.long_duration_issue,
            data.long_text_issue
        )
    end

    text = text .. "\n━━━━━━ 总体情况 ━━━━━━\n" .. string.format(
        "闪轴【%d】┋ 叠轴【%d】┋ 覆盖轴【%d】┋ 始&末贴K帧【%d+%d】┋ 过短&过长轴【%d+%d】┋ 字数多【%d】\n\n",
        stats.total.flash_issue,
        stats.total.overlap_issue,
        stats.total.full_coverage_issue,
        stats.total.start_time_keyframe_issue, stats.total.end_time_keyframe_issue,
        stats.total.short_duration_issue, stats.total.long_duration_issue,
        stats.total.long_text_issue
    )
    return text
end


--========================= TimingCheck =========================--
-- 处理关键帧贴合
function TimingCheck.process_keyframes(cur_line, keyframes, config, stats)
    local max_range = math.max(
        config.start_time_before_keyframe,
        config.start_time_after_keyframe,
        config.end_time_before_keyframe,
        config.end_time_after_keyframe
    )

    if max_range <= 0 or #keyframes == 0 then
        return
    end

    -- 查找相关关键帧
    local search_start = math.min(cur_line.start_time - max_range, cur_line.end_time - max_range)
    local search_end = math.max(cur_line.start_time + max_range, cur_line.end_time + max_range)
    local rel_keyframes = Keyframe.find_in_range(keyframes, search_start, search_end)

    -- 处理开始时间贴合
    TimingCheck.adjust_to_keyframe(
        cur_line,
        rel_keyframes,
        "start_time",
        config.start_time_before_keyframe,
        config.start_time_after_keyframe,
        config.check_only,
        stats,
        "start_time_keyframe_issue"
    )

    -- 处理结束时间贴合
    TimingCheck.adjust_to_keyframe(
        cur_line,
        rel_keyframes,
        "end_time",
        config.end_time_before_keyframe,
        config.end_time_after_keyframe,
        config.check_only,
        stats,
        "end_time_keyframe_issue"
    )
end

-- 调整时间到最近关键帧
function TimingCheck.adjust_to_keyframe(cur_line, rel_keyframes, time_type,
                                        before_threshold, after_threshold, check_only, stats, issue_type)
    -- time_type: "start_time" 或 "end_time"
    -- issue_type: "start_time_keyframe_issue" 或 "end_time_keyframe_issue"
    local process_time = cur_line[time_type]
    local kf_after, kf_before = nil, nil

    if before_threshold > 0 then
        kf_after = Keyframe.find_nearest(rel_keyframes, process_time, before_threshold, "after")
    end
    if after_threshold > 0 and process_time ~= kf_after then
        kf_before = Keyframe.find_nearest(rel_keyframes, process_time, after_threshold, "before")
    end

    -- 选择最优关键帧
    local target_kf = kf_after or kf_before
    if kf_after and kf_before then
        target_kf = (kf_after - process_time < process_time - kf_before) and kf_after or kf_before
    end

    if target_kf and process_time ~= target_kf then
        Stats.update(stats, cur_line.line_obj.style, issue_type)
        local icon = check_only and "🔎" or "🔨"
        local label = time_type == "start_time" and "始K帧" or "末K帧"
        local arrow = target_kf == kf_after and "→" or "←"

        table.insert(cur_line.issues, {
            icon .. label .. arrow,
            check_only and Utils.ms_to_time_str(target_kf) or Utils.ms_to_time_str(process_time)
        })
        cur_line[time_type] = target_kf
    end
end

-- 处理相邻行叠轴与闪轴
function TimingCheck.process_adjacent(cur_line, next_line, keyframes, config, stats)
    local gap = next_line.start_time - cur_line.end_time

    -- 处理叠轴（gap<0且存在重叠）
    if gap < 0 and next_line.end_time > cur_line.start_time then
        -- 判断叠轴类型
        if next_line.start_time < cur_line.start_time then
            if next_line.end_time < cur_line.end_time then
                -- 后句叠在前句的开始时间位置
                TimingCheck.handle_overlap(next_line, cur_line, keyframes, config, stats)
            else
                -- 后句的时轴把前句的时轴全覆盖（不修正）
                Stats.update(stats, cur_line.line_obj.style, "full_coverage_issue")
                if cur_line.line_obj.style ~= next_line.line_obj.style then
                    Stats.update(stats, next_line.line_obj.style, "full_coverage_issue", true)
                end
                table.insert(cur_line.issues, {"🔎轴被全覆盖", string.format("L%d", next_line.row_num)})
                table.insert(next_line.issues, {"🔎轴全覆盖", string.format("L%d", cur_line.row_num)})
            end
        elseif next_line.end_time <= cur_line.end_time then
            -- 前句的时轴把后句的时轴全覆盖（不修正）
            Stats.update(stats, cur_line.line_obj.style, "full_coverage_issue")
            if cur_line.line_obj.style ~= next_line.line_obj.style then
                Stats.update(stats, next_line.line_obj.style, "full_coverage_issue", true)
            end
            table.insert(cur_line.issues, {"🔎轴全覆盖", string.format("L%d", next_line.row_num)})
            table.insert(next_line.issues, {"🔎轴被全覆盖", string.format("L%d", cur_line.row_num)})
        else
            -- 一般情况的叠轴
            TimingCheck.handle_overlap(cur_line, next_line, keyframes, config, stats)
        end
    -- 处理闪轴（gap>0且小于阈值）
    elseif gap > 0 and gap < config.flash_threshold then
        TimingCheck.handle_flash(cur_line, next_line, keyframes, config, stats)
    -- 处理逆序闪轴（后句在前且有间隙）
    elseif gap < 0 and next_line.end_time < cur_line.start_time then
        local rev_gap = cur_line.start_time - next_line.end_time
        if rev_gap > 0 and rev_gap < config.flash_threshold then
            TimingCheck.handle_flash(next_line, cur_line, keyframes, config, stats)
        end
    end
end

-- 处理叠轴
function TimingCheck.handle_overlap(line_p, line_q, keyframes, config, stats)
    Stats.update(stats, line_p.line_obj.style, "overlap_issue")
    if line_p.line_obj.style ~= line_q.line_obj.style then
        Stats.update(stats, line_q.line_obj.style, "overlap_issue", true)
    end

    -- 计算分割时间
    local overlap = line_p.end_time - line_q.start_time
    local p_overlap = math.floor(overlap * config.overlap_prev_ratio / 100 + 0.5)
    local split_time = line_p.end_time - (overlap - p_overlap)

    -- 关键帧贴合优先
    if config.overlap_keyframe_prioritize then
        local rel_keyframes = Keyframe.find_in_range(keyframes, line_q.start_time, line_p.end_time)
        local kf_before = Keyframe.find_nearest(rel_keyframes, split_time, p_overlap, "before")
        local kf_after = Keyframe.find_nearest(rel_keyframes, split_time, overlap - p_overlap, "after")

        if kf_before or kf_after then
            split_time = (kf_before and kf_after) and 
                                (split_time - kf_before <= kf_after - split_time and kf_before or kf_after) or
                                (kf_before or kf_after)
        end
    end

    if config.check_only then
        table.insert(line_p.issues, {
            "🔎末叠轴" .. (line_p.end_time < split_time and "→" or "←"),
            string.format("L%d◈%s", line_q.row_num, Utils.ms_to_time_str(split_time))
        })
        table.insert(line_q.issues, {
            "🔎始叠轴" .. (line_q.start_time < split_time and "→" or "←"),
            string.format("L%d◈%s", line_p.row_num, Utils.ms_to_time_str(split_time))
        })
    else
        table.insert(line_p.issues, {
            "🔨末叠轴" .. (line_p.end_time < split_time and "→" or "←"),
            string.format("L%d◈%s", line_q.row_num, Utils.ms_to_time_str(line_p.end_time))
        })
        table.insert(line_q.issues, {
            "🔨始叠轴" .. (line_q.start_time < split_time and "→" or "←"),
            string.format("L%d◈%s", line_p.row_num, Utils.ms_to_time_str(line_q.start_time))
        })
    end

    line_p.end_time = split_time
    line_q.start_time = split_time
end

-- 处理闪轴
function TimingCheck.handle_flash(line_p, line_q, keyframes, config, stats)
    Stats.update(stats, line_p.line_obj.style, "flash_issue")
    if line_p.line_obj.style ~= line_q.line_obj.style then
        Stats.update(stats, line_q.line_obj.style, "flash_issue", true)
    end

    -- 计算分割时间
    local gap = line_q.start_time - line_p.end_time
    local p_gap = math.floor(gap * config.flash_prev_ratio / 100 + 0.5)
    local split_time = line_p.end_time + p_gap

    -- 关键帧贴合优先
    if config.flash_keyframe_prioritize then
        local rel_kf = Keyframe.find_in_range(keyframes, line_p.end_time, line_q.start_time)
        local kf_before = Keyframe.find_nearest(rel_kf, split_time, p_gap, "before")
        local kf_after = Keyframe.find_nearest(rel_kf, split_time, gap - p_gap, "after")

        if kf_before or kf_after then
            split_time = (kf_before and kf_after) and 
                                (split_time - kf_before <= kf_after - split_time and kf_before or kf_after) or
                                (kf_before or kf_after)
        end
    end

    if config.check_only then
        table.insert(line_p.issues, {
            "🔎末闪轴" .. (line_p.end_time < split_time and "→" or "←"),
            string.format("L%d◈%s", line_q.row_num, Utils.ms_to_time_str(split_time))
        })
        table.insert(line_q.issues, {
            "🔎始闪轴" .. (line_q.start_time < split_time and "→" or "←"),
            string.format("L%d◈%s", line_p.row_num, Utils.ms_to_time_str(split_time))
        })
    else
        table.insert(line_p.issues, {
            "🔨末闪轴" .. (line_p.end_time < split_time and "→" or "←"),
            string.format("L%d◈%s", line_q.row_num, Utils.ms_to_time_str(line_p.end_time))
        })
        table.insert(line_q.issues, {
            "🔨始闪轴" .. (line_q.start_time < split_time and "→" or "←"),
            string.format("L%d◈%s", line_p.row_num, Utils.ms_to_time_str(line_q.start_time))
        })
    end

    -- 应用调整
    line_p.end_time = split_time
    line_q.start_time = split_time
end

-- 检查时长问题
function TimingCheck.check_duration(line, config, stats)
    local duration = line.end_time - line.start_time

    if duration < config.min_duration then
        Stats.update(stats, line.line_obj.style, "short_duration_issue")
        table.insert(line.issues, {"🔎过短轴", duration .. "ms" .. (duration < 0 and "★末时间<始时间" or "")})
    end

    if duration > config.max_duration then
        Stats.update(stats, line.line_obj.style, "long_duration_issue")
        table.insert(line.issues, {"🔎过长轴", duration .. "ms"})
    end
end

-- 检查文本长度
function TimingCheck.check_text_length(line, config, stats)
    local char_count = Utils.count_stripped_text(line.line_obj.text)
    if char_count > config.max_chars then
        Stats.update(stats, line.line_obj.style, "long_text_issue")
        table.insert(line.issues, {"🔎超字数", char_count})
    end
end


--========================= CharReplace =========================--
-- 删除句首句末符号
function CharReplace.trim(segments, text_indices, regex)
    local changed = false
    if #text_indices == 0 then
        return changed
    end


    local segment = segments[text_indices[1]]
    local new_content = re.sub(segment.content, "^(?:" .. regex .. ")+", "")
    if new_content ~= segment.content then
        changed = true
        segment.content = new_content
    end

    segment = segments[text_indices[#text_indices]]
    new_content = re.sub(segment.content, "(?:" .. regex .. ")+$", "")
    if new_content ~= segment.content then
        changed = true
        segment.content = new_content
    end
    return changed
end

-- 替换指定字符
function CharReplace.replace(segments, text_indices, regex, replacement)
    local changed = false
    if #text_indices == 0 then
        return changed
    end

    local regex_cp = re.compile(regex)
    for _, idx in ipairs(text_indices) do
        local segment = segments[idx]
        local new_content = regex_cp:sub(segment.content, replacement)
        if new_content ~= segment.content then
            changed = true
            segment.content = new_content
        end
    end
    return changed
end

-- 替换引号
function CharReplace.replace_quotes(segments, text_indices, quotes_array, new_quotes)
    local changed = false
    if #text_indices == 0 then
        return changed
    end

    -- 存放开、闭相同字符的引号
    local same_quote_array = {}
    -- 存放开、闭不同字符的引号
    local diff_quotes_array = {{}, {}}
    for _, quotes in ipairs(quotes_array) do
        local front_quote, back_quote = quotes[1], quotes[2]

        if front_quote == back_quote then
            table.insert(same_quote_array, front_quote)
        else
            table.insert(diff_quotes_array[1], front_quote)
            table.insert(diff_quotes_array[2], back_quote)
        end
    end

    -- 先处理没有方向性的引号
    for _, quote in ipairs(same_quote_array) do
        local regex_cp = re.compile(quote .. "(.*?)" .. quote)
        local replacement = new_quotes[1] .."\\1" .. new_quotes[2]

        for _, idx in ipairs(text_indices) do
            local segment = segments[idx]
            local new_content = regex_cp:sub(segment.content, replacement)
            if new_content ~= segment.content then
                changed = true
                segment.content = new_content
            end
        end
    end

    -- 一次性处理掉开、闭引号
    for i, quotes_array in ipairs(diff_quotes_array) do
        local multi_quotes_regex = "[" .. table.concat(quotes_array, "") .. "]"
        if multi_quotes_regex ~= "[]" then
            local regex_cp = re.compile(multi_quotes_regex)
            local replacement = new_quotes[i]

            for _, idx in ipairs(text_indices) do
                local segment = segments[idx]
                local new_content = regex_cp:sub(segment.content, replacement)
                if new_content ~= segment.content then
                    changed = true
                    segment.content = new_content
                end
            end
        end
    end

    return changed
end

-- 替换英文单词前后的一个及以上的半角或全角空格为单个半角空格
function CharReplace.normalize_english_word_spaces(segments, text_indices)
    local function protect_sp_char(x)
        return x == "\\h" and "\x01" or (x == "\\n" and "\x02" or "\x03")
    end

    local function restore_protected_sp_char(x)
        return x == "\x01" and "\\h" or (x == "\x02" and "\\n" or "\\N")
    end

    local changed = false
    local protect_sp_char_regex_cp = re.compile("\\\\[hnN]")
    local restore_protected_sp_char_regex_cp = re.compile("[\x01\x02\x03]")
    local start_space_regex_cp = re.compile("^[ 　]+")
    local end_space_regex_cp = re.compile("[ 　]+$")
    local front_space_en_word_regex_cp = re.compile("[ 　]+([a-zA-Z'%-])")
    local back_space_en_word_regex_cp = re.compile("([a-zA-Z'%-])[ 　]+")

    for _, idx in ipairs(text_indices) do
        local content = segments[idx].content
        -- 保留句首的空格
        local start_space = start_space_regex_cp:find(content)
        if start_space then
            content = content:sub(start_space.last + 1)
        end
        -- 保留句末的空格
        local end_space = end_space_regex_cp:find(content)
        if end_space then
            content = content:sub(1, end_space.first - 1)
        end

        -- 保护三个ass字幕文本特殊符号\h、\n、\N，防止正则匹配时误认为是单词
        content = protect_sp_char_regex_cp:sub(content, protect_sp_char)

        local tmp_content = content
        -- 单词前的空格（且非句首）：替换为单个半角空格
        content = front_space_en_word_regex_cp:sub(content, " \\1")

        -- 单词后的空格（且非句末）：替换为单个半角空格
        content = back_space_en_word_regex_cp:sub(content, "\\1 ")

        -- 文本没有改变过就不用还原被保护的字符和句首句末保留的空格
        if tmp_content ~= content then
            changed = true

            -- 还原三个被保护的ass字幕文本特殊符号\h、\n、\N
            content = restore_protected_sp_char_regex_cp:sub(content, restore_protected_sp_char)
            -- 还原保留的句首空格
            if start_space then
                content = start_space.str .. content
            end

            -- 还原保留的句末空格
            if end_space then
                content = content .. end_space.str
            end

            segments[idx].content = content
        end
    end
    return changed
end


--========================= TagCheck =========================--
-- 标记问题
function TagCheck.add_issue(issues, msg)
    issues[msg] = true
end

-- 验证标签参数值
function TagCheck.validate_value(issues, tag_name, value)
    -- value不能传入nil
    if tag_name == "fn" or tag_name == "r" or value == "" then
        return
    end

    local function check_int(param_min, param_max)
        local param = Utils.str_to_int(value)
        if not param or param < param_min or param > param_max then
            TagCheck.add_issue(issues.error, string.format("\\%s值无效(需%d~%d)", tag_name, param_min, param_max))
            return false
        end
        return true
    end

    local function check_decimals(param_min)
        local param = Utils.str_to_decimal(value)
        if not param or (param_min and param < param_min) then
            local extra_msg = param_min and "(需大于" .. param_min .. ")" or ""
            TagCheck.add_issue(issues.error, string.format("\\%s值无效%s", tag_name, extra_msg))
            return false
        end
        return true
    end

    local function check_multi_decimals(...)
        local params = {}
        for p in value:gmatch("[^,]+") do
            local param = Utils.str_to_decimal(p)
            if param then
                table.insert(params, param)
            else
                TagCheck.add_issue(issues.error, "\\" .. tag_name .. "值无效")
                return false
            end
        end

        local check_pass = false
        for _, n in ipairs({...}) do
            if #params == n then
                check_pass = true
                break
            end
        end

        if not check_pass then
            TagCheck.add_issue(issues.error, "\\" .. tag_name .. "参数个数错误")
            return false
        end
        return true
    end

    if TagCheck.COLOR_TAGS[tag_name] then
        -- \c \1c \2c \3c \4c (&HBBGGRR& 6位)
        if not re.match(value, "^ *&H[\\da-fA-F]{6}& *$") then
            if re.match(value, "^ *&?H?[\\da-fA-F]{1,6}&? *$") then
                TagCheck.add_issue(issues.warn, "\\" .. tag_name .. "格式不标准")
            else
                TagCheck.add_issue(issues.error, "\\" .. tag_name .. "格式错误")
            end
        end
    elseif TagCheck.ALPHA_TAGS[tag_name] then
        -- \alpha \1a \2a \3a \4a (&HAA& 2位)
        if not re.match(value, "^ *&H[\\da-fA-F]{2}& *$") then
            if re.match(value, "^ *&?H?[\\da-fA-F]{1,2}&? *$") then
                TagCheck.add_issue(issues.warn, "\\" .. tag_name .. "格式不标准")
            else
                TagCheck.add_issue(issues.error, "\\" .. tag_name .. "格式错误")
            end
        end
    elseif tag_name == "an" or tag_name == "a" then
        -- \an \a (1-9)
        if tag_name == "a" then
            TagCheck.add_issue(issues.warn, "\\a已弃用(用\\an)")
        end

        check_int(1, 9)
    elseif tag_name == "q" then
        -- \q (0-3)
        check_int(0, 3)
    elseif tag_name == "i"
            or tag_name == "u"
            or tag_name == "s"
            or tag_name == "ortho" then
        -- \i \u \s \ortho (0或1)
        check_int(0, 1)
    elseif tag_name == "b" then
        -- \b (0, 1, 或 100-900)
        local num = Utils.str_to_int(value)
        if not num then
            TagCheck.add_issue(issues.error, "\\" .. tag_name .. "值无效")
        elseif num ~= 0 and num ~= 1 and (num < 100 or num > 900) then
            TagCheck.add_issue(issues.warn, "\\" .. tag_name .. "值异常")
        end
    elseif tag_name == "p" then
    -- \p (非负整数)
        check_int(0, 99)
    elseif tag_name == "k"
            or tag_name == "K"
            or tag_name == "kf"
            or tag_name == "ko" then
    -- \k \K \kf \ko (非负整数)
        check_int(0, 9999)
    elseif tag_name == "fe" then
        local num = Utils.str_to_int(value)
        if not num then
            TagCheck.add_issue(issues.error, "\\" .. tag_name .. "值无效")
        elseif not TagCheck.VALID_FONT_CODE[num] then
            TagCheck.add_issue(issues.warn, "\\" .. tag_name .. "值异常")
        end
    elseif tag_name == "fs"
            or tag_name == "fscx"
            or tag_name == "fscy"
            or tag_name == "be"
            or tag_name == "blur"
            or tag_name == "fsc"
            or tag_name == "xblur"
            or tag_name == "yblur" then
        -- \fs \fscx \fscy \fe \be \blur \fsc \xblur \yblur (非负数)
        check_decimals(0)
    elseif tag_name == "fsp"
            or tag_name == "fr"
            or tag_name == "frx"
            or tag_name == "fry"
            or tag_name == "frz"
            or tag_name == "fax"
            or tag_name == "fay"
            or tag_name == "bord"
            or tag_name == "xbord"
            or tag_name == "ybord"
            or tag_name == "shad"
            or tag_name == "xshad"
            or tag_name == "yshad"
            or tag_name == "pbo"
            or tag_name == "z"
            or tag_name == "frs"
            or tag_name == "fsvp"
            or tag_name == "fshp"
            or tag_name == "rnd"
            or tag_name == "rndx"
            or tag_name == "rndy"
            or tag_name == "rndz" then
        -- \fsp \fr \frx \fry \frz \fax \fay \bord \xbord \ybord \shad \xshad \yshad (任意数值)
        -- \z \frs \fsvp \fshp \rnd \rndx \rndy \rndz (任意数值)
        check_decimals(-99999)
    elseif tag_name == "pos" or tag_name == "org" or tag_name == "fad" then
        -- \pos \org \fad
        check_multi_decimals(2)
    elseif tag_name == "move" then
        -- \move
        check_multi_decimals(4, 6)
    elseif tag_name == "fade" then
        -- \fade
        check_multi_decimals(7)
    elseif tag_name == "clip" or tag_name == "iclip" then
        -- \clip \iclip
        local parts = {}
        for p in value:gmatch("[^,]+") do
            table.insert(parts, p)
        end

        if #parts == 1 then
            if not re.match(parts[1], "^[\\d .mnlbspc-]*$") then
                TagCheck.add_issue(issues.error, "\\" .. tag_name .. "值有误")
            end
        elseif #parts == 2 then
            if not (re.match(parts[1], "^ *[1-9]\\d* *$") and re.match(parts[2], "^[\\d .mnlbspc-]*$")) then
                TagCheck.add_issue(issues.error, "\\" .. tag_name .. "值有误")
            end
        elseif #parts > 2 then
            check_multi_decimals(4)
        end
    elseif tag_name == "jitter" then
        -- \jitter
        check_multi_decimals(5, 6)
    elseif tag_name == "distort" then
        -- \distort
        check_multi_decimals(6)
    elseif tag_name == "moves3" then
        -- \moves3
        check_multi_decimals(6, 8)
    elseif tag_name == "moves4" or tag_name == "mover" then
        -- \moves4 \mover
        check_multi_decimals(8, 10)
    elseif tag_name == "movevc" then
        -- \movevc
        check_multi_decimals(2, 4, 6)
    elseif tag_name == "1vc"
            or tag_name == "2vc"
            or tag_name == "3vc"
            or tag_name == "4vc" then
        -- \1vc \2vc \3vc \4vc
        if not re.match(value, "^ *&H[\\da-fA-F]{6}& *(?:, *&H[\\da-fA-F]{6}& *){3}$") then
            if re.match(value, "^ *&?H?[\\da-fA-F]{1,6}&? *(?:, *&?H?[\\da-fA-F]{1,6}&? *){3}$") then
                TagCheck.add_issue(issues.warn, "\\" .. tag_name .. "格式不标准")
            else
                TagCheck.add_issue(issues.error, "\\" .. tag_name .. "格式错误")
            end
        end
    elseif tag_name == "1va"
            or tag_name == "2va"
            or tag_name == "3va"
            or tag_name == "4va" then
        -- \1va \2va \3va \4va
        if not re.match(value, "^ *&H[\\da-fA-F]{2}& *(?:, *&H[\\da-fA-F]{2}& *){3}$") then
            if re.match(value, "^ *&?H?[\\da-fA-F]{1,2}&? *(?:, *&?H?[\\da-fA-F]{1,2}&? *){3}$") then
                TagCheck.add_issue(issues.warn, "\\" .. tag_name .. "格式不标准")
            else
                TagCheck.add_issue(issues.error, "\\" .. tag_name .. "格式错误")
            end
        end
    elseif tag_name == "1img"
            or tag_name == "2img"
            or tag_name == "3img"
            or tag_name == "4img" then
        -- \1img \2img \3img \4img
        local parts = {}
        for p in value:gmatch("[^,]+") do
            table.insert(parts, p)
        end

        if #parts == 3 then
            if not Utils.str_to_decimal(parts[2]) or not Utils.str_to_decimal(parts[3]) then
                TagCheck.add_issue(issues.error, "\\" .. tag_name .. "值有误")
            end
        elseif #parts > 1 then
            TagCheck.add_issue(issues.error, "\\" .. tag_name .. "参数个数错误")
        end
    end
end

-- 标签解析
function TagCheck.parse_tag_block(issues, block)
    local pos = 1
    local len = #block

    while pos <= len do
        -- 查找反斜杠
        local slash_start, slash_end = block:find("\\+", pos)
        if not slash_start then
            break
        end

        if slash_start ~= slash_end then
            TagCheck.add_issue(issues.warn, "连续的" .. string.rep("\\", slash_end - slash_start + 1))
        end

        pos = slash_end + 1
        if pos > len then
            TagCheck.add_issue(issues.warn, "\\后面无内容")
            break
        end

        -- 提取标签名
        local tag_name = nil
        -- 标签结束位置的下一位
        local tag_end = nil

        -- 先尝试匹配数字开头的标签 (1c, 2c, 3c, 4c, 1a, 2a, 3a, 4a)
        tag_name = block:match("^([1-4][ac])", pos)
        if tag_name then
            tag_end = pos + #tag_name
        else
            -- 匹配普通字母标签
            tag_name = block:match("^([a-zA-Z]+)", pos)
            if tag_name then
                if tag_name:match("^fn") then
                    tag_name = "fn"
                elseif tag_name:match("^r") then
                    local tmp_tag_name = tag_name:match("^rnd[xyz]?")
                    if tmp_tag_name then
                        tag_name = tmp_tag_name
                    else
                        tag_name = "r"
                    end
                end
                tag_end = pos + #tag_name
            end
        end

        if not tag_name then
            -- 无法识别的标签
            tag_end = block:find("\\", pos) or len + 1
            -- 前面已经判断\后面肯定有内容
            TagCheck.add_issue(issues.error, "无效标签:\\" .. block:sub(pos, tag_end - 1))
            pos = tag_end
        elseif not TagCheck.STANDARD_TAGS[tag_name] and not TagCheck.VSFILTERMOD_TAGS[tag_name] then
            TagCheck.add_issue(issues.error, "未知标签:\\" .. tag_name)
            pos = tag_end
        else
            -- 标签存在
            if TagCheck.VSFILTERMOD_TAGS[tag_name] then
                TagCheck.add_issue(issues.warn, "VSF扩展:\\" .. tag_name)
            end

            local value = nil
            if TagCheck.PAREN_TAGS[tag_name] then
                -- 处理需要括号的标签，查找匹配括号的位置
                local paren_start, paren_end = block:find("%b()", tag_end)
                -- 是紧跟着标签的括号，tag_end不会是nil
                if paren_start == tag_end then
                    value = block:sub(paren_start + 1, paren_end - 1)
                    pos = paren_end + 1
                else
                    if block:sub(tag_end, tag_end) == "(" then
                        TagCheck.add_issue(issues.error, "\\" .. tag_name .. "()号未闭合")
                    else
                        TagCheck.add_issue(issues.error, "\\" .. tag_name .. "缺少()")
                    end
                    pos = tag_end + 1
                end
            else
                -- 不需要括号的标签
                local value_end = block:find("\\", tag_end) or len + 1
                value = block:sub(tag_end, value_end - 1)
                pos = value_end
            end

            if value then
                TagCheck.validate_value(issues, tag_name, value)
            end
        end
    end
end

-- 检查每行的标签格式
function TagCheck.check_line(text)
    local issues = {
        error = {},
        warn = {},
    }

    if not text or text == "" then
        return {}, {}
    end

    -- 检查大括号匹配
    if text:gsub("%b{}", ""):match("[{}]") then
        TagCheck.add_issue(issues.error, "{}不匹配")
    end

    -- 嵌套/重复大括号
    if text:match("{[^}]-{") or text:match("}[^{]-}") then
        TagCheck.add_issue(issues.error, "{}嵌套或重复")
    end

    -- 空标签块
    if text:match("{ *}") then
        TagCheck.add_issue(issues.warn, "空标签块{}")
    end

    -- 检查是否有标签块在大括号外
    if text:gsub("{.-}", ""):gsub("\\[Nnh]", ""):match("\\[a-zA-Z1-4]") then
        TagCheck.add_issue(issues.warn, "标签在{}外")
    end

    -- 统计特定标签出现次数
    local pos_count, move_count, org_count, an_count = 0, 0, 0, 0

    -- 遍历每个标签块
    for block in text:gmatch("{(.-)}") do
        -- 检查小括号匹配
        if block:gsub("%b()", ""):match("[()]") then
            TagCheck.add_issue(issues.error, "()不匹配")
        end

        for _ in block:gmatch("\\pos%s*%(") do
            pos_count = pos_count + 1
        end
        for _ in block:gmatch("\\move%s*%(") do
            move_count = move_count + 1
        end
        for _ in block:gmatch("\\org%s*%(") do
            org_count = org_count + 1
        end
        for _ in block:gmatch("\\an?%d") do
            an_count = an_count + 1
        end

        -- 解析标签块
        TagCheck.parse_tag_block(issues, block)
    end

    -- 检查位置标签冲突
    if pos_count > 0 and move_count > 0 then
        TagCheck.add_issue(issues.warn, "\\pos与\\move冲突")
    end
    if pos_count > 1 then
        TagCheck.add_issue(issues.warn, "多个\\pos")
    end
    if move_count > 1 then
        TagCheck.add_issue(issues.warn, "多个\\move")
    end
    if org_count > 1 then
        TagCheck.add_issue(issues.warn, "多个\\org")
    end
    if an_count > 1 then
        TagCheck.add_issue(issues.warn, "多个\\a或\\an")
    end

    local error_list = {}
    local warn_list = {}
    for k, _ in pairs(issues.error) do
        table.insert(error_list, k)
    end
    for k, _ in pairs(issues.warn) do
        table.insert(warn_list, k)
    end

    return error_list, warn_list
end


--========================= TypoCheck =========================--
-- 加载错字文件
function TypoCheck.load_typo_dict()
    local file, err = io.open(Config.TYPO_DICT_FILE_PATH, "r")
    if not file then
        if err:find("No such file") then
            Utils.alert("没找到错字字典文件：" .. Config.TYPO_DICT_FILE_PATH)
        else
            Utils.alert("打开错字字典文件出错：" .. err)
        end
        return nil
    end

    local content = file:read("*a")
    file:close()

    local func, parse_err = Utils.IS_LUA51 and loadstring(content) or load(content)
    if not func then
        Utils.alert("解析错字字典文件出错：" .. parse_err)
        return nil
    end

    local ok, typo_dict = pcall(func)
    if not ok or type(typo_dict) ~= "table" then
        Utils.alert("加载错字字典数据出错：" .. typo_dict)
        return nil
    end

    if next(typo_dict) == nil then
        Utils.alert("错字字典没有数据")
        return nil
    end

    return typo_dict
end

-- 检查每行的错字
function TypoCheck.check_line(typo_dict, text)
    local issues = {}

    if not text or text == "" then
        return issues
    end

    for _, rule in ipairs(typo_dict) do
        if re.find(text, rule.pattern) then
            if rule.mark then
                table.insert(issues, rule.mark)
            else
                table.insert(issues, rule.pattern .. "→" .. rule.replacement)
            end
        end
    end
    return issues
end

--========================= ContentSweep =========================--
-- 清除繁化姬标记
function ContentSweep.line_sweep_fanhuaji(line_obj)
    if line_obj.class == "info" and line_obj.key == "Comment" and line_obj.value:match("^ *Processed by 繁化姬")
        or (line_obj.class == "dialogue" and line_obj.text:match("^ *Processed by 繁化姬")) then
        return nil, true
    end
    return line_obj, false
end

-- 清除Actor列的NTP标记
function ContentSweep.line_sweep_actor_ntp(line_obj)
    if line_obj.class == "dialogue" and line_obj.actor == "NTP" then
        line_obj.actor = ""
        return line_obj, true
    end
    return line_obj, false
end

 -- 清除Aegisub-Motion插件信息
function ContentSweep.line_sweep_aegisub_motion_plugin_info(line_obj)
    if line_obj.class == "dialogue" and not line_obj.comment then
        local match = line_obj.text:match("^{=%-?%d+}")
        if match then
            line_obj.text = line_obj.text:sub(#match + 1)
            return line_obj, true
        end
    elseif line_obj.class == "unknown" and line_obj.section == "[Aegisub Extradata]" then
        return nil, true
    end
    return line_obj, false
end

-- 清除ass字幕非标准段的内容
function ContentSweep.line_sweep_nonstandard_section(line_obj)
    if line_obj.class == "unknown" then
        return nil, true
    end
    return line_obj, false
end

-- 清除ass字幕末尾文本为空的行
function ContentSweep.sweep_last_notext_line(subtitles)
    local changed = false
    for i = #subtitles, 1, -1 do
        local line_obj = subtitles[i]
        if line_obj.class == "dialogue" then
            if line_obj.text == "" then
                subtitles.delete(i)
                changed = true
            else
                break
            end
        end
    end
    return changed
end

-- 统计有使用过的样式
function ContentSweep.line_stat_used_style(line_obj, stat_style_set)
    if line_obj.class == "dialogue" and not line_obj.comment then
        -- 统计行样式列标注的样式
        if line_obj.style then
            stat_style_set[line_obj.style] = true
        end

        -- 统计\r标签用到的样式（找每个标签块中最后一次出现的\r即可）
        for tag_str in re.gfind(line_obj.text, "\\{(?:[^}]*?\\\\r[^\\\\{}]+)+") do
            local match = re.match(tag_str, "\\\\r *([^\\\\{}]*?) *$")
            -- 此处宁可多统计，忽略vsfiltermod的标签\rnd、\rndx、\rndy、\rndz和特殊还原用法\r0
            if match then
                -- 第2个match开始才是括号的捕获值
                stat_style_set[match[2].str] = true
            end
        end
    end
    return line_obj, false
end

-- 统计定义的样式
function ContentSweep.line_stat_defined_style(line_obj, stat_style_set)
    if line_obj.class == "style" then
        stat_style_set[line_obj.name] = true
    end
    return line_obj, false
end

-- 清除未使用的样式定义
function ContentSweep.sweep_useless_style(subtitles, used_style_set)
    local changed = false
    local subs_len = #subtitles
    local i = 1
    while i <= subs_len do
        local line_obj = subtitles[i]
        if line_obj.class == "style" and not used_style_set[line_obj.name] then
            subtitles.delete(i)
            subs_len = subs_len - 1
            changed = true
        else
            i = i + 1
        end
    end
    return changed
end


--========================= GUI =========================--
-- 创建TimeCheck主界面
function GUI.time_check_create_ui(subtitles, selected_lines)
    local config = Config.load()
    local original_config = Utils.deep_copy(config)
    local styles = GUI.get_available_styles(subtitles)

    if #styles == 0 then
        Utils.alert("在非注释字幕行没有找到任何样式")
        return
    end

    while true do
        local dialog = GUI.time_check_build_dialog_elements(styles, config)
        local buttons = {"保存配置", "仅检查", "检查＆执行校正", "取消"}
        local button, results = aegisub.dialog.display(dialog, buttons)

        if not button or button == "取消" then
            return
        end

        -- 处理用户输入
        config = GUI.time_check_parse_dialog_results(results, styles, config)
        if next(config.time_check_selected_styles) == nil then
            Utils.alert("请至少选择一项样式")
        elseif button == "保存配置" then
            Config.save(config)
            Utils.alert("当前选项配置保存完毕")
        else
            if config.time_check_save_config_on_execute and not Utils.table_equal(config, original_config) then
                Config.save(config)
            end

            config = Config.validate(config)
            if button == "仅检查" then
                config = Config.set_check_only(config)
            end

            if config.time_check_clear_tips_before_execute then
                GUI.clear_tips_process(subtitles, false)
            end

            aegisub.set_undo_point("时轴检查＆校正")
            GUI.time_check_process(subtitles, selected_lines, config)
            return
        end
    end
end

-- 构建TimeCheck对话框元素
function GUI.time_check_build_dialog_elements(styles, config)
    local dialog = {}

    -- 左侧样式选择区
    table.insert(dialog, {
        class = "label",
        label = "━━━━━━★ 仅对选择的样式操作 ━━━━━━━\n(多选的样式会当成一个整体处理)",
        x = 0, y = 0, width = 2, height = 2
    })
    for i, style in ipairs(styles) do
        table.insert(dialog, {
            class = "checkbox",
            label = style,
            name = "style_" .. i,
            value = config.time_check_selected_styles[style],
            x = 0, y = i + 1, width = 2, height = 1
        })
    end

    -- 右侧配置区
    local x = 3
    local y = 0

    local function next_line_elem(element)
        if element then
            element.x = element.x or x
            element.y = element.y or y
            element.height = element.height or 1
            table.insert(dialog, element)
            y = element.y + element.height
        else
            y = y + 1
        end
    end

    next_line_elem({class="label", label="━━━★ 选项 ━━━━", width=20})
    next_line_elem({class="checkbox", label="执行前先清除本工具此前在字幕中输出的所有提示内容",
                    name="time_check_clear_tips_before_execute", value=config.time_check_clear_tips_before_execute,
                    width=12})
    next_line_elem({class="checkbox", label="执行后自动保存当前的选项配置", name="time_check_save_config_on_execute",
                    value=config.time_check_save_config_on_execute, width=12})
    next_line_elem({class="checkbox", label="仅对选择的字幕行操作", name="time_check_selected_only",
                    value=config.time_check_selected_only, width=12})
    next_line_elem({class="checkbox", label="忽略文本为空的行(但仅含标签的不忽略)", name="ignore_no_text",
                    value=config.ignore_no_text, x=x+12, y=y-3, width=7})
    next_line_elem({class="checkbox", label="内部对字幕进行时间升序排序后再处理", name="sort_by_time",
                    value=config.sort_by_time, x=x+12, width=7})
    next_line_elem({class="label", label="", x=x+12})
    next_line_elem()

    -- 关键帧设置
    next_line_elem({class="label", label="━━━★ 关键帧贴合检查&修正 (输入小于10ms当0ms处理；输入0ms即不执行) ━━━━",
                    width=20})
    next_line_elem({class="label", label="开始时间小于关键帧时间", width=6})
    next_line_elem({class="intedit", name="start_time_before_keyframe",
                    value=config.start_time_before_keyframe, x=x+6, y=y-1, width=2, min=0, max=999999})
    next_line_elem({class="label", label="毫秒以内，则增大至贴合", x=x+8, y=y-1, width=5})

    next_line_elem({class="label", label="开始时间大于关键帧时间", width=6})
    next_line_elem({class="intedit", name="start_time_after_keyframe",
                    value=config.start_time_after_keyframe, x=x+6, y=y-1, width=2, min=0, max=999999})
    next_line_elem({class="label", label="毫秒以内，则缩小至贴合", x=x+8, y=y-1, width=5})

    next_line_elem({class="label", label="结束时间小于关键帧时间", width=6})
    next_line_elem({class="intedit", name="end_time_before_keyframe",
                    value=config.end_time_before_keyframe, x=x+6, y=y-1, width=2, min=0, max=999999})
    next_line_elem({class="label", label="毫秒以内，则增大至贴合", x=x+8, y=y-1, width=5})

    next_line_elem({class="label", label="结束时间大于关键帧时间", width=6})
    next_line_elem({class="intedit", name="end_time_after_keyframe",
                    value=config.end_time_after_keyframe, x=x+6, y=y-1, width=2, min=0, max=999999})
    next_line_elem({class="label", label="毫秒以内，则缩小至贴合", x=x+8, y=y-1, width=5})
    next_line_elem()

    -- 闪轴设置
    next_line_elem({class="label", label="━━━★ 相邻行闪轴检查&修正 (输入小于10ms当0ms处理；输入0ms即不执行) ━━━━",
                    width=20})
    next_line_elem({class="checkbox", label="闪轴间隙含关键帧时，关键帧贴合优先", name="flash_keyframe_prioritize",
                    value=config.flash_keyframe_prioritize, width=20})
    next_line_elem({class="label", label="闪轴间隙:", width=3})
    next_line_elem({class="intedit", name="flash_threshold",
                    value=config.flash_threshold, x=x+3, y=y-1, width=3, min=0, max=999999})
    next_line_elem({class="label", label="毫秒以内", x=x+6, y=y-1, width=2})
    next_line_elem({class="label", label="闪轴间隙分配比例: 上一句结束时间增大间隙时间的", width=10})
    next_line_elem({class="intedit", name="flash_prev_ratio",
                    value=config.flash_prev_ratio, x=x+10, y=y-1, width=1, min=0, max=100})
    next_line_elem({class="label", label="% ，剩余比例缩小下一句开始时间", x=x+11, y=y-1, width=7})
    next_line_elem()

    -- 叠轴设置
    next_line_elem({class="label", label="━━━★ 相邻行叠轴检查&修正 (全覆盖轴不修正) ━━━━", width=20})
    next_line_elem({class="checkbox", label="重叠间隙含关键帧时，关键帧贴合优先", name="overlap_keyframe_prioritize",
                    value=config.overlap_keyframe_prioritize, width=20})
    next_line_elem({class="label", label="重叠间隙分配比例: 上一句结束时间缩小间隙时间的", width=10})
    next_line_elem({class="intedit", name="overlap_prev_ratio",
                    value=config.overlap_prev_ratio, x=x+10, y=y-1, width=1, min=0, max=100})
    next_line_elem({class="label", label="% ，剩余比例增大下一句开始时间", x=x+11, y=y-1, width=7})
    next_line_elem()

    -- 时长设置
    next_line_elem({class="label", label="━━━★ 过短轴&过长轴(仅检查) ━━━━", width=20})
    next_line_elem({class="label", label="单行最短时间:", width=5})
    next_line_elem({class="intedit", name="min_duration",
                    value=config.min_duration, x=x+5, y=y-1, width=3, min=10, max=999999})
    next_line_elem({class="label", label="毫秒", x=x+8, y=y-1, width=1})

    next_line_elem({class="label", label="单行最长时间:", width=5})
    next_line_elem({class="intedit", name="max_duration",
                    value=config.max_duration, x=x+5, y=y-1, width=3, min=10, max=9999999})
    next_line_elem({class="label", label="毫秒", x=x+8, y=y-1, width=1})
    next_line_elem()

    -- 文本长度设置
    next_line_elem({class="label", label="━━━★ 文本长度(仅检查) ━━━━", width=20})
    next_line_elem({class="label", label="单行最大字符数 (排除标签换行，含标点空格):", width=9})
    next_line_elem({class="intedit", name="max_chars", value=config.max_chars, x=x+9, y=y-1, width=2, min=1, max=999})

    return dialog
end

-- 解析TimeCheck对话框结果
function GUI.time_check_parse_dialog_results(results, styles, config)
    local new_config = Utils.deep_copy(config)
    new_config.time_check_clear_tips_before_execute = results.time_check_clear_tips_before_execute
    new_config.time_check_save_config_on_execute = results.time_check_save_config_on_execute
    new_config.time_check_selected_only = results.time_check_selected_only
    new_config.ignore_no_text = results.ignore_no_text
    new_config.sort_by_time = results.sort_by_time
    new_config.flash_threshold = results.flash_threshold
    new_config.flash_prev_ratio = results.flash_prev_ratio
    new_config.flash_keyframe_prioritize = results.flash_keyframe_prioritize
    new_config.overlap_keyframe_prioritize = results.overlap_keyframe_prioritize
    new_config.overlap_prev_ratio = results.overlap_prev_ratio
    new_config.start_time_before_keyframe = results.start_time_before_keyframe
    new_config.start_time_after_keyframe = results.start_time_after_keyframe
    new_config.end_time_before_keyframe = results.end_time_before_keyframe
    new_config.end_time_after_keyframe = results.end_time_after_keyframe
    new_config.min_duration = results.min_duration
    new_config.max_duration = results.max_duration
    new_config.max_chars = results.max_chars

    -- 解析选中的样式
    new_config.time_check_selected_styles = {}
    for i, style in ipairs(styles) do
        if results["style_" .. i] then
            new_config.time_check_selected_styles[style] = true
        end
    end
    return new_config
end

-- 进行TimeCheck处理
function GUI.time_check_process(subtitles, selected_lines, config)
    -- 准备处理的行数据
    local lines = GUI.time_check_prepare_lines(subtitles, selected_lines, config)
    if #lines == 0 then
        Utils.alert("没有符合条件的字幕行")
        return
    end

    -- 按时间排序
    if config.sort_by_time then
        table.sort(lines, function(a, b)
            if a.start_time == b.start_time then
                return a.end_time < b.end_time
            end
            return a.start_time < b.start_time
        end)
    end

    -- 初始化统计和关键帧
    local stats = Stats.create(config.time_check_selected_styles)
    local keyframes = Keyframe.get_all()
    if not next(keyframes) then
        Utils.log("⚠️ 没有找到关键帧信息！关键帧相关的检查和处理将无效！")
    end

    -- 处理关键帧贴合
    for _, line in ipairs(lines) do
        TimingCheck.process_keyframes(line, keyframes, config, stats)
    end

    -- 处理相邻行关系（叠轴/闪轴）
    for i = 1, #lines - 1 do
        TimingCheck.process_adjacent(lines[i], lines[i + 1], keyframes, config, stats)
    end

    -- 处理时长和文本检查 & 填充检测结果
    for _, line in ipairs(lines) do
        TimingCheck.check_duration(line, config, stats)
        TimingCheck.check_text_length(line, config, stats)

        -- 填充检测结果到字幕中
        GUI.time_check_update_subtitle_line(line, subtitles, config)
    end

    -- 显示结果
    Utils.log(Stats.format(stats))
end

-- 准备TimeCheck待处理行数据
function GUI.time_check_prepare_lines(subtitles, selected_lines, config)
    local lines = {}
    local sel_set = Utils.array_to_set(selected_lines)

    local row_num = 0
    for i = 1, #subtitles do
        local line_obj = subtitles[i]

        if line_obj.class == "dialogue" then
            row_num = row_num + 1

            if not line_obj.comment
                    and config.time_check_selected_styles[line_obj.style]
                    and (not config.time_check_selected_only or sel_set[i])
                    and (not config.ignore_no_text or line_obj.text ~= "") then
                table.insert(lines, {
                    index = i,
                    row_num = row_num,
                    line_obj = line_obj,
                    start_time = line_obj.start_time,
                    end_time = line_obj.end_time,
                    issues = {},
                })
            end
        end
    end
    return lines
end

-- 更新TimeCheck字幕行
function GUI.time_check_update_subtitle_line(line, subtitles, config)
    -- 生成问题标记
    local issue_mark = ""
    local regex_cp = re.compile("[→←]")
    for _, issue in ipairs(line.issues) do
        issue_mark = string.format("%s%s%s%s%s",
            issue_mark,
            issue_mark == "" and "" or "、",
            issue[1],
            regex_cp:match(issue[1]) and "" or "#",
            issue[2]
        )
    end
    if issue_mark ~= "" then
        line.line_obj[TIPS_OUTPUT_COLUMN] = "(【" .. issue_mark .. "】)" .. line.line_obj[TIPS_OUTPUT_COLUMN]
    end

    -- 非检查模式则调整时间
    if not config.check_only then
        line.line_obj.start_time = line.start_time
        line.line_obj.end_time = line.end_time
    end

    -- 写回字幕
    subtitles[line.index] = line.line_obj
end

-- 创建CharReplace主界面
function GUI.char_replace_create_ui(subtitles, selected_lines)
    local config = Config.load()
    local original_config = Utils.deep_copy(config)
    local styles = GUI.get_available_styles(subtitles)

    if #styles == 0 then
        Utils.alert("在非注释字幕行没有找到任何样式")
        return
    end

    while true do
        local dialog = GUI.char_replace_build_dialog_elements(styles, config)
        local buttons = {"保存配置", "取消勾选所有选项", "执行替换", "取消"}
        local button, results = aegisub.dialog.display(dialog, buttons)

        if not button or button == "取消" then
            return
        end

        if button == "取消勾选所有选项" then
            config = GUI.char_replace_clear_config(config)
        else
            config = GUI.char_replace_parse_dialog_results(results, styles, config)
            if next(config.char_replace_selected_styles) == nil then
                Utils.alert("请至少选择一项样式")
            elseif button == "保存配置" then
                Config.save(config)
                Utils.alert("当前选项配置保存完毕")
            else
                if config.char_replace_save_config_on_execute and not Utils.table_equal(config, original_config) then
                    Config.save(config)
                end

                if config.char_replace_clear_tips_before_execute then
                    GUI.clear_tips_process(subtitles, false)
                end

                aegisub.set_undo_point("字符替换")
                GUI.char_replace_process(subtitles, selected_lines, config)
                return
            end
        end
    end
end

-- 构建CharReplace对话框元素
function GUI.char_replace_build_dialog_elements(styles, config)
    local dialog = {}

    -- 左侧样式选择区
    table.insert(dialog, {
        class = "label",
        label = "━━━━━━★ 仅对选择的样式操作 ━━━━━━━\n(多选的样式会当成一个整体处理)",
        x = 0, y = 0, width = 2, height = 2
    })
    for i, style in ipairs(styles) do
        table.insert(dialog, {
            class = "checkbox",
            label = style,
            name = "style_" .. i,
            value = config.char_replace_selected_styles[style],
            x = 0, y = i + 1, width = 2, height = 1
        })
    end

    -- 右侧配置区
    local x = 3
    local y = 0

    local function next_line_elem(element)
        if element then
            element.x = element.x or x
            element.y = element.y or y
            element.height = element.height or 1
            table.insert(dialog, element)
            y = element.y + element.height
        else
            y = y + 1
        end
    end

    next_line_elem({class="label", label="━━━★ 选项 ━━━━", width=20})
    next_line_elem({class="checkbox", label="执行前先清除本工具此前在字幕中输出的所有提示内容",
                    name="char_replace_clear_tips_before_execute", value=config.char_replace_clear_tips_before_execute,
                    width=10})
    next_line_elem({class="checkbox", label="执行后自动保存当前的选项配置",
                    name="char_replace_save_config_on_execute", value=config.char_replace_save_config_on_execute,
                    width=10})
    next_line_elem({class="checkbox", label="仅对选择的字幕行操作",
                    name="char_replace_selected_only", value=config.char_replace_selected_only, width=10})
    next_line_elem({class="checkbox", label="-XXX\\N-YYY 形式的多人对话拆成多行",
                    hint="\"-\"号前后带有空格的这种形式也会拆开",
                    name="split_overlapping_dialogue", value=config.split_overlapping_dialogue, x=x+10, y=y-3, width=5})
    next_line_elem({class="label", label="", x=x+10, height=2})
    next_line_elem()

    next_line_elem({class="label", label="━━━★ 删除句首句尾的以下符号X，行中出现的符号X替换成半角空格 \" \"（U+0020） ━━━━",
                    width=20})
    next_line_elem({class="checkbox", label="\"，\"（中文逗号）", hint="U+FF0C 全角",
                    name="clear_cn_comma", value=config.clear_cn_comma, width=4})
    next_line_elem({class="checkbox", label="\",\"  （英文逗号）", hint="U+002C 半角",
                    name="clear_en_comma", value=config.clear_en_comma, width=4})
    next_line_elem({class="checkbox", label="\"。\"（中文句号）", hint="U+3002 全角",
                    name="clear_cn_period", value=config.clear_cn_period, x=x+10, y=y-2, width=2})
    next_line_elem({class="checkbox", label="\"、\"（中文顿号）", hint="U+3001 全角",
                    name="clear_cn_caesura_point", value=config.clear_cn_caesura_point, x=x+10, width=2})
    next_line_elem({class="checkbox", label="\"\\N\"（ass字幕换行符）", hint="U+005CU+004E（这实际是两个字符）",
                    name="clear_ass_line_break", value=config.clear_ass_line_break, width=6})
    next_line_elem({class="label", label="━━━★ 仅删除句首句尾的以下符号Y ━━━━", width=20})
    next_line_elem({class="checkbox", label="\" \"  （半角空格）", hint="U+0020（一般中英字幕是这种空格）",
                    name="clear_space", value=config.clear_space, width=4})
    next_line_elem({class="checkbox", label="\"　\"（全角空格）", hint="U+3000（日语字幕中常见）",
                    name="clear_full_width_space", value=config.clear_full_width_space, width=4})
    next_line_elem({class="checkbox", label="\"➡\"（右箭头）", hint="U+27A1（电视台日语字幕中常见）",
                    name="clear_right_arrow", value=config.clear_right_arrow, x=x+10, y=y-2, width=2})
    next_line_elem({class="label", label="", x=x+10, width=2})
    next_line_elem()

    next_line_elem({class="label", label="━━━★ 空格处理 ━━━━", width=20})
    next_line_elem({class="label", label="单个和连续的全角空格 \"　\"", width=6})
    next_line_elem({class="dropdown", hint="全角空格 U+3000", name="full_width_space_choice",
                    value=GUI.FULL_WIDTH_SPACE_CHOICE[config.full_width_space_choice_idx or 1],
                    items=GUI.FULL_WIDTH_SPACE_CHOICE, x=x+6, y=y-1, width=5})
    next_line_elem({class="label", label="单个和连续的半角空格 \" \" ", width=6})
    next_line_elem({class="dropdown", hint="半角空格 U+0020", name="space_choice",
                    value=GUI.SPACE_CHOICE[config.space_choice_idx or 1],
                    items=GUI.SPACE_CHOICE, x=x+6, y=y-1, width=5})
    next_line_elem({class="checkbox", hint="半角空格 U+0020、全角空格 U+3000",
                    label="英文单词前后的单个和连续的半角、全角空格（不包括句首句尾的空格） 替换为 \" \"（半角空格）",
                    name="english_word_spaces", value=config.english_word_spaces, width=20})
    next_line_elem()

    next_line_elem({class="label", label="━━━★ 感叹号和问号 ━━━━", width=20})
    next_line_elem({class="label", label="中文感叹号 \"！\" 和 英文感叹号 \"!\"", width=7})
    next_line_elem({class="dropdown", hint="中文感叹号 U+FF01、英文感叹号 U+0021", name="exclamation_point_choice",
                    value=GUI.EXCLAMATION_POINT_CHOICE[config.exclamation_point_choice_idx or 1],
                    items=GUI.EXCLAMATION_POINT_CHOICE, x=x+7, y=y-1, width=4})
    next_line_elem({class="label", label="中文问号 \"？\" 和 英文问号 \"?\"", width=7})
    next_line_elem({class="dropdown", hint="中文问号 U+FF1F、英文问号 U+003F", name="question_mark_choice",
                    value=GUI.QUESTION_MARK_CHOICE[config.question_mark_choice_idx or 1],
                    items=GUI.QUESTION_MARK_CHOICE, x=x+7, y=y-1, width=4})
    next_line_elem({class="label", label="感叹修辞疑问号 \"？！\" 或 \"！？\"（包括全角或半角或其混合形式）", width=10})
    next_line_elem({class="dropdown",
                    hint="替换的符号包含 U+FF1FU+FF01、U+FF1FU+0021、U+003FU+FF01、U+003FU+0021 及上述反序的符号",
                    name="interrobang_choice", value=GUI.INTERROBANG_CHOICE[config.interrobang_choice_idx or 1],
                    items=GUI.INTERROBANG_CHOICE, x=x+10, y=y-1, width=6})
    next_line_elem()

    next_line_elem({class="label", label="━━━★ 省略号 ━━━━", width=20})
    next_line_elem({class="checkbox", label="连续两个及以上的 \".\"（英文句号）替换为 \"…\"（半个中文省略号）【激进模式】",
                    hint="连续两个及以上的 U+002E 替换为 U+2026 【适合处理中文老字幕】",
                    name="replace_ellipsis_radical", value=config.replace_ellipsis_radical, width=20})
    next_line_elem({class="checkbox", label="\"...\"（3个英文句号）替换为 \"…\"（半个中文省略号）",
                    hint="U+002EU+002EU+002E 替换为 U+2026",
                    name="replace_ellipsis", value=config.replace_ellipsis, width=20})
    next_line_elem({class="checkbox", label="连续两个及以上的 \"…\"（半个中文省略号）替换为 单个 \"…\"（半个中文省略号）",
                    hint="单个和连续的 U+2026 替换为 单个 U+2026",
                    name="replace_multi_ellipsis", value=config.replace_multi_ellipsis, width=20})
    next_line_elem()

    next_line_elem({class="label", label="━━━★ 引号 ━━━━", width=20})
    next_line_elem({class="label", label="成对的 ", width=1})
    next_line_elem({class="checkbox", label="\"\"、", hint="U+0022U+0022，英文双引号，半角",
                    name="en_double_quotation_mark",value=config.en_double_quotation_mark, x=x+1, y=y-1, width=2})
    next_line_elem({class="checkbox", label="“”、", hint="U+201CU+201D，中文双引号，全角",
                    name="cn_double_quotation_mark",value=config.cn_double_quotation_mark, x=x+3, y=y-1, width=2})
    next_line_elem({class="checkbox", label="「」 ", hint="U+300CU+300D，二角括号，全角",
                    name="jp_double_quotation_mark",value=config.jp_double_quotation_mark, x=x+5, y=y-1, width=2})
    next_line_elem({class="dropdown", hint="不成对的不会替换", name="double_quotation_mark_choice",
                    value=GUI.DOUBLE_QUOTATION_MARK_CHOICE[config.double_quotation_mark_choice_idx or 1],
                    items=GUI.DOUBLE_QUOTATION_MARK_CHOICE, x=x+7, y=y-1, width=6})
    next_line_elem({class="label", label="成对的 ", width=1})
    next_line_elem({class="checkbox", label="''、", hint="U+0027U+0027，英文单引号，半角",
                    name="en_single_quotation_mark",value=config.en_single_quotation_mark, x=x+1, y=y-1, width=2})
    next_line_elem({class="checkbox", label="‘’、", hint="U+2018U+2019，中文单引号，全角",
                    name="cn_single_quotation_mark",value=config.cn_single_quotation_mark, x=x+3, y=y-1, width=2})
    next_line_elem({class="checkbox", label="『』 ", hint="U+300EU+300F，双重引号，全角",
                    name="jp_single_quotation_mark",value=config.jp_single_quotation_mark, x=x+5, y=y-1, width=2})
    next_line_elem({class="dropdown", hint="不成对的不会替换", name="single_quotation_mark_choice",
                    value=GUI.SINGLE_QUOTATION_MARK_CHOICE[config.single_quotation_mark_choice_idx or 1],
                    items=GUI.SINGLE_QUOTATION_MARK_CHOICE, x=x+7, y=y-1, width=6})
    next_line_elem()

    next_line_elem({class="label", label="━━━★ 间隔号 ━━━━", width=20})
    next_line_elem({class="label", label="\"·\"、 \"‧\"、 \"．\"、 \"・\"、\"･\"、 \"•\"、 \"⸱\" ", width=8})
    next_line_elem({class="dropdown", hint="U+00B7、 U+2027、 U+FF0E、 U+30FB、U+FF65、 U+2022、 U+2E31",
                    name="middle_dot_choice", value=GUI.MIDDLE_DOT_CHOICE[config.middle_dot_choice_idx or 1],
                    items=GUI.MIDDLE_DOT_CHOICE, x=x+8, y=y-1, width=4})
    next_line_elem()

    next_line_elem({class="label",
                    label="★※ 上面列出的所有功能会从上到下的顺序进行处理（即后面的选项会根据前面选项操作后的数据进行处理）" ..
                          "，但不会处理标签和绘图指令（\\p1等）★", width=20})
    return dialog
end

-- 解析CharReplace对话框结果
function GUI.char_replace_parse_dialog_results(results, styles, config)
    local new_config = Utils.deep_copy(config)
    new_config.char_replace_clear_tips_before_execute = results.char_replace_clear_tips_before_execute
    new_config.char_replace_save_config_on_execute = results.char_replace_save_config_on_execute
    new_config.char_replace_selected_only = results.char_replace_selected_only
    new_config.split_overlapping_dialogue = results.split_overlapping_dialogue
    new_config.sweep_fanhuaji = results.sweep_fanhuaji
    new_config.sweep_useless_style = results.sweep_useless_style
    new_config.sweep_actor_ntp = results.sweep_actor_ntp
    new_config.clear_cn_period = results.clear_cn_period
    new_config.clear_en_comma = results.clear_en_comma
    new_config.clear_cn_comma = results.clear_cn_comma
    new_config.clear_cn_caesura_point = results.clear_cn_caesura_point
    new_config.clear_ass_line_break = results.clear_ass_line_break
    new_config.clear_space = results.clear_space
    new_config.clear_full_width_space = results.clear_full_width_space
    new_config.clear_right_arrow = results.clear_right_arrow
    new_config.full_width_space_choice_idx = Utils.which_choice(GUI.FULL_WIDTH_SPACE_CHOICE,
                                                                results.full_width_space_choice)
    new_config.space_choice_idx = Utils.which_choice(GUI.SPACE_CHOICE, results.space_choice)
    new_config.english_word_spaces = results.english_word_spaces
    new_config.exclamation_point_choice_idx = Utils.which_choice(GUI.EXCLAMATION_POINT_CHOICE,
                                                                 results.exclamation_point_choice)
    new_config.question_mark_choice_idx = Utils.which_choice(GUI.QUESTION_MARK_CHOICE, results.question_mark_choice)
    new_config.interrobang_choice_idx = Utils.which_choice(GUI.INTERROBANG_CHOICE, results.interrobang_choice)
    new_config.replace_ellipsis_radical = results.replace_ellipsis_radical
    new_config.replace_ellipsis = results.replace_ellipsis
    new_config.replace_multi_ellipsis = results.replace_multi_ellipsis
    new_config.en_double_quotation_mark = results.en_double_quotation_mark
    new_config.cn_double_quotation_mark = results.cn_double_quotation_mark
    new_config.jp_double_quotation_mark = results.jp_double_quotation_mark
    new_config.double_quotation_mark_choice_idx = Utils.which_choice(GUI.DOUBLE_QUOTATION_MARK_CHOICE,
                                                                     results.double_quotation_mark_choice)
    new_config.en_single_quotation_mark = results.en_single_quotation_mark
    new_config.cn_single_quotation_mark = results.cn_single_quotation_mark
    new_config.jp_single_quotation_mark = results.jp_single_quotation_mark
    new_config.single_quotation_mark_choice_idx = Utils.which_choice(GUI.SINGLE_QUOTATION_MARK_CHOICE,
                                                                     results.single_quotation_mark_choice)
    new_config.middle_dot_choice_idx = Utils.which_choice(GUI.MIDDLE_DOT_CHOICE, results.middle_dot_choice)

    -- 解析选中的样式
    new_config.char_replace_selected_styles = {}
    for i, style in ipairs(styles) do
        if results["style_" .. i] then
            new_config.char_replace_selected_styles[style] = true
        end
    end
    return new_config
end

-- 清空CharReplace所有配置选项
function GUI.char_replace_clear_config(config)
    local new_config = Utils.deep_copy(config)
    new_config.char_replace_clear_tips_before_execute = false
    new_config.char_replace_save_config_on_execute = false
    new_config.char_replace_selected_only = false
    new_config.split_overlapping_dialogue = false
    new_config.sweep_fanhuaji = false
    new_config.sweep_useless_style = false
    new_config.sweep_actor_ntp = false
    new_config.clear_cn_period = false
    new_config.clear_en_comma = false
    new_config.clear_cn_comma = false
    new_config.clear_cn_caesura_point = false
    new_config.clear_ass_line_break = false
    new_config.clear_space = false
    new_config.clear_full_width_space = false
    new_config.clear_right_arrow = false
    new_config.full_width_space_choice_idx = 1
    new_config.space_choice_idx = 1
    new_config.english_word_spaces = false
    new_config.exclamation_point_choice_idx = 1
    new_config.question_mark_choice_idx = 1
    new_config.interrobang_choice_idx = 1
    new_config.replace_ellipsis_radical = false
    new_config.replace_ellipsis = false
    new_config.replace_multi_ellipsis = false
    new_config.en_double_quotation_mark = false
    new_config.cn_double_quotation_mark = false
    new_config.jp_double_quotation_mark = false
    new_config.double_quotation_mark_choice_idx = 1
    new_config.en_single_quotation_mark = false
    new_config.cn_single_quotation_mark = false
    new_config.jp_single_quotation_mark = false
    new_config.single_quotation_mark_choice_idx = 1
    new_config.middle_dot_choice_idx = 1

    new_config.char_replace_selected_styles = {}
    return new_config
end

-- 进行CharReplace处理
function GUI.char_replace_process(subtitles, selected_lines, config)
    -- 准备处理的行数据
    local lines, issue_cnt = GUI.char_replace_prepare_lines(subtitles, selected_lines, config)

    local function generate_task(msg, func, ...)
        return {msg=msg, func=func, params={...}}
    end

    local tasks = {}
    -- 句首句尾要去掉的字符
    if config.clear_cn_period then
        table.insert(tasks, generate_task("清除首尾中文句号", CharReplace.trim, "。"))
    end
    if config.clear_en_comma then
        table.insert(tasks, generate_task("清除首尾英文逗号", CharReplace.trim, ","))
    end
    if config.clear_cn_comma then
        table.insert(tasks, generate_task("清除首尾中文逗号", CharReplace.trim, "，"))
    end
    if config.clear_cn_caesura_point then
        table.insert(tasks, generate_task("清除首尾中文顿号", CharReplace.trim, "、"))
    end
    if config.clear_ass_line_break then
        table.insert(tasks, generate_task("清除首尾\\N", CharReplace.trim, "\\\\N"))
    end
    if config.clear_space then
        table.insert(tasks, generate_task("清除首尾半角空格", CharReplace.trim, " "))
    end
    if config.clear_full_width_space then
        table.insert(tasks, generate_task("清除首尾全角空格", CharReplace.trim, "　"))
    end
    if config.clear_right_arrow then
        table.insert(tasks, generate_task("清除首尾➡", CharReplace.trim, "➡"))
    end

    -- 句中要替换成的空格字符
    if config.clear_cn_period then
        table.insert(tasks, generate_task("替换中文句号为半角空格", CharReplace.replace, "。", " "))
    end

    if config.clear_en_comma then
        table.insert(tasks, generate_task("替换英文逗号为半角空格", CharReplace.replace, ",", " "))
    end

    if config.clear_cn_comma then
        table.insert(tasks, generate_task("替换中文逗号为半角空格", CharReplace.replace, "，", " "))
    end

    if config.clear_cn_caesura_point then
        table.insert(tasks, generate_task("替换中文顿号为半角空格", CharReplace.replace, "、", " "))
    end

    if config.clear_ass_line_break then
        table.insert(tasks, generate_task("替换\\N为半角空格", CharReplace.replace, "\\\\N", " "))
    end

    -- 替换连续的全角空格
    for choice_idx, replacement in pairs({
        [2] = " ",  -- 单个空格
        [3] = "  ",  -- 两个空格
        [4] = "　",  -- 全角空格
    }) do
        if choice_idx == config.full_width_space_choice_idx then
            table.insert(tasks, generate_task("替换全角空格", CharReplace.replace, "　+", replacement))
            break
        end
    end

    -- 替换连续的半角空格
    for choice_idx, replacement in pairs({
        [2] = " ",  -- 单个空格
        [3] = "  ",  -- 两个空格
        [4] = "　",  -- 全角空格
    }) do
        if choice_idx == config.space_choice_idx then
            table.insert(tasks, generate_task("替换半角空格", CharReplace.replace, " +", replacement))
            break
        end
    end

    -- 替换英文单词前后的空格
    if config.english_word_spaces then
        table.insert(tasks, generate_task("替换英文单词前后的空格", CharReplace.normalize_english_word_spaces))
    end

    -- 替换感叹号
    if config.exclamation_point_choice_idx == 2 then
        -- 感叹号全部替换为全角
        table.insert(tasks, generate_task("感叹号替换为全角", CharReplace.replace, "!", "！"))
    elseif config.exclamation_point_choice_idx == 3 then
        -- 感叹号全部替换为半角
        table.insert(tasks, generate_task("感叹号替换为半角", CharReplace.replace, "！", "!"))
    end

    -- 替换问号
    if config.question_mark_choice_idx == 2 then
        -- 问号全部替换为全角
        table.insert(tasks, generate_task("问号替换为全角", CharReplace.replace, "\\?", "？"))
    elseif config.question_mark_choice_idx == 3 then
        -- 问号全部替换为半角
        table.insert(tasks, generate_task("问号替换为半角", CharReplace.replace, "？", "?"))
    end

    -- 替换感叹修辞疑问号
    for choice_idx, replacement in pairs({
        [2] = "？！",  -- 替换为全角中文形式
        [3] = "?!",  -- 替换为半角中文形式
        [4] = "！？",  -- 替换为全角日文形式
        [5] = "!?",  -- 替换为半角日文形式
    }) do
        if choice_idx == config.interrobang_choice_idx then
            table.insert(tasks, generate_task("替换感叹修辞疑问号",
                                              CharReplace.replace, "[!！][?？]|[?？][!！]", replacement))
            break
        end
    end

    -- 替换省略号
    if config.replace_ellipsis_radical then
        -- 省略号替换 激进模式
        table.insert(tasks, generate_task("替换省略号", CharReplace.replace, "\\.{2,}", "…"))
    elseif config.replace_ellipsis then
        -- 省略号替换 一般模式
        table.insert(tasks, generate_task("替换省略号", CharReplace.replace, "\\.{3}", "…"))
    end
    if config.replace_multi_ellipsis then
        -- 重复省略号替换
        table.insert(tasks, generate_task("替换重复省略号", CharReplace.replace, "…+", "…"))
    end

    -- 替换双引号
    for choice_idx, replacement in pairs({
        [2] = {"\"", "\""},  -- 替换为英文双引号
        [3] = {"“", "”"},  -- 替换为中文双引号
        [4] = {"「", "」"},  -- 替换为二角括号（日文引号）
        [5] = {"﹁", "﹂"},  -- 替换为竖排二角括号（日文引号）
    }) do
        if choice_idx == config.double_quotation_mark_choice_idx then
            local replace_quotes = {}
            if config.en_double_quotation_mark and choice_idx ~= 2 then
                table.insert(replace_quotes, {"\"", "\""})
            end
            if config.cn_double_quotation_mark and choice_idx ~= 3 then
                table.insert(replace_quotes, {"“", "”"})
            end
            if config.jp_double_quotation_mark and choice_idx ~= 4 then
                table.insert(replace_quotes, {"「", "」"})
            end

            if next(replace_quotes) then
                table.insert(tasks, generate_task("替换双引号", CharReplace.replace_quotes, replace_quotes, replacement))
            end
            break
        end
    end

    -- 替换单引号
    for choice_idx, replacement in pairs({
        [2] = {"'", "'"},  -- 替换为英文单引号
        [3] = {"‘", "’"},  -- 替换为中文单引号
        [4] = {"『", "』"},  -- 替换为双重引号（日文引号）
        [5] = {"﹃", "﹄"},  -- 替换为竖排双重引号（日文引号）
    }) do
        if choice_idx == config.single_quotation_mark_choice_idx then
            local replace_quotes = {}
            if config.en_single_quotation_mark and choice_idx ~= 2 then
                table.insert(replace_quotes, {"'", "'"})
            end
            if config.cn_single_quotation_mark and choice_idx ~= 3 then
                table.insert(replace_quotes, {"‘", "’"})
            end
            if config.jp_single_quotation_mark and choice_idx ~= 4 then
                table.insert(replace_quotes, {"『", "』"})
            end

            if next(replace_quotes) then
                table.insert(tasks, generate_task("替换单引号", CharReplace.replace_quotes, replace_quotes, replacement))
            end
            break
        end
    end

    -- 替换间隔号
    for choice_idx, replacement in pairs({
        [2] = "·",  -- 替换为中文间隔号
        [3] = "．",  -- 替换为Big5间隔号
        [4] = "・",  -- 替换为全角片假名中点
        [5] = "･",  -- 替换为半角片假名中点
    }) do
        if choice_idx == config.middle_dot_choice_idx then
            -- U+00B7、U+2027、U+FF0E、U+30FB、U+FF65、U+2022、U+2E31
            table.insert(tasks, generate_task("替换间隔号", CharReplace.replace, "[·‧．・･•⸱]", replacement))
            break
        end
    end

    local unpack = Utils.IS_LUA51 and unpack or table.unpack
    for _, line in ipairs(lines) do
        for _, task in ipairs(tasks) do
            if task.func(line.segments, line.text_indices, unpack(task.params)) then
                table.insert(line.issues, task.msg)
                issue_cnt = issue_cnt + 1
            end
        end

        if next(line.issues) then
            local msg = "(【🔀#" .. table.concat(line.issues, "、") .. "】)"
            line.line_obj[TIPS_OUTPUT_COLUMN] = msg .. line.line_obj[TIPS_OUTPUT_COLUMN]
            local contents = {}
            for _, segment in pairs(line.segments) do
                table.insert(contents, segment.content)
            end
            line.line_obj.text = table.concat(contents)
            subtitles[line.index] = line.line_obj
        end
    end

    Utils.log(string.format("检查完成: 共处理【%d】行，替换了至少【%d】处", #lines, issue_cnt))
end


-- 准备CharReplace待处理行数据
function GUI.char_replace_prepare_lines(subtitles, selected_lines, config)
    local lines = {}
    local sel_set = Utils.array_to_set(selected_lines)
    local sweep_fanhuaji = config.sweep_fanhuaji
    local sweep_actor_ntp = config.sweep_actor_ntp
    local split_overlapping_dialogue = config.split_overlapping_dialogue
    local issue_cnt = 0
    local split_indices = {}

    local subs_len = #subtitles
    local i = 1
    while i <= subs_len do
        local step = 1
        local line_obj = subtitles[i]

        if sweep_fanhuaji and line_obj.class == "info" and line_obj.section == "[Script Info]"
                and line_obj.key == "Comment" and line_obj.value:match("^ *Processed by 繁化姬") then
            subtitles.delete(i)
            subs_len = subs_len - 1
            issue_cnt = issue_cnt + 1
            step = 0
        elseif line_obj.class == "dialogue" and not line_obj.comment
                and (not config.char_replace_selected_only or sel_set[i]) then
            if sweep_fanhuaji and line_obj.text:match("^ *Processed by 繁化姬") then
                subtitles.delete(i)
                subs_len = subs_len - 1
                issue_cnt = issue_cnt + 1
                step = 0
            elseif config.char_replace_selected_styles[line_obj.style] then
                local issues = {}
                if sweep_actor_ntp and line_obj.actor == "NTP" then
                    line_obj.actor = ""
                    subtitles[i] = line_obj
                    table.insert(issues, "删NTP")
                end

                local line_text = line_obj.text
                if split_overlapping_dialogue and line_text:match("^%-") then
                    local split_dialogues = {}
                    local regex_cp = re.compile("^ +| +$")
                    for split_text in re.gsplit(line_text:sub(2), "(?:\\\\N| +) *-", true) do
                        split_text = regex_cp:sub(split_text, "")
                        table.insert(split_dialogues, split_text)
                    end

                    local split_dialogues_len = #split_dialogues
                    if split_dialogues_len > 1 then
                        for j = 0, split_dialogues_len - 1 do
                            -- 记录是否分割的行，后面根据这个分割次数写入issues
                            split_indices[i + j] = true
                        end
                        issue_cnt = issue_cnt + 1
                        line_obj.text = split_dialogues[1]
                        subtitles[i] = line_obj

                        -- 插入对象到第i行字幕前面（即插入到第i行，原本的第i行会自动往后移)
                        for j = 2, split_dialogues_len do
                            local new_line_obj = Utils.deep_copy(line_obj)
                            new_line_obj.text = split_dialogues[j]
                            subtitles.insert(i, new_line_obj)
                        end
                        -- 总行数增加了split_dialogues_len-1行
                        subs_len = subs_len + split_dialogues_len - 1
                        -- 插入完重新获取第i行的内容
                        line_obj = subtitles[i]
                        line_text = line_obj.text
                    end
                end

                if split_indices[i] then
                    table.insert(issues, "拆多人对话")
                end

                local segments = Utils.parse_line(line_text)
                local text_indices = {}

                for j, segment in ipairs(segments) do
                    if segment.type == "text" then
                        table.insert(text_indices, j)
                    end
                end

                table.insert(lines, {
                    index = i,
                    line_obj = line_obj,
                    segments = segments,
                    text_indices = text_indices,
                    issues = issues,
                })
            end
        end
        i = i + step
    end
    return lines, issue_cnt
end

-- 创建ContentSweep主界面
function GUI.content_sweep_create_ui(subtitles, selected_lines)
    local config = Config.load()
    local original_config = Utils.deep_copy(config)

    while true do
        local dialog = GUI.content_sweep_build_dialog_elements(config)
        local buttons = {"保存配置", "取消勾选所有选项", "执行清理", "取消"}
        local button, results = aegisub.dialog.display(dialog, buttons)

        if not button or button == "取消" then
            return
        end

        if button == "取消勾选所有选项" then
            config = GUI.content_sweep_clear_config(config)
        else
            config = GUI.content_sweep_parse_dialog_results(results, config)
            if button == "保存配置" then
                Config.save(config)
                Utils.alert("当前选项配置保存完毕")
            else
                if config.content_sweep_save_config_on_execute and not Utils.table_equal(config, original_config) then
                    Config.save(config)
                end

                aegisub.set_undo_point("无用内容清理")
                GUI.content_sweep_process(subtitles, config)
                return
            end
        end
    end
end

-- 构建ContentSweep对话框元素
function GUI.content_sweep_build_dialog_elements(config)
    local dialog = {}

    local x = 0
    local y = 0

    local function next_line_elem(element)
        if element then
            element.x = element.x or x
            element.y = element.y or y
            element.height = element.height or 1
            table.insert(dialog, element)
            y = element.y + element.height
        else
            y = y + 1
        end
    end

    next_line_elem({class="checkbox", label="执行后自动保存当前的选项配置",
                    name="content_sweep_save_config_on_execute", value=config.content_sweep_save_config_on_execute})
    next_line_elem({class="checkbox", label="清除【繁化姬】生成的标记行", hint="清除ass和srt文件生成的不同形式的标记行",
                    name="sweep_fanhuaji", value=config.sweep_fanhuaji})
    next_line_elem({class="checkbox", label="清除未使用的样式定义", hint="会检测\\r标签是否使用过该样式",
                    name="sweep_useless_style", value=config.sweep_useless_style})
    next_line_elem({class="checkbox", label="清除【说话人（Actor)】列的 \"NTP\" 标记",
                    hint="\"NTP\"是PopSub软件默认填充到此列的，猜测是\"No Text Provided\"的意思",
                    name="sweep_actor_ntp", value=config.sweep_actor_ntp})
    next_line_elem({class="checkbox", label="清除位于字幕文件末尾的无文本行",
                    hint="若字幕最后存在文本为空的行，则清除",
                    name="sweep_last_notext_line", value=config.sweep_last_notext_line})
    next_line_elem({class="checkbox", label="清除[Aegisub Extradata]段的内容和字幕文本行首的{=XX}标签",
                    hint="会清除[Aegisub Extradata]段的内容和字幕文本行首的{=XX}标记",
                    name="sweep_aegisub_motion_plugin_info", value=config.sweep_aegisub_motion_plugin_info})
    next_line_elem({class="checkbox", label="清除除了[Script Info]、[V◯◯ Styles]、[Events]以外ass字幕非标准段的内容" ..
                                            "（除了[Aegisub Project Garbage]段）",
                    hint="[V◯◯ Styles]包括[V4 Styles]、[V4+ Styles]以及之后有可能出现的版本号" ..
                         "，而[Aegisub Project Garbage]段是aegisub保存文件时候生成的，用aegisub插件无法有效清除",
                    name="sweep_nonstandard_section", value=config.sweep_nonstandard_section})
    return dialog
end

-- 解析ContentSweep对话框结果
function GUI.content_sweep_parse_dialog_results(results, config)
    local new_config = Utils.deep_copy(config)
    new_config.content_sweep_save_config_on_execute = results.content_sweep_save_config_on_execute
    new_config.sweep_fanhuaji = results.sweep_fanhuaji
    new_config.sweep_useless_style = results.sweep_useless_style
    new_config.sweep_actor_ntp = results.sweep_actor_ntp
    new_config.sweep_last_notext_line = results.sweep_last_notext_line
    new_config.sweep_aegisub_motion_plugin_info = results.sweep_aegisub_motion_plugin_info
    new_config.sweep_nonstandard_section = results.sweep_nonstandard_section
    return new_config
end

-- 清空ContentSweep所有配置选项
function GUI.content_sweep_clear_config(config)
    local new_config = Utils.deep_copy(config)
    new_config.content_sweep_save_config_on_execute = false
    new_config.sweep_fanhuaji = false
    new_config.sweep_useless_style = false
    new_config.sweep_actor_ntp = false
    new_config.sweep_last_notext_line = false
    new_config.sweep_aegisub_motion_plugin_info = false
    new_config.sweep_nonstandard_section = false
    return new_config
end

-- 执行ContentSweep处理
function GUI.content_sweep_process(subtitles, config)
    local function generate_task(msg, func, ...)
        return {msg=msg, func=func, params={...}}
    end

    local tasks = {}
    local used_style_set = {}
    local defined_style_set = {}
    -- 清除繁化姬标记
    if config.sweep_fanhuaji then
        table.insert(tasks, generate_task("清除【繁化姬】生成的标记行", ContentSweep.line_sweep_fanhuaji))
    end

    -- 清除ass字幕非标准段的内容
    if config.sweep_nonstandard_section then
        table.insert(tasks, generate_task("清除ass字幕非标准段的内容", ContentSweep.line_sweep_nonstandard_section))
    end

    -- 清除Aegisub-Motion插件信息
    if config.sweep_aegisub_motion_plugin_info then
        table.insert(tasks, generate_task("清除Aegisub-Motion插件信息",
                                          ContentSweep.line_sweep_aegisub_motion_plugin_info))
    end

    -- 清除Actor列的NTP标记
    if config.sweep_actor_ntp then
        table.insert(tasks, generate_task("清除Actor列的NTP标记", ContentSweep.line_sweep_actor_ntp))
    end

    -- 统计样式
    if config.sweep_useless_style then
        -- 此处定义的msg无效，因为这两个方法都不会更改line_obj，不应输出msg这个变量
        -- 统计用过的样式
        table.insert(tasks, generate_task(nil, ContentSweep.line_stat_used_style, used_style_set))
        -- 统计定义的样式
        table.insert(tasks, generate_task(nil, ContentSweep.line_stat_defined_style, defined_style_set))
    end

    local unpack = Utils.IS_LUA51 and unpack or table.unpack
    local issue_status = {}
    local subs_len = #subtitles
    local i = 1
    while i <= subs_len do
        local line_obj = subtitles[i]
        local is_delete = false
        local changed = false
        local task_changed

        for _, task in ipairs(tasks) do
            line_obj, task_changed = task.func(line_obj, unpack(task.params))
            if task_changed then
                issue_status[task.msg] = "✔"
                changed = true
                -- 如果删除，本行就不用再执行后续的清除任务
                if not line_obj then
                    break
                end
            end
        end

        -- 判断有没有改变
        if changed then
            -- 如果line_obj为nil代表删除，按照aegisub文档可以直接设置为nil当删除，但不知为何报错，要用delete方法
            if line_obj then
                subtitles[i] = line_obj
            else
                subtitles.delete(i)
            end
        end

        -- 判断有没有删除
        if line_obj then
            i = i + 1
        else
            subs_len = subs_len - 1
        end
    end

    for _, task in ipairs(tasks) do
        -- 排除掉msg为nil的任务
        if task.msg and not issue_status[task.msg] then
            issue_status[task.msg] = "⚠️"
        end
    end

    local issues = {}
    for msg, status in pairs(issue_status) do
        table.insert(issues, status .. " " .. msg)
    end

    -- 清除字幕文件末尾文本为空的行
    if config.sweep_last_notext_line then
        local changed = ContentSweep.sweep_last_notext_line(subtitles)
        table.insert(issues, (changed and "✔" or "⚠️") .. " 清除字幕文件末尾文本为空的行")
    end

    -- 清除未使用的样式定义
    if config.sweep_useless_style then
        -- 判断是否有样式没定义就使用
        local undefined_style = {}
        local empty_style = false
        for used_style, _ in pairs(used_style_set) do
            if not defined_style_set[used_style] then
                if used_style == "" then
                    empty_style = true
                else
                    table.insert(undefined_style, used_style)
                end
            end
        end

        if next(undefined_style) or empty_style then
            local msg
            if next(undefined_style) then
                msg = "因存在未定义就使用的样式：" .. table.concat(undefined_style, "、")
            else
                msg = "因存在空字符串的样式"
            end
            table.insert(issues, "❌ 清除未使用的样式定义 " .. msg)
        else
            local changed = ContentSweep.sweep_useless_style(subtitles, used_style_set)
            table.insert(issues, (changed and "✔" or "⚠️") .. " 清除未使用的样式定义")
        end
    end

    Utils.log("清理完成\n\n" .. table.concat(issues, "\n"))
end

-- 进行TagCheck处理
function GUI.tag_check_process(subtitles)
    local processed_cnt = 0
    local issue_cnt = 0

    for i = 1, #subtitles do
        local line_obj = subtitles[i]
        if line_obj.class == "dialogue" and line_obj.comment == false then
            local errors, warns = TagCheck.check_line(line_obj.text)

            local msg = ""
            if next(errors) or next(warns) then
                issue_cnt = issue_cnt + 1
                if next(errors) then
                    msg = "💊#" .. table.concat(errors, "、💊#")
                end
                if next(warns) then
                    msg = string.format("%s%s👀#%s", msg, msg ~= "" and "、" or "", table.concat(warns, "、👀#"))
                end
            end

            if msg ~= "" then
                line_obj[TIPS_OUTPUT_COLUMN] = "(【" .. msg .. "】)" .. line_obj[TIPS_OUTPUT_COLUMN]
                subtitles[i] = line_obj
            end
            processed_cnt = processed_cnt + 1
        end
    end

    aegisub.set_undo_point("一键标签检查")
    Utils.log(string.format("检查完成: 共检查【%d】行，发现问题【%d】行", processed_cnt, issue_cnt))
end

-- 进行TypoCheck处理
function GUI.typo_check_process(subtitles)
    local processed_cnt = 0
    local issue_cnt = 0

    local typo_dict = TypoCheck.load_typo_dict()
    if not typo_dict then
        return
    end

    Utils.log("检查错字的规则数量：" .. #typo_dict)

    for i = 1, #subtitles do
        local line_obj = subtitles[i]
        if line_obj.class == "dialogue" and line_obj.comment == false then
            local issues = TypoCheck.check_line(typo_dict, line_obj.text)

            if next(issues) then
                local msg = "(【✍︎#" .. table.concat(issues, "、✍︎#") .. "】)"
                issue_cnt = issue_cnt + 1
                line_obj[TIPS_OUTPUT_COLUMN] = msg .. line_obj[TIPS_OUTPUT_COLUMN]
                subtitles[i] = line_obj
            end
            processed_cnt = processed_cnt + 1
        end
    end

    aegisub.set_undo_point("一键疑似错字检查")
    Utils.log(string.format("检查完成: 共检查【%d】行，发现问题【%d】行", processed_cnt, issue_cnt))
end

-- 进行SubsettingFontRestore处理
function GUI.subsetting_font_restore_process(subtitles)
    local filename = aegisub.file_name()

    if not filename or not filename:match("%.ass$") then
        Utils.log("❌ 当前的编辑的源文件非ass后缀的字幕文件")
        return
    end

    local file, err = io.open(aegisub.decode_path("?script/") .. filename, "r")
    if not file then
        Utils.log("❌ 打开字幕文件出错：" .. err)
        return
    end

    -- only detect first 10KB
    local encoding, bom_width = Utils.detect_encoding(file:read(10 * 1024))

    if not encoding then
        file:close()
        Utils.log("❌ 本工具无法侦测到此字幕文件的编码格式")
        return
    end

    file:seek("set", bom_width or 0)
    local err_msg = nil
    local font_mapping_script_info = {}
    local font_mapping_assfonts = {}
    -- 0=找行头
    -- 1=读取[Script Info]下的子集化信息
    -- 2=读取[Assfonts Rename Info]下的子集化信息
    local match_status = 0
    local section_regex_cp = re.compile("^ *\\[(Script Info|Assfonts Rename Info)\\]\\s*$")
    local script_info_section_font_regex_cp = re.compile("^ *; Font [Ss]ubset: (.+?) - (.+?)\\s*$")
    local assfont_section_font_regex_cp = re.compile("^ *(.+?) ---- (.+?)\\s*$")

    local function is_match_section(text)
        local match = section_regex_cp:match(text)
        if match then
            -- match第1个元素是整体，第2个元素开始才是捕获组
            if match[2].str == "Script Info" then
                match_status = 1
            else
                match_status = 2
            end
        end
    end

    local subsetting_info = {}
    -- 逐行读取文件
    for raw_line in file:lines() do
        raw_line = Utils.convert_to_utf8(raw_line, encoding)
        -- 查找以;开头的行
        if match_status == 0 then
            is_match_section(raw_line)
        elseif match_status == 1 then
            local match = script_info_section_font_regex_cp:match(raw_line)
            if match then
                -- match第1个元素是整体，第2、3个元素才是捕获组
                if font_mapping_script_info[match[2].str] then
                    if font_mapping_script_info[match[2].str] ~= match[3].str then
                        err_msg = string.format(
                                    "❌ 找到冲突的子集化：[Script Info]中的 %s 代替了两种字体：%s、 %s",
                                    font_mapping_assfonts[match[2].str], match[3].str)
                        -- 因为要file:close，所以这里用break而不直接return
                        break
                    end
                else
                    table.insert(subsetting_info, raw_line)
                    font_mapping_script_info[match[2].str] = match[3].str
                end
            elseif raw_line ~= "" and raw_line ~= "; ----- Font subset begin -----" then
                match_status = 0
                is_match_section(raw_line)
            end
        elseif match_status == 2 then
            local match = assfont_section_font_regex_cp:match(raw_line)
            if match then
                -- match第1个元素是整体，第2、3个元素才是捕获组
                if font_mapping_assfonts[match[3].str] then
                    if font_mapping_assfonts[match[3].str] ~= match[2].str then
                        err_msg = string.format(
                                    "❌ 找到冲突的子集化：[Assfonts Rename Info]中的 %s 代替了两种字体：%s、 %s",
                                    font_mapping_assfonts[match[3].str], match[2].str)
                        -- 因为要file:close，所以这里用break而不直接return
                        break
                    end
                else
                    table.insert(subsetting_info, raw_line)
                    font_mapping_assfonts[match[3].str] = match[2].str
                end
            elseif raw_line ~= "" then
                match_status = 0
                is_match_section(raw_line)
            end
        end
    end

    file:close()

    if next(subsetting_info) then
        Utils.log("字幕中找到的子集化字体映射信息:\n" .. table.concat(subsetting_info, "\n") .. "\n")
    end

    if err_msg then
        Utils.log(err_msg)
        return
    end

    -- 判断是否有多种模式存在的字体冲突
    local font_mapping_exists = (next(font_mapping_script_info) and 1 or 0) + (next(font_mapping_assfonts) and 1 or 0)
    if font_mapping_exists == 2 then
        for subsetting_name, original_name in pairs(font_mapping_script_info) do
            local original_name2 = font_mapping_assfonts[subsetting_name]
            if original_name2 and original_name2 ~= original_name then
                Utils.log(string.format("❌ 找到冲突的子集化：%s 在两种不同的子集化信息中分别代替了两种字体：%s、 %s",
                                        subsetting_name, original_name, original_name2))
                return
            end
        end
    elseif font_mapping_exists == 0 then
        Utils.log("⚠️ 没有找到子集化字体名字映射信息，无法进行还原")
        return
    end

    -- 把所有子集化信息汇总成一个集合
    local font_mapping = Utils.deep_copy(font_mapping_assfonts)
    for subsetting_name, original_name in pairs(font_mapping_script_info) do
        font_mapping[subsetting_name] = original_name
    end

    -- 还原子集化的字体名
    local changed_cnt = 0
    local font_tag_regex_cp = re.compile("\\\\fn[^\\\\{}]+")
    local font_tag2font_name_regex_cp = re.compile("^\\\\fn *| *$")
    local function fontname_replace_func(font_tag)
        local font_name = font_tag2font_name_regex_cp:sub(font_tag, "")
        local original_name = font_mapping[font_name]
        if original_name then
            changed_cnt = changed_cnt + 1
            return "\\fn" .. original_name
        end
        return font_tag
    end
    for i = 1, #subtitles do
        local line_obj = subtitles[i]
        if line_obj.class == "style" then
            local original_name = font_mapping[line_obj.fontname]
            if original_name then
                line_obj.fontname = original_name
                subtitles[i] = line_obj
                changed_cnt = changed_cnt + 1
            end
        elseif line_obj.class == "dialogue" and line_obj.comment == false then
            local last_changed_cnt = changed_cnt
            local contents = {}
            for _, segment in ipairs(Utils.parse_line(line_obj.text)) do
                if segment.type == "tag" then
                    segment.content = font_tag_regex_cp:sub(segment.content, fontname_replace_func)
                end
                table.insert(contents, segment.content)
            end
            -- 有改变过则更新行内容
            if last_changed_cnt ~= changed_cnt then
                line_obj.text = table.concat(contents, "")
                subtitles[i] = line_obj
            end
        end
    end

    if changed_cnt == 0 then
        Utils.log("⚠️ 没有找到需要还原的子集化字体名字")
        return
    end

    aegisub.set_undo_point("还原子集化字体名字")
    Utils.log("✔ 共还原【" .. changed_cnt .. "】处子集化字体名字")
end

-- 清除输出的提示内容
function GUI.clear_tips_process(subtitles, is_show_log)
    local cnt = 0
    for i = 1, #subtitles do
        local line_obj = subtitles[i]
        if line_obj.class == "dialogue" and line_obj.comment == false then
            if string.match(line_obj[TIPS_OUTPUT_COLUMN], "^%(【.-】%)") then
                cnt = cnt + 1
                -- 可能存在连续多项提示内容，要一直删到没有
                while true do
                    local new_text = line_obj[TIPS_OUTPUT_COLUMN]:gsub("^%(%【.-】%)", "")
                    if new_text == line_obj[TIPS_OUTPUT_COLUMN] then
                        break
                    end
                    line_obj[TIPS_OUTPUT_COLUMN] = new_text
                end
                subtitles[i] = line_obj
            end
        end
    end

    if is_show_log then
        aegisub.set_undo_point("一键清除填充的检查提示")
        Utils.log("共清除【" .. cnt .. "】处提示内容")
    end
end

-- 获取可用样式
function GUI.get_available_styles(subtitles)
    local styles = {}
    local style_set = {}
    for i = 1, #subtitles do
        local line = subtitles[i]
        if line.class == "dialogue" and not line.comment and not style_set[line.style] then
            style_set[line.style] = true
            table.insert(styles, line.style)
        end
    end
    table.sort(styles)
    return styles
end

-- 检查lua版本
function GUI.check_lua()
    local major, minor = _VERSION:match("Lua (%d+)%.(%d+)")
    if (tonumber(major) or 0) * 1000 + (tonumber(minor) or 0) < 5001 then
        Utils.alert("需要 Lua 5.1 或更高版本")
        return false
    end
    return true
end


-- 加载到aegisub中
function GUI.load_to_aegisub()
    local macros = {
        {
            script_name = "① 时轴检查＆校正",
            script_description = "检查字幕的闪轴、叠轴、关键帧、时长、字数等问题；可自动校正闪轴、叠轴、关键帧（忽略注释行）" ..
                                 "\n🔨标注的是原来的字幕信息，代表已修正过；🔎标注的是应修正成为的字幕信息，代表应手工修正",
            entry = function(subs, sel) return GUI.check_lua() and GUI.time_check_create_ui(subs, sel) end,
        },
        {
            script_name = "② 字符替换",
            script_description = "替换字幕文本中的特定字符（忽略注释行）\n会以🔀标注替换过的地方",
            entry = function(subs, sel) return GUI.check_lua() and GUI.char_replace_create_ui(subs, sel) end,
        },
        {
            script_name = "③ 无用内容清理",
            script_description = "清理整个字幕中的无用内容",
            entry = function(subs, sel) return GUI.check_lua() and GUI.content_sweep_create_ui(subs) end,
        },
        {
            script_name = "④ 一键标签检查",
            script_description = "【无选项】检查整个字幕的标签是否规范性使用（忽略注释行）" ..
                                 "\n💊标注的是大概率会出错的位置；👀标注的是不规范的标签使用方式",
            entry = function(subs, sel) return GUI.check_lua() and GUI.tag_check_process(subs) end,
        },
        {
            script_name = "⑤ 一键疑似错字检查",
            script_description = "【无选项】暴力检查整个字幕的是否存在疑似错字（忽略注释行）\n会以✍︎标注疑似错字的地方",
            entry = function(subs, sel) return GUI.check_lua() and GUI.typo_check_process(subs) end,
        },
        {
            script_name = "⑥ 一键还原子集化字体",
            script_description = "【无选项】根据字幕文件里的字体映射信息，将整个字幕子集化后的字体名字还原成原始的字体名字" ..
                                 "（某些字体的粗细、倾斜等可能因原信息缺失而导致观感有异）",
            entry = function(subs, sel) return GUI.check_lua() and GUI.subsetting_font_restore_process(subs) end,
        },
        {
            script_name = "⑦ 一键清除填充的检查提示",
            script_description = "【无选项】清除本工具在【" .. TIPS_OUTPUT_COLUMN .. "】列中所填充的检查提示内容（忽略注释行）",
            entry = function(subs, sel) return GUI.check_lua() and GUI.clear_tips_process(subs, true) end,
        },
    }

    for _, macro in ipairs(macros) do
        -- 注册插件入口
        aegisub.register_macro(
            script_name .. " / " .. tr(macro.script_name),
            tr(macro.script_description),
            macro.entry
        )
    end
end

GUI.load_to_aegisub()
