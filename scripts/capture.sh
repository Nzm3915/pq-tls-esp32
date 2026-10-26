#!/bin/bash
# Capture TLS 1.3 handshakes for three key-exchange groups over loopback.
# Prerequisite: wolfSSL example server running in another terminal:
#   ./examples/server/server -v 4 -i
# Usage: sudo -v && ./scripts/capture.sh   (WOLFSSL_DIR defaults to ~/wolfssl)
set -u
WOLFSSL_DIR="${WOLFSSL_DIR:-$HOME/wolfssl}"
OUT_DIR="${OUT_DIR:-/tmp}"
cd "$WOLFSSL_DIR"
for mode in x25519 hybrid mlkem; do
  case $mode in
    x25519) opt="-t" ;;
    hybrid) opt="--pqc X25519MLKEM768" ;;
    mlkem)  opt="--pqc ML_KEM_768" ;;
  esac
  sudo tshark -q -i lo -f "tcp port 11111" -a duration:6 -w "$OUT_DIR/$mode.pcap" &
  sleep 2
  ./examples/client/client -v 4 $opt
  wait
done
