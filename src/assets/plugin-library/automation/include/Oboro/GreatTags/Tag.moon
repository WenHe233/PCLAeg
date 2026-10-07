orderedTagKeys = {
  "iclip", "clip", "move", "fade", "fad", "org", "pos", "t", "alpha", "xbord", "xshad", "ybord", "yshad",
  "blur", "bord", "fscx", "fscy", "shad", "fax", "fay", "frx", "fry", "frz", "fsc", "fsp", "pbo",
  "an", "be", "fe", "fn", "fr", "fs", "kf", "ko", "kt", "1a", "2a", "3a", "4a", "1c", "2c", "3c", "4c",
  "K", "a", "c", "b", "i", "k", "r", "s", "u", "p", "q"
}

tagArgs = 
  clip:
    simple: false
    line: true
    nestable: true
    variants: {
      {
        { class: "drawing", typer: "drawing" }
      }
      {
        { class: "drawing-scale", typer: "number"  }
        { class: "drawing",       typer: "drawing" }
      }
      {
        { class: "coordinate", typer: "number" }
        { class: "coordinate", typer: "number" }
        { class: "coordinate", typer: "number" }
        { class: "coordinate", typer: "number" }
      }
    }

  fade:
    simple: false
    line: true
    nestable: false
    variants: {
      {
        { class: "time", typer: "number" }
        { class: "time", typer: "number" }
      }
      {
        { class: "alpha-dec", typer: "number" }
        { class: "alpha-dec", typer: "number" }
        { class: "alpha-dec", typer: "number" }
        { class: "time",      typer: "number" }
        { class: "time",      typer: "number" }
        { class: "time",      typer: "number" }
        { class: "time",      typer: "number" }
      }
    }

  pos:
    simple: false
    line: true
    nestable: false
    variants: {
      {
        { class: "coordinate", typer: "number" }
        { class: "coordinate", typer: "number" }
      }
    }

