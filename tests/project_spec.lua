local config = require("nvim-client-render.config")
local project = require("nvim-client-render.project")

describe("project", function()
  before_each(function()
    config.setup()
    -- Reset active project
    project._active = nil
  end)

  describe("path mapping", function()
    before_each(function()
      -- Simulate an active project
      project._active = {
        host = "user@myhost",
        remote_path = "/home/user/myproject",
        local_path = "/tmp/test-nvim-client-render/abc123/myproject",
        name = "myproject",
      }
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
      project._active = {
        host = "user@myhost",
        remote_path = "/home/user/myproject",
        local_path = "/tmp/test-nvim-client-render/abc123/myproject",
        name = "myproject",
      }
    end)

    it("returns true for files in project", function()
      assert.is_true(project.is_project_file("/tmp/test-nvim-client-render/abc123/myproject/src/main.py"))
    end)

    it("returns false for files outside project", function()
      assert.is_false(project.is_project_file("/tmp/other/file.txt"))
    end)

    it("returns false when no active project", function()
      project._active = nil
      assert.is_false(project.is_project_file("/any/path"))
    end)
  end)

  describe("get_active", function()
    it("returns nil when no project is active", function()
      assert.is_nil(project.get_active())
    end)

    it("returns project info when active", function()
      project._active = {
        host = "myhost",
        remote_path = "/path",
        local_path = "/local",
        name = "proj",
      }
      local info = project.get_active()
      assert.are.equal("myhost", info.host)
      assert.are.equal("/path", info.remote_path)
    end)
  end)
end)
