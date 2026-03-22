local config = require("nvim-client-render.config")
local git = require("nvim-client-render.git")
local ssh = require("nvim-client-render.ssh")

describe("git", function()
  local original_exec
  local original_get_ssh_args

  before_each(function()
    config.setup()
    git._state = nil
    original_exec = ssh.exec
    original_get_ssh_args = ssh.get_ssh_args
  end)

  after_each(function()
    ssh.exec = original_exec
    ssh.get_ssh_args = original_get_ssh_args
    pcall(git.teardown)
  end)

  describe("shell_quote", function()
    it("quotes simple strings", function()
      assert.are.equal("'hello'", git._shell_quote("hello"))
    end)

    it("escapes single quotes", function()
      assert.are.equal("'it'\\''s'", git._shell_quote("it's"))
    end)

    it("handles empty string", function()
      assert.are.equal("''", git._shell_quote(""))
    end)

    it("handles spaces", function()
      assert.are.equal("'hello world'", git._shell_quote("hello world"))
    end)

    it("handles multiple single quotes", function()
      assert.are.equal("'a'\\''b'\\''c'", git._shell_quote("a'b'c"))
    end)

    it("handles paths", function()
      assert.are.equal("'/home/user/my project'", git._shell_quote("/home/user/my project"))
    end)

    it("handles special shell chars", function()
      assert.are.equal("'$HOME'", git._shell_quote("$HOME"))
    end)
  end)

  describe("detect", function()
    it("returns true for git repos with standard .git dir", function()
      ssh.exec = function(_, cmd, cb)
        if cmd:match("git rev%-parse") then
          vim.schedule(function() cb(0, { ".git" }, {}) end)
        end
      end

      local result, result_dir
      git.detect({ host = "myhost", remote_path = "/project" }, function(is_git, remote_git_dir)
        result = is_git
        result_dir = remote_git_dir
      end)

      vim.wait(1000, function() return result ~= nil end)
      assert.is_true(result)
      assert.are.equal("/project/.git", result_dir)
    end)

    it("returns true for worktrees with absolute git dir", function()
      ssh.exec = function(_, cmd, cb)
        if cmd:match("git rev%-parse") then
          vim.schedule(function() cb(0, { "/srv/repo.git/worktrees/feat1" }, {}) end)
        end
      end

      local result, result_dir
      git.detect({ host = "myhost", remote_path = "/srv/worktrees/feat1" }, function(is_git, remote_git_dir)
        result = is_git
        result_dir = remote_git_dir
      end)

      vim.wait(1000, function() return result ~= nil end)
      assert.is_true(result)
      assert.are.equal("/srv/repo.git/worktrees/feat1", result_dir)
    end)

    it("returns false for non-git dirs", function()
      ssh.exec = function(_, _, cb)
        vim.schedule(function() cb(1, {}, {}) end)
      end

      local result
      git.detect({ host = "myhost", remote_path = "/project" }, function(is_git)
        result = is_git
      end)

      vim.wait(1000, function() return result ~= nil end)
      assert.is_false(result)
    end)

    it("returns false when git is disabled", function()
      config.values.git.enabled = false

      local result
      git.detect({ host = "myhost", remote_path = "/project" }, function(is_git)
        result = is_git
      end)

      vim.wait(1000, function() return result ~= nil end)
      assert.is_false(result)
    end)
  end)

  describe("create_shim", function()
    it("creates required directories", function()
      local tmpdir = vim.fn.tempname()
      vim.fn.mkdir(tmpdir, "p")

      git._state = {
        project_info = {
          host = "myhost",
          remote_path = "/project",
          local_path = tmpdir,
          name = "project",
        },
      }

      -- Mock sync_metadata to succeed without SSH
      local orig_sync = git.sync_metadata
      git.sync_metadata = function(cb)
        local git_dir = git._state.git_dir
        vim.fn.writefile({ "ref: refs/heads/main" }, git_dir .. "/HEAD")
        vim.schedule(function() cb(nil) end)
      end

      local done = false
      local err
      git.create_shim(git._state.project_info, function(e)
        err = e
        done = true
      end)

      vim.wait(1000, function() return done end)

      assert.is_nil(err)
      assert.are.equal(1, vim.fn.isdirectory(tmpdir .. "/.git/refs/heads"))
      assert.are.equal(1, vim.fn.isdirectory(tmpdir .. "/.git/refs/remotes"))
      assert.are.equal(1, vim.fn.isdirectory(tmpdir .. "/.git/refs/tags"))
      assert.are.equal(1, vim.fn.isdirectory(tmpdir .. "/.git/objects"))

      git.sync_metadata = orig_sync
      vim.fn.delete(tmpdir, "rf")
    end)
  end)

  describe("create_wrapper", function()
    it("generates wrapper script", function()
      local tmpdir = vim.fn.tempname()
      vim.fn.mkdir(tmpdir, "p")

      ssh.get_ssh_args = function()
        return { "-S", "/tmp/test_ssh_socket", "-o", "ConnectTimeout=10" },
          { host = "myhost", user = "user" }
      end

      git._state = {
        project_info = {
          host = "user@myhost",
          remote_path = "/home/user/project",
          local_path = tmpdir,
          name = "project",
        },
        git_dir = tmpdir .. "/.git",
      }

      local wrapper_path = git.create_wrapper(git._state.project_info)

      assert.are.equal(1, vim.fn.filereadable(wrapper_path))

      local content = table.concat(vim.fn.readfile(wrapper_path), "\n")
      -- Verify key parts of the wrapper
      assert.truthy(content:find("#!/bin/sh"), "missing shebang")
      assert.truthy(content:find("LOCAL_ROOT="), "missing LOCAL_ROOT")
      assert.truthy(content:find("REMOTE_ROOT="), "missing REMOTE_ROOT")
      assert.truthy(content:find("is_remote=false"), "missing detection logic")
      assert.truthy(content:find('exec "$REAL_GIT"'), "missing fallback to real git")
      assert.truthy(content:find("REMOTE_GIT_DIR="), "missing REMOTE_GIT_DIR")
      assert.truthy(content:find("sq()"), "missing sq function")
      assert.truthy(content:find("rewritten="), "missing arg rewriting")
      assert.truthy(content:find("GIT_EDITOR"), "missing editor handling")

      vim.fn.delete(wrapper_path)
      vim.fn.delete(tmpdir, "rf")
    end)

    it("includes correct paths in wrapper", function()
      local tmpdir = vim.fn.tempname()
      vim.fn.mkdir(tmpdir, "p")

      ssh.get_ssh_args = function()
        return { "-S", "/tmp/test_ssh_socket" }, { host = "example.com" }
      end

      git._state = {
        project_info = {
          host = "example.com",
          remote_path = "/srv/myapp",
          local_path = tmpdir,
          name = "myapp",
        },
        git_dir = tmpdir .. "/.git",
      }

      local wrapper_path = git.create_wrapper(git._state.project_info)
      local content = table.concat(vim.fn.readfile(wrapper_path), "\n")

      assert.truthy(content:find("/srv/myapp"), "remote path not found in wrapper")
      assert.truthy(content:find("example.com"), "host not found in wrapper")

      vim.fn.delete(wrapper_path)
      vim.fn.delete(tmpdir, "rf")
    end)
  end)

  describe("configure_fugitive", function()
    it("sets g:fugitive_git_executable", function()
      git._state = {
        project_info = {
          host = "myhost",
          remote_path = "/project",
          local_path = "/tmp/test",
          name = "project",
        },
        git_dir = "/tmp/test/.git",
      }

      git.configure_fugitive("/path/to/wrapper.sh")
      assert.are.equal("/path/to/wrapper.sh", vim.g.fugitive_git_executable)

      -- Clean up
      pcall(vim.api.nvim_del_var, "fugitive_git_executable")
    end)

    it("saves previous fugitive_git_executable", function()
      vim.g.fugitive_git_executable = "original_git"

      git._state = {
        project_info = {
          host = "myhost",
          remote_path = "/project",
          local_path = "/tmp/test",
          name = "project",
        },
        git_dir = "/tmp/test/.git",
      }

      git.configure_fugitive("/path/to/wrapper.sh")
      assert.are.equal("original_git", git._state.prev_fugitive_executable)

      -- Clean up
      pcall(vim.api.nvim_del_var, "fugitive_git_executable")
    end)
  end)

  describe("teardown", function()
    it("restores previous fugitive_git_executable", function()
      vim.g.fugitive_git_executable = "test_wrapper"

      git._state = {
        project_info = { host = "h", remote_path = "/p", local_path = "/l", name = "n" },
        wrapper_path = "/nonexistent/wrapper.sh",
        git_dir = "/tmp/test/.git",
        prev_fugitive_executable = "original_git",
      }

      git.teardown()

      assert.are.equal("original_git", vim.g.fugitive_git_executable)
      assert.is_nil(git._state)

      -- Clean up
      pcall(vim.api.nvim_del_var, "fugitive_git_executable")
    end)

    it("removes fugitive_git_executable when no previous value", function()
      vim.g.fugitive_git_executable = "test_wrapper"

      git._state = {
        project_info = { host = "h", remote_path = "/p", local_path = "/l", name = "n" },
        wrapper_path = "/nonexistent/wrapper.sh",
        git_dir = "/tmp/test/.git",
      }

      git.teardown()
      -- Variable should be removed
      local ok, val = pcall(vim.api.nvim_get_var, "fugitive_git_executable")
      assert.is_false(ok)
      assert.is_nil(git._state)
    end)

    it("is safe to call multiple times", function()
      git._state = nil
      assert.has_no.errors(function() git.teardown() end)
      assert.has_no.errors(function() git.teardown() end)
    end)
  end)

  describe("on_fugitive_changed", function()
    it("is safe when no state", function()
      git._state = nil
      assert.has_no.errors(function() git.on_fugitive_changed() end)
    end)
  end)

  describe("exec", function()
    it("runs git command on remote", function()
      ssh.exec = function(host, cmd, cb)
        assert.truthy(cmd:match("git status"))
        vim.schedule(function() cb(0, { "On branch main" }, {}) end)
      end

      git._state = {
        project_info = {
          host = "myhost",
          remote_path = "/project",
          local_path = "/tmp/test",
          name = "project",
        },
        git_dir = "/tmp/test/.git",
      }

      local done = false
      local result_code
      local result_stdout
      git.exec("status", function(code, stdout, stderr)
        result_code = code
        result_stdout = stdout
        done = true
      end)

      vim.wait(1000, function() return done end)
      assert.are.equal(0, result_code)
      assert.are.equal("On branch main", result_stdout[1])
    end)

    it("returns error when not initialized", function()
      git._state = nil

      local done = false
      local result_code
      git.exec("status", function(code)
        result_code = code
        done = true
      end)

      vim.wait(1000, function() return done end)
      assert.are.equal(1, result_code)
    end)
  end)
end)
