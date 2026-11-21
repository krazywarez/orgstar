#if canImport(JavaScriptCore)
import Foundation
import JavaScriptCore
import OrgCore

/// js and javascript blocks in JavaScriptCore, as `node` runs them, for builds that can't start
/// node. Node's `require('util')`, `require('process')`, `console` and timers are written in
/// JavaScript below; a block that uses anything else of Node's, or prints a value whose text
/// can't be made the same as Node's, is refused rather than given a different result.
///
/// The public JavaScriptCore API can't stop a running script. A run that is canceled or times
/// out ends at once, but a script that never finishes keeps its thread busy until the app quits.
public enum JavaScriptBlocks {
    /// Runs `job` when it is a js block, in `directory` or its `:dir`; nil for other languages.
    /// `:cmd` is ignored.
    public static func run(_ job: BabelJob, directory: URL, timeout: Duration = .seconds(300)) async throws -> BabelOutput? {
        guard job.language == "js" || job.language == "javascript" else { return nil }
        let folder = job.directory.map { URL(fileURLWithPath: $0, relativeTo: directory).standardizedFileURL } ?? directory
        switch job.runner {
        case .process:
            guard FileManager.default.fileExists(atPath: folder.path) else { throw Babel.Failure.message("No folder \(folder.path) for :dir.") }
            return try await evaluate(timeout: timeout) { run in try Engine().main(job.input, run: run) }
        case .session(let name, _, .node):
            guard FileManager.default.fileExists(atPath: folder.path) else { throw Babel.Failure.message("No folder \(folder.path) for :dir.") }
            // One context per file folder and session name; a stopped run's context is dropped.
            let key = folder.path + "\u{1}" + name
            let engine = sessions.engine(key)
            do {
                return try await evaluate(timeout: timeout) { run in try engine.session(job.input, value: !job.finish.output, run: run) }
            } catch let error where error is CancellationError || error is Stopped {
                sessions.drop(key, engine)
                throw error
            }
        default:
            return nil
        }
    }

    /// Runs a js `job` without a session on the calling thread, as `org-sbe` in a table
    /// formula needs; nil for other jobs.
    public static func runHere(_ job: BabelJob) throws -> BabelOutput? {
        guard job.language == "js" || job.language == "javascript", case .process = job.runner else { return nil }
        return try Engine().main(job.input, run: Run())
    }

    struct Stopped: Error, CustomStringConvertible {
        let description: String
    }

