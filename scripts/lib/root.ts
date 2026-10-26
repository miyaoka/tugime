import { dirname, join } from "node:path";

/// リポジトリの直下
export const root = join(dirname(import.meta.path), "../..");
