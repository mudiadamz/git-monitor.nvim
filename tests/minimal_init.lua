-- Minimal init to load the plugin for headless tests.
-- Run from the repo root: nvim --headless -u tests/minimal_init.lua ...
-- (the runner scripts cd to the repo root first).
vim.opt.runtimepath:append(vim.fn.getcwd())
require("gitmonitor").setup({})
