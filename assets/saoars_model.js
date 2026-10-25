/*
 * SAOUB 模型替换引擎（zhushou 换模型专用版）
 * ==============================================================
 * 真机验证基础：Xiaomi 24129PN74C / Android 16 / arm64 / KernelSU
 * 游戏版本：3.7.0 / versionCode 4745（libapp.so md5 0ec39731de824dbb0599a31fa08327bb）
 *
 * 只做一件事：角色 A 的模型换成角色 B 的（Spine 骨骼+图集+脸 的变体名改写）。
 * 不做动作替换（那是「SAOUB修改器」的职责），不写存档，不改游戏文件。
 *
 * ---------------------------------------------------------------------------
 * R0 探针结论（2026-10-17 实测，见 docs 设计文档 §2.7）
 * ---------------------------------------------------------------------------
 *   · 0x122fd4c（prologue 0xd10143ff）：双槽格式化函数。
 *       files/spine/characterAtlas/{0}/{1}   x1=骨骼集 chara_N，x2=角色变体名
 *       files/spine/faceAtlas/{0}/{1}        同上
 *       files/spine/characterSpine/{}/{}}    x2=武器内部变体名 f_chara_N_v0.4_*
 *                                            → 只记录，绝不改写
 *   · 0x1229d50（prologue 0xd10103ff）：**通用单槽**格式化函数，UI/语音/特效全走它
 *       → 只处理 files/character/ 前缀（其余 UI/语音/特效一律不碰）
 *   · id 一律是长度前缀缓冲：byte[0]=(len<<1)|flag，数据在 +1，长度显式写回。
 *
 * ---------------------------------------------------------------------------
 * 规则文件 /data/local/tmp/saoub-model-rules.json（每 2 秒热重载）
 * ---------------------------------------------------------------------------
 *   { "rules": { "models": { "kirito_cathedral": "alice_integrator" } } }
 *   兼容旧键名 "skeleton"（= models 别名）。空表 = 关闭全部替换。
 *
 * ---------------------------------------------------------------------------
 * 枚举输出 /data/local/tmp/saoub-model-enum.json（供 APP 下拉框）
 * ---------------------------------------------------------------------------
 *   { "characters": [...], "counts": {...} }  固定 65536 字节（空格补齐）
 *
 * 日志一律 ASCII：frida-inject 的 stdout 重定向到文件后，非 ASCII 会变 '?'。
 */
'use strict';

var CONFIG = {
    module: 'libapp.so',

    fmtSpine: 0x122fd4c,        // files/spine/*（双槽）
    spineExpect: 0xd10143ff,
    fmtCharacter: 0x1229d50,    // 通用单槽（白名单内才处理）
    charExpect: 0xd10103ff,

    rulesPath: '/data/local/tmp/saoub-model-rules.json',
    enumPath: '/data/local/tmp/saoub-model-enum.json',
    pairsPath: '/data/local/tmp/saoub-model-pairs.json',
    bonesPath: '/data/local/tmp/saoub-model-bones.json',
    skeletonsPath: '/data/local/tmp/saoub-model-skeletons.json',
    pollMs: 2000,
    flushMs: 5000,
    logFirst: 20,
};

// 只对这些前缀做改写（R0 结论 1：0x1229d50 是通用格式化函数，白名单外绝不碰）
//
// 真机 PATH 日志实测到的角色专属子路径（全都命中过）：
//   files/character/face/          files/character/card/
//   files/character/battle_status/ files/character/party_portrait/
//   files/character/time_line/     files/character/status/
// 注意：**没有**观测到 `files/character/base/`（当初扩成整个 files/character/ 的理由不成立，
// 已按证据收回成白名单）。`battle_status` 是这轮新观测到的，补进来。
var CHARA_REWRITE_PREFIXES = [
    'files/character/face/',
    'files/character/card/',
    'files/character/party_portrait/',
    'files/character/time_line/',
    'files/character/status/',
    'files/character/battle_status/',
];

// 双槽函数里允许改写变体名的前缀（characterSpine 的 x2 是武器内部名 → 排除）
var SPINE_REWRITE_PREFIXES = [
    'files/spine/characterAtlas/',
    'files/spine/faceAtlas/',
    'files/spine/realCharacterSpine/',
];
// 只记录不改写的（R0 结论 2）
var SPINE_INTERNAL_PREFIX = 'files/spine/characterSpine/';

