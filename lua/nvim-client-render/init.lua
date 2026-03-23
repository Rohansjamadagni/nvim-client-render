local M = {}

---Setup the plugin
---@param opts table|nil
function M.setup(opts)
  local config = require("nvim-client-render.config")
  config.setup(opts)

  -- Ensure state directories exist
  vim.fn.mkdir(config.values.ssh.control_dir, "p")
  vim.fn.mkdir(config.values.project.base_dir, "p")

  -- Register commands
  require("nvim-client-render.commands").setup()

  -- Clean up on exit and handle fugitive events
  local augroup = vim.api.nvim_create_augroup("NvimClientRender", { clear = true })

  vim.api.nvim_create_autocmd("User", {
    group = augroup,
    pattern = "FugitiveChanged",
    callback = function()
      pcall(function() require("nvim-client-render.git").on_fugitive_changed() end)
    end,
  })

  vim.api.nvim_create_autocmd("VimLeavePre", {
    group = augroup,
    callback = function()
      local sync = require("nvim-client-render.sync")
      local ssh = require("nvim-client-render.ssh")

      -- Teardown all git sessions
      pcall(function() require("nvim-client-render.git").teardown() end)

      -- Stop all remote watchers, terminals, and LSP
      pcall(function() require("nvim-client-render.remote_watcher").stop() end)
      pcall(function() require("nvim-client-render.terminal").close_all() end)
      pcall(function() require("nvim-client-render.lsp").stop_all() end)

      -- Teardown all file watchers
      pcall(function() require("nvim-client-render.watcher").teardown() end)

      -- Flush with a timeout so we don't hang forever
      local flushed = false
      sync.flush(function()
        flushed = true
      end)

      -- Wait up to 5 seconds for flush
      vim.wait(5000, function() return flushed end, 100)

      -- Disconnect all SSH sessions
      local disconnected = false
      ssh.disconnect_all(function()
        disconnected = true
      end)

      vim.wait(3000, function() return disconnected end, 100)
    end,
  })
end

---Open a remote project (convenience wrapper)
---@param host string
---@param remote_path string
---@param callback fun(err: string|nil)|nil
function M.open(host, remote_path, callback)
  callback = callback or function(err)
    if err then
      vim.notify("[nvim-client-render] " .. err, vim.log.levels.ERROR)
    end
  end
  require("nvim-client-render.project").open(host, remote_path, callback)
end

---Get current status
---@return table|nil
function M.status()
  return require("nvim-client-render.project").get_active()
end

---Close the active project
---@param callback fun(err: string|nil)|nil
function M.close(callback)
  require("nvim-client-render.project").close(callback)
end

return M
