local config = require("nvim-client-render.config")
local sync = require("nvim-client-render.sync")

describe("sync", function()
  before_each(function()
    config.setup()
    -- Clear queue and timers
    sync._queue = {}
    sync._uploading = false
    for bufnr, timer in pairs(sync._timers) do
      if not timer:is_closing() then
        timer:stop()
        timer:close()
      end
    end
    sync._timers = {}
  end)

  describe("get_status", function()
    it("returns zeroes when queue is empty", function()
      local status = sync.get_status()
      assert.are.equal(0, status.pending)
      assert.are.equal(0, status.failed)
      assert.are.same({}, status.items)
    end)

    it("counts pending items", function()
      sync._queue = {
        { bufnr = 1, local_path = "/a", remote_path = "/b", host = "h", retries = 0, state = "pending" },
        { bufnr = 2, local_path = "/c", remote_path = "/d", host = "h", retries = 0, state = "pending" },
      }
      local status = sync.get_status()
      assert.are.equal(2, status.pending)
    end)

    it("counts failed items", function()
      sync._queue = {
        { bufnr = 1, local_path = "/a", remote_path = "/b", host = "h", retries = 10, state = "failed" },
      }
      local status = sync.get_status()
      assert.are.equal(1, status.failed)
      assert.are.equal(0, status.pending)
    end)

    it("counts retry_pending as pending", function()
      sync._queue = {
        { bufnr = 1, local_path = "/a", remote_path = "/b", host = "h", retries = 2, state = "retry_pending" },
      }
      local status = sync.get_status()
      assert.are.equal(1, status.pending)
    end)
  end)

  describe("retry_failed", function()
    it("resets failed items to pending", function()
      -- Set uploading=true so _process_queue is a no-op (avoids side effects)
      sync._uploading = true
      sync._queue = {
        { bufnr = 1, local_path = "/a", remote_path = "/b", host = "h", retries = 10, state = "failed" },
        { bufnr = 2, local_path = "/c", remote_path = "/d", host = "h", retries = 5, state = "failed" },
      }
      sync.retry_failed()
      for _, item in ipairs(sync._queue) do
        assert.are.equal("pending", item.state)
        assert.are.equal(0, item.retries)
      end
    end)

    it("does not touch non-failed items", function()
      sync._uploading = true
      sync._queue = {
        { bufnr = 1, local_path = "/a", remote_path = "/b", host = "h", retries = 0, state = "pending" },
        { bufnr = 2, local_path = "/c", remote_path = "/d", host = "h", retries = 10, state = "failed" },
      }
      sync.retry_failed()
      assert.are.equal("pending", sync._queue[1].state)
      assert.are.equal(0, sync._queue[1].retries) -- unchanged
      assert.are.equal("pending", sync._queue[2].state)
      assert.are.equal(0, sync._queue[2].retries) -- reset
    end)
  end)
end)