var SSO_FLAG_MASK = 0x1;
var ENUM_WRITE_BYTES = 65536;

// ---------------------------------------------------------------------------
// 状态
// ---------------------------------------------------------------------------

var MODELS = {};            // {fromId: toId}
var lastRulesText = null;
var nModel = 0;
var nEnumWritten = 0;
var enumErrLogged = false;
var seenChars = {};
var FAMILY = {};          // 身体 id <-> 脸 id 配对（运行时学）
var pendingBodyByBone = {};   // chara_N -> 最近一次身体 id
var bodyTargetByBone = {};    // chara_N -> 本次加载身体改写到的目标（null=没换）
var seenPaths = {};          // 诊断模式去重
var DEBUG_PATHS = false;     // 规则文件里 debug:true 时打开

// 静态配对表（APP 随包携带并部署到设备）：身体 id -> 基础名（faceAtlas 常用 id）。
// 有了它，目标角色**不需要**先被加载过，也能解析出它的脸 id —— 这是
// 「A→B 必须同队才生效」那个问题的根治手段。
var PAIRS = {};              // {variant: baseCharacter}
var nPairsLoaded = 0;

// 骨架集表（APP 随包携带）：图集变体 -> chara_N。
// 模型 = 骨架 + 身体图集 + 脸图集，三者必须同属一个骨架集；跨集只换图集
// 会让模型建不起来（真机现象：黑屏 / 没头）。表来自游戏清单明文（设计文档 §2.12）。
var BONES = {};              // {variant: 'chara_1'|'chara_2'|...}
var nBonesLoaded = 0;

// 骨架文件名表（运行时学）：骨架集 -> 实际骨架文件（如 chara_2 -> f_chara_2_v0.4_sword）。
// 清单明文里**没有** characterSpine（0 条），只能靠"某个该骨架集角色真的加载过"来学；
// 跨骨架集互换时必须用它来改写 characterSpine 的两个槽位。
var SKELS = {};              // {'chara_2': 'f_chara_2_v0.4_sword'}  按骨架集（兜底）
// 真机发现同一骨架集有多个骨架名（chara_1 就有 f_chara_1_v0.4_sword /
// f_chara_1_v0.5_001040 / f_chara_1_v0.5_087005），说明骨架是**按角色**选的。
// 所以再按「角色变体」精确记一份，跨集互换时优先用它。
var CHAR_SKEL = {};          // {角色变体: 它自己用的骨架名}
var nSkelsLearned = 0;
var lastSkelSave = 0;
var crossBoneByBone = {};    // 源骨架集 -> 目标骨架集（同一次角色加载内有效）
var crossSkelByBone = {};    // 源骨架集 -> 本次选定的骨架文件名

function log() {
    var parts = [];
    for (var i = 0; i < arguments.length; i++) parts.push(String(arguments[i]));
    console.log('[saoub-model] ' + parts.join(' '));
}

// ---------------------------------------------------------------------------
// 长度前缀 id 读写
//   byte[0] = (len<<1)|flag，数据在 +1；真机样本 0x22 kirito_woodcutter / 0x12 sinon_ggo
// ---------------------------------------------------------------------------

function readPrefixedId(ptr) {
    try {
        var b0 = ptr.readU8();
        var len = b0 >> 1;
        if (len <= 0 || len > 200) return null;
        var raw = ptr.add(1).readByteArray(len);
        if (!raw) return null;
        var u = new Uint8Array(raw);
        var s = '';
        for (var i = 0; i < u.length; i++) {
            var c = u[i];
            if (c < 32 || c > 126) return null;
            s += String.fromCharCode(c);
        }
        return s;
    } catch (e) { return null; }
}

function writePrefixedId(ptr, newText) {
    try {
        var b0 = ptr.readU8();
        ptr.writeU8(((newText.length << 1) | (b0 & SSO_FLAG_MASK)) & 0xff);
        ptr.add(1).writeUtf8String(newText);
        ptr.add(1 + newText.length).writeU8(0);
        return true;
    } catch (e) { return false; }
}

// ---------------------------------------------------------------------------
// 规则解析 / 热重载
// ---------------------------------------------------------------------------

function decodeModelRules(data) {
    var r = data && data.rules ? data.rules : (data || {});
    return r.models || r.skeleton || {};
}

