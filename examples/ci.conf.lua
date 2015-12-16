local VM = require "ci.vm"

local systems = {
  debian = {
    stable = {
      amd64 = {
        dev  = {
          identifier = "debian-stable-amd64",
          user       = "cosyverif",
        },
      },
      i386 = {
        dev  = {
          identifier = "debian-stable-i386",
          user       = "cosyverif",
        },
      },
    },
  },
}

return function (t)
  local copev = t.copev

  for _, system in ipairs {
    systems.debian.stable.amd64,
  } do
    local vmm = VM.new {
      copev = copev,
    }
    copev.addthread (function ()
      local main = copev.running ()
      local client_archive
      copev.addthread (function ()
        local build_client = vmm (system.dev)
        build_client [[ sudo apt-get update  --yes ]]
        build_client [[ sudo apt-get install --yes git ]]
        build_client [[ git clone "https://github.com/CosyVerif/library.git" ]]
        build_client ([[ cd library && git checkout {{{branch}}} ]] % {
          branch = "issue-158",
        })
        local result = build_client [[ cd library && ./bin/build-client --in-ci]]
        local path   = result:match "(%S*cosy%-client%-.-%.tar%.gz)"
        client_archive = build_client [path]
        copev.wakeup (main)
      end)
      local server = nil
      copev.addthread (function ()
        local build_server = vmm (system.dev)
        build_server [[ sudo apt-get update  --yes ]]
        build_server [[ sudo apt-get install --yes git ]]
        build_server [[ git clone "https://github.com/CosyVerif/library.git" ]]
        build_server ([[ cd library && git checkout {{{branch}}} ]] % {
          branch = "issue-158",
        })
        build_server [[ cd library && ./bin/build-server --prefix=/home/cosyverif --in-ci]]
        server = true
        copev.wakeup (main)
      end)

      repeat
        copev.sleep (-math.huge)
      until client_archive and server

      local run_client = vmm (system.dev)
      run_client ["cosy-client.tar.gz"] = client_archive
      run_client [[ tar xvf cosy-client.tar.gz ]]
      run_client [[ ./usr/bin/cosy-version ]]
      run_client [[ ./usr/bin/cosy ]]
    end)
  end

end
