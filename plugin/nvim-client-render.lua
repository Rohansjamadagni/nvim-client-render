if vim.g.loaded_nvim_client_render then
  return
end
vim.g.loaded_nvim_client_render = true

require("nvim-client-render").setup()
