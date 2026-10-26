// 入力メソッドが使うモデル（genmai-310M の q8_0）を .zenz/ に取得し、SHA-256 を確かめてパスを出す。
// 版は Hugging Face のコミットで固定する。更新するときは scripts/convert-hf-to-gguf.ts で変換した GGUF を miyaoka/genmai-310M-GGUF に上げ、
// revision・sha256 と、App/Notices/genmai-310M.txt の版とコミットを一緒に変える
import { join } from "node:path";
import { fetchPinned } from "./lib/fetch";
import { root } from "./lib/root";

const revision = "535737d970be9ef31bd599436e16c9254f22f0f8";

export async function genmai(): Promise<string> {
  const path = join(root, ".zenz/genmai-310M-q8_0.gguf");
  await fetchPinned([
    {
      url: `https://huggingface.co/miyaoka/genmai-310M-GGUF/resolve/${revision}/genmai-310M-q8_0.gguf`,
      sha256:
        "83cdec80c39534104cbcd0be5dd2c9cc17e24731102d7b7bd22ffdd61fb368a6",
      path,
    },
  ]);
  return path;
}

if (import.meta.main) console.log(await genmai());
