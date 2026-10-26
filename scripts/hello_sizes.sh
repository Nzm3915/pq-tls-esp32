#!/bin/bash
# Print ClientHello (1) / ServerHello (2) size and key_share length per capture.
# Columns: handshake type, handshake length (B), key_share key_exchange length (B)
OUT_DIR="${OUT_DIR:-/tmp}"
for f in x25519 hybrid mlkem; do
  echo "== $f"
  sudo tshark -r "$OUT_DIR/$f.pcap" \
    -Y "tls.handshake.type==1 || tls.handshake.type==2" \
    -T fields -e tls.handshake.type -e tls.handshake.length \
    -e tls.handshake.extensions_key_share_key_exchange_length 2>/dev/null
done
