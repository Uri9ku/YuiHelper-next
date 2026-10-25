'use strict';
// =============================================================================
// S2 运行时取数（oracle）：按逻辑路径调用引擎 DataCache::read，拿「已解密+解压」的明文。
//
// 与解包期的 hook_oracle_v6.js 同一套原理（代码洞 trampoline 调 0x23031c8），
// 区别：请求来自文件、结果落盘并回传清单，供 App 直接消费。
//
// 协议（全部在 /data/local/tmp/yui-spine/）：
//   request.txt      每行一个逻辑路径（不带前导 /、不带 localization 前缀）
//   out/<n>.bin      第 n 条路径的明文
//   result.json      [{n, path, file, size, head, err}]
//   done.txt         完成标记（App 轮询）
// =============================================================================

var OUT_DIR = '/data/user/0/com.bandainamcoent.saoars/files/yui-spine/';
var REQ_FILE = OUT_DIR + 'request.txt';
var RES_FILE = OUT_DIR + 'result.json';
var DONE_FILE = OUT_DIR + 'done.txt';

var TRAMP_CAVE_OFF = 0x127d290;   // .text 内 4084 字节零填充代码洞
var READ_OFF = 0x23031c8;         // DataCache::read(instance, std::string const&, shared_ptr*)

var base = null;
var instance = null;
var readFn = null;
var strInitFn = null;
var started = false;

function safe(fn, dflt) { try { return fn(); } catch (e) { return dflt; } }

function hexHead(buf) {
    if (!buf) return null;
    var bytes = new Uint8Array(buf);
    var n = Math.min(bytes.length, 24);
    var out = '';
    for (var i = 0; i < n; i++) {
        var h = bytes[i].toString(16);
        out += (h.length < 2 ? '0' : '') + h;
    }
    return out;
}

function writeFile(name, bytes) {
    try {
        var f = new File(OUT_DIR + name, 'wb');
        f.write(bytes);
        f.close();
        return true;
    } catch (e) {
        send({ ev: 'write_err', name: name, msg: String(e) });
        return false;
    }
}

function writeText(name, text) {
    try {
        var f = new File(OUT_DIR + name, 'w');
        f.write(text);
        f.close();
        return true;
    } catch (e) {
        send({ ev: 'write_err', name: name, msg: String(e) });
        return false;
    }
}

// libc++ std::string 的短/长字符串布局（与 v6 相同）
function stdStringPtr(p) {
    return safe(function () {
        if (!p || p.isNull()) return null;
        var flag = p.readU8();
        var size, data;
        if (flag & 1) { size = p.add(8).readU64().toNumber(); data = p.add(16).readPointer(); }
        else { size = flag >> 1; data = p.add(1); }
        if (size <= 0 || size > 0x100000) return null;
        return { size: size, text: data.readUtf8String(size) };
    }, null);
}

function w32(arr, w) {
    w = w >>> 0;
    arr.push(w & 0xff, (w >>> 8) & 0xff, (w >>> 16) & 0xff, (w >>> 24) & 0xff);
}

// 把 "mov x8,x2 ; ldr x9,#8 ; br x9" 写进代码洞，参数槽 slot
function patchTramp(cave, target, slot) {
    var a = [];
    w32(a, (0xAA0003E0 | (slot << 16) | 8));   // mov x8, x<slot>
    w32(a, (0x58000000 | (2 << 5) | 9));       // ldr x9, #8
    w32(a, (0xD61F0000 | (9 << 5)));           // br x9
    Memory.patchCode(cave, 16, function (code) {
        code.writeByteArray(a);
        code.add(12).writePointer(target);
    });
}

function makeString(text) {
    var sObj = Memory.alloc(24);
    var buf = Memory.allocUtf8String(text);
    strInitFn(sObj, buf, text.length);
    return sObj;
}

