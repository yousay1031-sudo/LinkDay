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

  collection(name: string) {
    if (!this.store.has(name)) this.store.set(name, new Map());
    const col = this.store.get(name)!;
    return {
      doc: (id: string) => this.docRef(name, col, id),
    };
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
