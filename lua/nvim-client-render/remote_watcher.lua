local config = require("nvim-client-render.config")
local ssh = require("nvim-client-render.ssh")
local transfer = require("nvim-client-render.transfer")

local M = {}

M._job_id = nil
M._suppressed = {} ---@type table<string, number> remote_path -> timestamp
M._download_timers = {} ---@type table<string, userdata> remote_path -> uv_timer
M._reconnect_attempts = 0
M._project_info = nil ---@type table|nil
M._event_count = 0
M._event_window_start = 0
M._gc_timer = nil

---Suppress a remote path from triggering a download (loop prevention)
---@param remote_path string
function M.suppress(remote_path)
  M._suppressed[remote_path] = vim.uv.now()
end

---Build exclude regex from config exclude list (for inotifywait --exclude)
---@param excludes string[]
---@return string
local function build_exclude_regex(excludes)
  local parts = {}
  for _, pat in ipairs(excludes) do
    -- Escape dots for regex; parenthesize gsub to discard count return value
    local escaped = pat:gsub("%.", "\\.")
    table.insert(parts, escaped)
  end
  return "(" .. table.concat(parts, "|") .. ")"
end

---Build the remote watcher command
---@param remote_path string
---@param excludes string[]
---@return string
local function build_watch_cmd(remote_path, excludes)
  local exclude_regex = build_exclude_regex(excludes)
  local escaped_path = vim.fn.shellescape(remote_path)

  local inotifywait_cmd = string.format(
    "stdbuf -oL inotifywait -m -r -e modify,create,delete,move --exclude '%s' --format '%%e %%w%%f' %s",
    exclude_regex,
    escaped_path
  )

  local fswatch_cmd = string.format(
    "fswatch -r --exclude '%s' %s",
    exclude_regex,
    escaped_path
  )

  return string.format(
    "command -v inotifywait >/dev/null 2>&1 && %s || %s",
    inotifywait_cmd,
    fswatch_cmd
  )
end

---Handle a parsed event
---@param remote_path string
---@param event_type string "MODIFY"|"CREATE"|"DELETE"|"MOVED_TO"|"MOVED_FROM"|"unknown"
local function handle_event(remote_path, event_type)
  if not M._project_info then
    return
  end

  -- Loop prevention: check suppressed
  if M._suppressed[remote_path] then
    M._suppressed[remote_path] = nil
    return
  end

  local project = require("nvim-client-render.project")
  local local_path = project.remote_to_local(remote_path)
  if not local_path then
    return
  end

  -- Event storm detection
  local now = vim.uv.now()
  if now - M._event_window_start > 2000 then
    M._event_count = 0
    M._event_window_start = now
  end
  M._event_count = M._event_count + 1

  if M._event_count > 50 then
    -- Cancel all individual download timers
    for path, timer in pairs(M._download_timers) do
      timer:stop()
      timer:close()
      M._download_timers[path] = nil
    end
    M._event_count = 0
    -- Trigger full sync instead
    vim.notify("[nvim-client-render] Event storm detected, running full sync...", vim.log.levels.INFO)
    transfer.sync_folder(M._project_info.host, M._project_info.remote_path, M._project_info.local_path, function(err)
      if err then
        vim.notify("[nvim-client-render] Full sync failed: " .. err, vim.log.levels.ERROR)
      else
        vim.cmd("checktime")
      end
    end)
    return
  end

  -- Debounce per remote_path
  if M._download_timers[remote_path] then
    M._download_timers[remote_path]:stop()
    M._download_timers[remote_path]:close()
    M._download_timers[remote_path] = nil
  end

  local debounce_ms = config.values.remote_watcher.debounce_ms
  local timer = vim.uv.new_timer()
  M._download_timers[remote_path] = timer

  timer:start(debounce_ms, 0, function()
    timer:close()
    M._download_timers[remote_path] = nil

    vim.schedule(function()
      if event_type == "DELETE" or event_type == "MOVED_FROM" then
        vim.fn.delete(local_path)
        -- Wipe buffer if open
        for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
          if vim.api.nvim_buf_is_valid(bufnr) then
            local buf_name = vim.api.nvim_buf_get_name(bufnr)
            if buf_name == local_path then
              vim.api.nvim_buf_delete(bufnr, { force = true })
              break
            end
          end
        end
        return
      end

      -- For MODIFY, CREATE, MOVED_TO: download the file
      -- Conflict check for modified buffers
      local strategy = config.values.remote_watcher.conflict_strategy
      for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
        if vim.api.nvim_buf_is_valid(bufnr) then
          local buf_name = vim.api.nvim_buf_get_name(bufnr)
          if buf_name == local_path and vim.bo[bufnr].modified then
            if strategy == "warn" then
              vim.notify(
                "[nvim-client-render] Conflict: " .. vim.fn.fnamemodify(local_path, ":t") .. " changed remotely but has local modifications",
                vim.log.levels.WARN
              )
              return
            elseif strategy == "local_wins" then
              return
            end
            -- "remote_wins" falls through to download
          end
        end
      end

      -- Ensure parent directory exists for new files
      local parent = vim.fn.fnamemodify(local_path, ":h")
      vim.fn.mkdir(parent, "p")

      transfer.download_file(M._project_info.host, remote_path, local_path, function(err)
        if err then
          vim.notify("[nvim-client-render] Download failed: " .. err, vim.log.levels.ERROR)
          return
        end
        vim.cmd("checktime")

        -- Notify LSP about the change
        local ok, lsp_mod = pcall(require, "nvim-client-render.lsp")
        if ok and lsp_mod.notify_file_changed then
          lsp_mod.notify_file_changed(remote_path)
        end
      end)
    end)
  end)
