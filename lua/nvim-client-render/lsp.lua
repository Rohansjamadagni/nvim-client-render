local config = require("nvim-client-render.config")
local ssh = require("nvim-client-render.ssh")

local M = {}

---@type table<number, { name: string, host: string, server_config: table }>
M._clients = {}

---@type table<string, table> server_name -> { server_cmd, name, filetypes, settings, init_options }
M._discovered_configs = {}

---Convert a local file URI to a remote file URI
---@param uri string
---@return string
local function local_uri_to_remote(uri)
  local project = require("nvim-client-render.project")
  local active = project.get_active()
  if not active then
    return uri
  end

  local path = vim.uri_to_fname(uri)
  local remote = project.local_to_remote(path)
  if remote then
    return vim.uri_from_fname(remote)
  end
  return uri
end

---Convert a remote file URI to a local file URI
---@param uri string
---@return string
local function remote_uri_to_local(uri)
  local project = require("nvim-client-render.project")
  local active = project.get_active()
  if not active then
    return uri
  end

  local path = vim.uri_to_fname(uri)
  local local_path = project.remote_to_local(path)
  if local_path then
    return vim.uri_from_fname(local_path)
  end
  return uri
end

---Recursively rewrite any file:// URI string values in a table (in-place, key-agnostic)
---@param obj any
---@param transform fun(uri: string): string
---@return any
local function deep_rewrite_uris(obj, transform)
  if type(obj) ~= "table" then
    return obj
  end
  for k, v in pairs(obj) do
    if type(v) == "string" and v:sub(1, 7) == "file://" then
      obj[k] = transform(v)
    elseif type(v) == "table" then
      deep_rewrite_uris(v, transform)
    end
  end
  return obj
end

---Apply command_wrapper to a server command string
---@param server_cmd string The raw server command
---@param server_name string The server name (for function-style wrappers)
---@param wrapper? string|fun(cmd: string, name: string): string
---@return string
local function apply_command_wrapper(server_cmd, server_name, wrapper)
  if not wrapper then
    return server_cmd
  end
  if type(wrapper) == "function" then
    return wrapper(server_cmd, server_name)
  end
  if type(wrapper) == "string" then
    return wrapper:gsub("{}", vim.fn.shellescape(server_cmd))
  end
  return server_cmd
end

---Create a transport factory for vim.lsp.start({ cmd = ... })
---Wraps RPC to rewrite URIs on all messages in both directions.
---@param ssh_cmd string[] The SSH command to run the remote LSP server
---@param server_name string Human-readable name for error messages
---@return fun(dispatchers: table): table
local function create_transport(ssh_cmd, server_name)
  return function(dispatchers)
    local wrapped_dispatchers = {
      notification = function(method, params)
        deep_rewrite_uris(params, remote_uri_to_local)
        dispatchers.notification(method, params)
      end,
      server_request = function(method, params)
        deep_rewrite_uris(params, remote_uri_to_local)
        return dispatchers.server_request(method, params)
      end,
      on_exit = function(code, signal)
        if code ~= 0 then
          vim.schedule(function()
            vim.notify(
              "[nvim-client-render] LSP " .. server_name .. " exited (code " .. code .. ")",
              vim.log.levels.WARN
            )
          end)
        end
        dispatchers.on_exit(code, signal)
      end,
      on_error = function(code, err)
        vim.schedule(function()
          vim.notify(
            "[nvim-client-render] LSP " .. server_name .. " RPC error: " .. tostring(err),
            vim.log.levels.ERROR
          )
        end)
        if dispatchers.on_error then
          dispatchers.on_error(code, err)
        end
      end,
    }

    local rpc = vim.lsp.rpc.start(ssh_cmd, wrapped_dispatchers)

    return {
      request = function(method, params, callback, notify_reply_callback)
        deep_rewrite_uris(params, local_uri_to_remote)
        local wrapped_cb = callback and function(err, result)
          deep_rewrite_uris(result, remote_uri_to_local)
          callback(err, result)
        end
        return rpc.request(method, params, wrapped_cb, notify_reply_callback)
      end,
      notify = function(method, params)
        deep_rewrite_uris(params, local_uri_to_remote)
        return rpc.notify(method, params)
      end,
      is_closing = rpc.is_closing,
      terminate = rpc.terminate,
    }
  end
