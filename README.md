# pq-tls-esp32

ESP32-S3上でwolfSSLの耐量子TLS（ML-KEM・ML-DSA）を動かし、鍵交換・証明書・メモリ構成ごとのハンドシェイク時間、RAM使用量、通信量を実測するプロジェクト。

本リポジトリは進行中で、現在はESP32-S3上での暗号演算ベンチマーク（Phase 2）を進めている。

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
- [ ] Phase 2：ESP32-S3（N16R8）での暗号演算ベンチマーク
  - [x] 速度（PSRAM有効、FAST_MATH）
  - [ ] 速度（SP_MATH_ALL、公平性の確認）
  - [x] メモリ使用量（ヒープ、PSRAM有効、FAST_MATH）
  - [ ] PSRAM無効での比較
- [ ] Phase 3：ESP32-S3 ⇔ PC間のTLSハンドシェイク測定（鍵交換×証明書）
- [ ] Phase 4：PVDF振動センサノードとしての統合デモ

## スコープ外

通信路の保護のみを扱う。サイドチャネル攻撃・物理攻撃への耐性、端末内データ保護は対象外。
