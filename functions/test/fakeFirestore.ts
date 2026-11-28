/**
 * テスト用の最小 Firestore フェイク
 *
 * 実際の Firestore / エミュレータを使わずに
 *  - doc().create()（既存なら ALREADY_EXISTS で失敗 = 冪等検証に必須）
 *  - doc().set() / set(merge) / get() / delete()
 * の挙動を再現する。
 */
import {FieldValue} from 'firebase-admin/firestore';
import type {Firestore} from 'firebase-admin/firestore';

/** 'a/b/c/d' → ['a/b/c', 'd']（事業所の下の文書も扱う） */
function splitPath(path: string): [string, string] {
  const i = path.lastIndexOf('/');
  return [path.slice(0, i), path.slice(i + 1)];
}

const isDelete = (v: unknown): boolean =>
  v instanceof FieldValue && v.isEqual(FieldValue.delete());

/**
 * 更新の内容を反映する（'a.b' の形の項目名は入れ子に入れる。FieldValue.delete() は消す）。
 * serverTimestamp() などの他の FieldValue はそのまま置く（検証では中身を見ない）。
 */
function applyUpdate(
  base: Record<string, unknown>,
  data: Record<string, unknown>
): Record<string, unknown> {
  const out: Record<string, unknown> = {...base};
  for (const [k, v] of Object.entries(data)) {
    const parts = k.split('.');
    let o = out;
    for (const p of parts.slice(0, -1)) {
      const next = o[p];
      o[p] = next !== null && typeof next === 'object' ? {...(next as object)} : {};
      o = o[p] as Record<string, unknown>;
    }
    const last = parts[parts.length - 1];
    if (isDelete(v)) delete o[last];
    else o[last] = v;
  }
  return out;
}

export class FakeFirestore {
  /** collection → (docId → data) */
  readonly store = new Map<string, Map<string, Record<string, unknown>>>();

  /**
   * Day 13: transaction の衝突を再現するためのフック。
   *
   * runTransaction の「読み取り後・書き込み前」に呼ばれる。
   * ここで別ユーザーの確定を割り込ませることで、
   * 同時タップで二重確定しないことを検証できる。
   */
  onTransactionRead: (() => void | Promise<void>) | null = null;

  collection(name: string) {
    if (!this.store.has(name)) this.store.set(name, new Map());
    const col = this.store.get(name)!;
    return {
      doc: (id: string) => this.docRef(name, col, id),
      // where().limit().get() の最小実装（line_linkage の逆引き用）
      where: (field: string, op: string, value: unknown) =>
        this.query(col, [{field, op, value}]),
    };
  }

  private query(
    col: Map<string, Record<string, unknown>>,
    conds: Array<{field: string; op: string; value: unknown}>
  ) {
    const self = this;
    let limitN = Infinity;
    const build = () => ({
      limit(n: number) {
        limitN = n;
        return build();
      },
      where(field: string, op: string, value: unknown) {
        return self.query(col, [...conds, {field, op, value}]);
      },
      async get() {
        const matched: Array<{
          id: string;
          data: () => Record<string, unknown>;
        }> = [];
        for (const [id, d] of col.entries()) {
          const ok = conds.every((c) =>
            c.op === '==' ? d[c.field] === c.value : false
          );
          if (ok) matched.push({id, data: () => ({...d})});
          if (matched.length >= limitN) break;
        }
        return {empty: matched.length === 0, docs: matched, size: matched.length};
      },
    });
    return build();
  }