function setRules(obj) {
    MODELS = decodeModelRules(obj) || {};
    lastRulesText = JSON.stringify(obj);
    return Object.keys(MODELS).length;
}

function getModels() { return MODELS; }

// ---------------------------------------------------------------------------
// 静态配对表：身体 id -> 基础名（脸 id）
//
// 为什么需要：一次角色加载要三个 id（骨架集 / 身体图集 / 脸图集），
// 而身体 id 和脸 id 是**不同的字符串**（桐人：body=kirito_cathedral、face=kirito）。
// 只靠"运行时看到 B 被加载"来学这张表，就会出现
// 「A→B 必须同队才生效、否则脸是空的」——B 没被加载过就学不到它的脸 id。
// 所以 APP 随包带一张从游戏资源生成的表，部署到设备后由脚本读取。
// ---------------------------------------------------------------------------

function loadPairs() {
    try {
        var text;
        try { text = File.readAllText(CONFIG.pairsPath); }
        catch (e) { return false; }
        if (!text) return false;
        var data = JSON.parse(text);
        var v = (data && data.variants) || data || {};
        var n = 0;
        for (var k in v) {
            if (typeof v[k] === 'string' && v[k]) { PAIRS[k] = v[k]; n++; }
        }
        nPairsLoaded = n;
        log('PAIRS loaded: ' + n);
        return true;
    } catch (e) {
        log('pairs load failed: ' + e.message);
        return false;
    }
}

// 身体 id -> 脸 id。静态表精确命中最好；否则逐级去掉尾部 _token 再查
// （真机见过 alice_alo_4lb / eugeo_child_2020may 这类带后缀的 id）。
function baseOf(id) {
    if (!id) return null;
    if (PAIRS[id]) return PAIRS[id];
    var parts = id.split('_');
    for (var i = parts.length - 1; i >= 1; i--) {
        var cand = parts.slice(0, i).join('_');
        if (PAIRS[cand]) return PAIRS[cand];
    }
    return null;
}

// 骨架集表：变体 -> chara_N。只做精确匹配 + 逐级去尾（只认表里真有的项）。
function loadBones() {
    try {
        var text;
        try { text = File.readAllText(CONFIG.bonesPath); }
        catch (e) { return false; }
        if (!text) return false;
        var data = JSON.parse(text);
        var v = (data && data.variants) || data || {};
        var n = 0;
        for (var k in v) {
            if (typeof v[k] === 'string' && v[k]) { BONES[k] = v[k]; n++; }
        }
        nBonesLoaded = n;
        log('BONES loaded: ' + n);
        return true;
    } catch (e) {
        log('bones load failed: ' + e.message);
        return false;
    }
}

function boneOf(variant) {
    if (!variant) return null;
    if (BONES[variant]) return BONES[variant];
    var parts = variant.split('_');
    for (var i = parts.length - 1; i >= 1; i--) {
        var cand = parts.slice(0, i).join('_');
        if (BONES[cand]) return BONES[cand];
    }
    return null;
}

// 骨架文件名：从设备文件读回上次学到的（APP 部署时预建 666 文件）。
function loadSkeletons() {
    try {
        var text;
        try { text = File.readAllText(CONFIG.skeletonsPath); }
        catch (e) { return false; }
        if (!text) return false;
        var data = JSON.parse(text);
        var v = (data && data.skeletons) || data || {};
        for (var k in v) {
            if (typeof v[k] === 'string' && v[k]) { SKELS[k] = v[k]; nSkelsLearned++; }
        }
        var c = (data && data.characters) || {};
        for (var k2 in c) {
            if (typeof c[k2] === 'string' && c[k2]) { CHAR_SKEL[k2] = c[k2]; nSkelsLearned++; }
        }
        if (nSkelsLearned) log('SKELS loaded: ' + nSkelsLearned);
        return true;
    } catch (e) {
        log('skeletons load failed: ' + e.message);
        return false;
    }
}

function saveSkeletons() {
    var now = Date.now();
    if (now - lastSkelSave < 3000) return;
    lastSkelSave = now;
    try {
        var obj = {}, obj2 = {};
        for (var k in SKELS) obj[k] = SKELS[k];
        for (var k2 in CHAR_SKEL) obj2[k2] = CHAR_SKEL[k2];
        File.writeAllText(CONFIG.skeletonsPath, JSON.stringify({ skeletons: obj, characters: obj2 }));
    } catch (e) { /* 写不了就算了，只是缓存 */ }
}

