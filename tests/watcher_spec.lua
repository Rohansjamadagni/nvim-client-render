local watcher = require("nvim-client-render.watcher")

describe("watcher", function()
  describe("set_sync_state", function()
    it("sets buffer variable on valid buffer", function()
      local buf = vim.api.nvim_create_buf(false, true)
      watcher.set_sync_state(buf, "synced")
      assert.are.equal("synced", vim.b[buf].remote_sync_state)

      watcher.set_sync_state(buf, "uploading")
      assert.are.equal("uploading", vim.b[buf].remote_sync_state)

      watcher.set_sync_state(buf, "failed")
      assert.are.equal("failed", vim.b[buf].remote_sync_state)

      vim.api.nvim_buf_delete(buf, { force = true })
    end)

    it("does not error on invalid buffer", function()
      -- Should not throw
      watcher.set_sync_state(99999, "synced")
    end)
  end)

  describe("setup and teardown", function()
    it("can setup and teardown without error", function()
      local project_info = {
        host = "test@host",
        remote_path = "/remote/path",
        local_path = "/tmp/test-local-path",
        name = "test",
      }
      watcher.setup(project_info)
      watcher.teardown()
    end)

    it("teardown is idempotent", function()
      watcher.teardown()
      watcher.teardown()
    end)
  end)
end)