end

---Start a remote LSP server
---@param opts { server_cmd: string, name: string, filetypes?: string[], settings?: table, init_options?: table, command_wrapper?: string|function }
---@param bufnr? number Buffer to attach to (defaults to current buffer)
function M.start(opts, bufnr)
  local project = require("nvim-client-render.project")
  local active = project.get_active()
  if not active then
    vim.notify("[nvim-client-render] No active project for LSP", vim.log.levels.ERROR)
    return
  end

  local ssh_args, parsed = ssh.get_ssh_args(active.host)
  if not ssh_args or not parsed then
    vim.notify("[nvim-client-render] Not connected to " .. active.host, vim.log.levels.ERROR)
    return
  end

  local dest = ssh.ssh_dest(parsed)

  -- Apply command wrapper (per-server override > global config > none)
  local wrapper = opts.command_wrapper or config.values.lsp.command_wrapper
  local effective_cmd = apply_command_wrapper(opts.server_cmd, opts.name, wrapper)

  -- Build SSH command
  local remote_cmd = "cd " .. active.remote_path .. " && exec " .. effective_cmd
  local cmd = { "ssh" }
  vim.list_extend(cmd, ssh_args)
  table.insert(cmd, dest)
  table.insert(cmd, "--")
  table.insert(cmd, remote_cmd)

  local client_name = "remote-" .. opts.name
  local start_opts = bufnr and { bufnr = bufnr } or nil

  local client_id = vim.lsp.start({
    name = client_name,
    cmd = create_transport(cmd, client_name),
    root_dir = active.local_path,
    filetypes = opts.filetypes,
    settings = opts.settings,
    init_options = opts.init_options,
    before_init = function(params)
      -- Null out processId: the LSP server runs on a remote machine where
      -- our local PID doesn't exist. Without this, the server detects the
      -- "parent" process is missing and exits immediately.
      params.processId = vim.NIL
      if params.rootUri then
        params.rootUri = local_uri_to_remote(params.rootUri)
      end
      if params.rootPath then
        local remote = project.local_to_remote(params.rootPath)
        if remote then
          params.rootPath = remote
        end
      end
      if params.workspaceFolders then
        deep_rewrite_uris(params.workspaceFolders, local_uri_to_remote)
      end
    end,
  }, start_opts)

  if client_id then
    M._clients[client_id] = {
      name = client_name,
      host = active.host,
      server_config = {
        server_cmd = opts.server_cmd,
        name = opts.name,
        filetypes = opts.filetypes,
        settings = opts.settings,
        init_options = opts.init_options,
        command_wrapper = opts.command_wrapper,
      },
    }
    vim.notify("[nvim-client-render] LSP started: " .. client_name .. " (id: " .. client_id .. ")", vim.log.levels.INFO)
  else
    vim.notify("[nvim-client-render] LSP failed to start: " .. client_name .. "\ncmd: " .. table.concat(cmd, " "), vim.log.levels.ERROR)
  end

  return client_id
end

---Extract config from a local LSP client for remote reuse
---@param client table A vim.lsp client object
---@return table|nil config { server_cmd, name, filetypes, settings, init_options }
function M.capture_local_config(client)
  local cfg = client.config
  if not cfg or not cfg.cmd then
    return nil
  end

  local cmd_str
  if type(cfg.cmd) == "table" then
    local parts = {}
    for _, part in ipairs(cfg.cmd) do
      table.insert(parts, vim.fn.shellescape(part))
    end
    cmd_str = table.concat(parts, " ")
  elseif type(cfg.cmd) == "string" then
    cmd_str = cfg.cmd
  else
    return nil
  end

  local server_config = {
    server_cmd = cmd_str,
    name = client.name,
    filetypes = cfg.filetypes,
    settings = cfg.settings,
    init_options = cfg.init_options,
  }

  M._discovered_configs[client.name] = server_config
  return server_config
