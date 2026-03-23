local M = {}

M.defaults = {
  cache_dir = vim.fn.stdpath("state") .. "/nvim-client-render",
  ssh = {
    control_persist = "10m",
    connect_timeout = 10,
    server_alive_interval = 15,
  },
  transfer = {
    rsync_flags = { "-az", "--inplace", "--partial" },
    exclude = { ".git", "node_modules", "__pycache__", ".venv", "target", "build" },
  },
  sync = {
    debounce_ms = 300,
    retry_interval_ms = 5000,
    max_retries = 10,
  },
  project = {
    auto_cd = true,
  },
  remote_watcher = {
    enabled = true,
    debounce_ms = 500,
    suppress_ttl_ms = 5000,
    conflict_strategy = "warn", -- "warn" | "local_wins" | "remote_wins"
  },
  terminal = {
    default_split = "vertical",
    float_width = 0.8,
    float_height = 0.8,
    auto_cd = true,
  },
  lsp = {
    enabled = true,
    auto_start = true,
    servers = {},
  },
  git = {
    enabled = true,
    auto_detect = true,
    fugitive = true,
    resync_on_branch_change = true,
  },
}

---Resolve cache-derived paths (only sets them if not already present).
---@param values table
local function resolve_cache_paths(values)
  local cache = values.cache_dir
  if not values.ssh.control_dir then
    values.ssh.control_dir = cache .. "/ssh"
  end
  if not values.project.base_dir then
    values.project.base_dir = cache .. "/files"
  end
end

M.values = vim.deepcopy(M.defaults)
resolve_cache_paths(M.values)

---@param t table
---@return boolean
local function is_list(t)
  if vim.islist then
    return vim.islist(t)
  end
  return vim.tbl_islist(t)
end

---Deep merge t2 into t1
---@param t1 table
---@param t2 table
---@return table
local function deep_merge(t1, t2)
  local result = {}
  for k, v in pairs(t1) do
    if type(v) == "table" and type(t2[k]) == "table" and not is_list(t2[k]) then
      result[k] = deep_merge(v, t2[k])
    elseif t2[k] ~= nil then
      result[k] = t2[k]
    else
      result[k] = v
    end
  end
  for k, v in pairs(t2) do
    if result[k] == nil then
      result[k] = v
    end
  end
  return result
end

function M.setup(opts)
  M.values = deep_merge(M.defaults, opts or {})
  resolve_cache_paths(M.values)
end

return M
