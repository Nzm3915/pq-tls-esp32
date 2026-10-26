# pq-tls-esp32

ESP32-S3上でwolfSSLの耐量子TLS（ML-KEM・ML-DSA）を動かし、鍵交換・証明書・メモリ構成ごとのハンドシェイク時間、RAM使用量、通信量を実測するプロジェクト。

本リポジトリは進行中で、ESP32-S3上での暗号演算ベンチマーク（Phase 2）まで完了している。

## 研究課題と仮説

**RQ：** ESP32-S3上で耐量子TLSを使うとき、どの鍵交換・証明書・メモリ構成なら、ハンドシェイク時間とRAM使用量が実用範囲に収まるか。

| 仮説 | 内容 |
| --- | --- |
| H1 | X25519MLKEM768を使っても、ハンドシェイク遅延の増加はX25519単独比で実用範囲（+1秒未満）に収まる |
| H2 | 通信量とRAMを支配するのは鍵交換ではなく、ML-DSA証明書チェーンである |
| H3 | ESP32-S3はSHA-3をハードウェアで加速できないため、ML-KEMの処理時間の過半はSHAKEが占める |

## 環境（Phase 1：PC）

| 項目 | 値 |
| --- | --- |
| wolfSSL | v5.9.4-stable（commit 3c5eead44） |
| OS | Ubuntu on WSL2（Windows 11） |
| configure | `./configure --enable-mlkem --enable-mldsa --enable-curve25519 --enable-tls-mlkem-standalone` |

> 注：ML-KEM・ML-DSAのベンチマーク値は最初のビルド（`--enable-mlkem --enable-mldsa`）で取得。X25519の値と通信量の測定は上記の再ビルド後に取得。

## 結果1：TLS 1.3 ハンドシェイクのサイズ（PC、ループバック）

`scripts/capture.sh` でキャプチャし、`scripts/hello_sizes.sh` で集計。単位はバイト。

| 鍵交換グループ | ClientHello | ServerHello | key_share（C→S / S→C） |
| --- | ---: | ---: | ---: |
| X25519 | 205 | 86 | 32 / 32 |
| X25519MLKEM768 | 1405 | 1174 | 1216 / 1120 |
| ML_KEM_768 | 1373 | 1142 | 1184 / 1088 |

key_shareの値は、仕様から予測した値（ML-KEM-768のカプセル化鍵1184 B、暗号文1088 B、X25519の公開値32 B）と完全に一致した。

ハイブリッド化により、ClientHelloは約6.9倍、ServerHelloは約13.7倍、最初の往復で送受信する量は291 Bから2579 B（約8.9倍）になる。

未解決の点：key_share以外の部分がPQC構成では16 B大きい（173 B → 189 B）。どの拡張の差かは未特定。

## 結果2：暗号演算ベンチマーク（PC）

`./wolfcrypt/benchmark/benchmark` の出力。全値は `results/pc_benchmark.csv`。

TLSクライアント側の鍵交換コスト（鍵生成＋共有値計算）で比較すると：

| 方式 | 演算 | 合計（ms） |
| --- | --- | ---: |
| X25519 | keygen 0.036 + agree 0.035 | 0.071 |
| ML-KEM-768 | keygen 0.017 + decap 0.025 | 0.042 |
| X25519MLKEM768（両方） | | 約0.113 |
| ECDHE P-256（参考） | keygen 0.284 + agree 0.281 | 0.565 |

PCではML-KEM単体はX25519より速く、ハイブリッドでも計算コストは約1.6倍・絶対値0.1 ms程度に留まる。PCでの耐量子化の代償は計算時間ではなく通信量である。この関係がマイコン（ESP32-S3）でも成り立つかが、次のフェーズの検証対象となる。

## 結果3：暗号演算ベンチマーク（ESP32-S3、Phase 2）

