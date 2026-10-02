vim.opt.rtp:prepend(vim.fn.getcwd())
assert(vim.fn.executable("task") == 1, "Install the Task CLI before running this integration test")

local taskfile = require("taskfile")
local directory = vim.fn.tempname()
vim.fn.mkdir(directory, "p")
local path = directory .. "/Taskfile.yml"
vim.fn.writefile({
  "version: '3'",
  "tasks:",
  "  build:",
  "    desc: Build",
  "    cmds: [echo build]",
  "  deploy:",
  "    desc: Deploy",
  "    cmds: [echo deploy]",
}, path)

local calls = {}
package.loaded.snacks = {
  terminal = {
    open = function(argv)
      calls[#calls + 1] = argv
    end,
  },
}

local function wait_for_marks()
  -- Allow the scheduled read/write refresh to clear the preceding snapshot.
  local refreshed = false
  vim.schedule(function()
    refreshed = true
  end)
  assert(
    vim.wait(1000, function()
      return refreshed
    end, 10),
    "scheduled refresh did not run"
  )
  local namespace = vim.api.nvim_create_namespace("taskfile")
  assert(
    vim.wait(5000, function()
      return #vim.api.nvim_buf_get_extmarks(0, namespace, 0, -1, {}) == 2
    end, 10),
    "the Task CLI did not produce two markers"
  )
end

local ok, err = pcall(function()
  taskfile.setup()
  vim.cmd.edit(vim.fn.fnameescape(path))
  wait_for_marks()
  vim.api.nvim_win_set_cursor(0, { 3, 0 })
  taskfile.run_cursor()
  assert(calls[1][4] == "build")

  vim.api.nvim_buf_set_lines(0, 2, 2, false, { "", "" })
  vim.api.nvim_win_set_cursor(0, { 5, 0 })
  taskfile.run_cursor()
  assert(#calls == 1, "unsaved edits ran a task")
  vim.cmd.write()
  wait_for_marks()
  taskfile.run_cursor()
  assert(calls[2][4] == "build", "the saved cursor selected the wrong task")
end)

vim.fn.delete(directory, "rf")
if not ok then
  error(err)
end
print("PASS: real Task CLI discovery, edit guard, and refresh after save")
