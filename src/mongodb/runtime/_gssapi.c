#include <lauxlib.h>
#include <lua.h>

#include <dlfcn.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

typedef uint32_t OM_uint32;

struct gss_name_struct;
typedef struct gss_name_struct *gss_name_t;

struct gss_cred_id_struct;
typedef struct gss_cred_id_struct *gss_cred_id_t;

struct gss_ctx_id_struct;
typedef struct gss_ctx_id_struct *gss_ctx_id_t;

struct gss_channel_bindings_struct;
typedef struct gss_channel_bindings_struct *gss_channel_bindings_t;

typedef struct gss_oid_desc {
  OM_uint32 length;
  void *elements;
} gss_OID_desc, *gss_OID;

typedef struct gss_oid_set_desc {
  size_t count;
  gss_OID elements;
} gss_OID_set_desc, *gss_OID_set;

typedef struct gss_buffer_desc {
  size_t length;
  void *value;
} gss_buffer_desc, *gss_buffer_t;

typedef OM_uint32 gss_qop_t;
typedef int gss_cred_usage_t;

typedef OM_uint32 (*gss_import_name_fn)(
  OM_uint32 *, const gss_buffer_t, const gss_OID, gss_name_t *
);
typedef OM_uint32 (*gss_release_name_fn)(OM_uint32 *, gss_name_t *);
typedef OM_uint32 (*gss_init_sec_context_fn)(
  OM_uint32 *, const gss_cred_id_t, gss_ctx_id_t *, const gss_name_t,
  const gss_OID, OM_uint32, OM_uint32, const gss_channel_bindings_t,
  const gss_buffer_t, gss_OID *, gss_buffer_t, OM_uint32 *, OM_uint32 *
);
typedef OM_uint32 (*gss_delete_sec_context_fn)(
  OM_uint32 *, gss_ctx_id_t *, gss_buffer_t
);
typedef OM_uint32 (*gss_release_buffer_fn)(OM_uint32 *, gss_buffer_t);
typedef OM_uint32 (*gss_acquire_cred_with_password_fn)(
  OM_uint32 *, const gss_name_t, const gss_buffer_t, OM_uint32,
  const gss_OID_set, gss_cred_usage_t, gss_cred_id_t *, gss_OID_set *,
  OM_uint32 *
);
typedef OM_uint32 (*gss_release_cred_fn)(OM_uint32 *, gss_cred_id_t *);
typedef OM_uint32 (*gss_unwrap_fn)(
  OM_uint32 *, const gss_ctx_id_t, const gss_buffer_t, gss_buffer_t,
  int *, gss_qop_t *
);
typedef OM_uint32 (*gss_wrap_fn)(
  OM_uint32 *, const gss_ctx_id_t, int, gss_qop_t,
  const gss_buffer_t, int *, gss_buffer_t
);

typedef struct gssapi_api {
  void *library;
  gss_import_name_fn import_name;
  gss_release_name_fn release_name;
  gss_init_sec_context_fn init_sec_context;
  gss_delete_sec_context_fn delete_sec_context;
  gss_release_buffer_fn release_buffer;
  gss_acquire_cred_with_password_fn acquire_cred_with_password;
  gss_release_cred_fn release_cred;
  gss_unwrap_fn unwrap;
  gss_wrap_fn wrap;
  int available;
} gssapi_api;

typedef struct gssapi_context {
  gss_ctx_id_t context;
  gss_name_t target_name;
  gss_cred_id_t credential;
  int closed;
  int established;
} gssapi_context;

#define GSSAPI_CONTEXT_METATABLE "mongodb.runtime._gssapi.context"
#define GSS_C_INDEFINITE ((OM_uint32)0xffffffffU)
#define GSS_C_INITIATE 1
#define GSS_C_MUTUAL_FLAG 2U
#define GSS_S_CONTINUE_NEEDED 1U
#define GSS_CALLING_ERROR_MASK 0xff000000U
#define GSS_ROUTINE_ERROR_MASK 0x00ff0000U
#define GSS_ERROR(status) \
  (((status) & GSS_CALLING_ERROR_MASK) != 0U \
    || ((status) & GSS_ROUTINE_ERROR_MASK) != 0U)

