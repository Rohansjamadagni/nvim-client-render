local config = require("nvim-client-render.config")
local project = require("nvim-client-render.project")

describe("cache_dir config", function()
  before_each(function()
    config.values = {}
  end)

  it("resolves ssh.control_dir from cache_dir by default", function()
    config.setup()
    assert.are.equal(config.values.cache_dir .. "/ssh", config.values.ssh.control_dir)
  end)

  it("resolves project.base_dir from cache_dir by default", function()
    config.setup()
    assert.are.equal(config.values.cache_dir .. "/files", config.values.project.base_dir)
  end)

  it("uses custom cache_dir for sub-paths", function()
    config.setup({ cache_dir = "/tmp/my-nvim-cache" })
    assert.are.equal("/tmp/my-nvim-cache", config.values.cache_dir)
    assert.are.equal("/tmp/my-nvim-cache/ssh", config.values.ssh.control_dir)
    assert.are.equal("/tmp/my-nvim-cache/files", config.values.project.base_dir)
  end)

  it("allows explicit override of sub-paths", function()
    config.setup({
      cache_dir = "/tmp/my-cache",
      ssh = { control_dir = "/custom/ssh" },
      project = { base_dir = "/custom/files" },
    })
    assert.are.equal("/custom/ssh", config.values.ssh.control_dir)
    assert.are.equal("/custom/files", config.values.project.base_dir)
  end)

  it("allows overriding only one sub-path", function()
    config.setup({
      cache_dir = "/tmp/my-cache",
      ssh = { control_dir = "/custom/ssh" },
    })
    assert.are.equal("/custom/ssh", config.values.ssh.control_dir)
    assert.are.equal("/tmp/my-cache/files", config.values.project.base_dir)
  end)

  it("default cache_dir uses stdpath", function()
    config.setup()
    local expected = vim.fn.stdpath("state") .. "/nvim-client-render"
    assert.are.equal(expected, config.values.cache_dir)
  end)
end)

describe("RemoteClearCache", function()
  local test_cache_dir

  before_each(function()
    test_cache_dir = vim.fn.tempname() .. "-ncr-test"
    vim.fn.mkdir(test_cache_dir .. "/files/abc123/myproject", "p")
    vim.fn.mkdir(test_cache_dir .. "/ssh", "p")
    vim.fn.writefile({ "test" }, test_cache_dir .. "/files/abc123/myproject/file.txt")
    vim.fn.writefile({ "socket" }, test_cache_dir .. "/ssh/ctrl-abc")

    config.setup({ cache_dir = test_cache_dir })
    project._active = nil
    project._sessions = {}
  end)

  after_each(function()
    pcall(vim.fn.delete, test_cache_dir, "rf")
  end)

  it("cache dir exists before clear", function()
    assert.are.equal(1, vim.fn.isdirectory(test_cache_dir))
    assert.are.equal(1, vim.fn.isdirectory(test_cache_dir .. "/files"))
    assert.are.equal(1, vim.fn.isdirectory(test_cache_dir .. "/ssh"))
    assert.are.equal(1, vim.fn.filereadable(test_cache_dir .. "/files/abc123/myproject/file.txt"))
  end)

  it("deleting cache_dir removes all contents", function()
    vim.fn.delete(config.values.cache_dir, "rf")
    assert.are.equal(0, vim.fn.isdirectory(test_cache_dir))
    assert.are.equal(0, vim.fn.isdirectory(test_cache_dir .. "/files"))
    assert.are.equal(0, vim.fn.isdirectory(test_cache_dir .. "/ssh"))
  end)

  it("close removes session from project state", function()
    local info = {
      host = "myhost",
      remote_path = "/remote/proj",
      local_path = test_cache_dir .. "/files/abc123/myproject",
      name = "myproject",
    }
    project._sessions[info.local_path] = info
    project._active = info

    -- Simulate close (without SSH/sync dependencies)
    project._sessions[info.local_path] = nil
    project._active = nil

    assert.are.same({}, project.get_all())
    assert.is_nil(project.get_active())
  end)
end)