tagArgs =
  iclip: tagArgs.clip
  clip:  tagArgs.clip
  move:
    simple: false
    line: true
    nestable: false
    variants: {
      {
        { class: "coordinate", typer: "number" }
        { class: "coordinate", typer: "number" }
        { class: "coordinate", typer: "number" }
        { class: "coordinate", typer: "number" }
      }
      {
        { class: "coordinate", typer: "number" }
        { class: "coordinate", typer: "number" }
        { class: "coordinate", typer: "number" }
        { class: "coordinate", typer: "number" }
        { class: "time",       typer: "number" }
        { class: "time",       typer: "number" }
      }
    }
  fade: tagArgs.fade
  fad:  tagArgs.fade
  org:  tagArgs.pos
  pos:  tagArgs.pos

  t:
    simple: false
    line: false
    nestable: false
    variants: {
      {
        { class: "acceleration", typer: "number" }
      }
      {
        { class: "time", typer: "number" }
        { class: "time", typer: "number" }
      }
      {
        { class: "time",         typer: "number" }
        { class: "time",         typer: "number" }
        { class: "acceleration", typer: "number" }
      }
    }

  -- Simple tags (takes one or no arguments)
  alpha: { simple: true, line: false, nestable: true,  argument: { class: "alpha",     typer: "alpha"   } }
  xbord: { simple: true, line: false, nestable: true,  argument: { class: "bord",      typer: "number"  } }
  xshad: { simple: true, line: false, nestable: true,  argument: { class: "shad",      typer: "number"  } }
  ybord: { simple: true, line: false, nestable: true,  argument: { class: "bord",      typer: "number"  } }
  yshad: { simple: true, line: false, nestable: true,  argument: { class: "shad",      typer: "number"  } }
  blur:  { simple: true, line: false, nestable: true,  argument: { class: "blur",      typer: "number"  } }
  bord:  { simple: true, line: false, nestable: true,  argument: { class: "bord",      typer: "number"  } }
  fscx:  { simple: true, line: false, nestable: true,  argument: { class: "scale",     typer: "number"  } }
  fscy:  { simple: true, line: false, nestable: true,  argument: { class: "scale",     typer: "number"  } }
  shad:  { simple: true, line: false, nestable: true,  argument: { class: "shad",      typer: "number"  } }
  fax:   { simple: true, line: false, nestable: true,  argument: { class: "faxy",      typer: "number"  } }
  fay:   { simple: true, line: false, nestable: true,  argument: { class: "faxy",      typer: "number"  } }
  frx:   { simple: true, line: false, nestable: true,  argument: { class: "angle",     typer: "number"  } }
  fry:   { simple: true, line: false, nestable: true,  argument: { class: "angle",     typer: "number"  } }
  frz:   { simple: true, line: false, nestable: true,  argument: { class: "angle",     typer: "number"  } }
  fsc:   { simple: true, line: false, nestable: true,  argument: { class: "scale",     typer: "number"  } }
  fsp:   { simple: true, line: false, nestable: true,  argument: { class: "spacing",   typer: "number"  } }
  pbo:   { simple: true, line: false, nestable: false, argument: { class: "pbo",       typer: "number"  } }
  an:    { simple: true, line: true,  nestable: false, argument: { class: "align",     typer: "number"  } }
  be:    { simple: true, line: false, nestable: true,  argument: { class: "be",        typer: "number"  } }
  fe:    { simple: true, line: false, nestable: false, argument: { class: "fe",        typer: "number"  } }
  fn:    { simple: true, line: false, nestable: false, argument: { class: "fontname",  typer: "string"  } }
  fr:    { simple: true, line: false, nestable: true,  argument: { class: "angle",     typer: "number"  } }
  fs:    { simple: true, line: false, nestable: true,  argument: { class: "fontsize",  typer: "number"  } }
  kf:    { simple: true, line: false, nestable: false, argument: { class: "duration",  typer: "number"  } }
  ko:    { simple: true, line: false, nestable: false, argument: { class: "duration",  typer: "number"  } }
  kt:    { simple: true, line: false, nestable: false, argument: { class: "duration",  typer: "number"  } }
  "1a":  { simple: true, line: false, nestable: true,  argument: { class: "alpha",     typer: "alpha"   } }
  "2a":  { simple: true, line: false, nestable: true,  argument: { class: "alpha",     typer: "alpha"   } }
  "3a":  { simple: true, line: false, nestable: true,  argument: { class: "alpha",     typer: "alpha"   } }
  "4a":  { simple: true, line: false, nestable: true,  argument: { class: "alpha",     typer: "alpha"   } }
  "1c":  { simple: true, line: false, nestable: true,  argument: { class: "color",     typer: "color"   } }
  "2c":  { simple: true, line: false, nestable: true,  argument: { class: "color",     typer: "color"   } }
  "3c":  { simple: true, line: false, nestable: true,  argument: { class: "color",     typer: "color"   } }
  "4c":  { simple: true, line: false, nestable: true,  argument: { class: "color",     typer: "color"   } }
  K:     { simple: true, line: false, nestable: false, argument: { class: "duration",  typer: "number"  } }
  a:     { simple: true, line: true,  nestable: false, argument: { class: "old-align", typer: "number"  } }
  c:     { simple: true, line: false, nestable: true,  argument: { class: "color",     typer: "color"   } }
  b:     { simple: true, line: false, nestable: false, argument: { class: "effect",    typer: "boolean" } }
  i:     { simple: true, line: false, nestable: false, argument: { class: "effect",    typer: "boolean" } }
  k:     { simple: true, line: false, nestable: false, argument: { class: "duration",  typer: "number"  } }
  r:     { simple: true, line: false, nestable: false, argument: { class: "style",     typer: "string"  } }
  s:     { simple: true, line: false, nestable: false, argument: { class: "effect",    typer: "boolean" } }
  u:     { simple: true, line: false, nestable: false, argument: { class: "effect",    typer: "boolean" } }
  p:     { simple: true, line: false, nestable: false, argument: { class: "p",         typer: "number"  } }
  q:     { simple: true, line: false, nestable: false, argument: { class: "q",         typer: "number"  } }

argTypes = {
  "alpha":   (value) -> value\match("^%s*[&H]*%+?(%x+)") or "00"
  "color":   (value) -> value\match("^%s*[&H]*%+?(%x+)") or "000000"
  "number":  (value) -> tonumber value
  "string":  (value) -> string.trim value
  "boolean": (value) -> value != "0"
  "drawing": (value) -> string.trim value
}

isSimpleTag = (tag) ->
  return tagArgs[tag] and tagArgs[tag].simple or false

