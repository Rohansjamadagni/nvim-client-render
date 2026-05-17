local config = require("nvim-client-render.config")
local registry = require("nvim-client-render.registry")

describe("registry", function()
  local test_cache_dir

  before_each(function()
    test_cache_dir = vim.fn.tempname() .. "-ncr-registry-test"
    vim.fn.mkdir(test_cache_dir, "p")
    config.setup({ cache_dir = test_cache_dir })
  end)

  after_each(function()
    pcall(vim.fn.delete, test_cache_dir, "rf")
  end)

  local function make_info(overrides)
    local info = {
      host = "myhost",
      remote_path = "/home/me/proj",
      local_path = test_cache_dir .. "/files/abc123/proj",
      name = "proj",
    }
    for k, v in pairs(overrides or {}) do
      info[k] = v
    end
    vim.fn.mkdir(info.local_path, "p")
    return info
  end

  describe("load", function()
    it("returns empty when file does not exist", function()
      local data = registry.load()
      assert.are.same({}, data.projects)
    end)

    it("returns empty on corrupt JSON", function()
      vim.fn.writefile({ "{not valid json" }, test_cache_dir .. "/projects.json")
      local data = registry.load()
      assert.are.same({}, data.projects)
    end)
  end)

  describe("upsert", function()
    it("inserts a new entry with last_opened_at", function()
      local info = make_info()
      registry.upsert(info)

      local data = registry.load()
      assert.are.equal(1, #data.projects)
      assert.are.equal("myhost", data.projects[1].host)
      assert.are.equal("/home/me/proj", data.projects[1].remote_path)
      assert.is_number(data.projects[1].last_opened_at)
    end)

    it("updates rather than duplicates on same local_path", function()
      local info = make_info()
      registry.upsert(info)
      registry.upsert(info)
      registry.upsert(info)

      local data = registry.load()
      assert.are.equal(1, #data.projects)
    end)

    it("refreshes fields when re-upserting", function()
      local info = make_info()
      registry.upsert(info)

      info.host = "newhost"
      info.remote_path = "/new/path"
      registry.upsert(info)

      local data = registry.load()
      assert.are.equal(1, #data.projects)
      assert.are.equal("newhost", data.projects[1].host)
      assert.are.equal("/new/path", data.projects[1].remote_path)
    end)
  end)

  describe("list", function()
    it("returns empty list when registry is empty", function()
      assert.are.same({}, registry.list())
    end)

    it("sorts by last_opened_at desc", function()
      local a = make_info({ local_path = test_cache_dir .. "/files/h/a", name = "a" })
      local b = make_info({ local_path = test_cache_dir .. "/files/h/b", name = "b" })

      registry.upsert(a)
      -- Manually patch timestamps to ensure deterministic ordering.
      local data = registry.load()
      data.projects[1].last_opened_at = 100
      registry.save(data)

      registry.upsert(b)
      data = registry.load()
      for _, e in ipairs(data.projects) do
        if e.name == "b" then e.last_opened_at = 200 end
      end
      registry.save(data)

      local entries = registry.list()
      assert.are.equal("b", entries[1].name)
      assert.are.equal("a", entries[2].name)
    end)

    it("prunes entries whose local_path is missing", function()
      local present = make_info({ local_path = test_cache_dir .. "/files/h/present", name = "present" })
      registry.upsert(present)

      -- Inject an entry whose dir does not exist.
      local data = registry.load()
      table.insert(data.projects, {
        host = "ghost",
        remote_path = "/gone",
        local_path = test_cache_dir .. "/files/h/missing",
        name = "missing",
        last_opened_at = os.time(),
      })
      registry.save(data)

      local entries = registry.list({ prune = true })
      assert.are.equal(1, #entries)
      assert.are.equal("present", entries[1].name)

      -- Prune persists.
      data = registry.load()
      assert.are.equal(1, #data.projects)
    end)
  end)

  describe("clear", function()
    it("removes the registry file", function()
      registry.upsert(make_info())
      assert.are.equal(1, vim.fn.filereadable(test_cache_dir .. "/projects.json"))

      registry.clear()
      assert.are.equal(0, vim.fn.filereadable(test_cache_dir .. "/projects.json"))
    end)

    it("is a no-op when the file does not exist", function()
      assert.has_no.errors(function() registry.clear() end)
    end)
  end)
end)
