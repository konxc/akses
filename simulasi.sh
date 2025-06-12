#!/bin/bash

set -e

# Warna
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
BLUE='\033[0;34m'
NC='\033[0m' # no color

ENV_DIR="$HOME/.akses"
ENV_FILE="$ENV_DIR/.env"

# Cek dependensi
check_dependencies() {
    if ! command -v jq >/dev/null 2>&1; then
        echo -e "${RED}❌ Program 'jq' belum terinstal.${NC}"
        echo -e "${YELLOW}Program ini dibutuhkan untuk parsing JSON dari API Cloudflare.${NC}"
        echo ""
        read -p "Apakah Anda ingin menginstalnya sekarang? (y/N): " install_choice
        if [[ "$install_choice" =~ ^[Yy]$ ]]; then
            sudo apt update && sudo apt install -y jq
        else
            echo -e "${RED}Tidak bisa melanjutkan tanpa 'jq'. Keluar.${NC}"
            exit 1
        fi
    fi
}

# Muat token dari ~/.akses/.env jika ada
load_token_if_available() {
    if [ -f "$ENV_FILE" ]; then
        source "$ENV_FILE"
        if [[ -n "$CF_API_TOKEN" ]]; then
            echo -e "${BLUE}🔐 Mendeteksi token dari $ENV_FILE...${NC}"
            # Uji token
            response=$(curl -s -H "Authorization: Bearer $CF_API_TOKEN" \
                -H "Content-Type: application/json" \
                https://api.cloudflare.com/client/v4/zones)
            if echo "$response" | jq -e '.success == true' >/dev/null; then
                echo -e "${GREEN}✅ Token valid. Melanjutkan dengan token yang sudah ada.${NC}"
                return
            else
                echo -e "${YELLOW}⚠️ Token di $ENV_FILE tidak valid atau sudah kedaluwarsa.${NC}"
                unset CF_API_TOKEN
            fi
        fi
    fi
}

# Ambil token baru dan simpan ke ~/.akses/.env
get_api_token() {
    echo -e "${YELLOW}Cloudflare API membutuhkan token otentikasi untuk akses DNS Records.${NC}"
    echo "Silakan buat token API di sini:"
    echo "🔗 https://dash.cloudflare.com/profile/api-tokens"
    echo ""
    echo -e "${GREEN}Rekomendasi Scope Token:${NC}"
    echo "  - Zone → DNS → Read"
    echo "  - Zone Resources → Include → zona/domain yang ingin digunakan"
    echo ""
    read -p "Tekan [Enter] setelah Anda membuat token di browser..."
    echo ""
    read -p "Silakan paste token API Anda di sini: " CF_API_TOKEN

    if [[ -z "$CF_API_TOKEN" || ${#CF_API_TOKEN} -lt 20 ]]; then
        echo -e "${RED}❌ Token kosong atau terlalu pendek.${NC}"
        exit 1
    fi

    # Cek validitas
    echo ""
    echo -e "${BLUE}🔍 Mengecek token ke server Cloudflare...${NC}"
    response=$(curl -s -H "Authorization: Bearer $CF_API_TOKEN" \
        -H "Content-Type: application/json" \
        https://api.cloudflare.com/client/v4/zones)

    if echo "$response" | jq -e '.success == true' >/dev/null; then
        echo -e "${GREEN}✅ Token valid.${NC}"
        mkdir -p "$ENV_DIR"
        echo "CF_API_TOKEN=$CF_API_TOKEN" > "$ENV_FILE"
        echo -e "${GREEN}📁 Token disimpan ke $ENV_FILE${NC}"
    else
        echo -e "${RED}❌ Token yang Anda masukkan tidak valid.${NC}"
        exit 1
    fi
}

# Ambil daftar zone
get_zone_id_interaktif() {
    echo ""
    echo -e "${BLUE}📦 Mengambil daftar zona dari akun Anda...${NC}"
    ZONES=$(curl -s -X GET "https://api.cloudflare.com/client/v4/zones" \
        -H "Authorization: Bearer $CF_API_TOKEN" \
        -H "Content-Type: application/json")

    echo ""

    mapfile -t ZONE_NAMES < <(echo "$ZONES" | jq -r '.result[].name')
    mapfile -t ZONE_IDS < <(echo "$ZONES" | jq -r '.result[].id')

    for i in "${!ZONE_NAMES[@]}"; do
        echo "  $((i+1))) ${ZONE_NAMES[$i]}"
    done

    echo ""
    read -p "Pilih nomor zona yang ingin digunakan: " zone_choice
    ZONE_ID="${ZONE_IDS[$((zone_choice - 1))]}"
    ZONE_NAME="${ZONE_NAMES[$((zone_choice - 1))]}"

    if [ -z "$ZONE_ID" ]; then
        echo -e "${RED}❌ Zona tidak valid atau tidak terdeteksi.${NC}"
        exit 1
    fi

    echo -e "${GREEN}✅ Zona terpilih: $ZONE_NAME (ID: $ZONE_ID)${NC}"
}

# Ambil daftar subdomain CNAME
get_subdomain_choice() {
    echo ""
    echo -e "${BLUE}🌐 Mengambil daftar DNS record (CNAME) untuk $ZONE_NAME...${NC}"
    DNS=$(curl -s -X GET "https://api.cloudflare.com/client/v4/zones/$ZONE_ID/dns_records?type=CNAME" \
        -H "Authorization: Bearer $CF_API_TOKEN" \
        -H "Content-Type: application/json")

    echo ""

    mapfile -t SUBDOMAINS < <(echo "$DNS" | jq -r '.result[].name')
    mapfile -t CNAME_TARGETS < <(echo "$DNS" | jq -r '.result[].content')

    if [ "${#SUBDOMAINS[@]}" -eq 0 ]; then
        echo -e "${YELLOW}⚠️  Tidak ada CNAME record ditemukan di zona ini.${NC}"
        exit 0
    fi

    echo -e "${GREEN}| No | FQDN                        | Tunnel (ID) / Point Name              |${NC}"
    echo -e "${GREEN}|----|-----------------------------|----------------------------------------|${NC}"

    for i in "${!SUBDOMAINS[@]}"; do
        fqdn="${SUBDOMAINS[$i]}"
        target="${CNAME_TARGETS[$i]}"
        tunnel_info="$target"

        # Jika target mengarah ke .cfargotunnel.com → ekstrak ID
        if [[ "$target" =~ ^([a-f0-9-]{36})\.cfargotunnel\.com$ ]]; then
            tunnel_id="${BASH_REMATCH[1]}"
            tunnel_info="${TUNNEL_MAP[$tunnel_id]:-$tunnel_id (ID tidak dikenal)}"
        fi

        printf "| %2d | %-27s | %-38s |\n" "$((i + 1))" "$fqdn" "$tunnel_info"
    done

    echo ""
    read -p "Pilih nomor subdomain yang ingin diperiksa: " sub_choice
    SELECTED="${SUBDOMAINS[$((sub_choice - 1))]}"
    TARGET="${CNAME_TARGETS[$((sub_choice - 1))]}"

    if [ -z "$SELECTED" ]; then
        echo -e "${RED}❌ Subdomain tidak valid.${NC}"
        exit 1
    fi

    echo -e "${GREEN}✅ Subdomain terpilih: $SELECTED → $TARGET${NC}"
}

# Cek dan instal cloudflared jika belum tersedia
check_cloudflared() {
    if ! command -v cloudflared >/dev/null 2>&1; then
        echo -e "${RED}❌ cloudflared belum terinstal.${NC}"
        echo "Program ini dibutuhkan untuk mengidentifikasi nama tunnel dari ID."
        read -p "Apakah Anda ingin menginstalnya sekarang? (y/N): " install_choice
        if [[ "$install_choice" =~ ^[Yy]$ ]]; then
            curl -L https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64 -o cloudflared
            chmod +x cloudflared
            sudo mv cloudflared /usr/local/bin/
        else
            echo -e "${RED}Tidak bisa melanjutkan tanpa cloudflared.${NC}"
            exit 1
        fi
    fi
}

# Ambil mapping ID → tunnel name
build_tunnel_id_map() {
    declare -gA TUNNEL_MAP
    while IFS= read -r line; do
        id=$(echo "$line" | awk '{print $1}')
        name=$(echo "$line" | awk '{print $2}')
        if [[ "$id" =~ ^[a-f0-9-]{36}$ ]]; then
            short_id="${id:0:8}"
            TUNNEL_MAP["$id"]="$name ($short_id...)"
        fi
    done < <(cloudflared tunnel list 2>/dev/null | tail -n +3)
}

# Main eksekusi
main() {
	echo -e "${GREEN}=== Simulasi Interaktif Cloudflare API dengan .env Otomatis ===${NC}"
	echo ""
	check_dependencies
	check_cloudflared
	build_tunnel_id_map
	load_token_if_available

	if [[ -z "$CF_API_TOKEN" ]]; then
		get_api_token
	fi

	get_zone_id_interaktif
	get_subdomain_choice
}

main

