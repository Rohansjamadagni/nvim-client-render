local config = require("nvim-client-render.config")
local ssh = require("nvim-client-render.ssh")
local transfer = require("nvim-client-render.transfer")
local watcher = require("nvim-client-render.watcher")
local sync = require("nvim-client-render.sync")

local M = {}

---@class ProjectInfo
---@field host string
---@field remote_path string
---@field local_path string
---@field name string

---@type ProjectInfo|nil
M._active = nil

---Compute the local mirror path for a host and remote path
---@param host string
---@param remote_path string
---@return string
local function compute_local_path(host, remote_path)
  local base = config.values.project.base_dir
  local host_id = vim.fn.sha256(host):sub(1, 12)
  local name = vim.fn.fnamemodify(remote_path, ":t")
  if name == "" then
    name = "root"
  end
  return base .. "/" .. host_id .. "/" .. name
end

---Open a remote project
---@param host string
---@param remote_path string
---@param callback fun(err: string|nil)
function M.open(host, remote_path, callback)
  -- Normalize remote path: remove trailing slash
  remote_path = remote_path:gsub("/$", "")

  vim.notify("[nvim-client-render] Connecting to " .. host .. "...", vim.log.levels.INFO)

  ssh.connect(host, function(err)
    if err then
      callback("SSH connection failed: " .. err)
      return
    end

    local local_path = compute_local_path(host, remote_path)
    vim.fn.mkdir(local_path, "p")

    vim.notify("[nvim-client-render] Syncing " .. remote_path .. "...", vim.log.levels.INFO)

    transfer.sync_folder(host, remote_path, local_path, function(sync_err)
      if sync_err then
        callback("Folder sync failed: " .. sync_err)
        return
      end

      local name = vim.fn.fnamemodify(remote_path, ":t")
      if name == "" then
        name = "root"
      end

      M._active = {
        host = host,
        remote_path = remote_path,
        local_path = vim.fn.fnamemodify(local_path, ":p"):gsub("/$", ""),
        name = name,
      }

      -- Set up file watchers
      watcher.setup(M._active)

      -- Start remote watcher for 2-way sync
      local remote_watcher = require("nvim-client-render.remote_watcher")
      local watcher_ok, watcher_err = pcall(remote_watcher.start, M._active)
      if not watcher_ok then
        vim.notify("[nvim-client-render] Remote watcher: " .. tostring(watcher_err), vim.log.levels.WARN)
      end

      -- Auto-detect and setup git integration (non-blocking, non-fatal)
      local git = require("nvim-client-render.git")
      git.setup(M._active, function(git_err)
        if git_err then
          vim.notify("[nvim-client-render] Git: " .. git_err, vim.log.levels.DEBUG)
        end
      end)

      -- Auto cd into local mirror
      if config.values.project.auto_cd then
        vim.cmd("cd " .. vim.fn.fnameescape(M._active.local_path))
      end

      vim.notify(
        "[nvim-client-render] Project ready: " .. M._active.name .. " (" .. M._active.local_path .. ")",
        vim.log.levels.INFO
      )

      callback(nil)
    end)
  end)
end

---Close the active project
---@param callback fun(err: string|nil)|nil
function M.close(callback)
  callback = callback or function() end

  if not M._active then
    callback(nil)
    return
  end

  local host = M._active.host

  -- Flush sync queue first
  sync.flush(function()
    -- Teardown git integration
    pcall(function() require("nvim-client-render.git").teardown() end)

    -- Stop remote watcher, terminals, and LSP before tearing down
    local remote_watcher = require("nvim-client-render.remote_watcher")
    remote_watcher.stop()

    local terminal = require("nvim-client-render.terminal")
    terminal.close_all()

    local lsp_mod = require("nvim-client-render.lsp")
    lsp_mod.stop_all()

    watcher.teardown()
    M._active = nil
    callback(nil)
  end)
end

---Map a local path to its corresponding remote path
---@param local_path string
---@return string|nil
function M.local_to_remote(local_path)
  if not M._active then
    return nil
  end

  local norm_local = vim.fn.fnamemodify(local_path, ":p"):gsub("/$", "")
  local norm_base = vim.fn.fnamemodify(M._active.local_path, ":p"):gsub("/$", "")

  if norm_local:sub(1, #norm_base) == norm_base then
    local relative = norm_local:sub(#norm_base + 1)
    return M._active.remote_path .. relative
  end

  return nil
end

---Map a remote path to its corresponding local path
---@param remote_path string
---@return string|nil
function M.remote_to_local(remote_path)
  if not M._active then
    return nil
  end

  if remote_path:sub(1, #M._active.remote_path) == M._active.remote_path then
    local relative = remote_path:sub(#M._active.remote_path + 1)
    return M._active.local_path .. relative
  end

  return nil
end

---Check if a file path is within the active project
---@param filepath string
---@return boolean
function M.is_project_file(filepath)
  if not M._active then
    return false
  end

  local norm = vim.fn.fnamemodify(filepath, ":p"):gsub("/$", "")
  local norm_base = vim.fn.fnamemodify(M._active.local_path, ":p"):gsub("/$", "")

  return norm:sub(1, #norm_base) == norm_base
end

---Get the active project info
---@return ProjectInfo|nil
function M.get_active()
  return M._active
end

---Refresh: re-sync from remote
---@param callback fun(err: string|nil)|nil
function M.refresh(callback)
  callback = callback or function() end

  if not M._active then
    callback("No active project")
    return
  end

  vim.notify("[nvim-client-render] Refreshing from remote...", vim.log.levels.INFO)

  transfer.sync_folder(M._active.host, M._active.remote_path, M._active.local_path, function(err)
    if err then
      callback("Refresh failed: " .. err)
      return
    end

    vim.notify("[nvim-client-render] Refresh complete", vim.log.levels.INFO)

    -- Reload any open buffers that changed
    vim.cmd("checktime")
    callback(nil)
  end)
end

return M
