local errors = require("mongodb.error")
local options = require("mongodb.config.options")
local uri = require("mongodb.config.uri")

describe("driver option normalization", function()
  it("shares validation across URI and programmatic options with explicit precedence", function()
    local parsed = assert(uri.parse(
      "mongodb://localhost/?retryReads=false&readPreference=secondary&w=majority"
    ))
    local config = assert(options.normalize(parsed.options, {
      read_concern = { level = "majority" },
      read_preference = {
        max_staleness_seconds = 120,
        mode = "secondary_preferred",
        tag_sets = { { region = "east" } },
      },
      retry_reads = true,
      server_api = { strict = true, version = "1" },
      write_concern = { journal = true, w = 2, w_timeout_ms = 500 },
    }))

    assert.is_true(config.retry_reads)
    assert.are.equal("majority", config.read_concern.level)
    assert.are.equal("secondary_preferred", config.read_preference.mode)
    assert.are.equal("east", config.read_preference.tag_sets[1].region)
    assert.are.equal(2, config.write_concern.w)
    assert.is_true(config.write_concern.journal)
    assert.are.equal(500, config.write_concern.w_timeout_ms)
    assert.are.equal("1", config.server_api.version)
    assert.is_true(config.server_api.strict)

    assert.has_error(function()
      config.retry_reads = false
    end, "driver options are immutable")
    assert.has_error(function()
      config.read_preference.tag_sets[1].region = "west"
    end, "driver options are immutable")
  end)

  it("returns structured configuration errors for unsupported options", function()
    local config, err = options.normalize(nil, { unsupported = true })

    assert.is_nil(config)
    assert.is_true(errors.is(err, errors.CATEGORY.CONFIGURATION))
  end)

  it("rejects application names over 128 bytes as configuration errors", function()
    local config, err = options.normalize(nil, {
      app_name = string.rep("a", 129),
    })

    assert.is_nil(config)
    assert.is_true(errors.is(err, errors.CATEGORY.CONFIGURATION))
    assert.are.equal("app_name", err.details.option)
  end)

  it("applies the same type and range rules to URI strings and Lua values", function()
    local parsed = assert(uri.parse("mongodb://localhost/?maxPoolSize=-1"))
    local from_uri, uri_err, uri_warnings = options.normalize(parsed.options)
    local from_table, table_err = options.normalize(nil, { max_pool_size = -1 })

    assert.is_table(from_uri)
    assert.is_nil(uri_err)
    assert.are.equal(1, #uri_warnings)
    assert.are.equal(100, from_uri.max_pool_size)
    assert.is_nil(from_table)
    assert.is_true(errors.is(table_err, errors.CATEGORY.CONFIGURATION))

    parsed = assert(uri.parse(
      "mongodb://localhost/?readPreference=nearest"
        .. "&readPreferenceTags=region:east&readPreferenceTags="
        .. "&maxStalenessSeconds=120&readConcernLevel=snapshot"
    ))
    local config = assert(options.normalize(parsed.options))

    assert.are.equal("nearest", config.read_preference.mode)
    assert.are.equal("east", config.read_preference.tag_sets[1].region)
    assert.are.equal(0, #config.read_preference.tag_sets[2])
    assert.are.equal(120, config.read_preference.max_staleness_seconds)
    assert.are.equal("snapshot", config.read_concern.level)
  end)

  it("preserves zero as an explicit unbounded connect timeout", function()
    local parsed = assert(uri.parse(
      "mongodb://localhost/?connectTimeoutMS=0"
    ))
    local from_uri = assert(options.normalize(parsed.options))
    local from_table = assert(options.normalize(nil, {
      connect_timeout_ms = 0,
    }))

    assert.are.equal(0, from_uri.connect_timeout_ms)
    assert.are.equal(0, from_table.connect_timeout_ms)
    assert.are.equal(10000, assert(options.normalize()).connect_timeout_ms)
  end)

  it("normalizes the required single-threaded URI option", function()
    local parsed = assert(uri.parse(
      "mongodb://localhost/?serverSelectionTryOnce=false"
    ))
    local config, err, warnings = options.normalize(parsed.options)

    assert.is_nil(err)
    assert.are.same({}, warnings)
    assert.is_false(config.server_selection_try_once)
  end)

  it("normalizes SRV-only client options and the implicit TLS default", function()
    local parsed = assert(uri.parse(
      "mongodb+srv://cluster.example.com/?srvMaxHosts=2&loadBalanced=false"
    ))
    local config = assert(options.normalize(parsed.options, {
      srv_service_name = "custom-service",
    }, parsed))

    assert.is_true(config.tls)
    assert.is_false(config.load_balanced)
    assert.are.equal(2, config.srv_max_hosts)
    assert.are.equal("custom-service", config.srv_service_name)
    assert.is_true(options.validate_uri(parsed, config))

    local direct = assert(options.normalize(nil, { direct_connection = true }, parsed))
    local valid, direct_err = options.validate_uri(parsed, direct)

    assert.is_nil(valid)
    assert.is_true(errors.is(direct_err, errors.CATEGORY.CONFIGURATION))

    local standard = assert(uri.parse("mongodb://localhost"))
    local standard_config = assert(options.normalize(nil, { srv_max_hosts = 0 }, standard))
    local standard_valid, standard_err = options.validate_uri(standard, standard_config)

    assert.is_nil(standard_valid)
    assert.is_true(errors.is(standard_err, errors.CATEGORY.CONFIGURATION))

    local invalid, invalid_err = options.normalize(nil, {
      srv_service_name = "-invalid",
    }, parsed)

    assert.is_nil(invalid)
    assert.is_true(errors.is(invalid_err, errors.CATEGORY.CONFIGURATION))
  end)

  it("ignores invalid URI options with warnings while keeping programmatic input strict", function()
    local cases = {
      "foo=bar",
      "fsync=ifPossible",
      "replicaSet=test&replicaSet=test",
      "wtimeout=5&wtimeoutMS=10",
      "maxIdleTimeMS=",
      "journal=",
      "authMechanism=MONGODB-OIDC"
        .. "&authMechanismProperties=TOKEN_RESOURCE:mongodb://host1%2Chost2,ENVIRONMENT:azure",
    }

    for _, query in ipairs(cases) do
      local parsed = assert(uri.parse("mongodb://localhost/?" .. query))
      local config, err, warnings = options.normalize(parsed.options)

      assert.is_table(config)
      assert.is_nil(err)
      assert.is_true(#warnings > 0)
    end
  end)

  it("rejects invalid concern, preference, Stable API, and TLS combinations", function()
    local invalid = {
      { read_preference = { mode = "primary", tag_sets = { { region = "east" } } } },
      { read_preference = { max_staleness_seconds = 89, mode = "secondary" } },
      { server_api = { strict = true } },
      { write_concern = { journal = true, w = 0 } },
    }

    for _, values in ipairs(invalid) do
      local config, err = options.normalize(nil, values)

      assert.is_nil(config)
      assert.is_true(errors.is(err, errors.CATEGORY.CONFIGURATION))
    end

    local parsed = assert(uri.parse(
      "mongodb://localhost/?tlsInsecure=false&tlsAllowInvalidHostnames=false"
    ))
    local config, err = options.normalize(parsed.options)

    assert.is_nil(config)
    assert.is_true(errors.is(err, errors.CATEGORY.CONFIGURATION))
  end)
end)
