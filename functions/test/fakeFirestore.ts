/**
 * テスト用の最小 Firestore フェイク
 *
 * 実際の Firestore / エミュレータを使わずに
 *  - doc().create()（既存なら ALREADY_EXISTS で失敗 = 冪等検証に必須）
 *  - doc().set() / set(merge) / get() / delete()
 * の挙動を再現する。
 */
import type {Firestore} from 'firebase-admin/firestore';

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
        const [colName, id] = ref.path.split('/');
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
        const [colName, id] = ref.path.split('/');
        if (!this.store.has(colName)) this.store.set(colName, new Map());
        const col = this.store.get(colName)!;
        col.set(id, {...(col.get(id) ?? {}), ...data});
      },
      set: (
        ref: {path: string},
        data: Record<string, unknown>,
        options?: {merge?: boolean}
      ) => {
        const [colName, id] = ref.path.split('/');
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

  /** Firestore 型として渡すためのキャスト（使用 API のみ実装済み） */
  asFirestore(): Firestore {
    return this as unknown as Firestore;
  }
}
