local M = {}

---@type table<string, number> local_path -> augroup id
M._augroups = {}

---Set up file watchers for a project session
---@param project_info { host: string, remote_path: string, local_path: string, name: string }
function M.setup(project_info)
  local sync = require("nvim-client-render.sync")
  local project = require("nvim-client-render.project")

  local key = project_info.local_path
  -- Teardown existing augroup for this session if any
  if M._augroups[key] then
    pcall(vim.api.nvim_del_augroup_by_id, M._augroups[key])
  end

  local hash = vim.fn.sha256(key):sub(1, 12)
  local augroup = vim.api.nvim_create_augroup("NvimClientRender_Watcher_" .. hash, { clear = true })
  M._augroups[key] = augroup

  -- Normalize the local path for pattern matching
  local pattern = vim.fn.fnamemodify(project_info.local_path, ":p") .. "*"

  vim.api.nvim_create_autocmd("BufWritePost", {
    pattern = pattern,
    group = augroup,
    callback = function(args)
      local remote = project.local_to_remote(args.file)
      if remote then
        local session = project.get_for_path(args.file)
        local host = session and session.host or project_info.host
        sync.enqueue(args.buf, args.file, remote, host)
      end
    end,
  })

  vim.api.nvim_create_autocmd("BufReadPost", {
    pattern = pattern,
    group = augroup,
    callback = function(args)
      if vim.api.nvim_buf_is_valid(args.buf) then
        vim.b[args.buf].remote_sync_state = "synced"
      end
    end,
  })

  -- Intercept local LSP clients attaching to project mirror files:
  -- capture their config, detach them, and start/attach a remote equivalent
  vim.api.nvim_create_autocmd("LspAttach", {
    pattern = pattern,
    group = augroup,
    callback = function(args)
      local client = vim.lsp.get_client_by_id(args.data.client_id)
      if not client or client.name:match("^remote%-") then
        return -- already a remote client, leave it alone
      end

      local cfg = require("nvim-client-render.config")
      if not cfg.values.lsp.enabled or not cfg.values.lsp.auto_start then
        return
      end

      local lsp_mod = require("nvim-client-render.lsp")
      local server_config = lsp_mod.capture_local_config(client)

      -- Detach local client from this buffer
      vim.defer_fn(function()
        if vim.api.nvim_buf_is_valid(args.buf) then
          vim.lsp.buf_detach_client(args.buf, args.data.client_id)
        end
      end, 0)

      -- Start or attach remote equivalent
      if server_config then
        local client_name = "remote-" .. client.name
        local existing = lsp_mod.find_client_by_name(client_name)
        if existing then
          vim.lsp.buf_attach_client(args.buf, existing)
        else
          lsp_mod.start_from_config(server_config, args.buf)
        end
      end
    end,
  })
end

---Remove watchers for a specific session or all sessions
---@param local_path string|nil  session key, or nil to teardown all
function M.teardown(local_path)
  if local_path then
    local augroup = M._augroups[local_path]
    if augroup then
      pcall(vim.api.nvim_del_augroup_by_id, augroup)
      M._augroups[local_path] = nil
    end
  else
    for key, augroup in pairs(M._augroups) do
      pcall(vim.api.nvim_del_augroup_by_id, augroup)
      M._augroups[key] = nil
    end
  end
end

---Set sync state on a buffer
---@param bufnr number
---@param state "synced"|"uploading"|"retry_pending"|"failed"
function M.set_sync_state(bufnr, state)
  if vim.api.nvim_buf_is_valid(bufnr) then
    vim.b[bufnr].remote_sync_state = state
  end
end

return M