function skeletonOf(bone) {
    return bone ? (SKELS[bone] || null) : null;
}

// 跨骨架集时给目标角色挑骨架：优先「该角色自己用过的」，其次「该骨架集最近见到的」。
function skeletonFor(variant, bone) {
    if (variant && CHAR_SKEL[variant]) return CHAR_SKEL[variant];
    if (bone && SKELS[bone]) return SKELS[bone];
    return null;
}

// ★ 基础名 -> 真实身体图集变体。
//   UI 里选的是角色（names.tsv 的 `char alice 愛麗絲`），id 是 **基础名** `alice`；
//   但 characterAtlas 的变体必须是真实存在的（alice_integrator / alice_alo / …）。
//   直接把 `alice` 写进身体槽 = 图集不存在 = 模型整片空白（2026-10-18 真机踩到）。
//   优先常见默认装，其次取最短的名字；一个都匹配不到就返回 null（宁可不换）。
var BODY_VARIANT_PREFS = ['_integrator', '_cathedral', '_alo', '_uw', ''];

function bodyVariantFor(target) {
    if (!target) return null;
    if (BONES[target]) return target;
    var anyBones = false;
    for (var _b in BONES) { anyBones = true; break; }
    if (!anyBones) return target;          // 没有骨架集表时保持旧行为
    for (var i = 0; i < BODY_VARIANT_PREFS.length; i++) {
        var cand = target + BODY_VARIANT_PREFS[i];
        if (cand !== target && BONES[cand]) return cand;
    }
    var best = null;
    for (var k in BONES) {
        if (k.indexOf(target + '_') !== 0) continue;
        if (!best || k.length < best.length || (k.length === best.length && k < best)) best = k;
    }
    return best;
}

// 两个 id 是不是同一个角色（同一基础名，或互为前缀）
function sameCharacter(a, b) {
    if (!a || !b) return false;
    if (a === b) return true;
    var ba = baseOf(a);
    var bb = baseOf(b);
    if (ba && bb) return ba === bb;
    return a.indexOf(b) === 0 || b.indexOf(a) === 0;
}

function loadRules() {
    try {
        var text;
        try { text = File.readAllText(CONFIG.rulesPath); }
        catch (e) { return false; }
        if (!text || text === lastRulesText) return false;
        var data = JSON.parse(text);
        MODELS = decodeModelRules(data);
        DEBUG_PATHS = !!(data && (data.debug || (data.rules && data.rules.debug)));
        lastRulesText = text;
        log('RULES reloaded: models ' + Object.keys(MODELS).length + (DEBUG_PATHS ? ' debug' : ''));
        for (var k in MODELS) log('   [model] ' + k + ' -> ' + MODELS[k]);
        return true;
    } catch (e) {
        log('rules parse failed: ' + e.message);
        return false;
    }
}

// ---------------------------------------------------------------------------
// prologue 自检：偏移不匹配 = 游戏更新了，绝不静默失效
// ---------------------------------------------------------------------------

function prologueOk(readU32, expect) {
    return typeof readU32 === 'number' && readU32 === expect;
}

// ---------------------------------------------------------------------------
// 双槽钩子的纯逻辑：返回待写列表（onLeave 落写）
//   x1 = 骨骼集（chara_N / f_chara_N，跳过），x2 = 角色变体名
// ---------------------------------------------------------------------------