static unsigned char hostbased_service_oid_bytes[] = {
  0x2a, 0x86, 0x48, 0x86, 0xf7, 0x12, 0x01, 0x02, 0x01, 0x04
};
static unsigned char user_name_oid_bytes[] = {
  0x2a, 0x86, 0x48, 0x86, 0xf7, 0x12, 0x01, 0x02, 0x01, 0x01
};
static gss_OID_desc hostbased_service_oid = {
  sizeof(hostbased_service_oid_bytes), hostbased_service_oid_bytes
};
static gss_OID_desc user_name_oid = {
  sizeof(user_name_oid_bytes), user_name_oid_bytes
};
static gssapi_api api;
static int api_initialized;

static const char *platform_name(void) {
#if defined(__APPLE__)
  return "macos";
#elif defined(__linux__)
  return "linux";
#else
  return "unsupported";
#endif
}

static void *open_gssapi_library(void) {
#if defined(__APPLE__)
  const char *candidates[] = {
    "/System/Library/Frameworks/GSS.framework/GSS",
    "libgssapi_krb5.dylib",
    NULL
  };
#elif defined(__linux__)
  const char *candidates[] = {
    "libgssapi_krb5.so.2",
    "libgssapi_krb5.so",
    "libgssapi.so.3",
    "libgssapi.so",
    NULL
  };
#else
  const char *candidates[] = { NULL };
#endif
  size_t index;

  for (index = 0; candidates[index] != NULL; index++) {
    void *library = dlopen(candidates[index], RTLD_LAZY | RTLD_LOCAL);

    if (library != NULL) {
      return library;
    }
  }

  return NULL;
}

static void load_symbol(void *library, const char *name, void *target, size_t size) {
  void *symbol = dlsym(library, name);

  memset(target, 0, size);

  if (symbol != NULL) {
    memcpy(target, &symbol, size < sizeof(symbol) ? size : sizeof(symbol));
  }
}

#define LOAD_SYMBOL(field, name) \
  load_symbol(api.library, (name), &api.field, sizeof(api.field))

static void load_api(void) {
  if (api_initialized) {
    return;
  }

  api_initialized = 1;
  memset(&api, 0, sizeof(api));
  api.library = open_gssapi_library();

  if (api.library == NULL) {
    return;
  }

  LOAD_SYMBOL(import_name, "gss_import_name");
  LOAD_SYMBOL(release_name, "gss_release_name");
  LOAD_SYMBOL(init_sec_context, "gss_init_sec_context");
  LOAD_SYMBOL(delete_sec_context, "gss_delete_sec_context");
  LOAD_SYMBOL(release_buffer, "gss_release_buffer");
  LOAD_SYMBOL(acquire_cred_with_password, "gss_acquire_cred_with_password");
  LOAD_SYMBOL(release_cred, "gss_release_cred");
  LOAD_SYMBOL(unwrap, "gss_unwrap");
  LOAD_SYMBOL(wrap, "gss_wrap");

  api.available = api.import_name != NULL
    && api.release_name != NULL
    && api.init_sec_context != NULL
    && api.delete_sec_context != NULL
    && api.release_buffer != NULL
    && api.release_cred != NULL
    && api.unwrap != NULL
    && api.wrap != NULL;

  if (!api.available) {
    dlclose(api.library);
    memset(&api, 0, sizeof(api));
  }
}

static int push_failure(lua_State *lua, const char *message) {
  lua_pushnil(lua);
  lua_pushstring(lua, message);
  return 2;
}

static int status_failed(OM_uint32 status) {
  return GSS_ERROR(status);
}

static void release_buffer(gss_buffer_desc *buffer) {
  OM_uint32 minor_status = 0;

  if (buffer->value != NULL || buffer->length != 0) {
    api.release_buffer(&minor_status, buffer);
    buffer->value = NULL;
    buffer->length = 0;
  }
}

static int close_native_context(gssapi_context *context) {
  OM_uint32 major_status;
  OM_uint32 minor_status = 0;
  int success = 1;

  if (context->closed) {
    return 1;
  }

  context->closed = 1;

  if (context->context != NULL) {
    gss_buffer_desc output = { 0, NULL };

    major_status = api.delete_sec_context(
      &minor_status, &context->context, &output
    );
    release_buffer(&output);

    if (status_failed(major_status)) {
      success = 0;
    }

    context->context = NULL;
  }

  if (context->target_name != NULL) {
    major_status = api.release_name(&minor_status, &context->target_name);

    if (status_failed(major_status)) {
      success = 0;
    }

    context->target_name = NULL;
  }

  if (context->credential != NULL) {
    major_status = api.release_cred(&minor_status, &context->credential);

    if (status_failed(major_status)) {
      success = 0;
    }

    context->credential = NULL;
  }

  return success;
}

