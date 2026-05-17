local config = require("nvim-client-render.config")

local M = {}

---@class RegistryEntry
---@field host string
---@field remote_path string
---@field local_path string
---@field name string
---@field last_opened_at integer  unix seconds

local CURRENT_VERSION = 1

---@return string
local function registry_path()
  return config.values.cache_dir .. "/projects.json"
end

---Load the registry from disk. Returns an empty registry on missing/corrupt files.
---@return { version: integer, projects: RegistryEntry[] }
function M.load()
  local path = registry_path()
  if vim.fn.filereadable(path) ~= 1 then
    return { version = CURRENT_VERSION, projects = {} }
  end

  local lines = vim.fn.readfile(path)
  local ok, decoded = pcall(vim.json.decode, table.concat(lines, "\n"))
  if not ok or type(decoded) ~= "table" or type(decoded.projects) ~= "table" then
    return { version = CURRENT_VERSION, projects = {} }
  end

  decoded.version = decoded.version or CURRENT_VERSION
  return decoded
end

---Save the registry atomically.
---@param data { version: integer, projects: RegistryEntry[] }
function M.save(data)
  local path = registry_path()
  vim.fn.mkdir(vim.fn.fnamemodify(path, ":h"), "p")

  local payload = vim.json.encode(data)
  local tmp = path .. ".tmp"
  vim.fn.writefile({ payload }, tmp)
  -- os.rename is atomic on POSIX
  local ok, err = os.rename(tmp, path)
  if not ok then
    pcall(vim.fn.delete, tmp)
    error("registry save failed: " .. tostring(err))
  end
end

---Insert or update an entry keyed by local_path. Stamps last_opened_at = now.
---@param info ProjectInfo
function M.upsert(info)
  local data = M.load()
  local found = false
  for _, entry in ipairs(data.projects) do
    if entry.local_path == info.local_path then
      entry.host = info.host
      entry.remote_path = info.remote_path
      entry.name = info.name
      entry.last_opened_at = os.time()
      found = true
      break
    end
  end

  if not found then
    table.insert(data.projects, {
      host = info.host,
      remote_path = info.remote_path,
      local_path = info.local_path,
      name = info.name,
      last_opened_at = os.time(),
    })
  end

  M.save(data)
end

---List entries sorted by last_opened_at desc. Optionally prune missing dirs.
---@param opts? { prune?: boolean }
---@return RegistryEntry[]
function M.list(opts)
  opts = opts or {}
  local data = M.load()

  if opts.prune then
    local kept = {}
    local dropped_any = false
    for _, entry in ipairs(data.projects) do
      if vim.fn.isdirectory(entry.local_path) == 1 then
        table.insert(kept, entry)
      else
        dropped_any = true
      end
    end
    if dropped_any then
      data.projects = kept
      pcall(M.save, data)
    end
  end

  table.sort(data.projects, function(a, b)
    return (a.last_opened_at or 0) > (b.last_opened_at or 0)
  end)

  return data.projects
end

---Remove the registry file.
function M.clear()
  local path = registry_path()
  if vim.fn.filereadable(path) == 1 then
    vim.fn.delete(path)
  end
end

return M