function onSpineFormat(fmt, x1, x2) {
    var writes = [];
    if (!fmt) return writes;

    // 诊断开关（规则文件里写 "debug": true 才打开）：
    // 记下每条 files/spine/* 请求的两个槽位，用来定位「某个场景的模型到底走哪条路径」。
    if (DEBUG_PATHS) {
        var d1 = x1 ? readPrefixedId(x1) : null;
        var d2 = x2 ? readPrefixedId(x2) : null;
        var key = fmt + '|' + d1 + '|' + d2;
        if (!seenPaths[key]) {
            seenPaths[key] = 1;
            log('PATH ' + fmt + '  x1=' + d1 + '  x2=' + d2);
        }
    }

    var rewritable = false;
    for (var i = 0; i < SPINE_REWRITE_PREFIXES.length; i++) {
        if (fmt.indexOf(SPINE_REWRITE_PREFIXES[i]) === 0) { rewritable = true; break; }
    }
    var internalOnly = fmt.indexOf(SPINE_INTERNAL_PREFIX) === 0;

    // 枚举：变体名槽位（非骨骼集编号）
    if ((rewritable || internalOnly) && x2) {
        var id2 = readPrefixedId(x2);
        if (id2 && !/^(f_)?chara_/.test(id2)) {
            if (!seenChars[id2]) log('CHAR: ' + id2);
            seenChars[id2] = (seenChars[id2] || 0) + 1;
        }
    }

    var cur2 = x2 ? readPrefixedId(x2) : null;
    var boneRaw = x1 ? (readPrefixedId(x1) || '') : '';
    var bone = boneRaw.replace(/^f_/, '');   // 'chara_1'（x1 在 characterSpine 里是 'f_chara_1'）
    var isBody = fmt.indexOf('files/spine/characterAtlas/') === 0;
    var isFace = fmt.indexOf('files/spine/faceAtlas/') === 0;

    // ★ 学骨架文件名：characterSpine 的 x2 形如 f_chara_2_v0.4_sword。
    //   清单里没有 characterSpine，只能运行时学；跨骨架集互换要用它改写骨架槽。
    //   真机同一骨架集有多个骨架名 → 同时按「角色变体」精确记一份。
    if (internalOnly && bone && boneRaw && cur2 && cur2.indexOf(boneRaw + '_') === 0) {
        var spineBody = pendingBodyByBone[bone];
        if (SKELS[bone] !== cur2) {
            SKELS[bone] = cur2;
            nSkelsLearned++;
            log('SKEL learned: ' + bone + ' -> ' + cur2);
            saveSkeletons();
        }
        if (spineBody && CHAR_SKEL[spineBody] !== cur2) {
            CHAR_SKEL[spineBody] = cur2;
            nSkelsLearned++;
            log('SKEL char: ' + spineBody + ' -> ' + cur2);
            saveSkeletons();
        }
    }

    // ★ 学「身体 id ↔ 脸 id」配对：同一角色加载时是 body → spine → face 连着请求的。
    //   桐人实测：body=kirito_cathedral、face=kirito —— 两个 id 不是同一个，
    //   所以一条 A→B 规则必须能同时作用于两者，否则只换脸或只换身体。
    if (isBody && cur2) {
        pendingBodyByBone[bone] = cur2;
    } else if (isFace && cur2) {
        var learnedBody = pendingBodyByBone[bone];
        // 只记「看得出来是同一个角色」的配对：静态表说同一基础名，或互为前缀。
        // 否则同队多角色共用骨架集时会学到 sinon_alo<->asuna_alo 这种脏数据。
        if (learnedBody && learnedBody !== cur2 && sameCharacter(learnedBody, cur2)) {
            FAMILY[learnedBody] = cur2;
            FAMILY[cur2] = learnedBody;
        }
    }

    if (internalOnly) {
        // 跨骨架集：骨架集槽位 + 骨架文件名一起改写（否则 game 会拼出
        // f_chara_2/f_chara_1_v0.4_sword 这种不存在的路径）。
        var tgtSpineBone = crossBoneByBone[bone];
        if (tgtSpineBone && tgtSpineBone !== bone) {
            var skel = crossSkelByBone[bone] || skeletonFor(bodyTargetByBone[bone], tgtSpineBone);
            if (skel && x1 && boneRaw) {
                writes.push({ ptr: x1, from: boneRaw, to: 'f_' + tgtSpineBone });
                if (cur2 && cur2 !== skel) writes.push({ ptr: x2, from: cur2, to: skel });
                log('CROSS-BONE spine: ' + boneRaw + '/' + cur2 + ' -> f_' + tgtSpineBone + '/' + skel);
            }
        }
        return writes;
    }
    if (!rewritable) return writes;

    if (cur2) {
        var t = null;
        var x1Target = null;   // 需要同时改写的骨架集槽位（跨骨架集时）
        if (isBody) {
            // 身体：直接命中规则，或规则写的是这个角色的**基础名**（如 kirito）
            t = resolveTargetFor(cur2);
            // ★ 骨架集守卫：模型 = 骨架 + 身体图集 + 脸图集，三者必须同一骨架集。
            //   同集直接换；跨集则**必须**有目标骨架集的骨架文件名才能换（三处一起改），
            //   否则拒绝——宁可什么都不换，也不要换坏（真机：黑屏 / 没头）。
            if (t) {
                // 规则目标可能是基础名（alice）→ 必须落成真实图集变体（alice_integrator）
                var resolved = bodyVariantFor(t);
                if (!resolved) {
                    log('SKIP unknown target: ' + t + '（骨架集表里找不到该角色的身体图集）');
                    t = null;
                } else if (resolved !== t) {
                    log('target ' + t + ' -> ' + resolved + '（基础名解析为真实图集）');
                    t = resolved;
                }
            }
            if (t) {
                var srcBone = bone || boneOf(cur2);
                var tgtBone = boneOf(t);
                if (srcBone && tgtBone && srcBone !== tgtBone) {
                    var crossSkel = skeletonFor(t, tgtBone);
                    if (crossSkel) {
                        crossBoneByBone[bone || srcBone] = tgtBone;
                        crossSkelByBone[bone || srcBone] = crossSkel;
                        x1Target = tgtBone;
                        log('CROSS-BONE: ' + cur2 + '(' + srcBone + ') -> ' + t + '(' + tgtBone
                            + ') skel=' + crossSkel);
                    } else {
                        log('SKIP cross-bone: ' + cur2 + '(' + srcBone + ') -> ' + t + '(' + tgtBone
                            + ') 缺骨架文件名（先让该角色出场一次）');
                        t = null;
                        crossBoneByBone[bone || srcBone] = null;
                    }
                } else {
                    crossBoneByBone[bone || srcBone || ''] = null;
                }
            }
        } else if (isFace) {
            // ★ 脸只在"同一角色本次加载里身体已经换过"时才换。
            //   否则会出现「身体还是桐人、脸换成 alice」的错位 —— 画面上就是没头。
            //   这条守卫是 2026-10-18 真机踩出来的：当角色穿的是别的服装
            //   （body=kirito_woodcutter，规则却写 kirito_cathedral）时，
            //   旧逻辑会单独把脸换掉。
            var bodyTarget = bodyTargetByBone[bone];
            if (!bodyTarget) {
                // ★ 真机发现：身体槽改写后，游戏发**脸**请求时 x1 已经是**目标骨架集**
                //   （PATH faceAtlas x1=chara_2 x2=kirito）。这时按源骨架集查不到身体目标，
                //   必须反查「哪个源骨架集被换到了当前这个骨架集」。
                for (var srcB in bodyTargetByBone) {
                    if (bodyTargetByBone[srcB] && crossBoneByBone[srcB] === bone) {
                        bodyTarget = bodyTargetByBone[srcB];
                        break;
                    }
                }
            }
            if (bodyTarget) {
                var face = baseOf(bodyTarget);
                if (face && face !== cur2) t = face;
                var fb = crossBoneByBone[bone];
                if (fb && fb !== bone) x1Target = fb;
            }
        }
        if (t && t !== cur2) {
            writes.push({ ptr: x2, from: cur2, to: t });
            if (isBody) bodyTargetByBone[bone] = t;
        }
        if (isBody && !t) bodyTargetByBone[bone] = null;
        if (x1Target && x1 && bone && x1Target !== bone) {
            writes.push({ ptr: x1, from: boneRaw, to: (boneRaw.indexOf('f_') === 0 ? 'f_' : '') + x1Target });
        }
    }
    // x1 是骨骼集编号（chara_N），规则里显式出现时也允许（骨架集替换，风险自担）
    if (x1) {
        var id1 = readPrefixedId(x1);
        if (id1 && MODELS[id1] && MODELS[id1] !== id1) {
            writes.push({ ptr: x1, from: id1, to: MODELS[id1] });
        }
    }
    return writes;
}

