// 【検証環境のみ】Node の処理が、ループバック（127.0.0.1 / ::1 / localhost）以外へ
// 接続しようとしたら止めて記録する。
//
// 使い方: NODE_OPTIONS="--require <このファイル>" を付けて firebase emulators:start を起動する。
// 子の処理（Functions エミュレータの実行環境）にも NODE_OPTIONS が引き継がれる。
// 記録先: 環境変数 LINKDAY_NET_LOG（1 行 1 件の JSON。宛先・ポート・処理 ID だけで、
// 送ろうとした中身は記録しない）。
//
// LINE の関数は検証環境では読み込まないが（tool/verify/functions_account）、
// 万一外へ出ようとした場合もここで止まり、記録に残る。
'use strict';
const net = require('node:net');
const tls = require('node:tls');
const fs = require('node:fs');

const LOG = process.env.LINKDAY_NET_LOG || '';
const LOOPBACK = new Set(['127.0.0.1', '::1', 'localhost', '::ffff:127.0.0.1', '0.0.0.0', '']);

function record(host, port, how) {
  const line = JSON.stringify({
    at: new Date().toISOString(),
    pid: process.pid,
    argv1: (process.argv[1] || '').split('/').slice(-3).join('/'),
    how,
    host: String(host),
    port: port == null ? null : Number(port),
    blocked: true,
  });
  if (LOG) {
    try {
      fs.appendFileSync(LOG, line + '\n');
    } catch {
      /* 記録できなくても止めることは続ける */
    }
  }
  process.stderr.write(`[block_external] 外部への接続を止めました: ${host}:${port} (${how})\n`);
}

function hostOf(args) {
  const a = args[0];
  if (a && typeof a === 'object' && !Array.isArray(a)) {
    if (a.path) return {host: 'unix', port: null, local: true}; // UNIX ソケット（ローカル）
    return {host: a.host ?? 'localhost', port: a.port};
  }
  if (typeof a === 'number' || (typeof a === 'string' && /^\d+$/.test(a))) {
    return {host: typeof args[1] === 'string' ? args[1] : 'localhost', port: a};
  }
  if (typeof a === 'string') return {host: 'unix', port: null, local: true};
  return {host: 'localhost', port: null};
}

const origConnect = net.Socket.prototype.connect;
net.Socket.prototype.connect = function patchedConnect(...args) {
  const normalized = Array.isArray(args[0]) ? args[0] : args;
  const t = hostOf(normalized);
  if (!t.local && !LOOPBACK.has(String(t.host).replace(/^\[|\]$/g, ''))) {
    record(t.host, t.port, 'net.Socket.connect');
    const err = new Error(`[block_external] 検証環境では外部へ接続しません: ${t.host}:${t.port}`);
    err.code = 'ECONNREFUSED';
    process.nextTick(() => this.destroy(err));
    return this;
  }
  return origConnect.apply(this, args);
};

const origTlsConnect = tls.connect;
tls.connect = function patchedTlsConnect(...args) {
  const opts = args.find((a) => a && typeof a === 'object') || {};
  const host = opts.host || opts.servername || (typeof args[1] === 'string' ? args[1] : 'localhost');
  if (!LOOPBACK.has(String(host))) {
    record(host, opts.port ?? args[0], 'tls.connect');
    throw Object.assign(new Error(`[block_external] 検証環境では外部へ接続しません: ${host}`), {
      code: 'ECONNREFUSED',
    });
  }
  return origTlsConnect.apply(this, args);
};