条件：ESP32-S3-WROOM-1-N16R8（240 MHz、シングルコア動作）、ESP-IDF v5.5.6、wolfSSL v5.9.4-stable、PSRAM有効（8 MB、40 MHz）、wolfSSL公式 `wolfssl_benchmark` サンプル。数学ライブラリは既定の `USE_FAST_MATH`（`WOLFSSL_SP_MATH_ALL` 無効）。ML-KEMはmenuconfigの `ESP_WOLFSSL_ENABLE_MLKEM`、ML-DSAとSHA-3は `user_settings.h` に `WOLFSSL_SHA3` / `WOLFSSL_SHAKE128` / `WOLFSSL_SHAKE256` / `WOLFSSL_HAVE_MLDSA` を追加して有効化。全値は `results/esp32s3_benchmark_psram_fastmath.csv`。

| 比較 | PC（ms） | ESP32-S3（ms） | ESP32上の比 |
| --- | ---: | ---: | --- |
| X25519 鍵交換（keygen + agree） | 0.071 | 695.8 | 基準 |
| ML-KEM-768（keygen + decap） | 0.042 | 13.4 | X25519の約1/52 |
| X25519MLKEM768（合計の推定） | 0.113 | 約709 | X25519比 +約2% |
| ECDSA P-256 検証 | 0.193 | 565.0 | 基準 |
| ML-DSA-44 検証 | 0.041 | 16.0 | ECDSAの約1/35 |

PCではML-KEMとX25519の差は1.7倍だったが、ESP32-S3では約52倍に広がった。ハイブリッド鍵交換の計算時間はほぼ全てX25519が占め、耐量子部分の追加コストは約2%に留まる。

ハッシュ処理（`results/esp32s3_hash_throughput.csv`）：SHA-256はハードウェア加速で約12 MB/s、SHA3-256は加速なしで約1.2 MB/s（約1/10）。

注意（公平性）：楕円曲線系は既定の `USE_FAST_MATH` で測定しており、wolfSSLの高速版 `WOLFSSL_SP_MATH_ALL` を使えば大幅に速くなる可能性がある。比較の結論は、SP数学ライブラリでの再測定後に確定する。

## 結果4：演算ごとのヒープ使用量（ESP32-S3、Phase 2）

条件は結果3と同じで、`user_settings.h` に `WOLFSSL_TRACK_MEMORY` と `WOLFSSL_TRACK_MEMORY_VERBOSE` を追加した。ベンチマークの各行に、その演算で増えたヒープの最大量が表示される。全値は `results/esp32s3_heap_psram_fastmath.csv`、生ログは `logs/esp32s3_benchmark_heap_psram_fastmath.log`。

TLSクライアント（ESP32側）が行う処理で比較すると：

| 処理 | 古典 | ヒープ（B） | 耐量子 | ヒープ（B） |
| --- | --- | ---: | --- | ---: |
| 鍵交換：鍵生成 | X25519 keygen | 119 | ML-KEM-768 keygen | 6,650 |
| 鍵交換：共有値の計算 | X25519 agree | 119 | ML-KEM-768 decap | 12,346 |
| 証明書の署名検証 | ECDSA P-256 verify | 19,344 | ML-DSA-44 verify | 30,536 |

- 耐量子化で最もヒープを食うのは署名検証（ML-DSA-44で約30 KB）で、鍵交換（ML-KEM-768で約12 KB）の約2.5倍。H2の「RAMは証明書側が支配する」と同じ向きだが、TLS全体（レコードバッファ、証明書の解析）を含めた検証はPhase 3で行う。
- ベンチマーク全体のヒープ最大値は137,283 B（ML-DSA-87 signの約122 KBが最大）。PSRAMを除いた内蔵RAMのヒープ領域（約387 KB）にも収まる。
- スタック：メインタスク（28,672 B）の最小空き量は25,936 Bで、全処理を通じたスタック使用量は最大2,736 B。この構成は `WOLFSSL_SMALL_STACK` が有効で、大きな一時配列をスタックではなくヒープに置くため、メモリ使用量はほぼヒープ側の数字で把握できる。
- メモリ追跡を有効にしても速度はほぼ変わらない（差は約1%以内）。ただしML-DSAのsignは乱数による再試行（rejection sampling）があり、測定回数も少ないため、ばらつきが大きい（ML-DSA-65 sign：71.6 ms → 94.2 ms）。

