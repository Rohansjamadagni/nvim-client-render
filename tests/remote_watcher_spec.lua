-- vim.uv is the nvim 0.10+ alias for vim.loop; the production code uses it
-- throughout. Older nvim versions used in CI may not have it, so shim.
if not vim.uv then vim.uv = vim.loop end

local config = require("nvim-client-render.config")
local remote_watcher = require("nvim-client-render.remote_watcher")
local ssh = require("nvim-client-render.ssh")
local transfer = require("nvim-client-render.transfer")

describe("remote_watcher", function()
  local original_exec_streaming
  local original_ensure_connected
  local original_is_connected
  local original_connect
  local original_sync_folder

  before_each(function()
    config.setup({
      remote_watcher = {
        reconnect_max_delay_ms = 50,
        reconnect_max_attempts = 3,
      },
    })
    remote_watcher.stop()
    remote_watcher._watchers = {}
    original_exec_streaming = ssh.exec_streaming
    original_ensure_connected = ssh.ensure_connected
    original_is_connected = ssh.is_connected
    original_connect = ssh.connect
    original_sync_folder = transfer.sync_folder
    -- Default: catch-up sync is a no-op so tests don't try to shell out
    transfer.sync_folder = function(_, _, _, cb)
      vim.schedule(function() cb(nil) end)
    end
  end)

  after_each(function()
    remote_watcher.stop()
    ssh.exec_streaming = original_exec_streaming
    ssh.ensure_connected = original_ensure_connected
    ssh.is_connected = original_is_connected
    ssh.connect = original_connect
    transfer.sync_folder = original_sync_folder
  end)

  local function project_info()
    return {
      host = "h",
      remote_path = "/r",
      local_path = "/tmp/nvim-client-render-test",
      name = "test",
    }
  end

  describe("get_state", function()
    it("returns 'stopped' for unknown sessions", function()
      assert.are.equal("stopped", remote_watcher.get_state("/no/such/path"))
    end)

    it("returns 'running' after a successful start", function()
      ssh.exec_streaming = function(_, _, _, _)
        return 42
      end

      remote_watcher.start(project_info())
      assert.are.equal("running", remote_watcher.get_state("/tmp/nvim-client-render-test"))
    end)

    it("returns 'stopped' after stop()", function()
      ssh.exec_streaming = function(_, _, _, _)
        return 42
      end
      remote_watcher.start(project_info())
      remote_watcher.stop("/tmp/nvim-client-render-test")
      assert.are.equal("stopped", remote_watcher.get_state("/tmp/nvim-client-render-test"))
    end)
  end)

  describe("reconnect flow", function()
    it("calls ensure_connected then restarts on watcher exit", function()
      local ensure_calls = 0
      local start_calls = 0
      local captured_on_exit

      ssh.exec_streaming = function(_, _, _, on_exit)
        start_calls = start_calls + 1
        captured_on_exit = on_exit
        return 1000 + start_calls
      end

      ssh.ensure_connected = function(_, cb)
        ensure_calls = ensure_calls + 1
        vim.schedule(function() cb(nil) end)
      end

      remote_watcher.start(project_info())
      assert.are.equal(1, start_calls)
      assert.are.equal("running", remote_watcher.get_state("/tmp/nvim-client-render-test"))

      -- Simulate the watcher process dying
      vim.schedule(function() captured_on_exit(1, { "boom" }) end)
      vim.wait(200, function() return start_calls >= 2 end)

      assert.are.equal(1, ensure_calls)
      assert.are.equal(2, start_calls)
      assert.are.equal("running", remote_watcher.get_state("/tmp/nvim-client-render-test"))
    end)

    it("triggers catch-up sync after successful reattach", function()
      local sync_calls = 0
      transfer.sync_folder = function(_, _, _, cb)
        sync_calls = sync_calls + 1
        vim.schedule(function() cb(nil) end)
      end

      local captured_on_exit
      ssh.exec_streaming = function(_, _, _, on_exit)
        captured_on_exit = on_exit
        return 1
      end
      ssh.ensure_connected = function(_, cb)
        vim.schedule(function() cb(nil) end)
      end

      remote_watcher.start(project_info())
      assert.are.equal(0, sync_calls)  -- no sync on initial start

      vim.schedule(function() captured_on_exit(1, {}) end)
      vim.wait(200, function() return sync_calls >= 1 end)
      assert.are.equal(1, sync_calls)
    end)

    it("transitions to 'failed' after exhausting attempts", function()
      local captured_on_exit
      ssh.exec_streaming = function(_, _, _, on_exit)
        captured_on_exit = on_exit
        return 1
      end
      ssh.ensure_connected = function(_, cb)
        vim.schedule(function() cb("nope") end)
      end

      remote_watcher.start(project_info())

      -- First failure: schedules retry, ensure_connected fails => recurses on_exit
      -- After reconnect_max_attempts (3) recursions, state goes 'failed'.
      vim.schedule(function() captured_on_exit(1, {}) end)

      vim.wait(2000, function()
        return remote_watcher.get_state("/tmp/nvim-client-render-test") == "failed"
      end)
      assert.are.equal("failed", remote_watcher.get_state("/tmp/nvim-client-render-test"))
    end)

    it("does not reconnect after explicit stop", function()
      local start_calls = 0
      local captured_on_exit
      ssh.exec_streaming = function(_, _, _, on_exit)
        start_calls = start_calls + 1
        captured_on_exit = on_exit
        return 1
      end
      ssh.ensure_connected = function(_, cb)
        vim.schedule(function() cb(nil) end)
      end

      remote_watcher.start(project_info())
      remote_watcher.stop("/tmp/nvim-client-render-test")
      -- on_exit fires after stop() removed the entry
      captured_on_exit(0, {})
      vim.wait(150)

      assert.are.equal(1, start_calls)
      assert.are.equal("stopped", remote_watcher.get_state("/tmp/nvim-client-render-test"))
    end)
  end)
end)