static gssapi_context *check_context(lua_State *lua) {
  return (gssapi_context *)luaL_checkudata(
    lua, 1, GSSAPI_CONTEXT_METATABLE
  );
}

static int context_close(lua_State *lua) {
  gssapi_context *context = check_context(lua);

  if (!close_native_context(context)) {
    return push_failure(lua, "GSSAPI context cleanup failed");
  }

  lua_pushboolean(lua, 1);
  return 1;
}

static int context_gc(lua_State *lua) {
  gssapi_context *context = check_context(lua);

  close_native_context(context);
  return 0;
}

static int context_step(lua_State *lua) {
  gssapi_context *context = check_context(lua);
  size_t challenge_length;
  const char *challenge = luaL_checklstring(lua, 2, &challenge_length);
  gss_buffer_desc input;
  gss_buffer_desc output = { 0, NULL };
  gss_buffer_t input_pointer = NULL;
  OM_uint32 major_status;
  OM_uint32 minor_status = 0;

  if (context->closed) {
    return luaL_error(lua, "GSSAPI context is closed");
  }

  if (context->established) {
    return push_failure(lua, "GSSAPI context is already established");
  }

  if (challenge_length != 0) {
    input.length = challenge_length;
    input.value = (void *)challenge;
    input_pointer = &input;
  }

  major_status = api.init_sec_context(
    &minor_status,
    context->credential,
    &context->context,
    context->target_name,
    NULL,
    GSS_C_MUTUAL_FLAG,
    GSS_C_INDEFINITE,
    NULL,
    input_pointer,
    NULL,
    &output,
    NULL,
    NULL
  );

  if (status_failed(major_status)) {
    release_buffer(&output);
    return push_failure(lua, "GSSAPI token step failed");
  }

  context->established = (major_status & GSS_S_CONTINUE_NEEDED) == 0U;

  lua_createtable(lua, 0, 2);
  lua_pushlstring(lua, (const char *)output.value, output.length);
  lua_setfield(lua, -2, "token");
  lua_pushboolean(lua, context->established);
  lua_setfield(lua, -2, "complete");
  release_buffer(&output);
  return 1;
}

static int context_security_layer(lua_State *lua) {
  gssapi_context *context = check_context(lua);
  size_t challenge_length;
  size_t username_length;
  const char *challenge = luaL_checklstring(lua, 2, &challenge_length);
  const char *username = luaL_checklstring(lua, 3, &username_length);
  gss_buffer_desc input = { challenge_length, (void *)challenge };
  gss_buffer_desc unwrapped = { 0, NULL };
  gss_buffer_desc wrapped = { 0, NULL };
  gss_buffer_desc response;
  unsigned char *response_bytes;
  OM_uint32 major_status;
  OM_uint32 minor_status = 0;
  int confidentiality = 0;

  if (context->closed) {
    return luaL_error(lua, "GSSAPI context is closed");
  }

  if (!context->established) {
    return push_failure(lua, "GSSAPI context is not established");
  }

  major_status = api.unwrap(
    &minor_status,
    context->context,
    &input,
    &unwrapped,
    &confidentiality,
    NULL
  );

  if (status_failed(major_status)) {
    release_buffer(&unwrapped);
    return push_failure(lua, "GSSAPI security-layer unwrap failed");
  }

  if (unwrapped.length < 4
      || (((const unsigned char *)unwrapped.value)[0] & 1U) == 0U
      || username_length > SIZE_MAX - 4) {
    release_buffer(&unwrapped);
    return push_failure(lua, "GSSAPI server rejected the no-security layer");
  }

  release_buffer(&unwrapped);
  response.length = username_length + 4;
  response_bytes = (unsigned char *)malloc(response.length);

  if (response_bytes == NULL) {
    return push_failure(lua, "GSSAPI security-layer allocation failed");
  }

  response_bytes[0] = 1;
  response_bytes[1] = 0;
  response_bytes[2] = 0;
  response_bytes[3] = 0;
  memcpy(response_bytes + 4, username, username_length);
  response.value = response_bytes;

  major_status = api.wrap(
    &minor_status,
    context->context,
    0,
    0,
    &response,
    &confidentiality,
    &wrapped
  );
  free(response_bytes);

  if (status_failed(major_status) || confidentiality != 0) {
    release_buffer(&wrapped);
    return push_failure(lua, "GSSAPI security-layer wrap failed");
  }

  lua_pushlstring(lua, (const char *)wrapped.value, wrapped.length);
  release_buffer(&wrapped);
  return 1;
}

