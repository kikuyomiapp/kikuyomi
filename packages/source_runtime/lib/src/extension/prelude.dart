/// The JavaScript prelude that ships inside the app (§3.5).
///
/// "A small JavaScript prelude (polyfills such as `setTimeout`, `TextDecoder`, and `URL`, plus the
/// bridge shims) ships *inside the app*, so no part of the runtime environment itself is
/// downloaded." SourceAPI 1.0 lists exactly what it gives an extension: `setTimeout`,
/// `clearTimeout`, `TextEncoder`, `TextDecoder`, `URL`, `URLSearchParams`, `atob` and `btoa`, and
/// the `kikuyomi` object the host API is reached through. There is deliberately no global `fetch`.
///
/// QuickJS is a complete ES2020 engine and nothing more: it has classes, promises, typed arrays,
/// `encodeURIComponent` and `JSON`, and none of the things above, because none of them is in the
/// language. So this file is the whole environment an extension runs in, and it is written as
/// carefully as the Dart around it.
///
/// **Everything is reached through one host function.** The engine installs
/// `__kikuyomiHostCall(module, method, args)`; the prelude captures it, deletes the global, and
/// hands out only the shims, so an extension cannot call the dispatcher with arguments the shims
/// would not have produced. That is defence in depth rather than a boundary: every bridge validates
/// what it is given on the Dart side, where the real boundary is.
///
/// **What the host answers synchronously.** A host call returns a value or a promise, whichever the
/// Dart side returns. The contract makes `html`'s element methods synchronous and everything else a
/// promise, and that is exactly how the bridges are written.
library;