describe("ssh.ensure_connected", function()
  local original_is_connected
  local original_connect

  before_each(function()
    config.setup()
    original_is_connected = ssh.is_connected
    original_connect = ssh.connect
    ssh._connections = {}
  end)

  after_each(function()
    ssh.is_connected = original_is_connected
    ssh.connect = original_connect
    ssh._connections = {}
  end)

  it("short-circuits when an entry exists and is live", function()
    ssh._connections["h"] = { host_id = "h", parsed = { host = "h", raw = "h" }, socket = "/x", transport = "ssh" }
    ssh.is_connected = function() return true end
    local connect_called = false
    ssh.connect = function(_, cb)
      connect_called = true
      vim.schedule(function() cb(nil) end)
    end

    local err = "unset"
    ssh.ensure_connected("h", function(e) err = e end)
    vim.wait(100, function() return err ~= "unset" end)

    assert.is_nil(err)
    assert.is_false(connect_called)
  end)

  it("clears stale entry then reconnects when check fails", function()
    ssh._connections["h"] = { host_id = "h", parsed = { host = "h", raw = "h" }, socket = "/x", transport = "ssh" }
    ssh.is_connected = function() return false end
    local cleared_before_connect = false
    ssh.connect = function(host_string, cb)
      cleared_before_connect = ssh._connections["h"] == nil
      ssh._connections["h"] = { host_id = "h", parsed = { host = "h", raw = "h" }, socket = "/x", transport = "ssh" }
      vim.schedule(function() cb(nil) end)
    end

    local err = "unset"
    ssh.ensure_connected("h", function(e) err = e end)
    vim.wait(200, function() return err ~= "unset" end)

    assert.is_true(cleared_before_connect)
    assert.is_nil(err)
  end)

  it("calls connect when there is no entry at all", function()
    ssh.is_connected = function() return false end
    local connect_called = false
    ssh.connect = function(_, cb)
      connect_called = true
      vim.schedule(function() cb(nil) end)
    end

    local err = "unset"
    ssh.ensure_connected("brand-new", function(e) err = e end)
    vim.wait(100, function() return err ~= "unset" end)

    assert.is_true(connect_called)
    assert.is_nil(err)
  end)
end)
