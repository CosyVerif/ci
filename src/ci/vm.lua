local Socket = require "socket"

local VMS = {}
local VM  = {}

local function execute (command)
  local handler = assert (io.popen ([[ {{{command}}} 2>&1 ]] % {
    command = command,
  }, "r"))
  local lines   = {}
  for line in handler:lines () do
    print (line)
    lines [#lines+1] = line
  end
  local status  = { handler:close () }
  if status [1] then
    return table.concat (lines, "\n")
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
  print ("Executing command: " .. command)
  return assert (execute ([[
    ssh -o "StrictHostKeyChecking no" -o "UserKnownHostsFile /dev/null" -o "LogLevel=quiet" -p {{{port}}} {{{user}}}@127.0.0.1 {{{command}}}
  ]] % {
    port    = vm.port,
    user    = string.format ("%q", vm.user),
    command = string.format ("%q", command),
  }))
end

local Path = {}

function VM.__index (vm, key)
  assert (getmetatable (vm) == VM)
  assert (type (key) == "string")
  key = key:match "^(.-)[/]*$"
  local found = execute ([[
    ssh -o "StrictHostKeyChecking no" -o "UserKnownHostsFile /dev/null" -o "LogLevel=quiet" -p {{{port}}} {{{user}}}@127.0.0.1 ls {{{path}}}
  ]] % {
    port = vm.port,
    user = string.format ("%q", vm.user),
    path = string.format ("%q", key),
  })
  if not found then
    return nil
  end
  return setmetatable ({
    vm   = vm,
    path = key,
  }, Path)
end

function VM.__newindex (vm, key, value)
  assert (getmetatable (vm) == VM)
  assert (type (key) == "string")
  assert (getmetatable (value) == Path)
  local tmp = os.tmpname ()
  os.execute ([[ rm -f {{{tmp}}} && mkdir -p {{{tmp}}} ]] % {
    tmp = tmp,
  })
  assert (execute ([[
    scp -r -o "StrictHostKeyChecking no" -o "UserKnownHostsFile /dev/null" -P {{{port}}} {{{user}}}@127.0.0.1:{{{path}}} {{{tmp}}}/copy
  ]] % {
    port = value.vm.port,
    user = string.format ("%q", value.vm.user),
    path = string.format ("%q", value.path),
    tmp  = tmp,
  }))
  assert (execute ([[
    scp -r -o "StrictHostKeyChecking no" -o "UserKnownHostsFile /dev/null" -P {{{port}}} {{{tmp}}}/copy {{{user}}}@127.0.0.1:{{{path}}}
  ]] % {
    port = vm.port,
    user = string.format ("%q", vm.user),
    path = string.format ("%q", key),
    tmp  = tmp,
  }))
end

return setmetatable ({}, VMS)