// 规则解析：直接命中优先；没命中就借「同族 id」的规则
// （用户选中的可能是身体 id 也可能是脸 id，都要能生效）
function resolveTargetFor(id) {
    if (MODELS[id] && MODELS[id] !== id) return MODELS[id];

    // 规则键可能是这个角色的**基础名**（用户从下拉里选「桐人」而不是某个服装 id）
    var base = PAIRS[id];
    if (base && MODELS[base] && MODELS[base] !== id) return MODELS[base];

    // 运行时学到的配对（同一次角色加载里 body 与 face 成对出现）
    var sib = FAMILY[id];
    if (sib && MODELS[sib] && MODELS[sib] !== sib) return MODELS[sib];

    // 反向：传进来的是**脸 id**，而规则写在它的某个"身体变体"上。
    // 靠静态表把两者关联起来（桐人：face=kirito，body=kirito_cathedral）。
    if (PAIRS) {
        for (var body in MODELS) {
            if (PAIRS[body] === id) {
                var t = MODELS[body];
                if (t && t !== id) return t;
            }
        }
    }
    return null;
}

// ---------------------------------------------------------------------------
// 单槽钩子的纯逻辑：白名单外返回空（R0 结论 1）
// ---------------------------------------------------------------------------

function onCharaFormat(fmt, x1) {
    var writes = [];
    if (!fmt || !x1) return writes;

    // 诊断：单槽函数（0x1229d50）负责所有 files/character/* 与 UI/语音，
    // 打开 debug 后把「路径 + x1」打出来，用来确认某个场景的角色资源到底走哪条。
    if (DEBUG_PATHS) {
        var d1 = readPrefixedId(x1);
        var key = 'C|' + fmt + '|' + d1;
        if (!seenPaths[key]) {
            seenPaths[key] = 1;
            log('PATH ' + fmt + '  x1=' + d1);
        }
    }

    var hit = false;
    for (var i = 0; i < CHARA_REWRITE_PREFIXES.length; i++) {
        if (fmt.indexOf(CHARA_REWRITE_PREFIXES[i]) === 0) { hit = true; break; }
    }
    if (!hit) return writes;

    var id = readPrefixedId(x1);
    if (id) {
        if (!seenChars[id]) log('CHAR: ' + id);
        seenChars[id] = (seenChars[id] || 0) + 1;
        var t = resolveTargetFor(id);
        // 这条函数里 /face/ 是**脸**资源（看板/立绘的脸部件），必须写目标角色的脸 id；
        // 解析不到就不动，避免写成身体 id 导致空脸。
        if (t && fmt.indexOf('files/character/face/') === 0) {
            var face = baseOf(t);
            t = face;   // null = 不改
        }
        if (t && t !== id) {
            writes.push({ ptr: x1, from: id, to: t });
        }
    }
    return writes;
}