// 读一条路径；成功返回 {path,size,head,file}
function fetchOne(path, n) {
    var res = { n: n, path: path, file: null, size: -1, head: null, err: null };
    try {
        var pathObj = makeString(path);
        var sp = Memory.alloc(16);
        sp.writePointer(ptr(0));
        sp.add(8).writePointer(ptr(0));
        readFn(instance, pathObj, sp);
        var obj = sp.readPointer();
        if (obj.isNull()) { res.err = 'null object'; return res; }
        // Data: [8] = size?  按 v6 的两条路径都试（直接对象 / 二级指针）
        var f8 = safe(function () { return obj.add(8).readU64().toNumber(); }, -1);
        var p16 = safe(function () { return obj.add(16).readPointer(); }, null);
        var data = null, size = -1;
        if (f8 > 16 && f8 < 0x8000000 && p16 && !p16.isNull()) {
            data = p16; size = f8;
        } else {
            var p8 = safe(function () { return obj.add(8).readPointer(); }, null);
            if (p8 && !p8.isNull()) {
                var s2 = safe(function () { return p8.add(8).readU64().toNumber(); }, -1);
                var d2 = safe(function () { return p8.add(16).readPointer(); }, null);
                if (s2 > 16 && s2 < 0x8000000 && d2 && !d2.isNull()) { data = d2; size = s2; }
            }
        }
        if (!data || size <= 0) { res.err = 'no data (f8=' + f8 + ')'; return res; }
        var bytes = data.readByteArray(size);
        res.size = size;
        res.head = hexHead(bytes);
        res.file = 'out/' + n + '.bin';
        if (!writeFile(res.file, bytes)) res.file = null;
    } catch (e) {
        res.err = String(e);
    }
    return res;
}

function runFetch() {
    if (!instance || !readFn) { writeText('done.txt', 'no-instance'); return; }
    var lines = [];
    try {
        lines = File.readAllText(REQ_FILE).split(/\r?\n/);
    } catch (e) {
        writeText('done.txt', 'no-request');
        send({ ev: 'fatal', msg: 'no request file: ' + String(e) });
        return;
    }
    var paths = [];
    for (var i = 0; i < lines.length; i++) {
        var p = (lines[i] || '').trim();
        if (p && p.charAt(0) !== '#') paths.push(p);
    }
    var results = [];
    for (var j = 0; j < paths.length; j++) {
        var alts = paths[j].split('|');
        var r = null;
        for (var k = 0; k < alts.length; k++) {
            r = fetchOne(alts[k].trim(), j + 1);
            if (!r.err) break;
        }
        results.push(r);
        send({ ev: 'fetched', n: r.n, path: r.path, size: r.size, head: r.head, err: r.err });
    }
    writeText('result.json', JSON.stringify(results));
    writeText('done.txt', 'ok:' + results.length);
    send({ ev: 'done', count: results.length, ok: results.filter(function (x) { return !x.err; }).length });
}

function hookAndStart() {
    var m = Process.findModuleByName('libapp.so');
    if (!m) { setTimeout(hookAndStart, 100); return; }
    base = m.base;
    var mod = Process.getModuleByName('libapp.so');
    var initPtr = mod.getExportByName('_ZNSt6__ndk112basic_stringIcNS_11char_traitsIcEENS_9allocatorIcEEE6__initEPKcm');
    var dtorPtr = mod.getExportByName('_ZNSt6__ndk112basic_stringIcNS_11char_traitsIcEENS_9allocatorIcEEED1Ev');
    if (!initPtr || !dtorPtr) { send({ ev: 'fatal', msg: 'string symbols missing' }); return; }
    strInitFn = new NativeFunction(initPtr, 'void', ['pointer', 'pointer', 'size_t']);
    var cave = base.add(TRAMP_CAVE_OFF);
    patchTramp(cave, base.add(READ_OFF), 2);
    readFn = new NativeFunction(cave, 'void', ['pointer', 'pointer', 'pointer']);
    send({ ev: 'hooked', base: base.toString(), cave: cave.toString() });

    // 捕捉 DataCache 实例：第一次 read 的 args[0]
    Interceptor.attach(base.add(READ_OFF), {
        onEnter: function (args) {
            if (!instance) {
                instance = args[0];
                send({ ev: 'instance', instance: instance.toString() });
            }
        }
    });

    // 给游戏 40s 完成启动加载（期间必然产生 read），然后按 request.txt 取数
    setTimeout(function () {
        if (!instance) { writeText('done.txt', 'no-instance-timeout'); send({ ev: 'fatal', msg: 'instance not captured' }); return; }
        if (started) return;
        started = true;
        runFetch();
    }, 40000);
}

hookAndStart();