end

---Start a remote LSP from a captured local client config
---@param server_config table { server_cmd, name, filetypes, settings, init_options }
---@param bufnr? number Buffer to attach to
---@return number|nil client_id
function M.start_from_config(server_config, bufnr)
  return M.start(server_config, bufnr)
end

---Find an active remote client by name
---@param name string
---@return number|nil client_id
function M.find_client_by_name(name)
  for client_id, info in pairs(M._clients) do
    if info.name == name then
      local client = vim.lsp.get_client_by_id(client_id)
      if client then
        return client_id
      else
        M._clients[client_id] = nil
      end
    end
  end
  return nil
end

---Auto-start LSP for a buffer based on discovered configs or manual config
---@param bufnr number
function M.auto_start(bufnr)
  if not config.values.lsp.enabled or not config.values.lsp.auto_start then
    return
  end

  local ft = vim.bo[bufnr].filetype
  if ft == "" then
    return
  end

  -- Check discovered configs first (from LspAttach interception)
  for server_name, server_config in pairs(M._discovered_configs) do
    if server_config.filetypes then
      for _, sft in ipairs(server_config.filetypes) do
        if sft == ft then
          local client_name = "remote-" .. server_name
          local existing = M.find_client_by_name(client_name)
          if existing then
            vim.lsp.buf_attach_client(bufnr, existing)
          else
            M.start(server_config, bufnr)
          end
          return
        end
      end
    end
  end

  -- Fall back to manual lsp.servers config (backward compat)
  local server_cmd = config.values.lsp.servers[ft]
  if not server_cmd then
    return
  end

  local client_name = "remote-" .. ft
  local existing = M.find_client_by_name(client_name)
  if existing then
    vim.lsp.buf_attach_client(bufnr, existing)
    return
  end

  M.start({
    server_cmd = server_cmd,
    name = ft,
    filetypes = { ft },
  }, bufnr)
end

---Stop all remote LSP clients
function M.stop_all()
  for client_id, _ in pairs(M._clients) do
    local client = vim.lsp.get_client_by_id(client_id)
    if client then
      client.stop()
    end
  end
  M._clients = {}
end

---Restart all remote LSP clients
function M.restart()
  local to_restart = {}
  for client_id, info in pairs(M._clients) do
    local client = vim.lsp.get_client_by_id(client_id)
    if client then
      table.insert(to_restart, info.server_config)
      client.stop()
    end
  end
  M._clients = {}

  local timer = vim.uv.new_timer()
  timer:start(500, 0, function()
    timer:close()
    vim.schedule(function()
      for _, server_config in ipairs(to_restart) do
        M.start(server_config)
      end
    end)
  end)
end

---Get status of all remote LSP clients (cleans up stale entries)
---@return table[]
function M.get_status()
  local result = {}
  for client_id, info in pairs(M._clients) do
    local client = vim.lsp.get_client_by_id(client_id)
    if client then
      table.insert(result, {
        id = client_id,
        name = info.name,
        host = info.host,
        source = info.server_config and "auto" or "manual",
        active = true,
      })
    else
      M._clients[client_id] = nil
    end
  end
  return result
end

---Get discovered (intercepted) server configs
---@return table<string, table>
function M.get_discovered_configs()
  return M._discovered_configs
end

---Notify LSP clients about a file change (called by remote_watcher)
---@param remote_path string
function M.notify_file_changed(remote_path)
  local remote_uri = vim.uri_from_fname(remote_path)
  for client_id, _ in pairs(M._clients) do
    local client = vim.lsp.get_client_by_id(client_id)
    if client then
      client.notify("workspace/didChangeWatchedFiles", {
        changes = { { uri = remote_uri, type = 2 } },
      })
    end
  end
end

-- Expose internals for testing
M._apply_command_wrapper = apply_command_wrapper
M._deep_rewrite_uris = deep_rewrite_uris
M._local_uri_to_remote = local_uri_to_remote
M._remote_uri_to_local = remote_uri_to_local

return M
