/*
 * @Description: quickjs engine
 * @Author: ekibun
 * @Date: 2020-08-08 08:29:09
 * @LastEditors: ekibun
 * @LastEditTime: 2020-10-06 23:47:13
 */
part of '../flutter_qjs.dart';

/// Handler function to manage js module.
typedef _JsModuleHandler = String Function(String name);

/// Handler to manage unhandled promise rejection.
typedef _JsHostPromiseRejectionHandler = void Function(dynamic reason);

/// Quickjs engine for flutter.
class FlutterQjs {
  Pointer<JSRuntime>? _rt;
  Pointer<JSContext>? _ctx;

  /// Max stack size for quickjs.
  final int? stackSize;

  /// Max stack size for quickjs.
  final int? timeout;

  /// Max memory for quickjs.
  final int? memoryLimit;

  /// Message Port for event loop. Close it to stop dispatching event loop.
  ReceivePort port = ReceivePort();

  /// Handler function to manage js module.
  final _JsModuleHandler? moduleHandler;

  /// Handler function to manage js module.
  final _JsHostPromiseRejectionHandler? hostPromiseRejectionHandler;

  FlutterQjs({
    this.moduleHandler,
    this.stackSize,
    this.timeout,
    this.memoryLimit,
    this.hostPromiseRejectionHandler,
  });

  _ensureEngine() {
    if (_rt != null) return;
    final rt = jsNewRuntime((ctx, type, ptr) {
      try {
        switch (type) {
          case JSChannelType.METHON:
            final pdata = ptr.cast<Pointer<JSValue>>();
            final argc = pdata.elementAt(1).value.cast<Int32>().value;
            final pargs = [];
            for (var i = 0; i < argc; ++i) {
              pargs.add(_jsToDart(
                ctx,
                Pointer.fromAddress(
                  pdata.elementAt(2).value.address + sizeOfJSValue * i,
                ),
              ));
            }
            final JSInvokable func = _jsToDart(
              ctx,
              pdata.elementAt(3).value,
            );
            return _dartToJs(
                ctx,
                func.invoke(
                  pargs,
                  _jsToDart(ctx, pdata.elementAt(0).value),
                ));
          case JSChannelType.MODULE:
            if (moduleHandler == null) throw JSError('No ModuleHandler');
            final ret = moduleHandler!(
              ptr.cast<Utf8>().toDartString(),
            ).toNativeUtf8();
            Future.microtask(() {
              malloc.free(ret);
            });
            return ret.cast();
          case JSChannelType.PROMISE_TRACK:
            final err = _parseJSException(ctx, ptr);
            if (hostPromiseRejectionHandler != null) {
              hostPromiseRejectionHandler!(err);
            } else {
              print('unhandled promise rejection: $err');
            }
            return nullptr;
          case JSChannelType.FREE_OBJECT:
            final rt = ctx.cast<JSRuntime>();
            _DartObject.fromAddress(rt, ptr.address)?.free();
            return nullptr;
        }
        throw JSError('call channel with wrong type');
      } catch (e) {
        if (type == JSChannelType.FREE_OBJECT) {
          print('DartObject release error: $e');
          return nullptr;
        }
        if (type == JSChannelType.MODULE) {
          print('host Promise Rejection Handler error: $e');
          return nullptr;
        }
        final throwObj = _dartToJs(ctx, e);
        final err = jsThrow(ctx, throwObj);
        jsFreeValue(ctx, throwObj);
        if (type == JSChannelType.MODULE) {
          jsFreeValue(ctx, err);
          return nullptr;
        }
        return err;
      }
    }, timeout ?? 0, port);
    final stackSize = this.stackSize ?? 0;
    if (stackSize > 0) jsSetMaxStackSize(rt, stackSize);
    final memoryLimit = this.memoryLimit ?? 0;
    if (memoryLimit > 0) jsSetMemoryLimit(rt, memoryLimit);
    _rt = rt;
    _ctx = jsNewContext(rt);
  }

