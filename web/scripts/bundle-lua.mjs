// Lua kaynaklarını { "modül.adı": "kaynak" } manifestine paketler (F12/F17).
// Kullanım: node scripts/bundle-lua.mjs [--minify] [--exclude a.lua,b.lua] <kök>=<önek> [<dosya>=<modül> ...] > out.json
// Her dosya luac5.4 -p ile denetlenir (minify sonrası da); tek hata → çıkış kodu 1, build durur.
import { readFileSync, readdirSync, statSync, writeFileSync, mkdtempSync, rmSync } from "node:fs";
import { join, relative, resolve } from "node:path";
import { spawnSync } from "node:child_process";
import { tmpdir } from "node:os";

const args = process.argv.slice(2);
const minify = args.includes("--minify");
const exIdx = args.indexOf("--exclude");
const exclude = new Set(exIdx >= 0 ? args[exIdx + 1].split(",").map((p) => resolve(p)) : []);
const specs = args.filter((a, i) => a.includes("=") && (exIdx < 0 || i !== exIdx + 1));

// Yalnızca 5.4 derleyicisi kabul edilir (5.1 luac, 5.4 sözdizimini yanlışlıkla reddeder)
const luac = ["luac5.4", "luac"].find((c) => {
  const r = spawnSync(c, ["-v"], { encoding: "utf8" });
  return r.status === 0 && /Lua 5\.4/.test((r.stdout || "") + (r.stderr || ""));
});
if (!luac) {
  if (process.env.CI) { console.error("HATA: luac bulunamadı (CI'da zorunlu)"); process.exit(1); }
  console.error("UYARI: luac bulunamadı, sözdizimi kontrolü atlandı");
}
const tmp = mkdtempSync(join(tmpdir(), "bundle-lua-"));

function check(src, label) {
  if (!luac) return;
  const f = join(tmp, "chk.lua");
  writeFileSync(f, src);
  const r = spawnSync(luac, ["-p", f], { encoding: "utf8" });
  if (r.status !== 0) {
    console.error(`HATA: sözdizimi hatası (${label}): ${(r.stderr || "").replace(f, label).trim()}`);
    rmSync(tmp, { recursive: true, force: true });
    process.exit(1);
  }
}

// Basit minify: yorum satırları, blok yorumlar, sondaki boşluk ve boş satırlar
// (satır içi "--" string'ler bozulmasın diye yalnızca satırın tamamı yorumsa silinir)
function shrink(s) {
  return s
    .replace(/^\s*--\[(=*)\[[\s\S]*?\]\1\]\s*$/gm, "")
    .split("\n")
    .filter((l) => !/^\s*--/.test(l))
    .map((l) => l.replace(/^\s+|\s+$/g, ""))
    .filter((l) => l !== "")
    .join("\n") + "\n";
}

function walk(dir) {
  return readdirSync(dir).sort().flatMap((n) => {
    const p = join(dir, n);
    return statSync(p).isDirectory() ? walk(p) : (n.endsWith(".lua") ? [p] : []);
  });
}

const out = {};
for (const spec of specs) {
  const [path, name] = spec.split("=");
  const files = statSync(path).isDirectory()
    ? walk(path).map((f) => [f, name + relative(path, f).replace(/\.lua$/, "").replaceAll("/", ".")])
    : [[path, name]];
  for (const [file, mod] of files) {
    if (exclude.has(resolve(file))) continue;
    let src = readFileSync(file, "utf8");
    check(src, file);
    if (minify) { src = shrink(src); check(src, `${file} (minify)`); }
    out[mod] = src;
  }
}
rmSync(tmp, { recursive: true, force: true });
process.stdout.write(JSON.stringify(out));