// ---------------------------------------------------------------------------
// 枚举落盘（定长覆盖：Frida 的 File 写入不截断旧内容）
// ---------------------------------------------------------------------------

function flushEnum() {
    try {
        var counts = {};
        for (var k in seenChars) counts[k] = seenChars[k];
        var fam = {};
        for (var fk in FAMILY) fam[fk] = FAMILY[fk];
        var out = { characters: Object.keys(seenChars).sort(), counts: counts, pairs: fam };
        var s = JSON.stringify(out, null, 2);
        if (s.length + 2 <= ENUM_WRITE_BYTES) {
            s = s + '\n' + new Array(ENUM_WRITE_BYTES - s.length - 1 + 1).join(' ');
        } else {
            s = s + '\n';
        }
        try {
            File.writeAllText(CONFIG.enumPath, s);
            nEnumWritten++;
            if (nEnumWritten === 1) log('ENUM written #1: ' + out.characters.length + ' chars / ' + s.length + ' bytes');
            return;
        } catch (e) { /* fallthrough */ }
        try {
            var f = new File(CONFIG.enumPath, 'w');
            f.write(s);
            f.flush();
            f.close();
            nEnumWritten++;
        } catch (e2) {
            if (!enumErrLogged) { enumErrLogged = true; log('ENUM write FAILED: ' + e2.message); }
        }
    } catch (e) {
        if (!enumErrLogged) { enumErrLogged = true; log('ENUM flush error: ' + e.message); }
    }
}

// ---------------------------------------------------------------------------
// 安装（这部分依赖 Frida 运行时，无法离线测，只做薄壳）
// ---------------------------------------------------------------------------