  /// Kikuyomi addition. Arms a deadline of [limit] for the call about to run.
  ///
  /// The [timeout] given to the constructor is restarted on every entry from Dart into QuickJS,
  /// including converting a string argument of a host call, so it bounds each stretch between host
  /// calls rather than a whole call: `while (true) host('x')` runs forever under it. A deadline
  /// armed here is the host's, and nothing but the host clears it, so it bounds everything the
  /// call does — the evaluation, the host calls it makes, and the promise jobs it queues — until
  /// [disarmDeadline] is called or another deadline is armed.
  ///
  /// The runtime stays usable after the deadline fires, as it does after any interrupt.
  void armDeadline(Duration limit) {
    _ensureEngine();
    jsArmDeadline(_rt!, limit.inMilliseconds);
  }

  /// Kikuyomi addition. Clears the deadline armed by [armDeadline], leaving the runtime idle.
  void disarmDeadline() {
    final rt = _rt;
    if (rt != null) jsArmDeadline(rt, 0);
  }

  /// Kikuyomi addition. Asks for whatever is running in this runtime to stop.
  ///
  /// The script is interrupted at the next check of the interrupt handler, as it is by a deadline.
  /// Call it from a host function the script itself called, or from another isolate through
  /// [cancelRuntimeAt]: while a script runs, the isolate that started it is inside QuickJS and
  /// reaches no message of its own.
  void cancel() {
    final rt = _rt;
    if (rt != null) jsCancel(rt);
  }

  /// Kikuyomi addition. The address of this engine's runtime, for [cancelRuntimeAt].
  ///
  /// Null until the runtime exists, which is on the first evaluation or the first [armDeadline].
  int? get runtimeAddress => _rt?.address;

  /// Kikuyomi addition. Cancels whatever is running in the runtime at [address], from any isolate.
  ///
  /// [address] is that runtime's [runtimeAddress]. The runtime must still be open: cancelling a
  /// runtime that has been closed writes to freed memory. Isolates of one group share the native
  /// library and its memory, and the flag this sets is atomic, so the write is safe while the
  /// runtime's own isolate is inside QuickJS.
  static void cancelRuntimeAt(int address) =>
      jsCancel(Pointer<JSRuntime>.fromAddress(address));

  /// Kikuyomi addition. Why the last interrupt fired, cleared as it is read.
  ///
  /// One of [JSInterruptReason]'s values. QuickJS reports every interrupt as
  /// `InternalError: interrupted`, so this is the only way to tell an armed deadline from a
  /// cancellation, and either from a script that threw that error itself.
  int takeInterruptReason() {
    final rt = _rt;
    return rt == null ? JSInterruptReason.NONE : jsTakeInterruptReason(rt);
  }

  /// Free Runtime and Context which can be recreate when evaluate again.
  close() {
    final rt = _rt;
    final ctx = _ctx;
    _rt = null;
    _ctx = null;
    if (ctx != null) jsFreeContext(ctx);
    if (rt == null) return;
    _executePendingJob();
    try {
      jsFreeRuntime(rt);
    } on String catch (e) {
      throw JSError(e);
    }
  }

  void _executePendingJob() {
    final rt = _rt;
    final ctx = _ctx;
    if (rt == null || ctx == null) return;
    while (true) {
      int err = jsExecutePendingJob(rt);
      if (err <= 0) {
        if (err < 0) print(_parseJSException(ctx));
        break;
      }
    }
  }

  /// Dispatch JavaScript Event loop.
  Future<void> dispatch() async {
    await for (final _ in port) {
      _executePendingJob();
    }
  }

  /// Evaluate js script.
  dynamic evaluate(
    String command, {
    String? name,
    int? evalFlags,
  }) {
    _ensureEngine();
    final ctx = _ctx!;
    final jsval = jsEval(
      ctx,
      command,
      name ?? '<eval>',
      evalFlags ?? JSEvalFlag.GLOBAL,
    );
    if (jsIsException(jsval) != 0) {
      jsFreeValue(ctx, jsval);
      throw _parseJSException(ctx);
    }
    final result = _jsToDart(ctx, jsval);
    jsFreeValue(ctx, jsval);
    return result;
  }
}