測定方法の注意：数値は各ベンチマーク行の開始時点からの増分ピークで、それより前に確保済みの鍵構造体は含まない。encapの行は、ベンチマーク自身が準備する入出力バッファ（公開鍵・暗号文）も含む。decapとverifyの行は、演算そのものの一時領域に近い。

## 結果5：コンパイラ最適化の影響（-Og → -O2）

結果3・4はESP-IDF既定のデバッグ向け最適化（`-Og`）で測っていた。menuconfigの Compiler options → Optimization Level を **Optimize for performance (-O2)** に変え、他の条件は同じにして再測定した。全値は `results/esp32s3_benchmark_O2_vs_Og.csv`。

| 処理 | -Og（ms） | -O2（ms） | 速くなった倍率 |
| --- | ---: | ---: | ---: |
| X25519 鍵交換（keygen + agree） | 696.1 | 357.7 | 1.95 |
| ML-KEM-768（keygen + decap） | 13.4 | 12.0 | 1.11 |
| X25519MLKEM768（合計の推定） | 約709 | 約370 | |
| ECDSA P-256 検証 | 569.5 | 453.8 | 1.26 |
| ML-DSA-44 検証 | 16.0 | 13.0 | 1.23 |
| SHA-256（HW、KiB/s） | 12,325 | 27,350 | 2.22 |
| SHAKE128（ソフトウェア、KiB/s） | 1,516 | 1,673 | 1.10 |

- -O2ではX25519とML-KEM-768の差は約52倍から約30倍に縮んだ。それでもハイブリッド鍵交換の計算時間はほぼX25519が占め、耐量子部分の追加は約12 ms（+約3%）に留まる。H1の結論は変わらない。
- 最適化の効き方は演算によって大きく違う。X25519は約2倍速くなったが、ML-KEMは約1.1倍に留まり、これはSHAKE128の伸び（約1.1倍）とほぼ同じ。ML-KEMの処理時間をSHA-3系の計算（Keccak置換）が占めているという仮説H3と整合する（直接の測定は今後）。
- ヒープ使用量は-Ogと同一だった（確保するメモリの大きさはコードの最適化では変わらない）。
- 以降の測定は-O2を基準とする（結果6以降はさらにSP数学ライブラリを基準とする）。

## 結果6：数学ライブラリの影響（FAST_MATH → SP）と、X25519が遅い理由

-O2のまま、`user_settings.h` の `USE_FAST_MATH` を外し、`WOLFSSL_SP_MATH_ALL` と `WOLFSSL_HAVE_SP_ECC`（P-256専用の最適化コード）を有効にした。全値は `results/esp32s3_O2_fastmath_vs_spmath.csv`。

| 処理 | FAST_MATH（ms） | SP（ms） | ヒープ FAST → SP（B） |
| --- | ---: | ---: | --- |
| ECDHE P-256（keygen + agree） | 452.2 | 131.1 | 34,047 → 9,495（agree） |
| ECDSA P-256 検証 | 453.8 | 131.6 | 19,344 → 2,452 |
| X25519（keygen + agree） | 357.7 | 357.7 | 119 → 119 |
| ML-KEM-768（keygen + decap） | 12.0 | 12.0 | 変化なし |
| ML-DSA-44 検証 | 13.0 | 13.0 | 変化なし |

- P-256は約3.4倍速くなり、ヒープも大幅に減った。X25519・Ed25519・ML-KEM・ML-DSAは、汎用の数学ライブラリを使わないため変化しない（予測どおり）。
- **X25519が遅い理由：** wolfSSL v5.9.4の `settings.h` は、Xtensa（ESP32/ESP32-S3のCPU）では `CURVE25519_SMALL` と `ED25519_SMALL` を強制する。コメントによれば「Xtensa向けコンパイラが高速版のCコードを定数時間でない機械語に変換した例がある」ため、タイミング攻撃に安全と分かっている省メモリ版を使わせている（ビルド時に「定数時間の高速実装はwolfSSLサポートに問い合わせを」という警告も出る）。したがってESP32-S3上のX25519の遅さは、安全側に倒した意図的な設計の結果であり、X25519という方式そのものの限界ではない。
- 副次的な観察：SP数学ライブラリではESP32のRSAハードウェア支援が使われなくなり（`esp_mp_mul` 呼び出し0回）、RSA-2048の秘密鍵演算は470 ms → 1,459 msと遅くなった。本研究ではRSAは使わない。

