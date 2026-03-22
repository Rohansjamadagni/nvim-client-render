local config = require("nvim-client-render.config")

local M = {}

---@class SSHHost
---@field user string|nil
---@field host string
---@field port string|nil
---@field raw string

---@class SSHConnection
---@field host_id string
---@field parsed SSHHost
---@field socket string

M._connections = {}

---Parse a host string like "user@host:port", "user@host", "host:port", or "host"
---@param host_string string
---@return SSHHost
function M.parse_host(host_string)
  local parsed = { raw = host_string }

  local rest = host_string
  local at_pos = rest:find("@")
  if at_pos then
    parsed.user = rest:sub(1, at_pos - 1)
    rest = rest:sub(at_pos + 1)
  end

  -- Check for port: only match trailing :digits
  local colon_pos = rest:find(":(%d+)$")
  if colon_pos then
    parsed.port = rest:sub(colon_pos + 1)
    parsed.host = rest:sub(1, colon_pos - 1)
  else
    parsed.host = rest
  end

  return parsed
end

---Compute a host_id string for keying connections
---@param parsed SSHHost
---@return string
local function host_id(parsed)
  local id = ""
  if parsed.user then
    id = parsed.user .. "@"
  end
  id = id .. parsed.host
  if parsed.port then
    id = id .. ":" .. parsed.port
  end
  return id
end

---Get the socket path for a host
---@param hid string
---@return string
local function socket_path(hid)
  local cfg = config.values.ssh
  -- Use a simple hash to avoid filesystem issues with special chars
  local hash = vim.fn.sha256(hid):sub(1, 16)
  return cfg.control_dir .. "/" .. hash
end

---Build base SSH args for a parsed host
---@param parsed SSHHost
---@param sock string
---@return string[]
local function base_ssh_args(parsed, sock)
  local cfg = config.values.ssh
  local args = {
    "-S", sock,
    "-o", "ConnectTimeout=" .. cfg.connect_timeout,
    "-o", "ServerAliveInterval=" .. cfg.server_alive_interval,
  }
  if parsed.port then
    table.insert(args, "-p")
    table.insert(args, parsed.port)
  end
  return args
end

---Get the SSH destination string (user@host or host)
---@param parsed SSHHost
---@return string
local function ssh_dest(parsed)
  if parsed.user then
    return parsed.user .. "@" .. parsed.host
  end
  return parsed.host
end

---Connect to a host, establishing a ControlMaster socket
---@param host_string string
---@param callback fun(err: string|nil)
function M.connect(host_string, callback)
  local parsed = M.parse_host(host_string)
  local hid = host_id(parsed)

  if M._connections[hid] then
    vim.schedule(function() callback(nil) end)
    return
  end

  local cfg = config.values.ssh
  vim.fn.mkdir(cfg.control_dir, "p")
  -- Ensure 0700 permissions on control dir
  vim.fn.setfperm(cfg.control_dir, "rwx------")

  local sock = socket_path(hid)

  local args = { "ssh" }
  vim.list_extend(args, { "-fNM" })
  vim.list_extend(args, base_ssh_args(parsed, sock))
  vim.list_extend(args, { "-o", "ControlPersist=" .. cfg.control_persist })
  table.insert(args, ssh_dest(parsed))

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
          M._connections[hid] = {
            host_id = hid,
            parsed = parsed,
            socket = sock,
          }
          callback(nil)
        else
          callback("SSH connect failed (exit " .. code .. "): " .. table.concat(stderr_chunks, "\n"))
        end
      end)
    end,
  })
end

---Disconnect from a host
---@param host_string string
---@param callback fun(err: string|nil)
function M.disconnect(host_string, callback)
  local parsed = M.parse_host(host_string)
  local hid = host_id(parsed)
  local conn = M._connections[hid]

  if not conn then
    vim.schedule(function() callback(nil) end)
    return
  end

  vim.fn.jobstart({ "ssh", "-O", "exit", "-S", conn.socket, ssh_dest(parsed) }, {
    on_exit = function()
      vim.schedule(function()
        M._connections[hid] = nil
        callback(nil)
      end)
    end,
  })
end

