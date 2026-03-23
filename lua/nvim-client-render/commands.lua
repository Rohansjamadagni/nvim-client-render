local project = require("nvim-client-render.project")
local ssh = require("nvim-client-render.ssh")
local sync = require("nvim-client-render.sync")

local M = {}

function M.setup()
  vim.api.nvim_create_user_command("RemoteOpen", function(opts)
    local args = opts.fargs
    if #args < 2 then
      vim.notify("[nvim-client-render] Usage: :RemoteOpen <host> <remote_path>", vim.log.levels.ERROR)
      return
    end

    local host = args[1]
    local remote_path = args[2]

    project.open(host, remote_path, function(err)
      if err then
        vim.notify("[nvim-client-render] " .. err, vim.log.levels.ERROR)
      end
    end)
  end, {
    nargs = "+",
    desc = "Open a remote project for local editing",
    complete = function(arg_lead, cmd_line, cursor_pos)
      -- Parse what arg we're on
      local parts = vim.split(cmd_line:sub(1, cursor_pos), "%s+")
      local nargs = #parts - 1 -- subtract command name

      if nargs <= 1 then
        -- Complete host from SSH config
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

      return {}
    end,
  })

  vim.api.nvim_create_user_command("RemoteStatus", function()
    local active = project.get_active()
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

    -- Remote watcher status
    local remote_watcher = require("nvim-client-render.remote_watcher")
    table.insert(lines, "")
    table.insert(lines, "Remote Watcher: " .. (remote_watcher.is_running() and "running" or "stopped"))

    -- LSP status
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

  vim.api.nvim_create_user_command("RemoteSync", function()
    project.refresh(function(err)
      if err then
        vim.notify("[nvim-client-render] " .. err, vim.log.levels.ERROR)
      end
    end)
  end, {
    desc = "Re-sync project from remote",
  })

  vim.api.nvim_create_user_command("RemoteDisconnect", function()
    local active = project.get_active()
    if not active then
      vim.notify("[nvim-client-render] No active project", vim.log.levels.INFO)
      return
    end

    local host = active.host

    vim.notify("[nvim-client-render] Flushing sync queue...", vim.log.levels.INFO)
    sync.flush(function()
      project.close(function()
        ssh.disconnect(host, function(err)
          if err then
            vim.notify("[nvim-client-render] Disconnect error: " .. err, vim.log.levels.WARN)
          else
            vim.notify("[nvim-client-render] Disconnected from " .. host, vim.log.levels.INFO)
          end
        end)
      end)
    end)
  end, {
    desc = "Disconnect from remote and close project",
  })

  vim.api.nvim_create_user_command("RemoteRetry", function()
    sync.retry_failed()
    vim.notify("[nvim-client-render] Retrying failed uploads", vim.log.levels.INFO)
  end, {
    desc = "Retry failed sync uploads",
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
      local nargs = #parts - 1
      if nargs <= 1 then
        local hosts = {}
        local config_file = vim.fn.expand("~/.ssh/config")
        if vim.fn.filereadable(config_file) == 1 then
          local lines = vim.fn.readfile(config_file)
          for _, line in ipairs(lines) do
            local h = line:match("^%s*Host%s+(.+)$")
            if h and not h:match("[*?]") then
              for host in h:gmatch("%S+") do
                if host:find(arg_lead, 1, true) == 1 then
                  table.insert(hosts, host)
                end
              end
            end
          end
        end
        return hosts
      end
      return {}
    end,
  })

  -- Remote Terminal commands
  vim.api.nvim_create_user_command("RemoteTerminal", function(opts)
    local terminal = require("nvim-client-render.terminal")
    local split = opts.fargs[1]
    terminal.open({ split = split })
  end, {
    nargs = "?",
    desc = "Open a remote terminal",
    complete = function()
      return { "horizontal", "vertical", "float" }
    end,
  })

  vim.api.nvim_create_user_command("RemoteTerminalClose", function()
    local terminal = require("nvim-client-render.terminal")
    terminal.close_all()
    vim.notify("[nvim-client-render] All remote terminals closed", vim.log.levels.INFO)
  end, {
    desc = "Close all remote terminals",
  })

  -- Remote Watcher commands
  vim.api.nvim_create_user_command("RemoteWatch", function()
    local remote_watcher = require("nvim-client-render.remote_watcher")
    if remote_watcher.is_running() then
      remote_watcher.stop()
      vim.notify("[nvim-client-render] Remote watcher stopped", vim.log.levels.INFO)
    else
      local active = project.get_active()
      if active then
        remote_watcher.start(active)
        vim.notify("[nvim-client-render] Remote watcher started", vim.log.levels.INFO)
      else
        vim.notify("[nvim-client-render] No active project", vim.log.levels.ERROR)
      end
    end
  end, {
    desc = "Toggle remote filesystem watcher",
  })

  -- Remote LSP commands
  vim.api.nvim_create_user_command("RemoteLspStart", function(opts)
    local lsp_mod = require("nvim-client-render.lsp")
    local cmd = opts.args ~= "" and opts.args or nil
    if cmd then
      local ft = vim.bo.filetype
      lsp_mod.start({ server_cmd = cmd, name = ft ~= "" and ft or "custom" })
    else
      lsp_mod.auto_start(vim.api.nvim_get_current_buf())
    end
  end, {
    nargs = "*",
    desc = "Start remote LSP server for current buffer (use full path, not ~)",
  })

  vim.api.nvim_create_user_command("RemoteLspStop", function()
    local lsp_mod = require("nvim-client-render.lsp")
    lsp_mod.stop_all()
    vim.notify("[nvim-client-render] All remote LSP clients stopped", vim.log.levels.INFO)
  end, {
    desc = "Stop all remote LSP clients",
  })

  vim.api.nvim_create_user_command("RemoteLspStatus", function()
    local lsp_mod = require("nvim-client-render.lsp")
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
  end, {
    desc = "Show remote LSP client status",
  })

  -- Remote Git commands
  vim.api.nvim_create_user_command("RemoteGit", function(opts)
    local git = require("nvim-client-render.git")
    if not git._state then
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
    end)
  end, {
    nargs = "*",
    desc = "Run a git command on the remote",
  })

  vim.api.nvim_create_user_command("RemoteGitSync", function()
    local git = require("nvim-client-render.git")
    if not git._state then
      vim.notify("[nvim-client-render] Git integration not active", vim.log.levels.ERROR)
      return
    end

    git.sync_metadata(function(err)
      vim.schedule(function()
        if err then
          vim.notify("[nvim-client-render] Git sync failed: " .. err, vim.log.levels.ERROR)
        else
          vim.notify("[nvim-client-render] Git metadata synced", vim.log.levels.INFO)
        end
      end)
    end)
  end, {
    desc = "Manually refresh git metadata from remote",
  })

  vim.api.nvim_create_user_command("RemoteLspRestart", function()
    local lsp_mod = require("nvim-client-render.lsp")
    lsp_mod.restart()
    vim.notify("[nvim-client-render] Restarting remote LSP clients...", vim.log.levels.INFO)
  end, {
    desc = "Restart all remote LSP clients",
  })
end

return M