### 公平な条件（-O2、SP）でのまとめ

TLSクライアント（ESP32側）の計算時間：

| 処理 | 古典 | ms | 耐量子 | ms | 比 |
| --- | --- | ---: | --- | ---: | ---: |
| 鍵交換 | X25519 | 357.7 | ML-KEM-768 | 12.0 | 約30倍 |
| 鍵交換 | ECDHE P-256 | 131.1 | ML-KEM-768 | 12.0 | 約11倍 |
| 署名検証 | ECDSA P-256 | 131.6 | ML-DSA-44 | 13.0 | 約10倍 |

ハイブリッド鍵交換の推定：X25519MLKEM768 約370 ms（X25519比 +3%）、SecP256r1MLKEM768 約143 ms（P-256比 +9%）。

ヒープ（各演算のピーク）：ECDSA検証 2.4 KB に対しML-DSA-44検証 30.5 KB（約12倍）。鍵交換はP-256（agree 9.5 KB）とML-KEM-768（decap 12.3 KB）でほぼ同等。耐量子化で増えるRAMの大部分は署名検証側から来ており、H2と同じ向き。計算時間は耐量子の方が約10倍速い一方、メモリは署名で約12倍重い、というトレードオフになる。

## 結果7：PSRAMの有無（ESP32-S3、-O2、SP）

menuconfigで「Support for external, SPI-connected RAM」を無効にし、他は結果6と同じ条件で測定した。全値は `results/esp32s3_psram_on_vs_off.csv`。

- 全演算で速度差は±2%以内、ヒープ使用量は同一だった。ML-DSAのsignだけ±13%前後ばらつくが、増減の向きが揃っておらず、乱数による再試行回数の違いによるものと考えられる（verifyとkeygenは±0.2%以内）。
- 事前の仮説「16 KBを超える確保はPSRAMに置かれ、PSRAMを切るとML-DSAが速くなる」は否定された。理由：ESP-IDF版wolfSSLのメモリ確保は `pvPortMalloc` を通り、ESP-IDF v5.5ではこれが `heap_caps_malloc(size, MALLOC_CAP_INTERNAL | MALLOC_CAP_8BIT)`、つまり**内蔵RAMのみ**から確保する（`components/freertos/heap_idf.c`）。`WOLFSSL_TRACK_MEMORY` 有効時の `TrackMalloc` も同じく `pvPortMalloc` を使う。
- 含意：既定の構成では、PSRAMはwolfSSLのメモリ予算を広げない。TLSで使えるのは内蔵RAMのヒープ（本ボードで約400 KB）だけであり、Phase 3ではWi-Fi・lwIPとこの内蔵RAMを取り合うことになる。wolfSSLをPSRAMに載せたい場合は、`wolfSSL_SetAllocators()` で確保関数を差し替える必要がある（今後の実験候補）。

## 結果8：Keccak置換が占める時間（H3の直接計測）

`patches/keccak_profile.patch`（wolfSSL v5.9.4用）を当て、`user_settings.h` に `#define WC_KECCAK_PROFILE` を追加した。このパッチは、Keccak-f[1600]置換の関数 `BlockSha3` を計測用の関数で包み、呼び出し回数とCPUサイクル数（`esp_cpu_get_cycle_count()`）を数える。そしてベンチマークの各行ごとに、1演算あたりの値を表示する。条件は結果7と同じ（-O2、SP、PSRAM無効）。全値は `results/esp32s3_keccak_profile.csv`。