  /**
   * runTransaction の最小実装。
   *
   * 実 Firestore のような楽観ロックの再試行までは再現しないが、
   * 「読み取り → (割り込み) → 書き込み」の順序で onTransactionRead を
   * 挟むことで、競合が起きたときに後勝ちしないことを検証できる。
   * 書き込みは tx.update / tx.set を即時に反映する。
   */
  async runTransaction<T>(
    fn: (tx: {
      get: (ref: {path: string}) => Promise<{
        exists: boolean;
        id: string;
        data: () => Record<string, unknown> | undefined;
      }>;
      update: (ref: {path: string}, data: Record<string, unknown>) => void;
      delete: (ref: {path: string}) => void;
      set: (
        ref: {path: string},
        data: Record<string, unknown>,
        options?: {merge?: boolean}
      ) => void;
    }) => Promise<T>
  ): Promise<T> {
    let readCount = 0;
    const tx = {
      get: async (ref: {path: string}) => {
        // 検索（where().get()）も transaction の中で読めるようにする
        if (!('path' in ref)) {
          readCount++;
          return (ref as unknown as {get: () => Promise<never>}).get();
        }
        const [colName, id] = splitPath(ref.path);
        const col = this.store.get(colName);
        const d = col?.get(id);
        readCount++;
        // 最初の読み取り直後にだけ割り込みを入れる
        if (readCount === 1 && this.onTransactionRead) {
          const hook = this.onTransactionRead;
          this.onTransactionRead = null; // 1 回だけ
          await hook();
        }
        return {
          exists: d !== undefined,
          id,
          data: () => (d === undefined ? undefined : {...d}),
        };
      },
      update: (ref: {path: string}, data: Record<string, unknown>) => {
        const [colName, id] = splitPath(ref.path);
        if (!this.store.has(colName)) this.store.set(colName, new Map());
        const col = this.store.get(colName)!;
        col.set(id, applyUpdate(col.get(id) ?? {}, data));
      },
      delete: (ref: {path: string}) => {
        const [colName, id] = splitPath(ref.path);
        this.store.get(colName)?.delete(id);
      },
      set: (
        ref: {path: string},
        data: Record<string, unknown>,
        options?: {merge?: boolean}
      ) => {
        const [colName, id] = splitPath(ref.path);
        if (!this.store.has(colName)) this.store.set(colName, new Map());
        const col = this.store.get(colName)!;
        if (options?.merge && col.has(id)) {
          col.set(id, {...col.get(id)!, ...data});
        } else {
          col.set(id, {...data});
        }
      },
    };
    return fn(tx);
  }

  private docRef(
    colName: string,
    col: Map<string, Record<string, unknown>>,
    id: string
  ) {
    return {
      path: `${colName}/${id}`,
      id,
      async create(data: Record<string, unknown>): Promise<void> {
        if (col.has(id)) {
          const err = new Error(
            `6 ALREADY_EXISTS: entity already exists: ${colName}/${id}`
          ) as Error & {code: number};
          err.code = 6;
          throw err;
        }
        col.set(id, {...data});
      },
      async set(
        data: Record<string, unknown>,
        options?: {merge?: boolean}
      ): Promise<void> {
        if (options?.merge && col.has(id)) {
          col.set(id, {...col.get(id)!, ...data});
        } else {
          col.set(id, {...data});
        }
      },
      async get(): Promise<{
        exists: boolean;
        id: string;
        data: () => Record<string, unknown> | undefined;
      }> {
        const d = col.get(id);
        return {
          exists: d !== undefined,
          id,
          data: () => (d === undefined ? undefined : {...d}),
        };
      },
      async delete(): Promise<void> {
        col.delete(id);
      },
    };
  }

  /** 検証用: コレクションの中身を取る */
  docs(collection: string): Record<string, Record<string, unknown>> {
    const col = this.store.get(collection);
    if (!col) return {};
    return Object.fromEntries(col.entries());
  }

  get(collection: string, id: string): Record<string, unknown> | undefined {
    return this.store.get(collection)?.get(id);
  }

  seed(
    collection: string,
    id: string,
    data: Record<string, unknown>
  ): void {
    if (!this.store.has(collection)) this.store.set(collection, new Map());
    this.store.get(collection)!.set(id, data);
  }

  clear(): void {
    this.store.clear();
  }

  /**
   * ステップ2: collectionGroup(name).where(...).get() の最小実装。
   * コレクション名が name、または '/name' で終わるもの（例 'facilities/f1/staffAccounts'）
   * をすべて対象にする。各文書の ref.parent.parent.id は親の文書 ID（事業所 ID）。
   */
  collectionGroup(name: string) {
    const self = this;
    const run = (conds: Array<{field: string; value: unknown}>) => ({
      where(field: string, _op: string, value: unknown) {
        return run([...conds, {field, value}]);
      },
      async get() {
        const docs: Array<{
          id: string;
          data: () => Record<string, unknown>;
          ref: {path: string; parent: {parent: {id: string} | null}};
        }> = [];
        for (const [colName, col] of self.store.entries()) {
          if (colName !== name && !colName.endsWith(`/${name}`)) continue;
          const parts = colName.split('/');
          const parentId = parts.length >= 3 ? parts[parts.length - 2] : null;
          for (const [id, d] of col.entries()) {
            if (!conds.every((c) => d[c.field] === c.value)) continue;
            docs.push({
              id,
              data: () => ({...d}),
              ref: {
                path: `${colName}/${id}`,
                parent: {parent: parentId === null ? null : {id: parentId}},
              },
            });
          }
        }
        return {empty: docs.length === 0, docs, size: docs.length};
      },
    });
    return run([]);
  }

  /** Firestore 型として渡すためのキャスト（使用 API のみ実装済み） */
  asFirestore(): Firestore {
    return this as unknown as Firestore;
  }
}
