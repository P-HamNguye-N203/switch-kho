#!/bin/bash
# Creates the "Switch Kho Local" code-signing identity inside a dedicated,
# password-protected keychain that auto-locks after 15 minutes.
# Without arguments it asks for passwords interactively (run it in Terminal.app).
# With --auto it generates a random keychain password and stores it in the login
# keychain (service "switchkho-signing"), so scripts/build-app.sh can unlock the
# signing keychain without prompting.
set -euo pipefail

AUTO=0
[ "${1:-}" = "--auto" ] && AUTO=1
PW_SERVICE="switchkho-signing"
KCPW=()

KC="$HOME/Library/Keychains/switchkho-signing.keychain-db"
NAME="Switch Kho Local"

if security find-identity -p codesigning "$KC" 2>/dev/null | grep -q "$NAME"; then
    echo "đã có"
    exit 0
fi

if [ "$AUTO" -eq 1 ]; then
    if ! pw="$(security find-generic-password -s "$PW_SERVICE" -a "$USER" -w 2>/dev/null)"; then
        [ -e "$KC" ] && { echo "Keychain ký đã có nhưng không tìm thấy mật khẩu trong login keychain; chạy không có --auto."; exit 1; }
        pw="$(/usr/bin/openssl rand -hex 24)"
        security add-generic-password -s "$PW_SERVICE" -a "$USER" -l "Switch Kho signing keychain" \
            -T /usr/bin/security -w "$pw"
    fi
    KCPW=(-p "$pw")
fi

if [ ! -e "$KC" ]; then
    echo "Tạo keychain riêng."
    security create-keychain ${KCPW[@]+"${KCPW[@]}"} "$KC"
fi
security set-keychain-settings -lut 900 "$KC"

# Add to the user search list while keeping the existing keychains.
existing=()
while IFS= read -r line; do
    line="${line#"${line%%[![:space:]]*}"}"
    line="${line%\"}"
    line="${line#\"}"
    [ -n "$line" ] && [ "$line" != "$KC" ] && existing+=("$line")
done < <(security list-keychains -d user)
security list-keychains -d user -s "${existing[@]}" "$KC"

work="$(mktemp -d)"
chmod 700 "$work"
trap 'rm -rf "$work"' EXIT

cat > "$work/cert.cfg" <<'CFG'
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no

[dn]
CN = Switch Kho Local

[ext]
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
basicConstraints = critical,CA:false
CFG

/usr/bin/openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
    -config "$work/cert.cfg" -keyout "$work/key.pem" -out "$work/cert.pem" 2>/dev/null

P12PW="$(/usr/bin/openssl rand -hex 16)"
export P12PW
legacy=()
if /usr/bin/openssl version | grep -q "^OpenSSL 3"; then
    legacy=(-legacy)
fi
/usr/bin/openssl pkcs12 -export ${legacy[@]+"${legacy[@]}"} -inkey "$work/key.pem" -in "$work/cert.pem" \
    -name "$NAME" -out "$work/id.p12" -passout env:P12PW

echo "Mở khoá keychain riêng."
security unlock-keychain ${KCPW[@]+"${KCPW[@]}"} "$KC"
security import "$work/id.p12" -k "$KC" -P "$P12PW" -T /usr/bin/codesign
unset P12PW
echo "Cho phép codesign dùng khoá."
if [ "$AUTO" -eq 1 ]; then
    security set-key-partition-list -S apple-tool:,apple: -s -k "$pw" "$KC" >/dev/null
else
    security set-key-partition-list -S apple-tool:,apple: -s "$KC" >/dev/null
fi

echo "Xong: danh tính \"$NAME\" nằm trong $KC"
