local package_tree = assert(
  os.getenv("MONGODB_PACKAGE_TREE"),
  "MONGODB_PACKAGE_TREE is required"
)
local module_path = assert(package.searchpath("mongodb", package.path))

assert(module_path:sub(1, #package_tree) == package_tree)
assert(not module_path:find("/src/", 1, true))

local mongodb = require("mongodb")
local bson = mongodb.bson
local document = bson.document({
  { "name", "Ada" },
  { "count", bson.int64(2) },
})
local decoded = assert(bson.decode(assert(bson.encode(document))))

assert(mongodb._VERSION == "0.7.0")
assert(decoded:get("name") == "Ada")
assert(decoded:get("count"):to_number() == 2)

local model = mongodb.bulk.insert_one(document)
local index = mongodb.index_model(bson.document({ { "name", 1 } }))

assert(model.kind == "insert")
assert(index.name == "name_1")

local client, client_err = mongodb.client("http://localhost")

assert(client == nil)
assert(client_err.category == mongodb.error.CATEGORY.CONFIGURATION)

local capabilities = mongodb.runtime.required_capabilities()

assert(type(capabilities) == "table")
assert(mongodb.run(function()
  return "runtime-ok"
end) == "runtime-ok")

print("installed mongodb public API smoke passed")
