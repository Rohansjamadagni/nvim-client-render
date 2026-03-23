local config = require("nvim-client-render.config")
local ssh = require("nvim-client-render.ssh")
local transfer = require("nvim-client-render.transfer")

local M = {}

---@class WatcherState
---@field job_id number|nil
---@field project_info ProjectInfo
---@field suppressed table<string, number>
---@field download_timers table<string, userdata>
---@field reconnect_attempts number
---@field event_count number
---@field event_window_start number
---@field gc_timer userdata|nil

---@type table<string, WatcherState>
M._watchers = {}

---Suppress a remote path from triggering a download (loop prevention)
---@param remote_path string
function M.suppress(remote_path)
  local project = require("nvim-client-render.project")
  for _, w in pairs(M._watchers) do
    if remote_path:sub(1, #w.project_info.remote_path) == w.project_info.remote_path then
      w.suppressed[remote_path] = vim.uv.now()
      return
    end
  end
  -- Fallback: suppress in all watchers
  for _, w in pairs(M._watchers) do
    w.suppressed[remote_path] = vim.uv.now()
  end
end

---Build exclude regex from config exclude list (for inotifywait --exclude)
---@param excludes string[]
---@return string
local function build_exclude_regex(excludes)
  local parts = {}
  for _, pat in ipairs(excludes) do
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

---Handle a parsed event for a specific watcher
---@param w WatcherState
---@param remote_path string
---@param event_type string
local function handle_event(w, remote_path, event_type)
  -- Loop prevention: check suppressed (TTL-based)
  local suppress_ts = w.suppressed[remote_path]
  if suppress_ts then
    local ttl = config.values.remote_watcher.suppress_ttl_ms
    if vim.uv.now() - suppress_ts < ttl then
      return
    end
    w.suppressed[remote_path] = nil
  end

  local project = require("nvim-client-render.project")
  local local_path = project.remote_to_local(remote_path)
  if not local_path then
    return
  end

  -- Event storm detection
  local now = vim.uv.now()
  if now - w.event_window_start > 2000 then
    w.event_count = 0
    w.event_window_start = now
  end
  w.event_count = w.event_count + 1

  if w.event_count > 50 then
    for path, timer in pairs(w.download_timers) do
      timer:stop()
      timer:close()
      w.download_timers[path] = nil
    end
    w.event_count = 0
    vim.notify("[nvim-client-render] Event storm detected, running full sync...", vim.log.levels.INFO)
    transfer.sync_folder(w.project_info.host, w.project_info.remote_path, w.project_info.local_path, function(err)
      if err then
        vim.notify("[nvim-client-render] Full sync failed: " .. err, vim.log.levels.ERROR)
      else
        vim.cmd("checktime")
      end
    end)
    return
  end

  -- Debounce per remote_path
  if w.download_timers[remote_path] then
    w.download_timers[remote_path]:stop()
    w.download_timers[remote_path]:close()
    w.download_timers[remote_path] = nil
  end

  local debounce_ms = config.values.remote_watcher.debounce_ms
  local timer = vim.uv.new_timer()
  w.download_timers[remote_path] = timer

  timer:start(debounce_ms, 0, function()
    timer:close()
    w.download_timers[remote_path] = nil

    vim.schedule(function()
      if event_type == "DELETE" or event_type == "MOVED_FROM" then
        vim.fn.delete(local_path)
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
          end
        end
      end

      local parent = vim.fn.fnamemodify(local_path, ":h")
      vim.fn.mkdir(parent, "p")

      transfer.download_file(w.project_info.host, remote_path, local_path, function(err)
        if err then
          vim.notify("[nvim-client-render] Download failed: " .. err, vim.log.levels.ERROR)
          return
        end
        vim.cmd("checktime")

        local ok, lsp_mod = pcall(require, "nvim-client-render.lsp")
        if ok and lsp_mod.notify_file_changed then
          lsp_mod.notify_file_changed(remote_path)
        end
      end)
    end)
  end)
end

---Create on_line handler for a specific watcher
---@param w WatcherState
---@return fun(line: string)
local function make_on_line(w)
  return function(line)
    if line == "" then
      return
    end

    local event, path = line:match("^(%S+)%s+(.+)$")
    if event and path then
      local event_type = "MODIFY"
      if event:find("DELETE") then
        event_type = "DELETE"
      elseif event:find("CREATE") or event:find("MOVED_TO") then
        event_type = "CREATE"
      elseif event:find("MOVED_FROM") then
        event_type = "MOVED_FROM"
      end
      handle_event(w, path, event_type)
    else
      handle_event(w, line, "MODIFY")
    end
  end
end

---Create on_exit handler for a specific watcher
---@param w WatcherState
---@param key string
---@return fun(code: number, stderr: string[])
local function make_on_exit(w, key)
  return function(code, stderr)
    w.job_id = nil

    -- Normal shutdown (we stopped it)
    if not M._watchers[key] then
      return
    end

    local max_attempts = 5
    if w.reconnect_attempts >= max_attempts then
      vim.notify(
        "[nvim-client-render] Remote watcher failed after " .. max_attempts .. " reconnect attempts",
        vim.log.levels.ERROR
      )
      return
    end

    w.reconnect_attempts = w.reconnect_attempts + 1
    local delay = math.min(2000 * (2 ^ (w.reconnect_attempts - 1)), 30000)

    vim.notify(
      "[nvim-client-render] Remote watcher disconnected, reconnecting in " .. (delay / 1000) .. "s... (attempt " .. w.reconnect_attempts .. "/" .. max_attempts .. ")",
      vim.log.levels.WARN
    )

    local reconnect_timer = vim.uv.new_timer()
    reconnect_timer:start(delay, 0, function()
      reconnect_timer:close()
      vim.schedule(function()
        if M._watchers[key] then
          M.start(w.project_info)
        end
      end)
    end)
  end
end

---Start watching remote filesystem for changes
---@param project_info ProjectInfo
function M.start(project_info)
  if not config.values.remote_watcher.enabled then
    return
  end

  local key = project_info.local_path

  -- Stop existing watcher for this session if any
  if M._watchers[key] then
    M.stop(key)
  end

  local w = {
    job_id = nil,
    project_info = project_info,
    suppressed = {},
    download_timers = {},
    reconnect_attempts = 0,
    event_count = 0,
    event_window_start = 0,
    gc_timer = nil,
  }
  M._watchers[key] = w

  local excludes = config.values.transfer.exclude or {}
  local cmd = build_watch_cmd(project_info.remote_path, excludes)

  w.job_id = ssh.exec_streaming(project_info.host, cmd, make_on_line(w), make_on_exit(w, key))

  if w.job_id then
    local ttl = config.values.remote_watcher.suppress_ttl_ms
    w.gc_timer = vim.uv.new_timer()
    w.gc_timer:start(ttl, ttl, function()
      vim.schedule(function()
        local now = vim.uv.now()
        for path, ts in pairs(w.suppressed) do
          if now - ts > ttl then
            w.suppressed[path] = nil
          end
        end
      end)
    end)
  end
end

---Stop a specific watcher or all watchers
---@param local_path string|nil  session key, or nil to stop all
function M.stop(local_path)
  if local_path then
    local w = M._watchers[local_path]
    if w then
      M._stop_watcher(w)
      M._watchers[local_path] = nil
    end
  else
    for key, w in pairs(M._watchers) do
      M._stop_watcher(w)
    end
    M._watchers = {}
  end
end

---Internal: stop a single watcher state
---@param w WatcherState
function M._stop_watcher(w)
  if w.job_id then
    pcall(vim.fn.jobstop, w.job_id)
    w.job_id = nil
  end

  if w.gc_timer then
    w.gc_timer:stop()
    w.gc_timer:close()
    w.gc_timer = nil
  end

  for _, timer in pairs(w.download_timers) do
    timer:stop()
    timer:close()
  end
  w.download_timers = {}
  w.suppressed = {}
  w.event_count = 0
  w.reconnect_attempts = 0
end

---Check if a watcher is running
---@param local_path string|nil  session key, or nil to check if any are running
---@return boolean
function M.is_running(local_path)
  if local_path then
    local w = M._watchers[local_path]
    return w ~= nil and w.job_id ~= nil
  end
  for _, w in pairs(M._watchers) do
    if w.job_id ~= nil then
      return true
    end
  end
  return false
end

return M
