import Foundation

enum WebKitLegacyAPIs {
    /// API gaps observed in DSH 0.2.0-rc.2 and 0.2.1-alpha.2. Self-contained
    /// because the same installer is serialized into the bundled PDF Worker.
    static let installer = #"""
    (scope) => {
      'use strict';
      const define = (object, name, value) => {
        if (object && typeof object[name] !== 'function') {
          Object.defineProperty(object, name, { value, writable: true, configurable: true });
        }
      };
      const objectOf = (value) => {
        if (value == null) throw new TypeError('Expected an object.');
        return Object(value);
      };
      const integer = (value) => {
        const number = +value;
        return Number.isNaN(number) ? 0 : Math.trunc(number);
      };
      const lengthOf = (value) => Math.min(Math.max(integer(value.length), 0), Number.MAX_SAFE_INTEGER);
      define(scope.Object, 'hasOwn', (value, key) => Object.prototype.hasOwnProperty.call(objectOf(value), key));
      define(scope.Array.prototype, 'at', function(index) {
        const object = objectOf(this), length = lengthOf(object), offset = integer(index);
        const position = offset < 0 ? length + offset : offset;
        return position < 0 || position >= length ? undefined : object[position];
      });
      define(scope.String.prototype, 'at', function(index) {
        const string = String(objectOf(this)), offset = integer(index);
        const position = offset < 0 ? string.length + offset : offset;
        return position < 0 || position >= string.length ? undefined : string.charAt(position);
      });
      for (const name of ['findLast', 'findLastIndex']) {
        define(scope.Array.prototype, name, function(predicate, thisArg) {
          const object = objectOf(this), length = lengthOf(object);
          if (typeof predicate !== 'function') throw new TypeError('Expected a predicate.');
          for (let index = length - 1; index >= 0; index--) {
            const value = object[index];
            if (predicate.call(thisArg, value, index, object)) return name === 'findLast' ? value : index;
          }
          return name === 'findLast' ? undefined : -1;
        });
      }
      define(scope.Array.prototype, 'toSorted', function(compare) {
        if (compare !== undefined && typeof compare !== 'function') throw new TypeError('Expected a comparator.');
        const object = objectOf(this), length = lengthOf(object);
        // Copy indices rather than the iterator; holes become undefined and
        // neither custom iterators nor Array subclasses affect the result.
        const copy = new scope.Array(length);
        for (let index = 0; index < length; index++) copy[index] = object[index];
        return copy.sort(compare);
      });
      define(scope.Array.prototype, 'toReversed', function() {
        const object = objectOf(this), length = lengthOf(object), copy = new scope.Array(length);
        for (let index = 0; index < length; index++) copy[index] = object[length - index - 1];
        return copy;
      });
      if (typeof scope.Symbol.dispose === 'undefined') {
        Object.defineProperty(scope.Symbol, 'dispose', { value: scope.Symbol('Symbol.dispose') });
      }

      const cloneError = (message) => typeof scope.DOMException === 'function'
        ? new scope.DOMException(message, 'DataCloneError') : Object.assign(new Error(message), { name: 'DataCloneError' });
      const bufferLength = Object.getOwnPropertyDescriptor(scope.ArrayBuffer.prototype, 'byteLength').get;
      const copyBuffer = (buffer) => {
        const length = bufferLength.call(buffer);
        const bytes = new scope.Uint8Array(buffer); // Reject detached buffers, including empty ones.
        const copy = new scope.ArrayBuffer(length);
        new scope.Uint8Array(copy).set(bytes);
        return copy;
      };
      const detachBuffers = (buffers) => {
        if (buffers.length === 0) return;
        if (typeof scope.MessageChannel !== 'function') throw cloneError('ArrayBuffer transfer is unavailable.');
        const channel = new scope.MessageChannel();
        try {
          // Native structured serialization detaches synchronously, even when
          // structuredClone is absent. No messages escape this private channel.
          channel.port1.postMessage(null, buffers);
        } finally {
          channel.port1.close();
          channel.port2.close();
        }
      };
      define(scope, 'structuredClone', function(value, options) {
        const transfers = options?.transfer === undefined ? [] : Array.from(options.transfer);
        const unique = new scope.Set();
        for (const buffer of transfers) {
          if (unique.has(buffer)) throw cloneError('Duplicate transferable.');
          try { bufferLength.call(buffer); new scope.Uint8Array(buffer); }
          catch (_) { throw cloneError('Only attached ArrayBuffers can be transferred by this compatibility layer.'); }
          unique.add(buffer);
        }
        const seen = new scope.Map();
        const clone = (source) => {
          if (typeof source === 'symbol' || typeof source === 'function') throw cloneError('Value cannot be cloned.');
          if (source === null || typeof source !== 'object') return source;
          if (seen.has(source)) return seen.get(source);
          const tag = Object.prototype.toString.call(source);
          let target;
          if (tag === '[object ArrayBuffer]') {
            try { target = copyBuffer(source); } catch (_) { throw cloneError('Detached ArrayBuffer.'); }
          } else if (scope.ArrayBuffer.isView(source)) {
            const buffer = clone(source.buffer);
            const type = tag.slice(8, -1);
            target = type === 'DataView'
              ? new scope.DataView(buffer, source.byteOffset, source.byteLength)
              : new scope[type](buffer, source.byteOffset, source.length);
          } else if (tag === '[object Date]') target = new scope.Date(source.getTime());
          else if (tag === '[object RegExp]') target = new scope.RegExp(source.source, source.flags);
          else if (tag === '[object Blob]') target = source.slice(0, source.size, source.type);
          else if (tag === '[object File]' && typeof scope.File === 'function') {
            target = new scope.File([source], source.name, { type: source.type, lastModified: source.lastModified });
          } else if (tag === '[object Map]') {
            target = new scope.Map(); seen.set(source, target);
            for (const [key, entry] of source) target.set(clone(key), clone(entry));
          } else if (tag === '[object Set]') {
            target = new scope.Set(); seen.set(source, target);
            for (const entry of source) target.add(clone(entry));
          } else if (tag === '[object Error]') {
            const type = ['Error', 'EvalError', 'RangeError', 'ReferenceError', 'SyntaxError', 'TypeError', 'URIError']
              .includes(source.name) ? source.name : 'Error';
            target = new scope[type](source.message); seen.set(source, target);
            if ('cause' in source) Object.defineProperty(target, 'cause', { value: clone(source.cause), writable: true, configurable: true });
            if (typeof source.stack === 'string') target.stack = source.stack;
          } else if (['[object Boolean]', '[object Number]', '[object String]', '[object BigInt]'].includes(tag)) {
            target = Object(source.valueOf());
          } else if (tag === '[object Object]' || tag === '[object Array]') {
            target = tag === '[object Array]' ? new scope.Array(source.length) : {};
            seen.set(source, target);
            for (const key of Object.keys(source)) {
              Object.defineProperty(target, key, { value: clone(source[key]), writable: true, enumerable: true, configurable: true });
            }
          } else {
            // Do not silently turn unsupported host objects into empty records.
            throw cloneError('Unsupported clone type: ' + tag);
          }
          seen.set(source, target);
          return target;
        };
        const result = clone(value);
        detachBuffers(transfers); // Failed serialization must leave sources attached.
        return result;
      });
      define(scope.ArrayBuffer.prototype, 'transferToFixedLength', function(newLength) {
        const originalLength = bufferLength.call(this);
        new scope.Uint8Array(this);
        const length = newLength === undefined ? originalLength : integer(newLength);
        if (length < 0 || !Number.isFinite(length) || length > Number.MAX_SAFE_INTEGER) throw new RangeError('Invalid buffer length.');
        // Allocate and copy before detaching: allocation failures preserve the source.
        const result = new scope.ArrayBuffer(length);
        new scope.Uint8Array(result).set(new scope.Uint8Array(this, 0, Math.min(length, originalLength)));
        if (typeof scope.MessageChannel === 'function') detachBuffers([this]);
        else scope.structuredClone(this, { transfer: [this] });
        return result;
      });
      define(scope.Uint8Array.prototype, 'toBase64', function(options) {
        if (Object.prototype.toString.call(this) !== '[object Uint8Array]') throw new TypeError('Expected Uint8Array.');
        new scope.Uint8Array(this.buffer); // Check for detachment before reading.
        const alphabet = options?.alphabet ?? 'base64';
        if (alphabet !== 'base64' && alphabet !== 'base64url') throw new TypeError('Invalid base64 alphabet.');
        const table = alphabet === 'base64'
          ? 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/'
          : 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_';
        const chunks = [];
        let chunk = '';
        for (let index = 0; index < this.length; index += 3) {
          const a = this[index], b = this[index + 1], c = this[index + 2];
          chunk += table[a >> 2] + table[((a & 3) << 4) | ((b ?? 0) >> 4)]
            + (b === undefined ? (options?.omitPadding ? '' : '=') : table[((b & 15) << 2) | ((c ?? 0) >> 6)])
            + (c === undefined ? (options?.omitPadding ? '' : '=') : table[c & 63]);
          if (chunk.length >= 8192) { chunks.push(chunk); chunk = ''; }
        }
        chunks.push(chunk);
        return chunks.join('');
      });
      define(scope.Response?.prototype, 'bytes', async function() {
        return new scope.Uint8Array(await this.arrayBuffer());
      });
      if (scope.ReadableStream) {
        define(scope.ReadableStream.prototype, 'values', function(options) {
          const reader = this.getReader();
          let finished = false, tail = Promise.resolve();
          const enqueue = (action) => {
            const result = tail.then(action);
            tail = result.catch(() => {});
            return result;
          };
          return {
            next() { return enqueue(async () => {
              if (finished) return { done: true, value: undefined };
              try {
                const result = await reader.read();
                if (result.done) { finished = true; reader.releaseLock(); }
                return result;
              } catch (error) { finished = true; reader.releaseLock(); throw error; }
            }); },
            return(value) { return enqueue(async () => {
              if (!finished) {
                finished = true;
                try { if (!options?.preventCancel) await reader.cancel(value); }
                finally { reader.releaseLock(); }
              }
              return { done: true, value };
            }); },
            [scope.Symbol.asyncIterator]() { return this; }
          };
        });
        define(scope.ReadableStream.prototype, scope.Symbol.asyncIterator, scope.ReadableStream.prototype.values);
      }
      define(scope.AbortSignal?.prototype, 'throwIfAborted', function() {
        if (this.aborted) throw 'reason' in this ? this.reason : new scope.DOMException('The operation was aborted.', 'AbortError');
      });
    }
    """#
}