function install() {
    var mod = Process.findModuleByName(CONFIG.module);
    if (!mod) { setTimeout(install, 500); return; }
    var base = mod.base;
    log('libapp.so base = ' + base);

    // spine 双槽
    var spineAddr = base.add(CONFIG.fmtSpine);
    var spinePro = spineAddr.readU32();
    if (prologueOk(spinePro, CONFIG.spineExpect)) {
        Interceptor.attach(spineAddr, {
            onEnter: function (args) {
                this.fmt = null;
                try { this.fmt = args[0].readUtf8String(); } catch (e) { return; }
                if (!this.fmt) return;
                // ★ 改写必须在 onEnter：这是「路径格式化函数」，路径在函数体内部
                //   就用 id 拼好了。放 onLeave（返回后）改缓冲区为时已晚 ——
                //   本次拼出的路径仍是旧 id，只有碰巧复用缓冲区的下一次调用才生效，
                //   这正是「日志在改、模型不变」的原因。
                var ws = onSpineFormat(this.fmt, this.context.x1, this.context.x2);
                for (var i = 0; i < ws.length; i++) {
                    if (writePrefixedId(ws[i].ptr, ws[i].to)) {
                        nModel++;
                        if (nModel <= CONFIG.logFirst) log('MODEL ' + ws[i].from + ' -> ' + ws[i].to + ' [' + this.fmt + ']');
                    }
                }
            },
        });
        log('hook spine fmtSpine=0x' + CONFIG.fmtSpine.toString(16) + ' OK (onEnter rewrite)');
    } else {
        log('OFFSET MISMATCH fmtSpine prologue=0x' + spinePro.toString(16)
            + ' expect=0x' + CONFIG.spineExpect.toString(16));
    }

    // 通用单槽（白名单内）
    var charaAddr = base.add(CONFIG.fmtCharacter);
    var charaPro = charaAddr.readU32();
    if (prologueOk(charaPro, CONFIG.charExpect)) {
        Interceptor.attach(charaAddr, {
            onEnter: function (args) {
                this.fmt = null;
                try { this.fmt = args[0].readUtf8String(); } catch (e) { return; }
                if (!this.fmt) return;
                var ws = onCharaFormat(this.fmt, this.context.x1);
                for (var j = 0; j < ws.length; j++) {
                    if (writePrefixedId(ws[j].ptr, ws[j].to)) {
                        nModel++;
                        if (nModel <= CONFIG.logFirst) log('MODEL ' + ws[j].from + ' -> ' + ws[j].to + ' [' + this.fmt + ']');
                    }
                }
            },
        });
        log('hook chara fmtCharacter=0x' + CONFIG.fmtCharacter.toString(16) + ' OK (onEnter rewrite)');
    } else {
        log('OFFSET MISMATCH fmtCharacter prologue=0x' + charaPro.toString(16)
            + ' expect=0x' + CONFIG.charExpect.toString(16));
    }

    loadPairs();
    loadBones();
    loadSkeletons();
    loadRules();
    setInterval(loadRules, CONFIG.pollMs);
    setInterval(flushEnum, CONFIG.flushMs);
    log('pairs: ' + CONFIG.pairsPath + ' (' + nPairsLoaded + ')');
    log('bones: ' + CONFIG.bonesPath + ' (' + nBonesLoaded + ')');
    log('skeletons: ' + CONFIG.skeletonsPath + ' (' + Object.keys(SKELS).join(',') + ')');
    log('rules: ' + CONFIG.rulesPath + ' (poll ' + CONFIG.pollMs + 'ms)');
    log('enum out: ' + CONFIG.enumPath + ' (every ' + CONFIG.flushMs + 'ms)');
    log('ready');
}

// ---------------------------------------------------------------------------
// API
// ---------------------------------------------------------------------------

globalThis.SaoarsModel = {
    getRules: function () { return { models: MODELS }; },
    setRules: function (r) { return setRules(r); },
    stats: function () { return { modelSwaps: nModel, characters: Object.keys(seenChars).length, models: Object.keys(MODELS).length }; },
    enum: function () { return { characters: Object.keys(seenChars).sort() }; },
    flush: function () { flushEnum(); return true; },
};

rpc.exports = {
    getrules: function () { return globalThis.SaoarsModel.getRules(); },
    setrules: function (r) { return globalThis.SaoarsModel.setRules(r); },
    stats: function () { return globalThis.SaoarsModel.stats(); },
    enum: function () { return globalThis.SaoarsModel.enum(); },
    flush: function () { return globalThis.SaoarsModel.flush(); },
};

setTimeout(install, 0);
