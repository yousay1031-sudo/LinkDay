/**
 * LinkDay Cloud Functions エントリポイント
 *
 * 公開関数:
 *  - sendVacancyNotice (Callable, asia-northeast1)
 *      空き枠が出た日に、候補保護者へ LINE push 通知を送る。
 *      Firebase Auth 必須・同一 date+customerId は冪等。
 *  - lineWebhook (HTTPS, asia-northeast1)
 *      LINE からの webhook（follow / 連携コード受付）。署名検証必須。
 *
 * secrets:
 *  - LINE_CHANNEL_ACCESS_TOKEN
 *  - LINE_CHANNEL_SECRET
 */
import {initializeApp, getApps} from 'firebase-admin/app';
import {getFirestore} from 'firebase-admin/firestore';
import {onCall, onRequest} from 'firebase-functions/v2/https';
import {setGlobalOptions} from 'firebase-functions/v2';

import {
  LINE_CHANNEL_ACCESS_TOKEN,
  LINE_CHANNEL_SECRET,
  REGION,
} from './config';
import {handleSendVacancyNotice} from './sendVacancyNotice';
import {handleLineWebhook} from './lineWebhook';

if (getApps().length === 0) {
  initializeApp();
}

setGlobalOptions({region: REGION, maxInstances: 10});

/** 空き枠通知（Callable） */
export const sendVacancyNotice = onCall(
  {
    region: REGION,
    secrets: [LINE_CHANNEL_ACCESS_TOKEN],
    // CORS: Flutter Web（Firebase Hosting ドメイン）から呼ばれる
    cors: true,
    timeoutSeconds: 120,
    memory: '256MiB',
  },
  async (req) =>
    handleSendVacancyNotice(
      req,
      getFirestore(),
      LINE_CHANNEL_ACCESS_TOKEN.value()
    )
);

/** LINE webhook（HTTPS） */
export const lineWebhook = onRequest(
  {
    region: REGION,
    secrets: [LINE_CHANNEL_ACCESS_TOKEN, LINE_CHANNEL_SECRET],
    timeoutSeconds: 60,
    memory: '256MiB',
  },
  async (req, res) => {
    await handleLineWebhook(
      req,
      res,
      getFirestore(),
      LINE_CHANNEL_SECRET.value(),
      LINE_CHANNEL_ACCESS_TOKEN.value()
    );
  }
);
