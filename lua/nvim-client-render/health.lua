local M = {}

function M.check()
  vim.health.start("nvim-client-render")

  -- Check Neovim version
  if vim.fn.has("nvim-0.10") == 1 then
    vim.health.ok("Neovim >= 0.10")
  else
    vim.health.error("Neovim >= 0.10 required")
  end

  -- Check binaries
  local binaries = { "ssh", "rsync" }
  for _, bin in ipairs(binaries) do
    if vim.fn.executable(bin) == 1 then
      vim.health.ok(bin .. " found: " .. vim.fn.exepath(bin))
    else
      vim.health.error(bin .. " not found")
    end
  end

  -- Check control socket directory
  local config = require("nvim-client-render.config")
  local control_dir = config.values.ssh and config.values.ssh.control_dir
  if control_dir then
    if vim.fn.isdirectory(control_dir) == 1 then
      local perms = vim.fn.getfperm(control_dir)
      if perms == "rwx------" then
        vim.health.ok("Control socket directory: " .. control_dir .. " (permissions: " .. perms .. ")")
      else
        vim.health.warn("Control socket directory permissions: " .. perms .. " (expected rwx------)")
      end
    else
      vim.health.info("Control socket directory not yet created: " .. control_dir .. " (will be created on first connect)")
    end
  end

  -- Check git/fugitive
  if vim.fn.exists("*FugitiveDetect") == 1 then
    vim.health.ok("vim-fugitive: installed")
  else
    vim.health.info("vim-fugitive: not installed (optional, needed for :Git commands)")
  end

  if vim.fn.executable("git") == 1 then
    vim.health.ok("git found: " .. vim.fn.exepath("git"))
  else
    vim.health.warn("git not found (needed for git integration)")
  end

  -- Check active project
  local project = require("nvim-client-render.project")
  local active = project.get_active()
  if active then
    vim.health.ok("Active project: " .. active.name .. " @ " .. active.host .. ":" .. active.remote_path)
    local ssh_mod = require("nvim-client-render.ssh")
    if ssh_mod.is_connected(active.host) then
      vim.health.ok("SSH connection: active")
    else
      vim.health.warn("SSH connection: not active")
    end

    -- Check git integration status
    local git = require("nvim-client-render.git")
    local git_session = git.get_session(active.local_path)
    if git_session then
      local head_file = git_session.git_dir .. "/HEAD"
      if vim.fn.filereadable(head_file) == 1 then
        local head = vim.fn.readfile(head_file)
        local branch = head[1] or "unknown"
        if branch:match("^ref: refs/heads/") then
          branch = branch:gsub("^ref: refs/heads/", "")
        end
        vim.health.ok("Git integration: active (branch: " .. branch .. ")")
      else
        vim.health.ok("Git integration: active")
      end
      if git._wrapper_path then
        vim.health.ok("Git wrapper: " .. git._wrapper_path)
      end

      -- Check remote git availability
      ssh_mod.exec(active.host, "command -v git", function(git_code, git_stdout)
        vim.schedule(function()
          if git_code == 0 and #git_stdout > 0 then
            vim.health.ok("Remote git: " .. git_stdout[1])
          else
            vim.health.warn("Remote git: not found")
          end
        end)
      end)
    else
      vim.health.info("Git integration: not active")
    end

    -- Check remote watcher status
    local remote_watcher = require("nvim-client-render.remote_watcher")
    if remote_watcher.is_running() then
      vim.health.ok("Remote watcher: running")
    else
      vim.health.info("Remote watcher: not running")
    end

    -- Check inotifywait/fswatch availability on remote
    ssh_mod.exec(active.host, "command -v inotifywait || command -v fswatch", function(code, stdout)
      if code == 0 and #stdout > 0 then
        vim.schedule(function()
          vim.health.ok("Remote file watcher: " .. stdout[1])
        end)
      else
        vim.schedule(function()
          vim.health.warn("Neither inotifywait nor fswatch found on remote (needed for 2-way sync)")
        end)
      end
    end)

    -- Check remote LSP status
    local lsp_mod = require("nvim-client-render.lsp")
    local lsp_clients = lsp_mod.get_status()
    if #lsp_clients > 0 then
      for _, c in ipairs(lsp_clients) do
        vim.health.ok("Remote LSP: " .. c.name .. " (" .. (c.active and "active" or "stopped") .. ", " .. c.source .. ")")
      end
    else
      vim.health.info("No active remote LSP clients")
    end

    -- Show discovered (intercepted) server configs
    local discovered = lsp_mod.get_discovered_configs()
    local discovered_names = vim.tbl_keys(discovered)
    if #discovered_names > 0 then
      for _, name in ipairs(discovered_names) do
        local cfg = discovered[name]
        vim.health.ok("Discovered LSP config: " .. name .. " -> " .. cfg.server_cmd)
      end
    end

    -- Check configured LSP servers on remote
    local servers = config.values.lsp and config.values.lsp.servers or {}
    for ft, cmd in pairs(servers) do
      local bin = cmd:match("^(%S+)")
      ssh_mod.exec(active.host, "command -v " .. bin, function(srv_code, srv_stdout)
        vim.schedule(function()
          if srv_code == 0 and #srv_stdout > 0 then
            vim.health.ok("Remote LSP server for " .. ft .. ": " .. srv_stdout[1])
          else
            vim.health.warn("Remote LSP server for " .. ft .. " (" .. bin .. "): not found on remote")
          end
        end)
      end)
    end
  else
    vim.health.info("No active project")
  end
end

return M
