local config = require("nvim-client-render.config")
local transfer = require("nvim-client-render.transfer")

local M = {}

---@class SyncItem
---@field bufnr number
---@field local_path string
---@field remote_path string
---@field host string
---@field retries number
---@field state "pending"|"in_progress"|"retry_pending"|"failed"

---@type SyncItem[]
M._queue = {}

---@type table<number, userdata> -- bufnr -> uv_timer_t
M._timers = {}

M._uploading = false

-- Lazy reference to watcher (set after require to avoid circular dep)
local _watcher = nil
local function get_watcher()
  if not _watcher then
    _watcher = require("nvim-client-render.watcher")
  end
  return _watcher
end

---Find an existing queue entry for a local path
---@param local_path string
---@return number|nil index
local function find_in_queue(local_path)
  for i, item in ipairs(M._queue) do
    if item.local_path == local_path then
      return i
    end
  end
  return nil
end

---Process the next item in the queue
function M._process_queue()
  if M._uploading then
    return
  end

  -- Find next pending item
  local idx = nil
  for i, item in ipairs(M._queue) do
    if item.state == "pending" then
      idx = i
      break
    end
  end

  if not idx then
    return
  end

  local item = M._queue[idx]
  item.state = "in_progress"
  M._uploading = true

  local watcher = get_watcher()
  if vim.api.nvim_buf_is_valid(item.bufnr) then
    watcher.set_sync_state(item.bufnr, "uploading")
  end

  -- Suppress remote watcher to prevent upload->inotifywait->download loop
  local ok, remote_watcher = pcall(require, "nvim-client-render.remote_watcher")
  if ok then
    remote_watcher.suppress(item.remote_path)
  end

  transfer.upload_file(item.host, item.local_path, item.remote_path, function(err)
    M._uploading = false

    if not err then
      -- Success: remove from queue
      local remove_idx = find_in_queue(item.local_path)
      if remove_idx then
        table.remove(M._queue, remove_idx)
      end
      if vim.api.nvim_buf_is_valid(item.bufnr) then
        watcher.set_sync_state(item.bufnr, "synced")
      end
    else
      -- Failure: retry or fail
      local cfg = config.values.sync
      item.retries = item.retries + 1

      if item.retries <= cfg.max_retries then
        item.state = "retry_pending"
        if vim.api.nvim_buf_is_valid(item.bufnr) then
          watcher.set_sync_state(item.bufnr, "retry_pending")
        end

        local timer = vim.uv.new_timer()
        timer:start(cfg.retry_interval_ms, 0, function()
          timer:close()
          vim.schedule(function()
            item.state = "pending"
            M._process_queue()
          end)
        end)
      else
        item.state = "failed"
        if vim.api.nvim_buf_is_valid(item.bufnr) then
          watcher.set_sync_state(item.bufnr, "failed")
        end
        vim.notify(
          "[nvim-client-render] Upload failed after " .. cfg.max_retries .. " retries: " .. item.local_path,
          vim.log.levels.ERROR
        )
      end
    end

    -- Continue processing queue
    M._process_queue()
  end)
end

---Enqueue a file for upload with debounce
---@param bufnr number
---@param local_path string
---@param remote_path string
---@param host string
function M.enqueue(bufnr, local_path, remote_path, host)
  local cfg = config.values.sync

  -- Cancel existing debounce timer for this buffer
  if M._timers[bufnr] then
    M._timers[bufnr]:stop()
    M._timers[bufnr]:close()
    M._timers[bufnr] = nil
  end

  local timer = vim.uv.new_timer()
  M._timers[bufnr] = timer

  timer:start(cfg.debounce_ms, 0, function()
    timer:close()
    M._timers[bufnr] = nil

    vim.schedule(function()
      -- Coalesce: if same path already pending, replace it
      local existing = find_in_queue(local_path)
      if existing then
        local item = M._queue[existing]
        if item.state == "pending" or item.state == "retry_pending" then
          item.bufnr = bufnr
          item.retries = 0
          item.state = "pending"
          M._process_queue()
          return
        end
      end

      table.insert(M._queue, {
        bufnr = bufnr,
        local_path = local_path,
        remote_path = remote_path,
        host = host,
        retries = 0,
        state = "pending",
      })
      M._process_queue()
    end)
  end)
end

---Flush the queue: cancel all debounce timers and process everything immediately
---@param callback fun()|nil
function M.flush(callback)
  -- Fire all pending debounce timers immediately
  for bufnr, timer in pairs(M._timers) do
    timer:stop()
    timer:close()
    M._timers[bufnr] = nil
  end

  -- If nothing in queue, done
  if #M._queue == 0 then
    if callback then
      callback()
    end
    return
  end

  -- Set all retry_pending to pending
  for _, item in ipairs(M._queue) do
    if item.state == "retry_pending" then
      item.state = "pending"
    end
  end

  -- Process with a completion check
  if callback then
    -- Poll until queue is drained (with timeout)
    local check_timer = vim.uv.new_timer()
    local elapsed = 0
    local interval = 100
    local timeout = 30000

    check_timer:start(interval, interval, function()
      elapsed = elapsed + interval
      vim.schedule(function()
        local has_active = false
        for _, item in ipairs(M._queue) do
          if item.state ~= "failed" then
            has_active = true
            break
          end
        end
        if not has_active or #M._queue == 0 or elapsed >= timeout then
          check_timer:stop()
          check_timer:close()
          callback()
        end
      end)
    end)
  end

  M._process_queue()
end

---Get current sync status
---@return { pending: number, uploading: number, failed: number, items: SyncItem[] }
function M.get_status()
  local counts = { pending = 0, in_progress = 0, failed = 0, retry_pending = 0 }
  for _, item in ipairs(M._queue) do
    counts[item.state] = counts[item.state] + 1
  end
  return {
    pending = counts.pending + counts.retry_pending,
    uploading = counts.in_progress,
    failed = counts.failed,
    items = M._queue,
  }
end

---Retry all failed items
function M.retry_failed()
  for _, item in ipairs(M._queue) do
    if item.state == "failed" then
      item.state = "pending"
      item.retries = 0
    end
  end
  M._process_queue()
end

return M
