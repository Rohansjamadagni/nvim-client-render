local config = require("nvim-client-render.config")
config.setup({})

describe("nvim-client-render.lsp", function()
  local lsp

  before_each(function()
    lsp = require("nvim-client-render.lsp")
    lsp._clients = {}
    lsp._discovered_configs = {}
  end)

  describe("deep_rewrite_uris", function()
    local rewrite = function(obj, transform)
      return lsp._deep_rewrite_uris(obj, transform)
    end

    local add_prefix = function(uri)
      return uri:gsub("file://", "file:///remote")
    end

    it("rewrites string values matching file:// in flat tables", function()
      local obj = { uri = "file:///home/user/file.lua", name = "test" }
      rewrite(obj, add_prefix)
      assert.equals("file:///remote/home/user/file.lua", obj.uri)
      assert.equals("test", obj.name)
    end)

    it("rewrites any key with a file:// value, not just 'uri'", function()
      local obj = {
        targetUri = "file:///a/b.lua",
        rootUri = "file:///c/d.lua",
        documentUri = "file:///e/f.lua",
        baseUri = "file:///g/h.lua",
        customField = "file:///i/j.lua",
      }
      rewrite(obj, add_prefix)
      assert.equals("file:///remote/a/b.lua", obj.targetUri)
      assert.equals("file:///remote/c/d.lua", obj.rootUri)
      assert.equals("file:///remote/e/f.lua", obj.documentUri)
      assert.equals("file:///remote/g/h.lua", obj.baseUri)
      assert.equals("file:///remote/i/j.lua", obj.customField)
    end)

    it("recurses into nested tables", function()
      local obj = {
        result = {
          location = {
            uri = "file:///deep/nested.lua",
          },
        },
      }
      rewrite(obj, add_prefix)
      assert.equals("file:///remote/deep/nested.lua", obj.result.location.uri)
    end)

    it("rewrites URIs in arrays", function()
      local obj = {
        { uri = "file:///a.lua" },
        { uri = "file:///b.lua" },
        { targetUri = "file:///c.lua" },
      }
      rewrite(obj, add_prefix)
      assert.equals("file:///remote/a.lua", obj[1].uri)
      assert.equals("file:///remote/b.lua", obj[2].uri)
      assert.equals("file:///remote/c.lua", obj[3].targetUri)
    end)

    it("does not modify non-file:// strings", function()
      local obj = { uri = "https://example.com", path = "/local/path" }
      rewrite(obj, add_prefix)
      assert.equals("https://example.com", obj.uri)
      assert.equals("/local/path", obj.path)
    end)

    it("handles nil and non-table values gracefully", function()
      assert.equals(nil, rewrite(nil, add_prefix))
      assert.equals("hello", rewrite("hello", add_prefix))
      assert.equals(42, rewrite(42, add_prefix))
    end)

    it("mutates in place", function()
      local obj = { uri = "file:///test.lua" }
      local result = rewrite(obj, add_prefix)
      assert.equals(obj, result) -- same reference
      assert.equals("file:///remote/test.lua", obj.uri)
    end)

    it("handles mixed URI types in nested structures", function()
      local obj = {
        changes = {
          ["file:///a.lua"] = { { newText = "hello" } },
        },
        documentChanges = {
          {
            textDocument = { uri = "file:///b.lua" },
            edits = { { range = {}, newText = "world" } },
          },
        },
      }
      rewrite(obj, add_prefix)
      -- Keys are not rewritten, only values
      assert.is_not_nil(obj.changes["file:///a.lua"])
      assert.equals("file:///remote/b.lua", obj.documentChanges[1].textDocument.uri)
    end)
  end)

  describe("capture_local_config", function()
    it("extracts config from a client with table cmd", function()
      local mock_client = {
        name = "lua_ls",
        config = {
          cmd = { "lua-language-server", "--stdio" },
          filetypes = { "lua" },
          settings = { Lua = { diagnostics = { globals = { "vim" } } } },
          init_options = { foo = "bar" },
        },
      }
      local result = lsp.capture_local_config(mock_client)
      assert.is_not_nil(result)
      assert.equals("lua_ls", result.name)
      assert.is_truthy(result.server_cmd:find("lua%-language%-server"))
      assert.is_truthy(result.server_cmd:find("stdio"))
      assert.same({ "lua" }, result.filetypes)
      assert.same({ Lua = { diagnostics = { globals = { "vim" } } } }, result.settings)
      assert.same({ foo = "bar" }, result.init_options)
    end)

    it("extracts config from a client with string cmd", function()
      local mock_client = {
        name = "pyright",
        config = {
          cmd = "pyright-langserver --stdio",
          filetypes = { "python" },
        },
      }
      local result = lsp.capture_local_config(mock_client)
      assert.is_not_nil(result)
      assert.equals("pyright-langserver --stdio", result.server_cmd)
      assert.equals("pyright", result.name)
    end)

    it("returns nil for client with no cmd", function()
      local mock_client = {
        name = "broken",
        config = {},
      }
      assert.is_nil(lsp.capture_local_config(mock_client))
    end)

    it("returns nil for client with function cmd", function()
      local mock_client = {
        name = "custom",
        config = {
          cmd = function() end,
        },
      }
      assert.is_nil(lsp.capture_local_config(mock_client))
    end)

    it("caches config in _discovered_configs", function()
      local mock_client = {
        name = "ts_ls",
        config = {
          cmd = { "typescript-language-server", "--stdio" },
          filetypes = { "typescript", "javascript" },
        },
      }
      lsp.capture_local_config(mock_client)
      assert.is_not_nil(lsp._discovered_configs["ts_ls"])
      assert.same({ "typescript", "javascript" }, lsp._discovered_configs["ts_ls"].filetypes)
    end)
  end)

  describe("find_client_by_name", function()
    it("returns nil when no clients exist", function()
      assert.is_nil(lsp.find_client_by_name("remote-lua"))
    end)
  end)

  describe("get_discovered_configs", function()
    it("returns the discovered configs table", function()
      lsp._discovered_configs["test"] = { server_cmd = "test-server", name = "test" }
      local configs = lsp.get_discovered_configs()
      assert.equals("test-server", configs["test"].server_cmd)
    end)
  end)

  describe("get_status", function()
    it("returns empty table when no clients", function()
      assert.same({}, lsp.get_status())
    end)
  end)
end)