static int module_capabilities(lua_State *lua) {
  load_api();
  lua_createtable(lua, 0, 4);
  lua_pushboolean(lua, api.available);
  lua_setfield(lua, -2, "available");
  lua_pushboolean(lua, api.available);
  lua_setfield(lua, -2, "default_credentials");
  lua_pushboolean(lua, api.available && api.acquire_cred_with_password != NULL);
  lua_setfield(lua, -2, "password_credentials");
  lua_pushstring(lua, platform_name());
  lua_setfield(lua, -2, "platform");
  return 1;
}

static int module_create_context(lua_State *lua) {
  size_t service_length;
  size_t username_length;
  size_t password_length = 0;
  const char *service_principal;
  const char *username;
  const char *password = NULL;
  gssapi_context *context;
  gss_buffer_desc name_buffer;
  OM_uint32 major_status;
  OM_uint32 minor_status = 0;

  load_api();

  if (!api.available) {
    return push_failure(lua, "GSSAPI library is unavailable");
  }

  luaL_checktype(lua, 1, LUA_TTABLE);
  lua_getfield(lua, 1, "service_principal");
  service_principal = luaL_checklstring(lua, -1, &service_length);
  lua_pop(lua, 1);
  lua_getfield(lua, 1, "username");
  username = luaL_checklstring(lua, -1, &username_length);
  lua_pop(lua, 1);
  lua_getfield(lua, 1, "password");

  if (!lua_isnil(lua, -1)) {
    password = luaL_checklstring(lua, -1, &password_length);
  }

  lua_pop(lua, 1);

  if (service_length == 0 || username_length == 0
      || memchr(service_principal, '\0', service_length) != NULL
      || memchr(username, '\0', username_length) != NULL
      || (password != NULL && memchr(password, '\0', password_length) != NULL)) {
    return push_failure(lua, "GSSAPI context options are invalid");
  }

  context = (gssapi_context *)lua_newuserdatauv(lua, sizeof(*context), 0);
  memset(context, 0, sizeof(*context));
  luaL_setmetatable(lua, GSSAPI_CONTEXT_METATABLE);

  name_buffer.length = service_length;
  name_buffer.value = (void *)service_principal;
  major_status = api.import_name(
    &minor_status,
    &name_buffer,
    &hostbased_service_oid,
    &context->target_name
  );

  if (status_failed(major_status)) {
    close_native_context(context);
    return push_failure(lua, "GSSAPI service principal import failed");
  }

  if (password != NULL) {
    gss_name_t user_name = NULL;
    gss_buffer_desc password_buffer = { password_length, (void *)password };

    if (api.acquire_cred_with_password == NULL) {
      close_native_context(context);
      return push_failure(lua, "GSSAPI password credentials are unsupported");
    }

    name_buffer.length = username_length;
    name_buffer.value = (void *)username;
    major_status = api.import_name(
      &minor_status, &name_buffer, &user_name_oid, &user_name
    );

    if (!status_failed(major_status)) {
      major_status = api.acquire_cred_with_password(
        &minor_status,
        user_name,
        &password_buffer,
        GSS_C_INDEFINITE,
        NULL,
        GSS_C_INITIATE,
        &context->credential,
        NULL,
        NULL
      );
    }

    if (user_name != NULL) {
      api.release_name(&minor_status, &user_name);
    }

    if (status_failed(major_status)) {
      close_native_context(context);
      return push_failure(lua, "GSSAPI credential acquisition failed");
    }
  }

  return 1;
}

static const luaL_Reg context_methods[] = {
  { "close", context_close },
  { "security_layer", context_security_layer },
  { "step", context_step },
  { NULL, NULL }
};

static const luaL_Reg module_functions[] = {
  { "capabilities", module_capabilities },
  { "create_context", module_create_context },
  { NULL, NULL }
};

int luaopen_mongodb_runtime__gssapi(lua_State *lua) {
  luaL_newmetatable(lua, GSSAPI_CONTEXT_METATABLE);
  lua_pushcfunction(lua, context_gc);
  lua_setfield(lua, -2, "__gc");
  lua_newtable(lua);
  luaL_setfuncs(lua, context_methods, 0);
  lua_setfield(lua, -2, "__index");
  lua_pop(lua, 1);

  luaL_newlib(lua, module_functions);
  return 1;
}
