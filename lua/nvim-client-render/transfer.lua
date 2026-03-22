local config = require("nvim-client-render.config")
local ssh = require("nvim-client-render.ssh")

local M = {}

-- Cache for rsync availability per host
M._rsync_cache = {}

---Build the rsync -e flag from SSH args
---@param ssh_args string[]
---@return string
local function build_rsh(ssh_args)
  local parts = { "ssh" }
  for _, arg in ipairs(ssh_args) do
    -- Quote args that contain spaces
    if arg:find(" ") then
      table.insert(parts, '"' .. arg .. '"')
    else
      table.insert(parts, arg)
    end
  end
  return table.concat(parts, " ")
end

---Build the ssh destination prefix (user@host: or host:)
---@param parsed SSHHost
---@return string
local function dest_prefix(parsed)
  if parsed.user then
    return parsed.user .. "@" .. parsed.host .. ":"
  end
  return parsed.host .. ":"
end

---Sync an entire folder from remote to local
---@param host string
---@param remote_path string
---@param local_path string
---@param callback fun(err: string|nil)
function M.sync_folder(host, remote_path, local_path, callback)
  local ssh_args, parsed = ssh.get_ssh_args(host)
  if not ssh_args or not parsed then
    vim.schedule(function() callback("Not connected to " .. host) end)
    return
  end

  local cfg = config.values.transfer

  -- Ensure local path ends with /
  if not local_path:match("/$") then
    local_path = local_path .. "/"
  end
  -- Ensure remote path ends with / (sync contents, not dir itself)
  if not remote_path:match("/$") then
    remote_path = remote_path .. "/"
  end

  vim.fn.mkdir(local_path, "p")

  local args = { "rsync" }
  vim.list_extend(args, cfg.rsync_flags)
  table.insert(args, "--info=progress2")

  for _, pattern in ipairs(cfg.exclude) do
    table.insert(args, "--exclude=" .. pattern)
  end

  table.insert(args, "-e")
  table.insert(args, build_rsh(ssh_args))
  table.insert(args, dest_prefix(parsed) .. remote_path)
  table.insert(args, local_path)

  local stderr_chunks = {}
  local last_progress = ""

  vim.fn.jobstart(args, {
    on_stdout = function(_, data)
      for _, line in ipairs(data) do
        if line ~= "" then
          last_progress = line
        end
      end
    end,
    on_stderr = function(_, data)
      for _, line in ipairs(data) do
        if line ~= "" then
          table.insert(stderr_chunks, line)
        end
      end
    end,
    on_exit = function(_, code)
      vim.schedule(function()
        if code == 0 then
          callback(nil)
        else
          callback("rsync folder sync failed (exit " .. code .. "): " .. table.concat(stderr_chunks, "\n"))
        end
      end)
    end,
  })
end

---Upload a single file to remote
---@param host string
---@param local_file string
---@param remote_file string
---@param callback fun(err: string|nil)
function M.upload_file(host, local_file, remote_file, callback)
  local ssh_args, parsed = ssh.get_ssh_args(host)
  if not ssh_args or not parsed then
    vim.schedule(function() callback("Not connected to " .. host) end)
    return
  end

  local cfg = config.values.transfer
  local args = { "rsync" }
  vim.list_extend(args, cfg.rsync_flags)
  table.insert(args, "-e")
  table.insert(args, build_rsh(ssh_args))
  table.insert(args, local_file)
  table.insert(args, dest_prefix(parsed) .. remote_file)

  local stderr_chunks = {}

  vim.fn.jobstart(args, {
    on_stderr = function(_, data)
      for _, line in ipairs(data) do
        if line ~= "" then
          table.insert(stderr_chunks, line)
        end
      end
    end,
    on_exit = function(_, code)
      vim.schedule(function()
        if code == 0 then
          callback(nil)
        else
          callback("rsync upload failed (exit " .. code .. "): " .. table.concat(stderr_chunks, "\n"))
        end
      end)
    end,
  })
end

---Download a single file from remote
---@param host string
---@param remote_file string
---@param local_file string
---@param callback fun(err: string|nil)
function M.download_file(host, remote_file, local_file, callback)
  local ssh_args, parsed = ssh.get_ssh_args(host)
  if not ssh_args or not parsed then
    vim.schedule(function() callback("Not connected to " .. host) end)
    return
  end

  local cfg = config.values.transfer
  local args = { "rsync" }
  vim.list_extend(args, cfg.rsync_flags)
  table.insert(args, "-e")
  table.insert(args, build_rsh(ssh_args))
  table.insert(args, dest_prefix(parsed) .. remote_file)
  table.insert(args, local_file)

  local stderr_chunks = {}

  vim.fn.jobstart(args, {
    on_stderr = function(_, data)
      for _, line in ipairs(data) do
        if line ~= "" then
          table.insert(stderr_chunks, line)
        end
      end
    end,
    on_exit = function(_, code)
      vim.schedule(function()
        if code == 0 then
          callback(nil)
        else
          callback("rsync download failed (exit " .. code .. "): " .. table.concat(stderr_chunks, "\n"))
        end
      end)
    end,
  })
end

---Check if rsync is available on the remote host (cached)
---@param host string
---@param callback fun(available: boolean)
function M.check_rsync(host, callback)
  if M._rsync_cache[host] ~= nil then
    vim.schedule(function() callback(M._rsync_cache[host]) end)
    return
  end

  ssh.exec(host, "which rsync", function(code)
    M._rsync_cache[host] = (code == 0)
    callback(code == 0)
  end)
end

---Dry run to detect remote changes
---@param host string
---@param remote_path string
---@param local_path string
---@param callback fun(err: string|nil, changed_files: string[])
function M.dry_run(host, remote_path, local_path, callback)
  local ssh_args, parsed = ssh.get_ssh_args(host)
  if not ssh_args or not parsed then
    vim.schedule(function() callback("Not connected to " .. host, {}) end)
    return
  end

  local cfg = config.values.transfer

  if not remote_path:match("/$") then
    remote_path = remote_path .. "/"
  end
  if not local_path:match("/$") then
    local_path = local_path .. "/"
  end

  local args = { "rsync", "--dry-run", "--itemize-changes" }
  vim.list_extend(args, cfg.rsync_flags)

  for _, pattern in ipairs(cfg.exclude) do
    table.insert(args, "--exclude=" .. pattern)
  end

  table.insert(args, "-e")
  table.insert(args, build_rsh(ssh_args))
  table.insert(args, dest_prefix(parsed) .. remote_path)
  table.insert(args, local_path)

  local stdout_lines = {}
  local stderr_chunks = {}

  vim.fn.jobstart(args, {
    on_stdout = function(_, data)
      for _, line in ipairs(data) do
        if line ~= "" then
          table.insert(stdout_lines, line)
        end
      end
    end,
    on_stderr = function(_, data)
      for _, line in ipairs(data) do
        if line ~= "" then
          table.insert(stderr_chunks, line)
        end
      end
    end,
    on_exit = function(_, code)
      vim.schedule(function()
        if code == 0 then
          -- Parse itemized output: lines like ">f..t...... path/to/file"
          local changed = {}
          for _, line in ipairs(stdout_lines) do
            local file = line:match("^[<>ch.][fd.][cstpoguax.]+%s+(.+)$")
            if file then
              table.insert(changed, file)
            end
          end
          callback(nil, changed)
        else
          callback("rsync dry-run failed (exit " .. code .. "): " .. table.concat(stderr_chunks, "\n"), {})
        end
      end)
    end,
  })
end

return M
