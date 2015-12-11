local Socket = require "socket"

local VMS = {}
local VM  = {}

local function execute (command)
  print ("Executing command: " .. command)
  local handler = assert (io.popen (command, "r"))
  local output  = assert (handler:read "*all")
  local status  = { handler:close () }
  if status [1] then
    return output
  else
    return table.unpack (status)
  end
end

function VMS.__call (vms, source)
  assert (getmetatable (vms) == VMS)
  local tmp = os.tmpname ()
  local identifier = tmp:match "[^/]+$"
  local path       = tmp:sub (1, #tmp - #identifier)
  os.remove (tmp)
  local ok, err = execute ([[
    VBoxManage clonevm --mode machine --name {{{name}}} --basefolder {{{path}}} --register {{{source}}}
  ]] % {
    name   = string.format ("%q", identifier),
    path   = string.format ("%q", path),
    source = string.format ("%q", source.identifier),
  })
  if not ok then
    error (err)
  end
  local server = Socket.bind ("*", 0)
  local _, port = server:getsockname ()
  server:close ()
  assert (execute ([[
    VBoxManage modifyvm {{{name}}} --natpf1 ",tcp,,{{{port}}},,22"
  ]] % {
    name = string.format ("%q", identifier),
    port = port,
  }))
  assert (execute ([[
    VBoxManage startvm {{{name}}} --type headless
  ]] % {
    name = identifier,
  }))
  local result = setmetatable ({
    identifier  = identifier,
    user        = source.user,
    path        = path,
    port        = tonumber (port),
  }, VM)
  return result
end

VM.__index = VM

function VM.__gc (vm)
  assert (getmetatable (vm) == VM)
  assert (execute ([[
    VBoxManage controlvm    {{{name}}} poweroff
  ]] % {
    name = string.format ("%q", vm.identifier),
  }))
  repeat
    local ok = execute ([[
      VBoxManage unregistervm {{{name}}} --delete
    ]] % {
      name = string.format ("%q", vm.identifier),
    })
  until ok
end

function VM.__call (vm, command)
  assert (getmetatable (vm) == VM)
  return assert (execute ([[
    ssh -o "StrictHostKeyChecking no" -o "UserKnownHostsFile /dev/null" -p {{{port}}} {{{user}}}@127.0.0.1 {{{command}}}
  ]] % {
    port    = vm.port,
    user    = string.format ("%q", vm.user),
    command = string.format ("%q", command),
  }))
end

return setmetatable ({}, VMS)