-- Auto-loaded when the plugin is on the runtimepath (e.g. installed via a
-- plugin manager into pack/*/start). Creates the :GitMonitor command so it
-- works even without calling setup(). setup() is only needed to set a keymap,
-- a custom root, or the highlight colour.
if vim.g.loaded_gitmonitor then
  return
end
vim.g.loaded_gitmonitor = true

vim.api.nvim_create_user_command("GitMonitor", function()
  require("gitmonitor").open()
end, { desc = "Multi-repo git monitor" })
