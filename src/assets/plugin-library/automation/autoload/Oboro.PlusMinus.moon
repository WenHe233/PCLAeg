export script_name = "Plus Minus"
export script_description = "Plus Minus"
export script_author = "Oborozuki"
export script_version = "0.0.1"

haveDepCtrl, DependencyControl = pcall require, "l0.DependencyControl"
local depctrl, GreatTags, math, clipboard
if haveDepCtrl
  depctrl = DependencyControl {
    feed: "https://raw.githubusercontent.com/oborozuk1/Aegisub-Scripts/main/DependencyControl.json"
    {
      "Oboro.GreatTags"
      "math"
      "aegisub.clipboard"
    }
  }
  GreatTags, math, clipboard = depctrl\requireModules!
else
  GreatTags = require "Oboro.GreatTags"
  math = require "math"
  clipboard = require "aegisub.clipboard"
{:Tag} = GreatTags

cycle = (list, value, reversed) ->
  for i, item in ipairs list
    if item == value
      return list[(i + (reversed and -1 or 1) - 1) % #list + 1]
  return list[1]

rgb_to_hsv = (r, g, b) ->
    r, g, b = r / 255, g / 255, b / 255
    max_val = math.max(r, g, b)
    min_val = math.min(r, g, b)
    delta = max_val - min_val

    v = max_val
    s = max_val == 0 and 0 or (delta / max_val)
    h = 0
    if delta == 0
        h = 0
    else if max_val == r
        h = 60 * (((g - b) / delta) % 6)
    else if max_val == g
        h = 60 * (((b - r) / delta) + 2)
    else if max_val == b
        h = 60 * (((r - g) / delta) + 4)

    if h < 0 then h = h + 360
    return h, s, v

hsv_to_rgb = (h, s, v) ->
    c = v * s
    x = c * (1 - math.abs((h / 60) % 2 - 1))
    m = v - c

    local r1, g1, b1
    if h < 60 then r1, g1, b1 = c, x, 0
    else if h < 120 then r1, g1, b1 = x, c, 0
    else if h < 180 then r1, g1, b1 = 0, c, x
    else if h < 240 then r1, g1, b1 = 0, x, c
    else if h < 300 then r1, g1, b1 = x, 0, c
    else r1, g1, b1 = c, 0, x

    r = (r1 + m) * 255
    g = (g1 + m) * 255
    b = (b1 + m) * 255

    return math.floor(r + 0.5), math.floor(g + 0.5), math.floor(b + 0.5)

addHSV = (color, dh = 0, ds = 0, dv = 0) ->
  value = tonumber color, 16
  r = value % 0x100
  g = math.floor(value / 0x100) % 0x100
  b = math.floor(value / 0x10000) % 0x100
  h, s, v = rgb_to_hsv(r, g, b)
  r, g, b = hsv_to_rgb(h + dh, s + ds, v + dv)
  return ("%02X%02X%02X")\format b, g, r

classData = 
  p:            { interval: 1,    decimal: 0, min: 0 }
  be:           { interval: 0.5,  decimal: 2, min: 0 }
  pbo:          { interval: 10,   decimal: 0 }
  blur:         { interval: 0.5,  decimal: 2, min: 0 }
  bord:         { interval: 0.5,  decimal: 2 }
  faxy:         { interval: 0.01, decimal: 6 }
  shad:         { interval: 0.5,  decimal: 2 }
  time:         { interval: 100,  decimal: -1 }
  angle:        { interval: 1,    decimal: 3 }
  scale:        { interval: 10,   decimal: 2, min: 0 }
  spacing:      { interval: 0.5,  decimal: 1 }
  duration:     { interval: 1,    decimal: 0, min: 0 }
  fontsize:     { interval: 1,    decimal: 0, min: 0, max: 511 }
  coordinate:   { interval: 5,    decimal: 3, }
  acceleration: { interval: 0.1,  decimal: 3, min: 0 }

  color: 
    mode: "cycle"
    list: { "000000", "FFFFFF" }
    double: (tagName, argument) -> argument.value = addHSV(argument.value, 0, 0, 0.1)
    halve: (tagName, argument) -> argument.value = addHSV(argument.value, 0, 0, -0.1)

  align: 
    interval: 1
    decimal: 0
    min: 1
    max: 9
    double: (tagName, argument) -> argument.value = (argument.value + 2) % 9 + 1
    halve: (tagName, argument) -> argument.value = (argument.value + 1) % 9 + 1

  alpha:
    interval: 8
    decimal: 0
    min: 0
    max: 255
    preprocess: (argument) ->
      value = tonumber argument.value, 16
      argument.value = value and value % 0x100 or 0
    postprocess: (argument) ->
      argument.value = "%02X"\format argument.value

  effect:
    mode: "toggle"
    postprocess: (argument) ->
      argument.value = argument.value and 1 or 0

  fontname: 
    mode: "pattern-cycle"

    preprocess: (argument) ->
      flag = false
      if "@" == argument.value\sub 1, 1
        argument.value = argument.value\sub 2
        flag = true
      return { vertical: flag }

    postprocess: (argument, vars) ->
      if vars.vertical
        argument.value = "@" .. argument.value

    list: {
      {
        pattern: ".*#",
        values: {
          "方正兰亭圆_GBK_中#", "方正准雅宋_GBK#", "方正FW轻吟体 简 D#", "方正艺黑简繁#", "方正少儿简繁#",
          "方正FW珍珠体 简繁#", "汉仪正圆-65S#",
        }
      }
      {
        pattern: "方正兰亭圆_GBK.*",
        values: {
          "方正兰亭圆_GBK", "方正兰亭圆_GBK_准", "方正兰亭圆_GBK_中", "方正兰亭圆_GBK_中粗", "方正兰亭圆_GBK_粗",
          "方正兰亭圆_GBK_大", "方正兰亭圆_GBK_特", "方正兰亭圆_GBK_纤", "方正兰亭圆_GBK_细",
        }
      }
      {
        pattern: "方正.*雅宋_GBK",
        values: {
          "方正准雅宋_GBK", "方正中雅宋_GBK", "方正中粗雅宋_GBK", "方正粗雅宋_GBK", "方正大雅宋_GBK",
          "方正特雅宋_GBK", "方正纤雅宋_GBK", "方正细雅宋_GBK", "方正标雅宋_GBK",
        }
      }
      {
        pattern: "汉仪正圆.*",
        values: { "汉仪正圆-55S", "汉仪正圆-65S", "汉仪正圆-75S", "汉仪正圆-85S", "汉仪正圆-95S" }
      }
      {
        pattern: "方正FW轻吟体 简.*",
        values: { "方正FW轻吟体 简 D", "方正FW轻吟体 简 B", "方正FW轻吟体 简 E", "方正FW轻吟体 简 L", "方正FW轻吟体 简 M" }
      }
      {
        pattern: "汉仪正圆.*",
        values: { "汉仪正圆-55S", "汉仪正圆-65S", "汉仪正圆-75S", "汉仪正圆-85S", "汉仪正圆-95S" }
      }
      {
        pattern: "方正FW轻吟体 简.*",
        values: { "方正FW轻吟体 简 D", "方正FW轻吟体 简 B", "方正FW轻吟体 简 E", "方正FW轻吟体 简 L", "方正FW轻吟体 简 M" }
      }
    }
    
    double: (tagName, argument, vars) -> vars.vertical = not vars.vertical
    halve: (tagName, argument, vars) -> vars.vertical = not vars.vertical

string.trim = (s) -> s\match "^%s*(.-)%s*$"

string.rfind = (s, pattern, init, plain) ->
  init = init or #s
  lastPos = nil
  pos = 1
  while true
    startPos, endPos = string.find s, pattern, pos, plain
    break unless startPos and endPos <= init
    lastPos = startPos
    pos = startPos + 1
  return lastPos

string.split = (input, sep = ",") ->
  result = {}
  pattern = "(.-)" .. sep
  last_pos = 1
  for part, pos in input\gmatch pattern .. "()"
    table.insert result, part
    last_pos = pos
  table.insert result, input\sub last_pos
  return result

round = (num, precision = 3) ->
  shift = 10 ^ precision
  if num >= 0
    return math.floor(num * shift + 0.5) / shift
  else
    return math.ceil(num * shift - 0.5) / shift

log = (msg = "<nil>", end_ = "\n") ->
  aegisub.log tostring msg
  aegisub.log tostring end_

getTagBlock = (text, cursor) ->
  leftClose = string.rfind text, "}", cursor - 1
  leftOpen = string.rfind(text, "[^\\]{", cursor - 1)
  leftOpen = leftOpen and leftOpen + 1 or string.rfind(text, "^{", cursor - 1)
  rightClose =  text\find "}", cursor
  if leftOpen and rightClose and (not leftClose or leftOpen > leftClose)
    return text\sub(leftOpen + 1, rightClose - 1), leftOpen + 1, rightClose - 1

getTag = (tagBlock, cursor) ->
  leftBackSlash = string.rfind tagBlock, "\\", cursor - 1, true
  return unless leftBackSlash
  tagBlock = tagBlock\sub leftBackSlash
  tag = tagBlock\match "^\\[^\\(]*%([^)]*%)?"
  unless tag
    tag = tagBlock\match "^\\[^\\()]*"
  return unless tag
  return tag, leftBackSlash, leftBackSlash + #tag - 1

local modifyOperation
modifyOperation = {
  "wrap": (tagName, argument) ->
    className = argument.class
    if classData[className].min and argument.value < classData[className].min
      argument.value = classData[className].max and classData[className].max or classData[className].min
    if classData[className].max and argument.value > classData[className].max
      argument.value = classData[className].min and classData[className].min or classData[className].max

  "toggle": (tagName, argument) ->
    argument.value = not argument.value

  "patternCycle": (tagName, argument, reversed) ->
    className = argument.class
    for item in *classData[className].list
      if argument.value\match "^#{item.pattern}$"
        argument.value = cycle item.values, argument.value, reversed
        break

  "cycle": (tagName, argument, reversed) ->
    className = argument.class
    argument.value = cycle classData[className].list, argument.value, reversed

  "add": (tagName, argument, vars, reversed) ->
    className = argument.class
    if classData[className].add
      classData[className].add tagName, argument, vars
      return
    switch classData[className].mode
      when "toggle"
        modifyOperation.toggle tagName, argument
      when "pattern-cycle"
        modifyOperation.patternCycle tagName, argument, reversed
      when "cycle"
        modifyOperation.cycle tagName, argument, reversed
      else
        if reversed
          argument.value = argument.value - classData[className].interval
        else
          argument.value = argument.value + classData[className].interval
        modifyOperation.wrap tagName, argument
        if decimal = classData[className].decimal
          argument.value = round argument.value, decimal

  "subtract": (tagName, argument, vars) ->
    className = argument.class
    if classData[className].subtract
      classData[className].subtract tagName, argument, vars
    else
      modifyOperation.add tagName, argument, vars, true

  "multiply": (tagName, argument, times = 2) ->
    className = argument.class
    argument.value = argument.value * times
    modifyOperation.wrap tagName, argument
    if decimal = classData[className].decimal
      argument.value = round argument.value, decimal

  "double": (tagName, argument, vars) ->
    className = argument.class
    if classData[className].double
      classData[className].double tagName, argument, vars
    else
      modifyOperation.multiply tagName, argument, 2

  "halve": (tagName, argument, vars) ->
    className = argument.class
    if classData[className].halve
      classData[className].halve tagName, argument, vars
    else
      modifyOperation.multiply tagName, argument, 0.5
}

modifyArgument = (tag, tagRaw, cursor, op) ->
  return unless tag.valid and #tag.args > 0

  argument = Tag.argAtCursor tagRaw, cursor, tag
  return unless argument and classData[argument.class]

  preprocessData = {}
  if classData[argument.class].preprocess
    preprocessData = classData[argument.class].preprocess(argument) or {}

  modifyOperation[op] tag.name, argument, preprocessData
  return unless argument

  if classData[argument.class].postprocess
    classData[argument.class].postprocess argument, preprocessData

  tag\set argument

  tagText = tostring tag
  cursor = nil
  for i = 1, #tagText
    if argument.index == Tag.argAtCursor(tagText, i, tag).index
      cursor = i + 1
    else if cursor
      break
  cursor = cursor or #tagText + 1
  cursor -= 1 unless tag.simple
  return tagText, cursor

modify = (sub, index, op) ->
  cursor = aegisub.gui.get_cursor!
  line = sub[index]
  tagBlock, blockStart  = getTagBlock line.text, cursor
  unless tagBlock
    if op == "paste"
      newTagText = clipboard.get!
      line.text = line.text\sub(1, cursor - 1) .. "{#{newTagText}}" .. line.text\sub(cursor)
      sub[index] = line
      aegisub.gui.set_cursor cursor + #newTagText + 2
    return

  cursor -=  blockStart - 1
  blockStart -= 1
  tagText, tagStart, tagEnd = getTag tagBlock, cursor
  unless tagText
    log "No tag found at cursor position."
    return

  tagObj = Tag tagText
  switch op
    when "copy"
      clipboard.set tagText
      return
    when "paste"
      pasteTag = Tag clipboard.get!
      newTagText = tostring pasteTag
      unless pasteTag.name == tagObj.name
        newTagText = tagText .. newTagText
      line.text = line.text\sub(1, blockStart + tagStart - 1) .. newTagText .. line.text\sub(blockStart + tagEnd + 1)
      sub[index] = line
      aegisub.gui.set_cursor blockStart + tagStart + #newTagText
      return
    when "erase"
      if not tagObj.simple or #tagObj.args == 0
        tagText = ""
      else
        tagText = "\\#{tagObj.name}"
      line.text = line.text\sub(1, blockStart + tagStart - 1) .. tagText .. line.text\sub(blockStart + tagEnd + 1)
      sub[index] = line
      aegisub.gui.set_cursor blockStart + tagStart + #tagText
      return

  cursor -= tagStart - 1
  newTag, newCursor = modifyArgument tagObj, tagText, cursor, op
  unless newTag
    log "No valid tag found at cursor position."
    return

  line.text = line.text\sub(1, blockStart + tagStart - 1) .. newTag .. line.text\sub(blockStart + tagEnd + 1)
  sub[index] = line
  aegisub.gui.set_cursor blockStart + tagStart + newCursor - 1

call = (op) ->
  (sub, _, act) -> modify sub, act, op

if haveDepCtrl
  depctrl\registerMacros {
    { "Add",      "Add value",          call "add"      }
    { "Copy",     "Copy value",         call "copy"     }
    { "Double",   "Double value",       call "double"   }
    { "Erase",    "Erase value / tag",  call "erase"    }
    { "Halve",    "Halve value",        call "halve"    }
    { "Paste",    "Paste value",        call "paste"    }
    { "Subtract", "Subtract value",     call "subtract" }
  }
else
  aegisub.register_macro "#{script_name}/Add",      "Add value",          call "add"
  aegisub.register_macro "#{script_name}/Copy",     "Copy value",         call "copy"
  aegisub.register_macro "#{script_name}/Double",   "Double value",       call "double"
  aegisub.register_macro "#{script_name}/Erase",    "Erase value / tag",  call "erase"
  aegisub.register_macro "#{script_name}/Halve",    "Halve value",        call "halve"
  aegisub.register_macro "#{script_name}/Paste",    "Paste value",        call "paste"
  aegisub.register_macro "#{script_name}/Subtract", "Subtract value",     call "subtract"
