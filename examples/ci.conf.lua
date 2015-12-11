local VM = require "ci.vm"

return function ()

  local systems = {
    debian = {
      dev  = {
        identifier = "debian-stable-amd64",
        user       = "cosyverif",
      },
    },
  }
  local build_client = VM (systems.debian.dev)
  build_client [[ sudo apt-get update  --yes     ]]
  build_client [[ sudo apt-get install --yes git ]]
  build_client [[ git clone "https://github.com/CosyVerif/library.git" ]]
  build_client ([[ cd library && git checkout {{{branch}}} ]] % {
    branch = "issue-158",
  })
  local result = build_client [[ cd library && ./bin/build-client ]]
  local path   = result:match "Packaging in (.*%.tar%.gz)"
  local run_client = VM (systems.debian.dev)
  run_client ["cosy-client.tar.gz"] = build_client [path]
  run_client [[ tar xvf cosy-client.tar.gz ]]
  run_client [[ ls && ls cosy && ls cosy/client ]]
end
