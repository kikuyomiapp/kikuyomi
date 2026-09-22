/*
 * @Description:
 * @Author: ekibun
 * @Date: 2020-09-06 18:32:45
 * @LastEditors: ekibun
 * @LastEditTime: 2020-12-02 11:11:42
 */
#include "ffi.h"
#include <atomic>
#include <chrono>
#include <functional>
#include <future>
#include <string.h>

extern "C"
{

  DLLEXPORT JSValue *jsThrow(JSContext *ctx, JSValue *obj)
  {
    return new JSValue(JS_Throw(ctx, JS_DupValue(ctx, *obj)));
  }

  DLLEXPORT JSValue *jsEXCEPTION()
  {
    return new JSValue(JS_EXCEPTION);
  }

  DLLEXPORT JSValue *jsUNDEFINED()
  {
    return new JSValue(JS_UNDEFINED);
  }

  DLLEXPORT JSValue *jsNULL()
  {
    return new JSValue(JS_NULL);
  }

  // Why the interrupt handler last stopped a script. The host reads it with
  // jsTakeInterruptReason, because QuickJS reports every interrupt as the same
  // "InternalError: interrupted" and the host has to tell a deadline from a cancellation.
  enum JSInterruptReason {
    JSInterruptReason_NONE = 0,
    JSInterruptReason_TIMEOUT = 1,  // the per-entry timeout jsNewRuntime was given
    JSInterruptReason_DEADLINE = 2, // the deadline the host armed for one call
    JSInterruptReason_CANCEL = 3,   // the host asked for the running script to stop
  };

  struct RuntimeOpaque {
      JSChannel * channel;
      // The per-entry timeout, restarted on every entry from Dart into QuickJS. It bounds each
      // stretch between host calls rather than a whole call, which is why `deadline` exists; it
      // stays for callers that pass `timeout` to jsNewRuntime and never arm a deadline.
      int64_t timeout;
      int64_t start;
      // The host's deadline for one call, as an absolute point on the same clock as js_now_ms(),
      // or 0 for none. While it is armed it replaces the per-entry timeout entirely and no entry
      // from Dart restarts it, so a script that calls host functions in a loop is still stopped.
      // Atomic because the host may arm, disarm or cancel from another thread while the script
      // runs: that is the only way to stop a script that never returns to its isolate's loop.
      std::atomic<int64_t> deadline;
      std::atomic<int> cancelled;
      std::atomic<int> reason;
  };

  JSModuleDef *js_module_loader(
      JSContext *ctx,
      const char *module_name, void *opaque)
  {
    const char *str = (char *)((RuntimeOpaque *)opaque)->channel(ctx, JSChannelType_MODULE, (void *)module_name);
    if (str == 0)
      return NULL;
    JSValue func_val = JS_Eval(ctx, str, strlen(str), module_name, JS_EVAL_TYPE_MODULE | JS_EVAL_FLAG_COMPILE_ONLY);
    if (JS_IsException(func_val))
      return NULL;
    /* the module is already referenced, so we must free it */
    JSModuleDef *m = (JSModuleDef *)JS_VALUE_GET_PTR(func_val);
    JS_FreeValue(ctx, func_val);
    return m;
  }

  JSValue js_channel(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv, int magic, JSValue *func_data)
  {
    JSRuntime *rt = JS_GetRuntime(ctx);
    RuntimeOpaque *opaque = (RuntimeOpaque *)JS_GetRuntimeOpaque(rt);
    void *data[4];
    data[0] = &this_val;
    data[1] = &argc;
    data[2] = argv;
    data[3] = func_data;
    return *(JSValue *)opaque->channel(ctx, JSChannelType_METHON, data);
  }

  void js_promise_rejection_tracker(JSContext *ctx, JSValueConst promise,
                                    JSValueConst reason,
                                    JS_BOOL is_handled, void *opaque)
  {
    if (is_handled)
      return;
    ((RuntimeOpaque *)opaque)->channel(ctx, JSChannelType_PROMISE_TRACK, &reason);
  }

  // Milliseconds on a monotonic wall clock, which the timeout is measured against. Upstream used
  // clock(), which is wall time in the Windows CRT but CPU time for the whole process on POSIX,
  // Android included, so there the deadline ignored time a script spent blocked and was drained
  // by every other thread in the process. Never 0, which RuntimeOpaque::start reserves for "no
  // call in progress".
  static int64_t js_now_ms()
  {
    int64_t now = std::chrono::duration_cast<std::chrono::milliseconds>(
                      std::chrono::steady_clock::now().time_since_epoch())
                      .count();
    return now > 0 ? now : 1;
  }

  int js_interrupt_handler(JSRuntime * rt, void * opaque) {
    RuntimeOpaque *op = (RuntimeOpaque *)opaque;
    if (op->cancelled.exchange(0)) {
      op->deadline.store(0);
      op->start = 0;
      op->reason.store(JSInterruptReason_CANCEL);
      return 1;
    }
    const int64_t deadline = op->deadline.load();
    if (deadline) {
      if (js_now_ms() > deadline) {
        op->deadline.store(0);
        op->start = 0;
        op->reason.store(JSInterruptReason_DEADLINE);
        return 1;
      }
      return 0;
    }
    if(op->timeout && op->start && (js_now_ms() - op->start) > op->timeout) {
      op->start = 0;
      op->reason.store(JSInterruptReason_TIMEOUT);
      return 1;
    }
    return 0;
  }

  // Arms a deadline `timeout_ms` from now for the call that is about to run, or clears it when
  // `timeout_ms` is 0 or less. Unlike the per-entry timeout, nothing but the host clears it, so
  // entering QuickJS again — a host call's string argument, a promise job, a nested jsCall — does
  // not give the script another full timeout.
  DLLEXPORT void jsArmDeadline(JSRuntime *rt, int64_t timeout_ms)
  {
    RuntimeOpaque *op = (RuntimeOpaque *)JS_GetRuntimeOpaque(rt);
    if (!op)
      return;
    op->cancelled.store(0);
    op->reason.store(JSInterruptReason_NONE);
    op->deadline.store(timeout_ms > 0 ? js_now_ms() + timeout_ms : 0);
    op->start = 0;
  }

  // Asks for whatever is running in this runtime to stop at the next interrupt check. Safe to call
  // from another thread, and from a host function called by the script itself.
  DLLEXPORT void jsCancel(JSRuntime *rt)
  {
    RuntimeOpaque *op = (RuntimeOpaque *)JS_GetRuntimeOpaque(rt);
    if (op)
      op->cancelled.store(1);
  }

  // Why the last interrupt fired, cleared as it is read. QuickJS reports every interrupt as
  // "InternalError: interrupted", so without this the host cannot tell a deadline from a
  // cancellation, and both from a script that threw that error itself.
  DLLEXPORT int32_t jsTakeInterruptReason(JSRuntime *rt)
  {
    RuntimeOpaque *op = (RuntimeOpaque *)JS_GetRuntimeOpaque(rt);
    return op ? op->reason.exchange(JSInterruptReason_NONE) : JSInterruptReason_NONE;
  }

  DLLEXPORT JSRuntime *jsNewRuntime(JSChannel channel, int64_t timeout)
  {
    JSRuntime *rt = JS_NewRuntime();
    RuntimeOpaque *opaque = new RuntimeOpaque();
    opaque->channel = channel;
    opaque->timeout = timeout;
    opaque->start = 0;
    opaque->deadline.store(0);
    opaque->cancelled.store(0);
    opaque->reason.store(JSInterruptReason_NONE);
    JS_SetRuntimeOpaque(rt, opaque);
    JS_SetHostPromiseRejectionTracker(rt, js_promise_rejection_tracker, opaque);
    JS_SetModuleLoaderFunc(rt, nullptr, js_module_loader, opaque);
    JS_SetInterruptHandler(rt, js_interrupt_handler, opaque);
    return rt;
  }

  DLLEXPORT uint32_t jsNewClass(JSContext *ctx, const char *name)
  {
    JSClassID QJSClassId = 0;
    JS_NewClassID(&QJSClassId);
    JSRuntime *rt = JS_GetRuntime(ctx);
    if (!JS_IsRegisteredClass(rt, QJSClassId))
    {
      JSClassDef def{
          name,
          // destructor
          [](JSRuntime *rt, JSValue obj) noexcept
          {
            JSClassID classid = JS_GetClassID(obj);
            void *opaque = JS_GetOpaque(obj, classid);
            RuntimeOpaque *runtimeOpaque = (RuntimeOpaque *)JS_GetRuntimeOpaque(rt);
            if (runtimeOpaque == nullptr)
              return;
            runtimeOpaque->channel((JSContext *)rt, JSChannelType_FREE_OBJECT, opaque);
          }};
      int e = JS_NewClass(rt, QJSClassId, &def);
      if (e < 0)
      {
        JS_ThrowInternalError(ctx, "Cant register class %s", name);
        return 0;
      }
    }
    return QJSClassId;
  }

  DLLEXPORT void *jsGetObjectOpaque(JSValue *obj, uint32_t classid)
  {
    return JS_GetOpaque(*obj, classid);
  }

  DLLEXPORT JSValue *jsNewObjectClass(JSContext *ctx, uint32_t QJSClassId, void *opaque)
  {
    auto jsobj = new JSValue(JS_NewObjectClass(ctx, QJSClassId));
    if (JS_IsException(*jsobj))
      return jsobj;
    JS_SetOpaque(*jsobj, opaque);
    return jsobj;
  }

  DLLEXPORT void jsSetMaxStackSize(JSRuntime *rt, size_t stack_size)
  {
    JS_SetMaxStackSize(rt, stack_size);
  }

  DLLEXPORT void jsSetMemoryLimit(JSRuntime *rt, size_t limit)
  {
    JS_SetMemoryLimit(rt, limit);
  }

  DLLEXPORT void jsFreeRuntime(JSRuntime *rt)
  {
    RuntimeOpaque *opauqe = (RuntimeOpaque *)JS_GetRuntimeOpaque(rt);
    if (opauqe)
      delete opauqe;
    JS_SetRuntimeOpaque(rt, nullptr);
    JS_FreeRuntime(rt);
  }

  DLLEXPORT JSValue *jsNewCFunction(JSContext *ctx, JSValue *funcData)
  {
    return new JSValue(JS_NewCFunctionData(ctx, js_channel, 0, 0, 1, funcData));
  }

  DLLEXPORT JSContext *jsNewContext(JSRuntime *rt)
  {
    JS_UpdateStackTop(rt);
    JSContext *ctx = JS_NewContext(rt);
    return ctx;
  }

  DLLEXPORT void jsFreeContext(JSContext *ctx)
  {
    JS_FreeContext(ctx);
  }

  DLLEXPORT JSRuntime *jsGetRuntime(JSContext *ctx)
  {
    return JS_GetRuntime(ctx);
  }

  // Runs on every entry from Dart into QuickJS: an evaluation, a call, a promise job, and
  // converting a string for Dart. It restarts the per-entry timeout, which is why a script calling
  // a host function in a loop was never interrupted. A deadline armed by the host is left alone,
  // so it bounds the whole call however many times the script crosses back into the host.
  void js_begin_call(JSRuntime *rt) {
    JS_UpdateStackTop(rt);
    RuntimeOpaque * opaque = (RuntimeOpaque *)JS_GetRuntimeOpaque(rt);
    if(opaque && !opaque->deadline.load()) opaque->start = js_now_ms();
  }

  DLLEXPORT JSValue *jsEval(JSContext *ctx, const char *input, size_t input_len, const char *filename, int32_t eval_flags)
  {
    JSRuntime *rt = JS_GetRuntime(ctx);
    js_begin_call(rt);
    JSValue *ret = new JSValue(JS_Eval(ctx, input, input_len, filename, eval_flags));
    return ret;
  }

  DLLEXPORT int32_t jsValueGetTag(JSValue *val)
  {
    return JS_VALUE_GET_TAG(*val);
  }

  DLLEXPORT void *jsValueGetPtr(JSValue *val)
  {
    return JS_VALUE_GET_PTR(*val);
  }

  DLLEXPORT int32_t jsTagIsFloat64(int32_t tag)
  {
    return JS_TAG_IS_FLOAT64(tag);
  }

  DLLEXPORT JSValue *jsNewBool(JSContext *ctx, int32_t val)
  {
    return new JSValue(JS_NewBool(ctx, val));
  }

  DLLEXPORT JSValue *jsNewInt64(JSContext *ctx, int64_t val)
  {
    return new JSValue(JS_NewInt64(ctx, val));
  }

  DLLEXPORT JSValue *jsNewFloat64(JSContext *ctx, double val)
  {
    return new JSValue(JS_NewFloat64(ctx, val));
  }

  DLLEXPORT JSValue *jsNewString(JSContext *ctx, const char *str)
  {
    return new JSValue(JS_NewString(ctx, str));
  }

  DLLEXPORT JSValue *jsNewArrayBufferCopy(JSContext *ctx, const uint8_t *buf, size_t len)
  {
    return new JSValue(JS_NewArrayBufferCopy(ctx, buf, len));
  }

  DLLEXPORT JSValue *jsNewArray(JSContext *ctx)
  {
    return new JSValue(JS_NewArray(ctx));
  }

  DLLEXPORT JSValue *jsNewObject(JSContext *ctx)
  {
    return new JSValue(JS_NewObject(ctx));
  }

  DLLEXPORT void jsFreeValue(JSContext *ctx, JSValue *v, int32_t free)
  {
    JS_FreeValue(ctx, *v);
    if (free)
      delete v;
  }

  DLLEXPORT void jsFreeValueRT(JSRuntime *rt, JSValue *v, int32_t free)
  {
    JS_FreeValueRT(rt, *v);
    if (free)
      delete v;
  }

  DLLEXPORT JSValue *jsDupValue(JSContext *ctx, JSValueConst *v)
  {
    return new JSValue(JS_DupValue(ctx, *v));
  }

  DLLEXPORT JSValue *jsDupValueRT(JSRuntime *rt, JSValue *v)
  {
    return new JSValue(JS_DupValueRT(rt, *v));
  }

  DLLEXPORT int32_t jsToBool(JSContext *ctx, JSValueConst *val)
  {
    return JS_ToBool(ctx, *val);
  }

  DLLEXPORT int64_t jsToInt64(JSContext *ctx, JSValueConst *val)
  {
    int64_t p;
    JS_ToInt64(ctx, &p, *val);
    return p;
  }

  DLLEXPORT double jsToFloat64(JSContext *ctx, JSValueConst *val)
  {
    double p;
    JS_ToFloat64(ctx, &p, *val);
    return p;
  }

  DLLEXPORT const char *jsToCString(JSContext *ctx, JSValueConst *val)
  {
    JSRuntime *rt = JS_GetRuntime(ctx);
    js_begin_call(rt);
    const char *ret = JS_ToCString(ctx, *val);
    return ret;
  }

  DLLEXPORT void jsFreeCString(JSContext *ctx, const char *ptr)
  {
    return JS_FreeCString(ctx, ptr);
  }

  DLLEXPORT uint8_t *jsGetArrayBuffer(JSContext *ctx, size_t *psize, JSValueConst *obj)
  {
    return JS_GetArrayBuffer(ctx, psize, *obj);
  }

  DLLEXPORT int32_t jsIsFunction(JSContext *ctx, JSValueConst *val)
  {
    return JS_IsFunction(ctx, *val);
  }

  DLLEXPORT int32_t jsIsPromise(JSContext *ctx, JSValueConst *val)
  {
    return JS_IsPromise(ctx, *val);
  }

  DLLEXPORT int32_t jsIsArray(JSContext *ctx, JSValueConst *val)
  {
    return JS_IsArray(ctx, *val);
  }

  DLLEXPORT int32_t jsIsError(JSContext *ctx, JSValueConst *val)
  {
    return JS_IsError(ctx, *val);
  }

  DLLEXPORT JSValue *jsNewError(JSContext *ctx)
  {
    return new JSValue(JS_NewError(ctx));
  }

  DLLEXPORT JSValue *jsGetProperty(JSContext *ctx, JSValueConst *this_obj,
                                   JSAtom prop)
  {
    return new JSValue(JS_GetProperty(ctx, *this_obj, prop));
  }

  DLLEXPORT int32_t jsDefinePropertyValue(JSContext *ctx, JSValueConst *this_obj,
                                          JSAtom prop, JSValue *val, int32_t flags)
  {
    return JS_DefinePropertyValue(ctx, *this_obj, prop, *val, flags);
  }

  DLLEXPORT void jsFreeAtom(JSContext *ctx, JSAtom v)
  {
    JS_FreeAtom(ctx, v);
  }

  DLLEXPORT JSAtom jsValueToAtom(JSContext *ctx, JSValueConst *val)
  {
    return JS_ValueToAtom(ctx, *val);
  }

  DLLEXPORT JSValue *jsAtomToValue(JSContext *ctx, JSAtom val)
  {
    return new JSValue(JS_AtomToValue(ctx, val));
  }

  DLLEXPORT int32_t jsGetOwnPropertyNames(JSContext *ctx, JSPropertyEnum **ptab,
                                          uint32_t *plen, JSValueConst *obj, int32_t flags)
  {
    return JS_GetOwnPropertyNames(ctx, ptab, plen, *obj, flags);
  }

  DLLEXPORT JSAtom jsPropertyEnumGetAtom(JSPropertyEnum *ptab, int32_t i)
  {
    return ptab[i].atom;
  }

  DLLEXPORT uint32_t sizeOfJSValue()
  {
    return sizeof(JSValue);
  }

  DLLEXPORT void setJSValueList(JSValue *list, uint32_t i, JSValue *val)
  {
    list[i] = *val;
  }

  DLLEXPORT JSValue *jsCall(JSContext *ctx, JSValueConst *func_obj, JSValueConst *this_obj,
                            int32_t argc, JSValueConst *argv)
  {
    JSRuntime *rt = JS_GetRuntime(ctx);
    js_begin_call(rt);
    JSValue *ret = new JSValue(JS_Call(ctx, *func_obj, *this_obj, argc, argv));
    return ret;
  }

  DLLEXPORT int32_t jsIsException(JSValueConst *val)
  {
    return JS_IsException(*val);
  }

  DLLEXPORT JSValue *jsGetException(JSContext *ctx)
  {
    return new JSValue(JS_GetException(ctx));
  }

  DLLEXPORT int32_t jsExecutePendingJob(JSRuntime *rt)
  {
    js_begin_call(rt);
    JSContext *ctx;
    int ret = JS_ExecutePendingJob(rt, &ctx);
    return ret;
  }

  DLLEXPORT JSValue *jsNewPromiseCapability(JSContext *ctx, JSValue *resolving_funcs)
  {
    return new JSValue(JS_NewPromiseCapability(ctx, resolving_funcs));
  }

  DLLEXPORT void jsFree(JSContext *ctx, void *ptab)
  {
    js_free(ctx, ptab);
  }
}