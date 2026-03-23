local config = require("nvim-client-render.config")
local project = require("nvim-client-render.project")

describe("project", function()
  before_each(function()
    config.setup()
    -- Reset active project and sessions
    project._active = nil
    project._sessions = {}
  end)

  -- Helper to set up a test session
  local function set_test_session(info)
    project._active = info
    project._sessions[info.local_path] = info
  end

  describe("path mapping", function()
    before_each(function()
      set_test_session({
        host = "user@myhost",
        remote_path = "/home/user/myproject",
        local_path = "/tmp/test-nvim-client-render/abc123/myproject",
        name = "myproject",
      })
    end)

    it("maps local path to remote path", function()
      local remote = project.local_to_remote("/tmp/test-nvim-client-render/abc123/myproject/src/main.py")
      assert.are.equal("/home/user/myproject/src/main.py", remote)
    end)

    it("maps local root to remote root", function()
      local remote = project.local_to_remote("/tmp/test-nvim-client-render/abc123/myproject")
      assert.are.equal("/home/user/myproject", remote)
    end)

    it("returns nil for paths outside project", function()
      local remote = project.local_to_remote("/tmp/other-dir/file.txt")
      assert.is_nil(remote)
    end)

    it("maps remote path to local path", function()
      local local_path = project.remote_to_local("/home/user/myproject/lib/utils.lua")
      assert.are.equal("/tmp/test-nvim-client-render/abc123/myproject/lib/utils.lua", local_path)
    end)

    it("returns nil for remote paths outside project", function()
      local local_path = project.remote_to_local("/home/user/other-project/file.txt")
      assert.is_nil(local_path)
    end)

    it("handles deeply nested paths", function()
      local remote = project.local_to_remote(
        "/tmp/test-nvim-client-render/abc123/myproject/a/b/c/d/e.txt"
      )
      assert.are.equal("/home/user/myproject/a/b/c/d/e.txt", remote)
    end)
  end)

  describe("is_project_file", function()
    before_each(function()
      set_test_session({
        host = "user@myhost",
        remote_path = "/home/user/myproject",
        local_path = "/tmp/test-nvim-client-render/abc123/myproject",
        name = "myproject",
      })
    end)

    it("returns true for files in project", function()
      assert.is_true(project.is_project_file("/tmp/test-nvim-client-render/abc123/myproject/src/main.py"))
    end)

    it("returns false for files outside project", function()
      assert.is_false(project.is_project_file("/tmp/other/file.txt"))
    end)

    it("returns false when no active project", function()
      project._active = nil
      project._sessions = {}
      assert.is_false(project.is_project_file("/any/path"))
    end)
  end)

  describe("get_active", function()
    it("returns nil when no project is active", function()
      assert.is_nil(project.get_active())
    end)

    it("returns project info when active", function()
      set_test_session({
        host = "myhost",
        remote_path = "/path",
        local_path = "/local",
        name = "proj",
      })
      local info = project.get_active()
      assert.are.equal("myhost", info.host)
      assert.are.equal("/path", info.remote_path)
    end)
  end)

  describe("get_for_path", function()
    it("returns session matching a file path", function()
      set_test_session({
        host = "myhost",
        remote_path = "/project",
        local_path = "/tmp/test-project",
        name = "project",
      })
      local info = project.get_for_path("/tmp/test-project/src/file.lua")
      assert.is_not_nil(info)
      assert.are.equal("myhost", info.host)
    end)

    it("returns nil for unmatched path", function()
      set_test_session({
        host = "myhost",
        remote_path = "/project",
        local_path = "/tmp/test-project",
        name = "project",
      })
      assert.is_nil(project.get_for_path("/tmp/other/file.lua"))
    end)

    it("returns correct session among multiple", function()
      local info_a = {
        host = "host-a",
        remote_path = "/project-a",
        local_path = "/tmp/proj-a",
        name = "proj-a",
      }
      local info_b = {
        host = "host-b",
        remote_path = "/project-b",
        local_path = "/tmp/proj-b",
        name = "proj-b",
      }
      project._sessions[info_a.local_path] = info_a
      project._sessions[info_b.local_path] = info_b
      project._active = info_a

      local result = project.get_for_path("/tmp/proj-b/src/file.lua")
      assert.is_not_nil(result)
      assert.are.equal("host-b", result.host)
    end)
  end)

  describe("get_all", function()
    it("returns empty table when no sessions", function()
      assert.are.same({}, project.get_all())
    end)

    it("returns all sessions", function()
      set_test_session({
        host = "myhost",
        remote_path = "/project",
        local_path = "/tmp/test-project",
        name = "project",
      })
      local all = project.get_all()
      assert.is_not_nil(all["/tmp/test-project"])
    end)
  end)
end)