    /// Runs `body` on a thread of its own, which a cancel or the timeout leaves behind.
    private static func evaluate(timeout: Duration, _ body: @escaping @Sendable (Run) throws -> BabelOutput) async throws -> BabelOutput {
        let run = Run()
        let thread = Thread { run.end(Result { try body(run) }) }
        thread.stackSize = 8 << 20
        thread.start()
        let limit = Task {
            try await Task.sleep(for: timeout)
            run.end(.failure(Stopped(description: "The block took longer than \(timeout) and was stopped.")))
        }
        defer { limit.cancel() }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { run.wait($0) }
        } onCancel: {
            run.end(.failure(CancellationError()))
        }
    }

    /// A run, which ends once: with the script's output, a cancel or the timeout.
    final class Run: @unchecked Sendable {
        private let lock = NSLock()
        private var result: Result<BabelOutput, Error>?
        private var continuation: CheckedContinuation<BabelOutput, Error>?
        private let wake = DispatchSemaphore(value: 0)

        var stopped: Bool { lock.withLock { result != nil } }

        func end(_ outcome: Result<BabelOutput, Error>) {
            let (first, waiting) = lock.withLock { () -> (Bool, CheckedContinuation<BabelOutput, Error>?) in
                guard result == nil else { return (false, nil) }
                result = outcome
                defer { continuation = nil }
                return (true, continuation)
            }
            guard first else { return }
            waiting?.resume(with: outcome)
            wake.signal()
        }

        func wait(_ continuation: CheckedContinuation<BabelOutput, Error>) {
            let done = lock.withLock { () -> Result<BabelOutput, Error>? in
                if result == nil { self.continuation = continuation }
                return result
            }
            if let done { continuation.resume(with: done) }
        }

        /// Waits for a timer, or until the run ends.
        func sleep(milliseconds: Double) {
            _ = wake.wait(timeout: .now() + .milliseconds(Int(milliseconds.rounded(.up))))
        }
    }

    private static let sessions = Sessions()

    final class Sessions: @unchecked Sendable {
        private let lock = NSLock()
        private var engines: [String: Engine] = [:]

        func engine(_ key: String) -> Engine {
            lock.withLock {
                if let engine = engines[key] { return engine }
                let engine = Engine(session: true)
                engines[key] = engine
                return engine
            }
        }

        func drop(_ key: String, _ engine: Engine) {
            lock.withLock { if engines[key] === engine { engines[key] = nil } }
        }
    }

    /// A context with Node's globals, and what its scripts wrote.
    final class Engine: @unchecked Sendable {
        private final class Output {
            var stdout = ""
            var stderr = ""
            var exception: JSValue?
        }

        private let context: JSContext
        private let node: JSValue
        private let output: Output
        private let lock = NSLock()

        /// A session's context has `require`, `module` and the rest of a module's names as
        /// globals, as `node -e` has them.
        init(session: Bool = false) {
            let output = Output()
            self.output = output
            context = JSContext()
            let write: @convention(block) (Int32, String) -> Void = { fd, text in
                if fd == 1 { output.stdout += text } else { output.stderr += text }
            }
            // Runs a session's script as a script of its own, which the caller's call holds back
            // the promise callbacks of: whether it threw, and its error or completion value.
            let script: @convention(block) (String) -> JSValue = { source in
                let context = JSContext.current()!
                output.exception = nil
                let completion = context.evaluateScript(source)
                let result = JSValue(newArrayIn: context)!
                result.setValue(output.exception != nil, at: 0)
                result.setValue(output.exception ?? completion, at: 1)
                output.exception = nil
                return result
            }
            context.exceptionHandler = { _, exception in output.exception = exception }
            node = context.evaluateScript(Self.shim).call(withArguments: [write, script, session])
        }

        /// Runs `source` as node runs a script file, as Emacs runs it, then its timers.
        func main(_ source: String, run: Run) throws -> BabelOutput {
            node.invokeMethod("main", withArguments: [source])
            runTimers(run)
            return try finish(result: nil)
        }

        /// Runs `source` where the session's earlier scripts ran, as `vm.runInThisContext` does;
        /// with `value`, the result is its completion value as `util.inspect` prints it. A block
        /// that leaves a timer, or a promise callback that prints or throws, is refused.
        func session(_ source: String, value: Bool, run: Run) throws -> BabelOutput {
            try lock.withLock {
                output.stdout = ""
                output.stderr = ""
                output.exception = nil
                node.invokeMethod("session", withArguments: [source, value])
                // node's session returns before its timers and promise callbacks run, and they print later.
                node.invokeMethod("settle", withArguments: [])
                let result = node.forProperty("result")
                return try finish(result: result?.isString == true ? result?.toString() : nil)
            }
        }

        private func runTimers(_ run: Run) {
            while !run.stopped, let wait = node.invokeMethod("tick", withArguments: [])?.toDouble(), wait >= 0 {
                if wait > 0 { run.sleep(milliseconds: wait) }
            }
        }

        private func finish(result: String?) throws -> BabelOutput {
            if let refused = node.forProperty("refused")?.toString(), !refused.isEmpty {
                throw Babel.Failure.message("This block uses \(refused), which runs only in node.")
            }
            guard let error = node.forProperty("error"), !error.isUndefined else {
                return BabelOutput(stdout: output.stdout, resultFile: result, stderr: output.stderr)
            }
            return BabelOutput(stdout: output.stdout, resultFile: result, stderr: output.stderr + (error.toString() ?? "") + "\n", status: 1)
        }

        /// Node's globals and modules; `util.inspect` and `util.format` are ported from Node 26's
        /// lib/internal/util/inspect.js (MIT License, Node.js contributors). It returns the
        /// runner's controls.
        static let shim = #"""
            (function shim(write, script, session) {
              'use strict';
              const functionToString = Function.prototype.toString;
              const state = { dead: false, error: undefined, refused: '', timers: [], seq: 0, now: Date.now(), draining: false, result: undefined };
              const lateInSession = 'a promise callback that prints or throws in a session';

              function refuse(what) {
                if (!state.refused) state.refused = what;
                throw new Error(`${what} isn't available`);
              }
              function out(fd, text) {
                // node's session prints a promise callback's text after the block.
                if (state.draining) {
                  if (!state.refused) state.refused = lateInSession;
                  return;
                }
                if (!state.dead) write(fd, text.toWellFormed());
              }
              // Members a script may use, its own and those in `extra`; any other, and listing them, is
              // refused rather than answered differently.
              const ownProperty = Function.prototype.call.bind(Object.prototype.hasOwnProperty);
              const guarded = new WeakMap();
              function guard(target, name, extra = []) {
                const known = (t, key) => typeof key === 'symbol' || ownProperty(t, key) || extra.includes(key);
                const member = (t, key) => { if (!known(t, key)) refuse(`${name}.${String(key)}`); };
                const proxy = new Proxy(target, {
                  get(t, key, receiver) { member(t, key); return Reflect.get(t, key, receiver); },
                  has(t, key) { member(t, key); return Reflect.has(t, key); },
                  set(t, key, value, receiver) { member(t, key); return Reflect.set(t, key, value, receiver); },
                  defineProperty(t, key, descriptor) { member(t, key); return Reflect.defineProperty(t, key, descriptor); },
                  deleteProperty(t, key) { member(t, key); return Reflect.deleteProperty(t, key); },
                  getOwnPropertyDescriptor(t, key) { member(t, key); return Reflect.getOwnPropertyDescriptor(t, key); },
                  ownKeys() { refuse(`the members of ${name}`); },
                  getPrototypeOf() { refuse(`the prototype of ${name}`); },
                  setPrototypeOf() { refuse(`the prototype of ${name}`); },
                });
                guarded.set(proxy, name);
                return proxy;
              }
              // The script's proxies, target and handler, or null once revoked: JavaScriptCore can't tell
              // a proxy, and Node shows one.
              const proxies = new WeakMap();
              const RealProxy = Proxy;
              function revocable(target, handler) {
                const made = RealProxy.revocable(target, handler);
                proxies.set(made.proxy, [target, handler]);
                return { proxy: made.proxy, revoke: [() => { proxies.set(made.proxy, null); made.revoke(); }][0] };
              }
              const ProxyConstructor = new RealProxy(RealProxy, {
                construct(target, args, newTarget) {
                  const proxy = Reflect.construct(target, args, newTarget);
                  proxies.set(proxy, [args[0], args[1]]);
                  return proxy;
                },
                get(target, key, receiver) {
                  return key === 'revocable' ? revocable : Reflect.get(target, key, receiver);
                },
              });

              // util.inspect and util.format, after Node's lib/internal/util/inspect.js.
              const kObjectType = 0, kArrayType = 1, kArrayExtrasType = 2;
              const defaults = {
                showHidden: false, depth: 2, colors: false, customInspect: true, showProxy: false, maxArrayLength: 100,
                maxStringLength: 10000, breakLength: 80, compact: 3, sorted: false, getters: false, numericSeparator: false,
              };
              const customInspectSymbol = Symbol.for('nodejs.util.inspect.custom');
              const builtInObjects = new Set(Object.getOwnPropertyNames(globalThis).filter((e) => /^[A-Z][a-zA-Z0-9]+$/.test(e)));
              const strEscapeSequencesRegExp = /[\x00-\x1f\x27\x5c\x7f-\x9f]|[\ud800-\udbff](?![\udc00-\udfff])|(?<![\ud800-\udbff])[\udc00-\udfff]/;
              const strEscapeSequencesReplacer = /[\x00-\x1f\x27\x5c\x7f-\x9f]|[\ud800-\udbff](?![\udc00-\udfff])|(?<![\ud800-\udbff])[\udc00-\udfff]/g;
              const strEscapeSequencesRegExpSingle = /[\x00-\x1f\x5c\x7f-\x9f]|[\ud800-\udbff](?![\udc00-\udfff])|(?<![\ud800-\udbff])[\udc00-\udfff]/;
              const strEscapeSequencesReplacerSingle = /[\x00-\x1f\x5c\x7f-\x9f]|[\ud800-\udbff](?![\udc00-\udfff])|(?<![\ud800-\udbff])[\udc00-\udfff]/g;
              const keyStrRegExp = /^[a-zA-Z_][a-zA-Z_0-9]*$/;
              const numberRegExp = /^(0|[1-9][0-9]*)$/;
              const classRegExp = /^(\s+[^(]*?)\s*{/;
              const stripCommentsRegExp = /(\/\/.*?\n)|(\/\*(.|\n)*?\*\/)/g;
              const kMinLineLength = 16;
              const meta = [
                '\\x00', '\\x01', '\\x02', '\\x03', '\\x04', '\\x05', '\\x06', '\\x07',
                '\\b', '\\t', '\\n', '\\x0B', '\\f', '\\r', '\\x0E', '\\x0F',
                '\\x10', '\\x11', '\\x12', '\\x13', '\\x14', '\\x15', '\\x16', '\\x17',
                '\\x18', '\\x19', '\\x1A', '\\x1B', '\\x1C', '\\x1D', '\\x1E', '\\x1F',
                '', '', '', '', '', '', '', "\\'", '', '', '', '', '', '', '', '',
                '', '', '', '', '', '', '', '', '', '', '', '', '', '', '', '',
                '', '', '', '', '', '', '', '', '', '', '', '', '', '', '', '',
                '', '', '', '', '', '', '', '', '', '', '', '', '\\\\', '', '', '',
                '', '', '', '', '', '', '', '', '', '', '', '', '', '', '', '',
                '', '', '', '', '', '', '', '', '', '', '', '', '', '', '', '\\x7F',
                '\\x80', '\\x81', '\\x82', '\\x83', '\\x84', '\\x85', '\\x86', '\\x87',
                '\\x88', '\\x89', '\\x8A', '\\x8B', '\\x8C', '\\x8D', '\\x8E', '\\x8F',
                '\\x90', '\\x91', '\\x92', '\\x93', '\\x94', '\\x95', '\\x96', '\\x97',
                '\\x98', '\\x99', '\\x9A', '\\x9B', '\\x9C', '\\x9D', '\\x9E', '\\x9F',
              ];

              // Type checks through the built-ins' own brand checks.
              function branded(fn, value) {
                try { fn.call(value); return true; } catch { return false; }
              }
              const getter = (proto, key) => Object.getOwnPropertyDescriptor(proto, key).get;
              const typedArrayProto = Object.getPrototypeOf(Int8Array.prototype);
              const typedArrayTag = getter(typedArrayProto, Symbol.toStringTag);
              const isSet = (v) => branded(getter(Set.prototype, 'size'), v);
              const isMap = (v) => branded(getter(Map.prototype, 'size'), v);
              const isTypedArray = (v) => typedArrayTag.call(v) !== undefined;
              const isArrayBuffer = (v) => branded(getter(ArrayBuffer.prototype, 'byteLength'), v);
              const isDataView = (v) => branded(getter(DataView.prototype, 'byteLength'), v);
              const isRegExp = (v) => v !== RegExp.prototype && branded(getter(RegExp.prototype, 'source'), v);
              const isDate = (v) => branded(Date.prototype.getTime, v);
              const isWeakMap = (v) => branded(function () { WeakMap.prototype.has.call(this, {}); }, v);
              const isWeakSet = (v) => branded(function () { WeakSet.prototype.has.call(this, {}); }, v);
              const isPromise = (v) => Object.prototype.toString.call(v) === '[object Promise]' && v instanceof Promise;
              const isError = (v) => v instanceof Error || Object.prototype.toString.call(v) === '[object Error]';
              const isArgumentsObject = (v) => Object.prototype.toString.call(v) === '[object Arguments]';
              const iteratorTags = ['[object Map Iterator]', '[object Set Iterator]', '[object Array Iterator]', '[object String Iterator]', '[object Generator]', '[object Iterator Helper]'];
              const generatorFunctionProto = Object.getPrototypeOf(function* () {});
              const asyncFunctionProto = Object.getPrototypeOf(async function () {});
              const asyncGeneratorFunctionProto = Object.getPrototypeOf(async function* () {});
              const boxes = [
                ['Number', Number.prototype.valueOf], ['String', String.prototype.valueOf], ['Boolean', Boolean.prototype.valueOf],
                ['BigInt', BigInt.prototype.valueOf], ['Symbol', Symbol.prototype.valueOf],
              ];
              const boxType = (v) => boxes.find(([, fn]) => branded(fn, v));
              const internalGetConstructorName = (v) => Object.prototype.toString.call(v).slice(8, -1);

              // Width as a terminal shows it; text beyond ASCII is measured by ICU in Node.
              function getStringWidth(str) {
                let width = 0;
                for (let i = 0; i < str.length; i++) {
                  const code = str.charCodeAt(i);
                  if (code >= 127) refuse('lining up text beyond ASCII in util.inspect');
                  width += code >= 32 ? 1 : 0;
                }
                return width;
              }

              function inspect(value, opts) {
                const ctx = { budget: {}, indentationLvl: 0, seen: [], currentDepth: 0, ...defaults };
                if (arguments.length > 1) {
                  if (arguments.length > 2) {
                    if (arguments[2] !== undefined) ctx.depth = arguments[2];
                    if (arguments.length > 3 && arguments[3] !== undefined) ctx.colors = arguments[3];
                  }
                  if (typeof opts === 'boolean') {
                    ctx.showHidden = opts;
                  } else if (opts) {
                    for (const key of Object.keys(opts)) {
                      if (Object.prototype.hasOwnProperty.call(defaults, key)) ctx[key] = opts[key];
                      else if (key === 'stylize') refuse('util.inspect with stylize');
                      else if (ctx.userOptions === undefined) ctx.userOptions = opts;
                    }
                  }
                }
                if (ctx.colors) refuse('util.inspect with colors');
                if (ctx.maxArrayLength === null) ctx.maxArrayLength = Infinity;
                if (ctx.maxStringLength === null) ctx.maxStringLength = Infinity;
                return formatValue(ctx, value, 0);
              }
              inspect.custom = customInspectSymbol;
              Object.defineProperty(inspect, 'defaultOptions', { get() { refuse('util.inspect.defaultOptions'); } });

              const stylize = (str) => str;

              function getUserOptions(ctx) {
                const ret = { stylize };
                for (const key of Object.keys(defaults)) ret[key] = ctx[key];
                return { ...ret, ...ctx.userOptions };
              }

              function formatValue(ctx, value, recurseTimes, typedArray) {
                if (typeof value !== 'object' && typeof value !== 'function') return formatPrimitive(value, ctx);
                if (value === null) return 'null';
                if (guarded.has(value)) refuse(`util.inspect of ${guarded.get(value)}`);
                if (value === globalThis) refuse('util.inspect of the global object');
                const context = value;
                let proxyCount = 0;
                let proxy = proxies.get(value);
                if (proxy !== undefined) {
                  if (ctx.showProxy) return proxy === null ? '<Revoked Proxy>' : formatProxy(ctx, proxy, recurseTimes);
                  do {
                    if (proxy === null) return 'Proxy('.repeat(proxyCount) + '<Revoked Proxy>' + ')'.repeat(proxyCount);
                    value = proxy[0];
                    proxy = proxies.get(value);
                    proxyCount += 1;
                  } while (proxy !== undefined);
                }
                const formatted = formatUnwrapped(ctx, value, context, recurseTimes, typedArray);
                return 'Proxy('.repeat(proxyCount) + formatted + ')'.repeat(proxyCount);
              }

              function formatProxy(ctx, proxy, recurseTimes) {
                if (recurseTimes > ctx.depth && ctx.depth !== null) return 'Proxy [Array]';
                recurseTimes += 1;
                ctx.indentationLvl += 2;
                const res = [formatValue(ctx, proxy[0], recurseTimes), formatValue(ctx, proxy[1], recurseTimes)];
                ctx.indentationLvl -= 2;
                return reduceToSingleString(ctx, res, '', ['Proxy [', ']'], kArrayExtrasType, recurseTimes);
              }

              function formatUnwrapped(ctx, value, context, recurseTimes, typedArray) {
                if (ctx.customInspect) {
                  const maybeCustom = value[customInspectSymbol];
                  if (typeof maybeCustom === 'function' && maybeCustom !== inspect &&
                      Object.getOwnPropertyDescriptor(value, 'constructor')?.value?.prototype !== value) {
                    const depth = ctx.depth === null ? null : ctx.depth - recurseTimes;
                    const ret = maybeCustom.call(context, depth, getUserOptions(ctx), inspect);
                    if (ret !== context) {
                      if (typeof ret !== 'string') return formatValue(ctx, ret, recurseTimes);
                      return ret.replaceAll('\n', `\n${' '.repeat(ctx.indentationLvl)}`);
                    }
                  }
                }
                if (ctx.seen.includes(value)) {
                  let index = 1;
                  if (ctx.circular === undefined) {
                    ctx.circular = new Map();
                    ctx.circular.set(value, index);
                  } else {
                    index = ctx.circular.get(value);
                    if (index === undefined) {
                      index = ctx.circular.size + 1;
                      ctx.circular.set(value, index);
                    }
                  }
                  return `[Circular *${index}]`;
                }
                return formatRaw(ctx, value, recurseTimes, typedArray);
              }

              function getConstructorName(obj, ctx, recurseTimes, protoProps) {
                let firstProto;
                const tmp = obj;
                while (obj) {
                  const descriptor = Object.getOwnPropertyDescriptor(obj, 'constructor');
                  if (descriptor !== undefined && typeof descriptor.value === 'function' && descriptor.value.name !== '' &&
                      isInstanceof(tmp, descriptor.value)) {
                    if (protoProps !== undefined && (firstProto !== obj || !builtInObjects.has(descriptor.value.name))) {
                      addPrototypeProperties(ctx, tmp, firstProto || tmp, recurseTimes, protoProps);
                    }
                    return String(descriptor.value.name);
                  }
                  obj = Object.getPrototypeOf(obj);
                  if (firstProto === undefined) firstProto = obj;
                }
                if (firstProto === null) return null;
                const res = internalGetConstructorName(tmp);
                if (recurseTimes > ctx.depth && ctx.depth !== null) return `${res} <Complex prototype>`;
                const protoConstr = getConstructorName(firstProto, ctx, recurseTimes + 1, protoProps);
                if (protoConstr === null) {
                  return `${res} <${inspect(firstProto, { ...ctx, customInspect: false, depth: -1 })}>`;
                }
                return `${res} <${protoConstr}>`;
              }

              function isInstanceof(object, proto) {
                try { return object instanceof proto; } catch { return false; }
              }

              function addPrototypeProperties(ctx, main, obj, recurseTimes, output) {
                let depth = 0;
                let keys;
                let keySet;
                do {
                  if (depth !== 0 || main === obj) {
                    obj = Object.getPrototypeOf(obj);
                    if (obj === null) return;
                    const descriptor = Object.getOwnPropertyDescriptor(obj, 'constructor');
                    if (descriptor !== undefined && typeof descriptor.value === 'function' && builtInObjects.has(descriptor.value.name)) return;
                  }
                  if (depth === 0) {
                    keySet = new Set();
                  } else {
                    keys.forEach((key) => keySet.add(key));
                  }
                  keys = Reflect.ownKeys(obj);
                  ctx.seen.push(main);
                  for (const key of keys) {
                    if (key === 'constructor' || Object.prototype.hasOwnProperty.call(main, key) || (depth !== 0 && keySet.has(key))) continue;
                    const desc = Object.getOwnPropertyDescriptor(obj, key);
                    if (typeof desc.value === 'function') continue;
                    output.push(formatProperty(ctx, obj, recurseTimes, key, kObjectType, desc, main));
                  }
                  ctx.seen.pop();
                } while (++depth !== 3);
              }

              function getPrefix(constructor, tag, fallback, size = '') {
                if (constructor === null) {
                  if (tag !== '' && fallback !== tag) return `[${fallback}${size}: null prototype] [${tag}] `;
                  return `[${fallback}${size}: null prototype] `;
                }
                if (tag !== '') {
                  const dot = tag.lastIndexOf('.');
                  if (constructor === (dot >= 1 ? tag.slice(dot + 1) : tag)) return `${tag}${size} `;
                  return `${constructor}${size} [${tag}] `;
                }
                return `${constructor}${size} `;
              }

              function getKeys(value, showHidden) {
                let keys;
                const symbols = Object.getOwnPropertySymbols(value);
                if (showHidden) {
                  keys = Object.getOwnPropertyNames(value);
                  if (symbols.length !== 0) keys.push(...symbols);
                } else {
                  keys = Object.keys(value);
                  if (symbols.length !== 0) keys.push(...symbols.filter((key) => Object.prototype.propertyIsEnumerable.call(value, key)));
                }
                return keys;
              }

              function isIndex(key) {
                return typeof key === 'string' && numberRegExp.test(key) && Number(key) < 2 ** 32 - 1;
              }

              function getOwnNonIndexProperties(value, showHidden) {
                const keys = Reflect.ownKeys(value).filter((key) => !isIndex(key) &&
                  (showHidden || Object.prototype.propertyIsEnumerable.call(value, key)));
                return [...keys.filter((key) => typeof key === 'string'), ...keys.filter((key) => typeof key === 'symbol')];
              }

              function getCtxStyle(value, constructor, tag) {
                let fallback = '';
                if (constructor === null) {
                  fallback = internalGetConstructorName(value);
                  if (fallback === tag) fallback = 'Object';
                }
                return getPrefix(constructor, tag, fallback);
              }

              function formatRaw(ctx, value, recurseTimes, typedArray) {
                let keys;
                let protoProps;
                if (ctx.showHidden && (recurseTimes <= ctx.depth || ctx.depth === null)) protoProps = [];
                const constructor = getConstructorName(value, ctx, recurseTimes, protoProps);
                if (protoProps !== undefined && protoProps.length === 0) protoProps = undefined;
                let tag = '';
                try { tag = value[Symbol.toStringTag]; } catch {}
                if (typeof tag !== 'string' || (tag !== '' && (ctx.showHidden ? Object.prototype.hasOwnProperty
                  : Object.prototype.propertyIsEnumerable).call(value, Symbol.toStringTag))) {
                  tag = '';
                }
                let base = '';
                let formatter = () => [];
                let braces;
                let noIterator = true;
                let extrasType = kObjectType;
                let extraKeys;

                if (Symbol.iterator in value || constructor === null) {
                  noIterator = false;
                  if (Array.isArray(value)) {
                    const prefix = (constructor !== 'Array' || tag !== '') ? getPrefix(constructor, tag, 'Array', `(${value.length})`) : '';
                    keys = getOwnNonIndexProperties(value, ctx.showHidden);
                    braces = [`${prefix}[`, ']'];
                    if (value.length === 0 && keys.length === 0 && protoProps === undefined) return `${braces[0]}]`;
                    extrasType = kArrayExtrasType;
                    formatter = formatArray;
                  } else if (isSet(value)) {
                    const size = getter(Set.prototype, 'size').call(value);
                    const prefix = getPrefix(constructor, tag, 'Set', `(${size})`);
                    keys = getKeys(value, ctx.showHidden);
                    formatter = (ctx, v, recurseTimes) => formatSet(value, ctx, recurseTimes);
                    if (size === 0 && keys.length === 0 && protoProps === undefined) return `${prefix}{}`;
                    braces = [`${prefix}{`, '}'];
                  } else if (isMap(value)) {
                    const size = getter(Map.prototype, 'size').call(value);
                    const prefix = getPrefix(constructor, tag, 'Map', `(${size})`);
                    keys = getKeys(value, ctx.showHidden);
                    formatter = (ctx, v, recurseTimes) => formatMap(value, ctx, recurseTimes);
                    if (size === 0 && keys.length === 0 && protoProps === undefined) return `${prefix}{}`;
                    braces = [`${prefix}{`, '}'];
                  } else if (isTypedArray(value)) {
                    keys = getOwnNonIndexProperties(value, ctx.showHidden);
                    const fallback = constructor === null ? typedArrayTag.call(value) : '';
                    const size = getter(typedArrayProto, 'length').call(value);
                    const prefix = getPrefix(constructor, tag, fallback, `(${size})`);
                    braces = [`${prefix}[`, ']'];
                    if (value.length === 0 && keys.length === 0 && !ctx.showHidden) return `${braces[0]}]`;
                    formatter = (ctx) => formatTypedArray(value, size, ctx);
                    extrasType = kArrayExtrasType;
                    if (ctx.showHidden) {
                      extraKeys = ['BYTES_PER_ELEMENT', 'length', 'byteLength', 'byteOffset', 'buffer'];
                      typedArray = true;
                    }
                  } else if (iteratorTags.includes(Object.prototype.toString.call(value))) {
                    refuse('util.inspect of an iterator');
                  } else {
                    noIterator = true;
                  }
                }
                if (noIterator) {
                  keys = getKeys(value, ctx.showHidden);
                  braces = ['{', '}'];
                  if (typeof value === 'function') {
                    base = getFunctionBase(ctx, value, constructor, tag);
                    if (keys.length === 0 && protoProps === undefined) return base;
                  } else if (constructor === 'Object') {
                    if (isArgumentsObject(value)) {
                      braces[0] = '[Arguments] {';
                    } else if (tag !== '') {
                      braces[0] = `${getPrefix(constructor, tag, 'Object')}{`;
                    }
                    if (keys.length === 0 && protoProps === undefined) return `${braces[0]}}`;
                  } else if (isRegExp(value)) {
                    base = RegExp.prototype.toString.call(constructor !== null ? value : new RegExp(value));
                    const prefix = getPrefix(constructor, tag, 'RegExp');
                    if (prefix !== 'RegExp ') base = `${prefix}${base}`;
                    if ((keys.length === 0 && protoProps === undefined) || (recurseTimes > ctx.depth && ctx.depth !== null)) return base;
                  } else if (isDate(value)) {
                    base = Number.isNaN(Date.prototype.getTime.call(value)) ? Date.prototype.toString.call(value) : Date.prototype.toISOString.call(value);
                    const prefix = getPrefix(constructor, tag, 'Date');
                    if (prefix !== 'Date ') base = `${prefix}${base}`;
                    if (keys.length === 0 && protoProps === undefined) return base;
                  } else if (isError(value)) {
                    refuse('util.inspect of an Error');
                  } else if (isArrayBuffer(value)) {
                    const prefix = getPrefix(constructor, tag, 'ArrayBuffer');
                    if (typedArray === undefined) {
                      formatter = formatArrayBuffer;
                    } else if (keys.length === 0 && protoProps === undefined) {
                      return prefix + `{ [byteLength]: ${formatNumber(value.byteLength, false)} }`;
                    }
                    braces[0] = `${prefix}{`;
                    extraKeys = ['byteLength'];
                  } else if (isDataView(value)) {
                    braces[0] = `${getPrefix(constructor, tag, 'DataView')}{`;
                    extraKeys = ['byteLength', 'byteOffset', 'buffer'];
                  } else if (isPromise(value)) {
                    refuse('util.inspect of a Promise');
                  } else if (isWeakSet(value) || isWeakMap(value)) {
                    if (ctx.showHidden) refuse('util.inspect of WeakMap or WeakSet entries');
                    braces[0] = `${getPrefix(constructor, tag, isWeakSet(value) ? 'WeakSet' : 'WeakMap')}{`;
                    formatter = () => ['<items unknown>'];
                  } else if (typeof value === 'object' && boxType(value)) {
                    base = getBoxedBase(value, ctx, keys, constructor, tag);
                    if (keys.length === 0 && protoProps === undefined) return base;
                  } else {
                    if (keys.length === 0 && protoProps === undefined) return `${getCtxStyle(value, constructor, tag)}{}`;
                    braces[0] = `${getCtxStyle(value, constructor, tag)}{`;
                  }
                }

                if (recurseTimes > ctx.depth && ctx.depth !== null) {
                  let constructorName = getCtxStyle(value, constructor, tag).slice(0, -1);
                  if (constructor !== null) constructorName = `[${constructorName}]`;
                  return constructorName;
                }
                recurseTimes += 1;
                ctx.seen.push(value);
                ctx.currentDepth = recurseTimes;
                const output = formatter(ctx, value, recurseTimes);
                if (extraKeys !== undefined) {
                  for (const key of extraKeys) output.push(formatExtraProperties(ctx, value, recurseTimes, key, typedArray));
                }
                for (const key of keys) output.push(formatProperty(ctx, value, recurseTimes, key, extrasType));
                if (protoProps !== undefined) output.push(...protoProps);
                if (ctx.circular !== undefined) {
                  const index = ctx.circular.get(value);
                  if (index !== undefined) {
                    const reference = `<ref *${index}>`;
                    if (ctx.compact !== true) {
                      base = base === '' ? reference : `${reference} ${base}`;
                    } else {
                      braces[0] = `${reference} ${braces[0]}`;
                    }
                  }
                }
                ctx.seen.pop();
                if (ctx.sorted) {
                  const comparator = ctx.sorted === true ? undefined : ctx.sorted;
                  if (extrasType === kObjectType) {
                    output.sort(comparator);
                  } else if (keys.length > 1) {
                    const sorted = output.slice(output.length - keys.length).sort(comparator);
                    output.splice(output.length - keys.length, keys.length, ...sorted);
                  }
                }
                const res = reduceToSingleString(ctx, output, base, braces, extrasType, recurseTimes, value);
                const newLength = (ctx.budget[ctx.indentationLvl] || 0) + res.length;
                ctx.budget[ctx.indentationLvl] = newLength;
                if (newLength > 2 ** 27) ctx.depth = -1;
                return res;
              }

              function getBoxedBase(value, ctx, keys, constructor, tag) {
                const [type, fn] = boxType(value);
                if (type === 'String') keys.splice(0, value.length);
                let base = `[${type}`;
                if (type !== constructor) base += constructor === null ? ' (null prototype)' : ` (${constructor})`;
                base += `: ${formatPrimitive(fn.call(value), ctx)}]`;
                if (tag !== '' && tag !== constructor) base += ` [${tag}]`;
                return base;
              }

              function getClassBase(value, constructor, tag) {
                const hasName = Object.prototype.hasOwnProperty.call(value, 'name');
                const name = (hasName && value.name) || '(anonymous)';
                let base = `class ${name}`;
                if (constructor !== 'Function' && constructor !== null) base += ` [${constructor}]`;
                if (tag !== '' && constructor !== tag) base += ` [${tag}]`;
                if (constructor !== null) {
                  const superName = Object.getPrototypeOf(value).name;
                  if (superName) base += ` extends ${superName}`;
                } else {
                  base += ' extends [null prototype]';
                }
                return `[${base}]`;
              }

              function getFunctionBase(ctx, value, constructor, tag) {
                const stringified = functionToString.call(value);
                if (stringified.startsWith('class') && stringified[stringified.length - 1] === '}') {
                  const slice = stringified.slice(5, -1);
                  const bracketIndex = slice.indexOf('{');
                  if (bracketIndex !== -1 && (!slice.slice(0, bracketIndex).includes('(') ||
                      classRegExp.exec(slice.replace(stripCommentsRegExp, '')) !== null)) {
                    return getClassBase(value, constructor, tag);
                  }
                }
                const proto = Object.getPrototypeOf(value);
                let type = 'Function';
                if (proto === generatorFunctionProto || proto === asyncGeneratorFunctionProto) type = `Generator${type}`;
                if (proto === asyncFunctionProto || proto === asyncGeneratorFunctionProto) type = `Async${type}`;
                let base = `[${type}`;
                if (constructor === null) base += ' (null prototype)';
                if (value.name === '') {
                  base += ' (anonymous)';
                } else {
                  base += `: ${typeof value.name === 'string' ? value.name : formatValue(ctx, value.name)}`;
                }
                base += ']';
                if (constructor !== type && constructor !== null) base += ` ${constructor}`;
                if (tag !== '' && constructor !== tag) base += ` [${tag}]`;
                return base;
              }

              function addQuotes(str, quotes) {
                if (quotes === -1) return `"${str}"`;
                if (quotes === -2) return `\`${str}\``;
                return `'${str}'`;
              }

              function escapeFn(str) {
                const charCode = str.charCodeAt(0);
                return meta.length > charCode ? meta[charCode] : `\\u${charCode.toString(16)}`;
              }

              function strEscape(str) {
                let escapeTest = strEscapeSequencesRegExp;
                let escapeReplace = strEscapeSequencesReplacer;
                let singleQuote = 39;
                if (str.includes("'")) {
                  if (!str.includes('"')) {
                    singleQuote = -1;
                  } else if (!str.includes('`') && !str.includes('${')) {
                    singleQuote = -2;
                  }
                  if (singleQuote !== 39) {
                    escapeTest = strEscapeSequencesRegExpSingle;
                    escapeReplace = strEscapeSequencesReplacerSingle;
                  }
                }
                if (str.length < 5000 && escapeTest.exec(str) === null) return addQuotes(str, singleQuote);
                if (str.length > 100) {
                  str = str.replace(escapeReplace, escapeFn);
                  return addQuotes(str, singleQuote);
                }
                let result = '';
                let last = 0;
                for (let i = 0; i < str.length; i++) {
                  const point = str.charCodeAt(i);
                  if (point === singleQuote || point === 92 || point < 32 || (point > 126 && point < 160)) {
                    result += last === i ? meta[point] : `${str.slice(last, i)}${meta[point]}`;
                    last = i + 1;
                  } else if (point >= 0xd800 && point <= 0xdfff) {
                    if (point <= 0xdbff && i + 1 < str.length) {
                      const next = str.charCodeAt(i + 1);
                      if (next >= 0xdc00 && next <= 0xdfff) {
                        i++;
                        continue;
                      }
                    }
                    result += `${str.slice(last, i)}\\u${point.toString(16)}`;
                    last = i + 1;
                  }
                }
                if (last !== str.length) result += str.slice(last);
                return addQuotes(result, singleQuote);
              }

              function addNumericSeparator(integerString) {
                let result = '';
                let i = integerString.length;
                const start = integerString[0] === '-' ? 1 : 0;
                for (; i >= start + 4; i -= 3) result = `_${integerString.slice(i - 3, i)}${result}`;
                return i === integerString.length ? integerString : `${integerString.slice(0, i)}${result}`;
              }

              function addNumericSeparatorEnd(integerString) {
                let result = '';
                let i = 0;
                for (; i < integerString.length - 3; i += 3) result += `${integerString.slice(i, i + 3)}_`;
                return i === 0 ? integerString : `${result}${integerString.slice(i)}`;
              }

              const remainingText = (remaining) => `... ${remaining} more item${remaining > 1 ? 's' : ''}`;

              function formatNumber(number, numericSeparator) {
                if (Object.is(number, -0)) return '-0';
                if (!numericSeparator) return `${number}`;
                const numberString = String(number);
                const integer = Math.trunc(number);
                if (integer === number) {
                  if (!Number.isFinite(number) || numberString.includes('e')) return numberString;
                  return addNumericSeparator(numberString);
                }
                if (Number.isNaN(number) || numberString.includes('e')) return numberString;
                const decimalIndex = numberString.indexOf('.');
                return `${addNumericSeparator(numberString.slice(0, decimalIndex))}.${addNumericSeparatorEnd(numberString.slice(decimalIndex + 1))}`;
              }

              function formatBigInt(bigint, numericSeparator) {
                const string = String(bigint);
                return numericSeparator ? `${addNumericSeparator(string)}n` : `${string}n`;
              }

              function formatPrimitive(value, ctx) {
                if (typeof value === 'string') {
                  let trailer = '';
                  if (value.length > ctx.maxStringLength) {
                    const remaining = value.length - ctx.maxStringLength;
                    value = value.slice(0, ctx.maxStringLength);
                    trailer = `... ${remaining} more character${remaining > 1 ? 's' : ''}`;
                  }
                  if (ctx.compact !== true && value.length > kMinLineLength && value.length > ctx.breakLength - ctx.indentationLvl - 4) {
                    return value.split(/(?<=\n)/).map((line) => strEscape(line)).join(` +\n${' '.repeat(ctx.indentationLvl + 2)}`) + trailer;
                  }
                  return strEscape(value) + trailer;
                }
                if (typeof value === 'number') return formatNumber(value, ctx.numericSeparator);
                if (typeof value === 'bigint') return formatBigInt(value, ctx.numericSeparator);
                if (typeof value === 'boolean') return `${value}`;
                if (typeof value === 'undefined') return 'undefined';
                return Symbol.prototype.toString.call(value);
              }

              function formatSpecialArray(ctx, value, recurseTimes, maxLength, output, i) {
                const keys = Object.keys(value);
                let index = i;
                for (; i < keys.length && output.length < maxLength; i++) {
                  const key = keys[i];
                  const tmp = +key;
                  if (tmp > 2 ** 32 - 2) break;
                  if (`${index}` !== key) {
                    if (numberRegExp.exec(key) === null) break;
                    const emptyItems = tmp - index;
                    output.push(`<${emptyItems} empty item${emptyItems > 1 ? 's' : ''}>`);
                    index = tmp;
                    if (output.length === maxLength) break;
                  }
                  output.push(formatProperty(ctx, value, recurseTimes, key, kArrayType));
                  index++;
                }
                const remaining = value.length - index;
                if (output.length !== maxLength) {
                  if (remaining > 0) output.push(`<${remaining} empty item${remaining > 1 ? 's' : ''}>`);
                } else if (remaining > 0) {
                  output.push(remainingText(remaining));
                }
                return output;
              }

              function formatArrayBuffer(ctx, value) {
                const buffer = new Uint8Array(value);
                const shown = Array.from(buffer.subarray(0, Math.min(ctx.maxArrayLength, buffer.length)), (b) => b.toString(16).padStart(2, '0'));
                let str = shown.join(' ');
                const remaining = buffer.length - ctx.maxArrayLength;
                if (remaining > 0) str += ` ... ${remaining} more byte${remaining > 1 ? 's' : ''}`;
                return [`[Uint8Contents]: <${str}>`];
              }

              function formatArray(ctx, value, recurseTimes) {
                const valLen = value.length;
                const len = Math.min(Math.max(0, ctx.maxArrayLength), valLen);
                const remaining = valLen - len;
                const output = [];
                for (let i = 0; i < len; i++) {
                  const desc = Object.getOwnPropertyDescriptor(value, i);
                  if (desc === undefined) return formatSpecialArray(ctx, value, recurseTimes, len, output, i);
                  output.push(formatProperty(ctx, value, recurseTimes, i, kArrayType, desc));
                }
                if (remaining > 0) output.push(remainingText(remaining));
                return output;
              }

              function formatTypedArray(value, length, ctx) {
                const maxLength = Math.min(Math.max(0, ctx.maxArrayLength), length);
                const remaining = value.length - maxLength;
                const output = new Array(maxLength);
                const elementFormatter = value.length > 0 && typeof value[0] === 'number' ? formatNumber : formatBigInt;
                for (let i = 0; i < maxLength; ++i) output[i] = elementFormatter(value[i], ctx.numericSeparator);
                if (remaining > 0) output[maxLength] = remainingText(remaining);
                return output;
              }

              function formatSet(value, ctx, recurseTimes) {
                const length = value.size;
                const maxLength = Math.min(Math.max(0, ctx.maxArrayLength), length);
                const remaining = length - maxLength;
                const output = [];
                ctx.indentationLvl += 2;
                let i = 0;
                for (const v of Set.prototype.values.call(value)) {
                  if (i >= maxLength) break;
                  output.push(formatValue(ctx, v, recurseTimes));
                  i++;
                }
                if (remaining > 0) output.push(remainingText(remaining));
                ctx.indentationLvl -= 2;
                return output;
              }

              function formatMap(value, ctx, recurseTimes) {
                const length = value.size;
                const maxLength = Math.min(Math.max(0, ctx.maxArrayLength), length);
                const remaining = length - maxLength;
                const output = [];
                ctx.indentationLvl += 2;
                let i = 0;
                for (const { 0: k, 1: v } of Map.prototype.entries.call(value)) {
                  if (i >= maxLength) break;
                  output.push(`${formatValue(ctx, k, recurseTimes)} => ${formatValue(ctx, v, recurseTimes)}`);
                  i++;
                }
                if (remaining > 0) output.push(remainingText(remaining));
                ctx.indentationLvl -= 2;
                return output;
              }

              function formatExtraProperties(ctx, value, recurseTimes, key, typedArray) {
                const extraValue = value[key];
                ctx.indentationLvl += 2;
                const str = formatValue(ctx, extraValue, recurseTimes, typedArray);
                ctx.indentationLvl -= 2;
                return `[${key}]: ${str}`;
              }

              function formatProperty(ctx, value, recurseTimes, key, type, desc, original = value) {
                let name, str;
                let extra = ' ';
                desc ??= Object.getOwnPropertyDescriptor(value, key);
                if (desc.value !== undefined) {
                  const diff = (ctx.compact !== true || type !== kObjectType) ? 2 : 3;
                  ctx.indentationLvl += diff;
                  str = formatValue(ctx, desc.value, recurseTimes);
                  if (diff === 3 && ctx.breakLength < getStringWidth(str)) extra = `\n${' '.repeat(ctx.indentationLvl)}`;
                  ctx.indentationLvl -= diff;
                } else if (desc.get !== undefined) {
                  const label = desc.set !== undefined ? 'Getter/Setter' : 'Getter';
                  if (ctx.getters && (ctx.getters === true || (ctx.getters === 'get' && desc.set === undefined) ||
                      (ctx.getters === 'set' && desc.set !== undefined))) {
                    ctx.indentationLvl += 2;
                    try {
                      const tmp = desc.get.call(original);
                      if (tmp === null) {
                        str = `[${label}: null]`;
                      } else if (typeof tmp === 'object' || typeof tmp === 'function') {
                        str = `[${label}] ${formatValue(ctx, tmp, recurseTimes)}`;
                      } else {
                        str = `[${label}: ${formatPrimitive(tmp, ctx)}]`;
                      }
                    } catch (err) {
                      str = `[${label}: <Inspection threw (${formatValue(ctx, err, recurseTimes)})>]`;
                    }
                    ctx.indentationLvl -= 2;
                  } else {
                    str = `[${label}]`;
                  }
                } else if (desc.set !== undefined) {
                  str = '[Setter]';
                } else {
                  str = 'undefined';
                }
                if (type === kArrayType) return str;
                if (typeof key === 'symbol') {
                  name = Symbol.prototype.toString.call(key).replace(strEscapeSequencesReplacer, escapeFn);
                } else if (keyStrRegExp.exec(key) !== null) {
                  name = key === '__proto__' ? "['__proto__']" : key;
                } else {
                  name = strEscape(key);
                }
                if (desc.enumerable === false) name = `[${name}]`;
                return `${name}:${extra}${str}`;
              }

              function groupArrayElements(ctx, output, value) {
                let totalLength = 0;
                let maxLength = 0;
                let i = 0;
                let outputLength = output.length;
                if (ctx.maxArrayLength < output.length) outputLength--;
                const separatorSpace = 2;
                const dataLen = new Array(outputLength);
                for (; i < outputLength; i++) {
                  const len = getStringWidth(output[i]);
                  dataLen[i] = len;
                  totalLength += len + separatorSpace;
                  if (maxLength < len) maxLength = len;
                }
                const actualMax = maxLength + separatorSpace;
                if (actualMax * 3 + ctx.indentationLvl < ctx.breakLength && (totalLength / actualMax > 5 || maxLength <= 6)) {
                  const approxCharHeights = 2.5;
                  const averageBias = Math.sqrt(actualMax - totalLength / output.length);
                  const biasedMax = Math.max(actualMax - 3 - averageBias, 1);
                  const columns = Math.min(
                    Math.round(Math.sqrt(approxCharHeights * biasedMax * outputLength) / biasedMax),
                    Math.floor((ctx.breakLength - ctx.indentationLvl) / actualMax),
                    ctx.compact * 4,
                    15,
                  );
                  if (columns <= 1) return output;
                  const tmp = [];
                  const maxLineLength = [];
                  for (let i = 0; i < columns; i++) {
                    let lineMaxLength = 0;
                    for (let j = i; j < output.length; j += columns) {
                      if (dataLen[j] > lineMaxLength) lineMaxLength = dataLen[j];
                    }
                    maxLineLength[i] = lineMaxLength + separatorSpace;
                  }
                  let padStart = true;
                  if (value !== undefined) {
                    for (let i = 0; i < output.length; i++) {
                      if (typeof value[i] !== 'number' && typeof value[i] !== 'bigint') {
                        padStart = false;
                        break;
                      }
                    }
                  }
                  for (let i = 0; i < outputLength; i += columns) {
                    const max = Math.min(i + columns, outputLength);
                    let str = '';
                    let j = i;
                    for (; j < max - 1; j++) {
                      const padding = maxLineLength[j - i] + output[j].length - dataLen[j];
                      str += padStart ? `${output[j]}, `.padStart(padding, ' ') : `${output[j]}, `.padEnd(padding, ' ');
                    }
                    if (padStart) {
                      str += output[j].padStart(maxLineLength[j - i] + output[j].length - dataLen[j] - separatorSpace, ' ');
                    } else {
                      str += output[j];
                    }
                    tmp.push(str);
                  }
                  if (ctx.maxArrayLength < output.length) tmp.push(output[outputLength]);
                  output = tmp;
                }
                return output;
              }

              function isBelowBreakLength(ctx, output, start, base) {
                if (ctx.breakLength === Infinity) {
                  if (base !== '' && base.includes('\n')) return false;
                  return !output.some((entry) => typeof entry === 'string' && entry.includes('\n'));
                }
                let totalLength = output.length + start;
                if (totalLength + output.length > ctx.breakLength) return false;
                for (let i = 0; i < output.length; i++) {
                  totalLength += output[i].length;
                  if (totalLength > ctx.breakLength) return false;
                }
                return base === '' || !base.includes('\n');
              }

              function reduceToSingleString(ctx, output, base, braces, extrasType, recurseTimes, value) {
                if (ctx.compact !== true) {
                  if (typeof ctx.compact === 'number' && ctx.compact >= 1) {
                    const entries = output.length;
                    if (extrasType === kArrayExtrasType && entries > 6) output = groupArrayElements(ctx, output, value);
                    if (ctx.currentDepth - recurseTimes < ctx.compact && entries === output.length) {
                      const start = output.length + ctx.indentationLvl + braces[0].length + base.length + 10;
                      if (isBelowBreakLength(ctx, output, start, base)) {
                        const joinedOutput = output.join(', ');
                        if (!joinedOutput.includes('\n')) return `${base ? `${base} ` : ''}${braces[0]} ${joinedOutput}` + ` ${braces[1]}`;
                      }
                    }
                  }
                  const indentation = `\n${' '.repeat(ctx.indentationLvl)}`;
                  return `${base ? `${base} ` : ''}${braces[0]}${indentation}  ${output.join(`,${indentation}  `)}${indentation}${braces[1]}`;
                }
                if (isBelowBreakLength(ctx, output, 0, base)) return `${braces[0]}${base ? ` ${base}` : ''} ${output.join(', ')} ` + braces[1];
                const indentation = ' '.repeat(ctx.indentationLvl);
                const ln = base === '' && braces[0].length === 1 ? ' ' : `${base ? ` ${base}` : ''}\n${indentation}  `;
                return `${braces[0]}${ln}${output.join(`,\n${indentation}  `)} ${braces[1]}`;
              }

              function hasBuiltInToString(value) {
                let hasOwnToString = (o, k) => Object.prototype.hasOwnProperty.call(o, k);
                let hasOwnToPrimitive = hasOwnToString;
                if (typeof value.toString !== 'function') {
                  if (typeof value[Symbol.toPrimitive] !== 'function') return true;
                  if (Object.prototype.hasOwnProperty.call(value, Symbol.toPrimitive)) return false;
                  hasOwnToString = () => false;
                } else if (Object.prototype.hasOwnProperty.call(value, 'toString')) {
                  return false;
                } else if (typeof value[Symbol.toPrimitive] !== 'function') {
                  hasOwnToPrimitive = () => false;
                } else if (Object.prototype.hasOwnProperty.call(value, Symbol.toPrimitive)) {
                  return false;
                }
                let pointer = value;
                do {
                  pointer = Object.getPrototypeOf(pointer);
                } while (!hasOwnToString(pointer, 'toString') && !hasOwnToPrimitive(pointer, Symbol.toPrimitive));
                const descriptor = Object.getOwnPropertyDescriptor(pointer, 'constructor');
                return descriptor !== undefined && typeof descriptor.value === 'function' && builtInObjects.has(descriptor.value.name);
              }

              let circularErrorMessage;
              function tryStringify(arg) {
                try {
                  return JSON.stringify(arg);
                } catch (err) {
                  if (!circularErrorMessage) {
                    try {
                      const a = {};
                      a.a = a;
                      JSON.stringify(a);
                    } catch (circularError) {
                      circularErrorMessage = circularError.message.split('\n', 1)[0];
                    }
                  }
                  if (err.name === 'TypeError' && err.message.split('\n', 1)[0] === circularErrorMessage) return '[Circular]';
                  throw err;
                }
              }

              function formatWithOptions(inspectOptions, args) {
                const first = args[0];
                let a = 0;
                let str = '';
                let join = '';
                if (typeof first === 'string') {
                  if (args.length === 1) return first;
                  let tempStr;
                  let lastPos = 0;
                  for (let i = 0; i < first.length - 1; i++) {
                    if (first.charCodeAt(i) === 37) {
                      const nextChar = first.charCodeAt(++i);
                      if (a + 1 !== args.length) {
                        switch (nextChar) {
                          case 115: {
                            const tempArg = args[++a];
                            if (typeof tempArg === 'number') {
                              tempStr = formatNumber(tempArg, inspectOptions?.numericSeparator);
                            } else if (typeof tempArg === 'bigint') {
                              tempStr = formatBigInt(tempArg, inspectOptions?.numericSeparator);
                            } else if (typeof tempArg !== 'object' || tempArg === null || !hasBuiltInToString(tempArg)) {
                              tempStr = String(tempArg);
                            } else {
                              tempStr = inspect(tempArg, { ...inspectOptions, compact: 3, colors: false, depth: 0 });
                            }
                            break;
                          }
                          case 106:
                            tempStr = tryStringify(args[++a]);
                            break;
                          case 100: {
                            const tempNum = args[++a];
                            if (typeof tempNum === 'bigint') tempStr = formatBigInt(tempNum, inspectOptions?.numericSeparator);
                            else if (typeof tempNum === 'symbol') tempStr = 'NaN';
                            else tempStr = formatNumber(Number(tempNum), inspectOptions?.numericSeparator);
                            break;
                          }
                          case 79:
                            tempStr = inspect(args[++a], inspectOptions);
                            break;
                          case 111:
                            tempStr = inspect(args[++a], { ...inspectOptions, showHidden: true, showProxy: true, depth: 4 });
                            break;
                          case 105: {
                            const tempInteger = args[++a];
                            if (typeof tempInteger === 'bigint') tempStr = formatBigInt(tempInteger, inspectOptions?.numericSeparator);
                            else if (typeof tempInteger === 'symbol') tempStr = 'NaN';
                            else tempStr = formatNumber(Number.parseInt(tempInteger), inspectOptions?.numericSeparator);
                            break;
                          }
                          case 102: {
                            const tempFloat = args[++a];
                            if (typeof tempFloat === 'symbol') tempStr = 'NaN';
                            else tempStr = formatNumber(Number.parseFloat(tempFloat), inspectOptions?.numericSeparator);
                            break;
                          }
                          case 99:
                            a += 1;
                            tempStr = '';
                            break;
                          case 37:
                            str += first.slice(lastPos, i);
                            lastPos = i + 1;
                            continue;
                          default:
                            continue;
                        }
                        if (lastPos !== i - 1) str += first.slice(lastPos, i - 1);
                        str += tempStr;
                        lastPos = i + 1;
                      } else if (nextChar === 37) {
                        str += first.slice(lastPos, i);
                        lastPos = i + 1;
                      }
                    }
                  }
                  if (lastPos !== 0) {
                    a++;
                    join = ' ';
                    if (lastPos < first.length) str += first.slice(lastPos);
                  }
                }
                while (a < args.length) {
                  const value = args[a];
                  str += join;
                  str += typeof value !== 'string' ? inspect(value, inspectOptions) : value;
                  join = ' ';
                  a++;
                }
                return str;
              }

              // Node's globals, as far as they go without files, processes or the network.
              function stream(fd, name) {
                return guard({
                  write(chunk, ...rest) {
                    if (typeof chunk !== 'string' || rest.length !== 0) refuse(`${name}.write with anything but text`);
                    out(fd, chunk);
                    return true;
                  },
                }, name);
              }
              const process = guard({ stdout: stream(1, 'process.stdout'), stderr: stream(2, 'process.stderr'), [Symbol.toStringTag]: 'process' }, 'process');
              const util = guard({
                inspect,
                format: (...args) => formatWithOptions(undefined, args),
                formatWithOptions: (options, ...args) => formatWithOptions(options, args),
              }, 'util');
              const modules = { process, util };
              const require = guard(function require(id) {
                const name = typeof id === 'string' && id.startsWith('node:') ? id.slice(5) : id;
                if (Object.prototype.hasOwnProperty.call(modules, name)) return modules[name];
                const error = new Error(`Cannot find module '${id}'`);
                error.code = 'MODULE_NOT_FOUND';
                throw error;
              }, 'require', ['call', 'apply', 'bind']);
              const print = (fd) => (...args) => out(fd, formatWithOptions(undefined, args) + '\n');
              const console = guard({
                log: print(1), info: print(1), debug: print(1), warn: print(2), error: print(2),
                dir(object, options) { out(1, inspect(object, { customInspect: false, ...options }) + '\n'); },
                [Symbol.toStringTag]: 'console',
              }, 'console');

              // Timers run after the script, in order of when they are due, as Node's event loop runs them.
              class Timeout {
                constructor(timer) { this[timerKey] = timer; }
                ref() { this[timerKey].ref = true; return this; }
                unref() { this[timerKey].ref = false; return this; }
                hasRef() { return this[timerKey].ref; }
                [Symbol.toPrimitive]() { return this[timerKey].id; }
                [customInspectSymbol]() { refuse('util.inspect of a Timeout'); }
              }
              const timerKey = Symbol('timer');
              function schedule(callback, delay, args, repeat) {
                if (typeof callback !== 'function') {
                  const error = new TypeError(`The "callback" argument must be of type function. Received ${inspect(callback)}`);
                  error.code = 'ERR_INVALID_ARG_TYPE';
                  throw error;
                }
                delay *= 1;
                if (!(delay >= 1 && delay <= 2 ** 31 - 1)) delay = 1;
                const timer = { id: ++state.seq, seq: state.seq, due: state.now + delay, delay, callback, args, repeat, ref: true };
                timer.timeout = new Timeout(timer);
                state.timers.push(timer);
                return timer.timeout;
              }
              function clear(timeout) {
                const timer = timeout && typeof timeout === 'object' ? timeout[timerKey]
                  : state.timers.find((t) => t.id === Number(timeout));
                state.timers = state.timers.filter((t) => t !== timer);
              }
              function uncaught(error) {
                if (state.draining) {
                  if (!state.refused) state.refused = lateInSession;
                  return;
                }
                if (state.error === undefined) state.error = describe(error);
                state.dead = true;
              }
              function describe(error) {
                if (error instanceof Error) {
                  let message = String(error.message);
                  const missing = /^Can't find variable: (.*)$/.exec(message);
                  if (error.name === 'ReferenceError' && missing) message = `${missing[1]} is not defined`;
                  return message === '' ? String(error.name) : `${error.name}: ${message}`;
                }
                try { return `Uncaught ${inspect(error)}`; } catch { return 'Uncaught exception'; }
              }

              const AsyncFunction = (async function () {}).constructor;
              // A script that doesn't parse, which node may run as an ES module. Any `import` or `export`
              // counts, even in a string or comment.
              function moduleOnly(source) {
                if (/\b(import|export)\b/.test(source)) return true;
                try { new AsyncFunction(source); } catch { return false; }
                try { new Function(source); return false; } catch { return true; }
              }
              // `import()`, which parses in a script and never settles here.
              const dynamicImport = /(?<![\w$.])import\s*(\(|\/[*\/])/;

              const module = guard({ exports: {} }, 'module');
              const globals = {
                console, process, global: globalThis, Proxy: ProxyConstructor,
                setTimeout: (callback, delay, ...args) => schedule(callback, delay, args, false),
                setInterval: (callback, delay, ...args) => schedule(callback, delay, args, true),
                clearTimeout: clear, clearInterval: clear,
                queueMicrotask(callback) {
                  if (typeof callback !== 'function') throw new TypeError('The "callback" argument must be of type function.');
                  Promise.resolve().then(() => { try { callback(); } catch (error) { uncaught(error); } });
                },
              };
              // A promise callback that throws after a session's block ends its session in node.
              const then = Promise.prototype.then;
              const late = (callback) => typeof callback !== 'function' ? callback : function (value) {
                try {
                  return callback(value);
                } catch (error) {
                  if (state.draining && !state.refused) state.refused = lateInSession;
                  throw error;
                }
              };
              Object.defineProperty(Promise.prototype, 'then', {
                value: { then(onFulfilled, onRejected) { return then.call(this, late(onFulfilled), late(onRejected)); } }.then,
                writable: true, configurable: true,
              });
              // Node's enumerable globals, in node's order; `node -e` adds a module's names after them.
              const enumerable = [
                'global', 'clearImmediate', 'setImmediate', 'clearInterval', 'clearTimeout', 'setInterval', 'setTimeout',
                'queueMicrotask', 'structuredClone', 'atob', 'btoa', 'performance', 'fetch', 'crypto', 'navigator', 'sessionStorage',
              ];
              const moduleScope = session ? { __filename: '[eval]', module, exports: module.exports, __dirname: '.', require } : {};
              for (const name of enumerable) {
                if (Object.prototype.hasOwnProperty.call(globals, name)) {
                  Object.defineProperty(globalThis, name, { value: globals[name], writable: true, configurable: true, enumerable: true });
                } else {
                  Object.defineProperty(globalThis, name, { get() { refuse(name); }, configurable: true, enumerable: true });
                }
              }
              for (const [name, value] of Object.entries(moduleScope)) {
                Object.defineProperty(globalThis, name, { value, writable: true, configurable: true, enumerable: true });
              }
              for (const [name, value] of Object.entries(globals)) {
                if (!enumerable.includes(name)) Object.defineProperty(globalThis, name, { value, writable: true, configurable: true, enumerable: false });
              }
              // Node 26's other globals that JavaScriptCore lacks.
              for (const name of [
                'AbortController', 'AbortSignal', 'AsyncDisposableStack', 'atob', 'Blob', 'BroadcastChannel', 'btoa', 'Buffer',
                'ByteLengthQueuingStrategy', 'clearImmediate', 'CloseEvent', 'CompressionStream', 'CountQueuingStrategy', 'Crypto',
                'crypto', 'CryptoKey', 'CustomEvent', 'DecompressionStream', 'DisposableStack', 'DOMException', 'ErrorEvent', 'Event',
                'EventTarget', 'fetch', 'File', 'FormData', 'Headers', 'localStorage', 'MessageChannel', 'MessageEvent', 'MessagePort',
                'Navigator', 'navigator', 'Performance', 'performance', 'PerformanceEntry', 'PerformanceMark', 'PerformanceMeasure',
                'PerformanceObserver', 'PerformanceObserverEntryList', 'PerformanceResourceTiming', 'QuotaExceededError',
                'ReadableByteStreamController', 'ReadableStream', 'ReadableStreamBYOBReader', 'ReadableStreamBYOBRequest',
                'ReadableStreamDefaultController', 'ReadableStreamDefaultReader', 'Request', 'Response', 'sessionStorage',
                'setImmediate', 'SharedArrayBuffer', 'Storage', 'structuredClone', 'SubtleCrypto', 'SuppressedError', 'Temporal',
                'TextDecoder', 'TextDecoderStream', 'TextEncoder', 'TextEncoderStream', 'TransformStream',
                'TransformStreamDefaultController', 'URL', 'URLPattern', 'URLSearchParams', 'WebSocket', 'WritableStream',
                'WritableStreamDefaultController', 'WritableStreamDefaultWriter'
              ]) {
                if (!(name in globalThis)) {
                  Object.defineProperty(globalThis, name, { get() { refuse(name); }, configurable: true });
                }
              }

              // JavaScriptCore's stack text isn't V8's, so errors get none and reading one is refused. In
              // node an error's own keys include `stack`.
              Error.stackTraceLimit = 0;
              const refusing = (name) => ({ get() { refuse(name); }, set() { refuse(name); }, configurable: true });
              Object.defineProperty(Error, 'stackTraceLimit', { ...refusing('Error.stackTraceLimit'), enumerable: true });
              Object.defineProperty(Error, 'captureStackTrace', refusing('Error.captureStackTrace'));
              Object.defineProperty(Error.prototype, 'stack', {
                get() { refuse('Error.stack'); },
                set(value) { Object.defineProperty(this, 'stack', { value, writable: true, configurable: true }); },
                configurable: true,
              });
              const errorLike = (v) => v === Error.prototype || isError(v);
              // Calls `test` refuses, with what they use.
              function refuseCalls(object, name, test) {
                object[name] = new RealProxy(object[name], {
                  apply(target, self, args) {
                    const what = test(self, args);
                    if (what) refuse(what);
                    return Reflect.apply(target, self, args);
                  },
                });
              }
              const errors = "an error's own properties";
              // The global object behind the script's proxies. Its enumerable names are node's, but
              // the order of all of them is JavaScriptCore's.
              const isGlobal = (v) => {
                for (let p = proxies.get(v); p; p = proxies.get(v)) v = p[0];
                return v === globalThis;
              };
              const listing = (v) => isGlobal(v) ? "a list of the global object's properties" : '';
              for (const [object, name] of [[Object, 'getOwnPropertyNames'], [Object, 'getOwnPropertyDescriptors'], [Reflect, 'ownKeys']]) {
                refuseCalls(object, name, (self, [v]) => listing(v) || (errorLike(v) ? errors : ''));
              }
              refuseCalls(Object, 'getOwnPropertySymbols', (self, [v]) => listing(v));
              // A session's `var`s come first in JavaScriptCore and last in node.
              if (session) refuseCalls(Object, 'keys', (self, [v]) => listing(v));
              const sessionListing = /\bfor\s*\([^)]*\bin\s+(globalThis|global|this)\s*\)/;
              for (const [object, name] of [[Object, 'getOwnPropertyDescriptor'], [Object, 'hasOwn'], [Reflect, 'getOwnPropertyDescriptor']]) {
                refuseCalls(object, name, (self, [v, key]) => key === 'stack' && errorLike(v) ? errors : '');
              }
              for (const name of ['hasOwnProperty', 'propertyIsEnumerable']) {
                refuseCalls(Object.prototype, name, (self, [key]) => key === 'stack' && errorLike(self) ? errors : '');
              }
              // A built-in function's text is laid out differently from V8's, and the functions here
              // are native in node.
              const shimText = functionToString.call(shim);
              refuseCalls(Function.prototype, 'toString', (self) => {
                let text;
                try { text = functionToString.call(self); } catch { return ''; }
                return /\[native code\]\s*\}$/.test(text) || shimText.includes(text) ? "a built-in function's source text" : '';
              });

              return {
                // A script run as `node` runs a CommonJS file; an uncaught error ends it. `__filename`
                // and `__dirname` name Emacs's temporary file.
                main(source) {
                  if (/\b__(filename|dirname)\b/.test(source)) {
                    state.refused = '__filename or __dirname';
                    return;
                  }
                  if (dynamicImport.test(source)) {
                    state.refused = 'top-level await, import or export';
                    return;
                  }
                  let body;
                  try {
                    body = new Function('exports', 'require', 'module', '__filename', '__dirname', source);
                  } catch (error) {
                    // node runs a script that doesn't parse as one as an ES module, when that parses.
                    if (error instanceof SyntaxError && moduleOnly(source)) state.refused = 'top-level await, import or export';
                    else uncaught(error);
                    return;
                  }
                  try {
                    body.call(module.exports, module.exports, require, module, undefined, undefined);
                  } catch (error) {
                    uncaught(error);
                  }
                },
                // A session's script, and its value as the session writes it. Promise callbacks run
                // after this returns.
                session(source, value) {
                  Object.assign(state, { dead: false, error: undefined, refused: '', now: Date.now(), draining: false, result: undefined });
                  if (dynamicImport.test(source)) {
                    state.refused = 'top-level await, import or export';
                    return;
                  }
                  if (sessionListing.test(source)) {
                    state.refused = "a list of the global object's properties";
                    return;
                  }
                  Promise.resolve().then(() => { state.draining = true; });
                  const [failed, completion] = script(source);
                  if (failed) {
                    uncaught(completion);
                  } else if (value) {
                    try { state.result = inspect(completion); } catch (error) { uncaught(error); }
                  }
                },
                // Drops a session's timers, which would print after the block in node, and refuses the block.
                settle() {
                  state.draining = false;
                  if (state.timers.length === 0) return;
                  state.timers = [];
                  if (!state.refused) state.refused = 'a timer in a session';
                },
                get result() { return state.result; },
                // Runs the next timer that is due: the milliseconds until one is, 0 after running one,
                // or -1 when none is left to wait for.
                tick() {
                  if (state.dead || !state.timers.some((t) => t.ref)) return -1;
                  state.now = Date.now();
                  const next = state.timers.reduce((a, b) => (b.due < a.due || (b.due === a.due && b.seq < a.seq) ? b : a));
                  if (next.due > state.now) return next.due - state.now;
                  if (next.repeat) {
                    next.due = state.now + next.delay;
                    next.seq = ++state.seq;
                  } else {
                    clear(next.timeout);
                  }
                  try { next.callback.apply(next.timeout, next.args); } catch (error) { uncaught(error); }
                  return 0;
                },
                get error() { return state.error; },
                get refused() { return state.refused; },
              };
            })
            """#
    }
}
#endif
