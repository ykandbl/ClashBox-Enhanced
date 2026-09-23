#pragma once

#include <malloc.h>
#include <stddef.h>
#include <stdint.h>

#define TAG "FlClash"

typedef const char *c_string;

typedef void (*mark_socket_func)(int id, int fd);

// cgo
extern void mark_socket(void *interface, int id, int fd);

// ohos-napi v1.0.3's convenience TsFunc.Call creates napi_value objects on
// the calling Go goroutine and passes a pointer to stack storage through the
// asynchronous queue. Both violate N-API's thread/lifetime rules. These
// helpers enqueue plain C-owned data and only create JS values on ArkTS' event
// loop inside the thread-safe-function callback.
void *create_safe_string_tsfn(void *env, void *callback, const char *resource_name);
void *create_safe_int64_tsfn(void *env, void *callback, const char *resource_name);
int call_safe_string_tsfn(void *handle, const char *key, const char *value);
int call_safe_int64_tsfn(void *handle, int64_t key, int64_t value);
void release_safe_tsfn(void *handle);
