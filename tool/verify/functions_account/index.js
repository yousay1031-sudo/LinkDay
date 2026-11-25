// 検証環境専用の入口: 個人アカウントの所属の関数だけを読み込む。
// LINE の関数（sendVacancyNotice / lineWebhook）を含む functions/lib/index.js は読み込まない。
// functions/lib は `npm --prefix functions run build` で作る（tool/verify/start_emulators.sh が行う）。
// node_modules は functions/node_modules へのリンク（start_emulators.sh が作る。git には入れない）。
'use strict';
module.exports = require('../../../functions/lib/account/index.js');
