// 版を固定した外部のファイルを取得し、SHA-256 を確かめて置く。取得済みで一致すれば取り直さない
import { $ } from "bun";
import { mkdir, rename } from "node:fs/promises";
import { dirname } from "node:path";

/// 止まったとみなして打ち切るまでの秒数（curl の --speed-time。この間 1 B/s を下回れば打ち切る）
const STALL_SECONDS = 30;
/// 1 回の転送の上限（curl の --max-time）。最初の転送から、再試行を始めてよい期間（curl の --retry-max-time）にも使う
const MAX_TIME_SECONDS = 600;
/// 一時的な失敗のときに取り直す回数（curl の --retry）
const RETRIES = 3;

/// 取得する URL・その中身の SHA-256（16 進）・置くパス
export type Pinned = { url: string; sha256: string; path: string };

async function sha256Of(path: string): Promise<string | undefined> {
  const file = Bun.file(path);
  if (!(await file.exists())) return undefined;
  const hasher = new Bun.CryptoHasher("sha256");
  for await (const chunk of file.stream()) hasher.update(chunk);
  return hasher.digest("hex");
}

export async function fetchPinned(files: Pinned[]) {
  for (const { url, sha256, path } of files) {
    if ((await sha256Of(path)) === sha256) continue;
    await mkdir(dirname(path), { recursive: true });
    console.error(`== 取得 ${url}`);
    const part = `${path}.part`;
    await $`curl -fL --retry ${RETRIES} --retry-max-time ${MAX_TIME_SECONDS} --max-time ${MAX_TIME_SECONDS} --speed-time ${STALL_SECONDS} -o ${part} ${url}`;
    const actual = await sha256Of(part);
    if (actual !== sha256)
      throw new Error(`${url} の SHA-256 が ${sha256} でなく ${actual}`);
    await rename(part, path);
  }
}
