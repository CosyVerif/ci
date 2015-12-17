local Colors = require "ansicolors"
local Socket = require "socket"

local VMS = {}
local VM  = {}

local Data = setmetatable ({}, { __mode = "k" })

function VMS.new (t)
  local tmp        = os.tmpname ()
  local identifier = tmp:match "[^/]+$"
  local result     = setmetatable ({}, VMS)
  Data [result]    = {
    copev      = assert (t.copev),
    registered = {},
    identifier = identifier,
    tmp        = tmp,
  }
  assert (VMS.execute (result, [[
    VBoxManage natnetwork add --netname {{{network}}} --network "192.168.15.0/24" --enable --dhcp on
  ]] % {
    network = string.format ("%q", identifier),
  }))
  assert (VMS.execute (result, [[
    VBoxManage natnetwork start --netname {{{network}}}
  ]] % {
    network = string.format ("%q", identifier),
  }))
  return result
end

function VMS.execute (t, command)
  local vms
  local vm
  if getmetatable (t) == VMS then
    vms = Data [t]
  elseif getmetatable (t) == VM then
    vm  = Data [t]
    vms = Data [vm.manager]
  else
    print (command)
    assert (false)
  end
  local copev    = vms.copev
  local stdout   = os.tmpname ()
  local stderr   = os.tmpname ()
  local finished = 0
  do
    local prefix = "%{yellow}[{{{identifier}}}]: " % {
      identifier = vm and vm.identifier or "",
    }
    local suffix = "%{reset}\n"
    io.write (Colors (prefix .. command:gsub ("^%s*(.-)%s*$", "%1") .. suffix))
  end
  for filename, color in pairs {
    [stdout] = "green",
    [stderr] = "red"
  } do
    local prefix = ("%{" .. color .. "}[{{{identifier}}}]: ") % {
      identifier = vm and vm.identifier or "",
    }
    local suffix = "%{reset}\n"
    copev.addthread (function ()
      local file = io.open (filename, "r")
      while true do
        local line = file:read "*line"
        if finished > 0 and not line then
          break
        end
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
      finished = finished + 1
    end)
  end
  local ok, reason, status = copev.execute (command, {
    stdout = stdout,
    stderr = stderr,
  })
  finished = finished + 1
  if ok then
    local results = {}
    for i, filename in ipairs { stdout, stderr } do
      local file = io.open (filename, "r")
      results [i] = file:read "*all"
      file:close ()
      while finished ~= 3 do
        copev.sleep (0.5)
      end
      os.remove (filename)
    end
    return results [1], results [2]
  else
    return nil, reason, status
  end
end

function VMS.__gc (vms)
  assert (getmetatable (vms) == VMS)
  local data = Data [vms]
  local copev = data.copev
  copev.addthread (function ()
    assert (VMS.execute (vms, [[
      VBoxManage natnetwork stop --netname {{{network}}}
    ]] % {
      network = string.format ("%q", data.identifier),
    }))
    assert (VMS.execute (vms, [[
      VBoxManage natnetwork remove --netname {{{network}}}
    ]] % {
      network = string.format ("%q", data.identifier),
    }))
    os.remove (data.tmp)
  end)
end

function VMS.__call (vms, source)
  assert (getmetatable (vms) == VMS)
  local data       = Data [vms]
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
    VBoxManage modifyvm {{{name}}} --nic1 nat    --natpf1 delete ssh
    VBoxManage modifyvm {{{name}}} --nic1 nat    --natpf1  ",tcp,,{{{port}}},,22"
    VBoxManage modifyvm {{{name}}} --nic2 intnet --intnet2 {{{network}}}
  ]] % {
    name    = string.format ("%q", identifier),
    network = string.format ("%q", data.identifier),
    port    = port,
  }))
  assert (VMS.execute (vms, [[
    VBoxManage startvm {{{name}}} --type headless
  ]] % {
    name = string.format ("%q", identifier),
  }))
  local result = setmetatable ({}, VM)
  Data [result] = {
    manager     = vms,
    identifier  = identifier,
    user        = source.user,
    path        = path,
    port        = tonumber (port),
  }
  return result