-- also known as "first tag"
isLineTag = (tag) ->
  return tagArgs[tag] and tagArgs[tag].line or false

isNestableTag = (tag) ->
  return tagArgs[tag] and tagArgs[tag].nestable or false

class Argument
  new: (@value, @index = 1, @class = "unknown") =>

  __tostring: =>
    switch @class
      when "alpha"
        "&H%02X&"\format tonumber @value, 16
      when "color"
        "&H%06X&"\format tonumber @value, 16
      else
        tostring @value

class Tag
  new: (raw) =>
    splitArgs = (raw) ->
      return {} unless raw and raw != ""

      backslash_pos = raw\find "\\"
      if not backslash_pos
        parts = string.split raw, ","
        return [x for x in *parts when x\match "%S"]

      first_part = raw\sub 1, backslash_pos - 1
      result = [x for x in *string.split(first_part, ",") when x\match "%S"]
      table.insert result, raw\sub backslash_pos
      return result

    name, argsRaw = raw\match "^%\\([^\\(]*)%(([^)]*)"
    unless name
      name = raw\match "^%\\([^\\(]*)"
    unless name
      error "Invalid tag format: #{raw}"

    @args = splitArgs argsRaw
    for key in *orderedTagKeys
      if name\find "^#{key}"
        if tagArgs[key].simple and name != key
          table.insert @args, name\sub #key + 1
        @name = key
        break
    @name = @name or name
    @\validate!
    @simple = isSimpleTag @name
    @line = isLineTag @name
    @nestable = isNestableTag @name

  -- Validates the tag arguments based on the tag name.
  -- Returns a table of Argument objects and a boolean indicating validity.
  validateArgs: (name, args) ->
    _validate = (name, args) ->
      if tagArgs[name]
        if tagArgs[name].simple
          if #args == 0
            return args, true
          value = argTypes[tagArgs[name].argument.typer] args[1]
          args = { Argument value, 1, tagArgs[name].argument.class }
          return args, true
        else
          for variant in *tagArgs[name].variants
            if #args == #variant
              res = {}
              for i, arg in ipairs args
                value = argTypes[variant[i].typer] arg
                table.insert res, Argument value, i, variant[i].class
              return res, true
      args = [ Argument args[i], i, "unknown" for i in ipairs args ]
      return args, false

    args = [ tostring a for a in *args ]
    valid = false
    if name == "t" and #args > 0
      last = args[#args]
      table.remove args
      args, valid = _validate name, args
      table.insert args, Argument last, #args + 1, "tags"
    else
      args, valid = _validate name, args
   
    return args, valid

  validate: =>
    @args, @valid = Tag.validateArgs @name, @args
    return @

  -- Sets the i-th argument if index is provided or value is Argument,
  -- otherwise sets the entire tag arguments.
  set: (value, index) =>
    if "table" != type value
      @args[index or 1] = value
    else if Argument.__base == getmetatable value
      @args[index or value.index or 1] = value
    else
      @args = value
    @\validate!
    return @
  
  -- Returns the values of the tag arguments.
  getValues: => [ a.value for a in *@args ]

  copy: => Tag tostring @

  __tostring: =>
    if #@args == 0
      return "\\#{@name}"
    if @simple
      return "\\#{@name}#{@args[1]}"
    argsStr = [ tostring a for a in *@args ]
    return "\\#{@name}(#{table.concat argsStr, ","})"

  -- Finds the argument at the cursor position in a tag.
  -- Returns the argument object if found, otherwise returns nil.
  argAtCursor: (tagText, cursor, tagObj) ->
    return unless cursor

    tagObj = tagObj or Tag tagText
    return unless tagObj.valid and #tagObj.args > 0
    return tagObj.args[1] if tagObj.simple

    parenStart = tagText\find "(", 1, true
    return unless parenStart
    return tagObj.args[1] if cursor <= parenStart

    argText = tagText\sub parenStart + 1, cursor - 1
    commaCount = 0
    for _ in argText\gmatch "[,%s]+" do commaCount += 1 
    argIndex = math.min commaCount + 1, #tagObj.args
    return tagObj.args[argIndex]

{:Argument, :Tag, :isSimpleTag, :isLineTag, :isNestableTag}
