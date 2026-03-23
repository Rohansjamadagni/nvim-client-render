local config = require("nvim-client-render.config")

describe("config", function()
  before_each(function()
    config.values = {}
  end)

  describe("setup", function()
    it("uses defaults when no opts provided", function()
      config.setup()
      assert.are.equal(300, config.values.sync.debounce_ms)
      assert.are.equal(10, config.values.ssh.connect_timeout)
      assert.are.equal(true, config.values.project.auto_cd)
    end)

    it("merges user opts over defaults", function()
      config.setup({
        sync = { debounce_ms = 500 },
      })
      assert.are.equal(500, config.values.sync.debounce_ms)
      -- Other sync defaults preserved
      assert.are.equal(5000, config.values.sync.retry_interval_ms)
      assert.are.equal(10, config.values.sync.max_retries)
    end)

    it("deep merges nested tables", function()
      config.setup({
        ssh = { connect_timeout = 30 },
        transfer = { prefer = "scp" },
      })
      assert.are.equal(30, config.values.ssh.connect_timeout)
      assert.are.equal("scp", config.values.transfer.prefer)
      -- Defaults preserved
      assert.are.equal("10m", config.values.ssh.control_persist)
      assert.are.equal(15, config.values.ssh.server_alive_interval)
    end)

    it("allows overriding exclude patterns", function()
      config.setup({
        transfer = { exclude = { ".git", "vendor" } },
      })
      assert.are.same({ ".git", "vendor" }, config.values.transfer.exclude)
    end)

    it("allows overriding rsync_flags", function()
      config.setup({
        transfer = { rsync_flags = { "-avz" } },
      })
      assert.are.same({ "-avz" }, config.values.transfer.rsync_flags)
    end)

    it("preserves unrelated top-level keys", function()
      config.setup({
        sync = { debounce_ms = 100 },
      })
      -- ssh, transfer, project should still have defaults
      assert.is_not_nil(config.values.ssh)
      assert.is_not_nil(config.values.transfer)
      assert.is_not_nil(config.values.project)
    end)
  end)
end)
