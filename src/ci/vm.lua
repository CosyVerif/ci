local Colors = require "ansicolors"
local Socket = require "socket"

local VMS = {}
local VM  = {}

function VMS.new (t)
  return setmetatable ({
    copev = assert (t.copev),
  }, VMS)
end

function VMS.execute (t, command)
  local vms
  if getmetatable (t) == VMS then
    vms = t
  elseif getmetatable (t) == VM then
    vms = t.manager
  else
    assert (false)
  end
  local copev    = vms.copev
  local stdout   = os.tmpname ()
  local stderr   = os.tmpname ()
  local finished = false
  do
    local prefix = "%{yellow}"
    if getmetatable (t) == VM then
      prefix = prefix .. "[" .. t.identifier .. "] "
    end
    local suffix = "%{reset}\n"
    io.write (Colors (prefix .. command:gsub ("^%s*(.-)%s*$", "%1") .. suffix))
  end
  for filename, color in pairs {
    [stdout] = "green",
    [stderr] = "red"
  } do
    local prefix = "%{" .. color .. "}"
    if getmetatable (t) == VM then
      prefix = prefix .. "[" .. t.identifier .. "] "
    end
    local suffix = "%{reset}\n"
    copev.addthread (function ()
      local file = io.open (filename, "r")
      while not finished do
        local line = file:read "*line"
        if line then
          io.write (Colors (prefix .. line .. suffix))
          if math.random () >= 0.8 then
            copev.pass ()
          end
        else
          copev.sleep (0.5)
        end
      end
      file:close ()
    end)
  end
  local ok, reason, status = copev.execute (command, {
    stdout = stdout,
    stderr = stderr,
  })
  finished = true
  if ok then
    local results = {}
    for i, filename in ipairs { stdout, stderr } do
      local file = io.open (filename, "r")
      results [i] = file:read "*all"
      file:close ()
      os.remove (filename)
    end
    return results [1], results [2]
  else
    return nil, reason, status
  end
end

function VMS.__call (vms, source)
  assert (getmetatable (vms) == VMS)
  local tmp        = os.tmpname ()
  local identifier = tmp:match "[^/]+$"
  local path       = tmp:sub (1, #tmp - #identifier)
  os.remove (tmp)
  local ok, err = VMS.execute (vms, [[
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
  assert (VMS.execute (vms, [[
    VBoxManage modifyvm {{{name}}} --natpf1 ",tcp,,{{{port}}},,22"
  ]] % {
    name = string.format ("%q", identifier),
    port = port,
  }))
  assert (VMS.execute (vms, [[
    VBoxManage startvm {{{name}}} --type headless
  ]] % {
    name = identifier,
  }))
  local result = setmetatable ({
    manager     = vms,
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
  local vms   = vm.manager
  local copev = vms.copev
  copev.addthread (function ()
    assert (VMS.execute (vm, [[
      VBoxManage controlvm {{{name}}} poweroff
    ]] % {
      name = string.format ("%q", vm.identifier),
    }))
    repeat
      local ok = VMS.execute (vm, [[
        VBoxManage unregistervm {{{name}}} --delete
      ]] % {
        name = string.format ("%q", vm.identifier),
      })
    until ok
  end)
end

function VM.__call (vm, command)
  assert (getmetatable (vm) == VM)
  return assert (VMS.execute (vm, [[
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
  local found = VMS.execute (vm, [[
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
  VMS.execute (vm, [[ rm -f {{{tmp}}} && mkdir -p {{{tmp}}} ]] % {
    tmp = tmp,
  })
  assert (VMS.execute (value.vm, [[
    scp -r -o "StrictHostKeyChecking no" -o "UserKnownHostsFile /dev/null" -o "LogLevel=quiet" -P {{{port}}} {{{user}}}@127.0.0.1:{{{path}}} {{{tmp}}}/copy
  ]] % {
    port = value.vm.port,
    user = string.format ("%q", value.vm.user),
    path = string.format ("%q", value.path),
    tmp  = tmp,
  }))
  assert (VMS.execute (vm, [[
    scp -r -o "StrictHostKeyChecking no" -o "UserKnownHostsFile /dev/null" -o "LogLevel=quiet" -P {{{port}}} {{{tmp}}}/copy {{{user}}}@127.0.0.1:{{{path}}}
  ]] % {
    port = vm.port,
    user = string.format ("%q", vm.user),
    path = string.format ("%q", key),
    tmp  = tmp,
  }))
end

return VMS
