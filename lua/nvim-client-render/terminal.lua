local config = require("nvim-client-render.config")
local ssh = require("nvim-client-render.ssh")

local M = {}

---@class TerminalEntry
---@field bufnr number
---@field job_id number
---@field host string

---@type TerminalEntry[]
M._terminals = {}

---Open a remote terminal
---@param opts? { split?: "horizontal"|"vertical"|"float", host?: string }
function M.open(opts)
  opts = opts or {}

  -- Reuse existing terminal if one is already open
  for _, entry in ipairs(M._terminals) do
    if vim.api.nvim_buf_is_valid(entry.bufnr) then
      local win = vim.fn.bufwinid(entry.bufnr)
      if win ~= -1 then
        vim.api.nvim_set_current_win(win)
      else
        vim.cmd("botright vnew | buffer " .. entry.bufnr)
      end
      vim.cmd("startinsert")
      return
    end
  end

  local project = require("nvim-client-render.project")
  local active = project.get_active()

  local host = opts.host or (active and active.host)
  if not host then
    vim.notify("[nvim-client-render] No host specified and no active project", vim.log.levels.ERROR)
    return
  end

  local ssh_args, parsed = ssh.get_ssh_args(host)
  if not ssh_args or not parsed then
    vim.notify("[nvim-client-render] Not connected to " .. host, vim.log.levels.ERROR)
    return
  end

  local dest = parsed.user and (parsed.user .. "@" .. parsed.host) or parsed.host

  local cmd = { "ssh" }
  vim.list_extend(cmd, ssh_args)
  table.insert(cmd, "-t")
  table.insert(cmd, dest)
  table.insert(cmd, "--")

  if config.values.terminal.auto_cd and active then
    table.insert(cmd, "cd " .. vim.fn.shellescape(active.remote_path) .. " && exec $SHELL -l")
  else
    table.insert(cmd, "exec $SHELL -l")
  end

  local split = opts.split or config.values.terminal.default_split
  local cfg = config.values.terminal

  if split == "float" then
    local width = math.floor(vim.o.columns * cfg.float_width)
    local height = math.floor(vim.o.lines * cfg.float_height)
    local row = math.floor((vim.o.lines - height) / 2)
    local col = math.floor((vim.o.columns - width) / 2)

    local buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_open_win(buf, true, {
      relative = "editor",
      width = width,
      height = height,
      row = row,
      col = col,
      style = "minimal",
      border = "rounded",
    })
  elseif split == "vertical" then
    vim.cmd("botright vnew")
  else
    vim.cmd("botright new")
  end

  local job_id = vim.fn.termopen(cmd)
  local bufnr = vim.api.nvim_get_current_buf()
  vim.bo[bufnr].buflisted = false

  table.insert(M._terminals, {
    bufnr = bufnr,
    job_id = job_id,
    host = host,
  })

  -- Clean up on buffer delete
  vim.api.nvim_create_autocmd("BufDelete", {
    buffer = bufnr,
    once = true,
    callback = function()
      for i, entry in ipairs(M._terminals) do
        if entry.bufnr == bufnr then
          table.remove(M._terminals, i)
          break
        end
      end
    end,
  })

  vim.cmd("startinsert")
end

---Close all remote terminals
function M.close_all()
  for _, entry in ipairs(M._terminals) do
    if vim.api.nvim_buf_is_valid(entry.bufnr) then
      pcall(vim.fn.jobstop, entry.job_id)
      pcall(vim.api.nvim_buf_delete, entry.bufnr, { force = true })
    end
  end
  M._terminals = {}
end

return M