end

function VMS.__index (vms, key)
  assert (getmetatable (vms) == VMS)
  if type (key) ~= "string" then
    return nil
  end
  vms = Data [vms]
  return vms.registered [key]
end

function VMS.__newindex (vms, key, vm)
  assert (getmetatable (vms) == VMS)
  assert (getmetatable (vm ) == VM )
  assert (type (key) == "string")
  vms = Data [vms]
  vms.registered [key] = vm
end

function VM.__gc (vm)
  assert (getmetatable (vm) == VM)
  local data_vm  = Data [vm]
  local vms      = data_vm.manager
  local data_vms = Data [vms]
  local copev    = data_vms.copev
  copev.addthread (function ()
    assert (VMS.execute (vm, [[
      VBoxManage controlvm {{{name}}} poweroff
    ]] % {
      name = string.format ("%q", data_vm.identifier),
    }))
    repeat
      local ok = VMS.execute (vm, [[
        VBoxManage unregistervm {{{name}}} --delete
      ]] % {
        name = string.format ("%q", data_vm.identifier),
      })
    until ok
  end)
end

function VM.__call (vm, command)
  assert (getmetatable (vm) == VM)
  local data = Data [vm]
  return assert (VMS.execute (vm, [[
    ssh -o "StrictHostKeyChecking no" -o "UserKnownHostsFile /dev/null" -o "LogLevel=quiet" -p {{{port}}} {{{user}}}@127.0.0.1 {{{command}}}
  ]] % {
    port    = data.port,
    user    = string.format ("%q", data.user),
    command = string.format ("%q", command:gsub ("^%s*(.-)%s*$", "%1")),
  }))
end

local Path = {}

function VM.__index (vm, key)
  assert (getmetatable (vm) == VM)
  assert (type (key) == "string")
  local data = Data [vm]
  key = key:match "^(.-)[/]*$"
  local found = VMS.execute (vm, [[
    ssh -o "StrictHostKeyChecking no" -o "UserKnownHostsFile /dev/null" -o "LogLevel=quiet" -p {{{port}}} {{{user}}}@127.0.0.1 ls {{{path}}}
  ]] % {
    port = data.port,
    user = string.format ("%q", data.user),
    path = string.format ("%q", key),
  })
  if not found then
    return nil
  end
  local result = setmetatable ({}, Path)
  Data [result] = {
    vm   = vm,
    path = key,
  }
  return result
end

function VM.__newindex (vm, key, value)
  assert (getmetatable (vm) == VM)
  assert (type (key) == "string")
  assert (getmetatable (value) == Path)
  local path      = Data [value]
  local source_vm = path.vm
  local target_vm = vm
  local source    = Data [source_vm]
  local target    = Data [target_vm]
  local vms       = source.manager
  local tmp       = os.tmpname ()
  VMS.execute (vms, [[ rm -f {{{tmp}}} && mkdir -p {{{tmp}}} ]] % {
    tmp = tmp,
  })
  assert (VMS.execute (source_vm, [[
    scp -r -o "StrictHostKeyChecking no" -o "UserKnownHostsFile /dev/null" -o "LogLevel=quiet" -P {{{port}}} {{{user}}}@127.0.0.1:{{{path}}} {{{tmp}}}/copy
  ]] % {
    port = source.port,
    user = string.format ("%q", source.user),
    path = string.format ("%q", path.path),
    tmp  = tmp,
  }))
  assert (VMS.execute (target_vm, [[
    scp -r -o "StrictHostKeyChecking no" -o "UserKnownHostsFile /dev/null" -o "LogLevel=quiet" -P {{{port}}} {{{tmp}}}/copy {{{user}}}@127.0.0.1:{{{path}}}
  ]] % {
    port = target.port,
    user = string.format ("%q", target.user),
    path = string.format ("%q", key),
    tmp  = tmp,
  }))
end

return VMS
