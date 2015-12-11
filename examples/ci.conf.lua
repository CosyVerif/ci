local VM = require "ci.vm"

return function ()

  local systems = {
    debian = {
      dev  = {
        identifier = "Ubuntu 12.04",
        user       = "alinard",
      },
    },
  }
  for name, system in pairs (systems) do
    print ("Building on " .. name)
    local build_client = VM (system.dev)
    build_client [[ git clone "https://github.com/CosyVerif/library.git" ]]
    local client_output = build_client [[ cd library && ./bin/build/client ]]
    print (client_output)
  end

end
