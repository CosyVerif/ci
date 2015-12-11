local Argparse = require "argparse"
local Coronest = require "coroutine.make"
local I18n     = require "i18n"
local Lustache = require "lustache"

_G.coroutine = Coronest ()

do
  local Metatable = getmetatable ""
  Metatable.__mod = function (pattern, variables)
    return Lustache:render (pattern, variables)
  end
end

local locale = (os.getenv "LANG" or "en")
             : match "[^%.]+"
             : gsub ("_", "-")

do
  I18n.load (require "ci.i18n.en")
  local ok, translation = pcall (require, "ci.i18n.{{{locale}}}" % {
    locale = locale,
  })
  if ok then
    I18n.load (translation)
  end
end

local parser   = Argparse () {
  name        = "ci",
  description = I18n "ci:description",
}
parser:option "-l" "--locale" {
  description = I18n "ci:option:locale",
  default     = locale,
}
parser:mutex (
  parser:flag "-q" "--quiet" {
    description = I18n "ci:flag:quiet",
  },
  parser:flag "-v" "--verbose" {
    description = I18n "ci:flag:verbose",
  }
)
parser:option "-p" "--path" {
  description = I18n "ci:option:path",
  default     = os.getenv "PWD",
}

local arguments = parser:parse ()

local chunk, err1 = loadfile (arguments.path .. "/ci.conf.lua")
if not chunk then
  print ((I18n "ci:no-configuration") % {
    error = err1,
  })
  os.exit (1)
end
local ok2, loaded = pcall (chunk)
if not ok2 then
  print ((I18n "ci:error-configuration") % {
    error = loaded,
  })
  os.exit (1)
end
local ok3, err3 = pcall (loaded, {})
if not ok3 then
  print ((I18n "ci:error") % {
    error = err3,
  })
end

collectgarbage "collect"
