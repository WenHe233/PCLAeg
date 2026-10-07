script_name = "Modify Punctuations - 调整标点符号"
script_description = "调整 格式化字幕文本中的标点"
script_author = "Renaissance"
script_version = "1.1"

re = require "aegisub.re"

function trim(str)
    local subs = {
        {"\\.\\.\\.", "…"},
        {"…[ 　]*\\{\\\\fscx50\\}[ 　]+\\{\\\\fscx100\\}", "… "},
        {"…[ 　]*", "… "},
        {"~", "～"},
        {"～[ 　]+", "～　"},
        {"^[…～][ 　]*", ""},
        {"[?]", "？"},
        {"!", "！"},
        {"？[ 　]+", "？"},
        {"！[ 　]+", "！"},
        {"？！", "?!"},
        {"！？", "?!"},
        {"… ？", "…？"},
        {"… ！", "…！"},
        {"… [?]!", "…?!"},
        {"⸺", ""},
        {"^[ 　]+", ""},
        {"[ 　]+$", ""},
        {"\\{\\\\fscx50\\}　\\{\\\\fscx100\\}", "\\{\\\\fscx50\\} \\{\\\\fscx100\\}"}
    }
    for _, sub in ipairs(subs) do
        local pattern, replace = table.unpack(sub)
        str, _  = re.sub(str, pattern, replace)
    end
    return str
end

function substitute(subtitles, selected_lines, active_line)
    for _, i in ipairs(selected_lines) do
        local line = subtitles[i]
        local text = line.text
        if (line.style:find("JP")) then
            text, _  = re.sub(text, " +", "　")
        end
        text = trim(text)
        if line.style:find("CN") then
            text, _  = re.sub(text, "　+", "  ")
        end
        line.text = text
        subtitles[i] = line
    end
    aegisub.set_undo_point("punctuation")
end

aegisub.register_macro(script_name, script_description, substitute)