---Disconnect all hosts
---@param callback fun()
function M.disconnect_all(callback)
  local keys = vim.tbl_keys(M._connections)
  if #keys == 0 then
    vim.schedule(function() callback() end)
    return
  end

  local remaining = #keys
  for _, hid in ipairs(keys) do
    local conn = M._connections[hid]
    vim.fn.jobstart({ "ssh", "-O", "exit", "-S", conn.socket, ssh_dest(conn.parsed) }, {
      on_exit = function()
        vim.schedule(function()
          M._connections[hid] = nil
          remaining = remaining - 1
          if remaining == 0 then
            callback()
          end
        end)
      end,
    })
  end
end

---Execute a command on a remote host
---@param host_string string
---@param cmd string
---@param callback fun(code: number, stdout: string[], stderr: string[])
function M.exec(host_string, cmd, callback)
  local parsed = M.parse_host(host_string)
  local hid = host_id(parsed)
  local conn = M._connections[hid]

  if not conn then
    vim.schedule(function()
      callback(1, {}, { "Not connected to " .. host_string })
    end)
    return
  end

  local args = { "ssh" }
  vim.list_extend(args, base_ssh_args(parsed, conn.socket))
  table.insert(args, ssh_dest(parsed))
  table.insert(args, "--")
  table.insert(args, cmd)

  local stdout_lines = {}
  local stderr_lines = {}

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
          table.insert(stderr_lines, line)
        end
      end
    end,
    on_exit = function(_, code)
      vim.schedule(function()
        callback(code, stdout_lines, stderr_lines)
      end)
    end,
  })
end

---Execute a streaming command on a remote host (persistent, line-buffered)
---@param host_string string
---@param cmd string
---@param on_line fun(line: string)
---@param on_exit fun(code: number, stderr: string[])
---@return number|nil job_id
function M.exec_streaming(host_string, cmd, on_line, on_exit)
  local parsed = M.parse_host(host_string)
  local hid = host_id(parsed)
  local conn = M._connections[hid]

  if not conn then
    vim.schedule(function()
      on_exit(1, { "Not connected to " .. host_string })
    end)
    return nil
  end

  local args = { "ssh" }
  vim.list_extend(args, base_ssh_args(parsed, conn.socket))
  table.insert(args, ssh_dest(parsed))
  table.insert(args, "--")
  table.insert(args, cmd)

  local stderr_lines = {}
  local partial = ""

  local job_id = vim.fn.jobstart(args, {
    on_stdout = function(_, data)
      for i, chunk in ipairs(data) do
        if i == 1 then
          partial = partial .. chunk
        else
          -- Previous partial is now a complete line
          local line = partial
          partial = chunk
          if line ~= "" then
            vim.schedule(function() on_line(line) end)
          end
        end
      end
    end,
    on_stderr = function(_, data)
      for _, line in ipairs(data) do
        if line ~= "" then
          table.insert(stderr_lines, line)
        end
      end
    end,
    on_exit = function(_, code)
      -- Flush any remaining partial line
      if partial ~= "" then
        local last = partial
        partial = ""
        vim.schedule(function() on_line(last) end)
      end
      vim.schedule(function()
        on_exit(code, stderr_lines)
      end)
    end,
  })

  if job_id <= 0 then
    vim.schedule(function()
      on_exit(1, { "Failed to start SSH streaming job" })
    end)
    return nil
  end

  return job_id
end

---Check if a host is connected
---@param host_string string
---@return boolean
function M.is_connected(host_string)
  local parsed = M.parse_host(host_string)
  local hid = host_id(parsed)
  local conn = M._connections[hid]
  if not conn then
    return false
  end
  -- Synchronous check via system()
  local result = vim.fn.system({ "ssh", "-O", "check", "-S", conn.socket, ssh_dest(parsed) })
  return vim.v.shell_error == 0
end

---Get SSH args for use by transfer.lua (for rsync -e flag)
---@param host_string string
---@return string[]|nil args, SSHHost|nil parsed
function M.get_ssh_args(host_string)
  local parsed = M.parse_host(host_string)
  local hid = host_id(parsed)
  local conn = M._connections[hid]

  if not conn then
    return nil, nil
  end

  local args = base_ssh_args(parsed, conn.socket)
  return args, parsed
end

return M
