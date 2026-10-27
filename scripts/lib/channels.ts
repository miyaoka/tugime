/// 配布版の bundle id
export const BUNDLE_ID = "io.github.miyaoka.inputmethod.tugime";

/// 配布版の辞書を写す道具の、.app の中の場所を書いた Info.plist のキー
export const SYNC_APP_KEY = "TugimeSyncApp";

/// TUGIME_BUILD_CHANNEL ごとの bundle id と名前と、配布版の辞書を写す道具を同梱するか。無指定（空）は開発版
export const CHANNELS = new Map([
  ["stable", { bundleId: BUNDLE_ID, name: "tugime", sync: false }],
  ["", { bundleId: `${BUNDLE_ID}.dev`, name: "tugime Dev", sync: true }],
]);
