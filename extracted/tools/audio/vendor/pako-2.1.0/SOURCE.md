# Pako 2.1.0

This directory contains the unmodified `dist/pako.min.js` and `LICENSE` from
the upstream npm package `pako@2.1.0`. The npm `LICENSE` file contains the MIT
notice. `ZLIB-LICENSE` separately preserves the zlib 1.2.8 notice for code
ported into Pako; it comes from the [zlib v1.2.8 README](https://raw.githubusercontent.com/madler/zlib/v1.2.8/README).
The local `package.json` declares CommonJS so Node can load the unmodified
UMD artifact even when a parent project declares ESM.

- Source tarball: <https://registry.npmjs.org/pako/-/pako-2.1.0.tgz>
- Package SHA-256: `49fedc8866b4abfc8e71dc7fe75ad4ef1ff1ac9601b0642cff88ee5bf2338709`
- `pako.min.js` SHA-256: `ede2693a4a6a5126b9d35669062b358ecab6ae7b9b86a1cf302feb45a8514907`
- Upstream licenses: MIT (`LICENSE`) and Zlib (`ZLIB-LICENSE`)

The 2.1.0 compressor is pinned because it reproduces the original sounds EPK
GZIP stream byte for byte at level 9 with mtime zero. Pako 3.0.2 and the host
Node 24 zlib produce different compressed bytes from the same record stream.
