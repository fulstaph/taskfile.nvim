# taskfile.nvim

Run [Task](https://taskfile.dev/) tasks from Neovim with a Snacks picker, terminal output, and inline task markers.

## Requirements

- Neovim 0.10 or newer
- The `task` CLI on `PATH`
- [snacks.nvim](https://github.com/folke/snacks.nvim) for the picker and terminal

## Installation

With lazy.nvim:

```lua
{
  "fulstaph/taskfile.nvim",
  lazy = false,
  dependencies = { "folke/snacks.nvim" },
  opts = {},
  keys = {
    { "<leader>Tr", function() require("taskfile").pick(false, false) end, desc = "Run Task" },
    { "<leader>Ta", function() require("taskfile").pick(true, false) end, desc = "Run Task (all)" },
    { "<leader>Td", function() require("taskfile").pick(false, true) end, desc = "Dry-run Task" },
    { "<leader>Tl", function() require("taskfile").rerun() end, desc = "Rerun Last Task" },
    { "<leader>Te", function() require("taskfile").edit() end, desc = "Edit Taskfile" },
    { "<leader>Tc", function() require("taskfile").run_cursor() end, desc = "Run Task at Cursor" },
  },
}
```

Without lazy.nvim, add the plugin and Snacks to your runtime path and call `require("taskfile").setup()`.

## Behavior

Task discovery starts in the current buffer's directory, or Neovim's working directory for unnamed buffers. Task handles finding the nearest Taskfile. Each run opens its own terminal; rerun repeats the last task that was executed without `--dry`.

The plugin marks tasks in `Taskfile.yml`, `Taskfile.yaml`, `taskfile.yml`, and `taskfile.yaml` after reading or saving. Tasks with descriptions get a filled arrow; undocumented tasks get an outline arrow.

Save the Taskfile before using **Run Task at Cursor**. Edits invalidate cached positions, and asynchronous results are accepted only for the saved buffer snapshot that requested them. This prevents an old task position from selecting another task after edits. The picker and terminal execute the Taskfile on disk.

Task listings use `task --list --json` or `task --list-all --json`; Task may evaluate dynamic variables while listing. Task runs execute the commands defined in your Taskfile.

## Development

```sh
nvim --clean --headless -i NONE -l tests/run.lua
nvim --clean --headless -i NONE -l tests/lifecycle.lua
stylua --check lua tests
```

The regression tests cover argument boundaries, task selection after edits, out-of-order responses, invalid locations, failed listings, and buffer lifecycle changes.

With the Task CLI installed, also run the integration test:

```sh
nvim --clean --headless -i NONE -l tests/task-cli.lua
```

## License

MIT
