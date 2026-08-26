local package_tree = assert(
  os.getenv("MONGODB_PACKAGE_TREE"),
  "MONGODB_PACKAGE_TREE is required"
)

assert(#arg > 0, "at least one packaged module is required")

for _, name in ipairs(arg) do
  local module_path = assert(package.searchpath(name, package.path))

  assert(module_path:sub(1, #package_tree) == package_tree, name)
  assert(type(require(name)) == "table", name)
end

print("installed mongodb package completeness passed")