/// The prelude, as the runtime evaluates it before any extension code.
///
/// A raw string: `$` is literal, which JavaScript uses in identifiers and templates.
const kikuyomiPrelude = r'''
(function () {
  'use strict';

  // Taken once, so that an extension redefining a built-in later cannot change what the prelude
  // itself does.
  var hostCall = globalThis.__kikuyomiHostCall;
  delete globalThis.__kikuyomiHostCall;
  var info = globalThis.__kikuyomiHostInfo || {};
  delete globalThis.__kikuyomiHostInfo;

  var ObjectKeys = Object.keys;
  var ObjectFreeze = Object.freeze;
  var ArrayIsArray = Array.isArray;
  var StringFrom = String;
  var MathFloor = Math.floor;

  // A bridge that could not do what was asked answers with an error rather than throwing one, so
  // that the kind the contract names — Network for a site that could not be reached — survives the
  // crossing. Here it becomes an Error an extension can catch, with its kind on it.
  function hostFailure(data) {
    var error = new Error(StringFrom(data.message || ''));
    error.kind = data.kind;
    error.name = StringFrom(data.kind || 'Error');
    return error;
  }

  function unwrap(value) {
    if (value && typeof value === 'object' && value.__kikuyomiError) {
      throw hostFailure(value.__kikuyomiError);
    }
    return value;
  }

  function call(module, method, args) {
    var value = hostCall(module, method, args);
    if (value && typeof value.then === 'function') return value.then(unwrap);
    return unwrap(value);
  }

  // ------------------------------------------------------------------ text and bytes

  function bytesOf(value) {
    if (value instanceof Uint8Array) return value;
    if (value instanceof ArrayBuffer) return new Uint8Array(value);
    if (value && value.buffer instanceof ArrayBuffer) {
      return new Uint8Array(value.buffer, value.byteOffset, value.byteLength);
    }
    throw new TypeError('expected bytes');
  }

  function encodeUtf8(text) {
    var input = StringFrom(text);
    var out = [];
    for (var i = 0; i < input.length; i++) {
      var code = input.charCodeAt(i);
      if (code >= 0xd800 && code <= 0xdbff && i + 1 < input.length) {
        var low = input.charCodeAt(i + 1);
        if (low >= 0xdc00 && low <= 0xdfff) {
          code = 0x10000 + ((code - 0xd800) << 10) + (low - 0xdc00);
          i++;
        }
      }
      if (code < 0x80) {
        out.push(code);
      } else if (code < 0x800) {
        out.push(0xc0 | (code >> 6), 0x80 | (code & 0x3f));
      } else if (code < 0x10000) {
        // A lone surrogate is written as U+FFFD, as TextEncoder does: it is not text.
        if (code >= 0xd800 && code <= 0xdfff) code = 0xfffd;
        out.push(0xe0 | (code >> 12), 0x80 | ((code >> 6) & 0x3f), 0x80 | (code & 0x3f));
      } else {
        out.push(
          0xf0 | (code >> 18),
          0x80 | ((code >> 12) & 0x3f),
          0x80 | ((code >> 6) & 0x3f),
          0x80 | (code & 0x3f)
        );
      }
    }
    return new Uint8Array(out);
  }

  function decodeUtf8(value) {
    var bytes = bytesOf(value);
    var out = '';
    var i = 0;
    while (i < bytes.length) {
      var byte = bytes[i++];
      var code;
      var extra;
      if (byte < 0x80) {
        code = byte;
        extra = 0;
      } else if ((byte & 0xe0) === 0xc0) {
        code = byte & 0x1f;
        extra = 1;
      } else if ((byte & 0xf0) === 0xe0) {
        code = byte & 0x0f;
        extra = 2;
      } else if ((byte & 0xf8) === 0xf0) {
        code = byte & 0x07;
        extra = 3;
      } else {
        out += '\uFFFD';
        continue;
      }
      if (i + extra > bytes.length) {
        out += '\uFFFD';
        break;
      }
      var broken = false;
      for (var j = 0; j < extra; j++) {
        var next = bytes[i];
        if ((next & 0xc0) !== 0x80) {
          broken = true;
          break;
        }
        code = (code << 6) | (next & 0x3f);
        i++;
      }
      if (broken) {
        out += '\uFFFD';
        continue;
      }
      if (code > 0x10ffff || (code >= 0xd800 && code <= 0xdfff)) {
        out += '\uFFFD';
      } else if (code > 0xffff) {
        code -= 0x10000;
        out += String.fromCharCode(0xd800 + (code >> 10), 0xdc00 + (code & 0x3ff));
      } else {
        out += String.fromCharCode(code);
      }
    }
    return out;
  }

  function TextEncoder() {}
  TextEncoder.prototype.encoding = 'utf-8';
  TextEncoder.prototype.encode = function (input) {
    return encodeUtf8(input === undefined ? '' : input);
  };

  function TextDecoder(label) {
    var encoding = StringFrom(label === undefined ? 'utf-8' : label).toLowerCase();
    if (encoding !== 'utf-8' && encoding !== 'utf8' && encoding !== 'unicode-1-1-utf-8') {
      // Saying so beats decoding a page as something it is not. A site that is not UTF-8 is read
      // by the html bridge, which knows its own encodings.
      throw new RangeError('only utf-8 is supported, not "' + encoding + '"');
    }
    this.encoding = 'utf-8';
  }
  TextDecoder.prototype.decode = function (input) {
    if (input === undefined || input === null) return '';
    return decodeUtf8(input);
  };

  var BASE64 = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/';

  function btoa(input) {
    var text = StringFrom(input);
    var out = '';
    for (var i = 0; i < text.length; i += 3) {
      var a = text.charCodeAt(i);
      var b = i + 1 < text.length ? text.charCodeAt(i + 1) : NaN;
      var c = i + 2 < text.length ? text.charCodeAt(i + 2) : NaN;
      if (a > 0xff || b > 0xff || c > 0xff) {
        throw new Error('btoa takes characters below 256; encode text first');
      }
      out += BASE64[a >> 2];
      out += BASE64[((a & 3) << 4) | (b === b ? b >> 4 : 0)];
      out += b === b ? BASE64[((b & 15) << 2) | (c === c ? c >> 6 : 0)] : '=';
      out += c === c ? BASE64[c & 63] : '=';
    }
    return out;
  }

  function atob(input) {
    var text = StringFrom(input).replace(/[ \t\n\f\r]/g, '');
    if (text.length % 4 === 1) throw new Error('not base64: the length is wrong');
    var out = '';
    var bits = 0;
    var held = 0;
    for (var i = 0; i < text.length; i++) {
      var ch = text[i];
      if (ch === '=') break;
      var value = BASE64.indexOf(ch);
      if (value < 0) {
        if (ch === '-') value = 62;
        else if (ch === '_') value = 63;
        else throw new Error('not base64: "' + ch + '"');
      }
      held = (held << 6) | value;
      bits += 6;
      if (bits >= 8) {
        bits -= 8;
        out += String.fromCharCode((held >> bits) & 0xff);
      }
    }
    return out;
  }

  // ------------------------------------------------------------------ timers

  var timers = Object.create(null);
  var nextTimer = 1;

  function setTimeout(callback, delay) {
    if (typeof callback !== 'function') {
      throw new TypeError('setTimeout takes a function');
    }
    var extra = [];
    for (var i = 2; i < arguments.length; i++) extra.push(arguments[i]);
    var wait = MathFloor(Number(delay));
    if (!(wait >= 0)) wait = 0;
    var id = nextTimer++;
    timers[id] = callback;
    call('timer', 'sleep', [wait]).then(function () {
      var fn = timers[id];
      if (!fn) return;
      delete timers[id];
      fn.apply(null, extra);
    });
    return id;
  }

  function clearTimeout(id) {
    delete timers[id];
  }

  // ------------------------------------------------------------------ URL and URLSearchParams

  function decodeQuery(text) {
    try {
      return decodeURIComponent(StringFrom(text).replace(/\+/g, ' '));
    } catch (e) {
      return StringFrom(text);
    }
  }

  function encodeQuery(text) {
    return encodeURIComponent(StringFrom(text)).replace(/%20/g, '+');
  }

  function URLSearchParams(init) {
    this._pairs = [];
    if (init === undefined || init === null || init === '') return;
    if (init instanceof URLSearchParams) {
      for (var i = 0; i < init._pairs.length; i++) {
        this._pairs.push([init._pairs[i][0], init._pairs[i][1]]);
      }
      return;
    }
    if (typeof init === 'string') {
      var text = init[0] === '?' ? init.slice(1) : init;
      if (text === '') return;
      var parts = text.split('&');
      for (var j = 0; j < parts.length; j++) {
        if (parts[j] === '') continue;
        var at = parts[j].indexOf('=');
        if (at < 0) this._pairs.push([decodeQuery(parts[j]), '']);
        else {
          this._pairs.push([
            decodeQuery(parts[j].slice(0, at)),
            decodeQuery(parts[j].slice(at + 1))
          ]);
        }
      }
      return;
    }
    if (ArrayIsArray(init)) {
      for (var k = 0; k < init.length; k++) {
        this._pairs.push([StringFrom(init[k][0]), StringFrom(init[k][1])]);
      }
      return;
    }
    var keys = ObjectKeys(init);
    for (var n = 0; n < keys.length; n++) {
      this._pairs.push([keys[n], StringFrom(init[keys[n]])]);
    }
  }

  URLSearchParams.prototype.append = function (name, value) {
    this._pairs.push([StringFrom(name), StringFrom(value)]);
    this._changed();
  };
  URLSearchParams.prototype.set = function (name, value) {
    var key = StringFrom(name);
    var written = false;
    var kept = [];
    for (var i = 0; i < this._pairs.length; i++) {
      if (this._pairs[i][0] !== key) {
        kept.push(this._pairs[i]);
      } else if (!written) {
        kept.push([key, StringFrom(value)]);
        written = true;
      }
    }
    if (!written) kept.push([key, StringFrom(value)]);
    this._pairs = kept;
    this._changed();
  };
  URLSearchParams.prototype.get = function (name) {
    var key = StringFrom(name);
    for (var i = 0; i < this._pairs.length; i++) {
      if (this._pairs[i][0] === key) return this._pairs[i][1];
    }
    return null;
  };
  URLSearchParams.prototype.getAll = function (name) {
    var key = StringFrom(name);
    var out = [];
    for (var i = 0; i < this._pairs.length; i++) {
      if (this._pairs[i][0] === key) out.push(this._pairs[i][1]);
    }
    return out;
  };
  URLSearchParams.prototype.has = function (name) {
    return this.get(name) !== null;
  };
  URLSearchParams.prototype.delete = function (name) {
    var key = StringFrom(name);
    var kept = [];
    for (var i = 0; i < this._pairs.length; i++) {
      if (this._pairs[i][0] !== key) kept.push(this._pairs[i]);
    }
    this._pairs = kept;
    this._changed();
  };
  URLSearchParams.prototype.forEach = function (fn, thisArg) {
    for (var i = 0; i < this._pairs.length; i++) {
      fn.call(thisArg, this._pairs[i][1], this._pairs[i][0], this);
    }
  };
  URLSearchParams.prototype.keys = function () {
    return this._pairs.map(function (pair) { return pair[0]; })[Symbol.iterator]();
  };
  URLSearchParams.prototype.values = function () {
    return this._pairs.map(function (pair) { return pair[1]; })[Symbol.iterator]();
  };
  URLSearchParams.prototype.entries = function () {
    return this._pairs.map(function (pair) { return [pair[0], pair[1]]; })[Symbol.iterator]();
  };
  URLSearchParams.prototype[Symbol.iterator] = URLSearchParams.prototype.entries;
  URLSearchParams.prototype.toString = function () {
    var out = [];
    for (var i = 0; i < this._pairs.length; i++) {
      out.push(encodeQuery(this._pairs[i][0]) + '=' + encodeQuery(this._pairs[i][1]));
    }
    return out.join('&');
  };
  URLSearchParams.prototype._changed = function () {
    if (this._url) this._url._searchChanged(this);
  };

  // The host parses URLs, with the same parser that later checks them against the extension's
  // domains and fetches them. Two parsers reading one string differently is how an allowlist is
  // walked past, so there is only one here.
  function URL(input, base) {
    var parsed = call('url', 'parse', [StringFrom(input), base === undefined || base === null ? null : StringFrom(base)]);
    if (!parsed) {
      throw new TypeError('"' + StringFrom(input) + '" is not a URL');
    }
    this._read(parsed);
  }

  URL.prototype._read = function (parsed) {
    this.href = parsed.href;
    this.protocol = parsed.protocol;
    this.username = parsed.username;
    this.password = parsed.password;
    this.host = parsed.host;
    this.hostname = parsed.hostname;
    this.port = parsed.port;
    this.pathname = parsed.pathname;
    this.search = parsed.search;
    this.hash = parsed.hash;
    this.origin = parsed.origin;
    var params = new URLSearchParams(parsed.search);
    params._url = this;
    this.searchParams = params;
  };

  URL.prototype._searchChanged = function (params) {
    var text = params.toString();
    this.search = text === '' ? '' : '?' + text;
    this._rebuild();
  };

  // Rewriting a part and reading `href` back is what an extension does to build a request, so the
  // parts are writable and the host re-parses what they add up to.
  URL.prototype._rebuild = function () {
    var text = this.protocol + '//' +
      (this.username ? this.username + (this.password ? ':' + this.password : '') + '@' : '') +
      this.hostname + (this.port ? ':' + this.port : '') +
      this.pathname + this.search + this.hash;
    var parsed = call('url', 'parse', [text, null]);
    if (parsed) this._read(parsed);
  };

  URL.prototype.toString = function () {
    this._rebuild();
    return this.href;
  };
  URL.prototype.toJSON = function () {
    return this.toString();
  };

  // ------------------------------------------------------------------ the host API (§3.5)

  function HtmlElement(document, node) {
    this._document = document;
    this._node = node;
  }

  HtmlElement.prototype.select = function (css) {
    var nodes = call('html', 'select', [this._document, this._node, StringFrom(css)]);
    var out = [];
    for (var i = 0; i < nodes.length; i++) out.push(new HtmlElement(this._document, nodes[i]));
    return out;
  };
  HtmlElement.prototype.selectFirst = function (css) {
    var node = call('html', 'selectFirst', [this._document, this._node, StringFrom(css)]);
    return node === null || node === undefined ? null : new HtmlElement(this._document, node);
  };
  HtmlElement.prototype.text = function () {
    return call('html', 'text', [this._document, this._node]);
  };
  HtmlElement.prototype.attr = function (name) {
    return call('html', 'attr', [this._document, this._node, StringFrom(name)]);
  };
  HtmlElement.prototype.absUrl = function (name) {
    return call('html', 'absUrl', [this._document, this._node, StringFrom(name)]);
  };
  HtmlElement.prototype.html = function () {
    return call('html', 'html', [this._document, this._node]);
  };

  var kikuyomi = {
    http: {
      fetch: function (request) {
        return Promise.resolve(call('http', 'fetch', [request]));
      }
    },
    html: {
      parse: function (text, baseUrl) {
        var document = call('html', 'parse', [
          StringFrom(text),
          baseUrl === undefined || baseUrl === null ? null : StringFrom(baseUrl)
        ]);
        return Promise.resolve(new HtmlElement(document, 0));
      }
    },
    crypto: {
      hash: function (algorithm, data) {
        return Promise.resolve(call('crypto', 'hash', [StringFrom(algorithm), data]));
      },
      hmac: function (algorithm, key, data) {
        return Promise.resolve(call('crypto', 'hmac', [StringFrom(algorithm), key, data]));
      },
      base64Encode: function (data) {
        return Promise.resolve(call('crypto', 'base64Encode', [data]));
      },
      base64Decode: function (text) {
        return Promise.resolve(call('crypto', 'base64Decode', [StringFrom(text)]));
      },
      aesDecrypt: function (options) {
        return Promise.resolve(call('crypto', 'aesDecrypt', [options]));
      }
    },
    storage: {
      get: function (key) {
        return Promise.resolve(call('storage', 'get', [StringFrom(key)]));
      },
      set: function (key, value) {
        return Promise.resolve(call('storage', 'set', [StringFrom(key), StringFrom(value)]));
      },
      remove: function (key) {
        return Promise.resolve(call('storage', 'remove', [StringFrom(key)]));
      }
    },
    log: {
      debug: function (message) { call('log', 'debug', [StringFrom(message)]); },
      info: function (message) { call('log', 'info', [StringFrom(message)]); },
      warn: function (message) { call('log', 'warn', [StringFrom(message)]); },
      error: function (message) { call('log', 'error', [StringFrom(message)]); }
    },
    host: {
      apiVersion: StringFrom(info.apiVersion || ''),
      appVersion: StringFrom(info.appVersion || ''),
      has: function (feature) {
        var features = info.features || [];
        for (var i = 0; i < features.length; i++) {
          if (features[i] === feature) return true;
        }
        return false;
      }
    }
  };

  // ------------------------------------------------------------------ the extension protocol

  function readField(value, key) {
    // A thrown object can have a getter that throws, and losing the error kind over it would be
    // the extension's bug costing the listener an explanation.
    try {
      return value[key];
    } catch (e) {
      return undefined;
    }
  }

  // What an extension threw, as plain data. Nothing is thrown across the boundary: the host reads
  // this and decides which of the contract's error kinds it is.
  function describeThrow(value) {
    if (value === null || value === undefined) return 'the extension threw ' + StringFrom(value);
    if (typeof value !== 'object') return StringFrom(value);
    var out = {};
    // `stack` is here for the errors an extension did not mean to throw. A TypeError reaching the
    // host as "TypeError: not a function" and nothing else leaves an author with no line to look at,
    // and the stack is the only thing that says where. The host keeps a few frames of it.
    var keys = ['kind', 'message', 'name', 'url', 'retryAfterMs', 'stack'];
    for (var i = 0; i < keys.length; i++) {
      var field = readField(value, keys[i]);
      var type = typeof field;
      if (type === 'string' || type === 'number' || type === 'boolean') out[keys[i]] = field;
    }
    if (out.message === undefined && out.kind === undefined && out.name === undefined) {
      try {
        out.message = StringFrom(value);
      } catch (e) {
        out.message = 'the extension threw an object that cannot be described';
      }
    }
    return out;
  }

  var runtime = {
    extension: null,

    // The bundle's default export, however the SDK's bundler leaves it: as `module.exports`, as
    // its `default` for an ES module compiled to one, or as a global for an IIFE bundle.
    setExtension: function (value) {
      var found = value;
      if (found && typeof found === 'object' && !found.sources && found.default) {
        found = found.default;
      }
      if ((!found || !found.sources) && globalThis.__kikuyomiExtension) {
        found = globalThis.__kikuyomiExtension;
      }
      if (!found || typeof found !== 'object') {
        throw new Error('the extension exports nothing');
      }
      if (!found.sources || typeof found.sources !== 'object') {
        throw new Error('the extension exports no sources');
      }
      runtime.extension = found;
    },

    // The source keys the extension really has, so the host can check them against the manifest
    // without calling into the extension again.
    sourceKeys: function () {
      if (!runtime.extension) return [];
      return ObjectKeys(runtime.extension.sources);
    },

    // Whether a source has an optional method, for the capabilities a screen reads.
    hasMethod: function (sourceKey, method) {
      var extension = runtime.extension;
      if (!extension) return false;
      var source = extension.sources[sourceKey];
      return !!source && typeof source[method] === 'function';
    },

    // One call into the extension. It never throws: a failure comes back as data, so that the kind
    // of error the contract describes survives the crossing.
    invoke: function (sourceKey, method, args) {
      return (async function () {
        try {
          var extension = runtime.extension;
          if (!extension) throw new Error('the extension has not been loaded');
          var source = extension.sources[sourceKey];
          if (!source || typeof source !== 'object') {
            throw new Error('the extension has no source "' + sourceKey + '"');
          }
          var fn = source[method];
          if (typeof fn !== 'function') {
            throw new Error('the source "' + sourceKey + '" has no ' + method + '()');
          }
          var value = await fn.apply(source, args || []);
          return { ok: true, value: value === undefined ? null : value };
        } catch (error) {
          return { ok: false, error: describeThrow(error) };
        }
      })();
    }
  };

  globalThis.setTimeout = setTimeout;
  globalThis.clearTimeout = clearTimeout;
  globalThis.TextEncoder = TextEncoder;
  globalThis.TextDecoder = TextDecoder;
  globalThis.URL = URL;
  globalThis.URLSearchParams = URLSearchParams;
  globalThis.atob = atob;
  globalThis.btoa = btoa;
  // Not in the contract, but every author reaches for it, and silently losing what they wrote is
  // worse than sending it where their own log messages go.
  globalThis.console = {
    log: kikuyomi.log.info,
    debug: kikuyomi.log.debug,
    info: kikuyomi.log.info,
    warn: kikuyomi.log.warn,
    error: kikuyomi.log.error
  };
  globalThis.kikuyomi = ObjectFreeze(kikuyomi);
  globalThis.__kikuyomiRuntime = runtime;
})();
''';
