# Client-side game modules (vendored)

Ba thứ trong thư mục này không còn phân phối được từ nguồn gốc nữa, nên chúng
được pin ngay trong repo:

| Đường dẫn | Nguồn | License | Ghi chú |
|---|---|---|---|
| `xash3d-fwgs/` | npm `xash3d-fwgs@1.2.2+commit.7c58854` (đã bị deprecated, sẽ bị xoá) | MIT (wrapper) + GPL-3.0 (engine wasm) | Engine GoldSrc viết lại, build Emscripten |
| `client_emscripten_wasm32.wasm` | `x8BitRain/webXash` nhánh `gh-pages`, `cs16-client/dist/cstrike/cl_dlls/` | GPL-2.0+ (kèm ngoại lệ link Half-Life) | Client DLL CS 1.6, 478 KB |
| `menu_emscripten_wasm32.wasm` | như trên | GPL-2.0+ | Menu/VGUI DLL, 483 KB |
| `cs_emscripten_wasm32.wasm` | `cs16-client/dist/cstrike/dlls/` (cùng nguồn) | GPL-2.0+ | Server module, 1.3 MB. Không dùng khi chơi online nhưng engine vẫn `dlopen` nó lúc init game — không preload thì hiện alert "could not load dynamic lib" |

Client DLL này là bản **đúng cặp** với engine 1.2.2 (site webXash deploy cùng engine
`xash-CAtKZwSO.wasm` mà repo này cũng build ra). Bản 639 KB từ npm `xash-cs-demo` build cho
engine mới hơn và sẽ chết với `Xash3D FWGS version check failed` (nó đòi `host_ver >= 4190`,
mà cvar đó read-only).

## Kiểm tra toàn vẹn

```bash
node ../scripts/vendor-engine.mjs           # tải lại 2 DLL wasm, verify sha256
cd xash3d-fwgs && sha256sum -c SHA256SUMS   # verify engine đã vendor (Linux)
```

Hash của DLL nằm trong `scripts/vendor-engine.mjs`; nếu nguồn trả về byte khác, script fail
thay vì build ra binary lạ.

## Nâng cấp engine

1. `npm pack xash3d-fwgs@<version>` (khi package còn tồn tại), giải nén `dist/` vào
   `xash3d-fwgs/dist/`.
2. Cập nhật `xash3d-fwgs/package.json`.
3. Chạy lại `sha256sum` để ghi `SHA256SUMS` mới.
4. Build lại client và **test handshake thật** — engine và client DLL phải khớp interface
   (protocol 48) và build number. Cách nhanh nhất: chạy mục 11 trong README.
