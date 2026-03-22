-- Minimal init for running tests headlessly
-- Usage: nvim --headless -u tests/minimal_init.lua -c "PlenaryBustedDirectory tests/ {minimal_init = 'tests/minimal_init.lua'}"

local plenary_path = vim.fn.stdpath("data") .. "/lazy/plenary.nvim"
if vim.fn.isdirectory(plenary_path) == 0 then
  plenary_path = vim.fn.stdpath("data") .. "/site/pack/vendor/start/plenary.nvim"
end
if vim.fn.isdirectory(plenary_path) == 0 then
  -- Try common plugin manager paths
  local candidates = {
    vim.fn.stdpath("data") .. "/plugged/plenary.nvim",
    vim.fn.expand("~/.local/share/nvim/site/pack/packer/start/plenary.nvim"),
    vim.fn.expand("~/.local/share/nvim/site/pack/deps/start/plenary.nvim"),
  }
  for _, p in ipairs(candidates) do
    if vim.fn.isdirectory(p) == 1 then
      plenary_path = p
      break
    end
  end
end

vim.opt.rtp:prepend(plenary_path)
vim.opt.rtp:prepend(vim.fn.getcwd())

vim.cmd("runtime plugin/plenary.vim")