end

---Parse an event line from inotifywait or fswatch
---@param line string
function M._on_line(line)
  if line == "" then
    return
  end

  -- Try inotifywait format: "EVENT /path/to/file"
  local event, path = line:match("^(%S+)%s+(.+)$")
  if event and path then
    -- Normalize event type (inotifywait can emit comma-separated events like "CREATE,ISDIR")
    local event_type = "MODIFY"
    if event:find("DELETE") then
      event_type = "DELETE"
    elseif event:find("CREATE") or event:find("MOVED_TO") then
      event_type = "CREATE"
    elseif event:find("MOVED_FROM") then
      event_type = "MOVED_FROM"
    end
    handle_event(path, event_type)
  else
    -- fswatch format: just the path
    handle_event(line, "MODIFY")
  end
end

---Handle watcher process exit with auto-reconnect
---@param code number
---@param stderr string[]
function M._on_exit(code, stderr)
  M._job_id = nil

  -- Normal shutdown (we stopped it)
  if not M._project_info then
    return
  end

  local max_attempts = 5
  if M._reconnect_attempts >= max_attempts then
    vim.notify(
      "[nvim-client-render] Remote watcher failed after " .. max_attempts .. " reconnect attempts",
      vim.log.levels.ERROR
    )
    return
  end

  M._reconnect_attempts = M._reconnect_attempts + 1
  local delay = math.min(2000 * (2 ^ (M._reconnect_attempts - 1)), 30000)

  vim.notify(
    "[nvim-client-render] Remote watcher disconnected, reconnecting in " .. (delay / 1000) .. "s... (attempt " .. M._reconnect_attempts .. "/" .. max_attempts .. ")",
    vim.log.levels.WARN
  )

  local timer = vim.uv.new_timer()
  timer:start(delay, 0, function()
    timer:close()
    vim.schedule(function()
      if M._project_info then
        M.start(M._project_info)
      end
    end)
  end)
end

---Start watching remote filesystem for changes
---@param project_info { host: string, remote_path: string, local_path: string, name: string }
function M.start(project_info)
  if not config.values.remote_watcher.enabled then
    return
  end

  M.stop()

  M._project_info = project_info
  M._reconnect_attempts = 0

  local excludes = config.values.transfer.exclude or {}
  local cmd = build_watch_cmd(project_info.remote_path, excludes)

  M._job_id = ssh.exec_streaming(project_info.host, cmd, M._on_line, M._on_exit)

  if M._job_id then
    -- Start GC timer for stale suppressed entries
    M._gc_timer = vim.uv.new_timer()
    local ttl = config.values.remote_watcher.suppress_ttl_ms
    M._gc_timer:start(ttl, ttl, function()
      vim.schedule(function()
        local now = vim.uv.now()
        for path, ts in pairs(M._suppressed) do
          if now - ts > ttl then
            M._suppressed[path] = nil
          end
        end
      end)
    end)
  end
end

---Stop watching remote filesystem
function M.stop()
  M._project_info = nil

  if M._job_id then
    pcall(vim.fn.jobstop, M._job_id)
    M._job_id = nil
  end

  if M._gc_timer then
    M._gc_timer:stop()
    M._gc_timer:close()
    M._gc_timer = nil
  end

  for path, timer in pairs(M._download_timers) do
    timer:stop()
    timer:close()
  end
  M._download_timers = {}
  M._suppressed = {}
  M._event_count = 0
  M._reconnect_attempts = 0
end

---Check if the remote watcher is currently running
---@return boolean
function M.is_running()
  return M._job_id ~= nil
end

return M
