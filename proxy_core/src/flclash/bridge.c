#include "bridge.h"
#include <napi/native_api.h>
#include <stdlib.h>
#include <string.h>


void mark_socket(void *interface, int id, int fd) {
    mark_socket_func func = (mark_socket_func)(interface);
    func(id, fd);
}

typedef struct {
    char *key;
    char *value;
} safe_string_callback_data;

typedef struct {
    int64_t key;
    int64_t value;
} safe_int64_callback_data;

static void free_string_callback_data(safe_string_callback_data *data) {
    if (data == NULL) {
        return;
    }
    free(data->key);
    free(data->value);
    free(data);
}

static void safe_string_call_js(napi_env env, napi_value callback,
                                void *context, void *raw_data) {
    (void)context;
    safe_string_callback_data *data = (safe_string_callback_data *)raw_data;
    if (data == NULL) {
        return;
    }
    if (env != NULL && callback != NULL) {
        napi_value receiver = NULL;
        napi_value args[2] = {NULL, NULL};
        napi_status receiver_status = napi_get_undefined(env, &receiver);
        napi_status key_status = napi_create_string_utf8(
            env, data->key, NAPI_AUTO_LENGTH, &args[0]);
        napi_status value_status = napi_create_string_utf8(
            env, data->value, NAPI_AUTO_LENGTH, &args[1]);
        if (receiver_status == napi_ok && key_status == napi_ok &&
            value_status == napi_ok) {
            (void)napi_call_function(env, receiver, callback, 2, args, NULL);
        }
    }
    free_string_callback_data(data);
}

static void safe_int64_call_js(napi_env env, napi_value callback,
                               void *context, void *raw_data) {
    (void)context;
    safe_int64_callback_data *data = (safe_int64_callback_data *)raw_data;
    if (data == NULL) {
        return;
    }
    if (env != NULL && callback != NULL) {
        napi_value receiver = NULL;
        napi_value args[2] = {NULL, NULL};
        napi_status receiver_status = napi_get_undefined(env, &receiver);
        napi_status key_status = napi_create_int64(env, data->key, &args[0]);
        napi_status value_status = napi_create_int64(env, data->value, &args[1]);
        if (receiver_status == napi_ok && key_status == napi_ok &&
            value_status == napi_ok) {
            (void)napi_call_function(env, receiver, callback, 2, args, NULL);
        }
    }
    free(data);
}

static void *create_safe_tsfn(void *raw_env, void *raw_callback,
                              const char *resource_name,
                              napi_threadsafe_function_call_js call_js) {
    napi_env env = (napi_env)raw_env;
    napi_value callback = (napi_value)raw_callback;
    if (env == NULL || callback == NULL) {
        return NULL;
    }
    napi_value name = NULL;
    if (napi_create_string_utf8(env, resource_name, NAPI_AUTO_LENGTH, &name) !=
        napi_ok) {
        return NULL;
    }
    napi_threadsafe_function result = NULL;
    napi_status status = napi_create_threadsafe_function(
        env, callback, NULL, name, 0, 1, NULL, NULL, NULL, call_js, &result);
    return status == napi_ok ? (void *)result : NULL;
}

void *create_safe_string_tsfn(void *env, void *callback,
                              const char *resource_name) {
    return create_safe_tsfn(env, callback, resource_name, safe_string_call_js);
}

void *create_safe_int64_tsfn(void *env, void *callback,
                             const char *resource_name) {
    return create_safe_tsfn(env, callback, resource_name, safe_int64_call_js);
}

int call_safe_string_tsfn(void *handle, const char *key, const char *value) {
    if (handle == NULL || key == NULL || value == NULL) {
        return (int)napi_invalid_arg;
    }
    safe_string_callback_data *data =
        (safe_string_callback_data *)calloc(1, sizeof(*data));
    if (data == NULL) {
        return (int)napi_generic_failure;
    }
    data->key = strdup(key);
    data->value = strdup(value);
    if (data->key == NULL || data->value == NULL) {
        free_string_callback_data(data);
        return (int)napi_generic_failure;
    }
    napi_status status = napi_call_threadsafe_function(
        (napi_threadsafe_function)handle, data, napi_tsfn_nonblocking);
    if (status != napi_ok) {
        free_string_callback_data(data);
    }
    return (int)status;
}

int call_safe_int64_tsfn(void *handle, int64_t key, int64_t value) {
    if (handle == NULL) {
        return (int)napi_invalid_arg;
    }
    safe_int64_callback_data *data =
        (safe_int64_callback_data *)malloc(sizeof(*data));
    if (data == NULL) {
        return (int)napi_generic_failure;
    }
    data->key = key;
    data->value = value;
    napi_status status = napi_call_threadsafe_function(
        (napi_threadsafe_function)handle, data, napi_tsfn_nonblocking);
    if (status != napi_ok) {
        free(data);
    }
    return (int)status;
}

void release_safe_tsfn(void *handle) {
    if (handle != NULL) {
        (void)napi_release_threadsafe_function(
            (napi_threadsafe_function)handle, napi_tsfn_release);
    }
}
