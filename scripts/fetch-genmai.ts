// 入力メソッドが使うモデル（genmai-310M の q8_0）を .zenz/ に取得し、SHA-256 を確かめてパスを出す。
// 版は Hugging Face のコミットで固定する。更新するときは scripts/convert-hf-to-gguf.ts で変換した GGUF を miyaoka/genmai-310M-GGUF に上げ、
// revision・sha256 と、App/Notices/genmai-310M.txt の版とコミットを一緒に変える
import { join } from "node:path";
import { fetchPinned } from "./lib/fetch";
import { root } from "./lib/root";

const revision = "14d20cdc72a97857d4afa96a9ac6f9b2edc05aec";

export async function genmai(): Promise<string> {
  const path = join(root, ".zenz/genmai-310M-q8_0.gguf");
  await fetchPinned([
    {
      url: `https://huggingface.co/miyaoka/genmai-310M-GGUF/resolve/${revision}/genmai-310M-q8_0.gguf`,
      sha256:
        "adef071476174c979ec68cc2216e85ac685c8f985ee86bff34004b032389938b",
      path,
    },
  ]);
  return path;
}

if (import.meta.main) console.log(await genmai());