| 演算 | Keccak呼び出し / 演算 | Keccakが占める割合 |
| --- | ---: | ---: |
| ML-KEM-768 keygen | 34 | 70.4% |
| ML-KEM-768 encap | 35 | 64.8% |
| ML-KEM-768 decap | 44 | 62.0% |
| TLSクライアント側（keygen + decap） | 78 | 65.4% |
| ML-DSA-44 verify | 103 | 77.2% |
| ML-DSA-44 sign | 184.8 | 61.2% |
| ECDSA / X25519 / RSA（対照） | 0 | 0% |

- **H3は支持された。** ML-KEMの処理時間の57〜74%（ML-KEM-768のTLSクライアント側で65%）を、SHA-3系のKeccak置換が占める。ML-DSAではさらに高く、verifyで77〜82%を占める。
- Keccak置換1回の費用は、全演算で約23,000〜25,000サイクル（約0.1 ms）とほぼ一定。これはSHAKE128単体のベンチマーク（140サイクル/バイト × 168バイト ≈ 23,500サイクル）からの見積もりと一致する。
- 事前の机上見積もり（ML-KEM-768 keygenで43回・約88%）は回数を多く数えすぎていた。差の9回は、公開鍵のハッシュH(ek)（1,184バイトのSHA3-256で9回の置換）にあたる。wolfSSLはこれを鍵生成の中では計算せず、別の段階（ベンチマークでは計測区間外の公開鍵デコード時）で計算している。残りの内訳は、行列Aの生成27回、ノイズ6回、G 1回で、合計34回が実測と一致する。decapの44回も、A 27回、ノイズ7回、G 1回、暗黙的拒否用のJ（1,120バイトのSHAKE256で9回）で説明できる。
- 計測用の関数の負荷は無視できる（ML-KEM-768 keygen：計測なし4.781 ms、計測あり4.755 ms）。
- 含意（アムダールの法則）：Keccakが占める割合をfとすると、Keccakだけを無限に速くしても、全体は最大 1/(1−f) 倍しか速くならない。ML-KEM-768のTLSクライアント側（f = 0.654）では最大約2.9倍、Keccakを2倍速くした場合は約1.5倍になる。ESP32-S3でML-KEMを高速化する余地は、多項式演算ではなくKeccakにある。

## 再現手順（Phase 1）

```bash
git clone https://github.com/wolfSSL/wolfssl.git && cd wolfssl
git checkout v5.9.4-stable
./autogen.sh
./configure --enable-mlkem --enable-mldsa --enable-curve25519 --enable-tls-mlkem-standalone
make -j$(nproc)
./wolfcrypt/test/testwolfcrypt
./wolfcrypt/benchmark/benchmark

# 別ターミナルでサーバ起動
./examples/server/server -v 4 -i

# キャプチャと集計（要 tshark）
sudo -v && ./scripts/capture.sh
./scripts/hello_sizes.sh
```

## 今後

- [x] Phase 1：PCでの基準測定（ベンチマーク、ハンドシェイクサイズ）
- [x] Phase 2：ESP32-S3（N16R8）での暗号演算ベンチマーク
  - [x] 速度（PSRAM有効、FAST_MATH）
  - [x] 速度（コンパイラ最適化 -O2、公平性の確認その1）
  - [x] 速度（P-256をSP数学ライブラリで、公平性の確認その2）
  - [x] H3：ML-KEM内のKeccak置換の時間を直接計測（`patches/keccak_profile.patch` を wolfSSL v5.9.4 に適用し、`user_settings.h` に `#define WC_KECCAK_PROFILE` を追加）
  - [x] メモリ使用量（ヒープ、PSRAM有効、FAST_MATH）
  - [x] PSRAM無効での比較
- [ ] Phase 3：ESP32-S3 ⇔ PC間のTLSハンドシェイク測定（鍵交換×証明書）
- [ ] Phase 4：PVDF振動センサノードとしての統合デモ

## スコープ外

通信路の保護のみを扱う。サイドチャネル攻撃・物理攻撃への耐性、端末内データ保護は対象外。
