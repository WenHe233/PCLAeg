script_name = ('Extract Text - 提取文本')
script_description = ('提取文本为txt文件，并去除首尾空格及开头省略号')
script_author = 'Renaissance'
script_version = '1.0'

re = require 'aegisub.re'

function trim(str)
    subs = {'^[ 　]+', '[ 　]+$', '^…[ 　]*', '⸺'}
    for _, sub in ipairs(subs) do
        str, _  = re.sub(str, sub, '')
    end
    return str
end

function extractText(subtitles, selected_lines, active_line)
    filename = aegisub.dialog.save('Select file to read', '', '', 'Text files (.txt)|*.txt', false)
    file = io.open(filename, 'w')
    io.output(file)

    for _, i in ipairs(selected_lines) do
        local line = subtitles[i]
        text = trim(line.text)
        -- line.text = text
        -- subtitles[i] = line
        io.write(text)
        io.write('\n')
    end
    io.close(file)
end

aegisub.register_macro(script_name, script_description, extractText)
