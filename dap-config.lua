return {
  configurations = {
    zig = {
      {
        name = "Test Slide Deck",
        type = "lldb",
        request = "launch",
        cwd = "${workspaceFolder}",
        program = "${workspaceFolder}" .. "/zig-out/bin/slidey",
        args = { "-s", "test/deck/slides.txt" },
      },
    },
  },
  adapters = {
    -- List of adapter tables here
    -- The name of each table becomes the 'type' used in the config
    -- e.g.: lldb = { name = 'lldb', type = 'executable', command = '/path/to/lldb-vscode' }
  },
}
