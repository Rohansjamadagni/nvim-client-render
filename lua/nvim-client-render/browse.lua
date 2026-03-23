local ssh = require("nvim-client-render.ssh")
local project = require("nvim-client-render.project")

local M = {}

---Browse remote directories and pick one to open
---@param host string
---@param base_path string|nil defaults to "~"
function M.browse(host, base_path)
  base_path = base_path or "~"

  local function do_browse()
    ssh.exec(host, "find " .. vim.fn.shellescape(base_path) .. " -maxdepth 2 -type d 2>/dev/null", function(code, stdout)
    if code ~= 0 or #stdout == 0 then
      vim.notify("[nvim-client-render] Could not list directories on " .. host, vim.log.levels.ERROR)
      return
    end

    vim.ui.select(stdout, {
      prompt = "Select remote folder to open:",
    }, function(choice)
      if choice then
        project.open(host, choice, function(err)
          if err then
            vim.notify("[nvim-client-render] " .. err, vim.log.levels.ERROR)
          end
        end)
      end
    end)
  end)
  end

  if not ssh.is_connected(host) then
    vim.notify("[nvim-client-render] Connecting to " .. host .. "...", vim.log.levels.INFO)
    ssh.connect(host, function(err)
      if err then
        vim.notify("[nvim-client-render] Connection failed: " .. err, vim.log.levels.ERROR)
        return
      end
      do_browse()
    end)
  else
    do_browse()
  end
end

return M
