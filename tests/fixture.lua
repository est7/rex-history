-- Loads this checkout for `rex do`; does not touch the running config.
local root = debug.getinfo(1, "S").source:gsub("^@", ""):match("^(.*/)") .. "../"
dofile(root .. "init.lua").setup({ key = false })
