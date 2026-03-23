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

---@type table<string, ProjectInfo>
M._sessions = {}

---@type ProjectInfo|nil
M._active = nil

---Compute the local mirror path and project name for a host and remote path
---@param host string
---@param remote_path string
---@return string local_path
---@return string name
local function compute_local_path(host, remote_path)
  local base = config.values.project.base_dir
  local host_id = vim.fn.sha256(host):sub(1, 12)
  local name = vim.fn.fnamemodify(remote_path, ":t")
  if name == "" then
    name = "root"
  end
  return base .. "/" .. host_id .. "/" .. name, name
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

    local local_path, name = compute_local_path(host, remote_path)
    vim.fn.mkdir(local_path, "p")

    vim.notify("[nvim-client-render] Syncing " .. remote_path .. "...", vim.log.levels.INFO)

    transfer.sync_folder(host, remote_path, local_path, function(sync_err)
      if sync_err then
        callback("Folder sync failed: " .. sync_err)
        return
      end

      local norm_local_path = vim.fn.fnamemodify(local_path, ":p"):gsub("/$", "")

      local project_info = {
        host = host,
        remote_path = remote_path,
        local_path = norm_local_path,
        name = name,
      }

      M._sessions[norm_local_path] = project_info
      M._active = project_info

      -- Set up file watchers
      watcher.setup(project_info)

      -- Start remote watcher for 2-way sync
      local remote_watcher = require("nvim-client-render.remote_watcher")
      local watcher_ok, watcher_err = pcall(remote_watcher.start, project_info)
      if not watcher_ok then
        vim.notify("[nvim-client-render] Remote watcher: " .. tostring(watcher_err), vim.log.levels.WARN)
      end

      -- Auto-detect and setup git integration (non-blocking, non-fatal)
      local git = require("nvim-client-render.git")
      git.setup(project_info, function(git_err)
        if git_err then
          vim.notify("[nvim-client-render] Git: " .. git_err, vim.log.levels.DEBUG)
        end
      end)

      -- Auto cd into local mirror
      if config.values.project.auto_cd then
        vim.cmd("cd " .. vim.fn.fnameescape(project_info.local_path))
      end

      vim.notify(
        "[nvim-client-render] Project ready: " .. project_info.name .. " (" .. project_info.local_path .. ")",
        vim.log.levels.INFO
      )

      callback(nil)
    end)
  end)
end

---Close a specific session or the active one
---@param local_path string|nil  session key to close, or nil for active
---@param callback fun(err: string|nil)|nil
function M.close(local_path, callback)
  -- Support old signature: close(callback)
  if type(local_path) == "function" then
    callback = local_path
    local_path = nil
  end
  callback = callback or function() end

  local session = nil
  if local_path then
    session = M._sessions[local_path]
  else
    session = M._active
  end

  if not session then
    callback(nil)
    return
  end

  local session_key = session.local_path

  -- Flush sync queue first
  sync.flush(function()
    -- Teardown git integration for this session
    pcall(function() require("nvim-client-render.git").teardown(session_key) end)

    -- Stop remote watcher for this session
    local remote_watcher = require("nvim-client-render.remote_watcher")
    remote_watcher.stop(session_key)

    -- Stop terminals and LSP (these remain global for now)
    if vim.tbl_count(M._sessions) <= 1 then
      local terminal = require("nvim-client-render.terminal")
      terminal.close_all()

      local lsp_mod = require("nvim-client-render.lsp")
      lsp_mod.stop_all()
    end

    watcher.teardown(session_key)
    M._sessions[session_key] = nil

    -- Update _active
    if M._active and M._active.local_path == session_key then
      -- Pick another session or nil
      M._active = nil
      for _, s in pairs(M._sessions) do
        M._active = s
        break
      end
    end

    callback(nil)
  end)
end

---Find the session whose local_path prefixes the given path
---@param path string
---@return ProjectInfo|nil
function M.get_for_path(path)
  local norm = vim.fn.fnamemodify(path, ":p"):gsub("/$", "")
  for base, session in pairs(M._sessions) do
    local norm_base = vim.fn.fnamemodify(base, ":p"):gsub("/$", "")
    if norm:sub(1, #norm_base) == norm_base and (#norm == #norm_base or norm:sub(#norm_base + 1, #norm_base + 1) == "/") then
      return session
    end
  end
  return nil
end

---Map a local path to its corresponding remote path
---@param local_path string
---@return string|nil
function M.local_to_remote(local_path)
  local norm_local = vim.fn.fnamemodify(local_path, ":p"):gsub("/$", "")

  -- Try to find matching session
  for _, session in pairs(M._sessions) do
    local norm_base = vim.fn.fnamemodify(session.local_path, ":p"):gsub("/$", "")
    if norm_local:sub(1, #norm_base) == norm_base then
      local relative = norm_local:sub(#norm_base + 1)
      return session.remote_path .. relative
    end
  end

  return nil
end

---Map a remote path to its corresponding local path
---@param remote_path string
---@return string|nil
function M.remote_to_local(remote_path)
  for _, session in pairs(M._sessions) do
    if remote_path:sub(1, #session.remote_path) == session.remote_path then
      local relative = remote_path:sub(#session.remote_path + 1)
      return session.local_path .. relative
    end
  end

  return nil
end

---Check if a file path is within any active project
---@param filepath string
---@return boolean
function M.is_project_file(filepath)
  return M.get_for_path(filepath) ~= nil
end

---Get the active project info
---@return ProjectInfo|nil
function M.get_active()
  return M._active
end

---Get all active sessions
---@return table<string, ProjectInfo>
function M.get_all()
  return M._sessions
end

---Get the session matching the current context (buffer path, then CWD, then active)
---@return ProjectInfo|nil
function M.get_for_context()
  local session = M.get_for_path(vim.api.nvim_buf_get_name(0))
  if not session then
    session = M.get_for_path(vim.fn.getcwd())
  end
  return session or M._active
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
