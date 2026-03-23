local config = require("nvim-client-render.config")
local project = require("nvim-client-render.project")
local ssh = require("nvim-client-render.ssh")
local sync = require("nvim-client-render.sync")

local M = {}

---Complete SSH host names from ~/.ssh/config
---@param arg_lead string
---@return string[]
local function complete_ssh_hosts(arg_lead)
  local hosts = {}
  local config_file = vim.fn.expand("~/.ssh/config")
  if vim.fn.filereadable(config_file) == 1 then
    local lines = vim.fn.readfile(config_file)
    for _, line in ipairs(lines) do
      local host = line:match("^%s*Host%s+(.+)$")
      if host and not host:match("[*?]") then
        for h in host:gmatch("%S+") do
          if h:find(arg_lead, 1, true) == 1 then
            table.insert(hosts, h)
          end
        end
      end
    end
  end
  return hosts
end

function M.setup()
  vim.api.nvim_create_user_command("RemoteOpen", function(opts)
    local args = opts.fargs
    if #args < 2 then
      vim.notify("[nvim-client-render] Usage: :RemoteOpen <host> <remote_path>", vim.log.levels.ERROR)
      return
    end

    project.open(args[1], args[2], function(err)
      if err then
        vim.notify("[nvim-client-render] " .. err, vim.log.levels.ERROR)
      end
    end)
  end, {
    nargs = "+",
    desc = "Open a remote project for local editing",
    complete = function(arg_lead, cmd_line, cursor_pos)
      local parts = vim.split(cmd_line:sub(1, cursor_pos), "%s+")
      if #parts - 1 <= 1 then
        return complete_ssh_hosts(arg_lead)
      end
      return {}
    end,
  })

  vim.api.nvim_create_user_command("RemoteStatus", function()
    local active = project.get_for_context()
    if not active then
      vim.notify("[nvim-client-render] No active project", vim.log.levels.INFO)
      return
    end

    local status = sync.get_status()
    local connected = ssh.is_connected(active.host)

    local lines = {
      "Project: " .. active.name,
      "Host: " .. active.host .. (connected and " (connected)" or " (disconnected)"),
      "Remote: " .. active.remote_path,
      "Local: " .. active.local_path,
      "",
      "Sync Queue:",
      "  Pending: " .. status.pending,
      "  Uploading: " .. status.uploading,
      "  Failed: " .. status.failed,
    }

    if #status.items > 0 then
      table.insert(lines, "")
      table.insert(lines, "Items:")
      for _, item in ipairs(status.items) do
        table.insert(lines, "  [" .. item.state .. "] " .. item.local_path)
      end
    end

    local remote_watcher = require("nvim-client-render.remote_watcher")
    table.insert(lines, "")
    table.insert(lines, "Remote Watcher: " .. (remote_watcher.is_running(active.local_path) and "running" or "stopped"))

    local lsp_mod = require("nvim-client-render.lsp")
    local lsp_clients = lsp_mod.get_status()
    if #lsp_clients > 0 then
      table.insert(lines, "")
      table.insert(lines, "Remote LSP:")
      for _, c in ipairs(lsp_clients) do
        table.insert(lines, "  " .. c.name .. " (" .. (c.active and "active" or "stopped") .. ")")
      end
    end

    vim.notify(table.concat(lines, "\n"), vim.log.levels.INFO)
  end, {
    desc = "Show remote project status",
  })

  vim.api.nvim_create_user_command("RemoteSync", function(opts)
    local action = opts.fargs[1]

    if action == "git" then
      local git = require("nvim-client-render.git")
      local active = project.get_for_context()
      if not active or not git.get_session(active.local_path) then
        vim.notify("[nvim-client-render] Git integration not active", vim.log.levels.ERROR)
        return
      end
      git.sync_metadata(active.local_path, function(err)
        vim.schedule(function()
          if err then
            vim.notify("[nvim-client-render] Git sync failed: " .. err, vim.log.levels.ERROR)
          else
            vim.notify("[nvim-client-render] Git metadata synced", vim.log.levels.INFO)
          end
        end)
      end)
    elseif action == "retry" then
      sync.retry_failed()
      vim.notify("[nvim-client-render] Retrying failed uploads", vim.log.levels.INFO)
    else
      project.refresh(function(err)
        if err then
          vim.notify("[nvim-client-render] " .. err, vim.log.levels.ERROR)
        end
      end)
    end
  end, {
    nargs = "?",
    desc = "Re-sync project from remote (subcommands: git, retry)",
    complete = function()
      return { "git", "retry" }
    end,
  })

  vim.api.nvim_create_user_command("RemoteClose", function()
    local active = project.get_for_context()
    if not active then
      vim.notify("[nvim-client-render] No active project", vim.log.levels.INFO)
      return
    end

    local host = active.host
    local session_key = active.local_path

    vim.notify("[nvim-client-render] Flushing sync queue...", vim.log.levels.INFO)
    sync.flush(function()
      project.close(session_key, function()
        -- Only disconnect SSH if no other sessions use this host
        local still_used = false
        for _, s in pairs(project.get_all()) do
          if s.host == host then
            still_used = true
            break
          end
        end

        if still_used then
          vim.notify("[nvim-client-render] Session closed (SSH kept for other sessions on " .. host .. ")", vim.log.levels.INFO)
        else
          ssh.disconnect(host, function(err)
            if err then
              vim.notify("[nvim-client-render] Disconnect error: " .. err, vim.log.levels.WARN)
            else
              vim.notify("[nvim-client-render] Disconnected from " .. host, vim.log.levels.INFO)
            end
          end)
        end
      end)
    end)
  end, {
    desc = "Disconnect from remote and close project",
  })

  vim.api.nvim_create_user_command("RemoteBrowse", function(opts)
    local browse = require("nvim-client-render.browse")
    local args = opts.fargs
    if #args < 1 then
      vim.notify("[nvim-client-render] Usage: :RemoteBrowse <host> [base_path]", vim.log.levels.ERROR)
      return
    end
    browse.browse(args[1], args[2])
  end, {
    nargs = "+",
    desc = "Browse remote directories and open a project",
    complete = function(arg_lead, cmd_line, cursor_pos)
      local parts = vim.split(cmd_line:sub(1, cursor_pos), "%s+")
      if #parts - 1 <= 1 then
        return complete_ssh_hosts(arg_lead)
      end
      return {}
    end,
  })

  vim.api.nvim_create_user_command("RemoteTerminal", function(opts)
    local terminal = require("nvim-client-render.terminal")
    local action = opts.fargs[1]

    if action == "close" then
      terminal.close_all()
      vim.notify("[nvim-client-render] All remote terminals closed", vim.log.levels.INFO)
    else
      terminal.open({ split = action })
    end
  end, {
    nargs = "?",
    desc = "Open a remote terminal (subcommands: close, horizontal, vertical, float)",
    complete = function()
      return { "horizontal", "vertical", "float", "close" }
    end,
  })

  vim.api.nvim_create_user_command("RemoteWatch", function()
    local remote_watcher = require("nvim-client-render.remote_watcher")
    local active = project.get_for_context()
    if not active then
      vim.notify("[nvim-client-render] No active project", vim.log.levels.ERROR)
      return
    end

    if remote_watcher.is_running(active.local_path) then
      remote_watcher.stop(active.local_path)
      vim.notify("[nvim-client-render] Remote watcher stopped", vim.log.levels.INFO)
    else
      remote_watcher.start(active)
      vim.notify("[nvim-client-render] Remote watcher started", vim.log.levels.INFO)
    end
  end, {
    desc = "Toggle remote filesystem watcher",
  })

  vim.api.nvim_create_user_command("RemoteLsp", function(opts)
    local lsp_mod = require("nvim-client-render.lsp")
    local action = opts.fargs[1] or "status"
    local rest = table.concat(vim.list_slice(opts.fargs, 2), " ")

    if action == "start" then
      if rest ~= "" then
        local ft = vim.bo.filetype
        lsp_mod.start({ server_cmd = rest, name = ft ~= "" and ft or "custom" })
      else
        lsp_mod.auto_start(vim.api.nvim_get_current_buf())
      end
    elseif action == "stop" then
      lsp_mod.stop_all()
      vim.notify("[nvim-client-render] All remote LSP clients stopped", vim.log.levels.INFO)
    elseif action == "restart" then
      lsp_mod.restart()
      vim.notify("[nvim-client-render] Restarting remote LSP clients...", vim.log.levels.INFO)
    else
      local clients = lsp_mod.get_status()
      local discovered = lsp_mod.get_discovered_configs()
      local lines = {}

      if #clients > 0 then
        table.insert(lines, "Remote LSP Clients:")
        for _, c in ipairs(clients) do
          table.insert(lines, string.format("  [%d] %s @ %s (%s, %s)", c.id, c.name, c.host, c.active and "active" or "stopped", c.source))
        end
      else
        table.insert(lines, "No active remote LSP clients")
      end

      local discovered_names = vim.tbl_keys(discovered)
      if #discovered_names > 0 then
        table.insert(lines, "")
        table.insert(lines, "Discovered configs (from local LSP):")
        for _, name in ipairs(discovered_names) do
          local cfg = discovered[name]
          local fts = cfg.filetypes and table.concat(cfg.filetypes, ", ") or "any"
          table.insert(lines, string.format("  %s [%s] -> %s", name, fts, cfg.server_cmd))
        end
      end

      vim.notify(table.concat(lines, "\n"), vim.log.levels.INFO)
    end
  end, {
    nargs = "*",
    desc = "Manage remote LSP (subcommands: start [cmd], stop, restart, status)",
    complete = function(arg_lead, cmd_line, cursor_pos)
      local parts = vim.split(cmd_line:sub(1, cursor_pos), "%s+")
      if #parts - 1 <= 1 then
        return { "start", "stop", "restart", "status" }
      end
      return {}
    end,
  })

  vim.api.nvim_create_user_command("RemoteGit", function(opts)
    local git = require("nvim-client-render.git")
    local active = project.get_for_context()
    if not active or not git.get_session(active.local_path) then
      vim.notify("[nvim-client-render] Git integration not active", vim.log.levels.ERROR)
      return
    end

    local args = opts.args
    if args == "" then
      args = "status"
    end

    git.exec(args, function(code, stdout, stderr)
      vim.schedule(function()
        local output = {}
        for _, line in ipairs(stdout) do
          table.insert(output, line)
        end
        if code ~= 0 then
          for _, line in ipairs(stderr) do
            table.insert(output, line)
          end
        end
        if #output > 0 then
          vim.notify(table.concat(output, "\n"), code == 0 and vim.log.levels.INFO or vim.log.levels.ERROR)
        else
          vim.notify("[nvim-client-render] git " .. args .. " (exit " .. code .. ")", vim.log.levels.INFO)
        end
      end)
    end, active.local_path)
  end, {
    nargs = "*",
    desc = "Run a git command on the remote",
  })

  vim.api.nvim_create_user_command("RemoteClearCache", function()
    vim.ui.select({ "Yes", "No" }, {
      prompt = "Delete all local cache (" .. config.values.cache_dir .. ")?"
    }, function(choice)
      if choice ~= "Yes" then return end

      local sessions = project.get_all()
      local remaining = vim.tbl_count(sessions)

      local function delete_cache()
        ssh.disconnect_all(function()
          vim.fn.delete(config.values.cache_dir, "rf")
          vim.notify("[nvim-client-render] Cache cleared: " .. config.values.cache_dir, vim.log.levels.INFO)
        end)
      end

      if remaining == 0 then
        delete_cache()
        return
      end

      sync.flush(function()
        for local_path, _ in pairs(sessions) do
          project.close(local_path, function()
            remaining = remaining - 1
            if remaining == 0 then
              delete_cache()
            end
          end)
        end
      end)
    end)
  end, {
    desc = "Clear all local cache (mirrored files, SSH sockets, git shims)",
  })

  vim.api.nvim_create_user_command("RemoteSession", function(opts)
    local action = opts.fargs[1] or "list"

    if action == "switch" then
      local sessions = project.get_all()
      if vim.tbl_count(sessions) == 0 then
        vim.notify("[nvim-client-render] No active sessions", vim.log.levels.INFO)
        return
      end

      local items = {}
      local keys = {}
      for local_path, info in pairs(sessions) do
        table.insert(items, info.name .. " @ " .. info.host .. ":" .. info.remote_path)
        table.insert(keys, local_path)
      end

      vim.ui.select(items, { prompt = "Switch to session:" }, function(choice, idx)
        if not choice or not idx then return end
        local selected = sessions[keys[idx]]
        if selected then
          project._active = selected
          vim.notify("[nvim-client-render] Switched to: " .. selected.name, vim.log.levels.INFO)
        end
      end)
    else
      local sessions = project.get_all()
      local active = project.get_active()

      if vim.tbl_count(sessions) == 0 then
        vim.notify("[nvim-client-render] No active sessions", vim.log.levels.INFO)
        return
      end

      local lines = { "Active sessions:" }
      for local_path, info in pairs(sessions) do
        local marker = (active and active.local_path == local_path) and " *" or ""
        table.insert(lines, string.format("  %s @ %s:%s%s", info.name, info.host, info.remote_path, marker))
      end
      table.insert(lines, "")
      table.insert(lines, "(* = current active session)")

      vim.notify(table.concat(lines, "\n"), vim.log.levels.INFO)
    end
  end, {
    nargs = "?",
    desc = "Manage remote sessions (subcommands: list, switch)",
    complete = function()
      return { "list", "switch" }
    end,
  })
end

return M
